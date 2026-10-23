#!/usr/bin/env bash
# render-preferences.sh — Print, in full, the preferences filed under the
# activities a command starts, or under activities named directly.
#
# Usage:
#   render-preferences.sh --kdir <store> --command "<name>" [--json]
#   render-preferences.sh --kdir <store> --activity <name>... [--json]
#
# Preferences are this project's working style, accumulated from many hands
# and filed under the activity each one governs. A command that starts an
# activity prints those entries after its own output, so they are read at the
# moment they apply: `lore arc open` prints coordination and model-routing,
# `lore arc close` human-writing, `lore spec start` work-scoping, and
# `lore impl start` model-routing.
#
# --command looks the activities up in pk_activities.py's table
# (`pk_activities.py starts <command>`). --activity names them directly, as
# several names after one flag or as the flag repeated.
#
# The text is pk_activities.py's block, unchanged. Per activity it prints
# `Preferences for <name> (N):`, each live entry's title and body, and
# `Full set: lore search --preferences --activity <name>`. An activity with no
# entries prints `Preferences for <name>: none filed.` --json prints
# pk_activities.py's {"activities": [...], "text": "..."} object instead.
#
# --kdir is required. Each caller passes the store it resolved, so the block
# and the caller's own output come from the same store.
#
# Exit 1, with the reason on stderr, for a usage error, a store that does not
# exist, a command the table starts no activity for, or an activity name
# outside [a-z0-9-].

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KDIR=""
COMMAND=""
HAS_COMMAND=0
ACTIVITIES=()
JSON_FLAG=()

refuse() {
  echo "[preferences] Error: $1" >&2
  echo "Usage: render-preferences.sh --kdir <store> (--command \"<name>\" | --activity <name>...) [--json]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)
      [[ $# -ge 2 && -n "$2" ]] || refuse "--kdir requires a value"
      KDIR="$2"; shift 2 ;;
    --command)
      [[ $# -ge 2 && -n "$2" ]] || refuse "--command requires a value"
      COMMAND="$2"; HAS_COMMAND=1; shift 2 ;;
    --activity)
      shift
      [[ $# -gt 0 && "$1" != --* ]] || refuse "--activity requires at least one name"
      while [[ $# -gt 0 && "$1" != --* ]]; do
        ACTIVITIES+=("$1"); shift
      done ;;
    --json) JSON_FLAG=(--json); shift ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *) refuse "unknown argument '$1'" ;;
  esac
done

[[ -n "$KDIR" ]] || refuse "--kdir is required"
[[ -d "$KDIR" ]] || refuse "knowledge store not found at: $KDIR"
if [[ $HAS_COMMAND -eq 1 && ${#ACTIVITIES[@]} -gt 0 ]]; then
  refuse "pass --command or --activity, not both"
fi
if [[ $HAS_COMMAND -eq 0 && ${#ACTIVITIES[@]} -eq 0 ]]; then
  refuse "pass --command \"<name>\" or --activity <name>"
fi

if [[ $HAS_COMMAND -eq 1 ]]; then
  STARTED="$(python3 "$SCRIPT_DIR/pk_activities.py" --kdir "$KDIR" starts "$COMMAND")"
  while IFS= read -r name; do
    [[ -n "$name" ]] && ACTIVITIES+=("$name")
  done <<< "$STARTED"
  [[ ${#ACTIVITIES[@]} -gt 0 ]] || refuse "'$COMMAND' starts no activity in pk_activities.py's table"
fi

exec python3 "$SCRIPT_DIR/pk_activities.py" --kdir "$KDIR" ${JSON_FLAG[@]+"${JSON_FLAG[@]}"} block "${ACTIVITIES[@]}"
