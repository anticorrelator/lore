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

# The signal comes from the branch of the checkout the hook runs in, so run it
# from a repo on main rather than from wherever the suite was started.
setup_main_branch_repo
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# The context signal should use "Relevant entries" header with signal text
assert_contains "relevance signal present" "$OUTPUT" "Relevant entries"
assert_contains "relevance signal has signal text" "$OUTPUT" "signal:"

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
setup_main_branch_repo
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
# Should load actual entry content when context signal triggers relevance search
assert_contains "loads entry content" "$OUTPUT" "camelCase"

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

# --- Preferences filed under activities ---
pref_entry() {
  local rel="$1" title="$2" footer="$3"
  mkdir -p "$(dirname "$KNOWLEDGE_DIR/preferences/$rel")"
  printf '# %s\nBody of %s.\n<!-- %s -->\n' "$title" "$title" "$footer" > "$KNOWLEDGE_DIR/preferences/$rel"
}

setup_preferences_store() {
  setup_v2_knowledge_store
  mkdir -p "$KNOWLEDGE_DIR/preferences/nested"
  pref_entry a-cost.md "Arcs price themselves before running" "learned: 2026-10-01 | activity: coordination | status: current"
  pref_entry b-routing.md "Every role routes to one model" "learned: 2026-10-01 | activity: model-routing, coordination | status: current"
  pref_entry c-runtime.md "The runtime needs nothing launched by hand" "learned: 2026-10-01 | activity: runtime-design | status: current"
  pref_entry d-untagged.md "Filed before activities existed" "learned: 2026-10-01 | status: current"
  pref_entry g1.md "Propose a shape when a concern comes without one" "learned: 2026-10-01 | activity: general | status: current"
  pref_entry nested/g2.md "Explain the mechanism before the fix" "learned: 2026-10-01 | activity: general"
  pref_entry g3.md "Answer at the level of what a choice does" "learned: 2026-10-01 | activity: general, human-writing | status: current"
  pref_entry g4-retired.md "A retired general rule" "learned: 2026-07-01 | activity: general | status: retired"
  printf '# preferences/\nWhat this directory holds.\n' > "$KNOWLEDGE_DIR/preferences/README.md"
}

# Length of the general block as printed: its lines, each with its newline.
general_block_chars() {
  python3 -c '
import sys
text = sys.stdin.read()
start = text.find("--- Preferences for general ---\n")
if start < 0:
    print(-1)
else:
    end = text.index("\n\n", start)
    print(len(text[start:end + 1]))
'
}

# =============================================
# Test 20: The activity index replaces the preferences count line
# =============================================
echo ""
echo "Test 20: preferences/ renders as an activity index"
rm -rf "$KNOWLEDGE_DIR"
setup_preferences_store
setup_main_branch_repo
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
INDEX_BLOCK=$(echo "$OUTPUT" | sed -n '/--- Index (compact) ---/,/^$/p')
# 9 files: the 8 entries, retired one included, and the README, as the count always was.
assert_contains "index heads with the recursive count" "$INDEX_BLOCK" "**preferences/** (9 entries), by activity:"
if echo "$INDEX_BLOCK" | grep -qx '\*\*preferences/\*\* ([0-9]* entries)'; then
  echo "  FAIL: the bare preferences count line is still rendered"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: the bare preferences count line is gone"
  PASS=$((PASS + 1))
fi
assert_contains "a commanded activity names its command" "$INDEX_BLOCK" \
  "  coordination (2) — printed in full by lore arc open; lore search --preferences --activity coordination"
assert_contains "an activity two commands start names both" "$INDEX_BLOCK" \
  "  model-routing (1) — printed in full by lore arc open, lore impl start; lore search --preferences --activity model-routing"
assert_contains "a skill-started activity names the skill" "$INDEX_BLOCK" \
  "  human-writing (1) — printed in full by lore arc close, /pr-create; lore search --preferences --activity human-writing"
assert_contains "an activity no command starts reads titles only" "$INDEX_BLOCK" \
  "  runtime-design (1) — titles only; lore search --preferences --activity runtime-design"
assert_contains "general counts live entries only" "$INDEX_BLOCK" \
  "  general (3) — titles only; lore search --preferences --activity general"
assert_contains "untagged live entries keep a line" "$INDEX_BLOCK" \
  "  untagged (1) — titles only; lore search --preferences --activity untagged"
ACTIVITY_ORDER=$(echo "$INDEX_BLOCK" | sed -n 's/^  \([a-z0-9-]*\) (.*/\1/p' | tr '\n' ' ')
if [[ "$ACTIVITY_ORDER" == "coordination general human-writing model-routing runtime-design untagged " ]]; then
  echo "  PASS: activities listed in name order"
  PASS=$((PASS + 1))
else
  echo "  FAIL: activity order was '$ACTIVITY_ORDER'"
  FAIL=$((FAIL + 1))
fi
INDEX_SUM=$(echo "$INDEX_BLOCK" | sed -n 's/^\*\*.*\*\* (\([0-9][0-9]*\) .*/\1/p' | awk '{s += $1} END {print s + 0}')
FOOTER_TOTAL=$(echo "$OUTPUT" | sed -n 's/^\[knowledge\] \([0-9][0-9]*\) entries across.*/\1/p' | head -1)
assert_eq_num "footer total still equals the index sum" "${FOOTER_TOTAL:-missing}" "$INDEX_SUM"

