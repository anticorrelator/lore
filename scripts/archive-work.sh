#!/usr/bin/env bash
# archive-work.sh — Archive a work item by slug
# Usage: bash archive-work.sh <slug>
# Updates _meta.json status to "archived", moves to _archive/, rebuilds index.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
JSON_OUTPUT=false
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Missing required argument: slug"
  fi
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: bash archive-work.sh [--json] <slug>" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No work directory found"
  fi
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

ITEM_DIR="$WORK_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Work item not found: $SLUG"
  fi
  echo "[work] Error: Work item not found: $SLUG" >&2
  echo "Available items:" >&2
  for d in "$WORK_DIR"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" == "_archive" ]] && continue
    echo "  $name" >&2
  done
  exit 1
fi

META_FILE="$ITEM_DIR/_meta.json"

if [[ ! -f "$META_FILE" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "No _meta.json found for: $SLUG"
  fi
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# Check if already archived
CURRENT_STATUS=$(json_field "status" "$META_FILE")
if [[ "$CURRENT_STATUS" == "archived" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Work item '$SLUG' is already archived"
  fi
  echo "[work] Error: Work item '$SLUG' is already archived." >&2
  exit 1
fi

# --- Blocking review gate (BEFORE the non-retryable status mutation) ---
# Input: the _meta.json review block. A flagged OR held item refuses archive so
# the system carries the comprehension debt, not human memory. Placed here — after
# the already-archived check, before the in-place status sed — because a refusal
# after the sed would leave a half-mutated, non-retryable item. Conservative
# fallback: a review block present but malformed refuses too (never proceed on
# ambiguous gate state). A whole-file JSON parse failure is left to the existing
# flow, which reads status with grep/sed and tolerates non-strict meta.
GATE_STATUS=$(python3 - "$META_FILE" <<'PYEOF'
import json, sys, time
from datetime import datetime
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("PROCEED")
    sys.exit(0)
review = data.get("review")
if review is None:
    print("PROCEED")
    sys.exit(0)
if not isinstance(review, dict) or review.get("mechanism") not in ("flag", "hold"):
    print("MALFORMED")
    sys.exit(0)
gated_at = review.get("gated_at") or ""
age = "unknown age"
try:
    dt = datetime.fromisoformat(gated_at.replace("Z", "+00:00"))
    days = int((time.time() - dt.timestamp()) / 86400)
    age = "today" if days <= 0 else ("1 day" if days == 1 else f"{days} days")
except Exception:
    pass
print("GATED")
print(review.get("mechanism"))
print(age)
print(review.get("reason") or "(no reason recorded)")
PYEOF
)
GATE_VERDICT=$(printf '%s\n' "$GATE_STATUS" | sed -n '1p')
if [[ "$GATE_VERDICT" == "GATED" ]]; then
  GATE_MECHANISM=$(printf '%s\n' "$GATE_STATUS" | sed -n '2p')
  GATE_AGE=$(printf '%s\n' "$GATE_STATUS" | sed -n '3p')
  GATE_REASON=$(printf '%s\n' "$GATE_STATUS" | sed -n '4p')
  MSG="Work item '$SLUG' is under a $GATE_MECHANISM review gate ($GATE_AGE old): $GATE_REASON. Release it first with 'lore work release $SLUG'."
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "$MSG"
  fi
  echo "[work] Error: $MSG" >&2
  exit 1
elif [[ "$GATE_VERDICT" == "MALFORMED" ]]; then
  MSG="Work item '$SLUG' has a malformed review block — refusing to archive. Inspect _meta.json and clear it with 'lore work release $SLUG'."
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "$MSG"
  fi
  echo "[work] Error: $MSG" >&2
  exit 1
fi

# --- Closure-acceptance advisory (non-blocking) ---
# Per closure-acceptance-reconciliation D1: when an anchored work item is
# archived without a `closure` block on _meta.json, emit a single advisory
# warning to stderr but do NOT block. /implement Step 6 is the canonical
# verdict path; this advisory exists to surface accidental bypass via the
# manual `lore work archive` escape hatch (and any future bulk-archive
# callers) without forcing every existing caller into the new ceremony.
HAS_INTENT_ANCHOR=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    print("1" if (data.get("intent_anchor") or "").strip() else "0")
except Exception:
    print("0")
' "$META_FILE")
HAS_CLOSURE=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    print("1" if isinstance(data.get("closure"), dict) else "0")
except Exception:
    print("0")
' "$META_FILE")
if [[ "$HAS_INTENT_ANCHOR" == "1" && "$HAS_CLOSURE" == "0" ]]; then
  echo "[work] Warning: archiving anchored work item '$SLUG' without a _meta.json.closure block." >&2
  echo "[work]          /implement Step 6 records the closure verdict; archive proceeds without it." >&2
fi

# Update status in _meta.json
sed -i '' 's/"status"[[:space:]]*:[[:space:]]*"[^"]*"/"status": "archived"/' "$META_FILE"

# Add archived timestamp
ARCHIVE_TS=$(timestamp_iso)
sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ARCHIVE_TS\"/" "$META_FILE"

# Create _archive directory if needed
ARCHIVE_DIR="$WORK_DIR/_archive"
mkdir -p "$ARCHIVE_DIR"

# Check for name collision in archive
if [[ -d "$ARCHIVE_DIR/$SLUG" ]]; then
  if [[ "$JSON_OUTPUT" == true ]]; then
    json_error "Archive already contains an item named '$SLUG'"
  fi
  echo "[work] Error: Archive already contains an item named '$SLUG'." >&2
  exit 1
fi

# Move to archive
mv "$ITEM_DIR" "$ARCHIVE_DIR/$SLUG"

# Rebuild index
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true
bash "$SCRIPT_DIR/export-obsidian.sh" --work-hubs > /dev/null 2>&1 || true

# Get title for confirmation
TITLE=$(json_field "title" "$ARCHIVE_DIR/$SLUG/_meta.json")

if [[ "$JSON_OUTPUT" == true ]]; then
  python3 -c "
import json, sys
print(json.dumps({
    'slug': sys.argv[1],
    'archived_to': sys.argv[2],
    'title': sys.argv[3]
}))
" "$SLUG" "_work/_archive/$SLUG" "$TITLE"
  exit 0
fi

echo "[work] Archived: $SLUG ($TITLE)"
echo "[work] Moved to: _work/_archive/$SLUG"
