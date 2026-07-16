#!/usr/bin/env bash
# scorecard-read.sh — Published scorecard snapshot and bounded-row projections.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODE="${1:-}"
[[ -n "$MODE" ]] || { echo "Usage: scorecard-read.sh <current|rows> [options]" >&2; exit 1; }
shift

KDIR_OVERRIDE=""
WINDOW_START=""
WINDOW_END=""
JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --window-start) WINDOW_START="$2"; shift 2 ;;
    --window-end) WINDOW_END="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help)
      echo "Usage: scorecard-read.sh <current|rows> [--window-start RFC3339 --window-end RFC3339] [--kdir PATH] [--json]"
      exit 0
      ;;
    *) echo "Error: unknown scorecard reader flag '$1'" >&2; exit 1 ;;
  esac
done

[[ "$MODE" == "current" || "$MODE" == "rows" ]] || { echo "Error: reader mode must be current or rows" >&2; exit 1; }
if [[ -n "$WINDOW_START" || -n "$WINDOW_END" ]]; then
  [[ "$MODE" == "rows" ]] || { echo "Error: current is a snapshot and does not accept window bounds" >&2; exit 1; }
  [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || { echo "Error: --window-start and --window-end must be supplied together" >&2; exit 1; }
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || { echo "Error: knowledge store not found at: $KNOWLEDGE_DIR" >&2; exit 1; }

if [[ "$MODE" == "current" ]]; then
  CURRENT="$KNOWLEDGE_DIR/_scorecards/_current.json"
  if [[ -f "$CURRENT" ]]; then
    jq -e 'type == "object"' "$CURRENT" >/dev/null || { echo "[scorecard] error: _current.json is malformed" >&2; exit 1; }
    jq -c '. + {reader_contract_version:"1", projection_mode:"snapshot"}' "$CURRENT"
  else
    printf '%s\n' '{"reader_contract_version":"1","projection_mode":"snapshot","generated_at":null,"window_end":null,"source":"_scorecards/rows.jsonl","row_count":0,"corrupt_row_count":0,"summaries":[]}'
  fi
  exit 0
fi

ROWS="$KNOWLEDGE_DIR/_scorecards/rows.jsonl"
RESULT=$(python3 - "$ROWS" "$WINDOW_START" "$WINDOW_END" <<'PY'
import json, os, sys
from datetime import datetime, timezone

path, start_raw, end_raw = sys.argv[1:]

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
        raise SystemExit(f"[scorecard] error: invalid window: {exc}")
    if start >= end:
        raise SystemExit("[scorecard] error: window start must precede window end")

rows = []
if os.path.isfile(path):
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"[scorecard] error: rows.jsonl:{lineno} malformed: {exc.msg}")
            if not isinstance(row, dict):
                raise SystemExit(f"[scorecard] error: rows.jsonl:{lineno} is not an object")
            if start is not None:
                stamp = next((row.get(k) for k in ("window_end", "timestamp", "created_at", "captured_at", "settled_at") if row.get(k)), None)
                if not isinstance(stamp, str):
                    continue
                try:
                    when = parse(stamp)
                except ValueError:
                    raise SystemExit(f"[scorecard] error: rows.jsonl:{lineno} has invalid timestamp")
                if not (start <= when < end):
                    continue
            rows.append(row)
print(json.dumps(rows, ensure_ascii=False, separators=(",", ":")))
PY
)

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$RESULT"
else
  printf '%s' "$RESULT" | jq -c '.[]'
fi
