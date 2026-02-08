#!/usr/bin/env bash
# test_relevance_loading.sh — Integration test for relevance-based startup loading
# Verifies: relevance-ranked output, budget compliance, domain exclusion,
#           backlink direct-resolution, signal_sources in retrieval log

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
    echo "    Got: $(echo "$output" | head -10)"
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

assert_line_before() {
  local label="$1" output="$2" first="$3" second="$4"
  local first_line second_line
  first_line=$(echo "$output" | grep -nF -- "$first" | head -1 | cut -d: -f1)
  second_line=$(echo "$output" | grep -nF -- "$second" | head -1 | cut -d: -f1)
  if [[ -z "$first_line" || -z "$second_line" ]]; then
    echo "  FAIL: $label"
    echo "    Could not find both strings in output"
    echo "    first ('$first'): line $first_line"
    echo "    second ('$second'): line $second_line"
    FAIL=$((FAIL + 1))
  elif [[ "$first_line" -lt "$second_line" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    '$first' (line $first_line) should appear before '$second' (line $second_line)"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_field() {
  local label="$1" json="$2" field="$3" expected="$4"
  local actual
  actual=$(echo "$json" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('$field', ''))" 2>/dev/null) || actual=""
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Field '$field': expected '$expected', got '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_json_array_contains() {
  local label="$1" json="$2" field="$3" expected="$4"
  local found
  found=$(echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
arr = d.get('$field', [])
print('yes' if '$expected' in arr else 'no')
" 2>/dev/null) || found="no"
  if [[ "$found" == "yes" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Array '$field' does not contain '$expected'"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup knowledge store with targeted entries ---
setup_knowledge_store() {
  mkdir -p "$KNOWLEDGE_DIR"/{conventions,gotchas,workflows,architecture,principles,abstractions,domains,_meta}

  cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}
EOF

  # Entry about caching (will match work item signal)
  cat > "$KNOWLEDGE_DIR/conventions/caching-strategy.md" << 'EOF'
# Caching Strategy

Use Redis for distributed caching across services.
Always set explicit TTL values per cache key type.
Cache invalidation uses pub/sub events.
<!-- learned: 2026-01-15 | confidence: high | source: manual | related_files: src/cache.py -->
EOF

  # Entry about search (will match work item signal)
  cat > "$KNOWLEDGE_DIR/gotchas/search-latency.md" << 'EOF'
# Search Latency Issues

FTS5 queries over 50ms indicate missing index.
Always check EXPLAIN QUERY PLAN before optimizing.
The composite scorer adds ~10ms overhead per result.
<!-- learned: 2026-01-20 | confidence: high | source: manual | related_files: scripts/pk_search.py -->
EOF

  # Entry about authentication (unrelated to work item)
  cat > "$KNOWLEDGE_DIR/conventions/auth-flow.md" << 'EOF'
# Authentication Flow

OAuth2 with PKCE for browser clients.
JWT tokens expire after 15 minutes.
Refresh tokens stored in httpOnly cookies.
<!-- learned: 2026-01-10 | confidence: high | source: manual | related_files: src/auth.py -->
EOF

  # Entry about deployment (unrelated)
  cat > "$KNOWLEDGE_DIR/workflows/deploy-process.md" << 'EOF'
# Deploy Process

Run the deploy script with --dry-run first.
Then run it again without the flag.
Always check the dashboard after deploy.
<!-- learned: 2026-01-05 | confidence: high | source: manual -->
EOF

  # Entry about error handling (unrelated)
  cat > "$KNOWLEDGE_DIR/conventions/error-handling.md" << 'EOF'
# Error Handling

Use custom error classes for domain errors.
Never catch generic exceptions in production code.
Log structured error context with correlation IDs.
<!-- learned: 2026-01-08 | confidence: high | source: manual -->
EOF

  # Entry that will be direct-resolved via backlink
  cat > "$KNOWLEDGE_DIR/architecture/index-design.md" << 'EOF'
# Index Design

The FTS5 index uses a single table with heading, content, and metadata columns.
Entries are split at H1 boundaries within each markdown file.
The index is rebuilt on force; incremental updates use file mtime.
<!-- learned: 2026-01-25 | confidence: high | source: manual | related_files: scripts/pk_search.py -->
EOF

  # Architecture entry about service mesh (unrelated)
  cat > "$KNOWLEDGE_DIR/architecture/service-mesh.md" << 'EOF'
# Service Mesh

All services communicate through the mesh layer.
Retry policies are configured at the mesh level.
<!-- learned: 2026-01-02 | confidence: high | source: manual -->
EOF

  # Principles entry (unrelated)
  cat > "$KNOWLEDGE_DIR/principles/simplicity-first.md" << 'EOF'
# Simplicity First

Prefer simple solutions over complex abstractions.
Three lines of duplicated code is better than a premature abstraction.
<!-- learned: 2026-01-01 | confidence: high | source: manual -->
EOF

  # Domain entry (should be excluded from loading)
  cat > "$KNOWLEDGE_DIR/domains/auth-domain.md" << 'EOF'
# Authentication Domain

OAuth2 flow with refresh tokens.
User sessions stored in Redis.
<!-- learned: 2026-01-03 | confidence: high | source: manual -->
EOF
}

# --- Setup work item with signal targeting caching and search entries ---
setup_work_item() {
  mkdir -p "$KNOWLEDGE_DIR/_work/improve-cache-search"

  cat > "$KNOWLEDGE_DIR/_work/improve-cache-search/_meta.json" << 'EOF'
{
  "title": "Improve Cache and Search Performance",
  "status": "in-progress",
  "tags": ["caching", "search", "performance", "redis"],
  "created_at": "2026-02-01T00:00:00Z"
}
EOF

  cat > "$KNOWLEDGE_DIR/_work/improve-cache-search/plan.md" << 'EOF'
# Improve Cache and Search Performance

## Phases

### Phase 1: Cache Layer Optimization
Optimize Redis caching with better key patterns and TTL management.

### Phase 2: Search Index Improvements
Improve FTS5 query performance and reduce latency.

## References
See [[knowledge:architecture/index-design]] for index structure details.
EOF

  cat > "$KNOWLEDGE_DIR/_work/improve-cache-search/notes.md" << 'EOF'
## Session Notes

Working on cache invalidation and search performance.
Redis pub/sub for cache events.
FTS5 composite scoring needs optimization.

See also [[knowledge:gotchas/search-latency]] for known issues.
EOF

  # Make it the most recently modified work item
  touch "$KNOWLEDGE_DIR/_work/improve-cache-search/_meta.json"
}

# --- Setup large store (forces compact index) ---
setup_large_store() {
  # Add enough entries to trigger compact index (full index > 25% of budget)
  for i in $(seq 1 30); do
    cat > "$KNOWLEDGE_DIR/conventions/convention-padding-$i.md" << EOF
# Convention Padding Entry $i

This is padding entry $i to force compact index mode.
Content is generic and unrelated to the work item signal.
<!-- learned: 2026-01-01 | confidence: medium | source: manual -->
EOF
  done

  for i in $(seq 1 20); do
    cat > "$KNOWLEDGE_DIR/architecture/arch-padding-$i.md" << EOF
# Architecture Padding Entry $i

This is architecture padding entry $i for compact index testing.
<!-- learned: 2026-01-01 | confidence: medium | source: manual -->
EOF
  done
}

# =============================================================
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Relevance-Based Startup Loading Integration Tests ==="
echo ""

# =============================================
# Test 1: Direct-resolved entries from backlinks
# =============================================
echo "Test 1: Direct-resolved entries from backlinks"
setup_knowledge_store
setup_work_item

# Build FTS5 index
python3 "$SCRIPT_DIR/pk_cli.py" index "$KNOWLEDGE_DIR" --force > /dev/null 2>&1

OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "has direct-resolved section" "$OUTPUT" "Direct-resolved entries"
assert_contains "direct-resolved includes index-design" "$OUTPUT" "Index Design"
assert_contains "direct-resolved includes search-latency" "$OUTPUT" "Search Latency"

# =============================================
# Test 2: Relevance-ranked entries from signal
# =============================================
echo ""
echo "Test 2: Relevance-ranked entries from signal"
# Entries matching signal (caching, search, redis, performance) should appear
assert_contains "relevance section present" "$OUTPUT" "Relevant entries"
assert_contains "caching strategy loaded" "$OUTPUT" "Caching Strategy"

# =============================================
# Test 3: Domain entries excluded
# =============================================
echo ""
echo "Test 3: Domain entries excluded from loading"
assert_not_contains "domain entry not loaded" "$OUTPUT" "Authentication Domain"
# But domains should appear in the index
assert_contains "domains in index" "$OUTPUT" "domains/"

# =============================================
# Test 4: Budget line present
# =============================================
echo ""
echo "Test 4: Budget line present and valid"
assert_contains "budget report" "$OUTPUT" "[Budget]"
assert_contains "budget has chars" "$OUTPUT" "chars"

# =============================================
# Test 5: Compact index with large store
# =============================================
echo ""
echo "Test 5: Large store uses compact index"
rm -rf "$KNOWLEDGE_DIR"
setup_knowledge_store
setup_work_item
setup_large_store

python3 "$SCRIPT_DIR/pk_cli.py" index "$KNOWLEDGE_DIR" --force > /dev/null 2>&1

OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "compact index header" "$OUTPUT" "Index (compact)"
assert_contains "compact has entry counts" "$OUTPUT" "entries)"
# Still loads relevant content even with large store
assert_contains "still loads relevant entries" "$OUTPUT" "Relevant entries"

# =============================================
# Test 6: Retrieval log written with new fields
# =============================================
echo ""
echo "Test 6: Retrieval log includes new fields"
LOG_FILE="$KNOWLEDGE_DIR/_meta/retrieval-log.jsonl"
if [[ -f "$LOG_FILE" ]]; then
  LAST_LOG=$(tail -1 "$LOG_FILE")
  assert_json_field "format_version is 4" "$LAST_LOG" "format_version" "4"

  # Check signal_sources is an array with expected sources
  HAS_SIGNAL_SOURCES=$(echo "$LAST_LOG" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ss = d.get('signal_sources', [])
print('yes' if isinstance(ss, list) and len(ss) > 0 else 'no')
" 2>/dev/null) || HAS_SIGNAL_SOURCES="no"

  if [[ "$HAS_SIGNAL_SOURCES" == "yes" ]]; then
    echo "  PASS: signal_sources is non-empty array"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: signal_sources is empty or missing"
    echo "    Log: $LAST_LOG"
    FAIL=$((FAIL + 1))
  fi

  assert_json_array_contains "signal_sources includes title" "$LAST_LOG" "signal_sources" "title"
  assert_json_array_contains "signal_sources includes tags" "$LAST_LOG" "signal_sources" "tags"

  # direct_resolved and relevance_search should be numbers
  DR_COUNT=$(echo "$LAST_LOG" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('direct_resolved', -1))" 2>/dev/null) || DR_COUNT="-1"
  RS_COUNT=$(echo "$LAST_LOG" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('relevance_search', -1))" 2>/dev/null) || RS_COUNT="-1"

  if [[ "$DR_COUNT" -ge 0 ]]; then
    echo "  PASS: direct_resolved is non-negative integer ($DR_COUNT)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: direct_resolved missing or invalid ($DR_COUNT)"
    FAIL=$((FAIL + 1))
  fi

  if [[ "$RS_COUNT" -ge 0 ]]; then
    echo "  PASS: relevance_search is non-negative integer ($RS_COUNT)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: relevance_search missing or invalid ($RS_COUNT)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: retrieval log file not found"
  FAIL=$((FAIL + 3))
fi

# =============================================
# Test 7: Signal sources include backlinks when present
# =============================================
echo ""
echo "Test 7: Signal sources include backlinks"
if [[ -f "$LOG_FILE" ]]; then
  LAST_LOG=$(tail -1 "$LOG_FILE")
  assert_json_array_contains "signal_sources includes backlinks" "$LAST_LOG" "signal_sources" "backlinks"
else
  echo "  FAIL: retrieval log file not found"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 8: Direct-resolved entries not duplicated in relevance section
# =============================================
echo ""
echo "Test 8: No duplication between direct-resolved and relevance sections"
# Count occurrences of "Index Design" — should appear once (in direct-resolved)
INDEX_DESIGN_COUNT=$(echo "$OUTPUT" | grep -c "# Index Design" || true)
if [[ "$INDEX_DESIGN_COUNT" -le 1 ]]; then
  echo "  PASS: Index Design appears at most once"
  PASS=$((PASS + 1))
else
  echo "  FAIL: Index Design appears $INDEX_DESIGN_COUNT times (expected <= 1)"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 9: Output stays within budget
# =============================================
echo ""
echo "Test 9: Output respects budget"
# Extract budget numbers from the [Budget] line
BUDGET_LINE=$(echo "$OUTPUT" | grep '\[Budget\]')
BUDGET_USED=$(echo "$BUDGET_LINE" | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f1)
BUDGET_TOTAL=$(echo "$BUDGET_LINE" | grep -oE '[0-9]+/[0-9]+' | head -1 | cut -d/ -f2)

if [[ -n "$BUDGET_USED" && -n "$BUDGET_TOTAL" ]]; then
  if [[ "$BUDGET_USED" -le "$BUDGET_TOTAL" ]]; then
    echo "  PASS: budget used ($BUDGET_USED) <= total ($BUDGET_TOTAL)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: budget used ($BUDGET_USED) exceeds total ($BUDGET_TOTAL)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: could not parse budget line: $BUDGET_LINE"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 10: No signal on empty store (no work items)
# =============================================
echo ""
echo "Test 10: No signal when no work items exist"
rm -rf "$KNOWLEDGE_DIR"
setup_knowledge_store
# Don't set up work item — no signal source
python3 "$SCRIPT_DIR/pk_cli.py" index "$KNOWLEDGE_DIR" --force > /dev/null 2>&1

OUTPUT_NOSIGNAL=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_not_contains "no direct-resolved without backlinks" "$OUTPUT_NOSIGNAL" "Direct-resolved entries"
# With no signal, there should be no relevance section either
assert_not_contains "no relevance section without signal" "$OUTPUT_NOSIGNAL" "Relevant entries"

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
