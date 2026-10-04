#!/usr/bin/env bash
# active.sh — say whether lore is loaded for a harness in the current directory.
#
# Usage: bash active.sh [--harness <fw>] [--json]
#
# Active means all three hold, checked in this order:
#   1. LORE_AGENT_DISABLED is not 1;
#   2. lore_harness_enabled <fw> passes;
#   3. the store resolved for this directory is initialized — _manifest.json and
#      _work/_index.json both exist, the same test the TUI makes before it leaves
#      onboarding. Resolution alone proves nothing: it names a store for any
#      directory, /tmp included.
#
# Exit 0 when active, 1 when inactive, 2 on a usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore active [--harness <fw>] [--json]

Says whether lore is loaded here: the session kill switch is off, the harness is
enabled, and the knowledge store for the current directory is initialized.
Exits 0 when active and 1 when not, so `lore active && ...` works in a shell.

Options:
  --harness <fw>  Harness to check (default: claude-code).
  --json          Emit {active, harness, store, reason}. reason is one of ok,
                  disabled-env, harness-disabled, store-uninitialized,
                  lore-unresolved; store is null when no store was resolved.
  --help, -h      Show this help.
EOF
}

HARNESS="claude-code"
JSON_MODE=0

usage_error() {
  echo "[active] Error: $1" >&2
  usage
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness)
      [[ $# -ge 2 && -n "$2" ]] || usage_error "--harness needs a framework name"
      HARNESS="$2"; shift 2 ;;
    --harness=*)
      HARNESS="${1#--harness=}"
      [[ -n "$HARNESS" ]] || usage_error "--harness needs a framework name"
      shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unexpected argument '$1'" ;;
  esac
done

# lore_harness_enabled treats a framework it has no setting for as enabled, so a
# misspelled name would read as active.
if ! list_supported_frameworks | grep -qxF -- "$HARNESS"; then
  usage_error "unknown harness '$HARNESS' (registered: $(list_supported_frameworks | paste -sd ' ' -))"
fi

STORE=""
REASON="ok"
if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
  REASON="disabled-env"
elif ! lore_harness_enabled "$HARNESS"; then
  REASON="harness-disabled"
elif ! STORE="$(resolve_knowledge_dir 2>/dev/null)" || [[ -z "$STORE" ]]; then
  STORE=""
  REASON="lore-unresolved"
elif [[ ! -f "$STORE/_manifest.json" || ! -f "$STORE/_work/_index.json" ]]; then
  REASON="store-uninitialized"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n --arg harness "$HARNESS" --arg store "$STORE" --arg reason "$REASON" \
    '{active: ($reason == "ok"), harness: $harness,
      store: (if $store == "" then null else $store end), reason: $reason}'
elif [[ "$REASON" == "ok" ]]; then
  echo "active ($HARNESS): $STORE"
else
  echo "inactive ($HARNESS): $REASON${STORE:+ — $STORE}"
fi

[[ "$REASON" == "ok" ]]
