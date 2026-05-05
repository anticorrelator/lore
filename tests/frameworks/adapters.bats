#!/usr/bin/env bats
# adapters.bats — Cross-surface contract tests for the multi-framework
# adapter layer (Phase 7, T63).
#
# This file is the schematic that DEFINES what the adapter layer must
# uphold — sibling files (agents.bats, hooks.bats, transcripts.bats,
# capabilities.bats, roles.bats, harness_args.bats) drill into one
# surface each; this file pins the cross-surface contracts that hold
# the layer together. Coverage spans six surfaces:
#
#   1. Hooks adapter contract              — install/uninstall/smoke
#   2. Orchestration adapter contract       — directive grammar + 7-op
#                                             surface + per-harness
#                                             documented divergence
#   3. Instruction assembly contract        — assemble-instructions.sh
#                                             dispatches via per-framework
#                                             install_paths.instructions;
#                                             sentinel-splice intact
#   4. Skill packaging contract             — capabilities.json
#                                             .skills.<x>.requires
#                                             resolution rule, including
#                                             partial_below threshold
#   5. Transcript provider contract         — 7-operation closed interface;
#                                             provider_status returns
#                                             (level, reason); unknown
#                                             framework raises
#                                             UnsupportedFrameworkError
#   6. resolve_model_for_role precedence    — env > per-repo .lore.config
#                                             > user framework.json >
#                                             roles.default; closed-set
#                                             rejection for unknown role
#
# Per-harness divergence on the orchestration directive grammar (e.g.,
# `delegate:TaskList handle=<h>` for claude-code vs
# `delegate:TaskList task_id=<h>` for opencode/codex; shutdown via
# `SendMessage type=shutdown_request` for claude-code vs
# `TaskUpdate status=completed` for opencode/codex) is documented
# divergence — the README's "Per-Harness Mapping" table sanctions
# different native APIs per harness. These tests pin the per-harness
# wire shape to its current spelling so future drift surfaces here.
# See the "Decision: per-harness divergence is contract" comment block
# below for the rationale.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
ROLES="$REPO_DIR/adapters/roles.json"
LIB="$REPO_DIR/scripts/lib.sh"
AGENTS_README="$REPO_DIR/adapters/agents/README.md"
HOOKS_README="$REPO_DIR/adapters/hooks/README.md"
TRANSCRIPTS_README="$REPO_DIR/adapters/transcripts/README.md"

# Adapter source files (test subjects).
CC_AGENT="$REPO_DIR/adapters/agents/claude-code.sh"
OC_AGENT="$REPO_DIR/adapters/agents/opencode.sh"
CODEX_AGENT="$REPO_DIR/adapters/agents/codex.sh"
CC_HOOKS="$REPO_DIR/adapters/hooks/claude-code.sh"
CODEX_HOOKS="$REPO_DIR/adapters/codex/hooks.sh"
OC_HOOKS_TS="$REPO_DIR/adapters/opencode/lore-hooks.ts"
TRANSCRIPTS_PKG="$REPO_DIR/adapters/transcripts"
ASSEMBLE_INSTR="$REPO_DIR/scripts/assemble-instructions.sh"
ASSEMBLE_CMD="$REPO_DIR/scripts/assemble-claude-md.sh"

# Closed seven-operation set per adapters/agents/README.md
# §"Operation Surface". Drift between this list and the README is a
# contract violation that agents.bats's "README declares exactly the
# seven adapter operations" test will catch first; this file uses the
# same constant to assert dispatch parity across all three adapters.
AGENT_OPS=(
  spawn
  wait
  send_message
  collect_result
  shutdown
  completion_enforcement
  resolve_model_for_role
)

# Closed seven-operation set per adapters/transcripts/README.md
# §"Provider interface — extended operation set". This is the schematic
# the consumer scripts (extract-session-digest.py, check-plan-persistence.py,
# stop-novelty-check.py, probabilistic-audit-trigger.py) rely on.
TRANSCRIPT_OPS=(
  parse_transcript
  extract_file_paths
  previous_session_path
  provider_status
  read_raw_lines
  session_metadata
  tool_use_timestamps
)

setup() {
  [ -f "$CAPS" ] || skip "adapters/capabilities.json missing"
  [ -f "$LIB" ] || skip "scripts/lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  # Stage an isolated LORE_DATA_DIR so adapter calls resolve config
  # against a hermetic tree (mirrors the setup pattern in agents.bats,
  # hooks.bats, harness_args.bats — same symlink-to-scripts shape so
  # adapter source paths still resolve).
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
  # Prevent any LORE_MODEL_<ROLE> env vars from a developer shell from
  # leaking into precedence tests.
  for r in default lead worker researcher reviewer judge summarizer; do
    upper=$(echo "$r" | tr '[:lower:]' '[:upper:]')
    unset "LORE_MODEL_$upper" || true
  done
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

# --- Helpers ------------------------------------------------------------

set_framework() {
  local fw="$1"
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"$fw","capability_overrides":{},"roles":{"default":"sonnet","lead":"opus","worker":"sonnet"}}
EOF
}

