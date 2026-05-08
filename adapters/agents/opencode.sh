#!/usr/bin/env bash
# adapters/agents/opencode.sh — OpenCode orchestration adapter (T39).
#
# Implements the seven-operation contract documented in
# adapters/agents/README.md (T31, T32) for OpenCode. The adapter shares
# claude-code.sh's "delegate directive" wire shape (committed in
# notes.md 2026-05-04T08:05) — bash physically cannot drive the LLM
# tool API on any harness, so for tool-mediated ops the adapter emits a
# single-line `delegate:<ToolName> <key>=<value> ...` directive on
# stdout that the calling skill consumes. Skills running on OpenCode
# translate the directive ToolName into OpenCode's plugin-runtime
# subagent-spawn primitive (the SDK detail is consumed in T34/T35).
#
# Capability profile (capabilities.json frameworks.opencode.capabilities):
#   subagents=partial — has Primary + General/Explore subagents but no
#                       persistent team state.
#   team_messaging=none — no native TeamCreate/SendMessage primitive;
#                         send_message returns `unsupported` per contract.
#   task_completed_hook=fallback — no native subagent-completion blocking;
#                       completion_enforcement resolves to lead_validator.
#   transcript_provider=partial — session artifacts exist but format
#                       differs from Claude JSONL (T51 stub).
#   model_routing=multi — provider/model bindings are honored and split
#                       at the spawn boundary into provider= / model=
#                       directive keys.
#
# Subcommands match the claude-code.sh closed seven plus a smoke
# entrypoint (`smoke` / `--smoke`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

# --- require_opencode ---
# Refuse to run when active framework != opencode. Mirrors require_claude_code
# in adapters/agents/claude-code.sh — the orchestration adapter is harness-
# specific by construction; a misconfigured caller fails fast.
require_opencode() {
  local active
  active=$(resolve_active_framework 2>/dev/null) || active=""
  if [[ "$active" != "opencode" ]]; then
    echo "Error: adapters/agents/opencode.sh requires active framework=opencode (got '$active')" >&2
    echo "       set LORE_FRAMEWORK=opencode or run install.sh --framework opencode" >&2
    return 1
  fi
}

# --- emit_degraded_notice ---
# Emit a one-line stderr notice when operating under partial/fallback
# capability cells. Matches claude-code.sh's wording so audit channels
# can pattern-match across adapters.
emit_degraded_notice() {
  local op="$1" capability_level="$2" fallback_mech="$3"
  if [[ "$capability_level" == "partial" || "$capability_level" == "fallback" ]]; then
    echo "[lore] degraded: $op via $fallback_mech (capability=$capability_level)" >&2
  fi
}

# --- cap ---
# Pass-through to framework_capability so the override-then-static
# resolution lives in one place (lib.sh, T6).
cap() {
  framework_capability "$1" 2>/dev/null || echo "none"
}

