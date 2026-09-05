#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$CASE_ROOT"
}

@test "canonical writers retain compiled identities, historical rows, and unknown references" {
  python3 - "$REPO" "$CASE_ROOT" <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys

original, temporary = map(lambda p: Path(p).resolve(), sys.argv[1:])
if os.environ.get('POSITION_ATTRIBUTION_FIXTURES'):
    temporary = Path(os.environ['POSITION_ATTRIBUTION_FIXTURES']).resolve()
    temporary.mkdir(parents=True, exist_ok=False)
repo, home = temporary / 'checkout', temporary / 'home'
repo.mkdir(); home.mkdir()
for name in ('scripts', 'adapters', 'agents', 'docs', 'cli', 'skills'):
    shutil.copytree(original / name, repo / name)
store = home / '.lore'
store.mkdir()
(store / 'scripts').symlink_to(repo / 'scripts')
env = {k:v for k,v in os.environ.items() if not k.startswith(('LORE_', 'CLAUDE_'))}
env.update(HOME=str(home), LORE_DATA_DIR=str(store), LORE_KNOWLEDGE_DIR=str(store), LORE_FRAMEWORK='codex')
os.environ.update(env)
for key in list(os.environ):
    if key.startswith(('LORE_', 'CLAUDE_')) and key not in env:
        del os.environ[key]
os.chdir(repo)
sys.path.insert(0, str(repo / 'scripts'))
from position_compile import compile_position
from position_attribution import project, report_record, resolve_reference
from packet_builder import build_packet, pointer
from snippet_normalize import hash_normalized as snippet_hash
spec = importlib.util.spec_from_file_location('position_bind', repo / 'scripts/position-bind.py')
binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
commands = []

def call(argv, ok=True, input=None):
    p = subprocess.run(argv, cwd=repo, env=env, input=input, capture_output=True)
    commands.append({'argv': list(map(str,argv)), 'exit': p.returncode, 'stdout': p.stdout.decode(errors='replace'), 'stderr': p.stderr.decode(errors='replace')})
    assert (p.returncode == 0) == ok, commands[-1]
    return p

def script(name, *args, **kwargs):
    return call(['bash', str(repo / 'scripts' / name), *args], **kwargs)

script('create-work.sh', '--title', 'Fixture', '--slug', 'fixture', '--intent-anchor', 'Preserve attribution in isolated fixture data.')
item = store / '_work/fixture'
(item / 'plan.md').write_text('''# Fixture

## Intent Anchor
Preserve attribution in isolated fixture data.

**Scope delta:** none

## Tasks

**Merge rationale:** One fixture task.

### Task 1: Inspect bytes
**Deliverable:** Byte identity.
**Files:** `fixture.txt`
- [ ] Inspect bytes [class: mechanical]
''')
(repo / 'fixture.txt').write_text('Immutable producer identity\n')
(item / 'decisions.json').write_text(json.dumps({
    'anchor_coverage': {'disposition':'covered','by':'fixture-designer','note':'Isolated test data.'},
    'review_requirement': {'disposition':'not-required','by':'fixture-designer','note':'Isolated test data.'},
    'dispatch_decision': {'disposition':'proceed','by':'fixture-coordinator','note':'Isolated test data.','task_ids':['task-1'],'prior_review_refs':[]}}))
script('plan-revise.sh', 'fixture', '--decisions', str(item / 'decisions.json'))
publication = runpy.run_path(str(repo / 'scripts/work-evidence.py'))['publication_for_dispatch']
revision = publication(item, store)['revision_id']
guidance = script('render-dispatch-guidance.sh').stdout

def make_attempt(position='worker', framework='codex', attempt='attempt-1', mode=None):
    descriptor = compile_position(position, framework, store, None)
    packet_id = 'pkt-' + attempt
    row = {'packet_id':packet_id,'packet_scope':'task','work_item':'fixture','task_id':'task-1','revision_id':revision,
           'dispatch_attempt_id':attempt,'source_head':None,'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'}
    build_packet(store, row, assembly=('Isolated packet content', {}), role=position, scales=['implementation'])
    bindings = dict.fromkeys(binder.FIELDS)
    bindings.update(work_item='fixture', task_id='task-1', revision_id=revision, packet_id=packet_id,
                    packet_pointer=pointer(store, packet_id), dispatch_attempt_id=attempt, assignment='Read isolated fixture bytes.',
                    report_id='report-' + attempt, report_path=str(item / 'worker-reports' / ('report-' + attempt + '.md')),
                    execution_root=str(repo), mode=mode)
    if mode == 'consultation':
        bindings.update(consultation_id='consult-' + attempt, domain='storage', reply_destination='fixture-worker')
    bindings['absence_reasons'] = {k:'Not applicable to isolated fixture.' for k,v in bindings.items() if v is None}
    published = binder.publish(descriptor, bindings, store, guidance, native_model='fixture-model' if framework != 'opencode' else None)
    ref = {k:published[k] for k in ('manifest_path','manifest_sha256')}
    # Exercise each adapter's exact dispatch input without launching a live agent.
    scope = temporary / ('native-scope-' + attempt) / '.claude/agents'; scope.mkdir(parents=True)
    if framework == 'claude-code':
        binder.register_native(**ref, scope=scope)
    delivered = (binder.native_input(**ref, scope=scope if framework == 'claude-code' else None) if framework != 'opencode'
                 else {'activation': json.loads((Path(ref['manifest_path']).parent/'launch.json').read_text()), 'payload':Path(published['payload_path']).read_text()})
    (temporary / ('delivered-' + attempt + '.json')).write_text(json.dumps(delivered))
    return descriptor, bindings, ref

def emit_claim(cid, ref=None):
    row = {'claim_id':cid, 'tier':'task-evidence','claim':'The fixture retains producer bytes.', 'producer_role':'worker',
           'protocol_slot':'implement-step-3','task_id':'task-1','scale':'implementation','file':str(repo/'fixture.txt'),
           'line_range':'1-1','exact_snippet':'Immutable producer identity','normalized_snippet_hash':snippet_hash('Immutable producer identity'),
           'falsifier':'The fixture bytes differ.','why_this_work_needs_it':'Tests immutable attribution.', 'captured_at_sha':'fixture-source',
           'change_context':{'diff_ref':None,'changed_files':[str(repo/'fixture.txt')],'summary':'Isolated attribution input.'}}
    if ref is not None:
        row['position_dispatch'] = ref
        attribution = project({'position_dispatch':ref})
        if attribution['status']=='resolved':
            position = attribution['position']
            row['producer_role'] = {'investigator':'researcher','worker':'worker','reviewer':'advisor','designer':'advisor' if attribution['bindings']['mode']=='consultation' else 'spec-lead'}[position]
    script('evidence-append.sh','--work-item','fixture', input=json.dumps(row).encode())
    return json.loads((item/'task-claims.jsonl').read_text().splitlines()[-1])

def write_log(body, ref=None, version='111111111111'):
    args = ['--slug','fixture','--source','implement-lead','--template-version',version]
    if ref is not None:
        args += ['--position-dispatch-manifest',ref['manifest_path'],'--position-dispatch-sha256',ref['manifest_sha256']]
    return script('write-execution-log.sh', *args, input=body.encode())

refs = []
for position in ('investigator','designer','worker','reviewer'):
    for framework in ('claude-code','codex','opencode'):
        modes = ('planning','consultation') if position == 'designer' else (None,)
        for mode in modes:
            attempt = '-'.join(x for x in (position,framework,mode) if x)
            d,b,ref = make_attempt(position,framework,attempt,mode)
            refs.append((d,b,ref))
            # Native input resolution already checked the immutable bundle.
            assert d['template_id'] == f'position/{position}/{framework}'
            if framework == 'codex':
                claim = emit_claim('claim-' + attempt,ref)
                assert claim['producer_attribution']['template_version'] == d['template_version']
                write_log('Task: task-1\nReport-key: fixture/task-1\nChanges: Isolated attribution fixture.\nSurfaced concerns: None', ref)

worker = next(r for r in refs if r[0]['position']=='worker' and r[0]['framework']=='codex')
d,b,ref = worker
claim_id = 'claim-worker-codex'
report = f'''Report-schema: 1
Report-id: {b['report_id']}
Work-item: fixture
Task: task-1
Producer-role: worker
Harness: codex
Status: completed
Template-version: {d['template_version']}
Compiled-position: worker
Position-dispatch-manifest: {ref['manifest_path']}
Position-dispatch-sha256: {ref['manifest_sha256']}
**Artifacts:**
- path: {item/'task-claims.jsonl'}
  kind: tier2-claims
  writer: evidence-append.sh
  identity: {claim_id}
**Changes:** Fixture producer identity.
**Checks:** Read canonical fixture artifacts.
**Skills used:** None
**Observations:** None
**Tier 2 evidence:**
- {claim_id}
**Convention handling:** none in scope
**Surfaced concerns:**
- Retain this isolated routing concern.
**Blockers:** none
'''
script('coordinate-report.sh','fixture','--report-id',b['report_id'],input=report.encode())
checked = script('impl-check-report.sh','fixture','--task','task-1','--revision',revision,'--report',b['report_path'],'--json')
result = next(json.loads(line) for line in checked.stdout.decode().splitlines() if line.startswith('{'))
assert result['mechanical_pass'] and result['producer_attribution']['template_version']==d['template_version'], result
assert project(report_record(report.replace(d['template_version'],'0'*12)))['status']=='unknown'
assert project(report_record(report.replace('Producer-role: worker','Producer-role: reviewer')))['status']=='unknown'
assert project(report_record(report.replace(b['report_id'],'other-report')))['status']=='unknown'
write_log(report.replace('**Surfaced concerns:**','Surfaced concerns:'))
assert 'Retain this isolated routing concern.' in (item/'off_scale_routes.jsonl').read_text()
script('write-execution-log.sh','--slug','fixture','--source','implement-lead','--template-version',d['template_version'],
       '--filing-template-version','111111111111','--position-dispatch-manifest',ref['manifest_path'],
       '--position-dispatch-sha256',ref['manifest_sha256'],input=b'Task: task-1')
assert 'Filing-template-version: 111111111111' in (item/'execution-log.md').read_text()
script('write-execution-log.sh','--slug','fixture','--source','implement-lead','--template-version','111111111111',
       '--producer-role','implement-lead',input=b'Surfaced concerns: A lead-owned isolated concern.')
assert json.loads((item/'off_scale_routes.jsonl').read_text().splitlines()[-1])['producer_role']=='implement-lead'
log_before = (item/'execution-log.md').read_bytes()
script('write-execution-log.sh','--slug','fixture','--source','implement-lead','--position-dispatch-manifest',ref['manifest_path'],input=b'Partial flag',ok=False)
script('write-execution-log.sh','--slug','fixture','--source','implement-lead','--position-dispatch-manifest',ref['manifest_path'],
       '--position-dispatch-sha256',ref['manifest_sha256'],input=f"Position-dispatch-manifest: /other/manifest.json\nPosition-dispatch-sha256: {ref['manifest_sha256']}".encode(),ok=False)
assert (item/'execution-log.md').read_bytes()==log_before

advisor = next(r for r in refs if r[1]['mode']=='consultation' and r[0]['framework']=='codex')
ad,ab,ar = advisor
consult_args = ['fixture','--consultation-id',ab['consultation_id'],'--worker','fixture-worker','--domain','storage','--handler','agent',
                '--question','Which bytes?','--answer','Use the retained bytes.','--advisor-template-version',ad['template_version'],
                '--template-version','111111111111','--position-dispatch-manifest',ar['manifest_path'],'--position-dispatch-sha256',ar['manifest_sha256']]
script('impl-consult-log.sh', *consult_args)
transcript = json.loads((item/'consultation-transcript.jsonl').read_text().splitlines()[-1])
assert transcript['template_version']=='111111111111'
assert transcript['advisor_template_version']==ad['template_version']
assert transcript['producer_attribution']['template_id']=='position/designer/codex'
bad = consult_args.copy(); bad[bad.index('--advisor-template-version')+1]='0'*12
before = (item/'consultation-transcript.jsonl').read_bytes()
script('impl-consult-log.sh',*bad,ok=False)
assert (item/'consultation-transcript.jsonl').read_bytes()==before

consultation = f"""**Consultations:**
- consultation_id: {ab['consultation_id']}
  handler: agent
  domain: storage
  advisor_template_version: {ad['template_version']}
  query_summary: Which bytes?
  advice_summary: Use retained bytes.
  was_followed: true
  position_dispatch: {json.dumps(ar)}
"""
consult_report = item/'consultation-report.md'
consult_report.write_text(report.replace('**Blockers:** none',consultation+'**Blockers:** none'))
consult_check_args = ['fixture','--task','task-1','--report',str(consult_report),'--transcript',str(item/'consultation-transcript.jsonl'),
                     '--provider-status','full','--spawned-advisors',ad['template_version'],'--json']
check = script('impl-check-report.sh',*consult_check_args)
result = next(json.loads(line) for line in check.stdout.decode().splitlines() if line.startswith('{'))
assert result['findings']['fabrication_guard']['status']=='verified', result
assert result['consultation_attribution'][0]['producer_attribution']['status']=='resolved', result
consult_report.write_text(consult_report.read_text().replace(ar['manifest_sha256'],'0'*64))
check = script('impl-check-report.sh',*consult_check_args)
result = next(json.loads(line) for line in check.stdout.decode().splitlines() if line.startswith('{'))
assert result['findings']['fabrication_guard']['status']=='all-stripped', result
assert result['consultation_attribution'][0]['producer_attribution']['status']=='unknown', result
script('impl-check-report.sh','fixture','--task','missing-task','--revision',revision,'--report',b['report_path'],ok=False)

legacy = emit_claim('legacy')
assert 'position_dispatch' not in legacy and 'producer_attribution' not in legacy
assert project(legacy)['status']=='legacy'
missing = dict(ref,manifest_sha256='0'*64)
unknown = emit_claim('unknown',missing)
assert unknown['producer_attribution']['status']=='unknown' and unknown['producer_attribution']['template_version'] is None
assert project({'position':'worker'})['status']=='unknown'
assert project({'position_dispatch':None})['status']=='unknown'
assert project({'producer_attribution':{'status':'resolved','template_version':d['template_version']}})['status']=='unknown'
malformed = copy.deepcopy(legacy); malformed['position_dispatch']={'manifest_path':ref['manifest_path']}
script('evidence-append.sh','--work-item','fixture',input=json.dumps(malformed).encode(),ok=False)

# A reusable brief edit changes the new attempt while retained old bytes stay resolvable.
brief = repo/'agents/positions/worker.md'
brief.write_text(brief.read_text()+'\nFixture-only revised orientation.\n')
new = make_attempt('worker','codex','worker-retry')
assert new[0]['template_version'] != d['template_version']
assert project({'position_dispatch':ref})['template_version']==d['template_version']
assert project({'position_dispatch':new[2]})['template_version']==new[0]['template_version']
emit_claim('claim-worker-retry',new[2]);write_log('Task: task-1\nReport-key: fixture/task-1',new[2])
refs.append(new)

# Real registry refusal must prevent a new compiled artifact from looking registered.
registry_writer = repo/'scripts/template-registry-register.sh'
registry_source = registry_writer.read_bytes()
registry_writer.write_text('#!/usr/bin/env bash\nexit 1\n')
try:
    compile_position('worker','codex',store,None)
except ValueError:
    pass
else:
    raise AssertionError('registry failure was hidden')
finally:
    registry_writer.write_bytes(registry_source)

# A successful transcript append cannot mask an execution-log append failure.
log_writer = repo/'scripts/write-execution-log.sh'; source = log_writer.read_bytes()
log_writer.write_text('#!/usr/bin/env bash\nexit 1\n')
try:
    failure = script('impl-consult-log.sh',*consult_args,ok=False)
    assert b'execution-log append failed' in failure.stderr
    failure = script('impl-check-report.sh','fixture','--task','task-1','--report',b['report_path'],ok=False)
    assert b'execution-log append failed' in failure.stderr
finally:
    log_writer.write_bytes(source)

# Downstream reader fixture additions are integrated here by the owning lead.

# The original active reference survives archival; no historical row is rewritten.
archive = store/'_archive';archive.mkdir(exist_ok=True)
item.rename(archive/'fixture')
assert project({'position_dispatch':ref})['status']=='resolved'
(archive/'fixture').rename(item)
(temporary/'commands.json').write_text(json.dumps(commands,indent=2))
(temporary/'fixture-index.json').write_text(json.dumps({'isolated_test_data':True,'source':str(original),'attempts':[{'producer':d,'bindings':b,'position_dispatch':r} for d,b,r in refs]},indent=2))
print(f'PASS: {len(refs)} compiled attempts, canonical report/claim/consultation/log writers, legacy/unknown/archive/failure controls; fixtures: {temporary}')
PY
}

