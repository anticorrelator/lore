#!/usr/bin/env bash
# test_task_completed_fidelity.sh — Tests for the fidelity-validator splice
# inside scripts/task-completed-capture-check.sh (W06 Phase 2 task #5).
#
# Verifies:
#   1. Worker payload + structured Observations + missing fidelity artifact +
#      ALL THREE sentinels present → exit 2 (validator blocks).
#   2. Researcher (Explore) payload → exit 0 (applicability guard; Explore
#      branch never reaches the fidelity splice).
#   3. Pre-F0 payload (no template_version) → exit 0 with legacy warning
#      (existing backwards-compat preserved; fidelity check skipped).
#   4. Worker payload + structured Observations + warn-only mode (one sentinel
#      missing) → exit 0 (validator emits warn, hook continues).
#   5. Worker payload + valid aligned fidelity artifact → exit 0 (validator
#      passes, hook continues to its own pass).
#   6. Validator script missing → exit 0 (defensive fail-open in the hook
#      wrapper, preserving live-session safety).
#   7. Team-lead payload → exit 0 (team-lead branch bypasses both
#      structured-report check and fidelity splice).
#
# Each test runs in a fresh temp HOME with a synthetic team config and a
# scratch KDIR so no real session state is touched.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/task-completed-capture-check.sh"
VALIDATOR="$REPO_DIR/scripts/validate-fidelity-artifact.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT is not executable" >&2; exit 1
fi
if [[ ! -x "$VALIDATOR" ]]; then
  echo "FAIL: $VALIDATOR is not executable" >&2; exit 1
fi

PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
SLUG="fix-fidelity"
TEAM_NAME="impl-$SLUG"
SCRATCH_REPO="$TEST_DIR/repo"

mkdir -p "$KDIR/_work/$SLUG/_fidelity" "$KDIR/_work/$SLUG/_amendments"
mkdir -p "$SCRATCH_REPO/agents" "$SCRATCH_REPO/skills/implement"
mkdir -p "$TEST_DIR/.claude/teams/$TEAM_NAME"

cat > "$TEST_DIR/.claude/teams/$TEAM_NAME/config.json" <<'EOF'
{
  "members": [
    {"name": "worker-1", "agentType": "general-purpose"},
    {"name": "researcher-1", "agentType": "Explore"},
    {"name": "team-lead", "agentType": "team-lead"}
  ]
}
EOF

# All three sentinels — used by tests that expect blocking mode.
cat >"$SCRATCH_REPO/agents/fidelity-judge.md" <<'EOF'
W06_FIDELITY_JUDGE_TEMPLATE_READY
EOF
cat >"$SCRATCH_REPO/skills/implement/SKILL.md" <<'EOF'
W06_FIDELITY_STEP4_INTEGRATED
EOF
cat >"$SCRATCH_REPO/agents/worker.md" <<'EOF'
W06_FIDELITY_ACK_WAIT
EOF

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Build a payload with structured Observations + Template-version line so the
# tier-section check passes and we reach the fidelity splice.
build_worker_payload() {
  local subject="$1"
  python3 -c "
import json
desc = '''$subject

Template-version: ec44f393954d

**Observations:**
- claim: did a thing
  file: foo.py
  line_range: 1-10
  falsifier: foo not present
  significance: medium
'''
print(json.dumps({
    'team_name': '$TEAM_NAME',
    'task_description': desc,
    'agent_name': 'worker-1',
}))
"
}

build_researcher_payload() {
  local subject="$1"
  python3 -c "
import json
desc = '''$subject

Template-version: ec44f393954d

**Assertions:**
- claim: did a thing
  file: foo.py
  line_range: 1-10
  falsifier: foo not present
  significance: medium
'''
print(json.dumps({
    'team_name': '$TEAM_NAME',
    'task_description': desc,
    'agent_name': 'researcher-1',
}))
"
}

build_legacy_payload() {
  local subject="$1"
  python3 -c "
import json
desc = '''$subject

Some prose body without a template_version line.
'''
print(json.dumps({
    'team_name': '$TEAM_NAME',
    'task_description': desc,
    'agent_name': 'worker-1',
}))
"
}

