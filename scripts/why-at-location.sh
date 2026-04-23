#!/usr/bin/env bash
# why-at-location.sh — Reverse-lookup design-rationale entries for a code location.
#
# Usage: why-at-location.sh <file:line> [--limit N] [--json]
#
# Finds knowledge entries whose related_files metadata overlaps <file>.
# Ranks by structural importance (backlink in-degree). Renders with trust stamps.
# <line> is accepted but currently used only for display; filtering is file-level.
#
# Exit codes:
#   0 — success (zero results is still success)
#   1 — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LIMIT=5
JSON_OUTPUT=false
LOCATION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)  LIMIT="$2"; shift 2 ;;
    --json)   JSON_OUTPUT=true; shift ;;
    --help|-h)
      echo "Usage: why-at-location.sh <file:line> [--limit N] [--json]" >&2
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$LOCATION" ]]; then
        LOCATION="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$LOCATION" ]]; then
  echo "Usage: why-at-location.sh <file:line> [--limit N] [--json]" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  if "$JSON_OUTPUT"; then
    echo "[]"
  fi
  exit 0
fi

# Parse file from file:line (line is optional)
TARGET_FILE="${LOCATION%%:*}"
# Derive basename for loose matching
TARGET_BASENAME=$(basename "$TARGET_FILE")

# Run Python to scan knowledge entries for related_files matches
export _WHY_SCRIPT_DIR="$SCRIPT_DIR"
export _WHY_JSON="$(if "$JSON_OUTPUT"; then echo 1; else echo 0; fi)"
python3 - "$KNOWLEDGE_DIR" "$TARGET_FILE" "$TARGET_BASENAME" "$LIMIT" "$LOCATION" <<'PYEOF'
import json
import os
import re
import sqlite3
import sys

_script_dir = os.environ.get("_WHY_SCRIPT_DIR", "")
if _script_dir:
    sys.path.insert(0, _script_dir)
from pk_search import render_trust_stamp

knowledge_dir = sys.argv[1]
target_file = sys.argv[2]
target_basename = sys.argv[3]
limit = int(sys.argv[4])
location = sys.argv[5]

# Regex to extract key-value pairs from HTML metadata comments
_META_COMMENT_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
_KV_RE = re.compile(r"(\w[\w_]*):\s*([^|>]+?)(?=\s*\||\s*-->|\s*$)")

def _parse_related_files(text):
    """Extract related_files list from HTML metadata comment."""
    for m in _META_COMMENT_RE.finditer(text):
        inner = m.group(1)
        if "learned:" not in inner:
            continue
        for kv in _KV_RE.finditer(inner):
            if kv.group(1).strip() == "related_files":
                return [f.strip() for f in kv.group(2).strip().split(",") if f.strip()]
    return []

def _file_matches(related_files, target_file, target_basename):
    """Return True if any related file matches target_file or target_basename."""
    for rf in related_files:
        rf = rf.strip()
        if not rf:
            continue
        rf_basename = os.path.basename(rf)
        # Exact path match or path suffix match
        if rf == target_file or rf.endswith("/" + target_file) or target_file.endswith("/" + rf):
            return True
        # Basename match
        if rf_basename == target_basename:
            return True
    return False

# Walk all knowledge category directories
CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas", "principles", "workflows", "domains", "preferences"}

# Rationale-bearing categories get a rank boost
RATIONALE_CATEGORIES = {"principles", "architecture", "abstractions"}
RATIONALE_BOOST = 2.0

matches = []

