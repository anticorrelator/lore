#!/usr/bin/env bash
# relate-work.sh — Add or remove related work item references in _meta.json
# Usage: bash relate-work.sh <slug> --add <target> [--bidirectional] [--json]
#        bash relate-work.sh <slug> --remove <target> [--bidirectional] [--json]
# Idempotent: adding an existing relation or removing a non-existent one is a no-op.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
SLUG=""
TARGET=""
ACTION=""
BIDIRECTIONAL=0
JSON_MODE=0

if [[ $# -lt 1 ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: relate-work.sh <slug> --add <target> [--bidirectional] [--json]" >&2
  echo "       relate-work.sh <slug> --remove <target> [--bidirectional] [--json]" >&2
  exit 1
fi

SLUG="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --add)
      ACTION="add"
      TARGET="$2"
      shift 2
      ;;
    --remove)
      ACTION="remove"
      TARGET="$2"
      shift 2
      ;;
    --bidirectional)
      BIDIRECTIONAL=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "Unknown flag '$1'"
      fi
      echo "[work] Error: Unknown flag '$1'" >&2
      echo "Usage: relate-work.sh <slug> --add <target> [--bidirectional] [--json]" >&2
      echo "       relate-work.sh <slug> --remove <target> [--bidirectional] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No action specified. Use --add or --remove."
  fi
  echo "[work] Error: No action specified. Use --add or --remove." >&2
  exit 1
fi

if [[ -z "$TARGET" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing target slug for --$ACTION."
  fi
  echo "[work] Error: Missing target slug for --$ACTION." >&2
  exit 1
fi

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work directory found"
  fi
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

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
if [[ -z "$ITEM_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Work item not found: $SLUG"
  fi
  echo "[work] Error: Work item not found: $SLUG" >&2
  exit 1
fi

META_FILE="$ITEM_DIR/_meta.json"
if [[ ! -f "$META_FILE" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No _meta.json found for: $SLUG"
  fi
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# --- Reject self-references ---
if [[ "$TARGET" == "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Cannot relate a work item to itself: $SLUG"
  fi
  echo "[work] Error: Cannot relate a work item to itself: $SLUG" >&2
  exit 1
fi

# --- Validate target exists ---
TARGET_DIR=$(find_item_dir "$TARGET")
if [[ -z "$TARGET_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Target work item not found: $TARGET"
  fi
  echo "[work] Error: Target work item not found: $TARGET" >&2
  exit 1
fi

# --- Perform add/remove on a single _meta.json via Python ---
# Returns exit code 0 always; prints "changed" or "no-op" to stdout.
apply_relation() {
  local meta="$1"
  local action="$2"
  local target="$3"

  python3 - "$meta" "$action" "$target" << 'PYEOF'
import json, sys

meta_path = sys.argv[1]
action = sys.argv[2]
target = sys.argv[3]

with open(meta_path, "r") as f:
    data = json.load(f)

related = data.get("related_work", [])
if not isinstance(related, list):
    related = []

if action == "add":
    if target in related:
        print("no-op")
        sys.exit(0)
    related.append(target)
    changed = True
else:  # remove
    if target not in related:
        print("no-op")
        sys.exit(0)
    related = [s for s in related if s != target]
    changed = True

data["related_work"] = related

with open(meta_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("changed")
PYEOF
}

# --- Apply to primary item ---
RESULT=$(apply_relation "$META_FILE" "$ACTION" "$TARGET")

if [[ "$RESULT" == "changed" ]]; then
  update_meta_timestamp "$ITEM_DIR"
fi

# --- Apply bidirectional (best-effort) ---
BIDIR_STATUS="skipped"
if [[ $BIDIRECTIONAL -eq 1 ]]; then
  TARGET_META="$TARGET_DIR/_meta.json"
  if [[ -f "$TARGET_META" ]]; then
    BIDIR_RESULT=$(apply_relation "$TARGET_META" "$ACTION" "$SLUG" 2>&1) || {
      echo "[work] Warning: Failed to apply reverse relation to $TARGET" >&2
      BIDIR_STATUS="failed"
    }
    if [[ "$BIDIR_STATUS" != "failed" ]]; then
      if [[ "$BIDIR_RESULT" == "changed" ]]; then
        update_meta_timestamp "$TARGET_DIR"
        BIDIR_STATUS="changed"
      else
        BIDIR_STATUS="no-op"
      fi
    fi
  else
    echo "[work] Warning: No _meta.json for target $TARGET — skipping reverse relation" >&2
    BIDIR_STATUS="failed"
  fi
fi

# --- Rebuild index ---
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# --- Output ---
TITLE=$(json_field "title" "$META_FILE")

if [[ $JSON_MODE -eq 1 ]]; then
  python3 - "$META_FILE" "$ACTION" "$TARGET" "$RESULT" "$BIDIR_STATUS" << 'PYEOF'
import json, sys

meta_path, action, target, result, bidir_status = sys.argv[1:6]

with open(meta_path) as f:
    data = json.load(f)

out = {
    "slug": data.get("slug"),
    "title": data.get("title"),
    "action": action,
    "target": target,
    "changed": result == "changed",
    "related_work": data.get("related_work", []),
    "bidirectional_status": bidir_status,
}
print(json.dumps(out, indent=2))
PYEOF
  exit 0
fi

if [[ "$RESULT" == "no-op" ]]; then
  if [[ "$ACTION" == "add" ]]; then
    echo "[work] No change: $SLUG already includes $TARGET in related_work"
  else
    echo "[work] No change: $TARGET not present in $SLUG related_work"
  fi
else
  echo "[work] $(echo "$ACTION" | awk '{print toupper(substr($0,1,1)) substr($0,2)}') relation: $SLUG ($TITLE) → $TARGET"
fi

if [[ $BIDIRECTIONAL -eq 1 && "$BIDIR_STATUS" == "changed" ]]; then
  TARGET_TITLE=$(json_field "title" "$TARGET_DIR/_meta.json")
  echo "[work] Reverse relation applied: $TARGET ($TARGET_TITLE)"
fi
