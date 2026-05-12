#!/usr/bin/env bash
# test_correction_candidate_append.sh — Tests for correction-candidate-append.sh
# Creates a temporary knowledge store and runs the writer against it.
#
# Covers:
#   - Valid append → one line in _work/<slug>/correction-candidates.jsonl
#   - verdict literal is "contradicted" (producer cannot override)
#   - Missing-required-field rejection (every D6 field, exit 1, prefix)
#   - Enum rejection (--task-claim-anchor-scale)
#   - Boolean rejection (--target-overlap)
#   - Integer rejection (--target-rank)
#   - Float-range rejection (--target-sim outside [0, 1])
#   - line_range shape rejection (--task-claim-anchor-line-range)
#   - change_context must be JSON object
#   - dedupe_key silent no-op: two identical calls → one line on disk
#   - dedupe_key components → re-emitting with a different resolver_version
#     produces a second line (proves the dedupe key actually uses it)
#   - --json mode rejection shape (valid JSON {"error": ...} on stdout, exit 1)
#   - --json mode success shape (appended:true on stdout)
#   - Atomic-append invariant: two valid distinct appends → two complete lines

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/correction-candidate-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/correction-candidates.jsonl"

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

assert_not_exist() {
  local label="$1" filepath="$2"
  if [[ ! -f "$filepath" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file exists: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/_work/$SLUG"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
}

# Canonical valid invocation. Override individual flags by appending pairs.
valid_call() {
  "$SCRIPT" \
    --work-item "$SLUG" \
    --candidate-for-verdict-id "v-001" \
    --settlement-run-id "v-001" \
    --claim-id "c1" \
    --target-entry-path "domains/foo/bar.md" \
    --target-rank 1 \
    --target-overlap true \
    --target-sim 0.7234 \
    --verdict-evidence "code at audit.sh:42 contradicts entry" \
    --verdict-correction-text "the entry should say four judges, not three" \
    --task-claim-anchor-file "/abs/path/to/audit.sh" \
    --task-claim-anchor-line-range "10-20" \
    --task-claim-anchor-scale "implementation" \
    --task-claim-anchor-producer-role "worker" \
    --task-claim-anchor-change-context '{"diff_ref":"abc","summary":"changed thing"}' \
    --resolver-version "resv-001" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

echo "=== correction-candidate-append Tests ==="

# =============================================
# Test 1: --help prints usage naming required flags
# =============================================
echo ""
echo "Test 1: --help prints usage"
OUTPUT=$("$SCRIPT" --help 2>&1)
assert_contains "usage names --work-item" "$OUTPUT" "--work-item"
assert_contains "usage names --candidate-for-verdict-id" "$OUTPUT" "--candidate-for-verdict-id"
assert_contains "usage names --settlement-run-id" "$OUTPUT" "--settlement-run-id"
assert_contains "usage names --target-entry-path" "$OUTPUT" "--target-entry-path"
assert_contains "usage names --task-claim-anchor-file" "$OUTPUT" "--task-claim-anchor-file"
assert_contains "usage names --resolver-version" "$OUTPUT" "--resolver-version"

# =============================================
# Test 2: Valid append → one line in sidecar
# =============================================
echo ""
echo "Test 2: Valid append"
setup_store
OUTPUT=$(valid_call 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[correction-candidate] Candidate"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "verdict is literal contradicted" "$(echo "$ROW" | jq -r '.verdict')" "contradicted"
assert_eq "work_item round-tripped" "$(echo "$ROW" | jq -r '.work_item')" "$SLUG"
assert_eq "claim_id round-tripped" "$(echo "$ROW" | jq -r '.claim_id')" "c1"
assert_eq "target_entry_path round-tripped" "$(echo "$ROW" | jq -r '.target_entry_path')" "domains/foo/bar.md"
assert_eq "target_rank is number 1" "$(echo "$ROW" | jq -r '.target_rank')" "1"
assert_eq "target_overlap is boolean true" "$(echo "$ROW" | jq -r '.target_overlap')" "true"
assert_eq "target_sim round-tripped as number" "$(echo "$ROW" | jq -r '.target_sim')" "0.7234"
assert_eq "candidate_for_verdict_id round-tripped" "$(echo "$ROW" | jq -r '.candidate_for_verdict_id')" "v-001"
assert_eq "settlement_run_id round-tripped" "$(echo "$ROW" | jq -r '.settlement_run_id')" "v-001"
assert_eq "resolver_version round-tripped" "$(echo "$ROW" | jq -r '.resolver_version')" "resv-001"
assert_eq "task_claim_anchor.file round-tripped" "$(echo "$ROW" | jq -r '.task_claim_anchor.file')" "/abs/path/to/audit.sh"
assert_eq "task_claim_anchor.line_range round-tripped" "$(echo "$ROW" | jq -r '.task_claim_anchor.line_range')" "10-20"
assert_eq "task_claim_anchor.scale round-tripped" "$(echo "$ROW" | jq -r '.task_claim_anchor.scale')" "implementation"
assert_eq "task_claim_anchor.producer_role round-tripped" "$(echo "$ROW" | jq -r '.task_claim_anchor.producer_role')" "worker"
assert_eq "task_claim_anchor.change_context is object" "$(echo "$ROW" | jq -r '.task_claim_anchor.change_context | type')" "object"
assert_eq "task_claim_anchor.change_context.summary preserved" "$(echo "$ROW" | jq -r '.task_claim_anchor.change_context.summary')" "changed thing"
assert_eq "dedupe_key is 64-char hex" "$(echo "$ROW" | jq -r '.dedupe_key' | wc -c | tr -d ' ')" "65"
assert_eq "candidate_id has cc- prefix" "$(echo "$ROW" | jq -r '.candidate_id' | cut -c1-3)" "cc-"
assert_eq "emitted_at present and non-empty" "$(echo "$ROW" | jq -e '.emitted_at | type == "string" and . != ""' >/dev/null && echo ok)" "ok"

# =============================================
# Test 3: Producer cannot override --verdict (no such flag)
# =============================================
echo ""
echo "Test 3: Unknown --verdict flag rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --verdict "grounded" 2>&1) || EXIT_CODE=$?
assert_eq "unknown --verdict flag exits 1" "$EXIT_CODE" "1"
assert_contains "stderr says unknown flag" "$STDERR" "unknown flag"

# =============================================
# Test 4: Missing required fields rejected
# =============================================
echo ""
echo "Test 4: Missing --candidate-for-verdict-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --work-item "$SLUG" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --candidate-for-verdict-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr prefix" "$STDERR" "[correction-candidate]"
assert_contains "stderr names --candidate-for-verdict-id" "$STDERR" "--candidate-for-verdict-id"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

# Per-field missing — sweep every D6-required field.
# For each, drop that single field and confirm rejection + descriptive stderr.
# Bash 3.2 compatible: parallel arrays (FLAG[i] / VAL[i]) instead of associative.
echo ""
echo "Test 4b: Per-required-field rejection sweep"
FLAGS=(
  "--work-item"
  "--candidate-for-verdict-id"
  "--settlement-run-id"
  "--claim-id"
  "--target-entry-path"
  "--target-rank"
  "--target-overlap"
  "--target-sim"
  "--verdict-evidence"
  "--verdict-correction-text"
  "--task-claim-anchor-file"
  "--task-claim-anchor-line-range"
  "--task-claim-anchor-scale"
  "--task-claim-anchor-producer-role"
  "--task-claim-anchor-change-context"
  "--resolver-version"
)
VALUES=(
  "$SLUG"
  "v-001"
  "v-001"
  "c1"
  "domains/foo/bar.md"
  "1"
  "true"
  "0.5"
  "e"
  "c"
  "/abs/a.sh"
  "1-2"
  "implementation"
  "worker"
  '{"k":"v"}'
  "r1"
)

N=${#FLAGS[@]}
i=0
while [[ $i -lt $N ]]; do
  setup_store
  dropped="${FLAGS[$i]}"
  ARGS=()
  j=0
  while [[ $j -lt $N ]]; do
    if [[ $j -ne $i ]]; then
      ARGS+=("${FLAGS[$j]}" "${VALUES[$j]}")
    fi
    j=$((j + 1))
  done
  ARGS+=("--kdir" "$KNOWLEDGE_DIR")
  EXIT_CODE=0
  STDERR=$("$SCRIPT" "${ARGS[@]}" 2>&1) || EXIT_CODE=$?
  assert_eq "dropping $dropped exits 1" "$EXIT_CODE" "1"
  assert_contains "stderr names $dropped" "$STDERR" "$dropped"
  assert_not_exist "sidecar not created when $dropped missing" "$SIDECAR"
  i=$((i + 1))
done

# =============================================
# Test 5: Enum + type rejections
# =============================================
echo ""
echo "Test 5a: Invalid --task-claim-anchor-scale rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --task-claim-anchor-scale "galactic" 2>&1) || EXIT_CODE=$?
assert_eq "invalid scale exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names valid scales" "$STDERR" "implementation"

echo ""
echo "Test 5b: Invalid --target-overlap rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-overlap "maybe" 2>&1) || EXIT_CODE=$?
assert_eq "invalid overlap exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names true/false" "$STDERR" "true"

echo ""
echo "Test 5c: Invalid --target-rank rejected (non-positive integer)"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-rank "0" 2>&1) || EXIT_CODE=$?
assert_eq "zero rank exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names positive integer" "$STDERR" "positive integer"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-rank "abc" 2>&1) || EXIT_CODE=$?
assert_eq "non-numeric rank exits 1" "$EXIT_CODE" "1"

echo ""
echo "Test 5d: Invalid --target-sim rejected (outside [0,1])"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-sim "1.5" 2>&1) || EXIT_CODE=$?
assert_eq "sim > 1 exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names [0.0, 1.0]" "$STDERR" "[0.0, 1.0]"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-sim "-0.1" 2>&1) || EXIT_CODE=$?
assert_eq "sim < 0 exits 1" "$EXIT_CODE" "1"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --target-sim "notafloat" 2>&1) || EXIT_CODE=$?
assert_eq "non-numeric sim exits 1" "$EXIT_CODE" "1"

