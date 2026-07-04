#!/usr/bin/env bash
# packet-append.sh — Append a validated context-packet delivery row to packets.jsonl
#
# Usage:
#   echo '<json>' | packet-append.sh
#   packet-append.sh --row '<json>' [--kdir <path>] [--json] [--model <id>]
#
# Reads a single JSON object (via --row or stdin), stamps writer-owned
# provenance fields, validates it against the packet schema v1
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
# PROMPT-CONTEXT INVARIANT: packet rows are never loaded into any agent
# prompt. The packet measures delivery quality for agents whose behavior the
# graduation experiment compares; a measured agent seeing its own delivery
# record contaminates the measurement. See $KDIR/_packets/README.md.
#
# Writer-owned stamps (applied here, before validation):
#   schema_version         always "1"
#   packet_schema_sha      sha256 of packet_schema.py (always overwritten)
#   model                  row's own value > --model flag > LORE_MODEL > "unrecorded"
#   captured_at_branch / captured_at_sha / captured_at_merge_base_sha
#                          branch-provenance trio (always overwritten)
#   delivered_at           stamped with the current UTC time when absent
#   trust_compute_sha      row's own value wins (the emitter's fold produced
#                          the delivered scores); sha256 of trust-compute.py
#                          when absent
#
# Schema v1 field reference and reader contract: $KDIR/_packets/README.md.

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

if [[ -z "${ROW// }" ]]; then
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
  .schema_version = "1"
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
  fail "row rejected by packet schema v1 — not appended"
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
