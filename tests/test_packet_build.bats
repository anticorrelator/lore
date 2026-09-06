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

@test "impl-open legacy fixture preserves its contract with optional compiled descriptors" {
  packet_legacy_fixture
  bash "$REPO_DIR/scripts/impl-open.sh" legacy-packet --all --json > "$TEST_KDIR/actual.json"
  diff -u <(jq . "$REPO_DIR/tests/fixtures/packet-legacy-open.json") <(jq . "$TEST_KDIR/actual.json")
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

synth_fixture() {
  # Two entries so a drop leaves something behind; one extra file to add.
  printf '%s\n' '# Gadget boundary' 'The gadget boundary is separate from the widget boundary.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | status: current -->' > "$TEST_KDIR/conventions/gadget.md"
  printf '%s\n' '# Sprocket note' 'Sprockets are added by hand when retrieval misses them.' '<!-- learned: 2026-09-01 | confidence: medium | scale: implementation | status: current -->' > "$TEST_KDIR/conventions/sprocket.md"
  run bash "$PACKET" build --work-item packet-fixture --role worker --caller implement-lead --topic "widget gadget" --scale-set subsystem,implementation
  [ "$status" -eq 0 ]
  PKT=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["packet_id"])')
}

@test "synthesize supersedes the candidate row: drops a block, adds an entry, records reasons, show returns the latest" {
  synth_fixture
  run bash "$PACKET" synthesize "$PKT" --by implement-lead \
    --drop conventions/gadget.md "the worker touches widgets only" \
    --add conventions/sprocket.md "retrieval missed the sprocket rule the task depends on"
  [ "$status" -eq 0 ]
  STATUS_JSON="$output" PKT="$PKT" python3 - <<'PY'
import json, os
from pathlib import Path
s = json.loads(os.environ['STATUS_JSON'])
assert s['delivery_stage'] == 'synthesized' and s['by'] == 'implement-lead', s
assert (s['kept'], s['dropped'], s['added']) == (1, 1, 1), s
rows = [json.loads(l) for l in Path(s['location']).read_text().splitlines() if l.strip()]
mine = [r for r in rows if r['packet_id'] == os.environ['PKT']]
assert [r['delivery_stage'] for r in mine] == ['assembled', 'synthesized'], [r['delivery_stage'] for r in mine]
cand, syn = mine
assert 'Gadget boundary' in cand['content'] and 'Gadget boundary' not in syn['content'].split('## Left out by synthesis')[0]
assert 'Widget boundary' in syn['content']
assert '## Left out by synthesis' in syn['content'] and 'the worker touches widgets only' in syn['content']
assert '### Added by synthesis' in syn['content'] and 'Sprocket note' in syn['content']
paths = [e['path'] for e in syn['delivered_entries']]
assert paths == ['conventions/widget.md', 'conventions/sprocket.md'], paths
assert syn['synthesis']['kept'] == ['conventions/widget.md']
assert syn['synthesis']['dropped'] == [{'path': 'conventions/gadget.md', 'reason': 'the worker touches widgets only'}]
assert syn['synthesis']['added'][0]['path'] == 'conventions/sprocket.md'
assert syn['synthesized_from_delivered_at'] == cand['delivered_at'] and syn['delivered_at'] >= cand['delivered_at']
assert syn['trust_snapshot_hash'] != cand['trust_snapshot_hash']
assert syn['entries_per_scale'] == {'subsystem': 1, 'implementation': 1}, syn['entries_per_scale']
PY
  run bash "$PACKET" show "$PKT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(synthesized)"* ]]
  [[ "$output" == *"Synthesis: by implement-lead — kept 1, dropped 1, added 1"* ]]
  [[ "$output" == *"## Left out by synthesis"* ]]
  run bash "$PACKET" show "$PKT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"delivery_stage": "synthesized"'* ]] || [[ "$output" == *'"delivery_stage":"synthesized"'* ]]
}

