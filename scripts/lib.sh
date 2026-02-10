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
# Usage: slug=$(slugify "My Work Item Name")
# Output: "my-work-item-name"
slugify() {
  local input="$1"
  echo "$input" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-60
}

# --- resolve_knowledge_dir ---
# Resolve the knowledge store directory for the current project.
# Usage: KDIR=$(resolve_knowledge_dir)
resolve_knowledge_dir() {
  "$LORE_LIB_DIR/resolve-repo.sh"
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
      print buf
      collecting = 0
      next
    }
    collecting { buf = buf $0 }
  ' "$file"
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

# --- extract_context_signal ---
# Extract context signal from git branch + matched work item for FTS5 ranking.
# Combines branch name, work item title, and plan headings into a text signal.
# On main/master, falls back to most recently updated active work item.
# Usage: CONTEXT_SIGNAL=$(extract_context_signal "$KNOWLEDGE_DIR")
# Output: Space-separated signal terms (may be empty).
extract_context_signal() {
  local knowledge_dir="$1"
  local signal=""
  local branch
  branch=$(get_git_branch)

  if [[ -n "$branch" && "$branch" != "main" && "$branch" != "master" ]]; then
    # Branch name as initial signal (convert hyphens/underscores to spaces)
    signal=$(echo "$branch" | tr '_/-' ' ')

    # Try to match branch to a work item for a stronger signal
    local work_dir="$knowledge_dir/_work"
    if [[ -d "$work_dir" ]]; then
      local work_item_dir meta_file
      for work_item_dir in "$work_dir"/*/; do
        [[ -d "$work_item_dir" ]] || continue
        meta_file="${work_item_dir}_meta.json"
        [[ -f "$meta_file" ]] || continue

        if grep -q "\"$branch\"" "$meta_file" 2>/dev/null; then
          local work_title
          work_title=$(json_field "title" "$meta_file")
          if [[ -n "$work_title" ]]; then
            signal="${signal} ${work_title}"
          fi

          # Extract plan headings for strongest signal
          local plan_file="${work_item_dir}plan.md"
          if [[ -f "$plan_file" ]]; then
            local plan_headings
            plan_headings=$(grep '^### ' "$plan_file" 2>/dev/null | sed 's/^### //' | head -5 | tr '\n' ' ')
            if [[ -n "$plan_headings" ]]; then
              signal="${signal} ${plan_headings}"
            fi
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
        local work_title
        work_title=$(json_field "title" "${newest_dir}_meta.json")
        if [[ -n "$work_title" ]]; then
          signal="$work_title"
        fi

        local plan_file="${newest_dir}plan.md"
        if [[ -f "$plan_file" ]]; then
          local plan_headings
          plan_headings=$(grep '^### ' "$plan_file" 2>/dev/null | sed 's/^### //' | head -5 | tr '\n' ' ')
          if [[ -n "$plan_headings" ]]; then
            signal="${signal} ${plan_headings}"
          fi
        fi
      fi
    fi
  fi

  echo "$signal"
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
