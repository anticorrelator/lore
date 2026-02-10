#!/usr/bin/env bash
# update-thread-index.sh — Regenerate _threads/_index.json from thread metadata
# Usage: bash update-thread-index.sh [directory]
# v2: Scans _threads/<slug>/ directories and reads _meta.json
# v1 fallback: Scans _threads/*.md files and reads YAML frontmatter

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

THREADS_DIR="$KNOWLEDGE_DIR/_threads"

if [[ ! -d "$THREADS_DIR" ]]; then
  echo "No threads directory found at: $THREADS_DIR"
  exit 1
fi

INDEX="$THREADS_DIR/_index.json"
REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Detect format: v2 if any thread subdirectory with _meta.json exists
THREAD_FORMAT=1
for dir in "$THREADS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* || "$DIRNAME" == .* ]] && continue
  if [[ -f "${dir}_meta.json" ]]; then
    THREAD_FORMAT=2
    break
  fi
done

# Start JSON
echo '{' > "$INDEX"
echo "  \"version\": 1," >> "$INDEX"
echo "  \"thread_format_version\": $THREAD_FORMAT," >> "$INDEX"
echo "  \"repo\": \"$REPO_NAME\"," >> "$INDEX"
echo "  \"last_updated\": \"$TIMESTAMP\"," >> "$INDEX"
echo '  "threads": [' >> "$INDEX"

FIRST=true

if [[ $THREAD_FORMAT -ge 2 ]]; then
  # v2: scan thread directories with _meta.json
  for thread_dir in "$THREADS_DIR"/*/; do
    [[ -d "$thread_dir" ]] || continue
    DIRNAME=$(basename "$thread_dir")
    [[ "$DIRNAME" == _* || "$DIRNAME" == .* ]] && continue

    META_FILE="${thread_dir}_meta.json"
    [[ -f "$META_FILE" ]] || continue

    # Read fields from _meta.json (fall back to directory name for slug)
    SLUG=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('slug',''))" 2>/dev/null)
    [[ -z "$SLUG" ]] && SLUG="$DIRNAME"
    TOPIC=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('topic',''))" 2>/dev/null)
    TIER=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('tier','active'))" 2>/dev/null)
    UPDATED=$(python3 -c "import json; print(json.load(open('$META_FILE')).get('updated',''))" 2>/dev/null)

    # Auto-count sessions from .md entry files
    SESSIONS=0
    for entry_file in "$thread_dir"*.md; do
      [[ -f "$entry_file" ]] && SESSIONS=$((SESSIONS + 1))
    done

    [[ -z "$SLUG" ]] && continue
    [[ -z "$TOPIC" ]] && continue

    if [[ "$FIRST" == true ]]; then
      FIRST=false
    else
      echo '    ,' >> "$INDEX"
    fi

    cat >> "$INDEX" << ENTRY
    {
      "slug": "$SLUG",
      "topic": "$TOPIC",
      "tier": "$TIER",
      "updated": "$UPDATED",
      "sessions": $SESSIONS
    }
ENTRY
  done
else
  # v1 fallback: scan monolithic thread files
  for thread_file in "$THREADS_DIR"/*.md; do
    [[ -e "$thread_file" ]] || continue
    FILENAME=$(basename "$thread_file")

    TOPIC=$(awk '/^---$/ {count++; next} count == 1 && /^topic:/ {sub(/^topic:[[:space:]]*/, ""); print; exit}' "$thread_file")
    SLUG=$(awk '/^---$/ {count++; next} count == 1 && /^slug:/ {sub(/^slug:[[:space:]]*/, ""); print; exit}' "$thread_file")
    TIER=$(awk '/^---$/ {count++; next} count == 1 && /^tier:/ {sub(/^tier:[[:space:]]*/, ""); print; exit}' "$thread_file")
    UPDATED=$(awk '/^---$/ {count++; next} count == 1 && /^updated:/ {sub(/^updated:[[:space:]]*/, ""); print; exit}' "$thread_file")
    SESSIONS=$(grep -c '^## ' "$thread_file" 2>/dev/null || echo "0")

    [[ -z "$SLUG" ]] && continue
    [[ -z "$TOPIC" ]] && continue

    if [[ "$FIRST" == true ]]; then
      FIRST=false
    else
      echo '    ,' >> "$INDEX"
    fi

    cat >> "$INDEX" << ENTRY
    {
      "slug": "$SLUG",
      "topic": "$TOPIC",
      "tier": "$TIER",
      "updated": "$UPDATED",
      "sessions": $SESSIONS
    }
ENTRY
  done
fi

echo '  ]' >> "$INDEX"
echo '}' >> "$INDEX"

echo "Thread index updated: $INDEX"
