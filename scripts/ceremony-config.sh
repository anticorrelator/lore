#!/usr/bin/env bash
# ceremony-config.sh — Manage harness-local ceremony advisor bindings
# Usage: ceremony-config.sh [--harness <name>] <subcommand> [args...]
#
# Subcommands:
#   get <ceremony>                Get advisor list for a ceremony on the target harness
#                                 (JSON array, [] if absent)
#   add <ceremony> <skill>        Add an advisor to a ceremony (idempotent)
#   remove <ceremony> <skill>     Remove an advisor from a ceremony (no-op if absent)
#   list                          List all configured ceremonies (JSON object)
#
# Without --harness: writes to the active harness resolved by
# resolve_active_framework. With --harness <name>: writes to
# `harnesses.<name>.ceremonies.<skill>`. There is no top-level ceremonies
# map and no legacy ceremonies.json fallback.
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
ceremony-config.sh — manage harness-local ceremony advisor bindings

Usage: ceremony-config.sh [--harness <name>] <subcommand> [args...]

Subcommands:
  get <ceremony>                    Get advisor list for target harness (JSON array)
  add <ceremony> <skill>            Add an advisor (idempotent)
  remove <ceremony> <skill>         Remove an advisor (no-op if absent)
  list                              List configured ceremonies for target harness (JSON)

Options:
  --harness <name>  Operate on harnesses.<name>.ceremonies.<skill>.
                    Defaults to the active harness.
  --work-item <slug> Attach work-item context to unresolved get outcomes.
  --help, -h        Show this help
EOF
}

HARNESS=""
WORK_ITEM=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness)
      [[ -n "${2:-}" ]] || { echo "Error: --harness requires a name" >&2; exit 1; }
      HARNESS="$2"
      shift 2
      ;;
    --work-item)
      [[ -n "${2:-}" ]] || { echo "Error: --work-item requires a slug" >&2; exit 1; }
      WORK_ITEM="$2"
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

TARGET_HARNESS="$HARNESS"
if [[ -z "$TARGET_HARNESS" ]]; then
  TARGET_HARNESS=$(resolve_active_framework)
fi

_ceremony_path() {
  local skill="$1"
  printf '%s\n' "harnesses.$TARGET_HARNESS.ceremonies.$skill"
}

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
    resolve_ceremony_advisors "$CEREMONY" "$TARGET_HARNESS" "$WORK_ITEM"
    ;;
  add)
    if [[ ${#ARGS[@]} -lt 3 ]]; then
      echo "Usage: ceremony-config.sh [--harness <name>] add <ceremony> <skill>" >&2
      exit 1
    fi
    CEREMONY="${ARGS[1]}"
    SKILL="${ARGS[2]}"
    advisor_json=$(jq -cn --arg s "$SKILL" '[$s]')
    validate_ceremony_advisors "$TARGET_HARNESS" "$(_ceremony_path "$CEREMONY")" "$advisor_json"
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
    bash "$SETTINGS_SH" section "harnesses" \
      | jq -c --arg h "$TARGET_HARNESS" '.[$h].ceremonies // {}'
    ;;
  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
