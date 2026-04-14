#!/usr/bin/env bash
# archive-followup.sh — Archive a follow-up by id
# Usage: bash archive-followup.sh [--json] <id>
# Preserves terminal status ("reviewed", "promoted", "dismissed"), bumps
# "updated", moves directory to _followups/_archive/<id>/, and rebuilds the
# follow-up index.

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
  echo "Usage: bash archive-followup.sh [--json] <id>" >&2
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

ITEM_DIR="$FOLLOWUPS_DIR/$ID"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Follow-up not found: $ID"
  fi
  echo "[followup] Error: Follow-up not found: $ID" >&2
  echo "Available follow-ups:" >&2
  for d in "$FOLLOWUPS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" == "_archive" ]] && continue
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

# Require a terminal status before archiving
CURRENT_STATUS=$(json_field "status" "$META_FILE")
case "$CURRENT_STATUS" in
  reviewed|promoted|dismissed)
    ;;
  *)
    if [[ "$JSON_OUTPUT" == true ]]; then
      json_error "Follow-up '$ID' has non-terminal status '$CURRENT_STATUS'; must be reviewed, promoted, or dismissed"
    fi
    echo "[followup] Error: Follow-up '$ID' has non-terminal status '$CURRENT_STATUS'; must be reviewed, promoted, or dismissed." >&2
    exit 1
    ;;
esac

# Bump updated timestamp (preserve existing terminal status)
ARCHIVE_TS=$(timestamp_iso)
sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ARCHIVE_TS\"/" "$META_FILE"

# Create _archive directory if needed
ARCHIVE_DIR="$FOLLOWUPS_DIR/_archive"
mkdir -p "$ARCHIVE_DIR"

# Check for name collision in archive
if [[ -d "$ARCHIVE_DIR/$ID" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Archive already contains a follow-up named '$ID'"
  fi
  echo "[followup] Error: Archive already contains a follow-up named '$ID'." >&2
  exit 1
fi

# Move to archive
mv "$ITEM_DIR" "$ARCHIVE_DIR/$ID"

# Get title for confirmation
TITLE=$(json_field "title" "$ARCHIVE_DIR/$ID/_meta.json")

if [[ "$JSON_OUTPUT" == true ]]; then
  "$SCRIPT_DIR/update-followup-index.sh" >/dev/null 2>&1 || true
  python3 -c "
import json, sys
print(json.dumps({
    'id': sys.argv[1],
    'archived_to': sys.argv[2],
    'status': sys.argv[3],
    'title': sys.argv[4]
}))
" "$ID" "_followups/_archive/$ID" "$CURRENT_STATUS" "$TITLE"
  exit 0
fi

# Rebuild index (human branch)
"$SCRIPT_DIR/update-followup-index.sh" >/dev/null 2>/dev/null || true

echo "[followup] Archived: $ID ($TITLE)"
echo "[followup] Status preserved: $CURRENT_STATUS"
echo "[followup] Moved to: _followups/_archive/$ID"
