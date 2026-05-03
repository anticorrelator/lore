#!/usr/bin/env bash
# renormalize-emit-drift-guardrails.sh — Emit scale_drift_rate guardrail rows per producer_role.
#
# Reads $KDIR/_meta/classification-report.json (disagreements array from classifier)
# and $KDIR/_manifest.json (producer_role per entry), aggregates disagreement counts
# by role, then calls scorecard-append.sh once per role.
#
# Usage:
#   renormalize-emit-drift-guardrails.sh [--kdir <path>] [--run-id <id>]
#
# Options:
#   --kdir    Override knowledge directory (default: lore resolve)
#   --run-id  Renormalize run identifier included in each row (default: timestamp)
#
# Exit codes:
#   0 — success (even if 0 rows emitted)
#   1 — setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

KDIR=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)   KDIR="$2";   shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<'HELPEOF'
Usage: renormalize-emit-drift-guardrails.sh [--kdir <path>] [--run-id <id>]

Aggregates classifier disagreements by producer_role and emits one
scale_drift_rate telemetry row per role via scorecard-append.sh.

Reads:  $KDIR/_meta/classification-report.json
        $KDIR/_manifest.json
Writes: $KDIR/_scorecards/rows.jsonl (via scorecard-append.sh)
HELPEOF
      exit 0
      ;;
    *) echo "Error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$KDIR" ]]; then
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  die "knowledge directory not found: $KDIR"
fi

CLASSIFICATION_REPORT="$KDIR/_meta/classification-report.json"
MANIFEST="$KDIR/_manifest.json"

if [[ ! -f "$CLASSIFICATION_REPORT" ]]; then
  echo "[drift-guardrails] No classification-report.json found — skipping guardrail emission." >&2
  exit 0
fi

if [[ ! -f "$MANIFEST" ]]; then
  die "_manifest.json not found in $KDIR"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="renorm-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# Emit one JSON row per role to stdout, then pipe into scorecard-append.sh
AGGREGATOR="$SCRIPT_DIR/renormalize-emit-drift-guardrails.py"
python3 "$AGGREGATOR" "$CLASSIFICATION_REPORT" "$MANIFEST" "$RUN_ID" \
  | while IFS= read -r row; do
      "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
    done

echo "[drift-guardrails] scale_drift_rate rows emitted for run $RUN_ID"
