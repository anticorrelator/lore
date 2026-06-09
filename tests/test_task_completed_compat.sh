#!/usr/bin/env bash
# test_task_completed_compat.sh — Regression tests for the backwards-compat gate
# in scripts/task-completed-capture-check.sh (task #23).
#
# Verifies:
#   1. Legacy reports (no template_version): exit 0 with a warning.
#   2. Post-F0 reports (with template_version) + no structured observations: exit 2 (hard-fail).
#   3. Post-F0 reports (with template_version) + structured observations: exit 0.
#   4. Team-lead reports always pass regardless of template_version presence.
#   5. Empty/non-team input short-circuits to exit 0.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/task-completed-capture-check.sh"
TEST_DIR=$(mktemp -d)
TEAM_CONFIG_DIR="$TEST_DIR/teams/impl-test-slug"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
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

# Point the hook at a fake team config so it can resolve agentType.
mkdir -p "$TEAM_CONFIG_DIR"
cat > "$TEAM_CONFIG_DIR/config.json" << 'EOF'
{
  "members": [
    {"name": "worker-1", "agentType": "general-purpose"},
    {"name": "researcher-1", "agentType": "Explore"},
    {"name": "team-lead", "agentType": "team-lead"}
  ]
}
EOF

# run_hook — invoke the hook with the given JSON input. Captures stdout, stderr,
# and exit code. Overrides HOME so the hook's team-config lookup finds our
# fixture at $TEST_DIR/teams/ (paralleling $HOME/.claude/teams/).
run_hook() {
  local payload="$1"
  local exit_code=0
  mkdir -p "$TEST_DIR/.claude/teams"
  cp -R "$TEST_DIR/teams/impl-test-slug" "$TEST_DIR/.claude/teams/impl-test-slug" 2>/dev/null || true
  _STDERR_FILE=$(mktemp)
  _STDOUT_FILE=$(mktemp)
  HOME="$TEST_DIR" printf '%s' "$payload" | bash "$SCRIPT" >"$_STDOUT_FILE" 2>"$_STDERR_FILE" || exit_code=$?
  _EXIT="$exit_code"
  _STDOUT=$(cat "$_STDOUT_FILE")
  _STDERR=$(cat "$_STDERR_FILE")
  rm -f "$_STDERR_FILE" "$_STDOUT_FILE"
}

echo "=== Task-Completed Backwards-Compat Gate Tests ==="
echo ""

# =============================================
# Test 1: Legacy worker report (no template_version) → exit 0 + warning
# =============================================
echo "Test 1: Legacy worker report — no template_version → pass with warning"

LEGACY_REPORT='**Task:** Old work
**Changes:**
- some file: something
**Observations:** No structured entries here, just prose.
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$LEGACY_REPORT")

run_hook "$PAYLOAD"
assert_eq "legacy report exits 0 (pass)" "$_EXIT" "0"
# The warning may land in stderr (fallback path) or in the work-item's
# execution-log (slug path). We accept either.
if echo "$_STDERR" | grep -qF "LEGACY REPORT" || [[ -f "$TEST_DIR/_work/test-slug/execution-log.md" ]]; then
  echo "  PASS: legacy warning emitted (stderr or execution-log)"
  PASS=$((PASS + 1))
else
  # The script derived a slug but write-execution-log.sh can't resolve KDIR in
  # this test sandbox, so the emit_legacy_warning fallback must fire (stderr).
  # Accept silence IF neither path was exercisable; fail otherwise.
  # In practice, with no KDIR the fallback fires and we see "warning:" on stderr.
  if echo "$_STDERR" | grep -qF "warning:"; then
    echo "  PASS: legacy warning visible on stderr (fallback path)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: no legacy warning surfaced"
    echo "    stderr: $_STDERR"
    FAIL=$((FAIL + 1))
  fi
fi

# =============================================
# Test 2: Post-F0 worker report (template_version present, no structured obs) → exit 2
# =============================================
echo ""
echo "Test 2: Post-F0 worker — template_version + no structured obs → hard-fail (exit 2)"

POST_F0_BAD='**Task:** New F0-era work
template_version: abc123def456
**Observations:** Just prose, no claim: field.
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$POST_F0_BAD")

run_hook "$PAYLOAD"
assert_eq "post-F0 unstructured report exits 2 (hard-fail)" "$_EXIT" "2"
assert_contains "error names template_version requirement path" "$_STDERR" "Update the task description"

# =============================================
# Test 3: Post-F0 worker report (template_version + structured obs) → exit 0
# =============================================
echo ""
echo "Test 3: Post-F0 worker — template_version + structured observation → pass"

POST_F0_GOOD='**Task:** New F0-era work
template_version: abc123def456
**Observations:**
- claim: "The hook gate fires only on post-F0 reports."
  file: /abs/path/to/scripts/task-completed-capture-check.sh
  line_range: 90-110
  falsifier: "A pre-F0 report (no template_version) exiting 2 instead of 0."
  significance: medium
