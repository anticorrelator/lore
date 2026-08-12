#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
RENDERER="$REPO_DIR/scripts/render-dispatch-guidance.sh"
VALIDATOR="$REPO_DIR/scripts/validate-dispatch-guidance.sh"
LIB="$REPO_DIR/scripts/lib.sh"
CLI="$REPO_DIR/cli/lore"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_LORE_DATA_DIR="$TEST_ROOT/lore-data"
  mkdir -p "$TEST_HOME/.lore" "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_HOME/.lore/scripts"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export HOME="$TEST_HOME"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export LORE_FRAMEWORK=codex
  write_settings alpha
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# The second argument is the claude-code default-role binding the admission
# gate resolves when a launch names no model. Pass an empty string to write
# settings that bind nothing, which is the resolver-failure case.
write_settings() {
  local marker="$1"
  local claude_default="${2-opus-test}"
  local claude_block=""
  if [[ -n "$claude_default" ]]; then
    claude_block=",\"claude-code\":{\"roles\":{\"default\":\"$claude_default\"}}"
  fi
  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":1,"dispatch_test":"$marker","harnesses":{"codex":{"roles":{"worker":"gpt-test"}}$claude_block}}
EOF
}

# Wrap a prompt in the claude-code PreToolUse payload shape. A third argument
# adds an explicit tool_input.model.
agent_payload() {
  python3 - "$@" <<'PY'
import json, sys
prompt = sys.argv[1]
tool_input = {"prompt": prompt, "subagent_type": "Explore"}
if len(sys.argv) > 2 and sys.argv[2]:
    tool_input["model"] = sys.argv[2]
print(json.dumps({"tool_name": "Agent", "tool_input": tool_input}))
PY
}

render_prompt() {
  bash "$RENDERER"
}

@test "lore dispatch guidance is a thin reachable CLI verb" {
  run bash "$CLI" dispatch guidance
  [ "$status" -eq 0 ]
  [[ "$output" == *"<!-- lore-dispatch-guidance:v1:begin -->"* ]]
  [[ "$output" == *"dispatch_test: alpha"* ]]
}

@test "lib.sh exposes stable renderer and validator dispatch helpers" {
  run bash -c "source '$LIB'; block=\$(render_dispatch_guidance); printf '%s\\nTask: test\\n' \"\$block\" | validate_dispatch_guidance"
  [ "$status" -eq 0 ]
}

@test "renderer emits binding, complete external vocabulary, and a current digest" {
  run render_prompt
  [ "$status" -eq 0 ]
  [[ "$output" == *"Schema-Version: 1"* ]]
  [[ "$output" =~ Defaults-Digest:\ sha256:[0-9a-f]{64} ]]
  [[ "$output" == *"binding for this dispatch"* ]]
  [[ "$output" == *"harness session links"* ]]
  [[ "$output" == *"session trailers"* ]]
  [[ "$output" == *"generated-attribution lines"* ]]
  [[ "$output" == *"agent/worker/skill language"* ]]
  [[ "$output" == *"Lore tooling references"* ]]
}

@test "validator accepts one complete current block inside a composed prompt" {
  block="$(render_prompt)"
  run bash -c "printf '%s\\nTask-specific context.\\n' \"\$1\" | bash '$VALIDATOR'" _ "$block"
  [ "$status" -eq 0 ]
}

@test "validator rejects missing duplicated altered truncated and stale blocks" {
  block="$(render_prompt)"

  run bash -c "printf 'Task only\\n' | bash '$VALIDATOR'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one complete"* ]]

  run bash -c "printf '%s\\n%s\\n' \"\$1\" \"\$1\" | bash '$VALIDATOR'" _ "$block"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one complete"* ]]

  altered="${block/Binding: Treat/Binding: Ignore}"
  run bash -c "printf '%s\\n' \"\$1\" | bash '$VALIDATOR'" _ "$altered"
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding declaration"* ]]

  truncated="${block%<!-- lore-dispatch-guidance:v1:end -->}"
  run bash -c "printf '%s\\n' \"\$1\" | bash '$VALIDATOR'" _ "$truncated"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one complete"* ]]

  write_settings beta
  run bash -c "printf '%s\\n' \"\$1\" | bash '$VALIDATOR'" _ "$block"
  [ "$status" -ne 0 ]
  [[ "$output" == *"digest is stale"* ]]
}

