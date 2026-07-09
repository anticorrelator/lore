#!/usr/bin/env bash
# ceremony-outcome-record.sh — Record an unresolvable ceremony advisor.
#
# Usage:
#   ceremony-outcome-record.sh --ceremony <id> --advisor <name> --harness <name> \
#     --reason <text> [--work-item <slug>] [--kdir <path>]
#
# The scorecard event and optional work-item log entry are independent,
# best-effort writes. Once the input is valid, recording failures warn but do
# not make ceremony resolution fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CEREMONY=""
ADVISOR=""
HARNESS=""
REASON=""
WORK_ITEM=""
KDIR_OVERRIDE=""

usage() {
  sed -n '2,10p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ceremony) CEREMONY="${2:-}"; shift 2 ;;
    --advisor) ADVISOR="${2:-}"; shift 2 ;;
    --harness) HARNESS="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --work-item) WORK_ITEM="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[ceremony-outcome] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

for required in CEREMONY ADVISOR HARNESS REASON; do
  if [[ -z "${!required}" ]]; then
    flag="$(printf '%s' "$required" | tr '[:upper:]_' '[:lower:]-')"
    echo "[ceremony-outcome] Error: --$flag is required" >&2
    exit 1
  fi
done

TIMESTAMP=$(timestamp_iso)
CORRECTIVE_ACTION="Run the advisor on a harness where it is registered before consuming the artifact, or update the ceremony binding."

ROW=$(jq -cn \
  --arg ceremony "$CEREMONY" \
  --arg advisor "$ADVISOR" \
  --arg harness "$HARNESS" \
  --arg reason "$REASON" \
  --arg work_item "$WORK_ITEM" \
  --arg timestamp "$TIMESTAMP" \
  --arg corrective_action "$CORRECTIVE_ACTION" '
  {
    schema_version: "1",
    kind: "telemetry",
    tier: "telemetry",
    calibration_state: "unknown",
    event_type: "ceremony-resolution",
    metric: "ceremony_resolution_outcome",
    outcome: "needs-decision",
    disposition: "unhandled",
    ceremony: $ceremony,
    advisor: $advisor,
    harness: $harness,
    reason: $reason,
    corrective_action: $corrective_action,
    timestamp: $timestamp,
    source_artifact_ids: (if $work_item == "" then [] else [$work_item] end)
  }
  + if $work_item == "" then {} else {work_item: $work_item} end
')

APPEND_ARGS=(--row "$ROW")
if [[ -n "$KDIR_OVERRIDE" ]]; then
  APPEND_ARGS+=(--kdir "$KDIR_OVERRIDE")
fi
if ! bash "$SCRIPT_DIR/scorecard-append.sh" "${APPEND_ARGS[@]}" >/dev/null; then
  echo "[ceremony-outcome] Warning: scorecard outcome write failed; ceremony resolution continues." >&2
fi

if [[ -n "$WORK_ITEM" ]]; then
  if ! printf 'Ceremony resolution: needs-decision\nCeremony: %s\nAdvisor: %s\nHarness: %s\nOutcome: needs-decision\nDisposition: unhandled\nReason: %s\nCorrective action: %s\n' \
    "$CEREMONY" "$ADVISOR" "$HARNESS" "$REASON" "$CORRECTIVE_ACTION" \
    | bash "$SCRIPT_DIR/write-execution-log.sh" --slug "$WORK_ITEM" --source ceremony >/dev/null; then
    echo "[ceremony-outcome] Warning: work-item execution-log write failed; ceremony resolution continues." >&2
  fi
fi

exit 0
