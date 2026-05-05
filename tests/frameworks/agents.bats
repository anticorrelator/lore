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
  # framework.json without touching the user's real config (mirrors
  # hooks.bats setup; same symlink-to-scripts pattern).
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
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"$1","capability_overrides":{},"roles":{"default":"sonnet","lead":"opus","worker":"sonnet"}}
EOF
}

# Multi-provider variant: writes role bindings using `provider/model`
# syntax so the opencode adapter can exercise its split_provider_model
# helper. Only meaningful when the framework's model_routing.shape=multi.
set_framework_multi() {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"$1","capability_overrides":{},"roles":{"default":"anthropic/sonnet","lead":"anthropic/opus","worker":"openai/gpt-4o"}}
EOF
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
  run bash "$CC_AGENT_ADAPTER" spawn worker "do thing"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ model=sonnet ]]
}

@test "claude-code agent spawn honors per-call model override" {
  [ -f "$CC_AGENT_ADAPTER" ] || skip "adapters/agents/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_AGENT_ADAPTER" spawn lead "plan" haiku
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
  run bash "$OC_AGENT_ADAPTER" spawn lead "plan"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=lead ]]
  [[ "$output" =~ provider=anthropic ]]
  [[ "$output" =~ model=opus ]]
}

@test "opencode agent spawn keeps bare model bindings unsplit" {
  [ -f "$OC_AGENT_ADAPTER" ] || skip "adapters/agents/opencode.sh missing (T39 not landed yet)"
  set_framework opencode
  run bash "$OC_AGENT_ADAPTER" spawn worker "task"
  [ "$status" -eq 0 ]
  [[ "$output" =~ delegate:TaskCreate ]]
  [[ "$output" =~ role=worker ]]
  [[ "$output" =~ "model=sonnet" ]]
  # Bare bindings MUST NOT emit a provider= key.
  if [[ "$output" =~ provider= ]]; then
    echo "bare binding leaked provider= key: $output"
    return 1
  fi
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
  run bash "$CODEX_AGENT_ADAPTER" spawn worker "task"
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

@test "codex agent spawn rejects provider/model override (validates binding)" {
  [ -f "$CODEX_AGENT_ADAPTER" ] || skip "adapters/agents/codex.sh missing (T40 not landed yet)"
  set_framework codex
  run bash "$CODEX_AGENT_ADAPTER" spawn lead "plan" "anthropic/opus"
  [ "$status" -ne 0 ]
  # validate_role_model_binding emits the explanatory error on stderr;
  # bats `run` merges streams, so the message appears in $output.
  [[ "$output" =~ provider ]] || [[ "$output" =~ single ]]
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
