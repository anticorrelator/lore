#!/usr/bin/env bash
# packet-append.sh — Append a validated context-packet delivery row to packets.jsonl
#
# Usage:
#   echo '<json>' | packet-append.sh
#   packet-append.sh --row '<json>' [--kdir <path>] [--json] [--model <id>]
#
# Reads a single JSON object (via --row or stdin), stamps writer-owned
# provenance fields, validates it against the packet schema
# (packet_schema.py), and appends one compact JSONL line to
# $KDIR/_packets/packets.jsonl. Creates the _packets/ directory and seeds
# its README on first use. A row that fails validation exits non-zero
# without touching any file.
#
# SOLE-WRITER INVARIANT: `packet-append.sh` is the only sanctioned writer of
# `$KDIR/_packets/packets.jsonl`. No other script, skill, agent prompt, or
# human process may append, edit, or truncate that file directly. If a second
# write verb is ever needed (update, migrate), add a thin front that shells
# out to this script — never a second physical appender.
#
# APPEND-SUPERSEDE, NO DEDUPE: each row is a point-in-time delivery event; a
# re-dispatch is a new delivery, so identical appends produce distinct rows.
# Supersede by writing a new row, never by editing.
#
# Writer-owned stamps (applied here, before validation):
#   schema_version         "2" for bound task identity, otherwise "1"
#   packet_schema_sha      sha256 of packet_schema.py (always overwritten)
#   model                  row's own value > --model flag > LORE_MODEL > "unrecorded"
#   captured_at_branch / captured_at_sha / captured_at_merge_base_sha
#                          branch-provenance trio (always overwritten)
#   delivered_at           stamped with the current UTC time when absent
#   trust_compute_sha      row's own value wins (the emitter's fold produced
#                          the delivered scores); sha256 of trust-compute.py
#                          when absent
#
# Legacy field reference: $KDIR/_packets/README.md. Bound identity: docs/protocol-evidence.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ROW=""
KDIR_OVERRIDE=""
JSON_MODE=0
MODEL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --row)
      ROW="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --model)
      MODEL_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,41p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: packet-append.sh [--row '<json>'] [--kdir <path>] [--json] [--model <id>]" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

# --- Read row from stdin if not provided via flag ---
if [[ -z "$ROW" ]]; then
  if [[ -t 0 ]]; then
    fail "no row provided: pass --row '<json>' or pipe JSON on stdin"
  fi
  ROW=$(cat)
fi

if [[ -z "$ROW" || "$ROW" =~ ^[[:space:]]*$ ]]; then
  fail "row is empty"
fi

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if ! printf '%s' "$ROW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "row must be a JSON object"
fi

# --- Writer-owned stamps ---
PACKET_SCHEMA_SHA=$(python3 "$SCRIPT_DIR/packet_schema.py" --sha)

TRUST_COMPUTE_PY="$SCRIPT_DIR/trust-compute.py"
if [[ ! -f "$TRUST_COMPUTE_PY" ]]; then
  fail "trust-compute.py not found next to this script; cannot stamp trust_compute_sha"
fi
TRUST_COMPUTE_SHA=$(python3 -c '
import hashlib, sys
with open(sys.argv[1], "rb") as fh:
    print(hashlib.sha256(fh.read()).hexdigest())
' "$TRUST_COMPUTE_PY")

STAMP_MODEL="${MODEL_OVERRIDE:-${LORE_MODEL:-unrecorded}}"
DELIVERED_AT=$(timestamp_iso)
CAPTURED_AT_BRANCH=$(captured_at_branch)
CAPTURED_AT_SHA=$(captured_at_sha)
CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)

