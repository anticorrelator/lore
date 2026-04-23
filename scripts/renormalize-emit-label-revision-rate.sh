#!/usr/bin/env bash
# renormalize-emit-label-revision-rate.sh — Emit label_revision_rate guardrail rows per scale_id.
#
# Reads scripts/scale-registry.json and counts how many times each scale_id's label has changed
# in the last N registry versions. Emits one telemetry row per scale_id via scorecard-append.sh.
# When revisions >= 2 in the window, also emits a registry_design_flag telemetry row for /retro.
#
# Usage:
#   renormalize-emit-label-revision-rate.sh [--kdir <path>] [--run-id <id>] [--window <N>]
#
# Options:
#   --kdir    Override knowledge directory (default: lore resolve)
#   --run-id  Renormalize run identifier included in each row (default: timestamp)
#   --window  Number of registry versions to look back (default: 5)
#
# Exit codes:
#   0 — success (even if 0 rows emitted)
#   1 — setup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR=""
RUN_ID=""
WINDOW=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)   KDIR="$2";   shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<'HELPEOF'
Usage: renormalize-emit-label-revision-rate.sh [--kdir <path>] [--run-id <id>] [--window <N>]

Reads scale-registry.json label_history and emits one label_revision_rate
telemetry row per scale_id via scorecard-append.sh. When revisions >= 2 in the
window, also emits a registry_design_flag row for /retro surfacing.

Reads:  scripts/scale-registry.json
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

REGISTRY="$SCRIPT_DIR/scale-registry.json"
if [[ ! -f "$REGISTRY" ]]; then
  echo "[label-revision-rate] scale-registry.json not found at $REGISTRY — skipping." >&2
  exit 0
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="renorm-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# Generate rows and pipe to scorecard-append.sh one at a time
python3 "$SCRIPT_DIR/renormalize-emit-label-revision-rate.py" \
  "$REGISTRY" "$RUN_ID" --window "$WINDOW" \
  | while IFS= read -r row; do
      "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
    done

echo "[label-revision-rate] label_revision_rate rows emitted for run $RUN_ID"
