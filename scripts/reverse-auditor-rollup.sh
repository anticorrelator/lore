#!/usr/bin/env bash
# reverse-auditor-rollup.sh — Roll up reverse-auditor outcomes into scorecard rows
#
# Given a reverse-auditor outcome set for one artifact, compute the three
# canonical metrics per the plan's Phase 4 specification and append one row
# per metric to $KDIR/_scorecards/rows.jsonl via scorecard-append.sh.
#
# Usage:
#   reverse-auditor-rollup.sh \
#       --artifact-id <id> \
#       --producer-template-id <id> \
#       --producer-template-version <hash> \
#       --curator-template-id <id> \
#       --curator-template-version <hash> \
#       --reverse-auditor-template-id <id> \
#       --reverse-auditor-template-version <hash> \
#       --window-start <ISO-8601> \
#       --window-end <ISO-8601> \
#       [--calibration-state calibrated|pre-calibration|unknown] \
#       [--kdir <path>] \
#       [--verdicts <jsonl-path>]   # default: read JSONL on stdin
#
# Input: JSONL of verdicts from settlement-record-append.sh. Reverse-auditor
# lines look like:
#   {"judge":"reverse-auditor","claim_id":"<id>",
#    "verdict":"omission-claim|silence|preflight-failed",
#    ...artifact-scoped metadata}
#
# Per-artifact metric derivation:
#   Each artifact gets exactly one reverse-auditor emission, so total=1 in
#   the single-artifact case. Three verdict values:
#     - "omission-claim" : preflight passed and the claim reached the
#                          candidate queue. For `omission_rate` this counts
#                          as an omission surfaced (value=1.0, sample=1).
#                          Downstream /retro aggregates across artifacts.
#     - "silence"        : reverse-auditor emitted ∅; nothing to audit.
#                          Omission rate contribution: 0 (no omission).
#     - "preflight-failed" : reverse-auditor emitted a claim but the
#                          grounding-preflight.py verdict was fail.
#                          Contribution to `grounding_failure_rate`: 1.
#
# Metrics emitted:
#   omission_rate         (producer template,        kind=scored,
#                          granularity=portfolio-level)
#     Fraction of audited artifacts where the reverse-auditor surfaced a
#     grounded omission the correctness-gate later verified. High value =
#     producer template has systematic coverage gaps.
#
#   coverage_quality      (curator template,         kind=scored,
#                          granularity=portfolio-level)
#     Per the plan: `coverage_quality = 1 - omission_rate` (against the
#     curator). Interpretation: if the reverse-auditor is finding grounded
#     omissions, the curator's top-k selection missed them — coverage is
#     poor.
#
#   grounding_failure_rate (reverse-auditor template, kind=telemetry,
#                           granularity=portfolio-level)
#     Fraction of reverse-auditor emissions that failed grounding
#     preflight. Diagnostic-only per plan: telemetry-kind rows never drive
#     /evolve template mutation; they surface in /retro prose when
#     elevated. Scored complement of this *is* the correctness-gate's
#     audit_contradiction_rate (adjudicative misreads on claims that
#     passed preflight).
#
# Sole-writer parallel to correctness-gate-rollup.sh (task-14) and
# curator-rollup.sh (task-18). All three rollups funnel through
# scorecard-append.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARTIFACT_ID=""
PRODUCER_TEMPLATE_ID=""
PRODUCER_TEMPLATE_VERSION=""
CURATOR_TEMPLATE_ID=""
CURATOR_TEMPLATE_VERSION=""
REVERSE_AUDITOR_TEMPLATE_ID=""
REVERSE_AUDITOR_TEMPLATE_VERSION=""
WINDOW_START=""
WINDOW_END=""
CALIBRATION_STATE="pre-calibration"
KDIR_OVERRIDE=""
VERDICTS_PATH=""

usage() {
  sed -n '2,60p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact-id)                      ARTIFACT_ID="$2";                     shift 2 ;;
    --producer-template-id)             PRODUCER_TEMPLATE_ID="$2";            shift 2 ;;
    --producer-template-version)        PRODUCER_TEMPLATE_VERSION="$2";       shift 2 ;;
    --curator-template-id)              CURATOR_TEMPLATE_ID="$2";             shift 2 ;;
    --curator-template-version)         CURATOR_TEMPLATE_VERSION="$2";        shift 2 ;;
    --reverse-auditor-template-id)      REVERSE_AUDITOR_TEMPLATE_ID="$2";     shift 2 ;;
    --reverse-auditor-template-version) REVERSE_AUDITOR_TEMPLATE_VERSION="$2"; shift 2 ;;
    --window-start)                     WINDOW_START="$2";                    shift 2 ;;
    --window-end)                       WINDOW_END="$2";                      shift 2 ;;
    --calibration-state)                CALIBRATION_STATE="$2";               shift 2 ;;
    --kdir)                             KDIR_OVERRIDE="$2";                   shift 2 ;;
    --verdicts)                         VERDICTS_PATH="$2";                   shift 2 ;;
    -h|--help)                          usage; exit 0 ;;
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

