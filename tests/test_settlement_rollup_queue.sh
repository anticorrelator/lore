#!/usr/bin/env bash
# test_settlement_rollup_queue.sh — Phase 1 wire-judge-rollups verification.
#
# Exercises the queue-job rollup wiring per
# _work/wire-judge-rollups-to-restore-evolve-primary-gate/plan.md Phase 1
# Files block (lines 256-288). Covers six fixtures:
#   1. Aggregation correctness: weighted-average, calibration downgrade
#   2. Direct-enqueue + dispatch: 5 judges x N weeks of rollup items drain to completion
#   3. Enqueuer existence-check idempotency: re-scan emits no new items
#   4. Steady-state enqueuer: emits 5 items per scan when tier=template absent
#   5. Soft-cal pass-through: curator/reverse-auditor rollups complete on pre-cal rows
#   6. Empty window: rollup emits zero rows, exits 0
#
# Each test uses its own KDIR under TEST_DIR. Tests run sequentially, but
# fixture isolation is enforced by per-test KDIRn directories so failures
# don't poison later tests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"
PROCESSOR="$SCRIPTS_DIR/settlement-processor.py"
SCORECARD_APPEND="$SCRIPTS_DIR/scorecard-append.sh"
CG_ROLLUP="$SCRIPTS_DIR/correctness-gate-rollup.sh"
CURATOR_ROLLUP="$SCRIPTS_DIR/curator-rollup.sh"
RA_ROLLUP="$SCRIPTS_DIR/reverse-auditor-rollup.sh"

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

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

write_settings() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$body" > "$path"
}

# Resolve the agents/worker.md template hash so sentinel-mapped rows produce
# the canonical 12-char hex that the aggregator emits — tests assert on it.
WORKER_VERSION=$(bash "$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/worker.md")
RA_VERSION=$(bash "$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/reverse-auditor.md")

# All tests use this settlement-settings shape: enabled, one concurrent dispatcher,
# the no-op success executor for source-row dispatch, and an eligible harness.
SUCCESS_EXEC="$TEST_DIR/success-exec.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$SUCCESS_EXEC"
chmod +x "$SUCCESS_EXEC"

settings_body() {
  printf '{"version":1,"tui_launch_framework":"claude-code","harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}},"settlement":{"enabled":true,"max_concurrency":1,"harness_selection":{"mode":"first_eligible","eligible_frameworks":["claude-code"]}}}'
}

# Append a pre-built tier=reusable row to a KDIR's rows.jsonl. We bypass
# scorecard-append.sh here because the seed rows already match what
# audit-artifact.sh's inline emit blocks would have written; using the writer
# would re-validate but adds no test value.
seed_reusable_row() {
  local kdir="$1" verdict_source="$2" template_id="$3" template_version="$4" \
        metric="$5" value="$6" sample_size="$7" window_start="$8" window_end="$9" \
        calibration_state="${10:-pre-calibration}"
  mkdir -p "$kdir/_scorecards"
  jq -nc \
    --arg vs "$verdict_source" \
    --arg tid "$template_id" \
    --arg tv "$template_version" \
    --arg m "$metric" \
    --argjson v "$value" \
    --argjson n "$sample_size" \
    --arg ws "$window_start" \
    --arg we "$window_end" \
    --arg cs "$calibration_state" '{
      schema_version: "1",
      kind: "scored",
      tier: "reusable",
      calibration_state: $cs,
      verdict_source: $vs,
      template_id: $tid,
      template_version: $tv,
      metric: $m,
      value: $v,
      sample_size: $n,
      window_start: $ws,
      window_end: $we,
      source_artifact_ids: ["artifact-\($vs)-\($ws)"]
    }' >> "$kdir/_scorecards/rows.jsonl"
}

