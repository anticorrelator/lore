#!/usr/bin/env bash
# status.sh — Quick knowledge store health summary
# Reads _meta/ files (retrieval-log.jsonl, renormalize-flags.json, staleness/usage reports)
# and _manifest.json to give a snapshot of store health.
#
# Usage: bash status.sh [knowledge_dir] [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=0
KDIR=""

for arg in "$@"; do
  case "$arg" in
    --json) JSON_OUTPUT=1 ;;
    --help|-h)
      echo "Usage: lore status [--json]" >&2
      echo "  Show a quick knowledge store health summary." >&2
      echo "  Reads _meta/ logs and _manifest.json for status indicators." >&2
      exit 0
      ;;
    *)
      if [[ -z "$KDIR" ]]; then
        KDIR="$arg"
      fi
      ;;
  esac
done

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  echo "Error: knowledge directory not found: $KDIR" >&2
  exit 1
fi

META_DIR="$KDIR/_meta"

# --- Entry count from manifest ---
ENTRY_COUNT=0
FORMAT_VERSION=0
if [[ -f "$KDIR/_manifest.json" ]]; then
  # Sum entry_count values from manifest categories
  ENTRY_COUNT=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
fmt = m.get('format_version', 1)
total = sum(c.get('entry_count', 0) for c in m.get('categories', {}).values())
print(f'{fmt} {total}')
" "$KDIR/_manifest.json" 2>/dev/null || echo "0 0")
  FORMAT_VERSION=$(echo "$ENTRY_COUNT" | cut -d' ' -f1)
  ENTRY_COUNT=$(echo "$ENTRY_COUNT" | cut -d' ' -f2)
fi