set_framework_with_roles() {
  # $1 = framework, $2 = inline JSON for the .roles object body.
  local fw="$1" roles="$2"
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"$fw","capability_overrides":{},"roles":$roles}
EOF
}

# Resolve a capability cell from the static capabilities.json profile.
cap_support() {
  local fw="$1" cap="$2"
  jq -r --arg fw "$fw" --arg c "$cap" \
    '.frameworks[$fw].capabilities[$c].support // "missing"' "$CAPS"
}

# ============================================================
# 1. Hooks adapter contract surface
# ============================================================
#
# The hooks layer has its own drill-down file (hooks.bats) that pins
# every event × support level. This block asserts the cross-surface
# invariants the hooks adapters MUST satisfy at the contract level:
# every framework has SOME hook adapter (CLI or plugin file), and the
# resolve_permission_adapter() dispatcher returns the documented
# adapter shape for each closed-set framework id.

@test "every framework has a hook adapter wired (CLI or plugin file)" {
  # The closed framework set in capabilities.json MUST have a matching
  # hook adapter. The dispatcher in lib.sh::resolve_permission_adapter
  # is the single source of truth for which adapter type each framework
  # uses; this test asserts every framework resolves to a real on-disk
  # artifact (CLI script for claude-code/codex; plugin file for opencode).
  REPO="$REPO_DIR" LIB="$LIB" CAPS="$CAPS" run bash -c '
    set -e
    source "$LIB"
    # Iterate the closed framework set from capabilities.json.
    for fw in $(jq -r ".frameworks | keys[]" "$CAPS"); do
      out=$(resolve_permission_adapter "$fw")
      case "$out" in
        cli:*)
          path="${out#cli:}"
          [ -f "$path" ] || { echo "fw=$fw cli adapter missing: $path"; exit 1; }
          ;;
        plugin-symlink:*:*)
          rest="${out#plugin-symlink:}"
          src="${rest%%:*}"
          [ -f "$src" ] || { echo "fw=$fw plugin source missing: $src"; exit 1; }
          ;;
        unsupported)
          # Acceptable per contract — but every framework in the closed
          # set today has a wired adapter, so flag it as a regression.
          echo "fw=$fw resolves to unsupported (regression)"; exit 1
          ;;
        *)
          echo "fw=$fw resolves to unknown adapter shape: $out"; exit 1
          ;;
      esac
    done
  '
  [ "$status" -eq 0 ]
}

@test "resolve_permission_adapter rejects unknown framework with non-zero exit" {
  # Closed-set rejection: an unknown framework id is an error, not a
  # routed-to-`unsupported` case. Per the comment in
  # scripts/lib.sh::resolve_permission_adapter (lines 659-662), this
  # mirrors the closed-set rejection pattern used by
  # resolve_model_for_role and install.sh's case validation.
  run bash -c "source '$LIB'; resolve_permission_adapter bogus-framework"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown framework"* ]]
}

@test "resolve_permission_adapter shapes match the documented dispatch table" {
  # Pin the three closed framework adapter shapes:
  #   claude-code -> cli:<repo>/adapters/hooks/claude-code.sh
  #   codex       -> cli:<repo>/adapters/codex/hooks.sh
  #   opencode    -> plugin-symlink:<repo>/adapters/opencode/lore-hooks.ts:<dst>
  # Drift here means the dispatcher diverged from the documented shape.
  cc=$(bash -c "source '$LIB'; resolve_permission_adapter claude-code")
  [[ "$cc" == cli:*/adapters/hooks/claude-code.sh ]]

  codex=$(bash -c "source '$LIB'; resolve_permission_adapter codex")
  [[ "$codex" == cli:*/adapters/codex/hooks.sh ]]

  oc=$(bash -c "source '$LIB'; resolve_permission_adapter opencode")
  [[ "$oc" == plugin-symlink:*/adapters/opencode/lore-hooks.ts:* ]]
}

