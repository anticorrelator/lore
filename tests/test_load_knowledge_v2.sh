#!/usr/bin/env bash
# test_load_knowledge_v2.sh — Tests for v2 format load-knowledge.sh features
# Tests: compact index, main-branch context signal, context-aware loading

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

# --- Setup v2 format knowledge store ---
setup_v2_knowledge_store() {
  mkdir -p "$KNOWLEDGE_DIR"/{conventions,gotchas,workflows,architecture,principles,abstractions,domains}

  # Manifest with format_version 2
  cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}
EOF

  # Conventions entries
  cat > "$KNOWLEDGE_DIR/conventions/naming-patterns.md" << 'EOF'
# Naming Patterns

Use camelCase for variables and PascalCase for classes.
Enforced by the linter.
EOF

  cat > "$KNOWLEDGE_DIR/conventions/import-order.md" << 'EOF'
# Import Order

Always import stdlib first, then third-party, then local.
EOF

  cat > "$KNOWLEDGE_DIR/conventions/error-handling.md" << 'EOF'
# Error Handling

Use custom error classes for domain errors.
Never catch generic exceptions.
EOF

  # Gotchas entries
  cat > "$KNOWLEDGE_DIR/gotchas/timeout-bug.md" << 'EOF'
# Timeout Bug

The HTTP client has a default timeout of 30s.
Override it explicitly for long-running requests.
EOF

  cat > "$KNOWLEDGE_DIR/gotchas/cache-invalidation.md" << 'EOF'
# Cache Invalidation

Redis cache entries expire after 1 hour by default.
Set TTL explicitly for each key type.
EOF

  # Workflows entries
  cat > "$KNOWLEDGE_DIR/workflows/deploy-process.md" << 'EOF'
# Deploy Process

Run the deploy script with --dry-run first.
Then run it again without the flag.
EOF

  # Architecture entries
  cat > "$KNOWLEDGE_DIR/architecture/service-mesh.md" << 'EOF'
# Service Mesh

All services communicate through the mesh layer.
EOF

  # Principles entry
  cat > "$KNOWLEDGE_DIR/principles/simplicity-first.md" << 'EOF'
# Simplicity First

Prefer simple solutions over complex abstractions.
EOF

  # Domain file
  cat > "$KNOWLEDGE_DIR/domains/auth.md" << 'EOF'
# Authentication Domain

OAuth2 flow with refresh tokens.
EOF
}

# --- Setup a large v2 store to force compact index ---
setup_large_v2_knowledge_store() {
  setup_v2_knowledge_store

  # Add many entries to make full index exceed 25% of 8000 budget (>2000 chars)
  # Each entry title line is ~30 chars. Need ~60+ entries across categories.
  for i in $(seq 1 30); do
    cat > "$KNOWLEDGE_DIR/conventions/convention-entry-$i.md" << EOF
# Convention Entry Number $i - Extended Title

This is convention entry number $i with content.
EOF
  done

  for i in $(seq 1 25); do
    cat > "$KNOWLEDGE_DIR/architecture/architecture-entry-$i.md" << EOF
# Architecture Entry Number $i - Extended Title

This is architecture entry number $i with content.
EOF
  done

  for i in $(seq 1 20); do
    cat > "$KNOWLEDGE_DIR/gotchas/gotcha-entry-$i.md" << EOF
# Gotcha Entry Number $i - Extended Title

This is gotcha entry number $i with content.
EOF
  done

  for i in $(seq 1 10); do
    cat > "$KNOWLEDGE_DIR/workflows/workflow-entry-$i.md" << EOF
# Workflow Entry Number $i - Extended Title

This is workflow entry number $i with content.
EOF
  done
}

# --- Setup work items for main-branch context signal ---
setup_work_items() {
  mkdir -p "$KNOWLEDGE_DIR/_work/improve-search"

  cat > "$KNOWLEDGE_DIR/_work/improve-search/_meta.json" << 'EOF'
{
  "title": "Improve Search Quality",
  "status": "in-progress",
  "created_at": "2026-02-01T00:00:00Z"
}
EOF

  cat > "$KNOWLEDGE_DIR/_work/improve-search/plan.md" << 'EOF'
# Improve Search Quality

## Phases

### Phase 1: Fix Tokenization
Fix hyphenated token handling.

### Phase 2: Add Caller Tracking
Add caller field to search logs.
EOF

  # Touch to make it the most recent
  touch "$KNOWLEDGE_DIR/_work/improve-search/_meta.json"
}

setup_v2_knowledge_store
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== V2 Format Load-Knowledge Tests ==="
echo ""

# =============================================
# Test 1: Basic v2 loading works
# =============================================
echo "Test 1: Basic v2 loading"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "loads v2 content" "$OUTPUT" "=== Project Knowledge ==="
assert_contains "budget report present" "$OUTPUT" "[Budget]"

# =============================================
# Test 2: Small store uses full index (per-entry titles)
# =============================================
echo ""
echo "Test 2: Small store uses full index"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "full index header" "$OUTPUT" "--- Index ---"
assert_not_contains "not compact mode" "$OUTPUT" "--- Index (compact) ---"
# Full index should include per-entry titles
assert_contains "index has entry title" "$OUTPUT" "Naming Patterns"
assert_contains "index has category with count" "$OUTPUT" "conventions/"

# =============================================
# Test 3: Large store uses compact index
# =============================================
echo ""
echo "Test 3: Large store uses compact index"
# Recreate with many entries
rm -rf "$KNOWLEDGE_DIR"
setup_large_v2_knowledge_store
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "compact index header" "$OUTPUT" "Index (compact)"
# Compact should have category counts but not per-entry titles
assert_contains "compact has category" "$OUTPUT" "conventions/"
assert_contains "compact has entry count" "$OUTPUT" "entries)"
# Compact should NOT have the individual entry titles (just counts)
assert_not_contains "compact omits entry titles" "$OUTPUT" "  - Convention Entry Number 1"

# =============================================
# Test 4: Main branch with active work item produces context signal
# =============================================
echo ""
echo "Test 4: Main branch context signal from active work items"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
setup_work_items

# Override git branch to main
export LORE_GIT_BRANCH="main"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# The context signal should include the work item title
assert_contains "context signal present" "$OUTPUT" "Context-relevant"
assert_contains "context signal has work title" "$OUTPUT" "signal:"
unset LORE_GIT_BRANCH

# =============================================
# Test 5: Compact index frees budget for actual content
# =============================================
echo ""
echo "Test 5: Compact index frees budget for content"
rm -rf "$KNOWLEDGE_DIR"
setup_large_v2_knowledge_store
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# With compact index, there should be budget left for actual entries
assert_contains "has content after compact index" "$OUTPUT" "entries) ---"
# Budget should show actual usage, not exhausted at index
assert_contains "budget report" "$OUTPUT" "[Budget]"

# =============================================
# Test 6: v2 store loads entry content (not just index)
# =============================================
echo ""
echo "Test 6: v2 loads actual entry content"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# Should load actual entry content (small store = everything fits)
assert_contains "loads entry content" "$OUTPUT" "camelCase"

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
