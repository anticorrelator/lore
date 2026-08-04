#!/usr/bin/env bash
# test_ceremony_handle.sh — Ceremony handled-transition front contract tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDLE="$REPO_DIR/scripts/ceremony-handle.sh"
RECORDER="$REPO_DIR/scripts/ceremony-outcome-record.sh"
CLI="$REPO_DIR/cli/lore"
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" actual="$2" expected="$3"
  if grep -qF -- "$expected" <<<"$actual"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected output to contain '$expected'"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/_work/outcome-fixture"
  printf '%s\n' '{"format_version":2}' > "$KDIR/_manifest.json"
  cat > "$KDIR/_work/outcome-fixture/_meta.json" <<'JSON'
{"slug":"outcome-fixture","title":"Outcome fixture","status":"active"}
JSON
}

record_outcome() {
  bash "$RECORDER" \
    --ceremony spec-post-plan \
    --advisor codex-plan-review \
    --harness opencode \
    --reason "advisor is not registered for the active harness" \
    --kdir "$KDIR" "$@" >/dev/null 2>&1
  jq -r 'select(.event_type == "ceremony-resolution") | .outcome_id' "$KDIR/_scorecards/rows.jsonl" | tail -n 1
}

rows_count() {
  wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' '
}

echo "=== Ceremony Handle Front Tests ==="

echo "Test 1: an outcome carries a correlation identity the front can name"
setup_store
OUTCOME_ID=$(record_outcome)
if [[ -n "$OUTCOME_ID" && "$OUTCOME_ID" != "null" ]]; then
  echo "  PASS: recorded outcome carries an outcome_id"
  PASS=$((PASS + 1))
else
  echo "  FAIL: recorded outcome carries no outcome_id"
  FAIL=$((FAIL + 1))
fi

echo "Test 2: handling appends one correlated transition through the sole writer"
OUTPUT=$(bash "$HANDLE" --outcome-id "$OUTCOME_ID" --action adjudicated --handled-by coordinate --kdir "$KDIR")
assert_eq "handling appends exactly one row" "$(rows_count)" "2"
assert_contains "human output names the handled outcome" "$OUTPUT" "Handled outcome $OUTCOME_ID"
TRANSITION=$(tail -n 1 "$KDIR/_scorecards/rows.jsonl")
assert_eq "transition is a disposition record" "$(jq -r '.record_type' <<<"$TRANSITION")" "disposition"
assert_eq "transition is handled" "$(jq -r '.disposition' <<<"$TRANSITION")" "handled"
assert_eq "transition correlates to the outcome" "$(jq -r '.outcome_id' <<<"$TRANSITION")" "$OUTCOME_ID"
assert_eq "transition records the action" "$(jq -r '.action' <<<"$TRANSITION")" "adjudicated"
assert_eq "transition records the actor" "$(jq -r '.handled_by' <<<"$TRANSITION")" "coordinate"
assert_eq "transition carries a handling timestamp" "$(jq -r '(.handled_at // "") != ""' <<<"$TRANSITION")" "true"
assert_eq "transition copies the outcome's ceremony" "$(jq -r '.ceremony' <<<"$TRANSITION")" "spec-post-plan"
assert_eq "transition restates no outcome evidence" \
  "$(jq -r 'has("reason") or has("corrective_action") or has("harness")' <<<"$TRANSITION")" "false"

echo "Test 3: repeating the same handling is a no-op"
OUTPUT=$(bash "$HANDLE" --outcome-id "$OUTCOME_ID" --action adjudicated --handled-by coordinate --kdir "$KDIR")
assert_eq "identical retry appends nothing" "$(rows_count)" "2"
assert_contains "identical retry says so" "$OUTPUT" "already handled"

echo "Test 4: a different answer to the same outcome is refused"
for conflict in "--action skipped --handled-by coordinate" "--action adjudicated --handled-by someone-else"; do
  RC=0
  # shellcheck disable=SC2086
  OUTPUT=$(bash "$HANDLE" --outcome-id "$OUTCOME_ID" $conflict --kdir "$KDIR" 2>&1) || RC=$?
  assert_eq "conflicting handling exits non-zero ($conflict)" "$RC" "1"
  assert_contains "conflict names the recorded transition ($conflict)" "$OUTPUT" "already carries a different handled transition"
done
assert_eq "refused conflicts appended nothing" "$(rows_count)" "2"

echo "Test 5: work-item linkage travels from the outcome to the transition"
setup_store
LINKED_ID=$(record_outcome --work-item outcome-fixture)
bash "$HANDLE" --outcome-id "$LINKED_ID" --action deferred --handled-by coordinate --kdir "$KDIR" >/dev/null
LINKED_TRANSITION=$(tail -n 1 "$KDIR/_scorecards/rows.jsonl")
assert_eq "transition carries the outcome's work item" "$(jq -r '.work_item' <<<"$LINKED_TRANSITION")" "outcome-fixture"
assert_eq "transition source artifacts stay work-item aligned" \
  "$(jq -c '.source_artifact_ids' <<<"$LINKED_TRANSITION")" '["outcome-fixture"]'

echo "Test 6: malformed and uncorrelated invocations are refused before any write"
setup_store
OUTCOME_ID=$(record_outcome)
BEFORE=$(rows_count)
for invocation in \
  "--outcome-id $OUTCOME_ID --action adjudicate --handled-by coordinate" \
  "--outcome-id $OUTCOME_ID --action adjudicated" \
  "--action adjudicated --handled-by coordinate" \
  "--outcome-id ceremony-does-not-exist --action adjudicated --handled-by coordinate"; do
  RC=0
  # shellcheck disable=SC2086
  OUTPUT=$(bash "$HANDLE" $invocation --kdir "$KDIR" 2>&1) || RC=$?
  assert_eq "refused: $invocation" "$RC" "1"
done
assert_eq "refusals wrote no row" "$(rows_count)" "$BEFORE"

echo "Test 7: --json reports the append result for machine callers"
JSON_OUT=$(bash "$HANDLE" --outcome-id "$OUTCOME_ID" --action skipped --handled-by coordinate --kdir "$KDIR" --json)
assert_eq "json reports the append" "$(jq -r '.appended' <<<"$JSON_OUT")" "true"
JSON_RETRY=$(bash "$HANDLE" --outcome-id "$OUTCOME_ID" --action skipped --handled-by coordinate --kdir "$KDIR" --json)
assert_eq "json retry reports idempotence" "$(jq -r '.idempotent' <<<"$JSON_RETRY")" "true"
RC=0
JSON_ERR=$(bash "$HANDLE" --outcome-id ceremony-missing --action skipped --handled-by coordinate --kdir "$KDIR" --json) || RC=$?
assert_eq "json refusal exits non-zero" "$RC" "1"
assert_eq "json refusal carries an error payload" "$(jq -r '(.error // "") != ""' <<<"$JSON_ERR")" "true"

echo "Test 8: the CLI surfaces the verb"
assert_contains "ceremony help lists handle" "$(bash "$CLI" ceremony --help 2>&1)" "handle"
RC=0
OUTPUT=$(bash "$CLI" ceremony --harness codex handle --outcome-id x --action adjudicated --handled-by y 2>&1) || RC=$?
assert_eq "harness selector on handle is refused" "$RC" "1"
assert_contains "refusal explains the outcome already carries the harness" "$OUTPUT" "takes no --harness"

echo ""
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
