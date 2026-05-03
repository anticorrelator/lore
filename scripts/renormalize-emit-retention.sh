#!/usr/bin/env bash
# renormalize-emit-retention.sh — Emit retention_after_renormalize telemetry rows per entry.
#
# Reads $KDIR/_renormalize/prune-history.jsonl to count how many prior renormalize
# cycles each currently-living entry has survived without being pruned. Aggregates
# by producer template_version (from _manifest.json), emits one row per entry via
# scorecard-append.sh.
#
# If prune-history.jsonl does not exist, emits cycles_survived=0 for all entries
# (expected on first run; metric becomes meaningful after multiple cycles).
#
# Usage:
#   renormalize-emit-retention.sh [--kdir <path>] [--run-id <id>]
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
Usage: renormalize-emit-retention.sh [--kdir <path>] [--run-id <id>]

Reads $KDIR/_renormalize/prune-history.jsonl and $KDIR/_manifest.json to
compute how many prior renormalize cycles each entry survived without pruning.
Emits one retention_after_renormalize telemetry row per entry via scorecard-append.sh.

Reads:  $KDIR/_renormalize/prune-history.jsonl (optional — 0 cycles if absent)
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

MANIFEST="$KDIR/_manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  die "_manifest.json not found in $KDIR"
fi

PRUNE_HISTORY="$KDIR/_renormalize/prune-history.jsonl"

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="renorm-$(date -u +%Y%m%dT%H%M%SZ)"
fi

AGGREGATOR="$SCRIPT_DIR/renormalize-emit-retention.py"

if [[ -f "$PRUNE_HISTORY" ]]; then
  python3 "$AGGREGATOR" "$MANIFEST" "$RUN_ID" --prune-history "$PRUNE_HISTORY" \
    | while IFS= read -r row; do
        "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
      done
else
  echo "[retention] No prune-history.jsonl found — emitting cycles_survived=0 for all entries." >&2
  python3 "$AGGREGATOR" "$MANIFEST" "$RUN_ID" \
    | while IFS= read -r row; do
        "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
      done
fi

echo "[retention] retention_after_renormalize rows emitted for run $RUN_ID"
