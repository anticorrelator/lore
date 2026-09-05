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
                write_log('Task: task-1\nReport-key: fixture/task-1\nChanges: Isolated attribution fixture.\nSurfaced concerns: None', ref, version=d['template_version'])

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
write_log(report.replace('**Surfaced concerns:**','Surfaced concerns:'), version=d['template_version'])
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
emit_claim('claim-worker-retry',new[2]);write_log('Task: task-1\nReport-key: fixture/task-1',new[2],version=new[0]['template_version'])
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

# The original active reference survives archival; no historical row is rewritten.
script('archive-work.sh','fixture')
archive = store/'_work/_archive'
assert project({'position_dispatch':ref})['status']=='resolved'
script('unarchive-work.sh','fixture')
# Python fragment: insert inside exercise_attribution()'s Python heredoc, after
# the writer checks and before its final PY delimiter. Uses the fixture API in
# task-4-writers-interface.md; invoke reader_checks() once. No production data.
def reader_checks():
    import copy
    from position_attribution import project

    def json_output(result):
        return json.loads(result.stdout)

    def audit(path, gate=None, curator=None):
        args = ['bash', str(repo/'scripts/audit-artifact.sh'), str(path), '--kdir', str(store), '--json']
        if Path(path).name == 'promoted-commons.jsonl':
            args = ['bash',str(repo/'scripts/audit-artifact.sh'),'--kdir',str(store),'--json',
                    '--work-item','fixture','--kind','commons','--id','reader-promoted']
        if gate is None:
            args += ['--dry-run']
        else:
            args += ['--gate-output-file', str(gate)]
            if curator is not None:
                args += ['--curator-output-file', str(curator)]
        return call(args)

    def candidate(cid, ids):
        return dict(claim_id=cid, tier='reusable', claim='Compiled fixture attribution '+cid,
                    producer_role='worker', protocol_slot='implement-step-3', scale='implementation',
                    why_future_agent_cares='The original producing version remains recoverable.',
                    falsifier='A different compiled version is recovered from the source.',
                    related_files=[str(repo/'scripts/position_attribution.py')],
                    source_artifact_ids=ids, work_item='fixture', captured_at_sha='abc123')

    (store/'_manifest.json').write_text('{"version":1}\n')
    first = make_attempt(attempt='reader-first')
    brief = repo/'agents/positions/worker.md'
    original = brief.read_bytes()
    brief.write_bytes(original+b'\nFixture version change.\n')
    try:
        second = make_attempt(attempt='reader-second')
    finally:
        brief.write_bytes(original)
    assert first[0]['template_version'] != second[0]['template_version']
    ref1 = {k:first[2][k] for k in ('manifest_path','manifest_sha256')}
    ref2 = {k:second[2][k] for k in ('manifest_path','manifest_sha256')}
    emit_claim('reader-first', ref1)
    emit_claim('reader-second', ref2)
    emit_claim('reader-legacy')
    missing = dict(ref1, manifest_sha256='0'*64)
    emit_claim('reader-unknown', missing)
    claims_path = item/'task-claims.jsonl'
    resolved = json_output(audit(claims_path))
    claims = {c['claim_id']:c for c in resolved['claim_payload']}
    for name, attempt in [('reader-first',first),('reader-second',second)]:
        producer = claims[name]['producer_attribution']
        assert producer['status'] == 'resolved', producer
        assert producer['template_version'] == attempt[0]['template_version']
        assert producer['template_id'] == attempt[0]['template_id']
    assert claims['reader-unknown']['producer_attribution']['status'] == 'unknown'
    assert 'producer_attribution' not in claims['reader-legacy']
    assert resolved['producer_template_version'] == 'unknown'

    gate = item/'reader-gate.json'
    gate.write_text(json.dumps({'judge':'correctness-gate','judge_template_version':'reader-fixture',
        'verdicts':[{'claim_id':name,'verdict':'verified','evidence':'isolated fixture'}
                    for name in ['reader-first','reader-second','reader-legacy','reader-unknown']]}))
    curator = item/'reader-curator.json'
    curator.write_text(json.dumps({'judge':'curator','judge_template_version':'reader-fixture',
        'selected':[{'claim_id':'reader-first','selection_rationale':'fixture'}],
        'dropped':[{'claim_id':name,'drop_rationale':'fixture'}
                   for name in ['reader-second','reader-legacy','reader-unknown']]}))
    audit(claims_path,gate,curator)
    rows = [json.loads(line) for line in (store/'_scorecards/rows.jsonl').read_text().splitlines() if line.strip()]
    for attempt in [first,second]:
        matching = [r for r in rows if r.get('template_version') == attempt[0]['template_version']]
        assert any(r['metric']=='factual_precision' and r['value']==1 for r in matching), matching
        assert any(r['metric']=='curated_rate' for r in matching), matching
        assert all(r['template_id']==attempt[0]['template_id'] for r in matching)
    assert any(r.get('template_version')=='unknown' for r in rows)
    assert any(r.get('template_version')=='task-claims-jsonl' for r in rows)

    candidates = item/'reader-candidates.json'
    candidates.write_text(json.dumps([candidate('reader-promoted',['reader-first']),
        candidate('reader-mixed',['reader-first','reader-second']),
        candidate('reader-missing',['reader-unknown']),
        dict(candidate('reader-wrong-role',['reader-first']),producer_role='implement-lead'),
        dict(candidate('reader-wrong-ref',['reader-first']),position_dispatch=ref2)]))
    result = call(['bash',str(repo/'scripts/impl-promote-batch.sh'),'fixture','--candidates',str(candidates),'--json'])
    # Some canonical writers log before the final one-line JSON result.
    payload = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith('{')][-1]
    assert len(payload['accepted']) == 1 and len(payload['rejected']) == 4, payload
    promoted = [json.loads(line) for line in (item/'promoted-commons.jsonl').read_text().splitlines()]
    row = next(r for r in promoted if r['claim_id']=='reader-promoted')
    assert row['position_dispatch'] == ref1
    assert row['source_artifact_ids'] == ['reader-first']
    assert row['template_version'] == first[0]['template_version']
    assert first[0]['template_version'] in (store/row['entry_path']).read_text()
    projected = json_output(audit(item/'promoted-commons.jsonl'))
    assert next(c for c in projected['claim_payload'] if c['claim_id']=='reader-promoted')['producer_attribution']['status']=='resolved'

    # Assert the finalized legacy vocabulary directly, without deriving the
    # expected role from the same resolver that is under test.
    for position, expected_role in [('investigator','researcher'),('reviewer','advisor')]:
        typed = make_attempt(position=position,attempt='reader-role-'+position)
        typed_claim = emit_claim('reader-role-'+position,typed[2])
        assert typed_claim['producer_role'] == expected_role, typed_claim
        assert typed_claim['producer_attribution']['status'] == 'resolved', typed_claim
        typed_candidates = item/('reader-role-'+position+'.json')
        typed_candidates.write_text(json.dumps([dict(candidate('reader-promote-'+position,['reader-role-'+position]),producer_role=expected_role)]))
        result = call(['bash',str(repo/'scripts/impl-promote-batch.sh'),'fixture','--candidates',str(typed_candidates),'--json'])
        typed_result = [json.loads(line) for line in result.stdout.decode().splitlines() if line.startswith('{')][-1]
        assert typed_result['accepted_count'] == 1, typed_result

    # Corrupt only the isolated registry: the reader must not emit an eligible
    # compiled hash when the sanctioned registration writer refuses the store.
    registry = store/'_scorecards/template-registry.json'
    registry_bytes = registry.read_bytes()
    registry.write_text('{"schema_version":"broken","entries":[]}')
    try:
        broken = json_output(audit(claims_path))
        assert next(c for c in broken['claim_payload'] if c['claim_id']=='reader-first')['producer_attribution']['status']=='unknown'
    finally:
        registry.write_bytes(registry_bytes)

    call(['bash',str(repo/'scripts/template-registry-register.sh'),'--kdir',str(store),
          '--template-id',first[0]['template_id'],'--template-version',first[0]['template_version'],
          '--template-path',str(brief)],ok=False)
    advisor = make_attempt(position='designer',attempt='reader-advisor',mode='consultation')
    answer = dict(handler='agent',advisor_template_version=advisor[0]['template_version'],
                  consultation_id=advisor[1]['consultation_id'],domain='storage',query_summary='Fixture query',
                  advice_summary='Fixture reply',was_followed=True,position_dispatch=advisor[2])
    rolled = json_output(call(['bash',str(repo/'scripts/advisor-impact-rollup.sh'),'rollup','--kdir',str(store),
        '--work-item','fixture','--consultations-json',json.dumps([answer]),'--json']))
    assert rolled['advisors'] == [advisor[0]['template_version']], rolled
    before = (store/'_scorecards/rows.jsonl').read_bytes()
    unknown_answer = dict(answer,position_dispatch=dict(advisor[2],manifest_sha256='0'*64))
    call(['bash',str(repo/'scripts/advisor-impact-rollup.sh'),'rollup','--kdir',str(store),
        '--work-item','fixture','--consultations-json',json.dumps([unknown_answer]),'--json'])
    assert (store/'_scorecards/rows.jsonl').read_bytes() == before
    for invalid_answer in [dict(answer,position_dispatch=ref1,advisor_template_version=first[0]['template_version']),
                           dict(answer,domain='different-domain'),dict(answer,consultation_id='wrong-id')]:
        call(['bash',str(repo/'scripts/advisor-impact-rollup.sh'),'rollup','--kdir',str(store),
            '--work-item','fixture','--consultations-json',json.dumps([invalid_answer]),'--json'])
        assert (store/'_scorecards/rows.jsonl').read_bytes() == before

    # Sampling observes each new compiled version even when the lead version
    # already has historical telemetry, and ignores the current close's rows.
    history = dict(schema_version='1',kind='telemetry',tier='telemetry',calibration_state='pre-calibration',
                   event_type='fixture',metric='fixture',work_item='previous',template_version='111111111111')
    call(['bash',str(repo/'scripts/scorecard-append.sh'),'--kdir',str(store)],input=json.dumps(history).encode())
    attr = [{'task_id':'task-1','producer_attempts':[project({'position_dispatch':ref1}),project({'position_dispatch':ref2})]}]
    sampled = json_output(call(['bash',str(repo/'scripts/retro-sampling-gate.sh'),'--kdir',str(store),
        '--slug','fixture','--terminus','impl-close','--template-version','111111111111','--first-k','0',
        '--routine-rate','0','--task-attribution',json.dumps(attr),'--json']))
    assert 'new_template_version' in sampled['strata'], sampled
    assert {p['template_version'] for p in sampled['new_producer_versions']} == {first[0]['template_version'],second[0]['template_version']}

    forged = dict(project({'position_dispatch':ref1}),position_dispatch=missing,template_version='f'*12)
    forged_sample = json_output(call(['bash',str(repo/'scripts/retro-sampling-gate.sh'),'--kdir',str(store),
        '--slug','fixture','--terminus','impl-close','--template-version','111111111111','--first-k','0',
        '--routine-rate','0','--task-attribution',json.dumps([{'producer_attempts':[forged]}]),'--json']))
    assert not forged_sample['new_producer_versions'], forged_sample
    write_log('Task: task-1\nReport-key: fixture/task-1\nSpend: task=task-1 total_tokens=10\n',ref1,first[0]['template_version'])
    write_log('Task: task-1\nReport-key: fixture/task-1\n',ref1,first[0]['template_version'])
    call(['bash',str(repo/'scripts/write-execution-log.sh'),'--slug','fixture','--source','impl-verb',
          '--template-version','111111111111','--position-dispatch-manifest',ref1['manifest_path'],
          '--position-dispatch-sha256',ref1['manifest_sha256']],input=b'Check-report task: task-1')
    write_log('Task: task-1\nReport-key: fixture/task-1\nSpend: task=task-1 total_tokens=20\n',ref2,second[0]['template_version'])
    call(['bash',str(repo/'scripts/write-execution-log.sh'),'--slug','fixture','--source','implement-lead',
          '--template-version','0'*12,'--filing-template-version','111111111111',
          '--position-dispatch-manifest',advisor[2]['manifest_path'],
          '--position-dispatch-sha256',advisor[2]['manifest_sha256']],input=b'Task: task-1')
    plan = item/'plan.md'
    plan.write_text(plan.read_text().replace('- [ ]','- [x]'))
    call(['bash',str(repo/'scripts/impl-close.sh'),'fixture','--verdict','full','--summary','Fixture complete.','--json'])
    archived = store/'_work/_archive/fixture'
    assert archived.is_dir(), list(store.iterdir())
    bundle = json.loads((archived/'retro-bundle.json').read_text())
    task = next(t for t in bundle['task_attribution'] if t['task_id']=='task-1')
    assert {p['template_version'] for p in task['producer_attempts'] if p['status']=='resolved'} >= {first[0]['template_version'],second[0]['template_version']}, task
    assert next(p for p in task['producer_attempts'] if p['position_dispatch']==advisor[2])['status']=='unknown', task
    assert sum(p['position_dispatch']==ref1 for p in task['producer_attempts']) == 1, task
    assert len(task['producer_attempts']) == len(task['dispatch_context_estimates']), task
    assert isinstance(task['spend'],list) and [s['total_tokens'] for s in task['spend']][-2:] == [10,20]
    assert project({'position_dispatch':ref1})['status']=='resolved'
    assert project({'position_dispatch':ref2})['status']=='resolved'
    assert project({'position_dispatch':missing})['status']=='unknown'
    print('reader_checks: mixed versions, audit, promotion, registry refusal, sampling, close and archive passed')

