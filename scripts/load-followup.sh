#!/usr/bin/env bash
# load-followup.sh — Load a single follow-up's full context
# Usage: bash load-followup.sh <id> [--json]
# Output: Structured dump of _meta.json fields and finding.md content.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=false
ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    *)
      if [[ -z "$ID" ]]; then
        ID="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$ID" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Missing required argument: id"
  fi
  echo "[followup] Error: Missing required argument: id" >&2
  echo "Usage: bash load-followup.sh [--json] <id>" >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir) || {
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Could not resolve knowledge directory"
  fi
  echo "[followup] Error: Could not resolve knowledge directory" >&2
  exit 1
}

FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
ITEM_DIR="$FOLLOWUPS_DIR/$ID"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Follow-up not found: $ID"
  fi
  echo "[followup] Error: Follow-up not found: $ID" >&2
  exit 1
fi

META="$ITEM_DIR/_meta.json"

if [[ ! -f "$META" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No _meta.json found for: $ID"
  fi
  echo "[followup] Error: No _meta.json found for: $ID" >&2
  exit 1
fi

# --- JSON output mode ---
if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, os, sys

item_dir = sys.argv[1]
followup_id = sys.argv[2]
meta_file = os.path.join(item_dir, '_meta.json')

with open(meta_file) as f:
    meta = json.load(f)

def read_file(path):
    if os.path.isfile(path):
        with open(path) as f:
            return f.read()
    return None

finding_path = os.path.join(item_dir, 'finding.md')

result = {
    'id': followup_id,
    'title': meta.get('title', ''),
    'source': meta.get('source', ''),
    'severity': meta.get('severity', ''),
    'status': meta.get('status', ''),
    'attachments': meta.get('attachments', []),
    'suggested_actions': meta.get('suggested_actions', []),
    'created': meta.get('created', ''),
    'updated': meta.get('updated', ''),
    'finding_content': read_file(finding_path),
}

print(json.dumps(result))
" "$ITEM_DIR" "$ID"
  exit 0
fi

# --- Extract metadata fields ---
TITLE=$(json_field "title" "$META")
SOURCE=$(json_field "source" "$META")
SEVERITY=$(json_field "severity" "$META")
STATUS=$(json_field "status" "$META")
CREATED=$(json_field "created" "$META")
UPDATED=$(json_field "updated" "$META")

# --- Output structured metadata ---
draw_separator "Follow-up: $TITLE"
echo "ID: $ID"
echo "Source: $SOURCE"
echo "Severity: $SEVERITY"
echo "Status: $STATUS"
echo "Created: $CREATED"
echo "Updated: $UPDATED"
echo ""

# --- Attachments ---
ATTACHMENTS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    meta = json.load(f)
attachments = meta.get('attachments', [])
if attachments:
    for a in attachments:
        print(f\"  {a.get('type','?')}: {a.get('ref','?')}\")
" "$META" 2>/dev/null || true)

if [[ -n "$ATTACHMENTS" ]]; then
  echo "Attachments:"
  echo "$ATTACHMENTS"
  echo ""
fi

# --- Suggested actions ---
SUGGESTED=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    meta = json.load(f)
actions = meta.get('suggested_actions', [])
if actions:
    for a in actions:
        atype = a.get('type','?')
        rest = {k: v for k, v in a.items() if k != 'type'}
        if rest:
            print(f\"  {atype}: {rest}\")
        else:
            print(f\"  {atype}\")
" "$META" 2>/dev/null || true)

if [[ -n "$SUGGESTED" ]]; then
  echo "Suggested actions:"
  echo "$SUGGESTED"
  echo ""
fi

# --- Finding document ---
FINDING_FILE="$ITEM_DIR/finding.md"
draw_separator "Finding"
if [[ -f "$FINDING_FILE" ]]; then
  cat "$FINDING_FILE"
else
  echo "(no finding content)"
fi
echo ""
draw_separator
echo ""
