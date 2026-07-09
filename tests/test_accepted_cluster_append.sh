#!/usr/bin/env bash
# test_accepted_cluster_append.sh — Tests for accepted-cluster-append.sh
# Creates a temporary knowledge store and runs the sole-writer against it.
#
# Covers:
#   - Valid append → one row in _evolve/accepted-clusters.jsonl with the
#     SKILL.md §Accepted-cluster artifact format schema
#   - cluster_id matches the independent sha256[:16] derivation the Step 5
#     gate reader uses (drift here breaks gate lookup)
#   - change_types / work_items normalized to sorted lists; member order does
#     not change cluster_id
#   - Missing-required-field rejection (exit 1, [accepted-cluster] prefix)
#   - Invalid --decision enum rejection
#   - Empty-list rejection (whitespace-only / comma-only CSV)
#   - Idempotent no-op: re-invocation with same members → one line on disk
#   - consumed_at_run_id starts null (writer never sets it)
#   - Append-only invariant: two distinct appends → two complete JSON lines
#   - --json mode rejection + success shapes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/accepted-cluster-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SIDECAR="$KNOWLEDGE_DIR/_evolve/accepted-clusters.jsonl"

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
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
}

# A canonical valid-row invocation. Callers override individual flags by
# appending --<flag> <value> after `valid_call`.
valid_call() {
  "$SCRIPT" \
    --target "skills/foo/SKILL.md" \
    --change-types "ceiling-raise" \
    --work-items "wi-alpha,wi-beta,wi-gamma" \
    --decision merge \
    --accepted-at-run-id "run-N" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

# Independent cluster_id derivation — the same algorithm the Step 5 gate
# reader (test_evolve_recurring_failure_gate.sh write_accepted_cluster) uses.
# If the writer drifts from this, the gate can never find the row it wrote.
expected_cluster_id() {
  local target="$1" change_types_csv="$2" work_items_csv="$3"
  python3 - "$target" "$change_types_csv" "$work_items_csv" <<'PY'
import hashlib, sys
target, ct_csv, wi_csv = sys.argv[1:4]
cts = sorted([c.strip() for c in ct_csv.split(",") if c.strip()])
wis = sorted([w.strip() for w in wi_csv.split(",") if w.strip()])
key = target + "|" + "|".join(cts) + "|" + "|".join(wis)
print(hashlib.sha256(key.encode("utf-8")).hexdigest()[:16])
PY
}

echo "=== accepted-cluster-append Tests ==="

# =============================================
# Test 1: --help prints usage naming required flags
# =============================================
echo ""
echo "Test 1: --help prints usage"
OUTPUT=$("$SCRIPT" --help 2>&1)
assert_contains "usage names --target" "$OUTPUT" "--target"
assert_contains "usage names --change-types" "$OUTPUT" "--change-types"
assert_contains "usage names --work-items" "$OUTPUT" "--work-items"
assert_contains "usage names --decision" "$OUTPUT" "--decision"
assert_contains "usage names --accepted-at-run-id" "$OUTPUT" "--accepted-at-run-id"

# =============================================
# Test 2: Valid append → one row with the documented schema
# =============================================
echo ""
echo "Test 2: Valid append"
setup_store
OUTPUT=$(valid_call 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[accepted-cluster] Cluster"
assert_eq "sidecar has one line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
ROW=$(cat "$SIDECAR")
assert_eq "schema_version is declared" "$(echo "$ROW" | jq -r '.schema_version')" "1"
assert_eq "vocabulary_version is declared" "$(echo "$ROW" | jq -r '.vocabulary_version')" "1"
assert_eq "target round-tripped" "$(echo "$ROW" | jq -r '.target')" "skills/foo/SKILL.md"
assert_eq "change_types is a list" "$(echo "$ROW" | jq -r '.change_types | type')" "array"
assert_eq "change_types value" "$(echo "$ROW" | jq -c '.change_types')" '["ceiling-raise"]'
assert_eq "work_items is a list" "$(echo "$ROW" | jq -r '.work_items | type')" "array"
assert_eq "decision round-tripped" "$(echo "$ROW" | jq -r '.accepted_by_maintainer_decision')" "merge"
assert_eq "accepted_at_run_id round-tripped" "$(echo "$ROW" | jq -r '.accepted_at_run_id')" "run-N"
assert_eq "journal_row_refs defaults to empty list" "$(echo "$ROW" | jq -c '.journal_row_refs')" "[]"
assert_eq "accepted_at is non-empty" "$(echo "$ROW" | jq -r '.accepted_at | length > 0')" "true"
assert_eq "cluster_id is 16 hex chars" "$(echo "$ROW" | jq -r '.cluster_id' | wc -c | tr -d ' ')" "17" # 16 + newline

# =============================================
# Test 3: consumed_at_run_id starts null (writer never sets it)
# =============================================
echo ""
echo "Test 3: consumed_at_run_id starts null"
assert_eq "consumed_at_run_id key present" "$(echo "$ROW" | jq -r 'has("consumed_at_run_id")')" "true"
assert_eq "consumed_at_run_id is null" "$(echo "$ROW" | jq -r '.consumed_at_run_id')" "null"

# =============================================
# Test 4: cluster_id matches the gate-reader derivation
# =============================================
echo ""
echo "Test 4: cluster_id matches independent gate-reader derivation"
EXPECTED=$(expected_cluster_id "skills/foo/SKILL.md" "ceiling-raise" "wi-alpha,wi-beta,wi-gamma")
assert_eq "writer cluster_id == reader derivation" "$(echo "$ROW" | jq -r '.cluster_id')" "$EXPECTED"

# =============================================
# Test 5: Member order does not change cluster_id (sorted before hashing)
# =============================================
echo ""
echo "Test 5: Member order does not affect cluster_id"
setup_store
valid_call --work-items "wi-gamma,wi-alpha,wi-beta" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "work_items stored sorted" "$(echo "$ROW" | jq -c '.work_items')" '["wi-alpha","wi-beta","wi-gamma"]'
assert_eq "cluster_id stable under member reorder" "$(echo "$ROW" | jq -r '.cluster_id')" "$EXPECTED"

# =============================================
# Test 6: Missing required field rejected with stderr prefix
# =============================================
echo ""
echo "Test 6a: Missing --target rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --change-types c --work-items w --decision merge \
  --accepted-at-run-id r --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --target exits 1" "$EXIT_CODE" "1"
assert_contains "stderr has [accepted-cluster] prefix" "$STDERR" "[accepted-cluster]"
assert_contains "stderr names --target" "$STDERR" "--target"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

echo ""
echo "Test 6b: Missing --accepted-at-run-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --target t --change-types c --work-items w --decision merge \
  --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --accepted-at-run-id exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --accepted-at-run-id" "$STDERR" "--accepted-at-run-id"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

# =============================================
# Test 7: Invalid --decision enum rejected
# =============================================
echo ""
echo "Test 7: Invalid --decision rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --decision "approve" 2>&1) || EXIT_CODE=$?
assert_eq "invalid --decision exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names merge/edit/split" "$STDERR" "merge"
assert_not_exist "sidecar not created on enum rejection" "$SIDECAR"

# =============================================
# Test 8: Empty-list rejection (whitespace / comma-only CSV)
# =============================================
echo ""
echo "Test 8a: Comma-only --work-items rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --work-items ", ,," 2>&1) || EXIT_CODE=$?
assert_eq "comma-only --work-items exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names work-items requirement" "$STDERR" "work-items"
assert_not_exist "sidecar not created on empty work-items" "$SIDECAR"

echo ""
echo "Test 8b: Comma-only --change-types rejected"
setup_store
EXIT_CODE=0
STDERR=$(valid_call --change-types " , " 2>&1) || EXIT_CODE=$?
assert_eq "comma-only --change-types exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names change-types requirement" "$STDERR" "change-types"
assert_not_exist "sidecar not created on empty change-types" "$SIDECAR"

# =============================================
# Test 9: Idempotent no-op on re-invocation with same cluster_id
# =============================================
echo ""
echo "Test 9: Idempotent no-op"
setup_store
valid_call > /dev/null 2>&1
# Re-run with members in a different order — same set → same cluster_id.
OUTPUT=$(valid_call --work-items "wi-gamma,wi-beta,wi-alpha" 2>&1)
assert_contains "second call reports no-op" "$OUTPUT" "already present"
assert_eq "sidecar still has one line after duplicate call" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# Different work_item set → different cluster_id → new row appended.
valid_call --work-items "wi-alpha,wi-beta,wi-delta" > /dev/null 2>&1
assert_eq "distinct cluster appends a second line" "$(wc -l < "$SIDECAR" | tr -d ' ')" "2"

# =============================================
# Test 10: Append-only invariant — distinct appends yield complete JSON lines
# =============================================
echo ""
echo "Test 10: Append-only invariant (two distinct appends)"
setup_store
valid_call --target "skills/one/SKILL.md" > /dev/null 2>&1
valid_call --target "skills/two/SKILL.md" > /dev/null 2>&1
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
# The writer must never reopen the file for truncation — the first row written
# must survive a second distinct append.
assert_eq "first append preserved after second" \
  "$(head -1 "$SIDECAR" | jq -r '.target')" "skills/one/SKILL.md"

# =============================================
# Test 11: journal_row_refs parsing — ts:slug pairs preserved (colons in ts)
# =============================================
echo ""
echo "Test 11: journal_row_refs parsing"
setup_store
valid_call --journal-row-refs "2026-05-10T00:00:00Z:wi-alpha,2026-05-10T01:00:00Z:wi-beta" > /dev/null 2>&1
ROW=$(cat "$SIDECAR")
assert_eq "two refs parsed" "$(echo "$ROW" | jq -r '.journal_row_refs | length')" "2"
assert_eq "first ref timestamp keeps colons" "$(echo "$ROW" | jq -r '.journal_row_refs[0].timestamp')" "2026-05-10T00:00:00Z"
assert_eq "first ref work_item" "$(echo "$ROW" | jq -r '.journal_row_refs[0].work_item')" "wi-alpha"

# =============================================
# Test 12: --json mode — rejection + success shapes
# =============================================
echo ""
echo "Test 12a: --json mode rejection shape"
setup_store
EXIT_CODE=0
STDOUT=$("$SCRIPT" --json --kdir "$KNOWLEDGE_DIR" 2>/dev/null) || EXIT_CODE=$?
assert_eq "--json rejection exits 1" "$EXIT_CODE" "1"
ERROR_MSG=$(echo "$STDOUT" | jq -r '.error' 2>/dev/null || echo "")
assert_contains "--json error names [accepted-cluster]" "$ERROR_MSG" "[accepted-cluster]"

echo ""
echo "Test 12b: --json mode success shape"
setup_store
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "appended field true" "$(echo "$STDOUT" | jq -r '.appended')" "true"
assert_eq "deduped field false" "$(echo "$STDOUT" | jq -r '.deduped')" "false"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_evolve/accepted-clusters.jsonl"
CID=$(echo "$STDOUT" | jq -r '.cluster_id')
assert_eq "cluster_id length 16" "${#CID}" "16"

echo ""
echo "Test 12c: --json mode dedupe shape (second identical call)"
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "deduped field true on repeat" "$(echo "$STDOUT" | jq -r '.deduped')" "true"
assert_eq "appended field false on repeat" "$(echo "$STDOUT" | jq -r '.appended')" "false"

# =============================================
# Test 13: Nonexistent knowledge store rejected
# =============================================
echo ""
echo "Test 13: Nonexistent knowledge store rejected"
EXIT_CODE=0
STDERR=$("$SCRIPT" --target t --change-types c --work-items w --decision merge \
  --accepted-at-run-id r --kdir "$TEST_DIR/does-not-exist" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent kdir exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names knowledge store" "$STDERR" "knowledge store not found"

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
