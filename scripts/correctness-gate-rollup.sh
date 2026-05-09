#!/usr/bin/env bash
# correctness-gate-rollup.sh — Roll up correctness-gate verdicts into scorecard rows
#
# Given a correctness-gate verdict batch (emitted by the gate agent for one
# artifact), compute the three canonical producer-scoring metrics and append
# one row per metric to $KDIR/_scorecards/rows.jsonl via scorecard-append.sh.
#
# Usage:
#   correctness-gate-rollup.sh \
#       --artifact-id <id> \
#       --producer-template-id <id> \
#       --producer-template-version <hash> \
#       --window-start <ISO-8601> \
#       --window-end <ISO-8601> \
#       [--calibration-state calibrated|pre-calibration|unknown] \
#       [--kdir <path>] \
#       [--verdicts <jsonl-path>]   # default: read JSONL on stdin
#
# Input: JSONL of correctness-gate verdicts, one per line, per the audit
# contract (architecture/audit-pipeline/contract.md):
#   {"judge":"correctness-gate","claim_id":"<id>",
#    "verdict":"verified|unverified|contradicted","evidence":"...",
#    "correction":"..."}
#
# Metrics emitted (all kind=scored, granularity=claim-local, attributed to
# the producer template):
#   factual_precision       = verified / total
#   falsifier_quality       = (verified + contradicted) / total
#     Rationale: both verified and contradicted verdicts demonstrate the
#     claim was falsifiable — the gate could adjudicate it. Unverified
#     means the gate could neither confirm nor deny, usually because the
#     claim was unfalsifiable as written.
#   audit_contradiction_rate = contradicted / total
#     Rationale: rate at which the gate overturned the producer's claim.
#     High contradiction rate = producer template writing claims the gate
#     can verifiably disprove.
#
# All three rows share the same sample_size (= total verdicts), same window,
# same source_artifact_ids ([artifact-id]), same producer template_id and
# template_version. calibration_state defaults to "pre-calibration" per the
# plan's calibration gate — only correctness-gate runs that pass the
# discrimination test (task-15) carry calibration_state=calibrated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARTIFACT_ID=""
PRODUCER_TEMPLATE_ID=""
PRODUCER_TEMPLATE_VERSION=""
WINDOW_START=""
WINDOW_END=""
CALIBRATION_STATE="pre-calibration"
KDIR_OVERRIDE=""
VERDICTS_PATH=""

usage() {
  sed -n '2,35p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-id)                 ARTIFACT_ID="$2";                shift 2 ;;
    --producer-template-id)        PRODUCER_TEMPLATE_ID="$2";       shift 2 ;;
    --producer-template-version)   PRODUCER_TEMPLATE_VERSION="$2";  shift 2 ;;
    --window-start)                WINDOW_START="$2";               shift 2 ;;
    --window-end)                  WINDOW_END="$2";                 shift 2 ;;
    --calibration-state)           CALIBRATION_STATE="$2";          shift 2 ;;
    --kdir)                        KDIR_OVERRIDE="$2";              shift 2 ;;
    --verdicts)                    VERDICTS_PATH="$2";              shift 2 ;;
    -h|--help)                     usage; exit 0 ;;
    *)
      echo "[rollup] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  echo "[rollup] Error: $1" >&2
  exit 1
}

[[ -n "$ARTIFACT_ID"               ]] || fail "--artifact-id is required"
[[ -n "$PRODUCER_TEMPLATE_ID"      ]] || fail "--producer-template-id is required"
[[ -n "$PRODUCER_TEMPLATE_VERSION" ]] || fail "--producer-template-version is required"
[[ -n "$WINDOW_START"              ]] || fail "--window-start is required"
[[ -n "$WINDOW_END"                ]] || fail "--window-end is required"

case "$CALIBRATION_STATE" in
  calibrated|pre-calibration|unknown) ;;
  *)
    fail "--calibration-state must be one of: calibrated, pre-calibration, unknown"
    ;;
esac