echo ""
echo "Test 5e: Malformed --task-claim-anchor-line-range rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --task-claim-anchor-line-range "abc" 2>&1) || EXIT_CODE=$?
assert_eq "malformed line-range exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names N or N-M shape" "$STDERR" "line-range"

echo ""
echo "Test 5f: --task-claim-anchor-change-context must be JSON object"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --task-claim-anchor-change-context "not json" 2>&1) || EXIT_CODE=$?
assert_eq "non-JSON change_context exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names JSON object" "$STDERR" "JSON object"
setup_store
EXIT_CODE=0
# Array is JSON but not an object
STDERR=$(valid_call --task-claim-anchor-change-context "[1,2,3]" 2>&1) || EXIT_CODE=$?
assert_eq "JSON array (non-object) change_context exits 1" "$EXIT_CODE" "1"

# =============================================
# Test 6: dedupe_key silent no-op on duplicate call
# =============================================
echo ""
echo "Test 6: dedupe silent no-op"
setup_store
valid_call > /dev/null 2>&1
valid_call > /dev/null 2>&1
assert_eq "sidecar still has one line after duplicate call" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
# Even with different candidate_id supplied, same (candidate_for_verdict_id, target_entry_path, resolver_version) → no-op
valid_call --candidate-id "cc-explicit-override" > /dev/null 2>&1
assert_eq "sidecar still one line — dedupe ignores candidate_id" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# =============================================
# Test 6b: Dedupe key components — different resolver_version yields second row
# =============================================
echo ""
echo "Test 6b: Different resolver_version → second row"
setup_store
valid_call > /dev/null 2>&1
valid_call --resolver-version "resv-002" > /dev/null 2>&1
assert_eq "sidecar has two lines after different resolver_version" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# Different target_entry_path → second row.
setup_store
valid_call > /dev/null 2>&1
valid_call --target-entry-path "domains/other/baz.md" > /dev/null 2>&1
assert_eq "sidecar has two lines after different target_entry_path" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# Different candidate_for_verdict_id → second row.
setup_store
valid_call > /dev/null 2>&1
valid_call --candidate-for-verdict-id "v-002" > /dev/null 2>&1
assert_eq "sidecar has two lines after different candidate_for_verdict_id" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# =============================================
# Test 7: --json mode — rejection shape
# =============================================
echo ""
echo "Test 7: --json mode rejection shape"
setup_store
EXIT_CODE=0
STDOUT=$("$SCRIPT" --work-item "$SLUG" --json --kdir "$KNOWLEDGE_DIR" 2>/dev/null) || EXIT_CODE=$?
assert_eq "--json rejection exits 1" "$EXIT_CODE" "1"
ERROR_MSG=$(echo "$STDOUT" | jq -r '.error' 2>/dev/null || echo "")
assert_contains "--json stdout parses; error names [correction-candidate]" "$ERROR_MSG" "[correction-candidate]"

