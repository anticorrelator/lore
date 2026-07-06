#!/usr/bin/env bash
# create-work.sh — Create a new work item in _work/
# Usage: bash create-work.sh --title <name> [--slug <slug>] [--description <text>] [--intent-anchor <text>] [--directory <path>] [--issue <ref>] [--pr <ref>] [--tags <tag1,tag2>] [--scope <scope>] [--project <name>] [--reuse-project] [--json] [--detect-pr]
# Creates _work/<slug>/ with _meta.json and notes.md, then updates the index.
#
# --scope (Phase 2 — work item 02-durable-signal-foundation):
#   The work-item scope is the *absolute anchor* for any capture produced during the cycle.
#   Downstream, `lore scale compute` combines this scope with the role×slot matrix offset
#   to determine the absolute capture scale.
#   Valid values: architectural | subsystem | implementation | granular-fix | cross-cycle-meta
#   Default: subsystem.
#   Unknown values are rejected at the CLI level. Legacy work items without the field
#   continue to work — readers treat a missing scope as `subsystem`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
NAME=""
SLUG_OVERRIDE=""
DESCRIPTION=""
INTENT_ANCHOR=""
TARGET_DIR=""
ISSUE=""
PR=""
TAGS=""
SCOPE="subsystem"
# --project: optional grouping label. Slugified on write; the stored slug is
# both the canonical value and the display value. "" = ungrouped.
PROJECT=""
# --reuse-project: knowingly reuse a name that matches an archived project
# identity (otherwise the write-boundary gate rejects it), reactivating it.
REUSE_PROJECT=0
JSON_MODE=0
DETECT_PR=0
# --related-work: append-only references to other work items. May be passed
# multiple times; values are accumulated into RELATED_WORK_SLUGS. Each entry
# must be non-empty and kebab-case-shaped. The closure-acceptance partial-
# residue path in /implement Step 6 invokes this with the parent slug so the
# child's _meta.json.related_work points back at the parent.
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

if [[ $# -ge 1 && "$1" == --* ]]; then
  # Flag mode
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title)
        NAME="$2"
        shift 2
        ;;
      --slug)
        SLUG_OVERRIDE="$2"
        shift 2
        ;;
      --description)
        DESCRIPTION="$2"
        shift 2
        ;;
      --intent-anchor)
        INTENT_ANCHOR="$2"
        shift 2
        ;;
      --directory)
        TARGET_DIR="$2"
        shift 2
        ;;
      --issue)
        ISSUE="$2"
        shift 2
        ;;
      --pr)
        PR="$2"
        shift 2
        ;;
      --tags)
        TAGS="$2"
        shift 2
        ;;
      --scope)
        SCOPE="$2"
        shift 2
        ;;
      --project)
        PROJECT="$2"
        shift 2
        ;;
      --reuse-project)
        REUSE_PROJECT=1
        shift
        ;;
      --json)
        JSON_MODE=1
        shift
        ;;
      --detect-pr)
        DETECT_PR=1
        shift
        ;;
      --related-work)
        RELATED_WORK_SLUGS+=("$2")
        shift 2
        ;;
      *)
        echo "[work] Error: Unknown flag '$1'" >&2
        echo "Usage: create-work.sh --title <name> [--slug <slug>] [--description <text>] [--intent-anchor <text>] [--directory <path>] [--issue <ref>] [--pr <ref>] [--tags <tag1,tag2>] [--scope <scope>] [--project <name>] [--reuse-project] [--related-work <slug>] [--json] [--detect-pr]" >&2
        exit 1
        ;;
    esac
  done
else
  echo "[work] Error: Use flag mode: create-work.sh --title <name> [--description <text>] [--intent-anchor <text>] [--tags <tags>] [--json]" >&2
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-$(pwd)}"