@test "synthesize refuses unknown drops, unstored adds, empty reasons, a missing --by, and a second synthesis" {
  synth_fixture
  run bash "$PACKET" synthesize "$PKT" --by lead --drop conventions/nowhere.md "not delivered"
  [ "$status" -ne 0 ]; [[ "$output" == *"not in the candidate set"* ]]
  run bash "$PACKET" synthesize "$PKT" --by lead --add conventions/missing.md "does not exist"
  [ "$status" -ne 0 ]; [[ "$output" == *"not a knowledge entry"* ]]
  run bash "$PACKET" synthesize "$PKT" --by lead --drop conventions/gadget.md ""
  [ "$status" -ne 0 ]; [[ "$output" == *"reason"* ]]
  run bash "$PACKET" synthesize "$PKT" --drop conventions/gadget.md "x"
  [ "$status" -ne 0 ]
  [ "$(grep -c "\"$PKT\"" "$TEST_KDIR/_packets/packets.jsonl")" -eq 1 ]
  run bash "$PACKET" synthesize "$PKT" --by lead
  [ "$status" -eq 0 ]
  run bash "$PACKET" synthesize "$PKT" --by lead
  [ "$status" -ne 0 ]; [[ "$output" == *"not assembled"* ]]
  run bash "$PACKET" show "$PKT"
  [[ "$output" == *"kept 2, dropped 0, added 0"* ]]
}

@test "an assembled packet renders as a candidate set and a waiver renders as recorded" {
  synth_fixture
  run bash "$PACKET" show "$PKT"
  [[ "$output" == *"Synthesis: none — this is a candidate set"* ]]
  # A waiver is recorded by the builder at assembly (spec-open's full wave does this); the writer accepts it only unsynthesized.
  WAIVED=$(python3 - "$TEST_KDIR" "$REPO_DIR" <<'PY'
import json, sys
from pathlib import Path
kdir, repo = sys.argv[1:]
sys.path.insert(0, repo + '/scripts')
from packet_builder import build_packet
row = {'packet_id': 'pkt-waived', 'packet_scope': 'session', 'session_id': None, 'work_item': 'packet-fixture', 'task_id': None, 'phase': None,
       'arm': None, 'task_scale_set': 'subsystem', 'synthesis_waiver': {'by': 'spec-lead', 'reason': 'assembled and dispatched in one verb'}}
build_packet(Path(kdir), row, assembly=('Wave content', {}), role='investigator', caller='spec-lead', scales=['subsystem'])
print('pkt-waived')
PY
)
  run bash "$PACKET" show "$WAIVED"
  [[ "$output" == *"Synthesis waived:"* ]]
  run bash "$PACKET" synthesize "$WAIVED" --by lead
  [ "$status" -eq 0 ]
  run bash "$PACKET" show "$WAIVED" --json
  [[ "$output" != *"synthesis_waiver"* ]]
}

@test "synthesize accepts a JSON spec file so a lead can record many dispositions at once" {
  synth_fixture
  printf '%s\n' '{"dropped":[{"path":"conventions/gadget.md","reason":"outside the worker files"}],"added":[]}' > "$TEST_KDIR/synthesis.json"
  run bash "$PACKET" synthesize "$PKT" --by implement-lead --spec "$TEST_KDIR/synthesis.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"dropped": 1'* ]]
  printf '%s\n' '{"dropped":[{"path":"conventions/gadget.md"}]}' > "$TEST_KDIR/bad.json"
  run bash "$PACKET" synthesize "$PKT" --by implement-lead --spec "$TEST_KDIR/bad.json"
  [ "$status" -ne 0 ]
}

@test "synthesize removes exactly the recorded block: internal headings survive nothing, neighbours survive whole, unrecorded blocks refuse" {
  printf '%s\n' '# Gadget boundary' 'The gadget boundary is separate.' '## Internal rule' 'GADGET INTERNAL TEXT MUST GO' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | status: current -->' > "$TEST_KDIR/conventions/gadget.md"
  run bash "$PACKET" build --work-item packet-fixture --role worker --caller implement-lead --topic "widget gadget" --scale-set subsystem,implementation
  [ "$status" -eq 0 ]
  PKT=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["packet_id"])')
  run bash "$PACKET" synthesize "$PKT" --by implement-lead --drop conventions/gadget.md "not this worker's file"
  [ "$status" -eq 0 ]
  PKT="$PKT" python3 - <<'PY'