# =============================================
# Test 8: --json mode — success shape
# =============================================
echo ""
echo "Test 8: --json mode success shape"
setup_store
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "appended field true" "$(echo "$STDOUT" | jq -r '.appended')" "true"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_work/$SLUG/correction-candidates.jsonl"
assert_contains "candidate_id has cc- prefix" "$(echo "$STDOUT" | jq -r '.candidate_id')" "cc-"
DK=$(echo "$STDOUT" | jq -r '.dedupe_key')
assert_eq "dedupe_key length 64" "${#DK}" "64"

# =============================================
# Test 9: Atomic-append invariant — two distinct appends yield two complete lines
# =============================================
echo ""
echo "Test 9: Atomic-append invariant (two distinct appends)"
setup_store
valid_call --candidate-for-verdict-id "v-001" --target-entry-path "domains/a.md" > /dev/null 2>&1
valid_call --candidate-for-verdict-id "v-002" --target-entry-path "domains/b.md" > /dev/null 2>&1
assert_eq "sidecar has two lines" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"
LINE_COUNT=0
VALID_COUNT=0
while IFS= read -r line; do
  LINE_COUNT=$((LINE_COUNT + 1))
  if echo "$line" | jq -e 'type == "object"' >/dev/null 2>&1; then
    VALID_COUNT=$((VALID_COUNT + 1))
  fi
done < "$SIDECAR"
assert_eq "all lines are valid JSON objects" "$VALID_COUNT" "$LINE_COUNT"

# =============================================
# Test 10: Nonexistent work item rejected
# =============================================
echo ""
echo "Test 10: Nonexistent work item rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "does-not-exist" \
  --candidate-for-verdict-id v-001 \
  --settlement-run-id v-001 \
  --claim-id c1 \
  --target-entry-path d/x.md \
  --target-rank 1 \
  --target-overlap true \
  --target-sim 0.5 \
  --verdict-evidence e \
  --verdict-correction-text c \
  --task-claim-anchor-file /a \
  --task-claim-anchor-line-range 1 \
  --task-claim-anchor-scale implementation \
  --task-claim-anchor-producer-role worker \
  --task-claim-anchor-change-context '{}' \
  --resolver-version r1 \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent work item exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names work item" "$STDERR" "work item not found"

# =============================================
# Summary
# =============================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
