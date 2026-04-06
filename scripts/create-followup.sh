#!/usr/bin/env bash
# create-followup.sh — Create a new follow-up artifact in _followups/
# Usage: bash create-followup.sh --title <name> --source <agent>
#   [--attachments <json-array>] [--suggested-actions <json-array>]
#   [--proposed-comments <filepath>] [--content <body>] [--json]
# Creates $KNOWLEDGE_DIR/_followups/<id>/ with _meta.json and finding.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
TITLE=""
SOURCE=""
AUTHOR=""
ATTACHMENTS="[]"
SUGGESTED_ACTIONS="[]"
PROPOSED_COMMENTS=""
CONTENT=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --author)
      AUTHOR="$2"
      shift 2
      ;;
    --attachments)
      ATTACHMENTS="$2"
      shift 2
      ;;
    --suggested-actions)
      SUGGESTED_ACTIONS="$2"
      shift 2
      ;;
    --proposed-comments)
      PROPOSED_COMMENTS="$2"
      shift 2
      ;;
    --content)
      CONTENT="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: create-followup.sh --title <name> --source <agent> [--attachments <json>] [--suggested-actions <json>] [--proposed-comments <filepath>] [--content <body>] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TITLE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing --title"
  fi
  echo "[followup] Error: Missing --title." >&2
  exit 1
fi

if [[ -z "$SOURCE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing --source"
  fi
  echo "[followup] Error: Missing --source." >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"

# Initialize _followups/ if it doesn't exist
if [[ ! -d "$FOLLOWUPS_DIR" ]]; then
  mkdir -p "$FOLLOWUPS_DIR"
fi

# Generate timestamp-based unique ID
TIMESTAMP=$(timestamp_iso)
# Convert to filesystem-safe slug: 20260330T143000Z
TS_SLUG=$(echo "$TIMESTAMP" | tr -d ':-' | tr 'T' 't' | tr 'Z' 'z')
TITLE_SLUG=$(slugify "$TITLE" | cut -c1-40)
ID="${TS_SLUG}-${TITLE_SLUG}"

ITEM_DIR="$FOLLOWUPS_DIR/$ID"

if [[ -d "$ITEM_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up '$ID' already exists (timestamp collision)"
  fi
  echo "[followup] Error: Follow-up '$ID' already exists." >&2
  exit 1
fi

mkdir -p "$ITEM_DIR"

# Escape strings for JSON using python3
escape_json() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

TITLE_JSON=$(escape_json "$TITLE")
SOURCE_JSON=$(escape_json "$SOURCE")
AUTHOR_JSON=$(escape_json "$AUTHOR")

# Write _meta.json
cat > "$ITEM_DIR/_meta.json" << METAEOF
{
  "id": "$ID",
  "title": $TITLE_JSON,
  "source": $SOURCE_JSON,
  "author": $AUTHOR_JSON,
  "status": "open",
  "attachments": $ATTACHMENTS,
  "suggested_actions": $SUGGESTED_ACTIONS,
  "created": "$TIMESTAMP",
  "updated": "$TIMESTAMP"
}
METAEOF

# Write finding.md
if [[ -n "$CONTENT" ]]; then
  cat > "$ITEM_DIR/finding.md" << FINDINGEOF
# $TITLE

$CONTENT
FINDINGEOF
else
  cat > "$ITEM_DIR/finding.md" << FINDINGEOF
# $TITLE

<!-- Add finding details here. -->
FINDINGEOF
fi

# Write proposed-comments.json sidecar (accepts filepath or inline JSON)
if [[ -n "$PROPOSED_COMMENTS" ]]; then
  if [[ -f "$PROPOSED_COMMENTS" ]]; then
    # It's a file path — copy it
    cp "$PROPOSED_COMMENTS" "$ITEM_DIR/proposed-comments.json"
  elif printf '%s' "$PROPOSED_COMMENTS" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    # It's inline JSON — write it directly
    printf '%s\n' "$PROPOSED_COMMENTS" > "$ITEM_DIR/proposed-comments.json"
  else
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "Proposed comments: not a valid file path or JSON"
    fi
    echo "[followup] Error: --proposed-comments is neither a valid file path nor valid JSON" >&2
    exit 1
  fi
fi

# Update the followup index
if [[ -x "$SCRIPT_DIR/update-followup-index.sh" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    bash "$SCRIPT_DIR/update-followup-index.sh" > /dev/null 2>&1 || true
    json_output "$(cat "$ITEM_DIR/_meta.json")"
  fi
  bash "$SCRIPT_DIR/update-followup-index.sh"
else
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(cat "$ITEM_DIR/_meta.json")"
  fi
fi

echo "Created follow-up '$TITLE' at $ITEM_DIR"
