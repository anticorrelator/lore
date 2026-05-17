#!/usr/bin/env bash
# scorecards-calibrate.sh — Run a calibration fixture-set against a judge,
# decide pass/fail, and update the calibration marker + history.
#
# Usage:
#   lore scorecard calibrate
#       --judge <correctness-gate-assertion|correctness-gate-omission|
#                correctness-gate-contradiction|curator|reverse-auditor>
#       --fixture-set <path>
#       [--threshold N] [--determinism-rerun] [--kdir <path>] [--json]
#
# A calibration fixture-set is a directory containing:
#   manifest.json   — { "fixtures": [ {"id": "...", "expected_verdict": "..."}, ... ] }
#   <id>/input.json — resolved producer artifact (the judge's user prompt)
#   <id>/output.json — pre-computed judge stdout for that input
#   calibration-log.jsonl — per-gate log appended by this runner
#   README.md       — fixture-set documentation
#
# For the three correctness-gate-<kind> variants the builder
# (`scripts/calibration-fixture-builder.py`) lays the fixtures under
# `fixtures/<layer>/<id>/{input,output}.json` and the manifest `id` fields are
# already slash-separated (`fixtures/synthetic/syn-asn-000`).
#
# The runner does NOT spawn judge agents itself. It compares each fixture's
# recorded `output.json` against `expected_verdict` from the manifest using a
# per-judge discrimination rule:
#   correctness-gate-*  → all per-claim verdicts in output.judge.verdicts must
#                          match the fixture's expected_verdicts list, position-
#                          keyed by claim_id.
#   curator             → output.selected/dropped sets must match the fixture's
#                          expected_selected/expected_dropped sets (id-equality).
#   reverse-auditor     → output.verdict must equal the fixture's expected_verdict
#                          string.
# The aggregate pass-rate over all fixtures is compared to --threshold
# (default 1.00, i.e., every fixture must match).
#
# Hard-cal vs soft-cal:
#   correctness-gate-assertion and correctness-gate-contradiction are HARD-CAL
#     — calibration failure must keep the marker untouched so the settlement
#       processor refuses to dispatch the gate (fail-shut downstream).
#   correctness-gate-omission, curator, and reverse-auditor are SOFT-CAL —
#     failure still appends a calibration-failed log row + history row, but
#     downstream code is expected to continue dispatching.
#
# SOLE-WRITER INVARIANT for the four state files this script owns:
#   $KDIR/_scorecards/calibration-state.json
#                                         pass-only marker, keyed by
#                                         (judge_template_id, judge_template_version).
#                                         Passing runs overwrite the keyed entry;
#                                         failing runs leave the file untouched.
#   $KDIR/_scorecards/calibration-history.jsonl
#                                         append-only history; one row per run
#                                         (passing OR failing). Multi-pass runs
#                                         (--determinism-rerun) append once per
#                                         pass plus a summary row at the end.
#   <fixture_set>/calibration-log.jsonl   per-gate log appended once per run
#                                         with calibration_state, per-layer
#                                         counts, and a bounded failure sample.
#
# Calibration evidence (the per-run scorecard rows) flow through
# scripts/scorecard-append.sh — never a direct write to rows.jsonl.
#
# Reader contract: scripts/audit-artifact.sh reads the marker keyed by
# (judge_template_id, judge_template_version). Missing file or missing entry
# resolves to calibration_state="pre-calibration". The reader also recognizes
# the calibration-failed state — see read_calibration_state in audit-artifact.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

JUDGE=""
FIXTURE_SET=""
THRESHOLD="1.00"
KDIR_OVERRIDE=""
JSON_MODE=0
DETERMINISM_RERUN=0

usage() {
  cat >&2 <<EOF
lore scorecard calibrate — run a calibration fixture-set against a judge.

Usage:
  lore scorecard calibrate
      --judge <correctness-gate-assertion|correctness-gate-omission|
               correctness-gate-contradiction|curator|reverse-auditor>
      --fixture-set <path>
      [--threshold N] [--determinism-rerun] [--kdir <path>] [--json]

See header of scripts/scorecards-calibrate.sh for fixture-set layout, the
per-judge discrimination rule, hard-cal vs soft-cal binding, and the
sole-writer invariant for calibration-state.json, calibration-history.jsonl,
and per-gate calibration-log.jsonl.
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
    --determinism-rerun)
      DETERMINISM_RERUN=1
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
  correctness-gate-assertion|correctness-gate-omission|correctness-gate-contradiction|curator|reverse-auditor) ;;
  "")
    fail "--judge is required (correctness-gate-{assertion,omission,contradiction} | curator | reverse-auditor)"
    ;;
  *)
    fail "--judge must be one of: correctness-gate-assertion, correctness-gate-omission, correctness-gate-contradiction, curator, reverse-auditor (got '$JUDGE')"
    ;;
