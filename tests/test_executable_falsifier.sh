#!/usr/bin/env bash
# test_executable_falsifier.sh — Phase 3 tests for the optional
# executable_falsifier field.
#
# Covers:
#   Validators (validate-tier2.sh / validate-tier3.sh) — additive, non-gating:
#     1. row without the field validates (legacy behavior unchanged)
#     2. well-formed field accepted
#     3. wrong type (string / null / array) rejected
#     4. missing or empty command / expected_output_shape rejected
#     5. malformed optional root rejected; well-formed root accepted
#   Writers:
#     6. promote-commons-append.sh accepts without / accepts well-formed /
#        rejects malformed
#     7. evidence-append.sh passes the field through to task-claims.jsonl

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
VALIDATE2="$SCRIPTS_DIR/validate-tier2.sh"
VALIDATE3="$SCRIPTS_DIR/validate-tier3.sh"
APPEND="$SCRIPTS_DIR/evidence-append.sh"
COMMONS="$SCRIPTS_DIR/promote-commons-append.sh"
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

# --- Row builders -----------------------------------------------------------

GOOD_SNIPPET="hello world"
GOOD_HASH=$(printf '%s' "$GOOD_SNIPPET" | python3 "$NORMALIZE_PY" --hash)

build_tier2_row() {
  # args: key=json-value overrides; __DELETE__ removes a key
  python3 - "$GOOD_SNIPPET" "$GOOD_HASH" "$@" <<'PYEOF'
import json, sys
snippet, snippet_hash = sys.argv[1], sys.argv[2]
base = {
    "claim_id": "ef-t2-1",
    "tier": "task-evidence",
    "claim": "claim text",
    "producer_role": "worker",
    "protocol_slot": "implement-step-3",
    "task_id": "task-1",
    "phase_id": "phase-3",
    "scale": "implementation",
    "file": "/tmp/example.py",
    "line_range": "10-20",
    "exact_snippet": snippet,
    "normalized_snippet_hash": snippet_hash,
    "falsifier": "falsifier text",
    "why_this_work_needs_it": "because reasons",
    "captured_at_sha": "deadbeef",
    "change_context": {
        "diff_ref": None,
        "changed_files": ["/tmp/example.py"],
        "summary": "summary",
    },
}
for arg in sys.argv[3:]:
    k, v = arg.split("=", 1)
    if v == "__DELETE__":
        base.pop(k, None)
    else:
        base[k] = json.loads(v)
print(json.dumps(base))
PYEOF
}

build_tier3_row() {
  python3 - "$@" <<'PYEOF'
import json, sys
base = {
    "claim_id": "ef-t3-1",
    "tier": "reusable",
    "claim": "claim text",
    "producer_role": "worker",
    "protocol_slot": "implement-step-3",
    "scale": "implementation",
    "why_future_agent_cares": "because reasons",
    "falsifier": "falsifier text",
    "related_files": [],
    "source_artifact_ids": ["ef-t2-1"],
    "work_item": "wi",
    "confidence": "unaudited",
    "captured_at_sha": "deadbeef",
}
for arg in sys.argv[1:]:
    k, v = arg.split("=", 1)
    if v == "__DELETE__":
        base.pop(k, None)
    else:
        base[k] = json.loads(v)
print(json.dumps(base))
PYEOF
}

build_commons_row() {
  python3 - "$@" <<'PYEOF'
import json, sys
base = {
    "claim_id": "ef-c-1",
    "claim": "claim text",
    "falsifier": "falsifier text",
    "scale": "implementation",
    "related_files": ["scripts/example.py"],
    "work_item": "wi",
    "captured_at_sha": "deadbeef",
}
for arg in sys.argv[1:]:
    k, v = arg.split("=", 1)
    if v == "__DELETE__":
        base.pop(k, None)
    else:
        base[k] = json.loads(v)
print(json.dumps(base))
PYEOF
}

run_check() {
  # run_check <label-prefix> <script> <row> -> "pass"|"reject"
  local script="$1" row="$2"
  if printf '%s' "$row" | bash "$script" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "reject"
  fi
}

GOOD_EF='{"command": "echo hello", "expected_output_shape": "hel+o"}'

