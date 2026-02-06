#!/usr/bin/env bash
# load-plans.sh — SessionStart hook: show active plans, detect branch match
# Usage: bash load-plans.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

PLANS_DIR="$KNOWLEDGE_DIR/_plans"

# Exit silently if no plans directory
[[ -d "$PLANS_DIR" ]] || exit 0

INDEX="$PLANS_DIR/_index.json"

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-plan-index.sh" 2>/dev/null || exit 0
fi

[[ -f "$INDEX" ]] || exit 0

# Check if there are any plans
PLAN_COUNT=$(grep -c '"slug"' "$INDEX" 2>/dev/null || true)
PLAN_COUNT=$(echo "$PLAN_COUNT" | tr -d '[:space:]')
[[ "$PLAN_COUNT" -gt 0 ]] || exit 0

# Get current git branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

OUTPUT=""
BRANCH_MATCH=""
ACTIVE_PLANS=""
STALE_PLANS=""
NOW_EPOCH=$(date +%s)

# Parse plans from index (line-by-line approach for portability)
# Read each plan entry by extracting fields
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

  # End of a plan entry — process it
  if echo "$line" | grep -q '"has_plan_doc"'; then
    if [[ "$CURRENT_STATUS" == "active" ]]; then
      # Check for branch match
      if [[ -n "$CURRENT_BRANCH" ]]; then
        # Read branches from _meta.json directly for accuracy
        META_FILE="$PLANS_DIR/$CURRENT_SLUG/_meta.json"
        if [[ -f "$META_FILE" ]]; then
          if grep -q "\"$CURRENT_BRANCH\"" "$META_FILE" 2>/dev/null; then
            BRANCH_MATCH="$CURRENT_SLUG"
            # Get last notes entry
            NOTES_FILE="$PLANS_DIR/$CURRENT_SLUG/notes.md"
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
        # Parse ISO date to epoch (macOS compatible)
        UPDATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$CURRENT_UPDATED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${CURRENT_UPDATED%Z}" +%s 2>/dev/null || echo "0")
        if [[ "$UPDATED_EPOCH" -gt 0 ]]; then
          DAYS_AGO=$(( (NOW_EPOCH - UPDATED_EPOCH) / 86400 ))
          if [[ $DAYS_AGO -eq 0 ]]; then
            RELATIVE_DATE="today"
          elif [[ $DAYS_AGO -eq 1 ]]; then
            RELATIVE_DATE="yesterday"
          else
            RELATIVE_DATE="${DAYS_AGO}d ago"
          fi
          # Check for stale plans (>30 days)
          if [[ $DAYS_AGO -gt 30 ]]; then
            STALE_PLANS="${STALE_PLANS}- ${CURRENT_SLUG} — inactive ${DAYS_AGO} days, consider \`/plan archive\`\n"
          fi
        fi
      fi

      ACTIVE_PLANS="${ACTIVE_PLANS}- ${CURRENT_SLUG}: ${CURRENT_TITLE} (updated ${RELATIVE_DATE:-unknown})\n"
    fi

    # Reset for next plan
    CURRENT_SLUG=""
    CURRENT_TITLE=""
    CURRENT_STATUS=""
    CURRENT_UPDATED=""
    CURRENT_BRANCHES=""
  fi
done < "$INDEX"

# Build output (budget: ~2000 chars)
echo "=== Active Plans ==="
echo ""

if [[ -n "$BRANCH_MATCH" ]]; then
  META_FILE="$PLANS_DIR/$BRANCH_MATCH/_meta.json"
  MATCH_TITLE=$(grep '"title"' "$META_FILE" 2>/dev/null | sed 's/.*"title"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1)
  echo "[Current branch matches: $MATCH_TITLE]"
  if [[ -n "${LAST_ENTRY:-}" ]]; then
    echo "$LAST_ENTRY" | head -6
  fi
  echo ""
fi

echo -e "$ACTIVE_PLANS"

if [[ -n "$STALE_PLANS" ]]; then
  echo -e "$STALE_PLANS"
fi

echo "=== End Plans ==="
