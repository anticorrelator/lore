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

ROW='{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"worker","template_version":"abc123","metric":"accuracy","value":0.8,"sample_size":10}'
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

ROW='{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"pre-calibration","template_id":"researcher","template_version":"xyz789","metric":"coverage","value":0.95}'
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

ROW='{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"unknown","template_id":"lead","template_version":"deadbeef","metric":"precision"}'
OUTPUT=$(echo "$ROW" | bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" 2>&1)
assert_contains "stdin append succeeded" "$OUTPUT" "[scorecard] Appended row"
assert_file_exists "rows.jsonl created via stdin" "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

# =============================================
# Test 4: Reject invalid kind (error message lists all three valid kinds — D4)
# =============================================
echo ""
echo "Test 4: Reject invalid kind"
setup_store

EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"bogus","calibration_state":"calibrated"}' 2>&1) || EXIT_CODE=$?
assert_eq "invalid kind exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr names 'invalid kind'" "$STDERR" "invalid kind"
# The error message enumerates every appendable kind — the enum is public contract.
assert_contains "stderr lists 'scored'" "$STDERR" "scored"
assert_contains "stderr lists 'telemetry'" "$STDERR" "telemetry"

# File must not exist (first-use rejection leaves no partial state)
if [[ ! -f "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: rows.jsonl not created on rejection"
  PASS=$((PASS + 1))
else
  echo "  FAIL: rows.jsonl was created despite rejection"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 4a: `consumption-contradiction` is no longer an appendable kind
# =============================================
# The channel that produced these rows is gone. The writer refuses new ones;
# the rollup still reads the rows already on disk (Test 12a).
echo ""
echo "Test 4a: consumption-contradiction is refused at append"
setup_store

ROW='{"schema_version":"1","kind":"consumption-contradiction","tier":"telemetry","calibration_state":"pre-calibration","template_id":"consumer-channel","template_version":"ccc111222333","metric":"remediation_rate","value":0.42,"sample_size":7}'
EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$ROW" 2>&1) || EXIT_CODE=$?
assert_eq "retired kind exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr names 'invalid kind'" "$STDERR" "invalid kind"
if [[ ! -f "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: rows.jsonl not created on rejection"
  PASS=$((PASS + 1))
else
  echo "  FAIL: rows.jsonl was created despite rejection"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 4b: ceremony-resolution conditional schema is writer-enforced
# =============================================
echo ""
echo "Test 4b: Reject malformed ceremony-resolution telemetry"
setup_store

BASE_CEREMONY_ROW='{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","event_type":"ceremony-resolution","metric":"ceremony_resolution_outcome","outcome":"needs-decision","disposition":"unhandled","ceremony":"spec-post-plan","advisor":"codex-plan-review","harness":"opencode","reason":"advisor missing","corrective_action":"update binding","timestamp":"2026-07-09T12:00:00Z","source_artifact_ids":[]}'
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BASE_CEREMONY_ROW" >/dev/null
assert_eq "valid ceremony-resolution row appended" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "1"

for mutation in \
  '.kind = "scored"' \
  '.outcome = "failed"' \
  '.disposition = "handled"' \
  '.advisor = ""' \
  '.work_item = "item"'; do
  BAD_ROW=$(jq -c "$mutation" <<<"$BASE_CEREMONY_ROW")
  EXIT_CODE=0
  STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BAD_ROW" 2>&1) || EXIT_CODE=$?
  assert_eq "ceremony mutation rejected: $mutation" "$EXIT_CODE" "1"
  assert_contains "ceremony rejection names schema" "$STDERR" "ceremony-resolution row rejected"
done
assert_eq "rejected ceremony rows did not append" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "1"

# =============================================
# Test 4c: correlated ceremony handled transition
# =============================================
echo ""
echo "Test 4c: Ceremony handled transitions are correlated, idempotent, and conflict-refusing"
setup_store

CEREMONY_OUTCOME_ID="ceremony-fixture-1"
OUTCOME_ROW=$(jq -c --arg id "$CEREMONY_OUTCOME_ID" '. + {outcome_id: $id}' <<<"$BASE_CEREMONY_ROW")
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$OUTCOME_ROW" >/dev/null
BASE_TRANSITION_ROW=$(jq -cn --arg id "$CEREMONY_OUTCOME_ID" '{
  schema_version:"1", kind:"telemetry", tier:"telemetry", calibration_state:"unknown",
  event_type:"ceremony-resolution", metric:"ceremony_resolution_outcome",
  record_type:"disposition", outcome:"needs-decision", disposition:"handled",
  outcome_id:$id, ceremony:"spec-post-plan", advisor:"codex-plan-review",
  action:"adjudicated", handled_by:"coordinate",
  handled_at:"2026-07-09T13:00:00Z", timestamp:"2026-07-09T13:00:00Z",
  source_artifact_ids:[]
}')

bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BASE_TRANSITION_ROW" >/dev/null
assert_eq "valid transition appended" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "2"
TRANSITION_BACK=$(tail -n 1 "$KNOWLEDGE_DIR/_scorecards/rows.jsonl")
assert_eq "transition record type round-tripped" "$(jq -r '.record_type' <<<"$TRANSITION_BACK")" "disposition"
assert_eq "transition action round-tripped" "$(jq -r '.action' <<<"$TRANSITION_BACK")" "adjudicated"
assert_eq "transition actor round-tripped" "$(jq -r '.handled_by' <<<"$TRANSITION_BACK")" "coordinate"

# An identical retry is the same claim, not a second one.
IDEMPOTENT_OUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BASE_TRANSITION_ROW" --json)
assert_eq "identical retry appends nothing" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "2"
assert_eq "identical retry reports idempotence" "$(jq -r '.idempotent' <<<"$IDEMPOTENT_OUT")" "true"
assert_eq "identical retry reports no append" "$(jq -r '.appended' <<<"$IDEMPOTENT_OUT")" "false"

# A different answer to the same obligation is a conflict, never a second layer.
for conflict in '.action = "skipped"' '.handled_by = "someone-else"'; do
  CONFLICT_ROW=$(jq -c "$conflict" <<<"$BASE_TRANSITION_ROW")
  EXIT_CODE=0
  STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$CONFLICT_ROW" 2>&1) || EXIT_CODE=$?
  assert_eq "conflicting transition refused: $conflict" "$EXIT_CODE" "1"
  assert_contains "conflict names the existing transition" "$STDERR" "already carries a different handled transition"
done
assert_eq "refused conflicts did not append" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "2"

# A transition that names no outcome, or contradicts the one it names, is refused.
UNCORRELATED_ROW=$(jq -c '.outcome_id = "ceremony-does-not-exist"' <<<"$BASE_TRANSITION_ROW")
EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$UNCORRELATED_ROW" 2>&1) || EXIT_CODE=$?
assert_eq "transition naming no outcome refused" "$EXIT_CODE" "1"
assert_contains "uncorrelated transition names the missing outcome" "$STDERR" "no ceremony-resolution outcome row carries outcome_id"

CONTRADICTING_ROW=$(jq -c '.advisor = "some-other-advisor"' <<<"$BASE_TRANSITION_ROW")
EXIT_CODE=0
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$CONTRADICTING_ROW" 2>&1) || EXIT_CODE=$?
assert_eq "transition contradicting its outcome refused" "$EXIT_CODE" "1"
assert_contains "contradiction names the disagreeing field" "$STDERR" "contradicts the correlated outcome row"

# Structural validation runs before any correlation lookup.
for mutation in \
  '.action = "adjudicate"' \
  '.disposition = "unhandled"' \
  '.outcome_id = ""' \
  'del(.handled_by)' \
  'del(.handled_at)' \
  '.reason = "restated evidence"' \
  '.harness = "codex"'; do
  BAD_ROW=$(jq -c "$mutation" <<<"$BASE_TRANSITION_ROW")
  EXIT_CODE=0
  STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BAD_ROW" 2>&1) || EXIT_CODE=$?
  assert_eq "malformed transition rejected: $mutation" "$EXIT_CODE" "1"
done
assert_eq "malformed transitions did not append" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "2"

EXIT_CODE=0
BAD_RECORD_TYPE=$(jq -c '.record_type = "adjudication"' <<<"$BASE_TRANSITION_ROW")
STDERR=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BAD_RECORD_TYPE" 2>&1) || EXIT_CODE=$?
assert_eq "unknown ceremony record_type rejected" "$EXIT_CODE" "1"
assert_contains "unknown record_type names the enum" "$STDERR" "record_type must be 'outcome' or 'disposition'"

# Rows written before the transition shape existed carry no record_type and
# must keep validating as outcome rows.
setup_store
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --row "$BASE_CEREMONY_ROW" >/dev/null
assert_eq "record_type-less ceremony row still appends" "$(wc -l < "$KNOWLEDGE_DIR/_scorecards/rows.jsonl" | tr -d ' ')" "1"
assert_eq "record_type stays absent rather than defaulted onto the row" \
  "$(jq -r 'has("record_type")' "$KNOWLEDGE_DIR/_scorecards/rows.jsonl")" "false"

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
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"accuracy","value":0.75,"sample_size":4}' > /dev/null

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
    --row "{\"schema_version\":\"1\",\"kind\":\"scored\",\"tier\":\"telemetry\",\"calibration_state\":\"calibrated\",\"template_id\":\"w\",\"template_version\":\"v1\",\"metric\":\"accuracy\",\"value\":$v,\"sample_size\":2}" > /dev/null
done
# Group B: (w, v1, precision) — 1 row
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","template_id":"w","template_version":"v1","metric":"precision","value":0.6,"sample_size":10}' > /dev/null
# Group C: (r, v2, accuracy) — 1 row
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"r","template_version":"v2","metric":"accuracy","value":0.4,"sample_size":3}' > /dev/null

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
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"m","value":1.0}' > /dev/null
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","template_id":"w","template_version":"v1","metric":"m","value":2.0}' > /dev/null

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
GROUP=$(echo "$CURRENT" | jq '.summaries[0]')
assert_eq "mixed kind labelled" "$(echo "$GROUP" | jq -r '.kind')" "mixed"
assert_eq "calibration_states unique count" "$(echo "$GROUP" | jq -r '.calibration_states | length')" "2"

# =============================================
# Test 12a: recorded consumption-contradiction rows still roll up
# =============================================
echo ""
echo "Test 12a: recorded consumption-contradiction rows still roll up"
setup_store

# The kind is no longer appendable, so these rows are seeded directly — the
# shape a store carries from before the channel was retired. Two rows sharing
# (template_id, template_version, metric) must aggregate into ONE summary
# labelled with their kind, not be dropped as corrupt.
mkdir -p "$KNOWLEDGE_DIR/_scorecards"
for v in 0.4 0.8; do
  printf '%s\n' "{\"schema_version\":\"1\",\"kind\":\"consumption-contradiction\",\"calibration_state\":\"pre-calibration\",\"tier\":\"telemetry\",\"template_id\":\"cc\",\"template_version\":\"v1\",\"metric\":\"remediation_rate\",\"value\":$v,\"sample_size\":5}" \
    >> "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"
done

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
assert_eq "cc rollup row_count is 2" "$(echo "$CURRENT" | jq -r '.row_count')" "2"
assert_eq "cc rollup corrupt_row_count is 0" "$(echo "$CURRENT" | jq -r '.corrupt_row_count')" "0"
assert_eq "cc rollup summary count is 1" "$(echo "$CURRENT" | jq -r '.summaries | length')" "1"
CC_GROUP=$(echo "$CURRENT" | jq '.summaries[0]')
assert_eq "cc group kind label" "$(echo "$CC_GROUP" | jq -r '.kind')" "consumption-contradiction"
assert_eq "cc group sample_count" "$(echo "$CC_GROUP" | jq -r '.sample_count')" "2"
assert_eq "cc group sample_size_total" "$(echo "$CC_GROUP" | jq -r '.sample_size_total')" "10"
MEAN_CC=$(echo "$CC_GROUP" | jq -r '.value_mean')
MEAN_CC_OK=$(jq -rn --argjson m "$MEAN_CC" 'if (($m - 0.6) | fabs) < 0.0001 then "yes" else "no" end')
assert_eq "cc group value_mean ≈ 0.6" "$MEAN_CC_OK" "yes"
assert_eq "cc group calibration_states = [pre-calibration]" "$(echo "$CC_GROUP" | jq -rc '.calibration_states')" '["pre-calibration"]'

# =============================================
# Test 12b: a mixed group spanning a recorded and an appendable kind
# =============================================
echo ""
echo "Test 12b: mixed group including a recorded consumption-contradiction row"
setup_store

# Same grouping key, two different kinds. The rollup must still emit
# kind=mixed rather than picking one side.
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","tier":"telemetry","template_id":"mix","template_version":"v1","metric":"m","value":1.0}' > /dev/null
printf '%s\n' '{"schema_version":"1","kind":"consumption-contradiction","calibration_state":"pre-calibration","tier":"telemetry","template_id":"mix","template_version":"v1","metric":"m","value":2.0}' \
  >> "$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

bash "$SCRIPT_DIR/scorecard-rollup.sh" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
CURRENT=$(cat "$KNOWLEDGE_DIR/_scorecards/_current.json")
MIX_GROUP=$(echo "$CURRENT" | jq '.summaries[0]')
assert_eq "mix group kind labelled 'mixed'" "$(echo "$MIX_GROUP" | jq -r '.kind')" "mixed"
assert_eq "mix group sample_count" "$(echo "$MIX_GROUP" | jq -r '.sample_count')" "2"
assert_eq "mix group calibration_states length" "$(echo "$MIX_GROUP" | jq -r '.calibration_states | length')" "2"

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
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"w","template_version":"v1","metric":"m","value":0.5}' > /dev/null

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
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated"}')
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
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated"}' > /dev/null

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
if grep -qF 'event_type: ceremony-resolution' "$README" && grep -qF 'not deduplicated' "$README"; then
  echo "  PASS: README documents ceremony outcome validation and point-event semantics"
  PASS=$((PASS + 1))
