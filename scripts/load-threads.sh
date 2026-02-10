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

source "$SCRIPT_DIR/lib.sh"

BUDGET=3000
CHARS_USED=0
PINNED_COUNT=0
ACTIVE_COUNT=0
DORMANT_COUNT=0
FULL_ENTRY_COUNT=0
SUMMARY_ENTRY_COUNT=0
OMITTED_ENTRY_COUNT=0
BUDGET_EXHAUSTED=""

# --- Extract context signal for thread loading bias ---
CONTEXT_SIGNAL=$(extract_context_signal "$KNOWLEDGE_DIR")

# If we have a context signal, find matching thread entry file paths via FTS5
CONTEXT_MATCHED_FILES=""
if [[ -n "$CONTEXT_SIGNAL" ]]; then
  CONTEXT_MATCHED_FILES=$(python3 -c "
import sys, sqlite3, os
sys.path.insert(0, '$SCRIPT_DIR')
from pk_search import Searcher

searcher = Searcher('$KNOWLEDGE_DIR')
searcher._ensure_index()
conn = sqlite3.connect(searcher.db_path)

# Quote each token for FTS5 safety
query = ' '.join('\"' + t.replace('\"', '\"\"') + '\"' for t in '''$CONTEXT_SIGNAL'''.split())
fts = 'source_type:\"thread\" ' + query

try:
    rows = conn.execute('''
        SELECT file_path, heading FROM entries
        WHERE entries MATCH ? ORDER BY rank LIMIT 5
    ''', (fts,)).fetchall()
except:
    rows = []
conn.close()

for fp, h in rows:
    # Output file_path for matching against entry files
    print(fp)
" 2>/dev/null) || CONTEXT_MATCHED_FILES=""
fi

echo "=== Conversational Threads ==="
echo ""

# Parse index and get threads with their tiers
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

# Tiered loading parameters
PINNED_FULL_LIMIT=5
PINNED_SUMMARY_LIMIT=15
ACTIVE_FULL_LIMIT=3
ACTIVE_SUMMARY_LIMIT=10

# --- V2 helpers: filename <-> heading reconstruction ---

# Reconstruct a ## heading from an entry filename.
# 2026-02-06.md           → ## 2026-02-06
# 2026-02-06-s6.md        → ## 2026-02-06 (Session 6)
# 2026-02-07-s14-continued.md → ## 2026-02-07 (Session 14, continued)
# 2026-02-07-s14-2.md     → ## 2026-02-07 (Session 14)  (disambiguation suffix stripped)
filename_to_heading() {
  local fname="$1"
  local base="${fname%.md}"
  local date="${base:0:10}"
  local rest="${base:10}"

  if [[ -z "$rest" ]]; then
    echo "## $date"
    return
  fi

  # Strip leading dash
  rest="${rest#-}"

  if [[ "$rest" =~ ^s([0-9]+)(-.+)?$ ]]; then
    local session_num="${BASH_REMATCH[1]}"
    local suffix="${BASH_REMATCH[2]}"

    if [[ -z "$suffix" ]]; then
      echo "## $date (Session $session_num)"
    elif [[ "$suffix" =~ ^-[0-9]+$ ]]; then
      # Disambiguation suffix (e.g., -2), not a qualifier
      echo "## $date (Session $session_num)"
    else
      # Qualifier (e.g., -continued)
      local qualifier="${suffix#-}"
      qualifier=$(echo "$qualifier" | tr '-' ' ')
      echo "## $date (Session $session_num, $qualifier)"
    fi
  else
    echo "## $date"
  fi
}

# Extract **Summary:** line from an entry file's content
extract_entry_summary() {
  local file="$1"
  local line
  while IFS= read -r line; do
    if [[ "$line" == "**Summary:"* ]]; then
      echo "$line" | sed 's/^\*\*Summary:\*\*[[:space:]]*//'
      return
    fi
  done < "$file"
  echo ""
}

# --- V2: Load entries from a thread directory ---
# Lists .md files sorted descending (newest first), applies tiered budget logic.
# Sets global return vars: _THREAD_FULL, _THREAD_SUMMARY, _THREAD_OMITTED, _ENTRY_OUTPUT, _HEADER
load_thread_entries_v2() {
  local thread_dir="$1"
  local slug="$2"
  local full_limit="$3"
  local summary_limit="$4"

  local thread_full=0
  local thread_summary=0
  local thread_omitted=0
  local entry_output=""
  local entry_idx=0

  # List .md entry files sorted descending by name (newest first)
  local entry_files=()
  while IFS= read -r ef; do
    entry_files+=("$ef")
  done < <(ls -1r "$thread_dir"/*.md 2>/dev/null)

  if [[ ${#entry_files[@]} -eq 0 ]]; then
    _THREAD_FULL=0; _THREAD_SUMMARY=0; _THREAD_OMITTED=0; _ENTRY_OUTPUT=""; _HEADER=""
    return
  fi

  # Read _meta.json for header
  local meta_file="$thread_dir/_meta.json"
  local header=""
  if [[ -f "$meta_file" ]]; then
    header=$(python3 -c "
import json
with open('$meta_file') as f:
    m = json.load(f)
parts = []
for k in ('topic', 'tier', 'created', 'updated', 'sessions'):
    if k in m:
        parts.append(f'{k}: {m[k]}')
print('\n'.join(parts))
" 2>/dev/null)
  fi
  local header_size=${#header}

  # Check budget for header alone
  if [[ $((CHARS_USED + header_size)) -gt $BUDGET ]]; then
    BUDGET_EXHAUSTED="yes"
    echo "[threads] Budget exhausted, remaining threads available on-demand"
    _THREAD_FULL=0; _THREAD_SUMMARY=0; _THREAD_OMITTED=${#entry_files[@]}
    _ENTRY_OUTPUT=""; _HEADER="$header"
    return
  fi

  for entry_file in "${entry_files[@]}"; do
    local entry_basename
    entry_basename=$(basename "$entry_file")
    local heading
    heading=$(filename_to_heading "$entry_basename")
    local content
    content=$(< "$entry_file")
    local summary
    summary=$(extract_entry_summary "$entry_file")

    # Full entry = heading + content (matches old format output for display)
    local full_text="${heading}"$'\n'"${content}"

    if [[ -n "$BUDGET_EXHAUSTED" ]]; then
      thread_omitted=$((thread_omitted + 1))
      OMITTED_ENTRY_COUNT=$((OMITTED_ENTRY_COUNT + 1))
      entry_idx=$((entry_idx + 1))
      continue
    fi

    # Check if this entry matches a context-biased FTS5 result (by file path)
    local is_context_match=""
    if [[ -n "$CONTEXT_MATCHED_FILES" ]]; then
      while IFS= read -r matched_file; do
        if [[ "$matched_file" == "$entry_file" ]]; then
          is_context_match="yes"
          break
        fi
      done <<< "$CONTEXT_MATCHED_FILES"
    fi

    if [[ $entry_idx -lt $full_limit ]] || [[ -n "$is_context_match" ]]; then
      # Full entry tier
      local entry_text="${full_text}"$'\n'
      local entry_size=${#entry_text}
      if [[ $((CHARS_USED + header_size + ${#entry_output} + entry_size)) -gt $BUDGET ]]; then
        BUDGET_EXHAUSTED="yes"
        thread_omitted=$((thread_omitted + 1))
        OMITTED_ENTRY_COUNT=$((OMITTED_ENTRY_COUNT + 1))
        entry_idx=$((entry_idx + 1))
        continue
      fi
      entry_output="${entry_output}${entry_text}"
      thread_full=$((thread_full + 1))
      FULL_ENTRY_COUNT=$((FULL_ENTRY_COUNT + 1))
    elif [[ $entry_idx -lt $summary_limit ]]; then
      # Summary tier
      local summary_line
      if [[ -n "$summary" ]]; then
        summary_line="${heading}"$'\n'"**Summary:** ${summary}"$'\n\n'
      else
        summary_line="${heading}"$'\n'"(no summary)"$'\n\n'
      fi
      local summary_size=${#summary_line}
      if [[ $((CHARS_USED + header_size + ${#entry_output} + summary_size)) -gt $BUDGET ]]; then
        BUDGET_EXHAUSTED="yes"
        thread_omitted=$((thread_omitted + 1))
        OMITTED_ENTRY_COUNT=$((OMITTED_ENTRY_COUNT + 1))
        entry_idx=$((entry_idx + 1))
        continue
      fi
      entry_output="${entry_output}${summary_line}"
      thread_summary=$((thread_summary + 1))
      SUMMARY_ENTRY_COUNT=$((SUMMARY_ENTRY_COUNT + 1))
    else
      # Omitted tier
      thread_omitted=$((thread_omitted + 1))
      OMITTED_ENTRY_COUNT=$((OMITTED_ENTRY_COUNT + 1))
    fi

    entry_idx=$((entry_idx + 1))
  done

  _THREAD_FULL=$thread_full
  _THREAD_SUMMARY=$thread_summary
  _THREAD_OMITTED=$thread_omitted
  _ENTRY_OUTPUT="$entry_output"
  _HEADER="$header"
}

# --- Process threads by tier ---

# Process pinned threads first
while IFS='|' read -r slug tier; do
  [[ "$tier" == "pinned" ]] || continue
  [[ -n "$BUDGET_EXHAUSTED" ]] && break

  THREAD_DIR="$THREADS_DIR/${slug}"
  [[ -d "$THREAD_DIR" ]] || continue

  load_thread_entries_v2 "$THREAD_DIR" "$slug" "$PINNED_FULL_LIMIT" "$PINNED_SUMMARY_LIMIT"

  if [[ -n "$_ENTRY_OUTPUT" ]]; then
    COMBINED="${_HEADER}"$'\n\n'"${_ENTRY_OUTPUT}"
    COMBINED_SIZE=${#COMBINED}

    echo "--- ${slug}/ (pinned, ${_THREAD_FULL} full, ${_THREAD_SUMMARY} summary, ${_THREAD_OMITTED} omitted) ---"
    echo "$COMBINED"
    echo ""

    CHARS_USED=$((CHARS_USED + COMBINED_SIZE))
    PINNED_COUNT=$((PINNED_COUNT + 1))
  fi
done <<< "$THREAD_DATA"

# Process active threads
while IFS='|' read -r slug tier; do
  [[ "$tier" == "active" ]] || continue
  [[ -n "$BUDGET_EXHAUSTED" ]] && break

  THREAD_DIR="$THREADS_DIR/${slug}"
  [[ -d "$THREAD_DIR" ]] || continue

  load_thread_entries_v2 "$THREAD_DIR" "$slug" "$ACTIVE_FULL_LIMIT" "$ACTIVE_SUMMARY_LIMIT"

  if [[ -n "$_ENTRY_OUTPUT" ]]; then
    COMBINED="${_HEADER}"$'\n\n'"${_ENTRY_OUTPUT}"
    COMBINED_SIZE=${#COMBINED}

    echo "--- ${slug}/ (active, ${_THREAD_FULL} full, ${_THREAD_SUMMARY} summary, ${_THREAD_OMITTED} omitted) ---"
    echo "$COMBINED"
    echo ""

    CHARS_USED=$((CHARS_USED + COMBINED_SIZE))
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
  fi
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

echo "[threads] Budget: ${CHARS_USED}/${BUDGET} chars | ${PINNED_COUNT} pinned, ${ACTIVE_COUNT} active, ${DORMANT_COUNT} dormant | ${FULL_ENTRY_COUNT} full, ${SUMMARY_ENTRY_COUNT} summary, ${OMITTED_ENTRY_COUNT} omitted"

if [[ -n "$HAS_PENDING" ]]; then
  echo "[threads] Pending session digest — process on first turn"
fi

echo ""
echo "=== End Threads ==="
