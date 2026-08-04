#!/usr/bin/env bash
# ceremony-handle.sh — Record the handled transition for a ceremony outcome.
#
# Usage:
#   ceremony-handle.sh --outcome-id <id> \
#     --action <adjudicated|deferred|skipped> --handled-by <actor> \
#     [--kdir <path>] [--json]
#
# A ceremony that files a needs-decision outcome leaves an obligation on the
# coordination board. This verb closes it: it reads the correlated outcome row,
# builds the transition, and delegates the only physical write to
# scorecard-append.sh, which owns validation, correlation, and idempotence.
# Repeating the same call is a no-op; a different action or actor for the same
# outcome is refused there, not inferred here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

OUTCOME_ID=""
ACTION=""
HANDLED_BY=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  sed -n '2,15p' "$0" >&2
}

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

require_value() {
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a non-empty value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outcome-id) require_value --outcome-id "${2:-}"; OUTCOME_ID="$2"; shift 2 ;;
    --outcome-id=*) OUTCOME_ID="${1#--outcome-id=}"; shift ;;
    --action) require_value --action "${2:-}"; ACTION="$2"; shift 2 ;;
    --action=*) ACTION="${1#--action=}"; shift ;;
    --handled-by) require_value --handled-by "${2:-}"; HANDLED_BY="$2"; shift 2 ;;
    --handled-by=*) HANDLED_BY="${1#--handled-by=}"; shift ;;
    --kdir) require_value --kdir "${2:-}"; KDIR_OVERRIDE="$2"; shift 2 ;;
    --kdir=*) KDIR_OVERRIDE="${1#--kdir=}"; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ -n "$OUTCOME_ID" ]] || fail "--outcome-id is required"
[[ -n "$ACTION" ]] || fail "--action is required"
[[ -n "$HANDLED_BY" ]] || fail "--handled-by is required"
case "$ACTION" in
  adjudicated|deferred|skipped) ;;
  *) fail "--action must be 'adjudicated', 'deferred', or 'skipped' (got '$ACTION')" ;;
esac

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

ROWS_FILE="$KNOWLEDGE_DIR/_scorecards/rows.jsonl"
[[ -f "$ROWS_FILE" ]] || fail "no scorecard rows to handle at ${ROWS_FILE#"$KNOWLEDGE_DIR"/}"

# The outcome row is the source of the transition's identity fields. Copying
# them here keeps every reader that filters on ceremony or work item seeing the
# transition alongside what it handles; the appender rejects any copy that
# disagrees with the row it names.
SOURCE=$(jq -c --arg id "$OUTCOME_ID" '
  select(.event_type == "ceremony-resolution")
  | select(.outcome_id == $id)
  | select((.record_type // "outcome") == "outcome")
' "$ROWS_FILE" | tail -n 1)
[[ -n "$SOURCE" ]] || fail "no ceremony-resolution outcome row carries outcome_id '$OUTCOME_ID'"

HANDLED_AT=$(timestamp_iso)
ROW=$(jq -cn \
  --argjson source "$SOURCE" \
  --arg outcome_id "$OUTCOME_ID" \
  --arg action "$ACTION" \
  --arg handled_by "$HANDLED_BY" \
  --arg handled_at "$HANDLED_AT" '
  {
    schema_version: "1",
    kind: "telemetry",
    tier: "telemetry",
    calibration_state: "unknown",
    event_type: "ceremony-resolution",
    metric: "ceremony_resolution_outcome",
    record_type: "disposition",
    outcome: "needs-decision",
    disposition: "handled",
    outcome_id: $outcome_id,
    ceremony: $source.ceremony,
    advisor: $source.advisor,
    action: $action,
    handled_by: $handled_by,
    handled_at: $handled_at,
    timestamp: $handled_at,
    source_artifact_ids: ($source.source_artifact_ids // [])
  }
  + (if ($source | has("work_item")) then {work_item: $source.work_item} else {} end)
')

if [[ $JSON_MODE -eq 1 ]]; then
  exec bash "$SCRIPT_DIR/scorecard-append.sh" --row "$ROW" --kdir "$KNOWLEDGE_DIR" --json
fi

# Human output is rendered from the appender's machine surface rather than its
# prose, so the two never drift.
set +e
APPEND_OUTPUT=$(bash "$SCRIPT_DIR/scorecard-append.sh" --row "$ROW" --kdir "$KNOWLEDGE_DIR" --json 2>&1)
APPEND_RC=$?
set -e
if [[ $APPEND_RC -ne 0 ]]; then
  APPEND_ERROR=$(printf '%s' "$APPEND_OUTPUT" | jq -r '.error // empty' 2>/dev/null || true)
  fail "${APPEND_ERROR:-$APPEND_OUTPUT}"
fi

if [[ "$(printf '%s' "$APPEND_OUTPUT" | jq -r '.idempotent // false')" == "true" ]]; then
  echo "[ceremony handle] Outcome $OUTCOME_ID is already handled (action=$ACTION handled_by=$HANDLED_BY) — no row appended"
else
  echo "[ceremony handle] Handled outcome $OUTCOME_ID (action=$ACTION handled_by=$HANDLED_BY)"
fi
