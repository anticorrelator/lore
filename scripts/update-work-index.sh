#!/usr/bin/env bash
# update-work-index.sh — Regenerate _work/_index.json from _meta.json files
# Usage: bash update-work-index.sh [directory]
# Scans all _work/*/_meta.json files and rebuilds the index using Python for
# correct JSON parsing/generation, tolerating malformed _meta.json files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  echo "No work directory found at: $WORK_DIR"
  exit 1
fi

python3 - "$WORK_DIR" << 'PYEOF'
import json, os, sys, glob
from datetime import datetime, timezone

work_dir = sys.argv[1]
index_path = os.path.join(work_dir, "_index.json")
repo_name = os.path.basename(os.path.dirname(work_dir))

plans = []
seen_slugs = set()

# Normalize fields — tolerate non-standard _meta.json schemas by
# coercing types and providing defaults for missing keys.
def str_field(meta, key, default="", aliases=None):
    """Extract a string field, coercing non-string values."""
    val = meta.get(key, None)
    if val is None and aliases:
        for alias in aliases:
            val = meta.get(alias, None)
            if val is not None:
                break
    if val is None:
        return default
    return str(val)

def list_field(meta, key, default=None, aliases=None):
    """Extract a list field, wrapping scalars in a list."""
    val = meta.get(key, None)
    if val is None and aliases:
        for alias in aliases:
            val = meta.get(alias, None)
            if val is not None:
                break
    if val is None:
        return default or []
    if isinstance(val, list):
        return val
    return [val]

for meta_path in sorted(glob.glob(os.path.join(work_dir, "*", "_meta.json"))):
    slug = os.path.basename(os.path.dirname(meta_path))
    if slug == "_archive" or slug in seen_slugs:
        continue
    seen_slugs.add(slug)

    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[warn] Skipping {slug}: {e}", file=sys.stderr)
        continue

    parent = os.path.dirname(meta_path)

    plans.append({
        "slug": meta.get("slug", slug),
        "title": str_field(meta, "title", slug),
        "status": str_field(meta, "status", "active"),
        "branches": list_field(meta, "branches", aliases=["branch"]),
        "tags": list_field(meta, "tags"),
        "created": str_field(meta, "created"),
        "updated": str_field(meta, "updated"),
        "issue": str_field(meta, "issue"),
        "pr": str_field(meta, "pr"),
        "related_work": list_field(meta, "related_work"),
        "has_plan_doc": os.path.exists(os.path.join(parent, "plan.md")),
        "has_execution_log": os.path.exists(os.path.join(parent, "execution-log.md"))
                          or os.path.exists(os.path.join(parent, "execution_log.md")),
    })

archived = []
for meta_path in sorted(glob.glob(os.path.join(work_dir, "_archive", "*", "_meta.json"))):
    slug = os.path.basename(os.path.dirname(meta_path))
    if slug in seen_slugs:
        continue
    seen_slugs.add(slug)

    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[warn] Skipping archived {slug}: {e}", file=sys.stderr)
        continue

    # archived_date: use explicit field if present, fall back to updated
    archived_date = str_field(meta, "archived_date") or str_field(meta, "updated")

    archived.append({
        "slug": meta.get("slug", slug),
        "title": str_field(meta, "title", slug),
        "status": str_field(meta, "status", "archived"),
        "archived_date": archived_date,
    })

index = {
    "version": 1,
    "repo": repo_name,
    "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "plans": plans,
    "archived": archived,
}

with open(index_path, "w") as f:
    json.dump(index, f, indent=2)
    f.write("\n")

print(f"Work index updated: {index_path} ({len(plans)} active, {len(archived)} archived)")
PYEOF
