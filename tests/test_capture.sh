#!/usr/bin/env bash
# test_capture.sh — Tests for capture.sh (one entry file per capture, filed under its category)
# Creates a temporary knowledge store and tests capture.sh against it.

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

assert_file_exists() {
  local label="$1" filepath="$2"
  if [[ -f "$filepath" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File does not exist: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_contains() {
  local label="$1" filepath="$2" expected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$expected" "$filepath"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    if [[ ! -f "$filepath" ]]; then
      echo "    File does not exist: $filepath"
    else
      echo "    Expected file to contain: $expected"
      echo "    File contents: $(head -10 "$filepath")"
    fi
    FAIL=$((FAIL + 1))
  fi
}

assert_file_not_contains() {
  local label="$1" filepath="$2" unexpected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$unexpected" "$filepath"; then
    echo "  FAIL: $label"
    echo "    File should NOT contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# --- Setup test knowledge store ---
# capture.sh treats a directory with _manifest.json as an initialized store.
setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
}

# Every capture declares its scale; the provenance pair keeps the warning off stderr.
capture() {
  bash "$SCRIPT_DIR/capture.sh" --producer-role worker --protocol-slot test "$@"
}

# --- Override resolve-repo.sh to point at test directory ---
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Capture Tests ==="
echo ""

# =============================================
# Test 1: Basic happy path — insight written to its own file under the category
# =============================================
echo "Test 1: Basic happy path — writes conventions/<slug>.md"
setup_knowledge_store

OUTPUT=$(capture --insight "Use snake_case for database column names" --category "conventions" --scale implementation 2>&1)
ENTRY="$KNOWLEDGE_DIR/conventions/use-snake-case-database-column-names.md"
assert_contains "output confirms filing" "$OUTPUT" '[capture] Filed to conventions/use-snake-case-database-column-names.md'
assert_file_exists "entry file created" "$ENTRY"
assert_file_contains "insight text in file" "$ENTRY" "Use snake_case for database column names"
assert_file_contains "entry has an H1 title" "$ENTRY" "# Use Snake_case For Database Column Names"
assert_file_contains "entry has metadata comment" "$ENTRY" "<!-- learned:"
assert_file_contains "metadata has confidence" "$ENTRY" "confidence: high"
assert_file_contains "metadata has source" "$ENTRY" "source: manual"
assert_file_contains "metadata has scale" "$ENTRY" "scale: implementation"
assert_file_contains "metadata has kind" "$ENTRY" "kind: fact"
assert_file_contains "metadata has status" "$ENTRY" "status: current -->"
assert_file_not_contains "no activity field outside preferences" "$ENTRY" "activity:"
assert_not_contains "no preference block outside preferences" "$OUTPUT" "Preferences for"

# =============================================
# Test 2: Title generation — first eight words, title-cased
# =============================================
echo ""
echo "Test 2: Title generation — first eight words, title-cased"
setup_knowledge_store

capture --insight "the api rate limiter uses a sliding window algorithm for throttling" --category "conventions" --scale implementation > /dev/null 2>&1
ENTRY=$(ls "$KNOWLEDGE_DIR/conventions/"*.md | head -1)
CONTENT=$(cat "$ENTRY")
assert_contains "title is the first eight words, title-cased" "$CONTENT" "# The Api Rate Limiter Uses A Sliding Window"
assert_not_contains "the ninth word is not in the title" "$(head -1 "$ENTRY")" "Algorithm"
assert_contains "body has full insight text" "$CONTENT" "the api rate limiter uses a sliding window algorithm for throttling"

# =============================================
# Test 3: --title, --confidence and a different category
# =============================================
echo ""
echo "Test 3: --title, --confidence and the gotchas category"
setup_knowledge_store

capture \
  --insight "Redis cache entries expire after 1 hour by default" \
  --title "Redis cache entries expire after an hour" \
  --category "gotchas" \
  --confidence "medium" \
  --scale subsystem > /dev/null 2>&1

ENTRY="$KNOWLEDGE_DIR/gotchas/redis-cache-entries-expire-hour.md"
assert_file_exists "gotchas entry created" "$ENTRY"
assert_file_contains "H1 is the given title" "$ENTRY" "# Redis cache entries expire after an hour"
assert_file_contains "has insight body" "$ENTRY" "Redis cache entries expire after 1 hour by default"
assert_file_contains "has confidence in comment" "$ENTRY" "confidence: medium"

# =============================================
# Test 4: Default category — missing --category defaults to conventions
# =============================================
echo ""
echo "Test 4: Default category — omitting --category → conventions"
setup_knowledge_store

OUTPUT=$(capture --insight "Always validate user input at the boundary" --scale implementation 2>&1)
assert_contains "output shows conventions" "$OUTPUT" "Filed to conventions/"
assert_file_contains "insight in a conventions entry" "$KNOWLEDGE_DIR/conventions/always-validate-user-input-at-boundary.md" \
  "Always validate user input at the boundary"

# =============================================
# Test 5: Nested category — domains/<topic> creates the directory
# =============================================
echo ""
echo "Test 5: Nested category — domains/evaluators"
setup_knowledge_store

capture --insight "Evaluators use template-method pattern" --category "domains/evaluators" --scale subsystem > /dev/null 2>&1
ENTRY="$KNOWLEDGE_DIR/domains/evaluators/evaluators-use-template-method-pattern.md"
assert_file_exists "entry created under domains/evaluators/" "$ENTRY"
assert_file_contains "insight written" "$ENTRY" "Evaluators use template-method pattern"

# =============================================
# Test 6: Two-label scale is written in top-to-bottom order
# =============================================
echo ""
echo "Test 6: Two adjacent scale labels are normalized"
setup_knowledge_store

capture --insight "Scale pairs are ordered" --category conventions --scale "implementation,subsystem" > /dev/null 2>&1
assert_file_contains "pair written top-to-bottom" "$KNOWLEDGE_DIR/conventions/scale-pairs-are-ordered.md" "scale: subsystem,implementation"

# =============================================
# Test 7: Missing --insight and missing --scale produce errors
# =============================================
echo ""
echo "Test 7: Missing --insight or --scale → error"
setup_knowledge_store

OUTPUT=$(capture --category "conventions" --scale implementation 2>&1 || true)
assert_contains "error about missing insight" "$OUTPUT" "--insight is required"
OUTPUT=$(capture --insight "No scale given" --category "conventions" 2>&1 || true)
assert_contains "error about missing scale" "$OUTPUT" "--scale is required"
if [[ -d "$KNOWLEDGE_DIR/conventions" ]]; then
  echo "  FAIL: nothing should be filed without --insight or --scale"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: nothing filed without --insight or --scale"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 8: Unknown flags are refused with the usage line
# =============================================
echo ""
echo "Test 8: Unknown flag → usage"
setup_knowledge_store

OUTPUT=$(capture --insight "x" --scale implementation --no-file 2>&1 || true)
assert_contains "unknown argument named" "$OUTPUT" "Unknown argument: --no-file"
assert_contains "usage line printed" "$OUTPUT" "Usage: capture.sh --insight"

# =============================================
# Test 9: No knowledge store → error
# =============================================
echo ""
echo "Test 9: No knowledge store → error"
rm -rf "$KNOWLEDGE_DIR"
mkdir -p "$KNOWLEDGE_DIR"
# No _manifest.json

OUTPUT=$(capture --insight "This should fail" --scale implementation 2>&1 || true)
assert_contains "error about missing knowledge store" "$OUTPUT" "No knowledge store found"

# =============================================
# Test 10: Slug length cap — dedup collision keeps stems within MAX_SLUG_LENGTH
# =============================================
echo ""
echo "Test 10: Slug length cap — dedup keeps stems ≤ 50 chars"
setup_knowledge_store

LONG_INSIGHT="authentication authorization infrastructure configuration implementation deployment environment management"

# First capture — creates the base slug file
capture --insight "$LONG_INSIGHT" --category "conventions" --scale implementation > /dev/null 2>&1

# Second capture — triggers dedup, should trim slug before appending suffix
capture --insight "$LONG_INSIGHT" --category "conventions" --scale implementation > /dev/null 2>&1

# Assert all file stems in the conventions dir are ≤ 50 chars
ALL_WITHIN_LIMIT=1
for f in "$KNOWLEDGE_DIR/conventions/"*.md; do
  [[ -f "$f" ]] || continue
  stem=$(basename "$f" .md)
  if [[ ${#stem} -gt 50 ]]; then
    echo "  FAIL: stem exceeds 50 chars: '$stem' (${#stem} chars)"
    ALL_WITHIN_LIMIT=0
    FAIL=$((FAIL + 1))
  fi
done

if [[ $ALL_WITHIN_LIMIT -eq 1 ]]; then
  echo "  PASS: all file stems ≤ 50 chars"
  PASS=$((PASS + 1))
fi

# Also verify that two files were actually created (dedup worked)
FILE_COUNT=$(ls "$KNOWLEDGE_DIR/conventions/"*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$FILE_COUNT" -ge 2 ]]; then
  echo "  PASS: dedup created $FILE_COUNT files"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected ≥ 2 files, got $FILE_COUNT"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 11: --json prints one object naming the filed entry
# =============================================
echo ""
echo "Test 11: --json output"
setup_knowledge_store

OUTPUT=$(capture --insight "JSON output names the entry" --category conventions --scale implementation --json 2>/dev/null)
PARSED=$(printf '%s' "$OUTPUT" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d["path"], d["category"])')
assert_contains "JSON names path and category" "$PARSED" "conventions/json-output-names-entry.md conventions"

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
