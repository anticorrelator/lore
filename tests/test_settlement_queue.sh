#!/usr/bin/env bash
# test_settlement_queue.sh — settlement queue/processor conservation tests

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"
EVIDENCE="$SCRIPTS_DIR/evidence-append.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

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

assert_json_eq() {
  local label="$1" json="$2" expr="$3" expected="$4"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$expr")
  assert_eq "$label" "$actual" "$expected"
}

write_settings() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

setup_kdir() {
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
}

setup_plan_assertions_fixture() {
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
  cat > "$kdir/_work/$slug/plan.md" <<'PLANEOF'
# settlement smoke fixture

## Goal
Synthetic fixture for settlement executor smoke coverage.

## Investigations

### Verified path
**Question:** Does the executor return a real audit verdict?
Template-version: settlement-smoke-v1
**Findings:**
- The executor returns a real audit verdict.

**Assertions:**
- claim: settlement executor can route a verified audit fixture
  file: scripts/settlement-processor.py
  line_range: "1-1"
  exact_snippet: "#!/usr/bin/env python3"
  normalized_snippet_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  falsifier: Run the settlement executor smoke test and inspect run.verdict
  significance: high
PLANEOF
}

row_json() {
  local claim_id="$1" task_id="${2:-task-1}"
  # Claim and falsifier are intentionally >= 40 chars so the path-to-commons
  # pre-enqueue filter (D3) does not classify the row as templated-claim
  # / templated-falsifier and exclude it from the candidate set. Tests that
  # want to exercise the templated-detection path build a row inline with
  # a short claim or falsifier.
  jq -nc --arg cid "$claim_id" --arg task "$task_id" '{
    claim_id: $cid,
    tier: "task-evidence",
    claim: ("settlement processor durable trigger fixture row for claim " + $cid),
    producer_role: "worker",
    protocol_slot: "implementation",
    task_id: $task,
    phase_id: "1",
    scale: "implementation",
    file: "scripts/settlement-processor.py",
    line_range: "1-20",
    falsifier: "Run settlement queue tests and inspect durable run records",
    why_this_work_needs_it: "The settlement processor depends on validated Tier 2 rows as durable triggers",
    captured_at_sha: "test-sha",
    change_context: {
      diff_ref: "test-sha",
      changed_files: ["scripts/settlement-processor.py"],
      summary: "settlement queue fixture row used to exercise durable trigger processing"
    }
  }'
}

SUCCESS_EXEC="$TEST_DIR/success-exec.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$SUCCESS_EXEC"
chmod +x "$SUCCESS_EXEC"

echo "=== Settlement Queue Tests ==="
echo ""

echo "Test 0: status reports without creating settlement state"
KDIR0="$TEST_DIR/kdir0"
SETTINGS0="$TEST_DIR/settings0.json"
mkdir -p "$KDIR0"
write_settings "$SETTINGS0" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}}}'
STATUS0=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS0" bash "$QUEUE" status --kdir "$KDIR0" --json)
assert_json_eq "status returns ok on empty state" "$STATUS0" '.ok' "true"
if [[ ! -e "$KDIR0/_settlement" ]]; then
  echo "  PASS: status did not create _settlement"
  PASS=$((PASS + 1))
else
  echo "  FAIL: status created _settlement"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Test 1: evidence append enqueue is fail-open/idempotent and scan conserves unique items"
KDIR="$TEST_DIR/kdir1"
SETTINGS="$TEST_DIR/settings1.json"
setup_kdir "$KDIR" "wi"
write_settings "$SETTINGS" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}}}'

ROW=$(row_json "claim-a")
printf '%s' "$ROW" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$EVIDENCE" --work-item wi --kdir "$KDIR" >/dev/null
printf '%s' "$ROW" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$EVIDENCE" --work-item wi --kdir "$KDIR" >/dev/null
STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" status --kdir "$KDIR" --json)
assert_json_eq "duplicate evidence append leaves one pending item" "$STATUS" '.counts.pending' "1"

SCAN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" scan --kdir "$KDIR" --json)
assert_json_eq "scan saw two task-claims rows" "$SCAN" '.scanned' "2"
assert_json_eq "scan added no duplicate queue item" "$SCAN" '.enqueued' "0"
assert_json_eq "scan reported both duplicates" "$SCAN" '.duplicates' "2"

echo ""
echo "Test 1b: invalid task-claim rows are not queued and bypass executor"
KDIR_INVALID="$TEST_DIR/kdir-invalid"
SETTINGS_INVALID="$TEST_DIR/settings-invalid.json"
setup_kdir "$KDIR_INVALID" "wi"
write_settings "$SETTINGS_INVALID" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
jq -nc '{
  claim_id: "claim-invalid",
  tier: "task-evidence",
  claim: "invalid row is missing source file and change_context",
  producer_role: "worker",
  protocol_slot: "implementation",
  task_id: "task-1",
  phase_id: "1",
  scale: "implementation",
  line_range: "1-1",
  falsifier: "fixture",
  why_this_work_needs_it: "fixture",
  captured_at_sha: "test-sha"
}' > "$KDIR_INVALID/_work/wi/task-claims.jsonl"
SCAN_INVALID=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_INVALID" bash "$QUEUE" scan --kdir "$KDIR_INVALID" --json)
assert_json_eq "scan rejects invalid row" "$SCAN_INVALID" '.ok' "false"
assert_json_eq "scan does not enqueue invalid row" "$SCAN_INVALID" '.enqueued' "0"
printf '%s' "$(row_json "claim-preflight-invalid")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_INVALID" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_INVALID" >/dev/null
python3 - "$KDIR_INVALID" <<'PY'
import json, pathlib, sys
claims = pathlib.Path(sys.argv[1]) / "_work" / "wi" / "task-claims.jsonl"
row = json.loads(claims.read_text().splitlines()[-1])
row.pop("change_context", None)
row["file"] = ""
claims.write_text(json.dumps(row) + "\n")
PY
PREFLIGHT=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_INVALID" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_INVALID" --once --json)
assert_json_eq "invalid queued item bypasses executor" "$PREFLIGHT" '.reason' "invalid_task_claim"
assert_json_eq "invalid queued item records skipped verdict" "$PREFLIGHT" '.run.verdict.verdict' "skipped"
assert_json_eq "invalid queued item reserves no runtime" "$PREFLIGHT" '.run.runtime_seconds_reserved' "0"

