#!/usr/bin/env bash
# knowledge-tree.sh — render the subtree rooted at a knowledge entry
#
# Usage:
#   knowledge-tree.sh <entry-id>
#
# entry-id: category/slug (e.g. principles/scale-determined-by-role) or a path
#   relative to KDIR ending in .md (with or without the extension).
#
# Output: ASCII tree showing root and all descendants via parent/inferred_parents
#   edges. Each node shows: path  [scale | status]  (inferred) when applicable.
#
# Exit codes:
#   0 — success
#   1 — usage error or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: knowledge-tree.sh <entry-id>

Render the subtree rooted at a knowledge entry.

entry-id: category/slug (e.g. principles/scale-determined-by-role)
          Trailing .md is optional.

Each node displays: entry-path  [scale | status]
Inferred parent edges are marked with (inferred) on the child node.
EOF
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ROOT_ARG="$1"
KDIR=$(resolve_knowledge_dir)

# Normalize: strip leading KDIR prefix and trailing .md
ROOT_KEY="${ROOT_ARG#"$KDIR/"}"
ROOT_KEY="${ROOT_KEY%.md}"

python3 - "$KDIR" "$ROOT_KEY" <<'PYEOF'
import sys
import os
import re
import json
from collections import defaultdict

kdir = sys.argv[1]
root_key = sys.argv[2]

COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)

def parse_entry(path):
    """Return (title, scale, status, parents, inferred_parents) from an entry .md file."""
    try:
        with open(path, encoding='utf-8') as f:
            content = f.read()
    except OSError:
        return ('', '', '', [], [])

    # Title: first # heading
    title = ''
    for line in content.splitlines():
        if line.startswith('# '):
            title = line[2:].strip()
            break

    # Metadata from HTML comment
    scale = ''
    status = ''
    parents = []
    inferred_parents = []

    for m in COMMENT_RE.finditer(content):
        block = m.group(1)
        # Parse pipe-separated key: value pairs within the comment
        for part in block.split('|'):
            part = part.strip()
            if ':' not in part:
                continue
            k, _, v = part.partition(':')
            k = k.strip()
            v = v.strip()
            if k == 'scale':
                scale = v
            elif k == 'status':
                status = v
            elif k == 'parents':
                parents = [p.strip() for p in v.split(',') if p.strip()]
            elif k == 'inferred_parents':
                inferred_parents = [p.strip() for p in v.split(',') if p.strip()]

    return (title, scale, status, parents, inferred_parents)


def find_entry_path(kdir, key):
    """Resolve entry key to an absolute path. Returns None if not found."""
    # Direct path with extension
    direct = os.path.join(kdir, key + '.md')
    if os.path.isfile(direct):
        return direct
    # Already has .md
    with_ext = os.path.join(kdir, key)
    if os.path.isfile(with_ext):
        return with_ext
    return None


def collect_all_entries(kdir):
    """Walk KDIR and return list of relative paths (without .md) for all entries."""
    entries = []
    skip_prefixes = ('_', '.')
    for root, dirs, files in os.walk(kdir):
        # Skip underscore/dot directories
        dirs[:] = [d for d in sorted(dirs)
                   if not d.startswith(skip_prefixes)]
        for fname in sorted(files):
            if not fname.endswith('.md'):
                continue
            abs_path = os.path.join(root, fname)
            rel = os.path.relpath(abs_path, kdir)
            key = rel[:-3]  # strip .md
            entries.append(key)
    return entries


def normalize_parent_ref(ref, entry_key):
    """Normalize a parent reference to a relative key (category/slug)."""
    ref = ref.strip()
    if not ref:
        return None
    # Strip .md if present
    if ref.endswith('.md'):
        ref = ref[:-3]
    # If it's a knowledge: backlink style, strip prefix
    if ref.startswith('knowledge:'):
        ref = ref[len('knowledge:'):]
        # Strip any #anchor
        ref = ref.split('#')[0]
    return ref


# ---- Load manifest for fast path lookup ----
manifest_path = os.path.join(kdir, '_manifest.json')
manifest_paths = set()
if os.path.isfile(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        for e in manifest.get('entries', []):
            p = e.get('path', '')
            if p.endswith('.md'):
                p = p[:-3]
            if p:
                manifest_paths.add(p)
    except (json.JSONDecodeError, OSError):
        pass

# ---- Resolve root ----
root_path = find_entry_path(kdir, root_key)
if root_path is None:
    print(f"Error: entry not found: {root_key!r}", file=sys.stderr)
    sys.exit(1)

# ---- Collect all entries ----
all_keys = collect_all_entries(kdir)

# ---- Build parent → children map by reading each entry ----
# entry_meta[key] = (title, scale, status, parents, inferred_parents)
entry_meta = {}

# Children map: key → list of (child_key, is_inferred)
children_map = defaultdict(list)

for key in all_keys:
    abs_path = os.path.join(kdir, key + '.md')
    title, scale, status, parents, inferred_parents = parse_entry(abs_path)
    entry_meta[key] = (title, scale, status)

    for p in parents:
        pkey = normalize_parent_ref(p, key)
        if pkey:
            children_map[pkey].append((key, False))

    for p in inferred_parents:
        pkey = normalize_parent_ref(p, key)
        if pkey:
            children_map[pkey].append((key, True))

# ---- DFS render ----
root_entry_key = os.path.relpath(root_path, kdir)
if root_entry_key.endswith('.md'):
    root_entry_key = root_entry_key[:-3]

def render_node(key, prefix, is_last, is_inferred_edge, visited, is_root=False):
    meta = entry_meta.get(key, ('', '', ''))
    title, scale, status = meta

    parts = []
    if scale:
        parts.append(scale)
    if status:
        parts.append(status)
    annotation = '  [' + ' | '.join(parts) + ']' if parts else ''
    inferred_suffix = '  (inferred)' if is_inferred_edge else ''

    if is_root:
        print(f"{key}{annotation}")
    else:
        connector = '└── ' if is_last else '├── '
        print(f"{prefix}{connector}{key}{annotation}{inferred_suffix}")

    if key in visited:
        return
    visited = visited | {key}

    child_entries = children_map.get(key, [])
    # Deduplicate: if a child appears as both explicit and inferred, keep explicit
    seen_children = {}
    for (ckey, cinferred) in child_entries:
        if ckey not in seen_children or (not cinferred and seen_children[ckey]):
            seen_children[ckey] = cinferred
    sorted_children = sorted(seen_children.items())

    if is_root:
        child_prefix = ''
    else:
        extension = '    ' if is_last else '│   '
        child_prefix = prefix + extension

    for i, (ckey, cinferred) in enumerate(sorted_children):
        clast = (i == len(sorted_children) - 1)
        render_node(ckey, child_prefix, clast, cinferred, visited)

render_node(root_entry_key, '', True, False, set(), is_root=True)
PYEOF
