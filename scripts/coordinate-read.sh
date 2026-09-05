#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KDIR=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ -n "$KDIR" ]] || KDIR="$(resolve_knowledge_dir)"
COORDINATION_MAX_CONCURRENCY=$(bash "$SCRIPT_DIR/settings.sh" get coordination.max_concurrency 2>/dev/null || true)
[[ "$COORDINATION_MAX_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || COORDINATION_MAX_CONCURRENCY=1
export COORDINATION_MAX_CONCURRENCY
exec python3 "$SCRIPT_DIR/coordinate_projection.py" --kdir "$KDIR" "${ARGS[@]}"
