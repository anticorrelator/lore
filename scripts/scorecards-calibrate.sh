#!/usr/bin/env bash
# scorecards-calibrate.sh — Run a calibration fixture-set against a judge,
# decide pass/fail, and update the calibration marker + history.
#
# Usage:
#   lore scorecard calibrate --judge <correctness-gate|curator|reverse-auditor>
#                            --fixture-set <path>
#                            [--threshold N] [--kdir <path>] [--json]
#
# A calibration fixture-set is a directory containing:
#   manifest.json   — { "fixtures": [ {"id": "...", "expected_verdict": "..."}, ... ] }
#   <id>/input.json — resolved producer artifact (the judge's user prompt)
#   <id>/output.json — pre-computed judge stdout for that input
#
# The runner does NOT spawn judge agents. It compares each fixture's recorded
# `output.json` against `expected_verdict` from the manifest using a
# per-judge discrimination rule:
#   correctness-gate → all per-claim verdicts in output.judge.verdicts must
#                      match the fixture's expected_verdicts list, position-
#                      keyed by claim_id.
#   curator          → output.selected/dropped sets must match the fixture's
#                      expected_selected/expected_dropped sets (id-equality).
#   reverse-auditor  → output.verdict must equal the fixture's expected_verdict
#                      string.
# The aggregate pass-rate over all fixtures is compared to --threshold
# (default 1.00, i.e., every fixture must match).
#
# SOLE-WRITER INVARIANT for the two state files this script owns:
#   $KDIR/_scorecards/calibration-state.json    pass-only marker, keyed by
#                                                (judge_template_id, judge_template_version).
#                                                Passing runs overwrite the
#                                                keyed entry; failing runs leave
#                                                the file untouched.
#   $KDIR/_scorecards/calibration-history.jsonl append-only history; one row
#                                                per run (passing OR failing).
#
# Calibration evidence (the per-run scorecard rows) flow through
# scripts/scorecard-append.sh — never a direct write to rows.jsonl.
#
# Reader contract: scripts/audit-artifact.sh reads the marker (only) keyed by
# (judge_template_id, judge_template_version). Missing file or missing entry
# resolves to calibration_state="pre-calibration" — the marker's absence is
# the only signal audit-artifact needs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

JUDGE=""
FIXTURE_SET=""
THRESHOLD="1.00"
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
lore scorecard calibrate — run a calibration fixture-set against a judge.

Usage:
  lore scorecard calibrate --judge <correctness-gate|curator|reverse-auditor>
                           --fixture-set <path>
                           [--threshold N] [--kdir <path>] [--json]

See header of scripts/scorecards-calibrate.sh for fixture-set layout and
discrimination rules.
EOF
}

# Allow either `lore scorecard calibrate ...` or `scorecards-calibrate.sh ...`.
if [[ $# -gt 0 && "$1" == "calibrate" ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --judge)
      JUDGE="$2"
      shift 2
      ;;
    --fixture-set)
      FIXTURE_SET="$2"
      shift 2
      ;;
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[calibrate] Error: unknown argument '$1'" >&2
      usage
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

case "$JUDGE" in
  correctness-gate|curator|reverse-auditor) ;;
  "")
    fail "--judge is required (correctness-gate | curator | reverse-auditor)"
    ;;
  *)
    fail "--judge must be one of: correctness-gate, curator, reverse-auditor (got '$JUDGE')"
    ;;
esac

if [[ -z "$FIXTURE_SET" ]]; then
  fail "--fixture-set is required"
fi
if [[ ! -d "$FIXTURE_SET" ]]; then
  fail "fixture-set is not a directory: $FIXTURE_SET"
fi
if [[ ! -f "$FIXTURE_SET/manifest.json" ]]; then
  fail "fixture-set missing manifest.json: $FIXTURE_SET/manifest.json"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KDIR" ]]; then
  fail "knowledge store not found at: $KDIR"
fi

# Resolve judge template + content-hash version.
JUDGE_TEMPLATE_ID="$JUDGE"
if ! JUDGE_TEMPLATE=$(resolve_agent_template "$JUDGE" 2>/dev/null); then
  fail "could not resolve judge template for '$JUDGE' (resolve_agent_template failed)"
