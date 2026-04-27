#!/usr/bin/env bash
# fidelity-verdict-capture.sh — Route structured fidelity-judge verdicts into
# scorecard rows targeting the worker template version that produced the
# artifact being judged.
#
# Invoked by:
#   - skills/implement/SKILL.md Step 4 after the fidelity-judge emits a
#     verdict JSON for a sampled task — captures one scored row per verdict
#     dimension against the worker template version.
#
# The fidelity-judge becomes a measured in-band judge of worker-output
# fidelity: verdict distributions are themselves scorable across template
# versions. Rows land in `$KDIR/_scorecards/rows.jsonl` with `kind=scored`
# so /retro Step 3.9 (7th MVP metric family) and /evolve can cite them.
# The producer attribution is the worker template (the template that
# produced the artifact being judged), NOT the fidelity-judge template.
# Judge provenance rides in sidecar `verdict_source` and
# `judge_template_version` fields. Judge quality is measured separately by
# the Phase 5 eval harness against curated fixtures, not by the production
# drift distribution. This matches the audit-pipeline contract's per-judge
# row attribution table and the codex-verdict-capture.sh convention.
#
# Usage:
#   bash scripts/fidelity-verdict-capture.sh \
#     --work-slug <slug> --artifact-key <key> [--kdir <path>] [--json] \
#     < <fidelity-artifact-json>
#
# Input JSON shape on stdin (matches scripts/schemas/fidelity.json):
#   kind: "verdict" — four scored rows emitted
#     {
#       "kind": "verdict",
#       "artifact_key": "<12-hex>",
#       "phase": "phase-N",
#       "worker_template_version": "<12-hex hash>",
#       "judge_template_version": "<12-hex hash>",
#       "verdict": "aligned | drifted | contradicts | unjudgeable",
#       "evidence": {
#         "rationale": "...",
#         "claim_ids_used": ["<slug>", ...]
#       },
#       "trigger": "...",
#       "timestamp": "<ISO8601>"
#     }
#   kind: "exempt" — zero rows emitted (wrapper exits 0 without calling
#   scorecard-append)
#
# Emission contract (per scored row, all four emitted per verdict artifact):
#   schema_version           "1"
#   kind                     "scored"
#   calibration_state        "pre-calibration"
#   tier                     "template"
#   template_id              "worker"
#   template_version         <worker_template_version from artifact>
#   verdict_source           "fidelity-judge"
#   judge_template_version   <judge_template_version from artifact>
#   metric                   "fidelity_verdict_{aligned|drifted|contradicts|unjudgeable}"
#   value                    1.0 for this artifact's verdict dimension, 0.0 for the other three
#   granularity              "portfolio-level"
#   source_artifact_ids      ["_work/<slug>/_fidelity/<artifact-key>.json"] + evidence.claim_ids_used
#   window_start/window_end  <ISO8601 — uses artifact timestamp>
#   sample_size              1
#
# Sole-writer compliance: this script does NOT write rows.jsonl directly.
# It constructs row JSON and shells out to `scripts/scorecard-append.sh`
# for each row, which is the sole sanctioned writer.
#
# --telemetry mode (Phase 6): when invoked with --telemetry, the script
# accepts a JSON payload on stdin with `metric`, `value`, `telemetry_label`,
# `source_artifact_ids`, and `template_version` (the judge template hash —
# required) and emits one `kind: "telemetry"` / `tier: "telemetry"` row.
# Telemetry rows are observability-only: they MUST NOT be cited by /evolve
# (enforced by /evolve's `kind == scored` filter and /retro Step 3.5's
# `tier: telemetry` filter — see plan.md Phase 6 line 688).
#
# Telemetry-mode stdin shape:
#   {
#     "metric": "fidelity_branch_choice_respawn",
#     "value": 1.0,
#     "telemetry_label": "respawn",
#     "source_artifact_ids": ["_work/<slug>/_fidelity/<key>.json", ...],
#     "template_version": "<judge template hash>"
#   }
# Emission shape (all fields):
#   schema_version "1", kind "telemetry", tier "telemetry",
#   calibration_state "pre-calibration", template_id "fidelity-judge",
#   template_version <from payload>, granularity "portfolio-level",
#   metric/value/telemetry_label/source_artifact_ids <from payload>,
#   window_start/window_end <ISO8601 — current time>, sample_size 1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORK_SLUG=""
ARTIFACT_KEY=""
KDIR_OVERRIDE=""
JSON_MODE=0
TELEMETRY_MODE=0