esac

# Hard-cal binding: only assertion + contradiction gates fail-shut downstream
# (their verdicts drive `apply-correction.sh --mutate`). Soft-cal gates still
# emit log rows on failure but the marker absence does not stop downstream
# dispatch — the settlement processor's hard-cal precondition explicitly
# filters on this set.
IS_HARD_CAL=0
case "$JUDGE" in
  correctness-gate-assertion|correctness-gate-contradiction) IS_HARD_CAL=1 ;;
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
PER_GATE_LOG="$FIXTURE_SET/calibration-log.jsonl"

# --- Discrimination: compute per-fixture pass/fail and aggregate pass-rate ---
# Embedded python (per bash-python-hybrid-for-complex-scripts convention) does
# the JSON aggregation; bash drives state-flip + history append. Factored as a
# function so --determinism-rerun can call it twice and compare results.
run_pass() {
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
    actual_for_record = None
    if judge.startswith("correctness-gate"):
        # Expected: list of {claim_id, verdict} keyed by claim_id.
        expected = fx.get("expected_verdicts") or []
        actual = output.get("verdicts") or []
        exp_map = {e.get("claim_id"): e.get("verdict") for e in expected if e.get("claim_id")}
        act_map = {a.get("claim_id"): a.get("verdict") for a in actual if a.get("claim_id")}
        actual_for_record = act_map
        if exp_map and exp_map == act_map:
            ok = True
        else:
            reason = f"verdict map mismatch (expected={exp_map}, actual={act_map})"
    elif judge == "curator":
        exp_sel = set(fx.get("expected_selected") or [])
        exp_drop = set(fx.get("expected_dropped") or [])
        act_sel = set(c.get("claim_id") for c in (output.get("selected") or []) if c.get("claim_id"))
        act_drop = set(c.get("claim_id") for c in (output.get("dropped") or []) if c.get("claim_id"))
        actual_for_record = {"selected": sorted(act_sel), "dropped": sorted(act_drop)}
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
        actual_for_record = act
        if exp and exp == act:
            ok = True
        else:
            reason = f"verdict mismatch (expected={exp!r}, actual={act!r})"
    else:
        reason = f"unknown judge: {judge}"

    if ok:
        n_pass += 1
    per_fixture.append({"id": fid, "ok": ok, "reason": reason, "actual": actual_for_record})

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
}

# Pass 1.
RESULT_JSON=$(run_pass)

# Surface python-detected manifest error.
if printf '%s' "$RESULT_JSON" | jq -e '.error' >/dev/null 2>&1; then
  fail "$(printf '%s' "$RESULT_JSON" | jq -r '.error')"
fi

DETERMINISM_OK="true"
DETERMINISM_REASON=""
RESULT2_JSON=""
if [[ "$DETERMINISM_RERUN" -eq 1 ]]; then
  RESULT2_JSON=$(run_pass)
  # Compare per-fixture (id, ok, actual) tuples between the two runs. Both runs
  # read the same recorded outputs so a divergence indicates non-determinism
  # in the runner's discrimination math (which would point at a bug, not a
  # judge regression). Any divergence resolves to gate_pass=false.
  DETERMINISM_OK=$(
    R1="$RESULT_JSON" R2="$RESULT2_JSON" python3 -c '
import json, os
r1 = json.loads(os.environ["R1"]).get("per_fixture", [])
r2 = json.loads(os.environ["R2"]).get("per_fixture", [])
def proj(rows):
    return [(r.get("id"), r.get("ok"), json.dumps(r.get("actual"), sort_keys=True)) for r in rows]
print("true" if proj(r1) == proj(r2) else "false")
'
  )
  if [[ "$DETERMINISM_OK" != "true" ]]; then
    DETERMINISM_REASON="run-1 and run-2 produced divergent verdict-per-fixture results"
  fi
fi

