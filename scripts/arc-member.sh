#!/usr/bin/env bash
# arc-member.sh — add or remove a work item from an arc's member set.
#
# Usage: bash arc-member.sh add|rm <slug> <work-item-slug> [--json]
#
# Members are a set: adding one already listed changes nothing, and so does
# removing one that is not. Member slugs resolve in active work items first and
# then in the archive — historical arcs legitimately reference archived items.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc member add <slug> <work-item-slug> [--json]
  lore arc member rm  <slug> <work-item-slug> [--json]

Adds or removes a work item from the arc's members. Both directions are
idempotent, so re-running either one is safe.

Options:
  --json         Emit the updated record as JSON.
  --kdir <path>  Override the resolved knowledge dir (testing).
  --help, -h     Show this help.
EOF
}

ACTION=""
SLUG=""
MEMBER=""
POSITIONAL=()
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

if [[ ${#POSITIONAL[@]} -ne 3 ]]; then
  echo "[arc] Error: expected 'add|rm <slug> <work-item-slug>'" >&2
  usage
  exit 1
fi

ACTION="${POSITIONAL[0]}"
SLUG="${POSITIONAL[1]}"
MEMBER="${POSITIONAL[2]}"

case "$ACTION" in
  add) OP="member-add" ;;
  rm) OP="member-rm" ;;
  *) fail "'$ACTION' is not a member action — use add or rm" ;;
esac

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

RECORD_DIR="$KNOWLEDGE_DIR/_work/_arcs/$SLUG"
[[ -f "$RECORD_DIR/_meta.json" ]] || fail "no arc named '$SLUG'"

ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" --kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op "$OP" --member "$MEMBER") || exit 1

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["record"], indent=2))
'
  exit 0
fi

printf '%s' "$ENVELOPE" | ARC_ACTION="$ACTION" ARC_MEMBER="$MEMBER" python3 -c '
import json, os, sys
envelope = json.load(sys.stdin)
record = envelope["record"]
action = os.environ["ARC_ACTION"]
member = os.environ["ARC_MEMBER"]
if envelope["changed"]:
    verb = "Added member" if action == "add" else "Removed member"
    print("[arc] %s: %s → %s" % (verb, record["slug"], member))
else:
    state = "already a member of" if action == "add" else "not a member of"
    print("[arc] No change: %s is %s %s" % (member, state, record["slug"]))
print("  members: %s" % (", ".join(record.get("members") or []) or "none"))
'
