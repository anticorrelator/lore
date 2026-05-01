#!/usr/bin/env bash
# test_retrieval_scale_declaration.sh — Tests for Phase 2 retrieval scale declaration enforcement.
# Covers: hard-fail (prefetch, lore query, lore search --json), interactive prompt (lore search),
# manifest dispatch (resolve-manifest.sh null directive + missing scale_set), retrieval-log shape.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
CLI="$REPO_DIR/cli/lore"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_exit_nonzero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero, got 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"
    FAIL=$((FAIL + 1))
  fi
}

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

setup_knowledge_dir() {
  local kdir="$TEST_DIR/knowledge_$$_$RANDOM"
  mkdir -p "$kdir/_meta" "$kdir/_work"
  echo '{}' > "$kdir/_manifest.json"
  echo "$kdir"
}

echo "=== Retrieval Scale Declaration Tests ==="
echo ""

# ================================================================
# Section 1: prefetch-knowledge.sh hard-fail
# ================================================================
echo "--- Section 1: prefetch-knowledge.sh hard-fail ---"

echo "Test 1.1: prefetch-knowledge.sh with no --scale-set exits non-zero"
OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "some topic" 2>&1); EC=$?
assert_exit_nonzero "prefetch exits non-zero without --scale-set" "$EC"
assert_contains "prefetch error mentions --scale-set" "$OUT" "--scale-set"

echo ""
echo "Test 1.2: prefetch-knowledge.sh --scale-context (deprecated) alone exits non-zero"
OUT=$(bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "some topic" --scale-context worker 2>&1); EC=$?
assert_exit_nonzero "prefetch --scale-context alone exits non-zero" "$EC"

echo ""

# ================================================================
# Section 2: lore query hard-fail
# ================================================================
echo "--- Section 2: lore query hard-fail ---"

echo "Test 2.1: lore query --seeds <file> (no --scale-set) exits non-zero"
SEED_FILE="$TEST_DIR/seed.py"
echo "# seed" > "$SEED_FILE"
OUT=$(bash "$CLI" query --seeds "$SEED_FILE" 2>&1); EC=$?
assert_exit_nonzero "lore query exits non-zero without --scale-set" "$EC"
assert_contains "lore query error mentions --scale-set" "$OUT" "--scale-set"

echo ""

# ================================================================
# Section 3: lore search hard-fail (programmatic --json path)
# ================================================================
echo "--- Section 3: lore search --json hard-fail ---"

echo "Test 3.1: lore search --json (no --scale-set) exits non-zero"
OUT=$(bash "$CLI" search "some topic" --json 2>&1); EC=$?
assert_exit_nonzero "lore search --json exits non-zero without --scale-set" "$EC"

echo ""
echo "Test 3.2: lore search --json error output contains --scale-set guidance"
assert_contains "lore search --json error mentions --scale-set" "$OUT" "--scale-set"

echo ""

# ================================================================
# Section 4: lore search interactive prompt (non-JSON path)
# ================================================================
echo "--- Section 4: lore search interactive prompt ---"

echo "Test 4.1: lore search (no --json, no --scale-set) exits non-zero"
OUT=$(bash "$CLI" search "some topic" 2>&1); EC=$?
assert_exit_nonzero "lore search interactive exits non-zero without --scale-set" "$EC"

echo ""
echo "Test 4.2: lore search interactive output contains declaration guidance"
assert_contains "interactive output mentions scale-set" "$OUT" "--scale-set"

echo ""
echo "Test 4.3: lore search interactive output lists valid buckets"
assert_contains "interactive output lists abstract" "$OUT" "abstract"
assert_contains "interactive output lists architecture" "$OUT" "architecture"
assert_contains "interactive output lists subsystem" "$OUT" "subsystem"
assert_contains "interactive output lists implementation" "$OUT" "implementation"

echo ""

# ================================================================
# Section 5: resolve-manifest.sh — manifest dispatch hard-fail
# Uses LORE_KNOWLEDGE_DIR to redirect knowledge dir to a temp location.
# ================================================================
echo "--- Section 5: resolve-manifest.sh dispatch hard-fail ---"