reader_checks()

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

@test "large compiled-attribution telemetry reaches the canonical scorecard writer" {
  python3 - "$REPO" "$CASE_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import time
repo, temporary = map(Path,sys.argv[1:])
store=temporary/'store';store.mkdir()
env=dict(os.environ,LORE_KNOWLEDGE_DIR=str(store),LORE_DATA_DIR=str(store))
row={'schema_version':'1','kind':'telemetry','tier':'telemetry','calibration_state':'pre-calibration',
     'event_type':'implement-close','metric':'task_attribution','work_item':'fixture','template_version':'123456abcdef',
     'task_attribution':[{'task_id':f'task-{i}','producer_attempts':[{'status':'unknown','reason':'isolated fixture '+('retained component identity '*110)}]} for i in range(15)]}
encoded=json.dumps(row).encode();assert len(encoded)>36000
started=time.monotonic()
p=subprocess.run(['bash',str(repo/'scripts/scorecard-append.sh'),'--kdir',str(store)],input=encoded,env=env,capture_output=True,timeout=10)
assert p.returncode==0,(p.stdout,p.stderr)
rows=[json.loads(line) for line in (store/'_scorecards/rows.jsonl').read_text().splitlines()]
assert len(rows)==1 and rows[0]['task_attribution']==row['task_attribution'],rows
blank=subprocess.run(['bash',str(repo/'scripts/scorecard-append.sh'),'--kdir',str(store)],input=b' \t\n ',env=env,capture_output=True,timeout=10)
assert blank.returncode!=0 and b'row is empty' in blank.stderr
assert len((store/'_scorecards/rows.jsonl').read_text().splitlines())==1
print('Large-row canonical append:',len(encoded),'bytes;',round(time.monotonic()-started,3),'seconds')
PY
}

