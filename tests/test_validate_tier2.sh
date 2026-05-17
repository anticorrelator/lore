#!/usr/bin/env bash
# test_validate_tier2.sh — Phase 1 schema enforcement tests for the Tier 2
# evidence validator (`scripts/validate-tier2.sh`) and the writer-path gate in
# `scripts/evidence-append.sh`.
#
# Covers the nine cases from the implementation phase's verification block:
#   1. missing exact_snippet rejected
#   2. missing normalized_snippet_hash rejected
#   3. empty exact_snippet rejected
#   4. malformed hash rejected (uppercase / non-hex / wrong length)
#   5. hash mismatch rejected
#   6. valid round-trip accepted (whitespace-collapse, curly-quote, multi-line)
#   7. direct validator accepts `provenance: "legacy-no-snippet"` (no snippet/hash)
#   8. direct validator rejects the mixed state (legacy marker + snippet/hash)
#   9. evidence-append.sh rejects the legacy marker at the writer-path gate

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
VALIDATE="$SCRIPTS_DIR/validate-tier2.sh"
APPEND="$SCRIPTS_DIR/evidence-append.sh"
NORMALIZE_PY="$SCRIPTS_DIR/snippet_normalize.py"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Build a base row that passes every check EXCEPT what each test mutates.
# Caller supplies overrides via python kwargs serialized through env.
build_row() {
  python3 - "$@" <<'PYEOF'
import json, sys
base = {
    "claim_id": "t-1",
    "tier": "task-evidence",
    "claim": "claim text",
    "producer_role": "worker",
    "protocol_slot": "implement-phase-1",
    "task_id": "task-1",
    "phase_id": "phase-1",
    "scale": "implementation",
    "file": "/tmp/example.py",
    "line_range": "10-20",
    "falsifier": "falsifier text",
    "why_this_work_needs_it": "because reasons",
    "captured_at_sha": "deadbeef",
    "change_context": {
        "diff_ref": None,
        "changed_files": ["/tmp/example.py"],
        "summary": "summary",
    },
}
# Override key=value pairs from argv (value parsed as JSON).
for arg in sys.argv[1:]:
    k, v = arg.split("=", 1)
    if v == "__DELETE__":
        base.pop(k, None)
    else:
        base[k] = json.loads(v)
print(json.dumps(base))
PYEOF
}

hash_of() {
  printf '%s' "$1" | python3 "$NORMALIZE_PY" --hash
}

# A real, well-formed snippet+hash pair we can reuse.
GOOD_SNIPPET="hello world"
GOOD_HASH=$(hash_of "$GOOD_SNIPPET")

run_validator() {
  local row="$1"
  if printf '%s' "$row" | bash "$VALIDATE" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "reject"
  fi
}

run_appender() {
  # Append to a throwaway KDIR. Returns "pass" or "reject".
  local row="$1"
  local kdir="$TEST_DIR/kdir-append"
  rm -rf "$kdir"
  mkdir -p "$kdir/_work/wi"
  if printf '%s' "$row" | bash "$APPEND" --work-item wi --kdir "$kdir" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "reject"
  fi
}

echo "Setup sanity:"
assert_eq "good_hash is 64-char lowercase hex" \
  "$(printf '%s' "$GOOD_HASH" | grep -cE '^[0-9a-f]{64}$')" "1"

echo ""
echo "Test 1: missing exact_snippet is rejected"
ROW=$(build_row \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=\"$GOOD_HASH\"")
assert_eq "validator rejects row with no exact_snippet" "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 2: missing normalized_snippet_hash is rejected"
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=__DELETE__")
assert_eq "validator rejects row with no normalized_snippet_hash" "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 3: empty exact_snippet is rejected"
ROW=$(build_row \
  "exact_snippet=\"\"" \
  "normalized_snippet_hash=\"$(hash_of "")\"")
assert_eq "validator rejects empty snippet (even with consistent hash)" \
  "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 4: malformed hash is rejected"

# 4a: uppercase hex (rule says lowercase only)
UPPER_HASH=$(printf '%s' "$GOOD_HASH" | tr 'a-f' 'A-F')
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$UPPER_HASH\"")
assert_eq "validator rejects uppercase hash" "$(run_validator "$ROW")" "reject"

# 4b: non-hex chars
NONHEX_HASH=$(printf '%s' "$GOOD_HASH" | sed 's/./z/1')
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$NONHEX_HASH\"")
assert_eq "validator rejects non-hex hash" "$(run_validator "$ROW")" "reject"

# 4c: wrong length (63 chars)
SHORT_HASH=${GOOD_HASH:0:63}
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$SHORT_HASH\"")
assert_eq "validator rejects 63-char hash" "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 5: hash mismatch (well-formed but wrong) is rejected"
WRONG_HASH=$(hash_of "different content entirely")
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$WRONG_HASH\"")
assert_eq "validator rejects mismatched hash" "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 6: valid round-trip accepted (whitespace, curly quotes, multi-line)"

