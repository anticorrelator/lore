#!/usr/bin/env bash
# update-thread-index.sh — Regenerate _threads/_index.json from thread YAML frontmatter
# Usage: bash update-thread-index.sh [directory]
# Scans all _threads/*.md files and rebuilds the index

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

# Start JSON
echo '{' > "$INDEX"
echo "  \"version\": 1," >> "$INDEX"
echo "  \"repo\": \"$REPO_NAME\"," >> "$INDEX"
echo "  \"last_updated\": \"$TIMESTAMP\"," >> "$INDEX"
echo '  "threads": [' >> "$INDEX"

FIRST=true

# Scan thread files (exclude _index.json)
for thread_file in "$THREADS_DIR"/*.md; do
  # Handle no matches
  [[ -e "$thread_file" ]] || continue

  FILENAME=$(basename "$thread_file")

  # Extract YAML frontmatter fields using awk
  # Frontmatter is between first and second '---' lines
  TOPIC=$(awk '/^---$/ {count++; next} count == 1 && /^topic:/ {sub(/^topic:[[:space:]]*/, ""); print; exit}' "$thread_file")
  SLUG=$(awk '/^---$/ {count++; next} count == 1 && /^slug:/ {sub(/^slug:[[:space:]]*/, ""); print; exit}' "$thread_file")
  TIER=$(awk '/^---$/ {count++; next} count == 1 && /^tier:/ {sub(/^tier:[[:space:]]*/, ""); print; exit}' "$thread_file")
  CREATED=$(awk '/^---$/ {count++; next} count == 1 && /^created:/ {sub(/^created:[[:space:]]*/, ""); print; exit}' "$thread_file")
  UPDATED=$(awk '/^---$/ {count++; next} count == 1 && /^updated:/ {sub(/^updated:[[:space:]]*/, ""); print; exit}' "$thread_file")
  SESSIONS=$(awk '/^---$/ {count++; next} count == 1 && /^sessions:/ {sub(/^sessions:[[:space:]]*/, ""); print; exit}' "$thread_file")

  # Skip if missing required fields
  [[ -z "$SLUG" ]] && continue
  [[ -z "$TOPIC" ]] && continue

  # Add comma separator
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

echo '  ]' >> "$INDEX"
echo '}' >> "$INDEX"

echo "Thread index updated: $INDEX"
