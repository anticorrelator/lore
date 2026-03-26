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

    # Normalize fields — tolerate non-standard _meta.json schemas by
    # coercing types and providing defaults for missing keys.
    def str_field(key, default="", aliases=None):
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

    def list_field(key, default=None, aliases=None):
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

    plans.append({
        "slug": meta.get("slug", slug),
        "title": str_field("title", slug),
        "status": str_field("status", "active"),
        "branches": list_field("branches", aliases=["branch"]),
        "tags": list_field("tags"),
        "created": str_field("created"),
        "updated": str_field("updated"),
        "issue": str_field("issue"),
        "pr": str_field("pr"),
        "has_plan_doc": os.path.exists(os.path.join(parent, "plan.md")),
        "has_execution_log": os.path.exists(os.path.join(parent, "execution-log.md"))
                          or os.path.exists(os.path.join(parent, "execution_log.md")),
    })

index = {
    "version": 1,
    "repo": repo_name,
    "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "plans": plans,
}

with open(index_path, "w") as f:
    json.dump(index, f, indent=2)
    f.write("\n")

print(f"Work index updated: {index_path} ({len(plans)} items)")
PYEOF