# --- 1+2. Validators: absent field unchanged; well-formed accepted ----------
echo "validate-tier2.sh:"
assert_eq "t2 absent field validates" "$(run_check "$VALIDATE2" "$(build_tier2_row)")" "pass"
assert_eq "t2 well-formed accepted" "$(run_check "$VALIDATE2" "$(build_tier2_row "executable_falsifier=$GOOD_EF")")" "pass"
assert_eq "t2 well-formed with root accepted" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier={"command": "true", "expected_output_shape": "^$", "root": "scripts"}')")" "pass"

# --- 3+4+5. Validators: malformed shapes rejected ----------------------------
assert_eq "t2 string value rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier="echo hi"')")" "reject"
assert_eq "t2 null value rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier=null')")" "reject"
assert_eq "t2 array value rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier=[]')")" "reject"
assert_eq "t2 missing command rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier={"expected_output_shape": "x"}')")" "reject"
assert_eq "t2 empty command rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier={"command": "  ", "expected_output_shape": "x"}')")" "reject"
assert_eq "t2 missing shape rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier={"command": "true"}')")" "reject"
assert_eq "t2 non-string root rejected" "$(run_check "$VALIDATE2" "$(build_tier2_row 'executable_falsifier={"command": "true", "expected_output_shape": "x", "root": 3}')")" "reject"

echo "validate-tier3.sh:"
assert_eq "t3 absent field validates" "$(run_check "$VALIDATE3" "$(build_tier3_row)")" "pass"
assert_eq "t3 well-formed accepted" "$(run_check "$VALIDATE3" "$(build_tier3_row "executable_falsifier=$GOOD_EF")")" "pass"
assert_eq "t3 string value rejected" "$(run_check "$VALIDATE3" "$(build_tier3_row 'executable_falsifier="echo hi"')")" "reject"
assert_eq "t3 empty shape rejected" "$(run_check "$VALIDATE3" "$(build_tier3_row 'executable_falsifier={"command": "true", "expected_output_shape": ""}')")" "reject"

# --- 6. promote-commons-append.sh -------------------------------------------
echo "promote-commons-append.sh:"
COMMONS_KDIR="$TEST_DIR/kdir-commons"
mkdir -p "$COMMONS_KDIR/_work/wi" "$COMMONS_KDIR/conventions"
echo "# Entry" > "$COMMONS_KDIR/conventions/entry.md"
: > "$COMMONS_KDIR/_work/wi/promoted-commons.jsonl"

run_commons() {
  local row="$1"
  if printf '%s' "$row" | bash "$COMMONS" --work-item wi --entry-path conventions/entry.md --kdir "$COMMONS_KDIR" >/dev/null 2>&1; then
    echo "pass"
  else
    echo "reject"
  fi
}

assert_eq "commons absent field accepted" "$(run_commons "$(build_commons_row)")" "pass"
assert_eq "commons well-formed accepted" "$(run_commons "$(build_commons_row "executable_falsifier=$GOOD_EF")")" "pass"
assert_eq "commons malformed rejected" "$(run_commons "$(build_commons_row 'executable_falsifier={"command": ""}')")" "reject"
PERSISTED=$(tail -1 "$COMMONS_KDIR/_work/wi/promoted-commons.jsonl" | jq -r '.executable_falsifier.command // "MISSING"')
assert_eq "commons field persisted on append" "$PERSISTED" "echo hello"

# --- 7. evidence-append.sh passthrough --------------------------------------
echo "evidence-append.sh:"
APPEND_KDIR="$TEST_DIR/kdir-append"
mkdir -p "$APPEND_KDIR/_work/wi"
if printf '%s' "$(build_tier2_row "executable_falsifier=$GOOD_EF")" \
  | bash "$APPEND" --work-item wi --kdir "$APPEND_KDIR" >/dev/null 2>&1; then
  APPENDED=$(tail -1 "$APPEND_KDIR/_work/wi/task-claims.jsonl" | jq -r '.executable_falsifier.expected_output_shape // "MISSING"')
  assert_eq "evidence-append passes field through" "$APPENDED" "hel+o"
else
  assert_eq "evidence-append accepts well-formed row" "reject" "pass"
fi
if printf '%s' "$(build_tier2_row 'executable_falsifier={"command": 42, "expected_output_shape": "x"}')" \
  | bash "$APPEND" --work-item wi --kdir "$APPEND_KDIR" >/dev/null 2>&1; then
  assert_eq "evidence-append rejects malformed field" "pass" "reject"
else
  assert_eq "evidence-append rejects malformed field" "reject" "reject"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
