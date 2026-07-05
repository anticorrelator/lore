#!/usr/bin/env bash
# set-work-meta.sh — Set metadata fields on an existing work item
# Usage: bash set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--project <name>] [--intent-anchor <text>] [--related-work <slug>] [--blocked-by <slug>] [--ceremony-depth <1-3|"">]
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
# --blocked-by: append-only dependency edges. Same validate-then-append
# contract as --related-work, plus a write-time cycle check.
BLOCKED_BY_SLUGS=()
CEREMONY_DEPTH=""
HAS_CEREMONY_DEPTH=0

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
  echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--intent-anchor <text>] [--related-work <slug>] [--blocked-by <slug>] [--ceremony-depth <1-3|\"\">] [--detect-pr] [--json]" >&2
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
    --blocked-by)
      BLOCKED_BY_SLUGS+=("$2")
      shift 2
      ;;
    --ceremony-depth)
      CEREMONY_DEPTH="$2"
      HAS_CEREMONY_DEPTH=1
      shift 2
      ;;
    *)
      echo "[work] Error: Unknown flag '$1'" >&2
      echo "Usage: set-work-meta.sh <slug> [--issue <value>] [--pr <value>] [--scope <scope>] [--project <name>] [--intent-anchor <text>] [--related-work <slug>] [--blocked-by <slug>] [--ceremony-depth <1-3|\"\">] [--detect-pr] [--json]" >&2
      exit 1
      ;;
  esac
done

