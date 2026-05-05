#!/usr/bin/env bash
# adapters/agents/claude-code.sh — Claude Code orchestration adapter (T33).
#
# Implements the seven-operation contract documented in
# adapters/agents/README.md (T31, T32) for Claude Code. Most physical
# orchestration on Claude Code goes through the harness's native tool API
# (TaskCreate/TaskUpdate/SendMessage/TaskList) which the lead model invokes
# directly — the bash adapter cannot call those tools. Per the README's
# operation surface, the adapter therefore exposes:
#
#   - capability-query operations (`completion_enforcement`,
#     `resolve_model_for_role`) that produce real shell-side output.
#   - tool-mediated operations (`spawn`, `wait`, `send_message`,
#     `collect_result`, `shutdown`) that emit a single-line
#     `delegate:<tool> ...` directive which the calling skill or script
#     consumes (this is the documented Claude Code wire shape — the
#     harness's tool API is the spawn/wait/send_message surface, not a
#     subprocess).
#
# Subcommands match the seven operations one-to-one plus a `smoke`
# entrypoint (per adapter responsibility #4). The skill-side wiring
# (T34/T35) consumes this script via `source` for the helper functions
# and via subcommand invocation for the tool-delegation directives.
#
# Active framework MUST be claude-code; the adapter refuses to run
# under any other framework so a misconfigured caller cannot accidentally
# route an opencode/codex spawn through Claude Code's tool surface.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

# --- require_claude_code ---
# Refuse to run when active framework != claude-code. The orchestration
# adapter assumes Claude Code's tool API; any other framework must use
# its own adapter (adapters/agents/opencode.sh — T39, codex.sh — T40).
require_claude_code() {
  local active
  active=$(resolve_active_framework 2>/dev/null) || active=""
  if [[ "$active" != "claude-code" ]]; then
    echo "Error: adapters/agents/claude-code.sh requires active framework=claude-code (got '$active')" >&2
    echo "       set LORE_FRAMEWORK=claude-code or run install.sh --framework claude-code" >&2
    return 1
  fi
}

# --- emit_degraded_notice ---
# Per README adapter responsibility #3: every spawn under partial/fallback
# capability cells emits a one-line stderr notice. Claude Code's cells are
# all `full` today so this only fires under user override; the helper is
# kept central so opencode/codex adapters can reuse the wording.
emit_degraded_notice() {
  local op="$1" capability_level="$2" fallback_mech="$3"
  if [[ "$capability_level" == "partial" || "$capability_level" == "fallback" ]]; then
    echo "[lore] degraded: $op via $fallback_mech (capability=$capability_level)" >&2
  fi
}

# --- cap ---
# Single-call wrapper: print the support level for a capability cell on
# the active framework. Defers to framework_capability (lib.sh, T6) so
# the override-then-static-profile lookup is honored without re-implementing.
cap() {
  framework_capability "$1" 2>/dev/null || echo "none"
}

# --- cmd_spawn ---
# Spawn a worker agent. On Claude Code this means TaskCreate (and
# TeamCreate for the first call of a team). The bash adapter cannot
# physically spawn — it emits a delegation directive the calling skill
# parses to invoke the native tool. Caller passes role + task_prompt
# (positional) and an optional model override on stdin.
#
# Output: single-line `delegate:TaskCreate role=<role> model=<id>`
# directive on stdout; the skill body uses TaskCreate with that role/model.
cmd_spawn() {
  require_claude_code
  local role="${1:-}" task_prompt="${2:-}" override_model="${3:-}"
  if [[ -z "$role" || -z "$task_prompt" ]]; then
    echo "Error: spawn requires <role> <task_prompt>" >&2
    return 1
  fi

  local subagents
  subagents=$(cap subagents)
  if [[ "$subagents" == "none" ]]; then
    echo "Error: spawn unavailable — capabilities.json frameworks.claude-code.capabilities.subagents=none" >&2
    return 1
  fi
  emit_degraded_notice spawn "$subagents" "claude-code TaskCreate"

  # Resolve the role -> model binding. Per-call override (positional $3 or
  # LORE_MODEL_<ROLE>) is honored by resolve_model_for_role itself; the
  # adapter does not re-implement override precedence.
  local model
  if [[ -n "$override_model" ]]; then
    model="$override_model"
  else
    model=$(resolve_model_for_role "$role") || return 1
  fi

  echo "delegate:TaskCreate role=$role model=$model"
}

# --- cmd_wait ---
# Wait for a spawned worker to complete. On Claude Code this is a TaskList
# poll. The bash adapter cannot poll the harness; it emits the delegation
# directive so the lead's skill body invokes TaskList.
cmd_wait() {
  require_claude_code
  local handle="${1:-}"
  if [[ -z "$handle" ]]; then
    echo "Error: wait requires <spawn_handle>" >&2
    return 1
  fi
  echo "delegate:TaskList handle=$handle"
}

# --- cmd_send_message ---
# Send a message to a spawned worker. On Claude Code this is the native
# SendMessage tool. team_messaging cell is `full` for claude-code; if a
# user override drops it, the adapter returns `unsupported` per the
# operation surface contract.
cmd_send_message() {
  require_claude_code
  local handle="${1:-}" body="${2:-}"
  if [[ -z "$handle" || -z "$body" ]]; then
    echo "Error: send_message requires <spawn_handle> <body>" >&2
    return 1
  fi

  local team_messaging
  team_messaging=$(cap team_messaging)
  if [[ "$team_messaging" == "none" ]]; then
    echo "unsupported"
    return 0
  fi
  emit_degraded_notice send_message "$team_messaging" "claude-code SendMessage"
  echo "delegate:SendMessage handle=$handle"
}

