#!/usr/bin/env bash
# delete-followup.sh — Permanently delete a follow-up by ID
# Usage: bash delete-followup.sh --followup-id <id> [--json]
# Removes the follow-up directory and rebuilds the index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FOLLOWUP_ID=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --followup-id)
      FOLLOWUP_ID="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: delete-followup.sh --followup-id <id> [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FOLLOWUP_ID" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required flag: --followup-id"
  fi
  echo "[followup] Error: Missing required flag: --followup-id" >&2
  echo "Usage: delete-followup.sh --followup-id <id> [--json]" >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
FOLLOWUP_DIR="$FOLLOWUPS_DIR/$FOLLOWUP_ID"

if [[ ! -d "$FOLLOWUP_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up not found: $FOLLOWUP_ID"
  fi
  echo "[followup] Error: Follow-up not found: $FOLLOWUP_ID" >&2
  exit 1
fi

# Get title before deletion (for output)
TITLE=""
META_FILE="$FOLLOWUP_DIR/_meta.json"
if [[ -f "$META_FILE" ]]; then
  TITLE=$(json_field "title" "$META_FILE")
fi

# --- Delete the directory ---
rm -rf "$FOLLOWUP_DIR"

# --- Rebuild index ---
"$SCRIPT_DIR/update-followup-index.sh" >/dev/null 2>/dev/null || true

# --- Output ---
if [[ $JSON_MODE -eq 1 ]]; then
  python3 -c "
import json, sys
print(json.dumps({
    'followup_id': sys.argv[1],
    'deleted': True
}))
" "$FOLLOWUP_ID"
  exit 0
fi

echo "[followup] Deleted: $FOLLOWUP_ID${TITLE:+ ($TITLE)}"
