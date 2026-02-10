#!/usr/bin/env bash
# filtered-read.sh — Read a knowledge file, optionally filtered by query
# Usage: filtered-read.sh <file> [--query "<topic>"] [--type thread]
#
# Without --query: output full file content (simple cat)
# With --query: FTS5 search scoped to file, matching sections full,
#               non-matching sections as heading-only list
# With --type thread: use ## heading level for thread entries
#
# File resolution:
#   "conventions"           -> $KDIR/conventions.md
#   "conventions.md"        -> $KDIR/conventions.md
#   "domains/topic"         -> $KDIR/domains/topic.md
#   "domains/topic.md"      -> $KDIR/domains/topic.md
#   "_threads/how-we-work"  -> $KDIR/_threads/how-we-work/ (v2 dir) or $KDIR/_threads/how-we-work.md (v1)
#   Absolute paths          -> used directly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Usage ---
usage() {
  cat >&2 <<EOF
Usage: filtered-read.sh <file> [--query "<topic>"] [--type thread]

Read a knowledge file, optionally filtered by relevance.

Arguments:
  file              File to read (relative to knowledge dir, or absolute path)

Options:
  --query, -q       Filter sections by topic (FTS5 search)
  --type, -t        Source type hint (e.g. "thread" for ## heading level)
  --help, -h        Show this help

Examples:
  filtered-read.sh conventions
  filtered-read.sh conventions --query "naming"
  filtered-read.sh domains/api-design
  filtered-read.sh _threads/how-we-work --type thread
EOF
}

# --- Parse args ---
FILE_ARG=""
QUERY=""
SOURCE_TYPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --query|-q)
      QUERY="$2"
      shift 2
      ;;
    --type|-t)
      SOURCE_TYPE="$2"
      shift 2
      ;;
    -*)
      echo "Error: unknown option '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$FILE_ARG" ]]; then
        FILE_ARG="$1"
      else
        echo "Error: unexpected argument '$1'" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$FILE_ARG" ]]; then
  echo "Error: file argument required" >&2
  usage
  exit 1
fi

# --- Resolve file path ---
KDIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || die "Could not resolve knowledge directory"

