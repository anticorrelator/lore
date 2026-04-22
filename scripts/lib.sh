#!/usr/bin/env bash
# lib.sh — Shared utility functions for lore scripts and skills
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Or from skills: source ~/.lore/scripts/lib.sh
#
# NOTE: This is a library file. Do NOT add set -euo pipefail here.
# Callers set their own shell options.

LORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- die ---
# Print an error message to stderr and exit with status 1.
# Usage: die "something went wrong"
die() {
  echo "Error: $*" >&2
  exit 1
}

# --- json_error ---
# Print a JSON error object to stdout and exit with status 1.
# The message is properly escaped for JSON (handles quotes, backslashes, newlines).
# Usage: json_error "something went wrong"
# Output: {"error": "something went wrong"}
json_error() {
  local msg="$1"
  local escaped
  escaped=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")')
  printf '{"error": %s}\n' "$escaped"
  exit 1
}

# --- json_output ---
# Print a JSON string to stdout and exit with status 0.
# The caller is responsible for providing valid JSON.
# Usage: json_output '{"key": "value"}'
json_output() {
  printf '%s\n' "$1"
  exit 0
}

# --- json_field ---
# Extract a JSON string field value using grep/sed.
# Usage: value=$(json_field "title" "$file")
# Returns the first match of "key": "value" from the given file.
json_field() {
  local key="$1"
  local file="$2"
  grep "\"$key\"" "$file" | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1
}

# --- slugify ---
# Convert a string to a URL-friendly kebab-case slug.
# Strips common stopwords to produce more compact slugs.
# Usage: slug=$(slugify "My Work Item Name")
# Output: "my-work-item-name"
MAX_SLUG_LENGTH=50
slugify() {
  local input="$1"
  local lower
  lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  local stripped
  stripped=$(echo "$lower" \
    | sed -E 's/(^| )(the|a|an|and|or|but|with|for|via|from|into|after|before|between|through|about|during|using|based)( |$)/ /g' \
    | sed -E 's/(^| )(the|a|an|and|or|but|with|for|via|from|into|after|before|between|through|about|during|using|based)( |$)/ /g')
  # Fall back to original if stopword removal left only whitespace
  local check
  check=$(echo "$stripped" | tr -d '[:space:]')
  if [[ -z "$check" ]]; then
    stripped="$lower"
  fi
  echo "$stripped" \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-$MAX_SLUG_LENGTH
}

# --- resolve_knowledge_dir ---
# Resolve the knowledge store directory for the current project.
# Usage: KDIR=$(resolve_knowledge_dir)
resolve_knowledge_dir() {
  "$LORE_LIB_DIR/resolve-repo.sh"
}

# --- resolve_followup_dir ---
# Resolve the on-disk directory for a followup id, checking active then archive.
# Requires FOLLOWUPS_DIR to be set by the caller (typically "$KNOWLEDGE_DIR/_followups").
# Echoes the absolute path on stdout; on miss, writes a diagnostic to stderr and returns non-zero.
# Usage: dir=$(resolve_followup_dir "$id") || exit 1
resolve_followup_dir() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "[followup] Error: resolve_followup_dir requires an id" >&2
    return 1
  fi
  if [[ -z "${FOLLOWUPS_DIR:-}" ]]; then
    echo "[followup] Error: FOLLOWUPS_DIR is not set" >&2
    return 1
  fi
  if [[ -d "$FOLLOWUPS_DIR/$id" ]]; then
    echo "$FOLLOWUPS_DIR/$id"
    return 0
  fi
  if [[ -d "$FOLLOWUPS_DIR/_archive/$id" ]]; then
    echo "$FOLLOWUPS_DIR/_archive/$id"
    return 0
  fi
  echo "[followup] Error: followup '$id' not found in $FOLLOWUPS_DIR or $FOLLOWUPS_DIR/_archive" >&2
  return 1
}

# --- get_git_branch ---
# Get the current git branch name, or empty string if not in a git repo.
# Usage: branch=$(get_git_branch)
get_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# --- timestamp_iso ---
# Generate an ISO 8601 UTC timestamp.
# Usage: ts=$(timestamp_iso)
# Output: "2026-02-07T04:30:00Z"
timestamp_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- get_mtime ---
# Get the modification time of a file as Unix epoch seconds.
# Cross-platform: works on both Darwin (macOS) and Linux.
# Usage: mtime=$(get_mtime "$file")
# Output: Unix epoch seconds (e.g., "1707300000"), or "0" on error.
get_mtime() {
  local file="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f %m "$file" 2>/dev/null || echo "0"
  else
    stat -c %Y "$file" 2>/dev/null || echo "0"
  fi
}