for cat_dir in sorted(CATEGORY_DIRS):
    cat_path = os.path.join(knowledge_dir, cat_dir)
    if not os.path.isdir(cat_path):
        continue
    for root, dirs, files in os.walk(cat_path):
        dirs[:] = [d for d in dirs if not d.startswith("_") and d != "__pycache__"]
        for fname in sorted(files):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(root, fname)
            try:
                text = open(fpath, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            related = _parse_related_files(text)
            if not related or not _file_matches(related, target_file, target_basename):
                continue
            # Extract heading (H1)
            h1 = re.search(r"^#\s+(.+)$", text, re.MULTILINE)
            heading = h1.group(1).strip() if h1 else fname.replace(".md", "")
            rel_path = os.path.relpath(fpath, knowledge_dir)
            category = rel_path.split(os.sep)[0]
            matches.append({
                "heading": heading,
                "file_path": rel_path,
                "category": category,
                "abs_path": fpath,
                "related_files": related,
            })

# Load structural importance and metadata from DB
db_path = os.path.join(knowledge_dir, ".pk_search.db")
importance_map = {}
meta_map = {}  # abs_path -> {confidence, learned_date, entry_status, template_version}

if os.path.exists(db_path):
    try:
        conn = sqlite3.connect(db_path)
        rows = conn.execute(
            "SELECT file_path, heading, structural_importance, confidence, learned_date, entry_status, template_version "
            "FROM entries WHERE source_type = 'knowledge'"
        ).fetchall()
        conn.close()
        for fp, heading, imp, conf, learned, status, tv in rows:
            importance_map[(fp, heading)] = imp or 0.0
            meta_map[fp] = {
                "confidence": conf,
                "learned_date": learned,
                "entry_status": status or "current",
                "template_version": tv,
            }
    except (sqlite3.OperationalError, sqlite3.DatabaseError):
        pass

# Enrich matches with importance and metadata
for m in matches:
    fp = m["abs_path"]
    heading = m["heading"]
    imp = importance_map.get((fp, heading), 0.0)
    cat = m["category"]
    # Rationale boost: principles, architecture, abstractions rank higher
    boosted_imp = imp * RATIONALE_BOOST if cat in RATIONALE_CATEGORIES else imp
    m["structural_importance"] = imp
    m["boosted_importance"] = boosted_imp
    fm = meta_map.get(fp, {})
    m["confidence"] = fm.get("confidence")
    m["learned_date"] = fm.get("learned_date")
    m["entry_status"] = fm.get("entry_status", "current")
    m["template_version"] = fm.get("template_version")

# Sort by boosted importance descending, then category priority
CAT_PRIORITY = {"principles": 5, "architecture": 4, "abstractions": 3, "gotchas": 2, "conventions": 1, "workflows": 0, "domains": 0, "preferences": 0}
matches.sort(key=lambda x: (-x["boosted_importance"], -CAT_PRIORITY.get(x["category"], 0)))
matches = matches[:limit]

# --- Output ---
json_mode = os.environ.get("_WHY_JSON", "0") == "1"

if json_mode:
    out = []
    for m in matches:
        out.append({
            "heading": m["heading"],
            "file_path": m["file_path"],
            "category": m["category"],
            "structural_importance": m["structural_importance"],
            "confidence": m["confidence"],
            "learned_date": m["learned_date"],
            "entry_status": m["entry_status"],
            "template_version": m["template_version"],
            "related_files": m["related_files"],
        })
    print(json.dumps(out, indent=2))
    sys.exit(0)

if not matches:
    print(f'No design-rationale entries found for {location}')
    sys.exit(0)

print(f'## Design rationale for {location}')
print()
for i, m in enumerate(matches, 1):
    trust = render_trust_stamp(m)
    scale_str = ""
    imp_str = f" (importance: {m['structural_importance']:.2f})" if m["structural_importance"] > 0 else ""
    print(f"### {m['heading']}")
    print(f"From: {m['file_path']} [{m['category']}]{imp_str}")
    print(trust)
    # Read first non-empty paragraph of file content as snippet
    try:
        content = open(m["abs_path"], encoding="utf-8").read()
        # Strip HTML comments and H1
        content = re.sub(r"<!--.*?-->", "", content, flags=re.DOTALL).strip()
        content = re.sub(r"^#\s+.+$", "", content, flags=re.MULTILINE).strip()
        # Take first 300 chars
        snippet = content[:300]
        if len(content) > 300:
            snippet += "..."
        if snippet:
            print(snippet)
    except (OSError, UnicodeDecodeError):
        pass
    print()
PYEOF
