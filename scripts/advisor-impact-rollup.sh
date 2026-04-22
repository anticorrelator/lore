#!/usr/bin/env bash
# advisor-impact-rollup.sh — Roll up advisor_consultations entries from a
# worker report into scorecard rows attributing to the advisor template.
#
# Invoked after a worker report is produced. The report's optional
# "Advisor consultations:" section contains one YAML-list entry per
# consultation; this script parses the entries, groups by
# advisor_template_version, and emits two scorecard rows per advisor:
#
#   consultation_rate   = 1.0 per report-that-consulted-this-advisor
#                         (the rate is computed at retro-window rollup
#                          time; this writer emits a 1.0-weighted row
#                          per consultation event, which averages cleanly
#                          across reports)
#   advice_followed_rate = mean(was_followed) over all consultations of
#                          this advisor in the report
#
# Both rows carry kind=scored, calibration_state=pre-calibration. The
# template scored is the ADVISOR's template (template_id =
# advisor_template_version), NOT the producer's — advisor quality is
# scored separately from the quality of artifacts the advisor reviews.
# Conflating them (as codex-verdict-capture.sh's note warns) would let
# advisor-regression noise drive producer-template mutation.
#
# Usage (flag form):
#   lore advisor-impact rollup \
#     --consultations-json '<yaml-or-json array>' \
#     --work-item <slug> \
#     [--sample-size N] [--kdir <path>] [--json]
#
# Usage (stdin):
#   echo '<json array>' | lore advisor-impact rollup --work-item <slug>
#
# Consultation entry shape (accepts both YAML block and JSON array):
#   [
#     {
#       "advisor_template_version": "<12-char hash>",
#       "query_summary": "...",
#       "advice_summary": "...",
#       "was_followed": true | false,
#       "rationale_if_not_followed": "..." (required iff was_followed=false)
#     }
#   ]
#
# Sole-writer invariant preserved: shells out to scripts/scorecard-append.sh
# per row. Multiple consultations to the same advisor produce a single
# rolled-up pair of rows for that advisor in this report (consultation_rate
# stays at 1.0 per report-per-advisor; advice_followed_rate averages over
# the consultations).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CONSULTATIONS_JSON=""
WORK_ITEM=""
SAMPLE_SIZE=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
lore advisor-impact rollup — roll up advisor consultations into scorecard rows

Usage:
  lore advisor-impact rollup --consultations-json '<json>' --work-item <slug>
                             [--sample-size N] [--kdir <path>] [--json]
  echo '<json>' | lore advisor-impact rollup --work-item <slug>

Input: JSON array of consultation objects. See header of this script for
       the object shape. Accepts an empty array (no rollup emitted).
EOF
}

if [[ $# -gt 0 && "$1" == "rollup" ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --consultations-json)
      CONSULTATIONS_JSON="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --sample-size)
      SAMPLE_SIZE="$2"
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
      echo "[advisor-impact] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_ITEM" ]]; then
  echo "[advisor-impact] Error: --work-item is required" >&2
  usage
  exit 1
fi

# Read consultations from stdin if not provided as flag.
if [[ -z "$CONSULTATIONS_JSON" ]]; then
  if [[ -t 0 ]]; then
    echo "[advisor-impact] Error: no --consultations-json and stdin is a tty" >&2
    usage
    exit 1
  fi
  CONSULTATIONS_JSON=$(cat)
fi

if [[ -z "$CONSULTATIONS_JSON" ]]; then
  echo "[advisor-impact] Error: empty consultations input" >&2
  exit 1
fi

# Resolve KDIR.
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

WINDOW=$(timestamp_iso)
APPEND="$SCRIPT_DIR/scorecard-append.sh"

export ADVISOR_CONSULTATIONS_JSON="$CONSULTATIONS_JSON"
export ADVISOR_WORK_ITEM="$WORK_ITEM"
export ADVISOR_SAMPLE_SIZE="${SAMPLE_SIZE:-1}"
export ADVISOR_WINDOW="$WINDOW"
export ADVISOR_APPEND_SCRIPT="$APPEND"
export ADVISOR_KDIR="$KDIR"
export ADVISOR_JSON_MODE="$JSON_MODE"