# --- find_lore_config ---
# Walk from a starting directory up to / looking for a .lore.config file.
# Echoes the absolute path to the file and returns 0 if found, returns 1 if not.
# Usage: config_path=$(find_lore_config) && echo "found at $config_path"
#        find_lore_config "/some/start/dir"
find_lore_config() {
  local dir="${1:-$(pwd)}"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
  while true; do
    if [[ -f "$dir/.lore.config" ]]; then
      echo "$dir/.lore.config"
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

# --- parse_lore_config ---
# Extract a value by key from a .lore.config file.
# Ignores blank lines and lines starting with #.
# Usage: repo=$(parse_lore_config "repo" "/path/to/.lore.config")
# Output: The value after the = sign, with leading/trailing whitespace stripped.
# Returns 0 if key found, 1 if not found or file missing.
parse_lore_config() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  local line value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Match key= at start of line
    if [[ "$line" == "${key}="* ]]; then
      value="${line#"${key}="}"
      # Strip leading and trailing whitespace
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      echo "$value"
      return 0
    fi
  done < "$file"
  return 1
}

# --- json_array_field ---
# Extract a JSON array field's inner content from a file using awk.
# Handles both single-line ["a","b"] and multi-line arrays.
# Usage: values=$(json_array_field "branches" "$file")
# Output: Inner content of the array with whitespace stripped (e.g., "a","b")
# For display formatting, pipe through: sed 's/"//g; s/,/, /g'
json_array_field() {
  local key="$1"
  local file="$2"
  awk -v key="\"$key\"" '
    $0 ~ key {
      match($0, /\[.*\]/)
      if (RSTART > 0) {
        arr = substr($0, RSTART+1, RLENGTH-2)
        gsub(/[[:space:]]/, "", arr)
        print arr
        next
      }
      collecting = 1
      buf = ""
      next
    }
    collecting && /\]/ {
      buf = buf $0
      gsub(/[[:space:]\]\[]/, "", buf)
      sub(/,$/, "", buf)
      print buf
      collecting = 0
      next
    }
    collecting { buf = buf $0 }
  ' "$file"
}

# --- lore_agent_enabled ---
# Returns 0 (success) if lore agent integration is enabled, non-zero if disabled.
# Checks in priority order:
#   1. LORE_AGENT_DISABLED=1 env var → disabled (returns 1)
#   2. ~/.lore/config/agent.json enabled field → false means disabled (returns 1)
#   3. File absent or enabled=true → enabled (returns 0)
# Usage: lore_agent_enabled || exit 0
lore_agent_enabled() {
  if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
    return 1
  fi
  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/agent.json"
  if [[ -f "$config_file" ]]; then
    if grep -q '"enabled"[[:space:]]*:[[:space:]]*false' "$config_file"; then
      return 1
    fi
  fi
  return 0
}

# --- load_claude_args ---
# Print the args to prepend to every `claude` CLI invocation, one per line.
# Callers: mapfile -t CLAUDE_ARGS < <(load_claude_args)
# Resolution order:
#   1. LORE_CLAUDE_ARGS env var (JSON array, requires jq)
#   2. $LORE_DATA_DIR/config/claude.json `.args` (requires jq)
#   3. built-in default: --dangerously-skip-permissions
# Mirrors config.LoadClaudeConfig() in tui/internal/config/config.go.
load_claude_args() {
  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/claude.json"
  if command -v jq &>/dev/null; then
    if [[ -n "${LORE_CLAUDE_ARGS:-}" ]]; then
      if printf '%s' "$LORE_CLAUDE_ARGS" | jq -e 'type == "array"' &>/dev/null; then
        printf '%s' "$LORE_CLAUDE_ARGS" | jq -r '.[]'
        return
      fi
    fi
    if [[ -f "$config_file" ]]; then
      if jq -e '.args | type == "array"' "$config_file" &>/dev/null; then
        jq -r '.args[]' "$config_file"
        return
      fi
    fi
  fi
  echo "--dangerously-skip-permissions"
}

# --- resolve_ceremony_config_path ---
# Resolve the path to the global ceremony config file (ceremonies.json)
# at $LORE_DATA_DIR/ceremonies.json (defaults to ~/.lore/ceremonies.json).
# Usage: config_path=$(resolve_ceremony_config_path)
# Output: Absolute path to ceremonies.json (file may not exist yet)
resolve_ceremony_config_path() {
  source "$LORE_LIB_DIR/config.sh"
  echo "${LORE_DATA_DIR}/ceremonies.json"
}

# --- check_fts_available ---
# Check if FTS5 search backend is available (python3 + sqlite3).
# Sets USE_FTS=1 if available, USE_FTS=0 otherwise.
# Usage: check_fts_available; if [[ $USE_FTS -eq 1 ]]; then ...
check_fts_available() {
  USE_FTS=0
  if command -v python3 &>/dev/null && python3 -c "import sqlite3" 2>/dev/null; then
    USE_FTS=1
  fi
}

