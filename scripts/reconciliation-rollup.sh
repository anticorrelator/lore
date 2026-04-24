#!/usr/bin/env bash
# reconciliation-rollup.sh — Roll up tournament-reconciliation deltas into scorecard rows
#
# Given a reconciliation.json produced by reconcile-reviews.sh (task-32),
# compute three settlement metrics scoring the pr-self-review template
# and append one row per metric to $KDIR/_scorecards/rows.jsonl via
# scorecard-append.sh.
#
# Usage:
#   reconciliation-rollup.sh \
#       --reconciliation <path-to-reconciliation.json> \
#       --artifact-id <id> \
#       --template-version <hash> \
#       --window-start <ISO-8601> \
#       --window-end <ISO-8601> \
#       [--template-id pr-self-review]         # default: pr-self-review
#       [--calibration-state calibrated|pre-calibration|unknown] \
#       [--kdir <path>]
#
# Metrics emitted (all kind=scored, granularity=claim-local, attributed
# to the pr-self-review template per plan — these score the self-review's
# *accuracy* against the external review's ground truth, not the
# producer's code quality):
#
#   external_confirm_rate    = confirm / reconciled_total
#     Fraction of self-review findings the external review independently
#     corroborated. Higher = self-review template is producing findings
#     the external reviewer agrees with.
#   external_contradict_rate = contradict / reconciled_total
#     Fraction where self and external disagree in verdict direction
#     (strict — severity gap ≥2 AND textual opposite markers, per
#     reconcile-reviews-compute.py). Higher = self-review template is
#     drawing conclusions the external review actively refutes.
#   coverage_miss_rate       = coverage_miss.length / external_total
#     Fraction of external-review findings that have NO matching
#     self-review finding. Higher = self-review template is failing to
#     survey the surfaces where real findings live — a sampling/scope
#     failure, distinct from a verdict-accuracy failure.
#
# The three metrics are complementary:
#   - `external_confirm_rate`   = positive accuracy signal
#   - `external_contradict_rate` = negative verdict signal
#   - `coverage_miss_rate`       = surface-coverage signal (sampling, not
#                                  verdict — can be high while confirm
#                                  is also high: self was accurate on what
#                                  it looked at but missed whole regions)
#
# Denominators differ on purpose:
#   - confirm/contradict denominators are reconciled_total (self findings),
#     because they score the self-review's verdict accuracy.
#   - coverage_miss denominator is external_total (external findings),
#     because it measures how much the self-review *missed* relative to
#     what was actually there to find.
#
# Sole-writer parallel to curator-rollup.sh, correctness-gate-rollup.sh,
# reverse-auditor-rollup.sh. All rollups funnel through
# scorecard-append.sh — no direct rows.jsonl writes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

RECONCILIATION_PATH=""
ARTIFACT_ID=""
TEMPLATE_ID="pr-self-review"
TEMPLATE_VERSION=""
WINDOW_START=""
WINDOW_END=""
CALIBRATION_STATE="pre-calibration"
KDIR_OVERRIDE=""

usage() {
  sed -n '2,55p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reconciliation)     RECONCILIATION_PATH="$2"; shift 2 ;;
    --artifact-id)        ARTIFACT_ID="$2";         shift 2 ;;
    --template-id)        TEMPLATE_ID="$2";         shift 2 ;;
    --template-version)   TEMPLATE_VERSION="$2";    shift 2 ;;
    --window-start)       WINDOW_START="$2";        shift 2 ;;
    --window-end)         WINDOW_END="$2";          shift 2 ;;
    --calibration-state)  CALIBRATION_STATE="$2";   shift 2 ;;
    --kdir)               KDIR_OVERRIDE="$2";       shift 2 ;;
    -h|--help)            usage; exit 0 ;;
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

[[ -n "$RECONCILIATION_PATH"  ]] || fail "--reconciliation <path> is required"
[[ -f "$RECONCILIATION_PATH"  ]] || fail "reconciliation file not found: $RECONCILIATION_PATH"
[[ -n "$ARTIFACT_ID"          ]] || fail "--artifact-id is required"
[[ -n "$TEMPLATE_VERSION"     ]] || fail "--template-version is required"
[[ -n "$WINDOW_START"         ]] || fail "--window-start is required"
[[ -n "$WINDOW_END"           ]] || fail "--window-end is required"

