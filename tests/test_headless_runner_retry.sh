#!/usr/bin/env bash
# test_headless_runner_retry.sh — verifies headless_runner_invoke retries
# transient flakes (empty output, non-JSON output, non-zero subprocess) and
# bypasses retry for setup errors.
#
# Strategy: stub out `claude` on PATH with a script whose behavior is driven
# by a state file (attempt counter). Source audit-artifact.sh to expose
# headless_runner_invoke at test scope. Drive it with different stub recipes
# and assert outcomes.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

TEST_ROOT="$(mktemp -d -t lore-headless-retry.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# Stub claude binary. Behavior is driven by:
#   $STUB_DIR/recipe — newline-separated list of outcomes; each invocation
#                      consumes the next line. Outcomes:
#                        empty            — write empty stdout, exit 0
#                        nonjson          — write "not json" to stdout, exit 0
#                        json:<inline>    — write the inline JSON to stdout, exit 0
#                        fail:<rc>        — write nothing, exit with rc (e.g. fail:1)
#   $STUB_DIR/attempt_count — incremented on each call; readable post-test.
STUB_DIR="$TEST_ROOT/stub"
mkdir -p "$STUB_DIR"
STUB_BIN_DIR="$TEST_ROOT/bin"
mkdir -p "$STUB_BIN_DIR"

cat > "$STUB_BIN_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# Read everything from stdin so the parent's `printf '%s' "$user_prompt" | claude ...`
# completes without SIGPIPE.
cat >/dev/null
attempt_file="$STUB_DIR/attempt_count"
recipe_file="$STUB_DIR/recipe"
n=$(( $(cat "$attempt_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$attempt_file"
recipe=$(sed -n "${n}p" "$recipe_file" 2>/dev/null)
case "$recipe" in
  empty)
    exit 0
    ;;
  nonjson)
    printf 'not json\n'
    exit 0
    ;;
  json:*)
    printf '%s' "${recipe#json:}"
    exit 0
    ;;
  fail:*)
    exit "${recipe#fail:}"
    ;;
  *)
    # Unknown recipe — treat as malformed test setup.
    printf 'unknown recipe: %s' "$recipe" >&2
    exit 99
    ;;
esac
STUB
chmod +x "$STUB_BIN_DIR/claude"
export STUB_DIR

# Audit-artifact.sh expects `lore` library functions and an active framework.
# Source it in a controlled environment so we can call headless_runner_invoke
# directly. The library's framework lookup must report claude-code so the
# headless runner takes the `claude -p` branch.
export PATH="$STUB_BIN_DIR:$PATH"
export LORE_FRAMEWORK="claude-code"
# Pin attempts low and backoff zero so the tests run fast.
export LORE_JUDGE_MAX_ATTEMPTS=3
export LORE_JUDGE_RETRY_BACKOFF_SECS=0

# Sourcing the script triggers its option parser; we need to keep $@ empty so
# it sees no args, BUT it also calls main logic at the bottom. Instead of
# sourcing the full script, extract the two functions we need by sourcing a
# trimmed copy. Easier: invoke via a small driver that sources the library
# and the two functions.
DRIVER="$TEST_ROOT/driver.sh"
cat > "$DRIVER" <<DRIVEREOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/lib.sh"

# Pull the headless_runner_invoke + _headless_runner_invoke_once functions
# from audit-artifact.sh by sed-extracting the function blocks. This avoids
# running the script's main logic.
eval "\$(awk '
  /^(_headless_runner_invoke_once|headless_runner_invoke|split_codex_model_variant)\(\) \{/ { capture=1 }
  capture { print }
  capture && /^\}\$/ { capture=0 }
' "$SCRIPT_DIR/audit-artifact.sh")"

# framework_capability is from lib.sh; force it to "full" by exporting an
# override env var that lib.sh honors (the helper falls back to a static map
# when capabilities.json is absent — for claude-code the map has
# headless_runner=full).
export LORE_FRAMEWORK="claude-code"
JUDGE_MODEL="opus"

# Args: <sys_file> <user_prompt> <output_file>
headless_runner_invoke "\$1" "\$2" "\$3"
DRIVEREOF
chmod +x "$DRIVER"

# Helper: reset the stub state and recipe, then invoke the driver.
run_case() {
  local recipe_lines="$1"
  local sys_file="$TEST_ROOT/sys.md"
  local out_file="$TEST_ROOT/out.txt"
  echo "test system prompt" > "$sys_file"
  : > "$out_file"
  printf '%s' "$recipe_lines" > "$STUB_DIR/recipe"
  echo 0 > "$STUB_DIR/attempt_count"
  bash "$DRIVER" "$sys_file" "test user prompt" "$out_file" 2>"$TEST_ROOT/stderr.log"
  echo $?
}