# --- update_meta_timestamp ---
# Update the "updated" field in a work item's _meta.json to the current UTC time.
# Usage: update_meta_timestamp "$WORK_DIR/$slug"
# Args: $1 = work item directory (containing _meta.json)
# No-op if _meta.json doesn't exist.
update_meta_timestamp() {
  local work_item_dir="$1"
  local meta_file="$work_item_dir/_meta.json"
  [[ -f "$meta_file" ]] || return 0
  local ts
  ts=$(timestamp_iso)
  # Replace the "updated" field value in-place
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ts\"/" "$meta_file"
  else
    sed -i "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ts\"/" "$meta_file"
  fi
}

# --- iso_to_epoch ---
# Convert an ISO 8601 timestamp to Unix epoch seconds.
# Handles "2026-02-07T04:30:00Z" and "2026-02-07T04:30:00" (with or without Z).
# Cross-platform: works on both Darwin (macOS) and Linux.
# Usage: epoch=$(iso_to_epoch "2026-02-07T04:30:00Z")
# Output: Unix epoch seconds (e.g., "1738903800"), or "0" on error.
iso_to_epoch() {
  local iso_date="$1"
  if [[ -z "$iso_date" ]]; then
    echo "0"
    return
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_date" +%s 2>/dev/null \
      || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_date%Z}" +%s 2>/dev/null \
      || echo "0"
  else
    date -d "$iso_date" +%s 2>/dev/null || echo "0"
  fi
}

# --- extract_backlinks ---
# Extract [[knowledge:...]] backlinks from a file (notes.md or plan.md).
# Returns one backlink path per line (the part after "knowledge:").
# Usage: backlinks=$(extract_backlinks "$file")
# Output: Newline-separated knowledge paths (e.g., "conventions/skills/skill-composition-via-allowed-tools")
extract_backlinks() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local raw
  raw=$(grep -oE '\[\[knowledge:[^]]+\]\]' "$file" 2>/dev/null) || true
  if [[ -n "$raw" ]]; then
    echo "$raw" | sed 's/\[\[knowledge://;s/\]\]//' | sort -u
  fi
}

# --- _extract_work_item_backlinks ---
# Extract [[knowledge:...]] backlinks from a work item's notes.md and plan.md.
# Returns deduplicated backlink paths, one per line.
# Usage: backlinks=$(_extract_work_item_backlinks "$work_item_dir")
_extract_work_item_backlinks() {
  local work_item_dir="$1"
  local notes_backlinks plan_backlinks
  notes_backlinks=$(extract_backlinks "${work_item_dir}notes.md")
  plan_backlinks=$(extract_backlinks "${work_item_dir}plan.md")

  if [[ -n "$notes_backlinks" || -n "$plan_backlinks" ]]; then
    printf '%s\n%s' "$notes_backlinks" "$plan_backlinks" | grep -v '^$' | sort -u
  fi
}

