#!/usr/bin/env bats
# agents.bats — Smoke skeleton for the per-harness orchestration adapters
# (Phase 4, T33 — full contract coverage lands with T63).
#
# Verifies the minimum invariants the adapter contract in
# adapters/agents/README.md asserts about every adapter:
#   - smoke entrypoint exists and refuses non-target frameworks.
#   - smoke output advertises the closed seven-operation set.
#   - source uses stable ~/.lore/scripts/ paths or LORE_DATA_DIR (no
#     `$(pwd)` or repo-absolute references).
#   - completion_enforcement resolves to native_blocking on claude-code.
#
# T63 owns the full operation × harness × support-level matrix; this
# file is the smoke skeleton T33 ships so the adapter is observable
# the same way hooks.bats observes hook adapters.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
AGENTS_README="$REPO_DIR/adapters/agents/README.md"
CC_AGENT_ADAPTER="$REPO_DIR/adapters/agents/claude-code.sh"
OC_AGENT_ADAPTER="$REPO_DIR/adapters/agents/opencode.sh"
CODEX_AGENT_ADAPTER="$REPO_DIR/adapters/agents/codex.sh"

# Closed seven-operation set per adapters/agents/README.md "Operation
# Surface". Tests assert each adapter's smoke output mentions every
# token; drift between the README table and adapter sources is a
# contract violation.
AGENT_OPERATIONS=(
  spawn
  wait
  send_message
  collect_result
  shutdown
  completion_enforcement
  resolve_model_for_role
)

setup() {
  [ -f "$CAPS" ] || skip "adapters/capabilities.json missing"
  [ -f "$AGENTS_README" ] || skip "adapters/agents/README.md missing"

  # Stage an isolated LORE_DATA_DIR so adapter smoke commands resolve
  # settings.json without touching the user's real config (mirrors hooks.bats
  # setup; same symlink-to-scripts pattern).
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

set_framework() {
  export LORE_FRAMEWORK="$1"
  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":2,"tui_launch_framework":"$1","capability_overrides":{},"routes":{"default":"claude-code/sonnet"},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"sonnet","lead":"opus","worker":"sonnet"}},"opencode":{"args":[],"native_models":{"default":"anthropic/sonnet","lead":"anthropic/opus","worker":"openai/gpt-4o"}},"codex":{"args":[],"native_models":{"default":"gpt-5.5","lead":"gpt-5.5","worker":"gpt-5.5"}}}}
EOF
}

# Multi-provider variant: writes role bindings using `provider/model`
# syntax so the opencode adapter can exercise its split_provider_model
# helper. Only meaningful when the framework's model_routing.shape=multi.
set_framework_multi() {
  export LORE_FRAMEWORK="$1"
  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":2,"tui_launch_framework":"$1","capability_overrides":{},"routes":{"default":"opencode/anthropic/sonnet","lead":"opencode/anthropic/opus","worker":"opencode/openai/gpt-4o"},"harnesses":{"claude-code":{"args":[],"native_models":{"default":"sonnet"}},"opencode":{"args":[],"native_models":{"default":"anthropic/sonnet"}},"codex":{"args":[],"native_models":{"default":"gpt-5.5"}}}}
EOF
}

guidance_prompt() {
  bash "$REPO_DIR/scripts/render-dispatch-guidance.sh"
  printf '\nTask-specific prompt.\n'
}

# ============================================================
# Closed-set invariant — README is the source of truth
# ============================================================

@test "README declares exactly the seven adapter operations" {
  EXPECTED_OPS="${AGENT_OPERATIONS[*]}" \
  README_PATH="$AGENTS_README" \
  run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["README_PATH"]).read()
m = re.search(r"## Operation Surface \(Closed Set\)(.*?)## Capability Gates Per Operation", text, re.S)
if not m:
    print("could not locate Operation Surface section in README"); sys.exit(2)
section = m.group(1)
ops = re.findall(r"^\| `([a-z_]+)`\s*\|", section, re.M)
expected = sorted(os.environ["EXPECTED_OPS"].split())
got = sorted(set(ops))
if got != expected:
    print("README operations:", got)
    print("expected:         ", expected)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# claude-code orchestration adapter (T33 reference impl)
# ============================================================

@test "claude-code agent adapter exposes a smoke entrypoint" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ "claude-code" ]]
}

@test "claude-code agent adapter accepts --smoke flag form" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ "claude-code" ]]
}

@test "claude-code agent smoke advertises every adapter operation" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for op in "${AGENT_OPERATIONS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${op}([[:space:]]|$)" <<<"$output"; then
      echo "claude-code smoke missing op: $op"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "claude-code agent smoke reports completion_enforcement=native_blocking" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ native_blocking ]]
}

@test "claude-code agent completion_enforcement subcommand prints native_blocking" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" completion_enforcement
  [ "$status" -eq 0 ]
  [ "$output" = "native_blocking" ]
}

@test "claude-code agent smoke fails fast when active framework is not claude-code" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework opencode
  run bash "$CC_AGENT_ADAPTER" smoke
  [ "$status" -ne 0 ]
  [[ "$output" =~ claude-code ]]
}

