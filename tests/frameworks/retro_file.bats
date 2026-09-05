#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PREPARE="$REPO_DIR/scripts/retro-prepare.sh"
FILE_VERB="$REPO_DIR/scripts/retro-file.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/_work/cycle-a" "$TEST_KDIR/_scorecards" "$TEST_KDIR/_meta" "$TEST_KDIR/_sessions"
  printf '{"schema_version":"1"}\n' > "$TEST_KDIR/_manifest.json"
  printf '{"title":"Cycle A","status":"active"}\n' > "$TEST_KDIR/_work/cycle-a/_meta.json"
  printf '# Plan\n- [x] one\n' > "$TEST_KDIR/_work/cycle-a/plan.md"
  printf '# Notes\n' > "$TEST_KDIR/_work/cycle-a/notes.md"
  : > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '{"schema_version":1}\n' > "$TEST_KDIR/_scorecards/_current.json"
  : > "$TEST_KDIR/_sessions/events.jsonl"
  : > "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  bash "$PREPARE" cycle-a --window-start 2026-07-01T00:00:00Z --window-end 2026-07-02T00:00:00Z --json >/dev/null
  PACK="$TEST_KDIR/_work/cycle-a/retro-evidence-pack.json"
  # Retained v1 fixtures stay independent of the current prepare contract.
  python3 - "$PACK" <<'PYFIXTURE'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pack=json.loads(p.read_text());pack.pop('rubric',None)
pack['artifact_sha256']=hashlib.sha256(json.dumps({k:v for k,v in pack.items() if k!='artifact_sha256'},ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
p.write_text(json.dumps(pack))
PYFIXTURE
  JUDGMENTS="$TEST_KDIR/judgments.json"
  write_no_suggestion_manifest
}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR LORE_RETRO_FILE_FAIL_SINK
}

json_line() { echo "$output" | grep '^{' | tail -1; }

write_no_suggestion_manifest() {
  jq -n --arg pack_id "$(jq -r .pack_id "$PACK")" --arg pack_sha "$(jq -r .artifact_sha256 "$PACK")" '{
    schema_version:1, cycle_id:"cycle-a", pack_id:$pack_id, pack_sha256:$pack_sha,
    actor:"retro-lead", model:"fable-test", key_finding:"The evidence pack exposes the source gap.",
    most_actionable_gap:"Keep the reader-source issue live.",
    dimension_judgments:[
      {dimension_id:"D1",score:5,rationale:"Delivery complete.",evidence_refs:["source:cycle_work"]},
      {dimension_id:"D2",score:4,rationale:"Evidence quality explicit.",evidence_refs:["pack:/source_manifest"]},
      {dimension_id:"D3",score:4,rationale:"Gaps are named.",evidence_refs:["calculation:channel_contract_drift"]},
      {dimension_id:"D4",score:5,rationale:"Anchor alignment holds.",evidence_refs:["pack:/cycle/slug"]},
      {dimension_id:"D5",score:4,rationale:"Spec was useful.",evidence_refs:["source:journal"]}
    ],
    behavioral_health:[{check_id:"C7",answer:"The agents reasoned from missing evidence instead of complying with a green default.",evidence_refs:["pack:/fixed_health/state"]}],
    causal_diagnoses:[{diagnosis_id:"source-gap",interpretation:"The cycle work reader does not expose role-slot denominators for a trustworthy drift rate.",evidence_refs:["source:cycle_work"]}],
    escalation_judgment:{applicability:"not-applicable",reason:"No worker escalation fired."},
    scale_access_judgment:{applicability:"not-applicable",reason:"No scale comparison applies to this fixture."},
    channel_flags:{applicability:"applicable",value:[]},
    suggestion_outcome:"no-substantive-suggestion", suggestions:[]
  }' > "$JUDGMENTS"
}