# Same but for reverse-auditor — those rows carry claim_anchor for the
# grounded-or-nothing gate (per scorecard-append.sh:158).
seed_reverse_auditor_reusable_row() {
  local kdir="$1" template_id="$2" template_version="$3" \
        metric="$4" value="$5" sample_size="$6" window_start="$7" window_end="$8" \
        calibration_state="${9:-pre-calibration}"
  mkdir -p "$kdir/_scorecards"
  jq -nc \
    --arg tid "$template_id" \
    --arg tv "$template_version" \
    --arg m "$metric" \
    --argjson v "$value" \
    --argjson n "$sample_size" \
    --arg ws "$window_start" \
    --arg we "$window_end" \
    --arg cs "$calibration_state" '{
      schema_version: "1",
      kind: "scored",
      tier: "reusable",
      calibration_state: $cs,
      verdict_source: "reverse-auditor",
      template_id: $tid,
      template_version: $tv,
      metric: $m,
      value: $v,
      sample_size: $n,
      window_start: $ws,
      window_end: $we,
      source_artifact_ids: ["artifact-ra-\($ws)"],
      claim_anchor: {file: "scripts/example.sh", line_range: "1-10", exact_snippet: "example"}
    }' >> "$kdir/_scorecards/rows.jsonl"
}

echo "=== Settlement Rollup Queue Tests ==="
echo "WORKER_VERSION=$WORKER_VERSION"
echo "RA_VERSION=$RA_VERSION"
echo ""

# =====================================================================
# Test 1: aggregation correctness (D8 + D10)
# =====================================================================
echo "Test 1: aggregation correctness — weighted-average and calibration downgrade"
KDIR1="$TEST_DIR/kdir1"
mkdir -p "$KDIR1/_scorecards"
W_START="2026-05-18T00:00:00Z"
W_END="2026-05-25T00:00:00Z"
# 2 templates x 3 metrics x several rows per metric.
# Template "worker" with calibrated rows.
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "worker" "$WORKER_VERSION" "factual_precision" 1.0 5 "$W_START" "$W_END" "calibrated"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "worker" "$WORKER_VERSION" "factual_precision" 0.0 5 "$W_START" "$W_END" "calibrated"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "worker" "$WORKER_VERSION" "falsifier_quality" 1.0 10 "$W_START" "$W_END" "calibrated"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "worker" "$WORKER_VERSION" "audit_contradiction_rate" 0.2 10 "$W_START" "$W_END" "calibrated"
# Template "advisor" with mixed-state rows → calibration_state should downgrade to "pre-calibration"
ADVISOR_VERSION="111111111111"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "advisor" "$ADVISOR_VERSION" "factual_precision" 1.0 4 "$W_START" "$W_END" "calibrated"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "advisor" "$ADVISOR_VERSION" "factual_precision" 0.5 4 "$W_START" "$W_END" "pre-calibration"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "advisor" "$ADVISOR_VERSION" "falsifier_quality" 1.0 8 "$W_START" "$W_END" "pre-calibration"
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "advisor" "$ADVISOR_VERSION" "audit_contradiction_rate" 0.0 8 "$W_START" "$W_END" "calibrated"
# Out-of-window row — should NOT be aggregated. (Earlier week.)
seed_reusable_row "$KDIR1" "correctness-gate-assertion" "worker" "$WORKER_VERSION" "factual_precision" 0.0 100 "2026-05-11T00:00:00Z" "2026-05-18T00:00:00Z" "calibrated"
# Different judge — should NOT be aggregated for correctness-gate-assertion.
seed_reusable_row "$KDIR1" "curator" "worker" "$WORKER_VERSION" "curated_rate" 0.5 10 "$W_START" "$W_END" "pre-calibration"

# Run the rollup in aggregate-window mode.
ROLLUP_OUT1=$(bash "$CG_ROLLUP" --aggregate-window --judge "correctness-gate-assertion" --window-start "$W_START" --window-end "$W_END" --kdir "$KDIR1" 2>&1)
ROLLUP_EXIT1=$?
assert_eq "rollup exits 0" "$ROLLUP_EXIT1" "0"
assert_contains "summary reports 2 templates" "$ROLLUP_OUT1" "templates=2"
assert_contains "summary reports 6 rows (2 templates x 3 metrics)" "$ROLLUP_OUT1" "rows=6"

