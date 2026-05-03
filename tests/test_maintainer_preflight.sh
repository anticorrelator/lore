#!/usr/bin/env bash
# test_maintainer_preflight.sh — Tests for scripts/maintainer-preflight.sh (task-58)
#
# Covers:
#   - Contributor role → silent no-op (ran=false)
#   - Maintainer role → preflight runs; session marker is touched
#   - Session marker short-circuits a second invocation
#   - Non-git dir → warning with "not a git repository"
#   - Missing origin → warning with "no 'origin' remote configured"
#   - Exit code is always 0 (warn, never block) as long as argv is valid
#   - Usage error on unknown flag exits 1

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
PREFLIGHT="$SCRIPTS_DIR/maintainer-preflight.sh"

PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected=$expected, actual=$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — did not find: $needle"
    FAIL=$((FAIL + 1))
  fi
}

# JSON field extractor.
json_field() {
  local json="$1" key="$2"
  echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$key'))"
}

echo "=== maintainer-preflight.sh tests ==="

# --- Test 1: Contributor is no-op ---
echo ""
echo "Test 1: Contributor role → silent no-op"
OUT=$(LORE_ROLE=contributor bash "$PREFLIGHT" --json)
assert_eq "ran=False for contributor" "$(json_field "$OUT" ran)" "False"
assert_eq "role=contributor surfaced" "$(json_field "$OUT" role)" "contributor"

# --- Test 2: Maintainer runs against non-git dir, warning emitted ---
echo ""
echo "Test 2: Maintainer, non-git dir → warning"
NONGIT="$TEST_DIR/nongit"
mkdir -p "$NONGIT"
OUT=$(LORE_ROLE=maintainer bash "$PREFLIGHT" --json --repo-dir "$NONGIT")
assert_eq "ran=True" "$(json_field "$OUT" ran)" "True"
assert_eq "role=maintainer" "$(json_field "$OUT" role)" "maintainer"
assert_eq "push_dry_run_ok=False" "$(json_field "$OUT" push_dry_run_ok)" "False"
assert_contains "warning cites non-git" "$OUT" "not a git repository"

# --- Test 3: Maintainer against a git repo with NO origin → 'no origin' warning ---
echo ""
echo "Test 3: Maintainer, git repo without origin → warning"
NOORIGIN="$TEST_DIR/noorigin"
git init -q "$NOORIGIN"
# Make a commit so HEAD resolves.
(cd "$NOORIGIN" && git -c user.email=test@x -c user.name=Test commit --allow-empty -q -m "init")
OUT=$(LORE_ROLE=maintainer bash "$PREFLIGHT" --json --repo-dir "$NOORIGIN")
assert_eq "push_dry_run_ok=False when no origin" "$(json_field "$OUT" push_dry_run_ok)" "False"
assert_contains "warning cites missing origin" "$OUT" "no 'origin' remote configured"

# --- Test 4: Session marker short-circuits second call ---
echo ""
echo "Test 4: Session marker short-circuits subsequent calls"
MARKER="$TEST_DIR/marker"
# First call: runs
OUT1=$(LORE_ROLE=maintainer bash "$PREFLIGHT" --json --session-marker "$MARKER" --repo-dir "$NONGIT")
assert_eq "first call: ran=True" "$(json_field "$OUT1" ran)" "True"
# Marker now exists
if [[ -f "$MARKER" ]]; then
  echo "  PASS: session marker created after first call"; PASS=$((PASS + 1))
else
  echo "  FAIL: session marker not created"; FAIL=$((FAIL + 1))
fi
# Second call: short-circuits
OUT2=$(LORE_ROLE=maintainer bash "$PREFLIGHT" --json --session-marker "$MARKER" --repo-dir "$NONGIT")
assert_eq "second call: ran=False" "$(json_field "$OUT2" ran)" "False"
assert_eq "short_circuit_reason=marker-present" \
  "$(json_field "$OUT2" short_circuit_reason)" "marker-present"

# --- Test 5: Contributor with marker does NOT touch the marker ---
echo ""
echo "Test 5: Contributor role does not touch session marker"
CONTRIB_MARKER="$TEST_DIR/contrib-marker"
LORE_ROLE=contributor bash "$PREFLIGHT" --json --session-marker "$CONTRIB_MARKER" --repo-dir "$NONGIT" >/dev/null
if [[ -f "$CONTRIB_MARKER" ]]; then
  echo "  FAIL: contributor invocation created marker — should be a true no-op"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: contributor invocation left marker absent"
  PASS=$((PASS + 1))
fi

# --- Test 6: Exit code is 0 even on warning ---
echo ""
echo "Test 6: Exit code is 0 on warning (warn, don't block)"
EXIT=0
LORE_ROLE=maintainer bash "$PREFLIGHT" --repo-dir "$NONGIT" >/dev/null 2>&1 || EXIT=$?
assert_eq "exit=0 even with non-git warning" "$EXIT" "0"

# --- Test 7: Usage error on unknown flag ---
echo ""
echo "Test 7: Unknown flag exits 1"
EXIT=0
bash "$PREFLIGHT" --no-such-flag >/dev/null 2>&1 || EXIT=$?
assert_eq "unknown flag exits 1" "$EXIT" "1"

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
