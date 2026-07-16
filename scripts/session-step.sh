#!/usr/bin/env bash
# session-step.sh — Emit one idempotent hosted-protocol progress event
#
# Usage:
#   bash session-step.sh --step-id <stable-id> --step-label <label> [--kdir <path>] [--json]
#
# The live registry supplies the spawn request identity used only to construct
# the deterministic event id. The emitted row is a protocol transition, not a
# queue lifecycle row, so it carries no top-level request_id. Every append is
# delegated to session-event-append.sh, the sole physical journal writer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

STEP_ID=""
STEP_LABEL=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --step-id) STEP_ID="$2"; shift 2 ;;
    --step-label) STEP_LABEL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$STEP_ID" ]] || die "--step-id is required"
[[ -n "$STEP_LABEL" ]] || die "--step-label is required"

INSTANCE="${LORE_SESSION_INSTANCE:-}"
SLUG="${LORE_SESSION_SLUG:-}"
SESSION_TYPE="${LORE_SESSION_TYPE:-}"
[[ -n "$INSTANCE" ]] || die "LORE_SESSION_INSTANCE is required"
[[ -n "$SLUG" ]] || die "LORE_SESSION_SLUG is required"
[[ -n "$SESSION_TYPE" ]] || die "LORE_SESSION_TYPE is required"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || die "knowledge store not found at: $KNOWLEDGE_DIR"

REGISTRY="$KNOWLEDGE_DIR/_sessions/instances/$INSTANCE.json"
[[ -f "$REGISTRY" ]] || die "live session registry not found for instance '$INSTANCE'"

SPAWN_REQUEST_ID="$(jq -er \
  --arg instance "$INSTANCE" --arg slug "$SLUG" --arg type "$SESSION_TYPE" '
    select(.name == $instance)
    | [.sessions[] | select(.slug == $slug and .type == $type) | .request_id]
    | if length == 1 and .[0] != "" then .[0] else error("no unique persisted spawn request") end
  ' "$REGISTRY" 2>/dev/null)" || die "no unique persisted spawn request for '$SESSION_TYPE:$SLUG' on '$INSTANCE'"

EVENT_ID="step-$(python3 - "$INSTANCE" "$SLUG" "$SESSION_TYPE" "$SPAWN_REQUEST_ID" "$STEP_ID" <<'PY'
import hashlib, sys
parts = ["step_completed", *sys.argv[1:]]
print(hashlib.sha256("\0".join(parts).encode()).hexdigest())
PY
)"

ROW="$(jq -n \
  --arg event_id "$EVENT_ID" \
  --arg actor "$INSTANCE" \
  --arg slug "$SLUG" \
  --arg session_type "$SESSION_TYPE" \
  --arg step_id "$STEP_ID" \
  --arg step_label "$STEP_LABEL" \
  '{event_id: $event_id, event: "step_completed", actor_instance: $actor,
    slug: $slug, session_type: $session_type, step_id: $step_id,
    step_label: $step_label}')"

ARGS=(--kdir "$KNOWLEDGE_DIR")
[[ $JSON_MODE -eq 1 ]] && ARGS+=(--json)
printf '%s' "$ROW" | bash "$SCRIPT_DIR/session-event-append.sh" "${ARGS[@]}"
