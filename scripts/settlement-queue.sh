#!/usr/bin/env bash
# settlement-queue.sh — CLI facade for durable settlement state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: settlement-queue.sh <status|triggers|scan|enqueue|process|enable|disable|schedule|model|queue|retry-errors|drain|enqueue-rollup-backfill> [args...]

Commands:
  status --json                 Show queue, lease, run, and budget status.
  triggers --json               Run the event-driven enqueue triggers: dispute
                                detector, spot-sample budget, rollup steady-
                                state. Idempotent; self-throttled (--force
                                bypasses the throttle).
  scan --json                   Manual census walk over _work/*/ source streams.
                                Dormant as an automatic driver; still invocable.
  enqueue --work-item SLUG      Enqueue one Tier 2 row from stdin.
  process --once --json         Process one pending item.
  enable|disable --json         Toggle settlement.enabled in settings.json.
  schedule on|off --json        Toggle settlement.active_hours.enabled in
                                settings.json (the active-hours schedule gate).
  model <alias> --json          Set settlement.auditor_model — the judge model
                                for settlement-executed audits.
  model --unset --json          Remove settlement.auditor_model (role default).
  queue recompute --json        Recompute the active settlement batch.
  retry-errors --json           Requeue audit errors and timeout-blocked attempts.
  drain --json                  Loop process_once until queue empty; abort on
                                pipeline-degraded or hard-cal gate uncalibrated*.
  enqueue-rollup-backfill --json
                                Enqueue per-judge weekly rollup items for the
                                trailing N completed weeks (default 30, range
                                1-104). Skips windows whose tier=template row
                                or completed rollup run record already exists.

Options:
  --kdir PATH                   Override knowledge dir.
  --max-iterations N            (drain only) cap loop iterations; default 200.
  --weeks N                     (enqueue-rollup-backfill only) trailing weeks.
  --judge NAME                  (enqueue-rollup-backfill only) limit to one of
                                correctness-gate-assertion, correctness-gate-omission,
                                correctness-gate-contradiction, curator, reverse-auditor.
EOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  status|triggers|scan|enqueue|process|enable|disable|schedule|model|queue|retry-errors|drain|enqueue-rollup-backfill)
    python3 "$SCRIPT_DIR/settlement-processor.py" "$@"
    ;;
  *)
    echo "[settlement] Error: unknown command '$1'" >&2
    usage
    exit 1
    ;;
esac
