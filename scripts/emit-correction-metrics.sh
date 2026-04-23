#!/usr/bin/env bash
# emit-correction-metrics.sh — Emit correction_rate and precedent_rate telemetry rows.
#
# Walks all entries in the manifest, reads corrections[] and precedent_note: from
# each entry's HTML META block, aggregates per scale (correction_rate) and per
# registry group (precedent_rate). Emits one row per scale for each metric.
#
# correction_rate (per scale):
#   entries with ≥1 correction in window / entries at that scale
# precedent_rate (per registry group / scale_id):
#   L3 corrections / corrections in window  (L3 = corrections[] + precedent_note:)
#
# Usage:
#   emit-correction-metrics.sh [--kdir <path>] [--run-id <id>] [--window-days N]
#
# Options:
#   --kdir         Override knowledge directory (default: lore resolve)
#   --run-id       Run identifier included in each row (default: timestamp)
#   --window-days  Rolling window in days (default: 30)
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
WINDOW_DAYS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)         KDIR="$2";         shift 2 ;;
    --run-id)       RUN_ID="$2";       shift 2 ;;
    --window-days)  WINDOW_DAYS="$2";  shift 2 ;;
    --help|-h)
      cat >&2 <<'HELPEOF'
Usage: emit-correction-metrics.sh [--kdir <path>] [--run-id <id>] [--window-days N]

Emits correction_rate (per scale) and precedent_rate (per registry group) telemetry
rows via scorecard-append.sh.

Reads:  $KDIR/_manifest.json
        scripts/scale-registry.json
        entry META blocks (corrections[], precedent_note:, scale:)
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

REGISTRY="$SCRIPT_DIR/scale-registry.json"
if [[ ! -f "$REGISTRY" ]]; then
  die "scale-registry.json not found at $REGISTRY"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="renorm-$(date -u +%Y%m%dT%H%M%SZ)"
fi

EMITTER="$SCRIPT_DIR/emit-correction-metrics.py"
python3 "$EMITTER" "$MANIFEST" "$REGISTRY" "$RUN_ID" \
  --window-days "$WINDOW_DAYS" \
  --kdir "$KDIR" \
  | while IFS= read -r row; do
      "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
    done

echo "[correction-metrics] correction_rate and precedent_rate rows emitted for run $RUN_ID"
