#!/usr/bin/env bash
# test_validate_fidelity_artifact.sh — Tests for scripts/validate-fidelity-artifact.sh
#
# Covers (from plan.md § Phase 2 cases i–ix and the applicability guard):
#   i.    no fidelity artifact → block
#   ii.   kind: exempt → allow
#   iii.  verdict: aligned → allow
#   iv.   verdict: drifted, no branch artifact → block
#   v.    verdict: contradicts, no branch artifact → block
#   vi.   verdict: unjudgeable, no branch artifact → block
#   vii.  verdict: drifted + amendment file → allow
#   viii. verdict: contradicts + amendment file → allow
#   ix.   verdict: unjudgeable + amendment file ONLY → block (paper-over guard)
#   x.    verdict: unjudgeable + escalation file → allow
#   xi.   superseded fresh-aligned verdict → allow
#   xii.  pre-F0 / no template_version handling is owned by the sibling hook;
#          this validator runs only in impl-* contexts and exits 0 for non-impl-*
#          payloads (applicability guard tested as case xii)
#   xiii. researcher (Explore) report inside impl-* team → allow (applicability)
#
#   Sentinel mode tests:
#     a. one sentinel missing → warn-only (exit 0 even when artifact missing)
#     b. all three sentinels present → blocking (exit 2 when artifact missing)
#
# All cases run in a fresh temp $LORE_KNOWLEDGE_DIR so no real knowledge dir is
# touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/validate-fidelity-artifact.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "FAIL: $SCRIPT is not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

# ---------- Setup ----------

TEST_ROOT=$(mktemp -d)
KDIR="$TEST_ROOT/knowledge"
SLUG="06-fixture"
SCRATCH_REPO="$TEST_ROOT/repo"
mkdir -p "$KDIR/_work/$SLUG/_fidelity" "$KDIR/_work/$SLUG/_amendments"
mkdir -p "$SCRATCH_REPO/agents" "$SCRATCH_REPO/skills/implement"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# Pre-create sentinel files (toggled per test by writing/removing them).
cat >"$SCRATCH_REPO/agents/fidelity-judge.md" <<'EOF'
<!-- W06_FIDELITY_JUDGE_TEMPLATE_READY -->
EOF
cat >"$SCRATCH_REPO/skills/implement/SKILL.md" <<'EOF'
W06_FIDELITY_STEP4_INTEGRATED
EOF
cat >"$SCRATCH_REPO/agents/worker.md" <<'EOF'
W06_FIDELITY_ACK_WAIT
EOF

# ---------- Helpers ----------

# Compute artifact_key for a given subject — mirrors the validator's derive_artifact_key.
artifact_key_for() {
  local slug="$1" subject="$2"
  printf '%s:%s' "$slug" "$subject" \
    | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode('utf-8')).hexdigest()[:12])"
}

# Run validator with a given hook payload and capture exit + stderr.
# Args: 1=task_subject (becomes the first non-empty line of task_description)
#       2=mode ("blocking" | "warn-missing-judge" | "warn-missing-implement" | "warn-missing-worker")
run_validator() {
  local subject="$1" mode="${2:-blocking}"

  # Build sentinel paths per mode
  local judge_path="$SCRATCH_REPO/agents/fidelity-judge.md"
  local impl_path="$SCRATCH_REPO/skills/implement/SKILL.md"
  local worker_path="$SCRATCH_REPO/agents/worker.md"
  case "$mode" in
    warn-missing-judge)     judge_path="$SCRATCH_REPO/agents/__nope__.md" ;;
    warn-missing-implement) impl_path="$SCRATCH_REPO/skills/__nope__.md" ;;
    warn-missing-worker)    worker_path="$SCRATCH_REPO/agents/__nope__.md" ;;
  esac

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'team_name': 'impl-$SLUG',
    'task_description': '''$subject

Some other content here.''',
    'agent_name': 'worker-1',
}))
")

  printf '%s' "$payload" | LORE_KNOWLEDGE_DIR="$KDIR" \
    LORE_FIDELITY_JUDGE_TEMPLATE="$judge_path" \
    LORE_FIDELITY_IMPLEMENT_SKILL="$impl_path" \
    LORE_FIDELITY_WORKER_TEMPLATE="$worker_path" \
    bash "$SCRIPT" 2>&1
  return $?
}

