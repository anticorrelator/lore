#!/usr/bin/env bash
# load-work.sh — SessionStart hook: show active work items, detect branch match
# Usage: bash load-work.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

WORK_DIR="$KNOWLEDGE_DIR/_work"

# Exit silently if no work directory
[[ -d "$WORK_DIR" ]] || exit 0

INDEX="$WORK_DIR/_index.json"

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || exit 0
fi

[[ -f "$INDEX" ]] || exit 0

# Check if there are any work items
WORK_COUNT=$(grep -c '"slug"' "$INDEX" 2>/dev/null || true)
WORK_COUNT=$(echo "$WORK_COUNT" | tr -d '[:space:]')
[[ "$WORK_COUNT" -gt 0 ]] || exit 0

# Get current git branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

OUTPUT=""
BRANCH_MATCH=""
ACTIVE_WORK=""
STALE_WORK=""
NOW_EPOCH=$(date +%s)

# Parse work items from index (line-by-line approach for portability)
# Read each entry by extracting fields
CURRENT_SLUG=""
CURRENT_TITLE=""
CURRENT_STATUS=""
CURRENT_UPDATED=""
CURRENT_BRANCHES=""

while IFS= read -r line; do
  # Detect slug
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
  # Collect branch entries within the branches array
  if echo "$line" | grep -q '"branches"'; then
    CURRENT_BRANCHES=""
  fi

  # End of a work entry — process it
  if echo "$line" | grep -q '"has_plan_doc"'; then
    if [[ "$CURRENT_STATUS" == "active" ]]; then
      # Check for branch match
      if [[ -n "$CURRENT_BRANCH" ]]; then
        # Read branches from _meta.json directly for accuracy
        META_FILE="$WORK_DIR/$CURRENT_SLUG/_meta.json"
        if [[ -f "$META_FILE" ]]; then
          if grep -q "\"$CURRENT_BRANCH\"" "$META_FILE" 2>/dev/null; then
            BRANCH_MATCH="$CURRENT_SLUG"
            # Get last notes entry
            NOTES_FILE="$WORK_DIR/$CURRENT_SLUG/notes.md"
            if [[ -f "$NOTES_FILE" ]]; then
              # Extract the last ## section (last session notes)
              LAST_ENTRY=$(awk '/^## [0-9]/{start=NR; content=""} start{content=content "\n" $0} END{print content}' "$NOTES_FILE" 2>/dev/null | head -8 || true)
            fi
          fi
        fi
      fi

      # Calculate relative date
      RELATIVE_DATE=""
      if [[ -n "$CURRENT_UPDATED" ]]; then
        # Parse ISO date to epoch
        UPDATED_EPOCH=$(iso_to_epoch "$CURRENT_UPDATED")
        if [[ "$UPDATED_EPOCH" -gt 0 ]]; then
          DAYS_AGO=$(( (NOW_EPOCH - UPDATED_EPOCH) / 86400 ))
          if [[ $DAYS_AGO -eq 0 ]]; then
            RELATIVE_DATE="today"
          elif [[ $DAYS_AGO -eq 1 ]]; then
            RELATIVE_DATE="yesterday"
          else
            RELATIVE_DATE="${DAYS_AGO}d ago"
          fi
          # Check for stale work items (>30 days)
          if [[ $DAYS_AGO -gt 30 ]]; then
            STALE_WORK="${STALE_WORK}- ${CURRENT_SLUG} — inactive ${DAYS_AGO} days, consider \`/work archive\`\n"
          fi
        fi
      fi

      ACTIVE_WORK="${ACTIVE_WORK}- ${CURRENT_SLUG}: ${CURRENT_TITLE} (updated ${RELATIVE_DATE:-unknown})\n"
    fi

    # Reset for next entry
    CURRENT_SLUG=""
    CURRENT_TITLE=""
    CURRENT_STATUS=""
    CURRENT_UPDATED=""
    CURRENT_BRANCHES=""
  fi
done < "$INDEX"

# Check notes.md mtime for staleness (>14 days without activity)
NOTES_STALE=""
STALE_THRESHOLD=$((14 * 86400))

for work_dir in "$WORK_DIR"/*/; do
  [[ -d "$work_dir" ]] || continue
  slug=$(basename "$work_dir")
  meta="$work_dir/_meta.json"
  notes="$work_dir/notes.md"

  # Only check active work items
  [[ -f "$meta" ]] || continue
  grep -q '"status".*"active"' "$meta" 2>/dev/null || continue
  [[ -f "$notes" ]] || continue

  # Get mtime (cross-platform)
  mtime=$(get_mtime "$notes")

  age=$((NOW_EPOCH - mtime))
  if [[ $age -gt $STALE_THRESHOLD ]]; then
    days=$((age / 86400))
    NOTES_STALE="${NOTES_STALE}[Stale] Work item \"${slug}\" has no activity in ${days} days\n"
  fi
done

# Build output (budget: ~2000 chars)
echo "=== Active Work ==="
echo ""
echo "[work] Use \`/work\` to check status before manual exploration"
echo ""

if [[ -n "$BRANCH_MATCH" ]]; then
  META_FILE="$WORK_DIR/$BRANCH_MATCH/_meta.json"
  MATCH_TITLE=$(json_field "title" "$META_FILE")
  echo "[Current branch matches: $MATCH_TITLE]"
  if [[ -n "${LAST_ENTRY:-}" ]]; then
    echo "$LAST_ENTRY" | head -6
  fi
  echo ""
fi

echo -e "$ACTIVE_WORK"

if [[ -n "$STALE_WORK" ]]; then
  echo -e "$STALE_WORK"
fi

if [[ -n "$NOTES_STALE" ]]; then
  echo -e "$NOTES_STALE"
fi

# Check for orphaned ephemeral plan files
EPHEMERAL_DIR="$HOME/.claude/plans"
if [[ -d "$EPHEMERAL_DIR" ]]; then
  ORPHAN_COUNT=$(find "$EPHEMERAL_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$ORPHAN_COUNT" -gt 0 ]]; then
    echo "[work] $ORPHAN_COUNT ephemeral plan file(s) in ~/.claude/plans/ may not be persisted"
    echo "[work] Use /work list to review — persist with /work create or delete if stale"
    echo ""
  fi
fi

echo "=== End Work ==="
