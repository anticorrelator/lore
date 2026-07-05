#!/usr/bin/env bash
# session-event-append.sh — Append a validated event row to _sessions/events.jsonl
#
# Usage:
#   echo '<json>' | bash session-event-append.sh
#   bash session-event-append.sh --row '<json>' [--kdir <path>] [--json]
#
# Reads a single JSON object (via --row or stdin), validates it against the
# session-event schema, stamps provenance (event_id + ts when absent), compacts
# to one line, and appends it to $KDIR/_sessions/events.jsonl. Creates the
# _sessions/ directory on first use.
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# $KDIR/_sessions/events.jsonl. No TUI, verb, hook, or human process may append
# to that file directly — every emitter shells out here so validation lives in
# exactly one place. If a distinct sanctioned operation over this file is needed
# later, it is a sibling script that shells out to this appender, never a second
# physical writer. Rows that bypass this validator are treated as corrupt by
# every reader, which excludes-with-warning rather than counting them.
# See docs/session-substrate.md for the full substrate contract.
#
# Provenance stamping (writer-owned, omit-when-empty for caller-supplied ids):
#   event_id  generated as "<timestamp>-<random>" when the caller omits it;
#             callers that need idempotency pass a deterministic id and guard on
#             it (this writer NEVER dedupes — it appends every valid row).
#   ts        stamped with timestamp_iso when the caller omits it.
#   links     defaulted to {} so the Go reader always decodes a nested object.
#
# Required fields:
#   event        enum: requested | claimed | spawned | needs_input | quiescent |
#                resumed | closed | step_completed | harness_turn_ended |
#                spawn_failed | request_reclaimed | request_abandoned |
#                request_cancelled | close_requested | send_requested | sent |
#                send_refused
#
# Conditional rules:
#   Queue-lifecycle events (requested, claimed, spawned, spawn_failed,
#   request_reclaimed, request_abandoned, request_cancelled, close_requested,
#   send_requested, sent, send_refused) REQUIRE a non-empty request_id.
#
# Exit codes: 0 success; 1 validation error / refused. No child processes are
# spawned, so no child exit code is propagated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ROW=""
KDIR_OVERRIDE=""
JSON_MODE=0

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
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-event-append.sh [--row '<json>'] [--kdir <path>] [--json]" >&2
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

# --- Validate event against the closed vocabulary ---
EVENT=$(printf '%s' "$ROW" | jq -r '.event // ""')
case "$EVENT" in
  requested|claimed|spawned|needs_input|quiescent|resumed|closed|\
step_completed|harness_turn_ended|spawn_failed|request_reclaimed|\
request_abandoned|request_cancelled|close_requested|send_requested|sent|send_refused) ;;
  "")
    fail "missing required field: event"
    ;;
  *)
    fail "invalid event: '$EVENT' (must be one of requested, claimed, spawned, needs_input, quiescent, resumed, closed, step_completed, harness_turn_ended, spawn_failed, request_reclaimed, request_abandoned, request_cancelled, close_requested, send_requested, sent, send_refused)"
    ;;
esac

# --- Queue-lifecycle events require a non-empty request_id ---
case "$EVENT" in
  requested|claimed|spawned|spawn_failed|request_reclaimed|request_abandoned|request_cancelled|close_requested|send_requested|sent|send_refused)
    if ! printf '%s' "$ROW" | jq -e '(.request_id // "") != ""' >/dev/null 2>&1; then
      fail "missing required field: request_id (required for queue-lifecycle event '$EVENT')"
    fi
    ;;
esac

# --- links, when present, must be an object ---
if printf '%s' "$ROW" | jq -e 'has("links")' >/dev/null 2>&1; then
  if ! printf '%s' "$ROW" | jq -e '.links | type == "object"' >/dev/null 2>&1; then
    fail "invalid field: links (must be a JSON object)"
  fi
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

SESSIONS_DIR="$KNOWLEDGE_DIR/_sessions"
EVENTS_FILE="$SESSIONS_DIR/events.jsonl"
mkdir -p "$SESSIONS_DIR"

# --- Stamp provenance the caller did not supply ---
# event_id: "<timestamp>-<random>", generated only when absent so a caller's
# deterministic idempotency key survives. ts: authoritative write-time stamp
# when absent. links: always an object for the Go reader.
if ! printf '%s' "$ROW" | jq -e '(.event_id // "") != ""' >/dev/null 2>&1; then
  RAND=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  EVENT_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
  ROW=$(printf '%s' "$ROW" | jq -c --arg id "$EVENT_ID" '. + {event_id: $id}')
fi

if ! printf '%s' "$ROW" | jq -e '(.ts // "") != ""' >/dev/null 2>&1; then
  ROW=$(printf '%s' "$ROW" | jq -c --arg ts "$(timestamp_iso)" '. + {ts: $ts}')
fi

ROW=$(printf '%s' "$ROW" | jq -c 'if has("links") then . else . + {links: {}} end')

# --- Compact to one line and append (bare >> / O_APPEND, no read-modify-write) ---
COMPACT=$(printf '%s' "$ROW" | jq -c '.')
printf '%s\n' "$COMPACT" >> "$EVENTS_FILE"

RELPATH="${EVENTS_FILE#$KNOWLEDGE_DIR/}"
FINAL_EVENT_ID=$(printf '%s' "$COMPACT" | jq -r '.event_id')

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg event "$EVENT" \
    --arg event_id "$FINAL_EVENT_ID" \
    '{path: $path, event: $event, event_id: $event_id, appended: true}')
  json_output "$RESULT"
fi

echo "[session] Appended event to $RELPATH (event=$EVENT, event_id=$FINAL_EVENT_ID)"