resolve_file() {
  local arg="$1"
  local kdir="$2"

  # Absolute path — use directly (file or directory)
  if [[ "$arg" == /* ]]; then
    if [[ -f "$arg" || -d "$arg" ]]; then
      echo "$arg"
      return 0
    fi
    return 1
  fi

  # Strip .md suffix for consistent resolution
  local base="${arg%.md}"

  # Try candidates in resolution order (directories before files for threads)
  local candidates=(
    "$kdir/${base}.md"
    "$kdir/${base}"
    "$kdir/${arg}"
    "$kdir/domains/${base}.md"
    "$kdir/_threads/${base}"
    "$kdir/_threads/${base}.md"
  )

  # If the arg has a / prefix (e.g. "domains/topic"), also try as-is with .md
  if [[ "$base" == */* ]]; then
    candidates=("$kdir/${base}.md" "$kdir/${base}" "${candidates[@]}")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" || -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

RESOLVED_PATH=$(resolve_file "$FILE_ARG" "$KDIR") || die "File not found: $FILE_ARG (searched in $KDIR)"

# --- Auto-detect source type from resolved path ---
if [[ -z "$SOURCE_TYPE" ]]; then
  if [[ "$RESOLVED_PATH" == */_threads/* ]]; then
    SOURCE_TYPE="thread"
  fi
fi

# --- Helper: read thread directory as concatenated content ---
# For v2 thread directories, concatenate entry files with reconstructed headings
read_thread_dir() {
  local dir="$1"
  for entry_file in "$dir"/*.md; do
    [[ -f "$entry_file" ]] || continue
    local fname
    fname=$(basename "$entry_file")
    local heading
    heading=$(heading_from_entry_filename "$fname")
    echo "$heading"
    cat "$entry_file"
    echo
  done
}

# --- Read mode ---
if [[ -z "$QUERY" ]]; then
  # No query — output full content
  if [[ -d "$RESOLVED_PATH" ]]; then
    read_thread_dir "$RESOLVED_PATH"
  else
    cat "$RESOLVED_PATH"
  fi
else
  # With query — FTS5-scoped search: matching sections full, non-matching as headings
  HEADING_LEVEL="###"
  if [[ "$SOURCE_TYPE" == "thread" ]]; then
    HEADING_LEVEL="##"
  fi

  # For thread directories, collect all entry file paths for FTS5 matching
  if [[ -d "$RESOLVED_PATH" ]]; then
    SEARCH_PATHS=""
    for entry_file in "$RESOLVED_PATH"/*.md; do
      [[ -f "$entry_file" ]] || continue
      SEARCH_PATHS="${SEARCH_PATHS}${entry_file}"$'\n'
    done
    IS_DIR="true"
  else
    SEARCH_PATHS="$RESOLVED_PATH"
    IS_DIR="false"
  fi

  python3 -c "
import sys, os, sqlite3, glob
sys.path.insert(0, os.path.dirname(os.path.abspath('$SCRIPT_DIR/pk_search.py')))
sys.path.insert(0, '$SCRIPT_DIR')
from pk_search import MarkdownParser, Searcher

resolved_path = '$RESOLVED_PATH'
is_dir = '$IS_DIR' == 'true'
query = sys.argv[1]
heading_level = '$HEADING_LEVEL'
knowledge_dir = '$KDIR'

# Build entries list and file paths for FTS5
if is_dir:
    # v2 thread directory — each .md file is one entry
    entry_files = sorted(glob.glob(os.path.join(resolved_path, '*.md')))
    entries = []
    for fp in entry_files:
        content = open(fp, encoding='utf-8').read()
        basename = os.path.basename(fp)
        stem = basename[:-3] if basename.endswith('.md') else basename
        entries.append({'heading': stem, 'content': content, 'file_path': fp})
    display_name = os.path.basename(resolved_path)
else:
    # Single file — parse into sections
    entries_parsed = MarkdownParser.parse_file(resolved_path, heading_level=heading_level)
    if not entries_parsed:
        print(open(resolved_path, encoding='utf-8').read(), end='')
        sys.exit(0)
    entries = [{'heading': e['heading'], 'content': e['content'], 'file_path': resolved_path} for e in entries_parsed]
    display_name = os.path.basename(resolved_path)

# Search FTS5 for matching entries
searcher = Searcher(knowledge_dir)
searcher._ensure_index()
conn = sqlite3.connect(searcher.db_path)

try:
    prepared = Searcher._prepare_query(query)
    if is_dir:
        # Match against any file in the directory
        abs_paths = [os.path.abspath(e['file_path']) for e in entries]
        placeholders = ','.join('?' * len(abs_paths))
        rows = conn.execute(
            f'SELECT heading, file_path, rank FROM entries WHERE entries MATCH ? AND file_path IN ({placeholders}) ORDER BY rank',
            [prepared] + abs_paths,
        ).fetchall()
        matching = {os.path.abspath(row[1]) for row in rows}
    else:
        abs_path = os.path.abspath(resolved_path)
        rows = conn.execute(
            'SELECT heading, rank FROM entries WHERE entries MATCH ? AND file_path = ? ORDER BY rank',
            (prepared, abs_path),
        ).fetchall()
        matching = {row[0] for row in rows}
except sqlite3.OperationalError:
    # FTS5 error — fall back to full output
    if is_dir:
        for e in entries:
            print(f'{heading_level} {e[\"heading\"]}')
            print(e['content'])
            print()
    else:
        print(open(resolved_path, encoding='utf-8').read(), end='')
    sys.exit(0)
finally:
    conn.close()

if not matching:
    print(f'No sections matching \"{query}\" in {display_name}')
    print()
    print('Available sections:')
    for e in entries:
        h = e['heading']
        if h != '(ungrouped)':
            print(f'  {heading_level} {h}')
else:
    non_matching = []
    for e in entries:
        h = e['heading']
        if is_dir:
            abs_fp = os.path.abspath(e['file_path'])
            is_match = abs_fp in matching
        else:
            is_match = h in matching
        if is_match:
            print(f'{heading_level} {h}')
            print(e['content'])
            print()
        elif h != '(ungrouped)':
            non_matching.append(h)

    if non_matching:
        print('---')
        print(f'Other sections ({len(non_matching)}):')
        for h in non_matching:
            print(f'  {heading_level} {h}')
" "$QUERY"
fi
