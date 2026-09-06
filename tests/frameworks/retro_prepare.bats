#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"
PREPARE="$REPO_DIR/scripts/retro-prepare.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  run bash "$REPO_DIR/scripts/init-repo.sh" --force "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$REPO_DIR/scripts/create-work.sh" --title "Cycle A" --slug cycle-a \
    --intent-anchor "Exercise every published retro evidence reader." --json
  [ "$status" -eq 0 ]
  run bash "$REPO_DIR/scripts/work-note.sh" cycle-a --text '**Focus:** writer-created retro reader state'
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
  run bash "$REPO_DIR/scripts/scorecard-append.sh" --kdir "$TEST_KDIR" --row "$SCORECARD_ROW" --json
  [ "$status" -eq 0 ]
  run bash "$REPO_DIR/scripts/scorecard-rollup.sh" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]

  SESSION_ROW="$(jq -cn --arg now "$NOW" '{event:"needs_input",slug:"cycle-a",ts:$now}')"
  run bash "$REPO_DIR/scripts/session-event-append.sh" --kdir "$TEST_KDIR" --row "$SESSION_ROW" --json
  [ "$status" -eq 0 ]

  run bash "$REPO_DIR/scripts/journal.sh" write --observation "reader contract" --context "retro integration" \
    --work-item cycle-a --role retro
  [ "$status" -eq 0 ]

}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR
}

run_prepare() {
  run bash "$PREPARE" cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  jq -e '([.source_manifest[] | select(.source_id != "packet_assessments" and .coverage == "read")] | length) == 6' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json" >/dev/null
}

