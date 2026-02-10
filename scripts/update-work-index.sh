#!/usr/bin/env bash
# update-work-index.sh — Regenerate _work/_index.json from _meta.json files
# Usage: bash update-work-index.sh [directory]
# Scans all _work/*/_meta.json files and rebuilds the index

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "No work directory found at: $WORK_DIR"
  exit 1
fi

INDEX="$WORK_DIR/_index.json"
REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Start JSON
echo '{' > "$INDEX"
echo "  \"version\": 1," >> "$INDEX"
echo "  \"repo\": \"$REPO_NAME\"," >> "$INDEX"
echo "  \"last_updated\": \"$TIMESTAMP\"," >> "$INDEX"
echo '  "plans": [' >> "$INDEX"

FIRST=true

# Scan active work directories (exclude _archive and _index.json)
for meta_file in "$WORK_DIR"/*/_meta.json; do
  # Handle no matches
  [[ -e "$meta_file" ]] || continue

  ITEM_DIR=$(dirname "$meta_file")
  SLUG=$(basename "$ITEM_DIR")

  # Skip _archive
  [[ "$SLUG" == "_archive" ]] && continue

  # Extract fields from _meta.json
  TITLE=$(json_field "title" "$meta_file")
  STATUS=$(json_field "status" "$meta_file")
  CREATED=$(json_field "created" "$meta_file")
  UPDATED=$(json_field "updated" "$meta_file")

  # Extract JSON arrays
  BRANCHES=$(json_array_field "branches" "$meta_file")
  TAGS=$(json_array_field "tags" "$meta_file")

  # Check if plan.md exists
  HAS_PLAN_DOC=false
  [[ -f "$ITEM_DIR/plan.md" ]] && HAS_PLAN_DOC=true

  # Add comma separator
  if [[ "$FIRST" == true ]]; then
    FIRST=false
  else
    echo '    ,' >> "$INDEX"
  fi

  cat >> "$INDEX" << ENTRY
    {
      "slug": "$SLUG",
      "title": "$TITLE",
      "status": "$STATUS",
      "branches": [${BRANCHES}],
      "tags": [${TAGS}],
      "created": "$CREATED",
      "updated": "$UPDATED",
      "has_plan_doc": $HAS_PLAN_DOC
    }
ENTRY

done

echo '  ]' >> "$INDEX"
echo '}' >> "$INDEX"

echo "Work index updated: $INDEX"
