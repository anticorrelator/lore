#!/usr/bin/env bash
# expand-entry.sh — Walk one hop up or down the parent/child edge for an entry
#
# Usage:
#   expand-entry.sh <entry-id> [--up | --down]
#
# entry-id: category/slug (e.g. principles/scale-determined-by-role)
#   Trailing .md is optional.
#
# --up   (default) Show the entry's parents (explicit and inferred).
# --down Show the entry's children (entries that declare this as parent).
#
# Each result line shows: entry-path  [scale | status]  (inferred) when applicable.
#
# Exit codes:
#   0 — success
#   1 — usage error or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: expand-entry.sh <entry-id> [--up | --down]

Walk one hop along parent/child edges for a knowledge entry.

entry-id: category/slug (e.g. principles/scale-determined-by-role)
          Trailing .md is optional.

Options:
  --up     (default) Show the entry's parents (explicit and inferred).
  --down   Show entries that list this entry as a parent (children).

Each line shows: entry-path  [scale | status]  (inferred) when edge is inferred.
EOF
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ENTRY_ARG="$1"
DIRECTION="up"

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --up)
      DIRECTION="up"
      shift
      ;;
    --down)
      DIRECTION="down"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      echo "" >&2
      usage
      exit 1
      ;;
  esac
done

KDIR=$(resolve_knowledge_dir)

# Normalize: strip leading KDIR prefix and trailing .md
ENTRY_KEY="${ENTRY_ARG#"$KDIR/"}"
ENTRY_KEY="${ENTRY_KEY%.md}"

python3 - "$KDIR" "$ENTRY_KEY" "$DIRECTION" <<'PYEOF'
import sys
import os
import re
import json

kdir = sys.argv[1]
entry_key = sys.argv[2]
direction = sys.argv[3]  # "up" or "down"

COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)


def parse_entry(path):
    """Return (title, scale, status, parents, inferred_parents) from an entry .md file."""
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

    scale = ''
    status = ''
    parents = []
    inferred_parents = []

    for m in COMMENT_RE.finditer(content):
        block = m.group(1)
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
    direct = os.path.join(kdir, key + '.md')
    if os.path.isfile(direct):
        return direct
    with_ext = os.path.join(kdir, key)
    if os.path.isfile(with_ext):
        return with_ext
    return None


def normalize_parent_ref(ref):
    """Normalize a parent reference to a relative key (category/slug)."""
    ref = ref.strip()
    if not ref:
        return None
    if ref.endswith('.md'):
        ref = ref[:-3]
    if ref.startswith('knowledge:'):
        ref = ref[len('knowledge:'):]
        ref = ref.split('#')[0]
    return ref


def format_annotation(scale, status):
    parts = []
    if scale:
        parts.append(scale)
    if status:
        parts.append(status)
    return '  [' + ' | '.join(parts) + ']' if parts else ''


# Verify the target entry exists
entry_path = find_entry_path(kdir, entry_key)
if entry_path is None:
    print(f"Error: entry not found: {entry_key!r}", file=sys.stderr)
    sys.exit(1)

entry_rel = os.path.relpath(entry_path, kdir)
if entry_rel.endswith('.md'):
    entry_rel = entry_rel[:-3]

# ---- Load manifest for fast edge lookup ----
manifest_path = os.path.join(kdir, '_manifest.json')
manifest_entries = []
if os.path.isfile(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        manifest_entries = manifest.get('entries', [])
    except (json.JSONDecodeError, OSError):
        pass

# Build lookup: path (no .md) -> manifest entry
manifest_by_key = {}
for e in manifest_entries:
    p = e.get('path', '')
    if p.endswith('.md'):
        p = p[:-3]
    if p:
        manifest_by_key[p] = e


if direction == 'up':
    # Show parents of this entry
    _, _, _, parents, inferred_parents = parse_entry(entry_path)

    all_parents = []
    seen = set()
    for ref in parents:
        key = normalize_parent_ref(ref)
        if key and key not in seen:
            seen.add(key)
            all_parents.append((key, False))
    for ref in inferred_parents:
        key = normalize_parent_ref(ref)
        if key and key not in seen:
            seen.add(key)
            all_parents.append((key, True))

    if not all_parents:
        print(f"{entry_rel} has no parents.")
        sys.exit(0)

    print(f"Parents of {entry_rel}:")
    for (pkey, is_inferred) in all_parents:
        # Get scale/status from manifest or file
        scale = ''
        status = ''
        if pkey in manifest_by_key:
            me = manifest_by_key[pkey]
        else:
            # Try reading file directly
            ppath = find_entry_path(kdir, pkey)
            me = None
            if ppath:
                _, scale, status, _, _ = parse_entry(ppath)
        if me is not None:
            scale = me.get('scale', '') or ''
            status = me.get('status', '') or ''
        annotation = format_annotation(scale, status)
        inferred_suffix = '  (inferred)' if is_inferred else ''
        print(f"  {pkey}{annotation}{inferred_suffix}")

else:
    # direction == 'down': find children
    # Children are entries that list entry_rel as a parent or inferred_parent
    # Use manifest first for fast lookup, fall back to file scan
    children = []  # list of (key, is_inferred)

    # Fast path: scan manifest entries for parent references
    manifest_checked = False
    if manifest_entries:
        manifest_checked = True
        for me in manifest_entries:
            mpath = me.get('path', '')
            if mpath.endswith('.md'):
                mpath = mpath[:-3]
            if mpath == entry_rel:
                continue  # skip self

            m_parents = [normalize_parent_ref(p) for p in me.get('parents', [])]
            m_inferred = [normalize_parent_ref(p) for p in me.get('inferred_parents', [])]

            is_explicit = entry_rel in m_parents
            is_inferred = entry_rel in m_inferred

            if is_explicit or is_inferred:
                # Prefer explicit over inferred if both
                children.append((mpath, is_inferred and not is_explicit))

    if not manifest_checked:
        # Fallback: walk all .md files
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

    if not children:
        print(f"{entry_rel} has no children.")
        sys.exit(0)

    # Deduplicate (in case both manifest and fallback ran)
    seen = {}
    for (key, is_inferred) in children:
        if key not in seen or (not is_inferred and seen[key]):
            seen[key] = is_inferred
    children = sorted(seen.items())

    print(f"Children of {entry_rel}:")
    for (ckey, is_inferred) in children:
        scale = ''
        status = ''
        if ckey in manifest_by_key:
            me = manifest_by_key[ckey]
            scale = me.get('scale', '') or ''
            status = me.get('status', '') or ''
        else:
            cpath = find_entry_path(kdir, ckey)
            if cpath:
                _, scale, status, _, _ = parse_entry(cpath)
        annotation = format_annotation(scale, status)
        inferred_suffix = '  (inferred)' if is_inferred else ''
        print(f"  {ckey}{annotation}{inferred_suffix}")

PYEOF
