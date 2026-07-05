#!/usr/bin/env bash
# session-close.sh — Request teardown of a live session, or cancel a pending spawn
#
# Usage:
#   lore session close <slug>            Close the live session running <slug>
#   lore session close --self            Close the session named by LORE_SESSION_* env
#   lore session close --request <id>    Cancel a pending (unclaimed) spawn request
#
# Options:
#   --reason <r>       Close reason: protocol_terminus | coordinator | human
#                      (default: human). Ignored by the --request cancel form.
#   --requested-by <w> Who requested it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --ttl <seconds>    Instance liveness TTL for slug resolution (default: 30).
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object instead of a human line.
#
# The close and cancel surfaces are distinct on purpose (docs/session-substrate.md,
# D2): a close-request is a per-owner file in close-requests/ consumed (deleted) by
# the one live instance that runs the slug — there is no claim race, so no
# pending/claimed split. The cancel form instead deletes a still-pending spawn row
# in requests/pending/. The slug and --self forms are argument-resolution fronts
# over one physical enqueue path (enqueue_close_request); each form's write is
# tmp+rename and each emits its event through session-event-append.sh.
#
# Exit codes: 0 success; 1 error/refused. Codes 2 and 3 are reserved (unused here)
# for session verb family / composed-terminal-verb namespace compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SLUG_ARG=""
SELF=0
CANCEL_ID=""
REASON="human"
REQUESTED_BY=""
TTL=30
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self) SELF=1; shift ;;
    --request) CANCEL_ID="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    --*)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-close.sh (<slug> | --self | --request <id>) [--reason <r>] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
    *)
      if [[ -n "$SLUG_ARG" ]]; then
        echo "Unexpected extra argument: $1" >&2
        exit 1
      fi
      SLUG_ARG="$1"; shift
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

# --- Exactly one form must be selected ---
FORMS=0
[[ -n "$SLUG_ARG" ]] && FORMS=$((FORMS + 1))
[[ $SELF -eq 1 ]] && FORMS=$((FORMS + 1))
[[ -n "$CANCEL_ID" ]] && FORMS=$((FORMS + 1))
if [[ $FORMS -eq 0 ]]; then
  fail "no target: pass a <slug>, --self, or --request <id>"
elif [[ $FORMS -gt 1 ]]; then
  fail "ambiguous: pass exactly one of <slug>, --self, or --request <id>"
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
  # Route every event through the sole journal writer. A failed append is
  # surfaced but does not fail the command — the durable substrate change
  # (the close-request file, or the pending-row deletion) already succeeded.
  local row="$1"
  if ! printf '%s' "$row" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
    echo "[session] warning: event append failed (substrate change is durable)" >&2
  fi
}

# --- Cancel form: delete a pending spawn row, emit request_cancelled ---
if [[ -n "$CANCEL_ID" ]]; then
  PENDING_FILE="$SESSIONS_DIR/requests/pending/${CANCEL_ID}.json"
  [[ -f "$PENDING_FILE" ]] || fail "no pending request '$CANCEL_ID' to cancel"

  # Copy identifying fields for the event before deleting (tolerant read).
  C_SLUG="$(jq -r '.slug // empty' "$PENDING_FILE" 2>/dev/null || true)"
  C_TYPE="$(jq -r '.type // empty' "$PENDING_FILE" 2>/dev/null || true)"
  C_TARGET="$(jq -r '.target_instance // empty' "$PENDING_FILE" 2>/dev/null || true)"

  rm -f "$PENDING_FILE"

  EVENT_ROW="$(jq -n \
    --arg request_id "$CANCEL_ID" \
    --arg slug "$C_SLUG" \
    --arg session_type "$C_TYPE" \
    --arg target "$C_TARGET" \
    --arg reason "cancelled" \
    '{event: "request_cancelled", request_id: $request_id, reason: $reason}
     + (if $slug != "" then {slug: $slug} else {} end)
     + (if $session_type != "" then {session_type: $session_type} else {} end)
     + (if $target != "" then {target_instance: $target} else {} end)')"
  emit_event "$EVENT_ROW"

  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n --arg request_id "$CANCEL_ID" '{request_id: $request_id, cancelled: true}')"
  fi
  echo "[session] Cancelled pending request $CANCEL_ID"
  exit 0
