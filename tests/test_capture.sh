#!/usr/bin/env bash
# test_capture.sh — Tests for capture.sh (direct-to-category knowledge capture)
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
setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"

  cat > "$KNOWLEDGE_DIR/_index.md" << 'EOF'
# Project Knowledge Index

- conventions.md — Coding conventions
EOF
}

# --- Override resolve-repo.sh to point at test directory ---
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Capture Tests ==="
echo ""

# =============================================
# Test 1: Basic happy path — insight written to correct category file
# =============================================
echo "Test 1: Basic happy path — writes to conventions.md"
setup_knowledge_store

OUTPUT=$(bash "$SCRIPT_DIR/capture.sh" --insight "Use snake_case for database column names" --category "conventions" 2>&1)
assert_contains "output confirms filing" "$OUTPUT" '[capture] Filed to conventions:'
assert_file_exists "conventions.md created" "$KNOWLEDGE_DIR/conventions.md"
assert_file_contains "insight text in file" "$KNOWLEDGE_DIR/conventions.md" "Use snake_case for database column names"
assert_file_contains "entry has ### heading" "$KNOWLEDGE_DIR/conventions.md" "### "
assert_file_contains "entry has HTML comment" "$KNOWLEDGE_DIR/conventions.md" "<!-- learned:"
assert_file_contains "HTML comment has confidence" "$KNOWLEDGE_DIR/conventions.md" "confidence: high"
assert_file_contains "HTML comment has source" "$KNOWLEDGE_DIR/conventions.md" "source: capture"

# =============================================
# Test 2: Title generation — first ~8 words, title-cased
# =============================================
echo ""
echo "Test 2: Title generation — first ~8 words, title-cased"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" --insight "the api rate limiter uses a sliding window algorithm for throttling" --category "conventions" > /dev/null 2>&1
CONTENT=$(cat "$KNOWLEDGE_DIR/conventions.md")
# First ~8 words: "the api rate limiter uses a sliding window"
# Title-cased: "The Api Rate Limiter Uses A Sliding Window"
assert_contains "title has title-cased words" "$CONTENT" "### The"
assert_contains "title contains early words" "$CONTENT" "Rate Limiter"
# The 9th word "algorithm" should not be in the title (only ~8 words)
# But the full insight should appear in the body
assert_contains "body has full insight text" "$CONTENT" "the api rate limiter uses a sliding window algorithm for throttling"

# =============================================
# Test 3: Entry format — ### Title + body + HTML comment
# =============================================
echo ""
echo "Test 3: Entry format — ### Title + body + HTML comment"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" \
  --insight "Redis cache entries expire after 1 hour by default" \
  --category "gotchas" \
  --confidence "medium" > /dev/null 2>&1

assert_file_exists "gotchas.md created" "$KNOWLEDGE_DIR/gotchas.md"
CONTENT=$(cat "$KNOWLEDGE_DIR/gotchas.md")
assert_contains "has ### heading" "$CONTENT" "### "
assert_contains "has insight body" "$CONTENT" "Redis cache entries expire after 1 hour by default"
assert_contains "has HTML comment with date" "$CONTENT" "<!-- learned:"
assert_contains "has confidence in comment" "$CONTENT" "confidence: medium"

# =============================================
# Test 4: Default category — missing --category defaults to conventions
# =============================================
echo ""
echo "Test 4: Default category — omitting --category → conventions"
setup_knowledge_store

OUTPUT=$(bash "$SCRIPT_DIR/capture.sh" --insight "Always validate user input at the boundary" 2>&1)
assert_contains "output shows conventions" "$OUTPUT" "Filed to conventions"
assert_file_exists "conventions.md exists" "$KNOWLEDGE_DIR/conventions.md"
assert_file_contains "insight in conventions file" "$KNOWLEDGE_DIR/conventions.md" "Always validate user input at the boundary"

# =============================================
# Test 5: New category file creation — non-existent category creates file with heading
# =============================================
echo ""
echo "Test 5: New category file — creates with # Heading"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" --insight "Deploy requires a VPN connection" --category "workflows" > /dev/null 2>&1
assert_file_exists "workflows.md created" "$KNOWLEDGE_DIR/workflows.md"
assert_file_contains "file starts with # heading" "$KNOWLEDGE_DIR/workflows.md" "# Workflows"
assert_file_contains "insight appended" "$KNOWLEDGE_DIR/workflows.md" "Deploy requires a VPN connection"

