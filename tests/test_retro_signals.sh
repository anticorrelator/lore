#!/usr/bin/env bash
# test_retro_signals.sh — Tests for Phase 5 /retro signal redesign.
# Covers: counterfactual_better flag + enum, schema_version transition (v1→v2),
# six signal names referenced in append script spec, and observational-only invariant.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPEND_SH="$REPO_ROOT/scripts/retro-scale-access-append.sh"

PASS=0
FAIL=0

assert_exit_zero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_nonzero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero, got 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (not found: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label (unexpected: $needle)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_json_field() {
  local label="$1" json="$2" field="$3" expected="$4"
  actual=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2],'MISSING'))" "$json" "$field" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

KDIR=$(mktemp -d)
cleanup() { rm -rf "$KDIR"; }
trap cleanup EXIT

echo "=== test_retro_signals.sh ==="
echo ""

# --- Test 1: append script exists ---
echo "Test 1: retro-scale-access-append.sh exists"
if [[ -f "$APPEND_SH" ]]; then
  echo "  PASS: append script exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: append script not found at $APPEND_SH"
  FAIL=$((FAIL + 1))
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

APPEND_CONTENT=$(cat "$APPEND_SH")

# --- Test 2: --recall-grade is gone (renamed to --counterfactual-better) ---
echo ""
echo "Test 2: --recall-grade is renamed to --counterfactual-better"
assert_not_contains "no --recall-grade flag" "$APPEND_CONTENT" "--recall-grade)"
assert_not_contains "no RECALL_GRADE variable" "$APPEND_CONTENT" "RECALL_GRADE="
assert_not_contains "no recall_grade JSON key" "$APPEND_CONTENT" '"recall_grade"'
assert_contains "--counterfactual-better flag present" "$APPEND_CONTENT" "--counterfactual-better)"
assert_contains "COUNTERFACTUAL_BETTER variable present" "$APPEND_CONTENT" "COUNTERFACTUAL_BETTER="
assert_contains "counterfactual_better JSON key present" "$APPEND_CONTENT" '"counterfactual_better"'

# --- Test 3: schema_version is 2 ---
echo ""
echo "Test 3: schema_version is 2"
assert_contains "schema_version 2 in script" "$APPEND_CONTENT" '"schema_version": "2"'
assert_not_contains "schema_version 1 removed" "$APPEND_CONTENT" '"schema_version": "1"'

# --- Test 4: enum is {better, same, worse} ---
echo ""
echo "Test 4: counterfactual_better enum is {better, same, worse}"
assert_contains "better in enum" "$APPEND_CONTENT" "better|same|worse"
assert_not_contains "old useful enum removed" "$APPEND_CONTENT" "useful|neutral|not-useful"

# --- Test 5: --counterfactual-better better succeeds ---
echo ""
echo "Test 5: --counterfactual-better better exits 0"
bash "$APPEND_SH" \
  --cycle-id test-cycle \
  --abstraction-grade right-sized \
  --abstraction-rationale "test rationale" \
  --counterfactual-better better \
  --counterfactual-rationale "declared scale improved retrieval quality" \
  --kdir "$KDIR" > /dev/null 2>&1
assert_exit_zero "--counterfactual-better better exits 0" "$?"

# --- Test 6: --counterfactual-better same succeeds ---
echo ""
echo "Test 6: --counterfactual-better same exits 0"
bash "$APPEND_SH" \
  --cycle-id test-cycle-2 \
  --abstraction-grade right-sized \
  --abstraction-rationale "test rationale" \
  --counterfactual-better same \
  --counterfactual-rationale "declared scale made no difference" \
  --kdir "$KDIR" > /dev/null 2>&1
assert_exit_zero "--counterfactual-better same exits 0" "$?"

# --- Test 7: --counterfactual-better worse succeeds ---
echo ""
echo "Test 7: --counterfactual-better worse exits 0"
bash "$APPEND_SH" \
  --cycle-id test-cycle-3 \
  --abstraction-grade too-coarse \
  --abstraction-rationale "test rationale" \
  --counterfactual-better worse \
  --counterfactual-rationale "declared scale degraded retrieval" \
  --kdir "$KDIR" > /dev/null 2>&1
assert_exit_zero "--counterfactual-better worse exits 0" "$?"

# --- Test 8: --counterfactual-better foo fails ---
echo ""
echo "Test 8: --counterfactual-better foo exits non-zero with enum error"
ERR_OUT=$(bash "$APPEND_SH" \
  --cycle-id test-cycle-err \
  --abstraction-grade right-sized \
  --abstraction-rationale "test" \
  --counterfactual-better foo \
  --counterfactual-rationale "test" \
  --kdir "$KDIR" 2>&1)
assert_exit_nonzero "--counterfactual-better foo exits non-zero" "$?"
assert_contains "enum error mentions better/same/worse" "$ERR_OUT" "better"

# --- Test 9: written rows carry schema_version 2 ---
echo ""
echo "Test 9: written rows carry schema_version: 2"
SIDECAR="$KDIR/_scorecards/retro-scale-access.jsonl"
if [[ -f "$SIDECAR" ]]; then
  FIRST_ROW=$(head -1 "$SIDECAR")
  assert_json_field "schema_version is 2" "$FIRST_ROW" "schema_version" "2"
  assert_json_field "counterfactual_better field in row" "$FIRST_ROW" "counterfactual_better" "better"
