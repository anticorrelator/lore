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
# Isolate the hook itself, including provider selection and canonical writers.
export HOME="$TEST_DIR" LORE_FRAMEWORK=claude-code
export LORE_DATA_DIR="$TEST_DIR/.lore" LORE_KNOWLEDGE_DIR="$TEST_DIR/.lore"
unset LORE_AGENT_DISABLED LORE_LIB_DIR
mkdir -p "$LORE_DATA_DIR"
ln -s "$REPO_DIR/scripts" "$LORE_DATA_DIR/scripts"
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
  printf '%s' "$payload" | bash "$SCRIPT" >"$_STDOUT_FILE" 2>"$_STDERR_FILE" || exit_code=$?
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


# Successful fixture evidence is published by the compiler, binder, report,
# claim and result writers in an isolated copy of this checkout.
python3 - "$REPO_DIR" "$TEST_DIR" <<'COMPILED_TESTS' || FAIL=$((FAIL + 1))
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import yaml

original, temporary = map(Path, sys.argv[1:])
retained = os.environ.get('COMPLETION_COMPAT_FIXTURES')
base = (Path(retained) if retained else temporary / 'compiled').resolve()
base.mkdir(parents=True, exist_ok=False)
repo, home = base / 'checkout', base / 'home'
repo.mkdir(); home.mkdir()
for name in ('scripts', 'adapters', 'agents', 'docs', 'cli', 'skills'):
    shutil.copytree(original / name, repo / name)
store = home / '.lore'
store.mkdir(); (store / 'scripts').symlink_to(repo / 'scripts')
item = store / '_work/fixture'; item.mkdir(parents=True)
(item / '_meta.json').write_text(json.dumps({'title': 'Fixture', 'source_checkout': str(repo)}))
env = {key: value for key, value in os.environ.items() if not key.startswith(('LORE_', 'CLAUDE_'))}
env.update(HOME=str(home), LORE_DATA_DIR=str(store), LORE_KNOWLEDGE_DIR=str(store), LORE_FRAMEWORK='codex')
for key in list(os.environ):
    if key.startswith(('LORE_', 'CLAUDE_')):
        del os.environ[key]
os.environ.update(env)
os.chdir(repo)
sys.path.insert(0, str(repo / 'scripts'))
spec = importlib.util.spec_from_file_location('position_bind', repo / 'scripts/position-bind.py')
binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
from position_compile import compile_position
from packet_builder import build_packet, pointer
api = runpy.run_path(str(repo / 'scripts/work-evidence.py'))
checks, fixtures = [], []


def call(args, data=None, ok=True):
    p = subprocess.run(args, input=data, text=True, cwd=repo, env=env, capture_output=True)
    if ok:
        assert p.returncode == 0, p.stderr + p.stdout
    else:
        assert p.returncode != 0, p.stdout
    return p


call(['git', 'init', '-q'])
call(['git', 'config', 'user.email', 'fixture@example.invalid'])
call(['git', 'config', 'user.name', 'Fixture'])
call(['git', 'add', '.'])
call(['git', 'commit', '-qm', 'Completion fixture source'])
source_sha = call(['git', 'rev-parse', 'HEAD']).stdout.strip()
plan = '''# Fixture

## Intent Anchor
Validate completion against durable evidence.

**Scope delta:** none

## Tasks

**Merge rationale:** One fixture task.

### Task 1: Check completion
**Deliverable:** Checked completion.
**Files:** `scripts/task-completed-capture-check.sh`
**Close criteria:**
```json
[{"id":"fixture-check","intent":"Exercise real result publication.","argv":["bash","-c","exit 0"],"cwd":".","timeout":10,"expected_exit":0}]
```
- [ ] Check completion [class: mechanical]
'''
(item / 'plan.md').write_text(plan)
(item / 'decisions.json').write_text(json.dumps({
    'anchor_coverage': {'disposition':'covered','by':'fixture','note':'Isolated test data.'},
    'review_requirement': {'disposition':'not-required','by':'fixture','note':'Isolated test data.'},
    'dispatch_decision': {'disposition':'proceed','by':'fixture','note':'Isolated test data.','task_ids':['task-1'],'prior_review_refs':[]}}))


