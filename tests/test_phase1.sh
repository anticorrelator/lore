#!/usr/bin/env bash
# test_phase1.sh — Integration tests for Phase 1 bash script improvements
# Creates a temporary knowledge store and tests scripts against it.

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
  if echo "$output" | grep -qF "$expected"; then
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
  if echo "$output" | grep -qF "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Should NOT contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# --- Setup test knowledge store ---
setup_knowledge_store() {
  mkdir -p "$KNOWLEDGE_DIR/domains"

  cat > "$KNOWLEDGE_DIR/_index.md" << 'EOF'
# Project Knowledge Index

- conventions.md — Coding conventions
- gotchas.md — Known pitfalls
- workflows.md — Development workflows
EOF

  cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{
  "files": {
    "conventions.md": {"keywords": ["naming", "imports", "style"]},
    "gotchas.md": {"keywords": ["timeout", "cache", "race condition"]}
  }
}
EOF

  cat > "$KNOWLEDGE_DIR/conventions.md" << 'EOF'
# Conventions

### Naming Patterns
We use camelCase for variables and PascalCase for classes.
This is enforced by the linter.

### Import Order
Always import stdlib first, then third-party, then local.
Keep imports sorted alphabetically.

### Error Handling
Use custom error classes for domain errors.
Never catch generic exceptions.
EOF

  cat > "$KNOWLEDGE_DIR/gotchas.md" << 'EOF'
# Gotchas

### Timeout Bug
The HTTP client has a default timeout of 30s.
Override it explicitly for long-running requests.

### Cache Invalidation
Redis cache entries expire after 1 hour by default.
Set TTL explicitly for each key type.
**Confidence:** low
EOF

  cat > "$KNOWLEDGE_DIR/workflows.md" << 'EOF'
# Workflows

### Deploy Process
Run the deploy script with --dry-run first.
Then run it again without the flag.
EOF

  cat > "$KNOWLEDGE_DIR/_inbox.md" << 'EOF'
# Inbox

## [2025-01-15T10:00:00]
- **Insight:** The API uses rate limiting of 100 req/min
- **Confidence:** high
EOF
}

setup_knowledge_store

# We need to create a wrapper that overrides resolve-repo.sh for testing
WRAPPER_SCRIPT="$TEST_DIR/test-resolve-repo.sh"
cat > "$WRAPPER_SCRIPT" << WEOF
#!/usr/bin/env bash
echo "$KNOWLEDGE_DIR"
WEOF
chmod +x "$WRAPPER_SCRIPT"

# Temporarily replace resolve-repo.sh for testing
ORIG_RESOLVE="$SCRIPT_DIR/resolve-repo.sh"
cp "$ORIG_RESOLVE" "$TEST_DIR/resolve-repo.sh.bak"
cp "$WRAPPER_SCRIPT" "$ORIG_RESOLVE"

restore_resolve() {
  cp "$TEST_DIR/resolve-repo.sh.bak" "$ORIG_RESOLVE"
  # Restore load-knowledge.sh if it was modified
  if [[ -f "$TEST_DIR/load-knowledge.sh.bak" ]]; then
    cp "$TEST_DIR/load-knowledge.sh.bak" "$SCRIPT_DIR/load-knowledge.sh"
  fi
  cleanup
}
trap restore_resolve EXIT

echo "=== Phase 1 Tests ==="
echo ""

# =============================================
# Test 1: search-knowledge.sh normal mode
# =============================================
echo "Test 1: search-knowledge.sh normal mode"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" "camelCase" "$TEST_DIR" 2>&1)
assert_contains "normal search finds matches" "$OUTPUT" "conventions.md"
assert_contains "normal search shows line content" "$OUTPUT" "camelCase"
assert_contains "normal search shows ranked results" "$OUTPUT" "Ranked results (FTS5)"

# =============================================
# Test 2: search-knowledge.sh --concise mode
# =============================================
echo ""
echo "Test 2: search-knowledge.sh --concise mode"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" --concise "camelCase" "$TEST_DIR" 2>&1)
assert_contains "concise search shows file path" "$OUTPUT" "conventions.md"
assert_contains "concise search shows heading" "$OUTPUT" "### Naming Patterns"
assert_not_contains "concise search hides content lines" "$OUTPUT" "1:We use"
assert_not_contains "concise search hides manifest" "$OUTPUT" "Manifest matches"

