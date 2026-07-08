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

assert_json_contains() {
  local label="$1" json="$2" expr="$3" needle="$4"
  local actual
  actual=$(printf '%s' "$json" | jq -r "$expr")
  if [[ "$actual" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected substring: $needle"
    echo "    actual:             $actual"
    FAIL=$((FAIL + 1))
  fi
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

setup_task_claims_smoke_fixture() {
  # Writes a single task-claim row matching claim_id "$3" (default
  # "assertion-0" for back-compat with existing smoke calls) to
  # _work/<slug>/task-claims.jsonl. The downstream executor dispatches
  # via `lore audit --kind task-claim --id <claim_id>`, which requires
  # the per-kind source file to be present and contain that id.
  local kdir="$1" slug="$2" claim_id="${3:-assertion-0}"
  mkdir -p "$kdir/_work/$slug"
  jq -nc --arg cid "$claim_id" '{
    claim_id: $cid,
    tier: "task-evidence",
    claim: ("settlement processor smoke fixture row for claim " + $cid),
    producer_role: "worker",
    protocol_slot: "implementation",
    task_id: "task-1",
    phase_id: "1",
    scale: "implementation",
    file: "scripts/settlement-processor.py",
    line_range: "1-20",
    falsifier: "Run settlement smoke and inspect run.verdict for verified fixture",
    why_this_work_needs_it: "Smoke covers the per-kind dispatch path for task-claim",
    captured_at_sha: "test-sha",
    change_context: {
      diff_ref: "test-sha",
      changed_files: ["scripts/settlement-processor.py"],
      summary: "settlement smoke fixture row"
    },
    exact_snippet: "settlement smoke fixture snippet",
    normalized_snippet_hash: "fe36a0b26f180f1bccf74316c366108736c120752d30230840ad20bc7e004c03"
  }' > "$kdir/_work/$slug/task-claims.jsonl"
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
    },
    exact_snippet: "settlement smoke fixture snippet",
    normalized_snippet_hash: "fe36a0b26f180f1bccf74316c366108736c120752d30230840ad20bc7e004c03"
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
# Health block, auditor-model echo, and pump liveness must be present and
# null-safe with no _settlement state at all (proves neither needs a runs
# or queue scan to exist).
assert_json_eq "empty-state health counters are zero" "$STATUS0" '[.health.drain_rate_per_hour, .health.completions_24h, .health.requeues_today, .health.failures_today] | map(. == 0) | all' "true"
assert_json_eq "empty-state oldest pending age is null" "$STATUS0" '.health.oldest_pending_age_seconds' "null"
assert_json_eq "empty-state auditor_model echoes null" "$STATUS0" '.auditor_model' "null"
assert_json_eq "empty-state pump last_ran_at is null" "$STATUS0" '.dispatch.pump.last_ran_at' "null"
assert_json_eq "empty-state pump seconds_since_last is null" "$STATUS0" '.dispatch.pump.seconds_since_last' "null"
assert_json_eq "empty-state verify weeks carry the held/contradicted split" "$STATUS0" '[.dispatch.verify_volume.weeks[] | has("held") and has("contradicted")] | all' "true"
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
write_settings "$SETTINGS_INVALID" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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

write_settings "$SETTINGS" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
echo "Test 3b: missing eligible frameworks declaration blocks dispatch after GC"
KDIR_DECL_MISSING="$TEST_DIR/kdir-decl-missing"
SETTINGS_DECL_MISSING="$TEST_DIR/settings-decl-missing.json"
setup_kdir "$KDIR_DECL_MISSING" "wi"
write_settings "$SETTINGS_DECL_MISSING" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1}}'
printf '%s' "$(row_json "claim-decl-missing")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_MISSING" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_DECL_MISSING" >/dev/null
DECL_MISSING=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_MISSING" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_DECL_MISSING" --once --json)
assert_json_eq "missing declaration does not dispatch" "$DECL_MISSING" '.dispatched' "false"
assert_json_contains "missing declaration names settings key" "$DECL_MISSING" '.blocked_reason' "settlement.harness_selection.eligible_frameworks"
assert_json_contains "missing declaration carries remediation" "$DECL_MISSING" '.next_action' "declare settlement.harness_selection.eligible_frameworks"
assert_json_eq "missing declaration leaves pending item dispatchable" "$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_MISSING" bash "$QUEUE" status --kdir "$KDIR_DECL_MISSING" --json)" '.queue.pending' "1"
if compgen -G "$KDIR_DECL_MISSING/_settlement/runs/*.json" >/dev/null; then
  echo "  FAIL: missing declaration created a run record"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: missing declaration created no run record"
  PASS=$((PASS + 1))
fi
assert_eq "missing declaration appends one blocked-evaluation pump event" \
  "$(jq -s '[.[] | select(.event=="blocked_evaluation" and .settings_key=="settlement.harness_selection.eligible_frameworks" and (.remediation | contains("declare settlement.harness_selection.eligible_frameworks")))] | length' "$KDIR_DECL_MISSING/_settlement/pump-log.jsonl")" "1"
if [[ -e "$KDIR_DECL_MISSING/_settlement/latest-framework.json" ]]; then
  echo "  FAIL: missing declaration touched latest-framework marker"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: missing declaration did not touch latest-framework marker"
  PASS=$((PASS + 1))
fi
DECL_MISSING_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_MISSING" bash "$QUEUE" status --kdir "$KDIR_DECL_MISSING" --json)
assert_json_contains "status blocked_reason names declaration key" "$DECL_MISSING_STATUS" '.blocked_reason' "settlement.harness_selection.eligible_frameworks"
assert_json_contains "status next_action carries declaration remediation" "$DECL_MISSING_STATUS" '.next_action' "declare settlement.harness_selection.eligible_frameworks"

echo ""
echo "Test 3c: empty eligible frameworks declaration blocks dispatch"
KDIR_DECL_EMPTY="$TEST_DIR/kdir-decl-empty"
SETTINGS_DECL_EMPTY="$TEST_DIR/settings-decl-empty.json"
setup_kdir "$KDIR_DECL_EMPTY" "wi"
write_settings "$SETTINGS_DECL_EMPTY" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":[]}}}'
printf '%s' "$(row_json "claim-decl-empty")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_EMPTY" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_DECL_EMPTY" >/dev/null
DECL_EMPTY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_EMPTY" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_DECL_EMPTY" --once --json)
assert_json_eq "empty declaration does not dispatch" "$DECL_EMPTY" '.dispatched' "false"
assert_json_contains "empty declaration names settings key" "$DECL_EMPTY" '.blocked_reason' "settlement.harness_selection.eligible_frameworks"
assert_json_contains "empty declaration carries remediation" "$DECL_EMPTY" '.next_action' "declare settlement.harness_selection.eligible_frameworks"
if [[ -e "$KDIR_DECL_EMPTY/_settlement/latest-framework.json" ]]; then
  echo "  FAIL: empty declaration touched latest-framework marker"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: empty declaration did not touch latest-framework marker"
  PASS=$((PASS + 1))
fi

echo ""
echo "Test 3d: declared eligible framework dispatches without declaration block"
KDIR_DECL_OK="$TEST_DIR/kdir-decl-ok"
SETTINGS_DECL_OK="$TEST_DIR/settings-decl-ok.json"
setup_kdir "$KDIR_DECL_OK" "wi"
write_settings "$SETTINGS_DECL_OK" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-decl-ok")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_OK" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_DECL_OK" >/dev/null
DECL_OK=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DECL_OK" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_DECL_OK" --once --json)
assert_json_eq "declared list dispatches" "$DECL_OK" '.dispatched' "true"
assert_json_eq "declared list selects declared framework" "$DECL_OK" '.run.framework' "claude-code"
assert_json_eq "declared list has no declaration blocked reason" "$DECL_OK" '.blocked_reason // ""' ""

echo ""
echo "Test 3e: framework flip emits one run block and one pump-log event"
KDIR_FLIP="$TEST_DIR/kdir-framework-flip"
SETTINGS_FLIP="$TEST_DIR/settings-framework-flip.json"
setup_kdir "$KDIR_FLIP" "wi"
write_settings "$SETTINGS_FLIP" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-flip-1")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_FLIP" >/dev/null
printf '%s' "$(row_json "claim-flip-2")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_FLIP" >/dev/null
printf '%s' "$(row_json "claim-flip-3")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" bash "$EVIDENCE" --work-item wi --kdir "$KDIR_FLIP" >/dev/null
printf 'not-json\n' > "$KDIR_FLIP/_settlement/latest-framework.json"
FLIP_FIRST=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_FLIP" --once --json)
assert_json_eq "first framework run is quiet" "$FLIP_FIRST" '.run | has("framework_changed")' "false"
assert_json_eq "unreadable marker is replaced after first run" "$(cat "$KDIR_FLIP/_settlement/latest-framework.json")" '.framework' "claude-code"
write_settings "$SETTINGS_FLIP" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["codex"]}}}'
FLIP_SECOND=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_FLIP" --once --json)
assert_json_eq "second framework run records flip from" "$FLIP_SECOND" '.run.framework_changed.from' "claude-code"
assert_json_eq "second framework run records flip to" "$FLIP_SECOND" '.run.framework_changed.to' "codex"
assert_eq "one framework_changed pump-log event after flip" \
  "$(jq -s '[.[] | select(.event=="framework_changed" and .from=="claude-code" and .to=="codex")] | length' "$KDIR_FLIP/_settlement/pump-log.jsonl")" "1"