GATE_PASS=$(printf '%s' "$RESULT_JSON" | jq -r '.gate_pass')
PASS_RATE=$(printf '%s' "$RESULT_JSON" | jq -r '.pass_rate')
TOTAL=$(printf '%s' "$RESULT_JSON" | jq -r '.total')
N_PASS=$(printf '%s' "$RESULT_JSON" | jq -r '.n_pass')

# Determinism failure overrides gate_pass.
if [[ "$DETERMINISM_OK" != "true" ]]; then
  GATE_PASS="false"
fi

# Calibration state for log + marker rows. The reader (audit-artifact.sh)
# recognizes three values: calibrated, pre-calibration, calibration-failed.
if [[ "$GATE_PASS" == "true" ]]; then
  CALIBRATION_STATE="calibrated"
else
  CALIBRATION_STATE="calibration-failed"
fi

# --- Append history row (every run, passing OR failing) ---
HISTORY_ROW=$(
  RESULT_JSON="$RESULT_JSON" \
  RESULT2_JSON="$RESULT2_JSON" \
  JUDGE_TEMPLATE_ID="$JUDGE_TEMPLATE_ID" \
  JUDGE_TEMPLATE_VERSION="$JUDGE_TEMPLATE_VERSION" \
  FIXTURE_SET_ID="$FIXTURE_SET_ID" \
  WINDOW="$WINDOW" \
  CAPTURED_BRANCH="$CAPTURED_BRANCH" \
  CAPTURED_SHA="$CAPTURED_SHA" \
  CALIBRATION_STATE="$CALIBRATION_STATE" \
  GATE_PASS_OVERRIDE="$GATE_PASS" \
  DETERMINISM_RERUN="$DETERMINISM_RERUN" \
  DETERMINISM_OK="$DETERMINISM_OK" \
  DETERMINISM_REASON="$DETERMINISM_REASON" \
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
    "gate_pass": os.environ["GATE_PASS_OVERRIDE"] == "true",
    "calibration_state": os.environ["CALIBRATION_STATE"],
    "per_fixture": result["per_fixture"],
}
if os.environ.get("DETERMINISM_RERUN") == "1":
    second = os.environ.get("RESULT2_JSON") or ""
    row["determinism_rerun"] = True
    row["determinism_ok"] = os.environ.get("DETERMINISM_OK") == "true"
    if os.environ.get("DETERMINISM_REASON"):
        row["determinism_reason"] = os.environ["DETERMINISM_REASON"]
    if second:
        row["pass_rate_rerun"] = json.loads(second).get("pass_rate")
else:
    row["determinism_rerun"] = False
print(json.dumps(row, separators=(",", ":")))
PYEOF
)
printf '%s\n' "$HISTORY_ROW" >> "$HISTORY_FILE"

