#!/usr/bin/env bash
# test_spec_protocol_regressions.sh — Lint regressions in /spec prompt text
# that previously caused Claude harness setup failures before code ran.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_PROSE=("$REPO_DIR/skills/spec/SKILL.md" "$REPO_DIR/skills/spec/commissioning.md")

PASS=0
FAIL=0

assert_contains() {
  local label="$1" pattern="$2"
  if grep -qF -- "$pattern" "${SPEC_PROSE[@]}"; then
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
  if grep -qF -- "$pattern" "${SPEC_PROSE[@]}"; then
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

echo "Test 1: Startup and discovery route through read-only verbs"
assert_contains "startup uses spec start" 'START=$(lore spec start "${START_ARGS[@]}")'
assert_contains "discovery uses spec discover" 'DISCOVERY=$(lore spec discover "$SLUG" --json)'
assert_contains "startup exposes the closed plan-state vocabulary" '`plan_state=synthesis-complete`'
assert_not_contains "legacy hand-run work resolver removed" 'if RESULT=$(lore work resolve "$INPUT"'

echo ""
echo "Test 2: Commissioned dispatch is prepared by open and executed by the seat"
assert_contains "commissioning invokes spec open" 'DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)'
assert_not_contains "no direct researcher spawn recipe remains" 'bash "$ADAPTER" spawn researcher'

echo ""
echo "Test 3: Stale verification flag spellings stay gone"
assert_not_contains "stale claim-scope spelling removed" '--claim-scope'
assert_not_contains "stale dispute-reason spelling removed" '--dispute-reason'
assert_not_contains "no unowned contradiction route remains" 'consumption-contradictions.jsonl'

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
