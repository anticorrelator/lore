#!/usr/bin/env bash
# emit-downstream-adoption.sh — Emit downstream_adoption_rate telemetry rows per entry.
#
# Reads $KDIR/_meta/retrieval-log.jsonl to count how often each entry was loaded
# (retrieved) to agents within the rolling window. Stratifies by entry status
# (current | superseded | historical) read from each entry's HTML META block.
#
# "Adoption" is mechanically defined as retrieval: an agent received this entry
# in a loaded_paths batch. When explicit citation tracking is added, update the
# Python aggregator to consume that signal instead.
#
# Usage:
#   emit-downstream-adoption.sh [--kdir <path>] [--run-id <id>] [--window <days>]
#
# Options:
#   --kdir    Override knowledge directory (default: lore resolve)
#   --run-id  Renormalize run identifier included in each row (default: timestamp)
#   --window  Rolling window in days (default: 30)
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
WINDOW=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)   KDIR="$2";   shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --window) WINDOW="$2"; shift 2 ;;
    --help|-h)
      cat >&2 <<'HELPEOF'
Usage: emit-downstream-adoption.sh [--kdir <path>] [--run-id <id>] [--window <days>]

Reads $KDIR/_meta/retrieval-log.jsonl and $KDIR/_manifest.json to compute how
often each entry was retrieved (loaded to agents) in the rolling window. Emits
one downstream_adoption_rate telemetry row per entry via scorecard-append.sh.

Reads:  $KDIR/_meta/retrieval-log.jsonl
        $KDIR/_manifest.json
        entry META blocks (for status field)
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

RETRIEVAL_LOG="$KDIR/_meta/retrieval-log.jsonl"
MANIFEST="$KDIR/_manifest.json"

if [[ ! -f "$RETRIEVAL_LOG" ]]; then
  echo "[downstream-adoption] No retrieval-log.jsonl found — skipping." >&2
  exit 0
fi

if [[ ! -f "$MANIFEST" ]]; then
  die "_manifest.json not found in $KDIR"
fi

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="renorm-$(date -u +%Y%m%dT%H%M%SZ)"
fi

python3 "$SCRIPT_DIR/emit-downstream-adoption.py" \
  "$MANIFEST" "$RETRIEVAL_LOG" "$RUN_ID" \
  --window-days "$WINDOW" \
  --kdir "$KDIR" \
  | while IFS= read -r row; do
      "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row"
    done

echo "[downstream-adoption] downstream_adoption_rate rows emitted for run $RUN_ID"