python3 <<'PYEOF'
import json, os, subprocess, sys
from collections import defaultdict

raw = os.environ.get("ADVISOR_CONSULTATIONS_JSON", "").strip()
work_item = os.environ["ADVISOR_WORK_ITEM"]
sample_size = int(os.environ.get("ADVISOR_SAMPLE_SIZE") or "1")
window = os.environ["ADVISOR_WINDOW"]
append_script = os.environ["ADVISOR_APPEND_SCRIPT"]
kdir = os.environ["ADVISOR_KDIR"]
json_mode = os.environ.get("ADVISOR_JSON_MODE", "0") == "1"

try:
    consultations = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"[advisor-impact] Error: consultations is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(consultations, list):
    print("[advisor-impact] Error: consultations must be a JSON array", file=sys.stderr)
    sys.exit(1)

# Empty array → no rollup, no rows. Valid state (report had no consultations).
if not consultations:
    if json_mode:
        print(json.dumps({"status": "no-consultations", "rows": []}, indent=2))
    else:
        print("[advisor-impact] no consultations to roll up")
    sys.exit(0)

# Group by advisor_template_version + validate.
by_advisor: dict[str, list[dict]] = defaultdict(list)
errors: list[str] = []

for i, entry in enumerate(consultations):
    if not isinstance(entry, dict):
        errors.append(f"entry {i}: not an object")
        continue
    advisor = entry.get("advisor_template_version")
    if not advisor or not isinstance(advisor, str):
        errors.append(f"entry {i}: missing or invalid advisor_template_version")
        continue
    was_followed = entry.get("was_followed")
    if not isinstance(was_followed, bool):
        errors.append(f"entry {i}: was_followed must be a boolean, got {was_followed!r}")
        continue
    if not was_followed:
        rationale = entry.get("rationale_if_not_followed")
        if not rationale or not isinstance(rationale, str):
            errors.append(
                f"entry {i}: was_followed=false requires non-empty rationale_if_not_followed"
            )
            continue
    by_advisor[advisor].append(entry)

if errors:
    for e in errors:
        print(f"[advisor-impact] Validation error: {e}", file=sys.stderr)
    sys.exit(1)

rows: list[dict] = []
for advisor, entries in by_advisor.items():
    followed_count = sum(1 for e in entries if e["was_followed"])
    n = len(entries)
    advice_followed_rate = followed_count / n

    # consultation_rate row: 1.0 per report-per-advisor. A retro-window
    # rollup divides by |reports| to get the rate across reports.
    rows.append({
        "schema_version": "1",
        "template_id": "advisor",
        "template_version": advisor,
        "metric": "consultation_rate",
        "value": 1.0,
        "sample_size": sample_size,
        "window_start": window,
        "window_end": window,
        "source_artifact_ids": [work_item] if work_item else [],
        "granularity": "set-level",
        "kind": "scored",
        "calibration_state": "pre-calibration",
        "consultations_in_report": n,
    })

    # advice_followed_rate row: averaged over consultations in this report.
    rows.append({
        "schema_version": "1",
        "template_id": "advisor",
        "template_version": advisor,
        "metric": "advice_followed_rate",
        "value": advice_followed_rate,
        "sample_size": n,  # per-consultation sample, not per-report
        "window_start": window,
        "window_end": window,
        "source_artifact_ids": [work_item] if work_item else [],
        "granularity": "set-level",
        "kind": "scored",
        "calibration_state": "pre-calibration",
        "followed_count": followed_count,
        "total_consultations": n,
    })

appended: list[str] = []
for row in rows:
    row_json = json.dumps(row, separators=(",", ":"))
    result = subprocess.run(
        ["bash", append_script, "--row", row_json, "--kdir", kdir],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        print(
            f"[advisor-impact] Error: scorecard-append failed for "
            f"{row['template_version']}/{row['metric']}: {result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)
    appended.append(f"{row['template_version']}/{row['metric']}")

if json_mode:
    print(json.dumps({"status": "appended", "rows": appended, "advisors": list(by_advisor.keys())}, indent=2))
else:
    print(f"[advisor-impact] appended {len(appended)} rows across {len(by_advisor)} advisors")
PYEOF