fi
JUDGE_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$JUDGE_TEMPLATE")

WINDOW=$(timestamp_iso)
CAPTURED_BRANCH=$(get_git_branch || echo "")
CAPTURED_SHA=$(captured_at_sha || echo "")
FIXTURE_SET_ID=$(basename "$FIXTURE_SET")

SCORECARDS_DIR="$KDIR/_scorecards"
mkdir -p "$SCORECARDS_DIR"
MARKER_FILE="$SCORECARDS_DIR/calibration-state.json"
HISTORY_FILE="$SCORECARDS_DIR/calibration-history.jsonl"

# --- Discrimination: compute per-fixture pass/fail and aggregate pass-rate ---
# Embedded python (per bash-python-hybrid-for-complex-scripts convention) does
# the JSON aggregation; bash drives state-flip + history append.
RESULT_JSON=$(
  JUDGE="$JUDGE" \
  FIXTURE_SET="$FIXTURE_SET" \
  THRESHOLD="$THRESHOLD" \
  python3 - <<'PYEOF'
import json, os, sys

judge = os.environ["JUDGE"]
fixture_set = os.environ["FIXTURE_SET"]
threshold = float(os.environ["THRESHOLD"])

with open(os.path.join(fixture_set, "manifest.json")) as fh:
    manifest = json.load(fh)

fixtures = manifest.get("fixtures") or []
if not isinstance(fixtures, list) or not fixtures:
    print(json.dumps({"error": "manifest.fixtures must be a non-empty array"}))
    sys.exit(0)

per_fixture = []
n_pass = 0

for fx in fixtures:
    fid = fx.get("id")
    if not fid:
        per_fixture.append({"id": None, "ok": False, "reason": "fixture id missing"})
        continue
    out_path = os.path.join(fixture_set, fid, "output.json")
    if not os.path.isfile(out_path):
        per_fixture.append({"id": fid, "ok": False, "reason": f"output.json not found: {out_path}"})
        continue
    try:
        with open(out_path) as fh:
            output = json.load(fh)
    except json.JSONDecodeError as e:
        per_fixture.append({"id": fid, "ok": False, "reason": f"output.json invalid JSON: {e}"})
        continue

    ok = False
    reason = ""
    if judge == "correctness-gate":
        # Expected: list of {claim_id, verdict} keyed by claim_id.
        expected = fx.get("expected_verdicts") or []
        actual = output.get("verdicts") or []
        exp_map = {e.get("claim_id"): e.get("verdict") for e in expected if e.get("claim_id")}
        act_map = {a.get("claim_id"): a.get("verdict") for a in actual if a.get("claim_id")}
        if exp_map and exp_map == act_map:
            ok = True
        else:
            reason = f"verdict map mismatch (expected={exp_map}, actual={act_map})"
    elif judge == "curator":
        exp_sel = set(fx.get("expected_selected") or [])
        exp_drop = set(fx.get("expected_dropped") or [])
        act_sel = set(c.get("claim_id") for c in (output.get("selected") or []) if c.get("claim_id"))
        act_drop = set(c.get("claim_id") for c in (output.get("dropped") or []) if c.get("claim_id"))
        if exp_sel == act_sel and exp_drop == act_drop:
            ok = True
        else:
            reason = (
                f"selected/dropped mismatch (expected_selected={sorted(exp_sel)}, "
                f"actual_selected={sorted(act_sel)}, expected_dropped={sorted(exp_drop)}, "
                f"actual_dropped={sorted(act_drop)})"
            )
    elif judge == "reverse-auditor":
        exp = fx.get("expected_verdict")
        act = output.get("verdict")
        if exp and exp == act:
            ok = True
        else:
            reason = f"verdict mismatch (expected={exp!r}, actual={act!r})"
    else:
        reason = f"unknown judge: {judge}"

    if ok:
        n_pass += 1
    per_fixture.append({"id": fid, "ok": ok, "reason": reason})

total = len(per_fixture)
pass_rate = (n_pass / total) if total else 0.0
gate_pass = pass_rate >= threshold

print(json.dumps({
    "total": total,
    "n_pass": n_pass,
    "pass_rate": pass_rate,
    "threshold": threshold,
    "gate_pass": gate_pass,
    "per_fixture": per_fixture,
}))
PYEOF
)