usage() {
  cat >&2 <<EOF
fidelity-verdict-capture.sh — append fidelity-judge verdicts (or telemetry rows) to rows.jsonl

Usage (scored — default):
  bash scripts/fidelity-verdict-capture.sh \\
    --work-slug <slug> --artifact-key <key> \\
    [--kdir <path>] [--json] < <fidelity-artifact-json>

Usage (telemetry — Phase 6 branch-event observability):
  echo '<telemetry-payload-json>' | bash scripts/fidelity-verdict-capture.sh \\
    --telemetry [--kdir <path>] [--json]

See the header of this script for the input JSON shape and emission
contract for both modes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --work-slug)
      WORK_SLUG="$2"
      shift 2
      ;;
    --artifact-key)
      ARTIFACT_KEY="$2"
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
    --telemetry)
      TELEMETRY_MODE=1
      shift
      ;;
    *)
      echo "[fidelity-verdict] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ $TELEMETRY_MODE -eq 0 ]]; then
  if [[ -z "$WORK_SLUG" || -z "$ARTIFACT_KEY" ]]; then
    echo "[fidelity-verdict] Error: --work-slug and --artifact-key are required (scored mode)" >&2
    usage
    exit 1
  fi
fi

if [[ -t 0 ]]; then
  if [[ $TELEMETRY_MODE -eq 1 ]]; then
    echo "[fidelity-verdict] Error: telemetry payload JSON must be piped on stdin" >&2
  else
    echo "[fidelity-verdict] Error: fidelity artifact JSON must be piped on stdin" >&2
  fi
  usage
  exit 1
fi

ARTIFACT_JSON=$(cat)

if [[ -z "${ARTIFACT_JSON// }" ]]; then
  echo "[fidelity-verdict] Error: stdin JSON is empty" >&2
  exit 1
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

APPEND="$SCRIPT_DIR/scorecard-append.sh"

export FIDELITY_ARTIFACT_JSON="$ARTIFACT_JSON"
export FIDELITY_WORK_SLUG="$WORK_SLUG"
export FIDELITY_ARTIFACT_KEY="$ARTIFACT_KEY"
export FIDELITY_APPEND_SCRIPT="$APPEND"
export FIDELITY_KDIR="$KDIR"
export FIDELITY_JSON_MODE="$JSON_MODE"
export FIDELITY_TELEMETRY_MODE="$TELEMETRY_MODE"

python3 <<'PYEOF'
import json, os, subprocess, sys
from datetime import datetime, timezone

VERDICT_DIMENSIONS = ["aligned", "drifted", "contradicts", "unjudgeable"]
TELEMETRY_MODE = os.environ.get("FIDELITY_TELEMETRY_MODE", "0") == "1"

artifact_json = os.environ.get("FIDELITY_ARTIFACT_JSON", "").strip()
work_slug = os.environ.get("FIDELITY_WORK_SLUG", "")
artifact_key = os.environ.get("FIDELITY_ARTIFACT_KEY", "")
append_script = os.environ["FIDELITY_APPEND_SCRIPT"]
kdir = os.environ["FIDELITY_KDIR"]
json_mode = os.environ.get("FIDELITY_JSON_MODE", "0") == "1"

try:
    payload = json.loads(artifact_json)
