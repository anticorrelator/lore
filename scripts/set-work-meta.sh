#!/usr/bin/env bash
# set-work-meta.sh — Set metadata fields on an existing work item
# Usage: bash set-work-meta.sh <slug> [--issue <value>] [--pr <value>]
# Updates the specified fields in _meta.json, touches the timestamp, and rebuilds the index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
SLUG=""
ISSUE=""
PR=""
HAS_ISSUE=0
HAS_PR=0

if [[ $# -lt 1 ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>]" >&2
  exit 1
fi

SLUG="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      ISSUE="$2"
      HAS_ISSUE=1
      shift 2
      ;;
    --pr)
      PR="$2"
      HAS_PR=1
      shift 2
      ;;
    *)
      echo "[work] Error: Unknown flag '$1'" >&2
      echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>]" >&2
      exit 1
      ;;
  esac
done

if [[ "$HAS_ISSUE" -eq 0 && "$HAS_PR" -eq 0 ]]; then
  echo "[work] Error: No fields to set. Provide --issue and/or --pr." >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

ITEM_DIR="$WORK_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  echo "[work] Error: Work item not found: $SLUG" >&2
  echo "Available items:" >&2
  for d in "$WORK_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" == "_archive" ]] && continue
    echo "  $name" >&2
  done
  exit 1
fi

META_FILE="$ITEM_DIR/_meta.json"

if [[ ! -f "$META_FILE" ]]; then
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# --- Update fields ---
CHANGES=()

if [[ "$HAS_ISSUE" -eq 1 ]]; then
  if grep -q '"issue"' "$META_FILE" 2>/dev/null; then
    sed -i '' "s/\"issue\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"issue\": \"$ISSUE\"/" "$META_FILE"
  else
    # Insert before "created" line
    sed -i '' "s/\"created\"[[:space:]]*:/\"issue\": \"$ISSUE\",\n  \"created\":/" "$META_FILE"
  fi
  CHANGES+=("issue=$ISSUE")
fi

if [[ "$HAS_PR" -eq 1 ]]; then
  if grep -q '"pr"' "$META_FILE" 2>/dev/null; then
    sed -i '' "s/\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"pr\": \"$PR\"/" "$META_FILE"
  else
    # Insert before "created" line
    sed -i '' "s/\"created\"[[:space:]]*:/\"pr\": \"$PR\",\n  \"created\":/" "$META_FILE"
  fi
  CHANGES+=("pr=$PR")
fi

# --- Update timestamp and rebuild index ---
update_meta_timestamp "$ITEM_DIR"
"$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true

TITLE=$(json_field "title" "$META_FILE")
echo "[work] Updated $SLUG ($TITLE): ${CHANGES[*]}"
