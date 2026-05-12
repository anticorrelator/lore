#!/usr/bin/env bash
# test_propagation_miss_append.sh — Tests for propagation-miss-append.sh
# Creates a temporary knowledge store and runs the writer against it.
#
# Covers:
#   - Valid append → one line in _work/<slug>/propagation-misses.jsonl
#   - Missing required field rejection (each required flag, exit 1, prefix)
#   - Invalid --reason rejection (closed-set enforcement)
#   - dedupe_key silent no-op: two identical calls → one line on disk
#   - Different reasons on same settlement_run_id → two distinct rows
#   - --json mode rejection shape (valid JSON {"error": ...} on stdout, exit 1)
#   - --json mode success shape (appended:true on stdout)
#   - Atomic-append invariant: two sequential valid appends → two complete lines
#   - Nonexistent work item rejected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/propagation-miss-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/propagation-misses.jsonl"

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

# Canonical valid-row invocation. Callers can override individual flags by
# appending --<flag> <value> after `valid_call`.
valid_call() {
  "$SCRIPT" \
    --work-item "$SLUG" \
    --settlement-run-id "run-abc123" \
    --reason "hook_crashed" \
    --claim-id "claim-1" \
    --detector "propagation-reconcile.sh" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

echo "=== propagation-miss-append Tests ==="

# =============================================
# Test 1: --help prints usage naming required flags
# =============================================
echo ""
echo "Test 1: --help prints usage"
OUTPUT=$("$SCRIPT" --help 2>&1)
assert_contains "usage names --work-item" "$OUTPUT" "--work-item"
assert_contains "usage names --settlement-run-id" "$OUTPUT" "--settlement-run-id"
assert_contains "usage names --reason" "$OUTPUT" "--reason"
assert_contains "usage names --claim-id" "$OUTPUT" "--claim-id"
assert_contains "usage names --detector" "$OUTPUT" "--detector"
assert_contains "usage names hook_crashed" "$OUTPUT" "hook_crashed"
assert_contains "usage names hook_disabled" "$OUTPUT" "hook_disabled"
assert_contains "usage names rehydration_failed" "$OUTPUT" "rehydration_failed"
assert_contains "usage names emit_failed" "$OUTPUT" "emit_failed"

# =============================================
# Test 2: Valid append → one line in sidecar
# =============================================
echo ""
echo "Test 2: Valid append"
setup_store
OUTPUT=$(valid_call 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[propagation-miss] Miss for run"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "settlement_run_id round-tripped" "$(echo "$ROW" | jq -r '.settlement_run_id')" "run-abc123"
assert_eq "reason round-tripped" "$(echo "$ROW" | jq -r '.reason')" "hook_crashed"
assert_eq "work_item round-tripped" "$(echo "$ROW" | jq -r '.work_item')" "$SLUG"
assert_eq "claim_id round-tripped" "$(echo "$ROW" | jq -r '.claim_id')" "claim-1"
assert_eq "detector round-tripped" "$(echo "$ROW" | jq -r '.detector')" "propagation-reconcile.sh"
assert_eq "detected_at present" "$(echo "$ROW" | jq -r '.detected_at | length > 0')" "true"
assert_eq "dedupe_key is 64-char hex" "$(echo "$ROW" | jq -r '.dedupe_key' | wc -c | tr -d ' ')" "65" # 64 + newline

# =============================================
# Test 3: Missing required field rejected — each required flag
# =============================================
echo ""
echo "Test 3a: Missing --settlement-run-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" --reason hook_crashed --claim-id c1 \
  --detector d --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --settlement-run-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr has [propagation-miss] prefix" "$STDERR" "[propagation-miss]"
assert_contains "stderr names --settlement-run-id" "$STDERR" "--settlement-run-id"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

echo ""
echo "Test 3b: Missing --reason rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" --settlement-run-id r --claim-id c1 \
  --detector d --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --reason exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --reason" "$STDERR" "--reason"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

echo ""
echo "Test 3c: Missing --claim-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" --settlement-run-id r --reason hook_crashed \
  --detector d --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --claim-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --claim-id" "$STDERR" "--claim-id"

echo ""
echo "Test 3d: Missing --detector rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" --settlement-run-id r --reason hook_crashed \
  --claim-id c1 --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --detector exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --detector" "$STDERR" "--detector"

# =============================================
# Test 4: Invalid --reason rejection (closed-set enforcement)
# =============================================
echo ""
echo "Test 4a: Invalid --reason rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --reason "bogus_reason" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --reason exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names closed set" "$STDERR" "hook_crashed"
assert_contains "stderr names hook_disabled" "$STDERR" "hook_disabled"
assert_contains "stderr names rehydration_failed" "$STDERR" "rehydration_failed"
assert_contains "stderr names emit_failed" "$STDERR" "emit_failed"
assert_not_exist "sidecar not created on invalid reason" "$SIDECAR"

# Verify every member of the closed set is accepted.
for reason in hook_crashed hook_disabled rehydration_failed emit_failed; do
  setup_store
  if valid_call --reason "$reason" > /dev/null 2>&1; then
    echo "  PASS: closed-set member '$reason' accepted"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: closed-set member '$reason' rejected"
    FAIL=$((FAIL + 1))
  fi
done

# =============================================
# Test 5: dedupe_key silent no-op on duplicate call
# =============================================
echo ""
echo "Test 5: dedupe silent no-op on identical (settlement_run_id, reason)"
setup_store
valid_call > /dev/null 2>&1
valid_call > /dev/null 2>&1
assert_eq "sidecar still has one line after duplicate call" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# Sanity: changing only the detector or claim_id does NOT bypass dedupe
# (dedupe key is purely settlement_run_id|reason).
valid_call --detector "other-detector.sh" --claim-id "claim-other" > /dev/null 2>&1
assert_eq "dedupe unchanged when only non-key fields differ" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# =============================================
# Test 6: Different reasons on same settlement_run_id → distinct rows
# =============================================
echo ""
echo "Test 6: Same run, different reasons → distinct rows"
setup_store
valid_call --reason "hook_crashed" > /dev/null 2>&1
valid_call --reason "emit_failed" > /dev/null 2>&1
assert_eq "two distinct (run, reason) pairs yield two lines" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# =============================================
# Test 7: --json mode — rejection shape
# =============================================
echo ""
echo "Test 7: --json mode rejection shape"
setup_store
EXIT_CODE=0
STDOUT=$("$SCRIPT" --work-item "$SLUG" --json --kdir "$KNOWLEDGE_DIR" 2>/dev/null) || EXIT_CODE=$?
assert_eq "--json rejection exits 1" "$EXIT_CODE" "1"
# stdout must be valid JSON with an "error" key
ERROR_MSG=$(echo "$STDOUT" | jq -r '.error' 2>/dev/null || echo "")
assert_contains "--json stdout parses; error names [propagation-miss]" "$ERROR_MSG" "[propagation-miss]"

# =============================================
# Test 8: --json mode — success shape
# =============================================
echo ""
echo "Test 8: --json mode success shape"
setup_store
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "appended field true" "$(echo "$STDOUT" | jq -r '.appended')" "true"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_work/$SLUG/propagation-misses.jsonl"
assert_eq "reason echoed in json result" "$(echo "$STDOUT" | jq -r '.reason')" "hook_crashed"
DK=$(echo "$STDOUT" | jq -r '.dedupe_key')
assert_eq "dedupe_key length 64" "${#DK}" "64"

# =============================================
# Test 9: Atomic-append invariant — two sequential valid appends → two lines
# =============================================
echo ""
echo "Test 9: Atomic-append invariant (two distinct settlement runs)"
setup_store
valid_call --settlement-run-id "run-1" > /dev/null 2>&1
valid_call --settlement-run-id "run-2" > /dev/null 2>&1
assert_eq "sidecar has two lines" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"
# Every line must be a complete valid JSON object (no partial lines).
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
  --settlement-run-id "r" --reason hook_crashed \
  --claim-id c1 --detector d \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent work item exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names work item" "$STDERR" "work item not found"

# =============================================
# Test 11: Custom --detected-at round-trips
# =============================================
echo ""
echo "Test 11: Explicit --detected-at round-trips"
setup_store
valid_call --detected-at "2026-05-11T12:34:56Z" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "detected_at preserved verbatim" "$(echo "$ROW" | jq -r '.detected_at')" "2026-05-11T12:34:56Z"

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
