#!/usr/bin/env bash
# Guard the /retro verification vocabulary: the in-band terms that survive and
# the out-of-band lifecycle terms that must not come back.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/retro/SKILL.md"
PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# The skill is not hard-wrapped today, but flatten anyway: a line break inserted
# inside a pinned phrase would otherwise read as removed vocabulary.
FLAT=$(tr '\n' ' ' < "$SKILL" | tr -s ' ')
SECTION=$(awk '/^#### Verification vocabulary/ {capture=1; next} capture && /^### / {exit} capture {print}' "$SKILL" | tr '\n' ' ' | tr -s ' ')

assert_present() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" ;;
  esac
}

assert_absent() {
  local label="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$label" ;;
    *) pass "$label" ;;
  esac
}

echo "=== /retro verification vocabulary ==="

if [[ -z "${SECTION//[[:space:]]/}" ]]; then
  fail "verification vocabulary section is non-empty"
else
  pass "verification vocabulary section is non-empty"
fi

# Surviving term set: two dispositions, two resolutions, one drift guard.
assert_present "disposition held is named" '`held`' "$SECTION"
assert_present "disposition contradicted is named" '`contradicted`' "$SECTION"
assert_present "corrected rewrites the entry in place" '`corrected` rewrote the entry in place' "$SECTION"
assert_present "disputed leaves a dated marker" '`disputed` left a dated marker' "$SECTION"
assert_present "resolution vocabulary is exactly the terminal pair" 'resolution vocabulary is exactly `corrected | disputed`' "$SECTION"
assert_present "a disputed marker is a settled outcome, never a backlog entry" 'never as queue depth' "$SECTION"
assert_present "retired lifecycle words stay named as drift-detection tokens" '`pending`, `routed`, `verified`, `rejected`, `accepted`, `declined`, and `remediated`' "$SECTION"

# Removed term set: no surface of the skill may describe the out-of-band path.
assert_absent "no settlement vocabulary" 'settlement' "$FLAT"
assert_absent "no Settlement heading" 'Settlement' "$FLAT"
assert_absent "no consumption-contradiction reader" 'consumption-contradiction' "$FLAT"
assert_absent "no contradiction lifecycle source" 'consumer_contradiction_lifecycle' "$FLAT"
assert_absent "no settlement-health fact group" 'settlement_health_inputs' "$FLAT"
assert_absent "no census disposition" 'dormant-census' "$FLAT"
assert_absent "no audit-lag calculation" 'audit_lag' "$FLAT"
assert_absent "no judge-liveness check" 'Judge liveness' "$FLAT"
assert_absent "no sidecar status trio" 'pending | verified | contradicted' "$FLAT"
assert_absent "no routing report shape" 'Consumption contradictions:' "$FLAT"
assert_absent "no sidecar terminal-status writer" 'consumption-contradiction-update-status.sh' "$FLAT"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
