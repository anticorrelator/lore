#!/usr/bin/env bash
# test_consumption_contradiction_append.sh — Tests for consumption-contradiction-append.sh
# Creates a temporary knowledge store and runs the writer against it.
#
# Covers:
#   - Valid append → one line in _work/<slug>/consumption-contradictions.jsonl
#   - Missing-required-field rejection (exit 1, [consumption-contradiction] prefix)
#   - Invalid-enum rejection (--source, --status, --severity-hint, --line-range)
#   - dedupe_key silent no-op: two identical calls → one line on disk
#   - --json mode rejection shape (valid JSON {"error": ...} on stdout, exit 1)
#   - --json mode success shape (appended:true on stdout)
#   - Branch-provenance trio always emitted on every row
#   - Grounded-or-nothing: missing file/line_range/exact_snippet rejects
#   - Omit-when-empty fields absent from row when flag not supplied
#   - Atomic-append invariant: two sequential valid appends → two complete lines

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/consumption-contradiction-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/consumption-contradictions.jsonl"

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

# A canonical valid-row invocation. Callers can override individual flags by
# appending --<flag> <value> after `valid_call`.
valid_call() {
  "$SCRIPT" \
    --work-item "$SLUG" \
    --source worker \
    --producer-role impl-worker \
    --protocol-slot implement-step-3 \
    --cycle-id "cycle-$(date +%s)" \
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

echo "=== consumption-contradiction-append Tests ==="

# =============================================
# Test 1: --help prints usage naming required flags
# =============================================
echo ""
echo "Test 1: --help prints usage"
OUTPUT=$("$SCRIPT" --help 2>&1)
assert_contains "usage names --work-item" "$OUTPUT" "--work-item"
assert_contains "usage names --source" "$OUTPUT" "--source"
assert_contains "usage names --claim-id" "$OUTPUT" "--claim-id"
assert_contains "usage names --file" "$OUTPUT" "--file"
assert_contains "usage names --line-range" "$OUTPUT" "--line-range"
assert_contains "usage names --exact-snippet" "$OUTPUT" "--exact-snippet"
assert_contains "usage names --falsifier" "$OUTPUT" "--falsifier"

# =============================================
# Test 2: Valid append → one line in sidecar
# =============================================
echo ""
echo "Test 2: Valid append"
setup_store
OUTPUT=$(valid_call 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[consumption-contradiction] Contradiction"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "verdict_source set" "$(echo "$ROW" | jq -r '.verdict_source')" "consumer-contradiction-channel"
assert_eq "work_item round-tripped" "$(echo "$ROW" | jq -r '.work_item')" "$SLUG"
assert_eq "source round-tripped" "$(echo "$ROW" | jq -r '.source')" "worker"
assert_eq "status defaults to pending" "$(echo "$ROW" | jq -r '.status')" "pending"
assert_eq "claim_payload.file round-tripped" "$(echo "$ROW" | jq -r '.claim_payload.file')" "/abs/path/to/audit.sh"
assert_eq "claim_payload.line_range round-tripped" "$(echo "$ROW" | jq -r '.claim_payload.line_range')" "10-20"
assert_eq "claim_payload.exact_snippet round-tripped" "$(echo "$ROW" | jq -r '.claim_payload.exact_snippet')" "foo bar baz"
assert_eq "prefetched_commons_entry.knowledge_path" "$(echo "$ROW" | jq -r '.prefetched_commons_entry.knowledge_path')" "architecture/audit-pipeline/contract"
assert_eq "prefetched_commons_entry.heading stored verbatim" "$(echo "$ROW" | jq -r '.prefetched_commons_entry.heading')" "Input contract"
assert_eq "dedupe_key is 64-char hex" "$(echo "$ROW" | jq -r '.dedupe_key' | wc -c | tr -d ' ')" "65" # 64 + newline
assert_eq "contradiction_id has ctr- prefix" "$(echo "$ROW" | jq -r '.contradiction_id' | cut -c1-4)" "ctr-"

# =============================================
# Test 3: Branch-provenance trio always emitted as keys
# =============================================
echo ""
echo "Test 3: Branch-provenance trio emitted"
# All three keys must be present (string OR null); the trio is "always-emit-with-null-sentinel".
assert_eq "captured_at_branch key present" "$(echo "$ROW" | jq -r 'has("captured_at_branch")')" "true"
assert_eq "captured_at_sha key present" "$(echo "$ROW" | jq -r 'has("captured_at_sha")')" "true"
assert_eq "captured_at_merge_base_sha key present" "$(echo "$ROW" | jq -r 'has("captured_at_merge_base_sha")')" "true"

# =============================================
# Test 4: Missing required field rejected with stderr prefix
# =============================================
echo ""
echo "Test 4: Missing --source rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --work-item "$SLUG" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --source exits 1" "$EXIT_CODE" "1"
assert_contains "stderr has [consumption-contradiction] prefix" "$STDERR" "[consumption-contradiction]"
assert_contains "stderr names --source" "$STDERR" "--source"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

echo ""
echo "Test 4b: Missing --file (grounded-or-nothing) rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "$SLUG" --source worker \
  --producer-role r --protocol-slot s --cycle-id c \
  --knowledge-path k --contradiction-rationale r --claim-id c \
  --claim-text t --line-range 1 --exact-snippet e --falsifier f \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --file exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --file" "$STDERR" "--file"
assert_not_exist "sidecar not created on grounded-or-nothing rejection" "$SIDECAR"

# =============================================
# Test 5: Invalid-enum rejections
# =============================================
echo ""
echo "Test 5a: Invalid --source rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --source "bogus" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --source exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names worker/researcher/spec-lead/implement-lead" "$STDERR" "worker"

echo ""
echo "Test 5b: Invalid --status rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --status "maybe" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --status exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names pending/accepted/declined/remediated" "$STDERR" "pending"

echo ""
echo "Test 5c: Invalid --severity-hint rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --severity-hint "critical" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --severity-hint exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names low/medium/high" "$STDERR" "low"

echo ""
echo "Test 5d: Malformed --line-range rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --line-range "abc" 2>&1) || EXIT_CODE=$?
assert_eq "malformed --line-range exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names line-range shape" "$STDERR" "line-range"

# =============================================
# Test 6: dedupe_key silent no-op on duplicate call
# =============================================
echo ""
echo "Test 6: dedupe silent no-op"
setup_store
valid_call > /dev/null 2>&1
valid_call > /dev/null 2>&1
assert_eq "sidecar still has one line after duplicate call" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

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
assert_contains "--json stdout parses; error names [consumption-contradiction]" "$ERROR_MSG" "[consumption-contradiction]"

# =============================================
# Test 8: --json mode — success shape
# =============================================
echo ""
echo "Test 8: --json mode success shape"
setup_store
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "appended field true" "$(echo "$STDOUT" | jq -r '.appended')" "true"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_work/$SLUG/consumption-contradictions.jsonl"
assert_contains "contradiction_id has ctr- prefix" "$(echo "$STDOUT" | jq -r '.contradiction_id')" "ctr-"
# dedupe_key is 64 hex chars
DK=$(echo "$STDOUT" | jq -r '.dedupe_key')
assert_eq "dedupe_key length 64" "${#DK}" "64"

# =============================================
# Test 9: Omit-when-empty fields absent when flag not supplied
# =============================================
echo ""
echo "Test 9: Omit-when-empty fields"
setup_store
valid_call > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "template_version absent when not supplied" "$(echo "$ROW" | jq -r 'has("template_version")')" "false"
assert_eq "claim_payload.symbol_anchor absent when not supplied" "$(echo "$ROW" | jq -r '.claim_payload | has("symbol_anchor")')" "false"
assert_eq "claim_payload.severity_hint absent when not supplied" "$(echo "$ROW" | jq -r '.claim_payload | has("severity_hint")')" "false"
assert_eq "claim_payload.normalized_snippet_hash absent when not supplied" "$(echo "$ROW" | jq -r '.claim_payload | has("normalized_snippet_hash")')" "false"

# Supplying those flags should populate them.
setup_store
valid_call \
  --template-version "abc123" \
  --symbol-anchor "func foo()" \
  --severity-hint "high" \
  --normalized-snippet-hash "deadbeef" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "template_version present when supplied" "$(echo "$ROW" | jq -r '.template_version')" "abc123"
assert_eq "symbol_anchor present when supplied" "$(echo "$ROW" | jq -r '.claim_payload.symbol_anchor')" "func foo()"
assert_eq "severity_hint present when supplied" "$(echo "$ROW" | jq -r '.claim_payload.severity_hint')" "high"
assert_eq "normalized_snippet_hash present when supplied" "$(echo "$ROW" | jq -r '.claim_payload.normalized_snippet_hash')" "deadbeef"

# =============================================
# Test 10: Atomic-append invariant — two sequential appends yield two complete lines
# =============================================
echo ""
echo "Test 10: Atomic-append invariant (two sequential appends)"
setup_store
valid_call --claim-id "c1" --file "/abs/path/one.sh" > /dev/null 2>&1
valid_call --claim-id "c2" --file "/abs/path/two.sh" > /dev/null 2>&1
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
# Test 11: Nonexistent work item rejected
# =============================================
echo ""
echo "Test 11: Nonexistent work item rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" \
  --work-item "does-not-exist" \
  --source worker \
  --producer-role r --protocol-slot s --cycle-id c \
  --knowledge-path k --contradiction-rationale r --claim-id c \
  --claim-text t --file /a --line-range 1 --exact-snippet e --falsifier f \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent work item exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names work item" "$STDERR" "work item not found"

# =============================================
# Test 12: Heading normalization in dedupe_key — different casing still dedupes
# =============================================
echo ""
echo "Test 12: Heading dedupe normalized (lowercase + whitespace-collapse)"
setup_store
valid_call --heading "Input Contract" > /dev/null 2>&1
valid_call --heading "  input   contract  " > /dev/null 2>&1
assert_eq "heading-normalized duplicate dedupes to one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
# Stored heading is the FIRST-written verbatim value (verbatim preservation).
ROW=$(cat "$SIDECAR")
assert_eq "stored heading is verbatim first-write value" "$(echo "$ROW" | jq -r '.prefetched_commons_entry.heading')" "Input Contract"

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
