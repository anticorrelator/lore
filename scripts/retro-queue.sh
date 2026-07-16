#!/usr/bin/env bash
# retro-queue.sh — Narrow read/handling front for the retro outcome queue.
#
# `queue` folds DUE outcome + disposition rows by outcome_id while retaining
# legacy done/deferred/skipped rows in summary state. `handle` delegates the
# entire mutation to retro-deferred-append.sh, the queue's sole appender.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  retro-queue.sh queue [--cycle-id <slug>] [--window-start <RFC3339> --window-end <RFC3339>] [--kdir <path>] [--json]
  retro-queue.sh handle (--outcome-id <id> | --cycle-id <slug>)
      --action <dispatched|deferred|skipped> --handled-by <actor>
      [--kdir <path>] [--json]
EOF
}

[[ $# -gt 0 ]] || { usage; exit 1; }
OP="$1"
shift

if [[ "$OP" == "handle" ]]; then
  exec bash "$SCRIPT_DIR/retro-deferred-append.sh" \
    --record-type disposition --outcome due --disposition handled "$@"
fi

if [[ "$OP" != "queue" ]]; then
  echo "Error: unknown retro queue operation '$OP'" >&2
  usage
  exit 1
fi

CYCLE_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0
WINDOW_START=""
WINDOW_END=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycle-id) CYCLE_ID="$2"; shift 2 ;;
    --window-start) WINDOW_START="$2"; shift 2 ;;
    --window-end) WINDOW_END="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown flag '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$WINDOW_START" || -n "$WINDOW_END" ]]; then
  [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || { echo "Error: --window-start and --window-end must be supplied together" >&2; exit 1; }
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "Error: knowledge store not found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

QUEUE="$KNOWLEDGE_DIR/_scorecards/retro-deferred-queue.jsonl"
RESULT=$(python3 - "$QUEUE" "$CYCLE_ID" "$WINDOW_START" "$WINDOW_END" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

queue, cycle_filter, start_raw, end_raw = sys.argv[1:5]

def parse(value):
    value = value[:-1] + "+00:00" if value.endswith("Z") else value
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        raise ValueError("timezone required")
    return dt.astimezone(timezone.utc)

start = end = None
if start_raw or end_raw:
    try:
        start, end = parse(start_raw), parse(end_raw)
    except ValueError as exc:
        raise SystemExit(f"[retro queue] invalid window: {exc}")
    if start >= end:
        raise SystemExit("[retro queue] window start must precede window end")
outcomes = {}
dispositions = {}
legacy = []
malformed = 0

if os.path.isfile(queue):
    with open(queue, encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except (ValueError, TypeError):
                malformed += 1
                continue
            if cycle_filter and row.get("cycle_id") != cycle_filter:
                continue
            if start is not None:
                stamp = row.get("ts") or row.get("created_at") or row.get("timestamp")
                if not isinstance(stamp, str):
                    continue
                try:
                    if not (start <= parse(stamp) < end):
                        continue
                except ValueError:
                    malformed += 1
                    continue
            if row.get("outcome") == "due" and row.get("outcome_id"):
                oid = row["outcome_id"]
                if row.get("record_type") == "disposition":
                    dispositions.setdefault(oid, []).append(row)
                elif row.get("record_type") == "outcome":
                    outcomes[oid] = row
            elif row.get("outcome") in ("done", "deferred", "skipped"):
                legacy.append(row)

unhandled = []
handled = []
for oid, outcome in outcomes.items():
    transitions = dispositions.get(oid, [])
    if transitions:
        current = dict(outcome)
        current["disposition"] = "handled"
        current["handling"] = transitions[-1]
        handled.append(current)
    else:
        unhandled.append(outcome)

key = lambda row: (row.get("ts") or "", row.get("outcome_id") or "")
unhandled.sort(key=key)
handled.sort(key=key)
legacy.sort(key=key)
print(json.dumps({
    "reader_contract_version": "1",
    "projection_mode": "half-open-window" if start is not None else "fold",
    "window": {"start": start_raw, "end": end_raw} if start is not None else None,
    "fold_version": "1",
    "vocabulary_version": "1",
    "counts": {
        "unhandled_due": len(unhandled),
        "handled_due": len(handled),
        "deferred": sum(1 for row in legacy if row.get("outcome") == "deferred"),
        "done": sum(1 for row in legacy if row.get("outcome") == "done"),
        "skipped": sum(1 for row in legacy if row.get("outcome") == "skipped"),
        "malformed_ignored": malformed,
    },
    "unhandled_due": unhandled,
    "handled_due": handled,
    "legacy_outcomes": legacy,
}, ensure_ascii=False))
PYEOF
)

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$RESULT" | jq --arg path "${QUEUE#"$KNOWLEDGE_DIR"/}" \
    --arg cycle_id "$CYCLE_ID" \
    '. + {path: $path, cycle_filter: (if ($cycle_id | length) > 0 then $cycle_id else null end)}'
  exit 0
fi

UNHANDLED=$(printf '%s' "$RESULT" | jq -r '.counts.unhandled_due')
HANDLED=$(printf '%s' "$RESULT" | jq -r '.counts.handled_due')
DEFERRED=$(printf '%s' "$RESULT" | jq -r '.counts.deferred')
echo "Retro queue: $UNHANDLED unhandled DUE, $HANDLED handled DUE, $DEFERRED deferred"
if [[ "$UNHANDLED" -gt 0 ]]; then
  echo "Unhandled DUE outcomes:"
  printf '%s' "$RESULT" | jq -r '.unhandled_due[] | "  \(.outcome_id)  cycle=\(.cycle_id) terminus=\(.event_type) reason=\(.reason) stratum=\(.stratum)"'
fi