FLIP_THIRD=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_FLIP" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" process --kdir "$KDIR_FLIP" --once --json)
assert_json_eq "same framework run is quiet" "$FLIP_THIRD" '.run | has("framework_changed")' "false"
assert_eq "same framework run adds no extra flip event" \
  "$(jq -s '[.[] | select(.event=="framework_changed")] | length' "$KDIR_FLIP/_settlement/pump-log.jsonl")" "1"

echo ""
echo "Test 4: status is read-only and process reclaims expired lease"
KDIR2="$TEST_DIR/kdir2"
SETTINGS2="$TEST_DIR/settings2.json"
setup_kdir "$KDIR2" "wi"
write_settings "$SETTINGS2" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
echo "Test 4b: disabled processor still reclaims expired leases (regression: paused queues must GC dead leases)"
KDIR2B="$TEST_DIR/kdir2b"
SETTINGS2B="$TEST_DIR/settings2b.json"
setup_kdir "$KDIR2B" "wi"
# Settlement disabled — must NOT dispatch, but MUST still reclaim stale leases.
write_settings "$SETTINGS2B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":false,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
# Enqueue requires enabled=true momentarily so the row admits — toggle, enqueue, toggle back.
write_settings "$SETTINGS2B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-stale-paused")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2B" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR2B" --json >/dev/null
write_settings "$SETTINGS2B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":false,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
python3 - "$KDIR2B" <<'PY'
import json, pathlib, time
k = pathlib.Path(__import__("sys").argv[1]) / "_settlement"
q = json.load(open(k / "queue.json"))
item = q["items"][0]
item["status"] = "leased"
item["lease_id"] = "lease-expired-paused"
json.dump(q, open(k / "queue.json", "w"))
leases = {"version": 1, "leases": {"lease-expired-paused": {"lease_id": "lease-expired-paused", "item_id": item["id"], "run_id": "run-expired-paused", "state": "active", "expires_at_epoch": int(time.time()) - 1}}}
json.dump(leases, open(k / "leases.json", "w"))
PY
PAUSED_PROCESS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2B" bash "$QUEUE" process --kdir "$KDIR2B" --once --json)
PAUSED_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2B" bash "$QUEUE" status --kdir "$KDIR2B" --json)
assert_json_eq "paused process_once short-circuits dispatch" "$PAUSED_PROCESS" '.dispatched' "false"
assert_json_eq "paused process_once reports disabled reason" "$PAUSED_PROCESS" '.reason' "disabled"
assert_json_eq "paused process_once still reclaims expired lease" "$PAUSED_PROCESS" '.expired_leases_reclaimed' "1"
assert_json_eq "paused sweep returns item to pending" "$PAUSED_STATUS" '.counts.pending' "1"
assert_json_eq "paused sweep clears leased count" "$PAUSED_STATUS" '.counts.leased // 0' "0"
assert_json_eq "paused sweep clears active leases" "$PAUSED_STATUS" '.active_leases' "0"

echo ""
echo "Test 5: active lease remains visible while executor runs"
KDIR3="$TEST_DIR/kdir3"
SETTINGS3="$TEST_DIR/settings3.json"
setup_kdir "$KDIR3" "wi"
write_settings "$SETTINGS3" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"executor_timeout_seconds":5,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS3B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS4" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[],"enabled":false},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"random","eligible_frameworks":["phantom","claude-code"]}}}'
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
write_settings "$SETTINGS5" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"executor_timeout_seconds":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS6" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"active_hours":{"enabled":true,"timezone":"UTC","ranges":[{"days":["mon"],"start":"09:00","end":"10:00"},{"days":["mon"],"start":"13:00","end":"14:00"}]},"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS7" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"active_hours":{"enabled":true,"timezone":"UTC"},"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
setup_task_claims_smoke_fixture "$KDIR8" "$SMOKE_SLUG"
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
echo "Test 11b: shipped executor extracts per-claim correction from envelope-shaped verdicts file"
# Regression for the verdicts-file parser: audit-artifact.sh writes one ENVELOPE
# per judge run (wrapper around `verdicts: [...]`), but the executor's prior
# extractor expected flat per-row shape. That mismatch caused every contradicted
# run on every project to ship `correction: null`, which surfaced in the TUI as
# `contradicted → skip:empty_correction_text` via apply-correction's gate.
KDIR8F="$TEST_DIR/kdir8f"
SETTINGS8F="$TEST_DIR/settings8f.json"
GATE8F="$TEST_DIR/gate8f.json"
SMOKE_SLUG_F="settlement-smoke-contradicted"
setup_task_claims_smoke_fixture "$KDIR8F" "$SMOKE_SLUG_F"
printf '%s' "$(row_json "assertion-0")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8F" bash "$QUEUE" enqueue --work-item "$SMOKE_SLUG_F" --kdir "$KDIR8F" --json >/dev/null
write_settings "$SETTINGS8F" "$(jq -nc '{
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
    {"claim_id": "assertion-0", "verdict": "contradicted", "evidence": "per-claim contradicted evidence", "correction": "Replace with the corrected claim body"}
  ]
}' > "$GATE8F"
# Suppress auto-correction so the test does not depend on commons mutation;
# we only need to assert that verdict.correction flows through the envelope.
SMOKE_ARGS_F=$(printf -- '--kdir %q --gate-output-file %q' "$KDIR8F" "$GATE8F")
SMOKE_F=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS8F" LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION=1 LORE_SETTLEMENT_AUDIT_ARGS="$SMOKE_ARGS_F" bash "$QUEUE" process --kdir "$KDIR8F" --once --json)
assert_json_eq "contradicted shipped executor run completed" "$SMOKE_F" '.run.status' "completed"
assert_json_eq "contradicted run carries envelope verdict" "$SMOKE_F" '.run.verdict.verdict' "contradicted"
assert_json_eq "contradicted run extracts per-claim correction" "$SMOKE_F" '.run.verdict.correction' "Replace with the corrected claim body"
assert_json_eq "contradicted run extracts per-claim evidence" "$SMOKE_F" '.run.verdict.evidence' "per-claim contradicted evidence"