@test "canonical bold and plain routing labels reach the existing off-scale writer" {
  python3 - "$REPO" "$CASE_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
repo, temporary = map(Path, sys.argv[1:])
store = temporary/'store';store.mkdir()
env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(store), LORE_DATA_DIR=str(store))
subprocess.run(['bash',str(repo/'scripts/create-work.sh'),'--title','Routing fixture','--slug','routing-fixture'],env=env,check=True,capture_output=True)
for label, role in [('Surfaced concerns','worker'),('Worker leads','researcher')]:
    for bold in (False, True):
        heading = f'**{label}:**' if bold else label+':'
        payload = f'{role} {"bold" if bold else "plain"} fixture'
        subprocess.run(['bash',str(repo/'scripts/write-execution-log.sh'),'--slug','routing-fixture','--source','implement-lead',
                        '--template-version','123456abcdef'],input=f'{heading}\n- {payload}\n**Blockers:** none\n',
                       text=True,env=env,check=True,capture_output=True)
rows = [json.loads(line) for line in (store/'_work/routing-fixture/off_scale_routes.jsonl').read_text().splitlines()]
assert len(rows)==4, rows
assert {row['payload'] for row in rows} == {'- worker bold fixture','- worker plain fixture','- researcher bold fixture','- researcher plain fixture'}, rows
assert {row['producer_role'] for row in rows} == {'worker','researcher'}, rows
assert all(row['template_version']=='123456abcdef' for row in rows), rows
PY
}

