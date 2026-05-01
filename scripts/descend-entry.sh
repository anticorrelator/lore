#!/usr/bin/env bash
# descend-entry.sh — Show children of an entry filtered to the next scale down
#
# Like `expand-entry.sh --down`, but only returns children whose scale is
# exactly one step narrower than the parent entry's scale (per the registry
# ordinal: architecture > subsystem > implementation).
#
# Children without a scale field, or children at the same/higher scale, are
# excluded. When the parent has no scale field, all children are returned
# (same behavior as expand --down).
#
# Usage:
#   descend-entry.sh <entry-id>
#
# entry-id: category/slug (e.g. principles/scale-determined-by-role)
#   Trailing .md is optional.
#
# Exit codes:
#   0 — success
#   1 — usage error or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: descend-entry.sh <entry-id>

Return children of an entry filtered to the next scale down.
Children without a scale field or at the same/broader scale are excluded.
When the parent has no scale field, all children are returned.

entry-id: category/slug (e.g. principles/scale-determined-by-role)
          Trailing .md is optional.
EOF
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ENTRY_ARG="$1"
KDIR=$(resolve_knowledge_dir)

# Normalize: strip leading KDIR prefix and trailing .md
ENTRY_KEY="${ENTRY_ARG#"$KDIR/"}"
ENTRY_KEY="${ENTRY_KEY%.md}"

# Resolve parent entry's scale using expand-entry.sh output or direct parse
PARENT_SCALE=$(python3 - "$KDIR" "$ENTRY_KEY" <<'PYEOF'
import sys, os, re, json

kdir, entry_key = sys.argv[1:3]
COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)

def find_entry_path(kdir, key):
    direct = os.path.join(kdir, key + '.md')
    if os.path.isfile(direct):
        return direct
    with_ext = os.path.join(kdir, key)
    if os.path.isfile(with_ext):
        return with_ext
    return None

entry_path = find_entry_path(kdir, entry_key)
if entry_path is None:
    print("NOT_FOUND")
    sys.exit(0)

with open(entry_path, encoding='utf-8') as f:
    content = f.read()

scale = ''
for m in COMMENT_RE.finditer(content):
    for part in m.group(1).split('|'):
        part = part.strip()
        if ':' not in part:
            continue
        k, _, v = part.partition(':')
        if k.strip() == 'scale':
            scale = v.strip()
            break
    if scale:
        break

print(scale)
PYEOF
)

if [[ "$PARENT_SCALE" == "NOT_FOUND" ]]; then
  echo "Error: entry not found: $ENTRY_KEY" >&2
  exit 1
fi

# Resolve scale-below via registry
SCALE_BELOW=""
if [[ -n "$PARENT_SCALE" ]]; then
  SCALE_BELOW=$(bash "$SCRIPT_DIR/scale-registry.sh" get-adjacency "$PARENT_SCALE" 2>/dev/null | sed -n '1p' || true)
fi

# Run expand --down and filter by scale-below
python3 - "$KDIR" "$ENTRY_KEY" "$PARENT_SCALE" "$SCALE_BELOW" <<'PYEOF'
import sys
import os
import re
import json

kdir, entry_key, parent_scale, scale_below = sys.argv[1:5]

COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)


def parse_entry(path):
    try:
        with open(path, encoding='utf-8') as f:
            content = f.read()
    except OSError:
        return ('', '', '', [], [])
    title = ''
    for line in content.splitlines():
        if line.startswith('# '):
            title = line[2:].strip()
            break
    scale = status = ''
    parents = []
    inferred_parents = []
    for m in COMMENT_RE.finditer(content):
        for part in m.group(1).split('|'):
            part = part.strip()
            if ':' not in part:
                continue
            k, _, v = part.partition(':')
            k, v = k.strip(), v.strip()
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
    direct = os.path.join(kdir, key + '.md')
    if os.path.isfile(direct):
        return direct
    with_ext = os.path.join(kdir, key)
    if os.path.isfile(with_ext):
        return with_ext
    return None


