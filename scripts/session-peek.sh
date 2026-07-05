#!/usr/bin/env bash
# session-peek.sh — Snapshot a live TUI-hosted session's rendered screen.
#
# Usage:
#   lore session peek <slug> [--raw] [--timeout <sec>] [options]
#
# Options:
#   --raw              Include the ANSI-styled screen render, not just plain rows.
#   --timeout <sec>    Response poll budget (default: 15 ≈ 3 poll ticks).
#   --requested-by <w> Who requested it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --ttl <seconds>    Instance liveness TTL for slug resolution (default: 30).
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit the full JSON response object.
#
# Peek enqueues _sessions/peek-requests/<request_id>.json for the one live
# instance running <slug>. That instance snapshots the session's screen on its
# poll tick and writes _sessions/peek-responses/<request_id>.json (tmp + atomic
# rename) carrying the plain-text rows plus the readiness classification
# (ready / blocked_reason) from the same gate `session send` uses. This verb
# polls for that response, prints it, and deletes it (the requester is the sole
# consumer). Peek is a read, not a lifecycle transition, so it emits no journal
# events. See docs/session-substrate.md.
#
# Exit codes:
#   0  screen returned
#   1  error (bad args, no live instance, enqueue failure, or response timeout)
#   2  reserved (session verb family / composed-terminal-verb namespace)
#   3  reserved

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

SLUG_ARG=""
RAW=0
TIMEOUT=15
REQUESTED_BY=""
TTL=30
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw) RAW=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --*)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-peek.sh <slug> [--raw] [--timeout <sec>] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$SLUG_ARG" ]]; then
        SLUG_ARG="$1"
      else
        echo "Unexpected extra argument: $1" >&2
        exit 1
      fi
      shift
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

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

[[ -n "$SLUG_ARG" ]] || fail "no target: pass a <slug>"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail "invalid --timeout: '$TIMEOUT' (must be a non-negative integer)"
fi

if [[ -z "$REQUESTED_BY" ]]; then
  REQUESTED_BY="${LORE_SESSION_INSTANCE:-${USER:-unknown}}"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

SESSIONS_DIR="$KNOWLEDGE_DIR/_sessions"

# --- Resolve the owning live instance ---
SLUG="$SLUG_ARG"
TARGET_INSTANCE="$(resolve_session_owner "$SESSIONS_DIR/instances" "$SLUG" "$TTL")"
[[ -n "$TARGET_INSTANCE" ]] || fail "no live instance is running session '$SLUG'"

# --- Enqueue: tmp-write + rename into peek-requests/ ---
PEEK_DIR="$SESSIONS_DIR/peek-requests"
mkdir -p "$PEEK_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"
RAW_JSON=false
[[ $RAW -eq 1 ]] && RAW_JSON=true

ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg target "$TARGET_INSTANCE" \
  --argjson raw "$RAW_JSON" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  '{request_id: $request_id, slug: $slug, target_instance: $target, raw: $raw, requested_by: $requested_by, requested_at: $requested_at}')"

TMP="$(mktemp "$PEEK_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$PEEK_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

# --- Poll for the response, print, delete-on-read ---
RESPONSE_FILE="$SESSIONS_DIR/peek-responses/${REQUEST_ID}.json"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  if [[ -f "$RESPONSE_FILE" ]]; then
    RESP="$(cat "$RESPONSE_FILE")"
    rm -f "$RESPONSE_FILE"
    if [[ $JSON_MODE -eq 1 ]]; then
      json_output "$RESP"
    fi
    READY="$(printf '%s' "$RESP" | jq -r '.ready')"
    REASON="$(printf '%s' "$RESP" | jq -r '.blocked_reason // ""')"
    if [[ $RAW -eq 1 ]]; then
      printf '%s' "$RESP" | jq -r '.ansi // ""'
    else
      printf '%s' "$RESP" | jq -r '.rows[]?'
    fi
    if [[ "$READY" == "true" ]]; then
      echo "[session] peek '$SLUG': ready=true"
    else
      echo "[session] peek '$SLUG': ready=false blocked_reason=${REASON:-unspecified}"
    fi
    exit 0
  fi
  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 0.3
done

# Clean up the unanswered request so it does not linger for a late consumer.
rm -f "$DEST"
fail "timed out after ${TIMEOUT}s waiting for peek response (request $REQUEST_ID)"