# Verify emitted rows.
TEMPLATE_ROWS_PATH="$KDIR1/_scorecards/rows.jsonl"
TEMPLATE_ROW_COUNT=$(jq -s '[.[] | select(.tier=="template")] | length' < "$TEMPLATE_ROWS_PATH")
assert_eq "6 tier=template rows emitted" "$TEMPLATE_ROW_COUNT" "6"

# Worker factual_precision: weighted = (1.0*5 + 0.0*5) / 10 = 0.5
WORKER_FP=$(jq -s --arg tv "$WORKER_VERSION" '[.[] | select(.tier=="template" and .template_id=="worker" and .metric=="factual_precision" and .template_version==$tv)][0]' < "$TEMPLATE_ROWS_PATH")
assert_eq "worker factual_precision weighted=0.5" "$(echo "$WORKER_FP" | jq -r '.value')" "0.5"
assert_eq "worker factual_precision sample_size=10" "$(echo "$WORKER_FP" | jq -r '.sample_size')" "10"
assert_eq "worker factual_precision verdict_source set (D9)" "$(echo "$WORKER_FP" | jq -r '.verdict_source')" "correctness-gate-assertion"
assert_eq "worker calibration_state stays calibrated" "$(echo "$WORKER_FP" | jq -r '.calibration_state')" "calibrated"
assert_eq "worker window_start matches" "$(echo "$WORKER_FP" | jq -r '.window_start')" "$W_START"
assert_eq "worker window_end matches" "$(echo "$WORKER_FP" | jq -r '.window_end')" "$W_END"

# Advisor mixed-state → D10 downgrade to pre-calibration.
ADVISOR_FP=$(jq -s --arg tv "$ADVISOR_VERSION" '[.[] | select(.tier=="template" and .template_id=="advisor" and .metric=="factual_precision" and .template_version==$tv)][0]' < "$TEMPLATE_ROWS_PATH")
assert_eq "advisor calibration_state downgrades to pre-calibration (D10)" "$(echo "$ADVISOR_FP" | jq -r '.calibration_state')" "pre-calibration"
# Advisor factual_precision: weighted = (1.0*4 + 0.5*4) / 8 = 0.75
assert_eq "advisor factual_precision weighted=0.75" "$(echo "$ADVISOR_FP" | jq -r '.value')" "0.75"

# Out-of-window row was excluded.
OOW_COUNT=$(jq -s --arg tv "$WORKER_VERSION" '[.[] | select(.tier=="template" and .template_id=="worker" and .metric=="factual_precision" and .template_version==$tv and .window_start=="2026-05-11T00:00:00Z")] | length' < "$TEMPLATE_ROWS_PATH")
assert_eq "out-of-window row not aggregated" "$OOW_COUNT" "0"

echo ""

# =====================================================================
# Test 1b: re-running aggregate-window is idempotent (D8 step 5 dedupe)
# =====================================================================
echo "Test 1b: re-running aggregate-window is idempotent (call-site dedupe)"
RERUN_OUT=$(bash "$CG_ROLLUP" --aggregate-window --judge "correctness-gate-assertion" --window-start "$W_START" --window-end "$W_END" --kdir "$KDIR1" 2>&1)
TEMPLATE_ROW_COUNT_AFTER_RERUN=$(jq -s '[.[] | select(.tier=="template")] | length' < "$TEMPLATE_ROWS_PATH")
assert_eq "rerun does NOT duplicate rows (still 6)" "$TEMPLATE_ROW_COUNT_AFTER_RERUN" "6"
assert_contains "rerun reports skipped_existing" "$RERUN_OUT" "skipped_existing_aggregate_rows"

echo ""

# =====================================================================
# Test 2: direct-enqueue + dispatch (D6 + D7 + D12 backfill)
# =====================================================================
echo "Test 2: enqueue_rollup_backfill enqueues N x 5 items, drain dispatches all"
KDIR2="$TEST_DIR/kdir2"
SETTINGS2="$TEST_DIR/settings2.json"
mkdir -p "$KDIR2"
write_settings "$SETTINGS2" "$(settings_body)"
# Backfill 2 weeks x 5 judges = 10 items.
BACKFILL=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" LORE_SETTLEMENT_NOW="2026-05-25T12:00:00Z" \
  bash "$QUEUE" enqueue-rollup-backfill --weeks 2 --kdir "$KDIR2" --json)
