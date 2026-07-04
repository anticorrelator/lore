#!/usr/bin/env bash
# judge-quality-regression.sh — Strict omission-quality regression bar for the
# reverse-auditor judge.
#
# Usage:
#   judge-quality-regression.sh reverse-auditor --mode <strict-gate|canary|self-test-manual>
#       [--fixture <fixture-id>] [--fixture-dir <path>] [--kdir <path>]
#   judge-quality-regression.sh reverse-auditor --rolling-report
#       [--window <N>] [--threshold <T>] [--kdir <path>]
#
# Replay mode re-invokes the production judge code path
# (_headless_runner_invoke_once, sourced from scripts/audit-artifact.sh) on
# each fixture's frozen 04-reverse-auditor-input.json packet — the packet's
# inlined_evidence is the complete substrate the no-tool-use judge adjudicates
# from, so the frozen file is fed to the judge unchanged; nothing is
# path-rewritten. Single attempt, no retry: the strict bar measures the
# judge's first emission.
#
# A fixture passes iff the emission clears all four gates:
#   1. schema-valid against scripts/judge-schemas/reverse-auditor-output.schema.json
#   2. omission_claim is non-null (silence on an omission-positive fixture is
#      a regression)
#   3. emitted omission_claim.file equals the expected file
#   4. emitted line_range overlaps the expected line_range by >= 1 line
#
# Exit 0 iff every fixture passes (per-fixture pass lines on stdout);
# non-zero otherwise (per-fixture failure lines on stderr).
#
# Telemetry: --mode strict-gate writes nothing (its exit code is the
# merge-blocking signal). --mode canary and --mode self-test-manual append
# one telemetry row per fixture via scorecard-append.sh, tagged with a
# trigger field so the rolling-rate reader can count only
# post-settlement-canary rows.
#
# Pre-promotion contract: any change touching agents/reverse-auditor.md,
# scripts/judge-schemas/reverse-auditor-output.schema.json, the judge role
# model binding, or _headless_runner_invoke_once must clear
# `judge-quality-regression.sh reverse-auditor --mode strict-gate` before
# merge. A failing fixture blocks; retire aged-out fixtures only via
# scripts/retire-quality-fixture.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  sed -n '2,13p' "$0" >&2
  exit 1
}

JUDGE=""
MODE=""
ROLLING_REPORT=0
WINDOW=10
THRESHOLD="0.7"
FIXTURE=""
FIXTURE_DIR_OVERRIDE=""
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)          MODE="${2:?--mode requires a value}"; shift 2 ;;
    --rolling-report) ROLLING_REPORT=1; shift ;;
    --window)        WINDOW="${2:?--window requires a value}"; shift 2 ;;
    --threshold)     THRESHOLD="${2:?--threshold requires a value}"; shift 2 ;;
    --fixture)       FIXTURE="${2:?--fixture requires a value}"; shift 2 ;;
    --fixture-dir)   FIXTURE_DIR_OVERRIDE="${2:?--fixture-dir requires a value}"; shift 2 ;;
    --kdir)          KDIR_OVERRIDE="${2:?--kdir requires a value}"; shift 2 ;;
    -h|--help)       usage ;;
    -*)              echo "[judge-quality] Error: unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$JUDGE" ]]; then JUDGE="$1"; else echo "[judge-quality] Error: unexpected argument: $1" >&2; usage; fi
      shift ;;
  esac
done

[[ -n "$JUDGE" ]] || { echo "[judge-quality] Error: <judge> argument is required" >&2; usage; }
if [[ "$JUDGE" != "reverse-auditor" ]]; then
  echo "[judge-quality] Error: unsupported judge '$JUDGE' (only reverse-auditor is wired)" >&2
  exit 1
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KDIR" ]] || die "knowledge dir not found: $KDIR"

SUITE_DIR="$KDIR/_quality-fixtures/$JUDGE"
SCORECARD_ROWS="$KDIR/_scorecards/rows.jsonl"

