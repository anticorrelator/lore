#!/usr/bin/env bash
# test_activity_vocab_seed.sh — Tests for activity-vocab default seeding
# Covers: lib.sh primitive (seed_meta_activity_vocab), init-repo.sh consumer,
# and heal-knowledge.sh consumer (report-only vs --fix branches).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
CANONICAL="$REPO_DIR/defaults/_meta/activity-vocab.yaml"

TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    echo "    $2"
  fi
  FAIL=$((FAIL + 1))
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label" "File does not exist: $path"
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$label"
  else
    fail "$label" "Path should not exist: $path"
  fi
}

assert_byte_equal() {
  local label="$1" a="$2" b="$3"
  if cmp -s "$a" "$b"; then
    pass "$label"
  else
    fail "$label" "Files differ: $a vs $b"
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    pass "$label"
  else
    fail "$label" "Expected to contain: $expected"
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    fail "$label" "Should NOT contain: $unexpected"
  else
    pass "$label"
  fi
}

echo "=== activity-vocab seed tests ==="
echo ""

# =============================================
# Test 1: heal --fix materializes an absent file byte-equal to canonical
# =============================================
echo "Test 1: heal --fix seeds absent activity-vocab.yaml byte-equal to canonical default"
KDIR="$TEST_DIR/store1"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/init-repo.sh" --force "$KDIR" > /dev/null
# Remove the seeded file so heal has work to do
rm -f "$KDIR/_meta/activity-vocab.yaml"

OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" --fix 2>&1)
assert_file_exists "heal --fix materialized activity-vocab.yaml" "$KDIR/_meta/activity-vocab.yaml"
assert_byte_equal "seeded file byte-equal to canonical" "$KDIR/_meta/activity-vocab.yaml" "$CANONICAL"
assert_contains "heal report mentions seeding" "$OUTPUT" "Seeded missing _meta/activity-vocab.yaml"

# =============================================
# Test 2: heal report-only (no --fix) produces ZERO filesystem changes
# =============================================
echo ""
echo "Test 2: heal report-only does not create _meta/ or seed file"
KDIR="$TEST_DIR/store2"
# A bare knowledge directory: no _meta/, no activity-vocab.yaml, no _manifest.json
mkdir -p "$KDIR"

OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" 2>&1)
assert_contains "heal report names missing activity-vocab.yaml" "$OUTPUT" "Missing _meta/activity-vocab.yaml"
assert_file_absent "heal report-only did not create activity-vocab.yaml" "$KDIR/_meta/activity-vocab.yaml"
assert_file_absent "heal report-only did not create _meta/ directory" "$KDIR/_meta"

# =============================================
# Test 3: Present file (any content, including empty) is untouched
# =============================================
echo ""
echo "Test 3a: Present empty file is untouched by heal report and --fix"
KDIR="$TEST_DIR/store3"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/init-repo.sh" --force "$KDIR" > /dev/null
# Replace the seeded canonical file with an empty file (deliberate opt-out)
: > "$KDIR/_meta/activity-vocab.yaml"
PRE_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')

# Report-only: should be silent about activity-vocab and not mutate
REPORT_OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" 2>&1)
POST_REPORT_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')
if [[ "$PRE_CHECKSUM" == "$POST_REPORT_CHECKSUM" ]]; then
  pass "heal report-only left present empty file untouched"
else
  fail "heal report-only mutated present empty file"
fi
assert_not_contains "heal report-only is silent on present empty file" "$REPORT_OUTPUT" "activity-vocab"

# --fix: should still leave present file alone
FIX_OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" --fix 2>&1)
POST_FIX_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')
if [[ "$PRE_CHECKSUM" == "$POST_FIX_CHECKSUM" ]]; then
  pass "heal --fix left present empty file untouched"
else
  fail "heal --fix mutated present empty file"
fi
assert_not_contains "heal --fix is silent on present empty file" "$FIX_OUTPUT" "activity-vocab"

echo ""
echo "Test 3b: Present hand-authored file is untouched by heal report and --fix"
KDIR="$TEST_DIR/store3b"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/init-repo.sh" --force "$KDIR" > /dev/null
cat > "$KDIR/_meta/activity-vocab.yaml" << 'EOF'
# Project override
src/**/*.py: [logger, span, trace]
EOF
PRE_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')

REPORT_OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" 2>&1)
POST_REPORT_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')
if [[ "$PRE_CHECKSUM" == "$POST_REPORT_CHECKSUM" ]]; then
  pass "heal report-only left hand-authored file untouched"
else
  fail "heal report-only mutated hand-authored file"
fi
assert_not_contains "heal report-only is silent on hand-authored file" "$REPORT_OUTPUT" "activity-vocab"

FIX_OUTPUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/heal-knowledge.sh" --fix 2>&1)
POST_FIX_CHECKSUM=$(shasum "$KDIR/_meta/activity-vocab.yaml" | awk '{print $1}')
if [[ "$PRE_CHECKSUM" == "$POST_FIX_CHECKSUM" ]]; then
  pass "heal --fix left hand-authored file untouched"
else
  fail "heal --fix mutated hand-authored file"
fi
assert_not_contains "heal --fix is silent on hand-authored file" "$FIX_OUTPUT" "activity-vocab"

# =============================================
# Test 4: init-repo.sh --force seeds canonical file byte-equal
# =============================================
echo ""
echo "Test 4: init-repo.sh --force seeds activity-vocab.yaml byte-equal to canonical"
KDIR="$TEST_DIR/store4"
LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/init-repo.sh" --force "$KDIR" > /dev/null
assert_file_exists "init-repo created activity-vocab.yaml" "$KDIR/_meta/activity-vocab.yaml"
assert_byte_equal "init-repo seed byte-equal to canonical" "$KDIR/_meta/activity-vocab.yaml" "$CANONICAL"

# =============================================
# Test 5: Fault injection — canonical source missing, destination absent
# =============================================
echo ""
echo "Test 5: seed_meta_activity_vocab fails with named error when canonical source is missing"
KDIR="$TEST_DIR/store5"
mkdir -p "$KDIR"

# Stage a fake LORE_REPO_DIR with no defaults/_meta/activity-vocab.yaml under it
FAKE_REPO="$TEST_DIR/fake-repo"
mkdir -p "$FAKE_REPO/scripts"
# Copy lib.sh into the fake repo so the source-self-detection lands inside it,
# making LORE_REPO_DIR resolve to $FAKE_REPO (which has no defaults/_meta).
cp "$SCRIPT_DIR/lib.sh" "$FAKE_REPO/scripts/lib.sh"

set +e
ERROR_OUTPUT=$(bash -c "
  source '$FAKE_REPO/scripts/lib.sh'
  seed_meta_activity_vocab '$KDIR'
" 2>&1)
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  pass "seed_meta_activity_vocab returns non-zero when canonical source missing"
else
  fail "seed_meta_activity_vocab should have returned non-zero (rc=$RC)"
fi
assert_contains "error message names canonical path" "$ERROR_OUTPUT" "$FAKE_REPO/defaults/_meta/activity-vocab.yaml"
assert_file_absent "destination not created on fault" "$KDIR/_meta/activity-vocab.yaml"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