echo ""
echo "Test 2: disabled processor does not dispatch and enabled status is ready"
DISABLED=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" process --kdir "$KDIR" --once --json)
assert_json_eq "disabled no-dispatch reason" "$DISABLED" '.reason' "disabled"

ENABLED=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" enable --kdir "$KDIR" --json)
assert_json_eq "enable command toggles setting" "$ENABLED" '.enabled' "true"
assert_json_eq "enable command returns enabled status" "$ENABLED" '.status.enabled' "true"
DISABLED_TOGGLE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" disable --kdir "$KDIR" --json)
assert_json_eq "disable command toggles setting" "$DISABLED_TOGGLE" '.enabled' "false"
assert_json_eq "disable command returns disabled status" "$DISABLED_TOGGLE" '.status.enabled' "false"

write_settings "$SETTINGS" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
READY_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" status --kdir "$KDIR" --json)
assert_json_eq "status uses built-in executor path" "$READY_STATUS" '.blocked_reason' ""

echo ""
echo "Test 3: enabled process produces terminal item with durable run and verdict refs"
DONE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR" --once --json)
assert_json_eq "one item dispatched" "$DONE" '.dispatched' "true"
assert_json_eq "run completed" "$DONE" '.run.status' "completed"
assert_json_eq "no-op executor records opaque verdict" "$DONE" '.run.verdict.verdict_format' "opaque"
STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" bash "$QUEUE" status --kdir "$KDIR" --json)
assert_json_eq "completed item visible in status" "$STATUS" '[.terminal_items[] | select(.status=="completed")] | length' "1"
assert_json_eq "queue payload drops completed key" "$STATUS" '.queue | has("completed")' "false"
assert_json_eq "queue payload drops failed key" "$STATUS" '.queue | has("failed")' "false"
assert_json_eq "queue payload drops blocked key" "$STATUS" '.queue | has("blocked")' "false"
assert_json_eq "counts payload drops completed key" "$STATUS" '.counts | has("completed")' "false"
assert_json_eq "counts payload drops failed key" "$STATUS" '.counts | has("failed")' "false"
assert_json_eq "counts payload drops blocked key" "$STATUS" '.counts | has("blocked")' "false"
assert_json_eq "run ref is durable" "$STATUS" '.terminal_items[0].result.run_ref | test("^_settlement/runs/run-[a-f0-9]+\\.json$")' "true"
assert_json_eq "verdict ref is durable" "$STATUS" '.terminal_items[0].result.verdict_ref | test("^_settlement/runs/run-[a-f0-9]+\\.json#verdict$")' "true"

echo ""
echo "Test 4: status is read-only and process reclaims expired lease"
KDIR2="$TEST_DIR/kdir2"
SETTINGS2="$TEST_DIR/settings2.json"
setup_kdir "$KDIR2" "wi"
write_settings "$SETTINGS2" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-stale")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR2" --json >/dev/null
python3 - "$KDIR2" <<'PY'
import json, pathlib, time
k = pathlib.Path(__import__("sys").argv[1]) / "_settlement"
q = json.load(open(k / "queue.json"))
item = q["items"][0]
item["status"] = "leased"
item["lease_id"] = "lease-expired"
json.dump(q, open(k / "queue.json", "w"))
leases = {"version": 1, "leases": {"lease-expired": {"lease_id": "lease-expired", "item_id": item["id"], "run_id": "run-expired", "state": "active", "expires_at_epoch": int(time.time()) - 1}}}
json.dump(leases, open(k / "leases.json", "w"))
PY
FIRST=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" bash "$QUEUE" status --kdir "$KDIR2" --json)
SECOND=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR2" --once --json)
THIRD=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" bash "$QUEUE" status --kdir "$KDIR2" --json)
assert_json_eq "status reports stale lease without mutating queue" "$FIRST" '.stale_active_leases' "1"
assert_json_eq "status leaves stale item leased" "$FIRST" '.counts.leased' "1"
assert_json_eq "process reclaims and dispatches stale item" "$SECOND" '.dispatched' "true"
assert_json_eq "reclaimed no-op executor records opaque verdict" "$SECOND" '.run.verdict.verdict_format' "opaque"
assert_json_eq "reclaimed item reaches one terminal state" "$THIRD" '[.terminal_items[] | select(.status=="completed")] | length' "1"

