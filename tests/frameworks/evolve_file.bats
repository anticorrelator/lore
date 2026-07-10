#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PREPARE="$REPO_DIR/scripts/evolve-prepare.sh"
FILE_VERB="$REPO_DIR/scripts/evolve-file.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_ROLE=maintainer
  mkdir -p "$TEST_KDIR/_meta" "$TEST_KDIR/_scorecards" "$TEST_KDIR/_evolve" "$TEST_KDIR/_work/a"
  printf '{"format_version":2}\n' > "$TEST_KDIR/_manifest.json"
  : > "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  : > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '{"schema_version":"1","entries":[]}\n' > "$TEST_KDIR/_scorecards/template-registry.json"
  : > "$TEST_KDIR/_evolve/accepted-clusters.jsonl"
  DECISIONS="$TEST_KDIR/decisions.json"
}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR LORE_ROLE LORE_EVOLVE_FILE_FAIL_SINK
}

write_journal() {
  python3 - "$TEST_KDIR/_meta/effectiveness-journal.jsonl" "$@" <<'PY'
import json,sys
path=sys.argv[1]
for raw in sys.argv[2:]:
 role,stamp,work,observation=raw.split("~",3)
 with open(path,"a") as f:f.write(json.dumps({"timestamp":stamp,"role":role,"work_item":work,"context":role+":"+work,"observation":observation},separators=(",",":"))+"\n")
PY
}

proposal() { printf 'Target: %s | Change type: %s | Section: gate | Suggestion: %s | Evidence: %s' "$1" "$2" "$3" "$4"; }

prepare_queue() {
  local result
  result=$(bash "$PREPARE" --json)
  QUEUE="$TEST_KDIR/$(echo "$result" | jq -r .queue.path)"
}

write_default_manifest() {
  jq '{schema_version:1,queue_id:.queue_id,queue_sha256:(input_filename|""),actor:"evolve-lead",model:"fable-test",
      decisions:[.items[]|select(.eligibility.status=="eligible")|{item_id,verdict:"reject",rationale:"The lead rejects this proposal against its evidence.",escalation:null,application:null}],
      cluster_dispositions:[.recurring_clusters[]|{candidate_id,disposition:"reject",rationale:"The lead rejects this cluster.",resulting_clusters:null}],
      version_registrations:[],summary:"Lead-authored evolve filing."}' "$QUEUE" > "$DECISIONS"
  QUEUE_SHA=$(shasum -a 256 "$QUEUE" | awk '{print $1}')
  jq --arg sha "$QUEUE_SHA" '.queue_sha256=$sha' "$DECISIONS" > "$DECISIONS.tmp"
  mv "$DECISIONS.tmp" "$DECISIONS"
}