ROW=$(printf '%s' "$ROW" | jq -c \
  --arg schema_sha "$PACKET_SCHEMA_SHA" \
  --arg tc_sha "$TRUST_COMPUTE_SHA" \
  --arg model "$STAMP_MODEL" \
  --arg delivered_at "$DELIVERED_AT" \
  --arg branch "$CAPTURED_AT_BRANCH" \
  --arg sha "$CAPTURED_AT_SHA" \
  --arg mb "$CAPTURED_AT_MERGE_BASE_SHA" \
  '
  def nullable($v): if $v == "null" then null else $v end;
  .schema_version = (if .schema_version == "2" or has("revision_id") or has("dispatch_attempt_id") then "2" else "1" end)
  | .packet_schema_sha = $schema_sha
  | .trust_compute_sha = (.trust_compute_sha // $tc_sha)
  | .model = (if (.model // "") == "" then $model else .model end)
  | .delivered_at = (if (.delivered_at // "") == "" then $delivered_at else .delivered_at end)
  | .template_version = (.template_version // null)
  | .captured_at_branch = nullable($branch)
  | .captured_at_sha = nullable($sha)
  | .captured_at_merge_base_sha = nullable($mb)
  ')

# --- Validate before any disk touch ---
if ! printf '%s' "$ROW" | python3 "$SCRIPT_DIR/packet_schema.py" --kind packet; then
  fail "row rejected by packet schema — not appended"
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

# Validate revision attribution before creating packet artifacts.
printf '%s' "$ROW" | python3 - "$KNOWLEDGE_DIR" "$SCRIPT_DIR" 3<&0 <<'PY'
import json, os, runpy, sys
row = json.load(os.fdopen(3))
root, scripts = sys.argv[1:]
from pathlib import Path
if row.get("packet_scope") == "task" and row.get("work_item"):
    item = Path(root) / "_work" / row["work_item"]
    if item.parent.resolve() != (Path(root) / "_work").resolve():
        sys.exit("packet: work_item must identify an active work item")
    if row["schema_version"] == "1" and row.get("unbound_reason") != "dispatch-attempt-not-recorded" and ((item / "revisions.jsonl").exists() or
            ((item / "tasks.json").exists() and json.loads((item / "tasks.json").read_text()).get("revision_id"))):
        sys.exit("packet: revised tasks require revision_id and dispatch_attempt_id")
if row.get("unbound_reason") == "dispatch-attempt-not-recorded":
    if row["schema_version"] != "1" or row.get("packet_scope") != "task":
        sys.exit("packet: missing-attempt reason requires an unbound task packet")
    publication = runpy.run_path(os.path.join(scripts, "work-evidence.py"))["publication_for_dispatch"](str(item), root)
    if not publication["revision_id"]:
        sys.exit("packet: missing-attempt reason requires a committed revision")
    packets = Path(root) / "_packets/packets.jsonl"
    if packets.exists():
        for line in packets.read_text().splitlines():
            prior = json.loads(line)
            if (prior.get("work_item") == row["work_item"] and prior.get("task_id") == row["task_id"]
                    and prior.get("revision_id") == publication["revision_id"] and prior.get("dispatch_attempt_id")):
                sys.exit("packet: a dispatch attempt exists; bind the packet to it")
# Rows supersede by append under one packet_id (assembled, then synthesized, then delivered), and readers take
# the last row as the packet; so no row appended under an existing id may change what the packet is about.
packets_path = Path(root) / "_packets/packets.jsonl"
if packets_path.exists() and row.get("packet_id"):
    identity = ("schema_version", "packet_scope", "work_item", "task_id", "revision_id", "dispatch_attempt_id",
                "source_head", "recipient_role", "session_id")
    for line in packets_path.read_text().splitlines():
        if not line.strip():
            continue
        prior = json.loads(line)
        if prior.get("packet_id") != row["packet_id"]:
            continue
        for key in identity:
            if prior.get(key) != row.get(key):
                sys.exit(f"packet: {key} differs from the prior row for packet {row['packet_id']}; a supersede chain keeps its identity")
if row["schema_version"] == "2":
    try:
        publication = runpy.run_path(os.path.join(scripts, "work-evidence.py"))["publication_for_dispatch"](str(item), root)
        if publication["revision_id"] != row["revision_id"]:
            raise ValueError("packet revision does not match the committed task generation")
        tasks = json.loads((item / "tasks.json").read_text())
        flat = tasks.get("tasks")
        if not isinstance(flat, list):
            flat = [task for phase in tasks.get("phases", []) for task in phase.get("tasks", [])]
        if row["task_id"] not in {task["id"] for task in flat}:
            raise ValueError("packet task is absent from the committed revision")
        if row["source_head"] != publication["source_head"]:
            raise ValueError("packet source_head differs from the committed revision")
    except (OSError, ValueError, KeyError) as exc:
        sys.exit("packet: " + str(exc))
PY

PACKETS_DIR="$KNOWLEDGE_DIR/_packets"
ROWS_FILE="$PACKETS_DIR/packets.jsonl"
mkdir -p "$PACKETS_DIR"

# Seed _packets/README.md on first use so the invariants travel with the store.
if [[ ! -f "$PACKETS_DIR/README.md" ]]; then
  "$SCRIPT_DIR/seed-packets-readme.sh" "$PACKETS_DIR" 2>/dev/null || true
fi

# --- Compact to one line and append (single O_APPEND write; no lock, no dedupe) ---
COMPACT=$(printf '%s' "$ROW" | jq -c '.')
printf '%s\n' "$COMPACT" >> "$ROWS_FILE"

RELPATH="${ROWS_FILE#$KNOWLEDGE_DIR/}"
PACKET_ID=$(printf '%s' "$ROW" | jq -r '.packet_id')
PACKET_SCOPE=$(printf '%s' "$ROW" | jq -r '.packet_scope')

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg path "$RELPATH" \
    --arg packet_id "$PACKET_ID" \
    --arg packet_scope "$PACKET_SCOPE" \
    '{path: $path, packet_id: $packet_id, packet_scope: $packet_scope, appended: true}')"
fi

echo "[packet] Appended packet '$PACKET_ID' to $RELPATH (scope=$PACKET_SCOPE)"
