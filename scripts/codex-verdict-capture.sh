#!/usr/bin/env bash
# codex-verdict-capture.sh — Route structured Codex advisor verdicts into
# scorecard rows targeting the relevant template version.
#
# Invoked by:
#   - skills/codex-plan-review/SKILL.md after Codex returns its 6-criterion
#     rating — captures verdicts against the /spec template version.
#   - skills/codex-pr-review/SKILL.md after Codex returns its review —
#     captures verdicts against the /pr-review template version.
#
# Codex becomes a measured external judge: verdict accuracy is itself
# scorable across runs. Rows land in `$KDIR/_scorecards/rows.jsonl` with
# `kind=scored` so /evolve can cite them; the producer-template-version
# they attribute to is the template that generated the *artifact being
# reviewed* (the spec plan or the PR), not the codex-reviewer template.
# The codex reviewer's own accuracy is a separate metric tracked via the
# advisor-impact settlement path (task-51).
#
# Usage (flag form):
#   lore codex-verdict capture \
#     --source-ceremony <spec | pr-review> \
#     --producer-template-version <hash> \
#     --verdict-json '<codex structured output>' \
#     [--work-item <slug>] [--sample-size N] [--kdir <path>]
#
# Usage (--row form):
#   lore codex-verdict capture --row '<pre-built scorecard row json>'
#
# Input JSON shape for --verdict-json (matches codex-plan-review output
# at the 6-criterion layer):
#   {
#     "ratings": {
#       "Objective and Scope": "STRONG | ADEQUATE | WEAK | MISSING",
#       "Evidence and Uncertainty": "...",
#       "Interface Clarity": "...",
#       "Design Coherence": "...",
#       "Execution Readiness": "...",
#       "Validation and Traceability": "..."
#     },
#     "gate": "pass | fail"
#   }
#
# For codex-pr-review, the ratings map has different keys but the same
# STRONG/ADEQUATE/WEAK/MISSING enum. The script treats any rating map
# the same way — one row per criterion, mapped to [0, 1] via:
#   STRONG    = 1.00
#   ADEQUATE  = 0.75
#   WEAK      = 0.25
#   MISSING   = 0.00
# plus one aggregate gate row (gate: pass=1.0, fail=0.0).
#
# All emitted rows:
#   kind            = "scored"
#   calibration_state = "pre-calibration" (codex reviewer not yet calibrated)
#   template_id     = "codex-plan-review" or "codex-pr-review"
#   metric          = "criterion:<name>" (sanitized) or "gate"
#   granularity     = "set-level"
#
# Sole-writer compliance: this script does NOT write rows.jsonl directly.
# It constructs row JSON and shells out to `scripts/scorecard-append.sh`
# for each row, which is the sole sanctioned writer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SOURCE_CEREMONY=""
PRODUCER_TEMPLATE_VERSION=""
VERDICT_JSON=""
WORK_ITEM=""
SAMPLE_SIZE="1"
ROW_JSON=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
lore codex-verdict capture — append codex advisor verdicts to rows.jsonl

Usage:
  lore codex-verdict capture --source-ceremony <spec|pr-review>
                             --producer-template-version <hash>
                             --verdict-json '<json>'
                             [--work-item <slug>] [--sample-size N]
                             [--kdir <path>] [--json]
  lore codex-verdict capture --row '<row json>'

See header of this script for the verdict-json shape and row attribution.
EOF
}

if [[ $# -gt 0 && "$1" == "capture" ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --source-ceremony)
      SOURCE_CEREMONY="$2"
      shift 2
      ;;
    --producer-template-version)
      PRODUCER_TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --verdict-json)
      VERDICT_JSON="$2"
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
    --row)
      ROW_JSON="$2"
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
      echo "[codex-verdict] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# Resolve KDIR.
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

# --row fast-path: validate + forward to scorecard-append.
if [[ -n "$ROW_JSON" ]]; then
  APPEND="$SCRIPT_DIR/scorecard-append.sh"
  "$APPEND" --row "$ROW_JSON" --kdir "$KDIR" ${JSON_MODE:+--json}
  exit 0
fi

# Validate flag-form required fields.
if [[ -z "$SOURCE_CEREMONY" || -z "$PRODUCER_TEMPLATE_VERSION" || -z "$VERDICT_JSON" ]]; then
  echo "[codex-verdict] Error: --source-ceremony, --producer-template-version, --verdict-json are required" >&2
  usage
  exit 1
fi

case "$SOURCE_CEREMONY" in
  spec|pr-review) ;;
  *)
    echo "[codex-verdict] Error: --source-ceremony must be 'spec' or 'pr-review', got '$SOURCE_CEREMONY'" >&2
    exit 1
    ;;
esac

TEMPLATE_ID="codex-plan-review"
if [[ "$SOURCE_CEREMONY" == "pr-review" ]]; then
  TEMPLATE_ID="codex-pr-review"
fi

