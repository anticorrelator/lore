#!/usr/bin/env bash
# adapters/agents/codex.sh — Codex orchestration adapter (T40).
#
# Implements the seven-operation contract documented in
# adapters/agents/README.md (T31, T32) for Codex. The adapter shares
# the directive grammar committed in notes.md 2026-05-04T08:05:
# `delegate:<ToolName> <key>=<value> ...` lines on stdout that the
# calling skill consumes. Skills running on Codex translate the
# directive ToolName into Codex's subagent-spawn primitive.
#
# Capability profile (capabilities.json frameworks.codex.capabilities):
#   subagents=partial — opt-in subagent workflows; Codex orchestrates
#                       spawn via its native subagent surface.
#   team_messaging=none — no native TeamCreate/SendMessage primitive;
#                         send_message returns `unsupported`.
#   task_completed_hook=fallback — no native subagent-completion
#                       blocking; completion_enforcement resolves to
#                       lead_validator.
#   transcript_provider=partial — session artifacts exist; format
#                       differs from Claude JSONL (T51 stub).
#   model_routing=single — bare model ids only; no provider/model
#                       split at the spawn boundary.
#
# Subcommands match the seven-op closed surface plus a smoke
# entrypoint (`smoke` / `--smoke`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

# --- require_codex ---
# Refuse to run when active framework != codex. Mirrors the
# require_<framework> guards in claude-code.sh and opencode.sh.
require_codex() {
  local active
  active=$(resolve_active_framework 2>/dev/null) || active=""
  if [[ "$active" != "codex" ]]; then
    echo "Error: adapters/agents/codex.sh requires active framework=codex (got '$active')" >&2
    echo "       set LORE_FRAMEWORK=codex or run install.sh --framework codex" >&2
    return 1
  fi
}

# --- emit_degraded_notice ---
# One-line stderr notice on partial/fallback capability cells. Wording
# matches the other agent adapters so audit channels can pattern-match.
emit_degraded_notice() {
  local op="$1" capability_level="$2" fallback_mech="$3"
  if [[ "$capability_level" == "partial" || "$capability_level" == "fallback" ]]; then
    echo "[lore] degraded: $op via $fallback_mech (capability=$capability_level)" >&2
  fi
}

# --- cap ---
# Pass-through to framework_capability so the override-then-static
# lookup lives in lib.sh (T6).
cap() {
  framework_capability "$1" 2>/dev/null || echo "none"
}

# --- cmd_spawn ---
# Spawn a subagent. Codex is single-provider (model_routing.shape=single)
# so role bindings are bare model ids — no provider/model split. The
# directive carries `model=<m>` only.
#
# Output: `delegate:TaskCreate role=<r> model=<m>` on stdout.
cmd_spawn() {
  require_codex
  local role="${1:-}" task_prompt="${2:-}" override_model="${3:-}"
  if [[ -z "$role" || -z "$task_prompt" ]]; then
    echo "Error: spawn requires <role> <task_prompt>" >&2
    return 1
  fi

  local subagents
  subagents=$(cap subagents)
  if [[ "$subagents" == "none" ]]; then
    echo "Error: spawn unavailable — capabilities.json frameworks.codex.capabilities.subagents=none" >&2
    return 1
  fi
  emit_degraded_notice spawn "$subagents" "codex subagent spawn"

  local model
  if [[ -n "$override_model" ]]; then
    model="$override_model"
  else
    model=$(resolve_model_for_role "$role") || return 1
  fi

  # Reject provider/model syntax on this single-shape harness;
  # validate_role_model_binding emits the explanatory stderr line.
  if ! validate_role_model_binding "$role" "$model"; then
    return 1
  fi

  echo "delegate:TaskCreate role=$role model=$model"
}

# --- cmd_wait ---
# Codex subagent state is observable through the harness; the bash
# adapter emits the delegation directive so the lead skill polls via
# Codex's TaskList equivalent.
cmd_wait() {
  require_codex
  local handle="${1:-}"
  if [[ -z "$handle" ]]; then
    echo "Error: wait requires <spawn_handle>" >&2
    return 1
  fi
  echo "delegate:TaskList task_id=$handle"
}

# --- cmd_send_message ---
# Codex has no native TeamCreate/SendMessage primitive (capabilities.json
# team_messaging=none). The contract reserves the literal `unsupported`
# stdout for this case so callers can branch to lead-only orchestration
# without invoking a tool the harness cannot fulfill.
cmd_send_message() {
  require_codex
  local handle="${1:-}" body="${2:-}"
  if [[ -z "$handle" || -z "$body" ]]; then
    echo "Error: send_message requires <spawn_handle> <body>" >&2
    return 1
  fi

  local team_messaging
  team_messaging=$(cap team_messaging)
  if [[ "$team_messaging" == "none" ]]; then
    echo "[lore] degraded: send_message unsupported on codex (team_messaging=none); skill must run in lead-orchestrated mode" >&2
    echo "unsupported"
    return 0
  fi
  emit_degraded_notice send_message "$team_messaging" "codex SendMessage"
  echo "delegate:SendMessage to=$handle"
}

