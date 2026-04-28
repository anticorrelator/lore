#!/usr/bin/env bash
# overview-subsystem.sh — Return architectural-scale framing for a subsystem + descent affordances.
#
# Usage: overview-subsystem.sh <subsystem> --scale-set <bucket> [--limit N] [--json]
#
# Finds architectural-scale entries matching <subsystem>. Falls back to subsystem-scale
# if no architectural entries exist. Renders with trust stamp + lists direct children.
#
# Exit codes:
#   0 — success
#   1 — usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LIMIT=3
JSON_OUTPUT=false
SUBSYSTEM=""
SCALE_SET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)  LIMIT="$2"; shift 2 ;;
    --json)   JSON_OUTPUT=true; shift ;;
    --scale-set) SCALE_SET="$2"; shift 2 ;;
    --scale-set=*) SCALE_SET="${1#--scale-set=}"; shift ;;
    --help|-h)
      echo "Usage: overview-subsystem.sh <subsystem> --scale-set <bucket> [--limit N] [--json]" >&2
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$SUBSYSTEM" ]]; then
        SUBSYSTEM="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SUBSYSTEM" ]]; then
  echo "Usage: overview-subsystem.sh <subsystem> --scale-set <bucket> [--limit N] [--json]" >&2
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: --scale-set is required; declare your retrieval scale, e.g. --scale-set architectural" >&2
  echo "  Buckets: application, architectural, subsystem, implementation" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  if "$JSON_OUTPUT"; then echo "[]"; fi
  exit 0
fi

check_fts_available
if [[ $USE_FTS -eq 0 ]]; then
  if "$JSON_OUTPUT"; then echo "[]"; fi
  exit 0
fi

LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"
if [[ ! -f "$LORE_SEARCH" ]]; then
  if "$JSON_OUTPUT"; then echo "[]"; fi
  exit 0
fi

# Search for architectural-scale entries first
ARCH_JSON=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$SUBSYSTEM" \
  --scale-set "$SCALE_SET" --min-scale architectural --limit "$LIMIT" --json --caller overview 2>/dev/null || echo "[]")

# If no architectural entries, fall back to subsystem-scale
FALLBACK_USED=false
if [[ "$ARCH_JSON" == "[]" || -z "$ARCH_JSON" ]]; then
  FALLBACK_USED=true
  ARCH_JSON=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$SUBSYSTEM" \
    --scale-set "$SCALE_SET" --min-scale subsystem --limit "$LIMIT" --json --caller overview 2>/dev/null || echo "[]")
fi

# If still no results, try plain search
if [[ "$ARCH_JSON" == "[]" || -z "$ARCH_JSON" ]]; then
  FALLBACK_USED=true
  ARCH_JSON=$(python3 "$LORE_SEARCH" search "$KNOWLEDGE_DIR" "$SUBSYSTEM" \
    --scale-set "$SCALE_SET" --limit "$LIMIT" --json --caller overview 2>/dev/null || echo "[]")
fi

export _OV_RESULTS="$ARCH_JSON"
export _OV_SCRIPT_DIR="$SCRIPT_DIR"
export _OV_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"
export _OV_SUBSYSTEM="$SUBSYSTEM"
export _OV_FALLBACK="$(if "$FALLBACK_USED"; then echo 1; else echo 0; fi)"
export _OV_JSON="$(if "$JSON_OUTPUT"; then echo 1; else echo 0; fi)"
export _OV_LORE_SEARCH="$LORE_SEARCH"

python3 - <<'PYEOF'
import json
import os
import re
import sqlite3
import subprocess
import sys

_script_dir = os.environ.get("_OV_SCRIPT_DIR", "")
if _script_dir:
    sys.path.insert(0, _script_dir)
from pk_search import render_trust_stamp

knowledge_dir = os.environ["_OV_KNOWLEDGE_DIR"]
subsystem = os.environ["_OV_SUBSYSTEM"]
fallback_used = os.environ.get("_OV_FALLBACK", "0") == "1"
json_mode = os.environ.get("_OV_JSON", "0") == "1"
lore_search = os.environ.get("_OV_LORE_SEARCH", "")

results = json.loads(os.environ.get("_OV_RESULTS", "[]"))

