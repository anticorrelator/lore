#!/usr/bin/env bash
# unarchive-work.sh — Unarchive a work item by slug
# Usage: bash unarchive-work.sh [--json] <slug>
# Moves _archive/<slug>/ back to _work/<slug>/, updates _meta.json status to "active", rebuilds index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=false
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Missing required argument: slug"
  fi
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: bash unarchive-work.sh [--json] <slug>" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No work directory found"
  fi
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

ARCHIVE_DIR="$WORK_DIR/_archive"

if [[ ! -d "$ARCHIVE_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No archive directory found"
  fi
  echo "[work] Error: No archive directory found." >&2
  exit 1
fi

ITEM_DIR="$ARCHIVE_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Archived work item not found: $SLUG"
  fi
  echo "[work] Error: Archived work item not found: $SLUG" >&2
  echo "Available archived items:" >&2
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
    json_error "No _meta.json found for: $SLUG"
  fi
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# Check for name collision in active work
if [[ -d "$WORK_DIR/$SLUG" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Active work already contains an item named '$SLUG'"
  fi
  echo "[work] Error: Active work already contains an item named '$SLUG'." >&2
  exit 1
fi

# Update status in _meta.json
sed -i '' 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "active"/' "$META_FILE"

# Update timestamp
UNARCHIVE_TS=$(timestamp_iso)
sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$UNARCHIVE_TS\"/" "$META_FILE"

# Move back to active work
mv "$ITEM_DIR" "$WORK_DIR/$SLUG"

# Rebuild index
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# Get title for confirmation
TITLE=$(json_field "title" "$WORK_DIR/$SLUG/_meta.json")

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, sys
print(json.dumps({
    'slug': sys.argv[1],
    'restored_to': sys.argv[2],
    'title': sys.argv[3]
}))
" "$SLUG" "_work/$SLUG" "$TITLE"
  exit 0
fi

echo "[work] Unarchived: $SLUG ($TITLE)"
echo "[work] Restored to: _work/$SLUG"