def revise():
    call(['bash', 'scripts/plan-revise.sh', 'fixture', '--decisions', str(item / 'decisions.json')])
    return api['publication_for_dispatch'](str(item), str(store))


publication = revise()
descriptor = compile_position('worker', 'codex', store, None)
guidance = call(['bash', 'scripts/render-dispatch-guidance.sh']).stdout.encode()


def fixture(name, observations='- claim: "None"', tier='none', edit=None, land=True, result=False):
    packet = 'pkt-' + name
    build_packet(store, {'packet_id': packet, 'packet_scope': 'task', 'work_item': 'fixture', 'task_id': 'task-1',
                 'revision_id': publication['revision_id'], 'dispatch_attempt_id': name,
                 'source_head': publication['source_head'], 'session_id': None, 'phase': None, 'arm': None,
                 'task_scale_set': 'implementation'}, assembly=('Isolated completion packet.', {}), role='worker', scales=['implementation'])
    binding = dict.fromkeys(binder.FIELDS)
    binding.update(work_item='fixture', task_id='task-1', revision_id=publication['revision_id'], packet_id=packet,
                   packet_pointer=pointer(store, packet), dispatch_attempt_id=name, assignment='Check completion.',
                   report_id='report-' + name, report_path=str(item / 'worker-reports' / ('report-' + name + '.md')), execution_root=str(repo))
    binding['absence_reasons'] = {key: 'Not applicable.' for key, value in binding.items() if value is None}
    reference = binder.publish(descriptor, binding, store, guidance, required=binder.TASK_BINDINGS)
    artifacts = [{'path': str(repo / 'scripts/task-completed-capture-check.sh'), 'kind': 'source', 'writer': 'worker', 'identity': source_sha}]
    if tier != 'none':
        artifacts += [{'path': 'task-claims.jsonl', 'kind': 'tier2-claims', 'writer': 'evidence-append.sh', 'identity': yaml.safe_load(tier)[0]}]
    if result:
        call(['bash', 'scripts/criteria-run.sh', 'fixture', 'task-1', 'fixture-check', '--execution-worktree', str(repo), '--packet-id', packet])
        row = json.loads((item / 'results.jsonl').read_text().splitlines()[-1])
        artifacts += [{'path': row['output_path'], 'kind': 'test-output', 'writer': 'criteria-run.sh', 'identity': row['result_id']}]
    report = f'''Report-schema: 1
Report-id: {binding['report_id']}
Work-item: fixture
Task: A subject, not a task identifier
Producer-role: worker
Dispatch-path: codex-chaperone
Harness: codex
Status: completed
Template-version: {descriptor['template_version']}
Position-dispatch-manifest: {reference['manifest_path']}
Position-dispatch-sha256: {reference['manifest_sha256']}
Packet-id: {packet}
Revision-id: {binding['revision_id']}
Dispatch-attempt-id: {name}
**Artifacts:**
{yaml.safe_dump(artifacts, sort_keys=False)}**Changes:**
- Checked completion.
**Checks:**
- Read the fixture source and validated its revision.
**Skills used:** None
**Observations:**
{observations}
**Tier 2 evidence:**
{tier}
**Convention handling:** none in scope
**Surfaced concerns:** None
**Blockers:** none
'''
    if edit:
        report = edit(report)
    if land:
        call(['bash', 'scripts/coordinate-report.sh', 'fixture', '--report-id', binding['report_id'], '--kdir', str(store)], data=report)
    report_bytes = Path(binding['report_path']).read_bytes() if land else report.encode()
    fixtures.append({'reference': reference, 'binding': binding, 'report_sha256': hashlib.sha256(report_bytes).hexdigest(), 'landed': land})
    return {'task_id': 'task-1', 'team_name': 'impl-fixture', 'task_description': report, 'position_dispatch': reference}


