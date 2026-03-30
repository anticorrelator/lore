#!/usr/bin/env bash
# delete-work.sh — Permanently delete a work item by slug
# Usage: bash delete-work.sh [--json] <slug>
# Accepts slugs from active (_work/<slug>/) or archive (_work/_archive/<slug>/).
# Removes the directory and rebuilds the index.

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
  echo "Usage: bash delete-work.sh [--json] <slug>" >&2
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

# Locate the item — check active first, then archive
ITEM_DIR=""
DELETED_FROM=""

if [[ -d "$WORK_DIR/$SLUG" ]]; then
  ITEM_DIR="$WORK_DIR/$SLUG"
  DELETED_FROM="active"
elif [[ -d "$WORK_DIR/_archive/$SLUG" ]]; then
  ITEM_DIR="$WORK_DIR/_archive/$SLUG"
  DELETED_FROM="archive"
fi

if [[ -z "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Work item not found: $SLUG"
  fi
  echo "[work] Error: Work item not found: $SLUG" >&2
  exit 1
fi

# Get title before deletion (for human output)
TITLE=""
META_FILE="$ITEM_DIR/_meta.json"
if [[ -f "$META_FILE" ]]; then
  TITLE=$(json_field "title" "$META_FILE")
fi

# Delete the directory
rm -rf "$ITEM_DIR"

# Rebuild index
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, sys
print(json.dumps({
    'slug': sys.argv[1],
    'deleted_from': sys.argv[2]
}))
" "$SLUG" "$DELETED_FROM"
  exit 0
fi

echo "[work] Deleted: $SLUG${TITLE:+ ($TITLE)}"
echo "[work] Removed from: $DELETED_FROM"