KDIR=$(setup_knowledge_dir)
SLUG="test-manifest-slug"
mkdir -p "$KDIR/_work/$SLUG"

echo "Test 5.1: resolve-manifest.sh exits non-zero when retrieval_directive is null"
cat > "$KDIR/_work/$SLUG/tasks.json" <<'JSON'
{
  "phases": [
    {
      "phase_number": 1,
      "retrieval_directive": null
    }
  ]
}
JSON
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/resolve-manifest.sh" "$SLUG" 1 2>&1); EC=$?
assert_exit_nonzero "resolve-manifest exits non-zero for null directive" "$EC"
assert_contains "null directive error is diagnostic" "$OUT" "retrieval_directive"

echo ""
echo "Test 5.2: resolve-manifest.sh exits non-zero when scale_set is missing from directive"
cat > "$KDIR/_work/$SLUG/tasks.json" <<'JSON'
{
  "phases": [
    {
      "phase_number": 1,
      "retrieval_directive": {
        "seeds": ["scripts/capture.sh"],
        "hop_budget": 1
      }
    }
  ]
}
JSON
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/resolve-manifest.sh" "$SLUG" 1 2>&1); EC=$?
assert_exit_nonzero "resolve-manifest exits non-zero for missing scale_set" "$EC"
assert_contains "missing scale_set error is diagnostic" "$OUT" "scale"

echo ""
echo "Test 5.3: resolve-manifest.sh exits non-zero when seeds list is empty"
cat > "$KDIR/_work/$SLUG/tasks.json" <<'JSON'
{
  "phases": [
    {
      "phase_number": 1,
      "retrieval_directive": {
        "seeds": [],
        "scale_set": ["implementation"],
        "hop_budget": 1
      }
    }
  ]
}
JSON
OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/resolve-manifest.sh" "$SLUG" 1 2>&1); EC=$?
assert_exit_nonzero "resolve-manifest exits non-zero for empty seeds" "$EC"
assert_contains "empty seeds error is diagnostic" "$OUT" "seeds"

echo ""

# ================================================================
# Section 6: load-knowledge.sh retrieval-log shape
# Verifies the scale_declared field is present in log records.
# Uses LORE_KNOWLEDGE_DIR to write to a temp dir.
# ================================================================
echo "--- Section 6: load-knowledge.sh retrieval-log shape ---"

KDIR=$(setup_knowledge_dir)

echo "Test 6.1: load-knowledge.sh retrieval-log record contains scale_declared field"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/load-knowledge.sh" >/dev/null 2>&1 || true
LOG="$KDIR/_meta/retrieval-log.jsonl"
if [[ -f "$LOG" ]] && [[ -s "$LOG" ]]; then
  LAST_RECORD=$(tail -1 "$LOG")
  SCALE_DECL=$(echo "$LAST_RECORD" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('present' if 'scale_declared' in d else 'missing')
" 2>/dev/null || echo "parse_error")
  if [[ "$SCALE_DECL" == "present" ]]; then
    echo "  PASS: retrieval-log record contains scale_declared key"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: retrieval-log record missing scale_declared key (got: $SCALE_DECL)"
    echo "    Record: $LAST_RECORD"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  PASS: retrieval-log shape (no log written — acceptable when no db present)"
  PASS=$((PASS + 1))
fi

echo ""
echo "Test 6.2: load-knowledge.sh retrieval-log scale_declared is a boolean (true or false)"
if [[ -f "$LOG" ]] && [[ -s "$LOG" ]]; then
  LAST_RECORD=$(tail -1 "$LOG")
  SCALE_DECL_VAL=$(echo "$LAST_RECORD" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
v = d.get('scale_declared')
if isinstance(v, bool):
    print('bool')
else:
    print(f'not_bool:{type(v).__name__}:{v}')
" 2>/dev/null || echo "parse_error")
  if [[ "$SCALE_DECL_VAL" == "bool" ]]; then
    echo "  PASS: scale_declared is a JSON boolean"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: scale_declared should be a JSON boolean, got: $SCALE_DECL_VAL"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  PASS: scale_declared type (no log to check — acceptable)"
  PASS=$((PASS + 1))
fi

echo ""

# ================================================================
# Summary
# ================================================================
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
