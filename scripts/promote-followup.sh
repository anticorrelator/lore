#!/usr/bin/env bash
# promote-followup.sh — Promote a follow-up to a work item
# Usage: bash promote-followup.sh --followup-id <id> [--title <override>] [--findings-json <json>] [--json]
# Creates a work item from the follow-up, updates follow-up status to promoted,
# and records the cross-link in both artifacts.
# --findings-json: JSON array of selected LensFinding objects to embed in notes.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FOLLOWUP_ID=""
TITLE_OVERRIDE=""
FINDINGS_JSON=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --followup-id)
      FOLLOWUP_ID="$2"
      shift 2
      ;;
    --title)
      TITLE_OVERRIDE="$2"
      shift 2
      ;;
    --findings-json)
      FINDINGS_JSON="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      echo "[followup] Error: Unknown flag '$1'" >&2
      echo "Usage: promote-followup.sh --followup-id <id> [--title <override>] [--findings-json <json>] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$FOLLOWUP_ID" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required flag: --followup-id"
  fi
  echo "[followup] Error: Missing required flag: --followup-id" >&2
  echo "Usage: promote-followup.sh --followup-id <id> [--title <override>] [--findings-json <json>] [--json]" >&2
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
if [[ "$CURRENT_STATUS" == "promoted" ]]; then
  EXISTING_WORK=$(json_field "promoted_to" "$META_FILE")
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up '$FOLLOWUP_ID' is already promoted to work item: $EXISTING_WORK"
  fi
  echo "[followup] Error: Follow-up '$FOLLOWUP_ID' is already promoted to: $EXISTING_WORK" >&2
  exit 1
fi

if [[ "$CURRENT_STATUS" == "dismissed" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Follow-up '$FOLLOWUP_ID' is dismissed — cannot promote a dismissed follow-up"
  fi
  echo "[followup] Error: Follow-up '$FOLLOWUP_ID' is dismissed — cannot promote a dismissed follow-up" >&2
  exit 1
fi

# --- Read follow-up metadata ---
FOLLOWUP_TITLE=$(json_field "title" "$META_FILE")
FOLLOWUP_SOURCE=$(json_field "source" "$META_FILE")

# Determine work item title: prefer explicit override, fall back to follow-up title
WORK_TITLE="${TITLE_OVERRIDE:-$FOLLOWUP_TITLE}"

# --- Build description for work item ---
# Read finding.md content if present for richer description
FINDING_FILE="$FOLLOWUP_DIR/finding.md"
DESCRIPTION="Promoted from follow-up: $FOLLOWUP_ID"
if [[ -n "$FOLLOWUP_SOURCE" ]]; then
  DESCRIPTION="$DESCRIPTION (source: $FOLLOWUP_SOURCE)"
fi
if [[ -f "$FINDING_FILE" ]]; then
  FINDING_EXCERPT=$(head -5 "$FINDING_FILE" 2>/dev/null | grep -v '^#' | grep -v '^$' | head -3 | tr '\n' ' ' | cut -c1-200)
  if [[ -n "$FINDING_EXCERPT" ]]; then
    DESCRIPTION="$DESCRIPTION

$FINDING_EXCERPT"
  fi
fi

# --- Create work item ---
if [[ $JSON_MODE -eq 1 ]]; then
  WORK_OUTPUT=$("$SCRIPT_DIR/create-work.sh" --title "$WORK_TITLE" --description "$DESCRIPTION" --json 2>&1) || {
    json_error "Failed to create work item: $WORK_OUTPUT"
  }
  WORK_SLUG=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('slug',''))" "$WORK_OUTPUT" 2>/dev/null) || WORK_SLUG=""
else
  WORK_OUTPUT=$("$SCRIPT_DIR/create-work.sh" --title "$WORK_TITLE" --description "$DESCRIPTION" --json 2>&1) || {
    echo "[followup] Error: Failed to create work item for follow-up '$FOLLOWUP_ID'" >&2
    echo "$WORK_OUTPUT" >&2
    exit 1
  }
  WORK_SLUG=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('slug',''))" "$WORK_OUTPUT" 2>/dev/null) || WORK_SLUG=""
fi

