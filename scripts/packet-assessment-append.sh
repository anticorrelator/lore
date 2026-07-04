#!/usr/bin/env bash
# packet-assessment-append.sh — Append a validated packet-assessment row to assessments.jsonl
#
# Usage:
#   echo '<json>' | packet-assessment-append.sh
#   packet-assessment-append.sh --row '<json>' [--kdir <path>] [--json] [--model <id>]
#
# Reads a single JSON object (via --row or stdin), stamps writer-owned
# provenance fields, validates it against the assessment schema v1
# (packet_schema.py), and appends one compact JSONL line to
# $KDIR/_packets/assessments.jsonl. Creates the _packets/ directory and
# seeds its README on first use. A row that fails validation exits non-zero
# without touching any file.
#
# SOLE-WRITER INVARIANT: `packet-assessment-append.sh` is the only sanctioned
# writer of `$KDIR/_packets/assessments.jsonl`. No other script, skill, agent
# prompt, or human process may append, edit, or truncate that file directly.
# If a second write verb is ever needed, add a thin front that shells out to
# this script — never a second physical appender.
#
# APPEND-SUPERSEDE, NO DEDUPE: a re-assessment of the same packet is a new
# row. Supersede by writing a new row, never by editing.
#
# PROMPT-CONTEXT INVARIANT: assessment rows are never loaded into any agent
# prompt. See $KDIR/_packets/README.md.
#
# Writer-owned stamps (applied here, before validation):
#   schema_version         always "1"
#   packet_schema_sha      sha256 of packet_schema.py (always overwritten)
#   model                  row's own value > --model flag > LORE_MODEL > "unrecorded"
#   captured_at_branch / captured_at_sha / captured_at_merge_base_sha
#                          branch-provenance trio (always overwritten)
#   assessed_at            stamped with the current UTC time when absent
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
      sed -n '2,36p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: packet-assessment-append.sh [--row '<json>'] [--kdir <path>] [--json] [--model <id>]" >&2
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
STAMP_MODEL="${MODEL_OVERRIDE:-${LORE_MODEL:-unrecorded}}"
ASSESSED_AT=$(timestamp_iso)
CAPTURED_AT_BRANCH=$(captured_at_branch)
CAPTURED_AT_SHA=$(captured_at_sha)
CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)

ROW=$(printf '%s' "$ROW" | jq -c \
  --arg schema_sha "$PACKET_SCHEMA_SHA" \
  --arg model "$STAMP_MODEL" \
  --arg assessed_at "$ASSESSED_AT" \
  --arg branch "$CAPTURED_AT_BRANCH" \
  --arg sha "$CAPTURED_AT_SHA" \
  --arg mb "$CAPTURED_AT_MERGE_BASE_SHA" \
  '
  def nullable($v): if $v == "null" then null else $v end;
  .schema_version = "1"
  | .packet_schema_sha = $schema_sha
  | .model = (if (.model // "") == "" then $model else .model end)
  | .assessed_at = (if (.assessed_at // "") == "" then $assessed_at else .assessed_at end)
  | .captured_at_branch = nullable($branch)
  | .captured_at_sha = nullable($sha)
  | .captured_at_merge_base_sha = nullable($mb)
  ')

# --- Validate before any disk touch ---
if ! printf '%s' "$ROW" | python3 "$SCRIPT_DIR/packet_schema.py" --kind assessment; then
  fail "row rejected by assessment schema v1 — not appended"
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
ROWS_FILE="$PACKETS_DIR/assessments.jsonl"
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
DISPATCH_CONFIRMED=$(printf '%s' "$ROW" | jq -r '.dispatch_confirmed')

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg path "$RELPATH" \
    --arg packet_id "$PACKET_ID" \
    --argjson dispatch_confirmed "$DISPATCH_CONFIRMED" \
    '{path: $path, packet_id: $packet_id, dispatch_confirmed: $dispatch_confirmed, appended: true}')"
fi

echo "[packet-assessment] Appended assessment for packet '$PACKET_ID' to $RELPATH (dispatch_confirmed=$DISPATCH_CONFIRMED)"