write_artifact() {
  local subject="$1" json="$2"
  local key
  key=$(artifact_key_for "$SLUG" "$subject")
  printf '%s\n' "$json" > "$KDIR/_work/$SLUG/_fidelity/$key.json"
  printf '%s' "$key"
}

write_amendment() {
  local key="$1"
  printf 'amendment body\n' > "$KDIR/_work/$SLUG/_amendments/$key.md"
}

write_escalation() {
  local key="$1"
  printf 'escalation body\n' > "$KDIR/_work/$SLUG/_fidelity/$key.escalation.md"
}

# Reset between tests — clear all per-key files but keep the dirs.
reset_artifacts() {
  rm -f "$KDIR/_work/$SLUG/_fidelity/"* "$KDIR/_work/$SLUG/_amendments/"* 2>/dev/null || true
}

assert_exit() {
  local label="$1" expected="$2" got="$3" out="$4"
  if [[ "$got" == "$expected" ]]; then
    echo "  PASS: $label (exit=$got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected exit: $expected"
    echo "    Got exit: $got"
    [[ -n "$out" ]] && echo "    Output: $out"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" expected="$2" got="$3"
  if echo "$got" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $got"
    FAIL=$((FAIL + 1))
  fi
}

# Build minimal-valid artifacts using the schema-required field set.
# The schema requires kind, artifact_key, phase, worker_template_version,
# judge_template_version, verdict, evidence, trigger, timestamp.
build_aligned_artifact() {
  local key="$1"
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
        'rationale': 'Diff matches plan intent.',
        'claim_ids_used': [],
        'diff_quote': 'file.py:1 added foo',
        'plan_quote': 'plan.md:10 add function foo',
    },
    'trigger': 'random-p0.2',
    'timestamp': '2026-04-24T18:00:00Z',
}, indent=2))
"
}

build_drifted_artifact() {
  local key="$1"
  python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$key',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'drifted',
    'evidence': {
        'rationale': 'Worker changed scope.',
        'claim_ids_used': [],
        'diff_quote': 'file.py:1 also touched bar',
        'plan_quote': 'plan.md:10 only add foo',
    },
    'trigger': 'risk-keyword',
    'timestamp': '2026-04-24T18:00:00Z',
    'correction': {'summary': 'Revert bar; keep foo only'},
}, indent=2))
"
}

build_contradicts_artifact() {
  local key="$1"
  python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$key',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'contradicts',
    'evidence': {
        'rationale': 'Diff violates explicit Verification criterion.',
        'claim_ids_used': [],
        'diff_quote': 'file.py:1 X is not called from Y',
        'plan_quote': 'plan.md:10 Verification: Y must call X',
    },
    'trigger': 'phase-deliverable',
    'timestamp': '2026-04-24T18:00:00Z',
    'correction': {'summary': 'Add call to X from Y'},
}, indent=2))
"
}

build_unjudgeable_artifact() {
  local key="$1"
  python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$key',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'unjudgeable',
    'evidence': {
        'rationale': 'Spec is silent on acceptance criteria.',
        'claim_ids_used': [],
    },
    'trigger': 'random-p0.2',
    'timestamp': '2026-04-24T18:00:00Z',
    'unjudgeable_reason': 'Verification block missing for this task',
    'missing_inputs': ['task_spec'],
    'available_evidence': ['Read diff and worker report; spec was insufficient'],
}, indent=2))
"
}

build_exempt_artifact() {
  local key="$1"
  python3 -c "
import json
print(json.dumps({
    'kind': 'exempt',
    'artifact_key': '$key',
    'phase': 'phase-fixture',
    'exempt_reason': 'Task did not match any mandatory trigger and was not p=0.2 sampled',
    'sampling_trigger': 'unsampled',
    'timestamp': '2026-04-24T18:00:00Z',
}, indent=2))
"
}

# ---------- Tests ----------