# --- split_provider_model ---
# Multi-provider role bindings use the documented `provider/model`
# syntax (lib.sh::validate_role_model_binding splits on `/`; bats roles
# tests pin this). When the resolved binding contains a slash we emit
# both `provider=<provider>` and `model=<model>` directive keys so the
# skill can pass them separately to OpenCode's plugin-runtime spawn API.
# When the binding is a bare model id (no slash) we emit only `model=<m>`
# and the skill uses OpenCode's default provider for that session.
#
# Outputs (stdout): one or two `key=value` tokens, space-separated.
split_provider_model() {
  local binding="$1"
  if [[ "$binding" == */* ]]; then
    local provider="${binding%%/*}"
    local model="${binding#*/}"
    printf 'provider=%s model=%s' "$provider" "$model"
  else
    printf 'model=%s' "$binding"
  fi
}

# --- cmd_spawn ---
# Spawn a worker. Resolves role -> binding via resolve_model_for_role,
# validates the binding (rejects malformed cross-provider syntax against
# the active framework's model_routing.shape), splits provider/model,
# and emits a `delegate:TaskCreate role=<r> [provider=<p>] model=<m>`
# directive on stdout per the directive grammar.
cmd_spawn() {
  require_opencode
  local role="${1:-}" task_prompt="${2:-}" override_model="${3:-}"
  if [[ -z "$role" || -z "$task_prompt" ]]; then
    echo "Error: spawn requires <role> <task_prompt>" >&2
    return 1
  fi

  local subagents
  subagents=$(cap subagents)
  if [[ "$subagents" == "none" ]]; then
    echo "Error: spawn unavailable — capabilities.json frameworks.opencode.capabilities.subagents=none" >&2
    return 1
  fi
  emit_degraded_notice spawn "$subagents" "opencode plugin-runtime spawn"

  local binding
  if [[ -n "$override_model" ]]; then
    binding="$override_model"
  else
    binding=$(resolve_model_for_role "$role") || return 1
  fi

  if ! validate_role_model_binding "$role" "$binding"; then
    return 1
  fi

  local routing_keys
  routing_keys=$(split_provider_model "$binding")
  echo "delegate:TaskCreate role=$role $routing_keys"
}

# --- cmd_wait ---
# OpenCode subagent state is observable through the plugin runtime; the
# bash adapter emits the delegation directive so the lead skill polls
# via the harness's TaskList equivalent.
cmd_wait() {
  require_opencode
  local handle="${1:-}"
  if [[ -z "$handle" ]]; then
    echo "Error: wait requires <spawn_handle>" >&2
    return 1
  fi
  echo "delegate:TaskList task_id=$handle"
}

# --- cmd_send_message ---
# OpenCode has no native TeamCreate/SendMessage equivalent
# (capabilities.json team_messaging=none, evidence: opencode-team-messaging).
# The contract requires returning the literal `unsupported` so callers can
# branch to lead-only orchestration without invoking a tool that doesn't
# exist on the harness.
cmd_send_message() {
  require_opencode
  local handle="${1:-}" body="${2:-}"
  if [[ -z "$handle" || -z "$body" ]]; then
    echo "Error: send_message requires <spawn_handle> <body>" >&2
    return 1
  fi

  local team_messaging
  team_messaging=$(cap team_messaging)
  if [[ "$team_messaging" == "none" ]]; then
    echo "[lore] degraded: send_message unsupported on opencode (team_messaging=none); skill must run in lead-orchestrated mode" >&2
    echo "unsupported"
    return 0
  fi
  emit_degraded_notice send_message "$team_messaging" "opencode plugin-runtime SendMessage"
  echo "delegate:SendMessage to=$handle"
}

# --- cmd_collect_result ---
# Collect a worker's result via OpenCode's TaskGet equivalent. OpenCode's
# transcript_provider=partial cell means transcript fields may be absent
# in the returned envelope; the directive emission is identical, but the
# adapter logs a degraded notice so the audit channel sees the partial
# attribution.
cmd_collect_result() {
  require_opencode
  local handle="${1:-}"
  if [[ -z "$handle" ]]; then
    echo "Error: collect_result requires <spawn_handle>" >&2
    return 1
  fi

  local transcript
  transcript=$(cap transcript_provider)
  if [[ "$transcript" == "none" ]]; then
    echo "[lore] degraded: collect_result transcript fields omitted (capability=none)" >&2
    echo "delegate:TaskGet task_id=$handle"
    return 0
  fi
  emit_degraded_notice collect_result "$transcript" "opencode TaskGet + transcript stub"
  echo "delegate:TaskGet task_id=$handle"
}

# --- cmd_shutdown ---
# Without team_messaging, OpenCode lacks a SendMessage-based shutdown
# affordance. The plugin runtime exposes a kill primitive — the lead
# skill on OpenCode invokes its TaskUpdate equivalent to mark the task
# complete and stop the subagent.
cmd_shutdown() {
  require_opencode
  local handle="${1:-}" approve="${2:-true}"
  if [[ -z "$handle" ]]; then
    echo "Error: shutdown requires <spawn_handle> [approve=true|false]" >&2
    return 1
  fi
  echo "delegate:TaskUpdate task_id=$handle status=completed"
}

# --- cmd_completion_enforcement ---
# Read-only capability query. opencode resolves to lead_validator today
# (task_completed_hook=fallback + subagents=partial per the table at
# adapters/agents/README.md §Mode resolution rule). Delegates to the
# shared lib.sh helper so bash and Go agree on the table.
cmd_completion_enforcement() {
  require_opencode
  resolve_completion_enforcement_mode
}

# --- cmd_resolve_model_for_role ---
# Pass-through to lib.sh::resolve_model_for_role for callers that prefer
# the unified adapter binary over the helper directly. Output is the
# raw binding (possibly `provider/model`); callers that need the split
# form should invoke `spawn` instead.
cmd_resolve_model_for_role() {
  require_opencode
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "Error: resolve_model_for_role requires <role>" >&2
    return 1
  fi
  resolve_model_for_role "$role"
}

# --- cmd_system_prompt_flag ---
# Print the OpenCode flag spelling for the `append_system_prompt`
# TUI-launch concern (T11). OpenCode has no equivalent CLI flag today
# (per adapters/agents/README.md §TUI Launch Concerns) so the
# tui_launch_flags cell is `unsupported`. Mirrors the Go helper
# config.HarnessSystemPromptFlag.
cmd_system_prompt_flag() {
  require_opencode
  framework_tui_launch_flag append_system_prompt
}

# --- cmd_settings_override_flag ---
# Print the OpenCode flag spelling for the `inline_settings_override`
# TUI-launch concern (T11). OpenCode has no equivalent CLI flag today
# (file-based session config) so the cell is `unsupported`. Callers
# MUST skip the injection rather than substitute a different flag.
cmd_settings_override_flag() {
  require_opencode
  framework_tui_launch_flag inline_settings_override
}

# --- cmd_smoke ---
# Print the operation x support-level matrix for OpenCode. Same shape
# as claude-code.sh smoke but rows reflect OpenCode's actual capability
# cells (mostly partial / fallback, send_message=none).
cmd_smoke() {
  require_opencode
  local subagents team_messaging transcript task_completed routing_shape
  subagents=$(cap subagents)
  team_messaging=$(cap team_messaging)
  transcript=$(cap transcript_provider)
  task_completed=$(cap task_completed_hook)
  routing_shape=$(framework_model_routing_shape 2>/dev/null) || routing_shape="single"

  local mode
  mode=$(resolve_completion_enforcement_mode)

  local model_lead model_worker
  model_lead=$(resolve_model_for_role lead 2>/dev/null) || model_lead="<unresolved>"
  model_worker=$(resolve_model_for_role worker 2>/dev/null) || model_worker="<unresolved>"

  echo "[opencode orchestration adapter smoke]"
  echo "  active framework:        opencode"
  echo "  completion enforcement:  $mode"
  echo "  model routing shape:     $routing_shape"
  echo "  role bindings:           lead=$model_lead worker=$model_worker"
  echo
  echo "  Operation                Support       Native API"
  echo "  ------------------------ ------------- ---------------------------------------"
  printf '  %-24s %-13s %s\n' spawn                  "$subagents"      "plugin-runtime subagent spawn (delegate:TaskCreate)"
  printf '  %-24s %-13s %s\n' wait                   "$subagents"      "plugin-runtime task poll (delegate:TaskList)"
  printf '  %-24s %-13s %s\n' send_message           "$team_messaging" "unsupported (no native TeamCreate/SendMessage; lead-orchestrated)"
  printf '  %-24s %-13s %s\n' collect_result         "$subagents/$transcript" "plugin-runtime collect + transcript stub"
  printf '  %-24s %-13s %s\n' shutdown               "$subagents"      "plugin-runtime kill via delegate:TaskUpdate"
  printf '  %-24s %-13s %s\n' completion_enforcement "$task_completed" "lead-side validator (no native blocking hook)"
  printf '  %-24s %-13s %s\n' resolve_model_for_role "$routing_shape"  "provider/model binding split at spawn boundary"
}

# --- Dispatch ---
cmd="${1:-}"
case "$cmd" in
  spawn)                    shift; cmd_spawn                    "$@" ;;
  wait)                     shift; cmd_wait                     "$@" ;;
  send_message)             shift; cmd_send_message             "$@" ;;
  collect_result)           shift; cmd_collect_result           "$@" ;;
  shutdown)                 shift; cmd_shutdown                 "$@" ;;
  completion_enforcement)   shift; cmd_completion_enforcement   "$@" ;;
  resolve_model_for_role)   shift; cmd_resolve_model_for_role   "$@" ;;
  system_prompt_flag)       shift; cmd_system_prompt_flag       "$@" ;;
  settings_override_flag)   shift; cmd_settings_override_flag   "$@" ;;
  smoke|--smoke)            shift; cmd_smoke                    "$@" ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand> [args]