# --- Per-gate calibration-log.jsonl row ---
# Append one row per run to <fixture_set>/calibration-log.jsonl. Captures the
# state plus a compact per-fixture summary so /retro can read the gate's
# discrimination posture without re-running the fixtures.
PER_GATE_ROW=$(
  RESULT_JSON="$RESULT_JSON" \
  JUDGE_TEMPLATE_ID="$JUDGE_TEMPLATE_ID" \
  JUDGE_TEMPLATE_VERSION="$JUDGE_TEMPLATE_VERSION" \
  FIXTURE_SET_ID="$FIXTURE_SET_ID" \
  WINDOW="$WINDOW" \
  CAPTURED_BRANCH="$CAPTURED_BRANCH" \
  CAPTURED_SHA="$CAPTURED_SHA" \
  CALIBRATION_STATE="$CALIBRATION_STATE" \
  IS_HARD_CAL="$IS_HARD_CAL" \
  DETERMINISM_RERUN="$DETERMINISM_RERUN" \
  DETERMINISM_OK="$DETERMINISM_OK" \
  DETERMINISM_REASON="$DETERMINISM_REASON" \
  python3 - <<'PYEOF'
import json, os
result = json.loads(os.environ["RESULT_JSON"])
per_fixture = result.get("per_fixture", [])
layer_counts = {}
for r in per_fixture:
    fid = (r.get("id") or "")
    layer = fid.split("/")[1] if fid.startswith("fixtures/") and "/" in fid[len("fixtures/"):] else "unknown"
    bucket = layer_counts.setdefault(layer, {"total": 0, "pass": 0, "fail": 0})
    bucket["total"] += 1
    if r.get("ok"):
        bucket["pass"] += 1
    else:
        bucket["fail"] += 1
failures = [
    {"id": r.get("id"), "reason": r.get("reason") or ""}
    for r in per_fixture if not r.get("ok")
]
# Cap captured failure details so the log row stays bounded.
MAX_FAIL_RECORDS = 25
if len(failures) > MAX_FAIL_RECORDS:
    failures = failures[:MAX_FAIL_RECORDS] + [{"id": "...", "reason": f"+{len(per_fixture) - MAX_FAIL_RECORDS} more"}]
row = {
    "schema_version": "1",
    "ran_at": os.environ["WINDOW"],
    "judge_template_id": os.environ["JUDGE_TEMPLATE_ID"],
    "judge_template_version": os.environ["JUDGE_TEMPLATE_VERSION"],
    "fixture_set_id": os.environ["FIXTURE_SET_ID"],
    "captured_branch": os.environ["CAPTURED_BRANCH"],
    "captured_sha": os.environ["CAPTURED_SHA"],
    "calibration_state": os.environ["CALIBRATION_STATE"],
    "is_hard_cal": os.environ["IS_HARD_CAL"] == "1",
    "sample_size": result["total"],
    "n_pass": result["n_pass"],
    "pass_rate": result["pass_rate"],
    "threshold": result["threshold"],
    "per_layer": layer_counts,
    "failures": failures,
    "determinism_rerun": os.environ.get("DETERMINISM_RERUN") == "1",
    "determinism_ok": os.environ.get("DETERMINISM_OK") == "true",
}
if os.environ.get("DETERMINISM_REASON"):
    row["determinism_reason"] = os.environ["DETERMINISM_REASON"]
print(json.dumps(row, separators=(",", ":")))
PYEOF
)
# Ensure the per-gate log path is appendable; the builder touches it but a
# hand-edited fixture set may omit it.
mkdir -p "$(dirname "$PER_GATE_LOG")"
printf '%s\n' "$PER_GATE_ROW" >> "$PER_GATE_LOG"

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
  CALIBRATION_STATE="$CALIBRATION_STATE" \
  FIXTURE_SET_ID="$FIXTURE_SET_ID" \
  python3 -c '
import json, os
print(json.dumps({
    "schema_version": "1",
    "kind": "telemetry",
    "tier": "telemetry",
    "calibration_state": os.environ["CALIBRATION_STATE"],
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
    --arg calibration_state "$CALIBRATION_STATE" \
    --argjson total "$TOTAL" \
    --argjson n_pass "$N_PASS" \
    --argjson pass_rate "$PASS_RATE" \
    --argjson threshold "$THRESHOLD" \
    --argjson gate_pass "$GATE_PASS" \
    --argjson is_hard_cal "$IS_HARD_CAL" \
    --argjson determinism_rerun "$DETERMINISM_RERUN" \
    --arg determinism_ok "$DETERMINISM_OK" \
    --arg ran_at "$WINDOW" \
    '{judge: $judge, judge_template_version: $judge_template_version, fixture_set_id: $fixture_set_id, calibration_state: $calibration_state, total: $total, n_pass: $n_pass, pass_rate: $pass_rate, threshold: $threshold, gate_pass: $gate_pass, is_hard_cal: ($is_hard_cal == 1), determinism_rerun: ($determinism_rerun == 1), determinism_ok: ($determinism_ok == "true"), ran_at: $ran_at}')
  json_output "$RESULT"
fi

if [[ "$GATE_PASS" == "true" ]]; then
  echo "[calibrate] $JUDGE PASS — pass_rate=$PASS_RATE (n=$N_PASS/$TOTAL, threshold=$THRESHOLD); marker flipped to calibrated for $JUDGE_TEMPLATE_VERSION; per-gate log appended at $PER_GATE_LOG"
else
  if [[ -n "$DETERMINISM_REASON" ]]; then
    echo "[calibrate] $JUDGE FAIL (determinism) — $DETERMINISM_REASON; pass_rate=$PASS_RATE (n=$N_PASS/$TOTAL); marker untouched; per-gate log appended at $PER_GATE_LOG"
  else
    echo "[calibrate] $JUDGE FAIL — pass_rate=$PASS_RATE (n=$N_PASS/$TOTAL, threshold=$THRESHOLD); marker untouched; per-gate log appended at $PER_GATE_LOG (calibration_state=calibration-failed)"
  fi
  exit 1
fi