echo "=== validate-fidelity-artifact.sh tests (KDIR=$KDIR) ==="
echo

# Case i: no fidelity artifact → block (in blocking mode)
reset_artifacts
out=$(run_validator "task one" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case i: no artifact in blocking mode → exit 2" 2 "$rc" "$out"
assert_contains "case i: diagnostic mentions missing artifact" "no fidelity artifact" "$out"
unset rc

# Case ii: kind: exempt → allow
reset_artifacts
SUBJ="task ii exempt"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_exempt_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case ii: exempt artifact → exit 0" 0 "$rc" "$out"
unset rc

# Case iii: aligned → allow
reset_artifacts
SUBJ="task iii aligned"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_aligned_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case iii: aligned → exit 0" 0 "$rc" "$out"
unset rc

# Case iv: drifted, no branch artifact → block
reset_artifacts
SUBJ="task iv drifted naked"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_drifted_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case iv: drifted (no branch) → exit 2" 2 "$rc" "$out"
assert_contains "case iv: diagnostic mentions branch artifact" "branch artifact" "$out"
unset rc

# Case v: contradicts, no branch artifact → block
reset_artifacts
SUBJ="task v contradicts naked"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_contradicts_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case v: contradicts (no branch) → exit 2" 2 "$rc" "$out"
unset rc

# Case vi: unjudgeable, no branch → block
reset_artifacts
SUBJ="task vi unjudgeable naked"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_unjudgeable_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case vi: unjudgeable (no branch) → exit 2" 2 "$rc" "$out"
assert_contains "case vi: diagnostic asks for escalation" "escalation" "$out"
unset rc

# Case vii: drifted + amendment → allow
reset_artifacts
SUBJ="task vii drifted+amendment"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_drifted_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
write_amendment "$KEY"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case vii: drifted + amendment → exit 0" 0 "$rc" "$out"
unset rc

# Case viii: contradicts + amendment → allow
reset_artifacts
SUBJ="task viii contradicts+amendment"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_contradicts_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
write_amendment "$KEY"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case viii: contradicts + amendment → exit 0" 0 "$rc" "$out"
unset rc

# Case ix: unjudgeable + amendment ONLY → block (D5 paper-over guard)
reset_artifacts
SUBJ="task ix unjudgeable+amendment-only"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_unjudgeable_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
write_amendment "$KEY"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case ix: unjudgeable + amendment-only → exit 2" 2 "$rc" "$out"
assert_contains "case ix: diagnostic mentions paper-over" "paper over" "$out"
unset rc

# Case x: unjudgeable + escalation → allow
reset_artifacts
SUBJ="task x unjudgeable+escalation"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
build_unjudgeable_artifact "$KEY" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
write_escalation "$KEY"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case x: unjudgeable + escalation → exit 0" 0 "$rc" "$out"
unset rc

# Case xi: a fresh non-blocking superseding verdict (drifted → respawned → aligned).
# The acceptance event is the FRESH verdict at _fidelity/<key>.json which is now
# aligned; supersedes carries the old drifted entry. The validator reads the
# current artifact only.
reset_artifacts
SUBJ="task xi superseded-to-aligned"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$KEY',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'aligned',
    'evidence': {
        'rationale': 'After respawn, diff now matches plan.',
        'claim_ids_used': [],
        'diff_quote': 'file.py:1 added foo',
        'plan_quote': 'plan.md:10 add function foo',
    },
    'trigger': 'risk-keyword',
    'timestamp': '2026-04-24T18:30:00Z',
    'supersedes': [{'timestamp': '2026-04-24T18:00:00Z', 'verdict': 'drifted'}],
    'respawn_count': 1,
}, indent=2))
" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case xi: superseded-to-aligned → exit 0" 0 "$rc" "$out"
unset rc

