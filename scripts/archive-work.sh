#!/usr/bin/env bash
# archive-work.sh — Archive a work item by slug
# Usage: bash archive-work.sh <slug>
# Updates _meta.json status to "archived", moves to _archive/, rebuilds index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 1 || -z "$1" ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: bash archive-work.sh <slug>" >&2
  exit 1
fi

SLUG="$1"
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

ITEM_DIR="$WORK_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  echo "[work] Error: Work item not found: $SLUG" >&2
  echo "Available items:" >&2
  for d in "$WORK_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" == "_archive" ]] && continue
    echo "  $name" >&2
  done
  exit 1
fi

META_FILE="$ITEM_DIR/_meta.json"

if [[ ! -f "$META_FILE" ]]; then
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# Check if already archived
CURRENT_STATUS=$(json_field "status" "$META_FILE")
if [[ "$CURRENT_STATUS" == "archived" ]]; then
  echo "[work] Error: Work item '$SLUG' is already archived." >&2
  exit 1
fi

# Update status in _meta.json
sed -i '' 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "archived"/' "$META_FILE"

# Add archived timestamp
ARCHIVE_TS=$(timestamp_iso)
sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ARCHIVE_TS\"/" "$META_FILE"

# Create _archive directory if needed
ARCHIVE_DIR="$WORK_DIR/_archive"
mkdir -p "$ARCHIVE_DIR"

# Check for name collision in archive
if [[ -d "$ARCHIVE_DIR/$SLUG" ]]; then
  echo "[work] Error: Archive already contains an item named '$SLUG'." >&2
  exit 1
fi

# Move to archive
mv "$ITEM_DIR" "$ARCHIVE_DIR/$SLUG"

# Rebuild index
"$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true

# Get title for confirmation
TITLE=$(json_field "title" "$ARCHIVE_DIR/$SLUG/_meta.json")

echo "[work] Archived: $SLUG ($TITLE)"
echo "[work] Moved to: _work/_archive/$SLUG"
