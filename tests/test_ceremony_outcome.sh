#!/usr/bin/env bash
# test_ceremony_outcome.sh — Thin ceremony outcome recorder contract tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORDER="$REPO_DIR/scripts/ceremony-outcome-record.sh"
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
  export LORE_KNOWLEDGE_DIR="$KDIR"
}

record() {
  bash "$RECORDER" \
    --ceremony spec-post-plan \
    --advisor codex-plan-review \
    --harness opencode \
    --reason "advisor is not registered for the active harness" \
    "$@"
}

echo "=== Ceremony Outcome Recorder Tests ==="

echo "Test 1: context-free record writes one validated telemetry event"
setup_store
STDOUT=$(record 2>"$TEST_DIR/stderr")
assert_eq "recorder is stdout-silent" "$STDOUT" ""
assert_eq "one row appended" "$(wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' ')" "1"
ROW=$(cat "$KDIR/_scorecards/rows.jsonl")
assert_eq "event discriminator" "$(jq -r '.event_type' <<<"$ROW")" "ceremony-resolution"
assert_eq "telemetry kind" "$(jq -r '.kind' <<<"$ROW")" "telemetry"
assert_eq "needs-decision outcome" "$(jq -r '.outcome' <<<"$ROW")" "needs-decision"
assert_eq "unhandled disposition" "$(jq -r '.disposition' <<<"$ROW")" "unhandled"
assert_eq "context-free source artifacts empty" "$(jq -c '.source_artifact_ids' <<<"$ROW")" "[]"
assert_eq "context-free record has no work item" "$(jq -r 'has("work_item")' <<<"$ROW")" "false"

echo "Test 2: work-item context also writes a ceremony execution-log entry"
setup_store
STDOUT=$(record --work-item outcome-fixture 2>"$TEST_DIR/stderr")
assert_eq "work-item record remains stdout-silent" "$STDOUT" ""
ROW=$(cat "$KDIR/_scorecards/rows.jsonl")
assert_eq "work item stored" "$(jq -r '.work_item' <<<"$ROW")" "outcome-fixture"
assert_eq "work item is the source artifact" "$(jq -c '.source_artifact_ids' <<<"$ROW")" '["outcome-fixture"]'
LOG=$(cat "$KDIR/_work/outcome-fixture/execution-log.md")
assert_contains "execution log attributes ceremony source" "$LOG" "source: ceremony"
assert_contains "execution log marks needs-decision" "$LOG" "Ceremony resolution: needs-decision"
assert_contains "execution log carries corrective action" "$LOG" "Corrective action:"

echo "Test 3: repeated attempts remain distinct point-in-time events"
setup_store
record >/dev/null 2>&1
record >/dev/null 2>&1
assert_eq "two attempts append two rows" "$(wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' ')" "2"

echo "Test 4: scorecard failure warns, still logs the work item, and exits zero"
setup_store
RC=0
OUTPUT=$(record --work-item outcome-fixture --kdir "$TEST_DIR/not-a-store" 2>&1) || RC=$?
assert_eq "scorecard failure is fail-open" "$RC" "0"
assert_contains "scorecard failure warning" "$OUTPUT" "Warning: scorecard outcome write failed; ceremony resolution continues."
assert_contains "independent execution-log write survived" "$(cat "$KDIR/_work/outcome-fixture/execution-log.md")" "source: ceremony"

echo "Test 5: execution-log failure warns after a successful scorecard append"
setup_store
RC=0
OUTPUT=$(record --work-item missing-item 2>&1) || RC=$?
assert_eq "execution-log failure is fail-open" "$RC" "0"
assert_contains "execution-log failure warning" "$OUTPUT" "Warning: work-item execution-log write failed; ceremony resolution continues."
assert_eq "scorecard row still landed" "$(wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' ')" "1"

echo "Test 6: malformed invocation is rejected before either write"
setup_store
RC=0
OUTPUT=$(bash "$RECORDER" --ceremony spec-post-plan 2>&1) || RC=$?
assert_eq "missing inputs exit non-zero" "$RC" "1"
assert_contains "missing advisor named" "$OUTPUT" "--advisor is required"
if [[ -e "$KDIR/_scorecards/rows.jsonl" ]]; then
  echo "  FAIL: invalid invocation wrote a scorecard row"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: invalid invocation wrote no scorecard row"
  PASS=$((PASS + 1))
fi

echo ""
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