echo ""
echo "Test 5: active lease remains visible while executor runs"
KDIR3="$TEST_DIR/kdir3"
SETTINGS3="$TEST_DIR/settings3.json"
setup_kdir "$KDIR3" "wi"
write_settings "$SETTINGS3" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"executor_timeout_seconds":5,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-visible-lease")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR3" --json >/dev/null
VISIBLE_EXEC="$TEST_DIR/visible-exec.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 2\nexit 0\n' > "$VISIBLE_EXEC"
chmod +x "$VISIBLE_EXEC"
(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" LORE_SETTLEMENT_EXECUTOR="$VISIBLE_EXEC" bash "$QUEUE" process --kdir "$KDIR3" --once --json > "$TEST_DIR/visible-process.json") &
VISIBLE_PID=$!
sleep 0.3
RUNNING_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" LORE_SETTLEMENT_EXECUTOR="$VISIBLE_EXEC" bash "$QUEUE" status --kdir "$KDIR3" --json)
wait "$VISIBLE_PID"
DONE_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" LORE_SETTLEMENT_EXECUTOR="$VISIBLE_EXEC" bash "$QUEUE" status --kdir "$KDIR3" --json)
assert_json_eq "lease visible while executor runs" "$RUNNING_STATUS" '.active_leases' "1"
assert_json_eq "queue running while executor runs" "$RUNNING_STATUS" '.queue.running' "1"
assert_json_eq "lease released after executor completes" "$DONE_STATUS" '.active_leases' "0"
assert_json_eq "item completed after executor completes" "$DONE_STATUS" '[.terminal_items[] | select(.status=="completed")] | length' "1"

echo ""
echo "Test 6: settlement has no daily job/runtime caps"
KDIR3B="$TEST_DIR/kdir3b"
SETTINGS3B="$TEST_DIR/settings3b.json"
setup_kdir "$KDIR3B" "wi"
write_settings "$SETTINGS3B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
for i in 1 2 3; do
  printf '%s' "$(row_json "claim-uncapped-$i")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3B" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR3B" --json >/dev/null
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3B" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR3B" --once --json >/dev/null
done
STATUS3B=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3B" bash "$QUEUE" status --kdir "$KDIR3B" --json)
assert_json_eq "uncapped jobs budget reports null remaining" "$STATUS3B" '.budget.jobs_remaining' "null"
assert_json_eq "uncapped runtime budget reports null remaining" "$STATUS3B" '.budget.runtime_seconds_remaining' "null"
assert_json_eq "all jobs complete without daily caps" "$STATUS3B" '[.terminal_items[] | select(.status=="completed")] | length' "3"

echo ""
echo "Test 7: random mode rejects unknown/disabled harnesses without active fallback"
KDIR4="$TEST_DIR/kdir4"
SETTINGS4="$TEST_DIR/settings4.json"
setup_kdir "$KDIR4" "wi"
write_settings "$SETTINGS4" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[],"enabled":false},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"random","eligible_frameworks":["phantom","claude-code"]}}}'
printf '%s' "$(row_json "claim-random")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS4" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR4" --json >/dev/null
NO_HARNESS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS4" bash "$QUEUE" process --kdir "$KDIR4" --once --json)
assert_json_eq "random mode does not fall back to active framework" "$NO_HARNESS" '.reason' "no_eligible_harnesses"
assert_json_eq "unknown harness rejected" "$NO_HARNESS" '[.rejected_harnesses[].reason] | index("unknown") != null' "true"
assert_json_eq "disabled active harness rejected" "$NO_HARNESS" '[.rejected_harnesses[].reason] | index("disabled") != null' "true"

echo ""
echo "Test 8: failed and blocked terminal items are visible with durable refs"
KDIR5="$TEST_DIR/kdir5"
SETTINGS5="$TEST_DIR/settings5.json"
setup_kdir "$KDIR5" "wi"
write_settings "$SETTINGS5" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"executor_timeout_seconds":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-failed")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS5" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR5" --json >/dev/null
printf '%s' "$(row_json "claim-blocked")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS5" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR5" --json >/dev/null
FAIL_EXEC="$TEST_DIR/fail-exec.sh"
SLOW_EXEC="$TEST_DIR/slow-exec.sh"
printf '#!/usr/bin/env bash\nexit 7\n' > "$FAIL_EXEC"
printf '#!/usr/bin/env bash\nsleep 3\n' > "$SLOW_EXEC"
chmod +x "$FAIL_EXEC" "$SLOW_EXEC"
FAILED=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS5" LORE_SETTLEMENT_EXECUTOR="$FAIL_EXEC" bash "$QUEUE" process --kdir "$KDIR5" --once --json)
BLOCKED=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS5" LORE_SETTLEMENT_EXECUTOR="$SLOW_EXEC" bash "$QUEUE" process --kdir "$KDIR5" --once --json)
STATUS5=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS5" bash "$QUEUE" status --kdir "$KDIR5" --json)
assert_json_eq "executor non-zero marks failed" "$FAILED" '.run.status' "failed"
assert_json_eq "executor timeout marks blocked" "$BLOCKED" '.run.status' "blocked"
assert_json_eq "failed executor records opaque verdict" "$FAILED" '.run.verdict.verdict_format' "opaque"
assert_json_eq "timeout executor records opaque verdict" "$BLOCKED" '.run.verdict.verdict_format' "opaque"
assert_json_eq "failed item visible in status" "$STATUS5" '[.terminal_items[] | select(.status=="failed")] | length' "1"
assert_json_eq "blocked item visible in status" "$STATUS5" '[.terminal_items[] | select(.status=="blocked")] | length' "1"
assert_json_eq "failed/blocked both keep verdict refs" "$STATUS5" '[.terminal_items[] | select(.status == "failed" or .status == "blocked") | .result.verdict_ref | test("^_settlement/runs/run-[a-f0-9]+\\.json#verdict$")] | all' "true"

