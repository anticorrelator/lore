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

echo "Test 1: Startup and discovery route through read-only verbs"
assert_contains "startup uses spec start" 'START=$(lore spec start "${START_ARGS[@]}")'
assert_contains "discovery uses spec discover" 'DISCOVERY=$(lore spec discover "$SLUG" --json)'
assert_contains "startup exposes the closed plan-state vocabulary" '`plan_state=synthesis-complete`'
assert_contains "discovery keeps applicability false" 'it never combines rankings or emits `matched`, `binding`, or `applicability` fields'
assert_not_contains "legacy hand-run work resolver removed" 'if RESULT=$(lore work resolve "$INPUT"'

echo ""
echo "Test 2: Full dispatch is prepared by open and executed by the lead"
assert_contains "full branch invokes spec open" 'DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)'
assert_contains "open status vocabulary is visible" '`created | reused | recovered | replaced`'
assert_contains "native dispatch remains lead owned" 'Execute the returned directives in ordinal order.'
assert_contains "codex teardown matches live adapter" '`TaskUpdate status=completed`'
assert_not_contains "no direct researcher spawn recipe remains" 'bash "$ADAPTER" spawn researcher'

echo ""
echo "Test 3: Short branch search still declares scale"
assert_contains "short branch lore search declares scale-set" 'lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 5'

echo ""
echo "Test 4: Ceremony outcomes are filed before terminal finalize"
assert_contains "outcome verb is explicit" 'lore spec outcome "$SLUG"'
assert_contains "closed outcome vocabulary is visible" '`completed | failed | skipped | needs-decision`'
assert_contains "outcome evidence requires source plan hash" '"source_plan_sha256": "<sha256 of the plan the evaluator read>"'
post_line=$(grep -n '^### Step 5.5: Post-plan ceremony evaluation' "$SPEC_SKILL" | cut -d: -f1)
final_line=$(grep -n '^### Step 5.6: Finalize through the spec verb' "$SPEC_SKILL" | cut -d: -f1)
if [[ -n "$post_line" && -n "$final_line" && "$post_line" -lt "$final_line" ]]; then
  echo "  PASS: post-plan ceremony precedes terminal finalize"
  PASS=$((PASS + 1))
else
  echo "  FAIL: post-plan ceremony must precede terminal finalize"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
