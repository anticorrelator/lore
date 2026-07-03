#!/usr/bin/env bash
# describe-project.sh — Create or update a project record at _work/_projects/<slug>.md
# Usage: bash describe-project.sh <slug> [--anchor <text>] [--status <active|done|archived>] [--description <text>] [--json]
# Creates the record when absent (omitted status defaults to "active", anchor
# and description default empty); on update, omitted fields keep their values.
# Never creates, renames, or archives member work items.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

USAGE="Usage: describe-project.sh <slug> [--anchor <text>] [--status <active|done|archived>] [--description <text>] [--json]"

SLUG=""
ANCHOR=""
STATUS=""
DESCRIPTION=""
HAS_ANCHOR=0
HAS_STATUS=0
HAS_DESCRIPTION=0
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
RECORD="$RECORD_DIR/$SLUG.md"
mkdir -p "$RECORD_DIR"

CREATED=0
[[ -f "$RECORD" ]] || CREATED=1

# Merge supplied fields over the existing record (or defaults on create) and
# rewrite the whole file. Body (description) is everything after the field block.
python3 - "$RECORD" "$SLUG" "$HAS_STATUS" "$STATUS" "$HAS_ANCHOR" "$ANCHOR" "$HAS_DESCRIPTION" "$DESCRIPTION" << 'PYEOF'
import os, re, sys

record, slug, has_status, status, has_anchor, anchor, has_description, description = sys.argv[1:9]

title = " ".join(w.capitalize() for w in slug.split("-"))
cur_status, cur_anchor, cur_body = "active", "", ""

if os.path.exists(record):
    with open(record, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"^# (.+)$", text, re.MULTILINE)
    if m:
        title = m.group(1).strip()
    m = re.search(r"^\*\*Status:\*\*[ \t]*(.*)$", text, re.MULTILINE)
    if m:
        cur_status = m.group(1).strip() or "active"
    m = re.search(r"^\*\*Anchor:\*\*[ \t]*(.*)$", text, re.MULTILINE)
    if m:
        cur_anchor = m.group(1).strip()
    # Body = everything after the title/field header block: the first line
    # that is not blank, the H1, or one of the two bold fields.
    lines = text.splitlines()
    body_start = len(lines)
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or line.startswith("# ") or line.startswith("**Status:**") or line.startswith("**Anchor:**"):
            continue
        body_start = i
        break
    cur_body = "\n".join(lines[body_start:]).strip()

if has_status == "1":
    cur_status = status
if has_anchor == "1":
    cur_anchor = anchor
if has_description == "1":
    cur_body = description.strip()

out = f"# {title}\n\n**Status:** {cur_status}\n**Anchor:** {cur_anchor}\n"
if cur_body:
    out += f"\n{cur_body}\n"

with open(record, "w", encoding="utf-8") as f:
    f.write(out)
PYEOF

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(python3 - "$RECORD" "$SLUG" "$CREATED" << 'PYEOF'
import json, re, sys

record, slug, created = sys.argv[1:4]
with open(record, encoding="utf-8") as f:
    text = f.read()
status = re.search(r"^\*\*Status:\*\*[ \t]*(.*)$", text, re.MULTILINE).group(1).strip()
anchor = re.search(r"^\*\*Anchor:\*\*[ \t]*(.*)$", text, re.MULTILINE).group(1).strip()
print(json.dumps({
    "slug": slug,
    "record": record,
    "status": status,
    "anchor": anchor,
    "created": created == "1",
}, indent=2))
PYEOF
)
  json_output "$RESULT"
fi

if [[ "$CREATED" -eq 1 ]]; then
  echo "[work] Created project record: $SLUG ($RECORD)"
else
  echo "[work] Updated project record: $SLUG ($RECORD)"
fi
