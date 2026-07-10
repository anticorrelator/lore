#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PREPARE="$REPO_DIR/scripts/evolve-prepare.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_ROLE=maintainer
  mkdir -p "$TEST_KDIR/_meta" "$TEST_KDIR/_scorecards" "$TEST_KDIR/_evolve" \
    "$TEST_KDIR/_work/active-a" "$TEST_KDIR/_work/_archive/archived-a"
  printf '{"format_version":2}\n' > "$TEST_KDIR/_manifest.json"
  : > "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  : > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '{"schema_version":"1","entries":[]}\n' > "$TEST_KDIR/_scorecards/template-registry.json"
  : > "$TEST_KDIR/_evolve/accepted-clusters.jsonl"
}

teardown() {
  rm -rf "${TEST_KDIR:-}"
  unset LORE_KNOWLEDGE_DIR LORE_ROLE
}

write_journal() {
  python3 - "$TEST_KDIR/_meta/effectiveness-journal.jsonl" "$@" <<'PY'
import json,sys
path=sys.argv[1]
for raw in sys.argv[2:]:
    role,stamp,work,observation=raw.split("~",3)
    with open(path,"a") as f:
        f.write(json.dumps({"timestamp":stamp,"role":role,"work_item":work,"context":role+":"+work,"observation":observation},separators=(",",":"))+"\n")
PY
}

proposal() {
  printf 'Target: %s | Change type: %s | Section: gate | Suggestion: %s | Evidence: %s' "$1" "$2" "$3" "$4"
}

artifact() {
  find "$TEST_KDIR/_evolve/review-queues" -name '*.json' -type f | head -1
}