attempts() { cat "$STUB_DIR/attempt_count"; }
out_contents() { cat "$TEST_ROOT/out.txt"; }
stderr_contents() { cat "$TEST_ROOT/stderr.log"; }

echo "=== headless_runner_invoke retry tests ==="

echo ""
echo "Test 1: first attempt succeeds → no retry, no waste"
rc=$(run_case "json:{\"ok\":true}")
if [[ "$rc" == "0" ]] && [[ "$(attempts)" == "1" ]]; then
  pass "happy path: rc=0, attempts=1"
else
  fail "expected rc=0 attempts=1, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi

echo ""
echo "Test 2: empty output then valid JSON → retries and succeeds on attempt 2"
rc=$(run_case "empty
json:{\"ok\":true}")
if [[ "$rc" == "0" ]] && [[ "$(attempts)" == "2" ]]; then
  pass "empty→valid: rc=0, attempts=2"
else
  fail "expected rc=0 attempts=2, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi
if stderr_contents | grep -q "succeeded on attempt 2"; then
  pass "stderr advertises retry success on attempt 2"
else
  fail "expected 'succeeded on attempt 2' in stderr; got: $(stderr_contents)"
fi

echo ""
echo "Test 3: non-JSON output then valid JSON → retries and succeeds on attempt 2"
rc=$(run_case "nonjson
json:{\"ok\":true}")
if [[ "$rc" == "0" ]] && [[ "$(attempts)" == "2" ]]; then
  pass "nonjson→valid: rc=0, attempts=2"
else
  fail "expected rc=0 attempts=2, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi

echo ""
echo "Test 4: subprocess failure then valid JSON → retries and succeeds on attempt 2"
rc=$(run_case "fail:1
json:{\"ok\":true}")
if [[ "$rc" == "0" ]] && [[ "$(attempts)" == "2" ]]; then
  pass "rc=1→valid: rc=0, attempts=2"
else
  fail "expected rc=0 attempts=2, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi

echo ""
echo "Test 5: exhaust retries on persistent empty output → return 65, attempts hit max"
rc=$(run_case "empty
empty
empty")
if [[ "$rc" == "65" ]] && [[ "$(attempts)" == "3" ]]; then
  pass "exhaustion: rc=65, attempts=3"
else
  fail "expected rc=65 attempts=3, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi
if stderr_contents | grep -q "exhausted 3 attempts"; then
  pass "stderr advertises exhaustion"
else
  fail "expected 'exhausted 3 attempts' in stderr; got: $(stderr_contents)"
fi

echo ""
echo "Test 6: exhaust retries on persistent non-JSON → return 66"
rc=$(run_case "nonjson
nonjson
nonjson")
if [[ "$rc" == "66" ]] && [[ "$(attempts)" == "3" ]]; then
  pass "non-JSON exhaustion: rc=66, attempts=3"
else
  fail "expected rc=66 attempts=3, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi

echo ""
echo "Test 7: LORE_JUDGE_MAX_ATTEMPTS=1 disables retry (single-attempt mode)"
export LORE_JUDGE_MAX_ATTEMPTS=1
rc=$(run_case "empty
json:{\"ok\":true}")
if [[ "$rc" == "65" ]] && [[ "$(attempts)" == "1" ]]; then
  pass "single-attempt: rc=65, attempts=1, no retry attempted"
else
  fail "expected rc=65 attempts=1 (no retry), got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi
export LORE_JUDGE_MAX_ATTEMPTS=3

echo ""
echo "Test 8: setup error (claude not on PATH) bypasses retry"
# Remove claude from PATH for this case
SAVED_PATH="$PATH"
export PATH="$REPO_DIR:/usr/bin:/bin"
rc=$(run_case "json:{\"ok\":true}")
export PATH="$SAVED_PATH"
# rc=64 (setup error) AND attempt counter never increments because claude was never called
if [[ "$rc" == "64" ]] && [[ "$(attempts)" == "0" ]]; then
  pass "setup error: rc=64, attempts=0 (no retry waste)"
else
  fail "expected rc=64 attempts=0, got rc=$rc attempts=$(attempts); stderr: $(stderr_contents)"
fi

echo ""
echo "=== Results ==="
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
