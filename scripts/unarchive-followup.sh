#!/usr/bin/env bash
# unarchive-followup.sh — Unarchive a follow-up by id
# Usage: bash unarchive-followup.sh [--json] <id>
# Moves _followups/_archive/<id>/ back to _followups/<id>/, bumps "updated",
# and rebuilds the follow-up index. Preserves the current status (does NOT
# reopen or change status).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=false
ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
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
  echo "Usage: bash unarchive-followup.sh [--json] <id>" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"

if [[ ! -d "$FOLLOWUPS_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No followups directory found"
  fi
  echo "[followup] Error: No followups directory found." >&2
  exit 1
fi

ARCHIVE_DIR="$FOLLOWUPS_DIR/_archive"

if [[ ! -d "$ARCHIVE_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No archive directory found"
  fi
  echo "[followup] Error: No archive directory found." >&2
  exit 1
fi

ITEM_DIR="$ARCHIVE_DIR/$ID"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Archived follow-up not found: $ID"
  fi
  echo "[followup] Error: Archived follow-up not found: $ID" >&2
  echo "Available archived follow-ups:" >&2
  for d in "$ARCHIVE_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    echo "  $name" >&2
  done
  exit 1
fi

META_FILE="$ITEM_DIR/_meta.json"

if [[ ! -f "$META_FILE" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No _meta.json found for: $ID"
  fi
  echo "[followup] Error: No _meta.json found for: $ID" >&2
  exit 1
fi

# Check for name collision in active followups
if [[ -d "$FOLLOWUPS_DIR/$ID" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Active follow-ups already contain an item named '$ID'"
  fi
  echo "[followup] Error: Active follow-ups already contain an item named '$ID'." >&2
  exit 1
fi

# Preserve current status; only bump updated timestamp.
CURRENT_STATUS=$(json_field "status" "$META_FILE")
UNARCHIVE_TS=$(timestamp_iso)
sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$UNARCHIVE_TS\"/" "$META_FILE"

# Move back to active
mv "$ITEM_DIR" "$FOLLOWUPS_DIR/$ID"

# Get title for confirmation
TITLE=$(json_field "title" "$FOLLOWUPS_DIR/$ID/_meta.json")

if [[ "$JSON_OUTPUT" == true ]]; then
  "$SCRIPT_DIR/update-followup-index.sh" >/dev/null 2>&1 || true
  python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1],
    'restored_to': sys.argv[2],
    'status': sys.argv[3],
    'title': sys.argv[4]
}))
" "$ID" "_followups/$ID" "$CURRENT_STATUS" "$TITLE"
  exit 0
fi

# Rebuild index (human branch)
"$SCRIPT_DIR/update-followup-index.sh" >/dev/null 2>/dev/null || true

echo "[followup] Unarchived: $ID ($TITLE)"
echo "[followup] Status preserved: $CURRENT_STATUS"
echo "[followup] Restored to: _followups/$ID"