manifest_row() {
  jq -c --arg source "$1" '.source_manifest[] | select(.source_id == $source)' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "cycle_work uses the work writers and public snapshot reader" {
  run bash "$REPO_DIR/scripts/load-work-item.sh" cycle-a --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.slug == "cycle-a" and (.notes_content | contains("writer-created retro reader state"))'
  run_prepare
  manifest_row cycle_work | jq -e '
    .reader_contract_version == "2" and .projection_mode == "snapshot" and
    .reader == "lore work show cycle-a --json" and .stable_empty_shape == "missing-cycle-nonzero"
  '
  jq -e '.facts.cycle_artifacts.status == "available" and .facts.cycle_artifacts.values.has_notes' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "due_queue folds writer-created DUE state through the bounded public reader" {
  run bash "$REPO_DIR/scripts/retro-queue.sh" queue --cycle-id cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reader_contract_version == "1" and .counts.unhandled_due == 1'
  run_prepare
  manifest_row due_queue | jq -e '
    .reader_contract_version == "1" and .projection_mode == "half-open-window" and
    (.reader | contains("lore retro queue --cycle-id cycle-a")) and .content_identity != null
  '
}

@test "scorecard_rows returns the bounded row written by scorecard append" {
  run bash "$REPO_DIR/scripts/scorecard-read.sh" rows --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1 and .[0].metric == "retro-contract"'
  run_prepare
  manifest_row scorecard_rows | jq -e '.reader_contract_version == "1" and .stable_empty_shape == "[]"'
  jq -e '.facts.scorecard_eligibility_deltas.values.rows_total == 1' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "scorecard_current returns the snapshot produced by rollup" {
  run bash "$REPO_DIR/scripts/scorecard-read.sh" current --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reader_contract_version == "1" and .projection_mode == "snapshot" and .row_count == 1'
  run_prepare
  manifest_row scorecard_current | jq -e '
    .reader == "lore scorecard current --json" and .projection_mode == "snapshot" and
    .stable_empty_shape == "versioned-empty-summary" and .content_identity != null
  '
}

@test "session_events preserves cursor semantics while applying the half-open window" {
  run bash "$REPO_DIR/scripts/session-events.sh" --since 0 --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
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
  run bash "$REPO_DIR/scripts/journal.sh" read --since "$WINDOW_START" --until "$WINDOW_END" --json
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
      "cycle_work","due_queue","scorecard_rows","scorecard_current","session_events","journal","packet_assessments"
    ])) and
    ([.facts | keys[]] | any(. == "settlement_health_inputs" or . == "concerns_contradictions") | not) and
    ([.calculations[].calculation_id] | inside([
      "channel_contract_drift","scorecard_delta_readiness","template_headline_readiness"
    ])) and
    ([.calculations[].source_ids[]] | any(. == "settlement" or . == "consumer_contradiction_lifecycle") | not)
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "history readers have stable empty projections and absence never becomes green" {
  run bash "$REPO_DIR/scripts/retro-queue.sh" queue --cycle-id cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.counts.unhandled_due == 0 and .counts.handled_due == 0'
  run bash "$REPO_DIR/scripts/scorecard-read.sh" rows --window-start "$FUTURE_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run bash "$REPO_DIR/scripts/session-events.sh" --since 0 --window-start "$FUTURE_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.events == [] and (.next_cursor | type) == "number"'
  run bash "$REPO_DIR/scripts/journal.sh" read --since "$FUTURE_START" --until "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  run bash "$PREPARE" cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  jq -e '
    .fixed_health.state != "normal" and
    ([.calculations[] | select(.calculation_id == "template_headline_readiness")][0].disposition == "abstained")
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "writer validation rejects malformed evidence before readers see it" {
  run bash "$REPO_DIR/scripts/scorecard-append.sh" --kdir "$TEST_KDIR" --row '{"kind":"telemetry"}' --json
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/session-event-append.sh" --kdir "$TEST_KDIR" --row '{"event":"not-a-real-event"}' --json
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/scorecard-read.sh" rows --window-start "$WINDOW_START" --window-end "$WINDOW_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'length == 1'
  run_prepare
  jq -e '.fixed_health.state != "normal"' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "cycle_work v2 carries evidence bodies and names missing task evidence" {
  run_prepare
  jq -e '.schema_version == 1 and
    .source_data.cycle_work.reader_contract_version == "2" and
    .source_data.cycle_work.evidence.sources.tasks.state == "absent" and
    .source_data.cycle_work.evidence.sources.bundle.state == "absent" and
    .facts.task_context_backlinks.status == "not-computable" and
    .facts.task_context_backlinks.values == null' \
    "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  run bash "$REPO_DIR/scripts/load-work-item.sh" cycle-a --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -B "$REPO_DIR/scripts/work-evidence.py" --identity > "$TEST_KDIR/semantic-work.json"
  python3 - "$TEST_KDIR" <<'PY'
import hashlib, json, pathlib, sys
root=pathlib.Path(sys.argv[1]); work=json.loads((root/'semantic-work.json').read_text())
pack=json.loads((root/'_work/cycle-a/retro-evidence-pack.json').read_text())
assert pack['source_data']['cycle_work']==work
encoded=json.dumps(work,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
source=next(x for x in pack['source_manifest'] if x['source_id']=='cycle_work')
assert source['content_identity']==hashlib.sha256(encoded).hexdigest()
PY
}

@test "unchanged preparation excludes only its own marker and keeps exact pack bytes" {
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  cp "$pack" "$TEST_KDIR/first-pack.json"
  run_prepare
  python3 - "$pack" "$TEST_KDIR/first-pack.json" <<'PYCOMPARE'
import json,sys
left=json.load(open(sys.argv[1])); right=json.load(open(sys.argv[2]))
def differences(a,b,path=''):
 if isinstance(a,dict) and isinstance(b,dict):
  for k in sorted(a.keys()|b.keys()): differences(a.get(k),b.get(k),path+'/'+k)
 elif a!=b: print(path,repr(a)[:400],repr(b)[:400])
if left!=right: differences(left,right)
assert left==right
PYCOMPARE
  printf 'ordinary execution evidence\n' | bash "$REPO_DIR/scripts/write-execution-log.sh" --slug cycle-a --source manual
  run_prepare
  [ "$(jq -r .pack_id "$pack")" != "$(jq -r .pack_id "$TEST_KDIR/first-pack.json")" ]
  jq -e '.source_data.cycle_work.exec_log_content | contains("ordinary execution evidence")' "$pack"
}

@test "task bytes reports reviews result output packets and bundle all change identity" {
  item="$TEST_KDIR/_work/cycle-a"
  mkdir -p "$item/worker-reports" "$item/reviews/review-1" "$item/results/result-1" "$TEST_KDIR/_packets"
  printf '{"tasks":[{"id":"task-1","description":"task original","blocked_by":[]}]}' > "$item/tasks.json"
  printf 'Report-id: report-1\nStatus: completed\nreport original\n' > "$item/worker-reports/report-1.md"
  printf 'review original\n' > "$item/reviews/review-1/output.md"
  printf 'result original\n' > "$item/results/result-1/output.txt"
  printf '{"work_item":"cycle-a","tasks_completed":[],"tier2_claim_ids":[],"tier3_promoted_ids":[],"advisor_consultations_count":0,"blockers":[],"template_versions":{},"captured_at_sha":"old","run_started_at":"2026-07-01T00:00:00Z"}' > "$item/retro-bundle.json"
  printf '{"schema_version":"1","packet_id":"pkt-test","work_item":"cycle-a","task_id":"task-1","revision_id":"aaaaaaaaaaaa","delivery_stage":"assembled","delivered_entries":[]}' > "$TEST_KDIR/_packets/packets.jsonl"
  run_prepare
  previous="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
  for target in tasks.json worker-reports/report-1.md reviews/review-1/output.md results/result-1/output.txt retro-bundle.json; do
    python3 - "$item/$target" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); value=p.read_text()
p.write_text(value.replace('original','changed').replace('"old"','"new"'))
PY
    run_prepare
    current="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
    [ "$current" != "$previous" ]
    previous="$current"
  done
  python3 - "$TEST_KDIR/_packets/packets.jsonl" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace('aaaaaaaaaaaa','bbbbbbbbbbbb'))
PY
  run_prepare
  [ "$(jq -r .pack_id "$item/retro-evidence-pack.json")" != "$previous" ]
  python3 - "$item/retro-evidence-pack.json" <<'PY'
import json,sys
work=json.load(open(sys.argv[1]))['source_data']['cycle_work']
text=json.dumps(work)
for marker in ('task changed','report changed','review changed','result changed','bbbbbbbbbbbb'):
 assert marker in text, marker
PY
}

@test "malformed task repair and review outcome append remain substantive evidence" {
  item="$TEST_KDIR/_work/cycle-a"
  printf '{broken tasks' > "$item/tasks.json"
  run_prepare
  jq -e '.source_data.cycle_work.evidence.sources.tasks.state == "unreadable"' "$item/retro-evidence-pack.json"
  previous="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
  printf '{"tasks":[]}' > "$item/tasks.json"
  run_prepare
  [ "$(jq -r .pack_id "$item/retro-evidence-pack.json")" != "$previous" ]
  previous="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
  printf 'Spec-outcome-record: {"schema_version":1,"attempt_id":"historical-review","ceremony":"spec-design","outcome":"completed"}\n' |
    bash "$REPO_DIR/scripts/write-execution-log.sh" --slug cycle-a --source manual
  run_prepare
  [ "$(jq -r .pack_id "$item/retro-evidence-pack.json")" != "$previous" ]
  jq -e '.source_data.cycle_work.evidence.sources.outcomes.rows | length == 1' "$item/retro-evidence-pack.json"
  jq -e '.source_data.cycle_work.evidence.sources.outcomes.records[0].binding.state == "legacy-unbound"' "$item/retro-evidence-pack.json"
}

@test "published revision snapshots decisions and progress remain inspectable in the pack" {
  local item="$TEST_KDIR/_work/cycle-a"
  cat > "$item/plan.md" <<'PLAN'
# Cycle A

## Goal
Exercise revision evidence.

## Narrative
A task retains its criterion through publication and progress.

## Intent Anchor
Exercise every published retro evidence reader.

**Scope delta:** none

## Tasks

**Merge rationale:** One criterion exercises the revision reader.

### Task 1: Retain revision evidence
**Deliverable:** A revision-bound example.
**Files:** `example.py`
**Scope:**
- Output contract: Evidence remains inspectable.
**Close criteria:**
```json
[{"id":"C1","intent":"Observe the example","argv":["python3","-c","print('revision-one')"],"cwd":".","timeout":10,"expected_exit":0}]
```

- [ ] Retain the revision example.
PLAN
  cat > "$TEST_KDIR/decisions.json" <<'JSON'
{"anchor_coverage":{"disposition":"covered","by":"designer","note":"The criterion exercises the declared reader."},"review_requirement":{"disposition":"pending","by":"designer","note":"Review scope remains to be decided.","prior_review_refs":[]},"dispatch_decision":{"disposition":"proceed","by":"coordinator","note":"This isolated fixture can proceed while review scope is considered.","task_ids":["task-1"],"prior_review_refs":[]}}
JSON
  run bash "$REPO_DIR/scripts/plan-revise.sh" cycle-a --reason 'Publish reader fixture' --author-role designer --decisions "$TEST_KDIR/decisions.json" --json
  [ "$status" -eq 0 ]
  run_prepare
  local first_pack first_revision
  first_pack="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
  first_revision="$(jq -r .revision_id "$item/tasks.json")"
  jq -e --arg rid "$first_revision" '
    .source_data.cycle_work.evidence as $e |
    $e.revision.publication_state == "current" and
    $e.revision.head.revision_id == $rid and
    $e.sources.tasks.data.tasks[0].close_criteria[0].argv[2] == "print('\''revision-one'\'')" and
    ($e.sources.revisions.records[0].artifacts | length) >= 2 and
    ($e.sources.revisions.snapshots.entries | map(.content // "") | join("\n") | contains("revision-one"))
  ' "$item/retro-evidence-pack.json"
  cp "$item/revisions.jsonl" "$TEST_KDIR/first-ledger"
  run bash "$REPO_DIR/scripts/plan-revise.sh" cycle-a --reason 'Unchanged reader fixture' --author-role designer --json
  [ "$status" -eq 0 ]
  cmp "$TEST_KDIR/first-ledger" "$item/revisions.jsonl"
  run_prepare
  [ "$first_pack" = "$(jq -r .pack_id "$item/retro-evidence-pack.json")" ]

  run bash "$REPO_DIR/scripts/update-plan-checkbox.sh" cycle-a 'Retain the revision example.'
  [ "$status" -eq 0 ]
  run_prepare
  [ "$first_pack" != "$(jq -r .pack_id "$item/retro-evidence-pack.json")" ]
  jq -e --arg first "$first_revision" '
    .source_data.cycle_work.evidence as $e |
    $e.revision.publication_state == "current" and
    $e.revision.head.kind == "progress" and
    $e.revision.head.predecessor == $first and
    $e.sources.revisions.rows[0].revision_id == $first and
    $e.sources.tasks.data.tasks[0].id == "task-1" and
    ($e.sources.revisions.snapshots.entries | map(.content // "") | join("\n") | contains("- [ ] Retain"))
  ' "$item/retro-evidence-pack.json"
  python3 - "$item/plan.md" <<'PY_EDIT'
from pathlib import Path
import sys
p=Path(sys.argv[1]);p.write_text(p.read_text().replace("revision-one", "revision-two"))
PY_EDIT
  run bash "$REPO_DIR/scripts/plan-revise.sh" cycle-a --reason 'Change the actual criterion command' --author-role designer --json
  [ "$status" -eq 0 ]
  run_prepare
  local semantic_revision semantic_pack
  semantic_revision="$(jq -r .revision_id "$item/tasks.json")"
  semantic_pack="$(jq -r .pack_id "$item/retro-evidence-pack.json")"
  jq -e '.source_data.cycle_work.evidence as $e |
    $e.revision.head.kind == "semantic" and
    $e.revision.head.anchor_coverage.disposition == "pending" and
    ($e.sources.revisions.snapshots.entries | map(.content // "") | join("\n") | contains("revision-one")) and
    ($e.sources.tasks.content | contains("revision-two"))' "$item/retro-evidence-pack.json"
  run bash "$REPO_DIR/scripts/plan-revise.sh" cycle-a --decision-for "$semantic_revision" --decision-id reader-disposition --decisions "$TEST_KDIR/decisions.json" --json
  [ "$status" -eq 0 ]
  run_prepare
  [ "$semantic_pack" != "$(jq -r .pack_id "$item/retro-evidence-pack.json")" ]
  jq -e --arg rid "$semantic_revision" '.source_data.cycle_work.evidence as $e |
    $e.revision.head.revision_id == $rid and
    $e.sources.revisions.rows[-1].record_type == "decision" and
    $e.sources.revisions.rows[-1].revision_id == $rid' "$item/retro-evidence-pack.json"

}

@test "revision dispatch packet mismatch agrees across work retro and coordinator" {
  source "$REPO_DIR/tests/helpers/packet_revision.bash"
  item="$TEST_KDIR/_work/cycle-a"
  packet_revision_fixture "$item" cycle-a
  run bash "$REPO_DIR/scripts/impl-open.sh" cycle-a --task task-1 --json
  [ "$status" -eq 0 ]
  cp "$TEST_KDIR/_packets/packets.jsonl" "$BATS_TEST_TMPDIR/first-packets"
  printf '\nChanged packet contract.\n' >> "$item/plan.md"
  bash "$REPO_DIR/scripts/plan-revise.sh" cycle-a --decisions "$item/decisions.json" >/dev/null
  run bash "$REPO_DIR/scripts/impl-next-batch.sh" cycle-a --json
  [ "$status" -eq 0 ]
  run_prepare
  run bash "$REPO_DIR/scripts/load-work-item.sh" cycle-a --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/work.json"
  run bash "$REPO_DIR/scripts/coordinate-status.sh" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/coordinator.json"
  python3 - "$TEST_KDIR" "$BATS_TEST_TMPDIR" <<'PY'
import json, pathlib, sys
root, tmp = map(pathlib.Path, sys.argv[1:])
work = json.loads((tmp/'work.json').read_text())
pack = json.loads((root/'_work/cycle-a/retro-evidence-pack.json').read_text())
coordinator = json.loads((tmp/'coordinator.json').read_text())
assert pack['source_data']['session_events']['vocabulary_version'] == '2'
summary = work['evidence']['packet_summary']
assert len(summary) == 2
assert summary[0]['binding'] == {'state':'stale','reason':'revision-mismatch'}
assert summary[1]['binding']['state'] == 'current'
assert all(row['receipt'] == 'unknown' for row in summary)
assert summary == pack['source_data']['cycle_work']['evidence']['packet_summary']
assert summary == next(row for row in coordinator['work_evidence'] if row['slug']=='cycle-a')['packet_summary']
assert (root/'_packets/packets.jsonl').read_bytes().startswith((tmp/'first-packets').read_bytes())
rows = work['evidence']['sources']['packets']['rows']
for raw, entry in zip(rows, summary):
    for key in ('packet_id','task_id','dispatch_attempt_id','revision_id'):
        assert raw[key] == entry[key]
PY
}

@test "sealed review text dispositions and bound outcomes enter pack identity while prepare atoms do not" {
  source "$REPO_DIR/tests/helpers/packet_revision.bash"
  item="$TEST_KDIR/_work/cycle-a"
  packet_revision_fixture "$item" cycle-a
  rid=$(jq -r '.revision_id' "$item/tasks.json")
  bash "$REPO_DIR/scripts/plan-review.sh" prepare cycle-a --attempt-id review-retro --ceremony spec-design --revision "$rid" --purpose criterion-adequacy >/dev/null
  printf '%s\n' 'The criterion checks the intended behavior; the review raises a coverage question.' > "$TEST_KDIR/review.txt"
  printf '%s\n' '{"schema_version":1,"outcome":"completed","verdict":"PASS","reason":null,"judgments":[{"purpose":"criterion-adequacy","judgment":"adequate","rationale":"The criterion addresses the original anchor.","result_ids":[]}],"dispositions":[{"finding":"Coverage question","disposition":"resolved","reason":"The second branch is covered."}]}' > "$TEST_KDIR/dispositions.json"
  printf '%s\n' '{"evaluator_locator":"skill://review","evaluator_template_version":"123456789abc","framework":"codex","model":"review-model","final_round":1}' > "$TEST_KDIR/evaluator.json"
  bash "$REPO_DIR/scripts/plan-review.sh" seal cycle-a --attempt-id review-retro --output "$TEST_KDIR/review.txt" --dispositions "$TEST_KDIR/dispositions.json" --evaluator-manifest "$TEST_KDIR/evaluator.json" | jq '.evidence_manifest' > "$TEST_KDIR/review-manifest.json"
  run_prepare
  first=$(jq -r '.pack_id' "$item/retro-evidence-pack.json")
  run_prepare
  [ "$first" = "$(jq -r '.pack_id' "$item/retro-evidence-pack.json")" ]
  jq -e '.source_data.cycle_work.evidence.sources.reviews.entries | map(.content // "") | join("\n") | contains("coverage question") and contains("The second branch is covered.")' "$item/retro-evidence-pack.json"
  bash "$REPO_DIR/scripts/spec-outcome.sh" cycle-a --ceremony spec-design --advisor reviewer --attempt-id review-retro --outcome completed --verdict PASS --evidence-manifest "$TEST_KDIR/review-manifest.json" --json >/dev/null
  run_prepare
  [ "$first" != "$(jq -r '.pack_id' "$item/retro-evidence-pack.json")" ]
  after=$(jq -r '.pack_id' "$item/retro-evidence-pack.json")
  run_prepare
  [ "$after" = "$(jq -r '.pack_id' "$item/retro-evidence-pack.json")" ]
  bash "$REPO_DIR/scripts/load-work-item.sh" cycle-a --json > "$TEST_KDIR/work-view.json"
  bash "$REPO_DIR/scripts/coordinate-status.sh" --kdir "$TEST_KDIR" --json > "$TEST_KDIR/coordinator-view.json"
  python3 - "$TEST_KDIR" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);pack=json.loads((root/'_work/cycle-a/retro-evidence-pack.json').read_text())['source_data']['cycle_work']['evidence']
work=json.loads((root/'work-view.json').read_text())['evidence']
coord=next(r for r in json.loads((root/'coordinator-view.json').read_text())['work_evidence'] if r['slug']=='cycle-a')
assert pack['review_summary']==work['review_summary']==coord['review_summary']
assert pack['revision']['review_requirement']==work['revision']['review_requirement']==coord['revision']['review_requirement']
assert pack['sources']['outcomes']['rows'][0]['schema_version']==2
PY
}

# Packet rows deliberately include both cycles and two appended construction
# stages. The public work reader must supply membership and latest-row semantics.
packet_assessment_fixture() {
  mkdir -p "$TEST_KDIR/_packets"
  python3 - "$TEST_KDIR" "$NOW" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); now=sys.argv[2]
base=dict(schema_version='1', task_id='task-1', delivery_stage='assembled', delivered_entries=[])
rows=[dict(base,packet_id='pkt-a',work_item='cycle-a'),
      dict(base,packet_id='pkt-a',work_item='cycle-a',delivery_stage='synthesized',
           synthesis={'by':'lead','kept':[], 'dropped':[{'path':'old.md','reason':'irrelevant'}], 'added':[]}),
      dict(base,packet_id='pkt-b',work_item='cycle-b'),
      dict(base,packet_id='pkt-waived',work_item='cycle-a', synthesis_waiver={'by':'lead','reason':'empty candidates'}),
      dict(base,packet_id='pkt-receipt',work_item='cycle-a',delivery_stage='delivered'),
      dict(base,packet_id='pkt-unknown',work_item='cycle-a',delivery_stage='future-state')]
(root/'_packets/packets.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
row=dict(packet_id='pkt-a', source_transcript='/private/recipient-transcript.jsonl',
         assessed_at=now, assessor_schema_sha='0'*64, dispatch_confirmed=True,
         unused=[], harmful=[], missing=None, missing_not_assessable_reason='log-unavailable',
         unattributed_retrieval=[])
(root/'assessment-input.json').write_text(json.dumps(row))
PY
  run bash "$REPO_DIR/scripts/packet-assessment-append.sh" --kdir "$TEST_KDIR" --row "$(cat "$TEST_KDIR/assessment-input.json")" --json
  [ "$status" -eq 0 ]
}

@test "packet assessments register the exact cycle summary and preserve writer null semantics" {
  packet_assessment_fixture
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  jq -e '.facts.packet_delivery.values as $d |
    $d.unique_packets == 4 and $d.synthesized_packets == 1 and $d.waivers == 1 and
    $d.unknown_states == 1 and $d.receipt_state_counts.delivered == 1 and
    $d.synthesis_counts.dropped.total == 1 and $d.synthesis_counts.kept.total == 0 and
    $d.synthesis_counts.kept.excluded_packets == 3 and
    .source_data.cycle_work.evidence.packet_summary[0].superseded_rows == 1 and
    .facts.packet_assessments.values.observations == 1 and
    .facts.packet_assessments.values.classes.missing.findings == null and
    .facts.packet_assessments.values.classes.unused.findings == 0' "$pack"
  bash "$REPO_DIR/scripts/load-work-item.sh" cycle-a --json > "$TEST_KDIR/captured-work.json"
  python3 "$REPO_DIR/scripts/packet-assessments-read.py" --kdir "$TEST_KDIR" \
    --cycle-work "$TEST_KDIR/captured-work.json" --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json > "$TEST_KDIR/summary.json"
  python3 - "$pack" "$TEST_KDIR/summary.json" <<'PY'
import hashlib,json,sys
p=json.load(open(sys.argv[1])); summary=json.load(open(sys.argv[2]))
assert p['source_data']['packet_assessments']==summary
source=next(x for x in p['source_manifest'] if x['source_id']=='packet_assessments')
assert source['reader_contract_version']=='1'
assert source['projection_mode']=='cycle-assessment-summary'
assert source['window_field']=='assessed_at [start,end)'
assert '--cycle-work <captured-cycle_work-json>' in source['reader']
assert source['content_identity']==hashlib.sha256(json.dumps(summary,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
assert 'recipient-transcript' not in json.dumps(p)
assert summary['membership']['packet_ids']==['pkt-a','pkt-receipt','pkt-unknown','pkt-waived']
PY
}

@test "assessment source gaps never erase delivery facts or become zero findings" {
  packet_assessment_fixture
  rm "$TEST_KDIR/_packets/assessments.jsonl"
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  jq -e '.facts.packet_delivery.status == "available" and .facts.packet_assessments.status == "absent" and .facts.packet_assessments.values == null' "$pack"
  first=$(jq -r .pack_id "$pack")
  : > "$TEST_KDIR/_packets/assessments.jsonl"
  run_prepare
  [ "$first" != "$(jq -r .pack_id "$pack")" ]
  jq -e '.facts.packet_assessments.status == "available" and .facts.packet_assessments.values.observations == 0 and .facts.packet_assessments.values.classes.unused.findings == null' "$pack"
  printf '{broken assessment\n' > "$TEST_KDIR/_packets/assessments.jsonl"
  run_prepare
  jq -e '.facts.packet_delivery.status == "available" and .facts.packet_assessments.status == "not-computable" and .source_data.packet_assessments.diagnostics[0].reason == "malformed-json"' "$pack"
  manifest_row packet_assessments | jq -e '.coverage == "unreadable"'
  rm "$TEST_KDIR/_packets/assessments.jsonl"
  mkdir "$TEST_KDIR/_packets/assessments.jsonl"
  run_prepare
  manifest_row packet_assessments | jq -e '.coverage == "unreadable"'
}

@test "packet source absent empty and malformed retain distinct membership coverage" {
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  jq -e '.facts.packet_delivery.status == "not-computable" and .source_data.packet_assessments.membership.state == "unknown"' "$pack"
  mkdir -p "$TEST_KDIR/_packets"
  : > "$TEST_KDIR/_packets/packets.jsonl"
  : > "$TEST_KDIR/_packets/assessments.jsonl"
  run_prepare
  jq -e '.facts.packet_delivery.values.unique_packets == 0 and .facts.packet_assessments.values.eligible_packets == 0' "$pack"
  printf '{broken packet\n' > "$TEST_KDIR/_packets/packets.jsonl"
  run_prepare
  jq -e '.facts.packet_delivery.values == null and .facts.packet_assessments.status == "not-computable"' "$pack"
}

@test "assessment eligibility controls reuse and a later window admits delayed observations" {
  packet_assessment_fixture
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  cp "$pack" "$TEST_KDIR/first-pack.json"
  run_prepare
  cmp "$pack" "$TEST_KDIR/first-pack.json"
  # Neither another cycle nor a delayed assessment belongs to this projection.
  for case in unrelated delayed; do
    python3 - "$TEST_KDIR" "$case" "$FUTURE_START" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); row=json.loads((root/'assessment-input.json').read_text())
if sys.argv[2]=='unrelated': row['packet_id']='pkt-b'
else: row['assessed_at']=sys.argv[3]
(root/'next-assessment.json').write_text(json.dumps(row))
PY
    bash "$REPO_DIR/scripts/packet-assessment-append.sh" --kdir "$TEST_KDIR" --row "$(cat "$TEST_KDIR/next-assessment.json")" --json >/dev/null
    run_prepare
    cmp "$pack" "$TEST_KDIR/first-pack.json"
  done
  # A second transcript inside the window is a distinct observation.
  jq '.source_transcript = "/private/second.jsonl"' "$TEST_KDIR/assessment-input.json" > "$TEST_KDIR/next-assessment.json"
  bash "$REPO_DIR/scripts/packet-assessment-append.sh" --kdir "$TEST_KDIR" --row "$(cat "$TEST_KDIR/next-assessment.json")" --json >/dev/null
  run_prepare
  [ "$(jq -r .pack_id "$pack")" != "$(jq -r .pack_id "$TEST_KDIR/first-pack.json")" ]
  jq -e '.facts.packet_assessments.values.observations == 2' "$pack"
  run bash "$PREPARE" cycle-a --window-start "$FUTURE_START" --window-end "$FUTURE_END" --json
  [ "$status" -eq 0 ]
  jq -e '.facts.packet_assessments.values.observations == 1 and .source_data.packet_assessments.window.selection == "[start,end)"' "$pack"
}

@test "archived cycle keeps packet membership isolated from a second cycle" {
  packet_assessment_fixture
  bash "$REPO_DIR/scripts/create-work.sh" --title 'Cycle B' --slug cycle-b --intent-anchor 'Other cycle' --json >/dev/null
  mkdir -p "$TEST_KDIR/_work/_archive"
  mv "$TEST_KDIR/_work/cycle-a" "$TEST_KDIR/_work/_archive/cycle-a"
  run bash "$PREPARE" cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  jq -e '.cycle.archived == true and .facts.packet_assessments.values.observations == 1 and .facts.packet_delivery.values.unique_packets == 4' "$TEST_KDIR/_work/_archive/cycle-a/retro-evidence-pack.json"
  run bash "$PREPARE" cycle-b --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  jq -e '.facts.packet_delivery.values.unique_packets == 1 and .facts.packet_assessments.values.observations == 0' "$TEST_KDIR/_work/cycle-b/retro-evidence-pack.json"
}

@test "prepare freezes complete rubric bytes and relevant edits invalidate reuse" {
  local isolated="$BATS_TEST_TMPDIR/isolated"
  mkdir -p "$isolated/skills/retro"
  cp -R "$REPO_DIR/scripts" "$isolated/scripts"
  cp "$REPO_DIR/skills/retro/rubric.json" "$isolated/skills/retro/rubric.json"
  PREPARE="$isolated/scripts/retro-prepare.sh"
  run_prepare
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  jq .rubric "$pack" > "$TEST_KDIR/frozen.json"
  run python3 "$REPO_DIR/scripts/retro-rubric.py" validate-frozen "$TEST_KDIR/frozen.json"
  [ "$status" -eq 0 ]
  first=$(jq -r .pack_id "$pack")
  version=$(jq -r .rubric.rubric_version "$pack")
  printf 'Only protocol prose changed.\n' > "$isolated/skills/retro/SKILL.md"
  run_prepare
  [ "$first" = "$(jq -r .pack_id "$pack")" ]
  printf '\n' >> "$isolated/skills/retro/rubric.json"
  run_prepare
  [ "$first" != "$(jq -r .pack_id "$pack")" ]
  [ "$version" != "$(jq -r .rubric.rubric_version "$pack")" ]
  # An old valid descriptor stays independently verifiable.
  run python3 "$REPO_DIR/scripts/retro-rubric.py" validate-frozen "$TEST_KDIR/frozen.json"
  [ "$status" -eq 0 ]
  printf '{invalid rubric' > "$isolated/skills/retro/rubric.json"
  run bash "$PREPARE" cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -ne 0 ]
  [[ "$output" == *pack-build-failed* ]]
}

@test "prepare claims resurfaced deferrals with original IDs and preserves claim provenance on replay" {
  queue="$TEST_KDIR/_scorecards/retro-deferred-queue.jsonl"
  oid=$(jq -r 'select(.record_type == "outcome") | .outcome_id' "$queue")
  run bash "$REPO_DIR/scripts/retro-queue.sh" handle --outcome-id "$oid" --action deferred --handled-by coordinate --json
  [ "$status" -eq 0 ]
  cp "$queue" "$TEST_KDIR/original-queue"
  run_prepare
  [ "$(wc -l < "$queue" | tr -d ' ')" -eq 3 ]
  head -n 2 "$queue" > "$TEST_KDIR/retained-queue"
  cmp "$TEST_KDIR/original-queue" "$TEST_KDIR/retained-queue"
  pack="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  jq -e --arg oid "$oid" '
    .due_claim.attempted and .due_claim.disposition == "handled" and
    .due_claim.candidate_outcome_ids == [$oid] and .due_claim.outcome_ids == [$oid] and
    .due_claim.writer == "retro-queue.sh handle" and .due_claim.writer_exit_code == 0 and
    .due_claim.appended == 1 and .due_claim.warning == null and
    .source_data.due_queue.fold_version == "2" and .source_data.due_queue.vocabulary_version == "1" and
    .source_data.due_queue.counts.unhandled_due == 0 and
    .source_data.due_queue.handled_due[0].handling.handled_by == "retro-lead" and
    .rubric.rubric_id == "retro-rubric"
  ' "$pack"
  cp "$pack" "$TEST_KDIR/first-pack"
  run_prepare
  cmp "$pack" "$TEST_KDIR/first-pack"
  [ "$(wc -l < "$queue" | tr -d ' ')" -eq 3 ]
}

# Copy the scripts to inject failures only at the public queue front. All other
# readers and preparation still execute normally against the isolated store.
queue_failure_front() {
  cp -R "$REPO_DIR/scripts" "$TEST_KDIR/scripts"
  ln -s "$REPO_DIR/skills" "$TEST_KDIR/skills"
  ln -s "$REPO_DIR/adapters" "$TEST_KDIR/adapters"
  mv "$TEST_KDIR/scripts/retro-queue.sh" "$TEST_KDIR/scripts/retro-queue-real.sh"
  cat > "$TEST_KDIR/scripts/retro-queue.sh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "$FAIL_QUEUE_OPERATION" ]]; then
  echo "injected $1 evidence failure" >&2
  exit 23
fi
exec bash "$(dirname "$0")/retro-queue-real.sh" "$@"
SH
  PREPARE="$TEST_KDIR/scripts/retro-prepare.sh"
}

@test "prepare writer failure warns with attempted IDs and does not block the evidence pack" {
  queue_failure_front
  export FAIL_QUEUE_OPERATION=handle
  run bash "$PREPARE" cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"best-effort DUE claim failed"* ]]
  [[ "$output" == *"exit 23"* ]]
  jq -e '
    .due_claim.attempted and .due_claim.disposition == "failed" and
    (.due_claim.candidate_outcome_ids | length) == 1 and .due_claim.outcome_ids == [] and
    .due_claim.reader_exit_code == 0 and .due_claim.writer_exit_code == 23 and
    (.due_claim.warning | contains("injected handle evidence failure")) and
    .source_data.due_queue.counts.unhandled_due == 1
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  [ "$(wc -l < "$TEST_KDIR/_scorecards/retro-deferred-queue.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "prepare reader failure records an unattempted claim and unreadable source without blocking" {
  queue_failure_front
  export FAIL_QUEUE_OPERATION=queue
  run bash "$PREPARE" cycle-a --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"DUE queue reader failed"* ]]
  jq -e '
    .due_claim.attempted == false and .due_claim.disposition == "failed" and
    .due_claim.reader_exit_code == 23 and .due_claim.writer_exit_code == null and
    .due_claim.outcome_ids == [] and
    (.due_claim.warning | contains("injected queue evidence failure")) and
    .source_data.due_queue == null and
    any(.source_manifest[]; .source_id == "due_queue" and .coverage == "unreadable")
  ' "$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
}

@test "coordinate status accepts fold two and deferred rows retain the unhandled vocabulary" {
  run bash "$REPO_DIR/scripts/retro-queue.sh" handle --cycle-id cycle-a --action deferred --handled-by coordinate --json
  [ "$status" -eq 0 ]
  run bash "$REPO_DIR/scripts/coordinate-status.sh" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    any(.buckets.needs_judgment[]; .source_id == "retro-queue") and
    all(.source_manifest[] | select(.source_id == "retro-queue");
        .schema_version == "2" and .vocabulary_version == "1" and .read_status == "ok")
  '
}

# One whole cycle through the deployed rubric, prepare, file, journal, and
# scorecard paths. Fixture-only replicas cannot show that these seams agree.
write_v2_judgment() {
  local cycle="$1" pack="$2" out="$3" d6_json="$4"
  jq -n --arg cycle "$cycle" --arg pack_id "$(jq -r .pack_id "$pack")" \
    --arg pack_sha "$(jq -r .artifact_sha256 "$pack")" \
    --arg rubric_id "$(jq -r .rubric.rubric_id "$pack")" \
    --arg rubric_version "$(jq -r .rubric.rubric_version "$pack")" \
    --argjson d6 "$d6_json" '{
    schema_version:2, cycle_id:$cycle, pack_id:$pack_id, pack_sha256:$pack_sha,
    rubric_id:$rubric_id, rubric_version:$rubric_version,
    actor:"retro-lead", model:"fixture-model",
    key_finding:"The pack names its packet evidence and its gaps.",
    most_actionable_gap:"Recipient-use evidence is thin.",
    dimension_judgments:[
      {dimension_id:"D1",disposition:"scored",score:5,rationale:"Delivery complete.",evidence_refs:["source:cycle_work"]},
      {dimension_id:"D2",disposition:"scored",score:4,rationale:"Evidence quality explicit.",evidence_refs:["pack:/source_manifest"]},
      {dimension_id:"D3",disposition:"scored",score:4,rationale:"Gaps are named.",evidence_refs:["calculation:channel_contract_drift"]},
      {dimension_id:"D4",disposition:"scored",score:5,rationale:"Anchor alignment holds.",evidence_refs:["pack:/cycle/slug"]},
      {dimension_id:"D5",disposition:"scored",score:4,rationale:"Spec was useful.",evidence_refs:["source:journal"]},
      $d6
    ],
    behavioral_health:[{check_id:"C7",answer:"The judgments read the evidence rather than defaulting to green.",evidence_refs:["pack:/fixed_health/state"]}],
    causal_diagnoses:[],
    escalation_judgment:{applicability:"not-applicable",reason:"No worker escalation fired."},
    scale_access_judgment:{applicability:"not-applicable",reason:"No scale comparison applies."},
    channel_flags:{applicability:"applicable",value:[]},
    suggestion_outcome:"no-substantive-suggestion", suggestions:[]
  }' > "$out"
}

file_json() { echo "$output" | grep '^{' | tail -1; }

@test "complete cycle files rubric-bound judgments through deployed paths and reads separated series" {
  journal="$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  rows="$TEST_KDIR/_scorecards/rows.jsonl"
  # A historical retro entry: numeric D5, no rubric identity, written by the sole writer.
  run bash "$REPO_DIR/scripts/journal.sh" write --observation "historical retro" --context "retro: cycle-a | legacy" \
    --work-item cycle-a --role retro --scores '{"d5_spec_utility":3}'
  [ "$status" -eq 0 ]
  cp "$journal" "$TEST_KDIR/journal-history"
  cp "$rows" "$TEST_KDIR/rows-history"

  packet_assessment_fixture
  run_prepare
  pack_a="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  version_a=$(jq -r .rubric.rubric_version "$pack_a")
  [[ "$version_a" =~ ^[0-9a-f]{12}$ ]]
  [ "$version_a" = "$(python3 "$REPO_DIR/scripts/retro-rubric.py" descriptor | jq -r .rubric_version)" ]
  jq -e '.facts.packet_assessments.values.observations == 1 and
    .facts.packet_assessments.values.classes.unused.findings == 0 and
    .facts.packet_assessments.values.classes.missing.findings == null and
    .facts.packet_delivery.values.receipt_state_counts.delivered == 1' "$pack_a"

  write_v2_judgment cycle-a "$pack_a" "$TEST_KDIR/judgment-a.json" \
    '{"dimension_id":"D6","disposition":"scored","score":4,"rationale":"One confirmed recipient; unused and harmful classes assessed clean; the missing class was not assessable.","evidence_refs":["source:packet_assessments","pack:/facts/packet_assessments/values/classes/unused","pack:/facts/packet_delivery/values/receipt_state_counts"]}'
  run bash "$REPO_DIR/scripts/retro-file.sh" cycle-a --pack "$pack_a" --judgments "$TEST_KDIR/judgment-a.json" --json
  [ "$status" -eq 0 ]
  file_json | jq -e '.status=="created" and .filing_complete and (.completed_sinks|index("scorecard:dimension:D6")) and .missing_sinks==[]'

  # Historical bytes are an exact prefix; the new identity travels through journal and scorecard.
  head -c "$(wc -c < "$TEST_KDIR/journal-history")" "$journal" | cmp - "$TEST_KDIR/journal-history"
  head -c "$(wc -c < "$TEST_KDIR/rows-history")" "$rows" | cmp - "$TEST_KDIR/rows-history"
  jq -se --arg v "$version_a" 'map(select(.role=="retro" and .work_item=="cycle-a" and .scores!=null and .rubric_id!=null)) |
    length==1 and .[0].rubric_id=="retro-rubric" and .[0].rubric_version==$v and
    .[0].scores.d5_spec_utility==4 and .[0].scores.d6_packet_utility==4 and
    (.[0].scores|to_entries|all(.value|type=="number"))' "$journal"
  jq -se --arg v "$version_a" 'map(select(.kind=="scored")) | length==6 and
    all(.tier=="template" and .template_id=="retro-rubric" and .template_version==$v and
        .calibration_state=="pre-calibration" and .verdict_source=="retro-lead" and .sample_size==1) and
    (map(.metric)|sort)==["d1_delivery","d2_quality","d3_gaps","d4_alignment","d5_spec_utility","d6_packet_utility"]' "$rows"
  jq -se '.[-1].event_type=="retro-filing" and .[-1].filing_complete==true' "$rows"
  cp "$journal" "$TEST_KDIR/journal-after-a"
  cp "$rows" "$TEST_KDIR/rows-after-a"

  # A second cycle prepared under a changed rubric: prepare runs from an isolated
  # copy whose rubric bytes differ; the deployed verb files against the frozen pack.
  bash "$REPO_DIR/scripts/create-work.sh" --title 'Cycle B' --slug cycle-b --intent-anchor 'Second rubric series' --json >/dev/null
  isolated="$BATS_TEST_TMPDIR/next-rubric"
  mkdir -p "$isolated/skills/retro"
  cp -R "$REPO_DIR/scripts" "$isolated/scripts"
  cp "$REPO_DIR/skills/retro/rubric.json" "$isolated/skills/retro/rubric.json"
  printf '\n' >> "$isolated/skills/retro/rubric.json"
  run bash "$isolated/scripts/retro-prepare.sh" cycle-b --window-start "$WINDOW_START" --window-end "$WINDOW_END" --json
  [ "$status" -eq 0 ]
  pack_b="$TEST_KDIR/_work/cycle-b/retro-evidence-pack.json"
  version_b=$(jq -r .rubric.rubric_version "$pack_b")
  [[ "$version_b" =~ ^[0-9a-f]{12}$ ]]
  [ "$version_b" != "$version_a" ]
  jq -e '.facts.packet_delivery.values.unique_packets == 1 and .facts.packet_assessments.values.observations == 0' "$pack_b"
  write_v2_judgment cycle-b "$pack_b" "$TEST_KDIR/judgment-b.json" \
    '{"dimension_id":"D6","disposition":"not-assessable","score":null,"reason":"One packet was built and no recipient-use observation exists inside the window.","rationale":"Construction without an observed recipient supports no usefulness verdict.","evidence_refs":["pack:/facts/packet_delivery/values/unique_packets","pack:/facts/packet_assessments/values/observations"]}'
  run bash "$REPO_DIR/scripts/retro-file.sh" cycle-b --pack "$pack_b" --judgments "$TEST_KDIR/judgment-b.json" --json
  [ "$status" -eq 0 ]
  file_json | jq -e '.status=="created" and .filing_complete and ((.completed_sinks|index("scorecard:dimension:D6"))==null) and (.completed_sinks|index("scorecard:dimension:D5"))'
  jq -e '.judgments.dimension_judgments[5] | .dimension_id=="D6" and .disposition=="not-assessable" and .score==null and (.reason|length)>0 and (.evidence_refs|length)==2' \
    "$TEST_KDIR/_work/cycle-b/retro-filing.json"
  head -c "$(wc -c < "$TEST_KDIR/journal-after-a")" "$journal" | cmp - "$TEST_KDIR/journal-after-a"
  head -c "$(wc -c < "$TEST_KDIR/rows-after-a")" "$rows" | cmp - "$TEST_KDIR/rows-after-a"
  jq -se --arg v "$version_b" 'map(select(.kind=="scored" and .template_version==$v)) | length==5 and all(.metric!="d6_packet_utility")' "$rows"
  jq -se --arg v "$version_b" 'map(select(.role=="retro" and .work_item=="cycle-b" and .scores!=null)) |
    length==1 and .[0].rubric_version==$v and (.[0].scores|has("d6_packet_utility")|not) and .[0].scores.d5_spec_utility==4' "$journal"

  # The opt-in comparison from the skill: explicit columns, unknown history, null for an abstained D6.
  run bash "$REPO_DIR/scripts/journal.sh" query --role retro --extract-scores --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$version_a" --arg b "$version_b" '
    [.[] | {date: .timestamp, rubric_id, rubric_version,
            d5_spec_utility: .scores.d5_spec_utility,
            d6_packet_utility: .scores.d6_packet_utility}] |
    length==3 and
    (.[0] | .rubric_id=="legacy-unversioned" and .rubric_version==null and .d5_spec_utility==3 and .d6_packet_utility==null) and
    (.[1] | .rubric_id=="retro-rubric" and .rubric_version==$a and .d5_spec_utility==4 and .d6_packet_utility==4) and
    (.[2] | .rubric_id=="retro-rubric" and .rubric_version==$b and .d5_spec_utility==4 and .d6_packet_utility==null)'
  run bash "$REPO_DIR/scripts/journal.sh" query --role retro --extract-scores
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy-unversioned@unknown"* && "$output" == *"retro-rubric@$version_a"* && "$output" == *"retro-rubric@$version_b"* ]]

  # The deployed scorecard reader and aggregate grouping keep the two versions as separate series.
  run bash "$REPO_DIR/scripts/scorecard-read.sh" rows --window-start "$WINDOW_START" --window-end "$FUTURE_END" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$version_a" --arg b "$version_b" 'map(select(.kind=="scored")) | length==11 and (map(.template_version)|unique|sort)==([$a,$b]|sort)'
  run python3 "$REPO_DIR/scripts/retro-export-aggregate-cells.py" "$rows" 2026-01-01T00:00:00Z fixture
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg a "$version_a" --arg b "$version_b" '
    (map(select(.metric=="d5_spec_utility")) | length==2 and (map(.template_version)|sort)==([$a,$b]|sort) and all(.n==1 and (.calibrated_only|not))) and
    (map(select(.metric=="d6_packet_utility")) | length==1 and .[0].template_version==$a)'

  # Exact replay of both filings adds nothing.
  cp "$journal" "$TEST_KDIR/journal-final"
  cp "$rows" "$TEST_KDIR/rows-final"
  run bash "$REPO_DIR/scripts/retro-file.sh" cycle-a --pack "$pack_a" --judgments "$TEST_KDIR/judgment-a.json" --json
  [ "$status" -eq 0 ]
  file_json | jq -e '.status=="reused" and .filing_complete'
  run bash "$REPO_DIR/scripts/retro-file.sh" cycle-b --pack "$pack_b" --judgments "$TEST_KDIR/judgment-b.json" --json
  [ "$status" -eq 0 ]
  file_json | jq -e '.status=="reused" and .filing_complete'
  cmp "$journal" "$TEST_KDIR/journal-final"
  cmp "$rows" "$TEST_KDIR/rows-final"
}

@test "result rows carrying host load and environment fields pass the reader intact" {
  item="$TEST_KDIR/_work/cycle-a"
  mkdir -p "$item/results/result-load"
  printf 'load probe output\n' > "$item/results/result-load/output.out"
  sha="$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$item/results/result-load/output.out")"
  jq -cn --arg sha "$sha" '{
    schema_version: 1, result_id: "result-load", execution_attempt_id: "execution-load", dispatch_attempt_id: "dispatch-load",
    packet_id: "pkt-load", task_id: "task-1", criterion_id: "load-criterion", revision_id: "aaaaaaaaaaaa",
    criterion_version: ("c" * 64), state: "pass", exit: 0, signal: null, timed_out: false, execution_sequence: 1,
    output_path: "results/result-load/output.out", output_sha256: $sha, reason: "expected-exit",
    source_start: {head: "h", digest: "d", digest_version: "2", worktree: "/w"},
    source_end: {head: "h", digest: "d", digest_version: "2", worktree: "/w"},
    host_load_start: {timestamp: "2026-09-06T00:00:00Z", load_average_1_5_15: [1.5, 1.2, 1.0], cpu_count: 8},
    host_load_end: {timestamp: "2026-09-06T00:01:00Z", load_average_1_5_15: null, cpu_count: 8},
    environment: {PYTEST_DISABLE_PLUGIN_AUTOLOAD: "1"}
  }' > "$item/results.jsonl"
  run_prepare
  python3 - "$item/retro-evidence-pack.json" <<'PY'
import json, sys
pack = json.load(open(sys.argv[1]))
work = pack['source_data']['cycle_work']
text = json.dumps(work)
assert 'invalid-results-record' not in text, 'reader rejected a row that only added executor fields'
for marker in ('"host_load_start"', '"host_load_end"', '"load_average_1_5_15"', '"cpu_count": 8', '"PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"'):
    assert marker in text, marker
PY
}
