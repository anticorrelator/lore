#!/usr/bin/env bash
# harness-toggle/status.sh — Print per-harness lore integration state
#
# Usage: bash status.sh [<framework>] [--json]
#
# With no positional arg: prints status for every registered framework.
# With a framework arg: prints status for just that one.
#
# Reads `harnesses.<fw>.enabled` from unified settings.json (with legacy
# agent.json fallback during the deprecation window). LORE_AGENT_DISABLED=1
# overrides for the session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../lib.sh"

SETTINGS_SH="$SCRIPT_DIR/../settings.sh"
LEGACY_AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
SETTINGS_JSON=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" path)

JSON_OUTPUT=0
TARGET_FRAMEWORK=""

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=1 ;;
    --help|-h)
      cat >&2 <<EOF
Usage: lore harness status [<framework>] [--json]
  Report current lore integration state per harness.
EOF
      exit 0
      ;;
    -*) echo "Error: unknown flag '$arg'" >&2; exit 2 ;;
    *)
      if [[ -n "$TARGET_FRAMEWORK" ]]; then
        echo "Error: only one framework may be specified ($TARGET_FRAMEWORK then $arg)" >&2
        exit 2
      fi
      TARGET_FRAMEWORK="$arg"
      ;;
  esac
done

_fw_list=$(list_supported_frameworks) || exit 1
ALL_FRAMEWORKS=()
while IFS= read -r fw; do ALL_FRAMEWORKS+=("$fw"); done <<<"$_fw_list"
unset _fw_list

FRAMEWORKS=()
if [[ -n "$TARGET_FRAMEWORK" ]]; then
  found=0
  for fw in "${ALL_FRAMEWORKS[@]}"; do
    if [[ "$fw" == "$TARGET_FRAMEWORK" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "Error: '$TARGET_FRAMEWORK' is not a registered framework" >&2
    echo "       Registered: ${ALL_FRAMEWORKS[*]}" >&2
    exit 2
  fi
  FRAMEWORKS=("$TARGET_FRAMEWORK")
else
  FRAMEWORKS=("${ALL_FRAMEWORKS[@]}")
fi

SESSION_OVERRIDE=0
if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
  SESSION_OVERRIDE=1
fi

# Resolve a single framework's state. Sets:
#   ENABLED=true|false
#   SOURCE=settings|legacy|default
resolve_state_for() {
  local fw="$1"
  ENABLED=true
  SOURCE="default"

  local v
  v=$(LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" get "harnesses.${fw}.enabled" 2>/dev/null || true)
  if [[ -n "$v" ]]; then
    if [[ "$v" == "false" ]]; then
      ENABLED=false
    else
      ENABLED=true
    fi
    SOURCE="settings"
    return 0
  fi

  # Legacy fallback (global agent.json applies uniformly)
  if [[ -f "$LEGACY_AGENT_JSON" ]]; then
    local legacy
    legacy=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print('true' if d.get('enabled', True) else 'false')
" "$LEGACY_AGENT_JSON" 2>/dev/null || echo "true")
    if [[ "$legacy" == "false" ]]; then
      ENABLED=false
    else
      ENABLED=true
    fi
    SOURCE="legacy"
    return 0
  fi
}

if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  rows=()
  for fw in "${FRAMEWORKS[@]}"; do
    resolve_state_for "$fw"
    effective_enabled="$ENABLED"
    effective_source="config"
    if [[ "$SESSION_OVERRIDE" -eq 1 ]]; then
      effective_enabled="false"
      effective_source="env"
    fi
    [[ "$SOURCE" == "default" && "$SESSION_OVERRIDE" -eq 0 ]] && effective_source="default"
    [[ "$SOURCE" == "legacy"  && "$SESSION_OVERRIDE" -eq 0 ]] && effective_source="legacy"
    rows+=("{\"framework\":\"$fw\",\"enabled\":$effective_enabled,\"source\":\"$effective_source\"}")
  done
  joined=$(printf ',%s' "${rows[@]}")
  python3 -c "
import json, sys
items = json.loads(sys.argv[1])
print(json.dumps({'config_path': sys.argv[2], 'harnesses': items}))
" "[${joined:1}]" "$SETTINGS_JSON"
  exit 0
fi

# Human-readable output
for fw in "${FRAMEWORKS[@]}"; do
  resolve_state_for "$fw"
  if [[ "$SESSION_OVERRIDE" -eq 1 ]]; then
    eff="disabled"
    note=" (overridden this session via LORE_AGENT_DISABLED=1)"
  elif [[ "$ENABLED" == "true" ]]; then
    eff="enabled"
    note=""
  else
    eff="disabled"
    note=""
  fi
  src_note=""
  case "$SOURCE" in
    default) src_note=" [default]" ;;
    legacy)  src_note=" [legacy agent.json fallback]" ;;
  esac
  echo "Lore harness '$fw': ${eff}${note}${src_note}"
done
