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

  SESSION_ROW="$(jq -cn --arg now "$NOW" '{event:"review_flagged",slug:"cycle-a",ts:$now}')"
  run bash "$REPO_DIR/scripts/session-event-append.sh" --kdir "$TEST_KDIR" --row "$SESSION_ROW" --json
  [ "$status" -eq 0 ]

  run "$LORE" journal write --observation "reader contract" --context "retro integration" \
    --work-item cycle-a --role retro
  [ "$status" -eq 0 ]

  SNIPPET="$(sed -n '1p' "$REPO_DIR/README.md")"
  SNIPPET_HASH="$(printf '%s' "$SNIPPET" | python3 "$HOME/.lore/scripts/snippet_normalize.py" --hash)"
  REPO_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  CLAIM_ROW="$(jq -cn \
    --arg snippet "$SNIPPET" --arg hash "$SNIPPET_HASH" --arg sha "$REPO_SHA" \
    --arg file "$REPO_DIR/README.md" \
    '{claim_id:"contract-claim",tier:"task-evidence",claim:"Reader contract evidence",producer_role:"implement-lead",protocol_slot:"test",task_id:"task-1",phase_id:"phase-1",scale:"implementation",file:$file,line_range:"1-1",exact_snippet:$snippet,normalized_snippet_hash:$hash,falsifier:"Reader contract disappears",why_this_work_needs_it:"Exercise the settlement writer and reader pair.",captured_at_sha:$sha,change_context:{diff_ref:$sha,changed_files:[$file],summary:"Writer-reader contract test."}}')"
  run bash "$REPO_DIR/scripts/evidence-append.sh" --work-item cycle-a <<<"$CLAIM_ROW"
  [ "$status" -eq 0 ]
  run "$LORE" settlement enqueue --work-item cycle-a --kind task-claim \
    --row-file "$TEST_KDIR/_work/cycle-a/task-claims.jsonl" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]

  run "$LORE" consumption-contradiction \
    --work-item cycle-a --source implement-lead --producer-role implement-lead \
    --protocol-slot test --cycle-id cycle-a --knowledge-path conventions/example.md \
    --contradiction-rationale "Reader contract exercise" --claim-id contract-claim \
    --claim-text "Reader contract evidence" --file "$REPO_DIR/README.md" --line-range 1 \
    --exact-snippet "$SNIPPET" --falsifier "Reader contract disappears" \
    --contradiction-id ctr-contract --created-at "$NOW" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  run bash "$REPO_DIR/scripts/consumption-contradiction-update-status.sh" \
    --work-item cycle-a --contradiction-id ctr-contract --status verified \
    --settled-at "$NOW" --settled-by-run-id run-contract --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR
}

run_prepare() {
  run "$LORE" retro prepare cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  jq -e '([.source_manifest[] | select(.coverage == "read")] | length) == 8' \
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

@test "settlement publishes writer-created enqueue transitions without opening storage" {
  run "$LORE" settlement status --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .retro_projection.reader_contract_version == "1" and
    (.retro_projection.queue_transitions | length) == 1 and
    .retro_projection.queue_transitions[0].kind == "task-claim"
  '
  run_prepare
  manifest_row settlement | jq -e '.reader == ("lore settlement status --window-start " + $start + " --window-end " + $end + " --json")' \
    --arg start "$WINDOW_START" --arg end "$WINDOW_END"
  jq -e '.facts.settlement_health_inputs.values.queue_transitions | length == 1' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
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
    (.events | length) == 1 and .events[0].event == "review_flagged" and (.next_cursor | type) == "number"
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

@test "consumer contradiction lifecycle reads writer-created terminal state" {
  run "$LORE" consumption-contradiction read --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].contradiction_id == "ctr-contract" and .[0].status == "verified"'
  run_prepare
  manifest_row consumer_contradiction_lifecycle | jq -e '
    .reader_contract_version == "1" and .projection_mode == "half-open-window" and .content_identity != null
  '
  jq -e '
    .facts.concerns_contradictions.values == {produced:1, terminal:1} and
    ([.calculations[] | select(.calculation_id == "consumer_contradiction_routing")][0].disposition == "abstained")
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
  run "$LORE" consumption-contradiction read --window-start "$FUTURE_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run "$LORE" retro prepare cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  jq -e '
    .fixed_health.state != "normal" and
    ([.calculations[] | select(.calculation_id == "consumer_contradiction_routing")][0].disposition == "abstained")
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
