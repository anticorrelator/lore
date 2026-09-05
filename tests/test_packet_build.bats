#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
load helpers/packet_revision

setup() {
  TEST_KDIR=$(mktemp -d)
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR" LORE_DATA_DIR="$TEST_KDIR/data" LORE_FRAMEWORK=codex
  unset LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
  mkdir -p "$TEST_KDIR/_work/packet-fixture" "$TEST_KDIR/conventions"
  printf '%s\n' '{"title":"Packet fixture","status":"active"}' > "$TEST_KDIR/_work/packet-fixture/_meta.json"
  printf '%s\n' '# Widget boundary' 'The widget boundary preserves identity.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | status: current -->' > "$TEST_KDIR/conventions/widget.md"
  PACKET="$REPO_DIR/scripts/packet.sh"
}

teardown() { rm -rf "$TEST_KDIR"; }

build_role() {
  bash "$PACKET" build --work-item packet-fixture --role "$1" --caller coordinator --topic widget --scale-set subsystem,implementation "${@:2}"
}

@test "each recipient role gets the exact factual status contract and inspectable population" {
  for role in investigator designer worker reviewer coordinator; do
    run build_role "$role"
    [ "$status" -eq 0 ]
    STATUS_JSON="$output" python3 - "$role" <<'PY'
import json, os, sys
from pathlib import Path
s = json.loads(os.environ['STATUS_JSON'])
assert set(s) == {'packet_id','recipient_role','entries_per_scale','scales_requested','scales_returned','norm_population_count','consultation_requirements','trust_snapshot_hash','delivery_stage','location','flags'}
assert s['recipient_role'] == sys.argv[1]
assert s['entries_per_scale'] == {'subsystem':1,'implementation':0}, s
assert s['scales_requested'] == ['subsystem','implementation']
assert s['scales_returned'] == ['subsystem']
assert s['norm_population_count'] == 1
assert s['consultation_requirements'] == [] and s['flags'] == []
assert s['delivery_stage'] == 'assembled'
assert len(s['trust_snapshot_hash']) == 64
row = json.loads(Path(s['location']).read_text().splitlines()[-1])
assert row['packet_id'] == s['packet_id']
assert row['unbound_reason'] == 'task-not-requested'
assert row['norms'] == [{'label':'widget','path':'conventions/widget.md','source_id':'conventions-tree'}]
assert 'Widget boundary' in row['content']
PY
  done
}

@test "scale declaration is required and invalid flags or thresholds fail" {
  run bash "$PACKET" build --work-item packet-fixture --role worker --caller worker --topic widget
  [ "$status" -ne 0 ]
  [[ "$output" == *"--scale-set"* ]]
  for args in 'unknown reason' 'unverified-assumption '; do
    run build_role worker --flag "$args" reason
    [ "$status" -ne 0 ]
  done
  run build_role worker --thin-floor -1
  [ "$status" -ne 0 ]
  [ ! -f "$TEST_KDIR/_packets/packets.jsonl" ]
}

@test "caller flags and floor counts are recorded without an adequacy verdict" {
  run build_role investigator --thin-floor 1 --flag unverified-assumption 'Identity is assumed' --flag unfamiliar-boundary 'New interface' --flag conflicting-explanations 'Two accounts'
  [ "$status" -eq 0 ]
  STATUS_JSON="$output" python3 - <<'PY'
import json, os
from pathlib import Path
s=json.loads(os.environ['STATUS_JSON'])
r=json.loads(Path(s['location']).read_text().splitlines()[-1])
assert s['below_floor']==['implementation']
assert s['flags']==r['flags']==[{'flag':'unverified-assumption','reason':'Identity is assumed'},{'flag':'unfamiliar-boundary','reason':'New interface'},{'flag':'conflicting-explanations','reason':'Two accounts'}]
assert r['thin_floor']==1
assert 'adequate' not in s
PY
}

@test "revision without attempt is explicitly unbound then re-pull binds to the existing attempt" {
  packet_revision_fixture "$TEST_KDIR/_work/packet-fixture" packet-fixture
  run build_role coordinator --task task-1
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$TEST_KDIR/_packets/packets.jsonl" | jq -r .unbound_reason)" = dispatch-attempt-not-recorded ]
  run bash "$REPO_DIR/scripts/impl-open.sh" packet-fixture --all --json
  [ "$status" -eq 0 ]
  attempt=$(tail -1 "$TEST_KDIR/_packets/packets.jsonl" | jq -r .dispatch_attempt_id)
  run build_role reviewer --task task-1
  [ "$status" -eq 0 ]
  row=$(tail -1 "$TEST_KDIR/_packets/packets.jsonl")
  [ "$(jq -r .schema_version <<< "$row")" = 2 ]
  [ "$(jq -r .dispatch_attempt_id <<< "$row")" = "$attempt" ]
  [ "$(jq -r .unbound_reason <<< "$row")" = null ]
}

@test "short guidance includes exactly one optional pointer and no packet body" {
  result=$(build_role worker)
  id=$(jq -r .packet_id <<< "$result")
  run bash "$REPO_DIR/scripts/render-dispatch-guidance.sh" --short
  [ "$status" -eq 0 ]
  [[ "$output" != *'Knowledge packet:'* ]]
  run bash "$REPO_DIR/scripts/render-dispatch-guidance.sh" --short --packet "$id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | rg -c '^Knowledge packet:')" = 1 ]
  [[ "$output" == *"lore packet show $id"* ]]
  [[ "$output" != *'Widget boundary'* ]]
}

