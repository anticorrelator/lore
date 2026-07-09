#!/usr/bin/env bash
# Guard the consumption-contradiction lifecycle vocabulary across /retro prose.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/retro/SKILL.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL"; then pass "$label"; else fail "$label"; fi
}

echo "=== /retro consumption-contradiction vocabulary ==="

assert_contains "canonical lifecycle trio is direct verdict vocabulary" 'pending | verified | contradicted'
assert_contains "terminal pair is direct verdict vocabulary" 'verified | contradicted'
assert_contains "row schema names contradicted" '`status` — `pending | verified | contradicted`'
assert_contains "verification denominator names contradicted" 'status ∈ {verified, contradicted}'
assert_contains "report shape names contradicted" 'C contradicted'
assert_contains "drift guard retains retired rejected as a detection token" '`routed`, `rejected`, `accepted`, `declined`, `remediated`'
assert_contains "drift guard allows only the canonical trio" '{pending, verified, contradicted}'
assert_contains "updater remains the terminal-state writer" 'consumption-contradiction-update-status.sh'

BODY=$(awk '/^### 2b\.7:/ {capture=1; next} capture && /^### / {exit} capture {print}' "$SKILL")
if [[ "$BODY" == *'pending | verified | rejected'* ]]; then
  fail "Step 2b.7 carries no retired rejected lifecycle trio"
else
  pass "Step 2b.7 carries no retired rejected lifecycle trio"
fi
if [[ "$BODY" == *'J rejected'* ]]; then
  fail "Step 2b.7 report shape carries no rejected count"
else
  pass "Step 2b.7 report shape carries no rejected count"
fi

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
