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
#       [--artifact-type <type>]    # when "consumption-contradiction", the
#                                   # rollup flips the matching sidecar row's
#                                   # status via consumption-contradiction-
#                                   # update-status.sh (D3 verdict mapping).
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
ARTIFACT_TYPE=""
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
    --artifact-type)               ARTIFACT_TYPE="$2";              shift 2 ;;
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

FACTUAL_PRECISION=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["factual_precision"])')
FALSIFIER_QUALITY=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["falsifier_quality"])')
CONTRADICTION_RATE=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["audit_contradiction_rate"])')

emit_row "factual_precision"        "$FACTUAL_PRECISION"  "$TOTAL"
emit_row "falsifier_quality"        "$FALSIFIER_QUALITY"  "$TOTAL"
emit_row "audit_contradiction_rate" "$CONTRADICTION_RATE" "$TOTAL"

echo "[rollup] Appended 3 rows: factual_precision=$FACTUAL_PRECISION falsifier_quality=$FALSIFIER_QUALITY audit_contradiction_rate=$CONTRADICTION_RATE (n=$TOTAL)"

# --- Post-rollup contradiction-status flip (Phase 2 wiring) ---
# When the rolled-up artifact is a consumption-contradiction, derive a
# terminal verdict from the aggregated counts and call the sole-update-writer
# to flip the sidecar row's status. See D3 in
# restore-evolve-gates-add-recurring-failure-path-se for the mapping table:
#
#   gate verdict   | sidecar status
#   ---------------+----------------
#   verified       | verified
#   contradicted   | rejected
#   unverified     | (no change — rollup skips the call)
#
# Wiring at the rollup (not the agent itself) keeps the agent's three-valued-
# logic contract untouched. The agent emits per-claim verdicts as before; the
# rollup is the existing extension point for downstream work that runs after
# the verdict is final.
#
# Verdict-derivation rule for the aggregated batch (single-claim artifacts
# produce a one-row batch; multi-row batches are folded by precedence):
#
#   1. If any verdict is `contradicted` → terminal=contradicted → sidecar=rejected.
#      Rationale: a single contradicted finding overturns the claim. The
#      contradiction is rejected.
#   2. Else if every verdict is `verified` (no unverified) → terminal=verified →
#      sidecar=verified. Rationale: the gate confirmed the claim end-to-end.
#   3. Else (some unverified, no contradicted) → terminal=unverified → no
#      sidecar change. /evolve treats absent-status as pending review.
if [[ "$ARTIFACT_TYPE" == "consumption-contradiction" ]]; then
  if [[ -z "$ARTIFACT_ID" ]]; then
    # Should be unreachable — --artifact-id is required upstream — but D3
    # explicitly forbids inferred matching, so we fail loudly here rather
    # than guess.
    echo "[rollup] Error: --artifact-id is required to flip contradiction status (D3 forbids inferring contradiction-id by path or claim text)" >&2
    exit 1
  fi

  VERIFIED_N=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verified"])')
  UNVERIFIED_N=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unverified"])')
  CONTRADICTED_N=$(printf '%s' "$METRICS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["contradicted"])')

  TERMINAL_VERDICT=""
  TARGET_STATUS=""
  if [[ "$CONTRADICTED_N" -ge 1 ]]; then
    TERMINAL_VERDICT="contradicted"
    TARGET_STATUS="rejected"
  elif [[ "$VERIFIED_N" -ge 1 && "$UNVERIFIED_N" -eq 0 ]]; then
    TERMINAL_VERDICT="verified"
    TARGET_STATUS="verified"
  else
    TERMINAL_VERDICT="unverified"
    TARGET_STATUS=""  # no-op
  fi

  if [[ -n "$TARGET_STATUS" ]]; then
    UPDATE_CMD=("$SCRIPT_DIR/consumption-contradiction-update-status.sh"
                "--contradiction-id" "$ARTIFACT_ID"
                "--status" "$TARGET_STATUS")
    if [[ -n "$KDIR_OVERRIDE" ]]; then
      UPDATE_CMD+=("--kdir" "$KDIR_OVERRIDE")
    fi
    "${UPDATE_CMD[@]}" || {
      echo "[rollup] Error: consumption-contradiction-update-status.sh failed for contradiction_id=$ARTIFACT_ID target=$TARGET_STATUS" >&2
      exit 1
    }
    echo "[rollup] Flipped contradiction $ARTIFACT_ID → $TARGET_STATUS (terminal-verdict=$TERMINAL_VERDICT)"
  else
    echo "[rollup] No contradiction-status flip for $ARTIFACT_ID — terminal-verdict=$TERMINAL_VERDICT (unchanged)"
  fi
fi

printf '%s\n' "$METRICS"
