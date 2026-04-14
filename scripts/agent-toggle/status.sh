#!/usr/bin/env bash
# agent-toggle/status.sh — Print lore agent integration state
# Missing agent.json means enabled (D5). LORE_AGENT_DISABLED=1 overrides for session (D1).
# Usage: bash status.sh [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
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

if [[ -f "$AGENT_JSON" ]]; then
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
  [[ -f "$AGENT_JSON" ]] && CONFIG_EXISTS="true"
  python3 -c "
import json
print(json.dumps({
    'enabled': '$EFFECTIVE' == 'enabled',
    'effective_source': '$EFFECTIVE_SOURCE',
    'last_changed': '$LAST_CHANGED',
    'config_path': '$AGENT_JSON',
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
elif [[ ! -f "$AGENT_JSON" ]]; then
  echo "  (no config file — default: enabled)"
fi
