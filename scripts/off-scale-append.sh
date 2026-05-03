#!/usr/bin/env bash
# off-scale-append.sh — Append a row to a work item's off-scale routing sidecar
#
# Canonical writer for `_work/<slug>/off_scale_routes.jsonl`. Task #29
# (write-execution-log.sh ingestion) calls this when it parses a `Worker leads:`
# or `Surfaced concerns:` field with a non-None payload.
#
# Schema: architecture/off-scale-routing/sidecar-schema.md
#
# Usage:
#   off-scale-append.sh --work-item <slug> --source <worker|researcher> \
#                       --producer-role <role> --protocol-slot <slot> \
#                       --cycle-id <id> --payload <text> \
#                       [--template-version <hash>] [--target-scope-hint <hint>]
#                       [--route-id <uuid>] [--created-at <iso8601>]
#
# Dedupe: same dedupe_key in the same work item → no-op (silent, exit 0).
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — missing/empty required flag, unknown flag, work-item not found, JSON build failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: off-scale-append.sh --work-item <slug> --source <worker|researcher> \\
                           --producer-role <role> --protocol-slot <slot> \\
                           --cycle-id <id> --payload <text> \\
                           [--template-version <hash>] [--target-scope-hint <hint>] \\
                           [--route-id <uuid>] [--created-at <iso8601>]

Append a row to a work item's _work/<slug>/off_scale_routes.jsonl sidecar.
Dedupes on (source, payload) sha256 — a duplicate is a silent no-op.
EOF
}

WORK_ITEM=""
SOURCE_KIND=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
TEMPLATE_VERSION=""
CYCLE_ID=""
TARGET_SCOPE_HINT=""
PAYLOAD=""
ROUTE_ID=""
CREATED_AT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)         WORK_ITEM="$2";         shift 2 ;;
    --source)            SOURCE_KIND="$2";       shift 2 ;;
    --producer-role)     PRODUCER_ROLE="$2";     shift 2 ;;
    --protocol-slot)     PROTOCOL_SLOT="$2";     shift 2 ;;
    --template-version)  TEMPLATE_VERSION="$2";  shift 2 ;;
    --cycle-id)          CYCLE_ID="$2";          shift 2 ;;
    --target-scope-hint) TARGET_SCOPE_HINT="$2"; shift 2 ;;
    --payload)           PAYLOAD="$2";           shift 2 ;;
    --route-id)          ROUTE_ID="$2";          shift 2 ;;
    --created-at)        CREATED_AT="$2";        shift 2 ;;
    --help|-h)           usage; exit 0 ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# Required-field validation.
for _pair in \
  "work-item:$WORK_ITEM" \
  "source:$SOURCE_KIND" \
  "producer-role:$PRODUCER_ROLE" \
  "protocol-slot:$PROTOCOL_SLOT" \
  "cycle-id:$CYCLE_ID" \
  "payload:$PAYLOAD"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    echo "Error: --$_flag is required" >&2
    exit 1
  fi
done

case "$SOURCE_KIND" in
  worker|researcher) : ;;
  *)
    echo "Error: --source must be 'worker' or 'researcher' (got '$SOURCE_KIND')" >&2
    exit 1
    ;;
esac

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "Error: work item not found: $WORK_ITEM (expected $WORK_DIR)" >&2
  exit 1
fi

SIDECAR="$WORK_DIR/off_scale_routes.jsonl"

# --- Defaults for generated fields ---
if [[ -z "$ROUTE_ID" ]]; then
  # UUID v4 via python — portable across macOS and Linux, avoids uuidgen dependency variance.
  ROUTE_ID=$(python3 -c 'import uuid; print(uuid.uuid4())')
fi
if [[ -z "$CREATED_AT" ]]; then
  CREATED_AT=$(timestamp_iso)
fi

# --- Compute dedupe key: sha256(source + "|" + payload), 64-char hex ---
DEDUPE_KEY=$(printf '%s|%s' "$SOURCE_KIND" "$PAYLOAD" | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

# --- Dedupe check ---
# If an existing row in this work item already has the same dedupe_key, silent no-op.
if [[ -f "$SIDECAR" ]]; then
  if python3 -c '
import json, sys
sidecar, key = sys.argv[1:3]
try:
    with open(sidecar) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("dedupe_key") == key:
                sys.exit(0)
    sys.exit(1)
except FileNotFoundError:
    sys.exit(1)
' "$SIDECAR" "$DEDUPE_KEY"; then
    # Match found — silent no-op.
    exit 0
  fi
fi

# --- Build and append the row ---
# Use Python for JSON so escaping is correct even when payload contains quotes/newlines.
ROW=$(python3 -c '
import json, sys
(route_id, source_kind, producer_role, protocol_slot, template_version,
 cycle_id, work_item, target_scope_hint, payload, created_at, dedupe_key) = sys.argv[1:12]
row = {
    "route_id": route_id,
    "source": source_kind,
    "producer_role": producer_role,
    "protocol_slot": protocol_slot,
    "template_version": template_version if template_version else None,
    "cycle_id": cycle_id,
    "work_item": work_item,
    "target_scope_hint": target_scope_hint,
    "payload": payload,
    "status": "pending",
    "created_at": created_at,
    "resolved_at": None,
    "resolved_by": None,
    "dedupe_key": dedupe_key,
}
print(json.dumps(row, ensure_ascii=False))
' "$ROUTE_ID" "$SOURCE_KIND" "$PRODUCER_ROLE" "$PROTOCOL_SLOT" "$TEMPLATE_VERSION" \
  "$CYCLE_ID" "$WORK_ITEM" "$TARGET_SCOPE_HINT" "$PAYLOAD" "$CREATED_AT" "$DEDUPE_KEY")

printf '%s\n' "$ROW" >> "$SIDECAR"

echo "[off-scale] Route $ROUTE_ID appended to $SIDECAR"