# Case xii applicability guard: spec-* team payload → exit 0 silently
reset_artifacts
out=$(printf '%s' '{"team_name": "spec-foo", "task_description": "ignored", "agent_name": "researcher"}' \
    | LORE_KNOWLEDGE_DIR="$KDIR" \
      LORE_FIDELITY_JUDGE_TEMPLATE="$SCRATCH_REPO/agents/fidelity-judge.md" \
      LORE_FIDELITY_IMPLEMENT_SKILL="$SCRATCH_REPO/skills/implement/SKILL.md" \
      LORE_FIDELITY_WORKER_TEMPLATE="$SCRATCH_REPO/agents/worker.md" \
      bash "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
assert_exit "case xii: spec-* team payload → exit 0" 0 "$rc" "$out"
unset rc

# Case xiii applicability guard: non-team payload (no team_name) → exit 0 silently
out=$(printf '%s' '{"team_name": "", "task_description": "no team", "agent_name": "anon"}' \
    | LORE_KNOWLEDGE_DIR="$KDIR" \
      LORE_FIDELITY_JUDGE_TEMPLATE="$SCRATCH_REPO/agents/fidelity-judge.md" \
      LORE_FIDELITY_IMPLEMENT_SKILL="$SCRATCH_REPO/skills/implement/SKILL.md" \
      LORE_FIDELITY_WORKER_TEMPLATE="$SCRATCH_REPO/agents/worker.md" \
      bash "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
assert_exit "case xiii: empty team_name → exit 0" 0 "$rc" "$out"
unset rc

# Sentinel mode tests — warn-only when any of the three sentinels missing.
# Case a: judge sentinel missing, no artifact → warn-only exit 0 (NOT blocking)
reset_artifacts
out=$(run_validator "task warn judge" "warn-missing-judge") || rc=$?
rc=${rc:-0}
assert_exit "case a: warn-only when judge sentinel missing → exit 0" 0 "$rc" "$out"
assert_contains "case a: stderr carries warn-only diagnostic" "warn:" "$out"
unset rc

# Case b: implement sentinel missing, no artifact → warn-only exit 0
out=$(run_validator "task warn implement" "warn-missing-implement") || rc=$?
rc=${rc:-0}
assert_exit "case b: warn-only when implement sentinel missing → exit 0" 0 "$rc" "$out"
unset rc

# Case c: worker sentinel missing, no artifact → warn-only exit 0
out=$(run_validator "task warn worker" "warn-missing-worker") || rc=$?
rc=${rc:-0}
assert_exit "case c: warn-only when worker sentinel missing → exit 0" 0 "$rc" "$out"
unset rc

# Case d: schema-violating artifact (missing required field) in blocking mode → exit 2
reset_artifacts
SUBJ="task d schema-violation"
KEY=$(artifact_key_for "$SLUG" "$SUBJ")
# Missing the 'evidence' field (required for kind: verdict)
python3 -c "
import json
print(json.dumps({
    'kind': 'verdict',
    'artifact_key': '$KEY',
    'phase': 'phase-fixture',
    'worker_template_version': 'wkr_aaaa1234',
    'judge_template_version': 'jdg_bbbb1234',
    'verdict': 'aligned',
    'trigger': 'random-p0.2',
    'timestamp': '2026-04-24T18:00:00Z',
}))
" > "$KDIR/_work/$SLUG/_fidelity/$KEY.json"
out=$(run_validator "$SUBJ" "blocking") || rc=$?
rc=${rc:-0}
assert_exit "case d: schema-violation → exit 2" 2 "$rc" "$out"
assert_contains "case d: diagnostic mentions schema" "schema" "$out"
unset rc

# Case e: payload with empty task_description → block (cannot derive artifact_key)
out=$(printf '%s' '{"team_name": "impl-fixture", "task_description": "", "agent_name": "worker-1"}' \
    | LORE_KNOWLEDGE_DIR="$KDIR" \
      LORE_FIDELITY_JUDGE_TEMPLATE="$SCRATCH_REPO/agents/fidelity-judge.md" \
      LORE_FIDELITY_IMPLEMENT_SKILL="$SCRATCH_REPO/skills/implement/SKILL.md" \
      LORE_FIDELITY_WORKER_TEMPLATE="$SCRATCH_REPO/agents/worker.md" \
      bash "$SCRIPT" 2>&1) || rc=$?
rc=${rc:-0}
assert_exit "case e: empty task_description → exit 2" 2 "$rc" "$out"
unset rc

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0
exit 1
