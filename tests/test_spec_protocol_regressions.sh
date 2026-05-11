#!/usr/bin/env bash
# test_spec_protocol_regressions.sh — Lint regressions in /spec prompt text
# that previously caused Claude harness setup failures before code ran.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_SKILL="$REPO_DIR/skills/spec/SKILL.md"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" pattern="$2"
  if grep -qF -- "$pattern" "$SPEC_SKILL"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" pattern="$2"
  if grep -qF -- "$pattern" "$SPEC_SKILL"; then
    echo "  FAIL: $label"
    echo "    Forbidden: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== Spec Protocol Regression Tests ==="
echo ""

echo "Test 1: Lore source repo references do not use target knowledge resolver"
assert_contains "spec uses LORE_REPO_DIR for source repo discovery" 'LORE_SOURCE_REPO="$LORE_REPO_DIR"'
assert_contains "full-branch instructions warn against resolve-repo.sh source usage" "Do not use \`resolve-repo.sh\` for this"
assert_not_contains "no resolve-repo.sh /skills exclusion path" 'resolve-repo.sh)/skills/'
assert_not_contains "no resolve-repo.sh /agents exclusion path" 'resolve-repo.sh)/agents/'

echo ""
echo "Test 2: Optional knowledge categories do not fail directory scans"
assert_contains "spec directory scan guards missing category directories" '[[ -d "$dir" ]] && ls "$dir"'
assert_contains "spec states absent categories are zero entries" "absent directories count as zero entries"
assert_not_contains "no single ls call over all optional category dirs" 'ls "$KDIR/preferences/" "$KDIR/conventions/" "$KDIR/cross-cutting-conventions/"'

echo ""
echo "Test 3: Short branch search declares scale"
assert_contains "short branch lore search declares scale-set" 'lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 5'

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