# ---------------------------------------------------------------------------
# Rolling report: aggregate per-fixture reproduction rate from canary rows.
# ---------------------------------------------------------------------------
if [[ "$ROLLING_REPORT" -eq 1 ]]; then
  python3 - "$SCORECARD_ROWS" "$JUDGE" "$WINDOW" "$THRESHOLD" << 'PYEOF'
import json, sys
rows_path, judge, window, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
by_fixture = {}
try:
    fh = open(rows_path)
except OSError:
    print(f"[judge-quality] no scorecard rows at {rows_path}; no canary data yet")
    sys.exit(0)
with fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        if r.get("event_type") != "judge-quality-regression":
            continue
        if r.get("judge") != judge:
            continue
        # Only post-settlement canary rows drive the drift signal; manual
        # self-test runs are recorded but excluded from the rolling rate.
        if r.get("trigger") != "post-settlement-canary":
            continue
        fid = r.get("fixture_id") or "unknown"
        by_fixture.setdefault(fid, []).append((r.get("run_at") or "", r.get("value")))
if not by_fixture:
    print("[judge-quality] no post-settlement-canary rows yet; rolling rates unavailable")
    sys.exit(0)
suspects = []
print(f"[judge-quality] rolling reproduction rate (window={window}, threshold={threshold}):")
for fid in sorted(by_fixture):
    runs = sorted(by_fixture[fid], key=lambda t: t[0])[-window:]
    vals = [1 if v in (1, "1", True) else 0 for _, v in runs]
    rate = sum(vals) / len(vals)
    flag = ""
    if rate < threshold:
        flag = "  DRIFT-SUSPECT"
        suspects.append(fid)
    print(f"  {fid}: {rate:.2f} ({sum(vals)}/{len(vals)}){flag}")
if suspects:
    print(f"[judge-quality] drift-suspect fixtures: {', '.join(suspects)} — review for refresh or retirement (scripts/retire-quality-fixture.sh)")
PYEOF
  exit $?
fi

# ---------------------------------------------------------------------------
# Replay mode.
# ---------------------------------------------------------------------------
case "$MODE" in
  strict-gate|canary|self-test-manual) : ;;
  "")
    echo "[judge-quality] Error: --mode <strict-gate|canary|self-test-manual> is required for replay" >&2
    exit 1
    ;;
  *)
    echo "[judge-quality] Error: invalid --mode '$MODE' (must be strict-gate, canary, or self-test-manual)" >&2
    exit 1
    ;;
esac

FIXTURE_DIRS=()
if [[ -n "$FIXTURE_DIR_OVERRIDE" ]]; then
  [[ -d "$FIXTURE_DIR_OVERRIDE" ]] || die "fixture dir not found: $FIXTURE_DIR_OVERRIDE"
  FIXTURE_DIRS+=("$FIXTURE_DIR_OVERRIDE")
elif [[ -n "$FIXTURE" ]]; then
  [[ -d "$SUITE_DIR/$FIXTURE" ]] || die "fixture '$FIXTURE' not found under $SUITE_DIR"
  FIXTURE_DIRS+=("$SUITE_DIR/$FIXTURE")
