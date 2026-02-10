#!/usr/bin/env bash
# list-work.sh — List all active work items with summary info
# Usage: bash list-work.sh [--all] [--status <status>]
# Reads _index.json and formats a table of work items.
# --all: include archived items
# --status: filter by status (active, completed, archived)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "[work] Error: No work directory found. Run /work create first." >&2
  exit 1
fi

INDEX="$WORK_DIR/_index.json"

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true
fi

if [[ ! -f "$INDEX" ]]; then
  echo "[work] Error: No work index found and could not regenerate." >&2
  exit 1
fi

# Parse arguments
SHOW_ALL=false
FILTER_STATUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      SHOW_ALL=true
      shift
      ;;
    --status)
      FILTER_STATUS="$2"
      shift 2
      ;;
    *)
      echo "[work] Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Calculate relative date (macOS compatible)
NOW_EPOCH=$(date +%s)

relative_date() {
  local iso_date="$1"
  if [[ -z "$iso_date" ]]; then
    echo "unknown"
    return
  fi
  local epoch
  epoch=$(iso_to_epoch "$iso_date")
  if [[ "$epoch" -eq 0 ]]; then
    echo "unknown"
    return
  fi
  local days_ago=$(( (NOW_EPOCH - epoch) / 86400 ))
  if [[ $days_ago -eq 0 ]]; then
    echo "today"
  elif [[ $days_ago -eq 1 ]]; then
    echo "yesterday"
  else
    echo "${days_ago}d ago"
  fi
}

# Parse work items from _index.json
CURRENT_SLUG=""
CURRENT_TITLE=""
CURRENT_STATUS=""
CURRENT_UPDATED=""
CURRENT_HAS_PLAN=""
ACTIVE_COUNT=0
ITEMS=""

while IFS= read -r line; do
  if echo "$line" | grep -q '"slug"'; then
    CURRENT_SLUG=$(echo "$line" | sed 's/.*"slug"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
  fi
  if echo "$line" | grep -q '"title"'; then
    CURRENT_TITLE=$(echo "$line" | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
  fi
  if echo "$line" | grep -q '"status"'; then
    CURRENT_STATUS=$(echo "$line" | sed 's/.*"status"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
  fi
  if echo "$line" | grep -q '"updated"'; then
    CURRENT_UPDATED=$(echo "$line" | sed 's/.*"updated"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
  fi

  # End of entry — has_plan_doc is the last field
  if echo "$line" | grep -q '"has_plan_doc"'; then
    if echo "$line" | grep -q 'true'; then
      CURRENT_HAS_PLAN="yes"
    else
      CURRENT_HAS_PLAN="no"
    fi

    # Apply status filter
    if [[ -n "$FILTER_STATUS" && "$CURRENT_STATUS" != "$FILTER_STATUS" ]]; then
      CURRENT_SLUG=""
      CURRENT_TITLE=""
      CURRENT_STATUS=""
      CURRENT_UPDATED=""
      CURRENT_HAS_PLAN=""
      continue
    fi

    REL_DATE=$(relative_date "$CURRENT_UPDATED")

    # Truncate title for display
    DISPLAY_TITLE="$CURRENT_TITLE"
    if [[ ${#DISPLAY_TITLE} -gt 50 ]]; then
      DISPLAY_TITLE="${DISPLAY_TITLE:0:47}..."
    fi

    ITEMS="${ITEMS}  ${CURRENT_SLUG}|${DISPLAY_TITLE}|${CURRENT_STATUS}|${REL_DATE}|${CURRENT_HAS_PLAN}\n"
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))

    # Reset
    CURRENT_SLUG=""
    CURRENT_TITLE=""
    CURRENT_STATUS=""
    CURRENT_UPDATED=""
    CURRENT_HAS_PLAN=""
  fi
done < "$INDEX"

# Count archived items
ARCHIVE_DIR="$WORK_DIR/_archive"
ARCHIVE_COUNT=0
if [[ -d "$ARCHIVE_DIR" ]]; then
  ARCHIVE_COUNT=$(ls -1d "$ARCHIVE_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
fi

# Output
echo "=== Work Items ==="
echo ""

if [[ $ACTIVE_COUNT -eq 0 ]]; then
  if [[ -n "$FILTER_STATUS" ]]; then
    echo "No work items with status: $FILTER_STATUS"
  else
    echo "No active work items."
  fi
else
  # Print table header
  printf "  %-30s %-50s %-10s %-12s %-5s\n" "SLUG" "TITLE" "STATUS" "UPDATED" "PLAN"
  printf "  %-30s %-50s %-10s %-12s %-5s\n" "----" "-----" "------" "-------" "----"

  # Print items
  echo -e "$ITEMS" | while IFS='|' read -r slug title status updated plan; do
    [[ -z "$slug" ]] && continue
    printf "  %-30s %-50s %-10s %-12s %-5s\n" "$slug" "$title" "$status" "$updated" "$plan"
  done
fi

echo ""
echo "Active: $ACTIVE_COUNT | Archived: $ARCHIVE_COUNT"

if [[ "$SHOW_ALL" == true && $ARCHIVE_COUNT -gt 0 ]]; then
  echo ""
  echo "--- Archived ---"
  for archive_dir in "$ARCHIVE_DIR"/*/; do
    [[ -d "$archive_dir" ]] || continue
    slug=$(basename "$archive_dir")
    meta="$archive_dir/_meta.json"
    if [[ -f "$meta" ]]; then
      title=$(json_field "title" "$meta")
      echo "  $slug: $title"
    else
      echo "  $slug"
    fi
  done
fi

echo ""
echo "=== End Work Items ==="