# Surface python-detected manifest error.
if printf '%s' "$RESULT_JSON" | jq -e '.error' >/dev/null 2>&1; then
  fail "$(printf '%s' "$RESULT_JSON" | jq -r '.error')"
fi

GATE_PASS=$(printf '%s' "$RESULT_JSON" | jq -r '.gate_pass')
PASS_RATE=$(printf '%s' "$RESULT_JSON" | jq -r '.pass_rate')
TOTAL=$(printf '%s' "$RESULT_JSON" | jq -r '.total')
N_PASS=$(printf '%s' "$RESULT_JSON" | jq -r '.n_pass')

# --- Append history row (every run, passing OR failing) ---
HISTORY_ROW=$(
  RESULT_JSON="$RESULT_JSON" \
  JUDGE_TEMPLATE_ID="$JUDGE_TEMPLATE_ID" \
  JUDGE_TEMPLATE_VERSION="$JUDGE_TEMPLATE_VERSION" \
  FIXTURE_SET_ID="$FIXTURE_SET_ID" \
  WINDOW="$WINDOW" \
  CAPTURED_BRANCH="$CAPTURED_BRANCH" \
  CAPTURED_SHA="$CAPTURED_SHA" \
  python3 - <<'PYEOF'
import json, os
result = json.loads(os.environ["RESULT_JSON"])
row = {
    "schema_version": "1",
    "judge_template_id": os.environ["JUDGE_TEMPLATE_ID"],
    "judge_template_version": os.environ["JUDGE_TEMPLATE_VERSION"],
    "fixture_set_id": os.environ["FIXTURE_SET_ID"],
    "ran_at": os.environ["WINDOW"],
    "captured_branch": os.environ["CAPTURED_BRANCH"],
    "captured_sha": os.environ["CAPTURED_SHA"],
    "sample_size": result["total"],
    "n_pass": result["n_pass"],
    "pass_rate": result["pass_rate"],
    "threshold": result["threshold"],
    "gate_pass": result["gate_pass"],
    "per_fixture": result["per_fixture"],
}
print(json.dumps(row, separators=(",", ":")))
PYEOF
)
printf '%s\n' "$HISTORY_ROW" >> "$HISTORY_FILE"

# --- Pass-only marker flip: keyed by (judge_template_id, judge_template_version) ---
if [[ "$GATE_PASS" == "true" ]]; then
  MARKER_KEY="${JUDGE_TEMPLATE_ID}:${JUDGE_TEMPLATE_VERSION}"
  ENTRY=$(
    JUDGE_TEMPLATE_ID="$JUDGE_TEMPLATE_ID" \
    JUDGE_TEMPLATE_VERSION="$JUDGE_TEMPLATE_VERSION" \
    FIXTURE_SET_ID="$FIXTURE_SET_ID" \
    WINDOW="$WINDOW" \
    CAPTURED_BRANCH="$CAPTURED_BRANCH" \
    CAPTURED_SHA="$CAPTURED_SHA" \
    PASS_RATE="$PASS_RATE" \
    THRESHOLD="$THRESHOLD" \
    SAMPLE_SIZE="$TOTAL" \
    python3 -c '
import json, os
print(json.dumps({
    "calibration_state": "calibrated",
    "judge_template_id": os.environ["JUDGE_TEMPLATE_ID"],
    "judge_template_version": os.environ["JUDGE_TEMPLATE_VERSION"],
    "fixture_set_id": os.environ["FIXTURE_SET_ID"],
    "calibrated_at": os.environ["WINDOW"],
    "captured_branch": os.environ["CAPTURED_BRANCH"],
    "captured_sha": os.environ["CAPTURED_SHA"],
    "pass_rate": float(os.environ["PASS_RATE"]),
    "threshold": float(os.environ["THRESHOLD"]),
    "sample_size": int(os.environ["SAMPLE_SIZE"]),
}))
'
  )

  EXISTING="{}"
  if [[ -f "$MARKER_FILE" ]]; then
    if ! EXISTING=$(jq -e 'type == "object"' "$MARKER_FILE" >/dev/null 2>&1 && cat "$MARKER_FILE"); then
      fail "existing marker file is not a JSON object: $MARKER_FILE"
    fi
  fi

  UPDATED=$(
    EXISTING="$EXISTING" \
    KEY="$MARKER_KEY" \
    ENTRY="$ENTRY" \
    python3 -c '
import json, os
existing = json.loads(os.environ["EXISTING"])
entry = json.loads(os.environ["ENTRY"])
existing[os.environ["KEY"]] = entry
print(json.dumps(existing, indent=2, sort_keys=True))
'
  )
  printf '%s\n' "$UPDATED" > "$MARKER_FILE"
