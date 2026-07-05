#!/usr/bin/env bash
# session-send.sh — Inject a message into a live TUI-hosted session's composer.
#
# Usage:
#   lore session send <slug> <message> [--wait] [--timeout <sec>] [options]
#
# Options:
#   --message <text>   Message body (alternative to the positional form).
#   --wait             Block until the send is answered, mapping the outcome to
#                      an exit code (see below). Without it, enqueue and exit 0.
#   --timeout <sec>    --wait poll budget (default: 15).
#   --requested-by <w> Who requested it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --ttl <seconds>    Instance liveness TTL for slug resolution (default: 30).
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object instead of a human line.
#
# A send enqueues _sessions/send-requests/<request_id>.json (tmp + atomic rename)
# for the one live instance running <slug> — resolved by the same registry walk
# session-close.sh uses. That instance consumes the row on its poll tick, runs
# the strict readiness gate (session idle at its composer AND no permission
# modal), and pastes+submits the message. Otherwise it refuses (send_refused with
# a reason) and no bytes reach the PTY. The message is always pasted via bracketed
# paste, never written raw. See docs/session-substrate.md.
#
# Exit codes:
#   0  message sent (or, without --wait, request enqueued)
#   1  error (bad args, no live instance, enqueue failure, or --wait timeout)
#   2  reserved (session verb family / composed-terminal-verb namespace)
#   3  send refused by the readiness gate (--wait only; reason on stderr/JSON)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

SLUG_ARG=""
MESSAGE=""
MESSAGE_SET=0
WAIT=0
TIMEOUT=15
REQUESTED_BY=""
TTL=30
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message) MESSAGE="$2"; MESSAGE_SET=1; shift 2 ;;
    --wait) WAIT=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    --*)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-send.sh <slug> <message> [--wait] [--timeout <sec>] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$SLUG_ARG" ]]; then
        SLUG_ARG="$1"
      elif [[ $MESSAGE_SET -eq 0 ]]; then
        MESSAGE="$1"; MESSAGE_SET=1
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
[[ $MESSAGE_SET -eq 1 ]] || fail "no message: pass a <message> or --message <text>"
[[ -n "$MESSAGE" ]] || fail "message is empty"

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

emit_event() {
  local row="$1"
  if ! printf '%s' "$row" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
    echo "[session] warning: event append failed (substrate change is durable)" >&2
  fi
}

# --- Resolve the owning live instance ---
SLUG="$SLUG_ARG"
TARGET_INSTANCE="$(resolve_session_owner "$SESSIONS_DIR/instances" "$SLUG" "$TTL")"
[[ -n "$TARGET_INSTANCE" ]] || fail "no live instance is running session '$SLUG'"

# --- Enqueue: tmp-write + rename into send-requests/ ---
SEND_DIR="$SESSIONS_DIR/send-requests"
mkdir -p "$SEND_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg target "$TARGET_INSTANCE" \
  --arg body "$MESSAGE" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  '{request_id: $request_id, slug: $slug, target_instance: $target, body: $body, requested_by: $requested_by, requested_at: $requested_at}')"

TMP="$(mktemp "$SEND_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$SEND_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

# --- Emit send_requested through the sole journal writer ---
EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg target "$TARGET_INSTANCE" \
  '{event: "send_requested", request_id: $request_id, slug: $slug, target_instance: $target}')"
emit_event "$EVENT_ROW"

RELPATH="${DEST#"$KNOWLEDGE_DIR"/}"

# --- Without --wait: enqueue-and-exit-0 ---
if [[ $WAIT -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg request_id "$REQUEST_ID" --arg slug "$SLUG" --arg target "$TARGET_INSTANCE" --arg path "$RELPATH" \
      '{request_id: $request_id, slug: $slug, target_instance: $target, path: $path, enqueued: true}')"
  fi
  echo "[session] Enqueued send to '$SLUG' on instance $TARGET_INSTANCE → $RELPATH"
  exit 0
fi

# --- With --wait: poll the journal for this request's sent / send_refused ---
# Matched by request_id (unique), so per-slug ordering is satisfied without
# scanning for adjacency. json_output/json_error hard-exit 0/1, so the refusal
# terminal (exit 3) prints its JSON manually.
EVENTS_FILE="$SESSIONS_DIR/events.jsonl"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  if [[ -f "$EVENTS_FILE" ]]; then
    OUTCOME="$(jq -rj --arg rid "$REQUEST_ID" \
      'select(.request_id == $rid and (.event == "sent" or .event == "send_refused"))
       | .event + "	" + (.reason // "") + "\n"' \
      "$EVENTS_FILE" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$OUTCOME" ]]; then
      EV="${OUTCOME%%$'\t'*}"
      RSN="${OUTCOME#*$'\t'}"
      if [[ "$EV" == "sent" ]]; then
        if [[ $JSON_MODE -eq 1 ]]; then
          json_output "$(jq -n --arg request_id "$REQUEST_ID" --arg slug "$SLUG" \
            '{request_id: $request_id, slug: $slug, sent: true}')"
        fi
        echo "[session] Sent to '$SLUG' (request $REQUEST_ID)"
        exit 0
      else
        if [[ $JSON_MODE -eq 1 ]]; then
          printf '%s\n' "$(jq -n --arg request_id "$REQUEST_ID" --arg slug "$SLUG" --arg reason "$RSN" \
            '{request_id: $request_id, slug: $slug, sent: false, refused: true, reason: $reason}')"
        fi
        echo "[session] Refused send to '$SLUG' (reason=${RSN:-unspecified}, request $REQUEST_ID)" >&2
        exit 3
      fi
    fi
  fi
  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 0.3
done

fail "timed out after ${TIMEOUT}s waiting for send outcome (request $REQUEST_ID); it may still be delivered"
