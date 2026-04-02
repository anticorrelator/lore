#!/usr/bin/env bash
# list-followups.sh — List follow-up artifacts with filtering
# Usage: bash list-followups.sh [--status <status>] [--json] [--attachment-type <type>] [--attachment-ref <ref>]
# --status:          pending|reviewed|promoted|dismissed|all (default: pending)
# --json:            output raw JSON from index
# --attachment-type: filter by attachment type (work|pr|issue|standalone)
# --attachment-ref:  filter by attachment ref value

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
INDEX="$KNOWLEDGE_DIR/_followup_index.json"

# Self-heal: regenerate index if missing
if [[ ! -f "$INDEX" ]] && [[ -d "$FOLLOWUPS_DIR" ]]; then
  "$SCRIPT_DIR/update-followup-index.sh" 2>/dev/null || true
fi

# Parse arguments
FILTER_STATUS="pending"
JSON_OUTPUT=false
FILTER_ATTACHMENT_TYPE=""
FILTER_ATTACHMENT_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)
      FILTER_STATUS="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --attachment-type)
      FILTER_ATTACHMENT_TYPE="$2"
      shift 2
      ;;
    --attachment-ref)
      FILTER_ATTACHMENT_REF="$2"
      shift 2
      ;;
    *)
      echo "[followup] Error: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Validate status filter
case "$FILTER_STATUS" in
  pending|reviewed|promoted|dismissed|all) ;;
  *)
    echo "[followup] Error: --status must be one of: pending, reviewed, promoted, dismissed, all" >&2
    exit 1
    ;;
esac

# No index and no directory — nothing to list
if [[ ! -f "$INDEX" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "[]"
  else
    draw_separator "Follow-Ups"
    echo ""
    echo "No follow-ups found."
    echo ""
    draw_separator
  fi
  exit 0
fi

# JSON output: filter and return matching items from index
if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, sys

with open('$INDEX') as f:
    data = json.load(f)

filter_status = '$FILTER_STATUS'
filter_att_type = '$FILTER_ATTACHMENT_TYPE'
filter_att_ref = '$FILTER_ATTACHMENT_REF'

# Collect items based on status filter
if filter_status == 'all':
    items = []
    for bucket in ('pending', 'reviewed', 'promoted', 'dismissed'):
        items.extend(data.get(bucket, []))
else:
    items = data.get(filter_status, [])

# Apply attachment filters
if filter_att_type or filter_att_ref:
    filtered = []
    for item in items:
        attachments = item.get('attachments', [])
        match = False
        for att in attachments:
            type_ok = (not filter_att_type) or att.get('type') == filter_att_type
            ref_ok = (not filter_att_ref) or att.get('ref') == filter_att_ref
            if type_ok and ref_ok:
                match = True
                break
        if match:
            filtered.append(item)
    items = filtered

print(json.dumps(items))
"
  exit 0
fi

# Human-readable output
NOW_EPOCH=$(date +%s)

relative_date() {
  local iso_date="$1"
  if [[ -z "$iso_date" ]]; then
    echo "unknown"
    return
  fi
  local epoch
  epoch=$(iso_to_epoch "$iso_date")
  if [[ "$epoch" -eq 0 ]]; then
    echo "unknown"
    return
  fi
  local days_ago=$(( (NOW_EPOCH - epoch) / 86400 ))
  if [[ $days_ago -eq 0 ]]; then
    echo "today"
  elif [[ $days_ago -eq 1 ]]; then
    echo "yesterday"
  else
    echo "${days_ago}d ago"
  fi
}

ITEMS=""
TOTAL_COUNT=0

python3 -c "
import json, sys

with open('$INDEX') as f:
    data = json.load(f)

filter_status = '$FILTER_STATUS'
filter_att_type = '$FILTER_ATTACHMENT_TYPE'
filter_att_ref = '$FILTER_ATTACHMENT_REF'

if filter_status == 'all':
    items = []
    for bucket in ('pending', 'reviewed', 'promoted', 'dismissed'):
        items.extend(data.get(bucket, []))
else:
    items = data.get(filter_status, [])

# Apply attachment filters
if filter_att_type or filter_att_ref:
    filtered = []
    for item in items:
        attachments = item.get('attachments', [])
        match = False
        for att in attachments:
            type_ok = (not filter_att_type) or att.get('type') == filter_att_type
            ref_ok = (not filter_att_ref) or att.get('ref') == filter_att_ref
            if type_ok and ref_ok:
                match = True
                break
        if match:
            filtered.append(item)
    items = filtered

for item in items:
    id_ = item.get('id', '')
    title = item.get('title', '')
    status = item.get('status', '')
    source = item.get('source', '')
    created = item.get('created', '')
    attachments = item.get('attachments', [])
    att_summary = ','.join(f\"{a.get('type','')}:{a.get('ref','')}\" for a in attachments) if attachments else ''
    # Pipe-delimited row: id|title|status|source|created|att_summary
    # Escape pipes in fields
    row = '|'.join([
        id_.replace('|',''),
        title.replace('|',''),
        status.replace('|',''),
        source.replace('|',''),
        created.replace('|',''),
        att_summary.replace('|',','),
    ])
    print(row)
" | while IFS='|' read -r id title status source created att_summary; do
    REL_DATE=$(relative_date "$created")
    echo "${id}|${title}|${status}|${source}|${REL_DATE}|${att_summary}"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
done > /tmp/lore_followups_rows_$$.txt

TOTAL_COUNT=$(wc -l < /tmp/lore_followups_rows_$$.txt | tr -d ' ')

draw_separator "Follow-Ups"
echo ""

if [[ "$TOTAL_COUNT" -eq 0 ]]; then
  if [[ "$FILTER_STATUS" == "pending" ]]; then
    echo "No pending follow-ups."
  else
    echo "No follow-ups with status: $FILTER_STATUS"
  fi
else
  COL_SPEC="ID:fixed:28:left|TITLE:flex:100:left|SOURCE:fixed:16:left|CREATED:fixed:10:left|ATTACHMENTS:fixed:20:left"
  cat /tmp/lore_followups_rows_$$.txt \
    | cut -d'|' -f1,2,4,5,6 \
    | render_table "$COL_SPEC"
fi

rm -f /tmp/lore_followups_rows_$$.txt

echo ""
echo "Shown: $TOTAL_COUNT"

echo ""
draw_separator
