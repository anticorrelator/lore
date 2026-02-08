#!/usr/bin/env bash
# test_enriched_signal.sh — Tests for enriched context signal extraction
# Tests: stopword filtering, backlink extraction, multi-source signal construction
# Covers: extract_backlinks(), _extract_work_item_backlinks(),
#          _extract_work_item_signal(), extract_context_signal(), FTS5 query builder

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Should NOT contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Got: $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_line_count() {
  local label="$1" output="$2" expected="$3"
  local actual
  if [[ -z "$output" ]]; then
    actual=0
  else
    actual=$(echo "$output" | wc -l | tr -d '[:space:]')
  fi
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected $expected lines, got $actual"
    echo "    Content: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

source "$SCRIPT_DIR/lib.sh"

echo "=== Enriched Signal Tests ==="
echo ""

# =============================================
# Test 1: extract_backlinks — basic extraction
# =============================================
echo "Test 1: extract_backlinks basic extraction"
BACKLINKS_FILE="$TEST_DIR/backlinks_test.md"
cat > "$BACKLINKS_FILE" << 'EOF'
# Notes
Working on skill composition.
See [[knowledge:conventions/skills/skill-composition]] for reference.
Also related: [[knowledge:architecture/startup-loading]]
Some text without links.
EOF

OUTPUT=$(extract_backlinks "$BACKLINKS_FILE")
assert_contains "finds conventions backlink" "$OUTPUT" "conventions/skills/skill-composition"
assert_contains "finds architecture backlink" "$OUTPUT" "architecture/startup-loading"
assert_line_count "exactly 2 backlinks" "$OUTPUT" "2"

# =============================================
# Test 2: extract_backlinks — deduplication
# =============================================
echo ""
echo "Test 2: extract_backlinks deduplication"
DEDUP_FILE="$TEST_DIR/dedup_test.md"
cat > "$DEDUP_FILE" << 'EOF'
See [[knowledge:conventions/naming]] and later [[knowledge:conventions/naming]] again.
Also [[knowledge:gotchas/timeout]].
EOF

OUTPUT=$(extract_backlinks "$DEDUP_FILE")
assert_line_count "deduplicates to 2 unique" "$OUTPUT" "2"
assert_contains "has naming" "$OUTPUT" "conventions/naming"
assert_contains "has timeout" "$OUTPUT" "gotchas/timeout"

# =============================================
# Test 3: extract_backlinks — no backlinks
# =============================================
echo ""
echo "Test 3: extract_backlinks with no backlinks"
NO_LINKS_FILE="$TEST_DIR/no_links.md"
cat > "$NO_LINKS_FILE" << 'EOF'
# Notes
Just plain text, no knowledge links here.
Some [[other:syntax]] that is not knowledge.
EOF

OUTPUT=$(extract_backlinks "$NO_LINKS_FILE")
assert_equals "empty output for no backlinks" "$OUTPUT" ""

# =============================================
# Test 4: extract_backlinks — non-existent file
# =============================================
echo ""
echo "Test 4: extract_backlinks with non-existent file"
OUTPUT=$(extract_backlinks "$TEST_DIR/does_not_exist.md")
assert_equals "empty output for missing file" "$OUTPUT" ""

# =============================================
# Test 5: _extract_work_item_backlinks — combines notes.md and plan.md
# =============================================
echo ""
echo "Test 5: _extract_work_item_backlinks combines and deduplicates"
WORK_ITEM="$TEST_DIR/work-item/"
mkdir -p "$WORK_ITEM"

cat > "${WORK_ITEM}notes.md" << 'EOF'
See [[knowledge:conventions/naming]] and [[knowledge:gotchas/shell-quoting]].
EOF

cat > "${WORK_ITEM}plan.md" << 'EOF'
### Phase 1
Use [[knowledge:conventions/naming]] pattern.
### Phase 2
Handle [[knowledge:gotchas/fts5-limits]].
EOF

OUTPUT=$(_extract_work_item_backlinks "$WORK_ITEM")
assert_line_count "3 unique backlinks from both files" "$OUTPUT" "3"
assert_contains "has naming (shared)" "$OUTPUT" "conventions/naming"
assert_contains "has shell-quoting (notes only)" "$OUTPUT" "gotchas/shell-quoting"
assert_contains "has fts5-limits (plan only)" "$OUTPUT" "gotchas/fts5-limits"

# =============================================
# Test 6: _extract_work_item_backlinks — no notes or plan
# =============================================
echo ""
echo "Test 6: _extract_work_item_backlinks with no files"
EMPTY_WORK="$TEST_DIR/empty-work/"
mkdir -p "$EMPTY_WORK"

OUTPUT=$(_extract_work_item_backlinks "$EMPTY_WORK")
assert_equals "empty when no notes or plan" "$OUTPUT" ""

# =============================================
# Test 7: _extract_work_item_signal — multi-source construction
# =============================================
echo ""
echo "Test 7: _extract_work_item_signal multi-source"
SIGNAL_WORK="$TEST_DIR/signal-work/"
mkdir -p "$SIGNAL_WORK"

cat > "${SIGNAL_WORK}_meta.json" << 'EOF'
{
  "title": "Implement relevance-based loading",
  "status": "active",
  "tags": ["knowledge-store", "retrieval", "fts5"]
}
EOF

cat > "${SIGNAL_WORK}plan.md" << 'EOF'
# Plan
### Phase 1: Signal enrichment
### Phase 2: Budget search
### Phase 3: Integration
EOF

cat > "${SIGNAL_WORK}notes.md" << 'EOF'
# Notes
The current loader uses priority-order which misses relevant entries.
We need context-aware ranking for better startup loading.
EOF

ITEM_OUTPUT=$(_extract_work_item_signal "$SIGNAL_WORK")
OUTPUT=$(echo "$ITEM_OUTPUT" | head -1)
ITEM_SOURCES=$(echo "$ITEM_OUTPUT" | sed '1,/^---ITEM_SOURCES---$/d')
assert_contains "signal has title" "$OUTPUT" "Implement relevance-based loading"
assert_contains "signal has tags" "$OUTPUT" "knowledge store"
assert_contains "signal has plan heading" "$OUTPUT" "Phase 1: Signal enrichment"
assert_contains "signal has notes text" "$OUTPUT" "context-aware ranking"
assert_contains "sources has title" "$ITEM_SOURCES" "title"
assert_contains "sources has tags" "$ITEM_SOURCES" "tags"
assert_contains "sources has plan_headings" "$ITEM_SOURCES" "plan_headings"
assert_contains "sources has notes" "$ITEM_SOURCES" "notes"

# =============================================
# Test 8: _extract_work_item_signal — title only (no tags, plan, or notes)
# =============================================
echo ""
echo "Test 8: _extract_work_item_signal title only"
MINIMAL_WORK="$TEST_DIR/minimal-work/"
mkdir -p "$MINIMAL_WORK"

cat > "${MINIMAL_WORK}_meta.json" << 'EOF'
{
  "title": "Fix authentication bug",
  "status": "active"
}
EOF

ITEM_OUTPUT=$(_extract_work_item_signal "$MINIMAL_WORK")
OUTPUT=$(echo "$ITEM_OUTPUT" | head -1)
ITEM_SOURCES=$(echo "$ITEM_OUTPUT" | sed '1,/^---ITEM_SOURCES---$/d')
assert_contains "signal has title" "$OUTPUT" "Fix authentication bug"
assert_contains "sources has title" "$ITEM_SOURCES" "title"
assert_not_contains "no tags source" "$ITEM_SOURCES" "tags"
assert_not_contains "no plan_headings source" "$ITEM_SOURCES" "plan_headings"
assert_not_contains "no notes source" "$ITEM_SOURCES" "notes"

# =============================================
# Test 9: extract_context_signal — structured output format
# =============================================
echo ""
echo "Test 9: extract_context_signal structured output"
KDIR="$TEST_DIR/kdir-structured"
mkdir -p "$KDIR/_work/test-item"

cat > "$KDIR/_work/test-item/_meta.json" << 'EOF'
{
  "title": "Test structured output",
  "status": "active"
}
EOF

cat > "$KDIR/_work/test-item/notes.md" << 'EOF'
See [[knowledge:conventions/naming]] for patterns.
EOF

FULL_OUTPUT=$(extract_context_signal "$KDIR")
SIGNAL=$(echo "$FULL_OUTPUT" | head -1)
DELIMITER=$(echo "$FULL_OUTPUT" | sed -n '2p')
BACKLINKS=$(echo "$FULL_OUTPUT" | sed -n '/^---BACKLINKS---$/,/^---SIGNAL_SOURCES---$/{ /^---/d; p; }')
SOURCES=$(echo "$FULL_OUTPUT" | sed '1,/^---SIGNAL_SOURCES---$/d')

assert_contains "signal contains title" "$SIGNAL" "Test structured output"
assert_equals "delimiter is correct" "$DELIMITER" "---BACKLINKS---"
assert_contains "backlinks has naming" "$BACKLINKS" "conventions/naming"
assert_contains "sources has title" "$SOURCES" "title"

# =============================================
# Test 10: extract_context_signal — no backlinks still has delimiter
# =============================================
echo ""
echo "Test 10: extract_context_signal with no backlinks"
KDIR2="$TEST_DIR/kdir-no-links"
mkdir -p "$KDIR2/_work/no-links"

cat > "$KDIR2/_work/no-links/_meta.json" << 'EOF'
{
  "title": "No links here",
  "status": "active"
}
EOF

FULL_OUTPUT=$(extract_context_signal "$KDIR2")
SIGNAL=$(echo "$FULL_OUTPUT" | head -1)
DELIMITER=$(echo "$FULL_OUTPUT" | sed -n '2p')
BACKLINKS=$(echo "$FULL_OUTPUT" | sed -n '/^---BACKLINKS---$/,/^---SIGNAL_SOURCES---$/{ /^---/d; p; }')
SOURCES=$(echo "$FULL_OUTPUT" | sed '1,/^---SIGNAL_SOURCES---$/d')

assert_contains "signal has title" "$SIGNAL" "No links here"
assert_equals "delimiter present" "$DELIMITER" "---BACKLINKS---"
assert_equals "backlinks empty" "$BACKLINKS" ""
assert_contains "sources has title" "$SOURCES" "title"
assert_not_contains "no backlinks source" "$SOURCES" "backlinks"

# =============================================
# Test 11: Stopword filtering in FTS5 query builder
# =============================================
echo ""
echo "Test 11: Stopword filtering"

# The FTS5 query builder is inline Python in load-knowledge.sh.
# We extract and test the same logic directly.
FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {
    'and', 'or', 'not', 'near',
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "the quick brown fox is in a big box with 3 items")

assert_contains "keeps content words" "$FTS5_QUERY" '"quick"'
assert_contains "keeps brown" "$FTS5_QUERY" '"brown"'
assert_contains "keeps fox" "$FTS5_QUERY" '"fox"'
assert_contains "keeps big" "$FTS5_QUERY" '"big"'
assert_contains "keeps box" "$FTS5_QUERY" '"box"'
assert_contains "keeps items" "$FTS5_QUERY" '"items"'
assert_not_contains "filters 'the'" "$FTS5_QUERY" '"the"'
assert_not_contains "filters 'is'" "$FTS5_QUERY" '"is"'
assert_not_contains "filters 'in'" "$FTS5_QUERY" '"in"'
assert_not_contains "filters 'a'" "$FTS5_QUERY" '"a"'
assert_not_contains "filters 'with'" "$FTS5_QUERY" '"with"'

# =============================================
# Test 12: Stopword filtering — FTS5 operators removed
# =============================================
echo ""
echo "Test 12: FTS5 operators filtered"
FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {
    'and', 'or', 'not', 'near',
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "search and not near or filter")

assert_contains "keeps search" "$FTS5_QUERY" '"search"'
assert_contains "keeps filter" "$FTS5_QUERY" '"filter"'
assert_not_contains "filters AND operator" "$FTS5_QUERY" '"and"'
assert_not_contains "filters NOT operator" "$FTS5_QUERY" '"not"'
assert_not_contains "filters NEAR operator" "$FTS5_QUERY" '"near"'
assert_not_contains "filters OR operator" "$FTS5_QUERY" '"or"'

# =============================================
# Test 13: Stopword filtering — single chars and digits removed
# =============================================
echo ""
echo "Test 13: Single chars and digits filtered"
FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {
    'and', 'or', 'not', 'near',
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "x 42 100 feature-v2 abc")

assert_contains "keeps feature" "$FTS5_QUERY" '"feature"'
assert_contains "keeps v2" "$FTS5_QUERY" '"v2"'
assert_contains "keeps abc" "$FTS5_QUERY" '"abc"'
assert_not_contains "filters single char x" "$FTS5_QUERY" '"x"'
assert_not_contains "filters digit 42" "$FTS5_QUERY" '"42"'
assert_not_contains "filters digit 100" "$FTS5_QUERY" '"100"'

# =============================================
# Test 14: Stopword filtering — no term cap (more than 8 terms pass through)
# =============================================
echo ""
echo "Test 14: No term cap (previously was 8)"
FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {
    'and', 'or', 'not', 'near',
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima")

# Count OR-separated terms (should be 12, not capped at 8)
TERM_COUNT=$(echo "$FTS5_QUERY" | grep -o ' OR ' | wc -l | tr -d '[:space:]')
TERM_COUNT=$((TERM_COUNT + 1))  # N terms have N-1 ORs
assert_equals "all 12 terms present (no cap)" "$TERM_COUNT" "12"

# =============================================
# Test 15: Stopword filtering — deduplication
# =============================================
echo ""
echo "Test 15: Stopword filtering deduplication"
FTS5_QUERY=$(python3 -c "
import re, sys
signal = sys.argv[1]
words = re.sub(r'[-_/]', ' ', signal).lower().split()
stop = {
    'and', 'or', 'not', 'near',
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'shall',
    'should', 'may', 'might', 'must', 'can', 'could',
    'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
    'into', 'through', 'during', 'before', 'after', 'above', 'below',
    'between', 'under', 'about', 'than',
    'this', 'that', 'these', 'those', 'it', 'its',
    'i', 'me', 'my', 'we', 'our', 'you', 'your', 'he', 'his', 'she',
    'her', 'they', 'them', 'their', 'who', 'which', 'what', 'when',
    'where', 'how', 'why',
    'if', 'then', 'else', 'so', 'but', 'because', 'while', 'although',
    'no', 'yes', 'up', 'out', 'just', 'also', 'very', 'only', 'more',
    'most', 'other', 'some', 'any', 'all', 'each', 'every', 'both',
    'few', 'many', 'much', 'such', 'own', 'same', 'too', 'here',
    'there', 'now', 'well', 'way', 'even', 'new', 'one', 'two',
}
seen, terms = set(), []
for w in words:
    if len(w) <= 1 or w in stop or w.isdigit():
        continue
    if w not in seen:
        seen.add(w)
        terms.append('\"' + w + '\"')
print(' OR '.join(terms))
" "search search search filter filter unique")

TERM_COUNT=$(echo "$FTS5_QUERY" | grep -o ' OR ' | wc -l | tr -d '[:space:]')
TERM_COUNT=$((TERM_COUNT + 1))
assert_equals "deduplicates to 3 terms" "$TERM_COUNT" "3"
assert_contains "has search once" "$FTS5_QUERY" '"search"'
assert_contains "has filter once" "$FTS5_QUERY" '"filter"'
assert_contains "has unique once" "$FTS5_QUERY" '"unique"'

# =============================================
# Test 16: extract_backlinks — multiple links on one line
# =============================================
echo ""
echo "Test 16: extract_backlinks multiple links per line"
MULTI_FILE="$TEST_DIR/multi_per_line.md"
cat > "$MULTI_FILE" << 'EOF'
See [[knowledge:conventions/naming]] and [[knowledge:gotchas/timeout]] on same line.
EOF

OUTPUT=$(extract_backlinks "$MULTI_FILE")
assert_line_count "2 links from one line" "$OUTPUT" "2"
assert_contains "first link" "$OUTPUT" "conventions/naming"
assert_contains "second link" "$OUTPUT" "gotchas/timeout"

# =============================================
# Test 17: extract_backlinks — ignores non-knowledge wiki links
# =============================================
echo ""
echo "Test 17: extract_backlinks ignores non-knowledge links"
MIXED_FILE="$TEST_DIR/mixed_links.md"
cat > "$MIXED_FILE" << 'EOF'
See [[knowledge:conventions/naming]] for patterns.
Also [[work:auth-refactor]] and [[plan:deployment]].
And [[other:something]].
EOF

OUTPUT=$(extract_backlinks "$MIXED_FILE")
assert_line_count "only 1 knowledge link" "$OUTPUT" "1"
assert_contains "has knowledge link" "$OUTPUT" "conventions/naming"
assert_not_contains "no work link" "$OUTPUT" "auth-refactor"
assert_not_contains "no plan link" "$OUTPUT" "deployment"

# =============================================
# Test 18: _extract_work_item_signal — notes.md text truncated to ~500 chars
# =============================================
echo ""
echo "Test 18: notes.md text truncation"
LONG_WORK="$TEST_DIR/long-notes-work/"
mkdir -p "$LONG_WORK"

cat > "${LONG_WORK}_meta.json" << 'EOF'
{
  "title": "Long notes test",
  "status": "active"
}
EOF

# Generate notes.md with >500 chars of content (after heading/blank stripping)
{
  echo "# Long Notes"
  echo ""
  for i in $(seq 1 15); do
    echo "This is line number $i of the notes file with enough text to reach the limit soon."
  done
} > "${LONG_WORK}notes.md"

ITEM_OUTPUT=$(_extract_work_item_signal "$LONG_WORK")
OUTPUT=$(echo "$ITEM_OUTPUT" | head -1)
SIGNAL_LEN=${#OUTPUT}
# Title (~15) + notes text (~500) should be well under 800
# If notes were unbounded it would be >1200
if [[ $SIGNAL_LEN -lt 800 ]]; then
  echo "  PASS: notes text truncated (signal length: $SIGNAL_LEN)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: notes text not truncated (signal length: $SIGNAL_LEN, expected < 800)"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