# --- cmd_collect_result ---
# Collect a worker's result. On Claude Code this is TaskGet (description +
# linked transcript). The transcript_provider cell is `full` for
# claude-code today; under override the adapter still emits the delegate
# directive but flags missing transcript fields per README §"Capability
# Gates Per Operation".
cmd_collect_result() {
  require_claude_code
  local handle="${1:-}"
  if [[ -z "$handle" ]]; then
    echo "Error: collect_result requires <spawn_handle>" >&2
    return 1
  fi

  local transcript
  transcript=$(cap transcript_provider)
  if [[ "$transcript" == "none" ]]; then
    echo "delegate:TaskGet handle=$handle transcript=omit" >&2
    echo "[lore] degraded: collect_result transcript fields omitted (capability=none)" >&2
    echo "delegate:TaskGet handle=$handle transcript=omit"
    return 0
  fi
  emit_degraded_notice collect_result "$transcript" "claude-code TaskGet + transcript"
  echo "delegate:TaskGet handle=$handle"
}

# --- cmd_shutdown ---
# Shut a spawned worker down. On Claude Code this is a SendMessage with
# {type: shutdown_request}. The bash adapter emits the directive; the
# lead's skill body composes the JSON body and invokes SendMessage.
cmd_shutdown() {
  require_claude_code
  local handle="${1:-}" approve="${2:-true}"
  if [[ -z "$handle" ]]; then
    echo "Error: shutdown requires <spawn_handle> [approve=true|false]" >&2
    return 1
  fi
  echo "delegate:SendMessage handle=$handle type=shutdown_request approve=$approve"
}

# --- cmd_completion_enforcement ---
# Read-only capability query: print the resolved completion-enforcement
# mode (one of native_blocking | lead_validator | self_attestation |
# unavailable). Delegates to lib.sh::resolve_completion_enforcement_mode
# so the resolution table is shared across adapters.
cmd_completion_enforcement() {
  require_claude_code
  resolve_completion_enforcement_mode
}

# --- cmd_resolve_model_for_role ---
# Pass-through to lib.sh::resolve_model_for_role for callers that prefer
# a unified entry point (the orchestration adapter binary) over invoking
# the helper directly. Mirrors the contract row in adapters/agents/README.md
# §"Operation Surface".
cmd_resolve_model_for_role() {
  require_claude_code
  local role="${1:-}"
  if [[ -z "$role" ]]; then
    echo "Error: resolve_model_for_role requires <role>" >&2
    return 1
  fi
  resolve_model_for_role "$role"
}

# --- cmd_smoke ---
# Print the operation x support-level matrix for Claude Code. Mirrors
# the smoke contract in adapters/hooks/claude-code.sh; the operation
# rows are the closed seven plus a header summary.
cmd_smoke() {
  require_claude_code
  local subagents team_messaging transcript task_completed
  subagents=$(cap subagents)
  team_messaging=$(cap team_messaging)
  transcript=$(cap transcript_provider)
  task_completed=$(cap task_completed_hook)

  local mode
  mode=$(resolve_completion_enforcement_mode)

  local model_lead model_worker
  model_lead=$(resolve_model_for_role lead 2>/dev/null) || model_lead="<unresolved>"
  model_worker=$(resolve_model_for_role worker 2>/dev/null) || model_worker="<unresolved>"

  echo "[claude-code orchestration adapter smoke]"
  echo "  active framework:        claude-code"
  echo "  completion enforcement:  $mode"
  echo "  role bindings:           lead=$model_lead worker=$model_worker"
  echo
  echo "  Operation                Support       Native API"
  echo "  ------------------------ ------------- ---------------------------------------"
  printf '  %-24s %-13s %s\n' spawn                  "$subagents"      "TaskCreate (Claude Code tool API)"
  printf '  %-24s %-13s %s\n' wait                   "$subagents"      "TaskList polling"
  printf '  %-24s %-13s %s\n' send_message           "$team_messaging" "SendMessage"
  printf '  %-24s %-13s %s\n' collect_result         "$subagents/$transcript" "TaskGet description + transcript"
  printf '  %-24s %-13s %s\n' shutdown               "$subagents"      "SendMessage type=shutdown_request"
  printf '  %-24s %-13s %s\n' completion_enforcement "$task_completed" "TaskCompleted hook (exit-2 blocking)"
  printf '  %-24s %-13s %s\n' resolve_model_for_role "single"          "--model <id> (single-provider harness)"
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
                            Emit TaskCreate delegation directive.
  wait <spawn_handle>       Emit TaskList polling delegation directive.
  send_message <handle> <body>
                            Emit SendMessage delegation directive (or
                            print 'unsupported' when team_messaging=none).
  collect_result <handle>   Emit TaskGet delegation directive.
  shutdown <handle> [approve]
                            Emit SendMessage type=shutdown_request directive.
  completion_enforcement    Print resolved enforcement mode.
  resolve_model_for_role <role>
                            Print resolved model id.
  smoke | --smoke           Print operation x support-level matrix for
                            the active framework (claude-code only).

Refer to adapters/agents/README.md for the full orchestration contract.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: spawn, wait, send_message, collect_result, shutdown, completion_enforcement, resolve_model_for_role, smoke)" >&2
    exit 1
    ;;
esac