WINDOW=$(timestamp_iso)
APPEND="$SCRIPT_DIR/scorecard-append.sh"

# Expand the verdict JSON into per-criterion and gate rows, invoking
# scorecard-append for each. Python handles the JSON + enum mapping and
# shells back out for each append call (sole-writer invariant preserved).
export CODEX_VERDICT_JSON="$VERDICT_JSON"
export CODEX_TEMPLATE_ID="$TEMPLATE_ID"
export CODEX_PRODUCER_VERSION="$PRODUCER_TEMPLATE_VERSION"
export CODEX_WORK_ITEM="$WORK_ITEM"
export CODEX_SAMPLE_SIZE="$SAMPLE_SIZE"
export CODEX_WINDOW="$WINDOW"
export CODEX_APPEND_SCRIPT="$APPEND"
export CODEX_KDIR="$KDIR"
export CODEX_JSON_MODE="$JSON_MODE"

python3 <<'PYEOF'
import json, os, re, subprocess, sys

RATING_TO_VALUE = {
    "STRONG": 1.0,
    "ADEQUATE": 0.75,
    "WEAK": 0.25,
    "MISSING": 0.0,
}
GATE_TO_VALUE = {"pass": 1.0, "fail": 0.0}

verdict_json = os.environ.get("CODEX_VERDICT_JSON", "").strip()
template_id = os.environ["CODEX_TEMPLATE_ID"]
producer_version = os.environ["CODEX_PRODUCER_VERSION"]
work_item = os.environ.get("CODEX_WORK_ITEM") or ""
sample_size = int(os.environ.get("CODEX_SAMPLE_SIZE") or "1")
window = os.environ["CODEX_WINDOW"]
append_script = os.environ["CODEX_APPEND_SCRIPT"]
kdir = os.environ["CODEX_KDIR"]
json_mode = os.environ.get("CODEX_JSON_MODE", "0") == "1"

try:
    verdict = json.loads(verdict_json)
except json.JSONDecodeError as e:
    print(f"[codex-verdict] Error: --verdict-json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(verdict, dict):
    print("[codex-verdict] Error: verdict must be a JSON object", file=sys.stderr)
    sys.exit(1)

ratings = verdict.get("ratings", {}) or {}
gate = verdict.get("gate")

if not isinstance(ratings, dict) or not ratings:
    print("[codex-verdict] Error: verdict.ratings must be a non-empty object", file=sys.stderr)
    sys.exit(1)

def slugify(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")

rows_to_append: list[dict] = []
invalid_ratings = []

for criterion_name, rating in ratings.items():
    rating_upper = str(rating).strip().upper()
    if rating_upper not in RATING_TO_VALUE:
        invalid_ratings.append((criterion_name, rating))
        continue
    metric = f"criterion:{slugify(criterion_name)}"
    rows_to_append.append({
        "schema_version": "1",
        "template_id": template_id,
        "template_version": producer_version,
        "metric": metric,
        "value": RATING_TO_VALUE[rating_upper],
        "sample_size": sample_size,
        "window_start": window,
        "window_end": window,
        "source_artifact_ids": [work_item] if work_item else [],
        "granularity": "set-level",
        "kind": "scored",
        "tier": "reusable",
        "calibration_state": "pre-calibration",
        "rating_label": rating_upper,
        "criterion_name": criterion_name,
    })

if invalid_ratings:
    for name, rating in invalid_ratings:
        print(f"[codex-verdict] Warning: skipping criterion '{name}' with unknown rating '{rating}'", file=sys.stderr)

if gate is not None:
    gate_key = str(gate).strip().lower()
    if gate_key in GATE_TO_VALUE:
        rows_to_append.append({
            "schema_version": "1",
            "template_id": template_id,
            "template_version": producer_version,
            "metric": "gate",
            "value": GATE_TO_VALUE[gate_key],
            "sample_size": sample_size,
            "window_start": window,
            "window_end": window,
            "source_artifact_ids": [work_item] if work_item else [],
            "granularity": "set-level",
            "kind": "scored",
            "tier": "reusable",
            "calibration_state": "pre-calibration",
            "gate_label": gate_key,
        })
    else:
        print(f"[codex-verdict] Warning: skipping unknown gate value '{gate}'", file=sys.stderr)

if not rows_to_append:
    print("[codex-verdict] Error: no valid rows to append", file=sys.stderr)
    sys.exit(1)

appended = []
for row in rows_to_append:
    row_json = json.dumps(row, separators=(",", ":"))
    result = subprocess.run(
        ["bash", append_script, "--row", row_json, "--kdir", kdir],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        print(
            f"[codex-verdict] Error: scorecard-append failed for {row.get('metric')}: "
            f"{result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)
    appended.append(row.get("metric"))

if json_mode:
    print(json.dumps({"status": "appended", "rows": appended}, indent=2))
else:
    print(f"[codex-verdict] appended {len(appended)} rows: {', '.join(appended)}")
PYEOF
