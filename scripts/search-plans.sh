#!/usr/bin/env bash
# search-plans.sh — Search across plan documents and session notes
# Usage: bash search-plans.sh <query> [directory]
# Searches _index.json titles/tags, then full-text across plan .md files

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: search-plans.sh <query> [directory]"
  exit 1
fi

QUERY="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${2:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

PLANS_DIR="$KNOWLEDGE_DIR/_plans"

if [[ ! -d "$PLANS_DIR" ]]; then
  echo "No plans directory found. Run \`/plan create <name>\` to create a plan."
  exit 1
fi

echo "=== Plan Search: \"$QUERY\" ==="
echo ""

# Search 1: Index title/tag matches
INDEX="$PLANS_DIR/_index.json"
if [[ -f "$INDEX" ]]; then
  echo "--- Index matches ---"
  MATCHES=$(grep -i "$QUERY" "$INDEX" 2>/dev/null | grep -E '"(title|tags|slug)"' || true)
  if [[ -n "$MATCHES" ]]; then
    echo "$MATCHES" | sed 's/^/  /'
  else
    echo "  (no title/tag matches)"
  fi
  echo ""
fi

# Search 2: Full-text search across active plan files
echo "--- Active plan matches ---"
FOUND=0
while IFS= read -r -d '' file; do
  RELPATH="${file#$PLANS_DIR/}"
  HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
  if [[ -n "$HITS" ]]; then
    echo ""
    echo "  $RELPATH:"
    echo "$HITS" | head -10 | sed 's/^/    /'
    FOUND=$((FOUND + 1))
  fi
done < <(find "$PLANS_DIR" -path "$PLANS_DIR/_archive" -prune -o -name '*.md' -print0 2>/dev/null)

if [[ $FOUND -eq 0 ]]; then
  echo "  (no matches in active plans)"
fi
echo ""

# Search 3: Archived plan files
ARCHIVE_DIR="$PLANS_DIR/_archive"
if [[ -d "$ARCHIVE_DIR" ]]; then
  echo "--- Archived plan matches ---"
  ARCHIVE_FOUND=0
  while IFS= read -r -d '' file; do
    RELPATH="${file#$PLANS_DIR/}"
    HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
      echo ""
      echo "  [archived] $RELPATH:"
      echo "$HITS" | head -10 | sed 's/^/    /'
      ARCHIVE_FOUND=$((ARCHIVE_FOUND + 1))
    fi
  done < <(find "$ARCHIVE_DIR" -name '*.md' -print0 2>/dev/null)

  if [[ $ARCHIVE_FOUND -eq 0 ]]; then
    echo "  (no matches in archived plans)"
  fi
  echo ""
fi

echo "=== End Plan Search ==="