else
  if [[ -d "$SUITE_DIR" ]]; then
    while IFS= read -r d; do
      FIXTURE_DIRS+=("$d")
    done < <(find "$SUITE_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  if [[ ${#FIXTURE_DIRS[@]} -eq 0 ]]; then
    die "no fixtures under $SUITE_DIR — capture one via scripts/capture-quality-fixture.sh"
  fi
fi

# Source the production invocation helpers from audit-artifact.sh: everything
# up to usage() (the helper functions), with `set -euo pipefail` relaxed so a
# failing fixture doesn't kill the loop, and SCRIPT_DIR pinned to the real
# scripts directory (the chunk's own assignment would resolve to the temp
# file's location).
AUDIT_SH="$SCRIPT_DIR/audit-artifact.sh"
HELPERS=$(mktemp "${TMPDIR:-/tmp}/judge-quality-helpers.XXXXXX")
RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/judge-quality-run.XXXXXX")
cleanup() {
  rm -f "$HELPERS" 2>/dev/null || true
}
trap cleanup EXIT

python3 - "$AUDIT_SH" "$HELPERS" "$SCRIPT_DIR" << 'PYEOF'
import sys
src_path, out_path, script_dir = sys.argv[1:4]
src = open(src_path).read()
end = src.index("usage() {")
chunk = src[:end]
chunk = chunk.replace("set -euo pipefail", "set -uo pipefail")
chunk = chunk.replace(
    'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
    f'SCRIPT_DIR="{script_dir}"',
)
open(out_path, "w").write(chunk)
PYEOF

# shellcheck disable=SC1090
source "$HELPERS"
# The sourced chunk initializes JUDGE_MODEL="" — restore the role binding.
JUDGE_MODEL="$(resolve_model_for_role judge)"
export JUDGE_MODEL
if [[ -z "$JUDGE_MODEL" ]]; then
  die "no model binding for role 'judge' (resolve_model_for_role returned empty)"
fi

RA_TEMPLATE="$(resolve_agent_template reverse-auditor)"
RA_TEMPLATE_VERSION="$(bash "$SCRIPT_DIR/template-version.sh" "$RA_TEMPLATE")"
SCHEMA_FILE="$SCRIPT_DIR/judge-schemas/reverse-auditor-output.schema.json"
RUN_AT=$(timestamp_iso)

emit_telemetry() {
  local fixture_id="$1" value="$2" captured_at_sha="$3" failure_gate="$4" diag_json="$5"
  local trigger
  case "$MODE" in
    canary)           trigger="post-settlement-canary" ;;
    self-test-manual) trigger="self-test-manual" ;;
    *) return 0 ;;
  esac
  local row
  row=$(FIXTURE_ID_V="$fixture_id" VALUE_V="$value" SHA_V="$captured_at_sha" \
        GATE_V="$failure_gate" DIAG_V="$diag_json" TRIGGER_V="$trigger" \
        TV_V="$RA_TEMPLATE_VERSION" MODEL_V="$JUDGE_MODEL" RUN_AT_V="$RUN_AT" \
        python3 << 'PYEOF'
import json, os
row = {
    "kind": "telemetry",
    "tier": "telemetry",
    "schema_version": "1",
    "calibration_state": "calibrated",
    "event_type": "judge-quality-regression",
    "metric": "fixture_replay_pass",
    "value": int(os.environ["VALUE_V"]),
    "fixture_id": os.environ["FIXTURE_ID_V"],
    "verdict_source": "reverse-auditor",
    "judge": "reverse-auditor",
    "template_id": "reverse-auditor",
    "template_version": os.environ["TV_V"],
    "model_variant": os.environ["MODEL_V"],
    "captured_at_sha": os.environ["SHA_V"],
    "trigger": os.environ["TRIGGER_V"],
    "run_at": os.environ["RUN_AT_V"],
}
if os.environ["GATE_V"]:
    row["failure_gate"] = os.environ["GATE_V"]
diag = os.environ.get("DIAG_V") or ""
if diag:
    try:
        row.update(json.loads(diag))
    except json.JSONDecodeError:
        pass
print(json.dumps(row))
PYEOF
  )
  if ! printf '%s' "$row" | bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" >/dev/null; then
    echo "[judge-quality] warning: scorecard append failed for fixture '$fixture_id'" >&2
  fi
}

FAILURES=0
TOTAL=0