# --- cmd_collect_result ---
# Collect a worker's result via Codex's TaskGet equivalent. Codex's
# transcript_provider=partial means transcript fields may be absent
# in the returned envelope; the directive emission shape is identical
# to the other adapters and a degraded notice is logged so the audit
# channel sees the partial attribution.
cmd_collect_result() {
  require_codex
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
  emit_degraded_notice collect_result "$transcript" "codex TaskGet + transcript stub"
  echo "delegate:TaskGet task_id=$handle"
}

# --- cmd_shutdown ---
# Without team_messaging, Codex lacks SendMessage-based shutdown. The
# lead skill on Codex invokes its TaskUpdate equivalent to mark the
# task complete and stop the subagent — same fallback shape as the
# opencode adapter.
cmd_shutdown() {
  require_codex
  local handle="${1:-}" approve="${2:-true}"
  if [[ -z "$handle" ]]; then
    echo "Error: shutdown requires <spawn_handle> [approve=true|false]" >&2
    return 1
  fi
  echo "delegate:TaskUpdate task_id=$handle status=completed"
}

# --- cmd_completion_enforcement ---
# Read-only capability query. codex resolves to lead_validator today
# (task_completed_hook=fallback + subagents=partial per the table at
# adapters/agents/README.md §Mode resolution rule).
cmd_completion_enforcement() {
  require_codex
  resolve_completion_enforcement_mode
}

# --- cmd_resolve_model_for_role ---
# Pass-through. Codex bindings are bare model ids; callers don't need
# the split form opencode emits.
cmd_resolve_model_for_role() {
  require_codex
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "Error: resolve_model_for_role requires <role>" >&2
    return 1
  fi
  resolve_model_for_role "$role"
}

# --- cmd_smoke ---
# Print the operation x support-level matrix for Codex. Same shape
# as claude-code.sh and opencode.sh smoke; rows reflect Codex's actual
# capability cells.
cmd_smoke() {
  require_codex
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

  echo "[codex orchestration adapter smoke]"
  echo "  active framework:        codex"
  echo "  completion enforcement:  $mode"
  echo "  model routing shape:     $routing_shape"
  echo "  role bindings:           lead=$model_lead worker=$model_worker"
  echo
  echo "  Operation                Support       Native API"
  echo "  ------------------------ ------------- ---------------------------------------"
  printf '  %-24s %-13s %s\n' spawn                  "$subagents"      "codex subagent spawn (delegate:TaskCreate)"
  printf '  %-24s %-13s %s\n' wait                   "$subagents"      "codex task poll (delegate:TaskList)"
  printf '  %-24s %-13s %s\n' send_message           "$team_messaging" "unsupported (no native TeamCreate/SendMessage; lead-orchestrated)"
  printf '  %-24s %-13s %s\n' collect_result         "$subagents/$transcript" "codex TaskGet + transcript stub"
  printf '  %-24s %-13s %s\n' shutdown               "$subagents"      "codex kill via delegate:TaskUpdate"
  printf '  %-24s %-13s %s\n' completion_enforcement "$task_completed" "lead-side validator (no native blocking hook)"
  printf '  %-24s %-13s %s\n' resolve_model_for_role "$routing_shape"  "bare model id (single-provider harness)"
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
  smoke|--smoke)            shift; cmd_smoke                    "$@" ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand> [args]

Subcommands (mirroring adapters/agents/README.md §Operation Surface):
  spawn <role> <task_prompt> [model_override]
                            Emit delegate:TaskCreate directive (single-
                            provider; bare model id only).
  wait <spawn_handle>       Emit delegate:TaskList polling directive.
  send_message <handle> <body>
                            Returns 'unsupported' (codex has no native
                            team_messaging primitive).
  collect_result <handle>   Emit delegate:TaskGet directive.
  shutdown <handle> [approve]
                            Emit delegate:TaskUpdate status=completed
                            directive (lead-mediated termination).
  completion_enforcement    Print resolved enforcement mode
                            (lead_validator on codex today).
  resolve_model_for_role <role>
                            Print resolved bare model id.
  smoke | --smoke           Print operation x support-level matrix for
                            the active framework (codex only).

Refer to adapters/agents/README.md for the full orchestration contract
and to notes.md 2026-05-04T08:05 for the directive-line grammar.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: spawn, wait, send_message, collect_result, shutdown, completion_enforcement, resolve_model_for_role, smoke)" >&2
    exit 1
    ;;
esac
