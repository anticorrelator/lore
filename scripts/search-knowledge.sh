#!/usr/bin/env bash
# search-knowledge.sh — Search knowledge files by keyword
# Usage: bash search-knowledge.sh [--concise] [--scale-set <bucket>] [--no-preferences] <query> [directory]
# Uses pk_search.py (FTS5) as primary backend, falls back to grep
# --concise: output only file paths + ### section headings that match (no content)
# --scale-set: required when FTS5 backend is used; declare retrieval scale
# --no-preferences: skip the always-on Preferences side-channel block

set -euo pipefail

CONCISE=0
SCALE_SET=""
NO_PREFERENCES=0
ARGS=()
i=0
while [[ $i -lt $# ]]; do
  arg="${@:$((i+1)):1}"
  if [[ "$arg" == "--concise" ]]; then
    CONCISE=1
  elif [[ "$arg" == "--no-preferences" ]]; then
    NO_PREFERENCES=1
  elif [[ "$arg" == "--scale-set" ]]; then
    i=$((i+1))
    SCALE_SET="${@:$((i+1)):1}"
  elif [[ "$arg" == --scale-set=* ]]; then
    SCALE_SET="${arg#--scale-set=}"
  else
    ARGS+=("$arg")
  fi
  i=$((i+1))
done

if [[ ${#ARGS[@]} -lt 1 ]]; then
  echo "Usage: search-knowledge.sh [--concise] [--scale-set <bucket>] [--no-preferences] <query> [directory]"
  exit 1
fi

QUERY="${ARGS[0]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TARGET_DIR="${ARGS[1]:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found. Run \`/memory init\` first."
  exit 1
fi

echo "=== Knowledge Search: \"$QUERY\" ==="
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
  if [[ -z "$SCALE_SET" ]]; then
    echo "Error: --scale-set is required for FTS search; declare your retrieval scale, e.g. --scale-set implementation" >&2
    echo "  Buckets: abstract, architecture, subsystem, implementation" >&2
    exit 1
  fi

  # --- Preferences side-channel (always-on; --no-preferences opts out) ---
  PREF_DEDUPE_KEYS=""
  if [[ $NO_PREFERENCES -eq 0 ]]; then
    PREF_RESULTS=$(python3 "$LORE_SEARCH" search-preferences "$KNOWLEDGE_DIR" "$QUERY" --json --caller search-knowledge 2>/dev/null || true)
    if [[ -n "$PREF_RESULTS" && "$PREF_RESULTS" != "[]" ]]; then
      echo "--- Preferences ---"
      if [[ $CONCISE -eq 1 ]]; then
        python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for r in results:
    print(f'  {r[\"file_path\"]}')
    print(f'    ### {r[\"heading\"]}')
" <<< "$PREF_RESULTS"
      else
        python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for i, r in enumerate(results, 1):
    print(f'')
    print(f'--- Preference {i} (score: {r[\"score\"]}) ---')
    print(f'  File: {r[\"file_path\"]}')
    print(f'  Heading: {r[\"heading\"]}')
    if r.get('learned_date'):
        print(f'  Learned: {r[\"learned_date\"]}')
    print(f'  Snippet: {r[\"snippet\"]}')
" <<< "$PREF_RESULTS"
      fi
      # Capture (file_path, heading) tuples for dedupe of main results
      PREF_DEDUPE_KEYS=$(python3 -c "
import json, sys
results = json.loads(sys.stdin.read())
for r in results:
    print(f'{r[\"file_path\"]}|{r[\"heading\"]}')
" <<< "$PREF_RESULTS")
      echo ""
    fi
  fi

  echo "--- Ranked results (FTS5) ---"
  if [[ $CONCISE -eq 1 ]]; then
    # Concise mode: show file path + heading only
    FTS_RESULTS=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --scale-set "$SCALE_SET" --limit 20 --json 2>/dev/null || true)
    if [[ -n "$FTS_RESULTS" && "$FTS_RESULTS" != "[]" ]]; then
      # Parse JSON results, drop preferences-block dedupes, display concisely
      export _PK_DEDUPE_KEYS="$PREF_DEDUPE_KEYS"
      python3 -c "
import json, sys, os
results = json.loads(sys.stdin.read())
dedupe = set()
raw = os.environ.get('_PK_DEDUPE_KEYS', '')
for line in raw.splitlines():
    line = line.strip()
    if line:
        dedupe.add(line)
filtered = [r for r in results if f'{r[\"file_path\"]}|{r[\"heading\"]}' not in dedupe]
if not filtered:
    print('(no matches)')
    sys.exit(0)
seen_files = {}
for r in filtered:
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
    # Full mode: fetch JSON, dedupe against preferences block, render
    FTS_RESULTS=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$QUERY" --scale-set "$SCALE_SET" --limit 10 --json 2>/dev/null || true)
    if [[ -n "$FTS_RESULTS" && "$FTS_RESULTS" != "[]" ]]; then
      export _PK_DEDUPE_KEYS="$PREF_DEDUPE_KEYS"
      python3 -c "
import json, sys, os
results = json.loads(sys.stdin.read())
dedupe = set()
raw = os.environ.get('_PK_DEDUPE_KEYS', '')
for line in raw.splitlines():
    line = line.strip()
    if line:
        dedupe.add(line)
filtered = [r for r in results if f'{r[\"file_path\"]}|{r[\"heading\"]}' not in dedupe]
if not filtered:
    print('(no matches)')
    sys.exit(0)
for i, r in enumerate(filtered, 1):
    st = r.get('source_type', 'knowledge')
    print(f'')
    print(f'--- Result {i} [{st}] (score: {r[\"score\"]}) ---')
    print(f'  File: {r[\"file_path\"]}')
    if st == 'thread':
        print(f'  Entry: {r[\"heading\"]}')
    else:
        print(f'  Heading: {r[\"heading\"]}')
    if r.get('category'):
        print(f'  Category: {r[\"category\"]}')
    if r.get('confidence'):
        print(f'  Confidence: {r[\"confidence\"]}')
    if r.get('learned_date'):
        print(f'  Learned: {r[\"learned_date\"]}')
    if r.get('scale'):
        print(f'  Scale: {r[\"scale\"]}')
    print(f'  Snippet: {r[\"snippet\"]}')
" <<< "$FTS_RESULTS"
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