@test "claude-code hook validates Agent tool_input.prompt and emits native deny JSON" {
  block="$(render_prompt)"
  # A launch that names its own model needs nothing supplied, so a valid block
  # leaves the gate silent.
  valid=$(agent_payload "$block"$'\n'"Task" haiku-test)
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$valid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  altered=$(agent_payload "${block/Binding: Treat/Binding: Ignore}"$'\n'"Task" haiku-test)
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$altered"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"lore dispatch guidance"* ]]
}

@test "claude-code hook injects fresh guidance and the default model into block-free launches" {
  payload=$(agent_payload "Task only")
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
  [[ "$output" == *'"updatedInput"'* ]]

  updated_prompt=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.prompt')
  [[ "$updated_prompt" == "<!-- lore-dispatch-guidance:v1:begin -->"* ]]
  [[ "$updated_prompt" == *"<!-- lore-dispatch-guidance:v1:end -->"$'\n'"Task only" ]]

  # Guidance and model arrive in the same rewrite.
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.model')" = "opus-test" ]

  # Untouched tool_input fields survive the rewrite.
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.subagent_type')" = "Explore" ]

  # The injected prompt passes the strict validator it just bypassed.
  printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.prompt' | bash "$VALIDATOR"
}

@test "claude-code hook supplies the default model to a valid launch that names none" {
  block="$(render_prompt)"
  prompt="$block"$'\n'"Task"
  payload=$(agent_payload "$prompt")
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"allow"'* ]]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.model')" = "opus-test" ]

  # The prompt already carried a current block, so it round-trips byte for byte.
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.prompt')" = "$prompt" ]
}

@test "claude-code hook leaves an explicitly named model untouched" {
  payload=$(agent_payload "Task only" sonnet-test)
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$payload"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.model')" = "sonnet-test" ]
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')" != *"named no model"* ]]
}

@test "claude-code hook denies when the default launch model does not resolve" {
  write_settings alpha ""

  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$(agent_payload 'Task only')"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"default launch model failed to resolve"* ]]

  # A valid block does not rescue an unresolvable model either.
  block="$(render_prompt)"
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$(agent_payload "$block"$'\n'"Task")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"default launch model failed to resolve"* ]]
}

@test "claude-code hook still denies marker-bearing prompts instead of injecting" {
  # A stale block (settings changed after render) carries markers, so the
  # injection path must not rescue it — protocol seats own their freshness.
  # Neither does the model floor: a supplied default never converts a deny.
  block="$(render_prompt)"
  write_settings gamma
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$(agent_payload "$block"$'\n'"Task")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"digest is stale"* ]]
  [[ "$output" != *'"updatedInput"'* ]]

  altered="${block/Binding: Treat/Binding: Ignore}"
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$(agent_payload "$altered"$'\n'"Task")"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" != *'"updatedInput"'* ]]
}

@test "codex hook validates spawn_agent tool_input.message and fails closed" {
  block="$(render_prompt)"
  valid=$(python3 - "$block" <<'PY'
import json, sys
print(json.dumps({"tool_name":"spawn_agent", "tool_input":{"message":sys.argv[1] + "\nTask"}}))
PY
)
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook codex" _ "$valid"
  [ "$status" -eq 0 ]
  # Codex has no input-mutation channel, so nothing is ever supplied here.
  [ -z "$output" ]

  run bash -c "printf '%s' '{\"tool_name\":\"spawn_agent\",\"tool_input\":{\"message\":\"Task only\"}}' | bash '$VALIDATOR' --hook codex"
  [ "$status" -ne 0 ]
  [[ "$output" == *"lore dispatch guidance"* ]]
}

@test "hook mode rejects aliases and prompt fields without evidence" {
  run bash -c "printf '%s' '{\"tool_name\":\"Task\",\"tool_input\":{\"prompt\":\"x\"}}' | bash '$VALIDATOR' --hook claude-code"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsupported claude-code launch tool"* ]]

  run bash -c "printf '%s' '{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"x\"}}' | bash '$VALIDATOR' --hook codex"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported codex launch tool"* ]]
}