echo ""
echo "Test 9: active hours block outside the configured window"
KDIR6="$TEST_DIR/kdir6"
SETTINGS6="$TEST_DIR/settings6.json"
setup_kdir "$KDIR6" "wi"
write_settings "$SETTINGS6" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"active_hours":{"enabled":true,"timezone":"UTC","ranges":[{"days":["mon"],"start":"09:00","end":"10:00"},{"days":["mon"],"start":"13:00","end":"14:00"}]},"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-hours")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS6" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR6" --json >/dev/null
OUTSIDE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS6" LORE_SETTLEMENT_NOW="2026-05-11T08:30:00Z" bash "$QUEUE" process --kdir "$KDIR6" --once --json)
assert_json_eq "outside active hours does not dispatch" "$OUTSIDE" '.dispatched' "false"
assert_json_eq "outside active hours reason" "$OUTSIDE" '.reason' "outside_active_hours"
INSIDE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS6" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" LORE_SETTLEMENT_NOW="2026-05-11T13:30:00Z" bash "$QUEUE" process --kdir "$KDIR6" --once --json)
assert_json_eq "inside second active-hours range dispatches" "$INSIDE" '.dispatched' "true"

echo ""
echo "Test 10: enabled active hours without ranges means all time"
KDIR7="$TEST_DIR/kdir7"
SETTINGS7="$TEST_DIR/settings7.json"
setup_kdir "$KDIR7" "wi"
write_settings "$SETTINGS7" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"active_hours":{"enabled":true,"timezone":"UTC"},"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-all-time")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS7" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR7" --json >/dev/null
ALL_TIME=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS7" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" LORE_SETTLEMENT_NOW="2026-05-11T03:30:00Z" bash "$QUEUE" process --kdir "$KDIR7" --once --json)
assert_json_eq "unset active-hours ranges dispatch all time" "$ALL_TIME" '.dispatched' "true"
assert_json_eq "unset active-hours status ranges are empty" "$ALL_TIME" '.active_hours.ranges | length' "0"

echo ""
echo "Test 11: shipped audit executor records envelope verdict from pinned audit JSON"
KDIR8="$TEST_DIR/kdir8"
SETTINGS8="$TEST_DIR/settings8.json"
GATE8="$TEST_DIR/gate8.json"
SMOKE_SLUG="settlement-smoke"
setup_plan_assertions_fixture "$KDIR8" "$SMOKE_SLUG"
printf '%s' "$(row_json "assertion-0")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8" bash "$QUEUE" enqueue --work-item "$SMOKE_SLUG" --kdir "$KDIR8" --json >/dev/null
write_settings "$SETTINGS8" "$(jq -nc '{
  version: 1,
  tui_launch_framework: "claude-code",
  harnesses: {"claude-code": {args: []}, opencode: {args: []}, codex: {args: []}},
  settlement: {
    enabled: true,
    max_concurrency: 1,
    executor_timeout_seconds: 10,
    harness_selection: {mode: "first_eligible", eligible_frameworks: ["claude-code"]}
  }
}')"
printf '%s\n' '{
  "judge": "correctness-gate",
  "judge_template_version": "settlement-smoke-gate",
  "verdicts": [
    {"claim_id": "assertion-0", "verdict": "verified", "evidence": "verified fixture"}
  ]
}' > "$GATE8"
SMOKE_ARGS=$(printf -- '--kdir %q --gate-output-file %q' "$KDIR8" "$GATE8")
SMOKE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8" LORE_SETTLEMENT_AUDIT_ARGS="$SMOKE_ARGS" bash "$QUEUE" process --kdir "$KDIR8" --once --json)
SMOKE_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8" bash "$QUEUE" status --kdir "$KDIR8" --json)
assert_json_eq "shipped executor dispatched" "$SMOKE" '.dispatched' "true"
assert_json_eq "shipped executor run completed" "$SMOKE" '.run.status' "completed"
assert_json_eq "shipped executor records envelope verdict" "$SMOKE" '.run.verdict.verdict_format' "envelope"
assert_json_eq "verified fixture is not pre-change unverified literal" "$SMOKE" '.run.verdict.verdict != "unverified"' "true"
assert_json_eq "executor audit correctness gate is retained" "$SMOKE" '.run.executor_audit.correctness_gate != null' "true"
assert_json_eq "status exposes envelope verdict ref" "$SMOKE_STATUS" '.terminal_items[0].result.verdict_ref | test("^_settlement/runs/run-[a-f0-9]+\\.json#verdict$")' "true"
assert_json_eq "status exposes run data path" "$SMOKE_STATUS" '.terminal_items[0].result.run_ref | test("^_settlement/runs/run-[a-f0-9]+\\.json$")' "true"
assert_json_eq "status exposes actual verdict label" "$SMOKE_STATUS" '.terminal_items[0].verdict_label' "verified"
assert_json_eq "status exposes actual verdict evidence" "$SMOKE_STATUS" '.terminal_items[0].verdict_summary' "correctness_gate: total=1 verified=1 unverified=0 contradicted=0"
assert_json_eq "status nests verdict for TUI parsing" "$SMOKE_STATUS" '.terminal_items[0].verdict.verdict' "verified"

