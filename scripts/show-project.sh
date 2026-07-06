#!/usr/bin/env bash
# show-project.sh — Show a project: record fields (when a record exists) plus
# all members, active and archived, from _index.json.
# Usage: bash show-project.sh <slug> [--json]
# Read-only. A slug with no record and no members is an error; a recordless
# project with members renders a members-only view with a no-record notice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

USAGE="Usage: show-project.sh <slug> [--json]"

SLUG=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        echo "[work] Error: Unknown argument '$1'" >&2
        echo "$USAGE" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required argument: slug"
  fi
  echo "[work] Error: Missing required argument: slug" >&2
  echo "$USAGE" >&2
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

INDEX="$WORK_DIR/_index.json"

# Freshen the index so just-created or just-archived members show up.
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

HOME_DIR="$WORK_DIR/_projects/$SLUG"
FLAT="$WORK_DIR/_projects/$SLUG.md"

python3 - "$INDEX" "$HOME_DIR" "$FLAT" "$SLUG" "$JSON_MODE" << 'PYEOF'
import json, os, re, sys

index_path, home_dir, flat_path, slug, json_mode = sys.argv[1:6]
json_mode = json_mode == "1"

active, archived = [], []
try:
    with open(index_path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {}
# Members live in BOTH projections: plans[] alone loses archived members.
for item in data.get("plans") or []:
    if isinstance(item, dict) and str(item.get("project", "") or "") == slug:
        active.append(item)
for item in data.get("archived") or []:
    if isinstance(item, dict) and str(item.get("project", "") or "") == slug:
        archived.append(item)

# Read a file's text, or None when absent.
def read_file(path):
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            return f.read()
    return None

record = None
documents = []
home_meta = os.path.join(home_dir, "_meta.json")
if os.path.isfile(home_meta):
    # Directory home is authoritative. overview.md is the description; every
    # other file in the home is a project-level document, delivered in full.
    with open(home_meta, encoding="utf-8") as f:
        meta = json.load(f)
    overview = read_file(os.path.join(home_dir, "overview.md")) or ""
    record = {
        "title": meta.get("title") or slug,
        "status": meta.get("status") or "active",
        "anchor": meta.get("anchor") or "",
        "description": overview.strip(),
    }
    for name in sorted(os.listdir(home_dir)):
        if name in ("_meta.json", "overview.md") or name.startswith("_"):
            continue
        content = read_file(os.path.join(home_dir, name))
        if content is not None:
            documents.append({"name": name, "content": content})
elif os.path.isfile(flat_path):
    # Legacy flat record (unmigrated store): parse the bold fields and body.
    with open(flat_path, encoding="utf-8") as f:
        text = f.read()

    def field(name):
        m = re.search(rf"^\*\*{name}:\*\*[ \t]*(.*)$", text, re.MULTILINE)
        return m.group(1).strip() if m else ""

    m = re.search(r"^# (.+)$", text, re.MULTILINE)
    lines = text.splitlines()
    body_start = len(lines)
    for i, line in enumerate(lines):
        s = line.strip()
        if not s or line.startswith("# ") or line.startswith("**Status:**") or line.startswith("**Anchor:**"):
            continue
        body_start = i
        break
    record = {
        "title": m.group(1).strip() if m else slug,
        "status": field("Status") or "active",
        "anchor": field("Anchor"),
        "description": "\n".join(lines[body_start:]).strip(),
    }

if record is None and not active and not archived:
    if json_mode:
        print(json.dumps({"error": f"No project record or members found for: {slug}"}))
    else:
        print(f"[work] Error: No project record or members found for: {slug}", file=sys.stderr)
    sys.exit(1)

if json_mode:
    print(json.dumps({
        "slug": slug,
        "record": record,
        "documents": documents,
        "active": active,
        "archived": archived,
    }, indent=2))
    sys.exit(0)

print(f"=== Project: {slug} ===")
print()
if record:
    print(f"Title: {record['title']}")
    print(f"Status: {record['status']}")
    if record["anchor"]:
        print(f"Anchor: {record['anchor']}")
    if record["description"]:
        print()
        print(record["description"])
else:
    print("(no project record — members only; use `lore work project describe` to add one)")
print()
for doc in documents:
    print(f"--- Document: {doc['name']} ---")
    print(doc["content"].rstrip("\n"))
    print()
print(f"--- Active members ({len(active)}) ---")
for item in active:
    print(f"  {item.get('slug', '')}: {item.get('title', '')} (updated {item.get('updated', '')})")
if not active:
    print("  (none)")
print()
print(f"--- Archived members ({len(archived)}) ---")
for item in archived:
    print(f"  {item.get('slug', '')}: {item.get('title', '')} (archived {item.get('archived_date', '')})")
if not archived:
    print("  (none)")
print()
print(f"=== End Project: {slug} ===")
PYEOF