else
  echo "  FAIL: README missing ceremony outcome writer contract"
  FAIL=$((FAIL + 1))
fi
if grep -qF 'record_type: disposition' "$README" && grep -qF 'lore ceremony handle' "$README"; then
  echo "  PASS: README documents the handled-transition contract and its front"
  PASS=$((PASS + 1))
else
  echo "  FAIL: README missing ceremony handled-transition contract"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 17: Grounded-or-nothing enforcement for reverse-auditor scored rows (task-21)
# =============================================
echo ""
echo "Test 17: Grounded-or-nothing for reverse-auditor scored rows"
setup_store

# Case A: reverse-auditor + scored + no claim_anchor -> rejected
EXIT_CODE=0
ERR_OUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","verdict_source":"reverse-auditor","template_id":"worker","template_version":"aaaaaaaaaaaa","metric":"omission_rate","value":0.1,"sample_size":10}' \
  2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "reverse-auditor scored without anchor exits non-zero" "$EXIT_CODE" "1"
assert_contains "rejection cites grounded-or-nothing" "$ERR_OUT" "grounded-or-nothing"

# Case B: reverse-auditor + scored + complete claim_anchor -> accepted
OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","verdict_source":"reverse-auditor","template_id":"worker","template_version":"aaaaaaaaaaaa","metric":"omission_rate","value":0.1,"sample_size":10,"claim_anchor":{"file":"/x/y.py","line_range":"10-12","exact_snippet":"def foo()"}}')
assert_contains "reverse-auditor scored with anchor accepted" "$OUTPUT" "[scorecard] Appended row"