def check(name, event, expected=0, contains=None, framework='codex'):
    hook_env = dict(env, LORE_FRAMEWORK=framework)
    p = subprocess.run(['bash', 'scripts/task-completed-capture-check.sh'], input=json.dumps(event), text=True, env=hook_env, capture_output=True)
    assert p.returncode == expected, f'{name}: expected {expected}, got {p.returncode}: {p.stderr}'
    if expected == 0:
        assert 'compiled report validated' in p.stderr, p.stderr
        assert 'allowing' not in p.stderr and 'LEGACY REPORT' not in p.stderr, p.stderr
    elif contains:
        assert contains in p.stderr, f'{name}: {p.stderr}'
    checks.append({'name': name, 'exit': p.returncode, 'stderr': p.stderr})
    print('  PASS: ' + name, flush=True)


valid = fixture('empty', result=True)
check('explicitly empty observations with durable source/result evidence', valid)
check('no team tools still validates', {**valid, 'team_name': ''})
check('missing durable report', fixture('missing', land=False), 2, 'durable report missing')
check('bold Task remains a subject label', fixture('bold', edit=lambda s: s.replace('Task:', '**Task:**')))
check('explicit empty list', fixture('empty-list', observations='[]'))
check('missing assigned identity cannot use report headers', {k:v for k,v in valid.items() if k != 'position_dispatch'}, 2, 'assigned position_dispatch')
for key, value in [('task_id', 'task-unknown'), ('report_id', 'wrong-report'), ('dispatch_attempt_id', 'wrong-attempt'),
                   ('packet_id', 'pkt-unknown'), ('revision_id', '000000000000'), ('position', 'unknown'), ('work_item', 'wrong-item')]:
    check('independent ' + key + ' mismatch', {**valid, key: value}, 2)
for name, reference in [('empty marker', {}), ('malformed marker', 'compiled'),
                         ('missing hash', {'manifest_path': valid['position_dispatch']['manifest_path']}),
                         ('wrong hash', {**valid['position_dispatch'], 'manifest_sha256': '0' * 64})]:
    check(name + ' cannot bypass', {**valid, 'position_dispatch': reference}, 2)
check('report reference required', fixture('no-reference', edit=lambda s: '\n'.join(line for line in s.splitlines() if not line.startswith('Position-dispatch-'))), 2, 'Position-dispatch-manifest')
check('report header binding checked', fixture('wrong-packet', edit=lambda s: s.replace('Packet-id: pkt-wrong-packet', 'Packet-id: pkt-other')), 2, 'Packet-id')
check('convention presence retained', fixture('no-convention', edit=lambda s: s.replace('**Convention handling:** none in scope', '**Convention handling:**')), 2, 'Convention handling')
check('malformed observation cannot use empty exception', fixture('bad-observation', observations='- claim: invented'), 2, 'malformed compiled observation')
check('empty observation heading is not explicit emptiness', fixture('missing-observation', observations=''), 2, 'Observations')
check('missing source artifact', fixture('missing-source', edit=lambda s: s.replace('path: ' + str(repo / 'scripts/task-completed-capture-check.sh'), 'path: ' + str(repo / 'missing-source'))), 2, 'artifact missing')
check('unlanded task description cannot replace report', {**valid, 'task_description': valid['task_description'] + 'changed'}, 2, 'differs from durable')

call(['bash', 'scripts/evidence-append.sh', '--work-item', 'fixture', '--kdir', str(store)], data=json.dumps({'claim_id': 'failed-append'}), ok=False)
check('failed canonical claim append blocks completion', fixture('failed-append', tier='- failed-append'), 2)
source = repo / 'scripts/task-completed-capture-check.sh'
snippet = source.read_text().splitlines()[0]
snippet_hash = call(['python3', 'scripts/snippet_normalize.py', '--hash'], data=snippet).stdout.strip()
claim = dict(claim_id='canonical-claim', tier='task-evidence', claim='The completion hook is a Bash entry point.', producer_role='worker',
             protocol_slot='implement-step-3', task_id='task-1', scale='implementation', file=str(source), line_range='1-1',
             exact_snippet=snippet, normalized_snippet_hash=snippet_hash, falsifier='The first line selects another interpreter.',
             why_this_work_needs_it='Verify canonical report references.', captured_at_sha=source_sha,
             change_context={'diff_ref': source_sha, 'changed_files':[str(source)], 'summary':'Isolated completion test.'})
