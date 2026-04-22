#!/usr/bin/env bash
# test_scorecard.sh — Tests for scorecard-append.sh and scorecard-rollup.sh
# Creates a temporary knowledge store and tests the scripts against it.
#
# Covers:
#   - Round-trip a `kind: scored` row through append → rows.jsonl
#   - Round-trip a `kind: telemetry` row
#   - Rejection of invalid kind / missing schema_version / invalid calibration_state
#   - Rollup on empty rows.jsonl → valid empty _current.json
#   - Rollup on one valid row → correct single summary
#   - Rollup on many rows → correct aggregation per (template_id, template_version, metric)
#   - Rollup warns (non-fatal) when it encounters corrupt rows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Should NOT contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_file_exists() {
  local label="$1" filepath="$2"
  if [[ -f "$filepath" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file does not exist: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

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

assert_exit() {
  local label="$1" expected_exit="$2"; shift 2
  local actual_exit=0
  "$@" >/dev/null 2>&1 || actual_exit=$?
  if [[ "$actual_exit" == "$expected_exit" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected exit $expected_exit, got $actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
}

echo "=== Scorecard Tests ==="
echo ""

# =============================================
# Test 1: Round-trip a `kind: scored` row
# =============================================
echo "Test 1: Round-trip scored row"
setup_store

ROW='{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"worker","template_version":"abc123","metric":"accuracy","value":0.8,"sample_size":10}'
OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$ROW" 2>&1)
assert_contains "append confirmation printed" "$OUTPUT" "[scorecard] Appended row"
assert_contains "kind reported in confirmation" "$OUTPUT" "kind=scored"
assert_contains "calibration_state reported" "$OUTPUT" "calibration_state=calibrated"
assert_file_exists "rows.jsonl created" "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"
assert_file_exists "README.md seeded on first use" "$KNOWLEDGE_DIR/_scorecards/README.md"

# Read back the row via jq and verify every field round-tripped.
ROW_BACK=$(cat "$KNOWLEDGE_DIR/_scorecards/rows.jsonl")
assert_eq "template_id round-tripped" "$(echo "$ROW_BACK" | jq -r '.template_id')" "worker"
assert_eq "template_version round-tripped" "$(echo "$ROW_BACK" | jq -r '.template_version')" "abc123"
assert_eq "metric round-tripped" "$(echo "$ROW_BACK" | jq -r '.metric')" "accuracy"
assert_eq "value round-tripped" "$(echo "$ROW_BACK" | jq -r '.value')" "0.8"
assert_eq "sample_size round-tripped" "$(echo "$ROW_BACK" | jq -r '.sample_size')" "10"
assert_eq "kind round-tripped" "$(echo "$ROW_BACK" | jq -r '.kind')" "scored"

# =============================================
# Test 2: Round-trip a `kind: telemetry` row
# =============================================
echo ""
echo "Test 2: Round-trip telemetry row"
setup_store

ROW='{"schema_version":"1","kind":"telemetry","calibration_state":"pre-calibration","template_id":"researcher","template_version":"xyz789","metric":"coverage","value":0.95}'
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$ROW" > /dev/null 2>&1
ROW_BACK=$(cat "$KNOWLEDGE_DIR/_scorecards/rows.jsonl")
assert_eq "kind telemetry round-tripped" "$(echo "$ROW_BACK" | jq -r '.kind')" "telemetry"
assert_eq "calibration_state pre-calibration round-tripped" "$(echo "$ROW_BACK" | jq -r '.calibration_state')" "pre-calibration"
assert_eq "template_id round-tripped" "$(echo "$ROW_BACK" | jq -r '.template_id')" "researcher"

# =============================================
# Test 3: Append reads from stdin when --row omitted
# =============================================
echo ""
echo "Test 3: Append reads row from stdin"
setup_store

ROW='{"schema_version":"1","kind":"scored","calibration_state":"unknown","template_id":"lead","template_version":"deadbeef","metric":"precision"}'
OUTPUT=$(echo "$ROW" | bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" 2>&1)
assert_contains "stdin append succeeded" "$OUTPUT" "[scorecard] Appended row"
assert_file_exists "rows.jsonl created via stdin" "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

# =============================================
# Test 4: Reject invalid kind
# =============================================
echo ""
echo "Test 4: Reject invalid kind"
setup_store

EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"bogus","calibration_state":"calibrated"}' 2>&1) || EXIT_CODE=$?
assert_eq "invalid kind exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr names 'invalid kind'" "$STDERR" "invalid kind"

# File must not exist (first-use rejection leaves no partial state)
if [[ ! -f "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: rows.jsonl not created on rejection"
  PASS=$((PASS + 1))
else
  echo "  FAIL: rows.jsonl was created despite rejection"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 5: Reject missing schema_version
# =============================================
echo ""
echo "Test 5: Reject missing schema_version"
setup_store

EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"kind":"scored","calibration_state":"calibrated"}' 2>&1) || EXIT_CODE=$?
assert_eq "missing schema_version exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr names schema_version" "$STDERR" "schema_version"

# =============================================
# Test 6: Reject invalid calibration_state
# =============================================
echo ""
echo "Test 6: Reject invalid calibration_state"
setup_store

EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"maybe-probably"}' 2>&1) || EXIT_CODE=$?
assert_eq "invalid calibration_state exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr names calibration_state" "$STDERR" "calibration_state"

# =============================================
# Test 7: Reject non-object JSON
# =============================================
echo ""
echo "Test 7: Reject non-object JSON"
setup_store

EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '"just a string"' 2>&1) || EXIT_CODE=$?
assert_eq "non-object exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr says 'object'" "$STDERR" "JSON object"

# =============================================
# Test 8: Rollup on empty rows.jsonl
# =============================================
echo ""
echo "Test 8: Rollup on empty rows.jsonl"
setup_store
mkdir -p "$KNOWLEDGE_DIR/_scorecards"
: > "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

OUTPUT=$(bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" 2>&1)
assert_contains "rollup reports 0 rows" "$OUTPUT" "Rolled up 0 rows"
assert_file_exists "_current.json created" "$KNOWLEDGE_DIR/_scorecards/_current.json"
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
assert_eq "row_count is 0" "$(echo "$CURRENT" | jq -r '.row_count')" "0"
assert_eq "corrupt_row_count is 0" "$(echo "$CURRENT" | jq -r '.corrupt_row_count')" "0"
assert_eq "summaries is empty array" "$(echo "$CURRENT" | jq -r '.summaries | length')" "0"

# =============================================
# Test 9: Rollup on missing rows.jsonl
# =============================================
echo ""
echo "Test 9: Rollup on missing rows.jsonl"
setup_store

OUTPUT=$(bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" 2>&1)
assert_contains "rollup reports 0 rows" "$OUTPUT" "Rolled up 0 rows"
assert_file_exists "_current.json created" "$KNOWLEDGE_DIR/_scorecards/_current.json"

# =============================================
# Test 10: Rollup on one valid row
# =============================================
echo ""
echo "Test 10: Rollup on one row"
setup_store

bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"accuracy","value":0.75,"sample_size":4}' > /dev/null

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
assert_eq "row_count is 1" "$(echo "$CURRENT" | jq -r '.row_count')" "1"
assert_eq "summary count is 1" "$(echo "$CURRENT" | jq -r '.summaries | length')" "1"
assert_eq "summary template_version" "$(echo "$CURRENT" | jq -r '.summaries[0].template_version')" "v1"
assert_eq "summary metric" "$(echo "$CURRENT" | jq -r '.summaries[0].metric')" "accuracy"
assert_eq "summary sample_count is 1" "$(echo "$CURRENT" | jq -r '.summaries[0].sample_count')" "1"
assert_eq "summary sample_size_total is 4" "$(echo "$CURRENT" | jq -r '.summaries[0].sample_size_total')" "4"
assert_eq "summary value_mean is 0.75" "$(echo "$CURRENT" | jq -r '.summaries[0].value_mean')" "0.75"
assert_eq "summary kind is scored" "$(echo "$CURRENT" | jq -r '.summaries[0].kind')" "scored"

# =============================================
# Test 11: Rollup on many rows — grouping by (template_id, template_version, metric)
# =============================================
echo ""
echo "Test 11: Rollup on many rows — correct per-group aggregation"
setup_store

# Group A: (w, v1, accuracy) — 3 rows, values 0.5, 0.7, 0.9
for v in 0.5 0.7 0.9; do
  bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
    --row "{\"schema_version\":\"1\",\"kind\":\"scored\",\"calibration_state\":\"calibrated\",\"template_id\":\"w\",\"template_version\":\"v1\",\"metric\":\"accuracy\",\"value\":$v,\"sample_size\":2}" > /dev/null
done
# Group B: (w, v1, precision) — 1 row
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","template_id":"w","template_version":"v1","metric":"precision","value":0.6,"sample_size":10}' > /dev/null
# Group C: (r, v2, accuracy) — 1 row
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"r","template_version":"v2","metric":"accuracy","value":0.4,"sample_size":3}' > /dev/null

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
assert_eq "row_count is 5" "$(echo "$CURRENT" | jq -r '.row_count')" "5"
assert_eq "summary count is 3" "$(echo "$CURRENT" | jq -r '.summaries | length')" "3"

# Find the (w, v1, accuracy) group — should aggregate 3 rows: mean=0.7, sum=2.1, sample_size_total=6
GROUP_A=$(echo "$CURRENT" | jq '.summaries[] | select(.template_id=="w" and .template_version=="v1" and .metric=="accuracy")')
assert_eq "group A sample_count" "$(echo "$GROUP_A" | jq -r '.sample_count')" "3"
assert_eq "group A sample_size_total" "$(echo "$GROUP_A" | jq -r '.sample_size_total')" "6"
# Use a tolerance check — IEEE 754 float sums can drift by ULP
# (0.5 + 0.7 + 0.9) / 3 = 0.7000000000000001 under jq's double precision.
MEAN_A=$(echo "$GROUP_A" | jq -r '.value_mean')
MEAN_OK=$(jq -rn --argjson m "$MEAN_A" 'if (($m - 0.7) | fabs) < 0.0001 then "yes" else "no" end')
assert_eq "group A value_mean ≈ 0.7" "$MEAN_OK" "yes"
assert_eq "group A value_min" "$(echo "$GROUP_A" | jq -r '.value_min')" "0.5"
assert_eq "group A value_max" "$(echo "$GROUP_A" | jq -r '.value_max')" "0.9"
assert_eq "group A kind is scored (unanimous)" "$(echo "$GROUP_A" | jq -r '.kind')" "scored"

# (w, v1, precision) is a different group
GROUP_B=$(echo "$CURRENT" | jq '.summaries[] | select(.template_id=="w" and .metric=="precision")')
assert_eq "group B sample_count" "$(echo "$GROUP_B" | jq -r '.sample_count')" "1"
assert_eq "group B kind is telemetry" "$(echo "$GROUP_B" | jq -r '.kind')" "telemetry"

# (r, v2, accuracy) is a third group (different template_id)
GROUP_C=$(echo "$CURRENT" | jq '.summaries[] | select(.template_id=="r")')
assert_eq "group C template_version" "$(echo "$GROUP_C" | jq -r '.template_version')" "v2"
assert_eq "group C sample_count" "$(echo "$GROUP_C" | jq -r '.sample_count')" "1"

# =============================================
# Test 12: Mixed-kind grouping emits "mixed" label
# =============================================
echo ""
echo "Test 12: Mixed-kind group labelled 'mixed'"
setup_store

bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"m","value":1.0}' > /dev/null
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","template_id":"w","template_version":"v1","metric":"m","value":2.0}' > /dev/null

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
GROUP=$(echo "$CURRENT" | jq '.summaries[0]')
assert_eq "mixed kind labelled" "$(echo "$GROUP" | jq -r '.kind')" "mixed"
assert_eq "calibration_states unique count" "$(echo "$GROUP" | jq -r '.calibration_states | length')" "2"

# =============================================
# Test 13: Rollup warns on corrupt rows (parse fail, missing kind, missing schema_version)
# =============================================
echo ""
echo "Test 13: Rollup warns on corrupt rows and excludes them"
setup_store
mkdir -p "$KNOWLEDGE_DIR/_scorecards"
cat > "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" << 'EOF'
{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"w","metric":"m","value":1.0}
{"schema_version":"1","kind":"bogus","calibration_state":"calibrated"}
not valid json at all
{"kind":"scored","calibration_state":"calibrated"}
{"schema_version":"1","kind":"scored","calibration_state":"bogus"}
{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","template_id":"w","metric":"m","value":2.0}
EOF

OUTPUT=$(bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" 2>&1)

# 6 total rows, 4 corrupt (lines 2, 3, 4, 5), 2 valid (lines 1 and 6).
assert_contains "warn line 2 (invalid kind)" "$OUTPUT" "rows.jsonl:2 corrupt"
assert_contains "warn line 3 (unparseable)" "$OUTPUT" "rows.jsonl:3 corrupt"
assert_contains "warn line 4 (missing schema_version)" "$OUTPUT" "rows.jsonl:4 corrupt"
assert_contains "warn line 5 (bad calibration_state)" "$OUTPUT" "rows.jsonl:5 corrupt"
assert_contains "warn reason mentions unparseable" "$OUTPUT" "unparseable JSON"
assert_contains "warn reason names schema_version" "$OUTPUT" "schema_version"

# rollup still succeeds (non-fatal warning)
assert_contains "rollup completion message present" "$OUTPUT" "Rolled up 6 rows"
assert_contains "corrupt count is 4" "$OUTPUT" "(4 corrupt)"

# _current.json excludes corrupt rows from aggregation: 2 valid rows both (w, null, m) → 1 summary, sample_count=2
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
assert_eq "row_count is 6" "$(echo "$CURRENT" | jq -r '.row_count')" "6"
assert_eq "corrupt_row_count is 4" "$(echo "$CURRENT" | jq -r '.corrupt_row_count')" "4"
assert_eq "summary count is 1 (corrupt excluded)" "$(echo "$CURRENT" | jq -r '.summaries | length')" "1"
assert_eq "valid sample_count is 2" "$(echo "$CURRENT" | jq -r '.summaries[0].sample_count')" "2"

# =============================================
# Test 14: Clean rollup is silent (no stderr warnings)
# =============================================
echo ""
echo "Test 14: Rollup is silent on clean input"
setup_store
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"m","value":0.5}' > /dev/null

STDERR=$(bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" 2>&1 >/dev/null)
assert_not_contains "no warning emitted on clean input" "$STDERR" "warning"
assert_not_contains "no corrupt-line citation" "$STDERR" "corrupt"

# =============================================
# Test 15: --json mode round-trips structured output
# =============================================
echo ""
echo "Test 15: --json mode"
setup_store

JSON_OUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --json \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated"}')
assert_eq "append json.appended" "$(echo "$JSON_OUT" | jq -r '.appended')" "true"
assert_eq "append json.kind" "$(echo "$JSON_OUT" | jq -r '.kind')" "scored"

JSON_OUT=$(bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" --json)
assert_eq "rollup json.row_count" "$(echo "$JSON_OUT" | jq -r '.row_count')" "1"
assert_eq "rollup json.summary_count" "$(echo "$JSON_OUT" | jq -r '.summary_count')" "1"

# --json error mode
EXIT_CODE=0
JSON_ERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --json \
  --row '{"kind":"scored","calibration_state":"calibrated"}' 2>/dev/null) || EXIT_CODE=$?
assert_eq "json error exits non-zero" "$EXIT_CODE" "1"
assert_contains "json error payload has .error" "$JSON_ERR" '"error"'

# =============================================
# Test 16: Sole-writer invariant is documented in seeded README
# =============================================
echo ""
echo "Test 16: README documents sole-writer invariant"
setup_store

bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated"}' > /dev/null

README="$KNOWLEDGE_DIR/_scorecards/README.md"
assert_file_exists "README seeded" "$README"
if grep -qF "Sole-writer invariant" "$README"; then
  echo "  PASS: README documents 'Sole-writer invariant'"
  PASS=$((PASS + 1))
else
  echo "  FAIL: README missing 'Sole-writer invariant' section"
  FAIL=$((FAIL + 1))
fi
if grep -qF "Prompt-context invariant" "$README"; then
  echo "  PASS: README documents prompt-context invariant"
  PASS=$((PASS + 1))
else
  echo "  FAIL: README missing 'Prompt-context invariant' section"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
