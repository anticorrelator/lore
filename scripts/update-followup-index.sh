#!/usr/bin/env bash
# update-followup-index.sh — Regenerate _followup_index.json from _meta.json files
# Usage: bash update-followup-index.sh [directory]
# Scans all _followups/*/_meta.json files and rebuilds the index using Python for
# correct JSON parsing/generation, grouping follow-ups by status into separate arrays.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"

if [[ ! -d "$FOLLOWUPS_DIR" ]]; then
  echo "No followups directory found at: $FOLLOWUPS_DIR"
  exit 1
fi

python3 - "$FOLLOWUPS_DIR" << 'PYEOF'
import json, os, sys, glob
from datetime import datetime, timezone

followups_dir = sys.argv[1]
index_path = os.path.join(os.path.dirname(followups_dir), "_followup_index.json")

pending = []
reviewed = []
promoted = []
dismissed = []

def str_field(meta, key, default=""):
    val = meta.get(key, None)
    if val is None:
        return default
    return str(val)

def list_field(meta, key, default=None):
    val = meta.get(key, None)
    if val is None:
        return default or []
    if isinstance(val, list):
        return val
    return [val]

for meta_path in sorted(glob.glob(os.path.join(followups_dir, "*", "_meta.json"))):
    followup_id = os.path.basename(os.path.dirname(meta_path))

    try:
        with open(meta_path) as f:
            meta = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"[warn] Skipping {followup_id}: {e}", file=sys.stderr)
        continue

    entry = {
        "id": meta.get("id", followup_id),
        "title": str_field(meta, "title", followup_id),
        "status": str_field(meta, "status", "pending"),
        "source": str_field(meta, "source", ""),
        "attachments": list_field(meta, "attachments"),
        "suggested_actions": list_field(meta, "suggested_actions"),
        "created": str_field(meta, "created"),
        "updated": str_field(meta, "updated"),
        "promoted_to": str_field(meta, "promoted_to"),
        "has_finding": os.path.exists(os.path.join(os.path.dirname(meta_path), "finding.md")),
    }

    status = entry["status"]
    if status == "reviewed":
        reviewed.append(entry)
    elif status == "promoted":
        promoted.append(entry)
    elif status == "dismissed":
        dismissed.append(entry)
    else:
        pending.append(entry)

index = {
    "version": 1,
    "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "pending": pending,
    "reviewed": reviewed,
    "promoted": promoted,
    "dismissed": dismissed,
}

with open(index_path, "w") as f:
    json.dump(index, f, indent=2)
    f.write("\n")

total = len(pending) + len(reviewed) + len(promoted) + len(dismissed)
print(f"Follow-up index updated: {index_path} ({len(pending)} pending, {len(reviewed)} reviewed, {len(promoted)} promoted, {len(dismissed)} dismissed, {total} total)")
PYEOF