for FIX_DIR in "${FIXTURE_DIRS[@]}"; do
  FIX_ID=$(basename "$FIX_DIR")
  TOTAL=$((TOTAL + 1))
  PACKET="$FIX_DIR/04-reverse-auditor-input.json"
  EXPECTED="$FIX_DIR/expected-emission.json"
  PROVENANCE="$FIX_DIR/provenance.json"

  for f in "$PACKET" "$EXPECTED" "$PROVENANCE"; do
    if [[ ! -f "$f" ]]; then
      echo "[judge-quality] FAIL $FIX_ID: missing fixture file $(basename "$f")" >&2
      FAILURES=$((FAILURES + 1))
      continue 2
    fi
  done

  CAPTURED_AT_SHA=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("captured_at_sha") or "unknown")' "$PROVENANCE")

  # Integrity check only — a mismatch is surfaced but replay proceeds: the
  # equivalence gates, not the hash, decide pass/fail (deliberate packet
  # mutation is the falsification test for this suite).
  EXPECTED_HASH=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("packet_content_hash") or "")' "$PROVENANCE")
  ACTUAL_HASH=$(shasum -a 256 "$PACKET" | cut -d' ' -f1)
  if [[ -n "$EXPECTED_HASH" && "$EXPECTED_HASH" != "$ACTUAL_HASH" ]]; then
    echo "[judge-quality] warning: $FIX_ID packet content hash mismatch — 04-reverse-auditor-input.json was modified after capture" >&2
  fi

  RUN_DIR="$RUN_ROOT/$FIX_ID"
  mkdir -p "$RUN_DIR"
  RUN_PACKET="$RUN_DIR/04-reverse-auditor-input.json"
  cp "$PACKET" "$RUN_PACKET"

  # Mirror of the production reverse-auditor prompt composition at the
  # scripts/audit-artifact.sh reverse-auditor callsite (user prompt, schema
  # constraint, --max-turns 3). Keep in sync when that callsite changes —
  # prompt drift here silently weakens production-equivalence of the bar.
  USER_PROMPT="Reverse-auditor input object — evidence already resolved and inlined under inlined_evidence (adjudicate from the packet alone; do not read files or run shell commands):

$(cat "$RUN_PACKET")

Use judge_template_version: $RA_TEMPLATE_VERSION