echo ""
echo "Test 12: retry-errors requeues structured audit errors"
KDIR8B="$TEST_DIR/kdir8b"
SETTINGS8B="$TEST_DIR/settings8b.json"
ERROR_EXEC="$TEST_DIR/error-envelope-exec.sh"
setup_kdir "$KDIR8B" "wi"
write_settings "$SETTINGS8B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS8C" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"executor_timeout_seconds":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS8D" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
echo "Test 12e: audit executor treats exit 3 (grounding preflight routed) as informational success"
# Regression coverage for the exit-3 classification fix. `lore audit` exits 3
# when the reverse-auditor omission claim is routed to audit-attempts.jsonl
# (grounding preflight failed), but it prints a complete verdict JSON first.
# The prior any-non-zero=error branch discarded that JSON and emitted
# verdict=error, converting adjudicated claims into executor_audit_error. The
# fix parses the exit-3 stdout and derives the real envelope verdict.
KDIR8G="$TEST_DIR/kdir8g"
mkdir -p "$KDIR8G/_work/wi"
printf '%s\n' "$(row_json "claim-exit3")" > "$KDIR8G/_work/wi/task-claims.jsonl"
# Stub `lore` to mimic an exit-3 audit: full verified verdict JSON on stdout,
# a [audit] diagnostic on stderr, then exit 3.
FAKE_BIN_12E="$TEST_DIR/fake-bin-12e"
mkdir -p "$FAKE_BIN_12E"
cat > "$FAKE_BIN_12E/lore" <<'BIN'
#!/usr/bin/env bash
echo '{"correctness_gate":{"verified":1,"unverified":0,"contradicted":0,"verdicts_total":1}}'
echo '[audit] reverse-auditor omission routed to audit-attempts.jsonl (grounding preflight failed)' >&2
exit 3
BIN
chmod +x "$FAKE_BIN_12E/lore"
EXEC_STDERR_12E="$TEST_DIR/12e-stderr.txt"
EXEC_STDOUT_12E=$(printf '%s' '{"item": {"work_item": "wi", "claim_id": "claim-exit3"}}' | \
  PATH="$FAKE_BIN_12E:$PATH" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR8G" bash "$SCRIPTS_DIR/settlement-audit-executor.sh" 2>"$EXEC_STDERR_12E")
# stdout must be exactly one parseable JSON envelope (no stderr bleed).
EXEC_STDOUT_12E_LINES=$(printf '%s\n' "$EXEC_STDOUT_12E" | grep -c .)
assert_eq "exit-3 executor emits exactly one stdout line" "$EXEC_STDOUT_12E_LINES" "1"
assert_json_eq "exit-3 run derives real verdict, not error" "$EXEC_STDOUT_12E" '.verdict' "verified"
assert_json_eq "exit-3 envelope retains the audit correctness_gate block" "$EXEC_STDOUT_12E" '.audit.correctness_gate.verified' "1"
assert_json_eq "exit-3 executor records inner exit code 3" "$EXEC_STDOUT_12E" '.executor.exit_code' "3"
EXIT3_LOG_COUNT=$(grep -c 'audit exit 3' "$EXEC_STDERR_12E" || true)
assert_eq "exit-3 executor logs the informational-exit diagnostic to stderr" "$EXIT3_LOG_COUNT" "1"
# A genuine failure exit (non-3) must still produce verdict=error.
FAKE_BIN_12E_FAIL="$TEST_DIR/fake-bin-12e-fail"
mkdir -p "$FAKE_BIN_12E_FAIL"
cat > "$FAKE_BIN_12E_FAIL/lore" <<'BIN'
#!/usr/bin/env bash
echo '[audit] crashed before judging' >&2
exit 2
BIN
chmod +x "$FAKE_BIN_12E_FAIL/lore"
EXEC_STDOUT_12E_FAIL=$(printf '%s' '{"item": {"work_item": "wi", "claim_id": "claim-exit3"}}' | \
  PATH="$FAKE_BIN_12E_FAIL:$PATH" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR8G" bash "$SCRIPTS_DIR/settlement-audit-executor.sh" 2>/dev/null)
assert_json_eq "non-3 failure exit still produces error verdict" "$EXEC_STDOUT_12E_FAIL" '.verdict' "error"

echo ""
echo "Test 13: recompute scores only batch_size rows and exposes bounds"
KDIR9="$TEST_DIR/kdir9"
SETTINGS9="$TEST_DIR/settings9.json"
COUNT9="$TEST_DIR/score-count9"
SCORE9="$TEST_DIR/score9.sh"
setup_kdir "$KDIR9" "wi"
write_settings "$SETTINGS9" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"concordance_window_size":7,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS10" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS11" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS12" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":2,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS13" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":1,"batch_recompute_min_interval_seconds":9999,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS14" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
for cid in claim-tie-a claim-tie-b claim-tie-c; do printf '%s\n' "$(row_json "$cid")" >> "$KDIR14/_work/wi/task-claims.jsonl"; done
printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf '"'"'{"score": 2}\n'"'"'\n' > "$SCORE14"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 22\n' > "$ERR14"
chmod +x "$SCORE14" "$ERR14"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14" LORE_SETTLEMENT_SCORE_HOOK="$SCORE14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
ORDER_A=$(jq -r '[.items[].claim_id] | join(",")' "$KDIR14/_settlement/queue.json")
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14" LORE_SETTLEMENT_SCORE_HOOK="$SCORE14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
ORDER_B=$(jq -r '[.items[].claim_id] | join(",")' "$KDIR14/_settlement/queue.json")
assert_eq "equal relevance scores keep durable FIFO order" "$ORDER_B" "$ORDER_A"
write_settings "$SETTINGS14B" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14B" LORE_SETTLEMENT_SCORE_HOOK="$ERR14" bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
assert_json_eq "score hook errors degrade to fallback_error" "$(cat "$KDIR14/_settlement/queue.json")" '[.items[].selection_reason] | unique | .[0]' "fallback_error"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS14B" LORE_SETTLEMENT_RELEVANCE_DISABLED=1 bash "$QUEUE" queue recompute --kdir "$KDIR14" --json >/dev/null
assert_json_eq "disabled relevance uses FIFO fallback reason" "$(cat "$KDIR14/_settlement/queue.json")" '[.items[].selection_reason] | unique | .[0]' "fallback_fifo"

echo ""
echo "Test 19: legacy pending is normalized before selection"
KDIR15="$TEST_DIR/kdir15"
SETTINGS15="$TEST_DIR/settings15.json"
setup_kdir "$KDIR15" "wi"
write_settings "$SETTINGS15" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"batch_size":1,"batch_recompute_min_interval_seconds":9999,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
write_settings "$SETTINGS16" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
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
echo "Test 17: drain on empty queue returns aborted=false with iterations=1"
KDIR_DR1="$TEST_DIR/kdir-drain-empty"
SETTINGS_DR1="$TEST_DIR/settings-drain-empty.json"
setup_kdir "$KDIR_DR1" "wi"
write_settings "$SETTINGS_DR1" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
DRAIN_EMPTY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DR1" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" drain --kdir "$KDIR_DR1" --json)
assert_json_eq "drain empty queue not aborted" "$DRAIN_EMPTY" '.aborted' "false"
assert_json_eq "drain empty queue early-exits in one iteration" "$DRAIN_EMPTY" '.iterations' "1"
assert_json_eq "drain empty queue dispatched zero" "$DRAIN_EMPTY" '.dispatched' "0"
assert_json_eq "drain empty queue remaining zero" "$DRAIN_EMPTY" '.remaining' "0"
assert_json_eq "drain empty queue last_reason empty_queue" "$DRAIN_EMPTY" '.last_reason' "empty_queue"

echo ""
echo "Test 18: drain enforces --max-iterations cap"
KDIR_DR2="$TEST_DIR/kdir-drain-cap"
SETTINGS_DR2="$TEST_DIR/settings-drain-cap.json"
setup_kdir "$KDIR_DR2" "wi"
write_settings "$SETTINGS_DR2" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
for i in 1 2 3 4 5; do
  printf '%s' "$(row_json "claim-drain-cap-$i")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DR2" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR_DR2" --json >/dev/null
done
DRAIN_CAP=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DR2" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" drain --kdir "$KDIR_DR2" --max-iterations 2 --json)
assert_json_eq "drain cap reaches exactly max-iterations" "$DRAIN_CAP" '.iterations' "2"
assert_json_eq "drain cap dispatched two items" "$DRAIN_CAP" '.dispatched' "2"
assert_json_eq "drain cap leaves three items pending" "$DRAIN_CAP" '.remaining' "3"
assert_json_eq "drain cap not aborted on iteration cap" "$DRAIN_CAP" '.aborted' "false"

echo ""
echo "Test 19: drain aborts on hard-cal gate uncalibrated (calibration-failed marker)"
KDIR_DR3="$TEST_DIR/kdir-drain-abort"
SETTINGS_DR3="$TEST_DIR/settings-drain-abort.json"
setup_kdir "$KDIR_DR3" "wi"
write_settings "$SETTINGS_DR3" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s' "$(row_json "claim-drain-abort")" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DR3" bash "$QUEUE" enqueue --work-item wi --kdir "$KDIR_DR3" --json >/dev/null
GATE_VERSION=$("$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/correctness-gate-assertion.md")
mkdir -p "$KDIR_DR3/_scorecards"
jq -nc --arg key "correctness-gate-assertion:$GATE_VERSION" '{($key): {calibration_state: "calibration-failed"}}' > "$KDIR_DR3/_scorecards/calibration-state.json"
DRAIN_ABORT=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_DR3" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" bash "$QUEUE" drain --kdir "$KDIR_DR3" --json)
assert_json_eq "drain aborts on calibration-failed marker" "$DRAIN_ABORT" '.aborted' "true"
assert_json_eq "drain abort dispatched zero" "$DRAIN_ABORT" '.dispatched' "0"
assert_json_eq "drain abort surfaces hard-cal reason" "$DRAIN_ABORT" '.last_reason | startswith("audit-error: hard-cal gate uncalibrated")' "true"
assert_json_eq "drain abort leaves item pending" "$DRAIN_ABORT" '.remaining' "1"

echo ""
echo "Test 21: status health block matches the D4 contract (field names, types, windows)"
KDIR_HB="$TEST_DIR/kdir-health"
SETTINGS_HB="$TEST_DIR/settings-health.json"
setup_kdir "$KDIR_HB" "wi"
write_settings "$SETTINGS_HB" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}}}'
NOW_HB="2026-05-13T12:00:00Z"
python3 - "$KDIR_HB" <<'PY'
import json, pathlib, sys
k = pathlib.Path(sys.argv[1]) / "_settlement"
runs = k / "runs"
runs.mkdir(parents=True, exist_ok=True)
# Pending item enqueued 120s before the pinned now; pump ran 60s before.
json.dump({
    "version": 1,
    "items": [{"id": "item-pending", "status": "pending", "enqueued_at": "2026-05-13T11:58:00Z"}],
    "batch": {},
    "triggers": {"pump_ran_at": "2026-05-13T11:59:00Z"},
}, open(k / "queue.json", "w"))
json.dump({"version": 1, "leases": {}}, open(k / "leases.json", "w"))
def run(name, status, completed_at, **extra):
    row = {"version": 1, "run_id": name, "item_id": f"item-{name}", "work_item": "wi",
           "claim_id": name, "status": status, "completed_at": completed_at,
           "verdict": {"verdict": "verified", "evidence": "fixture"}}
    row.update(extra)
    json.dump(row, open(runs / f"{name}.json", "w"))