# =============================================
# Test 6: Hyphenated category name — heading has spaces and title case
# =============================================
echo ""
echo "Test 6: Hyphenated category name → heading with spaces"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" --insight "Use structured logging everywhere" --category "error-handling" > /dev/null 2>&1
assert_file_exists "error-handling.md created" "$KNOWLEDGE_DIR/error-handling.md"
assert_file_contains "heading is title-cased with spaces" "$KNOWLEDGE_DIR/error-handling.md" "# Error Handling"

# =============================================
# Test 7: domains/ path — --category "domains/my-topic" creates under domains/
# =============================================
echo ""
echo "Test 7: domains/ path — creates file under domains/"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" --insight "Evaluators use template-method pattern" --category "domains/evaluators" > /dev/null 2>&1
assert_file_exists "domains dir created" "$KNOWLEDGE_DIR/domains/evaluators.md"
assert_file_contains "heading is topic name" "$KNOWLEDGE_DIR/domains/evaluators.md" "# Evaluators"
assert_file_contains "insight appended" "$KNOWLEDGE_DIR/domains/evaluators.md" "Evaluators use template-method pattern"

# =============================================
# Test 8: --no-file flag — writes to _inbox/ instead
# =============================================
echo ""
echo "Test 8: --no-file flag — writes to _inbox/"
setup_knowledge_store

OUTPUT=$(bash "$SCRIPT_DIR/capture.sh" --insight "Something uncertain that needs review" --no-file 2>&1)
assert_contains "output mentions inbox" "$OUTPUT" "Inbox entry created"

# Check that an inbox file was created
INBOX_FILES=$(ls "$KNOWLEDGE_DIR/_inbox/"*.md 2>/dev/null | wc -l | tr -d ' ')
if [[ "$INBOX_FILES" -ge 1 ]]; then
  echo "  PASS: inbox file created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: no inbox file found"
  FAIL=$((FAIL + 1))
fi

# Check inbox file content
INBOX_FILE=$(ls "$KNOWLEDGE_DIR/_inbox/"*.md 2>/dev/null | head -1)
if [[ -n "$INBOX_FILE" ]]; then
  assert_file_contains "inbox has insight" "$INBOX_FILE" "Something uncertain that needs review"
  assert_file_contains "inbox has suggested category" "$INBOX_FILE" "Suggested category:"
  assert_file_contains "inbox has confidence" "$INBOX_FILE" "Confidence:"
fi

# Verify it did NOT write to a category file
assert_file_not_contains "conventions.md untouched" "$KNOWLEDGE_DIR/conventions.md" "Something uncertain" 2>/dev/null || true

# =============================================
# Test 9: --no-file uses default category in inbox entry
# =============================================
echo ""
echo "Test 9: --no-file with --category sets suggested category in inbox"
setup_knowledge_store

bash "$SCRIPT_DIR/capture.sh" --insight "Consider using connection pooling" --no-file --category "architecture" > /dev/null 2>&1
INBOX_FILE=$(ls -t "$KNOWLEDGE_DIR/_inbox/"*.md 2>/dev/null | head -1)
if [[ -n "$INBOX_FILE" ]]; then
  assert_file_contains "inbox has architecture category" "$INBOX_FILE" "architecture"
else
  echo "  FAIL: no inbox file found"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 10: Missing --insight flag produces error
# =============================================
echo ""
echo "Test 10: Missing --insight flag → error"
setup_knowledge_store

OUTPUT=$(bash "$SCRIPT_DIR/capture.sh" --category "conventions" 2>&1 || true)
assert_contains "error about missing insight" "$OUTPUT" "--insight is required"

# =============================================
# Test 11: Appending to existing category file
# =============================================
echo ""
echo "Test 11: Appending to existing category file"
setup_knowledge_store

# Create an existing conventions.md with content
cat > "$KNOWLEDGE_DIR/conventions.md" << 'EOF'
# Conventions

### Existing Entry
Some existing content.
EOF

bash "$SCRIPT_DIR/capture.sh" --insight "New naming convention for tests" --category "conventions" > /dev/null 2>&1
assert_file_contains "original content preserved" "$KNOWLEDGE_DIR/conventions.md" "Existing Entry"
assert_file_contains "new insight appended" "$KNOWLEDGE_DIR/conventions.md" "New naming convention for tests"

# =============================================
# Test 12: No knowledge store → error
# =============================================
echo ""
echo "Test 12: No knowledge store → error"
rm -rf "$KNOWLEDGE_DIR"
mkdir -p "$KNOWLEDGE_DIR"
# Don't create _index.md

OUTPUT=$(bash "$SCRIPT_DIR/capture.sh" --insight "This should fail" 2>&1 || true)
assert_contains "error about missing knowledge store" "$OUTPUT" "No knowledge store found"

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
