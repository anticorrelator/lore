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
    # File too large — show just headings
    echo "--- ${file}.md (headings only, read full file on-demand) ---"
    grep '^### ' "$FILEPATH" || true
    echo ""
    # Count heading lines toward budget (rough estimate)
    HEADING_CHARS=$(grep '^### ' "$FILEPATH" 2>/dev/null | wc -c | tr -d '[:space:]' || true)
    HEADING_CHARS="${HEADING_CHARS:-0}"
    CHARS_USED=$((CHARS_USED + HEADING_CHARS + 100))
  else
    echo "--- ${file}.md ---"
    echo "$FILE_CONTENT"
    echo ""
    CHARS_USED=$((CHARS_USED + FILE_SIZE))
  fi

  # Stop if budget exhausted
  if [[ $CHARS_USED -gt $BUDGET ]]; then
    echo "[Remaining files available on-demand via index]"
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

echo ""
echo "=== End Project Knowledge ==="
