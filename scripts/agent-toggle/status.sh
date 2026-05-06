#!/usr/bin/env bash
# agent-toggle/status.sh — Print lore agent integration state
# Reads via settings.sh (unified file) with legacy agent.json fallback (D4
# deprecation window). Missing on both layers means enabled (D5).
# LORE_AGENT_DISABLED=1 overrides for session (D1).
# Usage: bash status.sh [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

SETTINGS_SH="$SCRIPT_DIR/../settings.sh"
AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
SETTINGS_JSON=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" path)
JSON_OUTPUT=0

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=1 ;;
    --help|-h)
      echo "Usage: lore agent status [--json]" >&2
      echo "  Report current lore agent integration state." >&2
      exit 0
      ;;
  esac
done

# Determine effective state
SESSION_OVERRIDE=0
if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
  SESSION_OVERRIDE=1
fi

ENABLED=true
LAST_CHANGED=""
CONFIG_SOURCE=""

# Unified file (primary)
UNIFIED_ENABLED=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" get agent.enabled 2>/dev/null || true)
if [[ -n "$UNIFIED_ENABLED" ]]; then
  if [[ "$UNIFIED_ENABLED" == "false" ]]; then
    ENABLED=false
  else
    ENABLED=true
  fi
  UNIFIED_LAST_CHANGED=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" get agent.last_changed 2>/dev/null || true)
  if [[ -n "$UNIFIED_LAST_CHANGED" ]]; then
    LAST_CHANGED=$(printf '%s' "$UNIFIED_LAST_CHANGED" | jq -r '. // empty' 2>/dev/null)
  fi
  CONFIG_SOURCE="$SETTINGS_JSON"
elif [[ -f "$AGENT_JSON" ]]; then
  # Legacy fallback (deprecation-window).
  ENABLED=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print('true' if d.get('enabled', True) else 'false')
" "$AGENT_JSON" 2>/dev/null || echo "true")

  LAST_CHANGED=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('last_changed', ''))
" "$AGENT_JSON" 2>/dev/null || echo "")
  CONFIG_SOURCE="$AGENT_JSON"
fi

# Effective state: env var overrides config
if [[ "$SESSION_OVERRIDE" -eq 1 ]]; then
  EFFECTIVE="disabled"
  EFFECTIVE_SOURCE="env"
elif [[ "$ENABLED" == "true" ]]; then
  EFFECTIVE="enabled"
  EFFECTIVE_SOURCE="config"
else
  EFFECTIVE="disabled"
  EFFECTIVE_SOURCE="config"
fi

if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  CONFIG_EXISTS="false"
  [[ -n "$CONFIG_SOURCE" ]] && CONFIG_EXISTS="true"
  CONFIG_PATH_OUT="${CONFIG_SOURCE:-$SETTINGS_JSON}"
  python3 -c "
import json
print(json.dumps({
    'enabled': '$EFFECTIVE' == 'enabled',
    'effective_source': '$EFFECTIVE_SOURCE',
    'last_changed': '$LAST_CHANGED',
    'config_path': '$CONFIG_PATH_OUT',
    'config_exists': '$CONFIG_EXISTS' == 'true',
}))
"
  exit 0
fi

echo "Agent integration: $EFFECTIVE"

if [[ "$SESSION_OVERRIDE" -eq 1 && "$ENABLED" == "true" ]]; then
  echo "  (globally enabled, but overridden this session via LORE_AGENT_DISABLED=1)"
fi

if [[ -n "$LAST_CHANGED" ]]; then
  echo "  Last changed: $LAST_CHANGED"
elif [[ -z "$CONFIG_SOURCE" ]]; then
  echo "  (no config file — default: enabled)"
fi
