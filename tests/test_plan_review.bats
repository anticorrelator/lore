#!/usr/bin/env bats
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
load helpers/packet_revision

setup() {
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  ITEM="$TEST_KDIR/_work/review-item"
  packet_revision_fixture "$ITEM" review-item
  RID=$(jq -r '.revision_id' "$ITEM/tasks.json")
  printf '%s\n' 'The task preserves the original intent; criterion coverage is adequate.' > "$TEST_KDIR/review.md"
  printf '%s\n' '{"schema_version":1,"outcome":"completed","verdict":"PASS","reason":null,"judgments":[{"purpose":"criterion-adequacy","judgment":"adequate","rationale":"The check exercises the intended behavior.","result_ids":[]}],"dispositions":[{"finding":"Coverage","disposition":"accepted","reason":"The check matches the anchor."}]}' > "$TEST_KDIR/dispositions.json"
  printf '%s\n' '{"evaluator_locator":"skill://review","evaluator_template_version":"123456789abc","framework":"codex","model":"review-model","final_round":1}' > "$TEST_KDIR/evaluator.json"
}
teardown() { rm -rf "$TEST_KDIR"; }
prepare_review() {
  bash "$REPO_DIR/scripts/plan-review.sh" prepare review-item --attempt-id review-1 \
    --revision "$RID" --ceremony spec-post-plan --purpose criterion-adequacy
}
seal_review() {
  bash "$REPO_DIR/scripts/plan-review.sh" seal review-item --attempt-id review-1 \
    --output "$TEST_KDIR/review.md" --dispositions "$TEST_KDIR/dispositions.json" \
    --evaluator-manifest "$TEST_KDIR/evaluator.json"
}
file_review() {
  bash "$REPO_DIR/scripts/spec-outcome.sh" review-item --ceremony spec-post-plan --advisor reviewer \
    --attempt-id review-1 --outcome completed --verdict PASS --evidence-manifest "$TEST_KDIR/manifest.json" --json
}
seal_manifest() { seal_review | jq '.evidence_manifest' > "$TEST_KDIR/manifest.json"; }

