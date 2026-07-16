#!/usr/bin/env bash
# session-answer.sh — Select a numbered option on a live harness modal.
#
# Usage:
#   lore session answer <slug> --option <N> --expect <literal> [options]
#
# Options:
#   --option <N>       Displayed positive option number to select (required).
#   --expect <literal> Literal text that must still be visible in the modal (required).
#   --wait             Block until the answer is verified or refused.
#   --timeout <sec>    --wait poll budget (default: 15).
#   --requested-by <w> Requester identity (default: session instance, else user).
#   --ttl <seconds>    Instance liveness TTL for slug resolution (default: 30).
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object.
#
# The owning TUI consumes the request only when its shared screen classifier
# proves a numbered modal, the expectation is still visible, and both the
# selected and requested options are present. It writes one relative Up/Down
# sequence followed by Enter, then reports success only after a later screen no
# longer contains the expectation.
#
# Exit codes:
#   0  answer verified (or, without --wait, request enqueued)
#   1  error or wait timeout
#   2  reserved for the session verb family
#   3  answer refused (--wait only; reason on stderr/JSON)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

SLUG=""
OPTION=""
EXPECT=""
WAIT=0
TIMEOUT=15
REQUESTED_BY=""
TTL=30
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --option) OPTION="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --requested-by) REQUESTED_BY="${2:-}"; shift 2 ;;
    --ttl) TTL="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    --*) echo "Unknown argument: $1" >&2; exit 1 ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
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

[[ -n "$SLUG" ]] || fail "no target: pass a <slug>"
[[ -n "$OPTION" ]] || fail "missing required argument: --option <N>"
[[ "$OPTION" =~ ^[1-9][0-9]*$ ]] || fail "invalid --option: '$OPTION' (must be a positive integer)"
[[ -n "$EXPECT" ]] || fail "missing required argument: --expect <literal>"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || fail "invalid --timeout: '$TIMEOUT' (must be a non-negative integer)"
[[ "$TTL" =~ ^[0-9]+$ ]] || fail "invalid --ttl: '$TTL' (must be a non-negative integer)"

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
TARGET_INSTANCE="$(resolve_session_owner "$SESSIONS_DIR/instances" "$SLUG" "$TTL")"
[[ -n "$TARGET_INSTANCE" ]] || fail "no live instance is running session '$SLUG'"

ANSWER_DIR="$SESSIONS_DIR/answer-requests"
mkdir -p "$ANSWER_DIR"
RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg target "$TARGET_INSTANCE" \
  --argjson option "$OPTION" \
  --arg expect "$EXPECT" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  '{request_id:$request_id,slug:$slug,target_instance:$target,option:$option,expect:$expect,requested_by:$requested_by,requested_at:$requested_at}')"

TMP="$(mktemp "$ANSWER_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$ANSWER_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" --arg slug "$SLUG" --arg target "$TARGET_INSTANCE" \
  --argjson option "$OPTION" \
  '{event:"answer_requested",request_id:$request_id,slug:$slug,target_instance:$target,option:$option}')"
if ! printf '%s' "$EVENT_ROW" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
  echo "[session] warning: event append failed (answer request is durable)" >&2
fi

RELPATH="${DEST#"$KNOWLEDGE_DIR"/}"
if [[ $WAIT -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n --arg request_id "$REQUEST_ID" --arg slug "$SLUG" \
      --arg target "$TARGET_INSTANCE" --arg path "$RELPATH" --argjson option "$OPTION" \
      '{request_id:$request_id,slug:$slug,target_instance:$target,option:$option,path:$path,enqueued:true}')"
  fi
  echo "[session] Enqueued option $OPTION for '$SLUG' on instance $TARGET_INSTANCE → $RELPATH"
  exit 0
fi

EVENTS_FILE="$SESSIONS_DIR/events.jsonl"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  if [[ -f "$EVENTS_FILE" ]]; then
    OUTCOME="$(jq -rj --arg rid "$REQUEST_ID" \
      'select(.request_id == $rid and (.event == "answered" or .event == "answer_refused"))
       | .event + "\t" + (.reason // "") + "\n"' "$EVENTS_FILE" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$OUTCOME" ]]; then
      EVENT="${OUTCOME%%$'\t'*}"
      REASON="${OUTCOME#*$'\t'}"
      if [[ "$EVENT" == "answered" ]]; then
        if [[ $JSON_MODE -eq 1 ]]; then
          json_output "$(jq -n --arg request_id "$REQUEST_ID" --arg slug "$SLUG" --argjson option "$OPTION" \
            '{request_id:$request_id,slug:$slug,option:$option,answered:true}')"
        fi
        echo "[session] Answered '$SLUG' with option $OPTION (request $REQUEST_ID)"
        exit 0
      fi
      if [[ $JSON_MODE -eq 1 ]]; then
        printf '%s\n' "$(jq -n --arg request_id "$REQUEST_ID" --arg slug "$SLUG" \
          --arg reason "$REASON" --argjson option "$OPTION" \
          '{request_id:$request_id,slug:$slug,option:$option,answered:false,refused:true,reason:$reason}')"
      fi
      echo "[session] Refused answer for '$SLUG' (reason=${REASON:-unspecified}, request $REQUEST_ID)" >&2
      exit 3
    fi
  fi
  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 0.3
done

fail "timed out after ${TIMEOUT}s waiting for answer outcome (request $REQUEST_ID); it may still complete"