@test "zero-decision filing accepts authority and writes the terminal cutoff as the only sink" {
  prepare_queue
  write_default_manifest
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="created" and .decision_accepted and .filing_complete and (.completed_sinks|length)==1 and (.completed_sinks[0]|startswith("journal:evolve-filing:"))'
  [ "$(jq -s '[.[]|select(.role=="evolve")]|length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 1 ]
}

@test "exact replay reuses the filing and every exact sink key" {
  prepare_queue; write_default_manifest
  bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json >/dev/null
  before=$(wc -l < "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | tr -d ' ')
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="reused" and .decision_accepted and .filing_complete'
  [ "$before" -eq "$(wc -l < "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | tr -d ' ')" ]
}

@test "an apply decision requires live post-version proof and registers through the sanctioned writer" {
  TARGET="$TEST_KDIR/target-skill.md"
  printf 'new bytes\n' > "$TARGET"
  POST=$(shasum -a 256 "$TARGET" | awk '{print substr($1,1,12)}')
  mkdir -p "$TEST_KDIR/_work/a"
  printf '%s\n' '{"contradiction_id":"c1","status":"verified","prefetched_commons_entry":{"knowledge_path":"k/a"}}' > "$TEST_KDIR/_work/a/consumption-contradictions.jsonl"
  obs=$(proposal "$TARGET" claim-retraction 'apply edit' 'contradiction_id=c1 knowledge_path=k/a')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~a~$obs"
  prepare_queue; write_default_manifest
  jq --arg target "$TARGET" --arg post "$POST" '
    .decisions[0]={item_id:.decisions[0].item_id,verdict:"apply",rationale:"Evidence supports the direct lead-authored edit.",escalation:null,application:{outcome:"applied",target:$target,pre_version:"000000000000",post_version:$post}} |
    .version_registrations=[{item_id:.decisions[0].item_id,target:$target,template_id:"fixture",template_path:$target,pre_version:"000000000000",post_version:$post,description:"fixture bump"}]' "$DECISIONS" > "$DECISIONS.tmp"
  mv "$DECISIONS.tmp" "$DECISIONS"
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg key "template-registry:fixture@$POST" '.completed_sinks|index($key)'
  jq -e --arg post "$POST" '.entries[]|select(.template_id=="fixture" and .template_version==$post)' "$TEST_KDIR/_scorecards/template-registry.json"
}

@test "authority-first partial is visible and exact replay repairs only the missing registry and cutoff sinks" {
  TARGET="$TEST_KDIR/target-skill.md"; printf 'new bytes\n' > "$TARGET"; POST=$(shasum -a 256 "$TARGET" | awk '{print substr($1,1,12)}')
  printf '%s\n' '{"contradiction_id":"c1","status":"verified","prefetched_commons_entry":{"knowledge_path":"k/a"}}' > "$TEST_KDIR/_work/a/consumption-contradictions.jsonl"
  obs=$(proposal "$TARGET" claim-retraction 'apply edit' 'contradiction_id=c1 knowledge_path=k/a'); write_journal "retro-evolution~2026-07-10T01:00:00Z~a~$obs"
  prepare_queue; write_default_manifest
  jq --arg target "$TARGET" --arg post "$POST" '.decisions[0]={item_id:.decisions[0].item_id,verdict:"apply",rationale:"Apply.",escalation:null,application:{outcome:"applied",target:$target,pre_version:"000000000000",post_version:$post}}|.version_registrations=[{item_id:.decisions[0].item_id,target:$target,template_id:"fixture",template_path:$target,pre_version:"000000000000",post_version:$post,description:null}]' "$DECISIONS" > "$DECISIONS.tmp"; mv "$DECISIONS.tmp" "$DECISIONS"
  export LORE_EVOLVE_FILE_FAIL_SINK="template-registry:fixture@$POST"
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status=="partial" and .decision_accepted and (.filing_complete|not) and (.missing_sinks|length)==2'
  [ "$(jq -s '[.[]|select(.role=="evolve")]|length' "$TEST_KDIR/_meta/effectiveness-journal.jsonl")" -eq 0 ]
  run bash "$PREPARE" --json
  [ "$status" -eq 1 ]
  unset LORE_EVOLVE_FILE_FAIL_SINK
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="recovered" and .filing_complete'
}

@test "cluster creation and prior consumption stay on one writer and same-run clusters remain unconsumed" {
  obs=$(proposal 'skills/source/SKILL.md' recurring-failure 'review recurring issue' 'cluster evidence')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~a~$obs" \
    "retro-evolution~2026-07-10T02:00:00Z~b~$obs" \
    "retro-evolution~2026-07-10T03:00:00Z~c~$obs"
  bash "$REPO_DIR/scripts/accepted-cluster-append.sh" --append-exact --target skills/source/SKILL.md --change-types recurring-failure --work-items a,b,c --decision merge --accepted-at-run-id prior-run --accepted-at 2026-07-09T00:00:00Z --kdir "$TEST_KDIR" >/dev/null
  prepare_queue; write_default_manifest
  jq '.cluster_dispositions[0]={candidate_id:.cluster_dispositions[0].candidate_id,disposition:"edit",rationale:"Keep a narrower cluster.",resulting_clusters:[{target:"skills/new/SKILL.md",change_types:["recurring-failure"],work_items:["a","b","c"],journal_row_refs:[]}]}' "$DECISIONS" > "$DECISIONS.tmp"; mv "$DECISIONS.tmp" "$DECISIONS"
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 0 ]
  [ "$(jq -s 'length' "$TEST_KDIR/_evolve/accepted-clusters.jsonl")" -eq 2 ]
  jq -s -e '.[0].consumed_at_run_id!=null and .[1].consumed_at_run_id==null' "$TEST_KDIR/_evolve/accepted-clusters.jsonl"
}

@test "semantic reassignment and stale competing successors are refused before a second authority" {
  prepare_queue; Q1="$QUEUE"; write_default_manifest; D1="$TEST_KDIR/d1.json"; cp "$DECISIONS" "$D1"
  printf '%s\n' '{"schema_version":"1","kind":"telemetry","tier":"telemetry","metric":"new"}' >> "$TEST_KDIR/_scorecards/rows.jsonl"
  prepare_queue; Q2="$QUEUE"; write_default_manifest; D2="$TEST_KDIR/d2.json"; cp "$DECISIONS" "$D2"
  bash "$FILE_VERB" --queue "$Q1" --decisions "$D1" --json >/dev/null
  run bash "$FILE_VERB" --queue "$Q2" --decisions "$D2" --json
  [ "$status" -eq 1 ]
  echo "$output" | grep '^{' | tail -1 | jq -e '.status=="refused" and (.decision_accepted|not)'
  jq '.summary="Changed lead assignment."' "$D1" > "$D1.tmp"; mv "$D1.tmp" "$D1"
  run bash "$FILE_VERB" --queue "$Q1" --decisions "$D1" --json
  [ "$status" -eq 1 ]
  [ "$(find "$TEST_KDIR/_evolve/review-filings" -name '*.json' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "missing or extra lead verdicts refuse before authoritative publication" {
  printf '%s\n' '{"contradiction_id":"c1","status":"verified","prefetched_commons_entry":{"knowledge_path":"k/a"}}' > "$TEST_KDIR/_work/a/consumption-contradictions.jsonl"
  obs=$(proposal 'skills/a/SKILL.md' claim-retraction 'change' 'contradiction_id=c1 knowledge_path=k/a'); write_journal "retro-evolution~2026-07-10T01:00:00Z~a~$obs"
  prepare_queue; write_default_manifest
  jq '.decisions=[]' "$DECISIONS" > "$DECISIONS.tmp"; mv "$DECISIONS.tmp" "$DECISIONS"
  run bash "$FILE_VERB" --queue "$QUEUE" --decisions "$DECISIONS" --json
  [ "$status" -eq 1 ]
  [ ! -d "$TEST_KDIR/_evolve/review-filings" ]
}
