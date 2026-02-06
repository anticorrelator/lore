#!/usr/bin/env bash
# search-knowledge.sh — Search knowledge files by keyword
# Usage: bash search-knowledge.sh [--concise] <query> [directory]
# Uses pk_search.py (FTS5) as primary backend, falls back to grep
# --concise: output only file paths + ### section headings that match (no content)

set -euo pipefail

CONCISE=0
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--concise" ]]; then
    CONCISE=1
  else
    ARGS+=("$arg")
  fi
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  echo "Usage: search-knowledge.sh [--concise] <query> [directory]"
  exit 1
fi

QUERY="${ARGS[0]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${ARGS[1]:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found. Run \`/knowledge init\` first."
  exit 1
fi

echo "=== Knowledge Search: \"$QUERY\" ==="
echo ""

# ---------------------------------------------------------------------------
# Try pk_search.py (FTS5 backend) first
# ---------------------------------------------------------------------------
PK_SEARCH="$SCRIPT_DIR/pk_search.py"
USE_FTS=0

if [[ -f "$PK_SEARCH" ]] && command -v python3 &>/dev/null; then
  # Verify python3 has sqlite3 with FTS5 support
  if python3 -c "import sqlite3" 2>/dev/null; then
    USE_FTS=1
  fi
fi

if [[ $USE_FTS -eq 1 ]]; then
  echo "--- Ranked results (FTS5) ---"
  if [[ $CONCISE -eq 1 ]]; then
    # Concise mode: show file path + heading only
    FTS_RESULTS=$(python3 "$PK_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 20 --json 2>/dev/null || true)
    if [[ -n "$FTS_RESULTS" && "$FTS_RESULTS" != "[]" ]]; then
      # Parse JSON results and display concisely
      python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
if not results:
    print('(no matches)')
    sys.exit(0)
seen_files = {}
for r in results:
    fp = r['file_path']
    if fp not in seen_files:
        seen_files[fp] = []
        print(f'  {fp}')
    heading = r['heading']
    if heading not in seen_files[fp]:
        seen_files[fp].append(heading)
        print(f'    ### {heading}')
" <<< "$FTS_RESULTS"
    else
      echo "(no matches)"
    fi
  else
    # Full mode: show ranked results with snippets
    FTS_OUTPUT=$(python3 "$PK_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 2>/dev/null || true)
    if [[ -n "$FTS_OUTPUT" ]]; then
      echo "$FTS_OUTPUT"
    else
      echo "(no matches)"
    fi
  fi
  echo ""

  # Still search inbox separately (pk_search skips it)
  INBOX="$KNOWLEDGE_DIR/_inbox.md"
  if [[ -f "$INBOX" ]] && [[ $CONCISE -eq 0 ]]; then
    INBOX_HITS=$(grep -in "$QUERY" "$INBOX" 2>/dev/null || true)
    if [[ -n "$INBOX_HITS" ]]; then
      echo "--- Inbox (unfiled) matches ---"
      echo "$INBOX_HITS" | sed 's/^/    /'
      echo ""
    fi
  fi

  echo "=== End Search ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: grep-based search (no Python/FTS5 available)
# ---------------------------------------------------------------------------

# Search 1: Manifest keyword matches
MANIFEST="$KNOWLEDGE_DIR/_manifest.json"
if [[ -f "$MANIFEST" ]] && [[ $CONCISE -eq 0 ]]; then
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
    if [[ $CONCISE -eq 1 ]]; then
      # Concise mode: show file path + matching ### headings only
      echo "  $RELPATH"
      # Find ### headings in sections that contain matches
      MATCH_LINES=$(grep -n "$QUERY" "$file" 2>/dev/null | cut -d: -f1 || true)
      HEADINGS_SHOWN=""
      for lineno in $MATCH_LINES; do
        # Find the nearest ### heading at or before this line
        HEADING=$(head -n "$lineno" "$file" | grep '^### ' | tail -1 || true)
        if [[ -n "$HEADING" && "$HEADINGS_SHOWN" != *"$HEADING"* ]]; then
          echo "    $HEADING"
          HEADINGS_SHOWN="${HEADINGS_SHOWN}${HEADING}\n"
        fi
      done
    else
      echo ""
      echo "  $RELPATH:"
      echo "$HITS" | head -10 | sed 's/^/    /'
    fi
    FOUND=$((FOUND + 1))
  fi
done < <(find "$KNOWLEDGE_DIR" -name '*.md' -print0 2>/dev/null)

if [[ $FOUND -eq 0 ]]; then
  echo "(no full-text matches)"
fi
echo ""

# Search 3: Inbox (unfiled entries)
INBOX="$KNOWLEDGE_DIR/_inbox.md"
if [[ -f "$INBOX" ]] && [[ $CONCISE -eq 0 ]]; then
  INBOX_HITS=$(grep -in "$QUERY" "$INBOX" 2>/dev/null || true)
  if [[ -n "$INBOX_HITS" ]]; then
    echo "--- Inbox (unfiled) matches ---"
    echo "$INBOX_HITS" | sed 's/^/    /'
    echo ""
  fi
fi

echo "=== End Search ==="