call(['bash', 'scripts/evidence-append.sh', '--work-item', 'fixture', '--kdir', str(store)], data=json.dumps(claim))
observation = {key:claim[key] for key in ('claim','file','line_range','exact_snippet','normalized_snippet_hash','falsifier')}
observation['significance'] = 'low'
check('nonempty observation matches sanctioned writer output', fixture('canonical', observations=yaml.safe_dump([observation]), tier='- canonical-claim'))
check('empty observations still validate referenced claims', fixture('empty-claims', tier='- canonical-claim'))
check('unbacked nonempty observation rejected', fixture('unbacked', observations=yaml.safe_dump([observation])), 2, 'canonical claim')

native_dir = home / '.claude/tasks/impl-fixture'; native_dir.mkdir(parents=True)
(native_dir / '7.json').write_text(json.dumps({'id':'7', 'metadata': {'lore_task_id':'task-1', 'position_dispatch':valid['position_dispatch']}}))
native = {key:value for key,value in valid.items() if key != 'position_dispatch'}
native['task_id'] = '7'; native['teammate_name'] = 'worker-1'
check('native metadata supplies assigned report and plan task identity', native, framework='claude-code')
retry = fixture('retry')
check('fresh retry report identity', retry)
check('old report cannot complete new attempt', {**retry, 'task_description':valid['task_description']}, 2, 'differs from durable')
(repo / 'agents/worker.md').write_text('Changed installed template.\n')
check('changed installed template does not alter recorded attribution', valid)
(item / 'plan.md').write_text(plan + '\nA new revision.\n')
publication = revise()
changed = fixture('changed-revision')
check('fresh changed-revision dispatch', changed)
check('old revision report cannot satisfy new dispatch', {**changed, 'task_description':valid['task_description']}, 2)
check('historical prepared revision remains attributable', valid)

(item / 'plan.md').write_text(plan.replace('**Deliverable:**', '**Consultations required:**\n- storage\n\n**Deliverable:**'))
publication = revise()
consult = fixture('consultation', edit=lambda s: s + '''**Consultations:**
- consultation_id: c1
  handler: lead
  domain: storage
  query_summary: Check storage.
  advice_summary: Preserve immutable bytes.
  was_followed: true
''')
check('required consultation needs canonical acknowledgment', consult, 2, 'transcript')
call(['bash','scripts/impl-consult-log.sh','fixture','--consultation-id','c1','--worker','worker-1','--domain','storage',
      '--handler','lead','--question','Check storage.','--answer','Preserve immutable bytes.','--template-version', descriptor['template_version']])
check('required consultation acknowledged through canonical writer', consult)
log = item / 'execution-log.md'; saved = item / 'saved-execution-log.md'
log.rename(saved); log.mkdir()
check('failed canonical report-check append blocks completion', consult, 2)
log.rmdir(); saved.rename(log)
(item / 'plan.md').write_text(plan + '\nConsultation removed from a later revision.\n')
publication = revise()
transcript = item / 'consultation-transcript.jsonl'
transcript.rename(item / 'saved-transcript.jsonl')
check('later revision cannot erase assigned consultation requirement', consult, 2, 'transcript')
(item / 'saved-transcript.jsonl').rename(transcript)

(base / 'fixtures.json').write_text(json.dumps(fixtures, indent=2) + '\n')
(base / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
print(f'  {len(checks)} compiled completion checks passed', flush=True)
COMPILED_TESTS

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
