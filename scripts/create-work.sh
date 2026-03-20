#!/usr/bin/env bash
# create-work.sh — Create a new work item in _work/
# Usage: bash create-work.sh <name> [directory]
#        bash create-work.sh --title <name> [--slug <slug>] [--description <text>] [--directory <path>] [--issue <ref>] [--pr <ref>]
# Creates _work/<slug>/ with _meta.json and notes.md, then updates the index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments (flags or positional) ---
NAME=""
SLUG_OVERRIDE=""
DESCRIPTION=""
TARGET_DIR=""
ISSUE=""
PR=""
TAGS=""
JSON_MODE=0
DETECT_PR=0

if [[ $# -ge 1 && "$1" == --* ]]; then
  # Flag mode
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        NAME="$2"
        shift 2
        ;;
      --slug)
        SLUG_OVERRIDE="$2"
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
      --json)
        JSON_MODE=1
        shift
        ;;
      --detect-pr)
        DETECT_PR=1
        shift
        ;;
      *)
        echo "[work] Error: Unknown flag '$1'" >&2
        echo "Usage: create-work.sh --title <name> [--slug <slug>] [--description <text>] [--directory <path>] [--issue <ref>] [--pr <ref>] [--tags <tag1,tag2>] [--json] [--detect-pr]" >&2
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
      --json)
        JSON_MODE=1
        shift
        ;;
      --detect-pr)
        DETECT_PR=1
        shift
        ;;
      --*)
        echo "[work] Error: Unknown flag '$1'. Use --title flag mode for multiple options." >&2
        echo "Usage: create-work.sh <name> [directory] [--tags <tag1,tag2>] [--json] [--detect-pr]" >&2
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
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing work item name"
  fi
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

# Slugify the name (or use explicit --slug override)
if [[ -n "$SLUG_OVERRIDE" ]]; then
  SLUG=$(slugify "$SLUG_OVERRIDE")
else
  SLUG=$(slugify "$NAME")
fi

if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Name '$NAME' produced an empty slug"
  fi
  echo "[work] Error: Name '$NAME' produced an empty slug." >&2
  exit 1
fi

# Check for duplicate (exact match)
if [[ -d "$WORK_DIR/$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Work item '$SLUG' already exists"
  fi
  echo "[work] Error: Work item '$SLUG' already exists at $WORK_DIR/$SLUG" >&2
  exit 1
fi

# Check for similar slugs (substring overlap in either direction)
SIMILAR=()
for existing_dir in "$WORK_DIR"/*/; do
  [[ ! -d "$existing_dir" ]] && continue
  existing_slug=$(basename "$existing_dir")
  [[ "$existing_slug" == _* ]] && continue  # skip _archive, _index, etc.
  # Check if new slug contains existing slug or vice versa
  if [[ "$SLUG" == *"$existing_slug"* || "$existing_slug" == *"$SLUG"* ]]; then
    existing_title=$(python3 -c "import json; print(json.load(open('$existing_dir/_meta.json'))['title'])" 2>/dev/null || echo "$existing_slug")
    SIMILAR+=("$existing_slug ($existing_title)")
  fi
done

if [[ ${#SIMILAR[@]} -gt 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    # In JSON mode, emit a warning field but still block creation
    json_error "Similar work item(s) already exist: ${SIMILAR[*]}"
  fi
  echo "[work] Warning: Similar work item(s) already exist:" >&2
  for s in "${SIMILAR[@]}"; do
    echo "  - $s" >&2
  done
  echo "[work] Error: Refusing to create '$SLUG' — use a distinct name or work with the existing item." >&2
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

# --- Auto-detect PR from branch ---
# Only run if --detect-pr is active, no explicit --pr was given, and we have a branch
if [[ $DETECT_PR -eq 1 && -z "$PR" && -n "$BRANCH" ]]; then
  if command -v gh &>/dev/null; then
    DETECTED_PR=$(gh pr list --head "$BRANCH" --json number --limit 1 2>/dev/null \
      | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['number'] if data else '')" 2>/dev/null) || true
    if [[ -n "$DETECTED_PR" ]]; then
      # Update pr field in _meta.json
      META_FILE="$WORK_DIR/$SLUG/_meta.json"
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"pr\": \"$DETECTED_PR\"/" "$META_FILE"
      else
        sed -i "s/\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"pr\": \"$DETECTED_PR\"/" "$META_FILE"
      fi
    fi
  fi
fi

# Update the work index
if [[ $JSON_MODE -eq 1 ]]; then
  bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR" > /dev/null 2>&1 || true
  json_output "$(cat "$WORK_DIR/$SLUG/_meta.json")"
fi

bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR"

echo "Created work item '$TITLE' at $WORK_DIR/$SLUG"
