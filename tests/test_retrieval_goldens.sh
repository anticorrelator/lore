#!/usr/bin/env bash
# test_retrieval_goldens.sh — Golden-output regression tests for every
# consumer-visible retrieval surface:
#   - lore search (--json, human, missing --scale-set error)
#   - lore query (--format json, --format prompt, --budget)
#   - prefetch-knowledge.sh (--format prompt, --format summary,
#     --exclude-backlinks, --work-item scope pointers)
#   - pk_cli.py search --budget (load-knowledge's scale-blind channel)
#   - load-knowledge.sh (=== Project Knowledge === block)
#   - resolve-manifest.sh (v2 sectioned + legacy flat)
#   - retrieval-log.jsonl row shapes (sorted key sets per event kind)
#
# Each surface runs against the deterministic store from
# tests/fixtures/retrieval/build_store.sh; output is normalized (volatile
# scores, timings, dates masked) and diffed against
# tests/fixtures/retrieval/goldens/<name>.golden.
#
# Documented delta from the pre-consolidation pipelines (2026-06): prefetch
# no longer re-filters Searcher's results by scale. Searcher.search is the
# single scale authority, and its bypass rules (category=preferences,
# scale=abstract) now hold at the prefetch surface too — abstract-scale
# entries that Searcher returns appear in prefetch output instead of being
# silently re-suppressed by a duplicated post-filter. The prefetch goldens
# pin the post-consolidation behavior.
#
# Two further documented deltas (2026-06):
#   - Invalid flag VALUES now fail loudly: argparse rejects bad --format/
#     --type/--limit values with exit 2 + usage, where the old bash adapters
#     swallowed them into empty output + exit 0. Unusable-STORE conditions
#     (missing knowledge dir, broken index) remain fail-open on every
#     surface: empty results, exit 0.
#   - load-knowledge direct-resolved dedupe now runs before the budget
#     partition (--exclude-paths), so under budget pressure entries the old
#     flow demoted to titles_only (their budget burned by skipped
#     duplicates) are promoted into the full tier.
#
# Usage:
#   bash tests/test_retrieval_goldens.sh            # compare against goldens
#   bash tests/test_retrieval_goldens.sh --update   # rewrite goldens

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
CLI="$REPO_ROOT/cli/lore"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/retrieval"
GOLDEN_DIR="$FIXTURE_DIR/goldens"

UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
export LORE_KNOWLEDGE_DIR="$KDIR"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

bash "$FIXTURE_DIR/build_store.sh" "$KDIR"

# Run all surfaces from a stable non-git cwd so the load-knowledge context
# signal comes from the fixture work item, not the developer's branch.
cd "$TEST_DIR"

# `lore` must be resolvable for resolve-manifest's legacy path.
SHIM_DIR="$TEST_DIR/bin"
mkdir -p "$SHIM_DIR"
ln -s "$CLI" "$SHIM_DIR/lore"
export PATH="$SHIM_DIR:$PATH"

# Normalize volatile values: BM25/composite scores drift with recency and
# index internals; timings and timestamps drift always. Formats and content
# are what these goldens pin.
NORMALIZER="$TEST_DIR/normalize.py"
cat > "$NORMALIZER" <<'PY'
import re, sys

text = sys.stdin.read()
# JSON numeric score/timing fields
text = re.sub(r'("(?:score|composite_score|tfidf_score|importance_score|bm25|recency|tfidf|importance|similarity|elapsed_ms|structural_importance)":\s*)-?[0-9.]+', r'\1"<NUM>"', text)
# Human-readable score renderings
text = re.sub(r'\(score: -?[0-9.]+\)', '(score: <NUM>)', text)
text = re.sub(r'score: -?[0-9.]+', 'score: <NUM>', text)
text = re.sub(r'sim: -?[0-9.]+', 'sim: <NUM>', text)
# Timestamps
text = re.sub(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{4})?', '<TS>', text)
sys.stdout.write(text)
PY

normalize() {
  python3 "$NORMALIZER"
}

