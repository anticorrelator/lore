#!/usr/bin/env bash
# load-knowledge.sh — SessionStart hook: detect inbox items + load knowledge
# Usage: bash load-knowledge.sh
# Called by Claude Code SessionStart hook (startup, resume, compact)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || exit 0

# If no knowledge store exists, show cold-start message
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  cat << 'EOF'
[Knowledge Store] No knowledge store found for this project.
Run `/memory init` to initialize one. Non-git directories require `/memory init --force`.
EOF
  exit 0
fi

source "$SCRIPT_DIR/lib.sh"

BUDGET=8000
CHARS_USED=0
FILES_FULL=0
FILES_SUMMARY=0
FILES_SKIPPED=0

# Category priority order
PRIORITY_CATEGORIES=(principles workflows conventions gotchas abstractions architecture team)

# --- Extract context signal from git branch + matched work item ---
# Used to bias which knowledge sections load first (when signal exists)
# Output format: signal, ---BACKLINKS---, backlink paths, ---SIGNAL_SOURCES---, source names
_SIGNAL_OUTPUT=$(extract_context_signal "$KNOWLEDGE_DIR")
CONTEXT_SIGNAL=$(echo "$_SIGNAL_OUTPUT" | head -1)
CONTEXT_BACKLINKS=$(echo "$_SIGNAL_OUTPUT" | sed -n '/^---BACKLINKS---$/,/^---SIGNAL_SOURCES---$/{ /^---/d; p; }')
CONTEXT_SIGNAL_SOURCES=$(echo "$_SIGNAL_OUTPUT" | sed '1,/^---SIGNAL_SOURCES---$/d')
CURRENT_BRANCH=$(get_git_branch)

# --- Job A: Detect inbox entries ---
INBOX_COUNT=0