build_teamlead_payload() {
  python3 -c "
import json
print(json.dumps({
    'team_name': '$TEAM_NAME',
    'task_description': 'team-lead status update',
    'agent_name': 'team-lead',
}))
"
}

artifact_key_for() {
  local slug="$1" subject="$2"
  printf '%s:%s' "$slug" "$subject" \
    | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])"
}

reset_artifacts() {
  rm -f "$KDIR/_work/$SLUG/_fidelity/"* "$KDIR/_work/$SLUG/_amendments/"* 2>/dev/null || true
}

# run_hook — invoke the hook with payload + the sentinel/KDIR env overrides
# the validator reads. Captures exit, stdout, stderr.
run_hook() {
  local payload="$1" sentinel_mode="${2:-blocking}"

  local judge_path="$SCRATCH_REPO/agents/fidelity-judge.md"
  local impl_path="$SCRATCH_REPO/skills/implement/SKILL.md"
  local worker_path="$SCRATCH_REPO/agents/worker.md"
  case "$sentinel_mode" in
    warn-missing-judge) judge_path="$SCRATCH_REPO/agents/__nope__.md" ;;
  esac

  local rc=0
  printf '%s' "$payload" | \
    HOME="$TEST_DIR" \
    LORE_KNOWLEDGE_DIR="$KDIR" \
    LORE_FIDELITY_JUDGE_TEMPLATE="$judge_path" \
    LORE_FIDELITY_IMPLEMENT_SKILL="$impl_path" \
    LORE_FIDELITY_WORKER_TEMPLATE="$worker_path" \
    bash "$SCRIPT" >/dev/null 2>"$TEST_DIR/stderr" || rc=$?
  _STDERR=$(cat "$TEST_DIR/stderr")
  _EXIT=$rc
}

assert_exit() {
  local label="$1" expected="$2"
  if [[ "$_EXIT" == "$expected" ]]; then
    echo "  PASS: $label (exit=$_EXIT)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected exit: $expected"
    echo "    Got exit: $_EXIT"
    echo "    stderr: $_STDERR"
    FAIL=$((FAIL + 1))
  fi
}

assert_stderr_contains() {
  local label="$1" expected="$2"
  if echo "$_STDERR" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected stderr to contain: $expected"
    echo "    Got: $_STDERR"
    FAIL=$((FAIL + 1))
  fi
}

# A minimal valid aligned fidelity artifact — used by test 5.
write_aligned_artifact() {
  local subject="$1"
  local key
  key=$(artifact_key_for "$SLUG" "$subject")
  python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$key',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'aligned',
    'evidence': {
        'rationale': 'Diff matches plan.',
        'claim_ids_used': [],
        'diff_quote': 'foo.py:1 added',
        'plan_quote': 'plan.md:10 add',
    },
    'trigger': 'random-p0.2',
    'timestamp': '2026-04-24T18:00:00Z',
}, indent=2))
" > "$KDIR/_work/$SLUG/_fidelity/$key.json"
}

echo "=== task-completed-capture-check.sh fidelity-splice tests ==="
echo

# --------- Test 1: worker + missing artifact + all sentinels → exit 2 ---------
reset_artifacts
SUBJ="t1 worker missing artifact"
run_hook "$(build_worker_payload "$SUBJ")" "blocking"
assert_exit "test 1: worker + missing artifact (blocking) → exit 2" 2
assert_stderr_contains "test 1: stderr names fidelity check" "Fidelity artifact check failed"
assert_stderr_contains "test 1: validator diagnostic surfaced" "no fidelity artifact"

# --------- Test 2: researcher payload → exit 0 (applicability bypass) ---------
reset_artifacts
SUBJ="t2 researcher bypass"
run_hook "$(build_researcher_payload "$SUBJ")" "blocking"
assert_exit "test 2: researcher payload → exit 0" 0
# The Explore branch should never reach the fidelity splice; assert no fidelity-block
# stderr appears.
if echo "$_STDERR" | grep -qF "Fidelity artifact check failed"; then
  echo "  FAIL: test 2: researcher branch incorrectly invoked fidelity check"
  echo "    stderr: $_STDERR"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: test 2: researcher branch did not invoke fidelity check"
  PASS=$((PASS + 1))
fi