run("comp-a", "completed", "2026-05-13T11:00:00Z")                    # in 24h, today
run("comp-b", "completed", "2026-05-12T13:00:00Z")                    # in 24h, yesterday
run("comp-old", "completed", "2026-05-10T12:00:00Z")                  # outside 24h
run("fail-today", "failed", "2026-05-13T10:00:00Z")                   # in 24h, today
run("requeued", "failed", "2026-05-13T09:00:00Z",
    invalidated_at="2026-05-13T09:30:00Z",
    invalidated_reason="retry_infrastructure_failure")                # invalidated today
PY
STATUS_HB=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HB" LORE_SETTLEMENT_NOW="$NOW_HB" bash "$QUEUE" status --kdir "$KDIR_HB" --json)
# The health block is the shell→python→Go bridging contract Phase 2 parses:
# assert the exact field set and each field's JSON type explicitly.
assert_json_eq "health block carries exactly the D4 field set" "$STATUS_HB" '.health | keys | sort | join(",")' "completions_24h,drain_rate_per_hour,failures_today,oldest_pending_age_seconds,requeues_today"
assert_json_eq "drain_rate_per_hour is a number" "$STATUS_HB" '.health.drain_rate_per_hour | type' "number"
assert_json_eq "completions_24h is an integer" "$STATUS_HB" '(.health.completions_24h | type == "number") and (.health.completions_24h == (.health.completions_24h | floor))' "true"
assert_json_eq "requeues_today is an integer" "$STATUS_HB" '(.health.requeues_today | type == "number") and (.health.requeues_today == (.health.requeues_today | floor))' "true"
assert_json_eq "failures_today is an integer" "$STATUS_HB" '(.health.failures_today | type == "number") and (.health.failures_today == (.health.failures_today | floor))' "true"
assert_json_eq "completions_24h counts terminal non-invalidated runs in trailing 24h" "$STATUS_HB" '.health.completions_24h' "3"
assert_json_eq "drain rate is completions_24h / 24" "$STATUS_HB" '.health.drain_rate_per_hour' "0.12"
assert_json_eq "failures_today counts failed runs completed today" "$STATUS_HB" '.health.failures_today' "2"
assert_json_eq "requeues_today counts retry_infrastructure_failure invalidations today" "$STATUS_HB" '.health.requeues_today' "1"
assert_json_eq "oldest_pending_age_seconds is now minus min pending enqueued_at" "$STATUS_HB" '.health.oldest_pending_age_seconds' "120"
assert_json_eq "auditor_model echoes null when unset" "$STATUS_HB" '.auditor_model' "null"
assert_json_eq "pump liveness echoes triggers.pump_ran_at" "$STATUS_HB" '.dispatch.pump.last_ran_at' "2026-05-13T11:59:00Z"
assert_json_eq "pump seconds_since_last derives from the same echo" "$STATUS_HB" '.dispatch.pump.seconds_since_last' "60"

echo ""
echo "Test 21b: verify_volume weeks split held/contradicted by ledger payload.disposition"
mkdir -p "$KDIR_HB/_trust"
# Week window under NOW_HB=2026-05-13: current week starts Mon 2026-05-11;
# weeks[-1] is the completed week starting Mon 2026-05-04.
cat > "$KDIR_HB/_trust/trust-events.jsonl" <<'LEDGER'
{"event":"consumption-verification","observed_at":"2026-05-05T10:00:00Z","payload":{"disposition":"held"}}
{"event":"consumption-verification","observed_at":"2026-05-06T10:00:00Z","payload":{"disposition":"held"}}
{"event":"consumption-verification","observed_at":"2026-05-06T11:00:00Z","payload":{"disposition":"contradicted"}}
{"event":"consumption-verification","observed_at":"2026-05-07T10:00:00Z"}
{"event":"consumption-verification","observed_at":"2026-05-12T10:00:00Z","payload":{"disposition":"held"}}
{"event":"other-event","observed_at":"2026-05-05T12:00:00Z","payload":{"disposition":"held"}}
LEDGER
STATUS_VV=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HB" LORE_SETTLEMENT_NOW="$NOW_HB" bash "$QUEUE" status --kdir "$KDIR_HB" --json)
assert_json_eq "last completed week counts all verify events" "$STATUS_VV" '.dispatch.verify_volume.weeks[-1].events' "4"
assert_json_eq "last completed week held split" "$STATUS_VV" '.dispatch.verify_volume.weeks[-1].held' "2"
assert_json_eq "last completed week contradicted split" "$STATUS_VV" '.dispatch.verify_volume.weeks[-1].contradicted' "1"
assert_json_eq "dispositionless rows count in events but neither split" "$STATUS_VV" '.dispatch.verify_volume.weeks[-1] | .events - .held - .contradicted' "1"
assert_json_eq "current-week events stay out of the completed weeks" "$STATUS_VV" '.dispatch.verify_volume.current_week_events' "1"

echo ""
echo "Test 22: schedule and model verbs mutate exactly one settings field and embed full status"
KDIR_VB="$TEST_DIR/kdir-verbs"
SETTINGS_VB="$TEST_DIR/settings-verbs.json"
setup_kdir "$KDIR_VB" "wi"
write_settings "$SETTINGS_VB" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"active_hours":{"enabled":true,"timezone":"UTC"}}}'
SNAP_BEFORE=$(jq -S 'del(.settlement.active_hours.enabled)' "$SETTINGS_VB")
SCHED_OFF=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" schedule off --kdir "$KDIR_VB" --json)
SNAP_AFTER=$(jq -S 'del(.settlement.active_hours.enabled)' "$SETTINGS_VB")
assert_json_eq "schedule off returns ok" "$SCHED_OFF" '.ok' "true"
assert_json_eq "schedule off action label" "$SCHED_OFF" '.action' "schedule-off"
assert_json_eq "schedule off flips the flag" "$SCHED_OFF" '.enabled' "false"
assert_json_eq "schedule off embeds full status" "$SCHED_OFF" '.status.active_hours.enabled' "false"
assert_json_eq "schedule off persists the flag" "$(cat "$SETTINGS_VB")" '.settlement.active_hours.enabled' "false"
assert_eq "schedule verb mutates only active_hours.enabled" "$SNAP_AFTER" "$SNAP_BEFORE"
SCHED_ON=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" schedule on --kdir "$KDIR_VB" --json)
assert_json_eq "schedule on flips the flag back" "$SCHED_ON" '.enabled' "true"
if LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" schedule sideways --kdir "$KDIR_VB" --json >/dev/null 2>&1; then
  echo "  FAIL: schedule accepted an invalid subcommand"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: schedule rejects invalid subcommand"
  PASS=$((PASS + 1))
fi

SNAP_MODEL_BEFORE=$(jq -S 'del(.settlement.auditor_model)' "$SETTINGS_VB")
MODEL_SET=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" model sonnet --kdir "$KDIR_VB" --json)
SNAP_MODEL_AFTER=$(jq -S 'del(.settlement.auditor_model)' "$SETTINGS_VB")
assert_json_eq "model set returns ok" "$MODEL_SET" '.ok' "true"
assert_json_eq "model set action label" "$MODEL_SET" '.action' "model-set"
assert_json_eq "model set echoes the alias" "$MODEL_SET" '.auditor_model' "sonnet"
assert_json_eq "model set embeds status with the echo" "$MODEL_SET" '.status.auditor_model' "sonnet"
assert_json_eq "model set persists the field" "$(cat "$SETTINGS_VB")" '.settlement.auditor_model' "sonnet"
assert_eq "model verb mutates only auditor_model" "$SNAP_MODEL_AFTER" "$SNAP_MODEL_BEFORE"
MODEL_UNSET=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" model --unset --kdir "$KDIR_VB" --json)
assert_json_eq "model --unset action label" "$MODEL_UNSET" '.action' "model-unset"
assert_json_eq "model --unset echoes null" "$MODEL_UNSET" '.auditor_model' "null"
assert_json_eq "model --unset removes the key" "$(cat "$SETTINGS_VB")" '.settlement | has("auditor_model")' "false"
assert_json_eq "model --unset embeds status echoing null" "$MODEL_UNSET" '.status.auditor_model' "null"
if LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" model --kdir "$KDIR_VB" --json >/dev/null 2>&1; then
  echo "  FAIL: model accepted a call with neither alias nor --unset"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: model rejects a call with neither alias nor --unset"
  PASS=$((PASS + 1))
fi
if LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_VB" bash "$QUEUE" model sonnet --unset --kdir "$KDIR_VB" --json >/dev/null 2>&1; then
  echo "  FAIL: model accepted alias and --unset together"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: model rejects alias and --unset together"
  PASS=$((PASS + 1))
fi