# =============================================
# Test 21: General titles follow the index, inside the budget
# =============================================
echo ""
echo "Test 21: general block lists every live general title"
assert_contains "general block header" "$OUTPUT" "--- Preferences for general ---"
GENERAL_BLOCK=$(echo "$OUTPUT" | sed -n '/^--- Preferences for general ---$/,/^$/p')
assert_contains "first general title" "$GENERAL_BLOCK" "- Propose a shape when a concern comes without one"
assert_contains "nested general title" "$GENERAL_BLOCK" "- Explain the mechanism before the fix"
assert_contains "two-activity general title" "$GENERAL_BLOCK" "- Answer at the level of what a choice does"
assert_not_contains "retired general entry omitted" "$GENERAL_BLOCK" "A retired general rule"
assert_not_contains "non-general entry omitted" "$GENERAL_BLOCK" "Arcs price themselves"
assert_not_contains "titles only, no bodies" "$GENERAL_BLOCK" "Body of"
assert_not_contains "nothing overflowed" "$GENERAL_BLOCK" "more: lore search"
GENERAL_CHARS=$(echo "$OUTPUT" | general_block_chars)
assert_contains "budget is charged the block's chars and counts its titles" "$OUTPUT" \
  "[Budget] ${GENERAL_CHARS}/8000 chars | 0 full, 3 summary, 0 skipped"
assert_not_contains "titles delivered, so no zero-entry line" "$OUTPUT" "0 entries delivered"

# With a context signal, the block still precedes the entries resolved for it.
setup_work_items
build_index
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
GENERAL_LINE=$(echo "$OUTPUT" | grep -n -F -- "--- Preferences for general ---" | head -1 | cut -d: -f1)
RELEVANT_LINE=$(echo "$OUTPUT" | grep -n -F -- "--- Relevant entries" | head -1 | cut -d: -f1)
INDEX_LINE=$(echo "$OUTPUT" | grep -n -F -- "--- Index (compact) ---" | head -1 | cut -d: -f1)
if [[ -n "$GENERAL_LINE" && -n "$RELEVANT_LINE" && $INDEX_LINE -lt $GENERAL_LINE && $GENERAL_LINE -lt $RELEVANT_LINE ]]; then
  echo "  PASS: general block sits between the index and the relevant entries"
  PASS=$((PASS + 1))
else
  echo "  FAIL: general block at line ${GENERAL_LINE:-missing}, index ${INDEX_LINE:-missing}, relevant ${RELEVANT_LINE:-missing}"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 22: General titles past the reserve are counted, not printed
# =============================================
echo ""
echo "Test 22: general block overflow stays inside its 2,500-char reserve"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
for i in $(seq -w 1 60); do
  pref_entry "general-$i.md" "General preference number $i with a title long enough to need the reserve" \
    "learned: 2026-10-01 | activity: general | status: current"
done
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
GENERAL_BLOCK=$(echo "$OUTPUT" | sed -n '/^--- Preferences for general ---$/,/^$/p')
GENERAL_CHARS=$(echo "$OUTPUT" | general_block_chars)
SHOWN=$(echo "$GENERAL_BLOCK" | grep -c '^- General preference number' || true)
HIDDEN=$(echo "$GENERAL_BLOCK" | sed -n 's/^(+\([0-9][0-9]*\) more: lore search --preferences --activity general)$/\1/p')
if [[ "$GENERAL_CHARS" -gt 0 && "$GENERAL_CHARS" -le 2500 ]]; then
  echo "  PASS: block is $GENERAL_CHARS chars, inside the reserve"
  PASS=$((PASS + 1))
else
  echo "  FAIL: block is $GENERAL_CHARS chars against a 2500 reserve"
  FAIL=$((FAIL + 1))
fi
if [[ -n "$HIDDEN" && "$SHOWN" -gt 0 && $((SHOWN + HIDDEN)) -eq 60 ]]; then
  echo "  PASS: $SHOWN titles shown, overflow line counts the other $HIDDEN"
  PASS=$((PASS + 1))
else
  echo "  FAIL: shown=$SHOWN hidden=${HIDDEN:-none} (expected them to sum to 60)"
  FAIL=$((FAIL + 1))
fi
assert_contains "first titles in filename order" "$GENERAL_BLOCK" "- General preference number 01 with"
assert_contains "budget line counts the shown titles" "$OUTPUT" "[Budget] ${GENERAL_CHARS}/8000 chars | 0 full, ${SHOWN} summary"

# =============================================
# Test 23: No preferences/, no index lines and no general block
# =============================================
echo ""
echo "Test 23: a store without preferences/ is unchanged"
rm -rf "$KNOWLEDGE_DIR"
setup_v2_knowledge_store
OUTPUT=$(cd "$MAIN_REPO" && bash "$SCRIPT_DIR/load-knowledge.sh" 2>&1)
assert_not_contains "no activity index" "$OUTPUT" "by activity:"
assert_not_contains "no general block" "$OUTPUT" "--- Preferences for general ---"
assert_contains "zero-entry line still explains itself" "$OUTPUT" "[knowledge] 0 entries delivered —"

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
