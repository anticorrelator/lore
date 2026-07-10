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
      {dimension_id:"D3",score:4,rationale:"Gaps are named.",evidence_refs:["calculation:consumer_contradiction_routing"]},
      {dimension_id:"D4",score:5,rationale:"Anchor alignment holds.",evidence_refs:["pack:/cycle/slug"]},
      {dimension_id:"D5",score:4,rationale:"Spec was useful.",evidence_refs:["source:journal"]}
    ],
    behavioral_health:[{check_id:"C7",answer:"The agents reasoned from missing evidence instead of complying with a green default.",evidence_refs:["pack:/fixed_health/state"]}],
    causal_diagnoses:[{diagnosis_id:"source-gap",interpretation:"The public reader boundary prevents a trustworthy rate.",evidence_refs:["source:consumer_contradiction_lifecycle"]}],
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
      .suggestions=[{target:"skills/retro/SKILL.md",change_type:"evidence-gap",section:"Step 3.8",suggestion:"Add a sanctioned reader.",evidence:"Lifecycle is not computable.",evidence_refs:["calculation:consumer_contradiction_routing"]}] |
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