echo ""
echo "Test 23: settlement executor exports LORE_MODEL_JUDGE from settlement.auditor_model only when set"
KDIR_EX="$TEST_DIR/kdir-executor-model"
SETTINGS_EX="$TEST_DIR/settings-executor-model.json"
mkdir -p "$KDIR_EX/_work/wi"
printf '%s\n' "$(row_json "claim-model-export")" > "$KDIR_EX/_work/wi/task-claims.jsonl"
FAKE_BIN_EX="$TEST_DIR/fake-bin-executor-model"
mkdir -p "$FAKE_BIN_EX"
cat > "$FAKE_BIN_EX/lore" <<'BIN'
#!/usr/bin/env bash
printf '{"correctness_gate":{"verified":1,"unverified":0,"contradicted":0,"verdicts_total":1},"judge_model_env":"%s"}\n' "${LORE_MODEL_JUDGE:-unset}"
BIN
chmod +x "$FAKE_BIN_EX/lore"
write_settings "$SETTINGS_EX" '{"version":1,"settlement":{"auditor_model":"sonnet"}}'
EX_SET=$(printf '%s' '{"item":{"work_item":"wi","claim_id":"claim-model-export"}}' | \
  PATH="$FAKE_BIN_EX:$PATH" LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_EX" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR_EX" LORE_MODEL_JUDGE="inherited-env" \
  bash "$SCRIPTS_DIR/settlement-audit-executor.sh" 2>/dev/null)
assert_json_eq "auditor_model set overrides inherited LORE_MODEL_JUDGE" "$EX_SET" '.audit.judge_model_env' "sonnet"
write_settings "$SETTINGS_EX" '{"version":1,"settlement":{}}'
EX_INHERIT=$(printf '%s' '{"item":{"work_item":"wi","claim_id":"claim-model-export"}}' | \
  PATH="$FAKE_BIN_EX:$PATH" LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_EX" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR_EX" LORE_MODEL_JUDGE="inherited-env" \
  bash "$SCRIPTS_DIR/settlement-audit-executor.sh" 2>/dev/null)
assert_json_eq "auditor_model unset preserves inherited LORE_MODEL_JUDGE" "$EX_INHERIT" '.audit.judge_model_env' "inherited-env"
EX_NONE=$(printf '%s' '{"item":{"work_item":"wi","claim_id":"claim-model-export"}}' | \
  PATH="$FAKE_BIN_EX:$PATH" LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_EX" LORE_SETTLEMENT_AUDIT_ARGS="--kdir $KDIR_EX" \
  bash "$SCRIPTS_DIR/settlement-audit-executor.sh" 2>/dev/null)
assert_json_eq "auditor_model unset without env leaves resolution untouched" "$EX_NONE" '.audit.judge_model_env' "unset"

# --- Bounded auto-retry for infrastructure-failure runs (Tests 24-29) ---
# Shared stub: always emits an error envelope -> executor_audit_error run (an
# infrastructure failure, not a settled verdict). run_id derives from
# item_id + wall-clock second, so same-item redispatch needs sleep 1.1 between
# process cycles to avoid run_id collision (which would silently drop a run).
AR_ERR_EXEC="$TEST_DIR/ar-error-exec.sh"
cat > "$AR_ERR_EXEC" <<'EXEC'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"verdict_envelope_version":1,"verdict":"error","evidence":"fixture infra failure before judging the claim","correction":null}'
EXEC
chmod +x "$AR_ERR_EXEC"

# The trigger pump also runs rollup steady-state, which would enqueue five
# rollup items ahead of the spot-sample task-claim on every `triggers` call.
# Pin now to a fixed Wednesday and seed a template row per judge for that
# week's completed window so the existence check suppresses rollup enqueue,
# leaving spot_sample as the sole event-driven re-enqueue path under test.
AR_NOW="2026-05-13T12:00:00Z"
AR_ROLLUP_WINDOW="2026-05-04T00:00:00Z"
seed_rollup_suppression() {
  local kdir="$1"
  mkdir -p "$kdir/_scorecards"
  {
    for judge in correctness-gate-assertion correctness-gate-omission correctness-gate-contradiction curator reverse-auditor; do
      printf '{"tier":"template","verdict_source":"%s","window_start":"%s"}\n' "$judge" "$AR_ROLLUP_WINDOW"
    done
  } > "$kdir/_scorecards/rows.jsonl"
}

echo ""
echo "Test 24: bounded auto-retry re-audits below cap then exhausts (event-driven surface)"
KDIR_ARED="$TEST_DIR/kdir-autoretry-ed"
SETTINGS_ARED="$TEST_DIR/settings-autoretry-ed.json"
setup_kdir "$KDIR_ARED" "wi"
write_settings "$SETTINGS_ARED" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-autoretry-ed")" >> "$KDIR_ARED/_work/wi/task-claims.jsonl"
seed_rollup_suppression "$KDIR_ARED"
for _cycle in 1 2 3; do
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARED" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_ARED" --force --json >/dev/null
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARED" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_ARED" --once --json >/dev/null
  sleep 1.1
done
ARED_RUNS=$(find "$KDIR_ARED/_settlement/runs" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "event-driven: three infra-failure run records accumulated" "$ARED_RUNS" "3"
ARED_TRIG4=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARED" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_ARED" --force --json)
assert_json_eq "event-driven: exhausted item no longer re-sampled" "$ARED_TRIG4" '.spot_sample.enqueued' "0"
ARED_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARED" bash "$QUEUE" status --kdir "$KDIR_ARED" --json)
assert_json_eq "event-driven: one item reported exhausted" "$ARED_STATUS" '.infra_exhausted.count' "1"
assert_json_eq "event-driven: exhausted preview names last failure reason" "$ARED_STATUS" '.infra_exhausted.items[0].reason' "executor_audit_error"
assert_json_eq "event-driven: exhausted preview carries failure_count" "$ARED_STATUS" '.infra_exhausted.items[0].failure_count' "3"
assert_json_eq "event-driven: exhausted preview identifies work_item" "$ARED_STATUS" '.infra_exhausted.items[0].work_item' "wi"
assert_json_eq "event-driven: remedy names retry-errors" "$ARED_STATUS" '.infra_exhausted.remedy' "lore settlement retry-errors"

echo ""
echo "Test 25: bounded auto-retry re-batches below cap then stops batching (census surface)"
KDIR_ARC="$TEST_DIR/kdir-autoretry-census"
SETTINGS_ARC="$TEST_DIR/settings-autoretry-census.json"
setup_kdir "$KDIR_ARC" "wi"
write_settings "$SETTINGS_ARC" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-autoretry-census")" >> "$KDIR_ARC/_work/wi/task-claims.jsonl"
for _cycle in 1 2 3; do
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARC" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_ARC" --once --json >/dev/null
  sleep 1.1