fi

# --- Validate close reason for the enqueue forms ---
case "$REASON" in
  protocol_terminus|coordinator|human) ;;
  *) fail "invalid --reason: '$REASON' (must be one of protocol_terminus, coordinator, human)" ;;
esac

# --- Resolve (slug, target_instance) for the two enqueue fronts ---
TARGET_INSTANCE=""
SLUG=""
ACTOR_INSTANCE=""

if [[ $SELF -eq 1 ]]; then
  # Self-address from the running session's env (D3). No registry lookup — the
  # session addresses its own owning instance directly.
  TARGET_INSTANCE="${LORE_SESSION_INSTANCE:-}"
  [[ -n "$TARGET_INSTANCE" ]] || fail "--self requires LORE_SESSION_INSTANCE (not inside a lore session)"
  SLUG="${LORE_SESSION_SLUG:-}"
  ACTOR_INSTANCE="$TARGET_INSTANCE"
else
  # Slug form: the owning live instance is the one whose registry row hosts the
  # slug. Exactly one live instance is eligible; a missing one is a clear error.
  SLUG="$SLUG_ARG"
  command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"
  TARGET_INSTANCE="$(python3 - "$SESSIONS_DIR/instances" "$SLUG" "$TTL" <<'PYEOF'
import json, os, sys, time

instances_dir, slug, ttl = sys.argv[1], sys.argv[2], float(sys.argv[3])
now = time.time()
if os.path.isdir(instances_dir):
    for name in sorted(os.listdir(instances_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(instances_dir, name)
        try:
            if (now - os.path.getmtime(path)) > ttl:
                continue
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError):
            continue
        for sess in row.get("sessions") or []:
            if sess.get("slug") == slug:
                print(row.get("name", ""))
                sys.exit(0)
PYEOF
)"
  [[ -n "$TARGET_INSTANCE" ]] || fail "no live instance is running session '$SLUG'"
fi

# --- One physical enqueue path: tmp-write + rename into close-requests/ ---
CLOSE_DIR="$SESSIONS_DIR/close-requests"
mkdir -p "$CLOSE_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

SLUG_JSON="null"
[[ -n "$SLUG" ]] && SLUG_JSON="$(jq -n --arg s "$SLUG" '$s')"

ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --argjson slug "$SLUG_JSON" \
  --arg target "$TARGET_INSTANCE" \
  --arg reason "$REASON" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  '{request_id: $request_id, slug: $slug, target_instance: $target, reason: $reason, requested_by: $requested_by, requested_at: $requested_at}')"

TMP="$(mktemp "$CLOSE_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$CLOSE_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

# --- Emit close_requested through the sole journal writer ---
EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --argjson slug "$SLUG_JSON" \
  --arg target "$TARGET_INSTANCE" \
  --arg reason "$REASON" \
  --arg actor "$ACTOR_INSTANCE" \
  '{event: "close_requested", request_id: $request_id, target_instance: $target, reason: $reason}
   + (if $slug != null then {slug: $slug} else {} end)
   + (if $actor != "" then {actor_instance: $actor} else {} end)')"
emit_event "$EVENT_ROW"

RELPATH="${DEST#"$KNOWLEDGE_DIR"/}"

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg request_id "$REQUEST_ID" \
    --argjson slug "$SLUG_JSON" \
    --arg target "$TARGET_INSTANCE" \
    --arg reason "$REASON" \
    --arg path "$RELPATH" \
    '{request_id: $request_id, slug: $slug, target_instance: $target, reason: $reason, path: $path, enqueued: true}')"
fi

echo "[session] Requested close of '$SLUG' on instance $TARGET_INSTANCE (reason=$REASON) → $RELPATH"