if [[ -z "$WORK_SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Failed to extract work item slug from create-work.sh output"
  fi
  echo "[followup] Error: Failed to extract work item slug from create-work.sh output" >&2
  exit 1
fi

# --- Update follow-up status to promoted ---
TIMESTAMP=$(timestamp_iso)
UPDATE_SCRIPT="$SCRIPT_DIR/update-followup.sh"
if [[ -x "$UPDATE_SCRIPT" ]]; then
  "$UPDATE_SCRIPT" --followup-id "$FOLLOWUP_ID" --status promoted --promoted-to "$WORK_SLUG" 2>/dev/null || {
    # Non-fatal: work item was created, just log the warning
    echo "[followup] Warning: Failed to update follow-up status via update-followup.sh — updating _meta.json directly" >&2
    _update_meta_direct=1
  }
else
  _update_meta_direct=1
fi

# Direct meta update fallback (used when update-followup.sh is not yet available)
if [[ "${_update_meta_direct:-0}" -eq 1 ]]; then
  python3 - "$META_FILE" "$WORK_SLUG" "$TIMESTAMP" << 'PYEOF'
import json, sys

meta_path, work_slug, timestamp = sys.argv[1], sys.argv[2], sys.argv[3]

with open(meta_path, "r") as f:
    data = json.load(f)

data["status"] = "promoted"
data["promoted_to"] = work_slug
data["updated"] = timestamp

with open(meta_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
fi

# --- Add follow-up cross-reference and findings to work item notes.md ---
WORK_DIR="$KNOWLEDGE_DIR/_work"
WORK_NOTES="$WORK_DIR/$WORK_SLUG/notes.md"
if [[ -f "$WORK_NOTES" ]]; then
  cat >> "$WORK_NOTES" << NOTESEOF

<!-- cross-reference: promoted from follow-up $FOLLOWUP_ID -->
NOTESEOF

  # Append selected lens findings as a structured section when provided.
  if [[ -n "$FINDINGS_JSON" ]]; then
    python3 - "$WORK_NOTES" "$FINDINGS_JSON" << 'PYEOF'
import json, sys

notes_path = sys.argv[1]
findings_raw = sys.argv[2]

try:
    findings = json.loads(findings_raw)
except json.JSONDecodeError:
    sys.exit(0)  # Malformed input — skip silently

if not findings:
    sys.exit(0)

lines = ["\n## Selected Lens Findings\n"]
for f in findings:
    severity = f.get("severity", "")
    lens = f.get("lens", "")
    file_path = f.get("file", "")
    line_no = f.get("line", 0)
    body = f.get("body", "")
    rationale = f.get("rationale", "")

    loc = file_path
    if line_no:
        loc = f"{file_path}:{line_no}"

    header = f"- **[{severity}]** `{loc}` ({lens})"
    lines.append(header)
    if body:
        lines.append(f"  {body}")
    if rationale:
        lines.append(f"  *Rationale: {rationale}*")

with open(notes_path, "a") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
  fi
fi

# --- Rebuild follow-up index ---
UPDATE_INDEX="$SCRIPT_DIR/update-followup-index.sh"
if [[ -x "$UPDATE_INDEX" ]]; then
  "$UPDATE_INDEX" >/dev/null 2>/dev/null || true
fi

# --- Output ---
if [[ $JSON_MODE -eq 1 ]]; then
  python3 - "$META_FILE" "$WORK_SLUG" << 'PYEOF'
import json, sys

meta_path, work_slug = sys.argv[1], sys.argv[2]

with open(meta_path) as f:
    data = json.load(f)

print(json.dumps({
    "followup_id": data.get("id", ""),
    "followup_title": data.get("title", ""),
    "work_slug": work_slug,
    "status": data.get("status", ""),
    "promoted_to": data.get("promoted_to", ""),
}, indent=2))
PYEOF
  exit 0
fi

WORK_TITLE_DISPLAY=$(json_field "title" "$WORK_DIR/$WORK_SLUG/_meta.json" 2>/dev/null || echo "$WORK_SLUG")
echo "[followup] Promoted: $FOLLOWUP_ID → work item '$WORK_TITLE_DISPLAY' ($WORK_SLUG)"
