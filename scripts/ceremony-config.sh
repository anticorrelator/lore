#!/usr/bin/env bash
# ceremony-config.sh — Manage ceremony advisor overrides
# Usage: ceremony-config.sh [--harness <name>] <subcommand> [args...]
#
# Subcommands:
#   get <ceremony>                Get advisor list for a ceremony (JSON array, [] if absent)
#                                 Reads via resolve_ceremony_advisors so callers see the
#                                 D3b-resolved value (overlay > top-level > legacy).
#   add <ceremony> <skill>        Add an advisor to a ceremony (idempotent)
#   remove <ceremony> <skill>     Remove an advisor from a ceremony (no-op if absent)
#   list                          List all configured ceremonies (JSON object)
#
# Without --harness: writes to top-level `ceremonies.<skill>` in
# ~/.lore/config/settings.json (preserves pre-T2 semantics).
# With --harness <name>: writes to `harnesses.<name>.ceremonies.<skill>` —
# the D3b harness overlay. The empty-list-as-override semantics mean
# `add ... && remove ...` round-trips on the harness layer leave an
# explicit `[]` (which suppresses all advisors on that harness) rather than
# falling back to the top-level default; pass `remove <ceremony> --no-leave-empty`
# to force deletion of the harness overlay key entirely.
#
# Mutations write through `settings.sh patch` so the D5a write contract
# (flock-protected read-modify-write + atomic mv) is preserved across all
# ceremony writers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SETTINGS_SH="$SCRIPT_DIR/settings.sh"

usage() {
  cat >&2 <<EOF
ceremony-config.sh — manage ceremony advisor overrides

Usage: ceremony-config.sh [--harness <name>] <subcommand> [args...]

Subcommands:
  get <ceremony>                    Get resolved advisor list (JSON array)
  add <ceremony> <skill>            Add an advisor (idempotent)
  remove <ceremony> <skill>         Remove an advisor (no-op if absent)
  list                              List all configured ceremonies (JSON)

Options:
  --harness <name>  Operate on harnesses.<name>.ceremonies.<skill> (D3b overlay)
                    instead of top-level ceremonies.<skill>. Empty-list override
                    on the harness layer is meaningful — see header comment.
  --help, -h        Show this help
EOF
}

HARNESS=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness)
      [[ -n "${2:-}" ]] || { echo "Error: --harness requires a name" >&2; exit 1; }
      HARNESS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#ARGS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

# Build the settings.sh path for the targeted layer. With --harness, paths
# are scoped under harnesses.<name>.ceremonies; otherwise top-level.
_ceremony_path() {
  local skill="$1"
  if [[ -n "$HARNESS" ]]; then
    printf '%s\n' "harnesses.$HARNESS.ceremonies.$skill"
  else
    printf '%s\n' "ceremonies.$skill"
  fi
}

# Read the current advisor list at the targeted layer (NOT resolved across
# layers — `add`/`remove` operate on the actual stored array, not the
# resolved view). Returns `[]` when absent.
_read_layer() {
  local skill="$1"
  local raw
  raw=$(bash "$SETTINGS_SH" get "$(_ceremony_path "$skill")" 2>/dev/null || true)
  if [[ -z "$raw" ]]; then
    echo "[]"
    return 0
  fi
  if printf '%s' "$raw" | jq -e 'type == "array"' &>/dev/null; then
    printf '%s\n' "$raw"
  else
    echo "[]"
  fi
}

subcmd="${ARGS[0]}"
case "$subcmd" in
  get)
    if [[ ${#ARGS[@]} -lt 2 ]]; then
      echo "Usage: ceremony-config.sh [--harness <name>] get <ceremony>" >&2
      exit 1
    fi
    CEREMONY="${ARGS[1]}"
    # `get` returns the *resolved* value (overlay > top-level > legacy) so
    # consumers see what the runtime actually picks. Use the lib helper so
    # the resolution is centralized.
    if [[ -n "$HARNESS" ]]; then
      # Layer-scoped get: read the stored array, not the resolved view —
      # callers using --harness usually want to confirm what they wrote.
      _read_layer "$CEREMONY"
    else
      resolve_ceremony_advisors "$CEREMONY"
    fi
    ;;
  add)
    if [[ ${#ARGS[@]} -lt 3 ]]; then
      echo "Usage: ceremony-config.sh [--harness <name>] add <ceremony> <skill>" >&2
      exit 1
    fi
    CEREMONY="${ARGS[1]}"
    SKILL="${ARGS[2]}"
    current=$(_read_layer "$CEREMONY")
    updated=$(printf '%s' "$current" | jq -c --arg s "$SKILL" \
      'if any(.[]; . == $s) then . else . + [$s] end')
    bash "$SETTINGS_SH" patch "$(_ceremony_path "$CEREMONY")" "$updated"
    printf '%s\n' "$updated"
    ;;
  remove)
    if [[ ${#ARGS[@]} -lt 3 ]]; then
      echo "Usage: ceremony-config.sh [--harness <name>] remove <ceremony> <skill>" >&2
      exit 1
    fi
    CEREMONY="${ARGS[1]}"
    SKILL="${ARGS[2]}"
    current=$(_read_layer "$CEREMONY")
    updated=$(printf '%s' "$current" | jq -c --arg s "$SKILL" 'map(select(. != $s))')
    bash "$SETTINGS_SH" patch "$(_ceremony_path "$CEREMONY")" "$updated"
    printf '%s\n' "$updated"
    ;;
  list)
    if [[ -n "$HARNESS" ]]; then
      bash "$SETTINGS_SH" section "harnesses" \
        | jq -c --arg h "$HARNESS" '.[$h].ceremonies // {}'
    else
      bash "$SETTINGS_SH" section "ceremonies"
    fi
    ;;
  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