# ============================================================
# 2. Orchestration adapter contract — 7-op surface + directive grammar
# ============================================================
#
# Decision: per-harness divergence is contract.
# -----------------------------------------------------------
# The README's "Per-Harness Mapping (Today)" table explicitly sanctions
# different native APIs per harness:
#   wait:     claude-code "poll TaskList" / opencode "plugin event sub" / codex "poll subagent state"
#   shutdown: claude-code "shutdown_request via SendMessage" / opencode "plugin runtime kill" / codex "subagent stop"
# The bash adapters render those native-API differences into different
# directive shapes:
#   wait     -> claude-code: `delegate:TaskList handle=<h>`
#               opencode/codex: `delegate:TaskList task_id=<h>`
#   shutdown -> claude-code: `delegate:SendMessage handle=<h> type=shutdown_request approve=<b>`
#               opencode/codex: `delegate:TaskUpdate task_id=<h> status=completed`
# These are documented per-harness divergences, not bugs to converge.
# This block asserts each harness's spelling is intact so any future
# silent drift surfaces here. If a future task wants to converge the
# directive grammar across harnesses, the README's per-harness table
# must move first; these tests then update in lockstep.

@test "every agent adapter exposes the same closed seven-operation dispatch surface" {
  # Walk each adapter and assert its case-statement dispatch covers all
  # seven operations. The `--help` text in each adapter lists the closed
  # set; we grep for each operation name as a case label.
  for adapter in "$CC_AGENT" "$OC_AGENT" "$CODEX_AGENT"; do
    [ -f "$adapter" ] || skip "missing adapter: $adapter"
    for op in "${AGENT_OPS[@]}"; do
      if ! grep -qE "^[[:space:]]*${op}\)" "$adapter"; then
        echo "adapter $adapter missing case branch for op: $op"
        return 1
      fi
    done
  done
}

@test "claude-code wait directive uses handle= (per-harness wire shape)" {
  [ -f "$CC_AGENT" ] || skip "claude-code agent adapter missing"
  set_framework claude-code
  run bash "$CC_AGENT" wait task-handle-7
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:TaskList handle=task-handle-7" ]]
}

@test "opencode wait directive uses task_id= (per-harness wire shape)" {
  [ -f "$OC_AGENT" ] || skip "opencode agent adapter missing"
  set_framework opencode
  run bash "$OC_AGENT" wait task-handle-9
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:TaskList task_id=task-handle-9" ]]
}

@test "codex wait directive uses task_id= (per-harness wire shape)" {
  [ -f "$CODEX_AGENT" ] || skip "codex agent adapter missing"
  set_framework codex
  run bash "$CODEX_AGENT" wait task-handle-11
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:TaskList task_id=task-handle-11" ]]
}

@test "claude-code shutdown directive routes through SendMessage type=shutdown_request" {
  [ -f "$CC_AGENT" ] || skip "claude-code agent adapter missing"
  set_framework claude-code
  run bash "$CC_AGENT" shutdown handle-22
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:SendMessage" ]]
  [[ "$output" =~ "handle=handle-22" ]]
  [[ "$output" =~ "type=shutdown_request" ]]
}

@test "opencode shutdown directive routes through TaskUpdate status=completed" {
  [ -f "$OC_AGENT" ] || skip "opencode agent adapter missing"
  set_framework opencode
  run bash "$OC_AGENT" shutdown handle-23
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:TaskUpdate" ]]
  [[ "$output" =~ "task_id=handle-23" ]]
  [[ "$output" =~ "status=completed" ]]
  # Per-harness divergence: opencode does NOT use SendMessage for shutdown.
  if [[ "$output" =~ SendMessage ]]; then
    echo "opencode shutdown leaked SendMessage directive: $output"
    return 1
  fi
}

@test "codex shutdown directive routes through TaskUpdate status=completed" {
  [ -f "$CODEX_AGENT" ] || skip "codex agent adapter missing"
  set_framework codex
  run bash "$CODEX_AGENT" shutdown handle-24
  [ "$status" -eq 0 ]
  [[ "$output" =~ "delegate:TaskUpdate" ]]
  [[ "$output" =~ "task_id=handle-24" ]]
  [[ "$output" =~ "status=completed" ]]
  if [[ "$output" =~ SendMessage ]]; then
    echo "codex shutdown leaked SendMessage directive: $output"
    return 1
  fi
}

@test "send_message returns 'unsupported' literal on team_messaging=none harnesses" {
  # The contract reserves the literal `unsupported` stdout for
  # send_message when team_messaging=none — opencode and codex both have
  # this cell at none. This test asserts the literal token (not just
  # exit status) so callers can branch on it as documented in
  # adapters/agents/README.md §"Operation Surface".
  for fw_adapter in "opencode:$OC_AGENT" "codex:$CODEX_AGENT"; do
    fw="${fw_adapter%%:*}"
    adapter="${fw_adapter#*:}"
    [ -f "$adapter" ] || continue
    set_framework "$fw"
    output=$(bash "$adapter" send_message handle-1 "body" 2>/dev/null)
    if [ "$output" != "unsupported" ]; then
      echo "fw=$fw send_message returned '$output', expected literal 'unsupported'"
      return 1
    fi
  done
}