# Case C: reverse-auditor + telemetry + no anchor -> accepted (exempt)
OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","tier":"telemetry","calibration_state":"unknown","verdict_source":"reverse-auditor","template_id":"reverse-auditor","template_version":"aaaaaaaaaaaa","metric":"grounding_failure_rate","value":0.3,"sample_size":10}')
assert_contains "reverse-auditor telemetry without anchor accepted" "$OUTPUT" "[scorecard] Appended row"

# Case D: non-reverse-auditor scored without anchor -> accepted (not targeted)
OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","verdict_source":"correctness-gate","template_id":"worker","template_version":"aaaaaaaaaaaa","metric":"factual_precision","value":0.9,"sample_size":10}')
assert_contains "correctness-gate scored without anchor accepted" "$OUTPUT" "[scorecard] Appended row"

# Case E: reverse-auditor + scored + anchor with empty file -> rejected
EXIT_CODE=0
ERR_OUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","calibration_state":"calibrated","verdict_source":"reverse-auditor","template_id":"worker","template_version":"aaaaaaaaaaaa","metric":"omission_rate","value":0.1,"sample_size":10,"claim_anchor":{"file":"","line_range":"10-12","exact_snippet":"def foo()"}}' \
  2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "reverse-auditor scored with empty file exits non-zero" "$EXIT_CODE" "1"

