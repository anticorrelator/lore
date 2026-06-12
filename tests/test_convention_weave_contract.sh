#!/usr/bin/env bash
# test_convention_weave_contract.sh — Pin the convention-weave protocol tokens
# shared across /spec weave vocabulary, the worker report template, the
# TaskCompleted hook validator, and the check-report matcher.
#
# Only true protocol constants are pinned: tokens parsed by code or compared
# verbatim across surfaces. Surrounding prose is deliberately NOT pinned —
# wording may drift freely as long as these tokens survive.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_SKILL="$REPO_DIR/skills/spec/SKILL.md"
WORKER_MD="$REPO_DIR/agents/worker.md"
CHECK_SH="$REPO_DIR/scripts/impl-check-report.sh"
VALIDATE_PY="$REPO_DIR/scripts/validate-structured-report.py"

PASS=0
FAIL=0

assert_file_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Convention Weave Contract Tests ==="
echo ""

echo "Test 1: /spec weave vocabulary names the identifiers the handoff keys on"
# If "constraint clause" drifts, /spec stops naming the channel that delivers
# woven norms, and tasks stop carrying the imperative form workers disposition.
assert_file_contains "spec SKILL keeps the 'constraint clause' weave term" \
  "$SPEC_SKILL" "constraint clause"
# If "stable label" drifts, /spec no longer instructs the weave to name norms
# by entry slug, and worker dispositions stop matching the lead's woven list.
assert_file_contains "spec SKILL keeps the 'stable label' weave term" \
  "$SPEC_SKILL" "stable label"

echo ""
echo "Test 2: worker template bullet forms match the matcher's regex anchor"
# If the honored bullet form drifts, worker reports stop matching the
# '- (honored|diverged):' anchor impl-check-report.sh parses, and every
# disposition surfaces as a missing-norm finding.
assert_file_contains "worker.md keeps the honored bullet form" \
  "$WORKER_MD" "- honored: <norm-label>"
# Same anchor for the diverged form; drift also loses the dash-separated
# rationale the lead assesses.
assert_file_contains "worker.md keeps the diverged bullet form" \
  "$WORKER_MD" "- diverged: <norm-label> — <why>"
# The matcher side of the same anchor: if the regex drifts, conforming
# worker reports stop being parsed.
assert_file_contains "matcher keeps the disposition bullet regex anchor" \
  "$CHECK_SH" "(honored|diverged):"

echo ""
echo "Test 3: the 'none in scope' sentinel is shared verbatim"
# The matcher string-compares the section body against this sentinel; if
# either side drifts, a no-norms report becomes a missing-disposition finding.
assert_file_contains "worker.md keeps the 'none in scope' sentinel" \
  "$WORKER_MD" "none in scope"
assert_file_contains "matcher compares against the 'none in scope' sentinel" \
  "$CHECK_SH" '== "none in scope"'

echo ""
echo "Test 4: the 'Convention handling' section name is shared verbatim"
# The TaskCompleted hook (via validate-structured-report.py) matches this
# heading literally; if the template's heading drifts, every worker report
# is rejected at the gate.
assert_file_contains "worker.md keeps the Convention handling heading" \
  "$WORKER_MD" "**Convention handling:**"
assert_file_contains "hook validator keeps the Convention handling literal" \
  "$VALIDATE_PY" 'CONVENTION_HANDLING_HEADING = "Convention handling"'
# The matcher locates the same section by name; drift here silently skips
# the completeness comparison.
assert_file_contains "matcher keys on the Convention handling section name" \
  "$CHECK_SH" '"Convention handling"'

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
