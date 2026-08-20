#!/usr/bin/env bash
# test_guard_session_worktree_writes.sh — Acceptance for the session-scoped write
# fence: path classification, the tri-state hosted gate, and the degraded contexts.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/scripts/guard-session-worktree-writes.sh"
TEST_DIR=$(mktemp -d)
STORE="$TEST_DIR/store"
OWN="$STORE/_sessions/worktrees/own"
SIBLING="$STORE/_sessions/worktrees/sibling"
COORDINATED="$STORE/_coordination/worktrees/trees/stream-1"
ELSEWHERE="$TEST_DIR/another-clone"
# A dedicated TMPDIR so the fixture tree is not itself inside the allowed
# temporary root — on macOS every mktemp path is.
export TMPDIR="$TEST_DIR/tmp"
mkdir -p "$STORE/conventions" "$OWN" "$SIBLING" "$COORDINATED" "$ELSEWHERE" "$TMPDIR"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

hosted_env() {
  echo "LORE_SESSION_INSTANCE=amber-otter"
  echo "LORE_SESSION_SLUG=feature-x"
  echo "LORE_SESSION_TYPE=implement"
  echo "LORE_SESSION_WORKTREE=$OWN"
  echo "LORE_SESSION_STORE_ROOT=$STORE"
}

# run <payload> [env-overrides...] — the guard's stdout, with stderr discarded.
run() {
  local payload="$1"; shift
  local -a assignments=()
  while IFS= read -r line; do assignments+=("$line"); done < <(hosted_env)
  printf '%s' "$payload" | env "${assignments[@]}" "$@" bash "$GUARD" 2>/dev/null
}

decision() {
  python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["decision"])
except Exception:
    print("<no-decision>")'
}

assert_decision() {
  local label="$1" want="$2" payload="$3"; shift 3
  local got
  got=$(run "$payload" "$@" | decision)
  if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want $want, got $got"; fi
}

payload() {
  python3 -c 'import json,sys
row = {"tool_name": sys.argv[1], "cwd": sys.argv[2], "session_id": "harness-1"}
if sys.argv[3] != "<none>":
    row["tool_input"] = {"file_path": sys.argv[3]}
else:
    row["tool_input"] = {}
print(json.dumps(row))' "$1" "$2" "$3"
}

echo "== allowlist classification =="
for tool in Edit Write; do
  assert_decision "$tool inside the session's own checkout is approved" approve "$(payload "$tool" "$OWN" "$OWN/file.txt")"
  assert_decision "$tool into a sibling session worktree is refused" block "$(payload "$tool" "$OWN" "$SIBLING/file.txt")"
  assert_decision "$tool into a coordinated writer's tree is refused" block "$(payload "$tool" "$OWN" "$COORDINATED/file.txt")"
  assert_decision "$tool into a path belonging to no checkout is refused" block "$(payload "$tool" "$OWN" "$ELSEWHERE/file.txt")"
  assert_decision "$tool into the store outside the managed namespaces is approved" approve "$(payload "$tool" "$OWN" "$STORE/conventions/entry.md")"
  assert_decision "$tool into the temporary directory is approved" approve "$(payload "$tool" "$OWN" "$TMPDIR/scratch.txt")"
done

echo "== path resolution =="
assert_decision "a not-yet-created leaf under the own checkout is approved" approve \
  "$(payload Write "$OWN" "$OWN/does/not/exist/yet.txt")"
assert_decision "a relative target resolves against the payload working directory" approve \
  "$(payload Edit "$OWN" "nested/file.txt")"
assert_decision "a relative target resolved out of the checkout is refused" block \
  "$(payload Edit "$OWN" "../sibling/file.txt")"
ln -sfn "$ELSEWHERE" "$OWN/escape-link"
assert_decision "a write through a symlink out of the checkout is refused" block \
  "$(payload Write "$OWN" "$OWN/escape-link/file.txt")"
ln -sfn "$STORE/conventions" "$OWN/store-link"
assert_decision "a write through a symlink into an allowed root is approved" approve \
  "$(payload Write "$OWN" "$OWN/store-link/entry.md")"
assert_decision "a tool call naming no path is approved unclassified" approve \
  "$(payload Write "$OWN" "<none>")"

echo "== hosted gate =="
journal_rows() { [[ -f "$STORE/_sessions/events.jsonl" ]] && wc -l <"$STORE/_sessions/events.jsonl" | tr -d ' ' || echo 0; }
before=$(journal_rows)
got=$(printf '%s' "$(payload Edit "$OWN" "$ELSEWHERE/file.txt")" | \
  env -u LORE_SESSION_INSTANCE -u LORE_SESSION_SLUG -u LORE_SESSION_TYPE \
      -u LORE_SESSION_WORKTREE -u LORE_SESSION_STORE_ROOT bash "$GUARD" 2>/dev/null | decision)
