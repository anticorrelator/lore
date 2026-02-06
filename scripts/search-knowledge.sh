#!/usr/bin/env bash
# search-knowledge.sh — Search knowledge files by keyword
# Usage: bash search-knowledge.sh <query> [directory]
# Searches manifest keywords first, then full-text, then inbox

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: search-knowledge.sh <query> [directory]"
  exit 1
fi

QUERY="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${2:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found. Run \`/knowledge init\` first."
  exit 1
fi

echo "=== Knowledge Search: \"$QUERY\" ==="
echo ""

# Search 1: Manifest keyword matches
MANIFEST="$KNOWLEDGE_DIR/_manifest.json"
if [[ -f "$MANIFEST" ]]; then
  echo "--- Manifest matches ---"
  # Use grep on manifest for keyword hits, case-insensitive
  MATCHES=$(grep -i "$QUERY" "$MANIFEST" 2>/dev/null || true)
  if [[ -n "$MATCHES" ]]; then
    echo "$MATCHES"
  else
    echo "(no keyword matches)"
  fi
  echo ""
fi

# Search 2: Full-text search across knowledge files
echo "--- Full-text matches ---"
FOUND=0
# Search .md files (excluding inbox which is searched separately)
while IFS= read -r -d '' file; do
  BASENAME=$(basename "$file")
  if [[ "$BASENAME" == "_inbox.md" || "$BASENAME" == "_meta.md" ]]; then
    continue
  fi
  RELPATH="${file#$KNOWLEDGE_DIR/}"
  HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
  if [[ -n "$HITS" ]]; then
    echo ""
    echo "  $RELPATH:"
    echo "$HITS" | head -10 | sed 's/^/    /'
    FOUND=$((FOUND + 1))
  fi
done < <(find "$KNOWLEDGE_DIR" -name '*.md' -print0 2>/dev/null)

if [[ $FOUND -eq 0 ]]; then
  echo "(no full-text matches)"
fi
echo ""

# Search 3: Inbox (unfiled entries)
INBOX="$KNOWLEDGE_DIR/_inbox.md"
if [[ -f "$INBOX" ]]; then
  INBOX_HITS=$(grep -in "$QUERY" "$INBOX" 2>/dev/null || true)
  if [[ -n "$INBOX_HITS" ]]; then
    echo "--- Inbox (unfiled) matches ---"
    echo "$INBOX_HITS" | sed 's/^/    /'
    echo ""
  fi
fi

echo "=== End Search ==="
