#!/usr/bin/env bash
# consumption-contradiction-read.sh — Published bounded lifecycle projection.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR_OVERRIDE=""
WINDOW_START=""
WINDOW_END=""
CYCLE_ID=""
JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --window-start) WINDOW_START="$2"; shift 2 ;;
    --window-end) WINDOW_END="$2"; shift 2 ;;
    --cycle-id) CYCLE_ID="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help)
      echo "Usage: lore consumption-contradiction read --window-start RFC3339 --window-end RFC3339 [--cycle-id ID] [--kdir PATH] [--json]"
      exit 0
      ;;
    *) echo "[consumption-contradiction] Error: unknown reader flag '$1'" >&2; exit 1 ;;
  esac
done
[[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || { echo "[consumption-contradiction] Error: both window bounds are required" >&2; exit 1; }

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || { echo "[consumption-contradiction] Error: knowledge store not found" >&2; exit 1; }

RESULT=$(python3 - "$KNOWLEDGE_DIR" "$WINDOW_START" "$WINDOW_END" "$CYCLE_ID" <<'PY'
import glob, json, os, sys
from datetime import datetime, timezone

kdir, start_raw, end_raw, cycle_filter = sys.argv[1:]
def parse(value):
    value = value[:-1] + "+00:00" if value.endswith("Z") else value
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        raise ValueError("timezone required")
    return dt.astimezone(timezone.utc)
try:
    start, end = parse(start_raw), parse(end_raw)
except ValueError as exc:
    raise SystemExit(f"[consumption-contradiction] Error: invalid window: {exc}")
if start >= end:
    raise SystemExit("[consumption-contradiction] Error: window start must precede window end")

paths = glob.glob(os.path.join(kdir, "_work", "*", "consumption-contradictions.jsonl"))
paths += glob.glob(os.path.join(kdir, "_work", "_archive", "*", "consumption-contradictions.jsonl"))
rows = []
seen = set()
for path in sorted(paths):
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            if not raw.strip():
                continue
            try:
                row = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"[consumption-contradiction] Error: {path}:{lineno} malformed: {exc.msg}")
            if not isinstance(row, dict) or not row.get("contradiction_id"):
                raise SystemExit(f"[consumption-contradiction] Error: {path}:{lineno} invalid lifecycle row")
            if cycle_filter and row.get("cycle_id") != cycle_filter:
                continue
            created = row.get("created_at")
            settled = row.get("settled_at")
            try:
                in_window = (isinstance(created, str) and start <= parse(created) < end) or (isinstance(settled, str) and start <= parse(settled) < end)
            except ValueError:
                raise SystemExit(f"[consumption-contradiction] Error: {path}:{lineno} invalid lifecycle timestamp")
            if not in_window:
                continue
            identity = row["contradiction_id"]
            if identity in seen:
                raise SystemExit(f"[consumption-contradiction] Error: duplicate contradiction_id {identity}")
            seen.add(identity)
            rows.append({
                "contradiction_id": identity,
                "work_item": row.get("work_item"),
                "cycle_id": row.get("cycle_id"),
                "status": row.get("status"),
                "created_at": created,
                "settled_at": settled,
                "settled_by_run_id": row.get("settled_by_run_id"),
            })
rows.sort(key=lambda row: (row.get("created_at") or "", row["contradiction_id"]))
print(json.dumps(rows, ensure_ascii=False, separators=(",", ":")))
PY
)
printf '%s\n' "$RESULT"
