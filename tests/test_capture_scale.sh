#!/usr/bin/env bash
# test_capture_scale.sh — Tests for --scale enforcement in capture.sh
# Covers: missing flag, invalid enum, valid 4-bucket set, registry consultation,
# unknown rejection.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
CAPTURE_SH="$SCRIPT_DIR/capture.sh"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_exit_nonzero() {
  local label="$1"
  local exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero exit, got 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local label="$1"
  local exit_code="$2"
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
    fi
    FAIL=$((FAIL + 1))
  fi
}

run_capture() {
  bash "$CAPTURE_SH" "$@" 2>&1
  echo "EXIT:$?"
}

get_exit() {
  echo "$1" | grep "^EXIT:" | sed 's/EXIT://'
}

get_output() {
  echo "$1" | grep -v "^EXIT:"
}

setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
}

export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== Capture Scale Tests ==="
echo ""

# =============================================
# Test 1: Missing --scale flag exits non-zero
# =============================================
echo "Test 1: Missing --scale flag — non-zero exit + error message"
setup_knowledge_store

RESULT=$(run_capture --insight "test insight" --context "test context" --confidence high)
assert_exit_nonzero "exits non-zero when --scale omitted" "$(get_exit "$RESULT")"
assert_contains "error mentions --scale required" "$(get_output "$RESULT")" "--scale is required"

# =============================================
# Test 2: Invalid enum value exits non-zero
# =============================================
echo ""
echo "Test 2: Invalid enum value (--scale=foo) — non-zero exit + enum error"
setup_knowledge_store

RESULT=$(run_capture --insight "test insight" --context "test context" --confidence high --scale=foo)
assert_exit_nonzero "exits non-zero when scale=foo" "$(get_exit "$RESULT")"
assert_contains "error mentions valid values" "$(get_output "$RESULT")" "is not a registered scale id"

# =============================================
# Test 3: unknown is rejected (not in registry)
# =============================================
echo ""
echo "Test 3: scale=unknown rejected"
setup_knowledge_store

RESULT=$(run_capture --insight "test insight" --context "test context" --confidence high --scale=unknown)
assert_exit_nonzero "exits non-zero when scale=unknown" "$(get_exit "$RESULT")"
assert_contains "error mentions valid values for unknown rejection" "$(get_output "$RESULT")" "is not a registered scale id"

# =============================================
# Test 4: Valid 4-bucket set — all 4 values succeed
# =============================================
echo ""
echo "Test 4: Valid 4-bucket set — all 4 scale values succeed"

for BUCKET in implementation subsystem architecture abstract; do
  setup_knowledge_store
  RESULT=$(run_capture \
    --insight "scale bucket $BUCKET test" \
    --context "test context" \
    --confidence high \
    --scale="$BUCKET")
  assert_exit_zero "scale=$BUCKET succeeds" "$(get_exit "$RESULT")"
  # Verify scale is written into the entry's metadata comment
  ENTRY=$(find "$KNOWLEDGE_DIR/conventions" -name "*.md" 2>/dev/null | head -1)
  assert_file_contains "scale=$BUCKET written to entry metadata" \
    "$ENTRY" \
    "scale: $BUCKET"
done

# =============================================
# Test 5: Registry consultation — error lists current registry values
# =============================================
echo ""
echo "Test 5: Registry consultation — error lists current 4-bucket registry values"
setup_knowledge_store

RESULT=$(run_capture --insight "test" --context "x" --confidence high --scale=notavalidscale)
assert_contains "error lists implementation" "$(get_output "$RESULT")" "implementation"
assert_contains "error lists subsystem" "$(get_output "$RESULT")" "subsystem"
assert_contains "error lists architecture" "$(get_output "$RESULT")" "architecture"
assert_contains "error lists abstract" "$(get_output "$RESULT")" "abstract"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