import json, os
from pathlib import Path
rows = [json.loads(l) for l in Path(os.environ['LORE_KNOWLEDGE_DIR'], '_packets/packets.jsonl').read_text().splitlines() if l.strip()]
cand, syn = [r for r in rows if r['packet_id'] == os.environ['PKT']]
assert all(e.get('rendered') for e in cand['delivered_entries']), "assembly must record every rendered block"
body = syn['content'].split('## Left out by synthesis')[0]
assert 'GADGET INTERNAL TEXT MUST GO' not in body and 'Internal rule' not in body, body
assert 'Widget boundary' in body and 'The widget boundary preserves identity.' in body
assert syn['content'].count('Widget boundary') == cand['content'].count('Widget boundary')
PY
  # A candidate whose assembly recorded no blocks cannot be dropped from honestly.
  REFUSED=$(python3 - "$TEST_KDIR" "$REPO_DIR" <<'PY'
import json, sys
from pathlib import Path
kdir, repo = sys.argv[1:]
sys.path.insert(0, repo + '/scripts')
from packet_builder import build_packet, synthesize
row = {'packet_id': 'pkt-noblocks', 'packet_scope': 'session', 'session_id': None, 'work_item': 'packet-fixture', 'task_id': None, 'phase': None, 'arm': None, 'task_scale_set': 'subsystem'}
entries = [{'path': 'conventions/widget.md', 'scale': 'subsystem', 'render_mode': 'full', 'ranking_path': 'search-order',
            'trust': {'score': None, 'status': 'unknown', 'confidence': 'unknown', 'correction_recency': None}}]
build_packet(Path(kdir), row, assembly=('Legacy content without recorded blocks', {'entries': entries}), role='worker', caller='lead', scales=['subsystem'])
try:
    synthesize(Path(kdir), 'pkt-noblocks', by='lead', dropped=[('conventions/widget.md', 'try')])
except ValueError as exc:
    print('refused:', exc)
else:
    print('accepted')
PY
)
  [[ "$REFUSED" == refused:*"did not record a locatable rendered block"* ]]
  run bash "$PACKET" synthesize pkt-noblocks --by lead
  [ "$status" -eq 0 ]
}

@test "added entries carry every declared scale and their own status and confidence" {
  synth_fixture
  printf '%s\n' '# Dual scale note' 'Applies at two altitudes.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem,implementation | status: current -->' > "$TEST_KDIR/conventions/dual.md"
  run bash "$PACKET" synthesize "$PKT" --by lead --add conventions/dual.md "both altitudes matter here"
  [ "$status" -eq 0 ]
  run bash "$PACKET" show "$PKT" --json
  printf '%s' "$output" | python3 -c '
import json, sys
row = json.loads(sys.stdin.read())
added = [e for e in row["delivered_entries"] if e["path"] == "conventions/dual.md"][0]
assert added["scale"] == "subsystem,implementation", added
assert added["trust"]["status"] == "current" and added["trust"]["confidence"] == "high", added["trust"]
assert row["entries_per_scale"] == {"subsystem": 3, "implementation": 1}, row["entries_per_scale"]
'
  synth_fixture
  run bash "$PACKET" synthesize "$PKT" --by lead --add _packets/README.md "not an entry"
  [ "$status" -ne 0 ]; [[ "$output" == *"not a knowledge entry"* ]]
}

@test "the sole writer refuses a malformed synthesis row and a chain that changes identity" {
  synth_fixture
  ROW=$(bash "$PACKET" show "$PKT" --json)
  # synthesized stage without a synthesis object
  printf '%s' "$ROW" | python3 -c 'import json,sys; r=json.load(sys.stdin); r["delivery_stage"]="synthesized"; r.pop("delivered_at",None); print(json.dumps(r))' > "$TEST_KDIR/bad1.json"
  run bash "$REPO_DIR/scripts/packet-append.sh" --row "$(cat "$TEST_KDIR/bad1.json")" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]; [[ "$output" == *"synthesis must be an object"* ]]
  # a superseding row that changes identity: synthesize legitimately, then replay that row with another recipient
  run bash "$PACKET" synthesize "$PKT" --by lead
  [ "$status" -eq 0 ]
  bash "$PACKET" show "$PKT" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); r["recipient_role"]="designer"; r.pop("delivered_at",None); print(json.dumps(r))' > "$TEST_KDIR/bad2.json"
  run bash "$REPO_DIR/scripts/packet-append.sh" --row "$(cat "$TEST_KDIR/bad2.json")" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]; [[ "$output" == *"recipient_role differs from the prior row"* ]]
  [ "$(grep -c "\"$PKT\"" "$TEST_KDIR/_packets/packets.jsonl")" -eq 2 ]
}

