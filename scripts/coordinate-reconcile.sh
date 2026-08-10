#!/usr/bin/env bash
# coordinate-reconcile.sh — Resolve a work item and invoke the attempt-record sole writer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: lore coordinate reconcile <operation> <ref> [options]

Lifecycle operations, covering an attempt from allocation to report acceptance:
  register-attempt  --stream S --attempt A --tree writer --worktree-id ID
                    --tree read-only registers a stream that owns no checkout.
  advance-attempt   --stream S --attempt A --expected-status STATUS
                    [--to STATUS] [--branch-relevance ...] [--delivery-classification ...]
                    --expected-status is mandatory so a stale caller conflicts
                    instead of overwriting a newer status.
  lookup-attempt    --stream S --attempt A
                    Answers with the tree's identity, so callers do not carry a
                    worktree id by hand. Always exits 0: read `.outcome` to tell
                    "no record yet" from "the pointer went stale".

What shipped is not recorded here. The integration commit and the suite counts
that verified it belong in the arc ledger row, where a reader looks for them.
EOF
}

[[ $# -ge 2 ]] || { usage; exit 1; }
OPERATION="$1"
REF="$2"
shift 2

case "$OPERATION" in
  register-attempt|advance-attempt|lookup-attempt) ;;
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
