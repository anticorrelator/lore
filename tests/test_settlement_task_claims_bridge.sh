#!/usr/bin/env bash
# test_settlement_task_claims_bridge.sh — Phase 2 typed queue/audit bridge checks

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
EVIDENCE_APPEND="$SCRIPT_DIR/evidence-append.sh"
SETTLEMENT_QUEUE="$SCRIPT_DIR/settlement-queue.sh"
AUDIT_ARTIFACT="$SCRIPT_DIR/audit-artifact.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_count() {
  local label="$1" dir="$2" expected="$3"
  local actual=0
  if [[ -d "$dir" ]]; then
    actual=$(find "$dir" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  fi
  assert_eq "$label" "$actual" "$expected"
}

setup_work_item() {
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
}

row_json() {
  local claim_id="$1"
  python3 - "$claim_id" <<'PYEOF'
import json
import sys

claim_id = sys.argv[1]
print(json.dumps({
    "claim_id": claim_id,
    "tier": "task-evidence",
    "claim": f"Claim {claim_id} is grounded in the fixture.",
    "producer_role": "worker",
    "protocol_slot": "implementation",
    "task_id": "task-2",
    "phase_id": "phase-2",
    "scale": "implementation",
    "file": "scripts/evidence-append.sh",
    "line_range": "1-2",
    "falsifier": "Inspect the referenced script lines.",
    "why_this_work_needs_it": "The settlement queue must audit typed Tier 2 rows.",
    "captured_at_sha": "deadbeef",
    "template_version": "333333333333",
}, sort_keys=True))
PYEOF
}

echo "Test 1: valid Tier 2 append creates one task-claims row and one typed queue item"
KDIR1="$TEST_DIR/kdir-valid"
SLUG1="settlement-valid"
setup_work_item "$KDIR1" "$SLUG1"
row_json "claim-a" | "$EVIDENCE_APPEND" --work-item "$SLUG1" --kdir "$KDIR1" >/dev/null
assert_eq "task-claims has one row" "$(wc -l < "$KDIR1/_work/$SLUG1/task-claims.jsonl" | tr -d ' ')" "1"
QUEUE_DIR1="$KDIR1/_work-queue/settlement-audit"
assert_file_count "queue has one item" "$QUEUE_DIR1" "1"
QUEUE_FILE1=$(find "$QUEUE_DIR1" -maxdepth 1 -type f -name '*.json' | head -1)
assert_eq "queue schema typed" "$(jq -r '.schema_version' "$QUEUE_FILE1")" "settlement-audit.v1"
assert_eq "artifact_type task-claims" "$(jq -r '.artifact_type' "$QUEUE_FILE1")" "task-claims"
assert_eq "work_item carried" "$(jq -r '.work_item' "$QUEUE_FILE1")" "$SLUG1"
assert_eq "claim_ids carried" "$(jq -r '.claim_ids[0]' "$QUEUE_FILE1")" "claim-a"
assert_eq "status pending" "$(jq -r '.status' "$QUEUE_FILE1")" "pending"
assert_eq "source provenance" "$(jq -r '.source' "$QUEUE_FILE1")" "evidence-append"
assert_eq "artifact_path points to task-claims" "$(basename "$(jq -r '.artifact_path' "$QUEUE_FILE1")")" "task-claims.jsonl"
assert_contains "dedupe key includes artifact path" "$(jq -r '.dedupe_key' "$QUEUE_FILE1")" "task-claims.jsonl#claim-a"
assert_eq "queue item is not generic job" "$(jq -r 'has("job")' "$QUEUE_FILE1")" "false"

echo "Test 2: repeated enqueue for same artifact_path+claim_id is idempotent"
"$SETTLEMENT_QUEUE" enqueue --work-item "$SLUG1" --claim-id "claim-a" --kdir "$KDIR1" --json >/dev/null
"$SETTLEMENT_QUEUE" scan --kdir "$KDIR1" --json >/dev/null
assert_file_count "queue still has one item after duplicate enqueue and scan" "$QUEUE_DIR1" "1"

echo "Test 3: invalid Tier 2 input creates no claim and no queue item"
KDIR2="$TEST_DIR/kdir-invalid"
SLUG2="settlement-invalid"
setup_work_item "$KDIR2" "$SLUG2"
set +e
printf '{"claim_id":"bad"}\n' | "$EVIDENCE_APPEND" --work-item "$SLUG2" --kdir "$KDIR2" >/dev/null 2>"$TEST_DIR/invalid.err"
RC_INVALID=$?
set -e
assert_eq "invalid append exits nonzero" "$RC_INVALID" "1"
assert_eq "invalid append creates no task-claims file" "$([[ -f "$KDIR2/_work/$SLUG2/task-claims.jsonl" ]] && echo yes || echo no)" "no"
assert_file_count "invalid append creates no queue item" "$KDIR2/_work-queue/settlement-audit" "0"

