#!/usr/bin/env bash
# capture.sh — Capture an insight to the knowledge store
# Usage: lore capture --insight "..." [--context "..."] [--category "..."] [--confidence "..."] [--related-files "..."] [--source "..."]
#
# Writes an individual entry file to the category directory (e.g., conventions/<slug>.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
INSIGHT=""
CONTEXT=""
CATEGORY=""
CONFIDENCE="high"
RELATED_FILES=""
SOURCE="manual"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --insight)
      INSIGHT="$2"
      shift 2
      ;;
    --context)
      CONTEXT="$2"
      shift 2
      ;;
    --category)
      CATEGORY="$2"
      shift 2
      ;;
    --confidence)
      CONFIDENCE="$2"
      shift 2
      ;;
    --related-files)
      RELATED_FILES="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: capture.sh --insight \"...\" [--context \"...\"] [--category \"...\"] [--confidence \"...\"] [--related-files \"...\"] [--source \"...\"]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INSIGHT" ]]; then
  die "--insight is required"
fi

# --- Resolve knowledge directory ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)

# --- Verify knowledge store exists ---
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  die "No knowledge store found at: $KNOWLEDGE_DIR. Run \`lore init\` to initialize one."
fi

# --- Default category ---
if [[ -z "$CATEGORY" ]]; then
  CATEGORY="conventions"
fi

# --- Generate title from first ~8 words of insight, title-cased ---
generate_title() {
  local text="$1"
  # Take first ~8 words, title-case each (macOS-compatible via awk)
  echo "$text" | awk '{for(i=1;i<=NF && i<=8;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; NF=(NF>8?8:NF); print}'
}

TITLE=$(generate_title "$INSIGHT")
SLUG=$(slugify "$TITLE")

# --- Determine target directory ---
DATE_TODAY=$(date +"%Y-%m-%d")

# Category maps directly to directory (e.g., conventions, domains/evaluators)
TARGET_DIR="$KNOWLEDGE_DIR/$CATEGORY"
mkdir -p "$TARGET_DIR"

# --- Build metadata comment ---
META="<!-- learned: $DATE_TODAY | confidence: $CONFIDENCE | source: $SOURCE"
if [[ -n "$RELATED_FILES" ]]; then
  META="$META | related_files: $RELATED_FILES"
fi
META="$META -->"

# --- Write individual entry file ---
TARGET_FILE="$TARGET_DIR/${SLUG}.md"

# Avoid overwriting existing entries
if [[ -f "$TARGET_FILE" ]]; then
  COUNTER=2
  while [[ -f "$TARGET_DIR/${SLUG}-${COUNTER}.md" ]]; do
    COUNTER=$((COUNTER + 1))
  done
  TARGET_FILE="$TARGET_DIR/${SLUG}-${COUNTER}.md"
fi

{
  echo "# $TITLE"
  echo "$INSIGHT"
  echo "$META"
} > "$TARGET_FILE"

RELPATH="${TARGET_FILE#$KNOWLEDGE_DIR/}"
echo "[capture] Filed to $RELPATH"

# --- Append to capture log ---
LOG_FILE="$KNOWLEDGE_DIR/_capture_log.csv"
if [[ ! -f "$LOG_FILE" ]]; then
  echo "timestamp,source,category,confidence" > "$LOG_FILE"
fi
echo "$(timestamp_iso),$SOURCE,$CATEGORY,$CONFIDENCE" >> "$LOG_FILE"

# --- Run manifest update ---
"$SCRIPT_DIR/update-manifest.sh" > /dev/null 2>&1 || true