@test "pre-plan spec-open assertions retain report and attempt attribution through canonical readers" {
  python3 - "$REPO" "$CASE_ROOT" <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import yaml
original,temporary=map(lambda p:Path(p).resolve(),sys.argv[1:])
if os.environ.get('POSITION_PREPLAN_FIXTURES'):
    temporary=Path(os.environ['POSITION_PREPLAN_FIXTURES']).resolve();temporary.mkdir(parents=True,exist_ok=False)
repo=temporary/'checkout';repo.mkdir();home=temporary/'home';home.mkdir();store=home/'.lore';store.mkdir()
for name in ('scripts','adapters','agents','docs','cli','skills'):shutil.copytree(original/name,repo/name)
(store/'scripts').symlink_to(repo/'scripts');(store/'_manifest.json').write_text('{"version":1}')
env={k:v for k,v in os.environ.items() if not k.startswith(('LORE_','CLAUDE_'))}
env.update(HOME=str(home),LORE_DATA_DIR=str(store),LORE_KNOWLEDGE_DIR=str(store),LORE_FRAMEWORK='codex',LORE_MODEL_RESEARCHER='fixture-model')
for key in list(os.environ):
    if key.startswith(('LORE_','CLAUDE_')):del os.environ[key]
os.environ.update(env);os.chdir(repo);sys.path.insert(0,str(repo/'scripts'))
from position_attribution import project
from snippet_normalize import hash_normalized
from packet_builder import build_packet,pointer
spec=importlib.util.spec_from_file_location('position_bind',repo/'scripts/position-bind.py');binder=importlib.util.module_from_spec(spec);spec.loader.exec_module(binder)
commands=[]
def call(argv,input=None,ok=True):
    r=subprocess.run(argv,input=input,cwd=repo,env=env,capture_output=True)
    commands.append({'argv':list(map(str,argv)),'exit':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')})
    assert (r.returncode==0)==ok,commands[-1]
    return r

def script(name,*args,**kwargs):return call(['bash',str(repo/'scripts'/name),*args],**kwargs)
script('create-work.sh','--title','Preplan fixture','--slug','preplan-fixture')
item=store/'_work/preplan-fixture'
call(['git','init','-q']);call(['git','config','user.name','Fixture']);call(['git','config','user.email','fixture@example.invalid'])
(repo/'fixture.txt').write_text('Grounded pre-plan assertion.\n');call(['git','add','fixture.txt']);call(['git','commit','-qm','Fixture source'])
sha=call(['git','rev-parse','HEAD']).stdout.decode().strip()
document={'schema_version':1,'track':'full','investigations':[
    {'id':'external','kind':'fixed','question':'External skill and agent applicability','complexity':'simple','prefetch':[]},
    {'id':'preferences','kind':'fixed','question':'Preferences and conventions applicability','complexity':'simple','prefetch':[]}]}
source=temporary/'investigations.json';source.write_text(json.dumps(document))
opened=json.loads(script('spec-open.sh','preplan-fixture','--investigations',str(source),'--json').stdout)
(temporary/'spec-open.json').write_text(json.dumps(opened,indent=2))
payload=opened['directives'][0]['payload'];bindings=payload['bindings'];ref={key:payload['position_dispatch'][key] for key in ('manifest_path','manifest_sha256')}
assert bindings['task_id'] is None and bindings['revision_id'] is None,bindings
base={'claim_id':'preplan-good','tier':'task-evidence','claim':'The source contains a grounded pre-plan assertion.',
      'producer_role':'researcher','protocol_slot':'spec','task_id':'external','report_id':bindings['report_id'],
      'dispatch_attempt_id':bindings['dispatch_attempt_id'],'position_dispatch':ref,'scale':'implementation',
      'file':str(repo/'fixture.txt'),'line_range':'1-1','exact_snippet':'Grounded pre-plan assertion.',
      'normalized_snippet_hash':hash_normalized('Grounded pre-plan assertion.'),'falsifier':'The first committed line differs.',
      'why_this_work_needs_it':'Checks pre-plan attribution.','captured_at_sha':sha,'significance':'low',
      'change_context':{'summary':'Isolated pre-plan assertion.','changed_files':[str(repo/'fixture.txt')],'diff_ref':sha}}

def emit(row):
    script('evidence-append.sh','--work-item','preplan-fixture',input=json.dumps(row).encode())
    return json.loads((item/'task-claims.jsonl').read_text().splitlines()[-1])

good=emit(base)
assert good['producer_attribution']['status']=='resolved',good
negative=[]
for field in ('report_id','dispatch_attempt_id'):
    for missing in (True,False):
        row=dict(base,claim_id='preplan-'+field+('-missing' if missing else '-wrong'))
        if missing:row.pop(field)
        else:row[field]='wrong-association'
        written=emit(row);negative.append(written['claim_id'])
        assert written['producer_attribution']['status']=='unknown',written

# Actual completion uses the same association, with a committed source anchor.
headers={'Template-version':payload['producer']['template_version'],'Position-dispatch-manifest':ref['manifest_path'],
         'Position-dispatch-sha256':ref['manifest_sha256'],'Packet-id':bindings['packet_id'],
         'Report-id':bindings['report_id'],'Dispatch-attempt-id':bindings['dispatch_attempt_id']}
assertion={key:good[key] for key in ('claim_id','claim','file','line_range','exact_snippet','normalized_snippet_hash','falsifier','significance')}
report=''.join(f'{k}: {v}\n' for k,v in headers.items())+'**Question:** External skill and agent applicability\n**Findings:** Committed fixture bytes ground the assertion.\n**Key files:** None\n**Implications:** Attribution survives before plan tasks exist.\n**Assertions:**\n'+yaml.safe_dump([assertion])+'**Observations:** None\n**Worker leads:** None\n**Unknowns:** None\n'
script('coordinate-report.sh','preplan-fixture','--report-id',bindings['report_id'],'--json',input=report.encode())
script('task-completed-capture-check.sh',input=json.dumps(payload['completion_input']).encode())

resolved=json.loads(script('audit-artifact.sh',str(item/'task-claims.jsonl'),'--kdir',str(store),'--dry-run','--json').stdout)
claims={r['claim_id']:r for r in resolved['claim_payload']}
assert claims['preplan-good']['producer_attribution']['status']=='resolved',claims['preplan-good']
assert all(claims[cid]['producer_attribution']['status']=='unknown' for cid in negative)

def candidate(cid,sid):return {'claim_id':cid,'tier':'reusable','claim':'Pre-plan assertion attribution remains recoverable.',
    'producer_role':'researcher','protocol_slot':'spec','scale':'implementation','why_future_agent_cares':'The producing attempt predates plan task allocation.',
    'falsifier':'A different attempt is recovered.','related_files':[str(repo/'fixture.txt')],'source_artifact_ids':[sid],
    'work_item':'preplan-fixture','captured_at_sha':sha}
candidates=item/'candidates.json';candidates.write_text(json.dumps([candidate('promoted-good','preplan-good')]+[candidate('promoted-'+str(i),cid) for i,cid in enumerate(negative)]))
r=script('impl-promote-batch.sh','preplan-fixture','--candidates',str(candidates),'--json')
result=[json.loads(line) for line in r.stdout.decode().splitlines() if line.startswith('{')][-1]
assert result['accepted_count']==1 and len(result['rejected'])==4,result
commons=json.loads((item/'promoted-commons.jsonl').read_text().splitlines()[-1])
assert commons['position_dispatch']==ref and commons['source_artifact_ids']==['preplan-good']
assert commons['template_version']==payload['producer']['template_version']
again=json.loads(script('audit-artifact.sh','--kdir',str(store),'--work-item','preplan-fixture','--kind','commons','--id','promoted-good','--dry-run','--json').stdout)
assert again['claim_payload'][0]['producer_attribution']['status']=='resolved',again

# A real bound task still demands its exact task identity, even with the correct report/attempt pair.
(item/'plan.md').write_text('''# Bound fixture

## Intent Anchor
Preserve exact task identity.

**Scope delta:** none

## Tasks

**Merge rationale:** One fixture task.

### Task 1: Inspect bytes
**Deliverable:** Grounded identity.
**Files:** `fixture.txt`
- [ ] Inspect bytes [class: mechanical]
''')
decisions=item/'decisions.json';decisions.write_text(json.dumps({'anchor_coverage':{'disposition':'covered','by':'fixture','note':'Isolated test.'},'review_requirement':{'disposition':'not-required','by':'fixture','note':'Isolated test.'},'dispatch_decision':{'disposition':'proceed','by':'fixture','note':'Isolated test.','task_ids':['task-1'],'prior_review_refs':[]}}))
script('plan-revise.sh','preplan-fixture','--decisions',str(decisions))
import runpy
publication=runpy.run_path(str(repo/'scripts/work-evidence.py'))['publication_for_dispatch'](item,store)
revision=publication['revision_id']
bound=copy.deepcopy(bindings);bound.update(task_id='task-1',revision_id=revision,dispatch_attempt_id='bound-attempt',report_id='bound-report',report_path=str(item/'worker-reports/bound-report.md'),packet_id='pkt-bound')
build_packet(store,{'packet_id':'pkt-bound','packet_scope':'task','work_item':'preplan-fixture','task_id':'task-1','revision_id':revision,'dispatch_attempt_id':'bound-attempt','source_head':publication['source_head'],'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'},assembly=('Bound fixture.',{}),role='investigator',scales=['implementation'])
bound['packet_pointer']=pointer(store,'pkt-bound');bound['absence_reasons']={k:v for k,v in bound['absence_reasons'].items() if bound[k] is None}
published=binder.publish(payload['descriptor'],bound,store,(Path(ref['manifest_path']).parent/'guidance.md').read_bytes())
bref={k:published[k] for k in ('manifest_path','manifest_sha256')}
wrong=dict(base,claim_id='bound-wrong-task',report_id=bound['report_id'],dispatch_attempt_id=bound['dispatch_attempt_id'],position_dispatch=bref)
assert emit(wrong)['producer_attribution']['status']=='unknown'
right=dict(wrong,claim_id='bound-right-task',task_id='task-1')
assert emit(right)['producer_attribution']['status']=='resolved'
assert project(good,expected={'work_item':'preplan-fixture','task_id':'external'})['status']=='resolved'
assert project(good,expected={'work_item':'preplan-fixture','task_id':None})['status']=='resolved'
(temporary/'commands.json').write_text(json.dumps(commands,indent=2))
print('Pre-plan canonical spec-open, completion, evidence, audit and promotion passed; all missing/wrong association and exact-bound-task controls passed.')
PY
}
