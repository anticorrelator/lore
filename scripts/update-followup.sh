#!/usr/bin/env bash
# update-followup.sh — Update a follow-up artifact's status and metadata
# Usage: bash update-followup.sh <id> [--status <open|reviewed|promoted|dismissed>]
#   [--promoted-to <work-slug>] [--resolution <notes>] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=false
ID=""
NEW_STATUS=""
PROMOTED_TO=""
RESOLUTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      NEW_STATUS="$2"
      shift 2
      ;;
    --promoted-to)
      PROMOTED_TO="$2"
      shift 2
      ;;
    --resolution)
      RESOLUTION="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --*)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: update-followup.sh <id> [--status <open|reviewed|promoted|dismissed>] [--promoted-to <work-slug>] [--resolution <notes>] [--json]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$ID" ]]; then
        ID="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$ID" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Missing required argument: id"
  fi
  echo "[followup] Error: Missing required argument: id" >&2
  echo "Usage: update-followup.sh <id> [--status <open|reviewed|promoted|dismissed>] [--promoted-to <work-slug>] [--resolution <notes>] [--json]" >&2
  exit 1
fi

# Validate status if given
if [[ -n "$NEW_STATUS" ]]; then
  case "$NEW_STATUS" in
    open|reviewed|promoted|dismissed) ;;
    *)
      if [[ "$JSON_OUTPUT" == true ]]; then
        json_error "Invalid status '$NEW_STATUS': must be open, reviewed, promoted, or dismissed"
      fi
      echo "[followup] Error: Invalid status '$NEW_STATUS'. Must be: open, reviewed, promoted, dismissed." >&2
      exit 1
      ;;
  esac
fi

# --promoted-to only valid when status is promoted
if [[ -n "$PROMOTED_TO" && "$NEW_STATUS" != "promoted" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "--promoted-to requires --status promoted"
  fi
  echo "[followup] Error: --promoted-to requires --status promoted." >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
ITEM_DIR="$FOLLOWUPS_DIR/$ID"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Follow-up not found: $ID"
  fi
  echo "[followup] Error: Follow-up not found: $ID" >&2
  exit 1
fi

META="$ITEM_DIR/_meta.json"

if [[ ! -f "$META" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No _meta.json found for: $ID"
  fi
  echo "[followup] Error: No _meta.json found for: $ID" >&2
  exit 1
fi

# Apply updates via python3 to safely handle JSON
python3 -c "
import json, sys

meta_file = sys.argv[1]
new_status = sys.argv[2]       # empty string = no change
promoted_to = sys.argv[3]      # empty string = no change
resolution = sys.argv[4]       # empty string = no change
timestamp = sys.argv[5]

with open(meta_file) as f:
    meta = json.load(f)

changed = False

if new_status:
    meta['status'] = new_status
    changed = True

if promoted_to:
    meta['promoted_to'] = promoted_to
    changed = True

if resolution:
    meta['resolution'] = resolution
    changed = True

if changed:
    meta['updated'] = timestamp
    with open(meta_file, 'w') as f:
        json.dump(meta, f, indent=2)
    f.close()
    with open(meta_file, 'a') as f:
        f.write('\n')
" "$META" "$NEW_STATUS" "$PROMOTED_TO" "$RESOLUTION" "$(timestamp_iso)"

# Update the followup index
if [[ -x "$SCRIPT_DIR/update-followup-index.sh" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    bash "$SCRIPT_DIR/update-followup-index.sh" > /dev/null 2>&1 || true
    json_output "$(cat "$META")"
  fi
  bash "$SCRIPT_DIR/update-followup-index.sh"
else
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_output "$(cat "$META")"
  fi
fi

if [[ -n "$NEW_STATUS" ]]; then
  echo "Updated follow-up '$ID': status → $NEW_STATUS"
else
  echo "Updated follow-up '$ID'"
fi