@test "claude-code agent adapter source uses stable ~/.lore/scripts/ paths" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  # Reject `$(pwd)/scripts/` and repo-absolute references; embedded
  # script paths in a hook command MUST resolve via the symlink chain
  # at ~/.lore/scripts/<name>, mirroring the T24 hook checklist item 6.
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|/work/.*/scripts/[a-z_-]+\.(sh|py)|\$LORE_DATA_DIR/scripts/[a-z_-]+\.(sh|py))' "$CC_AGENT_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "claude-code agent adapter contains non-stable script paths:"
    echo "$bad_lines"
    return 1
  fi
}

@test "claude-code agent spawn delegates to TaskCreate with resolved model" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" spawn worker "$(guidance_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ model=sonnet ]]
}

@test "claude-code agent spawn honors per-call model override" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" spawn lead "$(guidance_prompt)" haiku
  [ "$status" -eq 0 ]
  [[ "$output" =~ "model=haiku" ]]
}

# ============================================================
# opencode orchestration adapter (T39)
# ============================================================

@test "opencode agent adapter exposes a smoke entrypoint" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ opencode ]]
}

@test "opencode agent adapter accepts --smoke flag form" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ opencode ]]
}

@test "opencode agent smoke advertises every adapter operation" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for op in "${AGENT_OPERATIONS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${op}([[:space:]]|$)" <<<"$output"; then
      echo "opencode smoke missing op: $op"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "opencode agent smoke reports completion_enforcement=lead_validator" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ lead_validator ]]
}

@test "opencode agent completion_enforcement subcommand prints lead_validator" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" completion_enforcement
  [ "$status" -eq 0 ]
  [ "$output" = "lead_validator" ]
}

@test "opencode agent send_message returns unsupported (no team_messaging)" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  # Capture stdout only — the adapter writes a degraded notice to
  # stderr in addition to the `unsupported` literal on stdout.
  output=$(bash "$OC_AGENT_ADAPTER" send_message handle1 "body" 2>/dev/null)
  [ "$output" = "unsupported" ]
}

@test "opencode agent spawn splits provider/model bindings" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework_multi opencode
  run bash "$OC_AGENT_ADAPTER" spawn lead "$(guidance_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=lead ]]
  [[ "$output" =~ provider=anthropic ]]
  [[ "$output" =~ model=opus ]]
}

@test "opencode route_flags preserves provider/model as one argv value" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  run bash "$OC_AGENT_ADAPTER" route_flags '{"framework":"opencode","model":"anthropic/sonnet","options":{}}'
  [ "$status" -eq 0 ]
  [ "$output" = '["--model","anthropic/sonnet"]' ]
}

@test "opencode agent spawn fails fast when active framework is not opencode" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework claude-code
  run bash "$OC_AGENT_ADAPTER" spawn worker "task"
  [ "$status" -ne 0 ]
  [[ "$output" =~ opencode ]]
}

@test "opencode agent shutdown emits TaskUpdate completion directive" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" shutdown handle1
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskUpdate ]]
  [[ "$output" =~ task_id=handle1 ]]
  [[ "$output" =~ status=completed ]]
}

@test "opencode agent adapter source uses stable ~/.lore/scripts/ paths" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|/work/.*/scripts/[a-z_-]+\.(sh|py)|\$LORE_DATA_DIR/scripts/[a-z_-]+\.(sh|py))' "$OC_AGENT_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "opencode agent adapter contains non-stable script paths:"
    echo "$bad_lines"
    return 1
  fi
}

# ============================================================
# codex orchestration adapter (T40)
# ============================================================

@test "codex agent adapter exposes a smoke entrypoint" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ codex ]]
}

@test "codex agent adapter accepts --smoke flag form" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ codex ]]
}

@test "codex agent smoke advertises every adapter operation" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for op in "${AGENT_OPERATIONS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${op}([[:space:]]|$)" <<<"$output"; then
      echo "codex smoke missing op: $op"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "codex agent smoke reports completion_enforcement=lead_validator" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ lead_validator ]]
}

@test "codex agent completion_enforcement subcommand prints lead_validator" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" completion_enforcement
  [ "$status" -eq 0 ]
  [ "$output" = "lead_validator" ]
}

@test "codex agent send_message returns unsupported (no team_messaging)" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  output=$(bash "$CODEX_AGENT_ADAPTER" send_message handle1 "body" 2>/dev/null)
  [ "$output" = "unsupported" ]
}

@test "codex agent spawn emits bare model directive (single-provider)" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" spawn worker "$(guidance_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ "model=sonnet" ]]
  # Single-provider harness MUST NOT emit a provider= key.
  if [[ "$output" =~ provider= ]]; then
    echo "codex spawn leaked provider= key on single-provider harness: $output"
    return 1
  fi
}