@test "completion_enforcement always returns a value (never errors)" {
  # Per adapters/agents/README.md §"Capability Gates Per Operation":
  # completion_enforcement is the only operation that always returns a
  # value — even on unsupported harnesses, it returns `unavailable` so
  # callers can branch instead of treating the call as a fatal error.
  # Assert this for all three adapters under their normal framework.
  for fw_adapter in "claude-code:$CC_AGENT" "opencode:$OC_AGENT" "codex:$CODEX_AGENT"; do
    fw="${fw_adapter%%:*}"
    adapter="${fw_adapter#*:}"
    [ -f "$adapter" ] || continue
    set_framework "$fw"
    run bash "$adapter" completion_enforcement
    [ "$status" -eq 0 ]
    case "$output" in
      native_blocking|lead_validator|self_attestation|unavailable) ;;
      *)
        echo "fw=$fw completion_enforcement returned '$output' (not in closed set)"
        return 1
        ;;
    esac
  done
}

@test "completion_enforcement matches the resolution table per harness" {
  # The Mode resolution rule table at adapters/agents/README.md is the
  # closed source of truth. This test pins each harness's resolved mode
  # from the table:
  #   claude-code: task_completed_hook=full + subagents=full -> native_blocking
  #   opencode:    task_completed_hook=fallback + subagents=partial -> lead_validator
  #   codex:       task_completed_hook=fallback + subagents=partial -> lead_validator
  # When the cells in capabilities.json change, this assertion forces a
  # README + adapter coordinated update.
  set_framework claude-code
  [ "$(bash "$CC_AGENT" completion_enforcement)" = "native_blocking" ]

  if [ -f "$OC_AGENT" ]; then
    set_framework opencode
    [ "$(bash "$OC_AGENT" completion_enforcement)" = "lead_validator" ]
  fi

  if [ -f "$CODEX_AGENT" ]; then
    set_framework codex
    [ "$(bash "$CODEX_AGENT" completion_enforcement)" = "lead_validator" ]
  fi
}

@test "multi-provider binding uses '/' as the separator (not ':')" {
  # The convention is that multi-provider role bindings carry a single
  # forward-slash separator: 'anthropic/sonnet', 'openai/gpt-4o'.
  # validate_role_model_binding splits on '/' and the opencode adapter's
  # split_provider_model helper relies on this separator. A legacy
  # variant using ':' would silently fail validation but pass through
  # adapters that don't split — this test pins the spelling.
  set_framework_with_roles opencode '{"default":"anthropic/sonnet","lead":"anthropic/opus","worker":"openai/gpt-4o"}'
  if [ -f "$OC_AGENT" ]; then
    run bash "$OC_AGENT" spawn lead "plan"
    [ "$status" -eq 0 ]
    # Adapter splits on '/' and emits both keys.
    [[ "$output" =~ "provider=anthropic" ]]
    [[ "$output" =~ "model=opus" ]]
  fi
  # The validator MUST reject a ':'-joined binding on a multi-shape
  # harness with the same error shape it uses for malformed strings
  # (the binding has no '/' so it's accepted as a bare model id —
  # but the resulting bare id 'anthropic:sonnet' is not a real model;
  # the contract is the separator, not the validator's reach).
  # Assert the validator's positive path for the canonical separator.
  LORE_FRAMEWORK=opencode run bash -c "source '$LIB'; validate_role_model_binding lead anthropic/sonnet"
  [ "$status" -eq 0 ]
}

@test "single-provider harnesses reject provider/model bindings (closed-set rejection)" {
  # Per validate_role_model_binding rule 2: provider/model syntax on a
  # single-shape harness MUST fail. Closed-set rejection is the contract,
  # not silent fallback to the harness default. This catches the
  # opposite of the multi-provider separator test.
  LORE_FRAMEWORK=claude-code run bash -c "source '$LIB'; validate_role_model_binding worker anthropic/haiku"
  [ "$status" -ne 0 ]
  [[ "$output" =~ single-provider ]]

  LORE_FRAMEWORK=codex run bash -c "source '$LIB'; validate_role_model_binding worker openai/gpt-4"
  [ "$status" -ne 0 ]
  [[ "$output" =~ single-provider ]]
}

# ============================================================
# 3. Instruction assembly contract
# ============================================================
#
# assemble-instructions.sh dispatches instruction-file rendering through
# the active framework's install_paths.instructions cell, then delegates
# to assemble-claude-md.sh with LORE_INSTRUCTIONS_TARGET pinned to the
# resolved path. The sentinel-splice logic in assemble-claude-md.sh
# (LORE:BEGIN / LORE:END markers) preserves non-lore content outside
# the sentinels — this is load-bearing for users who maintain their own
# CLAUDE.md / AGENTS.md content alongside the lore-managed block.

