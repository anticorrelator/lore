#!/usr/bin/env bash
# test_load_knowledge_v2.sh — Tests for v2 format load-knowledge.sh features
# Tests: compact index, relevance-based loading, context-aware loading

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  # Restore load-knowledge.sh if it was modified (tiny-budget test safety net)
  if [[ -f "$TEST_DIR/load-knowledge.sh.bak" ]]; then
    cp "$TEST_DIR/load-knowledge.sh.bak" "$SCRIPT_DIR/load-knowledge.sh"
  fi
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

# --- Setup a large v2 store with many entries ---
setup_large_v2_knowledge_store() {
  setup_v2_knowledge_store

  # Add many entries across categories
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

# --- Setup a store whose entries live in category SUBDIRECTORIES ---
# Mirrors the real store's post-April layout. A depth-1 walk sees only the
# handful of entries at each category root, which is how the session-start
# index came to report ~1/11th of the store.
setup_nested_v2_knowledge_store() {
  setup_v2_knowledge_store

  mkdir -p "$KNOWLEDGE_DIR/conventions/scripting" \
           "$KNOWLEDGE_DIR/conventions/skills" \
           "$KNOWLEDGE_DIR/principles/design"

  for i in $(seq 1 7); do
    cat > "$KNOWLEDGE_DIR/conventions/scripting/nested-scripting-$i.md" << EOF
# Nested Scripting Convention $i

Nested scripting convention number $i.
EOF
  done

  for i in $(seq 1 5); do
    cat > "$KNOWLEDGE_DIR/conventions/skills/nested-skill-$i.md" << EOF
# Nested Skill Convention $i

Nested skill convention number $i.
EOF
  done

  for i in $(seq 1 4); do
    cat > "$KNOWLEDGE_DIR/principles/design/nested-design-$i.md" << EOF
# Nested Design Principle $i

Nested design principle number $i.
EOF
  done
}

# --- A git repo on `main`, to run the hooks from ---
# The context signal is derived from the current branch, so a test that needs a
# predictable signal has to control the branch rather than the environment it
# happens to run in. On `main` the signal comes from the most recently updated
# active work item — or is empty when there are none.
MAIN_REPO="$TEST_DIR/main-repo"
setup_main_branch_repo() {
  [[ -d "$MAIN_REPO/.git" ]] && return
  mkdir -p "$MAIN_REPO"
  git -C "$MAIN_REPO" init -q -b main
  git -C "$MAIN_REPO" -c user.email=test@test -c user.name=test \
    commit -q --allow-empty -m "init"
}

# --- Build FTS5 index so pk_cli.py search works ---
build_index() {
  python3 "$SCRIPT_DIR/pk_cli.py" index "$KNOWLEDGE_DIR" 2>/dev/null || true
}

# --- Setup work items for main-branch context signal ---
# Work item title must contain terms that match test knowledge entries
# so FTS5 relevance search returns results
setup_work_items() {
  mkdir -p "$KNOWLEDGE_DIR/_work/fix-naming-conventions"

  cat > "$KNOWLEDGE_DIR/_work/fix-naming-conventions/_meta.json" << 'EOF'
{
  "title": "Fix Naming Conventions and Error Handling",
  "status": "in-progress",
  "created_at": "2026-02-01T00:00:00Z"
}
EOF

  cat > "$KNOWLEDGE_DIR/_work/fix-naming-conventions/plan.md" << 'EOF'
# Fix Naming Conventions and Error Handling

## Phases

### Phase 1: Update Naming Patterns
Enforce camelCase naming patterns across the codebase.

### Phase 2: Error Handling Improvements
Update custom error classes for domain errors.
EOF

  # Touch to make it the most recent
  touch "$KNOWLEDGE_DIR/_work/fix-naming-conventions/_meta.json"
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
# Test 2: Always uses compact index (category counts, no per-entry titles)
# =============================================
echo ""
echo "Test 2: Small store uses compact index"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "compact index header" "$OUTPUT" "--- Index (compact) ---"
# Compact index should have category names with counts
assert_contains "index has category" "$OUTPUT" "conventions/"
assert_contains "index has entry count" "$OUTPUT" "entries)"

# =============================================
# Test 3: Large store also uses compact index
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

# Build FTS5 index so relevance search works
build_index

# Override git branch to main
export LORE_GIT_BRANCH="main"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# The context signal should use "Relevant entries" header with signal text
assert_contains "relevance signal present" "$OUTPUT" "Relevant entries"
assert_contains "relevance signal has signal text" "$OUTPUT" "signal:"
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
assert_contains "has compact index" "$OUTPUT" "Index (compact)"
# Budget should show actual usage, not exhausted at index
assert_contains "budget report" "$OUTPUT" "[Budget]"

# =============================================
# Test 6: v2 store loads entry content (not just index)
# =============================================
echo ""
echo "Test 6: v2 loads actual entry content"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
setup_work_items
# Build FTS5 index so relevance search works
build_index
# Need a context signal to trigger content loading (relevance-ranked search)
export LORE_GIT_BRANCH="main"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# Should load actual entry content when context signal triggers relevance search
assert_contains "loads entry content" "$OUTPUT" "camelCase"
unset LORE_GIT_BRANCH

# =============================================
# Test 7: Budget report breaks down full/summary/skipped counts
# =============================================
echo ""
echo "Test 7: Budget report breakdown"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "budget report has full count" "$OUTPUT" "full,"
assert_contains "budget report has summary count" "$OUTPUT" "summary,"
assert_contains "budget report has skipped count" "$OUTPUT" "skipped"

# =============================================
# Test 8: Tiny budget still emits index + budget report
# =============================================
echo ""
echo "Test 8: Tiny budget (summary mode)"
# Temporarily set a tiny budget to force summary mode.
# Modify the actual script in-place and restore after (cleanup trap is the safety net).
ORIG_LOAD="$SCRIPT_DIR/load-knowledge.sh"
cp "$ORIG_LOAD" "$TEST_DIR/load-knowledge.sh.bak"
sed -i.tmp 's/^BUDGET=8000$/BUDGET=200/' "$ORIG_LOAD"

OUTPUT=$(bash "$ORIG_LOAD" 2>&1)

# Restore original
cp "$TEST_DIR/load-knowledge.sh.bak" "$ORIG_LOAD"
rm -f "$ORIG_LOAD.tmp"
assert_contains "tiny budget still shows index" "$OUTPUT" "Index (compact)"
assert_contains "tiny budget has budget report" "$OUTPUT" "[Budget]"

# =============================================
# Test 9: Staleness — low confidence
# =============================================
echo ""
echo "Test 9: Staleness indicator for low-confidence entries"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
# Must live in a rubric category (conventions) — scale-bearing categories
# (gotchas, architecture, ...) are only scanned when a context signal exists.
cat > "$KNOWLEDGE_DIR/conventions/flaky-retry.md" << 'EOF'
# Flaky Retry

Retries are capped at 3 attempts.
<!-- learned: 2026-01-10 | confidence: low | source: manual -->
EOF
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "staleness detects low confidence" "$OUTPUT" "low-confidence"

# =============================================
# Test 10: Staleness — old file mtime
# =============================================
echo ""
echo "Test 10: Staleness indicator for old mtime"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
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
# Test 11: Inbox detection
# =============================================
echo ""
echo "Test 11: Inbox detection"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
mkdir -p "$KNOWLEDGE_DIR/_inbox"
cat > "$KNOWLEDGE_DIR/_inbox/pending-insight.md" << 'EOF'
# Rate Limiting

The API uses rate limiting of 100 req/min.
EOF
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "inbox detection" "$OUTPUT" "inbox"

# =============================================
# Test 12: Health check — missing manifest
# =============================================
echo ""
echo "Test 12: Health check (missing manifest)"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
rm "$KNOWLEDGE_DIR/_manifest.json"
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "health detects missing manifest" "$OUTPUT" "No knowledge store found"

# =============================================
# Test 13: Index counts entries in category SUBDIRECTORIES
# =============================================
echo ""
echo "Test 13: Compact index counts nested entries"
rm -rf "$KNOWLEDGE_DIR"
setup_nested_v2_knowledge_store
OUTPUT=$(bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# conventions/: 3 at the category root + 7 scripting + 5 skills = 15.
assert_contains "conventions counted recursively" "$OUTPUT" "**conventions/** (15 entries)"
assert_not_contains "conventions not counted depth-1" "$OUTPUT" "**conventions/** (3 entries)"
# principles/: 1 at the root + 4 design = 5.
assert_contains "principles counted recursively" "$OUTPUT" "**principles/** (5 entries)"
assert_not_contains "principles not counted depth-1" "$OUTPUT" "**principles/** (1 entries)"

# =============================================
# Test 14: Index stays a bounded orientation surface
# =============================================
# The counts scale with the store; the rendered listing must not. A recursive
# walk that also listed titles would put 1000+ lines into every session start.
echo ""
echo "Test 14: Recursive counts do not enlarge the rendered index"
assert_not_contains "index omits nested entry titles" "$OUTPUT" "Nested Scripting Convention 1"
assert_not_contains "index omits root entry titles" "$OUTPUT" "  - Naming Patterns"
INDEX_LINES=$(echo "$OUTPUT" | sed -n '/--- Index (compact) ---/,/^$/p' | grep -c '^\*\*' || true)
if [[ "$INDEX_LINES" -le 10 ]]; then
  echo "  PASS: index is one line per category ($INDEX_LINES lines)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: index rendered $INDEX_LINES category lines (expected one per category)"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 15: [knowledge] footer agrees with the compact index
# =============================================
# Both surfaces count the same active categories. Before the fix the index and
# the footer were consistently wrong together; this pins them consistent AND
# recursive, so a future depth-1 regression in either one fails here.
echo ""
echo "Test 15: Footer total matches the compact index"
INDEX_SUM=$(echo "$OUTPUT" | sed -n '/--- Index (compact) ---/,/^$/p' \
  | sed -n 's/^\*\*.*\*\* (\([0-9][0-9]*\) .*/\1/p' \
  | awk '{s += $1} END {print s + 0}')
# Match on "entries across" — the zero-entry explanation line shares the
# [knowledge] prefix and would otherwise be picked up as a count of 0.
FOOTER_TOTAL=$(echo "$OUTPUT" | sed -n 's/^\[knowledge\] \([0-9][0-9]*\) entries across.*/\1/p' | head -1)
assert_eq_num() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (index sum=$expected, footer=$actual)"
    FAIL=$((FAIL + 1))
  fi
}
assert_eq_num "footer total equals index sum" "${FOOTER_TOTAL:-missing}" "$INDEX_SUM"
# And the total must exceed what a depth-1 walk would have produced.
if [[ "${FOOTER_TOTAL:-0}" -gt 12 ]]; then
  echo "  PASS: footer total is recursive (${FOOTER_TOTAL} > depth-1 ceiling)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: footer total ${FOOTER_TOTAL:-missing} looks like a depth-1 count"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 16: A zero-entry payload states its reason and its recovery
# =============================================
# The line renders on EVERY zero-entry payload, ordinary cases included — an
# agent that has only ever seen it on failures has no baseline to read it
# against.
echo ""
echo "Test 16: Zero-entry payload explains itself"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
setup_main_branch_repo
# No work items: on main that leaves the context signal empty, so the payload
# is the compact index and nothing else.
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "zero-entry line present" "$OUTPUT" "[knowledge] 0 entries delivered —"
assert_contains "zero-entry line names the reason" "$OUTPUT" "no context signal"
assert_contains "zero-entry line names the recovery" "$OUTPUT" 'lore prefetch "<topic>" --scale-set <bucket>'
# It sits immediately above the [Budget] footer.
ADJACENT=$(echo "$OUTPUT" | grep -A1 -F "[knowledge] 0 entries delivered" | tail -1)
assert_contains "zero-entry line precedes the budget footer" "$ADJACENT" "[Budget]"

# =============================================
# Test 17: A payload that delivered entries stays quiet
# =============================================
echo ""
echo "Test 17: Non-empty payload omits the zero-entry line"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
setup_work_items
setup_main_branch_repo
build_index
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_contains "entries were delivered" "$OUTPUT" "Relevant entries"
assert_not_contains "no zero-entry line" "$OUTPUT" "0 entries delivered"

# =============================================
# Test 18: A held index write lock degrades visibly, inside the time budget
# =============================================
# The hook must never wait on the lock past its own envelope: a SessionStart
# hook killed by timeout loses its entire stdout payload with no error anywhere.
echo ""
echo "Test 18: Held index write lock degrades visibly and in budget"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
setup_work_items
setup_main_branch_repo
# Deliberately no build_index — with the lock held, the hook cannot build one
# either, so the search has nothing usable to read.
LOCK_READY="$TEST_DIR/lock.ready"
rm -f "$LOCK_READY"
python3 -c "
import fcntl, sys, time
lock_path, ready_path, hold = sys.argv[1], sys.argv[2], float(sys.argv[3])
handle = open(lock_path, 'w')
fcntl.flock(handle, fcntl.LOCK_EX)
open(ready_path, 'w').close()
time.sleep(hold)
" "$KNOWLEDGE_DIR/.pk_search.lock" "$LOCK_READY" 25 &
LOCK_PID=$!
for _ in $(seq 1 100); do
  if [[ -f "$LOCK_READY" ]]; then
    break
  fi
  sleep 0.1
done

export LORE_LOAD_KNOWLEDGE_TIME_BUDGET=4
LOCK_START=$(date +%s)
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
LOCK_ELAPSED=$(( $(date +%s) - LOCK_START ))
unset LORE_LOAD_KNOWLEDGE_TIME_BUDGET
kill "$LOCK_PID" 2>/dev/null || true
wait "$LOCK_PID" 2>/dev/null || true

assert_contains "lock contention yields a zero-entry line" "$OUTPUT" "[knowledge] 0 entries delivered —"
assert_contains "lock contention names the search index" "$OUTPUT" "search index"
assert_contains "lock contention names the recovery" "$OUTPUT" 'lore prefetch "<topic>" --scale-set <bucket>'
assert_contains "payload still shipped" "$OUTPUT" "=== End Project Knowledge ==="
# The hook's own envelope is 15s (claude-code); a 4s search budget plus the
# rest of the load must stay well inside it.
if [[ "$LOCK_ELAPSED" -lt 12 ]]; then
  echo "  PASS: hook completed in ${LOCK_ELAPSED}s, inside its time budget"
  PASS=$((PASS + 1))
else
  echo "  FAIL: hook took ${LOCK_ELAPSED}s — lock wait is not bounded by the time budget"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 19: load-threads.sh reads the index, never builds it
# =============================================
# It used to call _ensure_index(), which made session start race two builders
# against one index. sqlite3.connect on a missing path would also leave an
# empty database behind for the next _ensure_index to detect and discard.
echo ""
echo "Test 19: load-threads.sh does not build or create the index"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
mkdir -p "$KNOWLEDGE_DIR/_threads/some-topic"
cat > "$KNOWLEDGE_DIR/_threads/_index.json" << 'EOF'
{"threads": [{"slug": "some-topic", "tier": "active"}]}
EOF
cat > "$KNOWLEDGE_DIR/_threads/some-topic/_meta.json" << EOF
{"topic": "Naming conventions", "tier": "active", "updated": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
EOF
cat > "$KNOWLEDGE_DIR/_threads/some-topic/2026-02-06.md" << 'EOF'
**Summary:** Discussed naming patterns and error handling.

Details about camelCase naming go here.
EOF
setup_work_items
setup_main_branch_repo
THREADS_OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-threads.sh" 2>&1)
assert_contains "threads render without an index" "$THREADS_OUTPUT" "=== Conversational Threads ==="
assert_contains "thread entry rendered" "$THREADS_OUTPUT" "camelCase"
if [[ ! -e "$KNOWLEDGE_DIR/.pk_search.db" ]]; then
  echo "  PASS: no index file created by the threads hook"
  PASS=$((PASS + 1))
else
  echo "  FAIL: threads hook created $KNOWLEDGE_DIR/.pk_search.db"
  FAIL=$((FAIL + 1))
fi

# With a warm index the ranking bias still works and the hook stays a reader.
build_index
INDEX_MTIME_BEFORE=$(python3 -c "import os,sys; print(os.path.getmtime(sys.argv[1]))" "$KNOWLEDGE_DIR/.pk_search.db")
THREADS_OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-threads.sh" 2>&1)
INDEX_MTIME_AFTER=$(python3 -c "import os,sys; print(os.path.getmtime(sys.argv[1]))" "$KNOWLEDGE_DIR/.pk_search.db")
assert_contains "threads render with a warm index" "$THREADS_OUTPUT" "camelCase"
if [[ "$INDEX_MTIME_BEFORE" == "$INDEX_MTIME_AFTER" ]]; then
  echo "  PASS: warm index untouched by the threads hook"
  PASS=$((PASS + 1))
else
  echo "  FAIL: threads hook wrote to the index (mtime $INDEX_MTIME_BEFORE -> $INDEX_MTIME_AFTER)"
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