except json.JSONDecodeError as e:
    print(f"[fidelity-verdict] Error: stdin is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload, dict):
    print("[fidelity-verdict] Error: stdin payload must be a JSON object", file=sys.stderr)
    sys.exit(1)


def call_append(row):
    row_json = json.dumps(row, separators=(",", ":"))
    return subprocess.run(
        ["bash", append_script, "--row", row_json, "--kdir", kdir],
        capture_output=True,
        text=True,
        timeout=5,
    )


if TELEMETRY_MODE:
    metric = payload.get("metric")
    if not isinstance(metric, str) or not metric:
        print(
            "[fidelity-verdict] Error: telemetry payload missing non-empty 'metric'",
            file=sys.stderr,
        )
        sys.exit(1)

    raw_value = payload.get("value")
    if not isinstance(raw_value, (int, float)) or isinstance(raw_value, bool):
        print(
            "[fidelity-verdict] Error: telemetry payload 'value' must be a number (1.0 or 0.0)",
            file=sys.stderr,
        )
        sys.exit(1)
    value = float(raw_value)

    telemetry_label = payload.get("telemetry_label")
    if not isinstance(telemetry_label, str) or not telemetry_label:
        print(
            "[fidelity-verdict] Error: telemetry payload missing non-empty 'telemetry_label'",
            file=sys.stderr,
        )
        sys.exit(1)

    source_artifact_ids = payload.get("source_artifact_ids", [])
    if not isinstance(source_artifact_ids, list):
        print(
            "[fidelity-verdict] Error: telemetry payload 'source_artifact_ids' must be an array",
            file=sys.stderr,
        )
        sys.exit(1)
    source_artifact_ids = [str(s) for s in source_artifact_ids if isinstance(s, (str, int))]

    template_version = payload.get("template_version")
    if not isinstance(template_version, str) or not template_version:
        print(
            "[fidelity-verdict] Error: telemetry payload missing non-empty 'template_version' (judge template hash)",
            file=sys.stderr,
        )
        sys.exit(1)

    window = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = {
        "schema_version": "1",
        "kind": "telemetry",
        "tier": "telemetry",
        "calibration_state": "pre-calibration",
        "template_id": "fidelity-judge",
        "template_version": template_version,
        "granularity": "portfolio-level",
        "metric": metric,
        "value": value,
        "telemetry_label": telemetry_label,
        "source_artifact_ids": source_artifact_ids,
        "window_start": window,
        "window_end": window,
        "sample_size": 1,
    }

    result = call_append(row)
    if result.returncode != 0:
        print(
            f"[fidelity-verdict] Error: scorecard-append failed for telemetry metric {metric}: "
            f"{result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)

    if json_mode:
        print(json.dumps({"status": "appended", "kind": "telemetry", "metric": metric}, indent=2))
    else:
        print(f"[fidelity-verdict] appended 1 telemetry row: metric={metric} label={telemetry_label}")
    sys.exit(0)


# --- Scored mode (default) ---
artifact = payload

kind = artifact.get("kind")
if kind == "exempt":
    msg = "[fidelity-verdict] kind=exempt — zero rows emitted (by design)"
    if json_mode:
        print(json.dumps({"status": "skipped", "kind": "exempt", "rows": []}, indent=2))
    else:
        print(msg)
    sys.exit(0)

if kind != "verdict":
    print(
        f"[fidelity-verdict] Error: artifact kind must be 'verdict' or 'exempt', got '{kind}'",
        file=sys.stderr,
    )
    sys.exit(1)

verdict = artifact.get("verdict")
if verdict not in VERDICT_DIMENSIONS:
    print(
        f"[fidelity-verdict] Error: verdict must be one of {VERDICT_DIMENSIONS}, got '{verdict}'",
        file=sys.stderr,
    )
    sys.exit(1)

worker_template_version = artifact.get("worker_template_version")
if not isinstance(worker_template_version, str) or not worker_template_version:
    print(
        "[fidelity-verdict] Error: artifact missing non-empty worker_template_version",
        file=sys.stderr,
    )
    sys.exit(1)

judge_template_version = artifact.get("judge_template_version")
if not isinstance(judge_template_version, str) or not judge_template_version:
    print(
        "[fidelity-verdict] Error: artifact missing non-empty judge_template_version",
        file=sys.stderr,
    )
    sys.exit(1)

evidence = artifact.get("evidence") or {}
if not isinstance(evidence, dict):
    print("[fidelity-verdict] Error: artifact.evidence must be an object", file=sys.stderr)
    sys.exit(1)

claim_ids_used = evidence.get("claim_ids_used", [])
if not isinstance(claim_ids_used, list):
    print(
        "[fidelity-verdict] Error: artifact.evidence.claim_ids_used must be an array",
        file=sys.stderr,
    )
    sys.exit(1)
claim_ids_used = [str(c) for c in claim_ids_used if isinstance(c, (str, int))]

timestamp = artifact.get("timestamp")
if not isinstance(timestamp, str) or not timestamp:
    print(
        "[fidelity-verdict] Error: artifact missing non-empty timestamp",
        file=sys.stderr,
    )
    sys.exit(1)

artifact_path = f"_work/{work_slug}/_fidelity/{artifact_key}.json"
source_artifact_ids = [artifact_path] + claim_ids_used

rows_to_append = []
for dimension in VERDICT_DIMENSIONS:
    value = 1.0 if dimension == verdict else 0.0
    rows_to_append.append({
        "schema_version": "1",
        "kind": "scored",
        "calibration_state": "pre-calibration",
        "tier": "template",
        "template_id": "worker",
        "template_version": worker_template_version,
        "verdict_source": "fidelity-judge",
        "judge_template_version": judge_template_version,
        "metric": f"fidelity_verdict_{dimension}",
        "value": value,
        "granularity": "portfolio-level",
        "source_artifact_ids": source_artifact_ids,
        "window_start": timestamp,
        "window_end": timestamp,
        "sample_size": 1,
    })

appended = []
for row in rows_to_append:
    result = call_append(row)
    if result.returncode != 0:
        print(
            f"[fidelity-verdict] Error: scorecard-append failed for {row.get('metric')}: "
            f"{result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)
    appended.append(row.get("metric"))

if json_mode:
    print(json.dumps({"status": "appended", "kind": "verdict", "verdict": verdict, "rows": appended}, indent=2))
else:
    print(f"[fidelity-verdict] appended {len(appended)} rows (verdict={verdict}): {', '.join(appended)}")
PYEOF