# --------- Test 3: pre-F0 payload (no template_version) → exit 0 + warning ----
reset_artifacts
SUBJ="t3 legacy no template_version"
run_hook "$(build_legacy_payload "$SUBJ")" "blocking"
assert_exit "test 3: pre-F0 payload → exit 0 (backwards-compat preserved)" 0
# The existing legacy warning emits via execution-log fallback (or stderr); the
# fidelity splice is bypassed entirely because the early `report_has_template_version`
# gate exits before the case dispatch.
if echo "$_STDERR" | grep -qF "Fidelity artifact check failed"; then
  echo "  FAIL: test 3: legacy report incorrectly invoked fidelity check"
  echo "    stderr: $_STDERR"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: test 3: legacy report did not invoke fidelity check"
  PASS=$((PASS + 1))
fi

# --------- Test 4: worker + warn-only mode (sentinel missing) → exit 0 -------
reset_artifacts
SUBJ="t4 warn-mode missing artifact"
run_hook "$(build_worker_payload "$SUBJ")" "warn-missing-judge"
assert_exit "test 4: worker + warn-only mode + missing artifact → exit 0" 0
assert_stderr_contains "test 4: warn diagnostic surfaced through hook" "warn:"

# --------- Test 5: worker + aligned artifact → exit 0 ------------------------
reset_artifacts
SUBJ="t5 worker aligned artifact"
write_aligned_artifact "$SUBJ"
run_hook "$(build_worker_payload "$SUBJ")" "blocking"
assert_exit "test 5: worker + aligned artifact → exit 0" 0
if echo "$_STDERR" | grep -qF "Fidelity artifact check failed"; then
  echo "  FAIL: test 5: aligned artifact unexpectedly blocked"
  echo "    stderr: $_STDERR"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: test 5: aligned artifact did not surface fidelity-block"
  PASS=$((PASS + 1))
fi

# --------- Test 6: validator missing → exit 0 (defensive fail-open) ----------
# Stage a temporary scripts dir without the validator and run the hook from it.
reset_artifacts
SUBJ="t6 validator missing"
TEMP_SCRIPT_DIR=$(mktemp -d)
# Symlink every script except validate-fidelity-artifact.sh into the temp dir.
for f in "$REPO_DIR/scripts"/*; do
  base=$(basename "$f")
  [[ "$base" == "validate-fidelity-artifact.sh" ]] && continue
  ln -sf "$f" "$TEMP_SCRIPT_DIR/$base"
done
TEMP_HOOK="$TEMP_SCRIPT_DIR/task-completed-capture-check.sh"
[[ -L "$TEMP_HOOK" ]] || { echo "FAIL: setup test 6"; exit 1; }
rc=0
printf '%s' "$(build_worker_payload "$SUBJ")" | \
  HOME="$TEST_DIR" \
  LORE_KNOWLEDGE_DIR="$KDIR" \
  LORE_FIDELITY_JUDGE_TEMPLATE="$SCRATCH_REPO/agents/fidelity-judge.md" \
  LORE_FIDELITY_IMPLEMENT_SKILL="$SCRATCH_REPO/skills/implement/SKILL.md" \
  LORE_FIDELITY_WORKER_TEMPLATE="$SCRATCH_REPO/agents/worker.md" \
  bash "$TEMP_HOOK" >/dev/null 2>"$TEST_DIR/stderr" || rc=$?
_STDERR=$(cat "$TEST_DIR/stderr")
_EXIT=$rc
rm -rf "$TEMP_SCRIPT_DIR"
assert_exit "test 6: validator script missing → exit 0 (fail-open)" 0
if echo "$_STDERR" | grep -qF "Fidelity artifact check failed"; then
  echo "  FAIL: test 6: hook blocked despite missing validator"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: test 6: hook did not block when validator absent"
  PASS=$((PASS + 1))
fi

# --------- Test 7: team-lead payload → exit 0 -------------------------------
reset_artifacts
run_hook "$(build_teamlead_payload)" "blocking"
assert_exit "test 7: team-lead payload → exit 0" 0
if echo "$_STDERR" | grep -qF "Fidelity artifact check failed"; then
  echo "  FAIL: test 7: team-lead branch invoked fidelity check"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: test 7: team-lead branch did not invoke fidelity check"
  PASS=$((PASS + 1))
fi

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0
exit 1
