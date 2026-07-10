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
#   - Legacy reconciliation validates v1 shape, inserts only declaration bytes,
#     preserves mode/order/newline layout, and is a byte/stat no-op on rerun
#   - Reconciliation rejects partial/unknown/malformed/non-v1 rows atomically
#   - The unchanged coordinate projection reports evolve-staging gap → ok → gap

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

stat_tuple() {
  python3 - "$1" <<'PY'
import hashlib, os, stat, sys
path = sys.argv[1]
st = os.stat(path)
with open(path, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
print("|".join(str(value) for value in (
    stat.S_IMODE(st.st_mode), st.st_size, st.st_mtime_ns, st.st_ctime_ns,
    st.st_ino, digest,
)))
PY
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
    --append-exact \
    --target "skills/foo/SKILL.md" \
    --change-types "ceiling-raise" \
    --work-items "wi-alpha,wi-beta,wi-gamma" \
    --decision merge \
    --accepted-at-run-id "run-N" \
    --accepted-at "2026-07-10T00:00:00Z" \
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
assert_contains "usage names exact append mode" "$OUTPUT" "--append-exact"
assert_contains "usage names consumption mode" "$OUTPUT" "--consume"
assert_contains "usage names reconciliation mode" "$OUTPUT" "--reconcile-legacy-versions"

# =============================================
# Test 2: Valid append → one row with the documented schema
# =============================================
echo ""
echo "Test 2: Valid append"
setup_store
OUTPUT=$(valid_call 2>&1)
assert_contains "confirmation printed" "$OUTPUT" "[accepted-cluster] append-exact created"
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
STDERR=$("$SCRIPT" --append-exact --change-types c --work-items w --decision merge \
  --accepted-at-run-id r --accepted-at 2026-07-10T00:00:00Z --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --target exits 1" "$EXIT_CODE" "1"
assert_contains "stderr has [accepted-cluster] prefix" "$STDERR" "[accepted-cluster]"
assert_contains "stderr names --target" "$STDERR" "--target"
assert_not_exist "sidecar not created on rejection" "$SIDECAR"

echo ""
echo "Test 6b: Missing --accepted-at-run-id rejected"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --append-exact --target t --change-types c --work-items w --decision merge \
  --accepted-at 2026-07-10T00:00:00Z --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
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
assert_contains "second call reports no-op" "$OUTPUT" "append-exact reused"
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
assert_eq "created status returned" "$(echo "$STDOUT" | jq -r '.status')" "created"
assert_contains "path points to sidecar" "$(echo "$STDOUT" | jq -r '.path')" "_evolve/accepted-clusters.jsonl"
CID=$(echo "$STDOUT" | jq -r '.cluster_id')
assert_eq "cluster_id length 16" "${#CID}" "16"

echo ""
echo "Test 12c: --json mode dedupe shape (second identical call)"
STDOUT=$(valid_call --json 2>/dev/null)
assert_eq "appended field false on repeat" "$(echo "$STDOUT" | jq -r '.appended')" "false"
assert_eq "reused status returned" "$(echo "$STDOUT" | jq -r '.status')" "reused"

# =============================================
# Test 13: Nonexistent knowledge store rejected
# =============================================
echo ""
echo "Test 13: Nonexistent knowledge store rejected"
EXIT_CODE=0
STDERR=$("$SCRIPT" --append-exact --target t --change-types c --work-items w --decision merge \
  --accepted-at-run-id r --accepted-at 2026-07-10T00:00:00Z --kdir "$TEST_DIR/does-not-exist" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent kdir exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names knowledge store" "$STDERR" "knowledge store not found"

# =============================================
# Test 14: Reconciliation preserves bytes outside the declaration prefix,
# file mode, row order, and newline layout; rerun is a true stat no-op.
# The unchanged coordinate projection is the positive and negative oracle.
# =============================================
echo ""
echo "Test 14: Legacy reconciliation is byte-preserving and idempotent"
setup_store
mkdir -p "$KNOWLEDGE_DIR/_evolve"

TARGET_ONE="skills/legacy-one/SKILL.md"
TARGET_TWO="skills/versioned-two/SKILL.md"
TARGET_THREE="skills/legacy-three/SKILL.md"
CID_ONE=$(expected_cluster_id "$TARGET_ONE" "evidence-gap" "wi-a,wi-b")
CID_TWO=$(expected_cluster_id "$TARGET_TWO" "ceiling-raise" "wi-c")
CID_THREE=$(expected_cluster_id "$TARGET_THREE" "validation-gap" "wi-d")

LEGACY_ONE="{\"cluster_id\":\"$CID_ONE\", \"target\":\"$TARGET_ONE\",\"change_types\":[\"evidence-gap\"],\"work_items\":[\"wi-a\",\"wi-b\"],\"journal_row_refs\":[{\"timestamp\":\"2026-07-01T00:00:00Z\",\"work_item\":\"wi-a\"}],\"accepted_at\":\"2026-07-02T00:00:00Z\",\"accepted_at_run_id\":\"run-1\",\"accepted_by_maintainer_decision\":\"merge\",\"consumed_at_run_id\":null}"
VERSIONED_TWO="  {\"schema_version\":\"1\",\"vocabulary_version\":\"1\",\"cluster_id\":\"$CID_TWO\",\"target\":\"$TARGET_TWO\",\"change_types\":[\"ceiling-raise\"],\"work_items\":[\"wi-c\"],\"journal_row_refs\":[],\"accepted_at\":\"2026-07-03T00:00:00Z\",\"accepted_at_run_id\":\"run-2\",\"accepted_by_maintainer_decision\":\"split\",\"consumed_at_run_id\":\"run-3\"}"
LEGACY_THREE="{\"cluster_id\":\"$CID_THREE\",\"target\":\"$TARGET_THREE\",\"change_types\":[\"validation-gap\"],\"work_items\":[\"wi-d\"],\"journal_row_refs\":[],\"accepted_at\":\"2026-07-04T00:00:00Z\",\"accepted_at_run_id\":\"run-4\",\"accepted_by_maintainer_decision\":\"edit\",\"consumed_at_run_id\":null}"

# Deliberately omit a final newline: the rewrite must retain that layout.
printf '%s\n%s' "$LEGACY_ONE" "$VERSIONED_TWO" > "$SIDECAR"
chmod 640 "$SIDECAR"
EXPECTED_ONE="{\"schema_version\":\"1\",\"vocabulary_version\":\"1\",${LEGACY_ONE#\{}"
EXPECTED_FILE="$TEST_DIR/expected-reconciled.jsonl"
printf '%s\n%s' "$EXPECTED_ONE" "$VERSIONED_TWO" > "$EXPECTED_FILE"

BEFORE_STATUS="$TEST_DIR/reconcile-before.json"
bash "$SCRIPT_DIR/coordinate-status.sh" --kdir "$KNOWLEDGE_DIR" --json > "$BEFORE_STATUS"
assert_eq "undeclared legacy row is a projection gap" \
  "gap" "$(jq -r '.source_manifest[] | select(.source_id=="evolve-staging") | .read_status' "$BEFORE_STATUS")"
assert_eq "undeclared legacy row emits one evolve source-gap" \
  "1" "$(jq -r '[.buckets.reconcile[] | select(.source_id=="evolve-staging" and .kind=="source-gap")] | length' "$BEFORE_STATUS")"

RECONCILE_JSON=$("$SCRIPT" --reconcile-legacy-versions --kdir "$KNOWLEDGE_DIR" --json)
assert_eq "reconciliation reports one updated row" "1" "$(echo "$RECONCILE_JSON" | jq -r '.updated')"
assert_eq "reconciliation reports one skipped v1 row" "1" "$(echo "$RECONCILE_JSON" | jq -r '.skipped')"
assert_eq "reconciliation reports total rows" "2" "$(echo "$RECONCILE_JSON" | jq -r '.total')"
assert_eq "reconciliation reports sidecar path" "_evolve/accepted-clusters.jsonl" "$(echo "$RECONCILE_JSON" | jq -r '.path')"
assert_eq "only the exact declaration prefix was inserted" \
  "same" "$(cmp -s "$SIDECAR" "$EXPECTED_FILE" && echo same || echo different)"
assert_eq "source mode is preserved across atomic replacement" \
  "416" "$(python3 -c 'import os,stat,sys; print(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$SIDECAR")"
assert_eq "unconsumed lifecycle marker remains null" \
  "null" "$(sed -n '1p' "$SIDECAR" | jq -r '.consumed_at_run_id')"
assert_eq "consumed lifecycle marker remains populated" \
  "run-3" "$(sed -n '2p' "$SIDECAR" | jq -r '.consumed_at_run_id')"

AFTER_STATUS="$TEST_DIR/reconcile-after.json"
bash "$SCRIPT_DIR/coordinate-status.sh" --kdir "$KNOWLEDGE_DIR" --json > "$AFTER_STATUS"
assert_eq "fully reconciled evolve staging is ok" \
  "ok" "$(jq -r '.source_manifest[] | select(.source_id=="evolve-staging") | .read_status' "$AFTER_STATUS")"
assert_eq "fully reconciled evolve staging declares schema v1" \
  "1" "$(jq -r '.source_manifest[] | select(.source_id=="evolve-staging") | .schema_version' "$AFTER_STATUS")"
assert_eq "fully reconciled evolve staging declares vocabulary v1" \
  "1" "$(jq -r '.source_manifest[] | select(.source_id=="evolve-staging") | .vocabulary_version' "$AFTER_STATUS")"
assert_eq "fully reconciled evolve staging has no source-gap" \
  "0" "$(jq -r '[.buckets.reconcile[] | select(.source_id=="evolve-staging" and .kind=="source-gap")] | length' "$AFTER_STATUS")"

NOOP_BEFORE=$(stat_tuple "$SIDECAR")
NOOP_JSON=$("$SCRIPT" --reconcile-legacy-versions --kdir "$KNOWLEDGE_DIR" --json)
NOOP_AFTER=$(stat_tuple "$SIDECAR")
assert_eq "second reconciliation reports zero updates" "0" "$(echo "$NOOP_JSON" | jq -r '.updated')"
assert_eq "second reconciliation skips both v1 rows" "2" "$(echo "$NOOP_JSON" | jq -r '.skipped')"
assert_eq "second reconciliation preserves bytes and stat tuple" "$NOOP_BEFORE" "$NOOP_AFTER"

printf '\n%s\n' "$LEGACY_THREE" >> "$SIDECAR"
NEGATIVE_STATUS="$TEST_DIR/reconcile-negative.json"
bash "$SCRIPT_DIR/coordinate-status.sh" --kdir "$KNOWLEDGE_DIR" --json > "$NEGATIVE_STATUS"
assert_eq "new undeclared sibling restores the projection gap" \
  "gap" "$(jq -r '.source_manifest[] | select(.source_id=="evolve-staging") | .read_status' "$NEGATIVE_STATUS")"
assert_eq "valid reconciled siblings remain visible through the strict reader" \
  "1" "$(jq -r '[.buckets.act_now[] | select(.source_id=="evolve-staging" and .observed_facts.cluster_id?=="'"$CID_ONE"'")] | length' "$NEGATIVE_STATUS")"

# =============================================
# Test 15: Reconciliation validates the complete file before replacement.
# =============================================
echo ""
echo "Test 15: Reconciliation rejects incompatible rows atomically"

assert_atomic_rejection() {
  local label="$1" bad_row="$2"
  printf '%s\n%s\n' "$LEGACY_ONE" "$bad_row" > "$SIDECAR"
  chmod 640 "$SIDECAR"
  local before after exit_code output
  before=$(stat_tuple "$SIDECAR")
  exit_code=0
  output=$("$SCRIPT" --reconcile-legacy-versions --kdir "$KNOWLEDGE_DIR" 2>&1) || exit_code=$?
  after=$(stat_tuple "$SIDECAR")
  assert_eq "$label exits 1" "1" "$exit_code"
  assert_contains "$label names the second row" "$output" "line 2"
  assert_eq "$label leaves bytes and stat unchanged" "$before" "$after"
}

PARTIAL_ROW="{\"schema_version\":\"1\",${LEGACY_THREE#\{}"
UNKNOWN_ROW="{\"schema_version\":\"9\",\"vocabulary_version\":\"1\",${LEGACY_THREE#\{}"
BAD_ID_ROW="${LEGACY_THREE/$CID_THREE/0000000000000000}"
assert_atomic_rejection "partial declaration" "$PARTIAL_ROW"
assert_atomic_rejection "unknown declaration" "$UNKNOWN_ROW"
assert_atomic_rejection "malformed JSON" '{not-json'
assert_atomic_rejection "non-v1 identity" "$BAD_ID_ROW"

EXIT_CODE=0
OUTPUT=$("$SCRIPT" --reconcile-legacy-versions --target forbidden --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "reconciliation rejects append-only flags" "1" "$EXIT_CODE"
assert_contains "mutually exclusive rejection names append flag" "$OUTPUT" "--target"

# =============================================
# Test 16: Same-id semantic conflict and validated consumption lifecycle.
# =============================================
echo ""
echo "Test 16: Exact conflict and consumption transitions"
setup_store
valid_call > /dev/null
CID=$(jq -r .cluster_id "$SIDECAR")
BEFORE=$(stat_tuple "$SIDECAR")
EXIT_CODE=0
OUTPUT=$(valid_call --accepted-at-run-id different-run 2>&1) || EXIT_CODE=$?
assert_eq "same-id changed semantics exits 1" "1" "$EXIT_CODE"
assert_contains "same-id conflict is loud" "$OUTPUT" "different semantics"
assert_eq "conflict leaves sidecar unchanged" "$BEFORE" "$(stat_tuple "$SIDECAR")"

CONSUME_JSON=$("$SCRIPT" --consume --cluster-id "$CID" --consumed-at-run-id consume-1 --kdir "$KNOWLEDGE_DIR" --json)
assert_eq "null to run transition updates" "updated" "$(echo "$CONSUME_JSON" | jq -r .status)"
assert_eq "consumption persisted" "consume-1" "$(jq -r .consumed_at_run_id "$SIDECAR")"
CONSUME_REPLAY=$("$SCRIPT" --consume --cluster-id "$CID" --consumed-at-run-id consume-1 --kdir "$KNOWLEDGE_DIR" --json)
assert_eq "same-run consumption reuses" "reused" "$(echo "$CONSUME_REPLAY" | jq -r .status)"
BEFORE=$(stat_tuple "$SIDECAR")
EXIT_CODE=0
OUTPUT=$("$SCRIPT" --consume --cluster-id "$CID" --consumed-at-run-id consume-2 --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "different-run consumption conflicts" "1" "$EXIT_CODE"
assert_contains "different-run conflict names owner" "$OUTPUT" "consume-1"
assert_eq "different-run conflict is atomic" "$BEFORE" "$(stat_tuple "$SIDECAR")"

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
