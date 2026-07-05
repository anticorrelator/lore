#!/usr/bin/env bash
# release-work.sh — Clear a review gate from a work item and record the release
# Usage: bash release-work.sh <slug> [--kdir <path>] [--json]
#
# Reads the active gate_id from the _meta.json review block, clears the block
# (the durable state change), rebuilds the index, then emits review_released
# through session-event-append.sh carrying the original gate_id — the audit
# join key that pairs the release with its gate-open row. Refuses when no gate
# is active (a second release on the same slug therefore exits non-zero).
#
# Mutation pipeline clones relate-work.sh (find_item_dir active-or-archive,
# Python meta mutation, index rebuild).
#
# Exit codes: 0 success; 1 error/refused.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SLUG=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  echo "Usage: release-work.sh <slug> [--kdir <path>] [--json]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown flag '$1'"; fi
      echo "[work] Error: Unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        if [[ $JSON_MODE -eq 1 ]]; then json_error "Unexpected extra argument '$1'"; fi
        echo "[work] Error: Unexpected extra argument '$1'" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then json_error "$msg"; fi
  echo "[work] Error: $msg" >&2
  exit 1
}

[[ -n "$SLUG" ]] || fail "Missing required argument: slug"

command -v jq &>/dev/null || fail "jq is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
WORK_DIR="$KNOWLEDGE_DIR/_work"
[[ -d "$WORK_DIR" ]] || fail "No work directory found"

# --- Locate a work item by slug (active or archive) ---
find_item_dir() {
  local slug="$1"
  if [[ -d "$WORK_DIR/$slug" ]]; then
    echo "$WORK_DIR/$slug"
  elif [[ -d "$WORK_DIR/_archive/$slug" ]]; then
    echo "$WORK_DIR/_archive/$slug"
  else
    echo ""
  fi
}

ITEM_DIR=$(find_item_dir "$SLUG")
[[ -n "$ITEM_DIR" ]] || fail "Work item not found: $SLUG"

META_FILE="$ITEM_DIR/_meta.json"
[[ -f "$META_FILE" ]] || fail "No _meta.json found for: $SLUG"

# --- Read the active gate; refuse when none is present ---
GATE_INFO=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    review = data.get("review")
    if isinstance(review, dict) and review.get("mechanism") in ("flag", "hold"):
        print(review.get("mechanism", ""))
        print(review.get("gate_id", ""))
except Exception:
    pass
' "$META_FILE")
MECHANISM=$(printf '%s\n' "$GATE_INFO" | sed -n '1p')
GATE_ID=$(printf '%s\n' "$GATE_INFO" | sed -n '2p')

if [[ -z "$MECHANISM" ]]; then
  fail "work item '$SLUG' has no active review gate to release"
fi

# --- Clear the review block (durable state change precedes the journal event) ---
python3 - "$META_FILE" << 'PYEOF'
import json, sys
meta_path = sys.argv[1]
with open(meta_path, encoding="utf-8") as f:
    data = json.load(f)
data.pop("review", None)
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

update_meta_timestamp "$ITEM_DIR"

# --- Rebuild index so plans[].review clears for the renderers ---
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# --- Emit review_released carrying the original gate_id (the audit join key) ---
EVENT_ROW=$(jq -n \
  --arg slug "$SLUG" \
  --arg gate_id "$GATE_ID" \
  '{event: "review_released", slug: $slug}
   + (if $gate_id != "" then {gate_id: $gate_id} else {} end)')
if ! printf '%s' "$EVENT_ROW" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
  echo "[work] Warning: journal append failed (review block cleared durably)" >&2
fi

TITLE=$(json_field "title" "$META_FILE")

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg slug "$SLUG" \
    --arg mechanism "$MECHANISM" \
    --arg gate_id "$GATE_ID" \
    '{slug: $slug, mechanism: $mechanism, gate_id: $gate_id, released: true}')"
fi

echo "[work] Released $MECHANISM gate on $SLUG ($TITLE) — gate_id=$GATE_ID"
