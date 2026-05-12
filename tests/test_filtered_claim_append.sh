#!/usr/bin/env bash
# test_filtered_claim_append.sh — Tests for filtered-claim-append.sh
# Creates a temporary knowledge store and runs the writer against it.
#
# Covers:
#   - --help prints usage naming required flags
#   - Valid append (pre-enqueue mode=exclude): one line in sidecar, expected fields
#   - Valid append (post-verdict mode=report-only): settlement_run_id present
#   - Missing-required-field rejection
#   - Invalid-enum rejection (--reason, --mode, --stage, --enqueued-anyway, --line-range)
#   - Stage-conditional rule:
#       * stage=post-verdict missing --settlement-run-id rejected
#       * stage=pre-enqueue with --settlement-run-id rejected
#   - Mode↔enqueued_anyway consistency:
#       * mode=exclude + enqueued-anyway=true rejected
#       * mode=report-only + enqueued-anyway=false rejected
#   - change_context must parse as JSON object
#   - Branch-provenance trio always emitted as keys
#   - settlement_run_id absent on pre-enqueue rows
#   - Dedupe idempotency: two identical calls → one line on disk
#   - --json mode rejection shape (valid JSON {"error": ...} on stdout, exit 1)
#   - --json mode success shape (appended:true on stdout)
#   - Atomic-append invariant (two sequential valid appends → two complete lines)
#   - Nonexistent work item rejected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/filtered-claim-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/filtered-claims.jsonl"

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