# Case F: no verdict_source -> enforcement not triggered (accepted)
OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"scored","tier":"telemetry","calibration_state":"calibrated","template_id":"worker","template_version":"aaaaaaaaaaaa","metric":"audit_pass_rate","value":0.8,"sample_size":10}')
assert_contains "row without verdict_source accepted" "$OUTPUT" "[scorecard] Appended row"

# Rejected rows never reached rows.jsonl: only the one accepted omission_rate row should be present
ROWS_FILE="$KNOWLEDGE_DIR/_scorecards/rows.jsonl"
ACCEPTED_OMISSION_COUNT=$(grep -c '"omission_rate"' "$ROWS_FILE" 2>/dev/null || echo "0")
assert_eq "only the one accepted omission_rate row landed" "$ACCEPTED_OMISSION_COUNT" "1"

# =============================================
# Model provenance stamp (segmentation across model generations)
# Priority: row's own model field > --model flag > LORE_MODEL env > "unrecorded"
# =============================================

# Case A: no model anywhere -> stamped "unrecorded"
bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","tier":"telemetry","metric":"model_stamp_probe_a"}' >/dev/null
STAMPED=$(grep '"model_stamp_probe_a"' "$ROWS_FILE" | tail -1 | jq -r '.model')
assert_eq "no model anywhere stamps unrecorded" "$STAMPED" "unrecorded"