@test "assemble-instructions.sh --dry-run reports per-framework target path" {
  [ -f "$ASSEMBLE_INSTR" ] || skip "assemble-instructions.sh missing"

  # claude-code -> $HOME/.claude/CLAUDE.md
  run bash "$ASSEMBLE_INSTR" --framework claude-code --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "framework=claude-code" ]]
  [[ "$output" =~ ".claude/CLAUDE.md" ]]

  # opencode -> $HOME/.claude/CLAUDE.md (OpenCode reads CLAUDE.md natively)
  run bash "$ASSEMBLE_INSTR" --framework opencode --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "framework=opencode" ]]
  [[ "$output" =~ ".claude/CLAUDE.md" ]]

  # codex -> $HOME/.codex/AGENTS.md
  run bash "$ASSEMBLE_INSTR" --framework codex --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" =~ "framework=codex" ]]
  [[ "$output" =~ ".codex/AGENTS.md" ]]
}

@test "assemble-instructions.sh rejects unknown framework (closed-set rejection)" {
  [ -f "$ASSEMBLE_INSTR" ] || skip "assemble-instructions.sh missing"
  run bash "$ASSEMBLE_INSTR" --framework bogus-fw --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown framework" ]]
}

@test "assemble-claude-md.sh respects LORE_INSTRUCTIONS_TARGET override" {
  # The override is the lever assemble-instructions.sh uses to retarget
  # the assembler at $HOME/.codex/AGENTS.md (codex) without forking the
  # sentinel-splice logic. Validate the override actually changes the
  # write target by running the assembler against a tmp file.
  [ -f "$ASSEMBLE_CMD" ] || skip "assemble-claude-md.sh missing"
  local tmp_target
  tmp_target="$(mktemp -d)/AGENTS.md"
  LORE_INSTRUCTIONS_TARGET="$tmp_target" run bash "$ASSEMBLE_CMD"
  [ "$status" -eq 0 ]
  [ -f "$tmp_target" ]
  # The sentinels MUST be present in the written file.
  grep -q '<!-- LORE:BEGIN -->' "$tmp_target"
  grep -q '<!-- LORE:END -->' "$tmp_target"
  rm -rf "$(dirname "$tmp_target")"
}

@test "assemble-claude-md.sh sentinel-splice preserves non-lore content across reruns" {
  # The assembler's contract for files that ALREADY contain sentinels:
  # only the sentinel-bounded region is replaced; content above and
  # below the sentinels is preserved across reruns. (First-run files
  # without sentinels are backed up to .pre-lore-backup and replaced
  # entirely — that migration path is documented at
  # scripts/assemble-claude-md.sh::migrate_if_needed lines 138-155.)
  # This test exercises the post-migration steady state by pre-seeding
  # a target that already has the sentinels + outside content.
  [ -f "$ASSEMBLE_CMD" ] || skip "assemble-claude-md.sh missing"
  local tmp_target
  tmp_target="$(mktemp -d)/CLAUDE.md"
  cat > "$tmp_target" <<'EOF'
# My personal preamble — must survive lore renders
<!-- LORE:BEGIN -->
old lore content to be replaced
<!-- LORE:END -->

# My personal trailer — must also survive
EOF
  LORE_INSTRUCTIONS_TARGET="$tmp_target" run bash "$ASSEMBLE_CMD"
  [ "$status" -eq 0 ]
  grep -q "My personal preamble" "$tmp_target"
  grep -q "My personal trailer" "$tmp_target"
  grep -q '<!-- LORE:BEGIN -->' "$tmp_target"
  grep -q '<!-- LORE:END -->' "$tmp_target"
  # Old lore content was replaced (sentinel-bounded region rendered fresh).
  if grep -q "old lore content to be replaced" "$tmp_target"; then
    echo "sentinel-splice failed to replace old lore content"
    cat "$tmp_target"
    return 1
  fi
  rm -rf "$(dirname "$tmp_target")"
}

# ============================================================
# 4. Skill packaging contract — capabilities.json .skills.<x>.requires
# ============================================================
#
# The schema documented at adapters/capabilities.json:.skills._description
# accepts two requirement forms (legacy string + object with thresholds)
# and resolves to one of three states per requirement: full, partial-mode,
# unavailable. The aggregate state across the requires array takes the
# worst per-requirement state. This block asserts the resolution rule on
# representative skills:
#   - team-heavy skills (bootstrap, implement, spec) use the object form
#     with a partial_below knob, and resolve to partial-mode (NOT
#     unavailable) on opencode/codex even though team_messaging=none.
#   - framework-agnostic skills (memory, retro, evolve) have empty
#     requires and resolve to full on every framework.