done
ARC_RUNS=$(find "$KDIR_ARC/_settlement/runs" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "census: three infra-failure run records accumulated" "$ARC_RUNS" "3"
ARC_PROC4=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARC" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_ARC" --once --json)
assert_json_eq "census: exhausted item no longer batched" "$ARC_PROC4" '.reason' "empty_queue"
ARC_RUNS_AFTER=$(find "$KDIR_ARC/_settlement/runs" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "census: no fourth run produced" "$ARC_RUNS_AFTER" "3"
ARC_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_ARC" bash "$QUEUE" status --kdir "$KDIR_ARC" --json)
assert_json_eq "census: one item reported exhausted" "$ARC_STATUS" '.infra_exhausted.count' "1"
assert_json_eq "census: exhausted preview carries failure_count" "$ARC_STATUS" '.infra_exhausted.items[0].failure_count' "3"

echo ""
echo "Test 26: a genuine settle supersedes prior infra-failure runs and excludes re-audit"
KDIR_SUP="$TEST_DIR/kdir-supersede"
SETTINGS_SUP="$TEST_DIR/settings-supersede.json"
SUP_MARKER="$TEST_DIR/supersede-counter"
SUP_EXEC="$TEST_DIR/ar-settle-exec.sh"
setup_kdir "$KDIR_SUP" "wi"
write_settings "$SETTINGS_SUP" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-supersede")" >> "$KDIR_SUP/_work/wi/task-claims.jsonl"
seed_rollup_suppression "$KDIR_SUP"
# Stateful stub: first dispatch infra-fails, every later dispatch settles.
cat > "$SUP_EXEC" <<EXEC
#!/usr/bin/env bash
cat >/dev/null
n=\$(cat "$SUP_MARKER" 2>/dev/null || echo 0)
n=\$((n + 1)); echo "\$n" > "$SUP_MARKER"
if [ "\$n" -le 1 ]; then
  printf '%s\n' '{"verdict_envelope_version":1,"verdict":"error","evidence":"first attempt infra failure","correction":null}'
else
  printf '%s\n' '{"verdict_envelope_version":1,"verdict":"verified","evidence":"the claim holds under audit on retry","correction":null}'
fi
EXEC
chmod +x "$SUP_EXEC"
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_SUP" --force --json >/dev/null
SUP_RUN1=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" LORE_SETTLEMENT_EXECUTOR="$SUP_EXEC" bash "$QUEUE" process --kdir "$KDIR_SUP" --once --json)
SUP_RUN1_ID=$(printf '%s' "$SUP_RUN1" | jq -r '.run.run_id')
assert_json_eq "supersede: first attempt is an infra failure" "$SUP_RUN1" '.run.reason' "executor_audit_error"
sleep 1.1
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_SUP" --force --json >/dev/null
SUP_RUN2=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" LORE_SETTLEMENT_EXECUTOR="$SUP_EXEC" bash "$QUEUE" process --kdir "$KDIR_SUP" --once --json)
assert_json_eq "supersede: second attempt settles genuinely" "$SUP_RUN2" '.run.verdict.verdict' "verified"
assert_json_eq "supersede: prior infra run invalidated by settle" "$(cat "$KDIR_SUP/_settlement/runs/$SUP_RUN1_ID.json")" '.invalidated_reason' "superseded_by_settled_run"
sleep 1.1
SUP_TRIG3=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_SUP" --force --json)
assert_json_eq "supersede: settled item not re-sampled" "$SUP_TRIG3" '.spot_sample.enqueued' "0"
SUP_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_SUP" bash "$QUEUE" status --kdir "$KDIR_SUP" --json)
assert_json_eq "supersede: settled item is not exhausted" "$SUP_STATUS" '.infra_exhausted.count' "0"

echo ""
echo "Test 27: retry-errors resets the full ledger and the requeue survives census recompute (archived source)"
KDIR_RR="$TEST_DIR/kdir-retry-reset"
SETTINGS_RR="$TEST_DIR/settings-retry-reset.json"
setup_kdir "$KDIR_RR" "wi"
write_settings "$SETTINGS_RR" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-retry-reset")" >> "$KDIR_RR/_work/wi/task-claims.jsonl"
for _cycle in 1 2 3; do
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_RR" --once --json >/dev/null
  sleep 1.1
done
RR_STATUS_EXH=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" status --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: item is exhausted before retry-errors" "$RR_STATUS_EXH" '.infra_exhausted.count' "1"
# Archive the source so the requeued item is absent from the backlog glob:
# only _preserved() keeps it through the intervening census recompute.
mkdir -p "$KDIR_RR/_work/_archive"
mv "$KDIR_RR/_work/wi" "$KDIR_RR/_work/_archive/wi"
RR_RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" retry-errors --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: invalidated counts all three run records" "$RR_RETRY" '.invalidated' "3"
assert_json_eq "retry-reset: matched counts one item" "$RR_RETRY" '.matched' "1"
assert_json_eq "retry-reset: enqueued counts one item" "$RR_RETRY" '.enqueued' "1"
RR_RECOMPUTE=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" queue recompute --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: census recompute runs" "$RR_RECOMPUTE" '.recomputed' "true"
RR_STATUS_AFTER=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" status --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: requeued item survives recompute" "$RR_STATUS_AFTER" '.counts.pending' "1"
assert_json_eq "retry-reset: surviving item carries retry selection reason" "$RR_STATUS_AFTER" '.items[0].selection_reason' "retry_infrastructure_failure"
assert_json_eq "retry-reset: no longer counts as exhausted" "$RR_STATUS_AFTER" '.infra_exhausted.count' "0"
# No-match: with every infra run already invalidated, a second retry-errors is a no-op.
RR_NOMATCH=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" retry-errors --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: no-match reports zero matched" "$RR_NOMATCH" '.matched' "0"
assert_json_eq "retry-reset: no-match reports zero invalidated" "$RR_NOMATCH" '.invalidated' "0"
assert_json_eq "retry-reset: no-match reports zero enqueued" "$RR_NOMATCH" '.enqueued' "0"
RR_STATUS_NOMATCH=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_RR" bash "$QUEUE" status --kdir "$KDIR_RR" --json)
assert_json_eq "retry-reset: no-match leaves the queue unchanged" "$RR_STATUS_NOMATCH" '.counts.pending' "1"

echo ""
echo "Test 28: retry-errors requeue survives an intervening heal_queue tick (event-driven)"
KDIR_HS="$TEST_DIR/kdir-heal-survive"
SETTINGS_HS="$TEST_DIR/settings-heal-survive.json"
SETTINGS_HS_OFF="$TEST_DIR/settings-heal-survive-off.json"
setup_kdir "$KDIR_HS" "wi"
write_settings "$SETTINGS_HS" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
# Same posture with dispatch disabled: process --once then runs heal_queue only.
write_settings "$SETTINGS_HS_OFF" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":false,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-heal-survive")" >> "$KDIR_HS/_work/wi/task-claims.jsonl"
seed_rollup_suppression "$KDIR_HS"
for _cycle in 1 2 3; do
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HS" LORE_SETTLEMENT_NOW="$AR_NOW" bash "$QUEUE" triggers --kdir "$KDIR_HS" --force --json >/dev/null
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HS" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_HS" --once --json >/dev/null
  sleep 1.1
done
HS_RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HS" bash "$QUEUE" retry-errors --kdir "$KDIR_HS" --json)
assert_json_eq "heal-survive: retry-errors requeued the exhausted item" "$HS_RETRY" '.enqueued' "1"
HS_HEAL=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HS_OFF" bash "$QUEUE" process --kdir "$KDIR_HS" --once --json)
assert_json_eq "heal-survive: heal-only tick does not dispatch" "$HS_HEAL" '.dispatched' "false"
HS_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_HS" bash "$QUEUE" status --kdir "$KDIR_HS" --json)
assert_json_eq "heal-survive: requeued item survives the heal tick" "$HS_STATUS" '.counts.pending' "1"
assert_json_eq "heal-survive: surviving item keeps retry selection reason" "$HS_STATUS" '.items[0].selection_reason' "retry_infrastructure_failure"

echo ""
echo "Test 29: max_auto_retry_attempts=0 reproduces immediate exclusion (current behavior)"
KDIR_CAP0="$TEST_DIR/kdir-cap0"
SETTINGS_CAP0="$TEST_DIR/settings-cap0.json"
setup_kdir "$KDIR_CAP0" "wi"
write_settings "$SETTINGS_CAP0" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":true},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":0,"batch_size":4,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
printf '%s\n' "$(row_json "claim-cap0")" >> "$KDIR_CAP0/_work/wi/task-claims.jsonl"
CAP0_RUN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_CAP0" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_CAP0" --once --json)
assert_json_eq "cap0: first infra failure recorded" "$CAP0_RUN" '.run.reason' "executor_audit_error"
sleep 1.1
CAP0_PROC2=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_CAP0" LORE_SETTLEMENT_EXECUTOR="$AR_ERR_EXEC" bash "$QUEUE" process --kdir "$KDIR_CAP0" --once --json)
assert_json_eq "cap0: single infra failure excludes item immediately" "$CAP0_PROC2" '.reason' "empty_queue"
CAP0_RUNS=$(find "$KDIR_CAP0/_settlement/runs" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "cap0: no auto-retry run produced" "$CAP0_RUNS" "1"
CAP0_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_CAP0" bash "$QUEUE" status --kdir "$KDIR_CAP0" --json)
assert_json_eq "cap0: item exhausted after one failure" "$CAP0_STATUS" '.infra_exhausted.count' "1"
CAP0_RETRY=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_CAP0" bash "$QUEUE" retry-errors --kdir "$KDIR_CAP0" --json)
assert_json_eq "cap0: manual retry-errors still resets the one run" "$CAP0_RETRY" '.invalidated' "1"
assert_json_eq "cap0: manual retry-errors requeues the item" "$CAP0_RETRY" '.enqueued' "1"

echo ""
echo "Test 30: infra-exhausted is reported from the persisted summary even when the failing runs predate the metrics window"
KDIR_EXW="$TEST_DIR/kdir-exhausted-window"
SETTINGS_EXW="$TEST_DIR/settings-exhausted-window.json"
setup_kdir "$KDIR_EXW" "wi"
write_settings "$SETTINGS_EXW" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"batch_recompute_min_interval_seconds":0,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
# Three infra-failure runs for one item, all older than the 7-day metrics
# window by both completed_at and file mtime. A window parse would never see
# them; the summary (a full census) must still report the item exhausted.
python3 - "$KDIR_EXW" <<'PY'
import json, os, pathlib, sys, time
runs_dir = pathlib.Path(sys.argv[1]) / "_settlement" / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)
old_mtime = time.time() - 30 * 24 * 3600
for i in range(3):
    name = f"run-old-infra-{i:02d}"
    p = runs_dir / f"{name}.json"
    p.write_text(json.dumps({
        "version": 1,
        "run_id": name,
        "item_id": "item-old-exhausted",
        "kind": "task-claim",
        "source_id": "claim-old-exhausted",
        "claim_id": "claim-old-exhausted",
        "work_item": "wi",
        "status": "failed",
        "reason": "executor_audit_error",
        "started_at": "2020-01-01T00:00:00Z",
        "completed_at": f"2020-01-0{i+1}T00:00:00Z",
        "verdict": {"verdict_format": "envelope", "verdict": "error", "evidence": "old infra failure"},
    }))
    os.utime(p, (old_mtime + i, old_mtime + i))
PY
# A process tick seeds the summary via ensure() (empty queue -> no dispatch).
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_EXW" bash "$QUEUE" process --kdir "$KDIR_EXW" --once --json >/dev/null
EXW_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_EXW" bash "$QUEUE" status --kdir "$KDIR_EXW" --json)
assert_json_eq "window: exhausted count from summary, not the window" "$EXW_STATUS" '.infra_exhausted.count' "1"
assert_json_eq "window: exhausted preview carries the full failure_count" "$EXW_STATUS" '.infra_exhausted.items[0].failure_count' "3"
assert_json_eq "window: exhausted preview identifies the item" "$EXW_STATUS" '.infra_exhausted.items[0].item_id' "item-old-exhausted"
assert_json_eq "window: exhausted preview names the failure reason" "$EXW_STATUS" '.infra_exhausted.items[0].reason' "executor_audit_error"
# The runs are outside the 7-day window, so the windowed health parse sees
# none of them — proving infra_exhausted did not read the window.
assert_json_eq "window: windowed health excludes the pre-window runs" "$EXW_STATUS" '.health.completions_24h' "0"