# Case B: LORE_MODEL env -> stamped from env
LORE_MODEL="env-model-id" bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","tier":"telemetry","metric":"model_stamp_probe_b"}' >/dev/null
STAMPED=$(grep '"model_stamp_probe_b"' "$ROWS_FILE" | tail -1 | jq -r '.model')
assert_eq "LORE_MODEL env stamps row" "$STAMPED" "env-model-id"

# Case C: --model flag beats env
LORE_MODEL="env-model-id" bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --model "flag-model-id" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","tier":"telemetry","metric":"model_stamp_probe_c"}' >/dev/null
STAMPED=$(grep '"model_stamp_probe_c"' "$ROWS_FILE" | tail -1 | jq -r '.model')
assert_eq "--model flag beats LORE_MODEL env" "$STAMPED" "flag-model-id"

# Case D: row's own model field is never overwritten
LORE_MODEL="env-model-id" bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KNOWLEDGE_DIR" --model "flag-model-id" \
  --row '{"schema_version":"1","kind":"telemetry","calibration_state":"unknown","tier":"telemetry","metric":"model_stamp_probe_d","model":"row-model-id"}' >/dev/null
STAMPED=$(grep '"model_stamp_probe_d"' "$ROWS_FILE" | tail -1 | jq -r '.model')
assert_eq "row's own model field wins" "$STAMPED" "row-model-id"

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
