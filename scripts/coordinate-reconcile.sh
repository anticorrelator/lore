#!/usr/bin/env bash
# coordinate-reconcile.sh — Resolve a work item and invoke the reconciliation sole writer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: lore coordinate reconcile <freeze-source|merge|record-conflict|freeze-integrated|status> <ref> [options]

Freeze immutable source/integrated stream evidence, record unresolved merge
conflicts, or validate the aggregate against the worktree lifecycle archive.
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }
OPERATION="$1"
REF="$2"
shift 2

case "$OPERATION" in
  freeze-source|merge|record-conflict|freeze-integrated|status) ;;
  *) echo "[coordinate-reconcile] Error: unknown operation '$OPERATION'" >&2; usage; exit 1 ;;
esac

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" 2>&1)
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  printf '%s\n' "$RESOLVED" >&2
  exit "$RC"
fi
SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
KDIR=$(resolve_knowledge_dir)

exec python3 "$SCRIPT_DIR/coordinate-reconcile.py" "$OPERATION" \
  --kdir "$KDIR" --slug "$SLUG" "$@"