echo "Test 4: enqueue failure after validation fail-opens evidence append"
KDIR3="$TEST_DIR/kdir-fail-open"
SLUG3="settlement-fail-open"
setup_work_item "$KDIR3" "$SLUG3"
printf 'not-a-directory\n' > "$KDIR3/_work-queue"
set +e
row_json "claim-fail-open" | "$EVIDENCE_APPEND" --work-item "$SLUG3" --kdir "$KDIR3" >/dev/null 2>"$TEST_DIR/fail-open.err"
RC_FAIL_OPEN=$?
set -e
assert_eq "fail-open append exits zero" "$RC_FAIL_OPEN" "0"
assert_eq "fail-open append kept task-claims row" "$(wc -l < "$KDIR3/_work/$SLUG3/task-claims.jsonl" | tr -d ' ')" "1"
assert_contains "fail-open warning emitted" "$(cat "$TEST_DIR/fail-open.err")" "settlement enqueue failed"

echo "Test 5: task-claims audit bridge targets task-claims rows despite fallback files"
printf 'legacy observation that should not be selected\n' > "$KDIR1/_work/$SLUG1/execution-log.md"
printf '# legacy plan that should not be selected\n' > "$KDIR1/_work/$SLUG1/plan.md"
DRY_JSON=$("$AUDIT_ARTIFACT" "$KDIR1/_work/$SLUG1/task-claims.jsonl" --kdir "$KDIR1" --dry-run --json)
assert_eq "dry-run artifact_type is task-claims" "$(printf '%s' "$DRY_JSON" | jq -r '.artifact_type')" "task-claims"
assert_eq "dry-run carries task claim id" "$(printf '%s' "$DRY_JSON" | jq -r '.claim_payload[0].claim_id')" "claim-a"
assert_eq "dry-run carries task-claims path" "$(basename "$(printf '%s' "$DRY_JSON" | jq -r '.task_claims_path')")" "task-claims.jsonl"

echo "Test 6: nonmatching priority claim ids fail clearly before judging"
PRIORITY_MISSING="$TEST_DIR/priority-missing.json"
printf '["does-not-exist"]\n' > "$PRIORITY_MISSING"
set +e
ERR_MISSING=$("$AUDIT_ARTIFACT" "$KDIR1/_work/$SLUG1/task-claims.jsonl" --kdir "$KDIR1" --priority-claims "$PRIORITY_MISSING" 2>&1 >/dev/null)
RC_MISSING=$?
set -e
assert_eq "nonmatching priority exits nonzero" "$RC_MISSING" "1"
assert_contains "nonmatching priority names filter miss" "$ERR_MISSING" "priority-claims filter yielded 0 claims"

echo "Test 7: process dry-run reports explicit task-claims target"
PROCESS_JSON=$("$SETTLEMENT_QUEUE" process --kdir "$KDIR1" --dry-run --json)
assert_eq "process dry-run sees one item" "$(printf '%s' "$PROCESS_JSON" | jq -r '.processed')" "1"
assert_eq "process dry-run reports true" "$(printf '%s' "$PROCESS_JSON" | jq -r '.dry_run')" "true"
assert_eq "process dry-run item claim id" "$(printf '%s' "$PROCESS_JSON" | jq -r '.items[0].claim_ids[0]')" "claim-a"
assert_eq "process dry-run item artifact path" "$(basename "$(printf '%s' "$PROCESS_JSON" | jq -r '.items[0].artifact_path')")" "task-claims.jsonl"

echo "Test 8: task-claims audit emits calibrated template-tier rows"
GATE_TV=$(bash "$SCRIPT_DIR/template-version.sh" "$SCRIPT_DIR/../agents/correctness-gate.md")
mkdir -p "$KDIR1/_scorecards"
printf '{"correctness-gate:%s":{"calibration_state":"calibrated"}}\n' "$GATE_TV" > "$KDIR1/_scorecards/calibration-state.json"
GATE_TASK="$TEST_DIR/gate-task-claims.json"
cat > "$GATE_TASK" <<'JSON'
{
  "judge": "correctness-gate",
  "judge_template_version": "abc123def456",
  "verdicts": [
    {"claim_id": "claim-a", "verdict": "verified", "evidence": "fixture confirms claim"}
  ]
}
JSON
OUT_AUDIT=$("$AUDIT_ARTIFACT" "$KDIR1/_work/$SLUG1/task-claims.jsonl" --kdir "$KDIR1" --gate-output-file "$GATE_TASK")
assert_contains "task-claims audit appends gate rows" "$OUT_AUDIT" "scorecard rows appended: 3"
TASK_SCORE_ROWS=$(jq -c 'select(.kind=="scored") | {tier,calibration_state,template_id,template_version}' < "$KDIR1/_scorecards/rows.jsonl")
assert_contains "task-claims scored rows are template tier" "$TASK_SCORE_ROWS" '"tier":"template"'
assert_contains "task-claims scored rows calibrated" "$TASK_SCORE_ROWS" '"calibration_state":"calibrated"'
assert_contains "task-claims template version propagated" "$TASK_SCORE_ROWS" '"template_version":"333333333333"'
REGISTRY_TASK=$(jq -c '.entries[] | select(.template_id=="worker" and .template_version=="333333333333")' "$KDIR1/_scorecards/template-registry.json")
assert_contains "task-claims producer template registered" "$REGISTRY_TASK" '"template_id":"worker"'

echo ""
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