echo ""
echo "Test 12: retry-errors requeues structured audit errors"
KDIR8B="$TEST_DIR/kdir8b"
SETTINGS8B="$TEST_DIR/settings8b.json"
ERROR_EXEC="$TEST_DIR/error-envelope-exec.sh"
setup_kdir "$KDIR8B" "wi"
write_settings "$SETTINGS8B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-error-envelope")" >> "$KDIR8B/_work/wi/task-claims.jsonl"
cat > "$ERROR_EXEC" <<'EXEC'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"verdict_envelope_version":1,"verdict":"error","evidence":"fixture audit failed before judging the claim","correction":null}'
EXEC
chmod +x "$ERROR_EXEC"
ERROR_RUN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8B" LORE_SETTLEMENT_EXECUTOR="$ERROR_EXEC" bash "$QUEUE" process --kdir "$KDIR8B" --once --json)
RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8B" bash "$QUEUE" retry-errors --kdir "$KDIR8B" --json)
RETRY_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8B" bash "$QUEUE" status --kdir "$KDIR8B" --json)
assert_json_eq "error envelope was originally terminal" "$ERROR_RUN" '.run.verdict.verdict' "error"
assert_json_eq "error envelope marks run failed" "$ERROR_RUN" '.run.status' "failed"
assert_json_eq "error envelope reason is audit-specific" "$ERROR_RUN" '.run.reason' "executor_audit_error"
assert_json_eq "retry invalidated one error run" "$RETRY" '.invalidated' "1"
assert_json_eq "retry enqueued one replacement item" "$RETRY" '.enqueued' "1"
assert_json_eq "invalidated error no longer counts completed" "$RETRY_STATUS" '[.terminal_items[] | select(.status=="completed")] | length' "0"
assert_json_eq "retry item is pending" "$RETRY_STATUS" '.counts.pending' "1"
assert_json_eq "retry item carries retry selection reason" "$RETRY_STATUS" '.items[0].selection_reason' "retry_infrastructure_failure"
assert_json_eq "retry item records previous audit error" "$RETRY_STATUS" '.items[0].retry_reason' "previous_audit_error"
assert_json_eq "run record stores invalidation marker" "$(cat "$KDIR8B/_settlement/runs/$(printf '%s' "$ERROR_RUN" | jq -r '.run.run_id').json")" '.invalidated_reason' "retry_infrastructure_failure"

echo ""
echo "Test 12b: retry-errors requeues timeout-blocked audits"
KDIR8C="$TEST_DIR/kdir8c"
SETTINGS8C="$TEST_DIR/settings8c.json"
SLOW8C="$TEST_DIR/slow8c.sh"
setup_kdir "$KDIR8C" "wi"
write_settings "$SETTINGS8C" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"executor_timeout_seconds":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-timeout-envelope")" >> "$KDIR8C/_work/wi/task-claims.jsonl"
printf '#!/usr/bin/env bash\ncat >/dev/null\nsleep 3\n' > "$SLOW8C"
chmod +x "$SLOW8C"
TIMEOUT_RUN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8C" LORE_SETTLEMENT_EXECUTOR="$SLOW8C" bash "$QUEUE" process --kdir "$KDIR8C" --once --json)
TIMEOUT_RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8C" bash "$QUEUE" retry-errors --kdir "$KDIR8C" --json)
TIMEOUT_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8C" bash "$QUEUE" status --kdir "$KDIR8C" --json)
assert_json_eq "timeout run was blocked" "$TIMEOUT_RUN" '.run.status' "blocked"
assert_json_eq "timeout run reason is timeout" "$TIMEOUT_RUN" '.run.reason' "executor_timeout"
assert_json_eq "retry invalidated one timeout run" "$TIMEOUT_RETRY" '.invalidated' "1"
assert_json_eq "retry enqueued timeout replacement" "$TIMEOUT_RETRY" '.enqueued' "1"
assert_json_eq "retry timeout item records timeout reason" "$TIMEOUT_STATUS" '.items[0].retry_reason' "previous_executor_timeout"

echo ""
echo "Test 12c: retry-errors requeues 'no auditable artifact' skips and resolves task-claim row from _archive/"
KDIR8D="$TEST_DIR/kdir8d"
SETTINGS8D="$TEST_DIR/settings8d.json"
SKIP_EXEC="$TEST_DIR/skip-envelope-exec.sh"
setup_kdir "$KDIR8D" "wi"
write_settings "$SETTINGS8D" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-archived-skip")" >> "$KDIR8D/_work/wi/task-claims.jsonl"
# Mock executor emits the same skip envelope the real executor produces when it
# can't see the work-item artifact. Tests that the new retryable_infrastructure_failure_reason
# branch recognizes this as infrastructure-induced.
cat > "$SKIP_EXEC" <<'EXEC'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"verdict_envelope_version":1,"verdict":"skipped","evidence":"no auditable artifact for work_item=wi","correction":null}'
EXEC
chmod +x "$SKIP_EXEC"
SKIP_RUN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8D" LORE_SETTLEMENT_EXECUTOR="$SKIP_EXEC" bash "$QUEUE" process --kdir "$KDIR8D" --once --json)
# Archive the work item between process and retry to simulate the production scenario:
# the executor produced a skip because the active dir went missing mid-flight.
mkdir -p "$KDIR8D/_work/_archive"
mv "$KDIR8D/_work/wi" "$KDIR8D/_work/_archive/wi"
SKIP_RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8D" bash "$QUEUE" retry-errors --kdir "$KDIR8D" --json)
SKIP_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8D" bash "$QUEUE" status --kdir "$KDIR8D" --json)
assert_json_eq "skip envelope was originally terminal" "$SKIP_RUN" '.run.verdict.verdict' "skipped"
assert_json_eq "skip envelope marks run completed" "$SKIP_RUN" '.run.status' "completed"
assert_json_eq "retry invalidated one skip run" "$SKIP_RETRY" '.invalidated' "1"
assert_json_eq "retry enqueued one replacement after archival" "$SKIP_RETRY" '.enqueued' "1"
assert_json_eq "retry skip item carries retry selection reason" "$SKIP_STATUS" '.items[0].selection_reason' "retry_infrastructure_failure"
assert_json_eq "retry skip item records artifact-unresolved reason" "$SKIP_STATUS" '.items[0].retry_reason' "previous_artifact_unresolved"