echo ""
echo "Test 31: windowed health/spot_sample equal the full-parse values on a mixed in/out-of-window substrate"
KDIR_CONS="$TEST_DIR/kdir-window-conservation"
SETTINGS_CONS="$TEST_DIR/settings-window-conservation.json"
setup_kdir "$KDIR_CONS" "wi"
write_settings "$SETTINGS_CONS" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false,"spot_sample_weekly_budget":12},"enabled":true,"max_concurrency":1,"max_auto_retry_attempts":3,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
# Recent runs (in window: mtime now, dates within 24h / this week) carry the
# metric signal; old runs (out of window: mtime 30d ago, 2020 dates) are read
# only by a full parse and must not change either metric. mtime >= completed_at
# holds for every file, which is the substrate invariant the window relies on.
python3 - "$KDIR_CONS" <<'PY'
import json, os, pathlib, sys, time
from datetime import datetime, timezone, timedelta
runs_dir = pathlib.Path(sys.argv[1]) / "_settlement" / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
now_z = now.strftime("%Y-%m-%dT%H:%M:%SZ")
recent_iso = (now - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
now_mtime = time.time()
old_mtime = time.time() - 30 * 24 * 3600

def write(name, mtime, run):
    p = runs_dir / f"{name}.json"
    p.write_text(json.dumps(run))
    os.utime(p, (mtime, mtime))

# In-window: two completed audits and one failed audit today.
for i in range(2):
    write(f"run-recent-ok-{i}", now_mtime, {
        "version": 1, "run_id": f"run-recent-ok-{i}", "item_id": f"item-recent-ok-{i}",
        "work_item": "wi", "status": "completed", "completed_at": recent_iso,
        "verdict": {"verdict": "verified", "evidence": "recent"}})
write("run-recent-fail", now_mtime, {
    "version": 1, "run_id": "run-recent-fail", "item_id": "item-recent-fail",
    "work_item": "wi", "status": "failed", "completed_at": recent_iso,
    "verdict": {"verdict": "unverified", "evidence": "recent fail"}})
# In-window: two spot-sample runs selected this week.
for i in range(2):
    write(f"run-recent-spot-{i}", now_mtime, {
        "version": 1, "run_id": f"run-recent-spot-{i}", "item_id": f"item-recent-spot-{i}",
        "work_item": "wi", "status": "completed", "completed_at": recent_iso,
        "selection": {"reason": "spot_sample", "selected_at": now_z},
        "verdict": {"verdict": "verified", "evidence": "recent spot"}})
# Out-of-window: completed + spot-sample runs from 2020. A full parse reads
# these; neither metric filter matches them, so equality must hold.
for i in range(2):
    write(f"run-old-ok-{i}", old_mtime, {
        "version": 1, "run_id": f"run-old-ok-{i}", "item_id": f"item-old-ok-{i}",
        "work_item": "wi", "status": "completed", "completed_at": "2020-01-01T00:00:00Z",
        "verdict": {"verdict": "verified", "evidence": "old"}})
write("run-old-spot", old_mtime, {
    "version": 1, "run_id": "run-old-spot", "item_id": "item-old-spot",
    "work_item": "wi", "status": "completed", "completed_at": "2020-01-01T00:00:00Z",
    "selection": {"reason": "spot_sample", "selected_at": "2020-01-01T00:00:00Z"},
    "verdict": {"verdict": "verified", "evidence": "old spot"}})
PY
# Compare the windowed read model against a full parse directly on the code
# under test: health_metrics and spot_sample_used_this_week must agree.
CONS_CMP=$(python3 - "$KDIR_CONS" "$SCRIPTS_DIR/settlement-processor.py" <<'PY'
import importlib.util, pathlib, sys
kdir = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("settlement_processor", sys.argv[2])
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
s = sp.Settlement(kdir)
queue = s.load_queue()
full = s.load_runs()
windowed, _recent = s.scan_status_runs()
h_full = s.health_metrics(queue, full)
h_win = s.health_metrics(queue, windowed)
ss_full = s.spot_sample_used_this_week(full)
ss_win = s.spot_sample_used_this_week(windowed)
ok = (h_full == h_win) and (ss_full == ss_win)
# Guard against a vacuous match: the metrics must carry real signal.
nontrivial = h_win.get("completions_24h", 0) >= 1 and ss_win >= 1
print("MATCH" if ok and nontrivial else f"MISMATCH full={h_full} win={h_win} ss_full={ss_full} ss_win={ss_win}")
PY
)
assert_eq "conservation: windowed health/spot_sample equal full-parse (non-vacuous)" "$CONS_CMP" "MATCH"
CONS_STATUS=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_CONS" bash "$QUEUE" status --kdir "$KDIR_CONS" --json)
assert_json_eq "conservation: status completions_24h counts the three in-window terminal runs" "$CONS_STATUS" '.health.completions_24h' "5"
assert_json_eq "conservation: status failures_today counts the one in-window failure" "$CONS_STATUS" '.health.failures_today' "1"
assert_json_eq "conservation: status spot_sample used_this_week counts the two in-window samples" "$CONS_STATUS" '.dispatch.spot_sample.used_this_week' "2"

echo ""
echo "Test 32: L3 compaction conserves every all-time census count and shrinks the hot files"
KDIR_L3="$TEST_DIR/kdir-l3-compaction"
setup_kdir "$KDIR_L3" "wi"
# Mixed substrate: an old genuine-settled run and an old already-invalidated
# run are archive-eligible; an old non-invalidated infra-failure run is the
# live retry ledger and must stay hot; a recent settled run is too young to
# archive. Two dead leases (released + expired) archive; one active stays.
python3 - "$KDIR_L3" <<'PY'
import json, os, pathlib, sys, time
from datetime import datetime, timezone, timedelta
state = pathlib.Path(sys.argv[1]) / "_settlement"
runs_dir = state / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)
now = datetime.now(timezone.utc)
old_iso = "2020-01-01T00:00:00Z"
recent_iso = (now - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
old_mtime = time.time() - 30 * 24 * 3600
now_mtime = time.time()

def write(name, mtime, run):
    p = runs_dir / f"{name}.json"
    p.write_text(json.dumps(run))
    os.utime(p, (mtime, mtime))

write("run-settled-old", old_mtime, {
    "version": 1, "run_id": "run-settled-old", "item_id": "item-A", "work_item": "wi",
    "kind": "task-claim", "status": "completed", "completed_at": old_iso,
    "verdict": {"verdict": "verified", "evidence": "old settled"}})
write("run-invalidated-old", old_mtime, {
    "version": 1, "run_id": "run-invalidated-old", "item_id": "item-B", "work_item": "wi",
    "kind": "task-claim", "status": "completed", "completed_at": old_iso,
    "invalidated_at": old_iso, "invalidated_reason": "superseded_by_settled_run",
    "verdict": {"verdict": "verified", "evidence": "old invalidated"}})
write("run-infra-old", old_mtime, {
    "version": 1, "run_id": "run-infra-old", "item_id": "item-C", "work_item": "wi",
    "kind": "task-claim", "status": "blocked", "reason": "executor_timeout",
    "completed_at": old_iso, "source_id": "claim-C",
    "verdict": {"verdict": "error", "verdict_format": "envelope"}})
write("run-recent", now_mtime, {
    "version": 1, "run_id": "run-recent", "item_id": "item-D", "work_item": "wi",
    "kind": "task-claim", "status": "completed", "completed_at": recent_iso,
    "verdict": {"verdict": "verified", "evidence": "recent settled"}})
leases = {"version": 1, "leases": {
    "lease-active": {"lease_id": "lease-active", "item_id": "item-live", "run_id": "run-live", "state": "active", "expires_at_epoch": int(time.time()) + 3600},
    "lease-released": {"lease_id": "lease-released", "item_id": "item-A", "run_id": "run-settled-old", "state": "released", "released_at": old_iso},
    "lease-expired": {"lease_id": "lease-expired", "item_id": "item-C", "run_id": "run-infra-old", "state": "expired", "expired_at": old_iso},
}}
json.dump(leases, open(state / "leases.json", "w"))
PY
L3_CMP=$(python3 - "$KDIR_L3" "$SCRIPTS_DIR/settlement-processor.py" <<'PY'
import importlib.util, json, pathlib, sys
kdir = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("settlement_processor", sys.argv[2])
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
s = sp.Settlement(kdir)
leases = s.load_leases()
b_settled, b_infra = s._settled_and_infra_counts()
b_terminal = s.terminal_run_item_ids()
b_excl = s.settled_or_exhausted_item_ids(3)
s.rebuild_infra_exhausted_summary()
b_exhausted = json.load(open(s.exhausted_path))["items"] if (s.exhausted_path.exists()) else {}
counts = s.compact_substrate(leases)
s.save_leases(leases)
a_settled, a_infra = s._settled_and_infra_counts()
a_terminal = s.terminal_run_item_ids()
a_excl = s.settled_or_exhausted_item_ids(3)
s.rebuild_infra_exhausted_summary()
a_exhausted = json.load(open(s.exhausted_path))["items"]
conserved = (b_settled == a_settled and b_infra == a_infra and b_terminal == a_terminal
             and b_excl == a_excl and b_exhausted == a_exhausted)
# The census must carry real signal: item-A settled, item-C infra, item-B skipped.
nontrivial = ("item-A" in a_settled and a_infra.get("item-C") == 1 and "item-B" not in a_terminal)
moved = (counts["leases_archived"] == 2 and counts["runs_archived"] == 2)
print("MATCH" if conserved and nontrivial and moved else
      f"MISMATCH conserved={conserved} nontrivial={nontrivial} counts={counts} "
      f"b_settled={sorted(b_settled)} a_settled={sorted(a_settled)} b_infra={b_infra} a_infra={a_infra} "
      f"b_excl={sorted(b_excl)} a_excl={sorted(a_excl)} b_ex={b_exhausted} a_ex={a_exhausted}")
PY
)
assert_eq "L3: census counts byte-identical across a compaction pass (leases+runs archived)" "$L3_CMP" "MATCH"
assert_eq "L3: active lease survives compaction" "$(jq -r '.leases | has("lease-active")' "$KDIR_L3/_settlement/leases.json")" "true"
assert_eq "L3: released lease left the hot file" "$(jq -r '.leases | has("lease-released")' "$KDIR_L3/_settlement/leases.json")" "false"
assert_eq "L3: expired lease left the hot file" "$(jq -r '.leases | has("lease-expired")' "$KDIR_L3/_settlement/leases.json")" "false"
assert_eq "L3: two dead leases landed in the archive ledger" "$(wc -l < "$KDIR_L3/_settlement/archive/leases.jsonl" | tr -d ' ')" "2"
assert_eq "L3: two run files moved to the archive dir" "$(ls "$KDIR_L3/_settlement/archive/runs" | wc -l | tr -d ' ')" "2"
assert_eq "L3: archive index carries the two moved runs" "$(wc -l < "$KDIR_L3/_settlement/archive/runs-index.jsonl" | tr -d ' ')" "2"
assert_eq "L3: non-invalidated infra run stays hot (live retry ledger)" "$([[ -f "$KDIR_L3/_settlement/runs/run-infra-old.json" ]] && echo yes || echo no)" "yes"
assert_eq "L3: recent settled run stays hot (below retention age)" "$([[ -f "$KDIR_L3/_settlement/runs/run-recent.json" ]] && echo yes || echo no)" "yes"
assert_eq "L3: archived settled run left the hot dir" "$([[ -f "$KDIR_L3/_settlement/runs/run-settled-old.json" ]] && echo present || echo gone)" "gone"

echo ""
echo "Test 33: crash between index-append and file-move leaves every census count unchanged (dedup by run_id)"
KDIR_L3C="$TEST_DIR/kdir-l3-crash"
setup_kdir "$KDIR_L3C" "wi"
python3 - "$KDIR_L3C" <<'PY'
import json, os, pathlib, sys, time
runs_dir = pathlib.Path(sys.argv[1]) / "_settlement" / "runs"
runs_dir.mkdir(parents=True, exist_ok=True)
old_mtime = time.time() - 30 * 24 * 3600
p = runs_dir / "run-x.json"
p.write_text(json.dumps({
    "version": 1, "run_id": "run-x", "item_id": "item-X", "work_item": "wi",
    "kind": "task-claim", "status": "completed", "completed_at": "2020-01-01T00:00:00Z",
    "verdict": {"verdict": "verified", "evidence": "settled"}}))
os.utime(p, (old_mtime, old_mtime))
PY
L3_CRASH=$(python3 - "$KDIR_L3C" "$SCRIPTS_DIR/settlement-processor.py" <<'PY'
import importlib.util, json, pathlib, sys
kdir = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("settlement_processor", sys.argv[2])
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
s = sp.Settlement(kdir)

def census():
    settled, infra = s._settled_and_infra_counts()
    return (sorted(settled), dict(infra), sorted(s.terminal_run_item_ids()), sorted(s.settled_or_exhausted_item_ids(3)))

clean = census()
# Simulate the crash state: the index row was appended but os.replace never
# ran, so run-x is in BOTH the hot dir and the archive index.
s.archive_dir.mkdir(parents=True, exist_ok=True)
run = s.load_runs()[0]
with s.archive_runs_index_path.open("a", encoding="utf-8") as fh:
    fh.write(sp.compact(s._archive_run_index_row(run)) + "\n")
crashed = census()
# Now complete the move: run-x lives only in the archive.
s.archive_runs_dir.mkdir(parents=True, exist_ok=True)
import os
os.replace(s.run_path("run-x"), s.archive_runs_dir / "run-x.json")
completed = census()
print("MATCH" if clean == crashed == completed and clean[0] == ["item-X"] else
      f"MISMATCH clean={clean} crashed={crashed} completed={completed}")
PY
)
assert_eq "L3 crash: census identical across clean / crash-window / completed-move states" "$L3_CRASH" "MATCH"

echo ""
echo "Test 34: compaction runs inside the process_once GC block and reports counts in the payload"
KDIR_L3P="$TEST_DIR/kdir-l3-process"
SETTINGS_L3P="$TEST_DIR/settings-l3-process.json"
setup_kdir "$KDIR_L3P" "wi"
write_settings "$SETTINGS_L3P" '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"dispatch":{"census_enabled":false},"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
python3 - "$KDIR_L3P" <<'PY'
import json, pathlib, sys, time
state = pathlib.Path(sys.argv[1]) / "_settlement"
state.mkdir(parents=True, exist_ok=True)
# One active lease (holds the sole concurrency slot) and one released lease
# left by a prior dispatch. The GC block must archive the released lease and
# report the count even though the concurrency guard then short-circuits.
json.dump({"version": 1, "items": [
    {"id": "item-live", "status": "leased", "lease_id": "lease-active", "work_item": "wi", "kind": "task-claim"}
]}, open(state / "queue.json", "w"))
json.dump({"version": 1, "leases": {
    "lease-active": {"lease_id": "lease-active", "item_id": "item-live", "run_id": "run-live", "state": "active", "expires_at_epoch": int(time.time()) + 3600},
    "lease-released": {"lease_id": "lease-released", "item_id": "item-old", "run_id": "run-old", "state": "released", "released_at": "2020-01-01T00:00:00Z"},
}}, open(state / "leases.json", "w"))
PY
L3P=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS_L3P" bash "$QUEUE" process --kdir "$KDIR_L3P" --once --json)
assert_json_eq "L3 process: concurrency guard short-circuits after GC" "$L3P" '.reason' "max_concurrency_reached"
assert_json_eq "L3 process: short-circuit payload carries leases_archived" "$L3P" '.leases_archived' "1"
assert_json_eq "L3 process: short-circuit payload carries runs_archived" "$L3P" '.runs_archived' "0"
assert_eq "L3 process: released lease archived out of the hot file" "$(jq -r '.leases | has("lease-released")' "$KDIR_L3P/_settlement/leases.json")" "false"
assert_eq "L3 process: active lease untouched by compaction" "$(jq -r '.leases | has("lease-active")' "$KDIR_L3P/_settlement/leases.json")" "true"

echo ""
echo "Test 35: apply-correction resolves a settlement verdict from the archive fallback"
KDIR_L3A="$TEST_DIR/kdir-l3-apply"
mkdir -p "$KDIR_L3A/_settlement/archive/runs" "$KDIR_L3A/conventions"
ENTRY_L3A="$KDIR_L3A/conventions/sample-entry.md"
cat > "$ENTRY_L3A" <<'MD'
# Sample entry

The head element is compared before processing.

<!-- learned: 2026-01-01 | scale: implementation | source: test -->
MD
# The full run record lives only in the archive (compacted), not the hot dir.
cat > "$KDIR_L3A/_settlement/archive/runs/verdict-archived.json" <<'JSON'
{"version": 1, "run_id": "verdict-archived", "item_id": "item-Z", "status": "completed", "kind": "task-claim", "completed_at": "2020-01-01T00:00:00Z", "verdict": {"verdict": "contradicted", "evidence": "the head element is not compared", "correction": "The tail element is compared before processing."}}
JSON
APPLY_OUT=$(LORE_KNOWLEDGE_DIR="$KDIR_L3A" bash "$SCRIPTS_DIR/apply-correction.sh" --entry "$ENTRY_L3A" \
  --verdict-id "verdict-archived" --verdict-source "correctness-gate" --allow-settlement-verdict \
  --evidence "archived verdict fallback" \
  --superseded-text "The head element is compared before processing." \
  --replacement-text "The tail element is compared before processing." 2>&1 || true)
assert_eq "L3 apply-correction: archived verdict resolves and mutates the entry body" \
  "$(grep -cxF 'The tail element is compared before processing.' "$ENTRY_L3A")" "1"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