@test "worker request inserts one pointer after the floor including precomposed briefs" {
  result=$(build_role worker)
  id=$(jq -r .packet_id <<< "$result")
  for mode in plain composed; do
    brief='Read the widget boundary.'
    if [ "$mode" = composed ]; then
      brief="$(bash "$REPO_DIR/scripts/render-dispatch-guidance.sh" --packet "$id")
$brief"
    fi
    run bash "$REPO_DIR/scripts/session-request.sh" --type worker --slug unrelated--w1 --context "$brief" --packet "$id" --anywhere --kdir "$TEST_KDIR" --json
    [ "$status" -eq 0 ]
  done
  python3 - "$TEST_KDIR" "$id" <<'PY'
import json, pathlib, sys
rows=list(pathlib.Path(sys.argv[1], '_sessions/requests/pending').glob('*.json'))
assert len(rows)==2
for path in rows:
    row=json.loads(path.read_text())
    prompt=row['extra_context']['dispatch_guidance']
    assert prompt.count('Knowledge packet:')==1
    end=prompt.index('<!-- lore-dispatch-guidance:v1:end -->')
    assert prompt[end:].splitlines()[1].startswith('Knowledge packet:')
    assert f'lore packet show {sys.argv[2]}' in prompt
    assert 'Widget boundary' not in prompt
PY
}

@test "show returns the complete JSON row or rendered content with binding and norms" {
  result=$(build_role coordinator)
  id=$(jq -r .packet_id <<< "$result")
  run bash "$PACKET" show "$id" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .recipient_role <<< "$output")" = coordinator ]
  run bash "$PACKET" show "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Binding:'* && "$output" == *'## Norms'* && "$output" == *'Widget boundary'* ]]
}

load helpers/packet_legacy

@test "impl-open legacy fixture stdout is byte-identical to the pre-refactor output" {
  packet_legacy_fixture
  bash "$REPO_DIR/scripts/impl-open.sh" legacy-packet --all --json > "$TEST_KDIR/actual.json"
  cmp "$REPO_DIR/tests/fixtures/packet-legacy-open.json" "$TEST_KDIR/actual.json"
}

@test "next-batch assembles directive entries and preserves required consultations" {
  packet_legacy_fixture
  python3 - "$TEST_KDIR/_work/legacy-packet/tasks.json" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); d=json.loads(p.read_text())
d['phases'][0]['retrieval_directive']={'version':2,'topics':[{'role':'focal','topic':'widget','seeds':['widget'],'scale_set':['subsystem']}]}
d['phases'][0]['consultations_required']=['identity']
p.write_text(json.dumps(d))
PY
  run bash "$REPO_DIR/scripts/impl-next-batch.sh" legacy-packet --json
  [ "$status" -eq 0 ]
  python3 - "$TEST_KDIR/_packets/packets.jsonl" <<'PY'
import json, pathlib, sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text().splitlines()[-1])
assert r['delivered_entries'][0]['path']=='conventions/widget.md'
assert r['consultation_requirements']==['identity']
assert r['delivery_stage']=='assembled'
assert r['recipient_role']=='worker'
assert r['unbound_reason']=='revision-not-recorded'
PY
}

@test "packet content retains available entry bylines" {
  printf '%s\n' '# Widget boundary' 'Keep widget identity.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | producer_role: worker | status: current -->' > "$TEST_KDIR/conventions/widget.md"
  result=$(build_role worker)
  id=$(jq -r .packet_id <<< "$result")
  run bash "$PACKET" show "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == *'captured by a worker'* ]]
}

@test "packet assembly does not change prefetch or session-start output" {
  packet_legacy_fixture
  bash "$REPO_DIR/tests/fixtures/retrieval/build_store.sh" "$TEST_KDIR"
  bash "$REPO_DIR/scripts/prefetch-knowledge.sh" widget --scale-set subsystem --format prompt > "$TEST_KDIR/prefetch-before"
  (cd "$TEST_KDIR" && bash "$REPO_DIR/scripts/load-knowledge.sh") > "$TEST_KDIR/start-before"
  build_role coordinator >/dev/null
  bash "$REPO_DIR/scripts/prefetch-knowledge.sh" widget --scale-set subsystem --format prompt > "$TEST_KDIR/prefetch-after"
  (cd "$TEST_KDIR" && bash "$REPO_DIR/scripts/load-knowledge.sh") > "$TEST_KDIR/start-after"
  cmp "$TEST_KDIR/prefetch-before" "$TEST_KDIR/prefetch-after"
  cmp "$TEST_KDIR/start-before" "$TEST_KDIR/start-after"
  [ -s "$TEST_KDIR/prefetch-before" ]
  [ -s "$TEST_KDIR/start-before" ]
  rg -q "Widget" "$TEST_KDIR/start-before"
}

@test "CLI routes packet build and show to this checkout" {
  packet_legacy_fixture
  run "$TEST_KDIR/bin/lore" packet build --work-item packet-fixture --role designer --caller coordinator --seeds widget --scale-set subsystem
  [ "$status" -eq 0 ]
  id=$(jq -r .packet_id <<< "$output")
  run "$TEST_KDIR/bin/lore" packet show "$id" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .recipient_role <<< "$output")" = designer ]
}
