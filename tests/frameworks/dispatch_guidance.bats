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

write_settings() {
  local marker="$1"
  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":1,"dispatch_test":"$marker","harnesses":{"codex":{"roles":{"worker":"gpt-test"}}}}
EOF
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
  valid=$(python3 - "$block" <<'PY'
import json, sys
print(json.dumps({"tool_name":"Agent", "tool_input":{"prompt":sys.argv[1] + "\nTask"}}))
PY
)
  run bash -c "printf '%s' \"\$1\" | bash '$VALIDATOR' --hook claude-code" _ "$valid"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c "printf '%s' '{\"tool_name\":\"Agent\",\"tool_input\":{\"prompt\":\"Task only\"}}' | bash '$VALIDATOR' --hook claude-code"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"lore dispatch guidance"* ]]
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