case "$CALIBRATION_STATE" in
  calibrated|pre-calibration|unknown) ;;
  *)
    fail "--calibration-state must be one of: calibrated, pre-calibration, unknown"
    ;;
esac

# --- Compute metrics from reconciliation.json ---
METRICS=$(python3 -c '
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

reconciled = data.get("reconciled", [])
coverage_miss = data.get("coverage_miss", [])
external_total = data.get("external_finding_count", 0)

reconciled_total = len(reconciled)
confirm = sum(1 for r in reconciled if r.get("tag") == "confirm")
extend = sum(1 for r in reconciled if r.get("tag") == "extend")
contradict = sum(1 for r in reconciled if r.get("tag") == "contradict")
orthogonal = sum(1 for r in reconciled if r.get("tag") == "orthogonal")
coverage_miss_count = len(coverage_miss)

out = {
    "reconciled_total": reconciled_total,
    "confirm": confirm,
    "extend": extend,
    "contradict": contradict,
    "orthogonal": orthogonal,
    "coverage_miss_count": coverage_miss_count,
    "external_total": external_total,
}

if reconciled_total > 0:
    out["external_confirm_rate"]    = confirm / reconciled_total
    out["external_contradict_rate"] = contradict / reconciled_total
else:
    out["external_confirm_rate"]    = None
    out["external_contradict_rate"] = None

if external_total > 0:
    out["coverage_miss_rate"] = coverage_miss_count / external_total
else:
    out["coverage_miss_rate"] = None

print(json.dumps(out))
' "$RECONCILIATION_PATH")

RECONCILED_TOTAL=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reconciled_total"])')
EXTERNAL_TOTAL=$(printf '%s' "$METRICS"   | python3 -c 'import json,sys; print(json.load(sys.stdin)["external_total"])')

if [[ "$RECONCILED_TOTAL" -eq 0 && "$EXTERNAL_TOTAL" -eq 0 ]]; then
  echo "[rollup] Reconciliation has zero self and zero external findings — nothing to roll up." >&2
  printf '%s\n' "$METRICS"
  exit 0
fi

# --- Emit one row per metric via scorecard-append.sh ---
KDIR_ARG=()
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR_ARG=(--kdir "$KDIR_OVERRIDE")
fi

emit_row() {
  local metric="$1"
  local value="$2"
  local sample_size="$3"
  # Skip rows with null value (insufficient sample to compute the metric).
  if [[ "$value" == "null" || -z "$value" ]]; then
    echo "[rollup] Skipped $metric row: denominator was zero" >&2
    return 0
  fi
  local row
  row=$(ARTIFACT_ID_ENV="$ARTIFACT_ID" \
        TEMPLATE_ID_ENV="$TEMPLATE_ID" \
        TEMPLATE_VERSION_ENV="$TEMPLATE_VERSION" \
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
    "tier":                "reusable",
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

CONFIRM_RATE=$(printf '%s' "$METRICS"    | python3 -c 'import json,sys; v=json.load(sys.stdin)["external_confirm_rate"]; print("null" if v is None else v)')
CONTRADICT_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; v=json.load(sys.stdin)["external_contradict_rate"]; print("null" if v is None else v)')
COVERAGE_MISS_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; v=json.load(sys.stdin)["coverage_miss_rate"]; print("null" if v is None else v)')

emit_row "external_confirm_rate"    "$CONFIRM_RATE"       "$RECONCILED_TOTAL"
emit_row "external_contradict_rate" "$CONTRADICT_RATE"    "$RECONCILED_TOTAL"
emit_row "coverage_miss_rate"       "$COVERAGE_MISS_RATE" "$EXTERNAL_TOTAL"

APPENDED=0
for v in "$CONFIRM_RATE" "$CONTRADICT_RATE" "$COVERAGE_MISS_RATE"; do
  [[ "$v" != "null" && -n "$v" ]] && APPENDED=$((APPENDED + 1))
done

echo "[rollup] Appended $APPENDED rows: external_confirm_rate=$CONFIRM_RATE external_contradict_rate=$CONTRADICT_RATE coverage_miss_rate=$COVERAGE_MISS_RATE (reconciled=$RECONCILED_TOTAL external=$EXTERNAL_TOTAL)"
printf '%s\n' "$METRICS"