@test "codex agent spawn splits reasoning-effort model suffix" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" spawn worker "$(guidance_prompt)" "gpt-5.5-high"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ "model=gpt-5.5" ]]
  [[ "$output" =~ "reasoning_effort=high" ]]
  if [[ "$output" =~ provider= ]]; then
    echo "codex spawn leaked provider= key on single-provider harness: $output"
    return 1
  fi
}

@test "codex agent spawn rejects provider/model override (validates binding)" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" spawn lead "$(guidance_prompt)" "anthropic/opus"
  [ "$status" -ne 0 ]
}

@test "codex route_flags emits model effort and fast tier as exact argv" {
  run bash "$CODEX_AGENT_ADAPTER" route_flags '{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high","service_tier":"fast"}}'
  [ "$status" -eq 0 ]
  [ "$output" = '["-m","gpt-5.6-sol","-c","model_reasoning_effort=\"high\"","-c","service_tier=\"fast\""]' ]
}

@test "codex native_selection accepts canonical route and preserves effort" {
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" native_selection ignored.md attempt-1 '{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high"}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tool_input.model' <<<"$output")" = "gpt-5.6-sol" ]
  [ "$(jq -r '.tool_input.reasoning_effort' <<<"$output")" = "high" ]
}

@test "native_tool_fields projects canonical routes without artifact registration" {
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" native_tool_fields '{"framework":"claude-code","model":"opus","options":{},"routing_source":{"layer":"routes","role":"worker"}}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"model":"opus"}' ]

  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" native_tool_fields '{"framework":"codex","model":"gpt-5.6-sol","options":{"effort":"high"},"routing_source":{"layer":"routes","role":"worker"}}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"model":"gpt-5.6-sol","reasoning_effort":"high"}' ]
}

@test "native_tool_fields refuses malformed foreign and unsupported routes" {
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" native_tool_fields '{"framework":"claude-code","model":"opus","options":{}}'
  [ "$status" -ne 0 ]
  [[ "$output" =~ framework ]]
  run bash "$CODEX_AGENT_ADAPTER" native_tool_fields '{"framework":"codex","model":"gpt-5.6-sol","options":{"service_tier":"fast"}}'
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unsupported native-option: service_tier" ]]
  run bash "$CODEX_AGENT_ADAPTER" native_tool_fields '{"framework":"codex","model":"gpt","options":{"unknown":"x"}}'
  [ "$status" -ne 0 ]

  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" native_tool_fields '{"framework":"claude-code","model":"opus","options":{"effort":"high"}}'
  [ "$status" -ne 0 ]

  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" native_tool_fields '{"framework":"opencode","model":"anthropic/opus","options":{}}'
  [ "$status" -ne 0 ]
  [[ "$output" =~ unavailable ]]
}

@test "codex native_selection parses legacy effort shorthand canonically" {
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" native_selection ignored.md attempt-1 gpt-5.5-high
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tool_input.model' <<<"$output")" = "gpt-5.5" ]
  [ "$(jq -r '.tool_input.reasoning_effort' <<<"$output")" = "high" ]
}

@test "codex native_selection rejects foreign routes and unsupported service tier" {
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" native_selection ignored.md attempt-1 '{"framework":"claude-code","model":"opus","options":{}}'
  [ "$status" -ne 0 ]
  run bash "$CODEX_AGENT_ADAPTER" native_selection ignored.md attempt-1 '{"framework":"codex","model":"gpt-5.6-sol","options":{"service_tier":"fast"}}'
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unsupported native-option: service_tier" ]]
}

@test "claude native_selection accepts canonical and legacy routes while OpenCode remains unavailable" {
  local artifact="$TEST_LORE_DATA_DIR/native.md"
  printf '%s\n' '---' 'name: fixture' 'description: fixture' 'tools: Read' '---' 'prompt' > "$artifact"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" native_selection "$artifact" attempt-1 '{"framework":"claude-code","model":"opus","options":{}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tool_input.model' <<<"$output")" = opus ]
  run bash "$CC_AGENT_ADAPTER" native_selection "$artifact" attempt-2 sonnet
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tool_input.model' <<<"$output")" = sonnet ]
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" native_selection "$artifact" attempt-3 '{"framework":"opencode","model":"anthropic/opus","options":{}}'
  [ "$status" -ne 0 ]
  [[ "$output" =~ unavailable ]]
}

@test "codex agent spawn fails fast when active framework is not codex" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework opencode
  run bash "$CODEX_AGENT_ADAPTER" spawn worker "task"
  [ "$status" -ne 0 ]
  [[ "$output" =~ codex ]]
}

@test "codex agent shutdown emits TaskUpdate completion directive" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" shutdown handle1
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskUpdate ]]
  [[ "$output" =~ task_id=handle1 ]]
  [[ "$output" =~ status=completed ]]
}

@test "codex agent adapter source uses stable ~/.lore/scripts/ paths" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|/work/.*/scripts/[a-z_-]+\.(sh|py)|\$LORE_DATA_DIR/scripts/[a-z_-]+\.(sh|py))' "$CODEX_AGENT_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "codex agent adapter contains non-stable script paths:"
    echo "$bad_lines"
    return 1
  fi
}
