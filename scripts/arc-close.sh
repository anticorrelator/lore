#!/usr/bin/env bash
# arc-close.sh — record the closure of a coordination arc.
#
# Usage: bash arc-close.sh <slug> [--json]
#
# Closure is the coordinator's decision, so it is recorded rather than inferred
# from what is on disk. A missing report.md is called out loudly and does not
# stop the close.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc close <slug> [--json]

Records the arc as closed and stamps its closure time. Closing an already-closed
arc leaves the recorded closure time alone.

Options:
  --json         Emit the updated record as JSON.
  --kdir <path>  Override the resolved knowledge dir (testing).
  --help, -h     Show this help.
EOF
}

SLUG=""
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
    *)
      if [[ -n "$SLUG" ]]; then
        echo "[arc] Error: unexpected argument '$1'" >&2; usage; exit 1
      fi
      SLUG="$1"; shift ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

[[ -n "$SLUG" ]] || fail "a slug is required"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

RECORD_DIR="$KNOWLEDGE_DIR/_work/_arcs/$SLUG"
[[ -f "$RECORD_DIR/_meta.json" ]] || fail "no arc named '$SLUG'"

# An archived arc is refused by the writer below; warning about its report first
# would put a to-do note in front of a refusal.
CURRENT_STATUS="$(json_field "status" "$RECORD_DIR/_meta.json")"
if [[ "$CURRENT_STATUS" != "archived" && ! -f "$RECORD_DIR/report.md" ]]; then
  echo "[arc] Warning: arc '$SLUG' is closing without a report — write $RECORD_DIR/report.md so the arc's residue is readable by whoever comes next" >&2
fi

ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" --kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op close) || exit 1

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["record"], indent=2))
'
  exit 0
fi

printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
record = json.load(sys.stdin)["record"]
print("[arc] Closed: %s (%s)" % (record["slug"], record.get("title") or "untitled"))
print("  closed_at: %s" % (record.get("closed_at") or "unrecorded"))
'
