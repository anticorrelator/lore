#!/usr/bin/env bash
# test_consumption_contradiction_update_status.sh — Tests for
# consumption-contradiction-update-status.sh + the enum extension in
# consumption-contradiction-append.sh + the correctness-gate-rollup.sh wiring.
#
# Covers:
#   1. Enum extension: append accepts --status verified|rejected; legacy
#      values still work; invalid values still rejected.
#   2. Update happy path: pending → verified flips status, populates
#      settled_at, leaves other fields unchanged.
#   3. Missing contradiction-id: exit non-zero, stderr carries the error.
#   4. Double-update idempotency: second call to same target → exit 0,
#      file unchanged.
#   5. Rollup end-to-end:
#      - verdict batch all-verified → sidecar status verified
#      - verdict batch contains contradicted → sidecar status rejected
#      - verdict batch unverified-dominant → sidecar status unchanged

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
APPEND="$SCRIPT_DIR/consumption-contradiction-append.sh"
UPDATE="$SCRIPT_DIR/consumption-contradiction-update-status.sh"
ROLLUP="$SCRIPT_DIR/correctness-gate-rollup.sh"

TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/consumption-contradictions.jsonl"
SCORECARD="$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

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

assert_neq() {
  local label="$1" actual="$2" not_expected="$3"
  if [[ "$actual" != "$not_expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected not equal to: $not_expected"
    echo "    Actual: $actual"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/_work/$SLUG"
  mkdir -p "$KNOWLEDGE_DIR/_scorecards"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
}

valid_append() {
  "$APPEND" \
    --work-item "$SLUG" \
    --source worker \
    --producer-role impl-worker \
    --protocol-slot implement-step-3 \
    --cycle-id "cycle-1" \
    --knowledge-path "architecture/audit-pipeline/contract" \
    --heading "Input contract" \
    --contradiction-rationale "code disagrees with commons entry" \
    --claim-id "c1" \
    --claim-text "audit runs three judges" \
    --file "/abs/path/to/audit.sh" \
    --line-range "10-20" \
    --exact-snippet "foo bar baz" \
    --falsifier "if audit.sh runs four judges" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

echo "=== consumption-contradiction-update-status Tests ==="

# =============================================
# Test 1: Enum extension — append accepts verified|rejected; legacy still works
# =============================================
echo ""
echo "Test 1a: append accepts --status verified"
setup_store
EXIT_CODE=0
OUTPUT=$(valid_append --status "verified" --contradiction-id "ctr-test-verified" 2>&1) || EXIT_CODE=$?
assert_eq "append --status verified exits 0" "$EXIT_CODE" "0"
ROW=$(cat "$SIDECAR")
assert_eq "appended row carries status:verified" "$(echo "$ROW" | jq -r '.status')" "verified"

echo ""
echo "Test 1b: append accepts --status rejected"
setup_store
EXIT_CODE=0
OUTPUT=$(valid_append --status "rejected" --contradiction-id "ctr-test-rejected" 2>&1) || EXIT_CODE=$?
assert_eq "append --status rejected exits 0" "$EXIT_CODE" "0"
ROW=$(cat "$SIDECAR")
assert_eq "appended row carries status:rejected" "$(echo "$ROW" | jq -r '.status')" "rejected"

echo ""
echo "Test 1c: append still accepts legacy --status pending"
setup_store
EXIT_CODE=0
OUTPUT=$(valid_append --status "pending" --contradiction-id "ctr-test-pending" 2>&1) || EXIT_CODE=$?
assert_eq "append --status pending exits 0" "$EXIT_CODE" "0"
ROW=$(cat "$SIDECAR")
assert_eq "appended row carries status:pending" "$(echo "$ROW" | jq -r '.status')" "pending"

echo ""
echo "Test 1d: append still rejects invalid --status"
setup_store
EXIT_CODE=0
STDERR=$(valid_append --status "bogus" 2>&1) || EXIT_CODE=$?
assert_eq "append --status bogus exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names verified" "$STDERR" "verified"
assert_contains "stderr names rejected" "$STDERR" "rejected"

echo ""
echo "Test 1e: append --settled-by-run-id is appended omit-when-empty"
setup_store
valid_append --contradiction-id "ctr-with-runid" --settled-by-run-id "run-99" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "settled_by_run_id round-tripped on append" "$(echo "$ROW" | jq -r '.settled_by_run_id')" "run-99"
setup_store
valid_append --contradiction-id "ctr-no-runid" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "settled_by_run_id absent when --settled-by-run-id not supplied" "$(echo "$ROW" | jq -r 'has("settled_by_run_id")')" "false"

# =============================================
# Test 2: Update happy path — pending → verified
# =============================================
echo ""
echo "Test 2: Happy path (pending → verified)"
setup_store
valid_append --contradiction-id "ctr-happy-1" > /dev/null 2>&1
ROW_BEFORE=$(cat "$SIDECAR")
assert_eq "pre-update status is pending" "$(echo "$ROW_BEFORE" | jq -r '.status')" "pending"
assert_eq "pre-update settled_at absent or null" "$(echo "$ROW_BEFORE" | jq -r 'has("settled_at") | not or .settled_at == null')" "true"

EXIT_CODE=0
OUTPUT=$("$UPDATE" --contradiction-id "ctr-happy-1" --status "verified" --settled-by-run-id "run-42" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "update exits 0 on happy path" "$EXIT_CODE" "0"
assert_contains "stdout reports OK with target status" "$OUTPUT" "OK: ctr-happy-1 → verified"

ROW_AFTER=$(cat "$SIDECAR")
assert_eq "status updated to verified" "$(echo "$ROW_AFTER" | jq -r '.status')" "verified"
assert_eq "settled_at populated" "$(echo "$ROW_AFTER" | jq -r '.settled_at | length > 0')" "true"
assert_eq "settled_by_run_id populated" "$(echo "$ROW_AFTER" | jq -r '.settled_by_run_id')" "run-42"

# All other fields unchanged.
assert_eq "contradiction_id unchanged" "$(echo "$ROW_AFTER" | jq -r '.contradiction_id')" "ctr-happy-1"
assert_eq "verdict_source unchanged" "$(echo "$ROW_AFTER" | jq -r '.verdict_source')" "consumer-contradiction-channel"
assert_eq "work_item unchanged" "$(echo "$ROW_AFTER" | jq -r '.work_item')" "$SLUG"
assert_eq "source unchanged" "$(echo "$ROW_AFTER" | jq -r '.source')" "worker"
assert_eq "claim_payload.file unchanged" "$(echo "$ROW_AFTER" | jq -r '.claim_payload.file')" "/abs/path/to/audit.sh"
assert_eq "claim_payload.exact_snippet unchanged" "$(echo "$ROW_AFTER" | jq -r '.claim_payload.exact_snippet')" "foo bar baz"
assert_eq "dedupe_key unchanged" "$(echo "$ROW_AFTER" | jq -r '.dedupe_key')" "$(echo "$ROW_BEFORE" | jq -r '.dedupe_key')"

# Sidecar still has exactly one line.
assert_eq "sidecar still has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# =============================================
# Test 2b: Update happy path — pending → rejected (other terminal value)
# =============================================
echo ""
echo "Test 2b: Happy path (pending → rejected)"
setup_store
valid_append --contradiction-id "ctr-rej-1" > /dev/null 2>&1
EXIT_CODE=0
OUTPUT=$("$UPDATE" --contradiction-id "ctr-rej-1" --status "rejected" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "update to rejected exits 0" "$EXIT_CODE" "0"
ROW=$(cat "$SIDECAR")
assert_eq "status updated to rejected" "$(echo "$ROW" | jq -r '.status')" "rejected"
assert_eq "settled_at populated on rejected path" "$(echo "$ROW" | jq -r '.settled_at | length > 0')" "true"
# settled_by_run_id was not passed and not previously present.
assert_eq "settled_by_run_id absent when not passed" "$(echo "$ROW" | jq -r 'has("settled_by_run_id")')" "false"

# =============================================
# Test 3: Missing contradiction-id → exit non-zero
# =============================================
echo ""
echo "Test 3: Missing contradiction-id"
setup_store
valid_append --contradiction-id "ctr-exists" > /dev/null 2>&1
EXIT_CODE=0
STDERR=$("$UPDATE" --contradiction-id "ctr-not-there" --status "verified" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "update on missing id exits non-zero" "$EXIT_CODE" "1"
assert_contains "stderr has [contradiction-update] prefix" "$STDERR" "[contradiction-update]"
assert_contains "stderr names the missing id" "$STDERR" "ctr-not-there"
# Pre-existing row untouched.
ROW=$(cat "$SIDECAR")
assert_eq "pre-existing row untouched" "$(echo "$ROW" | jq -r '.status')" "pending"

# =============================================
# Test 4: Double-update idempotency
# =============================================
echo ""
echo "Test 4: Double-update idempotency"
setup_store
valid_append --contradiction-id "ctr-idem-1" > /dev/null 2>&1
"$UPDATE" --contradiction-id "ctr-idem-1" --status "verified" --kdir "$KNOWLEDGE_DIR" > /dev/null 2>&1
ROW_FIRST=$(cat "$SIDECAR")
HASH_FIRST=$(shasum -a 256 "$SIDECAR" | awk '{print $1}')

# Second call — already verified.
EXIT_CODE=0
STDERR=$("$UPDATE" --contradiction-id "ctr-idem-1" --status "verified" --kdir "$KNOWLEDGE_DIR" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "second update exits 0" "$EXIT_CODE" "0"
assert_contains "stderr has no-op log" "$STDERR" "[contradiction-update] already verified"

HASH_SECOND=$(shasum -a 256 "$SIDECAR" | awk '{print $1}')
assert_eq "sidecar byte-identical after no-op" "$HASH_SECOND" "$HASH_FIRST"

# =============================================
# Test 4b: --json mode shapes
# =============================================
echo ""
echo "Test 4b: --json mode (update + noop)"
setup_store
valid_append --contradiction-id "ctr-json-1" > /dev/null 2>&1
STDOUT=$("$UPDATE" --contradiction-id "ctr-json-1" --status "verified" --kdir "$KNOWLEDGE_DIR" --json 2>/dev/null)
assert_eq "--json update emits contradiction_id" "$(echo "$STDOUT" | jq -r '.contradiction_id')" "ctr-json-1"
assert_eq "--json update emits new_status" "$(echo "$STDOUT" | jq -r '.new_status')" "verified"
assert_eq "--json update emits previous_status" "$(echo "$STDOUT" | jq -r '.previous_status')" "pending"
assert_eq "--json update emits settled_at" "$(echo "$STDOUT" | jq -r '.settled_at | length > 0')" "true"

STDOUT=$("$UPDATE" --contradiction-id "ctr-json-1" --status "verified" --kdir "$KNOWLEDGE_DIR" --json 2>/dev/null)
assert_eq "--json noop emits noop:true" "$(echo "$STDOUT" | jq -r '.noop')" "true"

# =============================================
# Test 5: Rollup end-to-end — verdict mapping
# =============================================
echo ""
echo "Test 5a: Rollup verified → sidecar status verified"
setup_store
valid_append --contradiction-id "ctr-rollup-verified" > /dev/null 2>&1
# Build a verdict file with all-verified.
VERDICTS_PATH="$TEST_DIR/verdicts-verified.jsonl"
cat > "$VERDICTS_PATH" <<EOF
{"judge":"correctness-gate","claim_id":"c1","verdict":"verified","evidence":"e1"}
{"judge":"correctness-gate","claim_id":"c2","verdict":"verified","evidence":"e2"}
EOF
EXIT_CODE=0
OUTPUT=$("$ROLLUP" \
  --artifact-id "ctr-rollup-verified" \
  --artifact-type "consumption-contradiction" \
  --producer-template-id "tpl-1" \
  --producer-template-version "abcdef012345" \
  --window-start "2026-05-01T00:00:00Z" \
  --window-end   "2026-05-13T00:00:00Z" \
  --kdir "$KNOWLEDGE_DIR" \
  --verdicts "$VERDICTS_PATH" 2>&1) || EXIT_CODE=$?
assert_eq "rollup verified exits 0" "$EXIT_CODE" "0"
assert_contains "rollup logs the flip" "$OUTPUT" "Flipped contradiction ctr-rollup-verified → verified"

ROW=$(cat "$SIDECAR")
assert_eq "sidecar status flipped to verified" "$(echo "$ROW" | jq -r '.status')" "verified"

echo ""
echo "Test 5b: Rollup contradicted → sidecar status rejected"
setup_store
valid_append --contradiction-id "ctr-rollup-contradicted" > /dev/null 2>&1
VERDICTS_PATH="$TEST_DIR/verdicts-contradicted.jsonl"
cat > "$VERDICTS_PATH" <<EOF
{"judge":"correctness-gate","claim_id":"c1","verdict":"verified","evidence":"e1"}
{"judge":"correctness-gate","claim_id":"c2","verdict":"contradicted","evidence":"e2","correction":"cx"}
EOF
EXIT_CODE=0
OUTPUT=$("$ROLLUP" \
  --artifact-id "ctr-rollup-contradicted" \
  --artifact-type "consumption-contradiction" \
  --producer-template-id "tpl-1" \
  --producer-template-version "abcdef012345" \
  --window-start "2026-05-01T00:00:00Z" \
  --window-end   "2026-05-13T00:00:00Z" \
  --kdir "$KNOWLEDGE_DIR" \
  --verdicts "$VERDICTS_PATH" 2>&1) || EXIT_CODE=$?
assert_eq "rollup contradicted exits 0" "$EXIT_CODE" "0"
assert_contains "rollup logs the rejected flip" "$OUTPUT" "Flipped contradiction ctr-rollup-contradicted → rejected"

ROW=$(cat "$SIDECAR")
assert_eq "sidecar status flipped to rejected" "$(echo "$ROW" | jq -r '.status')" "rejected"

echo ""
echo "Test 5c: Rollup unverified-dominant → sidecar unchanged"
setup_store
valid_append --contradiction-id "ctr-rollup-unverified" > /dev/null 2>&1
VERDICTS_PATH="$TEST_DIR/verdicts-unverified.jsonl"
cat > "$VERDICTS_PATH" <<EOF
{"judge":"correctness-gate","claim_id":"c1","verdict":"verified","evidence":"e1"}
{"judge":"correctness-gate","claim_id":"c2","verdict":"unverified","evidence":"e2"}
EOF
EXIT_CODE=0
OUTPUT=$("$ROLLUP" \
  --artifact-id "ctr-rollup-unverified" \
  --artifact-type "consumption-contradiction" \
  --producer-template-id "tpl-1" \
  --producer-template-version "abcdef012345" \
  --window-start "2026-05-01T00:00:00Z" \
  --window-end   "2026-05-13T00:00:00Z" \
  --kdir "$KNOWLEDGE_DIR" \
  --verdicts "$VERDICTS_PATH" 2>&1) || EXIT_CODE=$?
assert_eq "rollup unverified exits 0" "$EXIT_CODE" "0"
assert_contains "rollup logs no-flip" "$OUTPUT" "No contradiction-status flip"

ROW=$(cat "$SIDECAR")
assert_eq "sidecar status unchanged when terminal=unverified" "$(echo "$ROW" | jq -r '.status')" "pending"

echo ""
echo "Test 5d: Rollup without --artifact-type does NOT flip"
setup_store
valid_append --contradiction-id "ctr-rollup-untyped" > /dev/null 2>&1
VERDICTS_PATH="$TEST_DIR/verdicts-untyped.jsonl"
cat > "$VERDICTS_PATH" <<EOF
{"judge":"correctness-gate","claim_id":"c1","verdict":"verified","evidence":"e1"}
EOF
EXIT_CODE=0
OUTPUT=$("$ROLLUP" \
  --artifact-id "ctr-rollup-untyped" \
  --producer-template-id "tpl-1" \
  --producer-template-version "abcdef012345" \
  --window-start "2026-05-01T00:00:00Z" \
  --window-end   "2026-05-13T00:00:00Z" \
  --kdir "$KNOWLEDGE_DIR" \
  --verdicts "$VERDICTS_PATH" 2>&1) || EXIT_CODE=$?
assert_eq "rollup without artifact-type exits 0" "$EXIT_CODE" "0"
ROW=$(cat "$SIDECAR")
assert_eq "sidecar untouched when artifact-type not consumption-contradiction" "$(echo "$ROW" | jq -r '.status')" "pending"

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