# --- Read verdicts ---
if [[ -n "$VERDICTS_PATH" ]]; then
  [[ -f "$VERDICTS_PATH" ]] || fail "verdicts file not found: $VERDICTS_PATH"
  VERDICTS_INPUT=$(cat "$VERDICTS_PATH")
else
  if [[ -t 0 ]]; then
    fail "no verdicts: pass --verdicts <path> or pipe JSONL on stdin"
  fi
  VERDICTS_INPUT=$(cat)
fi

if [[ -z "${VERDICTS_INPUT// }" ]]; then
  fail "verdicts input is empty"
fi

# --- Compute metrics via python ---
# Single pass over the JSONL: count verified, unverified, contradicted.
# Tolerate lines that aren't correctness-gate verdicts (a verdicts file
# may contain mixed-judge entries; filter in).
METRICS=$(printf '%s' "$VERDICTS_INPUT" | python3 -c '
import json, sys

verified = 0
unverified = 0
contradicted = 0
total = 0
bad_lines = 0

for i, line in enumerate(sys.stdin, start=1):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        bad_lines += 1
        continue
    if row.get("judge") != "correctness-gate":
        continue
    verdict = row.get("verdict")
    if verdict == "verified":
        verified += 1
    elif verdict == "unverified":
        unverified += 1
    elif verdict == "contradicted":
        contradicted += 1
    else:
        bad_lines += 1
        continue
    total += 1

if total == 0:
    sys.stderr.write("[rollup] Warning: no correctness-gate verdicts found\n")
    print(json.dumps({"total": 0, "verified": 0, "unverified": 0, "contradicted": 0, "bad_lines": bad_lines}))
    sys.exit(0)

print(json.dumps({
    "total": total,
    "verified": verified,
    "unverified": unverified,
    "contradicted": contradicted,
    "bad_lines": bad_lines,
    "factual_precision":        verified / total,
    "falsifier_quality":        (verified + contradicted) / total,
    "audit_contradiction_rate": contradicted / total,
}))
')

TOTAL=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "[rollup] No correctness-gate verdicts in input — no rows appended." >&2
  printf '%s\n' "$METRICS"
  exit 0
fi

# --- Emit one row per metric via scorecard-append.sh ---
KDIR_ARG=()
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR_ARG=(--kdir "$KDIR_OVERRIDE")
fi

register_template_version_if_possible() {
  local template_id="$1"
  local template_version="$2"
  local template_path=""
  [[ "$template_version" =~ ^[0-9a-f]{12}$ ]] || return 0
  if template_path=$(resolve_agent_template "$template_id" 2>/dev/null); then
    bash "$SCRIPT_DIR/template-registry-register.sh" "${KDIR_ARG[@]}" \
      --template-id "$template_id" \
      --template-version "$template_version" \
      --template-path "$template_path" \
      --description "correctness-gate rollup producer template" >/dev/null 2>&1 || true
  fi
}

register_template_version_if_possible "$PRODUCER_TEMPLATE_ID" "$PRODUCER_TEMPLATE_VERSION"

emit_row() {
  local metric="$1"
  local value="$2"
  local sample_size="$3"
  local row
  row=$(ARTIFACT_ID_ENV="$ARTIFACT_ID" \
        TEMPLATE_ID_ENV="$PRODUCER_TEMPLATE_ID" \
        TEMPLATE_VERSION_ENV="$PRODUCER_TEMPLATE_VERSION" \
        METRIC_ENV="$metric" \
        VALUE_ENV="$value" \
        SAMPLE_SIZE_ENV="$sample_size" \
        WINDOW_START_ENV="$WINDOW_START" \
        WINDOW_END_ENV="$WINDOW_END" \
        CALIBRATION_STATE_ENV="$CALIBRATION_STATE" \
        python3 -c '
import json, os
print(json.dumps({
    "schema_version":      "1",
    "kind":                "scored",
    "tier":                "template",
    "calibration_state":   os.environ["CALIBRATION_STATE_ENV"],
    "template_id":         os.environ["TEMPLATE_ID_ENV"],
    "template_version":    os.environ["TEMPLATE_VERSION_ENV"],
    "metric":              os.environ["METRIC_ENV"],
    "value":               float(os.environ["VALUE_ENV"]),
    "sample_size":         int(os.environ["SAMPLE_SIZE_ENV"]),
    "window_start":        os.environ["WINDOW_START_ENV"],
    "window_end":          os.environ["WINDOW_END_ENV"],
    "source_artifact_ids": [os.environ["ARTIFACT_ID_ENV"]],
    "granularity":         "claim-local",
}))
')
  "$SCRIPT_DIR/scorecard-append.sh" "${KDIR_ARG[@]}" --row "$row" >/dev/null
}

emit_correction_authorizations() {
  if [[ "$CALIBRATION_STATE" != "calibrated" ]]; then
    return 0
  fi
  printf '%s' "$VERDICTS_INPUT" | ARTIFACT_ID_ENV="$ARTIFACT_ID" \
    TEMPLATE_ID_ENV="$PRODUCER_TEMPLATE_ID" \
    TEMPLATE_VERSION_ENV="$PRODUCER_TEMPLATE_VERSION" \
    WINDOW_START_ENV="$WINDOW_START" \
    WINDOW_END_ENV="$WINDOW_END" \
    python3 -c '
import hashlib, json, os, re, sys
template_version = os.environ["TEMPLATE_VERSION_ENV"]
template_id = os.environ["TEMPLATE_ID_ENV"]
if not template_id or not re.match(r"^[0-9a-f]{12}$", template_version or ""):
    sys.exit(0)
artifact_id = os.environ["ARTIFACT_ID_ENV"]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        verdict = json.loads(line)
    except json.JSONDecodeError:
        continue
    if verdict.get("judge") != "correctness-gate":
        continue
    if verdict.get("verdict") != "contradicted" or not (verdict.get("correction") or "").strip():
        continue
    identity = {
        "artifact_id": artifact_id,
        "judge": verdict.get("judge") or "correctness-gate",
        "judge_template_version": verdict.get("judge_template_version") or "",
        "claim_id": verdict.get("claim_id"),
        "verdict": verdict.get("verdict"),
        "correction": verdict.get("correction") or "",
    }
    verdict_id = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:16]
    print(json.dumps({
        "schema_version": "1",
        "kind": "telemetry",
        "tier": "telemetry",
        "calibration_state": "calibrated",
        "template_id": template_id,
        "template_version": template_version,
        "metric": "correction_authorization",
        "value": 1,
        "sample_size": 1,
        "window_start": os.environ["WINDOW_START_ENV"],
        "window_end": os.environ["WINDOW_END_ENV"],
        "source_artifact_ids": [artifact_id],
        "granularity": "claim-local",
        "verdict_source": "correctness-gate",
        "claim_id": verdict.get("claim_id"),
        "verdict_id": verdict_id,
    }))
' | while IFS= read -r auth_row; do
    [[ -n "$auth_row" ]] || continue
    "$SCRIPT_DIR/scorecard-append.sh" "${KDIR_ARG[@]}" --row "$auth_row" >/dev/null
  done
}

FACTUAL_PRECISION=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["factual_precision"])')
FALSIFIER_QUALITY=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["falsifier_quality"])')
CONTRADICTION_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audit_contradiction_rate"])')

emit_row "factual_precision"        "$FACTUAL_PRECISION"  "$TOTAL"
emit_row "falsifier_quality"        "$FALSIFIER_QUALITY"  "$TOTAL"
emit_row "audit_contradiction_rate" "$CONTRADICTION_RATE" "$TOTAL"
emit_correction_authorizations

echo "[rollup] Appended 3 rows: factual_precision=$FACTUAL_PRECISION falsifier_quality=$FALSIFIER_QUALITY audit_contradiction_rate=$CONTRADICTION_RATE (n=$TOTAL)"
printf '%s\n' "$METRICS"
