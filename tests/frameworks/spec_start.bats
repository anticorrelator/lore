#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"

setup() {
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_FRAMEWORK=codex
  export LORE_MODEL_LEAD=test-lead-model
  mkdir -p "$TEST_KDIR/_work/start-item"
  printf '%s\n' '{"title":"Start Item","status":"active","intent_anchor":"Deliver startup."}' > "$TEST_KDIR/_work/start-item/_meta.json"
  printf '%s\n' '# Start Item' '' '## Strategy' 'Use verbs.' '' '## Investigations' 'Findings.' '' '## Phases' '### Phase 1: Build' '- [ ] Build it [class: standard]' '' '## Open Questions' '- None.' > "$TEST_KDIR/_work/start-item/plan.md"
}

teardown() {
  rm -rf "$TEST_KDIR"
  unset LORE_KNOWLEDGE_DIR LORE_FRAMEWORK LORE_MODEL_LEAD
}

json_line() { echo "$output" | grep '"schema_version"'; }

@test "start returns the complete version-1 branch-selection schema" {
  run bash "$LORE" spec start start-item --json
  [ "$status" -eq 0 ]
  json_line | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert set(d)=={"schema_version","resolved","slug","archived","plan_state","intent_anchor","strategy_present","active_framework","effective_lead_model","track","lead_template_version","provenance"}
assert d["schema_version"]==1 and d["resolved"] is True
assert d["plan_state"]=="synthesis-complete"
assert d["intent_anchor"]=="Deliver startup."
assert d["strategy_present"] is True
assert d["active_framework"]=="codex" and d["effective_lead_model"]=="test-lead-model"
assert d["track"]=="full" and len(d["lead_template_version"])==12
'
  [ ! -e "$TEST_KDIR/_work/start-item/execution-log.md" ]
}

@test "start short and model are explicit overrides" {
  run bash "$LORE" spec start start-item --short --model invocation-model --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["track"]=="short"; assert d["effective_lead_model"]=="invocation-model"'
}

@test "unseen input is a read-only unresolved struct, not an error or implicit work item" {
  run bash "$LORE" spec start a-brand-new-capability --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["resolved"] is False; assert d["slug"] is None; assert d["plan_state"]=="none"'
  [ ! -d "$TEST_KDIR/_work/a-brand-new-capability" ]
  [ ! -e "$TEST_KDIR/_work/_index.json" ]
}

@test "follow-up-needed outranks synthesis-complete when open questions remain" {
  printf '%s\n' '- A real unresolved question' >> "$TEST_KDIR/_work/start-item/plan.md"
  run bash "$LORE" spec start start-item --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; assert json.load(sys.stdin)["plan_state"]=="follow-up-needed"'
}

@test "start rejects undeclared or unknown arguments rather than routing defaults" {
  run bash "$LORE" spec start --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing required argument"
  run bash "$LORE" spec start start-item --mystery
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown flag"
}