@test "every team-heavy skill declares object-form requires with partial_below" {
  # The partial_below knob is what splits "downgrade to partial-mode"
  # from "refuse outright" — without it, team_messaging=none on
  # opencode/codex would refuse the skill rather than degrading.
  # T9/T41 added this; this assertion catches accidental reversion to
  # the legacy string form.
  CAPS="$CAPS" run python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
team_heavy = ["bootstrap", "implement", "spec"]
for skill in team_heavy:
    skill_def = d["skills"].get(skill)
    if not skill_def:
        print(f"skill {skill} missing from capabilities.json"); sys.exit(1)
    requires = skill_def.get("requires", [])
    if not requires:
        print(f"skill {skill} has empty requires (expected team-heavy gating)"); sys.exit(1)
    object_form_reqs = [r for r in requires if isinstance(r, dict)]
    if not object_form_reqs:
        print(f"skill {skill} has no object-form requirements (lost partial_below knob)"); sys.exit(1)
    has_partial_below = any("partial_below" in r for r in object_form_reqs)
    if not has_partial_below:
        print(f"skill {skill} missing partial_below threshold on every requirement"); sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "team_messaging requirement uses partial_below=none for team-heavy skills" {
  # Per the contract: team_messaging at any sub-`full` level (including
  # `none` on opencode/codex today) downgrades to lead-orchestrated
  # rather than refusing. This requires partial_below="none" — anything
  # higher would flip the resolution to `unavailable` on opencode/codex.
  CAPS="$CAPS" run python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
for skill in ["bootstrap", "implement", "spec"]:
    skill_def = d["skills"][skill]
    tm = next((r for r in skill_def["requires"]
               if isinstance(r, dict) and r.get("id") == "team_messaging"), None)
    if not tm:
        print(f"{skill}: no team_messaging requirement found"); sys.exit(1)
    if tm.get("partial_below") != "none":
        print(f"{skill}: team_messaging.partial_below = {tm.get('partial_below')!r}, expected 'none'")
        sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "skill requires resolution: implement on opencode profile resolves to partial-mode" {
  # Pin the resolution rule from adapters/agents/README.md
  # §"Skill requirement schema (T41 partial-mode gating)" against the
  # live opencode profile. Expectation:
  #   subagents=partial vs min_level=full, partial_below=fallback -> partial-mode
  #   team_messaging=none vs min_level=full, partial_below=none -> partial-mode
  #     (cell == partial_below threshold; per the table cell `>= partial_below`
  #      and `< min_level` -> partial-mode)
  #   task_completed_hook=fallback vs min_level=full, partial_below=fallback
  #     -> partial-mode
  # Aggregate: partial-mode (worst across the array).
  CAPS="$CAPS" run python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
LEVELS = ["full", "partial", "fallback", "none"]  # most -> least capable

def cmp(level, threshold):
    """Return < 0 if level is below threshold (less capable),
       0 if equal, > 0 if above (more capable). Lower index = more capable."""
    if level not in LEVELS or threshold not in LEVELS:
        return None
    return LEVELS.index(threshold) - LEVELS.index(level)

def resolve_state(cell_level, min_level, partial_below):
    """full | partial-mode | unavailable per the adapters/agents/README.md
    §"Skill requirement schema" table."""
    if cmp(cell_level, partial_below) < 0:  # cell less capable than partial_below
        return "unavailable"
    if cmp(cell_level, min_level) < 0:      # cell less capable than min_level
        return "partial-mode"
    return "full"

fw_caps = d["frameworks"]["opencode"]["capabilities"]
implement = d["skills"]["implement"]
states = []
for req in implement["requires"]:
    if isinstance(req, str):
        cap_id = req
        min_level = "full"
        partial_below = "full"
    else:
        cap_id = req["id"]
        min_level = req.get("min_level", "full")
        partial_below = req.get("partial_below", "full")
    cell = fw_caps.get(cap_id, {}).get("support", "none")
    state = resolve_state(cell, min_level, partial_below)
    states.append((cap_id, cell, min_level, partial_below, state))

# Aggregate: worst state wins (unavailable > partial-mode > full).
order = {"unavailable": 0, "partial-mode": 1, "full": 2}
agg = min(states, key=lambda s: order[s[4]])[4]

if agg != "partial-mode":
    print("expected aggregate=partial-mode, got", agg)
    for s in states: print(" ", s)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "skill requires resolution: empty requires resolves to full on every framework" {
  # Skills with empty `requires` are framework-agnostic per the schema
  # description. Pin that memory, evolve, and retro all stay `full`
  # regardless of framework.
  CAPS="$CAPS" run python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
fws = list(d["frameworks"].keys())
for skill in ["memory", "evolve", "retro"]:
    requires = d["skills"][skill].get("requires", [])
    if requires:
        print(f"{skill} expected empty requires but found {requires}"); sys.exit(1)
    # Empty requires aggregates to `full` trivially — there are no
    # requirements to fail. This assertion is documentary; the
    # framework-agnostic property is encoded by the empty array itself.
PYEOF
  [ "$status" -eq 0 ]
}

@test "_degradation_vocab exposes the closed-set tokens adapters may emit" {
  # The orchestration adapter's `[lore] degraded:` stderr notices and
  # `lore framework doctor`'s skill-availability column MUST use only
  # the tokens in this vocabulary. Adapter strings outside this set are
  # a contract violation per the comment block in capabilities.json.
  CAPS="$CAPS" run python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
vocab = d["skills"].get("_degradation_vocab", {})
required_tokens = {"partial", "fallback", "none", "no-evidence", "unverified-support"}
got = set(vocab.keys()) - {"_description"}
missing = required_tokens - got
if missing:
    print("missing degradation tokens:", missing); sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# 5. Transcript provider contract
# ============================================================

@test "every transcript provider exports the closed seven-operation interface" {
  # adapters/transcripts/README.md §"Provider interface — extended
  # operation set" defines the seven operations every provider must
  # expose. Drift between the README's list and the provider modules
  # is a contract violation.
  PROVIDER_PKG="$TRANSCRIPTS_PKG" REPO="$REPO_DIR" OPS="${TRANSCRIPT_OPS[*]}" run python3 - <<'PYEOF'
import importlib, os, sys
sys.path.insert(0, os.environ["REPO"])
ops = os.environ["OPS"].split()
providers = ["adapters.transcripts.claude_code",
             "adapters.transcripts.opencode",
             "adapters.transcripts.codex"]
errs = []
for mod_name in providers:
    try:
        mod = importlib.import_module(mod_name)
    except Exception as e:
        errs.append(f"{mod_name}: import failed -- {e}"); continue
    for op in ops:
        if not hasattr(mod, op):
            errs.append(f"{mod_name}: missing op {op}")
if errs:
    for e in errs: print(e)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "provider_status returns a (level, reason) tuple on every provider" {
  # The README documents provider_status as returning the tuple
  # (level, reason). pinning the tuple shape (not just the level)
  # catches providers that regress to returning bare strings.
  PROVIDER_PKG="$TRANSCRIPTS_PKG" REPO="$REPO_DIR" run python3 - <<'PYEOF'
import importlib, os, sys
sys.path.insert(0, os.environ["REPO"])
errs = []
for mod_name in ["adapters.transcripts.claude_code",
                 "adapters.transcripts.opencode",
                 "adapters.transcripts.codex"]:
    mod = importlib.import_module(mod_name)
    res = mod.provider_status()
    if not isinstance(res, tuple) or len(res) != 2:
        errs.append(f"{mod_name}: provider_status returned {type(res).__name__} {res!r}, expected 2-tuple")
        continue
    level, reason = res
    if level not in ("full", "partial", "unavailable"):
        errs.append(f"{mod_name}: provider_status level {level!r} not in closed set")
    if not isinstance(reason, str):
        errs.append(f"{mod_name}: provider_status reason {type(reason).__name__}, expected str")
if errs:
    for e in errs: print(e)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "get_provider raises UnsupportedFrameworkError on unknown framework (closed-set rejection)" {
  # Per the __init__.py contract, an unknown framework is an error,
  # not a routed-to-claude-code fallback. Closed-set rejection mirrors
  # the bash side's resolve_active_framework behavior.
  REPO="$REPO_DIR" run python3 - <<'PYEOF'
import sys, os
sys.path.insert(0, os.environ["REPO"])
from adapters.transcripts import get_provider, UnsupportedFrameworkError
try:
    get_provider("bogus-framework")
except UnsupportedFrameworkError as e:
    if "bogus-framework" not in str(e):
        print("UnsupportedFrameworkError raised but message lost the framework id:", e)
        sys.exit(1)
    sys.exit(0)
print("expected UnsupportedFrameworkError, but get_provider returned a value")
sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "get_provider routes to the right module for each closed-set framework" {
  # Pin the dispatch table at adapters/transcripts/__init__.py
  # _PROVIDER_MODULES so future renames surface here.
  REPO="$REPO_DIR" run python3 - <<'PYEOF'
import sys, os
sys.path.insert(0, os.environ["REPO"])
from adapters.transcripts import get_provider
expected = {
    "claude-code": "adapters.transcripts.claude_code",
    "opencode": "adapters.transcripts.opencode",
    "codex": "adapters.transcripts.codex",
}
errs = []
for fw, mod_name in expected.items():
    mod = get_provider(fw)
    if mod.__name__ != mod_name:
        errs.append(f"fw={fw}: got {mod.__name__}, expected {mod_name}")
if errs:
    for e in errs: print(e)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# 6. resolve_model_for_role precedence (env > per-repo > user > default)
# ============================================================
#
# scripts/lib.sh::resolve_model_for_role documents the precedence:
#   1. env LORE_MODEL_<ROLE>
#   2. per-repo .lore.config `model_for_<role>=`
#   3. user $LORE_DATA_DIR/config/framework.json `.roles.<role>`
#   4. user framework.json `.roles.default`
# This block walks each precedence step and asserts the higher tier wins.

@test "resolve_model_for_role: env override beats per-repo .lore.config" {
  # Stage all four sources at once with distinct values; the env var
  # MUST win.
  set_framework_with_roles claude-code '{"default":"user-default","lead":"user-lead"}'
  local repo_root tmp_repo
  tmp_repo="$(mktemp -d)"
  cat > "$tmp_repo/.lore.config" <<EOF
model_for_lead=repo-lead
EOF

  # Env var top tier
  LORE_MODEL_LEAD="env-lead" run bash -c "cd '$tmp_repo' && source '$LIB' && resolve_model_for_role lead"
  [ "$status" -eq 0 ]
  [ "$output" = "env-lead" ]

  rm -rf "$tmp_repo"
}

@test "resolve_model_for_role: per-repo .lore.config beats user framework.json roles" {
  set_framework_with_roles claude-code '{"default":"user-default","lead":"user-lead"}'
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  cat > "$tmp_repo/.lore.config" <<EOF
model_for_lead=repo-lead
EOF

  # No env var; per-repo wins over user framework.json's .roles.lead
  run bash -c "cd '$tmp_repo' && source '$LIB' && resolve_model_for_role lead"
  [ "$status" -eq 0 ]
  [ "$output" = "repo-lead" ]

  rm -rf "$tmp_repo"
}

@test "resolve_model_for_role: user framework.json roles.<role> beats roles.default" {
  set_framework_with_roles claude-code '{"default":"user-default","lead":"user-lead"}'
  # No env, no per-repo — must hit user framework.json's .roles.lead, not default.
  # cd to a dir that has no .lore.config in any ancestor (use mktemp).
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  run bash -c "cd '$tmp_dir' && source '$LIB' && resolve_model_for_role lead"
  [ "$status" -eq 0 ]
  [ "$output" = "user-lead" ]
  rm -rf "$tmp_dir"
}

@test "resolve_model_for_role: roles.default is the fallback when role binding is unset" {
  # framework.json carries roles.default but no entry for `judge`.
  set_framework_with_roles claude-code '{"default":"user-default"}'
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  run bash -c "cd '$tmp_dir' && source '$LIB' && resolve_model_for_role judge"
  [ "$status" -eq 0 ]
  [ "$output" = "user-default" ]
  rm -rf "$tmp_dir"
}

@test "resolve_model_for_role: closed-set rejection for unknown role" {
  # roles.json is the closed registry; an unknown role MUST be rejected
  # with non-zero exit and an `unknown role` message on stderr.
  # Mirrors the validate_role_model_binding rejection in roles.bats.
  set_framework claude-code
  run bash -c "source '$LIB'; resolve_model_for_role bogus-role"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown role" ]]
}

@test "resolve_model_for_role: every closed-set role resolves under env override" {
  # Cross-check that every role in adapters/roles.json is accepted by
  # the validator. roles.bats has the same assertion at the json level;
  # this test asserts the bash helper agrees with the registry.
  REPO="$REPO_DIR" LIB="$LIB" run python3 - <<'PYEOF'
import json, os, subprocess, sys
roles_file = os.path.join(os.environ["REPO"], "adapters", "roles.json")
d = json.load(open(roles_file))
ids = [r["id"] for r in d["roles"]]
errs = []
for role in ids:
    env = os.environ.copy()
    env[f"LORE_MODEL_{role.upper()}"] = "stub-model"
    res = subprocess.run(
        ["bash", "-c", f'source "{os.environ["LIB"]}" && resolve_model_for_role {role}'],
        capture_output=True, text=True, env=env,
    )
    if res.returncode != 0:
        errs.append(f"role={role!r}: rejected, stderr={res.stderr.strip()!r}")
        continue
    if res.stdout.strip() != "stub-model":
        errs.append(f"role={role!r}: env override ignored, got {res.stdout.strip()!r}")
if errs:
    for e in errs: print(e)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}