if [[ "$HAS_ISSUE" -eq 0 && "$HAS_PR" -eq 0 && "$HAS_SCOPE" -eq 0 && "$HAS_PROJECT" -eq 0 && "$HAS_INTENT_ANCHOR" -eq 0 && "$DETECT_PR" -eq 0 && ${#RELATED_WORK_SLUGS[@]} -eq 0 && ${#BLOCKED_BY_SLUGS[@]} -eq 0 && "$HAS_CEREMONY_DEPTH" -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No fields to set. Provide --issue, --pr, --scope, --project, --intent-anchor, --related-work, --blocked-by, --ceremony-depth, and/or --detect-pr."
  fi
  echo "[work] Error: No fields to set. Provide --issue, --pr, --scope, --project, --intent-anchor, --related-work, --blocked-by, --ceremony-depth, and/or --detect-pr." >&2
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

# Validate --ceremony-depth: an empty value clears the field; otherwise it must
# be an integer 1-3. Hand-rolled check — no shared lib.sh enum helper exists.
if [[ "$HAS_CEREMONY_DEPTH" -eq 1 && -n "$CEREMONY_DEPTH" ]] && ! [[ "$CEREMONY_DEPTH" =~ ^[1-3]$ ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Invalid --ceremony-depth '$CEREMONY_DEPTH'. Valid values: integer 1-3 (or empty to clear)."
  fi
  echo "[work] Error: Invalid --ceremony-depth '$CEREMONY_DEPTH'. Valid values: integer 1-3 (or empty to clear)." >&2
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
    else
      warn_near_project_label "$WORK_DIR" "$PROJECT"
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

if [[ "$HAS_CEREMONY_DEPTH" -eq 1 ]]; then
  # Scalar set (not append). A non-empty value is stored as an integer; an
  # empty value removes the field, mirroring --project clear semantics.
  python3 - "$META_FILE" "$CEREMONY_DEPTH" << 'PYEOF'
import json, sys
path, depth = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if depth:
    data["ceremony_depth"] = int(depth)
else:
    data.pop("ceremony_depth", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("ceremony_depth=${CEREMONY_DEPTH:-\"\"}")
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

if [[ ${#BLOCKED_BY_SLUGS[@]} -gt 0 ]]; then
  # Same validate-then-append contract as --related-work: validate shape and
  # existence (active or archive) before mutating, reject the whole call on any
  # invalid slug, append-only and deduplicated. Blocked_by additionally rejects
  # self-reference and any edge that would close a dependency cycle.
  BLOCKED_BY_KEBAB_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
  for blocked_slug in "${BLOCKED_BY_SLUGS[@]}"; do
    if [[ -z "$blocked_slug" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--blocked-by value cannot be empty"
      fi
      echo "[work] Error: --blocked-by value cannot be empty." >&2
      exit 1
    fi
    if ! [[ "$blocked_slug" =~ $BLOCKED_BY_KEBAB_RE ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--blocked-by '$blocked_slug' is not a valid kebab-case slug"
      fi
      echo "[work] Error: --blocked-by '$blocked_slug' is not a valid kebab-case slug." >&2
      exit 1
    fi
    if [[ "$blocked_slug" == "$SLUG" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "a work item cannot be blocked by itself: $SLUG"
      fi
      echo "[work] Error: a work item cannot be blocked by itself: $SLUG." >&2
      exit 1
    fi
    if [[ ! -d "$WORK_DIR/$blocked_slug" && ! -d "$WORK_DIR/_archive/$blocked_slug" ]]; then
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "--blocked-by '$blocked_slug' does not refer to an existing work item"
      fi
      echo "[work] Error: --blocked-by '$blocked_slug' does not refer to an existing work item (checked $WORK_DIR and $WORK_DIR/_archive)." >&2
      exit 1
    fi
  done

  BLOCKED_BY_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${BLOCKED_BY_SLUGS[@]}")

  # Write-time cycle check: adding "$SLUG --blocked-by A" closes a loop iff
  # $SLUG is already reachable from A along blocked_by edges. Walk breadth-first
  # over _meta.json across the active tree and _archive/ (a cycle may route
  # through an archived item). On a hit, print the cycle path and reject.
  CYCLE_PATH=$(python3 - "$WORK_DIR" "$SLUG" "$BLOCKED_BY_JSON" << 'PYEOF'
import json, os, sys
from collections import deque

work_dir, slug, new_json = sys.argv[1], sys.argv[2], sys.argv[3]
new_blockers = json.loads(new_json)

def blocked_by_of(item):
    for base in (os.path.join(work_dir, item),
                 os.path.join(work_dir, "_archive", item)):
        meta = os.path.join(base, "_meta.json")
        if os.path.isfile(meta):
            try:
                with open(meta, encoding="utf-8") as f:
                    val = json.load(f).get("blocked_by", [])
            except (json.JSONDecodeError, OSError):
                return []
            return val if isinstance(val, list) else []
    return []

for start in new_blockers:
    parent = {start: None}
    queue = deque([start])
    while queue:
        cur = queue.popleft()
        if cur == slug:
            path = []
            node = cur
            while node is not None:
                path.append(node)
                node = parent[node]
            path.reverse()  # start -> ... -> slug (blocked_by edge direction)
            print(" -> ".join([slug] + path))  # slug -> start -> ... -> slug
            sys.exit(0)
        for nxt in blocked_by_of(cur):
            if nxt not in parent:
                parent[nxt] = cur
                queue.append(nxt)
sys.exit(0)
PYEOF
)
  if [[ -n "$CYCLE_PATH" ]]; then
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "--blocked-by would create a dependency cycle: $CYCLE_PATH"
    fi
    echo "[work] Error: --blocked-by would create a dependency cycle: $CYCLE_PATH" >&2
    exit 1
  fi

  python3 - "$META_FILE" "$BLOCKED_BY_JSON" << 'PYEOF'
import json, sys
path, new_json = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
existing = data.get("blocked_by", []) or []
new_slugs = json.loads(new_json)
seen = set(existing)
for slug in new_slugs:
    if slug not in seen:
        existing.append(slug)
        seen.add(slug)
data["blocked_by"] = existing
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
  CHANGES+=("blocked_by+=${BLOCKED_BY_SLUGS[*]}")
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
