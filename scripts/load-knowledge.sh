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
CONTEXT_SIGNAL=$(extract_context_signal "$KNOWLEDGE_DIR")
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

  # Budget-check: use full index if <= 25% of budget, else compact
  INDEX_FULL_SIZE=${#INDEX_FULL}
  INDEX_COMPACT_SIZE=${#INDEX_COMPACT}
  INDEX_BUDGET_THRESHOLD=$((BUDGET / 4))

  if [[ $INDEX_FULL_SIZE -gt 0 ]]; then
    if [[ $INDEX_FULL_SIZE -le $INDEX_BUDGET_THRESHOLD ]]; then
      echo "--- Index ---"
      echo "$INDEX_FULL"
      CHARS_USED=$((CHARS_USED + INDEX_FULL_SIZE))
    elif [[ $INDEX_COMPACT_SIZE -gt 0 ]]; then
      echo "--- Index (compact) ---"
      echo "$INDEX_COMPACT"
      CHARS_USED=$((CHARS_USED + INDEX_COMPACT_SIZE))
    fi
  fi

  # --- Context-aware loading: FTS5-ranked entries first ---
  CONTEXT_LOADED_ENTRIES=()   # entry file paths already loaded via context signal
  CONTEXT_SECTIONS_COUNT=0
  CONTEXT_MAX_SECTIONS=5

  if [[ -n "$CONTEXT_SIGNAL" ]]; then
    # Build FTS5 OR query from context signal
    FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {'and', 'or', 'not', 'near'}
seen, terms = set(), []
for w in words:
    if w not in stop and w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
        if len(terms) >= 8:
            break
print(' OR '.join(terms))
" "$CONTEXT_SIGNAL" 2>/dev/null) || FTS5_QUERY=""

    if [[ -n "$FTS5_QUERY" ]]; then
      # Use composite scoring (BM25 + recency + access frequency) via pk_cli.py
      SEARCH_RESULTS=$(python3 "$SCRIPT_DIR/pk_cli.py" search "$KNOWLEDGE_DIR" "$FTS5_QUERY" \
        --type knowledge --limit "$CONTEXT_MAX_SECTIONS" --composite --json 2>/dev/null) || SEARCH_RESULTS="[]"

      # Parse composite-scored results and load matching entries
      while IFS=$'\t' read -r -d '' rel_path entry_content; do
        if [[ $CONTEXT_SECTIONS_COUNT -eq 0 ]]; then
          echo "--- Context-relevant entries (signal: ${CONTEXT_SIGNAL:0:60}) ---"
          echo ""
        fi

        ENTRY_SIZE=${#entry_content}

        # Check budget
        if [[ $((CHARS_USED + ENTRY_SIZE + 2)) -gt $BUDGET ]]; then
          break
        fi

        echo "$entry_content"
        echo ""
        CHARS_USED=$((CHARS_USED + ENTRY_SIZE + 1))
        CONTEXT_SECTIONS_COUNT=$((CONTEXT_SECTIONS_COUNT + 1))

        # Track loaded entries to avoid duplicates in priority pass
        CONTEXT_LOADED_ENTRIES+=("$rel_path")
      done < <(echo "$SEARCH_RESULTS" | python3 -c "
import json, sys, os
results = json.load(sys.stdin)
knowledge_dir = sys.argv[1]
for r in results:
    rel_path = r.get('file_path', '')
    content = r.get('content', '')
    if not content:
        abs_path = os.path.join(knowledge_dir, rel_path)
        if os.path.isfile(abs_path):
            content = open(abs_path, 'r').read().rstrip('\n')
    if content:
        sys.stdout.write(rel_path + '\t' + content + '\0')
" "$KNOWLEDGE_DIR" 2>/dev/null)
    fi

    if [[ $CONTEXT_SECTIONS_COUNT -gt 0 ]]; then
      echo ""
    fi
  fi

  # --- Priority-order loading: iterate category directories ---
  for category in "${PRIORITY_CATEGORIES[@]}"; do
    CAT_DIR="$KNOWLEDGE_DIR/$category"
    [[ -d "$CAT_DIR" ]] || continue

    # Collect entry files
    ENTRY_FILES=()
    while IFS= read -r -d '' f; do
      ENTRY_FILES+=("$f")
    done < <(find "$CAT_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)

    ENTRY_COUNT=${#ENTRY_FILES[@]}
    [[ $ENTRY_COUNT -gt 0 ]] || continue

    # Calculate total category size and collect per-entry info
    CAT_TOTAL_SIZE=0
    ENTRY_SIZES=()
    ENTRY_TITLES=()
    ENTRY_RELPATHS=()
    for entry_file in "${ENTRY_FILES[@]}"; do
      CONTENT=$(cat "$entry_file")
      SIZE=${#CONTENT}
      TITLE=$(echo "$CONTENT" | head -1 | sed 's/^# //')
      REL_PATH="${category}/$(basename "$entry_file")"

      ENTRY_SIZES+=("$SIZE")
      ENTRY_TITLES+=("$TITLE")
      ENTRY_RELPATHS+=("$REL_PATH")
      CAT_TOTAL_SIZE=$((CAT_TOTAL_SIZE + SIZE))
    done

    # Check if entire category fits in budget
    if [[ $((CHARS_USED + CAT_TOTAL_SIZE)) -le $BUDGET ]]; then
      # Load all entries in this category
      echo "--- ${category}/ (${ENTRY_COUNT} entries) ---"
      for i in "${!ENTRY_FILES[@]}"; do
        REL_PATH="${ENTRY_RELPATHS[$i]}"

        # Skip if already loaded via context signal
        ALREADY_LOADED=0
        if [[ ${#CONTEXT_LOADED_ENTRIES[@]} -gt 0 ]]; then
          for loaded in "${CONTEXT_LOADED_ENTRIES[@]}"; do
            if [[ "$loaded" == "$REL_PATH" ]]; then
              ALREADY_LOADED=1
              break
            fi
          done
        fi
        if [[ $ALREADY_LOADED -eq 1 ]]; then
          continue
        fi

        CONTENT=$(cat "${ENTRY_FILES[$i]}")
        echo "$CONTENT"
        echo ""
        CHARS_USED=$((CHARS_USED + ${ENTRY_SIZES[$i]} + 1))
      done
      FILES_FULL=$((FILES_FULL + 1))
    else
      # Category doesn't fit — try loading entries individually until budget exhausted
      LOADED_ANY=0
      SUMMARY_TITLES=()

      for i in "${!ENTRY_FILES[@]}"; do
        REL_PATH="${ENTRY_RELPATHS[$i]}"
        SIZE=${ENTRY_SIZES[$i]}

        # Skip if already loaded via context signal
        ALREADY_LOADED=0
        if [[ ${#CONTEXT_LOADED_ENTRIES[@]} -gt 0 ]]; then
          for loaded in "${CONTEXT_LOADED_ENTRIES[@]}"; do
            if [[ "$loaded" == "$REL_PATH" ]]; then
              ALREADY_LOADED=1
              break
            fi
          done
        fi
        if [[ $ALREADY_LOADED -eq 1 ]]; then
          continue
        fi

        if [[ $((CHARS_USED + SIZE)) -le $BUDGET ]]; then
          # Entry fits — load it
          if [[ $LOADED_ANY -eq 0 ]]; then
            echo "--- ${category}/ (${ENTRY_COUNT} entries, partial) ---"
          fi
          CONTENT=$(cat "${ENTRY_FILES[$i]}")
          echo "$CONTENT"
          echo ""
          CHARS_USED=$((CHARS_USED + SIZE + 1))
          LOADED_ANY=1
        else
          # Entry doesn't fit — add to summary list
          SUMMARY_TITLES+=("${ENTRY_TITLES[$i]}")
        fi
      done

      if [[ ${#SUMMARY_TITLES[@]} -gt 0 ]]; then
        if [[ $LOADED_ANY -eq 0 ]]; then
          echo "--- ${category}/ (${ENTRY_COUNT} entries, titles only) ---"
        fi
        # Show remaining as title list
        TITLE_LIST=""
        for title in "${SUMMARY_TITLES[@]}"; do
          CANDIDATE="${TITLE_LIST}  - ${title}"$'\n'
          if [[ $((CHARS_USED + ${#CANDIDATE})) -gt $BUDGET ]]; then
            TITLE_LIST="${TITLE_LIST}  (...truncated)"$'\n'
            break
          fi
          TITLE_LIST="$CANDIDATE"
        done
        echo "$TITLE_LIST"
        CHARS_USED=$((CHARS_USED + ${#TITLE_LIST}))
        FILES_SUMMARY=$((FILES_SUMMARY + 1))
      elif [[ $LOADED_ANY -eq 1 ]]; then
        FILES_FULL=$((FILES_FULL + 1))
      fi
    fi

    # Stop if budget exhausted
    if [[ $CHARS_USED -ge $BUDGET ]]; then
      echo "[Remaining categories available on-demand]"
      # Count remaining categories as skipped
      FOUND_CURRENT=0
      for remaining in "${PRIORITY_CATEGORIES[@]}"; do
        if [[ $FOUND_CURRENT -eq 1 ]]; then
          REMAINING_DIR="$KNOWLEDGE_DIR/$remaining"
          if [[ -d "$REMAINING_DIR" ]]; then
            RCOUNT=$(find "$REMAINING_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
            if [[ "${RCOUNT:-0}" -gt 0 ]]; then
              FILES_SKIPPED=$((FILES_SKIPPED + 1))
            fi
          fi
        fi
        if [[ "$remaining" == "$category" ]]; then
          FOUND_CURRENT=1
        fi
      done
      break
    fi
  done

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
printf '{"timestamp":"%s","format_version":%d,"budget_used":%d,"budget_total":%d,"files_full":%d,"files_summary":%d,"files_skipped":%d,"context_signal":"%s","context_sections":%d,"git_branch":"%s"}\n' \
  "$LOG_TIMESTAMP" \
  2 \
  "$CHARS_USED" \
  "$BUDGET" \
  "$FILES_FULL" \
  "$FILES_SUMMARY" \
  "$FILES_SKIPPED" \
  "$(echo "$CONTEXT_SIGNAL" | tr '"\\' '__')" \
  "$CONTEXT_SECTIONS_COUNT" \
  "$(echo "$CURRENT_BRANCH" | tr '"\\' '__')" \
  >> "$META_DIR/retrieval-log.jsonl" 2>/dev/null || true
