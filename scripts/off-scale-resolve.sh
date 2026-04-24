#!/usr/bin/env bash
# off-scale-resolve.sh — Transition an off-scale route from pending to a terminal state
#
# Canonical resolver for `_work/*/off_scale_routes.jsonl`. Searches all work items
# for the given route_id and transitions it from `pending` to `accepted` or `declined`.
#
# IMPORTANT: Do NOT edit off_scale_routes.jsonl directly. Direct edits break the
# scorecard emission pipeline wired in `lore scorecard` (task-15). Use this script
# or `lore off-scale resolve` — they are the sole sanctioned writers for status
# transitions.
#
# Usage:
#   off-scale-resolve.sh <route_id> --status accepted|declined --resolved-by <agent-or-human>
#
# Exit codes:
#   0 — transition applied successfully
#   1 — usage/validation error (missing flag, bad status value, file/route not found)
#   2 — route is already in a terminal state (accepted or declined)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: off-scale-resolve.sh <route_id> --status accepted|declined --resolved-by <agent-or-human>

Transition a pending off-scale route to a terminal state.
Searches all _work/*/off_scale_routes.jsonl files for the route.

Options:
  --status        Target status: accepted or declined (required)
  --resolved-by   Agent name or human identifier (required)
  --help, -h      Show this help

Exit codes:
  0  Transition applied
  1  Usage error / route not found
  2  Already in terminal state (accepted or declined)
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

ROUTE_ID=""
TARGET_STATUS=""
RESOLVED_BY=""

# First positional arg is route_id
case "$1" in
  --help|-h) usage; exit 0 ;;
  --*)
    echo "Error: first argument must be <route_id>, not a flag" >&2
    usage
    exit 1
    ;;
  *)
    ROUTE_ID="$1"
    shift
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)      TARGET_STATUS="$2"; shift 2 ;;
    --resolved-by) RESOLVED_BY="$2";   shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate required fields
if [[ -z "$ROUTE_ID" ]]; then
  echo "Error: <route_id> is required" >&2
  exit 1
fi

if [[ -z "$TARGET_STATUS" ]]; then
  echo "Error: --status is required" >&2
  exit 1
fi

case "$TARGET_STATUS" in
  accepted|declined) : ;;
  *)
    echo "Error: --status must be 'accepted' or 'declined' (got '$TARGET_STATUS')" >&2
    exit 1
    ;;
esac

if [[ -z "$RESOLVED_BY" ]]; then
  echo "Error: --resolved-by is required" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_BASE="$KNOWLEDGE_DIR/_work"

# Search all off_scale_routes.jsonl files for the route_id
RESULT=$(python3 - "$WORK_BASE" "$ROUTE_ID" "$TARGET_STATUS" "$RESOLVED_BY" <<'PYEOF'
import json
import os
import sys
import tempfile

work_base, route_id, target_status, resolved_by = sys.argv[1:5]

TERMINAL = {"accepted", "declined"}

sidecar_found = None
row_found = None

for dirpath, dirnames, filenames in os.walk(work_base):
    if "off_scale_routes.jsonl" in filenames:
        sidecar = os.path.join(dirpath, "off_scale_routes.jsonl")
        with open(sidecar) as f:
            lines = f.readlines()
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("route_id") == route_id:
                sidecar_found = sidecar
                row_found = row
                all_lines = lines
                break
    if sidecar_found:
        break

if sidecar_found is None:
    print(json.dumps({"status": "not_found"}))
    sys.exit(0)

current_status = row_found.get("status", "pending")
if current_status in TERMINAL:
    print(json.dumps({"status": "terminal", "current": current_status}))
    sys.exit(0)

import datetime
resolved_at = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

row_found["status"] = target_status
row_found["resolved_by"] = resolved_by
row_found["resolved_at"] = resolved_at

# Rewrite the sidecar atomically
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(sidecar_found))
try:
    with os.fdopen(tmp_fd, "w") as tmp_f:
        for line in all_lines:
            stripped = line.strip()
            if not stripped:
                tmp_f.write(line)
                continue
            try:
                row = json.loads(stripped)
            except json.JSONDecodeError:
                tmp_f.write(line)
                continue
            if row.get("route_id") == route_id:
                tmp_f.write(json.dumps(row_found, ensure_ascii=False) + "\n")
            else:
                tmp_f.write(line)
    os.replace(tmp_path, sidecar_found)
except Exception:
    os.unlink(tmp_path)
    raise

out = {
    "status": "ok",
    "sidecar": sidecar_found,
    "resolved_at": resolved_at,
    "template_version": row_found.get("template_version") or "",
    "role": row_found.get("source") or "",
    "work_item": row_found.get("work_item") or "",
}
print(json.dumps(out))
PYEOF
)

RESULT_STATUS=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status',''))" "$RESULT")

case "$RESULT_STATUS" in
  not_found)
    echo "Error: route_id '$ROUTE_ID' not found in any _work/*/off_scale_routes.jsonl" >&2
    exit 1
    ;;
  terminal)
    current=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('current',''))" "$RESULT")
    echo "Error: route '$ROUTE_ID' is already in terminal state '$current' — re-resolution is not allowed" >&2
    exit 2
    ;;
  ok)
    sidecar=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('sidecar',''))" "$RESULT")
    resolved_at=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('resolved_at',''))" "$RESULT")
    template_version=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('template_version',''))" "$RESULT")
    role=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('role',''))" "$RESULT")
    work_item=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('work_item',''))" "$RESULT")

    echo "[off-scale] Route $ROUTE_ID resolved as '$TARGET_STATUS' by '$RESOLVED_BY' at $resolved_at (sidecar: $sidecar)"

    # Emit a route_precision telemetry row to the scorecard substrate.
    # kind=telemetry: observability-only, does NOT feed /evolve or F1 template ranking
    # (plan Principle 6). calibration_state=pre-calibration until enough signal accrues.
    SCORECARD_ROW=$(python3 -c '
import json, sys
route_id, template_version, role, outcome, work_item, ts = sys.argv[1:7]
row = {
    "schema_version": "1",
    "kind": "telemetry",
    "tier": "telemetry",
    "calibration_state": "pre-calibration",
    "metric": "route_precision",
    "template_id": template_version if template_version else None,
    "role": role if role else None,
    "outcome": outcome,
    "route_id": route_id,
    "ts": ts,
    "work_item": work_item if work_item else None,
}
print(json.dumps(row, ensure_ascii=False))
' "$ROUTE_ID" "$template_version" "$role" "$TARGET_STATUS" "$work_item" "$resolved_at")

    "$SCRIPT_DIR/scorecard-append.sh" --row "$SCORECARD_ROW"
    ;;
  *)
    echo "Error: unexpected result from resolver: $RESULT" >&2
    exit 1
    ;;
esac