def normalize_parent_ref(ref):
    ref = ref.strip()
    if not ref:
        return None
    if ref.endswith('.md'):
        ref = ref[:-3]
    if ref.startswith('knowledge:'):
        ref = ref[len('knowledge:'):]
        ref = ref.split('#')[0]
    return ref


entry_path = find_entry_path(kdir, entry_key)
if entry_path is None:
    print(f"Error: entry not found: {entry_key!r}", file=sys.stderr)
    sys.exit(1)

entry_rel = os.path.relpath(entry_path, kdir)[:-3] if entry_path.endswith('.md') else os.path.relpath(entry_path, kdir)

# Load manifest for fast lookup
manifest_path = os.path.join(kdir, '_manifest.json')
manifest_entries = []
if os.path.isfile(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        manifest_entries = manifest.get('entries', [])
    except (json.JSONDecodeError, OSError):
        pass

manifest_by_key = {}
for e in manifest_entries:
    p = e.get('path', '')
    if p.endswith('.md'):
        p = p[:-3]
    if p:
        manifest_by_key[p] = e

# Collect children
children = []
if manifest_entries:
    for me in manifest_entries:
        mpath = me.get('path', '')
        if mpath.endswith('.md'):
            mpath = mpath[:-3]
        if mpath == entry_rel:
            continue
        m_parents = [normalize_parent_ref(p) for p in me.get('parents', [])]
        m_inferred = [normalize_parent_ref(p) for p in me.get('inferred_parents', [])]
        is_explicit = entry_rel in m_parents
        is_inferred = entry_rel in m_inferred
        if is_explicit or is_inferred:
            children.append((mpath, is_inferred and not is_explicit))
else:
    skip_prefixes = ('_', '.')
    for root, dirs, files in os.walk(kdir):
        dirs[:] = [d for d in sorted(dirs) if not d.startswith(skip_prefixes)]
        for fname in sorted(files):
            if not fname.endswith('.md'):
                continue
            abs_path = os.path.join(root, fname)
            rel = os.path.relpath(abs_path, kdir)[:-3]
            if rel == entry_rel:
                continue
            _, _, _, fparents, finferred = parse_entry(abs_path)
            norm_p = [normalize_parent_ref(r) for r in fparents]
            norm_i = [normalize_parent_ref(r) for r in finferred]
            is_explicit = entry_rel in norm_p
            is_inferred_edge = entry_rel in norm_i
            if is_explicit or is_inferred_edge:
                children.append((rel, is_inferred_edge and not is_explicit))

# Deduplicate
seen = {}
for (key, is_inferred) in children:
    if key not in seen or (not is_inferred and seen[key]):
        seen[key] = is_inferred
children = sorted(seen.items())

if not children:
    print(f"{entry_rel} has no children.")
    sys.exit(0)

# Filter by scale_below when parent has a scale
filtered = []
for (ckey, is_inferred) in children:
    child_scale = ''
    if ckey in manifest_by_key:
        child_scale = manifest_by_key[ckey].get('scale', '') or ''
    else:
        cpath = find_entry_path(kdir, ckey)
        if cpath:
            _, child_scale, _, _, _ = parse_entry(cpath)

    if scale_below:
        # Parent has a scale: include only children at exactly scale_below
        if child_scale == scale_below:
            filtered.append((ckey, child_scale, is_inferred))
    else:
        # Parent has no scale: include all children, show their scale
        filtered.append((ckey, child_scale, is_inferred))

filter_note = f" (scale-below: {scale_below})" if scale_below else ""
print(f"Children of {entry_rel}{filter_note}:")

if not filtered:
    total = len(children)
    print(f"  (no children at scale '{scale_below}'; {total} total children exist at other scales)")
    sys.exit(0)

for (ckey, cscale, is_inferred) in filtered:
    scale_tag = f"  [{cscale}]" if cscale else ""
    inferred_suffix = "  (inferred)" if is_inferred else ""
    print(f"  {ckey}{scale_tag}{inferred_suffix}")
PYEOF
