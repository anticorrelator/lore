#!/usr/bin/env bash
# update-plan-index.sh — Regenerate _plans/_index.json from _meta.json files
# Usage: bash update-plan-index.sh [directory]
# Scans all _plans/*/_meta.json files and rebuilds the index

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

PLANS_DIR="$KNOWLEDGE_DIR/_plans"

if [[ ! -d "$PLANS_DIR" ]]; then
  echo "No plans directory found at: $PLANS_DIR"
  exit 1
fi

INDEX="$PLANS_DIR/_index.json"
REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Start JSON
echo '{' > "$INDEX"
echo "  \"version\": 1," >> "$INDEX"
echo "  \"repo\": \"$REPO_NAME\"," >> "$INDEX"
echo "  \"last_updated\": \"$TIMESTAMP\"," >> "$INDEX"
echo '  "plans": [' >> "$INDEX"

FIRST=true

# Scan active plan directories (exclude _archive and _index.json)
for meta_file in "$PLANS_DIR"/*/_meta.json; do
  # Handle no matches
  [[ -e "$meta_file" ]] || continue

  PLAN_DIR=$(dirname "$meta_file")
  SLUG=$(basename "$PLAN_DIR")

  # Skip _archive
  [[ "$SLUG" == "_archive" ]] && continue

  # Extract fields from _meta.json using simple grep/sed
  TITLE=$(grep '"title"' "$meta_file" | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1)
  STATUS=$(grep '"status"' "$meta_file" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1)
  CREATED=$(grep '"created"' "$meta_file" | sed 's/.*"created"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1)
  UPDATED=$(grep '"updated"' "$meta_file" | sed 's/.*"updated"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1)

  # Extract JSON arrays using awk for reliability
  # Handles both single-line ["a","b"] and multi-line arrays
  BRANCHES=$(awk '
    /"branches"/ {
      # Get everything from [ to ]
      match($0, /\[.*\]/)
      if (RSTART > 0) {
        arr = substr($0, RSTART+1, RLENGTH-2)
        gsub(/[[:space:]]/, "", arr)
        print arr
        next
      }
      # Multi-line array
      collecting = 1
      buf = ""
      next
    }
    collecting && /\]/ {
      buf = buf $0
      gsub(/[[:space:]\]\[]/, "", buf)
      print buf
      collecting = 0
      next
    }
    collecting { buf = buf $0 }
  ' "$meta_file")

  TAGS=$(awk '
    /"tags"/ {
      match($0, /\[.*\]/)
      if (RSTART > 0) {
        arr = substr($0, RSTART+1, RLENGTH-2)
        gsub(/[[:space:]]/, "", arr)
        print arr
        next
      }
      collecting = 1
      buf = ""
      next
    }
    collecting && /\]/ {
      buf = buf $0
      gsub(/[[:space:]\]\[]/, "", buf)
      print buf
      collecting = 0
      next
    }
    collecting { buf = buf $0 }
  ' "$meta_file")

  # Check if plan.md exists
  HAS_PLAN_DOC=false
  [[ -f "$PLAN_DIR/plan.md" ]] && HAS_PLAN_DOC=true

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

echo "Plan index updated: $INDEX"
