#!/usr/bin/env bash
# describe-project.sh — Create or update a project home at _work/_projects/<slug>/
# Usage: bash describe-project.sh <slug> [--anchor <text>] [--status <active|done|archived>] [--description <text>] [--reuse] [--json]
# Writes _meta.json (identity source of truth) + overview.md (description body)
# in the home directory. Creates the home when absent (omitted status defaults
# to "active", anchor and description default empty); on update, omitted fields
# keep their values. A legacy flat record migrates to the home on this touch.
# Describing a name that matches an archived project identity is a hard error
# unless --reuse is passed, which reactivates the project (status -> active
# unless --status says otherwise). Never creates, renames, or archives members.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

USAGE="Usage: describe-project.sh <slug> [--anchor <text>] [--status <active|done|archived>] [--description <text>] [--reuse] [--json]"

SLUG=""
ANCHOR=""
STATUS=""
DESCRIPTION=""
HAS_ANCHOR=0
HAS_STATUS=0
HAS_DESCRIPTION=0
REUSE=0
JSON_MODE=0

VALID_STATUS=(active done archived)
is_valid_status() {
  local candidate="$1"
  local s
  for s in "${VALID_STATUS[@]}"; do
    if [[ "$s" == "$candidate" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ $# -lt 1 ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "$USAGE" >&2
  exit 1
fi

SLUG="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --anchor)
      ANCHOR="$2"
      HAS_ANCHOR=1
      shift 2
      ;;
    --status)
      STATUS="$2"
      HAS_STATUS=1
      shift 2
      ;;
    --description)
      DESCRIPTION="$2"
      HAS_DESCRIPTION=1
      shift 2
      ;;
    --reuse)
      REUSE=1
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
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done

if [[ "$HAS_STATUS" -eq 1 ]] && ! is_valid_status "$STATUS"; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Invalid --status '$STATUS'. Valid values: ${VALID_STATUS[*]}"
  fi
  echo "[work] Error: Invalid --status '$STATUS'. Valid values: ${VALID_STATUS[*]}" >&2
  exit 1
fi

INPUT_SLUG="$SLUG"
SLUG=$(slugify "$SLUG")
if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Project label '$INPUT_SLUG' produced an empty slug"
  fi
  echo "[work] Error: Project label '$INPUT_SLUG' produced an empty slug." >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work directory found"
  fi
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

RECORD_DIR="$WORK_DIR/_projects"
mkdir -p "$RECORD_DIR"

# Migrate any legacy flat record to the directory home before reading or
# writing — describe is a mutating touch.
migrate_project_record "$WORK_DIR" "$SLUG"

HOME_DIR="$RECORD_DIR/$SLUG"
META="$HOME_DIR/_meta.json"

# Write-boundary uniqueness gate: describing a name that matches an archived
# project identity requires --reuse (which reactivates it). Active and free
# identities pass gate-free.
STATE=$(project_identity_state "$WORK_DIR" "$SLUG")
if [[ "$STATE" == "archived" && $REUSE -eq 0 ]]; then
  MSG="Project '$SLUG' is archived. Either pass --reuse to knowingly continue the archived project (reactivates it), or choose a different name."
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$MSG"
  fi
  echo "[work] Error: $MSG" >&2
  exit 1
fi
# Reuse of an archived identity reactivates to active unless --status overrides.
if [[ "$STATE" == "archived" && $REUSE -eq 1 && $HAS_STATUS -eq 0 ]]; then
  STATUS="active"
  HAS_STATUS=1
fi

CREATED=0
[[ -f "$META" ]] || CREATED=1

# Merge supplied fields over the existing home (or defaults on create) and
# rewrite _meta.json + overview.md. created is preserved across updates.
python3 - "$HOME_DIR" "$SLUG" "$HAS_STATUS" "$STATUS" "$HAS_ANCHOR" "$ANCHOR" "$HAS_DESCRIPTION" "$DESCRIPTION" "$(timestamp_iso)" << 'PYEOF'
import json, os, sys

home, slug, has_status, status, has_anchor, anchor, has_description, description, ts = sys.argv[1:10]
meta_path = os.path.join(home, "_meta.json")
overview_path = os.path.join(home, "overview.md")

title = " ".join(w.capitalize() for w in slug.split("-"))
cur_status, cur_anchor, cur_created = "active", "", ts
cur_body = ""

if os.path.exists(meta_path):
    with open(meta_path, encoding="utf-8") as f:
        meta = json.load(f)
    title = meta.get("title") or title
    cur_status = meta.get("status") or "active"
    cur_anchor = meta.get("anchor") or ""
    cur_created = meta.get("created") or ts
if os.path.exists(overview_path):
    with open(overview_path, encoding="utf-8") as f:
        cur_body = f.read().strip()

if has_status == "1":
    cur_status = status
if has_anchor == "1":
    cur_anchor = anchor
if has_description == "1":
    cur_body = description.strip()

os.makedirs(home, exist_ok=True)
meta = {
    "slug": slug,
    "title": title,
    "status": cur_status,
    "anchor": cur_anchor,
    "created": cur_created,
    "updated": ts,
}
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
if cur_body:
    with open(overview_path, "w", encoding="utf-8") as f:
        f.write(cur_body + "\n")
elif os.path.exists(overview_path):
    os.remove(overview_path)
PYEOF

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(python3 - "$META" "$SLUG" "$CREATED" << 'PYEOF'
import json, sys

meta_path, slug, created = sys.argv[1:4]
with open(meta_path, encoding="utf-8") as f:
    meta = json.load(f)
print(json.dumps({
    "slug": slug,
    "home": meta_path.rsplit("/", 1)[0],
    "status": meta.get("status", ""),
    "anchor": meta.get("anchor", ""),
    "created": created == "1",
}, indent=2))
PYEOF
)
  json_output "$RESULT"
fi

if [[ "$CREATED" -eq 1 ]]; then
  echo "[work] Created project home: $SLUG ($HOME_DIR)"
else
  echo "[work] Updated project home: $SLUG ($HOME_DIR)"
fi