@test "actual log append refusal is nonzero and malformed CLI references never append" {
  python3 - "$REPO" "$CASE_ROOT" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
repo, temporary = map(Path, sys.argv[1:])
store = temporary/'store';store.mkdir()
env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(store), LORE_DATA_DIR=str(store))
subprocess.run(['bash',str(repo/'scripts/create-work.sh'),'--title','Append fixture','--slug','append-fixture'],env=env,check=True,capture_output=True)
args = ['bash',str(repo/'scripts/write-execution-log.sh'),'--slug','append-fixture','--source','implement-lead']
subprocess.run(args,input=b'Initial entry',env=env,check=True,capture_output=True)
log = store/'_work/append-fixture/execution-log.md'; before=log.read_bytes()
for flags in [ ['--position-dispatch-manifest','','--position-dispatch-sha256',''],
               ['--position-dispatch-manifest','/invalid/manifest.json','--position-dispatch-sha256','bad-digest'] ]:
    failed = subprocess.run(args+flags,input=b'Malformed reference',env=env,capture_output=True)
    assert failed.returncode != 0 and log.read_bytes()==before, failed
log.chmod(0o444)
try:
    failed = subprocess.run(args,input=b'Refused append',env=env,capture_output=True)
    assert failed.returncode != 0 and log.read_bytes()==before, failed
    assert b'execution-log append failed' in failed.stderr and b'Entry written' not in failed.stdout, failed
finally:
    log.chmod(0o644)
PY
}