echo ""
echo "Test 12d: audit executor falls back to _archive/<slug>/ when active dir is a stub"
# Regression coverage for the v1 archive-fallback patch: a work item can be
# archived and then partially recreated (e.g. _meta.json + notes.md only),
# leaving _work/<slug>/ present but without an auditable artifact. The
# original patch keyed off dir presence and would pin to the stub, then
# emit a spurious "no auditable artifact" skip. The fix iterates active
# then archive, choosing by ARTIFACT presence.
KDIR8E="$TEST_DIR/kdir8e"
mkdir -p "$KDIR8E/_work/wi" "$KDIR8E/_work/_archive/wi"
printf '{"slug": "wi"}' > "$KDIR8E/_work/wi/_meta.json"
printf '# wi stub\n' > "$KDIR8E/_work/wi/notes.md"
printf '%s\n' "$(row_json "claim-stub-active")" > "$KDIR8E/_work/_archive/wi/task-claims.jsonl"
# Stub `lore` so we don't depend on the real binary running real audits.
FAKE_BIN_12D="$TEST_DIR/fake-bin-12d"
mkdir -p "$FAKE_BIN_12D"
cat > "$FAKE_BIN_12D/lore" <<'BIN'
#!/usr/bin/env bash
echo '{"correctness_gate":{"verified":1,"unverified":0,"contradicted":0,"verdicts_total":1}}'
BIN
chmod +x "$FAKE_BIN_12D/lore"
EXECUTOR_BIN_12D="$SCRIPTS_DIR/settlement-audit-executor.sh"
EXEC_STDERR_12D="$TEST_DIR/12d-stderr.txt"
EXEC_STDOUT_12D=$(printf '%s' '{"item": {"work_item": "wi", "claim_id": "claim-stub-active"}}' | \
  PATH="$FAKE_BIN_12D:$PATH" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR8E" bash "$EXECUTOR_BIN_12D" 2>"$EXEC_STDERR_12D")
EXEC_STDERR_12D_CONTENT=$(cat "$EXEC_STDERR_12D")
ARCHIVE_HIT_COUNT=$(printf '%s\n' "$EXEC_STDERR_12D_CONTENT" | grep -c 'Resolving work_item=wi from _archive' || true)
SKIP_LOG_COUNT=$(printf '%s\n' "$EXEC_STDERR_12D_CONTENT" | grep -c 'no auditable artifact' || true)
assert_eq "executor logged archive fallback for stub active dir" "$ARCHIVE_HIT_COUNT" "1"
assert_eq "executor did not emit spurious no-auditable-artifact skip" "$SKIP_LOG_COUNT" "0"
assert_json_eq "executor produced non-skip verdict via fake audit" "$EXEC_STDOUT_12D" '.verdict' "verified"

echo ""
echo "Test 13: recompute scores only batch_size rows and exposes bounds"
KDIR9="$TEST_DIR/kdir9"
SETTINGS9="$TEST_DIR/settings9.json"
COUNT9="$TEST_DIR/score-count9"
SCORE9="$TEST_DIR/score9.sh"
setup_kdir "$KDIR9" "wi"
write_settings "$SETTINGS9" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"concordance_window_size":7,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '#!/usr/bin/env bash\ncat >/dev/null\nn=0; [[ -f "$LORE_SCORE_COUNT" ]] && n=$(cat "$LORE_SCORE_COUNT"); n=$((n+1)); printf "%%s" "$n" > "$LORE_SCORE_COUNT"; printf '"'"'{"score": 1}\n'"'"'\n' > "$SCORE9"
chmod +x "$SCORE9"
for i in 1 2 3 4 5 6 7; do
  printf '%s\n' "$(row_json "claim-batch-$i")" >> "$KDIR9/_work/wi/task-claims.jsonl"
done
RECOMP9=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS9" LORE_SETTLEMENT_SCORE_HOOK="$SCORE9" LORE_SCORE_COUNT="$COUNT9" bash "$QUEUE" queue recompute --kdir "$KDIR9" --json)
STATUS9=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS9" bash "$QUEUE" status --kdir "$KDIR9" --json)
assert_json_eq "recompute fills only batch_size pending rows" "$RECOMP9" '.batch.size' "3"
assert_eq "score hook called only batch_size times" "$(cat "$COUNT9")" "3"
assert_json_eq "status exposes backlog size" "$STATUS9" '.batch.backlog_size' "7"
assert_json_eq "effective concordance is capped to batch size" "$STATUS9" '.bounds.effective_concordance_window' "3"

echo ""
echo "Test 14: recompute preserves active leases byte-identical for lease/selection fields"
KDIR10="$TEST_DIR/kdir10"
SETTINGS10="$TEST_DIR/settings10.json"
setup_kdir "$KDIR10" "wi"
write_settings "$SETTINGS10" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
for i in 1 2 3; do printf '%s\n' "$(row_json "claim-lease-$i")" >> "$KDIR10/_work/wi/task-claims.jsonl"; done
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS10" bash "$QUEUE" queue recompute --kdir "$KDIR10" --json >/dev/null
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS10" LORE_SETTLEMENT_EXECUTOR="$VISIBLE_EXEC" bash "$QUEUE" process --kdir "$KDIR10" --once --json > "$TEST_DIR/lease-process.json" &
LEASE_PID=$!
sleep 0.3
BEFORE_LEASE=$(jq -c '.items[] | select(.status=="leased") | {id,status,lease_id,batch_id,selection_score,selection_reason,selected_at}' "$KDIR10/_settlement/queue.json")
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS10" bash "$QUEUE" queue recompute --kdir "$KDIR10" --json >/dev/null
AFTER_LEASE=$(jq -c '.items[] | select(.status=="leased") | {id,status,lease_id,batch_id,selection_score,selection_reason,selected_at}' "$KDIR10/_settlement/queue.json")
wait "$LEASE_PID"
assert_eq "active lease core selection fields preserved" "$AFTER_LEASE" "$BEFORE_LEASE"

echo ""
echo "Test 15: terminal drain leaves queue terminal-free and run records keep selection"
KDIR11="$TEST_DIR/kdir11"
SETTINGS11="$TEST_DIR/settings11.json"
setup_kdir "$KDIR11" "wi"
write_settings "$SETTINGS11" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-drain")" >> "$KDIR11/_work/wi/task-claims.jsonl"
DRAIN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS11" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR11" --once --json)
STATUS11=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS11" bash "$QUEUE" status --kdir "$KDIR11" --json)
assert_json_eq "queue has no terminal statuses after finalize" "$(cat "$KDIR11/_settlement/queue.json")" '[.items[] | select(.status=="completed" or .status=="failed" or .status=="blocked")] | length' "0"
assert_json_eq "status derives terminal item from runs" "$STATUS11" '.terminal_items | length' "1"
assert_json_eq "run record contains selection block selected_at" "$DRAIN" '.run.selection.selected_at != null' "true"

