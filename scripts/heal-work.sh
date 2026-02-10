#!/usr/bin/env bash
# heal-work.sh — Detect and fix structural issues in _work/
# Usage: bash heal-work.sh [directory]
# Checks for missing _index.json, orphan dirs, missing notes.md, stale index, inactive items.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TARGET_DIR="${1:-$(pwd)}"
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "No work directory found."
  exit 0
fi

FIXES=0
WARNINGS=0
FINDINGS=()

# --- (a) Missing _index.json ---
if [[ ! -f "$WORK_DIR/_index.json" ]]; then
  bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR" >/dev/null
  FINDINGS+=("[heal] Regenerated missing _index.json")
  FIXES=$((FIXES + 1))
fi

# --- (b) Orphan directories (no _meta.json) ---
for dir in "$WORK_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == "_archive" ]] && continue

  if [[ ! -f "$dir/_meta.json" ]]; then
    # Title case the dirname: replace hyphens with spaces, capitalize each word
    TITLE=$(echo "$DIRNAME" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
    TIMESTAMP=$(timestamp_iso)
    cat > "$dir/_meta.json" << METAEOF
{
  "slug": "$DIRNAME",
  "title": "$TITLE",
  "status": "active",
  "branches": [],
  "tags": [],
  "created": "$TIMESTAMP",
  "updated": "$TIMESTAMP",
  "related_knowledge": []
}
METAEOF
    FINDINGS+=("[heal] Created missing _meta.json for '$DIRNAME'")
    FIXES=$((FIXES + 1))
  fi
done

# --- (c) Missing notes.md ---
for dir in "$WORK_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == "_archive" ]] && continue

  if [[ -f "$dir/_meta.json" ]] && [[ ! -f "$dir/notes.md" ]]; then
    # Extract title from _meta.json
    TITLE=$(json_field "title" "$dir/_meta.json")
    cat > "$dir/notes.md" << NOTESEOF
# Session Notes: $TITLE

<!-- Append session entries below. Each entry records what happened in a session. -->
NOTESEOF
    FINDINGS+=("[heal] Created missing notes.md for '$DIRNAME'")
    FIXES=$((FIXES + 1))
  fi
done

# --- (d) Stale index ---
# Count actual work item directories (with _meta.json, excluding _archive)
ACTUAL_COUNT=0
for dir in "$WORK_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == "_archive" ]] && continue
  [[ -f "$dir/_meta.json" ]] && ACTUAL_COUNT=$((ACTUAL_COUNT + 1))
done

# Count entries in index
INDEX_COUNT=0
if [[ -f "$WORK_DIR/_index.json" ]]; then
  INDEX_COUNT=$(grep -c '"slug"' "$WORK_DIR/_index.json" 2>/dev/null || echo "0")
fi

if [[ "$ACTUAL_COUNT" -ne "$INDEX_COUNT" ]]; then
  bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR" >/dev/null
  FINDINGS+=("[heal] Reindexed: $ACTUAL_COUNT items (was $INDEX_COUNT in index)")
  FIXES=$((FIXES + 1))
fi

# --- (e) Inactive items (>30 days old, still active) ---
NOW_EPOCH=$(date -u "+%s")
THIRTY_DAYS=$((30 * 86400))

for dir in "$WORK_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == "_archive" ]] && continue
  [[ -f "$dir/_meta.json" ]] || continue

  STATUS=$(json_field "status" "$dir/_meta.json")
  [[ "$STATUS" == "active" ]] || continue

  UPDATED=$(json_field "updated" "$dir/_meta.json")
  [[ -n "$UPDATED" ]] || continue

  # Parse ISO timestamp to epoch
  UPDATED_EPOCH=$(iso_to_epoch "$UPDATED")

  if [[ "$UPDATED_EPOCH" -gt 0 ]]; then
    AGE_SECONDS=$((NOW_EPOCH - UPDATED_EPOCH))
    if [[ "$AGE_SECONDS" -gt "$THIRTY_DAYS" ]]; then
      AGE_DAYS=$((AGE_SECONDS / 86400))
      FINDINGS+=("[heal] Stale: '$DIRNAME' — inactive $AGE_DAYS days, consider /work archive")
      WARNINGS=$((WARNINGS + 1))
    fi
  fi
done

# --- Report ---
echo "=== Work Heal Report ==="
if [[ ${#FINDINGS[@]} -eq 0 ]]; then
  echo "No issues found."
else
  for finding in "${FINDINGS[@]}"; do
    echo "$finding"
  done
  echo "Fixed: $FIXES issues"
  echo "Warnings: $WARNINGS items"
fi
echo "=== End Heal Report ==="