assert_eq "backfill enqueued 10 items" "$(echo "$BACKFILL" | jq -r '.enqueued')" "10"
assert_eq "backfill reports zero duplicates" "$(echo "$BACKFILL" | jq -r '.duplicates')" "0"
QUEUE_LEN=$(jq '.items | length' < "$KDIR2/_settlement/queue.json")
assert_eq "queue.json has 10 pending items" "$QUEUE_LEN" "10"
# All items have selection_reason=rollup_window (so process_once does NOT
# trigger legacy-pending-normalization recompute, per D6).
ALL_ROLLUP_REASON=$(jq '[.items[] | select(.selection_reason=="rollup_window")] | length' < "$KDIR2/_settlement/queue.json")
assert_eq "all 10 items carry selection_reason=rollup_window" "$ALL_ROLLUP_REASON" "10"

# Drain.
DRAIN=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" \
  bash "$QUEUE" drain --kdir "$KDIR2" --json --max-iterations 50)
assert_eq "drain processed 10 items" "$(echo "$DRAIN" | jq -r '.dispatched')" "10"
assert_eq "drain leaves 0 pending" "$(echo "$DRAIN" | jq -r '.remaining')" "0"

# All 10 runs are completed and use verdict_format=rollup (per D7).
RUNS_DIR="$KDIR2/_settlement/runs"
COMPLETED_RUNS=$(find "$RUNS_DIR" -name '*.json' -exec jq -r '[.status, .verdict.verdict_format] | @tsv' {} \; | grep -c "^completed	rollup$" || true)
assert_eq "10 runs are completed with verdict_format=rollup" "$COMPLETED_RUNS" "10"
# Verdict label rollup-complete.
COMPLETE_VERDICTS=$(find "$RUNS_DIR" -name '*.json' -exec jq -r '.verdict.verdict' {} \; | grep -c "^rollup-complete$" || true)
assert_eq "10 runs carry verdict=rollup-complete" "$COMPLETE_VERDICTS" "10"

echo ""

# =====================================================================
# Test 3: enqueuer existence-check idempotency (D11 + run-record fallback)
# =====================================================================
echo "Test 3: re-running backfill after drain is idempotent — empty windows recognized via run-record fallback"
BACKFILL2=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" LORE_SETTLEMENT_NOW="2026-05-25T12:00:00Z" \
  bash "$QUEUE" enqueue-rollup-backfill --weeks 2 --kdir "$KDIR2" --json)
# All 10 windows now have completed run records (empty windows); D11 should
# short-circuit via the run-record fallback (no tier=template rows exist
# because rows.jsonl was empty for those windows).
assert_eq "rerun enqueues 0 items (all 10 windows covered by run records)" "$(echo "$BACKFILL2" | jq -r '.enqueued')" "0"
assert_eq "rerun reports 10 skipped_existing" "$(echo "$BACKFILL2" | jq -r '.skipped_existing')" "10"

echo ""

# =====================================================================
# Test 4: steady-state enqueuer in scan() (D4 + D12)
# =====================================================================
echo "Test 4: scan() steady-state enqueuer emits 5 items for the current completed week"
KDIR4="$TEST_DIR/kdir4"
SETTINGS4="$TEST_DIR/settings4.json"
mkdir -p "$KDIR4/_work"
write_settings "$SETTINGS4" "$(settings_body)"
# scan() with no _work source files; only the steady-state enqueuer fires.
SCAN_OUT=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS4" LORE_SETTLEMENT_NOW="2026-05-25T12:00:00Z" \
  bash "$QUEUE" scan --kdir "$KDIR4" --json)
