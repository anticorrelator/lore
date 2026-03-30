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
JSON_OUTPUT=false

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
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    *)
      echo "[work] Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# JSON output: return the plans array from _index.json directly
# With --all, also return the archived array
if [[ "$JSON_OUTPUT" == true ]]; then
  if [[ "$SHOW_ALL" == true ]]; then
    python3 -c "
import json, sys
with open('$INDEX') as f:
    data = json.load(f)
result = {'plans': data.get('plans', []), 'archived': data.get('archived', [])}
print(json.dumps(result))
"
  else
    python3 -c "
import json, sys
with open('$INDEX') as f:
    data = json.load(f)
print(json.dumps(data.get('plans', [])))
"
  fi
  exit 0
fi

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
CURRENT_ISSUE=""
CURRENT_PR=""
CURRENT_HAS_PLAN=""
ACTIVE_COUNT=0
HAS_ANY_ISSUE=false
HAS_ANY_PR=false
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
  if echo "$line" | grep -q '"issue"'; then
    CURRENT_ISSUE=$(echo "$line" | sed 's/.*"issue"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
  fi
  if echo "$line" | grep -q '"pr"'; then
    CURRENT_PR=$(echo "$line" | sed 's/.*"pr"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/')
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
      CURRENT_ISSUE=""
      CURRENT_PR=""
      CURRENT_HAS_PLAN=""
      continue
    fi

    REL_DATE=$(relative_date "$CURRENT_UPDATED")

    # Track whether any item has issue/pr populated
    [[ -n "$CURRENT_ISSUE" ]] && HAS_ANY_ISSUE=true
    [[ -n "$CURRENT_PR" ]] && HAS_ANY_PR=true

    # Format issue/pr with # prefix when populated
    local_issue=""
    local_pr=""
    [[ -n "$CURRENT_ISSUE" ]] && local_issue="#${CURRENT_ISSUE}"
    [[ -n "$CURRENT_PR" ]] && local_pr="#${CURRENT_PR}"

    ITEMS="${ITEMS}${CURRENT_SLUG}|${CURRENT_STATUS}|${REL_DATE}|${local_issue}|${local_pr}|${CURRENT_HAS_PLAN}\n"
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))

    # Reset
    CURRENT_SLUG=""
    CURRENT_TITLE=""
    CURRENT_STATUS=""
    CURRENT_UPDATED=""
    CURRENT_ISSUE=""
    CURRENT_PR=""
    CURRENT_HAS_PLAN=""
  fi
done < "$INDEX"

# Count archived items — prefer index, fall back to filesystem
ARCHIVE_DIR="$WORK_DIR/_archive"
ARCHIVE_COUNT=0
ARCHIVE_COUNT=$(python3 -c "
import json, os
index = '$INDEX'
archive_dir = '$ARCHIVE_DIR'
try:
    with open(index) as f:
        data = json.load(f)
    archived = data.get('archived', None)
    if archived is not None:
        print(len(archived))
    elif os.path.isdir(archive_dir):
        entries = [d for d in os.listdir(archive_dir) if os.path.isdir(os.path.join(archive_dir, d))]
        print(len(entries))
    else:
        print(0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)

# Output
draw_separator "Work Items"
echo ""

if [[ $ACTIVE_COUNT -eq 0 ]]; then
  if [[ -n "$FILTER_STATUS" ]]; then
    echo "No work items with status: $FILTER_STATUS"
  else
    echo "No active work items."
  fi
else
  # Build column spec and select columns conditionally
  # Row data is: slug(1)|status(2)|updated(3)|issue(4)|pr(5)|plan(6)
  COL_SPEC="SLUG:flex:100:left|STATUS:fixed:8:left|UPDATED:fixed:10:left"
  KEEP_COLS="1,2,3"
  if [[ "$HAS_ANY_ISSUE" == true ]]; then
    COL_SPEC="${COL_SPEC}|ISSUE:fixed:8:left"
    KEEP_COLS="${KEEP_COLS},4"
  fi
  if [[ "$HAS_ANY_PR" == true ]]; then
    COL_SPEC="${COL_SPEC}|PR:fixed:8:left"
    KEEP_COLS="${KEEP_COLS},5"
  fi
  COL_SPEC="${COL_SPEC}|PLAN:fixed:4:left"
  KEEP_COLS="${KEEP_COLS},6"

  # Print table with only the relevant columns
  echo -e "$ITEMS" | grep -v '^$' | cut -d'|' -f"$KEEP_COLS" | render_table "$COL_SPEC"
fi

echo ""
echo "Active: $ACTIVE_COUNT | Archived: $ARCHIVE_COUNT"

if [[ "$SHOW_ALL" == true && $ARCHIVE_COUNT -gt 0 ]]; then
  echo ""
  echo "--- Archived ---"
  python3 -c "
import json, os, sys

index_path = '$INDEX'
archive_dir = '$ARCHIVE_DIR'

try:
    with open(index_path) as f:
        data = json.load(f)
    archived = data.get('archived', None)
    if archived is not None:
        for item in archived:
            slug = item.get('slug', '')
            title = item.get('title', slug)
            refs = ''
            issue = item.get('issue', '')
            pr = item.get('pr', '')
            if issue:
                refs += f' issue:#{issue}'
            if pr:
                refs += f' pr:#{pr}'
            print(f'  {slug}: {title}{refs}')
        sys.exit(0)
except Exception:
    pass

# Fallback: filesystem scan
if not os.path.isdir(archive_dir):
    sys.exit(0)
for slug in sorted(os.listdir(archive_dir)):
    item_dir = os.path.join(archive_dir, slug)
    if not os.path.isdir(item_dir):
        continue
    meta_path = os.path.join(item_dir, '_meta.json')
    if os.path.exists(meta_path):
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            title = meta.get('title', slug)
            refs = ''
            issue = meta.get('issue', '')
            pr = meta.get('pr', '')
            if issue:
                refs += f' issue:#{issue}'
            if pr:
                refs += f' pr:#{pr}'
            print(f'  {slug}: {title}{refs}')
        except Exception:
            print(f'  {slug}')
    else:
        print(f'  {slug}')
"
fi

echo ""
draw_separator