# Load parent/child manifest for descent affordances
_KV_RE = re.compile(r"(\w[\w_]*):\s*([^|>]+?)(?=\s*\||\s*-->|\s*$)")
_META_COMMENT_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas", "principles", "workflows", "domains", "preferences"}


def _parse_parents_field(text, field_name):
    """Extract a comma-separated list field from HTML metadata comment."""
    for m in _META_COMMENT_RE.finditer(text):
        inner = m.group(1)
        if "learned:" not in inner:
            continue
        for kv in _KV_RE.finditer(inner):
            if kv.group(1).strip() == field_name:
                return [f.strip() for f in kv.group(2).strip().split(",") if f.strip() and f.strip() != "none"]
    return []


def _find_children_of(entry_rel, kdir):
    """Find knowledge entries that list entry_rel as a parent."""
    children = []
    for cat_dir in sorted(CATEGORY_DIRS):
        cat_path = os.path.join(kdir, cat_dir)
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
                parents = _parse_parents_field(text, "parents")
                inferred = _parse_parents_field(text, "inferred_parents")
                rel = os.path.relpath(fpath, kdir)
                # Normalize: drop .md
                rel_key = rel[:-3] if rel.endswith(".md") else rel
                entry_key = entry_rel[:-3] if entry_rel.endswith(".md") else entry_rel
                for p in parents + inferred:
                    # normalize parent ref: strip leading category or full path
                    p_norm = p.replace(".md", "").lstrip("/")
                    if p_norm == entry_key or entry_key.endswith("/" + p_norm) or p_norm.endswith("/" + entry_key):
                        children.append({
                            "file_path": rel,
                            "heading": re.search(r"^#\s+(.+)$", text, re.MULTILINE).group(1) if re.search(r"^#\s+(.+)$", text, re.MULTILINE) else fname,
                        })
                        break
    return children


if json_mode:
    out = []
    for r in results:
        entry = {
            "heading": r["heading"],
            "file_path": r["file_path"],
            "category": r.get("category"),
            "scale": r.get("scale"),
            "entry_status": r.get("entry_status", "current"),
            "confidence": r.get("confidence"),
            "learned_date": r.get("learned_date"),
            "template_version": r.get("template_version"),
            "score": r.get("score", 0),
            "snippet": r.get("snippet", ""),
            "fallback": fallback_used,
        }
        children = _find_children_of(r["file_path"], knowledge_dir)
        entry["children"] = [{"heading": c["heading"], "file_path": c["file_path"]} for c in children]
        out.append(entry)
    print(json.dumps(out, indent=2))
    sys.exit(0)

if not results:
    print(f'No entries found for subsystem "{subsystem}"')
    sys.exit(0)

scale_label = results[0].get("scale") or "unknown"
fallback_note = f" (no architectural entries found; showing {scale_label}-scale)" if fallback_used and results else ""
print(f'## Overview: {subsystem}{fallback_note}')
print()

for r in results:
    trust_line = render_trust_stamp(r)
    backlink = r["file_path"]
    if backlink.endswith(".md"):
        backlink = backlink[:-3]

    # Resolve full content
    content = None
    if lore_search:
        try:
            bl = f"[[knowledge:{backlink}]]"
            proc = subprocess.run(
                ["python3", lore_search, "resolve", knowledge_dir, bl, "--json"],
                capture_output=True, text=True, timeout=10
            )
            if proc.returncode == 0 and proc.stdout.strip():
                resolved = json.loads(proc.stdout.strip())
                if resolved and isinstance(resolved, list) and resolved[0].get("resolved"):
                    content = resolved[0]["content"]
        except (subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, IndexError):
            pass

    if content is None:
        content = r.get("snippet", "")

    print(f'### {r["heading"]}')
    print(f'From: {r["file_path"]}')
    print(trust_line)
    print()
    print(content)
    print()

    # List direct children as descent affordances
    children = _find_children_of(r["file_path"], knowledge_dir)
    if children:
        child_refs = [c["file_path"].replace(".md", "") for c in children[:5]]
        print(f'Children ({len(children)}): {", ".join(child_refs)}')
        print(f'Use `lore descend <entry>` or `lore expand <entry> --down` to drill down.')
        print()
    else:
        print('No children found. Use `lore expand <entry> --down` to check for children.')
        print()
PYEOF