Emit exactly one JSON object matching this Reverse-auditor output shape:
{
  \"judge\": \"reverse-auditor\",
  \"judge_template_version\": \"$RA_TEMPLATE_VERSION\",
  \"work_item\": \"<slug>\",
  \"artifact_id\": \"<id>\",
  \"coverage_state\": \"covered\",
  \"abstention_reason\": null,
  \"insufficient_evidence_refs\": null,
  \"omission_claim\": null,
  \"created_at\": \"<ISO-8601 UTC>\"
}
Set coverage_state to \"insufficient-evidence\" (with abstention_reason + insufficient_evidence_refs, omission_claim null) when the inlined packet is inadequate to adjudicate. If you emit an omission, replace omission_claim null with the omission_claim object required by the template and keep coverage_state \"covered\". Do not emit legacy fields such as verdict_source, verdict, or claim. No markdown fences. No prose outside the JSON."

  OUTPUT_FILE="$RUN_DIR/emission.json"
  RUNNER_STDERR="$RUN_DIR/runner-stderr.log"

  echo "[judge-quality] $FIX_ID: invoking judge (model=$JUDGE_MODEL, template=$RA_TEMPLATE_VERSION, single attempt)" >&2
  RC=0
  LORE_JUDGE_MAX_ATTEMPTS=1 _headless_runner_invoke_once \
    "$RA_TEMPLATE" "$USER_PROMPT" "$OUTPUT_FILE" "$SCHEMA_FILE" 3 \
    2>"$RUNNER_STDERR" || RC=$?

  if [[ "$RC" -ne 0 ]]; then
    echo "[judge-quality] FAIL $FIX_ID: judge invocation failed (rc=$RC) — see $RUNNER_STDERR" >&2
    FAILURES=$((FAILURES + 1))
    emit_telemetry "$FIX_ID" 0 "$CAPTURED_AT_SHA" "invocation" ""
    continue
  fi

  VERDICT=$(python3 - "$OUTPUT_FILE" "$EXPECTED" "$SCHEMA_FILE" << 'PYEOF'
import json, sys

out_path, expected_path, schema_path = sys.argv[1:4]
result = {"pass": False, "failure_gate": None, "emitted_file": None, "emitted_line_range": None,
          "expected_file": None, "expected_line_range": None}


def emit(res):
    print(json.dumps(res))
    sys.exit(0)


expected = json.load(open(expected_path))
exp_claim = expected.get("omission_claim") or {}
result["expected_file"] = exp_claim.get("file")
result["expected_line_range"] = exp_claim.get("line_range")

try:
    emission = json.load(open(out_path))
except (OSError, json.JSONDecodeError) as e:
    result["failure_gate"] = "schema-valid"
    result["detail"] = f"emission unreadable: {e}"
    emit(result)

# Gate 1: schema-valid.
try:
    import jsonschema
    jsonschema.validate(emission, json.load(open(schema_path)))
except ImportError:
    # jsonschema unavailable: fall back to the required-field subset the
    # production shape validator enforces.
    required = ("judge", "judge_template_version", "work_item", "artifact_id",
                "coverage_state", "omission_claim", "created_at")
    missing = [k for k in required if k not in emission]
    if missing:
        result["failure_gate"] = "schema-valid"
        result["detail"] = f"missing fields: {missing}"
        emit(result)
except jsonschema.ValidationError as e:
    result["failure_gate"] = "schema-valid"
    result["detail"] = e.message[:300]
    emit(result)

# Gate 2: omission_claim non-null (silence is a regression on an
# omission-positive fixture).
claim = emission.get("omission_claim")
if not isinstance(claim, dict):
    result["failure_gate"] = "omission-nonnull"
    result["detail"] = f"coverage_state={emission.get('coverage_state')!r}, abstention_reason={emission.get('abstention_reason')!r}"
    emit(result)

result["emitted_file"] = claim.get("file")
result["emitted_line_range"] = claim.get("line_range")

# Gate 3: file equality (nothing was rewritten at replay, so emitted and
# expected are both the original captured path).
if claim.get("file") != exp_claim.get("file"):
    result["failure_gate"] = "file-match"
    emit(result)


def parse_range(lr):
    try:
        a, b = str(lr).split("-", 1)
        return int(a), int(b)
    except (ValueError, AttributeError):
        return None


# Gate 4: line_range overlap >= 1 line.
got = parse_range(claim.get("line_range"))
want = parse_range(exp_claim.get("line_range"))
if got is None or want is None:
    result["failure_gate"] = "line-range-overlap"
    result["detail"] = "unparseable line_range"
    emit(result)
if not (max(got[0], want[0]) <= min(got[1], want[1])):
    result["failure_gate"] = "line-range-overlap"
    emit(result)

result["pass"] = True
emit(result)
PYEOF
  )

  PASS=$(printf '%s' "$VERDICT" | python3 -c 'import json,sys; print("1" if json.load(sys.stdin)["pass"] else "0")')
  FAILURE_GATE=$(printf '%s' "$VERDICT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("failure_gate") or "")')
  DIAG=$(printf '%s' "$VERDICT" | python3 -c '
import json, sys
v = json.load(sys.stdin)
print(json.dumps({k: v[k] for k in ("expected_file", "expected_line_range", "emitted_file", "emitted_line_range") if v.get(k)}))
')

  if [[ "$PASS" == "1" ]]; then
    echo "[judge-quality] PASS $FIX_ID (file + line_range reproduced; emission at $OUTPUT_FILE)"
  else
    echo "[judge-quality] FAIL $FIX_ID: gate=$FAILURE_GATE — $VERDICT (emission at $OUTPUT_FILE)" >&2
    FAILURES=$((FAILURES + 1))
  fi
  emit_telemetry "$FIX_ID" "$PASS" "$CAPTURED_AT_SHA" "$FAILURE_GATE" "$DIAG"
done

echo "[judge-quality] $((TOTAL - FAILURES))/$TOTAL fixtures passed (run artifacts under $RUN_ROOT)" >&2
if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
exit 0