echo ""
echo "Test 16: partial crash heal prunes queue item when run record already exists"
KDIR12="$TEST_DIR/kdir12"
SETTINGS12="$TEST_DIR/settings12.json"
setup_kdir "$KDIR12" "wi"
write_settings "$SETTINGS12" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-crash")" >> "$KDIR12/_work/wi/task-claims.jsonl"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS12" bash "$QUEUE" queue recompute --kdir "$KDIR12" --json >/dev/null
python3 - "$KDIR12" <<'PY'
import json, pathlib, time
k = pathlib.Path(__import__("sys").argv[1]) / "_settlement"
q = json.load(open(k / "queue.json"))
item = q["items"][0]
item["status"] = "leased"; item["lease_id"] = "lease-crash"; item["run_id"] = "run-crash"
json.dump(q, open(k / "queue.json", "w"))
json.dump({"version": 1, "leases": {"lease-crash": {"lease_id": "lease-crash", "item_id": item["id"], "run_id": "run-crash", "state": "active", "expires_at_epoch": int(time.time()) + 60}}}, open(k / "leases.json", "w"))
(k / "runs").mkdir(exist_ok=True)
json.dump({"version": 1, "run_id": "run-crash", "item_id": item["id"], "work_item": item["work_item"], "claim_id": item["claim_id"], "status": "completed", "reason": "simulated_crash", "completed_at": "2026-05-11T00:00:00Z", "verdict_ref": "_settlement/runs/run-crash.json#verdict", "selection": {"batch_id": item.get("batch_id"), "score": item.get("selection_score"), "reason": item.get("selection_reason"), "selected_at": item.get("selected_at")}}, open(k / "runs/run-crash.json", "w"))
PY
HEAL12=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS12" bash "$QUEUE" queue recompute --kdir "$KDIR12" --json)
assert_json_eq "heal observed crash residue" "$HEAL12" '.healed' "1"
assert_json_eq "crash residue pruned from queue" "$(cat "$KDIR12/_settlement/queue.json")" '[.items[] | select(.run_id=="run-crash")] | length' "0"