else
  echo "  FAIL: sidecar not written at $SIDECAR"
  FAIL=$((FAIL + 1))
fi

# --- Test 10: all six signal names documented in append script header ---
echo ""
echo "Test 10: all six signal names documented in append script header"
assert_contains "counterfactual_better signal" "$APPEND_CONTENT" "counterfactual_better"
assert_contains "off_altitude_skipped signal" "$APPEND_CONTENT" "off_altitude_skipped"
assert_contains "declaration_coverage signal" "$APPEND_CONTENT" "declaration_coverage"
assert_contains "redeclare_rate signal" "$APPEND_CONTENT" "redeclare_rate"
assert_contains "off_scale_routes_emitted signal" "$APPEND_CONTENT" "off_scale_routes_emitted"
assert_contains "verifier_disagreements signal" "$APPEND_CONTENT" "verifier_disagreements"

# --- Test 11: compute_scale_signals via retro-aggregate-compute.py ---
COMPUTE_PY="$REPO_ROOT/scripts/retro-aggregate-compute.py"
echo ""
echo "Test 11: retro-aggregate-compute.py emits scale_signals block"

# Build synthetic kdir
TMPKDIR=$(mktemp -d)
cleanup_compute() { rm -rf "$TMPKDIR"; }
trap 'cleanup_compute; rm -rf "$KDIR"' EXIT

mkdir -p "$TMPKDIR/_meta" "$TMPKDIR/_work/test-cycle-11"

cat > "$TMPKDIR/_meta/retrieval-log.jsonl" << 'RETRIEVAL_EOF'
{"event": "search", "session_id": "s1", "scale_set": "subsystem", "scale_declared": true}
{"event": "search", "session_id": "s1", "scale_set": "implementation", "scale_declared": true}
{"event": "search", "session_id": "s2", "scale_set": "subsystem", "scale_declared": true}
{"event": "search", "session_id": "s2", "scale_declared": null}
RETRIEVAL_EOF

printf '{"concern": "one"}\n{"concern": "two"}\n' > "$TMPKDIR/_work/test-cycle-11/off_scale_routes.jsonl"
printf '{"disagreements": ["a.md", "b.md"]}\n' > "$TMPKDIR/_meta/classification-report.json"

COMPUTE_OUT=$(python3 "$COMPUTE_PY" /tmp/nonexistent-pool --kdir "$TMPKDIR" --cycle-id "test-cycle-11" 2>/dev/null)

DECL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); s=d.get('scale_signals',{}); print(s.get('declaration_coverage',{}).get('declared','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
TOTAL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); s=d.get('scale_signals',{}); print(s.get('declaration_coverage',{}).get('total','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
ROUTES=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); s=d.get('scale_signals',{}); print(s.get('off_scale_routes_emitted',{}).get('count','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
DISAGREE=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); s=d.get('scale_signals',{}); print(s.get('verifier_disagreements',{}).get('count','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)
REDECL=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); s=d.get('scale_signals',{}); print(s.get('redeclare_rate',{}).get('redeclares','MISSING'))" "$COMPUTE_OUT" 2>/dev/null)

if [[ "$DECL" == "3" ]]; then echo "  PASS: declaration_coverage declared=3"; PASS=$((PASS+1)); else echo "  FAIL: declaration_coverage declared expected 3, got $DECL"; FAIL=$((FAIL+1)); fi
if [[ "$TOTAL" == "4" ]]; then echo "  PASS: declaration_coverage total=4"; PASS=$((PASS+1)); else echo "  FAIL: declaration_coverage total expected 4, got $TOTAL"; FAIL=$((FAIL+1)); fi
if [[ "$ROUTES" == "2" ]]; then echo "  PASS: off_scale_routes_emitted=2"; PASS=$((PASS+1)); else echo "  FAIL: off_scale_routes_emitted expected 2, got $ROUTES"; FAIL=$((FAIL+1)); fi
if [[ "$DISAGREE" == "2" ]]; then echo "  PASS: verifier_disagreements=2"; PASS=$((PASS+1)); else echo "  FAIL: verifier_disagreements expected 2, got $DISAGREE"; FAIL=$((FAIL+1)); fi
if [[ "$REDECL" == "1" ]]; then echo "  PASS: redeclare_rate redeclares=1"; PASS=$((PASS+1)); else echo "  FAIL: redeclare_rate redeclares expected 1, got $REDECL"; FAIL=$((FAIL+1)); fi

# --- Test 12: scale_signals absent when --kdir not provided ---
echo ""
echo "Test 12: scale_signals absent when --kdir omitted"
OUT_NO_KDIR=$(python3 "$COMPUTE_PY" /tmp/nonexistent-pool 2>/dev/null)
HAS_SIGNALS=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('yes' if 'scale_signals' in d else 'no')" "$OUT_NO_KDIR" 2>/dev/null)
if [[ "$HAS_SIGNALS" == "no" ]]; then echo "  PASS: scale_signals absent without --kdir"; PASS=$((PASS+1)); else echo "  FAIL: scale_signals present unexpectedly"; FAIL=$((FAIL+1)); fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