# =============================================
# Test 3: search-knowledge.sh --concise no results
# =============================================
echo ""
echo "Test 3: search-knowledge.sh --concise no results"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" --concise "zzzznonexistent" "$TEST_DIR" 2>&1)
assert_contains "concise no match reports no matches" "$OUTPUT" "no matches"

# =============================================
# Test 4: search-knowledge.sh normal no results
# =============================================
echo ""
echo "Test 4: search-knowledge.sh normal mode no results"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" "zzzznonexistent" "$TEST_DIR" 2>&1)
assert_contains "normal no match" "$OUTPUT" "No results"
assert_contains "normal no FTS match" "$OUTPUT" "Ranked results (FTS5)"

# =============================================
# Test 5: load-knowledge.sh loads content + budget report
# =============================================
echo ""
echo "Test 5: load-knowledge.sh basic loading + budget"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "loads index" "$OUTPUT" "Project Knowledge Index"
assert_contains "loads conventions" "$OUTPUT" "conventions.md"
assert_contains "budget report present" "$OUTPUT" "[Budget]"
assert_contains "budget report has full count" "$OUTPUT" "full,"
assert_contains "budget report has summary count" "$OUTPUT" "summary,"
assert_contains "budget report has skipped count" "$OUTPUT" "skipped"

# =============================================
# Test 6: load-knowledge.sh heading+first-sentence summary mode
# =============================================
echo ""
echo "Test 6: load-knowledge.sh summary mode (small budget)"

# Temporarily set a tiny budget to force summary mode
# Modify the actual script in-place and restore after
ORIG_LOAD="$SCRIPT_DIR/load-knowledge.sh"
cp "$ORIG_LOAD" "$TEST_DIR/load-knowledge.sh.bak"
sed -i.tmp 's/^BUDGET=8000$/BUDGET=200/' "$ORIG_LOAD"

OUTPUT=$(bash "$ORIG_LOAD" 2>&1)

# Restore original
cp "$TEST_DIR/load-knowledge.sh.bak" "$ORIG_LOAD"
assert_contains "summary mode label" "$OUTPUT" "summary, read full file on-demand"
assert_contains "summary shows heading" "$OUTPUT" "### Naming Patterns"
# First sentence extraction: "We use camelCase for variables and PascalCase for classes."
assert_contains "summary shows first sentence" "$OUTPUT" "We use camelCase for variables and PascalCase for classes."
# Should NOT show the second line of content
assert_not_contains "summary hides second line" "$OUTPUT" "This is enforced by the linter"

# =============================================
# Test 7: load-knowledge.sh staleness — low confidence
# =============================================
echo ""
echo "Test 7: load-knowledge.sh staleness indicators"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "staleness detects low confidence" "$OUTPUT" "low-confidence"

# =============================================
# Test 8: load-knowledge.sh staleness — old file mtime
# =============================================
echo ""
echo "Test 8: load-knowledge.sh old mtime staleness"
# Set workflows.md mtime to 100 days ago
if [[ "$(uname)" == "Darwin" ]]; then
  touch -t "$(date -v-100d '+%Y%m%d%H%M.%S')" "$KNOWLEDGE_DIR/workflows.md"
else
  touch -d "100 days ago" "$KNOWLEDGE_DIR/workflows.md"
fi
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "staleness detects old mtime" "$OUTPUT" "workflows.md"
assert_contains "staleness shows days" "$OUTPUT" "d old"

# =============================================
# Test 9: load-knowledge.sh inbox detection
# =============================================
echo ""
echo "Test 9: load-knowledge.sh inbox detection"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "inbox detection" "$OUTPUT" "pending inbox entries"

# =============================================
# Test 10: load-knowledge.sh health check
# =============================================
echo ""
echo "Test 10: load-knowledge.sh health check (missing manifest)"
rm "$KNOWLEDGE_DIR/_manifest.json"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "health detects missing manifest" "$OUTPUT" "_manifest.json missing"

# =============================================
# Test 11: search-knowledge.sh backward compat (no --concise = same as before)
# =============================================
echo ""
echo "Test 11: backward compatibility"
# Restore manifest for this test
cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{"files": {"conventions.md": {"keywords": ["naming"]}}}
EOF
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" "timeout" "$TEST_DIR" 2>&1)
assert_contains "backward compat shows ranked section" "$OUTPUT" "Ranked results (FTS5)"
assert_contains "backward compat shows content" "$OUTPUT" "gotchas.md"

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