# Count files in _inbox/ directory
INBOX_DIR="$KNOWLEDGE_DIR/_inbox"
if [[ -d "$INBOX_DIR" ]]; then
  INBOX_COUNT=$(find "$INBOX_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
fi

if [[ "$INBOX_COUNT" -gt 0 ]]; then
  echo "[Knowledge Store] $INBOX_COUNT entries in inbox — run \`/memory curate\` to review."
  echo ""
fi

# --- Job B: Load knowledge ---
echo "=== Project Knowledge ==="
echo ""

# --- Dynamic index: build full and compact versions ---
  # Full index: category names + per-entry titles
  # Compact index: category names + entry counts only (saves ~90% of index budget)
  INDEX_FULL=""
  INDEX_COMPACT=""

  for category in "${PRIORITY_CATEGORIES[@]}"; do
    CAT_DIR="$KNOWLEDGE_DIR/$category"
    [[ -d "$CAT_DIR" ]] || continue

    ENTRY_FILES=()
    while IFS= read -r -d '' f; do
      ENTRY_FILES+=("$f")
    done < <(find "$CAT_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)

    ENTRY_COUNT=${#ENTRY_FILES[@]}
    [[ $ENTRY_COUNT -gt 0 ]] || continue

    INDEX_FULL+="**${category}/** (${ENTRY_COUNT} entries):"$'\n'
    INDEX_COMPACT+="**${category}/** (${ENTRY_COUNT} entries)"$'\n'
    for entry_file in "${ENTRY_FILES[@]}"; do
      # Extract title from first line (# Title)
      TITLE=$(head -1 "$entry_file" | sed 's/^# //')
      INDEX_FULL+="  - ${TITLE}"$'\n'
    done
    INDEX_FULL+=$'\n'
  done

  # Include domains if present
  DOMAINS_DIR="$KNOWLEDGE_DIR/domains"
  if [[ -d "$DOMAINS_DIR" ]]; then
    DOMAIN_FILES=()
    while IFS= read -r -d '' f; do
      DOMAIN_FILES+=("$f")
    done < <(find "$DOMAINS_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)

    if [[ ${#DOMAIN_FILES[@]} -gt 0 ]]; then
      INDEX_FULL+="**domains/** (${#DOMAIN_FILES[@]} files, lazy-loaded):"$'\n'
      INDEX_COMPACT+="**domains/** (${#DOMAIN_FILES[@]} files, lazy-loaded)"$'\n'
      for df in "${DOMAIN_FILES[@]}"; do
        TITLE=$(head -1 "$df" | sed 's/^# //')
        INDEX_FULL+="  - ${TITLE}"$'\n'
      done
      INDEX_FULL+=$'\n'
    fi
  fi

  # Always show compact index — not counted against entry budget
  INDEX_COMPACT_SIZE=${#INDEX_COMPACT}
  if [[ $INDEX_COMPACT_SIZE -gt 0 ]]; then
    echo "--- Index (compact) ---"
    echo "$INDEX_COMPACT"
  fi

  # --- Step 1: Direct-resolve knowledge backlinks ---
  DIRECT_RESOLVED_COUNT=0
  DIRECT_LOADED_PATHS=()   # track loaded paths to exclude from search results

  if [[ -n "$CONTEXT_BACKLINKS" ]]; then
    FIRST_DIRECT=1
    while IFS= read -r backlink_path; do
      [[ -n "$backlink_path" ]] || continue

      # Skip domain entries — they are lazy-loaded on demand, never at startup
      if [[ "$backlink_path" == domains/* ]]; then
        continue
      fi

      # Resolve backlink to an absolute file path
      # Backlinks look like: "conventions/naming-patterns" or "architecture/service-design"
      ABS_PATH="$KNOWLEDGE_DIR/${backlink_path}.md"
      if [[ ! -f "$ABS_PATH" ]]; then
        # Try without .md extension (in case it already has one or is a directory path)
        ABS_PATH="$KNOWLEDGE_DIR/${backlink_path}"
        [[ -f "$ABS_PATH" ]] || continue
      fi

      CONTENT=$(cat "$ABS_PATH" 2>/dev/null) || continue
      ENTRY_SIZE=${#CONTENT}

      # Check budget
      if [[ $((CHARS_USED + ENTRY_SIZE + 2)) -gt $BUDGET ]]; then
        continue
      fi

      if [[ $FIRST_DIRECT -eq 1 ]]; then
        echo "--- Direct-resolved entries (from backlinks) ---"
        echo ""
        FIRST_DIRECT=0
      fi

      echo "$CONTENT"
      echo ""
      CHARS_USED=$((CHARS_USED + ENTRY_SIZE + 1))
      DIRECT_RESOLVED_COUNT=$((DIRECT_RESOLVED_COUNT + 1))
      FILES_FULL=$((FILES_FULL + 1))

      # Track loaded path for dedup
      DIRECT_LOADED_PATHS+=("$backlink_path")
    done <<< "$CONTEXT_BACKLINKS"

    if [[ $DIRECT_RESOLVED_COUNT -gt 0 ]]; then
      echo ""
    fi
  fi

  # --- Step 2: Relevance-ranked search via budget_search ---
  RELEVANCE_SEARCH_COUNT=0

  if [[ -n "$CONTEXT_SIGNAL" ]]; then
    # Build FTS5 OR query from context signal
    FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
# Strip markdown/punctuation, normalize to plain words
signal = re.sub(r'[*\`\[\]\(\),;:!?\"{}|<>#@=+~^]', ' ', signal)
words = re.sub(r'[-_/]', ' ', signal).lower().split()
# FTS5 operators + common English stopwords
stop = {
    'and', 'or', 'not', 'near',  # FTS5 operators
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    # Strip remaining non-alphanumeric chars and skip short/stop/numeric
    w = re.sub(r'[^a-z0-9]', '', w)
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "$CONTEXT_SIGNAL" 2>/dev/null) || FTS5_QUERY=""

    if [[ -n "$FTS5_QUERY" ]]; then
      REMAINING_BUDGET=$((BUDGET - CHARS_USED))

      # Call budget_search via pk_cli.py — returns two-tier JSON
      # Exclude domains/ (lazy-loaded on demand, never at startup)
      BUDGET_RESULTS=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$KNOWLEDGE_DIR" "$FTS5_QUERY" \
        --type knowledge --limit 20 --budget "$REMAINING_BUDGET" \
        --exclude-category domains 2>/dev/null) || BUDGET_RESULTS="{}"

      # Build direct-loaded paths for dedup
      DIRECT_PATHS_JSON="[]"
      if [[ ${#DIRECT_LOADED_PATHS[@]} -gt 0 ]]; then
        DIRECT_PATHS_JSON=$(printf '%s\n' "${DIRECT_LOADED_PATHS[@]}" | python3 -c "
import json, sys
paths = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(paths))
" 2>/dev/null) || DIRECT_PATHS_JSON="[]"
      fi

      # Parse full entries (null-delimited: file_path\tcontent\0)
      FIRST_FULL=1
      while IFS=$'\t' read -r -d '' rel_path entry_content; do
        [[ -n "$rel_path" ]] || continue
        if [[ $FIRST_FULL -eq 1 ]]; then
          echo "--- Relevant entries (signal: ${CONTEXT_SIGNAL:0:60}) ---"
          echo ""
          FIRST_FULL=0
        fi
        echo "$entry_content"
        echo ""
        ENTRY_SIZE=${#entry_content}
        CHARS_USED=$((CHARS_USED + ENTRY_SIZE + 1))
        RELEVANCE_SEARCH_COUNT=$((RELEVANCE_SEARCH_COUNT + 1))
        FILES_FULL=$((FILES_FULL + 1))
      done < <(echo "$BUDGET_RESULTS" | python3 -c "
import json, sys, os
data = json.load(sys.stdin)
direct_paths = json.loads(sys.argv[1])
knowledge_dir = sys.argv[2]

# Build dedup set from direct-resolved paths
direct_set = set()
for dp in direct_paths:
    direct_set.add(dp)
    if not dp.endswith('.md'):
        direct_set.add(dp + '.md')

for e in data.get('full', []):
    fp = e.get('file_path', '')
    fp_no_ext = fp.rsplit('.', 1)[0] if '.' in fp else fp
    if fp in direct_set or fp_no_ext in direct_set:
        continue
    content = e.get('content', '')
    if not content:
        abs_path = os.path.join(knowledge_dir, fp)
        if os.path.isfile(abs_path):
            content = open(abs_path, 'r').read().rstrip('\n')
    if content:
        sys.stdout.write(fp + '\t' + content + '\0')
" "$DIRECT_PATHS_JSON" "$KNOWLEDGE_DIR" 2>/dev/null)

      # Parse titles-only entries (null-delimited: heading\tfile_path\0)
      FIRST_TITLE=1
      while IFS=$'\t' read -r -d '' heading title_path; do
        [[ -n "$heading" ]] || continue
        if [[ $FIRST_TITLE -eq 1 ]]; then
          echo "--- Additional relevant entries (titles only) ---"
          FIRST_TITLE=0
        fi
        echo "  - ${heading} (${title_path})"
        FILES_SUMMARY=$((FILES_SUMMARY + 1))
      done < <(echo "$BUDGET_RESULTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
direct_paths = json.loads(sys.argv[1])

direct_set = set()
for dp in direct_paths:
    direct_set.add(dp)
    if not dp.endswith('.md'):
        direct_set.add(dp + '.md')

for e in data.get('titles_only', []):
    fp = e.get('file_path', '')
    fp_no_ext = fp.rsplit('.', 1)[0] if '.' in fp else fp
    if fp in direct_set or fp_no_ext in direct_set:
        continue
    heading = e.get('heading', '')
    if heading:
        sys.stdout.write(heading + '\t' + fp + '\0')
" "$DIRECT_PATHS_JSON" 2>/dev/null)

      if [[ $FIRST_TITLE -eq 0 ]]; then
        echo ""
      fi
    fi
  fi

  # --- Health check (v2) ---
  ISSUES=()
  if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
    ISSUES+=("_manifest.json missing")
  fi
  if [[ ! -d "$KNOWLEDGE_DIR/domains" ]]; then
    ISSUES+=("domains/ directory missing")
  fi
  # Check that at least one category directory exists
  HAS_CATEGORY=0
  for chk_cat in "${PRIORITY_CATEGORIES[@]}"; do
    if [[ -d "$KNOWLEDGE_DIR/$chk_cat" ]]; then
      HAS_CATEGORY=1
      break
    fi
  done
  if [[ $HAS_CATEGORY -eq 0 ]]; then
    ISSUES+=("no category directories found")
  fi

  if [[ ${#ISSUES[@]} -gt 0 ]]; then
    echo ""
    echo "[Health] Issues detected: ${ISSUES[*]}"
    echo "Run \`/memory heal\` to fix structural issues."
  fi

  # --- Staleness check (v2): check entry files in category directories ---
  STALE_ENTRIES=()
  STALE_COUNT=0
  NOW=$(date +%s)
  NINETY_DAYS=$((90 * 86400))

  for category in "${PRIORITY_CATEGORIES[@]}"; do
    CAT_DIR="$KNOWLEDGE_DIR/$category"
    [[ -d "$CAT_DIR" ]] || continue

    while IFS= read -r -d '' file; do
      BASENAME=$(basename "$file")

      # Check file mtime > 90 days
      FILE_MTIME=$(get_mtime "$file")
      [[ "$FILE_MTIME" -eq 0 ]] && FILE_MTIME="$NOW"
      AGE=$((NOW - FILE_MTIME))
      if [[ $AGE -gt $NINETY_DAYS ]]; then
        DAYS_OLD=$((AGE / 86400))
        STALE_ENTRIES+=("${category}/${BASENAME} (${DAYS_OLD}d)")
        STALE_COUNT=$((STALE_COUNT + 1))
      fi

      # Check for low-confidence markers
      LOW_CONF=$(grep -c 'confidence: low' "$file" 2>/dev/null || true)
      LOW_CONF=$(echo "$LOW_CONF" | tr -d '[:space:]')
      if [[ "${LOW_CONF:-0}" -gt 0 ]]; then
        ALREADY=0
        if [[ $STALE_COUNT -gt 0 ]]; then
          for entry in "${STALE_ENTRIES[@]}"; do
            if [[ "$entry" == "${category}/${BASENAME}"* ]]; then
              ALREADY=1
              break
            fi
          done
        fi
        if [[ $ALREADY -eq 0 ]]; then
          STALE_ENTRIES+=("${category}/${BASENAME} (low-confidence)")
          STALE_COUNT=$((STALE_COUNT + 1))
        fi
      fi
    done < <(find "$CAT_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
  done

  if [[ $STALE_COUNT -gt 0 ]]; then
    echo ""
    echo "[Stale] Entries needing review: ${STALE_ENTRIES[*]}"
  fi

  # --- Stats (v2): count entry files per category ---
  TOTAL_ENTRIES=0
  TOTAL_CATEGORIES=0
  for category in "${PRIORITY_CATEGORIES[@]}"; do
    CAT_DIR="$KNOWLEDGE_DIR/$category"
    [[ -d "$CAT_DIR" ]] || continue
    COUNT=$(find "$CAT_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "${COUNT:-0}" -gt 0 ]]; then
      TOTAL_ENTRIES=$((TOTAL_ENTRIES + COUNT))
      TOTAL_CATEGORIES=$((TOTAL_CATEGORIES + 1))
    fi
  done
  # Include domain files
  if [[ -d "$KNOWLEDGE_DIR/domains" ]]; then
    DCOUNT=$(find "$KNOWLEDGE_DIR/domains" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "${DCOUNT:-0}" -gt 0 ]]; then
      TOTAL_ENTRIES=$((TOTAL_ENTRIES + DCOUNT))
      TOTAL_CATEGORIES=$((TOTAL_CATEGORIES + 1))
    fi
  fi

echo "[Budget] ${CHARS_USED}/${BUDGET} chars | ${FILES_FULL} full, ${FILES_SUMMARY} summary, ${FILES_SKIPPED} skipped"
if [[ $TOTAL_ENTRIES -gt 0 ]]; then
  echo "[knowledge] ${TOTAL_ENTRIES} entries across ${TOTAL_CATEGORIES} categories — use \`/memory search <query>\` before raw exploration"
fi
echo "[search] lore search \"<query>\" --json | /memory search <query> | /work search <query>"
echo ""
echo "=== End Project Knowledge ==="

# --- Log retrieval metrics to _meta/ ---
META_DIR="$KNOWLEDGE_DIR/_meta"
mkdir -p "$META_DIR"
LOG_TIMESTAMP=$(timestamp_iso)
CONTEXT_SECTIONS_TOTAL=$((DIRECT_RESOLVED_COUNT + RELEVANCE_SEARCH_COUNT))

# Build signal_sources JSON array from newline-separated source names
SIGNAL_SOURCES_JSON="[]"
if [[ -n "$CONTEXT_SIGNAL_SOURCES" ]]; then
  SIGNAL_SOURCES_JSON=$(echo "$CONTEXT_SIGNAL_SOURCES" | python3 -c "
import json, sys
sources = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(sources))
" 2>/dev/null) || SIGNAL_SOURCES_JSON="[]"
fi

printf '{"timestamp":"%s","format_version":%d,"budget_used":%d,"budget_total":%d,"files_full":%d,"files_summary":%d,"files_skipped":%d,"context_signal":"%s","context_sections":%d,"direct_resolved":%d,"relevance_search":%d,"signal_sources":%s,"git_branch":"%s"}\n' \
  "$LOG_TIMESTAMP" \
  4 \
  "$CHARS_USED" \
  "$BUDGET" \
  "$FILES_FULL" \
  "$FILES_SUMMARY" \
  "$FILES_SKIPPED" \
  "$(echo "$CONTEXT_SIGNAL" | tr '"\\' '__')" \
  "$CONTEXT_SECTIONS_TOTAL" \
  "$DIRECT_RESOLVED_COUNT" \
  "$RELEVANCE_SEARCH_COUNT" \
  "$SIGNAL_SOURCES_JSON" \
  "$(echo "$CURRENT_BRANCH" | tr '"\\' '__')" \
  >> "$META_DIR/retrieval-log.jsonl" 2>/dev/null || true
