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
SHOW_ALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --all)
      SHOW_ALL=1
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
    # Always fetch both active and archived results for JSON output
    ACTIVE_JSON=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work --json 2>/dev/null || true)
    ARCHIVED_JSON=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work --include-archived --json 2>/dev/null || true)
    # Merge: add "status" field — active results get "active", archived get "archived"
    MERGED=$(python3 -c "
import json, sys
active_raw = sys.argv[1]
archived_raw = sys.argv[2]

active = json.loads(active_raw) if active_raw else []
archived_all = json.loads(archived_raw) if archived_raw else []

# Mark active
active_slugs = set()
results = []
for r in active:
    r['status'] = 'active'
    # Derive slug from file_path: first component of _work/<slug>/...
    fp = r.get('file_path', '')
    parts = fp.replace('_work/', '').split('/')
    slug = parts[0] if parts else ''
    active_slugs.add(slug)
    results.append(r)

# Add archived results not already in active
for r in archived_all:
    fp = r.get('file_path', '')
    parts = fp.replace('_work/_archive/', '').replace('_work/', '').split('/')
    slug = parts[0] if parts else ''
    if slug not in active_slugs:
        r['status'] = 'archived'
        results.append(r)

print(json.dumps(results))
" "$ACTIVE_JSON" "$ARCHIVED_JSON")
    json_output "$MERGED"
    exit 0
  fi

  echo "--- Ranked results (FTS5) ---"
  FTS_OUTPUT=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work 2>/dev/null || true)
  if [[ -n "$FTS_OUTPUT" ]]; then
    echo "$FTS_OUTPUT"
  else
    echo "(no active matches)"
  fi
  echo ""

  # Check for archived matches and show hint or full results
  ARCHIVED_OUTPUT=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --limit 10 --type work --include-archived 2>/dev/null || true)
  # Count archived-only results (those in _archive path) by comparing with active
  ARCHIVED_COUNT=$(python3 -c "
import sys
active = sys.argv[1]
archived_all = sys.argv[2]
# Count lines in archived_all not in active (rough heuristic: line count difference)
a_lines = [l for l in active.strip().splitlines() if l.strip() and not l.startswith('Score')]
b_lines = [l for l in archived_all.strip().splitlines() if l.strip() and not l.startswith('Score')]
print(max(0, len(b_lines) - len(a_lines)))
" "$FTS_OUTPUT" "$ARCHIVED_OUTPUT" 2>/dev/null || echo 0)

  if [[ "$SHOW_ALL" -eq 1 ]]; then
    if [[ -n "$ARCHIVED_OUTPUT" && "$ARCHIVED_OUTPUT" != "$FTS_OUTPUT" ]]; then
      echo "--- Archived results (FTS5) ---"
      echo "$ARCHIVED_OUTPUT"
      echo ""
    else
      echo "(no additional archived matches)"
      echo ""
    fi
  else
    # Show hint if there are archived matches beyond active
    HINT_COUNT=$(python3 -c "
import sys
active = sys.argv[1]
archived_all = sys.argv[2]
a_slugs = set()
b_slugs = set()
import re
for line in active.splitlines():
    m = re.search(r'_work/([^/]+)/', line)
    if m: a_slugs.add(m.group(1))
for line in archived_all.splitlines():
    m = re.search(r'_work/_archive/([^/]+)/', line)
    if m: b_slugs.add(m.group(1))
print(len(b_slugs - a_slugs))
" "$FTS_OUTPUT" "$ARCHIVED_OUTPUT" 2>/dev/null || echo 0)
    if [[ "$HINT_COUNT" -gt 0 ]]; then
      echo "Also found: $HINT_COUNT archived match(es) — use --all to show"
      echo ""
    fi
  fi

  echo "=== End Work Search ==="
  exit 0
fi

# ---------------------------------------------------------------------------
# Fallback: grep-based search (no Python/FTS5 available)
# ---------------------------------------------------------------------------

if [[ $JSON_MODE -eq 1 ]]; then
  # JSON grep fallback: collect matches and emit as [{slug, title, excerpt, status}]
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
      GREP_RESULTS="${GREP_RESULTS}${SLUG}"$'\t'"${TITLE}"$'\t'"${EXCERPT}"$'\t'"active"$'\n'
    fi
  done < <(find "$WORK_DIR" -path "$WORK_DIR/_archive" -prune -o -name '*.md' -print0 2>/dev/null)

  # Always search archive for JSON output
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
        GREP_RESULTS="${GREP_RESULTS}${SLUG}"$'\t'"${TITLE}"$'\t'"${EXCERPT}"$'\t'"archived"$'\n'
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
    parts = line.split("\t", 3)
    if len(parts) < 3:
        continue
    slug = parts[0]
    title = parts[1]
    excerpt = parts[2]
    status = parts[3] if len(parts) > 3 else "active"
    if slug in seen:
        continue
    seen.add(slug)
    results.append({"slug": slug, "title": title, "excerpt": excerpt, "status": status})
print(json.dumps(results, indent=2))
')
  json_output "$JSON_OUT"
  exit 0
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
  ARCHIVE_FOUND=0
  ARCHIVE_SLUGS=()
  while IFS= read -r -d '' file; do
    RELPATH="${file#$WORK_DIR/}"
    HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
      ARCHIVE_SLUG=$(echo "$RELPATH" | cut -d/ -f2)
      # Track unique slugs
      ALREADY=0
      for s in "${ARCHIVE_SLUGS[@]:-}"; do [[ "$s" == "$ARCHIVE_SLUG" ]] && ALREADY=1 && break; done
      if [[ $ALREADY -eq 0 ]]; then
        ARCHIVE_SLUGS+=("$ARCHIVE_SLUG")
      fi
      ARCHIVE_FOUND=$((ARCHIVE_FOUND + 1))
    fi
  done < <(find "$ARCHIVE_DIR" -name '*.md' -print0 2>/dev/null)

  if [[ $ARCHIVE_FOUND -gt 0 ]]; then
    if [[ $SHOW_ALL -eq 1 ]]; then
      echo "--- Archived work matches ---"
      while IFS= read -r -d '' file; do
        RELPATH="${file#$WORK_DIR/}"
        HITS=$(grep -in "$QUERY" "$file" 2>/dev/null || true)
        if [[ -n "$HITS" ]]; then
          echo ""
          echo "  [archived] $RELPATH:"
          echo "$HITS" | head -10 | sed 's/^/    /'
        fi
      done < <(find "$ARCHIVE_DIR" -name '*.md' -print0 2>/dev/null)
      echo ""
    else
      UNIQUE_ARCHIVE_COUNT="${#ARCHIVE_SLUGS[@]}"
      echo "Also found: $UNIQUE_ARCHIVE_COUNT archived match(es) — use --all to show"
      echo ""
    fi
  fi
fi

echo "=== End Work Search ==="
