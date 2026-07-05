#!/usr/bin/env bash
# flag-work.sh — Open a review gate on a work item (flag or hold mechanism)
# Usage: bash flag-work.sh <slug> --mechanism <flag|hold> --reason <r> [--packet <name>] [--kdir <path>] [--json]
#
# Writes the optional `review` block to _meta.json (the source of truth for
# gating, per docs/review-gates.md D2), then emits the gate-open journal event
# (review_flagged | review_held) through session-event-append.sh — the durable
# meta write precedes the journal append. The generated gate_id becomes the
# event's event_id; `lore work release` echoes it back as the audit join key.
#
# One active gate per item: a second gate on an already-gated item is refused
# (escalation is release + re-gate, both audited). Mutation pipeline clones
# relate-work.sh (find_item_dir active-or-archive, Python meta mutation, index
# rebuild).
#
# Exit codes: 0 success; 1 error/refused.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SLUG=""
MECHANISM=""
REASON=""
PACKET=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  echo "Usage: flag-work.sh <slug> --mechanism <flag|hold> --reason <r> [--packet <name>] [--kdir <path>] [--json]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mechanism) MECHANISM="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --packet) PACKET="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
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

# --- Validate mechanism against the closed set (hand-rolled per neighbor) ---
case "$MECHANISM" in
  flag|hold) ;;
  "") fail "Missing required flag: --mechanism <flag|hold>" ;;
  *) fail "invalid --mechanism: '$MECHANISM' (must be one of flag, hold)" ;;
esac

[[ -n "$REASON" ]] || fail "Missing required flag: --reason <r>"

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

# --- Single-gate invariant: refuse a second gate on an already-gated item ---
EXISTING_MECHANISM=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    review = data.get("review")
    if isinstance(review, dict) and review.get("mechanism") in ("flag", "hold"):
        print(review.get("mechanism"))
except Exception:
    pass
' "$META_FILE")
if [[ -n "$EXISTING_MECHANISM" ]]; then
  fail "work item '$SLUG' already has an active $EXISTING_MECHANISM gate — release it first with 'lore work release $SLUG' (escalation is release + re-gate)"
fi

# --- Generate the gate_id (same shape as event_id) ---
RAND=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
GATE_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RAND}"
GATED_AT=$(timestamp_iso)

# --- Write the review block (durable state precedes the journal event) ---
python3 - "$META_FILE" "$MECHANISM" "$GATE_ID" "$GATED_AT" "$REASON" "$PACKET" << 'PYEOF'
import json, sys
meta_path, mechanism, gate_id, gated_at, reason, packet = sys.argv[1:7]
with open(meta_path, encoding="utf-8") as f:
    data = json.load(f)
review = {
    "mechanism": mechanism,
    "gate_id": gate_id,
    "gated_at": gated_at,
    "reason": reason,
}
if packet:
    review["packet"] = packet
data["review"] = review
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

update_meta_timestamp "$ITEM_DIR"

# --- Rebuild index so plans[].review is current for the renderers ---
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# --- Emit the gate-open event through the sole journal writer ---
# event_id = gate_id (the audit join key); links.artifact = packet when present.
if [[ "$MECHANISM" == "hold" ]]; then
  EVENT="review_held"
else
  EVENT="review_flagged"
fi
EVENT_ROW=$(jq -n \
  --arg event "$EVENT" \
  --arg event_id "$GATE_ID" \
  --arg slug "$SLUG" \
  --arg reason "$REASON" \
  --arg packet "$PACKET" \
  '{event: $event, event_id: $event_id, slug: $slug, reason: $reason}
   + (if $packet != "" then {links: {artifact: $packet}} else {} end)')
if ! printf '%s' "$EVENT_ROW" | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
  echo "[work] Warning: journal append failed (review block is durable)" >&2
fi

TITLE=$(json_field "title" "$META_FILE")

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg slug "$SLUG" \
    --arg mechanism "$MECHANISM" \
    --arg gate_id "$GATE_ID" \
    --arg gated_at "$GATED_AT" \
    --arg reason "$REASON" \
    --arg packet "$PACKET" \
    '{slug: $slug, mechanism: $mechanism, gate_id: $gate_id, gated_at: $gated_at, reason: $reason, gated: true}
     + (if $packet != "" then {packet: $packet} else {} end)')"
fi

MECHANISM_CAP=$(echo "$MECHANISM" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
echo "[work] $MECHANISM_CAP gate opened on $SLUG ($TITLE) — gate_id=$GATE_ID"
echo "[work] Release with: lore work release $SLUG"
