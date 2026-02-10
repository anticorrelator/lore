#!/usr/bin/env bash
# load-work-item.sh — Load a single work item's full context for agent summarization
# Usage: bash load-work-item.sh <slug>
# Output: Structured dump of _meta.json fields, plan.md (if exists), and last 3 notes entries.
# The agent receiving this output will summarize it — raw content, not pre-summarized.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Validate arguments ---
if [[ $# -lt 1 || -z "$1" ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: bash load-work-item.sh <slug>" >&2
  exit 1
fi

SLUG="$1"

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir) || {
  echo "[work] Error: Could not resolve knowledge directory" >&2
  exit 1
}

WORK_DIR="$KNOWLEDGE_DIR/_work"
ITEM_DIR="$WORK_DIR/$SLUG"

# Check if item exists — if not, check archive, then fail
if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ -d "$WORK_DIR/_archive/$SLUG" ]]; then
    echo "[work] '$SLUG' is archived. Use /work search to view."
    exit 0
  fi
  echo "[work] Error: Work item not found: $SLUG" >&2
  exit 1
fi

META="$ITEM_DIR/_meta.json"

if [[ ! -f "$META" ]]; then
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# --- Extract metadata fields ---
TITLE=$(json_field "title" "$META")
STATUS=$(json_field "status" "$META")
CREATED=$(json_field "created" "$META")
UPDATED=$(json_field "updated" "$META")

# Extract branches and tags as comma-separated display strings
BRANCHES=$(json_array_field "branches" "$META" | sed 's/"//g; s/,/, /g')
TAGS=$(json_array_field "tags" "$META" | sed 's/"//g; s/,/, /g')

# --- Output structured metadata ---
echo "=== Work Item: $TITLE ==="
echo "Slug: $SLUG"
echo "Status: $STATUS"
echo "Branches: ${BRANCHES:-none}"
echo "Tags: ${TAGS:-none}"
echo "Created: $CREATED"
echo "Updated: $UPDATED"
echo ""

# --- Plan document ---
PLAN_FILE="$ITEM_DIR/plan.md"
if [[ -f "$PLAN_FILE" ]]; then
  echo "--- Plan ---"
  cat "$PLAN_FILE"
  echo ""
  echo "--- End Plan ---"
  echo ""
fi

# --- Session notes (last 3 entries) ---
NOTES_FILE="$ITEM_DIR/notes.md"
echo "--- Recent Notes ---"
if [[ -f "$NOTES_FILE" ]]; then
  HEADING_COUNT=$(grep -c '^## ' "$NOTES_FILE" 2>/dev/null || true)

  if [[ "$HEADING_COUNT" -gt 0 ]]; then
    # Find the line number of the Nth-to-last ## heading (last 3)
    START_LINE=$(awk -v max_entries=3 '
      /^## / { heading_lines[++count] = NR }
      END {
        start_from = count - max_entries + 1
        if (start_from < 1) start_from = 1
        print heading_lines[start_from]
      }
    ' "$NOTES_FILE")

    if [[ -n "$START_LINE" && "$START_LINE" -gt 0 ]]; then
      tail -n +"$START_LINE" "$NOTES_FILE"
    else
      echo "(no session notes)"
    fi
  else
    echo "(no session notes)"
  fi
else
  echo "(no session notes)"
fi
echo "--- End Notes ---"

echo ""
echo "=== End Work Item ==="