echo ""
echo "Test 17: status is read-only and does not trigger throttled recompute"
KDIR13="$TEST_DIR/kdir13"
SETTINGS13="$TEST_DIR/settings13.json"
setup_kdir "$KDIR13" "wi"
write_settings "$SETTINGS13" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":1,"batch_recompute_min_interval_seconds":9999,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-readonly")" >> "$KDIR13/_work/wi/task-claims.jsonl"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS13" bash "$QUEUE" queue recompute --kdir "$KDIR13" --json >/dev/null
SUM_BEFORE=$(find "$KDIR13/_settlement" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')
STATUS13A=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS13" bash "$QUEUE" status --kdir "$KDIR13" --json)
STATUS13B=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS13" bash "$QUEUE" status --kdir "$KDIR13" --json)
SUM_AFTER=$(find "$KDIR13/_settlement" -type f -print0 | sort -z | xargs -0 shasum | shasum | awk '{print $1}')
assert_eq "status calls leave settlement files checksum-stable" "$SUM_AFTER" "$SUM_BEFORE"
assert_eq "repeated status output stable" "$STATUS13B" "$STATUS13A"

echo ""
echo "Test 18: deterministic FIFO ties and fallback reasons"
KDIR14="$TEST_DIR/kdir14"
SETTINGS14="$TEST_DIR/settings14.json"
SETTINGS14B="$TEST_DIR/settings14b.json"
SCORE14="$TEST_DIR/score14.sh"
ERR14="$TEST_DIR/score-error14.sh"
setup_kdir "$KDIR14" "wi"
write_settings "$SETTINGS14" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
for cid in claim-tie-a claim-tie-b claim-tie-c; do printf '%s\n' "$(row_json "$cid")" >> "$KDIR14/_work/wi/task-claims.jsonl"; done
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf '"'"'{"score": 2}\n'"'"'\n' > "$SCORE14"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 22\n' > "$ERR14"
chmod +x "$SCORE14" "$ERR14"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14" LORE_SETTLEMENT_SCORE_HOOK="$SCORE14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
ORDER_A=$(jq -r '[.items[].claim_id] | join(",")' "$KDIR14/_settlement/queue.json")
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14" LORE_SETTLEMENT_SCORE_HOOK="$SCORE14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
ORDER_B=$(jq -r '[.items[].claim_id] | join(",")' "$KDIR14/_settlement/queue.json")
assert_eq "equal relevance scores keep durable FIFO order" "$ORDER_B" "$ORDER_A"
write_settings "$SETTINGS14B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14B" LORE_SETTLEMENT_SCORE_HOOK="$ERR14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
assert_json_eq "score hook errors degrade to fallback_error" "$(cat "$KDIR14/_settlement/queue.json")" '[.items[].selection_reason] | unique | .[0]' "fallback_error"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14B" LORE_SETTLEMENT_RELEVANCE_DISABLED=1 bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
assert_json_eq "disabled relevance uses FIFO fallback reason" "$(cat "$KDIR14/_settlement/queue.json")" '[.items[].selection_reason] | unique | .[0]' "fallback_fifo"

echo ""
echo "Test 19: legacy pending is normalized before selection"
KDIR15="$TEST_DIR/kdir15"
SETTINGS15="$TEST_DIR/settings15.json"
setup_kdir "$KDIR15" "wi"
write_settings "$SETTINGS15" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"batch_size":1,"batch_recompute_min_interval_seconds":9999,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-legacy-normalized")" >> "$KDIR15/_work/wi/task-claims.jsonl"
printf '%s' "$(row_json "claim-legacy-normalized")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS15" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR15" --json >/dev/null
LEGACY_RUN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS15" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR15" --once --json)
assert_json_eq "legacy pending selected with non-legacy reason" "$LEGACY_RUN" '.run.selection.reason != "legacy"' "true"
assert_json_eq "legacy pending run has selection block" "$LEGACY_RUN" '.run.selection.batch_id != null and .run.selection.selected_at != null' "true"

echo ""
echo "Test 20: status path bounds JSON parsing to the K most recent run files"
KDIR16="$TEST_DIR/kdir16"
SETTINGS16="$TEST_DIR/settings16.json"
setup_kdir "$KDIR16" "wi"
write_settings "$SETTINGS16" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
python3 - "$KDIR16" <<'PY'
import json, os, pathlib, sys, time
kdir = pathlib.Path(sys.argv[1])
runs_dir = kdir / "_settlement" / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)
# Older sentinel files: malformed JSON + sentinel item ids visible only via parsing.
# If the bounded status path parsed beyond K, terminal_items would include these.
base_mtime = time.time() - 10000
for i in range(120):
    name = f"run-sentinel-old-{i:04d}"
    p = runs_dir / f"{name}.json"
    if i % 2 == 0:
        p.write_text("{ this is not valid json")
    else:
        p.write_text(json.dumps({
            "version": 1,
            "run_id": name,
            "item_id": f"item-sentinel-old-{i:04d}",
            "work_item": "wi",
            "claim_id": f"sentinel-old-{i:04d}",
            "status": "completed",
            "completed_at": "2020-01-01T00:00:00Z",
            "verdict": {"verdict": "verified", "evidence": "sentinel old"},
        }))
    os.utime(p, (base_mtime + i, base_mtime + i))
# Fresh files: at most K (25) should be parsed; we add 5 fresh completed runs so
# terminal_items returns them with their recent_id, and no sentinel_old rows.
fresh_mtime = time.time() + 1000
for i in range(5):
    name = f"run-fresh-{i:04d}"
    p = runs_dir / f"{name}.json"
    p.write_text(json.dumps({
        "version": 1,
        "run_id": name,
        "item_id": f"item-fresh-{i:04d}",
        "work_item": "wi",
        "claim_id": f"fresh-{i:04d}",
        "status": "completed",
        "completed_at": f"2026-05-11T0{i}:00:00Z",
        "verdict": {"verdict": "verified", "evidence": "fresh"},
    }))
    os.utime(p, (fresh_mtime + i, fresh_mtime + i))
PY
START_NS=$(python3 -c 'import time; print(time.time_ns())')
STATUS16=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS16" bash "$QUEUE" status --kdir "$KDIR16" --json)
END_NS=$(python3 -c 'import time; print(time.time_ns())')
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
assert_json_eq "bounded scan returns ok with >100 historical run files" "$STATUS16" '.ok' "true"
assert_json_eq "bounded scan terminal preview cap is 5 or fewer" "$STATUS16" '.terminal_items | length <= 5' "true"
assert_json_eq "bounded scan does not surface older-than-K sentinel rows" "$STATUS16" '[.terminal_items[] | select(.claim_id | startswith("sentinel-old-"))] | length' "0"
assert_json_eq "bounded scan surfaces only fresh run ids" "$STATUS16" '[.terminal_items[].claim_id | startswith("fresh-")] | all' "true"
if [[ $ELAPSED_MS -lt 1000 ]]; then
  echo "  PASS: status latency under 1s with 120+ historical run files (${ELAPSED_MS}ms)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: status latency too high with bounded scan (${ELAPSED_MS}ms >= 1000ms)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
