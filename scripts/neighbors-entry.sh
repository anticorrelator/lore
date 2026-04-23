#!/usr/bin/env bash
# neighbors-entry.sh — Find same-scale entries with high concordance similarity
#
# Usage:
#   neighbors-entry.sh <entry-id> [--limit N]
#
# entry-id: category/slug (e.g. gotchas/some-gotcha)
#   Trailing .md is optional.
#
# --limit N   Max results (default: 5)
#
# Output: Ranked list of same-scale sibling entries by TF-IDF cosine similarity.
#
# Exit codes:
#   0 — success
#   1 — usage error or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: neighbors-entry.sh <entry-id> [--limit N]

Find same-scale entries with high concordance similarity to the given entry.

entry-id: category/slug (e.g. gotchas/some-gotcha)
          Trailing .md is optional.

Options:
  --limit N   Maximum results to return (default: 5)
EOF
}

if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ENTRY_ARG="$1"
LIMIT=5
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)
      LIMIT="$2"
      shift 2
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

python3 - "$KDIR" "$ENTRY_KEY" "$LIMIT" "$SCRIPT_DIR" <<'PYEOF'
import sys
import os
import re

kdir = sys.argv[1]
entry_key = sys.argv[2]
limit = int(sys.argv[3])
script_dir = sys.argv[4]

sys.path.insert(0, script_dir)

COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)
SCALE_RE = re.compile(r'\|\s*scale:\s*(?P<scale>[^\s|>]+)', re.IGNORECASE)
STATUS_RE = re.compile(r'\|\s*status:\s*(?P<status>[^\s|>]+)', re.IGNORECASE)


def parse_entry_meta(path):
    """Return (title, scale, status) from a knowledge entry file."""
    try:
        text = open(path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return ('', '', '')
    title = ''
    for line in text.splitlines():
        if line.startswith('# '):
            title = line[2:].strip()
            break
    scale = ''
    status = ''
    for m in COMMENT_RE.finditer(text):
        block = m.group(1)
        sm = SCALE_RE.search(block)
        if sm:
            scale = sm.group('scale').strip().lower()
        stm = STATUS_RE.search(block)
        if stm:
            status = stm.group('status').strip().lower()
    return (title, scale, status)


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
    print(f"Error: entry not found: {entry_key!r}", file=sys.stderr)
    sys.exit(1)

entry_title, entry_scale, entry_status = parse_entry_meta(entry_path)

db_path = os.path.join(kdir, '.pk_search.db')
if not os.path.isfile(db_path):
    print("No concordance index found — run `lore rebuild` to build it.", file=sys.stderr)
    sys.exit(1)

try:
    from pk_concordance import Concordance
except ImportError:
    print("Error: pk_concordance not found", file=sys.stderr)
    sys.exit(1)

concordance = Concordance(db_path)

# Get the heading for this entry (first heading in the vectors table, or title)
all_vecs = concordance.get_all_vectors(source_type='knowledge')
abs_entry = os.path.abspath(entry_path)
entry_heading = ''
for v in all_vecs:
    # file_path in DB may be abs or relative — handle both
    fp = v['file_path']
    if not os.path.isabs(fp):
        fp = os.path.join(kdir, fp)
    if os.path.abspath(fp) == abs_entry:
        entry_heading = v['heading']
        break

if not entry_heading:
    entry_heading = entry_title  # fallback

similar = concordance.find_similar(
    file_path=abs_entry,
    heading=entry_heading,
    limit=limit * 3,  # fetch extra to filter by scale
    source_type_filter='knowledge',
)

if not similar:
    print(f"No concordance neighbors found for: {entry_key}")
    sys.exit(0)

# Filter to same-scale entries (or 'unknown' scale if entry itself is unknown)
neighbors = []
for s in similar:
    fp = s['file_path']
    if not os.path.isabs(fp):
        fp = os.path.join(kdir, fp)
    rel = os.path.relpath(fp, kdir)
    if rel.endswith('.md'):
        rel = rel[:-3]
    neighbor_title, neighbor_scale, neighbor_status = parse_entry_meta(fp)
    # Same-scale filter: if entry_scale is unknown, include all; else require match
    if entry_scale and entry_scale != 'unknown' and neighbor_scale and neighbor_scale != 'unknown':
        if neighbor_scale != entry_scale:
            continue
    neighbors.append({
        'key': rel,
        'title': neighbor_title,
        'scale': neighbor_scale,
        'status': neighbor_status,
        'similarity': s['similarity'],
    })
    if len(neighbors) >= limit:
        break

if not neighbors:
    print(f"No same-scale concordance neighbors for: {entry_key} (scale: {entry_scale or 'unknown'})")
    sys.exit(0)

own_scale_label = entry_scale or 'unknown'
print(f"Neighbors of {entry_key} (scale: {own_scale_label}):")
for n in neighbors:
    scale_tag = f"[{n['scale']}]" if n['scale'] else "[unknown]"
    status_tag = f" {n['status']}" if n['status'] else ""
    score = f"{n['similarity']:.4f}"
    print(f"  {n['key']}  {scale_tag}{status_tag}  sim={score}")
    if n['title']:
        print(f"    {n['title']}")

PYEOF
