#!/usr/bin/env bash
# set-work-meta.sh — Set metadata fields on an existing work item
# Usage: bash set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--project <name>] [--intent-anchor <text>]
# Updates the specified fields in _meta.json, touches the timestamp, and rebuilds the index.
#
# --scope (Phase 2 — work item 02-durable-signal-foundation):
#   Refines the work-item scope (capture-scale absolute anchor) after creation.
#   Valid values: architectural | subsystem | implementation | granular-fix | cross-cycle-meta
#   Unknown values are rejected. Missing fields are inserted; existing fields are overwritten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
SLUG=""
ISSUE=""
PR=""
SCOPE=""
PROJECT=""
INTENT_ANCHOR=""
HAS_ISSUE=0
HAS_PR=0
HAS_SCOPE=0
HAS_PROJECT=0
HAS_INTENT_ANCHOR=0
DETECT_PR=0
JSON_MODE=0
# --related-work: append-only references to other work items. May be passed
# multiple times. Per closure-acceptance-reconciliation D3, the flag MUST
# append (not replace) and reject invalid slugs with a non-zero exit.
RELATED_WORK_SLUGS=()

# Valid work-item scope values (Phase 2 capture-scale anchor).
VALID_SCOPES=(architectural subsystem implementation granular-fix cross-cycle-meta)
is_valid_scope() {
  local candidate="$1"
  local s
  for s in "${VALID_SCOPES[@]}"; do
    if [[ "$s" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ $# -lt 1 ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--intent-anchor <text>] [--detect-pr] [--json]" >&2
  exit 1
fi

SLUG="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      ISSUE="$2"
      HAS_ISSUE=1
      shift 2
      ;;
    --pr)
      PR="$2"
      HAS_PR=1
      shift 2
      ;;
    --scope)
      SCOPE="$2"
      HAS_SCOPE=1
      shift 2
      ;;
    --project)
      PROJECT="$2"
      HAS_PROJECT=1
      shift 2
      ;;
    --intent-anchor)
      INTENT_ANCHOR="$2"
      HAS_INTENT_ANCHOR=1
      shift 2
      ;;
    --detect-pr)
      DETECT_PR=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --related-work)
      RELATED_WORK_SLUGS+=("$2")
      shift 2
      ;;
    *)
      echo "[work] Error: Unknown flag '$1'" >&2
      echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--project <name>] [--intent-anchor <text>] [--related-work <slug>] [--detect-pr] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ "$HAS_ISSUE" -eq 0 && "$HAS_PR" -eq 0 && "$HAS_SCOPE" -eq 0 && "$HAS_PROJECT" -eq 0 && "$HAS_INTENT_ANCHOR" -eq 0 && "$DETECT_PR" -eq 0 && ${#RELATED_WORK_SLUGS[@]} -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No fields to set. Provide --issue, --pr, --scope, --project, --intent-anchor, --related-work, and/or --detect-pr."
  fi
  echo "[work] Error: No fields to set. Provide --issue, --pr, --scope, --project, --intent-anchor, --related-work, and/or --detect-pr." >&2
  exit 1
fi

# Validate --scope against the enum (rejects unknown values).
if [[ "$HAS_SCOPE" -eq 1 ]] && ! is_valid_scope "$SCOPE"; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Invalid --scope '$SCOPE'. Valid values: ${VALID_SCOPES[*]}"
  fi
  echo "[work] Error: Invalid --scope '$SCOPE'. Valid values: ${VALID_SCOPES[*]}" >&2
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

ITEM_DIR="$WORK_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
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
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No _meta.json found for: $SLUG"
  fi
  echo "[work] Error: No _meta.json found for: $SLUG" >&2
  exit 1
fi

# --- Detect PR from branch (if requested and --pr not explicitly set) ---
if [[ "$DETECT_PR" -eq 1 && "$HAS_PR" -eq 0 ]]; then
  BRANCH=$(json_array_field "branches" "$META_FILE" | sed 's/"//g' | cut -d, -f1)
  if [[ -n "$BRANCH" ]] && command -v gh &>/dev/null; then
    DETECTED_PR=$(gh pr list --head "$BRANCH" --json number,url --limit 1 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if data:
        print(data[0].get("url", ""))
except Exception:
    pass
' 2>/dev/null || true)
    if [[ -n "$DETECTED_PR" ]]; then
      PR="$DETECTED_PR"
      HAS_PR=1
    fi
  fi
fi

# --- Update fields ---
CHANGES=()

if [[ "$HAS_ISSUE" -eq 1 ]]; then
  if grep -q '"issue"' "$META_FILE" 2>/dev/null; then
    sed -i '' "s/\"issue\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"issue\": \"$ISSUE\"/" "$META_FILE"
  else
    # Insert before "created" line
    sed -i '' "s/\"created\"[[:space:]]*:/\"issue\": \"$ISSUE\",\n  \"created\":/" "$META_FILE"
  fi
  CHANGES+=("issue=$ISSUE")
fi

if [[ "$HAS_PR" -eq 1 ]]; then
  if grep -q '"pr"' "$META_FILE" 2>/dev/null; then
    # Use | as sed delimiter to handle URLs with slashes
    sed -i '' "s|\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"pr\": \"$PR\"|" "$META_FILE"
  else
    # Insert before "created" line
    sed -i '' "s|\"created\"[[:space:]]*:|\"pr\": \"$PR\",\n  \"created\":|" "$META_FILE"
  fi
  CHANGES+=("pr=$PR")
fi

if [[ "$HAS_SCOPE" -eq 1 ]]; then
  # Use python3 for robust JSON-aware update (preserves formatting; inserts or overwrites).
  python3 - "$META_FILE" "$SCOPE" << 'PYEOF'
import json, sys
path, scope = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
data["scope"] = scope
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("scope=$SCOPE")
fi

if [[ "$HAS_PROJECT" -eq 1 ]]; then
  # Non-empty values are slugified; the stored slug is also the display value.
  # An empty value clears project membership.
  if [[ -n "$PROJECT" ]]; then
    PROJECT_INPUT="$PROJECT"
    PROJECT=$(slugify "$PROJECT")
    if [[ -z "$PROJECT" ]]; then
      echo "[work] Warning: --project '$PROJECT_INPUT' produced an empty slug; clearing project." >&2
    fi
  fi
  python3 - "$META_FILE" "$PROJECT" << 'PYEOF'
import json, sys
path, project = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if project:
    data["project"] = project
else:
    data.pop("project", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("project=${PROJECT:-\"\"}")
fi

if [[ "$HAS_INTENT_ANCHOR" -eq 1 ]]; then
  python3 - "$META_FILE" "$INTENT_ANCHOR" << 'PYEOF'
import json, sys
path, intent_anchor = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if intent_anchor:
    data["intent_anchor"] = intent_anchor
else:
    data.pop("intent_anchor", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("intent_anchor=$INTENT_ANCHOR")
fi

if [[ ${#RELATED_WORK_SLUGS[@]} -gt 0 ]]; then
  # Per closure-acceptance-reconciliation D3: validate shape and existence
  # before mutating; reject the entire call on any invalid slug. Append-only
  # against existing related_work, deduplicated to keep the array stable
  # under repeated invocations.
  RELATED_WORK_KEBAB_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
  for related_slug in "${RELATED_WORK_SLUGS[@]}"; do
    if [[ -z "$related_slug" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--related-work value cannot be empty"
      fi
      echo "[work] Error: --related-work value cannot be empty." >&2
      exit 1
    fi
    if ! [[ "$related_slug" =~ $RELATED_WORK_KEBAB_RE ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--related-work '$related_slug' is not a valid kebab-case slug"
      fi
      echo "[work] Error: --related-work '$related_slug' is not a valid kebab-case slug." >&2
      exit 1
    fi
    if [[ ! -d "$WORK_DIR/$related_slug" && ! -d "$WORK_DIR/_archive/$related_slug" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--related-work '$related_slug' does not refer to an existing work item"
      fi
      echo "[work] Error: --related-work '$related_slug' does not refer to an existing work item (checked $WORK_DIR and $WORK_DIR/_archive)." >&2
      exit 1
    fi
  done

  RELATED_WORK_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${RELATED_WORK_SLUGS[@]}")
  python3 - "$META_FILE" "$RELATED_WORK_JSON" << 'PYEOF'
import json, sys
path, new_json = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
existing = data.get("related_work", []) or []
new_slugs = json.loads(new_json)
seen = set(existing)
for slug in new_slugs:
    if slug not in seen:
        existing.append(slug)
        seen.add(slug)
data["related_work"] = existing
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("related_work+=${RELATED_WORK_SLUGS[*]}")
fi

# --- Check if any changes were actually made ---
if [[ ${#CHANGES[@]} -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(cat "$META_FILE")"
  fi
  echo "[work] No changes made to $SLUG (--detect-pr found no associated PR)"
  exit 0
fi

# --- Update timestamp and rebuild index ---
update_meta_timestamp "$ITEM_DIR"
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(cat "$META_FILE")"
fi

TITLE=$(json_field "title" "$META_FILE")
echo "[work] Updated $SLUG ($TITLE): ${CHANGES[*]}"
