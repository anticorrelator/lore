#!/usr/bin/env bash
# search-work.sh — Search across work item documents and session notes
# Usage: bash search-work.sh <query> [directory] [--json]
# Uses pk_search.py (FTS5) as primary backend, falls back to grep

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
QUERY=""
TARGET_DIR=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      elif [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required argument: query"
  fi
  echo "Usage: search-work.sh <query> [directory] [--json]"
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work directory found"
  fi
  echo "No work directory found. Run \`/work create <name>\` to create a work item."
  exit 1
fi

if [[ $JSON_MODE -eq 0 ]]; then
  echo "=== Work Search: \"$QUERY\" ==="
  echo ""
fi

# ---------------------------------------------------------------------------
# Try pk_cli.py (FTS5 backend) first
# ---------------------------------------------------------------------------
LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"
USE_FTS=0
if [[ -f "$LORE_SEARCH" ]]; then
  check_fts_available
fi

if [[ $USE_FTS -eq 1 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    # Pass --json through to pk_cli.py
    FTS_OUTPUT=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work --json 2>/dev/null || true)
    if [[ -n "$FTS_OUTPUT" ]]; then
      json_output "$FTS_OUTPUT"
    else
      json_output "[]"
    fi
  fi

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

if [[ $JSON_MODE -eq 1 ]]; then
  # JSON grep fallback: collect matches and emit as [{slug, title, excerpt}]
  GREP_RESULTS=""
  while IFS= read -r -d '' file; do
    RELPATH="${file#$WORK_DIR/}"
    HITS=$(grep -in "$QUERY" "$file" 2>/dev/null | head -3 || true)
    if [[ -n "$HITS" ]]; then
      # Extract slug from path (first directory component)
      SLUG=$(echo "$RELPATH" | cut -d/ -f1)
      # Get title from _meta.json if available
      META_FILE="$WORK_DIR/$SLUG/_meta.json"
      TITLE=""
      if [[ -f "$META_FILE" ]]; then
        TITLE=$(json_field "title" "$META_FILE")
      fi
      TITLE="${TITLE:-$SLUG}"
      # Use first match line as excerpt
      EXCERPT=$(echo "$HITS" | head -1 | sed 's/^[0-9]*://')
      GREP_RESULTS="${GREP_RESULTS}${SLUG}"$'\t'"${TITLE}"$'\t'"${EXCERPT}"$'\n'
    fi
  done < <(find "$WORK_DIR" -path "$WORK_DIR/_archive" -prune -o -name '*.md' -print0 2>/dev/null)

  # Also search archive
  ARCHIVE_DIR="$WORK_DIR/_archive"
  if [[ -d "$ARCHIVE_DIR" ]]; then
    while IFS= read -r -d '' file; do
      RELPATH="${file#$ARCHIVE_DIR/}"
      HITS=$(grep -in "$QUERY" "$file" 2>/dev/null | head -3 || true)
      if [[ -n "$HITS" ]]; then
        SLUG=$(echo "$RELPATH" | cut -d/ -f1)
        META_FILE="$ARCHIVE_DIR/$SLUG/_meta.json"
        TITLE=""
        if [[ -f "$META_FILE" ]]; then
          TITLE=$(json_field "title" "$META_FILE")
        fi
        TITLE="${TITLE:-$SLUG}"
        EXCERPT=$(echo "$HITS" | head -1 | sed 's/^[0-9]*://')
        GREP_RESULTS="${GREP_RESULTS}${SLUG}"$'\t'"${TITLE}"$'\t'"${EXCERPT}"$'\n'
      fi
    done < <(find "$ARCHIVE_DIR" -name '*.md' -print0 2>/dev/null)
  fi

  # Deduplicate by slug and emit JSON array via inline python3
  JSON_OUT=$(printf '%s' "$GREP_RESULTS" | python3 -c '
import json, sys
seen = set()
results = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t", 2)
    if len(parts) < 3:
        continue
    slug, title, excerpt = parts
    if slug in seen:
        continue
    seen.add(slug)
    results.append({"slug": slug, "title": title, "excerpt": excerpt})
print(json.dumps(results, indent=2))
')
  json_output "$JSON_OUT"
fi

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
