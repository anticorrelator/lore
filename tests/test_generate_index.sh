#!/usr/bin/env bash
# test_generate_index.sh — Tests for scripts/generate-index.sh (behind `lore index`)
#
# Covers:
#   - Entries filed in category SUBDIRECTORIES are counted and listed. The
#     previous non-recursive `$cat_dir/*.md` glob saw only the handful of
#     entries at each category root.
#   - The category list is a display ORDER, not a closed set: `preferences` and
#     `design-rationale` (both omitted by the old hardcoded array) render, and a
#     category directory nobody named still renders.
#   - Store-internal `_`-prefixed and dotted directories are never treated as
#     categories.
#   - Title / summary / parent-edge extraction survives the batched awk pass:
#     H1 title, filename fallback, 120-char summary truncation, `See also:` and
#     comment lines skipped, explicit and inferred parent edges.
#   - --category filters to one category.
#
# Style: plain bash asserts, mirroring tests/test_load_knowledge_v2.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
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

# --- Fixture: a store shaped like the real one (entries in subdirectories) ---
setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"/{conventions/scripting,conventions/skills,principles,preferences,design-rationale,_inbox,.git}

  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"

  cat > "$KNOWLEDGE_DIR/conventions/root-level-entry.md" << 'EOF'
# Root Level Entry

An entry that sits at the category root.
EOF

  for i in 1 2 3; do
    cat > "$KNOWLEDGE_DIR/conventions/scripting/nested-scripting-$i.md" << EOF
# Nested Scripting Entry $i

Nested scripting entry $i summary line.
EOF
  done

  cat > "$KNOWLEDGE_DIR/conventions/skills/nested-skill-entry.md" << 'EOF'
# Nested Skill Entry

Nested skill entry summary line.
EOF

  cat > "$KNOWLEDGE_DIR/principles/simplicity.md" << 'EOF'
# Simplicity

Prefer simple solutions.
EOF

  # Categories the old hardcoded CATEGORIES array omitted entirely.
  cat > "$KNOWLEDGE_DIR/preferences/tone.md" << 'EOF'
# Tone Preference

Plain prose over ceremony.
EOF

  cat > "$KNOWLEDGE_DIR/design-rationale/why-substrates.md" << 'EOF'
# Why Substrates

One sanctioned writer per substrate.
EOF

  # Store-internal directories — must never be read as categories.
  echo "not an entry" > "$KNOWLEDGE_DIR/_inbox/pending.md"
  echo "not an entry" > "$KNOWLEDGE_DIR/.git/config.md"
}

run_index() {
  LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" bash "$SCRIPT_DIR/generate-index.sh" "$KNOWLEDGE_DIR" 2>&1
}

echo "=== generate-index.sh tests ==="

setup_store
OUTPUT=$(run_index)

# =============================================
# Test 1: Recursive counting
# =============================================
echo ""
echo "Test 1: Entries in subdirectories are counted"
# conventions/: 1 at the root + 3 scripting + 1 skills = 5
assert_contains "conventions counted recursively" "$OUTPUT" "## conventions (5 entries)"
assert_not_contains "conventions not counted depth-1" "$OUTPUT" "## conventions (1 entries)"

# =============================================
# Test 2: Nested entries are listed, not just counted
# =============================================
echo ""
echo "Test 2: Nested entries appear in the listing"
assert_contains "nested scripting entry listed" "$OUTPUT" "**Nested Scripting Entry 1**"
assert_contains "nested skill entry listed" "$OUTPUT" "**Nested Skill Entry**"
assert_contains "root entry still listed" "$OUTPUT" "**Root Level Entry**"
assert_contains "summary rendered" "$OUTPUT" "Nested scripting entry 1 summary line."

# =============================================
# Test 3: Categories the old hardcoded list dropped
# =============================================
echo ""
echo "Test 3: preferences and design-rationale render"
assert_contains "preferences rendered" "$OUTPUT" "## preferences (1 entries)"
assert_contains "design-rationale rendered" "$OUTPUT" "## design-rationale (1 entries)"

