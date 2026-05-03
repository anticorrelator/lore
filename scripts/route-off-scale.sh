#!/usr/bin/env bash
# route-off-scale.sh — Route pending off-scale rows into work-item scope_pointers
#
# Reads rows from `_work/<slug>/off_scale_routes.jsonl` where:
#   source  == <--source arg>
#   status  == "pending"
#
# For each matching row, writes (or idempotently skips) an entry in
# `_work/<slug>/scope_pointers.jsonl`. Scope pointers are consumed by
# prefetch-knowledge.sh when a worker's task file-scope overlaps the
# pointer's target_scope_hint.
#
# Usage:
#   route-off-scale.sh --work-item <slug> --source researcher|worker
#
# Exit codes:
#   0 — success (0 or more rows routed)
#   1 — usage/validation error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: route-off-scale.sh --work-item <slug> --source researcher|worker

Read pending off-scale rows and write them to scope_pointers.jsonl.
Source 'researcher' routes 'Worker leads' protocol-slot rows.
Source 'worker' routes 'Surfaced concerns' protocol-slot rows.

Options:
  --work-item   Work item slug (required)
  --source      Row source filter: researcher or worker (required)
  --help, -h    Show this help
EOF
}

WORK_ITEM=""
SOURCE_KIND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item) WORK_ITEM="$2"; shift 2 ;;
    --source)    SOURCE_KIND="$2"; shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_ITEM" ]]; then
  echo "Error: --work-item is required" >&2
  exit 1
fi

case "$SOURCE_KIND" in
  researcher|worker) : ;;
  "")
    echo "Error: --source is required" >&2
    exit 1
    ;;
  *)
    echo "Error: --source must be 'researcher' or 'worker' (got '$SOURCE_KIND')" >&2
    exit 1
    ;;
esac

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "Error: work item not found: $WORK_ITEM (expected $WORK_DIR)" >&2
  exit 1
fi

SIDECAR="$WORK_DIR/off_scale_routes.jsonl"

# researcher rows → scope_pointers (forward: feed next worker's prefetch)
# worker rows    → surfaced_concerns (backward: feed spec-lead synthesis + retro)
if [[ "$SOURCE_KIND" == "researcher" ]]; then
  OUTPUT_FILE="$WORK_DIR/scope_pointers.jsonl"
else
  OUTPUT_FILE="$WORK_DIR/surfaced_concerns.jsonl"
fi

if [[ ! -f "$SIDECAR" ]]; then
  echo "[route-off-scale] No sidecar found for $WORK_ITEM — nothing to route"
  exit 0
fi

python3 - "$SIDECAR" "$OUTPUT_FILE" "$SOURCE_KIND" <<'PYEOF'
import json
import sys

sidecar_path, scope_pointers_path, source_kind = sys.argv[1:4]

# Load existing route_ids for deduplication
existing_ids = set()
try:
    with open(scope_pointers_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                existing_ids.add(row.get("route_id", ""))
            except json.JSONDecodeError:
                pass
except FileNotFoundError:
    pass

# Read pending rows matching source_kind
with open(sidecar_path) as f:
    rows = []
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("source") == source_kind and row.get("status") == "pending":
            rows.append(row)

routed = 0
skipped = 0
with open(scope_pointers_path, "a") as out:
    for row in rows:
        route_id = row.get("route_id", "")
        if route_id in existing_ids:
            skipped += 1
            continue
        pointer = {
            "route_id": route_id,
            "source": row.get("source", ""),
            "protocol_slot": row.get("protocol_slot", ""),
            "payload": row.get("payload", ""),
            "target_scope_hint": row.get("target_scope_hint", ""),
            "work_item": row.get("work_item", ""),
            "created_at": row.get("created_at", ""),
        }
        out.write(json.dumps(pointer, ensure_ascii=False) + "\n")
        existing_ids.add(route_id)
        routed += 1

print(f"[route-off-scale] source={source_kind}: routed={routed} skipped={skipped} (sidecar: {sidecar_path})")
PYEOF
