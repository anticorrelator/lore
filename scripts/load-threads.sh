#!/usr/bin/env bash
# load-threads.sh — SessionStart hook: load thread context within budget
# Usage: bash load-threads.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

THREADS_DIR="$KNOWLEDGE_DIR/_threads"

# If threads not initialized, exit silently
if [[ ! -d "$THREADS_DIR" ]]; then
  exit 0
fi

INDEX_FILE="$THREADS_DIR/_index.json"
if [[ ! -f "$INDEX_FILE" ]]; then
  exit 0
fi

BUDGET=3000
CHARS_USED=0
PINNED_COUNT=0
ACTIVE_COUNT=0
DORMANT_COUNT=0

echo "=== Conversational Threads ==="
echo ""

# Parse index and get threads with their tiers
# Use python3 for reliable JSON parsing
THREAD_DATA=$(python3 -c "
import json, sys
try:
    with open('$INDEX_FILE', 'r') as f:
        idx = json.load(f)
    threads = idx.get('threads', [])
    for t in threads:
        print(f\"{t['slug']}|{t['tier']}\")
except Exception as e:
    sys.exit(0)
" 2>/dev/null) || exit 0

# Process pinned threads first (full content)
while IFS='|' read -r slug tier; do
  if [[ "$tier" != "pinned" ]]; then
    continue
  fi

  THREAD_FILE="$THREADS_DIR/${slug}.md"
  if [[ ! -f "$THREAD_FILE" ]]; then
    continue
  fi

  CONTENT=$(cat "$THREAD_FILE")
  CONTENT_SIZE=${#CONTENT}

  # Check budget
  if [[ $((CHARS_USED + CONTENT_SIZE)) -gt $BUDGET ]]; then
    echo "[threads] Budget exhausted, remaining threads available on-demand"
    break
  fi

  echo "--- ${slug}.md (pinned) ---"
  echo "$CONTENT"
  echo ""

  CHARS_USED=$((CHARS_USED + CONTENT_SIZE))
  PINNED_COUNT=$((PINNED_COUNT + 1))
done <<< "$THREAD_DATA"

# Process active threads (frontmatter + last entry only)
while IFS='|' read -r slug tier; do
  if [[ "$tier" != "active" ]]; then
    continue
  fi

  THREAD_FILE="$THREADS_DIR/${slug}.md"
  if [[ ! -f "$THREAD_FILE" ]]; then
    continue
  fi

  # Extract frontmatter (between --- markers) and last ## entry
  FRONTMATTER=$(awk '/^---$/{if(++count==1){start=1;next}else{exit}}start' "$THREAD_FILE")

  # Get last ## entry (from last ## heading to end of file)
  LAST_ENTRY=$(awk '
    /^## / {
      last_start = NR
      content = ""
    }
    {
      if (last_start > 0) {
        content = content $0 "\n"
      }
    }
    END {
      printf "%s", content
    }
  ' "$THREAD_FILE")

  COMBINED="---
${FRONTMATTER}
---

${LAST_ENTRY}"

  COMBINED_SIZE=${#COMBINED}

  # Check budget
  if [[ $((CHARS_USED + COMBINED_SIZE)) -gt $BUDGET ]]; then
    echo "[threads] Budget exhausted, remaining threads available on-demand"
    break
  fi

  echo "--- ${slug}.md (active, last entry) ---"
  echo "$COMBINED"
  echo ""

  CHARS_USED=$((CHARS_USED + COMBINED_SIZE))
  ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
done <<< "$THREAD_DATA"

# Count dormant threads
while IFS='|' read -r slug tier; do
  if [[ "$tier" == "dormant" ]]; then
    DORMANT_COUNT=$((DORMANT_COUNT + 1))
  fi
done <<< "$THREAD_DATA"

# Check for pending digest
PENDING_DIGEST="$THREADS_DIR/_pending_digest.md"
HAS_PENDING=""
if [[ -f "$PENDING_DIGEST" ]]; then
  HAS_PENDING="yes"
fi

BUDGET_REMAINING=$((BUDGET - CHARS_USED))
if [[ $BUDGET_REMAINING -lt 0 ]]; then
  BUDGET_REMAINING=0
fi

echo "[threads] Budget: ${CHARS_USED}/${BUDGET} chars | ${PINNED_COUNT} pinned, ${ACTIVE_COUNT} active, ${DORMANT_COUNT} dormant"

if [[ -n "$HAS_PENDING" ]]; then
  echo "[threads] Pending session digest — process on first turn"
fi

echo ""
echo "=== End Threads ==="