@test "no-substantive-suggestion completes with zero proposal rows and terminal sole-writer telemetry" {
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="created" and .judgment_accepted and .filing_complete and (.missing_sinks|length)==0'
  [ "$(jq -s '[.[] | select(.role=="retro-evolution")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 0 ]
  [ "$(jq -s '[.[] | select(.role=="retro")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.role=="retro-behavioral-health")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
  run jq -e 'select(.kind=="telemetry" and .tier=="telemetry" and .event_type=="retro-filing" and .suggestion_outcome=="no-substantive-suggestion" and .filing_complete==true)' "$TEST_KDIR/_scorecards/rows.jsonl"
  [ "$status" -eq 0 ]
}

@test "exact replay reuses every exact sink key without duplicates" {
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  before_journal="$(wc -l < "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | tr -d ' ')"
  before_rows="$(wc -l < "$TEST_KDIR/_scorecards/rows.jsonl" | tr -d ' ')"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="reused" and .filing_complete'
  [ "$(wc -l < "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | tr -d ' ')" -eq "$before_journal" ]
  [ "$(wc -l < "$TEST_KDIR/_scorecards/rows.jsonl" | tr -d ' ')" -eq "$before_rows" ]
}

@test "recoverable partial accepts the judgment and resumes only missing sinks" {
  export LORE_RETRO_FILE_FAIL_SINK=journal:behavioral
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
  json_line | jq -e '.status=="partial" and .judgment_accepted and (.filing_complete|not) and (.missing_sinks|index("journal:behavioral"))'
  [ -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
  [ "$(jq -r 'select(.event_type=="retro-filing")' "$TEST_KDIR/_scorecards/rows.jsonl" | wc -l | tr -d ' ')" -eq 0 ]
  unset LORE_RETRO_FILE_FAIL_SINK
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="recovered" and .filing_complete'
  [ "$(jq -s '[.[] | select(.role=="retro")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.role=="retro-behavioral-health")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
}

@test "substantive filing fans out escalation scale channel and one proposal by exact keys" {
  jq '.suggestion_outcome="substantive" |
      .suggestions=[{target:"skills/retro/SKILL.md",change_type:"evidence-gap",section:"Step 3.8",suggestion:"Add a sanctioned reader.",evidence:"Channel contract drift is not computable without role-slot denominators.",evidence_refs:["calculation:channel_contract_drift"]}] |
      .escalation_judgment={applicability:"applicable",value:{observation:"One task needed re-scoping.",evidence_refs:["pack:/facts/task_context_backlinks"]}} |
      .scale_access_judgment={applicability:"applicable",value:{abstraction_grade:"right-sized",abstraction_rationale:"The subsystem pack was sufficient.",counterfactual_better:"worse",counterfactual_rationale:"Full-store retrieval would add noise.",evidence_refs:["source:cycle_work"]}} |
      .channel_flags={applicability:"applicable",value:[{role:"worker",slot:"Surfaced-concerns",signal_type:"under_routing",rate:0.5,window_cycles:3,remedy_hint:"Clarify the slot.",evidence_refs:["pack:/facts/task_context_backlinks"]}]}' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.role=="retro-evolution")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
  [ "$(jq -s '[.[] | select(.role=="retro-escalations")] | length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
  [ "$(wc -l < "$TEST_KDIR/_scorecards/retro-scale-access.jsonl" | tr -d ' ')" -eq 1 ]
  [ "$(wc -l < "$TEST_KDIR/_scorecards/retro-channel-flags.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "terminal telemetry is withheld when an auxiliary sink fails" {
  jq '.scale_access_judgment={applicability:"applicable",value:{abstraction_grade:"right-sized",abstraction_rationale:"Right-sized.",counterfactual_better:"same",counterfactual_rationale:"No meaningful difference.",evidence_refs:["source:cycle_work"]}}' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  export LORE_RETRO_FILE_FAIL_SINK=scale-access
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
  [ "$(jq -r 'select(.event_type=="retro-filing")' "$TEST_KDIR/_scorecards/rows.jsonl" | wc -l | tr -d ' ')" -eq 0 ]
}

@test "semantic reassignment for the same cycle is refused" {
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  jq '.key_finding="A different lead commitment."' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
  json_line | jq -e '.status=="refused" and .error.code=="filing-collision"'
}

@test "invalid evidence references and missing Check 7 refuse before acceptance" {
  jq '.dimension_judgments[0].evidence_refs=["source:not-real"]' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
  write_no_suggestion_manifest
  jq '.behavioral_health[0].check_id="C1"' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
}

@test "pack self-hash mismatch refuses before any mutation" {
  jq '.artifact_sha256="bad"' "$PACK" > "$PACK.tmp"
  mv "$PACK.tmp" "$PACK"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
  [ "$(wc -l < "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | tr -d ' ')" -eq 0 ]
}

@test "legacy reader-version-one pack remains fileable and accepted replay preserves its bytes" {
  python3 - "$PACK" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);pack=json.loads(p.read_text())
pack.pop('source_data',None)
for row in pack['source_manifest']:
 if row['source_id']=='cycle_work': row['reader_contract_version']='1'
body={k:v for k,v in pack.items() if k!='artifact_sha256'}
canonical=lambda x:json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
pack['artifact_sha256']=hashlib.sha256(canonical(body)).hexdigest()
p.write_bytes(canonical(pack))
PY
  write_no_suggestion_manifest
  cp "$PACK" "$TEST_KDIR/legacy-pack.json"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  cp "$TEST_KDIR/_work/cycle-a/retro-filing.json" "$TEST_KDIR/accepted-filing.json"
  run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json
  [ "$status" -eq 0 ]
  json_line | jq -e '.status == "reused" and .filing_complete'
  cmp "$PACK" "$TEST_KDIR/legacy-pack.json"
  cmp "$TEST_KDIR/_work/cycle-a/retro-filing.json" "$TEST_KDIR/accepted-filing.json"
}

# Freeze the same descriptor the prepare integration publishes. Existing cases
# above deliberately exercise retained v1 packs and their original sink set.
upgrade_to_v2() {
  python3 "$REPO_DIR/scripts/retro-rubric.py" descriptor "${1:-$REPO_DIR/skills/retro/rubric.json}" > "$TEST_KDIR/rubric.json"
  python3 - "$PACK" "$JUDGMENTS" "$TEST_KDIR/rubric.json" <<'PY'
import hashlib,json,pathlib,sys
p,j,r=map(pathlib.Path,sys.argv[1:]);pack=json.loads(p.read_text());rubric=json.loads(r.read_text())
canonical=lambda x:json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
pack['rubric']=rubric
pack['artifact_sha256']=hashlib.sha256(canonical({k:v for k,v in pack.items() if k!='artifact_sha256'})).hexdigest()
p.write_bytes(canonical(pack))
judgment=json.loads(j.read_text());judgment.update(schema_version=2,pack_sha256=pack['artifact_sha256'],rubric_id=rubric['rubric_id'],rubric_version=rubric['rubric_version'])
for d in judgment['dimension_judgments']: d['disposition']='scored'
judgment['dimension_judgments'].append(dict(dimension_id='D6',disposition='scored',score=4,rationale='The recipient used relevant prior knowledge and avoided rediscovery.',evidence_refs=['source:cycle_work']))
j.write_bytes(canonical(judgment))
PY
}

file_cycle() { run bash "$FILE_VERB" cycle-a --pack "$PACK" --judgments "$JUDGMENTS" --json; }

@test "rubric pins unique ordered IDs keys anchors and exact byte hash independently of prose" {
  python3 - "$REPO_DIR" "$TEST_KDIR" <<'PY'
import importlib.util,pathlib,sys,subprocess,json
root,tmp=map(pathlib.Path,sys.argv[1:]);spec=importlib.util.spec_from_file_location('rubric',root/'scripts/retro-rubric.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
r=m.load_rubric();assert r['rubric_version']==subprocess.check_output(['bash',str(root/'scripts/template-version.sh'),str(root/'skills/retro/rubric.json')],text=True).strip()
# Copy the source layout to establish that a prose-only edit cannot fork identity.
(tmp/'skills/retro').mkdir(parents=True);(tmp/'scripts').mkdir()
(tmp/'scripts/retro-rubric.py').write_bytes((root/'scripts/retro-rubric.py').read_bytes())
(tmp/'skills/retro/rubric.json').write_text(r['rubric_text'])
(tmp/'skills/retro/SKILL.md').write_text('Changed guidance only')
assert json.loads(subprocess.check_output([sys.executable,str(tmp/'scripts/retro-rubric.py'),'descriptor']))==r
assert m.describe_bytes((r['rubric_text']+'\n').encode())['rubric_version']!=r['rubric_version']
for field,value in [('dimension_id','D1'),('journal_key','d1_delivery'),('anchors',{'1':'only'}),('allow_not_assessable',True)]:
 bad=json.loads(r['rubric_text']);bad['dimensions'][1][field]=value
 try: m.validate_declaration(bad)
 except ValueError: pass
 else: raise AssertionError(field)
PY
}

@test "v2 scored dimensions pass actual appender admission and stay below calibrated evidence floors" {
  upgrade_to_v2
  file_cycle
  [ "$status" -eq 0 ]
  jq -se 'map(select(.kind=="scored")) | length==6 and all(.schema_version==1 and .tier=="template" and .calibration_state=="pre-calibration" and .sample_size==1 and .verdict_source=="retro-lead" and (.template_version|test("^[0-9a-f]{12}$")) and (.source_artifact_ids|length)==2)' "$TEST_KDIR/_scorecards/rows.jsonl"
  # Readiness uses the real reader/calculation, with all six observations in-window.
  mkdir "$TEST_KDIR/_work/cycle-b"
  cp "$TEST_KDIR/_work/cycle-a/_meta.json" "$TEST_KDIR/_work/cycle-b/_meta.json"
  bash "$PREPARE" cycle-b --window-start 2026-01-01T00:00:00Z --window-end 2099-01-01T00:00:00Z --json >/dev/null
  jq -e '.facts.scorecard_eligibility_deltas.values | .calibrated_template_rows==0 and .rows_total==6' "$TEST_KDIR/_work/cycle-b/retro-evidence-pack.json"
}

@test "D6 abstention retains reason and resolving evidence without numeric sinks" {
  upgrade_to_v2
  jq '.dimension_judgments[5] += {disposition:"not-assessable",score:null,reason:"No eligible recipient-use evidence."}' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  file_cycle
  [ "$status" -eq 0 ]
  jq -e '.judgments.dimension_judgments[5] | .score==null and .disposition=="not-assessable" and (.reason|length)>0 and (.evidence_refs|length)>0' "$TEST_KDIR/_work/cycle-a/retro-filing.json"
  jq -se 'map(select(.kind=="scored")) | length==5 and all(.metric!="d6_packet_utility")' "$TEST_KDIR/_scorecards/rows.jsonl"
  jq -se 'map(select(.role=="retro"))[0].scores | has("d6_packet_utility")|not' "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  file_cycle
  [ "$status" -eq 0 ]
  json_line | jq -e '.status=="reused"'
}

@test "v2 rejects malformed dispositions scores abstentions and unresolved evidence before writes" {
  upgrade_to_v2
  cp "$JUDGMENTS" "$TEST_KDIR/valid.json"
  for change in '.dimension_judgments[0].score=true' '.dimension_judgments[5].score=0' '.dimension_judgments[5].disposition="unknown"' '.dimension_judgments[5]+={disposition:"not-assessable",score:null,reason:""}' '.dimension_judgments[0]+={disposition:"not-assessable",score:null,reason:"Absent"}' '.dimension_judgments[5].evidence_refs=["source:missing"]'; do
    jq "$change" "$TEST_KDIR/valid.json" > "$JUDGMENTS"
    file_cycle
    [ "$status" -eq 1 ]
    [ ! -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
    [ ! -s "$TEST_KDIR/_scorecards/rows.jsonl" ]
    [ ! -s "$TEST_KDIR/_meta/effectiveness-journal.jsonl" ]
  done
}

@test "frozen rubric mismatch rejects before writes even when pack self hash is valid" {
  upgrade_to_v2
  jq '.rubric_version="0123456789ab"' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  file_cycle
  [ "$status" -eq 1 ]
  python3 - "$PACK" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);r=json.loads(p.read_text());r['rubric']['rubric_version']='0123456789ab'
r['artifact_sha256']=hashlib.sha256(json.dumps({k:v for k,v in r.items() if k!='artifact_sha256'},ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest();p.write_text(json.dumps(r))
PY
  jq --arg sha "$(jq -r .artifact_sha256 "$PACK")" '.pack_sha256=$sha' "$JUDGMENTS" > "$JUDGMENTS.tmp"
  mv "$JUDGMENTS.tmp" "$JUDGMENTS"
  file_cycle
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
  [ ! -s "$TEST_KDIR/_meta/effectiveness-journal.jsonl" ]
  [ ! -s "$TEST_KDIR/_scorecards/rows.jsonl" ]
}

@test "legacy replay retains exact v1 filing identity and never creates dimension sinks" {
  file_cycle
  [ "$status" -eq 0 ]
  python3 - "$PACK" "$JUDGMENTS" "$TEST_KDIR/_work/cycle-a/retro-filing.json" <<'PY'
import hashlib,json,sys
pack,judgment,filing=[json.load(open(p)) for p in sys.argv[1:]]
identity={'schema_version':1,'cycle_id':'cycle-a','pack_id':pack['pack_id'],'pack_sha256':pack['artifact_sha256'],'judgments':judgment}
assert filing['filing_id']==hashlib.sha256(json.dumps(identity,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()
PY
  cp "$TEST_KDIR/_scorecards/rows.jsonl" "$TEST_KDIR/before-rows"
  cp "$TEST_KDIR/_meta/effectiveness-journal.jsonl" "$TEST_KDIR/before-journal"
  file_cycle
  [ "$status" -eq 0 ]
  cmp "$TEST_KDIR/before-rows" "$TEST_KDIR/_scorecards/rows.jsonl"
  cmp "$TEST_KDIR/before-journal" "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  jq -se 'all(.kind=="telemetry")' "$TEST_KDIR/_scorecards/rows.jsonl"
}

@test "journal readers compare historical D5 and new D6 with explicit identity and preserve historical bytes" {
  printf '{ "timestamp":"2026-07-01T00:00:00Z", "role":"retro", "context":"original", "scores":{"d5_spec_utility":3} }\n' > "$TEST_KDIR/history"
  cp "$TEST_KDIR/history" "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  printf '{ "schema_version":1,"kind":"telemetry","model":"historic" }\n' > "$TEST_KDIR/row-history"
  cp "$TEST_KDIR/row-history" "$TEST_KDIR/_scorecards/rows.jsonl"
  upgrade_to_v2
  file_cycle
  [ "$status" -eq 0 ]
  head -c "$(wc -c < "$TEST_KDIR/history")" "$TEST_KDIR/_meta/effectiveness-journal.jsonl" > "$TEST_KDIR/prefix"
  cmp "$TEST_KDIR/history" "$TEST_KDIR/prefix"
  head -c "$(wc -c < "$TEST_KDIR/row-history")" "$TEST_KDIR/_scorecards/rows.jsonl" > "$TEST_KDIR/prefix"
  cmp "$TEST_KDIR/row-history" "$TEST_KDIR/prefix"
  run bash "$REPO_DIR/scripts/journal.sh" query --role retro --extract-scores --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map({date:.timestamp,rubric_id,rubric_version,d5:.scores.d5_spec_utility,d6:.scores.d6_packet_utility}) | .[0]=={date:"2026-07-01",rubric_id:"legacy-unversioned",rubric_version:null,d5:3,d6:null} and .[1].rubric_id=="retro-rubric" and .[1].d5==4 and .[1].d6==4'
  run bash "$REPO_DIR/scripts/journal.sh" query --role retro --extract-scores
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rubric identity"* && "$output" == *"legacy-unversioned@unknown"* && "$output" == *"d6_packet_utility"* ]]
  run python3 "$REPO_DIR/scripts/retro-export-collect-retros.py" "$TEST_KDIR/_meta/effectiveness-journal.jsonl" 2026-01-01T00:00:00Z
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(select(.scores!=null)) | length==2 and .[0].rubric_id=="legacy-unversioned" and .[0].rubric_version==null and .[1].rubric_id=="retro-rubric" and (.[1].rubric_version|test("^[0-9a-f]{12}$")) and .[1].scores.d6_packet_utility==4'
}

@test "journal paired optional rubric flags validate together and leave scores numeric" {
  for args in '--rubric-id retro-rubric' '--rubric-version 0123456789ab' '--rubric-id retro-rubric --rubric-version bad'; do
    # Intentional word splitting for the fixed argument fixtures.
    run bash "$REPO_DIR/scripts/journal.sh" write --observation Test --context Test $args
    [ "$status" -eq 1 ]
    [ ! -s "$TEST_KDIR/_meta/effectiveness-journal.jsonl" ]
  done
  run bash "$REPO_DIR/scripts/journal.sh" write --observation Test --context Test --scores '{"d5_spec_utility":4}' --rubric-id retro-rubric --rubric-version 0123456789ab
  [ "$status" -eq 0 ]
  jq -e '.rubric_id=="retro-rubric" and .rubric_version=="0123456789ab" and .scores=={"d5_spec_utility":4}' "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
}

@test "each new dimension sink resumes independently and exact replay adds no duplicates" {
  upgrade_to_v2
  for dimension in D1 D2 D3 D4 D5 D6; do
    # Each isolated filing fails a different dimension after all other sinks land.
    rm -f "$TEST_KDIR/_work/cycle-a/retro-filing.json"
    : > "$TEST_KDIR/_scorecards/rows.jsonl"
    : > "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
    export LORE_RETRO_FILE_FAIL_SINK="scorecard:dimension:$dimension"
    file_cycle
    [ "$status" -eq 1 ]
    json_line | jq -e --arg sink "$LORE_RETRO_FILE_FAIL_SINK" '.missing_sinks==[$sink,"scorecard:retro-filing"]'
    jq -se 'length==5 and all(.kind=="scored")' "$TEST_KDIR/_scorecards/rows.jsonl"
    cp "$TEST_KDIR/_scorecards/rows.jsonl" "$TEST_KDIR/partial-rows"
    unset LORE_RETRO_FILE_FAIL_SINK
    file_cycle
    [ "$status" -eq 0 ]
    json_line | jq -e '.status=="recovered"'
    head -c "$(wc -c < "$TEST_KDIR/partial-rows")" "$TEST_KDIR/_scorecards/rows.jsonl" > "$TEST_KDIR/prefix"
    cmp "$TEST_KDIR/partial-rows" "$TEST_KDIR/prefix"
    cp "$TEST_KDIR/_scorecards/rows.jsonl" "$TEST_KDIR/full-rows"
    file_cycle
    [ "$status" -eq 0 ]
    json_line | jq -e '.status=="reused"'
    cmp "$TEST_KDIR/full-rows" "$TEST_KDIR/_scorecards/rows.jsonl"
    jq -se 'length==7 and .[-1].event_type=="retro-filing"' "$TEST_KDIR/_scorecards/rows.jsonl"
  done
}

@test "cycle lock retains immediate filing-locked refusal without writes" {
  upgrade_to_v2
  mkdir "$TEST_KDIR/_work/cycle-a/.retro-file.lock"
  file_cycle
  [ "$status" -eq 1 ]
  json_line | jq -e '.error.code=="filing-locked"'
  [ ! -f "$TEST_KDIR/_work/cycle-a/retro-filing.json" ]
  [ ! -s "$TEST_KDIR/_scorecards/rows.jsonl" ]
}

@test "existing aggregate reader separates two rubric versions and D5 versus D6" {
  upgrade_to_v2
  file_cycle
  [ "$status" -eq 0 ]
  old_version=$(jq -r .rubric_version "$JUDGMENTS")
  cp "$REPO_DIR/skills/retro/rubric.json" "$TEST_KDIR/next-rubric.json"
  printf '\n' >> "$TEST_KDIR/next-rubric.json"
  # Model a second accepted cycle using a separately frozen rubric version.
  mv "$TEST_KDIR/_work/cycle-a" "$TEST_KDIR/_work/cycle-original"
  mkdir "$TEST_KDIR/_work/cycle-a"
  cp "$TEST_KDIR/_work/cycle-original/_meta.json" "$TEST_KDIR/_work/cycle-a/_meta.json"
  cp "$TEST_KDIR/_work/cycle-original/retro-evidence-pack.json" "$PACK"
  write_no_suggestion_manifest
  upgrade_to_v2 "$TEST_KDIR/next-rubric.json"
  file_cycle
  [ "$status" -eq 0 ]
  new_version=$(jq -r .rubric_version "$JUDGMENTS")
  [ "$new_version" != "$old_version" ]
  run python3 "$REPO_DIR/scripts/retro-export-aggregate-cells.py" "$TEST_KDIR/_scorecards/rows.jsonl" 2026-01-01T00:00:00Z fixture
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg old "$old_version" --arg new "$new_version" 'map(select(.metric=="d5_spec_utility" or .metric=="d6_packet_utility")) | length==4 and (map(.template_version)|unique|sort)==([$old,$new]|sort) and all(.n==1 and (.calibrated_only|not))'
}

@test "terminal marker cannot conceal a missing dimension sink" {
  upgrade_to_v2
  file_cycle
  [ "$status" -eq 0 ]
  # Simulate an incomplete restored ledger; production writes use only the appender.
  jq -c 'select(.dimension_id!="D6")' "$TEST_KDIR/_scorecards/rows.jsonl" > "$TEST_KDIR/restored"
  cp "$TEST_KDIR/restored" "$TEST_KDIR/_scorecards/rows.jsonl"
  export LORE_RETRO_FILE_FAIL_SINK=scorecard:dimension:D6
  file_cycle
  [ "$status" -eq 1 ]
  json_line | jq -e '.filing_complete==false and .missing_sinks==["scorecard:dimension:D6"]'
  unset LORE_RETRO_FILE_FAIL_SINK
  file_cycle
  [ "$status" -eq 0 ]
  jq -se 'length==7 and (map(select(.event_type=="retro-filing"))|length)==1' "$TEST_KDIR/_scorecards/rows.jsonl"
}
