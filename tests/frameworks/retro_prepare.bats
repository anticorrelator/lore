#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"
PREPARE="$REPO_DIR/scripts/retro-prepare.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  run "$LORE" init --force "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run "$LORE" work create --title "Cycle A" --slug cycle-a \
    --intent-anchor "Exercise every published retro evidence reader." --json
  [ "$status" -eq 0 ]
  run "$LORE" work note cycle-a --text '**Focus:** writer-created retro reader state'
  [ "$status" -eq 0 ]

  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  read -r WINDOW_START WINDOW_END FUTURE_START FUTURE_END < <(python3 - "$NOW" <<'PY'
from datetime import datetime, timedelta
import sys
now = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
fmt = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
print(fmt(now - timedelta(minutes=2)), fmt(now + timedelta(minutes=5)), fmt(now + timedelta(days=1)), fmt(now + timedelta(days=1, minutes=5)))
PY
)

  run bash "$REPO_DIR/scripts/retro-deferred-append.sh" \
    --cycle-id cycle-a --event-type spec-finalize --outcome due --rate 1 \
    --stratum routine --reason always-stratum --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]

  SCORECARD_ROW="$(jq -cn --arg now "$NOW" '{schema_version:1,kind:"telemetry",tier:"telemetry",calibration_state:"unknown",metric:"retro-contract",value:1,sample_size:1,window_start:$now,window_end:$now}')"
  run "$LORE" scorecard append --kdir "$TEST_KDIR" --row "$SCORECARD_ROW" --json
  [ "$status" -eq 0 ]
  run "$LORE" scorecard rollup --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]

  SESSION_ROW="$(jq -cn --arg now "$NOW" '{event:"needs_input",slug:"cycle-a",ts:$now}')"
  run bash "$REPO_DIR/scripts/session-event-append.sh" --kdir "$TEST_KDIR" --row "$SESSION_ROW" --json
  [ "$status" -eq 0 ]

  run "$LORE" journal write --observation "reader contract" --context "retro integration" \
    --work-item cycle-a --role retro
  [ "$status" -eq 0 ]

}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR
}

run_prepare() {
  run "$LORE" retro prepare cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  jq -e '([.source_manifest[] | select(.coverage == "read")] | length) == 6' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json" >/dev/null
}

manifest_row() {
  jq -c --arg source "$1" '.source_manifest[] | select(.source_id == $source)' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "cycle_work uses the work writers and public snapshot reader" {
  run "$LORE" work show cycle-a --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.slug == "cycle-a" and (.notes_content | contains("writer-created retro reader state"))'
  run_prepare
  manifest_row cycle_work | jq -e '
    .reader_contract_version == "1" and .projection_mode == "snapshot" and
    .reader == "lore work show cycle-a --json" and .stable_empty_shape == "missing-cycle-nonzero"
  '
  jq -e '.facts.cycle_artifacts.status == "available" and .facts.cycle_artifacts.values.has_notes' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "due_queue folds writer-created DUE state through the bounded public reader" {
  run "$LORE" retro queue --cycle-id cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reader_contract_version == "1" and .counts.unhandled_due == 1'
  run_prepare
  manifest_row due_queue | jq -e '
    .reader_contract_version == "1" and .projection_mode == "half-open-window" and
    (.reader | contains("lore retro queue --cycle-id cycle-a")) and .content_identity != null
  '
}

@test "scorecard_rows returns the bounded row written by scorecard append" {
  run "$LORE" scorecard rows --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].metric == "retro-contract"'
  run_prepare
  manifest_row scorecard_rows | jq -e '.reader_contract_version == "1" and .stable_empty_shape == "[]"'
  jq -e '.facts.scorecard_eligibility_deltas.values.rows_total == 1' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "scorecard_current returns the snapshot produced by rollup" {
  run "$LORE" scorecard current --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reader_contract_version == "1" and .projection_mode == "snapshot" and .row_count == 1'
  run_prepare
  manifest_row scorecard_current | jq -e '
    .reader == "lore scorecard current --json" and .projection_mode == "snapshot" and
    .stable_empty_shape == "versioned-empty-summary" and .content_identity != null
  '
}

@test "session_events preserves cursor semantics while applying the half-open window" {
  run "$LORE" session events --since 0 --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .reader_contract_version == "1" and .projection_mode == "half-open-window" and
    (.events | length) == 1 and .events[0].event == "needs_input" and (.next_cursor | type) == "number"
  '
  run_prepare
  manifest_row session_events | jq -e '.reader_contract_version == "1" and .cursor > 0'
  jq -e '.facts.session_retrieval_friction_packets.values.session_events == 1' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "journal keeps its published bounded projection unchanged" {
  run "$LORE" journal read --since "$WINDOW_START" --until "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].observation == "reader contract"'
  run_prepare
  manifest_row journal | jq -e '.reader_contract_version == "1" and .stable_empty_shape == "[]"'
  jq -e '.facts.session_retrieval_friction_packets.values.journal_entries == 1' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "the retired settlement and contradiction surface is absent from the pack" {
  run_prepare
  jq -e '
    ([.source_manifest[].source_id] | inside([
      "cycle_work","due_queue","scorecard_rows","scorecard_current","session_events","journal"
    ])) and
    ([.facts | keys[]] | any(. == "settlement_health_inputs" or . == "concerns_contradictions") | not) and
    ([.calculations[].calculation_id] | inside([
      "channel_contract_drift","scorecard_delta_readiness","template_headline_readiness"
    ])) and
    ([.calculations[].source_ids[]] | any(. == "settlement" or . == "consumer_contradiction_lifecycle") | not)
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "history readers have stable empty projections and absence never becomes green" {
  run "$LORE" retro queue --cycle-id cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.counts.unhandled_due == 0 and .counts.handled_due == 0'
  run "$LORE" scorecard rows --window-start "$FUTURE_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run "$LORE" session events --since 0 --window-start "$FUTURE_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.events == [] and (.next_cursor | type) == "number"'
  run "$LORE" journal read --since "$FUTURE_START" --until "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run "$LORE" retro prepare cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  jq -e '
    .fixed_health.state != "normal" and
    ([.calculations[] | select(.calculation_id == "template_headline_readiness")][0].disposition == "abstained")
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "writer validation rejects malformed evidence before readers see it" {
  run "$LORE" scorecard append --kdir "$TEST_KDIR" --row '{"kind":"telemetry"}' --json
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/session-event-append.sh" --kdir "$TEST_KDIR" --row '{"event":"not-a-real-event"}' --json
  [ "$status" -ne 0 ]
  run "$LORE" scorecard rows --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  run_prepare
  jq -e '.fixed_health.state != "normal"' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}