assert_eq "scan reports 5 rollup_enqueued" "$(echo "$SCAN_OUT" | jq -r '.rollup_enqueued')" "5"
# Targeted at the MOST RECENTLY COMPLETED week — not the in-progress week.
assert_eq "rollup_window_start = most recent completed Monday" "$(echo "$SCAN_OUT" | jq -r '.rollup_window_start')" "2026-05-18T00:00:00Z"
assert_eq "rollup_window_end = following Monday" "$(echo "$SCAN_OUT" | jq -r '.rollup_window_end')" "2026-05-25T00:00:00Z"

# Re-running scan() with the same NOW should NOT re-enqueue — run records and
# pending items already cover the window. (Pending items are skipped via the
# enqueue_rollup_item dedupe on id.)
SCAN_OUT2=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS4" LORE_SETTLEMENT_NOW="2026-05-25T12:00:00Z" \
  bash "$QUEUE" scan --kdir "$KDIR4" --json)
assert_eq "second scan enqueues 0 new (already pending)" "$(echo "$SCAN_OUT2" | jq -r '.rollup_enqueued')" "0"
# enqueue_rollup_item returns duplicate when the id already exists in queue.json.
DUP_COUNT=$(echo "$SCAN_OUT2" | jq -r '.rollup_duplicates')
SKIP_COUNT=$(echo "$SCAN_OUT2" | jq -r '.rollup_skipped_existing')
TOTAL_NOOP=$((DUP_COUNT + SKIP_COUNT))
assert_eq "second scan reports 5 noop (duplicate or skipped_existing)" "$TOTAL_NOOP" "5"

echo ""

# =====================================================================
# Test 5: soft-cal pass-through — curator + reverse-auditor on pre-cal rows
# =====================================================================
echo "Test 5: curator + reverse-auditor rollups complete on pre-calibration rows; D10 downgrades aggregate"
KDIR5="$TEST_DIR/kdir5"
mkdir -p "$KDIR5/_scorecards"
W_START5="2026-05-18T00:00:00Z"
W_END5="2026-05-25T00:00:00Z"
# Curator pre-calibration rows for one template.
CURATOR_TID="curator"
CURATOR_TV="222222222222"
seed_reusable_row "$KDIR5" "curator" "$CURATOR_TID" "$CURATOR_TV" "curated_rate" 0.8 5 "$W_START5" "$W_END5" "pre-calibration"
seed_reusable_row "$KDIR5" "curator" "$CURATOR_TID" "$CURATOR_TV" "triviality_rate" 0.2 5 "$W_START5" "$W_END5" "pre-calibration"
CURATOR_OUT=$(bash "$CURATOR_ROLLUP" --aggregate-window --judge curator --window-start "$W_START5" --window-end "$W_END5" --kdir "$KDIR5" 2>&1)
CURATOR_EXIT=$?
assert_eq "curator rollup exits 0 on soft-cal input" "$CURATOR_EXIT" "0"
assert_contains "curator summary reports 1 template" "$CURATOR_OUT" "templates=1"
CURATOR_AGG=$(jq -s '[.[] | select(.tier=="template" and .verdict_source=="curator")][0]' < "$KDIR5/_scorecards/rows.jsonl")
assert_eq "curator aggregate carries pre-calibration (D10)" "$(echo "$CURATOR_AGG" | jq -r '.calibration_state')" "pre-calibration"