Subcommands (mirroring adapters/agents/README.md §Operation Surface):
  spawn <role> <task_prompt> [model_override]
                            Emit delegate:TaskCreate directive with
                            provider/model split for multi-provider
                            bindings.
  wait <spawn_handle>       Emit delegate:TaskList polling directive.
  send_message <handle> <body>
                            Returns 'unsupported' (opencode has no
                            native team_messaging primitive).
  collect_result <handle>   Emit delegate:TaskGet directive.
  shutdown <handle> [approve]
                            Emit delegate:TaskUpdate status=completed
                            directive (lead-mediated termination).
  completion_enforcement    Print resolved enforcement mode
                            (lead_validator on opencode today).
  resolve_model_for_role <role>
                            Print resolved role binding (raw, possibly
                            'provider/model' form).
  system_prompt_flag        Returns 'unsupported' (opencode has no
                            --append-system-prompt equivalent).
  settings_override_flag    Returns 'unsupported' (opencode has no
                            --settings equivalent; session config is
                            file-based).
  smoke | --smoke           Print operation x support-level matrix for
                            the active framework (opencode only).

Refer to adapters/agents/README.md for the full orchestration contract
and to notes.md 2026-05-04T08:05 for the directive-line grammar.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: spawn, wait, send_message, collect_result, shutdown, completion_enforcement, resolve_model_for_role, system_prompt_flag, settings_override_flag, smoke)" >&2
    exit 1
    ;;
esac
