#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"

setup() {
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/_work/outcome-item"
  printf '%s\n' '{"title":"Outcome Item","status":"active"}' > "$TEST_KDIR/_work/outcome-item/_meta.json"
  printf '%s\n' '# Outcome Item' '## Phases' '- [ ] Build [class: standard]' > "$TEST_KDIR/_work/outcome-item/plan.md"
  EVIDENCE="$TEST_KDIR/evidence.json"
  printf '%s' '{"schema_version":1,"evaluator_locator":"skill://review","evaluator_template_version":"123456789abc","framework":"codex","model":"review-model","final_round":2,"disposition_ledger_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_plan_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' > "$EVIDENCE"
}

teardown() { rm -rf "$TEST_KDIR"; unset LORE_KNOWLEDGE_DIR; }

invoke_completed() {
  run bash "$LORE" spec outcome outcome-item --ceremony spec-design --advisor reviewer \
    --attempt-id attempt-1 --outcome completed --verdict PASS --evidence-manifest "$EVIDENCE" --json
}

record_count() { grep -c '^Spec-outcome-record:' "$TEST_KDIR/_work/outcome-item/execution-log.md" 2>/dev/null || true; }

@test "completed outcome files one authoritative record with opaque raw verdict and evidence" {
  invoke_completed
  [ "$status" -eq 0 ]
  echo "$output" | grep '"schema_version"' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="completed"; assert len(d["outcome_id"])==64'
  [ "$(record_count)" -eq 1 ]
  grep -q 'Raw-verdict: PASS' "$TEST_KDIR/_work/outcome-item/execution-log.md"
  [ ! -e "$TEST_KDIR/_scorecards/rows.jsonl" ]
}

@test "exact replay is idempotent while attempt-id semantic reuse is refused" {
  invoke_completed; [ "$status" -eq 0 ]
  invoke_completed; [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "reused"'
  [ "$(record_count)" -eq 1 ]

  run bash "$LORE" spec outcome outcome-item --ceremony spec-design --advisor reviewer \
    --attempt-id attempt-1 --outcome failed --verdict FAIL --evidence-manifest "$EVIDENCE" --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "attempt-id collision"
  [ "$(record_count)" -eq 1 ]
}

@test "needs-decision requires a reason and appends the existing unhandled ceremony scorecard shape" {
  python3 - "$EVIDENCE" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for k in list(d):
    if k != "schema_version": d[k]=None
json.dump(d,open(sys.argv[1],"w"))
PY
  run bash "$LORE" spec outcome outcome-item --ceremony spec-post-plan --advisor reviewer \
    --attempt-id attempt-2 --outcome needs-decision --verdict UNAVAILABLE --evidence-manifest "$EVIDENCE" --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--reason is required"

  run bash "$LORE" spec outcome outcome-item --ceremony spec-post-plan --advisor reviewer \
    --attempt-id attempt-2 --outcome needs-decision --verdict UNAVAILABLE --evidence-manifest "$EVIDENCE" \
    --reason "Evaluator could not resolve." --json
  [ "$status" -eq 0 ]
  jq -e 'select(.event_type=="ceremony-resolution" and .outcome=="needs-decision" and .disposition=="unhandled" and .outcome_id)' "$TEST_KDIR/_scorecards/rows.jsonl" >/dev/null
}

@test "completed rejects null evidence and every missing declaration is an error" {
  printf '%s' '{"schema_version":1,"evaluator_locator":null,"evaluator_template_version":null,"framework":null,"model":null,"final_round":null,"disposition_ledger_sha256":null,"source_plan_sha256":null}' > "$EVIDENCE"
  invoke_completed
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "validation failed"
  [ ! -e "$TEST_KDIR/_work/outcome-item/execution-log.md" ]

  run bash "$LORE" spec outcome outcome-item --ceremony spec-design
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing required declaration"
}