# --- _extract_work_item_signal ---
# Extract signal terms from a single work item directory.
# Reads title, plan headings, tags from _meta.json, and first ~500 chars of notes.md.
# Usage: output=$(_extract_work_item_signal "$work_item_dir")
# Output format (multi-line):
#   Line 1: Space-separated signal terms (may be empty)
#   Line 2: "---ITEM_SOURCES---" delimiter
#   Lines 3+: One source name per line (title, tags, plan_headings, notes)
_extract_work_item_signal() {
  local work_item_dir="$1"
  local signal=""
  local sources=()
  local meta_file="${work_item_dir}_meta.json"

  # Title
  if [[ -f "$meta_file" ]]; then
    local work_title
    work_title=$(json_field "title" "$meta_file")
    if [[ -n "$work_title" ]]; then
      signal="${work_title}"
      sources+=("title")
    fi

    # Tags from _meta.json (JSON array → space-separated words)
    local tags_raw
    tags_raw=$(json_array_field "tags" "$meta_file")
    if [[ -n "$tags_raw" ]]; then
      local tags_clean
      tags_clean=$(echo "$tags_raw" | sed 's/"//g; s/,/ /g; s/-/ /g')
      if [[ -n "$tags_clean" ]]; then
        signal="${signal} ${tags_clean}"
        sources+=("tags")
      fi
    fi
  fi

  # Plan headings
  local plan_file="${work_item_dir}plan.md"
  if [[ -f "$plan_file" ]]; then
    local plan_headings
    plan_headings=$(grep '^### ' "$plan_file" 2>/dev/null | sed 's/^### //' | head -5 | tr '\n' ' ')
    if [[ -n "$plan_headings" ]]; then
      signal="${signal} ${plan_headings}"
      sources+=("plan_headings")
    fi
  fi

  # First ~500 chars of notes.md (strip markdown headings, comments, blank lines)
  local notes_file="${work_item_dir}notes.md"
  if [[ -f "$notes_file" ]]; then
    local notes_text
    notes_text=$(sed '/^#/d; /^$/d; /^<!--/d' "$notes_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)
    if [[ -n "$notes_text" ]]; then
      signal="${signal} ${notes_text}"
      sources+=("notes")
    fi
  fi

  echo "$signal"
  echo "---ITEM_SOURCES---"
  if [[ ${#sources[@]} -gt 0 ]]; then
    printf '%s\n' "${sources[@]}"
  fi
}

# --- extract_context_signal ---
# Extract context signal from git branch + matched work item for FTS5 ranking.
# Combines branch name, work item title, plan headings, tags, and notes into a text signal.
# Also extracts [[knowledge:...]] backlinks from notes.md and plan.md.
# On main/master, falls back to most recently updated active work item.
# Usage: OUTPUT=$(extract_context_signal "$KNOWLEDGE_DIR")
# Output format (multi-line):
#   Line 1: Space-separated signal terms (may be empty)
#   Line 2: "---BACKLINKS---" delimiter
#   Lines 3+: One knowledge backlink path per line (may be none)
#   "---SIGNAL_SOURCES---" delimiter
#   Remaining lines: One source name per line (branch, title, tags, plan_headings, notes, backlinks)
# Parsing:
#   CONTEXT_SIGNAL=$(echo "$OUTPUT" | head -1)
#   BACKLINKS=$(echo "$OUTPUT" | sed -n '/^---BACKLINKS---$/,/^---SIGNAL_SOURCES---$/{ /^---/d; p; }')
#   SIGNAL_SOURCES=$(echo "$OUTPUT" | sed '1,/^---SIGNAL_SOURCES---$/d')
extract_context_signal() {
  local knowledge_dir="$1"
  local signal=""
  local backlinks=""
  local signal_sources=()
  local branch
  branch=$(get_git_branch)

  # Helper: call _extract_work_item_signal and parse its multi-line output
  _parse_item_signal() {
    local item_output="$1"
    # Signal is line 1
    _PARSED_SIGNAL=$(echo "$item_output" | head -1)
    # Sources are after ---ITEM_SOURCES--- delimiter
    _PARSED_SOURCES=$(echo "$item_output" | sed '1,/^---ITEM_SOURCES---$/d')
  }

  if [[ -n "$branch" && "$branch" != "main" && "$branch" != "master" ]]; then
    # Branch name as initial signal (convert hyphens/underscores to spaces)
    signal=$(echo "$branch" | tr '_/-' ' ')
    signal_sources+=("branch")

    # Try to match branch to a work item for a stronger signal
    local work_dir="$knowledge_dir/_work"
    if [[ -d "$work_dir" ]]; then
      local work_item_dir meta_file
      for work_item_dir in "$work_dir"/*/; do
        [[ -d "$work_item_dir" ]] || continue
        meta_file="${work_item_dir}_meta.json"
        [[ -f "$meta_file" ]] || continue

        if grep -q "\"$branch\"" "$meta_file" 2>/dev/null; then
          local item_output
          item_output=$(_extract_work_item_signal "$work_item_dir")
          _parse_item_signal "$item_output"
          if [[ -n "$_PARSED_SIGNAL" ]]; then
            signal="${signal} ${_PARSED_SIGNAL}"
          fi
          # Collect item sources
          if [[ -n "$_PARSED_SOURCES" ]]; then
            while IFS= read -r src; do
              [[ -n "$src" ]] && signal_sources+=("$src")
            done <<< "$_PARSED_SOURCES"
          fi

          # Extract backlinks from notes.md and plan.md
          backlinks=$(_extract_work_item_backlinks "$work_item_dir")
          if [[ -n "$backlinks" ]]; then
            signal_sources+=("backlinks")
          fi
          break
        fi
      done
    fi
  else
    # On main/master: use most recently updated active work item
    local work_dir="$knowledge_dir/_work"
    if [[ -d "$work_dir" ]]; then
      local newest_mtime=0 newest_dir="" work_item_dir dirname meta_file item_status item_mtime
      for work_item_dir in "$work_dir"/*/; do
        [[ -d "$work_item_dir" ]] || continue
        dirname=$(basename "$work_item_dir")
        [[ "$dirname" == _* ]] && continue
        meta_file="${work_item_dir}_meta.json"
        [[ -f "$meta_file" ]] || continue

        item_status=$(json_field "status" "$meta_file")
        if [[ "$item_status" == "completed" || "$item_status" == "archived" ]]; then
          continue
        fi

        item_mtime=$(get_mtime "$meta_file")
        if [[ "$item_mtime" -gt "$newest_mtime" ]]; then
          newest_mtime="$item_mtime"
          newest_dir="$work_item_dir"
        fi
      done

      if [[ -n "$newest_dir" ]]; then
        local item_output
        item_output=$(_extract_work_item_signal "$newest_dir")
        _parse_item_signal "$item_output"
        signal="$_PARSED_SIGNAL"
        # Collect item sources
        if [[ -n "$_PARSED_SOURCES" ]]; then
          while IFS= read -r src; do
            [[ -n "$src" ]] && signal_sources+=("$src")
          done <<< "$_PARSED_SOURCES"
        fi

        backlinks=$(_extract_work_item_backlinks "$newest_dir")
        if [[ -n "$backlinks" ]]; then
          signal_sources+=("backlinks")
        fi
      fi
    fi
  fi

  # Output: signal on first line, delimiter, backlinks, delimiter, signal sources
  echo "$signal"
  echo "---BACKLINKS---"
  if [[ -n "$backlinks" ]]; then
    echo "$backlinks"
  fi
  echo "---SIGNAL_SOURCES---"
  if [[ ${#signal_sources[@]} -gt 0 ]]; then
    printf '%s\n' "${signal_sources[@]}"
  fi
}

# --- entry_filename_from_heading ---
# Convert a thread entry heading into a filename stem (without .md).
# Handles: "## 2026-02-06" → "2026-02-06"
#          "## 2026-02-06 (Session 6)" → "2026-02-06-s6"
#          "## 2026-02-07 (Session 14, continued)" → "2026-02-07-s14-continued"
#
# Usage: stem=$(entry_filename_from_heading "## 2026-02-06 (Session 6)")
# Output: "2026-02-06-s6"
entry_filename_from_heading() {
  local heading="$1"
  python3 -c "
import re, sys

heading = sys.argv[1]

# Strip leading ## and whitespace
text = heading.lstrip('#').strip()

# Extract date (YYYY-MM-DD)
date_match = re.match(r'(\d{4}-\d{2}-\d{2})', text)
if not date_match:
    # Fallback: slugify the whole heading
    slug = re.sub(r'[^a-z0-9]', '-', text.lower())
    slug = re.sub(r'-+', '-', slug).strip('-')
    print(slug[:60])
    sys.exit(0)

date = date_match.group(1)
rest = text[date_match.end():].strip()

if not rest:
    print(date)
    sys.exit(0)

# Parse parenthesized session info: (Session N) or (Session N, extra)
session_match = re.match(r'\(Session\s+(\d+)(?:,\s*(.+?))?\)', rest)
if session_match:
    session_num = session_match.group(1)
    extra = session_match.group(2)
    suffix = f'-s{session_num}'
    if extra:
        # Slugify the extra text (e.g., 'continued' → 'continued')
        extra_slug = re.sub(r'[^a-z0-9]', '-', extra.lower())
        extra_slug = re.sub(r'-+', '-', extra_slug).strip('-')
        if extra_slug:
            suffix += f'-{extra_slug}'
    print(f'{date}{suffix}')
else:
    # Non-session parenthetical — slugify the rest as suffix
    rest_slug = re.sub(r'[^a-z0-9]', '-', rest.lower())
    rest_slug = re.sub(r'-+', '-', rest_slug).strip('-')
    if rest_slug:
        print(f'{date}-{rest_slug}')
    else:
        print(date)
" "$heading"
}

# --- disambiguate_entry_filename ---
# Given a filename stem and a newline-separated list of already-used stems,
# append -2, -3, etc. if the stem is already taken.
#
# Usage:
#   USED_STEMS=""
#   stem=$(disambiguate_entry_filename "$stem" "$USED_STEMS")
#   USED_STEMS="${USED_STEMS}${stem}"$'\n'
#
# Output: the (possibly disambiguated) stem
disambiguate_entry_filename() {
  local stem="$1"
  local used="$2"
  local candidate="$stem"
  local counter=2

  while echo "$used" | grep -qxF "$candidate"; do
    candidate="${stem}-${counter}"
    counter=$((counter + 1))
  done

  echo "$candidate"
}

# --- heading_from_entry_filename ---
# Reconstruct a ## heading from an entry filename (or stem).
# Handles: "2026-02-06.md" or "2026-02-06" → "## 2026-02-06"
#          "2026-02-06-s6.md" → "## 2026-02-06 (Session 6)"
#          "2026-02-07-s14-continued.md" → "## 2026-02-07 (Session 14, continued)"
#
# Usage: heading=$(heading_from_entry_filename "2026-02-06-s6.md")
# Output: "## 2026-02-06 (Session 6)"
heading_from_entry_filename() {
  local filename="$1"
  python3 -c "
import re, sys

name = sys.argv[1]

# Strip .md extension if present
if name.endswith('.md'):
    name = name[:-3]

# Match date + optional session suffix
# Extra text must contain a letter (distinguishes from -N dedup suffix)
m = re.match(r'^(\d{4}-\d{2}-\d{2})(?:-s(\d+)(?:-((?=.*[a-z]).+))?)?(?:-\d+)?$', name)
if m:
    date = m.group(1)
    session = m.group(2)
    extra = m.group(3)
    if session:
        if extra:
            # Convert slug back to words (hyphens to spaces)
            extra_text = extra.replace('-', ' ')
            print(f'## {date} (Session {session}, {extra_text})')
        else:
            print(f'## {date} (Session {session})')
    else:
        print(f'## {date}')
else:
    # Fallback: use the filename as-is
    print(f'## {name}')
" "$filename"
}

# --- term_width ---
# Get the current terminal width in columns.
# Tries tput first, falls back to $COLUMNS or 100. Enforces a minimum of 100.
# Usage: width=$(term_width)
# Output: Integer column count (e.g., "120")
term_width() {
  local w
  w=$(tput cols 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$w" || "$w" -le 0 ]] 2>/dev/null; then
    w="${COLUMNS:-100}"
    w=$(echo "$w" | tr -d '[:space:]')
  fi
  if [[ "$w" -lt 100 ]] 2>/dev/null; then
    w=100
  fi
  echo "$w"
}

# --- draw_separator ---
# Draw a box-drawing separator line filling the terminal width.
# With a title:  "── Title ────────────...──"
# Without:       "──────────────────────...──"
# Usage: draw_separator "Section Title"
#        draw_separator   # no title
draw_separator() {
  local title="${1:-}"
  local width
  width=$(term_width)

  if [[ -z "$title" ]]; then
    # Full-width line
    printf '%*s\n' "$width" '' | tr ' ' '─'
  else
    local prefix="── "
    local suffix=" "
    local decorated="${prefix}${title}${suffix}"
    local decorated_len=${#decorated}
    local remaining=$((width - decorated_len))
    if [[ "$remaining" -lt 1 ]]; then
      remaining=1
    fi
    printf '%s' "$decorated"
    printf '%*s\n' "$remaining" '' | tr ' ' '─'
  fi
}

# --- render_table ---
# Render a formatted table to stdout with dynamic column widths.
# Reads pipe-delimited data rows from stdin and formats them according to a
# column specification string.
#
# Column spec format: "NAME:type:size:align|NAME:type:size:align|..."
#   type  — "flex" (proportional) or "fixed" (absolute)
#   size  — character width (fixed) or relative weight (flex)
#   align — "left" or "right"
#
# Flex columns share the remaining terminal width after fixed columns are
# allocated. Minimum flex column width is 10 characters. Values that exceed
# their column width are truncated with a ".." suffix.
#
# Usage: echo "val1|val2|val3" | render_table "COL1:flex:40:left|COL2:fixed:10:right|COL3:flex:60:left"
# Output:
#   COL1          COL2       COL3
#   ----------    ---------- ----------------
#   val1               val2 val3
render_table() {
  local spec="$1"
  local tw
  tw=$(term_width)

  # Parse column spec into parallel arrays
  local -a col_names col_types col_sizes col_aligns col_widths
  local IFS='|'
  local i=0
  for col_spec in $spec; do
    local saved_ifs="$IFS"
    IFS=':'
    local -a parts=($col_spec)
    IFS="$saved_ifs"
    col_names+=("${parts[0]}")
    col_types+=("${parts[1]}")
    col_sizes+=("${parts[2]}")
    col_aligns+=("${parts[3]}")
    i=$((i + 1))
  done
  local ncols=$i

  # Calculate fixed total and flex total weight
  local fixed_total=0
  local flex_weight_total=0
  for ((i = 0; i < ncols; i++)); do
    if [[ "${col_types[$i]}" == "fixed" ]]; then
      fixed_total=$((fixed_total + col_sizes[$i]))
    else
      flex_weight_total=$((flex_weight_total + col_sizes[$i]))
    fi
  done

  # Gaps between columns: (ncols - 1) single spaces
  local gaps=$((ncols - 1))
  # 2-char indent
  local indent=2
  local flex_space=$((tw - indent - fixed_total - gaps))
  if [[ "$flex_space" -lt 0 ]]; then
    flex_space=0
  fi

  # Assign widths
  for ((i = 0; i < ncols; i++)); do
    if [[ "${col_types[$i]}" == "fixed" ]]; then
      col_widths+=("${col_sizes[$i]}")
    else
      local w=10
      if [[ "$flex_weight_total" -gt 0 ]]; then
        w=$((flex_space * col_sizes[$i] / flex_weight_total))
      fi
      if [[ "$w" -lt 10 ]]; then
        w=10
      fi
      col_widths+=("$w")
    fi
  done

  # Build printf format string
  local fmt="  "  # 2-space indent
  for ((i = 0; i < ncols; i++)); do
    if [[ "$i" -gt 0 ]]; then
      fmt="${fmt} "
    fi
    if [[ "${col_aligns[$i]}" == "right" ]]; then
      fmt="${fmt}%${col_widths[$i]}s"
    else
      fmt="${fmt}%-${col_widths[$i]}s"
    fi
  done

  # Helper: truncate a value to a given width, appending ".." if needed
  _trunc() {
    local val="$1"
    local maxw="$2"
    if [[ "${#val}" -gt "$maxw" ]]; then
      if [[ "$maxw" -le 2 ]]; then
        echo "${val:0:$maxw}"
      else
        echo "${val:0:$((maxw - 2))}.."
      fi
    else
      echo "$val"
    fi
  }

  # Render header
  local -a hdr_vals
  for ((i = 0; i < ncols; i++)); do
    hdr_vals+=("$(_trunc "${col_names[$i]}" "${col_widths[$i]}")")
  done
  printf "${fmt}\n" "${hdr_vals[@]}"

  # Render separator
  local -a sep_vals
  for ((i = 0; i < ncols; i++)); do
    local dashes=""
    local w="${col_widths[$i]}"
    dashes=$(printf '%*s' "$w" '' | tr ' ' '-')
    sep_vals+=("$dashes")
  done
  printf "${fmt}\n" "${sep_vals[@]}"

  # Render data rows from stdin
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    local -a row_vals=()
    local saved_ifs="$IFS"
    IFS='|'
    local -a fields=($line)
    IFS="$saved_ifs"
    for ((i = 0; i < ncols; i++)); do
      local val="${fields[$i]:-}"
      row_vals+=("$(_trunc "$val" "${col_widths[$i]}")")
    done
    printf "${fmt}\n" "${row_vals[@]}"
  done
}

# --- remap_line_through_diff ---
# Map an old line number through a git diff to its new position.
# Usage: remap_line_through_diff <path> <line> <old_sha> <new_sha> [repo_dir]
# Output (stdout, single line):
#   anchored                  — line unchanged
#   shifted:<NEW_LINE>        — line moved, content semantically identical
#   renamed:<NEW_PATH>:<LINE> — file renamed, line tracked through rename
#   lost                      — line deleted or rewritten
# Exit 1 if diff cannot be computed (caller should bail).
remap_line_through_diff() {
  local file_path="$1"
  local target_line="$2"
  local old_sha="$3"
  local new_sha="$4"
  local repo_dir="${5:-.}"

  # Compute unified diff with rename detection
  local diff_output
  if ! diff_output=$(git -C "$repo_dir" diff -M "${old_sha}..${new_sha}" -- "$file_path" 2>/dev/null); then
    return 1
  fi

  # Empty diff: file is identical — line is anchored
  if [[ -z "$diff_output" ]]; then
    echo "anchored"
    return 0
  fi

  # Detect rename: path-filtered diff suppresses rename headers (git treats renamed-away file as
  # a pure deletion). Re-run without path filter when a rename from this path exists.
  local new_path=""
  local full_diff
  full_diff=$(git -C "$repo_dir" diff -M "${old_sha}..${new_sha}" 2>/dev/null) || true
  new_path=$(printf '%s\n' "$full_diff" | awk -v src="$file_path" '
    found_src { if (/^rename to /) { sub(/^rename to /, ""); print; exit } }
    /^rename from / { path = $0; sub(/^rename from /, "", path); if (path == src) found_src = 1 }
  ')

  # If renamed, use the rename-aware diff for hunk walking
  if [[ -n "$new_path" ]]; then
    diff_output=$(printf '%s\n' "$full_diff" | awk -v src="$file_path" -v dst="$new_path" '
      in_block { print }
      /^diff --git/ {
        in_block = 0
        # Check if this block is the rename of our file
        if ($0 ~ ("a/" src " b/" dst)) in_block = 1
      }
    ')
  fi

  # Walk the diff to determine outcome for target_line.
  #
  # Algorithm:
  #   - Track cumulative_delta = (new lines added) - (old lines deleted) across all hunks seen so far.
  #   - For each hunk header, if target_line < old_start → it's between/before hunks:
  #       new_line = target_line + cumulative_delta → anchored (or shifted if delta!=0, or renamed)
  #   - Inside a hunk body, walk line by line tracking old_pos / new_pos:
  #       ' ' context: advance both; if old_pos==target → anchored/renamed
  #       '-' deletion: if old_pos==target → save content for comparison; advance old_pos
  #       '+' addition: if we have a saved deletion at target → compare content:
  #                       same → shifted/renamed; different → lost
  #   - After processing all hunks, if not found → target is after last hunk:
  #       new_line = target_line + cumulative_delta → anchored/renamed
  local result
  result=$(printf '%s\n' "$diff_output" | awk \
    -v target="$target_line" \
    -v new_path="$new_path" \
    '
    BEGIN {
      found = 0
      outcome = ""
      in_hunk = 0
      old_pos = 0
      new_pos = 0
      cumulative_delta = 0
      # For deleted-line lookahead
      pending_delete = 0
      pending_delete_content = ""
      pending_new_pos = 0
    }

    /^@@ / {
      # Flush any pending delete that was not followed by "+"
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }

      # Parse: @@ -old_start[,old_count] +new_start[,new_count] @@
      # Portable BSD awk: extract numbers using sub/split on the header
      hdr = $0
      sub(/^@@ -/, "", hdr)
      split(hdr, a, " ")
      old_part = a[1]; sub(/,.*/, "", old_part); old_start = old_part + 0
      new_part = a[2]; sub(/^\+/, "", new_part); sub(/,.*/, "", new_part); new_start = new_part + 0

      # If target is before this hunk, it lives in the context between/before hunks
      if (target < old_start && !found) {
        # new_line = target + cumulative_delta (delta from all prior hunks)
        new_line = target + cumulative_delta
        if (new_path != "") {
          outcome = "renamed:" new_path ":" new_line
        } else if (new_line == target) {
          outcome = "anchored"
        } else {
          outcome = "shifted:" new_line
        }
        found = 1
      }

      # cumulative_delta from prior hunks: (new_start - old_start) reflects prior hunk edits
      # We update cumulative_delta AFTER we check the target relative to old_start,
      # but we need cumulative_delta to reflect all prior (already-finished) hunks.
      # Track it via old/new position advancement below; reset here to hunk start.
      old_pos = old_start
      new_pos = new_start
      in_hunk = 1
      next
    }

    in_hunk && /^([-+ ])/ {
      ch = substr($0, 1, 1)

      if (ch == "+") {
        # Addition line
        if (pending_delete && !found) {
          # Compare content of deleted line with this added line
          add_content = substr($0, 2)
          if (add_content == pending_delete_content) {
            # Same content — shifted (or renamed)
            if (new_path != "") {
              outcome = "renamed:" new_path ":" pending_new_pos
            } else {
              outcome = "shifted:" pending_new_pos
            }
          } else {
            outcome = "lost"
          }
          found = 1
          pending_delete = 0
        }
        cumulative_delta++
        new_pos++
        next
      }

      # For "-" or " " lines: flush any open pending_delete (deletion not followed by "+")
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }

      if (ch == " ") {
        # Context line: in both old and new
        if (old_pos == target && !found) {
          new_line = new_pos
          if (new_path != "") {
            outcome = "renamed:" new_path ":" new_line
          } else if (new_line == target) {
            outcome = "anchored"
          } else {
            outcome = "shifted:" new_line
          }
          found = 1
        }
        old_pos++
        new_pos++
      } else if (ch == "-") {
        # Deletion line: only in old
        if (old_pos == target && !found) {
          # Save for comparison with next "+" line
          pending_delete = 1
          pending_delete_content = substr($0, 2)
          pending_new_pos = new_pos
        }
        cumulative_delta--
        old_pos++
      }
      next
    }

    # Non-diff-body lines inside a hunk (e.g. "\ No newline at end of file")
    in_hunk && /^\\ / {
      next
    }

    # Any other line ends the hunk
    in_hunk {
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }
      in_hunk = 0
    }

    END {
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
      }
      if (!found) {
        # Target is after all hunks
        new_line = target + cumulative_delta
        if (new_path != "") {
          outcome = "renamed:" new_path ":" new_line
        } else if (new_line == target) {
          outcome = "anchored"
        } else {
          outcome = "shifted:" new_line
        }
      }
      print outcome
    }
  ')

  echo "$result"
}

# --- init_followups_dir ---
# Create $KNOWLEDGE_DIR/_followups/ if it does not already exist.
# Usage: init_followups_dir "$KNOWLEDGE_DIR"
# Args: $1 = knowledge directory path
# Returns 0 if created or already exists. Exits 1 if KNOWLEDGE_DIR does not exist.
init_followups_dir() {
  local knowledge_dir="$1"
  if [[ ! -d "$knowledge_dir" ]]; then
    echo "Error: knowledge store not found at: $knowledge_dir" >&2
    return 1
  fi
  local followups_dir="$knowledge_dir/_followups"
  if [[ ! -d "$followups_dir" ]]; then
    mkdir -p "$followups_dir"
  fi
}