# Reverse-auditor: seed rows that carry claim_anchor so they pass the grounded-or-nothing gate.
RA_TID="reverse-auditor"
seed_reverse_auditor_reusable_row "$KDIR5" "$RA_TID" "$RA_VERSION" "omission_rate" 0.1 4 "$W_START5" "$W_END5" "pre-calibration"
seed_reverse_auditor_reusable_row "$KDIR5" "$RA_TID" "$RA_VERSION" "coverage_quality" 0.9 4 "$W_START5" "$W_END5" "pre-calibration"
RA_OUT=$(bash "$RA_ROLLUP" --aggregate-window --judge reverse-auditor --window-start "$W_START5" --window-end "$W_END5" --kdir "$KDIR5" 2>&1)
RA_EXIT=$?
assert_eq "reverse-auditor rollup exits 0 on soft-cal input" "$RA_EXIT" "0"
RA_AGG=$(jq -s '[.[] | select(.tier=="template" and .verdict_source=="reverse-auditor")][0]' < "$KDIR5/_scorecards/rows.jsonl")
assert_eq "reverse-auditor aggregate carries pre-calibration (D10)" "$(echo "$RA_AGG" | jq -r '.calibration_state')" "pre-calibration"
# Aggregate-provenance: source_anchor_count == sample_size (8 = 4+4 underlying anchors? No — 4 anchors per metric per template, sample_size per metric).
RA_OMISSION=$(jq -s --arg tv "$RA_VERSION" '[.[] | select(.tier=="template" and .verdict_source=="reverse-auditor" and .metric=="omission_rate" and .template_version==$tv)][0]' < "$KDIR5/_scorecards/rows.jsonl")
assert_eq "reverse-auditor template row carries source_anchor_count" "$(echo "$RA_OMISSION" | jq -r 'has("source_anchor_count")')" "true"
assert_eq "reverse-auditor source_anchor_count == sample_size for the metric (gate input)" "$(echo "$RA_OMISSION" | jq -r '.source_anchor_count')" "4"

# Primary-gate smoke: pre-cal aggregates do NOT satisfy calibration_state=="calibrated".
GATE_ELIGIBLE=$(jq -s '[.[] | select(.tier=="template" and .kind=="scored" and .calibration_state=="calibrated")] | length' < "$KDIR5/_scorecards/rows.jsonl")
assert_eq "0 template rows are calibrated (primary-gate input set is empty)" "$GATE_ELIGIBLE" "0"

echo ""

# =====================================================================
# Test 6: empty window
# =====================================================================
echo "Test 6: rollup with empty window — exit 0, zero rows emitted"
KDIR6="$TEST_DIR/kdir6"
mkdir -p "$KDIR6/_scorecards"
touch "$KDIR6/_scorecards/rows.jsonl"
EMPTY_OUT=$(bash "$CG_ROLLUP" --aggregate-window --judge correctness-gate-assertion --window-start "2026-05-18T00:00:00Z" --window-end "2026-05-25T00:00:00Z" --kdir "$KDIR6" 2>&1)
EMPTY_EXIT=$?
assert_eq "empty window exits 0" "$EMPTY_EXIT" "0"
assert_contains "empty window logs templates=0" "$EMPTY_OUT" "templates=0"
assert_contains "empty window logs rows=0" "$EMPTY_OUT" "rows=0"
EMPTY_TEMPLATE_COUNT=$(jq -s '[.[] | select(.tier=="template")] | length' < "$KDIR6/_scorecards/rows.jsonl" 2>/dev/null || echo 0)
assert_eq "empty window emits 0 template rows" "$EMPTY_TEMPLATE_COUNT" "0"

echo ""

# =====================================================================
# Test 7: rollup item validation — invalid rollup item shape rejected
# =====================================================================
echo "Test 7: process_once rejects malformed rollup item (missing judge)"
KDIR7="$TEST_DIR/kdir7"
SETTINGS7="$TEST_DIR/settings7.json"
mkdir -p "$KDIR7/_settlement"
write_settings "$SETTINGS7" "$(settings_body)"
# Hand-craft a malformed rollup queue item (missing judge).
cat > "$KDIR7/_settlement/queue.json" <<'EOF'
{"version":1,"items":[{"id":"deadbeefdeadbeefdead","kind":"rollup-curator","status":"pending","window_start":"2026-05-18T00:00:00Z","window_end":"2026-05-25T00:00:00Z","attempts":0,"enqueued_at":"2026-05-25T00:00:00Z","updated_at":"2026-05-25T00:00:00Z","selection_reason":"rollup_window"}]}
EOF
INVALID_PROC=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS7" LORE_SETTLEMENT_EXECUTOR="$SUCCESS_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR7" --once --json)
assert_eq "malformed rollup item bypasses executor" "$(echo "$INVALID_PROC" | jq -r '.dispatched')" "false"
assert_contains "malformed rollup reason references invalid" "$(echo "$INVALID_PROC" | jq -r '.reason')" "invalid"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
