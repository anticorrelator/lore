#!/usr/bin/env bash
# update-manifest.sh — Regenerate _manifest.json from knowledge files
# Usage: bash update-manifest.sh [directory]
# Scans all .md files, counts ### entries, extracts keywords, writes _manifest.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR"
  exit 1
fi

MANIFEST="$KNOWLEDGE_DIR/_manifest.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPO_NAME=$(basename "$KNOWLEDGE_DIR")

# Start JSON
echo '{' > "$MANIFEST"
echo "  \"version\": 1," >> "$MANIFEST"
echo "  \"repo\": \"$REPO_NAME\"," >> "$MANIFEST"
echo "  \"last_updated\": \"$TIMESTAMP\"," >> "$MANIFEST"
echo '  "files": [' >> "$MANIFEST"

FIRST=true

# Scan all .md files (excluding _inbox, _index, _meta)
while IFS= read -r -d '' file; do
  BASENAME=$(basename "$file")
  if [[ "$BASENAME" == "_inbox.md" || "$BASENAME" == "_index.md" || "$BASENAME" == "_meta.md" ]]; then
    continue
  fi

  RELPATH="${file#$KNOWLEDGE_DIR/}"

  # Count ### headings (entries)
  ENTRY_COUNT=$(grep -c '^### ' "$file" 2>/dev/null || true)
  ENTRY_COUNT="${ENTRY_COUNT:-0}"
  ENTRY_COUNT=$(echo "$ENTRY_COUNT" | tr -d '[:space:]')

  # Extract keywords from ### headings (lowercase, deduplicated)
  KEYWORDS=""
  if [[ "$ENTRY_COUNT" -gt 0 ]]; then
    # Extract heading text, split into words, lowercase, remove punctuation, deduplicate
    KEYWORD_LIST=$(grep '^### ' "$file" 2>/dev/null \
      | sed 's/^### //' \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cs '[:alnum:]-' '\n' \
      | sort -u \
      | grep -v '^$' \
      | head -30 \
      || true)

    # Format as JSON array
    if [[ -n "$KEYWORD_LIST" ]]; then
      KEYWORDS=$(echo "$KEYWORD_LIST" | while IFS= read -r kw; do echo "\"$kw\""; done | paste -sd ',' -)
    fi
  fi

  # Extract backlinks
  BACKLINKS=""
  BACKLINK_LIST=$(grep -o '\[\[[^]]*\]\]' "$file" 2>/dev/null \
    | sed 's/\[\[//;s/\]\]//' \
    | sed 's/|.*//' \
    | sort -u \
    || true)

  if [[ -n "$BACKLINK_LIST" ]]; then
    BACKLINKS=$(echo "$BACKLINK_LIST" | while IFS= read -r bl; do echo "\"$bl\""; done | paste -sd ',' -)
  fi

  # Add comma separator
  if [[ "$FIRST" == true ]]; then
    FIRST=false
  else
    echo '    ,' >> "$MANIFEST"
  fi

  # Write file entry
  cat >> "$MANIFEST" << ENTRY
    {
      "path": "$RELPATH",
      "entries": $ENTRY_COUNT,
      "keywords": [${KEYWORDS}],
      "backlinks": [${BACKLINKS}]
    }
ENTRY

done < <(find "$KNOWLEDGE_DIR" -name '*.md' -print0 2>/dev/null | sort -z)

echo '  ]' >> "$MANIFEST"
echo '}' >> "$MANIFEST"

echo "Manifest updated: $MANIFEST"
