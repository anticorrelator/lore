#!/usr/bin/env bash
# load-work-item.sh — Load a single work item's full context for agent summarization
# Usage: bash load-work-item.sh <slug>
# Output: Structured dump of _meta.json fields, plan.md (if exists), and last 3 notes entries.
# The agent receiving this output will summarize it — raw content, not pre-summarized.

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
  echo "Usage: bash load-work-item.sh [--json] <slug>" >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir) || {
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Could not resolve knowledge directory"
  fi
  echo "[work] Error: Could not resolve knowledge directory" >&2
  exit 1
}

WORK_DIR="$KNOWLEDGE_DIR/_work"
ITEM_DIR="$WORK_DIR/$SLUG"

# Check if item exists — if not, check archive, then fail
ARCHIVED=false
if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ -d "$WORK_DIR/_archive/$SLUG" ]]; then
    ITEM_DIR="$WORK_DIR/_archive/$SLUG"
    ARCHIVED=true
  else
    if [[ "$JSON_OUTPUT" == true ]]; then
      json_error "Work item not found: $SLUG"
    fi
    echo "[work] Error: Work item not found: $SLUG" >&2
    exit 1
  fi
fi

META="$ITEM_DIR/_meta.json"

if [[ ! -f "$META" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No _meta.json found for: $SLUG"
  fi
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# --- JSON output mode ---
if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -B "$SCRIPT_DIR/work-evidence.py" --item-dir "$ITEM_DIR" \
    --knowledge-dir "$KNOWLEDGE_DIR" --work
  exit 0
fi

# --- Extract metadata fields ---
TITLE=$(json_field "title" "$META")
STATUS=$(json_field "status" "$META")
CREATED=$(json_field "created" "$META")
UPDATED=$(json_field "updated" "$META")
ISSUE=$(json_field "issue" "$META" || true)
PR=$(json_field "pr" "$META" || true)
PROJECT=$(json_field "project" "$META" || true)
INTENT_ANCHOR=$(json_field "intent_anchor" "$META" || true)

# Extract branches, tags, related_work, and blocked_by as comma-separated
# display strings.
BRANCHES=$(json_array_field "branches" "$META" | sed 's/"//g; s/,/, /g')
TAGS=$(json_array_field "tags" "$META" | sed 's/"//g; s/,/, /g')
RELATED_WORK=$(json_array_field "related_work" "$META" | sed 's/"//g; s/,/, /g')
BLOCKED_BY=$(json_array_field "blocked_by" "$META" | sed 's/"//g; s/,/, /g')

# ceremony_depth is numeric (unquoted), so json_field can't read it.
CEREMONY_DEPTH=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        v = json.load(f).get("ceremony_depth")
except Exception:
    v = None
if v is not None:
    print(v)
' "$META" || true)

# --- Output structured metadata ---
if [[ "$ARCHIVED" == true ]]; then
  draw_separator "[archived] Work Item: $TITLE"
  echo "[archived] This work item has been archived."
  echo ""
else
  draw_separator "Work Item: $TITLE"
fi
echo "Slug: $SLUG"
echo "Status: $STATUS"
if [[ -n "$PROJECT" ]]; then
  echo "Project: $PROJECT"
fi
echo "Branches: ${BRANCHES:-none}"
echo "Tags: ${TAGS:-none}"
if [[ -n "$RELATED_WORK" ]]; then
  echo "Related: $RELATED_WORK"
fi
if [[ -n "$BLOCKED_BY" ]]; then
  echo "Blocked by: $BLOCKED_BY"
fi
echo "Issue: ${ISSUE:-none}"
echo "PR: ${PR:-none}"
if [[ -n "$INTENT_ANCHOR" ]]; then
  echo "Intent anchor: $INTENT_ANCHOR"
fi
if [[ -n "$CEREMONY_DEPTH" ]]; then
  echo "Ceremony depth: $CEREMONY_DEPTH"
fi
echo "Created: $CREATED"
echo "Updated: $UPDATED"
echo ""

# --- Plan document ---
PLAN_FILE="$ITEM_DIR/plan.md"
if [[ -f "$PLAN_FILE" ]]; then
  draw_separator "Plan"
  cat "$PLAN_FILE"
  echo ""
  draw_separator
  echo ""
fi

# --- Session notes (last 3 entries) ---
NOTES_FILE="$ITEM_DIR/notes.md"
draw_separator "Recent Notes"
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
draw_separator

# --- Additional .md files (sorted, excluding already-shown files) ---
for md_file in $(ls "$ITEM_DIR"/*.md 2>/dev/null | sort); do
  basename_file=$(basename "$md_file")
  case "$basename_file" in
    plan.md|notes.md) continue ;;
  esac
  # Strip .md extension and title-case for display
  display_name="${basename_file%.md}"
  draw_separator "$display_name"
  cat "$md_file"
  echo ""
  draw_separator
  echo ""
done

echo ""
draw_separator
