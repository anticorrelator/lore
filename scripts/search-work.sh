#!/usr/bin/env bash
# search-work.sh — Search across work item documents and session notes
# Usage: bash search-work.sh <query> [directory]
# Uses pk_search.py (FTS5) as primary backend, falls back to grep

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: search-work.sh <query> [directory]"
  exit 1
fi

QUERY="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TARGET_DIR="${2:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "No work directory found. Run \`/work create <name>\` to create a work item."
  exit 1
fi

echo "=== Work Search: \"$QUERY\" ==="
echo ""

# ---------------------------------------------------------------------------
# Try pk_cli.py (FTS5 backend) first
# ---------------------------------------------------------------------------
LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"
USE_FTS=0
if [[ -f "$LORE_SEARCH" ]]; then
  check_fts_available
fi

if [[ $USE_FTS -eq 1 ]]; then
  echo "--- Ranked results (FTS5) ---"
  FTS_OUTPUT=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work 2>/dev/null || true)
  if [[ -n "$FTS_OUTPUT" ]]; then
    echo "$FTS_OUTPUT"
  else
    echo "(no matches)"
  fi
  echo ""

  # Archive search — pk_search.py indexes _archive with source_type "work",
  # so archived results are already included above. Note this for clarity.

  echo "=== End Work Search ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: grep-based search (no Python/FTS5 available)
# ---------------------------------------------------------------------------

# Search 1: Index title/tag matches
INDEX="$WORK_DIR/_index.json"
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

# Search 2: Full-text search across active work item files
echo "--- Active work matches ---"
FOUND=0
while IFS= read -r -d '' file; do
  RELPATH="${file#$WORK_DIR/}"
  HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
  if [[ -n "$HITS" ]]; then
    echo ""
    echo "  $RELPATH:"
    echo "$HITS" | head -10 | sed 's/^/    /'
    FOUND=$((FOUND + 1))
  fi
done < <(find "$WORK_DIR" -path "$WORK_DIR/_archive" -prune -o -name '*.md' -print0 2>/dev/null)

if [[ $FOUND -eq 0 ]]; then
  echo "  (no matches in active work items)"
fi
echo ""

# Search 3: Archived work item files
ARCHIVE_DIR="$WORK_DIR/_archive"
if [[ -d "$ARCHIVE_DIR" ]]; then
  echo "--- Archived work matches ---"
  ARCHIVE_FOUND=0
  while IFS= read -r -d '' file; do
    RELPATH="${file#$WORK_DIR/}"
    HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
      echo ""
      echo "  [archived] $RELPATH:"
      echo "$HITS" | head -10 | sed 's/^/    /'
      ARCHIVE_FOUND=$((ARCHIVE_FOUND + 1))
    fi
  done < <(find "$ARCHIVE_DIR" -name '*.md' -print0 2>/dev/null)

  if [[ $ARCHIVE_FOUND -eq 0 ]]; then
    echo "  (no matches in archived work items)"
  fi
  echo ""
fi

echo "=== End Work Search ==="