fi

# --- Emit per-judge calibration evidence row through scorecard-append.sh ---
# This is one telemetry-tier row per calibration run (passing OR failing) that
# attributes to the judge template — sole-writer compliant.
EVIDENCE_ROW=$(
  JUDGE_TEMPLATE_ID="$JUDGE_TEMPLATE_ID" \
  JUDGE_TEMPLATE_VERSION="$JUDGE_TEMPLATE_VERSION" \
  WINDOW="$WINDOW" \
  PASS_RATE="$PASS_RATE" \
  TOTAL="$TOTAL" \
  GATE_PASS="$GATE_PASS" \
  FIXTURE_SET_ID="$FIXTURE_SET_ID" \
  python3 -c '
import json, os
gate_pass = os.environ["GATE_PASS"] == "true"
print(json.dumps({
    "schema_version": "1",
    "kind": "telemetry",
    "tier": "telemetry",
    "calibration_state": "calibrated" if gate_pass else "pre-calibration",
    "template_id": os.environ["JUDGE_TEMPLATE_ID"],
    "template_version": os.environ["JUDGE_TEMPLATE_VERSION"],
    "metric": "calibration_pass_rate",
    "value": float(os.environ["PASS_RATE"]),
    "sample_size": int(os.environ["TOTAL"]),
    "window_start": os.environ["WINDOW"],
    "window_end": os.environ["WINDOW"],
    "source_artifact_ids": [os.environ["FIXTURE_SET_ID"]],
    "granularity": "set-level",
    "verdict_source": "calibration-runner",
    "judge_template_version": os.environ["JUDGE_TEMPLATE_VERSION"],
}))
'
)
if ! bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$EVIDENCE_ROW" >/dev/null 2>&1; then
  echo "[calibrate] warning: scorecard-append rejected the calibration evidence row" >&2
fi

# --- Output ---
if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg judge "$JUDGE" \
    --arg judge_template_version "$JUDGE_TEMPLATE_VERSION" \
    --arg fixture_set_id "$FIXTURE_SET_ID" \
    --argjson total "$TOTAL" \
    --argjson n_pass "$N_PASS" \
    --argjson pass_rate "$PASS_RATE" \
    --argjson threshold "$THRESHOLD" \
    --argjson gate_pass "$GATE_PASS" \
    --arg ran_at "$WINDOW" \
    '{judge: $judge, judge_template_version: $judge_template_version, fixture_set_id: $fixture_set_id, total: $total, n_pass: $n_pass, pass_rate: $pass_rate, threshold: $threshold, gate_pass: $gate_pass, ran_at: $ran_at}')
  json_output "$RESULT"
fi

if [[ "$GATE_PASS" == "true" ]]; then
  echo "[calibrate] $JUDGE PASS — pass_rate=$PASS_RATE (n=$N_PASS/$TOTAL, threshold=$THRESHOLD); marker flipped to calibrated for $JUDGE_TEMPLATE_VERSION"
else
  echo "[calibrate] $JUDGE FAIL — pass_rate=$PASS_RATE (n=$N_PASS/$TOTAL, threshold=$THRESHOLD); marker untouched (history row appended)"
  exit 1
fi
