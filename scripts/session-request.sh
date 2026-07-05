#!/usr/bin/env bash
# session-request.sh — Enqueue a session spawn request into _sessions/requests/pending/
#
# Usage:
#   lore session request --type <spec|implement|chat> [options]
#
# Options:
#   --type <t>         Required. Session type: spec | implement | chat.
#   --slug <s>         Work-item slug the request targets (default: null / no work item).
#   --target <name>    Instance name to address the request to (default: null / any instance).
#   --initiator <i>    Who initiated the request: agent | human (default: human).
#   --requested-by <w> Who enqueued it (default: $LORE_SESSION_INSTANCE, else $USER).
#   --context <t|file> Dispatch guidance handed to prompt composition. Value is read
#                      from a file when it names one, else treated as literal text. A
#                      JSON object is stored verbatim as extra_context; any other text
#                      is wrapped as {"dispatch_guidance": <text>}.
#   --kdir <path>      Knowledge-store override (test isolation).
#   --json             Emit a JSON result object instead of a human line.
#
# Prepare-and-return: writes one request file tmp+rename into requests/pending/ and
# emits a `requested` journal event through session-event-append.sh, then exits. It
# never spawns, waits, or touches the TUI. Field validation happens here at write
# time (non-zero exit naming the offending field); readers never re-validate.
#
# Exit codes: 0 success; 1 error/refused. Codes 2 and 3 are reserved (unused here)
# to keep the session verb family compatible with the composed-terminal-verb
# exit-code namespace. No child exit code is propagated verbatim.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TYPE=""
SLUG=""
TARGET=""
INITIATOR="human"
REQUESTED_BY=""
CONTEXT=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --initiator) INITIATOR="$2"; shift 2 ;;
    --requested-by) REQUESTED_BY="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-request.sh --type <spec|implement|chat> [--slug <s>] [--target <name>] [--initiator <agent|human>] [--requested-by <who>] [--context <text|file>] [--kdir <path>] [--json]" >&2
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

command -v jq &>/dev/null || fail "jq is required but not found on PATH"

# --- Validate required fields at write time (sole-writer discipline) ---
case "$TYPE" in
  spec|implement|chat) ;;
  "") fail "missing required field: --type (one of spec, implement, chat)" ;;
  *) fail "invalid --type: '$TYPE' (must be one of spec, implement, chat)" ;;
esac

case "$INITIATOR" in
  agent|human) ;;
  *) fail "invalid --initiator: '$INITIATOR' (must be one of agent, human)" ;;
esac

if [[ -z "$REQUESTED_BY" ]]; then
  REQUESTED_BY="${LORE_SESSION_INSTANCE:-${USER:-unknown}}"
fi

# --- Resolve extra_context (object verbatim, else wrapped guidance) ---
EXTRA_JSON="null"
if [[ -n "$CONTEXT" ]]; then
  CONTENT="$CONTEXT"
  if [[ -f "$CONTEXT" ]]; then
    CONTENT="$(cat "$CONTEXT")"
  fi
  if printf '%s' "$CONTENT" | jq -e 'type == "object"' >/dev/null 2>&1; then
    EXTRA_JSON="$(printf '%s' "$CONTENT" | jq -c '.')"
  else
    EXTRA_JSON="$(jq -n --arg g "$CONTENT" '{dispatch_guidance: $g}')"
  fi
fi

# Nullable string fields become explicit JSON null when unset.
SLUG_JSON="null"
[[ -n "$SLUG" ]] && SLUG_JSON="$(jq -n --arg s "$SLUG" '$s')"
TARGET_JSON="null"
[[ -n "$TARGET" ]] && TARGET_JSON="$(jq -n --arg t "$TARGET" '$t')"

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
mkdir -p "$PENDING_DIR"

RAND="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
REQUEST_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
REQUESTED_AT="$(timestamp_iso)"

# attempts MUST be a JSON number (--argjson), never a quoted string, so the Go
# decoder accepts it (docs/session-substrate.md, Type discipline).
ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg type "$TYPE" \
  --argjson slug "$SLUG_JSON" \
  --argjson target "$TARGET_JSON" \
  --arg initiator "$INITIATOR" \
  --arg requested_by "$REQUESTED_BY" \
  --arg requested_at "$REQUESTED_AT" \
  --argjson attempts 0 \
  --argjson extra "$EXTRA_JSON" \
  '{request_id: $request_id, type: $type, slug: $slug, target_instance: $target, initiator: $initiator, requested_by: $requested_by, requested_at: $requested_at, attempts: $attempts, extra_context: $extra, last_error: null, last_attempt_at: null}')"

# Enqueue = tmp-write + atomic rename-in. The tmp name is hidden and lacks the
# .json suffix, so a concurrent reader globbing *.json never sees a torn row.
TMP="$(mktemp "$PENDING_DIR/.tmp.${REQUEST_ID}.XXXXXX")"
printf '%s\n' "$ROW" > "$TMP"
DEST="$PENDING_DIR/${REQUEST_ID}.json"
mv "$TMP" "$DEST"

# --- Emit the `requested` event through the sole journal writer ---
# Built after the durable pending row lands. target_instance/slug follow
# omit-when-empty; actor_instance is absent (an enqueue via the CLI is not a TUI).
EVENT_ROW="$(jq -n \
  --arg request_id "$REQUEST_ID" \
  --arg session_type "$TYPE" \
  --arg initiator "$INITIATOR" \
  --argjson slug "$SLUG_JSON" \
  --argjson target "$TARGET_JSON" \
  '{event: "requested", request_id: $request_id, session_type: $session_type, initiator: $initiator}
   + (if $slug != null then {slug: $slug} else {} end)
   + (if $target != null then {target_instance: $target} else {} end)')"

if ! printf '%s' "$EVENT_ROW" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
  # The pending row is durable (the source of truth for liveness); a lost
  # history row is tolerated by the journal contract. Surface, do not fail.
  echo "[session] warning: requested event append failed for $REQUEST_ID (pending row is durable)" >&2
fi

RELPATH="${DEST#"$KNOWLEDGE_DIR"/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT="$(jq -n \
    --arg request_id "$REQUEST_ID" \
    --arg type "$TYPE" \
    --argjson slug "$SLUG_JSON" \
    --argjson target "$TARGET_JSON" \
    --arg path "$RELPATH" \
    '{request_id: $request_id, type: $type, slug: $slug, target_instance: $target, path: $path, enqueued: true}')"
  json_output "$RESULT"
fi

echo "[session] Enqueued $TYPE request $REQUEST_ID → $RELPATH"