[[ -n "$ARTIFACT_ID"                      ]] || fail "--artifact-id is required"
[[ -n "$PRODUCER_TEMPLATE_ID"             ]] || fail "--producer-template-id is required"
[[ -n "$PRODUCER_TEMPLATE_VERSION"        ]] || fail "--producer-template-version is required"
[[ -n "$CURATOR_TEMPLATE_ID"              ]] || fail "--curator-template-id is required"
[[ -n "$CURATOR_TEMPLATE_VERSION"         ]] || fail "--curator-template-version is required"
[[ -n "$REVERSE_AUDITOR_TEMPLATE_ID"      ]] || fail "--reverse-auditor-template-id is required"
[[ -n "$REVERSE_AUDITOR_TEMPLATE_VERSION" ]] || fail "--reverse-auditor-template-version is required"
[[ -n "$WINDOW_START"                     ]] || fail "--window-start is required"
[[ -n "$WINDOW_END"                       ]] || fail "--window-end is required"

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
# Filter to reverse-auditor lines. Accept three verdicts: omission-claim,
# silence, preflight-failed. Anything else is a bad line.
METRICS=$(printf '%s' "$VERDICTS_INPUT" | python3 -c '
import json, sys

omission_claims = 0
silences = 0
preflight_failed = 0
total = 0
bad_lines = 0

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        bad_lines += 1
        continue
    if row.get("judge") != "reverse-auditor":
        continue
    verdict = row.get("verdict")
    if verdict == "omission-claim":
        omission_claims += 1
    elif verdict == "silence":
        silences += 1
    elif verdict == "preflight-failed":
        preflight_failed += 1
    else:
        bad_lines += 1
        continue
    total += 1

if total == 0:
    sys.stderr.write("[rollup] Warning: no reverse-auditor verdicts found\n")
    print(json.dumps({"total": 0, "omission_claims": 0, "silences": 0, "preflight_failed": 0, "bad_lines": bad_lines}))
    sys.exit(0)

omission_rate = omission_claims / total
coverage_quality = 1.0 - omission_rate
grounding_failure_rate = preflight_failed / total

print(json.dumps({
    "total":                 total,
    "omission_claims":       omission_claims,
    "silences":              silences,
    "preflight_failed":      preflight_failed,
    "bad_lines":             bad_lines,
    "omission_rate":         omission_rate,
    "coverage_quality":      coverage_quality,
    "grounding_failure_rate": grounding_failure_rate,
}))
')

TOTAL=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])')

if [[ "$TOTAL" -eq 0 ]]; then
  echo "[rollup] No reverse-auditor verdicts in input — no rows appended." >&2
  printf '%s\n' "$METRICS"
  exit 0
fi

# --- Emit rows ---
KDIR_ARG=()
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR_ARG=(--kdir "$KDIR_OVERRIDE")
fi

emit_row() {
  local metric="$1"
  local value="$2"
  local sample_size="$3"
  local template_id="$4"
  local template_version="$5"
  local kind="$6"
  local row
  row=$(ARTIFACT_ID_ENV="$ARTIFACT_ID" \
        TEMPLATE_ID_ENV="$template_id" \
        TEMPLATE_VERSION_ENV="$template_version" \
        METRIC_ENV="$metric" \
        VALUE_ENV="$value" \
        SAMPLE_SIZE_ENV="$sample_size" \
        WINDOW_START_ENV="$WINDOW_START" \
        WINDOW_END_ENV="$WINDOW_END" \
        CALIBRATION_STATE_ENV="$CALIBRATION_STATE" \
        KIND_ENV="$kind" \
        python3 -c '
import json, os
print(json.dumps({
    "schema_version":      "1",
    "kind":                os.environ["KIND_ENV"],
    "calibration_state":   os.environ["CALIBRATION_STATE_ENV"],
    "template_id":         os.environ["TEMPLATE_ID_ENV"],
    "template_version":    os.environ["TEMPLATE_VERSION_ENV"],
    "metric":              os.environ["METRIC_ENV"],
    "value":               float(os.environ["VALUE_ENV"]),
    "sample_size":         int(os.environ["SAMPLE_SIZE_ENV"]),
    "window_start":        os.environ["WINDOW_START_ENV"],
    "window_end":          os.environ["WINDOW_END_ENV"],
    "source_artifact_ids": [os.environ["ARTIFACT_ID_ENV"]],
    "granularity":         "portfolio-level",
}))
')
  "$SCRIPT_DIR/scorecard-append.sh" "${KDIR_ARG[@]}" --row "$row" >/dev/null
}

OMISSION_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["omission_rate"])')
COVERAGE_QUALITY=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["coverage_quality"])')
GROUNDING_FAILURE_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["grounding_failure_rate"])')

# omission_rate → producer template, kind=scored
emit_row "omission_rate"          "$OMISSION_RATE"          "$TOTAL" \
         "$PRODUCER_TEMPLATE_ID"  "$PRODUCER_TEMPLATE_VERSION" "scored"

# coverage_quality → curator template, kind=scored
emit_row "coverage_quality"       "$COVERAGE_QUALITY"       "$TOTAL" \
         "$CURATOR_TEMPLATE_ID"   "$CURATOR_TEMPLATE_VERSION" "scored"

# grounding_failure_rate → reverse-auditor template, kind=telemetry
emit_row "grounding_failure_rate" "$GROUNDING_FAILURE_RATE" "$TOTAL" \
         "$REVERSE_AUDITOR_TEMPLATE_ID" "$REVERSE_AUDITOR_TEMPLATE_VERSION" "telemetry"

echo "[rollup] Appended 3 rows: omission_rate=$OMISSION_RATE coverage_quality=$COVERAGE_QUALITY grounding_failure_rate=$GROUNDING_FAILURE_RATE (n=$TOTAL)"
printf '%s\n' "$METRICS"
