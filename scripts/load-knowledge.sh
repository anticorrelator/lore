#!/usr/bin/env bash
# load-knowledge.sh — SessionStart hook: detect inbox items + load knowledge
# Usage: bash load-knowledge.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

# If no knowledge store exists, show cold-start message
if [[ ! -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  cat << 'EOF'
[Knowledge Store] No knowledge store found for this project.
Run `/memory init` to initialize one, or it will be created automatically when you first capture an insight.
EOF
  exit 0
fi

BUDGET=8000
CHARS_USED=0
FILES_FULL=0
FILES_SUMMARY=0
FILES_SKIPPED=0

# --- Job A: Detect inbox entries ---
INBOX="$KNOWLEDGE_DIR/_inbox.md"
if [[ -f "$INBOX" ]]; then
  # Count entries (## headings after the header)
  ENTRY_COUNT=$(grep -c '^## \[' "$INBOX" 2>/dev/null || true)
  ENTRY_COUNT="${ENTRY_COUNT:-0}"
  ENTRY_COUNT=$(echo "$ENTRY_COUNT" | tr -d '[:space:]')
  if [[ "$ENTRY_COUNT" -gt 0 ]]; then
    echo "[Knowledge Store] $ENTRY_COUNT pending inbox entries found."
    echo "Run \`/memory organize\` to process them before starting work."
    echo ""
  fi
fi

# --- Job B: Load knowledge ---
echo "=== Project Knowledge ==="
echo ""

# Always load index
if [[ -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  INDEX_CONTENT=$(cat "$KNOWLEDGE_DIR/_index.md")
  CHARS_USED=$((CHARS_USED + ${#INDEX_CONTENT}))
  echo "$INDEX_CONTENT"
  echo ""
fi

# Load files in priority order within budget
PRIORITY_FILES=(workflows conventions gotchas abstractions architecture team)

for file in "${PRIORITY_FILES[@]}"; do
  FILEPATH="$KNOWLEDGE_DIR/${file}.md"
  if [[ ! -f "$FILEPATH" ]]; then
    continue
  fi

  FILE_CONTENT=$(cat "$FILEPATH")
  FILE_SIZE=${#FILE_CONTENT}

  # Skip files that only have the header (no actual entries)
  ENTRY_COUNT=$(grep -c '^### ' "$FILEPATH" 2>/dev/null || true)
  ENTRY_COUNT="${ENTRY_COUNT:-0}"
  ENTRY_COUNT=$(echo "$ENTRY_COUNT" | tr -d '[:space:]')
  if [[ "$ENTRY_COUNT" -eq 0 ]]; then
    continue
  fi

  # Check budget
  if [[ $((CHARS_USED + FILE_SIZE)) -gt $BUDGET ]]; then
    # File too large — show headings + first sentence of each section
    echo "--- ${file}.md (summary, read full file on-demand) ---"
    SUMMARY=""
    CURRENT_HEADING=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^###\  ]]; then
        CURRENT_HEADING="$line"
        SUMMARY="${SUMMARY}${CURRENT_HEADING}"$'\n'
      elif [[ -n "$CURRENT_HEADING" && -n "$line" && ! "$line" =~ ^# ]]; then
        # First non-empty content line after a heading — extract first sentence
        FIRST_SENTENCE="${line%%.*}"
        if [[ "$FIRST_SENTENCE" != "$line" ]]; then
          FIRST_SENTENCE="${FIRST_SENTENCE}."
        fi
        SUMMARY="${SUMMARY}${FIRST_SENTENCE}"$'\n'
        CURRENT_HEADING=""  # Only take first sentence per section
      fi
    done < "$FILEPATH"
    echo "$SUMMARY"
    SUMMARY_CHARS=${#SUMMARY}
    CHARS_USED=$((CHARS_USED + SUMMARY_CHARS))
    FILES_SUMMARY=$((FILES_SUMMARY + 1))
  else
    echo "--- ${file}.md ---"
    echo "$FILE_CONTENT"
    echo ""
    CHARS_USED=$((CHARS_USED + FILE_SIZE))
    FILES_FULL=$((FILES_FULL + 1))
  fi

  # Stop if budget exhausted
  if [[ $CHARS_USED -gt $BUDGET ]]; then
    echo "[Remaining files available on-demand via index]"
    # Count remaining priority files as skipped
    FOUND_CURRENT=0
    for remaining in "${PRIORITY_FILES[@]}"; do
      if [[ $FOUND_CURRENT -eq 1 ]]; then
        if [[ -f "$KNOWLEDGE_DIR/${remaining}.md" ]]; then
          SKIP_ENTRIES=$(grep -c '^### ' "$KNOWLEDGE_DIR/${remaining}.md" 2>/dev/null || true)
          SKIP_ENTRIES=$(echo "$SKIP_ENTRIES" | tr -d '[:space:]')
          if [[ "${SKIP_ENTRIES:-0}" -gt 0 ]]; then
            FILES_SKIPPED=$((FILES_SKIPPED + 1))
          fi
        fi
      fi
      if [[ "$remaining" == "$file" ]]; then
        FOUND_CURRENT=1
      fi
    done
    break
  fi
done

# Quick structural health check
ISSUES=()
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  ISSUES+=("_manifest.json missing")
fi
if [[ ! -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  ISSUES+=("_index.md missing")
fi
if [[ ! -d "$KNOWLEDGE_DIR/domains" ]]; then
  ISSUES+=("domains/ directory missing")
fi

if [[ ${#ISSUES[@]} -gt 0 ]]; then
  echo ""
  echo "[Health] Issues detected: ${ISSUES[*]}"
  echo "Run \`/memory heal\` to fix structural issues."
fi

# --- Staleness check ---
STALE_ENTRIES=()
STALE_COUNT=0
NOW=$(date +%s)
NINETY_DAYS=$((90 * 86400))

while IFS= read -r -d '' file; do
  BASENAME=$(basename "$file")
  # Skip meta files
  if [[ "$BASENAME" == _* ]]; then
    continue
  fi

  # Check file mtime > 90 days
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_MTIME=$(stat -f %m "$file" 2>/dev/null || echo "$NOW")
  else
    FILE_MTIME=$(stat -c %Y "$file" 2>/dev/null || echo "$NOW")
  fi
  AGE=$((NOW - FILE_MTIME))
  if [[ $AGE -gt $NINETY_DAYS ]]; then
    DAYS_OLD=$((AGE / 86400))
    STALE_ENTRIES+=("${BASENAME} (${DAYS_OLD}d old)")
    STALE_COUNT=$((STALE_COUNT + 1))
  fi

  # Check for low-confidence markers within the file
  LOW_CONF=$(grep -c '\*\*Confidence:\*\* low' "$file" 2>/dev/null || true)
  LOW_CONF=$(echo "$LOW_CONF" | tr -d '[:space:]')
  if [[ "${LOW_CONF:-0}" -gt 0 ]]; then
    # Only add if not already flagged by mtime
    ALREADY=0
    if [[ $STALE_COUNT -gt 0 ]]; then
      for entry in "${STALE_ENTRIES[@]}"; do
        if [[ "$entry" == "${BASENAME}"* ]]; then
          ALREADY=1
          break
        fi
      done
    fi
    if [[ $ALREADY -eq 0 ]]; then
      STALE_ENTRIES+=("${BASENAME} (${LOW_CONF} low-confidence entries)")
      STALE_COUNT=$((STALE_COUNT + 1))
    fi
  fi
done < <(find "$KNOWLEDGE_DIR" -name '*.md' -not -path '*/domains/*' -print0 2>/dev/null)

if [[ $STALE_COUNT -gt 0 ]]; then
  echo ""
  echo "[Stale] Entries needing review: ${STALE_ENTRIES[*]}"
fi

BUDGET_REMAINING=$((BUDGET - CHARS_USED))
if [[ $BUDGET_REMAINING -lt 0 ]]; then
  BUDGET_REMAINING=0
fi
echo "[Budget] ${CHARS_USED}/${BUDGET} chars | ${FILES_FULL} full, ${FILES_SUMMARY} summary, ${FILES_SKIPPED} skipped"
echo ""
echo "=== End Project Knowledge ==="