@test "prepared review files outcome against N after live plan becomes N+1 and retries retain exact identity" {
  prepare_review > "$TEST_KDIR/prepare.json"
  cp "$ITEM/reviews/review-1/prepared.json" "$TEST_KDIR/prepared-original"
  sed -i.bak 's/Record history/Record revised history/g' "$ITEM/plan.md"
  bash "$REPO_DIR/scripts/plan-revise.sh" review-item >/dev/null
  [ "$RID" != "$(jq -r '.revision_id' "$ITEM/tasks.json")" ]
  seal_manifest
  cp "$ITEM/reviews/review-1/sealed/seal.json" "$TEST_KDIR/seal-original"
  run prepare_review; [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
  run seal_review; [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
  file_review > "$TEST_KDIR/outcome.json"
  run file_review; [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
  [ "$(grep -c '^Spec-outcome-record:' "$ITEM/execution-log.md")" -eq 1 ]
  cmp "$TEST_KDIR/prepared-original" "$ITEM/reviews/review-1/prepared.json"
  cmp "$TEST_KDIR/seal-original" "$ITEM/reviews/review-1/sealed/seal.json"
  bash "$REPO_DIR/scripts/load-work-item.sh" review-item --json > "$TEST_KDIR/work.json"
  jq -e --arg rid "$RID" '.evidence.sources.outcomes.rows[0] | .schema_version==2 and .revision_id==$rid' "$TEST_KDIR/work.json"
  jq -e '.evidence.review_summary[0] | .state=="sealed" and .binding.state=="stale" and .execution_evidence=="none"' "$TEST_KDIR/work.json"
}

@test "conflicting prepare seal and outcome attempt reuse preserve accepted artifacts" {
  prepare_review >/dev/null; seal_manifest; file_review >/dev/null
  cp "$ITEM/reviews/review-1/sealed/seal.json" "$TEST_KDIR/original"
  run bash "$REPO_DIR/scripts/plan-review.sh" prepare review-item --attempt-id review-1 --revision "$RID" --ceremony spec-design --purpose criterion-adequacy
  [ "$status" -eq 1 ]; [[ "$output" == *collision* ]]
  printf 'Changed verdict text\n' > "$TEST_KDIR/review.md"
  run seal_review; [ "$status" -eq 1 ]; [[ "$output" == *collision* ]]
  run bash "$REPO_DIR/scripts/spec-outcome.sh" review-item --ceremony spec-post-plan --advisor reviewer --attempt-id review-1 --outcome failed --verdict FAIL --evidence-manifest "$TEST_KDIR/manifest.json" --json
  [ "$status" -eq 1 ]
  cmp "$TEST_KDIR/original" "$ITEM/reviews/review-1/sealed/seal.json"
  [ "$(grep -c '^Spec-outcome-record:' "$ITEM/execution-log.md")" -eq 1 ]
}

@test "wrong snapshot ledger and manifest hashes fail before outcome filing" {
  prepare_review >/dev/null; seal_manifest
  cp "$ITEM/reviews/review-1/plan.md" "$TEST_KDIR/original-plan"
  printf 'wrong\n' > "$ITEM/reviews/review-1/plan.md"
  run file_review; [ "$status" -eq 1 ]
  cp "$TEST_KDIR/original-plan" "$ITEM/reviews/review-1/plan.md"
  printf 'wrong\n' >> "$ITEM/reviews/review-1/sealed/dispositions.json"
  run file_review; [ "$status" -eq 1 ]
  cp "$TEST_KDIR/dispositions.json" "$ITEM/reviews/review-1/sealed/dispositions.json"
  jq '.review_sha256="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$TEST_KDIR/manifest.json" > "$TEST_KDIR/bad.json"
  mv "$TEST_KDIR/bad.json" "$TEST_KDIR/manifest.json"
  run file_review; [ "$status" -eq 1 ]
  [ ! -f "$ITEM/execution-log.md" ]
}

@test "seal refuses command results and invented result ids" {
  prepare_review >/dev/null
  jq '.judgments[0].exit=0' "$TEST_KDIR/dispositions.json" > "$TEST_KDIR/bad.json"
  mv "$TEST_KDIR/bad.json" "$TEST_KDIR/dispositions.json"
  run seal_review; [ "$status" -eq 1 ]; [[ "$output" == *executor* ]]
  jq 'del(.judgments[0].exit) | .judgments[0].result_ids=["invented"]' "$TEST_KDIR/dispositions.json" > "$TEST_KDIR/bad.json"
  mv "$TEST_KDIR/bad.json" "$TEST_KDIR/dispositions.json"
  run seal_review; [ "$status" -eq 1 ]; [[ "$output" == *result* ]]
  [ ! -d "$ITEM/reviews/review-1/sealed" ]
}

@test "publication failures leave no accepted partial review and retry publishes once" {
  export LORE_PLAN_REVIEW_FAIL_AT=review-1
  run prepare_review; [ "$status" -eq 1 ]; [ ! -e "$ITEM/reviews/review-1" ]
  unset LORE_PLAN_REVIEW_FAIL_AT
  prepare_review >/dev/null
  export LORE_PLAN_REVIEW_FAIL_AT=sealed
  run seal_review; [ "$status" -eq 1 ]; [ ! -e "$ITEM/reviews/review-1/sealed" ]
  unset LORE_PLAN_REVIEW_FAIL_AT
  run seal_review; [ "$status" -eq 0 ]; [[ "$output" == *'"sealed"'* ]]
  run seal_review; [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
}

@test "required pending dispatch and prior review reuse stay separate authored decisions" {
  prepare_review >/dev/null; seal_manifest; file_review >/dev/null
  sed -i.bak 's/Record history/Record revised history/g' "$ITEM/plan.md"
  bash "$REPO_DIR/scripts/plan-revise.sh" review-item >/dev/null
  NEW_RID=$(jq -r '.revision_id' "$ITEM/tasks.json")
  bash "$REPO_DIR/scripts/load-work-item.sh" review-item --json > "$TEST_KDIR/pending.json"
  jq -e '.evidence.revision.review_requirement | .state=="read" and .value.disposition=="pending" and .value.by==null' "$TEST_KDIR/pending.json"
  printf '%s\n' '{"anchor_coverage":{"disposition":"covered","by":"designer","note":"Coverage retained."},"review_requirement":{"disposition":"required","by":"designer","note":"Changed scope."}}' > "$TEST_KDIR/decision.json"
  bash "$REPO_DIR/scripts/plan-revise.sh" review-item --decision-for "$NEW_RID" --decision-id required --decisions "$TEST_KDIR/decision.json" >/dev/null
  bash "$REPO_DIR/scripts/load-work-item.sh" review-item --json > "$TEST_KDIR/required.json"
  jq -e '.evidence.revision | .review_requirement.value.disposition=="required" and .dispatch.blocked["task-1"]=="missing authored dispatch decision"' "$TEST_KDIR/required.json"
  printf '%s\n' '{"dispatch_decision":{"disposition":"reuse","by":"coordinator","note":"The renamed task preserves the reviewed scope.","task_ids":["task-1"],"prior_review_refs":["reviews/review-1/sealed/seal.json"]}}' > "$TEST_KDIR/decision.json"
  bash "$REPO_DIR/scripts/plan-revise.sh" review-item --decision-for "$NEW_RID" --decision-id reuse --decisions "$TEST_KDIR/decision.json" >/dev/null
  bash "$REPO_DIR/scripts/load-work-item.sh" review-item --json > "$TEST_KDIR/reuse.json"
  jq -e '.evidence.revision | .review_requirement.value.disposition=="required" and .dispatch.blocked=={} and .dispatch.tasks["task-1"].dispatch.disposition=="reuse"' "$TEST_KDIR/reuse.json"
  bash "$REPO_DIR/scripts/coordinate-status.sh" --json > "$TEST_KDIR/status.json"
  python3 - "$TEST_KDIR/reuse.json" "$TEST_KDIR/status.json" <<'PY'
import json,sys
work=json.load(open(sys.argv[1]))['evidence']
status=json.load(open(sys.argv[2]))
def find(value):
    if isinstance(value, dict):
        if value.get('slug')=='review-item' and 'review_summary' in value: return value
        for v in value.values():
            found=find(v)
            if found: return found
    if isinstance(value, list):
        for v in value:
            found=find(v)
            if found: return found
found=find(status)
assert found is not None
assert found['review_summary']==work['review_summary']
assert found['revision']==work['revision']
PY
}

@test "integration freezes code identity and archive retains review bodies" {
  CODE="$TEST_KDIR/code"
  git init -q "$CODE"
  printf 'source\n' > "$CODE/source"
  git -C "$CODE" add .
  git -C "$CODE" -c user.name=Fixture -c user.email=f@example.test commit -qm Fixture
  run bash "$REPO_DIR/scripts/plan-review.sh" prepare review-item --attempt-id review-1 --revision "$RID" --ceremony spec-post-plan --purpose integration --execution-worktree "$CODE"
  [ "$status" -eq 0 ]
  jq '.judgments += [{"purpose":"integration","judgment":"consistent","rationale":"The composed source meets the anchor; no execution evidence is cited.","result_ids":[]}]' "$TEST_KDIR/dispositions.json" > "$TEST_KDIR/both.json"
  mv "$TEST_KDIR/both.json" "$TEST_KDIR/dispositions.json"
  seal_manifest; file_review >/dev/null
  printf 'changed\n' >> "$CODE/source"
  run bash "$REPO_DIR/scripts/plan-review.sh" prepare review-item --attempt-id review-1 --revision "$RID" --ceremony spec-post-plan --purpose integration --execution-worktree "$CODE"
  [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
  mkdir -p "$TEST_KDIR/_work/_archive"
  mv "$ITEM" "$TEST_KDIR/_work/_archive/review-item"
  python3 - "$REPO_DIR" "$TEST_KDIR" <<'PY'
import runpy,sys
from pathlib import Path
api=runpy.run_path(sys.argv[1]+'/scripts/work-evidence.py')
root=Path(sys.argv[2]); item=root/'_work/_archive/review-item'
e=api['project'](item,root)
assert e['review_summary'][0]['state']=='sealed'
assert e['sources']['outcomes']['records'][0]['binding']['state']=='current'
assert any('composed source' in (x.get('content') or '') for x in e['sources']['reviews']['entries'])
PY
}

@test "seal freezes validated result rows and output and replay does not consult changed live results" {
  prepare_review >/dev/null
  python3 - "$ITEM" "$RID" "$TEST_KDIR/dispositions.json" <<'PY'
import json,hashlib,sys
from pathlib import Path
item=Path(sys.argv[1]); output=b'failed assertion\n'
(item/'results/r1').mkdir(parents=True)
(item/'results/r1/output.txt').write_bytes(output)
row={'schema_version':1,'result_id':'r1','execution_attempt_id':'run-r1','task_id':'task-1','criterion_id':'c1',
     'revision_id':sys.argv[2],'criterion_version':'a'*64,'state':'fail','exit':1,'signal':None,'timed_out':False,
     'unbound_reason':'Historical fixture execution','output_path':'results/r1/output.txt','output_sha256':hashlib.sha256(output).hexdigest()}
(item/'results.jsonl').write_text(json.dumps(row)+'\n')
p=Path(sys.argv[3]); d=json.loads(p.read_text());d['judgments'][0]['result_ids']=['r1'];p.write_text(json.dumps(d))
PY
  seal_manifest
  cp "$ITEM/reviews/review-1/sealed/cited-results.json" "$TEST_KDIR/frozen"
  printf 'changed output\n' > "$ITEM/results/r1/output.txt"
  printf 'malformed live ledger\n' > "$ITEM/results.jsonl"
  run seal_review; [ "$status" -eq 0 ]; [[ "$output" == *'"reused"'* ]]
  run file_review; [ "$status" -eq 0 ]
  cmp "$TEST_KDIR/frozen" "$ITEM/reviews/review-1/sealed/cited-results.json"
  jq -e '.results[0].artifacts[0].content=="failed assertion\n" and .result_ids==["r1"]' "$TEST_KDIR/frozen"
  printf 'changed frozen copy\n' >> "$ITEM/reviews/review-1/sealed/cited-results.json"
  run file_review; [ "$status" -eq 1 ]
}

@test "concurrent identical outcome filing appends a single authoritative record" {
  prepare_review >/dev/null; seal_manifest
  file_review > "$TEST_KDIR/first" & first=$!
  file_review > "$TEST_KDIR/second" & second=$!
  wait "$first"; wait "$second"
  [ "$(grep -c '^Spec-outcome-record:' "$ITEM/execution-log.md")" -eq 1 ]
}

@test "bound needs-decision replay recovers missing auxiliary sink without changing outcome" {
  prepare_review >/dev/null
  jq '.outcome="needs-decision" | .verdict="UNRESOLVED" | .reason="Coverage needs an authored decision."' "$TEST_KDIR/dispositions.json" > "$TEST_KDIR/needs.json"
  mv "$TEST_KDIR/needs.json" "$TEST_KDIR/dispositions.json"
  seal_manifest
  invoke_needs() {
    bash "$REPO_DIR/scripts/spec-outcome.sh" review-item --ceremony spec-post-plan --advisor reviewer --attempt-id review-1 --outcome needs-decision --verdict UNRESOLVED --reason 'Coverage needs an authored decision.' --evidence-manifest "$TEST_KDIR/manifest.json" --json
  }
  invoke_needs > "$TEST_KDIR/first"
  cp "$ITEM/execution-log.md" "$TEST_KDIR/original-log"
  rm "$TEST_KDIR/_scorecards/rows.jsonl"
  run invoke_needs; [ "$status" -eq 0 ]; [[ "$output" == *'"recovered"'* ]]
  cmp "$TEST_KDIR/original-log" "$ITEM/execution-log.md"
  jq -e 'select(.outcome=="needs-decision" and .outcome_id)' "$TEST_KDIR/_scorecards/rows.jsonl"
}

@test "integration code identity excludes only this attempt and detects older review edits" {
  CODE="$TEST_KDIR/source-root"
  git init -q "$CODE"
  printf 'source\n' > "$CODE/source"
  git -C "$CODE" add source
  git -C "$CODE" -c user.name=Fixture -c user.email=f@example.test commit -qm Fixture
  export LORE_KNOWLEDGE_DIR="$CODE/store"
  ITEM="$CODE/store/_work/review-item"
  packet_revision_fixture "$ITEM" review-item
  RID=$(jq -r '.revision_id' "$ITEM/tasks.json")
  mkdir -p "$ITEM/reviews/older"
  printf 'Earlier review evidence\n' > "$ITEM/reviews/older/output.md"
  bash "$REPO_DIR/scripts/plan-review.sh" prepare review-item --attempt-id review-1 --revision "$RID" --ceremony spec-post-plan --purpose integration --execution-worktree "$CODE" >/dev/null
  python3 - "$REPO_DIR" "$ITEM" "$CODE" <<'PY'
import json,runpy,sys
from pathlib import Path
api=runpy.run_path(sys.argv[1]+'/scripts/work-evidence.py'); item=Path(sys.argv[2]); base=item/'reviews/review-1'
prepared=json.loads((base/'prepared.json').read_text())
assert prepared['source_exclusions']==[str(base)]
assert api['code_identity'](sys.argv[3], excluded_paths=(base,))['digest']==prepared['source_identity']['digest']
(item/'reviews/older/output.md').write_text('Changed earlier review evidence\n')
assert api['code_identity'](sys.argv[3], excluded_paths=(base,))['digest']!=prepared['source_identity']['digest']
PY
}