@test "a literal copy of another entry's block inside a kept entry is not what gets removed" {
  # gizmo documents packet formatting and embeds the exact rendered block of gadget; dropping gadget must remove gadget, not the example.
  printf '%s\n' '# Gadget boundary' 'The gadget boundary is separate.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | status: current -->' > "$TEST_KDIR/conventions/gadget.md"
  run bash "$PACKET" build --work-item packet-fixture --role worker --caller implement-lead --topic "widget gadget" --scale-set subsystem
  [ "$status" -eq 0 ]
  FIRST=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["packet_id"])')
  GADGET_BLOCK=$(bash "$PACKET" show "$FIRST" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); print([e["rendered"] for e in r["delivered_entries"] if e["path"]=="conventions/gadget.md"][0], end="")')
  { printf '%s\n' '# Aaa gizmo formatting example' 'A literal example of a rendered block follows:'; printf '%s\n' "$GADGET_BLOCK"; printf '%s\n' 'Keep this example unchanged.' '<!-- learned: 2026-09-01 | confidence: high | scale: subsystem | status: current -->'; } > "$TEST_KDIR/conventions/aaa-gizmo.md"
  run bash "$PACKET" build --work-item packet-fixture --role worker --caller implement-lead --topic "gizmo gadget widget formatting" --scale-set subsystem
  [ "$status" -eq 0 ]
  PKT=$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["packet_id"])')
  PKT="$PKT" python3 - <<'PY'
import json, os
from pathlib import Path
rows = [json.loads(l) for l in Path(os.environ['LORE_KNOWLEDGE_DIR'], '_packets/packets.jsonl').read_text().splitlines() if l.strip()]
cand = [r for r in rows if r['packet_id'] == os.environ['PKT']][-1]
paths = [e['path'] for e in cand['delivered_entries']]
assert 'conventions/aaa-gizmo.md' in paths and 'conventions/gadget.md' in paths, paths
gizmo = [e['rendered'] for e in cand['delivered_entries'] if e['path'] == 'conventions/aaa-gizmo.md'][0]
gadget = [e['rendered'] for e in cand['delivered_entries'] if e['path'] == 'conventions/gadget.md'][0]
assert gadget in gizmo, "fixture premise: the kept entry embeds the dropped entry's exact block"
assert cand['content'].count(gadget) >= 2
PY
  run bash "$PACKET" synthesize "$PKT" --by implement-lead --drop conventions/gadget.md "outside this worker's files"
  [ "$status" -eq 0 ]
  PKT="$PKT" python3 - <<'PY'
import json, os
from pathlib import Path
rows = [json.loads(l) for l in Path(os.environ['LORE_KNOWLEDGE_DIR'], '_packets/packets.jsonl').read_text().splitlines() if l.strip()]
cand, syn = [r for r in rows if r['packet_id'] == os.environ['PKT']]
gizmo = [e['rendered'] for e in cand['delivered_entries'] if e['path'] == 'conventions/aaa-gizmo.md'][0]
gadget = [e['rendered'] for e in cand['delivered_entries'] if e['path'] == 'conventions/gadget.md'][0]
body = syn['content'].split('## Left out by synthesis')[0]
assert gizmo in body, "the kept entry, embedded example included, must survive byte for byte"
assert body.count(gadget) == cand['content'].count(gadget) - 1, "exactly the dropped entry's own occurrence is removed"
PY
}

@test "paths are validated as the caller spelled them and an assembled row cannot change an id's identity" {
  synth_fixture
  run bash "$PACKET" synthesize "$PKT" --by lead --drop ../conventions/gadget.md "escape"
  [ "$status" -ne 0 ]; [[ "$output" == *"not a store-relative path"* ]]
  run bash "$PACKET" synthesize "$PKT" --by lead --add /conventions/sprocket.md "absolute"
  [ "$status" -ne 0 ]; [[ "$output" == *"not a store-relative path"* ]]
  run bash "$PACKET" synthesize "$PKT" --by lead --add ./conventions/sprocket.md "dot-slash alias is fine"
  [ "$status" -eq 0 ]
  # an assembled row replayed under the same id with another work item is refused by the writer
  bash "$PACKET" show "$PKT" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); r["delivery_stage"]="assembled"; r.pop("synthesis",None); r["work_item"]="other-item"; r.pop("delivered_at",None); print(json.dumps(r))' > "$TEST_KDIR/bad3.json"
  run bash "$REPO_DIR/scripts/packet-append.sh" --row "$(cat "$TEST_KDIR/bad3.json")" --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]; [[ "$output" == *"work_item differs from the prior row"* ]]
}
