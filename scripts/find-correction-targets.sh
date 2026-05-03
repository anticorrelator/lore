#!/usr/bin/env bash
# find-correction-targets.sh — Map a contradicted claim to candidate commons entries
#
# Usage:
#   find-correction-targets.sh --claim-text "<text>" [--file-line "<file:line_range>"] [--limit N] [--threshold F]
#
# Given the text of a contradicted claim (from a correctness-gate or reverse-auditor
# verdict) and optionally the file:line_range anchor from the verdict, returns a ranked
# list of knowledge entry paths that likely contain the claim.
#
# Mapping heuristic (two-pass, OR-combined):
#   1. related_files overlap: entry's related_files mentions the same file (basename or
#      full path) as the verdict's claim_anchor file.
#   2. TF-IDF similarity >= threshold (default 0.4) between claim_text and entry body.
#   Entries matching either pass are ranked by overlap + similarity descending.
#
# Output (one path per line, ranked):
#   <entry_path> [overlap=yes] [sim=0.NNNN]
#
# Exit codes:
#   0 — success (0 or more results)
#   1 — usage error
#   2 — knowledge store not found or concordance index missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLAIM_TEXT=""
FILE_LINE=""
LIMIT=10
THRESHOLD=0.4

usage() {
  cat >&2 <<EOF
Usage: find-correction-targets.sh --claim-text "<text>" [--file-line "<file:line_range>"] [--limit N] [--threshold F]

Map a contradicted claim to candidate knowledge entry paths.

Options:
  --claim-text TEXT     The text of the contradicted claim (required)
  --file-line FILE:LINE The file:line_range anchor from the verdict (optional)
  --limit N             Maximum results to return (default: 10)
  --threshold F         Minimum TF-IDF cosine similarity (default: 0.4)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --claim-text)
      CLAIM_TEXT="$2"
      shift 2
      ;;
    --file-line)
      FILE_LINE="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$CLAIM_TEXT" ]]; then
  echo "Error: --claim-text is required" >&2
  usage
  exit 1
fi

KDIR=$(resolve_knowledge_dir)

if [[ ! -f "$KDIR/_manifest.json" ]]; then
  echo "Error: knowledge store not found at: $KDIR" >&2
  exit 2
fi

DB_PATH="$KDIR/.pk_search.db"
if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: concordance index not found — run 'lore rebuild' to build it" >&2
  exit 2
fi

python3 - "$KDIR" "$DB_PATH" "$CLAIM_TEXT" "$FILE_LINE" "$LIMIT" "$THRESHOLD" "$SCRIPT_DIR" <<'PYEOF'
import sys
import os
import re

kdir = sys.argv[1]
db_path = sys.argv[2]
claim_text = sys.argv[3]
file_line = sys.argv[4]   # may be empty
limit = int(sys.argv[5])
threshold = float(sys.argv[6])
script_dir = sys.argv[7]

sys.path.insert(0, script_dir)

from pk_concordance import Concordance, sparse_cosine_similarity

COMMENT_RE = re.compile(r'<!--(.*?)-->', re.DOTALL)
RELATED_FILES_RE = re.compile(r'\|\s*related_files:\s*(?P<val>[^|>]+)', re.IGNORECASE)


def extract_meta_field(text, pattern):
    for m in COMMENT_RE.finditer(text):
        block = m.group(1)
        fm = pattern.search(block)
        if fm:
            return fm.group('val').strip()
    return ''


def get_related_files(entry_path):
    try:
        text = open(entry_path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError):
        return []
    raw = extract_meta_field(text, RELATED_FILES_RE)
    if not raw:
        return []
    return [f.strip() for f in raw.split(',') if f.strip()]


def basenames(paths):
    return {os.path.basename(p) for p in paths}


# Parse the anchor file from file_line (e.g., "scripts/foo.sh:10-20" -> "scripts/foo.sh")
anchor_file = ''
anchor_basename = ''
if file_line:
    anchor_file = file_line.split(':')[0] if ':' in file_line else file_line
    anchor_basename = os.path.basename(anchor_file)

concordance = Concordance(db_path)

# Build TF-IDF vector for the claim text
claim_vec = concordance.build_query_vector(claim_text)

# Get all knowledge entry vectors
all_vecs = concordance.get_all_vectors(source_type='knowledge')

results = []

for entry in all_vecs:
    fp = entry['file_path']
    if not os.path.isabs(fp):
        fp = os.path.join(kdir, fp)
    if not os.path.isfile(fp):
        continue

    # Skip entries outside the knowledge store (e.g., source files)
    rel = os.path.relpath(fp, kdir)
    if rel.startswith('_'):
        continue

    # Pass 1: related_files overlap with anchor file
    overlap = False
    if anchor_file:
        related = get_related_files(fp)
        related_bases = basenames(related)
        if anchor_basename and anchor_basename in related_bases:
            overlap = True
        elif anchor_file in related:
            overlap = True

    # Pass 2: TF-IDF similarity
    sim = 0.0
    if claim_vec and entry.get('vector'):
        sim = sparse_cosine_similarity(claim_vec, entry['vector'])

    if not overlap and sim < threshold:
        continue

    rel_key = rel[:-3] if rel.endswith('.md') else rel
    results.append({
        'path': fp,
        'key': rel_key,
        'overlap': overlap,
        'sim': round(sim, 4),
    })

# Sort: overlap=True first, then by sim descending
results.sort(key=lambda x: (-int(x['overlap']), -x['sim']))
results = results[:limit]

if not results:
    print("No matching entries found")
    sys.exit(0)

for r in results:
    overlap_tag = '[overlap=yes]' if r['overlap'] else '[overlap=no]'
    print(f"{r['path']}  {overlap_tag}  [sim={r['sim']:.4f}]")

PYEOF