@test "prepare publishes the exact queue-v1 schema with four-state eligibility and no judgment fields" {
  obs=$(proposal 'skills/a/SKILL.md' 'ceiling-raise' 'tighten behavior' 'metric=quality sample_size=9')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-a~$obs"
  printf '%s\n' '{"schema_version":"1","kind":"scored","tier":"template","calibration_state":"calibrated","template_id":"a","template_version":"v1","sample_size":9,"metric":"quality","window_start":"2026-07-01T00:00:00Z","window_end":"2026-07-02T00:00:00Z"}' > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '%s\n' '{"schema_version":"1","entries":[{"template_id":"a","template_version":"v1"}]}' > "$TEST_KDIR/_scorecards/template-registry.json"

  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="created" and .decision_accepted==null and .filing_complete==null'
  run python3 - "$(artifact)" <<'PY'
import hashlib,json,sys
raw=open(sys.argv[1],"rb").read(); q=json.loads(raw)
assert not raw.endswith(b"\n")
assert set(q)=={"schema_version","queue_id","input_fingerprint","source_fingerprint","artifact_sha256","run","cutoff","due_claim","source_manifest","items","groups","recurring_clusters","summary","provenance"}
assert [r["source_id"] for r in q["source_manifest"]]==["journal","scorecard_rows","template_registry","accepted_clusters","consumption_contradictions","prior_filings"]
assert q["due_claim"]=={"attempted":False,"outcome_ids":[],"disposition":"not-applicable","warning":None}
assert q["items"][0]["eligibility"]["status"]=="eligible"
assert set(q["summary"]["eligibility"])=={"eligible","no_op","abstained","not_computable"}
body={k:v for k,v in q.items() if k!="artifact_sha256"}
assert q["artifact_sha256"]==hashlib.sha256(json.dumps(body,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest()
forbidden={"recommended_verdict","recommendation","selected","approved","decision","verdict","edit","edit_text","application"}
def walk(v):
 if isinstance(v,dict):
  assert not (set(v)&forbidden); [walk(x) for x in v.values()]
 elif isinstance(v,list): [walk(x) for x in v]
walk(q)
PY
  [ "$status" -eq 0 ]
}

@test "equal timestamps retain distinct append cursors and an explicit legacy lower boundary" {
  old=$(proposal 'skills/old/SKILL.md' 'ceiling' 'old' 'metric=m sample_size=8')
  one=$(proposal 'skills/one/SKILL.md' 'ceiling' 'one' 'metric=m sample_size=8')
  two=$(proposal 'skills/two/SKILL.md' 'ceiling' 'two' 'metric=m sample_size=8')
  write_journal "evolve~2026-07-10T01:00:00Z~legacy~done" \
    "retro-evolution~2026-07-10T02:00:00Z~wi-1~$one" \
    "retro-evolution~2026-07-10T02:00:00Z~wi-2~$two"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  run jq -e '.cutoff.basis=="legacy-evolve-row" and .cutoff.lower.row_ordinal==1 and .cutoff.upper.row_ordinal==3 and (.items|length)==2 and .items[0].source_cursor.row_ordinal==2 and .items[1].source_cursor.row_ordinal==3' "$(artifact)"
  [ "$status" -eq 0 ]
}

@test "interior malformed suggestions are retained while a torn tail does not advance the upper cutoff" {
  one=$(proposal 'skills/one/SKILL.md' 'ceiling' 'one' 'metric=m sample_size=8')
  two=$(proposal 'skills/two/SKILL.md' 'ceiling' 'two' 'metric=m sample_size=8')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-1~$one"
  printf '{bad interior}\n' >> "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  write_journal "retro-evolution~2026-07-10T02:00:00Z~wi-2~$two"
  printf '{torn' >> "$TEST_KDIR/_meta/effectiveness-journal.jsonl"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.warnings|length==2'
  run jq -e '.cutoff.upper.row_ordinal==3 and (.items|length)==3 and ([.items[].parse.status]|index("invalid"))!=null and .summary.parse_invalid_total==1' "$(artifact)"
  [ "$status" -eq 0 ]
}

@test "active and archived verified contradiction rows satisfy claim retraction without a kind projection" {
  obs=$(proposal 'knowledge/foo.md' 'claim-retraction' 'remove claim' 'contradiction_id=contra-arch knowledge_path=knowledge/foo.md')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-a~$obs"
  printf '%s\n' '{"contradiction_id":"contra-arch","status":"verified","prefetched_commons_entry":{"knowledge_path":"knowledge/foo.md"},"settled_at":"2026-07-09T00:00:00Z"}' > "$TEST_KDIR/_work/_archive/archived-a/consumption-contradictions.jsonl"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  run jq -e '.items[0].gate_path=="claim-retraction" and .items[0].eligibility.status=="eligible" and (.items[0].eligibility.evidence_refs[0].source_path|contains("_archive"))' "$(artifact)"
  [ "$status" -eq 0 ]
}

@test "definitive failure low sample and unavailable sources remain distinct states" {
  no=$(proposal 'skills/no/SKILL.md' 'ceiling' 'change' 'metric=absent sample_size=9')
  low=$(proposal 'skills/low/SKILL.md' 'ceiling' 'change' 'metric=quality sample_size=2')
  missing=$(proposal 'knowledge/missing.md' 'claim-retraction' 'remove' 'contradiction_id=none')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-no~$no" \
    "retro-evolution~2026-07-10T02:00:00Z~wi-low~$low" \
    "retro-evolution~2026-07-10T03:00:00Z~wi-missing~$missing"
  printf '%s\n' '{"schema_version":"1","kind":"scored","tier":"template","calibration_state":"calibrated","template_id":"a","template_version":"v1","sample_size":2,"metric":"quality"}' > "$TEST_KDIR/_scorecards/rows.jsonl"
  printf '%s\n' '{"schema_version":"1","entries":[{"template_id":"a","template_version":"v1"}]}' > "$TEST_KDIR/_scorecards/template-registry.json"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  run jq -e '[.items[].eligibility.status]==["no_op","abstained","not_computable"]' "$(artifact)"
  [ "$status" -eq 0 ]
}

@test "declared-v1 accepted clusters gate recurring failure and same source bytes are read-only" {
  obs=$(proposal 'skills/a/SKILL.md' 'recurring-failure' 'change' 'cluster evidence')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-a~$obs"
  printf '%s\n' '{"schema_version":"1","vocabulary_version":"1","cluster_id":"c1","target":"skills/a/SKILL.md","change_types":["recurring-failure"],"work_items":["a","b","c"],"accepted_at_run_id":"prior","consumed_at_run_id":null}' > "$TEST_KDIR/_evolve/accepted-clusters.jsonl"
  before=$(shasum -a 256 "$TEST_KDIR/_evolve/accepted-clusters.jsonl" "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | shasum -a 256 | awk '{print $1}')
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  after=$(shasum -a 256 "$TEST_KDIR/_evolve/accepted-clusters.jsonl" "$TEST_KDIR/_meta/effectiveness-journal.jsonl" | shasum -a 256 | awk '{print $1}')
  [ "$before" = "$after" ]
  run jq -e '.items[0].gate_path=="recurring-failure" and .items[0].eligibility.status=="eligible" and .items[0].eligibility.arithmetic.numerator==3' "$(artifact)"
  [ "$status" -eq 0 ]
}

@test "exact replay reuses canonical bytes and changed evidence yields a new queue identity" {
  obs=$(proposal 'skills/a/SKILL.md' 'ceiling' 'change' 'metric=q sample_size=9')
  write_journal "retro-evolution~2026-07-10T01:00:00Z~wi-a~$obs"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  first=$(echo "$output" | jq -r '.queue.id')
  first_hash=$(shasum -a 256 "$(artifact)" | awk '{print $1}')
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status=="reused"'
  [ "$first_hash" = "$(shasum -a 256 "$(artifact)" | awk '{print $1}')" ]
  printf '%s\n' '{"schema_version":"1","kind":"telemetry","tier":"telemetry","metric":"new"}' >> "$TEST_KDIR/_scorecards/rows.jsonl"
  run bash "$PREPARE" --json
  [ "$status" -eq 0 ]
  [ "$first" != "$(echo "$output" | jq -r '.queue.id')" ]
  [ "$(find "$TEST_KDIR/_evolve/review-queues" -name '*.json' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "prepare refuses past an accepted incomplete filing" {
  mkdir -p "$TEST_KDIR/_evolve/review-filings"
  printf '%s' '{"schema_version":1,"filing_id":"f-incomplete","accepted_at":"2026-07-10T00:00:00Z"}' > "$TEST_KDIR/_evolve/review-filings/q.json"
  run bash "$PREPARE" --json
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.status=="refused" and .error.code=="accepted_filing_incomplete" and .decision_accepted==null'
}