# 6a: trivial
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$GOOD_HASH\"")
assert_eq "validator accepts trivial snippet+hash pair" "$(run_validator "$ROW")" "pass"

# 6b: whitespace-collapse — producer hashes the v1-normalized form
WS_SNIPPET=$'hello\n\tworld   foo'   # post-norm: "hello world foo"
WS_HASH=$(hash_of "$WS_SNIPPET")
ROW=$(BASE="$(build_row)" S="$WS_SNIPPET" H="$WS_HASH" python3 -c '
import json,os
base = json.loads(os.environ["BASE"])
base["exact_snippet"] = os.environ["S"]
base["normalized_snippet_hash"] = os.environ["H"]
print(json.dumps(base))
')
assert_eq "validator accepts whitespace-collapsed snippet" "$(run_validator "$ROW")" "pass"

# 6c: curly quotes — both U+2018/2019 and U+201C/201D normalize to ASCII
CQ_SNIPPET=$'\xe2\x80\x9chello\xe2\x80\x9d \xe2\x80\x98world\xe2\x80\x99'
CQ_HASH=$(hash_of "$CQ_SNIPPET")
ROW=$(BASE="$(build_row)" S="$CQ_SNIPPET" H="$CQ_HASH" python3 -c '
import json,os
base = json.loads(os.environ["BASE"])
base["exact_snippet"] = os.environ["S"]
base["normalized_snippet_hash"] = os.environ["H"]
print(json.dumps(base))
')
assert_eq "validator accepts curly-quoted snippet" "$(run_validator "$ROW")" "pass"

# 6d: multi-line snippet
ML_SNIPPET=$'def foo():\n    return 1\n\n    # extra'
ML_HASH=$(hash_of "$ML_SNIPPET")
ROW=$(BASE="$(build_row)" S="$ML_SNIPPET" H="$ML_HASH" python3 -c '
import json,os
base = json.loads(os.environ["BASE"])
base["exact_snippet"] = os.environ["S"]
base["normalized_snippet_hash"] = os.environ["H"]
print(json.dumps(base))
')
assert_eq "validator accepts multi-line snippet" "$(run_validator "$ROW")" "pass"

echo ""
echo "Test 7: direct validator accepts legacy slow-path state"
ROW=$(build_row \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"")
assert_eq "validator accepts legacy-no-snippet with no snippet/hash" \
  "$(run_validator "$ROW")" "pass"

echo ""
echo "Test 8: direct validator rejects mixed state (legacy marker + snippet/hash)"
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$GOOD_HASH\"" \
  "provenance=\"legacy-no-snippet\"")
assert_eq "validator rejects mixed legacy+snippet+hash state" \
  "$(run_validator "$ROW")" "reject"

# Also reject partial mixed (legacy marker + only snippet).
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"")
assert_eq "validator rejects legacy marker + snippet alone" \
  "$(run_validator "$ROW")" "reject"

echo ""
echo "Test 9: evidence-append.sh rejects the legacy marker at the writer gate"
ROW=$(build_row \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"")
assert_eq "evidence-append rejects legacy-no-snippet rows" \
  "$(run_appender "$ROW")" "reject"

# Sanity: a fresh valid row appends.
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$GOOD_HASH\"")
assert_eq "evidence-append accepts a valid fast-path row" \
  "$(run_appender "$ROW")" "pass"

echo ""
echo "Test 10: D2 grandfather waiver — legacy row missing change_context is accepted"
# Pre-Phase-1 producer rows lack change_context entirely. The slow-path
# terminal state grandfathers them against this requirement; the validator
# must accept such rows (other required fields still present).
ROW=$(build_row \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"" \
  "change_context=__DELETE__")
assert_eq "validator accepts legacy-no-snippet row missing change_context" \
  "$(run_validator "$ROW")" "pass"

# Legacy row with change_context present is also accepted (waiver is gated,
# not mandatory absence).
ROW=$(build_row \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"")
assert_eq "validator accepts legacy-no-snippet row WITH change_context too" \
  "$(run_validator "$ROW")" "pass"

echo ""
echo "Test 11: change_context waiver is gated — non-legacy fast-path row missing change_context still rejected"
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$GOOD_HASH\"" \
  "change_context=__DELETE__")
assert_eq "validator rejects fast-path row missing change_context" \
  "$(run_validator "$ROW")" "reject"

# Even with provenance set to some OTHER value, the waiver must not apply.
ROW=$(build_row \
  "exact_snippet=\"$GOOD_SNIPPET\"" \
  "normalized_snippet_hash=\"$GOOD_HASH\"" \
  "provenance=\"some-other-value\"" \
  "change_context=__DELETE__")
assert_eq "validator rejects fast-path row with non-legacy provenance + missing change_context" \
  "$(run_validator "$ROW")" "reject"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]] || exit 1