check_golden() {
  local name="$1"
  local content="$2"
  local golden_file="$GOLDEN_DIR/$name.golden"
  if [[ $UPDATE -eq 1 ]]; then
    mkdir -p "$GOLDEN_DIR"
    printf '%s\n' "$content" > "$golden_file"
    echo "  UPDATED: $name"
    return
  fi
  if [[ ! -f "$golden_file" ]]; then
    echo "  FAIL: $name (golden missing: $golden_file — run with --update)"
    FAIL=$((FAIL + 1))
    return
  fi
  if diff -u "$golden_file" <(printf '%s\n' "$content") > "$TEST_DIR/diff_$name" 2>&1; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (output drifted from golden)"
    sed -n '1,40p' "$TEST_DIR/diff_$name" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Retrieval Golden Tests ==="

# Pre-build the index once so per-surface runs don't interleave indexing output.
python3 "$SCRIPTS_DIR/pk_cli.py" index "$KDIR" > /dev/null 2>&1

# Truncate the retrieval log: the shape golden below covers exactly the events
# emitted by the surfaces in this file.
: > "$KDIR/_meta/retrieval-log.jsonl"

# --- lore search ---
OUT=$("$CLI" search "widget pipeline" --scale-set subsystem --json 2>&1 | normalize)
check_golden "search_json" "$OUT"

OUT=$("$CLI" search "widget pipeline" --scale-set subsystem 2>&1 | normalize)
check_golden "search_human" "$OUT"

OUT=$("$CLI" search "widget pipeline" 2>&1)
EC=$?
check_golden "search_missing_scale" "exit=$EC
$OUT"

# --- lore query ---
OUT=$("$CLI" query --seeds "widget pipeline" --scale-set subsystem,implementation --format json 2>&1 | normalize)
check_golden "query_json" "$OUT"

OUT=$("$CLI" query --seeds "widget pipeline" --scale-set subsystem,implementation --format prompt 2>&1 | normalize)
check_golden "query_prompt" "$OUT"

OUT=$("$CLI" query --seeds "widget pipeline" --scale-set subsystem,implementation --budget 600 --format json 2>&1 | normalize)
check_golden "query_budget_json" "$OUT"

OUT=$("$CLI" query --seeds "widget pipeline" --format json 2>&1)
EC=$?
check_golden "query_missing_scale" "exit=$EC
$OUT"

# --- prefetch-knowledge.sh ---
OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "widget pipeline" --scale-set subsystem --format prompt 2>&1 | normalize)
check_golden "prefetch_prompt" "$OUT"

OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "widget pipeline" --scale-set subsystem,implementation --format summary 2>&1 | normalize)
check_golden "prefetch_summary" "$OUT"

OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "widget pipeline" --scale-set subsystem --format prompt \
      --exclude-backlinks "knowledge:conventions/widget-naming" 2>&1 | normalize)
check_golden "prefetch_exclude_backlinks" "$OUT"

OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "widget pipeline" --scale-set subsystem --format prompt \
      --work-item fixture-item 2>&1 | normalize)
check_golden "prefetch_work_item" "$OUT"

OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "widget pipeline" 2>&1)
EC=$?
check_golden "prefetch_missing_scale" "exit=$EC
$OUT"

# --- pk_cli search --budget (scale-blind budgeted channel) ---
OUT=$(python3 "$SCRIPTS_DIR/pk_cli.py" search "$KDIR" "widget pipeline" --type knowledge \
      --limit 20 --budget 700 --exclude-category domains 2>&1 | normalize)
check_golden "pk_budget_json" "$OUT"

# --- load-knowledge.sh (scale-blind by design: no declaration required) ---
OUT=$(bash "$SCRIPTS_DIR/load-knowledge.sh" 2>&1 | normalize)
check_golden "load_knowledge" "$OUT"

# --- resolve-manifest.sh ---
OUT=$(bash "$SCRIPTS_DIR/resolve-manifest.sh" fixture-item 1 2>&1 | normalize)
check_golden "manifest_v2" "$OUT"

OUT=$(bash "$SCRIPTS_DIR/resolve-manifest.sh" fixture-item 2 2>&1 | normalize)
check_golden "manifest_legacy" "$OUT"

# --- retrieval-log row shapes ---
OUT=$(python3 - "$KDIR/_meta/retrieval-log.jsonl" <<'PY'
import json, sys

shapes = []
seen = set()
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        kind = row.get("event", "unknown")
        # manifest_load rows: include nested section/call key shapes
        keys = ",".join(sorted(row.keys()))
        extra = ""
        if row.get("sections"):
            extra += " sections[" + ",".join(sorted(row["sections"][0].keys())) + "]"
        if row.get("calls"):
            extra += " calls[" + ",".join(sorted(row["calls"][0].keys())) + "]"
        shape = f"{kind}: {keys}{extra}"
        if shape not in seen:
            seen.add(shape)
            shapes.append(shape)
for s in sorted(shapes):
    print(s)
PY
)
check_golden "retrieval_log_shapes" "$OUT"

echo ""
if [[ $UPDATE -eq 1 ]]; then
  echo "Goldens updated in $GOLDEN_DIR"
  exit 0
fi
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
