#!/usr/bin/env bash
# create-work.sh — Create a new work item in _work/
# Usage: bash create-work.sh <name> [directory]
#        bash create-work.sh --title <name> [--description <text>] [--directory <path>] [--issue <ref>] [--pr <ref>]
# Creates _work/<slug>/ with _meta.json and notes.md, then updates the index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments (flags or positional) ---
NAME=""
DESCRIPTION=""
TARGET_DIR=""
ISSUE=""
PR=""
TAGS=""

if [[ $# -ge 1 && "$1" == --* ]]; then
  # Flag mode
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        NAME="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --directory)
        TARGET_DIR="$2"
        shift 2
        ;;
      --issue)
        ISSUE="$2"
        shift 2
        ;;
      --pr)
        PR="$2"
        shift 2
        ;;
      --tags)
        TAGS="$2"
        shift 2
        ;;
      *)
        echo "[work] Error: Unknown flag '$1'" >&2
        echo "Usage: create-work.sh --title <name> [--description <text>] [--directory <path>] [--issue <ref>] [--pr <ref>] [--tags <tag1,tag2>]" >&2
        exit 1
        ;;
    esac
  done
else
  # Positional mode: NAME is first arg, then optional directory, then optional flags
  NAME="${1:-}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tags)
        TAGS="$2"
        shift 2
        ;;
      --*)
        echo "[work] Error: Unknown flag '$1'. Use --title flag mode for multiple options." >&2
        echo "Usage: create-work.sh <name> [directory] [--tags <tag1,tag2>]" >&2
        exit 1
        ;;
      *)
        TARGET_DIR="$1"
        shift
        ;;
    esac
  done
fi

TARGET_DIR="${TARGET_DIR:-$(pwd)}"

if [[ -z "$NAME" ]]; then
  echo "[work] Error: Missing work item name." >&2
  echo "Usage: create-work.sh <name> [directory]" >&2
  echo "       create-work.sh --title <name> [--description <text>] [--directory <path>] [--issue <ref>] [--pr <ref>]" >&2
  exit 1
fi
KNOWLEDGE_DIR=$(resolve_knowledge_dir)

WORK_DIR="$KNOWLEDGE_DIR/_work"

# Initialize _work/ if it doesn't exist
if [[ ! -d "$WORK_DIR" ]]; then
  bash "$SCRIPT_DIR/init-work.sh" "$TARGET_DIR"
fi

# Slugify the name
SLUG=$(slugify "$NAME")

if [[ -z "$SLUG" ]]; then
  echo "[work] Error: Name '$NAME' produced an empty slug." >&2
  exit 1
fi

# Check for duplicate
if [[ -d "$WORK_DIR/$SLUG" ]]; then
  echo "[work] Error: Work item '$SLUG' already exists at $WORK_DIR/$SLUG" >&2
  exit 1
fi

# Get current git branch (may be empty if not in a git repo)
BRANCH=$(get_git_branch)

# Build branches JSON array
if [[ -n "$BRANCH" ]]; then
  BRANCHES_JSON="[\"$BRANCH\"]"
else
  BRANCHES_JSON="[]"
fi

# Title case: capitalize first letter of each word
TITLE=$(echo "$NAME" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

TIMESTAMP=$(timestamp_iso)

# Build tags JSON array from comma-separated string
TAGS_JSON="[]"
if [[ -n "$TAGS" ]]; then
  TAGS_JSON="["
  first=true
  IFS=',' read -ra TAG_ARRAY <<< "$TAGS"
  for tag in "${TAG_ARRAY[@]}"; do
    tag="${tag## }"
    tag="${tag%% }"
    [[ -z "$tag" ]] && continue
    [[ "$first" == true ]] && first=false || TAGS_JSON+=","
    TAGS_JSON+="\"$tag\""
  done
  TAGS_JSON+="]"
fi

# Create the work item directory
mkdir -p "$WORK_DIR/$SLUG"

# Write _meta.json
cat > "$WORK_DIR/$SLUG/_meta.json" << METAEOF
{
  "slug": "$SLUG",
  "title": "$TITLE",
  "status": "active",
  "branches": $BRANCHES_JSON,
  "tags": $TAGS_JSON,
  "issue": "$ISSUE",
  "pr": "$PR",
  "created": "$TIMESTAMP",
  "updated": "$TIMESTAMP",
  "related_knowledge": []
}
METAEOF

# Write notes.md
if [[ -n "$DESCRIPTION" ]]; then
cat > "$WORK_DIR/$SLUG/notes.md" << NOTESEOF
# Session Notes: $TITLE

<!-- Append session entries below. Each entry records what happened in a session. -->

## $(date -u +%Y-%m-%dT%H:%M)
**Focus:** Initial scoping
$DESCRIPTION
NOTESEOF
else
cat > "$WORK_DIR/$SLUG/notes.md" << NOTESEOF
# Session Notes: $TITLE

<!-- Append session entries below. Each entry records what happened in a session. -->
NOTESEOF
fi

# Update the work index
bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR"

echo "Created work item '$TITLE' at $WORK_DIR/$SLUG"