if [[ -z "$NAME" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing work item name"
  fi
  echo "[work] Error: Missing work item name." >&2
  echo "Usage: create-work.sh --title <name> [--description <text>] [--intent-anchor <text>] [--directory <path>] [--issue <ref>] [--pr <ref>] [--tags <tag1,tag2>] [--scope <scope>] [--json]" >&2
  exit 1
fi

# Validate --scope against the enum (rejects unknown values).
if ! is_valid_scope "$SCOPE"; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Invalid --scope '$SCOPE'. Valid values: ${VALID_SCOPES[*]}"
  fi
  echo "[work] Error: Invalid --scope '$SCOPE'. Valid values: ${VALID_SCOPES[*]}" >&2
  exit 1
fi
# Warn on long titles (>70 chars, git convention)
if [[ ${#NAME} -gt 70 ]]; then
  echo "[work] Warning: Title is ${#NAME} chars (recommended ≤70)." >&2
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

WORK_DIR="$KNOWLEDGE_DIR/_work"

# Initialize _work/ if it doesn't exist
if [[ ! -d "$WORK_DIR" ]]; then
  bash "$SCRIPT_DIR/init-work.sh" "$TARGET_DIR"
fi

# --- Validate --related-work slugs ---
# Per closure-acceptance-reconciliation D3: invalid slugs fail the create call
# with a non-zero exit. The contract (shape + existence) is enforced before
# any directory is created so a rejection leaves no half-created state.
# Shape: lowercase kebab-case (matches what slugify() produces).
# Existence: must resolve to either an active _work/<slug>/ or _work/_archive/<slug>/.
RELATED_WORK_KEBAB_RE='^[a-z0-9]+(-[a-z0-9]+)*$'
for related_slug in "${RELATED_WORK_SLUGS[@]+"${RELATED_WORK_SLUGS[@]}"}"; do
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

# Slugify the name (or use explicit --slug override)
if [[ -n "$SLUG_OVERRIDE" ]]; then
  SLUG=$(slugify "$SLUG_OVERRIDE")
else
  SLUG=$(slugify "$NAME")
fi

if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Name '$NAME' produced an empty slug"
  fi
  echo "[work] Error: Name '$NAME' produced an empty slug." >&2
  exit 1
fi

# Normalize the project label; the slug is stored as-is and doubles as the
# display value.
if [[ -n "$PROJECT" ]]; then
  PROJECT_INPUT="$PROJECT"
  PROJECT=$(slugify "$PROJECT")
  if [[ -z "$PROJECT" ]]; then
    echo "[work] Warning: --project '$PROJECT_INPUT' produced an empty slug; item left ungrouped." >&2
  else
    warn_near_project_label "$WORK_DIR" "$PROJECT"
    # Write-boundary uniqueness gate: joining an archived project identity
    # requires --reuse-project (which reactivates it). Active joins pass free.
    PROJECT_STATE=$(project_identity_state "$WORK_DIR" "$PROJECT")
    if [[ "$PROJECT_STATE" == "archived" ]]; then
      if [[ $REUSE_PROJECT -eq 0 ]]; then
        MSG="Project '$PROJECT' is archived. Either pass --reuse-project to knowingly continue the archived project (reactivates it), or choose a different name."
        if [[ $JSON_MODE -eq 1 ]]; then
          json_error "$MSG"
        fi
        echo "[work] Error: $MSG" >&2
        exit 1
      fi
      set_project_record_status "$WORK_DIR" "$PROJECT" active
    fi
  fi
fi

# Check for similar slugs (substring overlap in either direction)
SIMILAR=()
for existing_dir in "$WORK_DIR"/*/; do
  [[ ! -d "$existing_dir" ]] && continue
  existing_slug=$(basename "$existing_dir")
  [[ "$existing_slug" == _* ]] && continue  # skip _archive, _index, etc.
  # Check if new slug contains existing slug or vice versa
  if [[ "$SLUG" == *"$existing_slug"* || "$existing_slug" == *"$SLUG"* ]]; then
    existing_title=$(python3 -c "import json; print(json.load(open('$existing_dir/_meta.json'))['title'])" 2>/dev/null || echo "$existing_slug")
    SIMILAR+=("$existing_slug ($existing_title)")
  fi
done

if [[ ${#SIMILAR[@]} -gt 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Similar work item(s) already exist: ${SIMILAR[*]}"
  fi
  echo "[work] Warning: Similar work item(s) already exist:" >&2
  for s in "${SIMILAR[@]}"; do
    echo "  - $s" >&2
  done
  echo "[work] Error: Refusing to create '$SLUG' — use a distinct name or work with the existing item." >&2
  exit 1
fi

# Exact duplicate: append numeric suffix (-2, -3, ...)
if [[ -d "$WORK_DIR/$SLUG" ]]; then
  BASE_SLUG="$SLUG"
  N=2
  while [[ -d "$WORK_DIR/${BASE_SLUG}-${N}" ]]; do
    N=$((N + 1))
  done
  SLUG="${BASE_SLUG}-${N}"
fi

# Get current git branch (may be empty if not in a git repo)
BRANCH=$(get_git_branch)

# Build branches JSON array
if [[ -n "$BRANCH" ]]; then
  BRANCHES_JSON="[\"$BRANCH\"]"
else
  BRANCHES_JSON="[]"
fi

# Title case: capitalize first letter of each word
TITLE=$(echo "$NAME" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

TIMESTAMP=$(timestamp_iso)

# Build tags JSON array from comma-separated string
TAGS_JSON="[]"
if [[ -n "$TAGS" ]]; then
  TAGS_JSON="["
  first=true
  IFS=',' read -ra TAG_ARRAY <<< "$TAGS"
  for tag in "${TAG_ARRAY[@]}"; do
    tag="${tag## }"
    tag="${tag%% }"
    [[ -z "$tag" ]] && continue
    [[ "$first" == true ]] && first=false || TAGS_JSON+=","
    TAGS_JSON+="\"$tag\""
  done
  TAGS_JSON+="]"
fi

# Create the work item directory
mkdir -p "$WORK_DIR/$SLUG"

# Build related_work JSON from validated slugs (append-only by construction
# at create time; the partial-residue path in /implement Step 6 records the
# parent slug here so the child links back).
RELATED_WORK_JSON="[]"
if [[ ${#RELATED_WORK_SLUGS[@]} -gt 0 ]]; then
  RELATED_WORK_JSON=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${RELATED_WORK_SLUGS[@]}")
fi

# Write _meta.json
python3 - "$WORK_DIR/$SLUG/_meta.json" "$SLUG" "$TITLE" "$SCOPE" "$PROJECT" "$BRANCHES_JSON" "$TAGS_JSON" "$ISSUE" "$PR" "$TIMESTAMP" "$INTENT_ANCHOR" "$RELATED_WORK_JSON" << 'PYEOF'
import json
import sys

path, slug, title, scope, project, branches_json, tags_json, issue, pr, timestamp, intent_anchor, related_work_json = sys.argv[1:13]
meta = {
    "slug": slug,
    "title": title,
    "status": "active",
    "scope": scope,
    "project": project,
    "branches": json.loads(branches_json),
    "tags": json.loads(tags_json),
    "issue": issue,
    "pr": pr,
    "created": timestamp,
    "updated": timestamp,
    "related_knowledge": [],
    "related_work": json.loads(related_work_json),
}
if intent_anchor:
    meta["intent_anchor"] = intent_anchor
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
PYEOF

# Write notes.md
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M)"
if [[ -n "$DESCRIPTION" ]]; then
cat > "$WORK_DIR/$SLUG/notes.md" << NOTESEOF
# Session Notes: $TITLE

<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM followed by **Focus:**, **Progress:**, **Next:** fields. -->

$(if [[ -n "$INTENT_ANCHOR" ]]; then printf '## Intent Anchor\n%s\n\n' "$INTENT_ANCHOR"; fi)

## $TIMESTAMP
**Focus:** Initial scoping
$DESCRIPTION
NOTESEOF
else
cat > "$WORK_DIR/$SLUG/notes.md" << NOTESEOF
# Session Notes: $TITLE

<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM followed by **Focus:**, **Progress:**, **Next:** fields. -->

$(if [[ -n "$INTENT_ANCHOR" ]]; then printf '## Intent Anchor\n%s\n\n' "$INTENT_ANCHOR"; fi)

## $TIMESTAMP
**Focus:** Initial scoping
NOTESEOF
fi

# --- Auto-detect PR from branch ---
# Only run if --detect-pr is active, no explicit --pr was given, and we have a branch
if [[ $DETECT_PR -eq 1 && -z "$PR" && -n "$BRANCH" ]]; then
  if command -v gh &>/dev/null; then
    DETECTED_PR=$(gh pr list --head "$BRANCH" --json number --limit 1 2>/dev/null \
      | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['number'] if data else '')" 2>/dev/null) || true
    if [[ -n "$DETECTED_PR" ]]; then
      # Update pr field in _meta.json
      META_FILE="$WORK_DIR/$SLUG/_meta.json"
      if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"pr\": \"$DETECTED_PR\"/" "$META_FILE"
      else
        sed -i "s/\"pr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"pr\": \"$DETECTED_PR\"/" "$META_FILE"
      fi
    fi
  fi
fi

# Update the work index
if [[ $JSON_MODE -eq 1 ]]; then
  bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR" > /dev/null 2>&1 || true
  bash "$SCRIPT_DIR/export-obsidian.sh" --work-hubs > /dev/null 2>&1 || true
  json_output "$(cat "$WORK_DIR/$SLUG/_meta.json")"
fi

bash "$SCRIPT_DIR/update-work-index.sh" "$TARGET_DIR"
bash "$SCRIPT_DIR/export-obsidian.sh" --work-hubs > /dev/null 2>&1 || true

echo "Created work item '$TITLE' at $WORK_DIR/$SLUG"
