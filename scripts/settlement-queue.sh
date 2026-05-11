#!/usr/bin/env bash
# settlement-queue.sh — CLI facade for durable settlement state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: settlement-queue.sh <status|scan|enqueue|process|enable|disable|queue|retry-errors> [args...]

Commands:
  status --json                 Show queue, lease, run, and budget status.
  scan --json                   Idempotently scan _work/*/task-claims.jsonl.
  enqueue --work-item SLUG      Enqueue one Tier 2 row from stdin.
  process --once --json         Process one pending item.
  enable|disable --json         Toggle settlement.enabled in settings.json.
  queue recompute --json        Recompute the active settlement batch.
  retry-errors --json           Requeue audit errors and timeout-blocked attempts.

Options:
  --kdir PATH                   Override knowledge dir.
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
  status|scan|enqueue|process|enable|disable|queue|retry-errors)
    python3 "$SCRIPT_DIR/settlement-processor.py" "$@"
    ;;
  *)
    echo "[settlement] Error: unknown command '$1'" >&2
    usage
    exit 1
    ;;
esac
