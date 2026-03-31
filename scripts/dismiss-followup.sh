#!/usr/bin/env bash
# dismiss-followup.sh — Dismiss a follow-up with optional reason
# Usage: bash dismiss-followup.sh --followup-id <id> [--reason <text>] [--json]
# Updates follow-up status to dismissed and records the reason in _meta.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FOLLOWUP_ID=""
REASON=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --followup-id)
      FOLLOWUP_ID="$2"
      shift 2
      ;;
    --reason)
      REASON="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: dismiss-followup.sh --followup-id <id> [--reason <text>] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FOLLOWUP_ID" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required flag: --followup-id"
  fi
  echo "[followup] Error: Missing required flag: --followup-id" >&2
  echo "Usage: dismiss-followup.sh --followup-id <id> [--reason <text>] [--json]" >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"
FOLLOWUP_DIR="$FOLLOWUPS_DIR/$FOLLOWUP_ID"
META_FILE="$FOLLOWUP_DIR/_meta.json"

if [[ ! -d "$FOLLOWUP_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up not found: $FOLLOWUP_ID"
  fi
  echo "[followup] Error: Follow-up not found: $FOLLOWUP_ID" >&2
  exit 1
fi

if [[ ! -f "$META_FILE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No _meta.json found for follow-up: $FOLLOWUP_ID"
  fi
  echo "[followup] Error: No _meta.json found for follow-up: $FOLLOWUP_ID" >&2
  exit 1
fi

# --- Check current status ---
CURRENT_STATUS=$(json_field "status" "$META_FILE")
if [[ "$CURRENT_STATUS" == "dismissed" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up '$FOLLOWUP_ID' is already dismissed"
  fi
  echo "[followup] Error: Follow-up '$FOLLOWUP_ID' is already dismissed." >&2
  exit 1
fi

if [[ "$CURRENT_STATUS" == "promoted" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up '$FOLLOWUP_ID' is promoted — cannot dismiss a promoted follow-up"
  fi
  echo "[followup] Error: Follow-up '$FOLLOWUP_ID' is promoted — cannot dismiss a promoted follow-up" >&2
  exit 1
fi

# --- Update follow-up status to dismissed ---
UPDATE_SCRIPT="$SCRIPT_DIR/update-followup.sh"
if [[ -x "$UPDATE_SCRIPT" ]]; then
  UPDATE_ARGS=(--followup-id "$FOLLOWUP_ID" --status dismissed)
  [[ -n "$REASON" ]] && UPDATE_ARGS+=(--reason "$REASON")
  "$UPDATE_SCRIPT" "${UPDATE_ARGS[@]}" 2>/dev/null || {
    echo "[followup] Warning: Failed to update follow-up status via update-followup.sh — updating _meta.json directly" >&2
    _update_meta_direct=1
  }
else
  _update_meta_direct=1
fi

# Direct meta update fallback (used when update-followup.sh is not yet available)
if [[ "${_update_meta_direct:-0}" -eq 1 ]]; then
  TIMESTAMP=$(timestamp_iso)
  python3 - "$META_FILE" "$REASON" "$TIMESTAMP" << 'PYEOF'
import json, sys

meta_path, reason, timestamp = sys.argv[1], sys.argv[2], sys.argv[3]

with open(meta_path, "r") as f:
    data = json.load(f)

data["status"] = "dismissed"
data["updated"] = timestamp
if reason:
    data["dismiss_reason"] = reason

with open(meta_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
fi

# --- Rebuild follow-up index ---
UPDATE_INDEX="$SCRIPT_DIR/update-followup-index.sh"
if [[ -x "$UPDATE_INDEX" ]]; then
  "$UPDATE_INDEX" >/dev/null 2>/dev/null || true
fi

# --- Output ---
FOLLOWUP_TITLE=$(json_field "title" "$META_FILE")

if [[ $JSON_MODE -eq 1 ]]; then
  python3 - "$META_FILE" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

out = {
    "followup_id": data.get("id", ""),
    "title": data.get("title", ""),
    "status": data.get("status", ""),
}
if "dismiss_reason" in data:
    out["dismiss_reason"] = data["dismiss_reason"]
print(json.dumps(out, indent=2))
PYEOF
  exit 0
fi

if [[ -n "$REASON" ]]; then
  echo "[followup] Dismissed: $FOLLOWUP_ID ($FOLLOWUP_TITLE) — $REASON"
else
  echo "[followup] Dismissed: $FOLLOWUP_ID ($FOLLOWUP_TITLE)"
fi
