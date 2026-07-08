#!/usr/bin/env bash
# find-correction-targets.sh — Map a contradicted claim to candidate commons entries
#
# Usage:
#   find-correction-targets.sh --claim-text "<text>" [--file-line "<file:line_range>"] \
#                              [--limit N] [--threshold F] [--json]
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
# Output modes:
#   default (text): one path per line, ranked
#     <entry_path>  [overlap=yes|no]  [sim=0.NNNN]
#     Special line "No matching entries found" when results is empty.
#   --json: a single parseable JSON object on stdout:
#     {
#       "targets": [{"path": <abs path>, "rank": 1, "overlap": <bool>, "sim": <float>}, ...],
#       "index_state": "ready" | "stale" | "missing",
#       "resolver_version": "<short-sha-or-v1>"
#     }
#
# index_state trichotomy (per D4):
#   missing  — the FTS concordance DB ($KDIR/.pk_search.db) does not exist.
#   ready    — the DB exists and the query succeeded.
#   stale    — RESERVED for a future hook (e.g. mtime-based freshness predicate). This
#              script never emits "stale" today; the trichotomy is documented so
#              downstream consumers (settlement filter, propagation reconcile backstop)
#              can encode the three-way decision now and the producer can flip to
#              "stale" without a consumer migration. Adding the stale predicate is
#              explicitly out of scope for this PR.
#
# resolver_version:
#   When invoked from inside a git working tree, the value is `git rev-parse --short HEAD`
#   (the commit of the script's own checkout — used as the resolver identity for
#   audit-trail purposes). If git is unavailable or the script is not in a git tree,
#   the literal string "v1" is emitted. Document any future schema bump by incrementing
#   the v-prefix fallback rather than overloading the sha.
#
# Exit codes:
#   0 — success
#       * In text mode: 0 or more results printed (or "No matching entries found").
#       * In --json mode: ALWAYS exit 0 on a successful query — JSON consumers need a
#         parseable response, not exit-code branching. Empty targets + index_state="ready"
#         is a valid, well-formed answer ("no candidates"); index_state="missing" is the
#         analogous well-formed answer for a not-yet-built index.
#   1 — usage error (bad/missing flags) — applies to both modes
#   2 — knowledge store or concordance index missing (TEXT MODE ONLY; --json folds
#       the missing-index condition into index_state="missing" with exit 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CLAIM_TEXT=""
FILE_LINE=""
LIMIT=10
THRESHOLD=0.4
JSON_MODE=0
KDIR_OVERRIDE=""

usage() {
  cat >&2 <<EOF
Usage: find-correction-targets.sh --claim-text "<text>" [--file-line "<file:line_range>"] [--limit N] [--threshold F] [--json]

Map a contradicted claim to candidate knowledge entry paths.

Options:
  --claim-text TEXT     The text of the contradicted claim (required)
  --file-line FILE:LINE The file:line_range anchor from the verdict (optional)
  --limit N             Maximum results to return (default: 10)
  --threshold F         Minimum TF-IDF cosine similarity (default: 0.4)
  --kdir PATH           Override the knowledge directory (default: lore resolve)
  --json                Emit a single JSON object on stdout (see header for schema)
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
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
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

# Resolve resolver_version: short-sha of the script's commit, or "v1" fallback.
RESOLVER_VERSION="v1"
if RESOLVER_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null); then
  if [[ -n "$RESOLVER_SHA" ]]; then
    RESOLVER_VERSION="$RESOLVER_SHA"
  fi
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -f "$KDIR/_manifest.json" ]]; then
  if [[ "$JSON_MODE" -eq 1 ]]; then
    # Treat missing knowledge store like missing index for JSON consumers — they
    # cannot do anything with an exit-2 either way; "missing" is the right signal.
    python3 -c 'import json,sys; json.dump({"targets":[],"index_state":"missing","resolver_version":sys.argv[1]}, sys.stdout)' "$RESOLVER_VERSION"
    echo
    exit 0
  fi
  echo "Error: knowledge store not found at: $KDIR" >&2
  exit 2
fi

DB_PATH="$KDIR/.pk_search.db"
if [[ ! -f "$DB_PATH" ]]; then
  if [[ "$JSON_MODE" -eq 1 ]]; then
    python3 -c 'import json,sys; json.dump({"targets":[],"index_state":"missing","resolver_version":sys.argv[1]}, sys.stdout)' "$RESOLVER_VERSION"
    echo
    exit 0
  fi
  echo "Error: concordance index not found — run 'lore rebuild' to build it" >&2
  exit 2
fi

python3 - "$KDIR" "$DB_PATH" "$CLAIM_TEXT" "$FILE_LINE" "$LIMIT" "$THRESHOLD" "$SCRIPT_DIR" "$JSON_MODE" "$RESOLVER_VERSION" <<'PYEOF'
import sys
import os
import re
import json

kdir = sys.argv[1]
db_path = sys.argv[2]
claim_text = sys.argv[3]
file_line = sys.argv[4]   # may be empty
limit = int(sys.argv[5])
threshold = float(sys.argv[6])
script_dir = sys.argv[7]
json_mode = sys.argv[8] == "1"
resolver_version = sys.argv[9]

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

if json_mode:
    # JSON projection — emit `{targets, index_state, resolver_version}` per D4.
    # Successful queries always return index_state="ready"; the "stale" branch
    # is reserved for a future freshness predicate (see header comment).
    payload = {
        'targets': [
            {
                'path': r['path'],
                'rank': i + 1,
                'overlap': bool(r['overlap']),
                'sim': float(r['sim']),
            }
            for i, r in enumerate(results)
        ],
        'index_state': 'ready',
        'resolver_version': resolver_version,
    }
    json.dump(payload, sys.stdout)
    sys.stdout.write('\n')
    sys.exit(0)

# Text mode (unchanged, byte-compatible with the pre-D4 contract).
if not results:
    print("No matching entries found")
    sys.exit(0)

for r in results:
    overlap_tag = '[overlap=yes]' if r['overlap'] else '[overlap=no]'
    print(f"{r['path']}  {overlap_tag}  [sim={r['sim']:.4f}]")

PYEOF
