#!/usr/bin/env bash
# generate-index.sh — Dynamically walk category directories and output a knowledge index
# Usage: bash generate-index.sh [directory] [--category <name>]
# Replaces static _index.md with on-demand directory walking.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TARGET_DIR=""
FILTER_CATEGORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category)
      FILTER_CATEGORY="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: lore index [--category <name>]" >&2
      echo "  Walks category directories and prints entry titles + summaries." >&2
      echo "  --category <name>  Show only entries in this category" >&2
      exit 0
      ;;
    *)
      TARGET_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="$(pwd)"
fi

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

# Category directories in priority order
CATEGORIES=(principles workflows conventions architecture gotchas abstractions domains team)

for category in "${CATEGORIES[@]}"; do
  # Apply category filter if specified
  if [[ -n "$FILTER_CATEGORY" && "$category" != "$FILTER_CATEGORY" ]]; then
    continue
  fi

  cat_dir="$KNOWLEDGE_DIR/$category"
  if [[ ! -d "$cat_dir" ]]; then
    continue
  fi

  # Count entries
  entry_count=0
  for f in "$cat_dir"/*.md; do
    [[ -f "$f" ]] && entry_count=$((entry_count + 1))
  done

  if [[ "$entry_count" -eq 0 ]]; then
    continue
  fi

  echo "## $category ($entry_count entries)"
  echo ""

  for filepath in "$cat_dir"/*.md; do
    [[ -f "$filepath" ]] || continue

    fname=$(basename "$filepath")

    # Extract title from H1 heading, fallback to filename
    title=$(head -1 "$filepath" | sed 's/^# //')
    if [[ -z "$title" || "$title" == "$(head -1 "$filepath")" ]]; then
      # No H1 found, use filename as title
      title="${fname%.md}"
    fi

    # Extract first-line summary (first non-empty line after H1)
    summary=$(awk 'NR==1{next} /^[[:space:]]*$/{next} /^<!--/{next} /^See also:/{next} {print; exit}' "$filepath")

    # Truncate summary to 120 chars
    if [[ ${#summary} -gt 120 ]]; then
      summary="${summary:0:117}..."
    fi

    if [[ -n "$summary" ]]; then
      echo "- **$title** — $summary"
    else
      echo "- **$title**"
    fi
  done

  echo ""
done