# =============================================
# Test 4: Internal directories are not categories
# =============================================
echo ""
echo "Test 4: Store-internal directories are skipped"
assert_not_contains "_inbox not a category" "$OUTPUT" "## _inbox"
assert_not_contains "dotted dir not a category" "$OUTPUT" "## .git"

# =============================================
# Test 5: An unnamed category directory is still discovered
# =============================================
echo ""
echo "Test 5: Category outside the display order is discovered"
mkdir -p "$KNOWLEDGE_DIR/experiments"
cat > "$KNOWLEDGE_DIR/experiments/probe.md" << 'EOF'
# Probe Entry

An entry in a category nobody hardcoded.
EOF
OUTPUT_DISCOVER=$(run_index)
assert_contains "unnamed category rendered" "$OUTPUT_DISCOVER" "## experiments (1 entries)"
assert_contains "unnamed category entry listed" "$OUTPUT_DISCOVER" "**Probe Entry**"
rm -rf "$KNOWLEDGE_DIR/experiments"

# =============================================
# Test 6: Title / summary extraction edge cases
# =============================================
echo ""
echo "Test 6: Title and summary extraction"
# No H1 -> filename stem is the title. Line 1 is always consumed as the
# heading slot, so the summary comes from line 2 onward either way.
cat > "$KNOWLEDGE_DIR/principles/no-heading-entry.md" << 'EOF'
Not a heading line.

Second line is the summary.
EOF
# Summary skips blank lines, HTML comments, and "See also:".
cat > "$KNOWLEDGE_DIR/principles/skips-noise.md" << 'EOF'
# Skips Noise

<!-- learned: 2026-01-01 | confidence: high -->
See also: something
The real summary line.
EOF
# A >120 character summary is truncated to 117 chars plus an ellipsis.
LONG_LINE=$(printf 'x%.0s' $(seq 1 200))
cat > "$KNOWLEDGE_DIR/principles/long-summary.md" << EOF
# Long Summary

$LONG_LINE
EOF
OUTPUT_EXTRACT=$(run_index)
assert_contains "filename fallback title" "$OUTPUT_EXTRACT" "**no-heading-entry** — Second line is the summary."
assert_contains "summary skips comment and See also" "$OUTPUT_EXTRACT" "**Skips Noise** — The real summary line."
assert_contains "long summary truncated" "$OUTPUT_EXTRACT" "$(printf 'x%.0s' $(seq 1 117))..."
assert_not_contains "long summary not rendered whole" "$OUTPUT_EXTRACT" "$(printf 'x%.0s' $(seq 1 121))"
rm -f "$KNOWLEDGE_DIR/principles/no-heading-entry.md" \
      "$KNOWLEDGE_DIR/principles/skips-noise.md" \
      "$KNOWLEDGE_DIR/principles/long-summary.md"

# =============================================
# Test 7: Parent edges still render from the batched pass
# =============================================
echo ""
echo "Test 7: Explicit and inferred parent edges"
cat > "$KNOWLEDGE_DIR/principles/has-parents.md" << 'EOF'
# Has Parents

An entry carrying parent edges.
<!-- learned: 2026-01-01 | confidence: high | parents: framing-v1 | inferred_parents: framing-v2, framing-v3 -->
EOF
OUTPUT_PARENTS=$(run_index)
assert_contains "explicit parents rendered" "$OUTPUT_PARENTS" "Parents (explicit): framing-v1"
assert_contains "inferred parents rendered" "$OUTPUT_PARENTS" "Parents (inferred): framing-v2, framing-v3"
rm -f "$KNOWLEDGE_DIR/principles/has-parents.md"

# =============================================
# Test 8: --category filter
# =============================================
echo ""
echo "Test 8: --category filters output"
OUTPUT_FILTERED=$(LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" \
  bash "$SCRIPT_DIR/generate-index.sh" "$KNOWLEDGE_DIR" --category conventions 2>&1)
assert_contains "filtered category present" "$OUTPUT_FILTERED" "## conventions (5 entries)"
assert_not_contains "other category absent" "$OUTPUT_FILTERED" "## principles"

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