if [[ "$got" == "approve" ]]; then pass "an operator's own terminal is never fenced"; else fail "an operator's own terminal is never fenced" "got $got"; fi
if [[ "$(journal_rows)" == "$before" ]]; then
  pass "the same call unfenced appends no journal row"
else
  fail "the same call unfenced appends no journal row" "rows went $before -> $(journal_rows)"
fi

echo "== degraded containment context =="
assert_decision "a hosted session with no declared boundary is refused" block \
  "$(payload Edit "$OWN" "$OWN/file.txt")" LORE_SESSION_WORKTREE=
assert_decision "a hosted session whose boundary names no directory is refused" block \
  "$(payload Edit "$OWN" "$OWN/file.txt")" "LORE_SESSION_WORKTREE=$TEST_DIR/gone"
assert_decision "a relative target with no reported working directory is refused" block \
  '{"tool_name":"Edit","session_id":"harness-1","tool_input":{"file_path":"rel.txt"}}'
assert_decision "a payload with no tool_input object is refused" block \
  '{"tool_name":"Edit","cwd":"/","tool_input":"not-an-object"}'
assert_decision "an unreadable payload is refused" block 'not json at all'

echo "== journaled refusals =="
EVENTS="$STORE/_sessions/events.jsonl"
rm -f "$EVENTS"
run "$(payload Edit "$OWN" "$SIBLING/file.txt")" >/dev/null
run "$(payload Write "$OWN" "$OWN/file.txt")" LORE_SESSION_WORKTREE= >/dev/null
if python3 - "$EVENTS" "$SIBLING/file.txt" "$OWN" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
assert len(rows) == 2, rows
outside, missing = rows
assert outside["event"] == "worktree_write_refused", outside
assert outside["reason"] == "outside-session-allowlist", outside
assert outside["actor_instance"] == "amber-otter", outside
assert outside["slug"] == "feature-x", outside
assert outside["links"]["tool_name"] == "Edit", outside
assert outside["links"]["harness_session_id"] == "harness-1", outside
assert outside["links"]["target_path"].endswith("/sibling/file.txt"), outside
assert outside["links"]["worktree_path"].endswith("/own"), outside
assert missing["reason"] == "containment-context-missing", missing
assert missing["links"]["tool_name"] == "Write", missing
assert "worktree_path" not in missing["links"], missing
assert all(v != "" for v in missing["links"].values()), missing
PY
then pass "refusal rows name the target, the boundary, and the tool"
else fail "refusal rows name the target, the boundary, and the tool"; fi

echo "== a refusal with nowhere to journal still refuses =="
got=$(printf '%s' "$(payload Edit "$OWN" "$SIBLING/file.txt")" | \
  env LORE_SESSION_INSTANCE=amber-otter "LORE_SESSION_WORKTREE=$OWN" \
      "LORE_SESSION_STORE_ROOT=$TEST_DIR/no-such-store" bash "$GUARD" 2>/dev/null | decision)
if [[ "$got" == "block" ]]; then pass "an unusable store root blocks rather than approving"; else fail "an unusable store root blocks rather than approving" "got $got"; fi
stderr=$(printf '%s' "$(payload Edit "$OWN" "$SIBLING/file.txt")" | \
  env LORE_SESSION_INSTANCE=amber-otter "LORE_SESSION_WORKTREE=$OWN" \
      "LORE_SESSION_STORE_ROOT=$TEST_DIR/no-such-store" bash "$GUARD" 2>&1 >/dev/null)
if [[ "$stderr" == *"not journaled"* ]]; then pass "the missing journal destination is reported on stderr"; else fail "the missing journal destination is reported on stderr" "$stderr"; fi
# An events.jsonl that cannot be appended to: the sole writer fails, and the
# refusal must survive that.
rm -f "$EVENTS"; mkdir -p "$EVENTS"
out=$(printf '%s' "$(payload Edit "$OWN" "$SIBLING/file.txt")" | \
  env LORE_SESSION_INSTANCE=amber-otter "LORE_SESSION_WORKTREE=$OWN" \
      "LORE_SESSION_STORE_ROOT=$STORE" bash "$GUARD" 2>"$TEST_DIR/append-fail.err")
if [[ "$(printf '%s' "$out" | decision)" == "block" ]]; then pass "a failed append still emits the blocking decision"; else fail "a failed append still emits the blocking decision" "got $(printf '%s' "$out" | decision)"; fi
if [[ "$(cat "$TEST_DIR/append-fail.err")" == *"journaled nowhere"* ]]; then pass "a failed append is reported on stderr"; else fail "a failed append is reported on stderr" "$(cat "$TEST_DIR/append-fail.err")"; fi
rmdir "$EVENTS"

assert_decision "an empty payload blocks rather than approving" block ""

echo
echo "  $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