# Canonical pre-enqueue valid-row invocation (mode=exclude → enqueued-anyway=false,
# no settlement-run-id). Callers can override individual flags by appending
# --<flag> <value> after `valid_pre`.
valid_pre() {
  "$SCRIPT" \
    --work-item "$SLUG" \
    --claim-id "claim-1" \
    --reason "templated-claim" \
    --mode "exclude" \
    --stage "pre-enqueue" \
    --file "/abs/path/to/audit.sh" \
    --line-range "10-20" \
    --change-context '{"diff_ref": "abc123", "summary": "test change"}' \
    --enqueued-anyway "false" \
    --resolver-version "resolver-v1" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

# Canonical post-verdict valid-row invocation (mode=report-only →
# enqueued-anyway=true, settlement-run-id REQUIRED).
valid_post() {
  "$SCRIPT" \
    --work-item "$SLUG" \
    --claim-id "claim-2" \
    --reason "no-discoverable-target" \
    --mode "report-only" \
    --stage "post-verdict" \
    --settlement-run-id "run-xyz-789" \
    --file "/abs/path/to/audit.sh" \
    --line-range "30-40" \
    --change-context '{"diff_ref": "def456", "summary": "another change"}' \
    --enqueued-anyway "true" \
    --resolver-version "resolver-v1" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

echo "=== filtered-claim-append Tests ==="

# =============================================
# Test 1: --help prints usage naming required flags
# =============================================
echo ""
echo "Test 1: --help prints usage"
OUTPUT=$("$SCRIPT" --help 2>&1)
assert_contains "usage names --work-item"          "$OUTPUT" "--work-item"
assert_contains "usage names --claim-id"           "$OUTPUT" "--claim-id"
assert_contains "usage names --reason"             "$OUTPUT" "--reason"
assert_contains "usage names --mode"               "$OUTPUT" "--mode"
assert_contains "usage names --stage"              "$OUTPUT" "--stage"
assert_contains "usage names --settlement-run-id"  "$OUTPUT" "--settlement-run-id"
assert_contains "usage names --file"               "$OUTPUT" "--file"
assert_contains "usage names --line-range"         "$OUTPUT" "--line-range"
assert_contains "usage names --change-context"     "$OUTPUT" "--change-context"
assert_contains "usage names --enqueued-anyway"    "$OUTPUT" "--enqueued-anyway"
assert_contains "usage names --resolver-version"   "$OUTPUT" "--resolver-version"

# =============================================
# Test 2: Valid pre-enqueue append → one line in sidecar
# =============================================
echo ""
echo "Test 2: Valid pre-enqueue append"
setup_store
OUTPUT=$(valid_pre 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[filtered-claim] Filtered claim"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "work_item round-tripped"        "$(echo "$ROW" | jq -r '.work_item')" "$SLUG"
assert_eq "claim_id round-tripped"         "$(echo "$ROW" | jq -r '.claim_id')" "claim-1"
assert_eq "reason round-tripped"           "$(echo "$ROW" | jq -r '.reason')" "templated-claim"
assert_eq "mode round-tripped"             "$(echo "$ROW" | jq -r '.mode')" "exclude"
assert_eq "stage round-tripped"            "$(echo "$ROW" | jq -r '.stage')" "pre-enqueue"
assert_eq "file round-tripped"             "$(echo "$ROW" | jq -r '.file')" "/abs/path/to/audit.sh"
assert_eq "line_range round-tripped"       "$(echo "$ROW" | jq -r '.line_range')" "10-20"
assert_eq "enqueued_anyway is bool false"  "$(echo "$ROW" | jq -r '.enqueued_anyway')" "false"
assert_eq "enqueued_anyway is JSON boolean" "$(echo "$ROW" | jq -r '.enqueued_anyway | type')" "boolean"
assert_eq "resolver_version round-tripped" "$(echo "$ROW" | jq -r '.resolver_version')" "resolver-v1"
assert_eq "change_context is object"       "$(echo "$ROW" | jq -r '.change_context | type')" "object"
assert_eq "change_context.summary preserved" "$(echo "$ROW" | jq -r '.change_context.summary')" "test change"
assert_eq "dedupe_key is 64-char hex"      "$(echo "$ROW" | jq -r '.dedupe_key' | wc -c | tr -d ' ')" "65"
# Pre-enqueue MUST NOT carry settlement_run_id.
assert_eq "settlement_run_id absent on pre-enqueue" "$(echo "$ROW" | jq -r 'has("settlement_run_id")')" "false"

# =============================================
# Test 3: Branch-provenance trio always emitted as keys
# =============================================
echo ""
echo "Test 3: Branch-provenance trio emitted"
assert_eq "captured_at_branch key present"         "$(echo "$ROW" | jq -r 'has("captured_at_branch")')" "true"
assert_eq "captured_at_sha key present"            "$(echo "$ROW" | jq -r 'has("captured_at_sha")')" "true"
assert_eq "captured_at_merge_base_sha key present" "$(echo "$ROW" | jq -r 'has("captured_at_merge_base_sha")')" "true"

# =============================================
# Test 4: Valid post-verdict append → settlement_run_id present
# =============================================
echo ""
echo "Test 4: Valid post-verdict append"
setup_store
OUTPUT=$(valid_post 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[filtered-claim] Filtered claim"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "stage=post-verdict"                       "$(echo "$ROW" | jq -r '.stage')" "post-verdict"
assert_eq "mode=report-only"                         "$(echo "$ROW" | jq -r '.mode')" "report-only"
assert_eq "enqueued_anyway=true"                     "$(echo "$ROW" | jq -r '.enqueued_anyway')" "true"
assert_eq "settlement_run_id present on post-verdict" "$(echo "$ROW" | jq -r '.settlement_run_id')" "run-xyz-789"

# =============================================
# Test 5: Missing required field rejected
# =============================================
echo ""
echo "Test 5a: Missing --claim-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --work-item "$SLUG" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --claim-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr has [filtered-claim] prefix" "$STDERR" "[filtered-claim]"
assert_contains "stderr names --claim-id"             "$STDERR" "--claim-id"
assert_not_exist "sidecar not created on rejection"  "$SIDECAR"

echo ""
echo "Test 5b: Missing --file rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --file "" 2>&1) || EXIT_CODE=$?
assert_eq "missing --file exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --file" "$STDERR" "--file"

# =============================================
# Test 6: Invalid-enum rejections
# =============================================
echo ""
echo "Test 6a: Invalid --reason rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --reason "bogus" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --reason exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names templated-claim" "$STDERR" "templated-claim"

echo ""
echo "Test 6b: Invalid --mode rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --mode "deferred" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --mode exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names exclude/report-only" "$STDERR" "exclude"

echo ""
echo "Test 6c: Invalid --stage rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --stage "midstream" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --stage exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names pre-enqueue/post-verdict" "$STDERR" "pre-enqueue"

echo ""
echo "Test 6d: Invalid --enqueued-anyway rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --enqueued-anyway "maybe" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --enqueued-anyway exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names true/false" "$STDERR" "true"

echo ""
echo "Test 6e: Malformed --line-range rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --line-range "abc" 2>&1) || EXIT_CODE=$?
assert_eq "malformed --line-range exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names line-range shape" "$STDERR" "line-range"

# =============================================
# Test 7: Stage-conditional settlement_run_id rule (LOAD-BEARING)
# =============================================
echo ""
echo "Test 7a: stage=post-verdict missing --settlement-run-id rejected"
setup_store
EXIT_CODE=0
# Start from a post-verdict-shaped call (mode=report-only, enqueued-anyway=true)
# but omit --settlement-run-id.
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" \
  --claim-id "claim-x" \
  --reason "no-discoverable-target" \
  --mode "report-only" \
  --stage "post-verdict" \
  --file "/abs/path/x.sh" \
  --line-range "1-2" \
  --change-context '{}' \
  --enqueued-anyway "true" \
  --resolver-version "rv1" \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "post-verdict w/o run-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names settlement-run-id is REQUIRED" "$STDERR" "REQUIRED when --stage=post-verdict"
assert_not_exist "sidecar not created" "$SIDECAR"

echo ""
echo "Test 7b: stage=pre-enqueue with --settlement-run-id rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --settlement-run-id "run-leak-123" 2>&1) || EXIT_CODE=$?
assert_eq "pre-enqueue w/ run-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names settlement-run-id MUST be absent" "$STDERR" "MUST be absent when --stage=pre-enqueue"
assert_not_exist "sidecar not created" "$SIDECAR"

# =============================================
# Test 8: Mode↔enqueued_anyway consistency
# =============================================
echo ""
echo "Test 8a: mode=exclude + enqueued-anyway=true rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --mode "exclude" --enqueued-anyway "true" 2>&1) || EXIT_CODE=$?
assert_eq "exclude+enqueued=true exits 1" "$EXIT_CODE" "1"
assert_contains "stderr explains exclude/enqueued mismatch" "$STDERR" "exclude requires --enqueued-anyway=false"

echo ""
echo "Test 8b: mode=report-only + enqueued-anyway=false rejected"
setup_store
EXIT_CODE=0
# Stage post-verdict required for report-only flow (carries run-id).
STDERR=$(valid_post --mode "report-only" --enqueued-anyway "false" 2>&1) || EXIT_CODE=$?
assert_eq "report-only+enqueued=false exits 1" "$EXIT_CODE" "1"
assert_contains "stderr explains report-only/enqueued mismatch" "$STDERR" "report-only requires --enqueued-anyway=true"

# =============================================
# Test 9: change_context must parse as JSON object
# =============================================
echo ""
echo "Test 9a: --change-context non-object (array) rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --change-context '["not", "an", "object"]' 2>&1) || EXIT_CODE=$?
assert_eq "non-object change-context exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names change-context" "$STDERR" "change-context"

echo ""
echo "Test 9b: --change-context malformed JSON rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_pre --change-context '{not valid json' 2>&1) || EXIT_CODE=$?
assert_eq "malformed change-context exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names change-context" "$STDERR" "change-context"

# =============================================
# Test 10: Dedupe key — silent no-op on duplicate call (BOTH stages)
# =============================================
echo ""
echo "Test 10a: dedupe silent no-op (pre-enqueue)"
setup_store
valid_pre > /dev/null 2>&1
valid_pre > /dev/null 2>&1
assert_eq "pre-enqueue sidecar still has one line after duplicate" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

echo ""
echo "Test 10b: dedupe silent no-op (post-verdict)"
setup_store
valid_post > /dev/null 2>&1
valid_post > /dev/null 2>&1
assert_eq "post-verdict sidecar still has one line after duplicate" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# Different settlement_run_id ⇒ different dedupe_key ⇒ both rows kept.
echo ""
echo "Test 10c: distinct run-ids on post-verdict are not deduped"
setup_store
valid_post --settlement-run-id "run-A" > /dev/null 2>&1
valid_post --settlement-run-id "run-B" > /dev/null 2>&1
assert_eq "distinct run-ids → two lines" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# =============================================
# Test 11: --json mode — rejection shape
# =============================================
echo ""
echo "Test 11: --json mode rejection shape"
setup_store
EXIT_CODE=0
STDOUT=$("$SCRIPT" --work-item "$SLUG" --json --kdir "$KNOWLEDGE_DIR" 2>/dev/null) || EXIT_CODE=$?
assert_eq "--json rejection exits 1" "$EXIT_CODE" "1"
ERROR_MSG=$(echo "$STDOUT" | jq -r '.error' 2>/dev/null || echo "")
assert_contains "--json stdout parses; error names [filtered-claim]" "$ERROR_MSG" "[filtered-claim]"

# =============================================
# Test 12: --json mode — success shape
# =============================================
echo ""
echo "Test 12: --json mode success shape"
setup_store
STDOUT=$(valid_pre --json 2>/dev/null)
assert_eq "appended field true"   "$(echo "$STDOUT" | jq -r '.appended')" "true"
assert_eq "stage field reflected" "$(echo "$STDOUT" | jq -r '.stage')" "pre-enqueue"
assert_eq "mode field reflected"  "$(echo "$STDOUT" | jq -r '.mode')" "exclude"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_work/$SLUG/filtered-claims.jsonl"
DK=$(echo "$STDOUT" | jq -r '.dedupe_key')
assert_eq "dedupe_key length 64" "${#DK}" "64"

# =============================================
# Test 13: Atomic-append invariant — two sequential appends yield two complete lines
# =============================================
echo ""
echo "Test 13: Atomic-append invariant (two sequential appends)"
setup_store
valid_pre --claim-id "c-one" > /dev/null 2>&1
valid_pre --claim-id "c-two" > /dev/null 2>&1
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
# Test 14: Nonexistent work item rejected
# =============================================
echo ""
echo "Test 14: Nonexistent work item rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "does-not-exist" \
  --claim-id "c" \
  --reason "templated-claim" \
  --mode "exclude" \
  --stage "pre-enqueue" \
  --file "/a" \
  --line-range "1" \
  --change-context '{}' \
  --enqueued-anyway "false" \
  --resolver-version "r" \
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