**Convention handling:**
- none in scope
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$POST_F0_GOOD")

run_hook "$PAYLOAD"
assert_eq "post-F0 structured report exits 0 (pass)" "$_EXIT" "0"

# =============================================
# Test 4: Team-lead reports always pass
# =============================================
echo ""
echo "Test 4: Team-lead report — no template_version, no structure → pass"

LEAD_REPORT='**Task:** Synthesis
Some lead-level prose.'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "team-lead"
}
print(json.dumps(d))
' "$LEAD_REPORT")

run_hook "$PAYLOAD"
assert_eq "team-lead exits 0" "$_EXIT" "0"

# =============================================
# Test 5: Non-team task → short-circuit exit 0
# =============================================
echo ""
echo "Test 5: Non-team task (no team_name) → short-circuit pass"

PAYLOAD='{"task_description": "Some task", "agent_name": "somebody"}'
run_hook "$PAYLOAD"
assert_eq "non-team task exits 0" "$_EXIT" "0"

# =============================================
# Test 6: Legacy researcher report → exit 0 + warning (not exit 2)
# =============================================
echo ""
echo "Test 6: Legacy researcher — no template_version → pass with warning"

LEGACY_RESEARCHER='**Question:** ?
**Findings:** Some prose findings.
**Assertions:** Just prose, no claim: field.'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "spec-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "researcher-1"
}
print(json.dumps(d))
' "$LEGACY_RESEARCHER")

# spec- prefix; team config lookup needs corresponding fixture.
mkdir -p "$TEST_DIR/.claude/teams/spec-test-slug"
cp "$TEAM_CONFIG_DIR/config.json" "$TEST_DIR/.claude/teams/spec-test-slug/config.json"

run_hook "$PAYLOAD"
assert_eq "legacy researcher exits 0" "$_EXIT" "0"

# =============================================
# Test 7: Post-F0 worker, structured obs + Convention handling → exit 0
# =============================================
echo ""
echo "Test 7: Post-F0 worker — template_version + structured obs + Convention handling → pass"

CONV_GOOD='**Task:** Convention work
template_version: abc123def456
**Observations:**
- claim: "The convention field rides the Observations validation path."
  file: /abs/path/to/scripts/validate-structured-report.py
  line_range: 130-145
  falsifier: "An Observations-path report without the field passing."
  significance: high
**Convention handling:**
- honored: script-first-skill-design
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$CONV_GOOD")

run_hook "$PAYLOAD"
assert_eq "worker with Convention handling exits 0 (pass)" "$_EXIT" "0"

# =============================================
# Test 8: Post-F0 worker, structured obs but NO Convention handling → exit 2
# =============================================
echo ""
echo "Test 8: Post-F0 worker — template_version + structured obs, missing Convention handling → hard-fail (exit 2)"

CONV_MISSING='**Task:** Convention work
template_version: abc123def456
**Observations:**
- claim: "A structured observation with no convention disposition."
  file: /abs/path/to/scripts/validate-structured-report.py
  line_range: 130-145
  falsifier: "The report passing despite the missing section."
  significance: high
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$CONV_MISSING")

run_hook "$PAYLOAD"
assert_eq "worker missing Convention handling exits 2 (hard-fail)" "$_EXIT" "2"
assert_contains "error names Convention handling requirement" "$_STDERR" "Convention handling"

# =============================================
# Test 9: Post-F0 worker, Convention handling present but empty → exit 2
# =============================================
echo ""
echo "Test 9: Post-F0 worker — Convention handling heading present but empty → hard-fail (exit 2)"

CONV_EMPTY='**Task:** Convention work
template_version: abc123def456
**Observations:**
- claim: "A structured observation with an empty convention section."
  file: /abs/path/to/scripts/validate-structured-report.py
  line_range: 130-145
  falsifier: "The report passing despite the empty section."
  significance: high
**Convention handling:**
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$CONV_EMPTY")

run_hook "$PAYLOAD"
assert_eq "worker empty Convention handling exits 2 (hard-fail)" "$_EXIT" "2"

# =============================================
# Test 10: Legacy worker (no template_version) without Convention handling → pass
# =============================================
echo ""
echo "Test 10: Legacy worker — no template_version, no Convention handling → pass (backward-compat path intact)"

LEGACY_NO_CONV='**Task:** Old work
**Changes:**
- some file: something
**Observations:** No structured entries here, just prose.
**Blockers:** none'

PAYLOAD=$(python3 -c '
import json, sys
d = {
  "team_name": "impl-test-slug",
  "task_description": sys.argv[1],
  "agent_name": "worker-1"
}
print(json.dumps(d))
' "$LEGACY_NO_CONV")

run_hook "$PAYLOAD"
assert_eq "legacy worker without Convention handling exits 0 (pass)" "$_EXIT" "0"

# =============================================
# Summary
# =============================================
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
