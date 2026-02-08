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
  # Restore load-knowledge.sh if it was modified (Test 6 safety net)
  if [[ -f "$TEST_DIR/load-knowledge.sh.bak" ]]; then
    cp "$TEST_DIR/load-knowledge.sh.bak" "$SCRIPT_DIR/load-knowledge.sh"
  fi
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

# --- Setup test knowledge store (v2 categorical structure) ---
setup_knowledge_store() {
  mkdir -p "$KNOWLEDGE_DIR"/{conventions,gotchas,workflows,domains}

  cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}
EOF

  cat > "$KNOWLEDGE_DIR/conventions/naming-patterns.md" << 'EOF'
# Naming Patterns

We use camelCase for variables and PascalCase for classes.
This is enforced by the linter.
<!-- learned: 2026-01-15 | confidence: high | source: manual | related_files: src/index.ts -->
EOF

  cat > "$KNOWLEDGE_DIR/conventions/import-order.md" << 'EOF'
# Import Order

Always import stdlib first, then third-party, then local.
Keep imports sorted alphabetically.
EOF

  cat > "$KNOWLEDGE_DIR/conventions/error-handling.md" << 'EOF'
# Error Handling

Use custom error classes for domain errors.
Never catch generic exceptions.
EOF

  cat > "$KNOWLEDGE_DIR/gotchas/timeout-bug.md" << 'EOF'
# Timeout Bug

The HTTP client has a default timeout of 30s.
Override it explicitly for long-running requests.
EOF

  cat > "$KNOWLEDGE_DIR/gotchas/cache-invalidation.md" << 'EOF'
# Cache Invalidation

Redis cache entries expire after 1 hour by default.
Set TTL explicitly for each key type.
<!-- learned: 2026-01-10 | confidence: low | source: manual -->
EOF

  cat > "$KNOWLEDGE_DIR/workflows/deploy-process.md" << 'EOF'
# Deploy Process

Run the deploy script with --dry-run first.
Then run it again without the flag.
EOF
}

setup_knowledge_store

# Override resolution via env var instead of mutating resolve-repo.sh
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Phase 1 Tests ==="
echo ""

# =============================================
# Test 1: search-knowledge.sh normal mode
# =============================================
echo "Test 1: search-knowledge.sh normal mode"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" "camelCase" "$TEST_DIR" 2>&1)
assert_contains "normal search finds matches" "$OUTPUT" "naming-patterns"
assert_contains "normal search shows line content" "$OUTPUT" "camelCase"
assert_contains "normal search shows ranked results" "$OUTPUT" "Ranked results (FTS5)"

# =============================================
# Test 2: search-knowledge.sh --concise mode
# =============================================
echo ""
echo "Test 2: search-knowledge.sh --concise mode"
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" --concise "camelCase" "$TEST_DIR" 2>&1)
assert_contains "concise search shows file path" "$OUTPUT" "naming-patterns"
assert_contains "concise search shows heading" "$OUTPUT" "Naming Patterns"
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
assert_contains "loads index header" "$OUTPUT" "=== Project Knowledge ==="
assert_contains "loads compact index" "$OUTPUT" "Index (compact)"
assert_contains "shows conventions category" "$OUTPUT" "conventions/"
assert_contains "budget report present" "$OUTPUT" "[Budget]"
assert_contains "budget report has full count" "$OUTPUT" "full,"
assert_contains "budget report has summary count" "$OUTPUT" "summary,"
assert_contains "budget report has skipped count" "$OUTPUT" "skipped"

# =============================================
# Test 6: load-knowledge.sh summary mode (small budget)
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
# With a tiny budget, entries should not be loaded (budget exhausted at index)
assert_contains "tiny budget still shows index" "$OUTPUT" "Index (compact)"
assert_contains "tiny budget has budget report" "$OUTPUT" "[Budget]"

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
# Set workflows entry mtime to 100 days ago
if [[ "$(uname)" == "Darwin" ]]; then
  touch -t "$(date -v-100d '+%Y%m%d%H%M.%S')" "$KNOWLEDGE_DIR/workflows/deploy-process.md"
else
  touch -d "100 days ago" "$KNOWLEDGE_DIR/workflows/deploy-process.md"
fi
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "staleness detects old mtime" "$OUTPUT" "deploy-process.md"
assert_contains "staleness shows days" "$OUTPUT" "d)"

# =============================================
# Test 9: load-knowledge.sh inbox detection
# =============================================
echo ""
echo "Test 9: load-knowledge.sh inbox detection"
# Create an _inbox directory with a pending entry
mkdir -p "$KNOWLEDGE_DIR/_inbox"
cat > "$KNOWLEDGE_DIR/_inbox/pending-insight.md" << 'EOF'
# Rate Limiting

The API uses rate limiting of 100 req/min.
EOF
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "inbox detection" "$OUTPUT" "inbox"

# =============================================
# Test 10: load-knowledge.sh health check
# =============================================
echo ""
echo "Test 10: load-knowledge.sh health check (missing manifest)"
rm "$KNOWLEDGE_DIR/_manifest.json"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "health detects missing manifest" "$OUTPUT" "No knowledge store found"

# =============================================
# Test 11: search-knowledge.sh backward compat (no --concise = same as before)
# =============================================
echo ""
echo "Test 11: backward compatibility"
# Restore manifest for this test
cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}
EOF
OUTPUT=$(bash "$SCRIPT_DIR/search-knowledge.sh" "timeout" "$TEST_DIR" 2>&1)
assert_contains "backward compat shows ranked section" "$OUTPUT" "Ranked results (FTS5)"
assert_contains "backward compat shows content" "$OUTPUT" "timeout-bug"

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