# --- Category count ---
CATEGORY_COUNT=0
for dir in "$KDIR"/*/; do
  [[ -d "$dir" ]] || continue
  DIRNAME=$(basename "$dir")
  [[ "$DIRNAME" == _* ]] && continue
  CATEGORY_COUNT=$((CATEGORY_COUNT + 1))
done

# --- Budget utilization from retrieval log ---
BUDGET_USED=0
BUDGET_TOTAL=0
RETRIEVAL_SESSIONS=0
LAST_RETRIEVAL=""
if [[ -f "$META_DIR/retrieval-log.jsonl" ]]; then
  # Read last line for most recent session data
  LAST_LINE=$(tail -1 "$META_DIR/retrieval-log.jsonl" 2>/dev/null || echo "")
  if [[ -n "$LAST_LINE" ]]; then
    eval "$(python3 -c "
import json, sys
line = sys.argv[1]
d = json.loads(line)
print(f'BUDGET_USED={d.get(\"budget_used\", 0)}')
print(f'BUDGET_TOTAL={d.get(\"budget_total\", 0)}')
print(f'LAST_RETRIEVAL=\"{d.get(\"timestamp\", \"\")}\"')
" "$LAST_LINE" 2>/dev/null || echo "")"
    RETRIEVAL_SESSIONS=$(wc -l < "$META_DIR/retrieval-log.jsonl" | tr -d '[:space:]')
  fi
fi

BUDGET_PCT=0
if [[ "$BUDGET_TOTAL" -gt 0 ]]; then
  BUDGET_PCT=$(python3 -c "print(round($BUDGET_USED / $BUDGET_TOTAL * 100, 1))")
fi

# --- Staleness indicators ---
STALE_COUNT=0
AGING_COUNT=0
FRESH_COUNT=0
STALENESS_SCAN_TIME=""
if [[ -f "$META_DIR/staleness-report.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
counts = r.get('counts', {})
print(f'STALE_COUNT={counts.get(\"stale\", 0)}')
print(f'AGING_COUNT={counts.get(\"aging\", 0)}')
print(f'FRESH_COUNT={counts.get(\"fresh\", 0)}')
print(f'STALENESS_SCAN_TIME=\"{r.get(\"scan_time\", \"\")}\"')
" "$META_DIR/staleness-report.json" 2>/dev/null || echo "")"
fi

# --- Usage analysis indicators ---
COLD_ENTRIES=0
USAGE_SCAN_TIME=""
if [[ -f "$META_DIR/usage-report.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
s = r.get('summary', {})
print(f'COLD_ENTRIES={s.get(\"cold_entry_count\", 0)}')
print(f'USAGE_SCAN_TIME=\"{r.get(\"generated_at\", \"\")}\"')
" "$META_DIR/usage-report.json" 2>/dev/null || echo "")"
fi

# --- Renormalize flags ---
RENORM_FLAG_COUNT=0
LAST_RENORMALIZE=""
if [[ -f "$META_DIR/renormalize-flags.json" ]]; then
  eval "$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
# Count flags across all categories (oversized_categories, stale_related_files, zero_access_entries)
total = (len(r.get('oversized_categories', []))
    + len(r.get('stale_related_files', []))
    + len(r.get('zero_access_entries', [])))
print(f'RENORM_FLAG_COUNT={total}')
print(f'LAST_RENORMALIZE=\"{r.get(\"last_renormalize\", \"never\")}\"')
" "$META_DIR/renormalize-flags.json" 2>/dev/null || echo "")"
fi

# --- Inbox count ---
INBOX_COUNT=0
if [[ -d "$KDIR/_inbox" ]]; then
  INBOX_COUNT=$(find "$KDIR/_inbox" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
fi

# --- JSON output ---
if [[ "$JSON_OUTPUT" -eq 1 ]]; then
  python3 -c "
import json
data = {
    'knowledge_dir': '$KDIR',
    'format_version': $FORMAT_VERSION,
    'entries': {
        'total': $ENTRY_COUNT,
        'categories': $CATEGORY_COUNT,
        'inbox_pending': $INBOX_COUNT,
    },
    'budget': {
        'used': $BUDGET_USED,
        'total': $BUDGET_TOTAL,
        'utilization_pct': $BUDGET_PCT,
    },
    'retrieval': {
        'total_sessions': $RETRIEVAL_SESSIONS,
        'last_retrieval': '$LAST_RETRIEVAL',
    },
    'staleness': {
        'stale': $STALE_COUNT,
        'aging': $AGING_COUNT,
        'fresh': $FRESH_COUNT,
        'last_scan': '$STALENESS_SCAN_TIME',
    },
    'usage': {
        'cold_entries': $COLD_ENTRIES,
        'last_scan': '$USAGE_SCAN_TIME',
    },
    'renormalize': {
        'flag_count': $RENORM_FLAG_COUNT,
        'last_renormalize': '$LAST_RENORMALIZE',
    },
}
print(json.dumps(data, indent=2))
"
  exit 0
fi

# --- Human-readable output ---
echo "=== Knowledge Store Status ==="
echo ""
echo "Store: $KDIR"
echo "Format version: $FORMAT_VERSION"
echo ""

echo "## Entries"
echo "  Total: $ENTRY_COUNT across $CATEGORY_COUNT categories"
if [[ "$INBOX_COUNT" -gt 0 ]]; then
  echo "  Inbox pending: $INBOX_COUNT"
fi
echo ""

echo "## Budget"
echo "  Last load: ${BUDGET_USED}/${BUDGET_TOTAL} tokens (${BUDGET_PCT}%)"
echo "  Retrieval sessions logged: $RETRIEVAL_SESSIONS"
if [[ -n "$LAST_RETRIEVAL" ]]; then
  echo "  Last retrieval: $LAST_RETRIEVAL"
fi
echo ""

if [[ -f "$META_DIR/staleness-report.json" ]]; then
  echo "## Staleness"
  echo "  Fresh: $FRESH_COUNT | Aging: $AGING_COUNT | Stale: $STALE_COUNT"
  if [[ -n "$STALENESS_SCAN_TIME" ]]; then
    echo "  Last scan: $STALENESS_SCAN_TIME"
  fi
  echo ""
fi

if [[ -f "$META_DIR/usage-report.json" ]]; then
  echo "## Usage"
  echo "  Cold entries (never retrieved): $COLD_ENTRIES"
  if [[ -n "$USAGE_SCAN_TIME" ]]; then
    echo "  Last scan: $USAGE_SCAN_TIME"
  fi
  echo ""
fi

if [[ "$RENORM_FLAG_COUNT" -gt 0 ]]; then
  echo "## Renormalize"
  echo "  Flags accumulated: $RENORM_FLAG_COUNT"
  if [[ -n "$LAST_RENORMALIZE" ]]; then
    echo "  Last renormalize: $LAST_RENORMALIZE"
  fi
  echo "  Run /memory renormalize to optimize."
  echo ""
fi

echo "=== End Status ==="
