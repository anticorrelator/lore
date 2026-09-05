#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  CASE_ROOT="$(mktemp -d)"
  export GOTOOLCHAIN=local
  export GOMODCACHE="${TMPDIR:-/tmp}/lore-implement-go-cache-$(id -u)/modules"
  export GOCACHE="${TMPDIR:-/tmp}/lore-implement-go-cache-$(id -u)/build"
  mkdir -p "$GOMODCACHE" "$GOCACHE"
}

teardown() {
  chmod -R u+w "$CASE_ROOT"
  rm -rf "$CASE_ROOT"
}

exercise_binding() {
  python3 - "$REPO" "$CASE_ROOT" "$1" <<'PY'
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
import re
import runpy
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import textwrap

import yaml

original, temporary, scenario = sys.argv[1:]
original, temporary = Path(original).resolve(), Path(temporary).resolve()
if os.environ.get('POSITION_DISPATCH_FIXTURES') and scenario in ('native', 'session', 'launch', 'native-selection', 'spec', 'spec-native', 'spec-session', 'implement-envelope', 'spec-report-fields'):
    temporary = Path(os.environ['POSITION_DISPATCH_FIXTURES']).resolve() / scenario
    temporary.mkdir(parents=True, exist_ok=False)
repo, home = temporary / 'checkout', temporary / 'home'
repo.mkdir(); home.mkdir()
os.chdir(repo)
for name in ('scripts', 'adapters', 'agents', 'docs', 'cli', 'skills'):
    shutil.copytree(original / name, repo / name)
store = home / '.lore'
(store / 'config').mkdir(parents=True)
(store / 'scripts').symlink_to(repo / 'scripts')
settings = {'version': 1, 'harnesses': {'codex': {'roles': {'lead': 'planning-model', 'reviewer': 'review-model', 'worker': 'worker-model', 'researcher': 'research-model', 'advisor': 'advisor-model'}, 'ceremony_roles': {'spec': {'lead': 'spec-model'}}}}}
(store / 'config/settings.json').write_text(json.dumps(settings))
item = store / '_work/fixture'
if scenario not in ('implement-envelope', 'spec-report-fields'):
    item.mkdir(parents=True)
    (item / '_meta.json').write_text(json.dumps({'title': 'Fixture', 'source_checkout': str(repo)}))
instances = store / '_sessions/instances'; instances.mkdir(parents=True)
(instances / 'fixture.json').write_text(json.dumps({'name': 'fixture', 'project_dir': str(repo)}))
env = {k:v for k,v in os.environ.items() if not k.startswith(('LORE_', 'CLAUDE_'))}
env.update(HOME=str(home), LORE_DATA_DIR=str(store), LORE_KNOWLEDGE_DIR=str(store), LORE_FRAMEWORK='codex')
os.environ.update(env)
for key in list(os.environ):
    if key.startswith('LORE_') and key not in env:
        del os.environ[key]
sys.path.insert(0, str(repo / 'scripts'))
spec = importlib.util.spec_from_file_location('position_bind', repo / 'scripts/position-bind.py')
binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
from position_compile import compile_position, native_prompt, validate_descriptor
from packet_builder import build_packet, pointer, show, synthesize

def call(args, ok=True, **kwargs):
    p = subprocess.run(args, cwd=repo, env=env, capture_output=True, **kwargs)
    if ok:
        assert p.returncode == 0, p.stderr.decode(errors='replace') + p.stdout.decode(errors='replace')
    else:
        assert p.returncode != 0, p.stdout
    return p

def refused(fn, message=None):
    try:
        fn()
    except (ValueError, OSError, KeyError) as exc:
        if message: assert message in str(exc), str(exc)
    else:
        raise AssertionError('expected refusal')

if scenario in ('implement-envelope', 'spec-report-fields'):
    call([str(repo/'cli/lore'), 'work', 'create', '--title', 'Fixture', '--slug', 'fixture',
          '--intent-anchor', 'Preserve isolated packet history.'])
    call([str(repo/'cli/lore'), 'work', 'source-checkout', 'fixture', '--from-instance', 'fixture'])

(item / 'plan.md').write_text('''# Fixture

## Intent Anchor
Preserve isolated packet history.

**Scope delta:** none

## Tasks

**Merge rationale:** One fixture task.

### Task 1: Inspect bytes
**Deliverable:** Byte identity.
**Files:** `fixture.txt`
- [ ] Inspect bytes [class: mechanical]
''')
(item / 'decisions.json').write_text(json.dumps({
    'anchor_coverage': {'disposition':'covered','by':'fixture-designer','note':'Isolated test data.'},
    'review_requirement': {'disposition':'not-required','by':'fixture-designer','note':'Isolated test data.'},
    'dispatch_decision': {'disposition':'proceed','by':'fixture-coordinator','note':'Isolated test data.','task_ids':['task-1'],'prior_review_refs':[]}}))
call(['bash', str(repo/'scripts/plan-revise.sh'), 'fixture', '--decisions', str(item/'decisions.json')])
publication = runpy.run_path(str(repo/'scripts/work-evidence.py'))['publication_for_dispatch']

def fixture(position='worker', attempt='attempt-1', revision=None, mode=None):
    if revision is not None:
        with (item/'plan.md').open('a') as f: f.write('\nFixture revision change.\n')
        call(['bash', str(repo/'scripts/plan-revise.sh'), 'fixture', '--decisions', str(item/'decisions.json')])
    committed = publication(str(item),str(store))
    revision = committed['revision_id']
    packet_id = 'pkt-' + attempt
    row = {'packet_id': packet_id, 'packet_scope': 'task', 'work_item': 'fixture', 'task_id': 'task-1', 'revision_id': revision,
           'dispatch_attempt_id': attempt, 'source_head': committed['source_head'], 'session_id': None, 'phase': None, 'arm': None, 'task_scale_set': 'implementation'}
    build_packet(store, row, assembly=('Isolated packet content', {}), role=position, scales=['implementation'])
    synthesize(store, packet_id, by='spec-lead')
    b = dict.fromkeys(binder.FIELDS)
    b.update(work_item='fixture', task_id='task-1', revision_id=revision, packet_id=packet_id, packet_pointer=pointer(store, packet_id),
             dispatch_attempt_id=attempt, assignment='Inspect actual bytes.\nPreserve Unicode: λ and trailing newline.\n', report_id='report-' + attempt,
             report_path=str(item / ('worker-reports' if position == 'worker' else 'outputs') / ('report-' + attempt + '.md')),
             execution_root=str(repo), mode=mode)
    if mode == 'consultation':
        b.update(consultation_id='consult-1', domain='storage', reply_destination='requesting-worker')
    b['absence_reasons'] = {key: 'not applicable to this assignment' for key,value in b.items() if value is None}
    return b

def unbound_fixture(position, attempt, mode=None):
    b=fixture(position,attempt,mode=mode)
    packet_id='pkt-preplan-'+attempt
    row={'packet_id':packet_id,'packet_scope':'session','work_item':'fixture','task_id':None,
         'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'}
    build_packet(store,row,assembly=('Pre-plan investigation.',{}),role=position,scales=['implementation'])
    synthesize(store, packet_id, by='spec-lead')
    b.update(task_id=None,revision_id=None,packet_id=packet_id,packet_pointer=pointer(store,packet_id))
    b['absence_reasons'].update(task_id='No task has been assigned.',revision_id='No plan revision exists.')
    return b

def guidance():
    return call(['bash', str(repo / 'scripts/render-dispatch-guidance.sh')]).stdout

def compile(position='worker', framework='codex'):
    return compile_position(position, framework, store, None)

def bind(d,b,g=None,**kw):
    return binder.publish(d,b,store,g or guidance(),**kw)

def request(b, position='worker', framework='codex', extra=None, flags=(), ok=True, fixed=True):
    (instances / 'fixture.json').touch()
    context = {'bindings': b, **(extra or {})}
    path = temporary / ('context-' + b['dispatch_attempt_id'] + '.json'); path.write_text(json.dumps(context))
    return call(['bash', str(repo / 'scripts/session-request.sh'), '--type', 'worker', '--slug', 'fixture--w1', '--anywhere',
                 '--position', position, '--framework', framework, '--packet', b['packet_id'] or '',
                 *(['--worktree-id', 'fixture-worktree', '--execution-dir', str(repo)] if fixed else []), '--context', str(path), '--kdir', str(store), '--json', *flags], ok=ok)

def pending():
    return list((store / '_sessions/requests/pending').glob('*.json'))

def enqueue_recipe(recipe):
    cli_dir = home / 'bin'; cli_dir.mkdir(exist_ok=True)
    cli = cli_dir / 'lore'
    if not cli.exists(): cli.symlink_to(repo/'cli/lore')
    (instances/'fixture.json').touch()
    before = set(pending())
    call(['bash', '-e', '-c', 'export PATH=' + shlex.quote(str(cli_dir)) + ':"$PATH"\n' + recipe])
    created = set(pending()) - before
    assert len(created) == 1
    return created.pop()

def implement_session_recipe(fixed=False):
    # Execute the authored preparation and enqueue recipes, through the real
    # CLI and writers in this isolated checkout, rather than recreating them.
    b = fixture(attempt='implement-recipe-' + ('fixed' if fixed else 'ordinary'))
    if not fixed:
        b['execution_root'] = None
        b['absence_reasons']['execution_root'] = 'ordinary host supplies the root'
    g = guidance()
    gpath = temporary / (b['dispatch_attempt_id'] + '.guidance.md'); gpath.write_bytes(g)
    d = compile_position('worker', 'codex', store, gpath)
    wrapper_path = repo / 'agents/session-worker.md'
    wrapper_bytes = wrapper_path.read_bytes()
    wrapper = {'template_id': 'implement/session-worker', 'template_version': hashlib.sha256(wrapper_bytes).hexdigest()[:12],
               'path': str(wrapper_path), 'sha256': hashlib.sha256(wrapper_bytes).hexdigest()}
    text = wrapper_bytes.decode()
    suffix = text.split('## Session note', 1)[1].split('```\n', 1)[1].split('\n```', 1)[0].encode()
    for name, value in {'work item title':'Fixture', 'task-id':'task-1', 'derived-slug':'fixture--w1', 'slug':'fixture',
                        'packet-id':b['packet_id'], 'report-id':b['report_id'], 'subject':'Inspect bytes', 'framework':'codex'}.items():
        suffix = suffix.replace(('<' + name + '>').encode(), value.encode())
    prefix = ''.join(f'{label}: {b[key]}\n' for label, key in [('Packet-id','packet_id'), ('Report-id','report_id'),
                      ('Revision-id','revision_id'), ('Dispatch-attempt-id','dispatch_attempt_id')]).encode()
    paths = {'KDIR': str(store), 'GUIDANCE_FILE': str(gpath)}
    for name, value in [('DESCRIPTOR_FILE', json.dumps(d).encode()), ('BINDINGS_FILE', json.dumps(b).encode()),
                        ('WRAPPER_FILE', json.dumps(wrapper).encode()), ('PREFIX_FILE', prefix), ('SUFFIX_FILE', suffix)]:
        path = temporary / (b['dispatch_attempt_id'] + '.' + name); path.write_bytes(value); paths[name] = str(path)
    context_path = temporary / (b['dispatch_attempt_id'] + '.context.json'); paths['CONTEXT_FILE'] = str(context_path)
    if fixed:
        ref = binder.publish(d, b, store, g, wrapper=wrapper, prefix=prefix, suffix=suffix)
        context_path.write_text(json.dumps({'position_dispatch': ref, 'dispatch_guidance': Path(ref['payload_path']).read_text()}))
    else:
        blocks = re.findall(r'```bash\n(.*?)\n\s*```', (repo/'skills/implement/templates/worker-spawn.md').read_text(), re.S)
        recipes = [textwrap.dedent(block) for block in blocks if 'binder.prepare_session_input(' in block]
        assert len(recipes) == 1
        assignments = '\n'.join(name + '=' + shlex.quote(value) for name, value in paths.items())
        call(['bash', '-eu', '-c', assignments + '\n' + recipes[0]])
    context = json.loads(context_path.read_bytes())
    blocks = re.findall(r'```bash\n(.*?)\n```', text, re.S)
    enqueue = [block for block in blocks if 'ENQUEUE_RC=$?' in block]
    assert len(enqueue) == 1
    recipe = enqueue[0]
    values = {'derived_slug':'fixture--w1','work_item_slug':'fixture','worker_model':'provider/opaque-model',
              'dispatch_route':'compiled','brief_file':'','context_file':str(context_path),'framework':'codex',
              'worktree_id':'fixture-worktree' if fixed else '', 'execution_dir':str(repo) if fixed else '', 'team_lead':'fixture-lead'}
    for name, value in values.items():
        recipe = recipe.replace('{{' + name + '}}', value)
    assert '{{' not in recipe
    row_path = enqueue_recipe(recipe); row = json.loads(row_path.read_bytes())
    assert row['extra_context'] == context
    assert row['model'] == 'provider/opaque-model' and row['framework'] == 'codex'
    if fixed:
        assert row['worktree_id'] == 'fixture-worktree' and row['execution_dir'] == str(repo)
        launched = binder.launch_session(context, framework='codex', slug='fixture--w1', execution_root=str(repo), kdir=store)
        collected = binder.session_reference(context, kdir=store)
        assert collected['reference'] == launched['reference']
        assert prefix in launched['payload'].encode() and suffix in launched['payload'].encode()
        assert binder.validate_dispatch(ref['manifest_path'], ref['manifest_sha256'])['wrapper'] == wrapper
    else:
        assert not {'worktree_id', 'execution_dir'} & row.keys()
        prepared = context['position_preparation']
        assert prepared['composition']['wrapper'] == wrapper
        assert prepared['composition']['prefix'].encode() == prefix
        assert prepared['composition']['suffix'].encode() == suffix
        assert not (item/'position-dispatch'/b['dispatch_attempt_id']).exists()
    return {'position':'worker','framework':'codex','mode':'implement-composed','queue_path':str(row_path),'kdir':str(store)}

def spec_sessions(frameworks):
    document = {'schema_version': 1, 'track': 'full', 'investigations': [
        {'id': 'external', 'kind': 'fixed', 'question': 'External skill and agent applicability', 'complexity': 'simple', 'prefetch': []},
        {'id': 'preferences', 'kind': 'fixed', 'question': 'Preferences and conventions applicability', 'complexity': 'simple', 'prefetch': []},
        {'id': 'code', 'kind': 'lead-authored', 'question': 'Which fixture bytes exist?', 'complexity': 'moderate', 'prefetch': []}]}
    for inv, framework in zip(document['investigations'], frameworks):
        b = unbound_fixture('investigator', 'spec-ordinary-' + inv['id'])
        b['assignment'] = json.dumps({'investigation_id': inv['id'], 'question': inv['question'], 'complexity': inv['complexity']})
        b['report_path'] = str(item / 'worker-reports' / (b['report_id'] + '.md'))
        b['execution_root'] = None
        b['absence_reasons']['execution_root'] = 'The ordinary session host supplies its physical worktree.'
        inv['dispatch'] = {'framework': framework, 'route': 'session', 'model': 'opus' if framework == 'claude-code' else 'research-model' if framework == 'codex' else 'anthropic/opus', 'bindings': b}
    source = temporary / 'ordinary-investigations.json'
    source.write_text(json.dumps(document))
    args = ['bash', str(repo / 'scripts/spec-open.sh'), 'fixture', '--investigations', str(source), '--json']
    opened = json.loads(call(args).stdout)
    examples = []
    for inv, directive in zip(document['investigations'], opened['directives']):
        payload = directive['payload']
        context = payload['session_context']
        assert payload['publication_state'] == 'pending-execution-root'
        assert payload['prompt'] is payload['position_dispatch'] is payload['completion_input'] is None
        assert context['position_preparation']['bindings']['execution_root'] is None
        assert not (item / 'position-dispatch' / payload['bindings']['dispatch_attempt_id']).exists()
        context_path = temporary / ('ordinary-context-' + inv['id'] + '.json')
        context_path.write_text(json.dumps(context))
        sys.path.insert(0, str(original / 'tests/helpers'))
        from implement_recipes import inventory
        document_inventory, bodies = inventory(repo / 'skills/spec/SKILL.md', 'spec')
        recipe_row = next(row for row in document_inventory['recipes'] if row['id'] == 'request-session')
        values = {'SESSION_SLUG': 'fixture--w1', 'MODEL': payload['model'], 'TARGET_FRAMEWORK': payload['framework'],
                  'CONTEXT_FILE': str(context_path), 'WORKTREE_ID': '', 'EXECUTION_DIR': '',
                  'TARGET_INSTANCE': '', 'MIN_VINTAGE': ''}
        assert set(values) == set(recipe_row['inputs'])
        assignments = '\n'.join('export ' + name + '=' + shlex.quote(value) for name, value in values.items())
        row_path = enqueue_recipe(assignments + '\n' + bodies['request-session'].decode())
        row = json.loads(row_path.read_bytes())
        assert row['extra_context'] == context
        assert row['placement_stance'] == 'required_dir' and row['required_project_dir'] == str(repo)
        assert not {'execution_dir', 'worktree_id'} & row.keys()
        examples.append({'position': 'investigator', 'framework': payload['framework'], 'mode': 'spec-' + inv['id'],
                         'queue_path': str(row_path), 'kdir': str(store), 'model': payload['model'], 'payload': payload})
    return args, document, opened, examples

if scenario == 'implement-envelope':
    assert item == temporary/'home/.lore/_work/fixture'
    assert item.resolve().is_relative_to(temporary)
    start=json.loads(call(['bash',str(repo/'scripts/impl-start.sh'),'fixture','--compiled-positions','--json']).stdout)
    assert set(start['position_descriptors']['codex'])=={'worker','designer'}
    for d in start['position_descriptors']['codex'].values(): validate_descriptor(d)
    legacy=json.loads(call(['bash',str(repo/'scripts/impl-start.sh'),'fixture','--json']).stdout)
    assert legacy['position_descriptors'] is None
    assert start['template_versions']==legacy['template_versions']
    opened=json.loads(call(['bash',str(repo/'scripts/impl-open.sh'),'fixture','--all','--compiled-positions','--json']).stdout)
    for d in opened['position_descriptors']['codex'].values(): validate_descriptor(d)
    task=next(t for t in opened['manifest'] if t['op']=='TaskCreate')
    inputs=task['position_binding_inputs'];packet=show(store,inputs['packet_id'])
    assert task['position']=='worker'
    assert inputs['packet_pointer']==pointer(store,inputs['packet_id'])
    assert inputs['assignment']==task['description']
    assert all(inputs[key]==packet.get(key) for key in ('task_id','revision_id','dispatch_attempt_id','work_item'))
    assert not {'execution_root','report_path','report_id'} & inputs.keys()
    assert not (item/'position-dispatch').exists()
    synthesize(store,inputs['packet_id'],by='fixture-lead')
    b=dict.fromkeys(binder.FIELDS);b.update(inputs)
    b.update(report_id='implement-envelope-report',report_path=str(item/'worker-reports/implement-envelope-report.md'),execution_root=str(repo))
    b['absence_reasons']={key:'not applicable to this worker' for key,value in b.items() if value is None}
    g=guidance();guidance_path=temporary/'dispatch-guidance.md';guidance_path.write_bytes(g)
    d=compile_position('worker','codex',store,guidance_path)
    wrapper_path=repo/'skills/implement/templates/worker-spawn.md'
    wrapper_hash=hashlib.sha256(wrapper_path.read_bytes()).hexdigest()
    wrapper={'template_id':'implement/worker-spawn','template_version':wrapper_hash[:12],'path':str(wrapper_path),'sha256':wrapper_hash}
    ref=bind(d,b,g,wrapper=wrapper,native_model='gpt-6-astra-high',required=('task_id','revision_id','packet_id','packet_pointer'))
    m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    selected=binder.native_input(ref['manifest_path'],ref['manifest_sha256'])
    assert m['producer']['template_version']==d['template_version']
    assert m['wrapper']==wrapper and m['producer']['template_version']!=wrapper['template_version']
    assert m['producer']['template_version']!=legacy['template_versions']['worker']
    assert selected['tool_input']=={'message':Path(ref['payload_path']).read_text(),'model':'gpt-6-astra','reasoning_effort':'high'}
    assert m['bindings']['assignment']==task['description']
    assert m['accounting']['delivery_proven'] is False
    assert hashlib.sha256(Path(ref['manifest_path']).read_bytes()).hexdigest()==ref['manifest_sha256']
    before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(ref['manifest_path']).parent.iterdir()}
    legacy_open=json.loads(call(['bash',str(repo/'scripts/impl-open.sh'),'fixture','--all','--json']).stdout)
    assert legacy_open['position_descriptors'] is None
    assert all('position_binding_inputs' not in t for t in legacy_open['manifest'] if t['op']=='TaskCreate')
    after={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in Path(ref['manifest_path']).parent.iterdir()}
    assert before==after
    saved=env.copy()
    try:
        env.update(LORE_FRAMEWORK='claude-code',LORE_MODEL_LEAD='opus',LORE_MODEL_WORKER='opus',LORE_MODEL_ADVISOR='opus',LORE_MODEL_WORKER_MECHANICAL='codex/gpt-6-astra-high')
        routed=json.loads(call(['bash',str(repo/'scripts/impl-start.sh'),'fixture','--compiled-positions','--json']).stdout)
        assert set(routed['position_descriptors'])=={'claude-code','codex'}
        route=routed['worker_class_routes']['mechanical']
        assert route['source_framework']=='claude-code' and route['target_framework']=='codex'
        assert route['native_binding']=='gpt-6-astra-high'
        for target,positions in routed['position_descriptors'].items():
            for position,descriptor in positions.items():
                assert descriptor['framework']==target and descriptor['position']==position
                validate_descriptor(descriptor)
    finally:
        env.clear();env.update(saved)
    examples={'start':start,'opened':opened,'legacy_start':legacy,'reference':ref,'prepared_tool_input':selected,'foreign_start':routed,
              'limits':'Prepared envelope and current wrapper identity only; no authored wrapper payload, model launch, live readiness, report landing, or acceptance.'}
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    registration=repo/'scripts/template-registry-register.sh'
    registration.write_text('#!/usr/bin/env bash\nexit 19\n')
    call(['bash',str(repo/'scripts/impl-start.sh'),'fixture','--compiled-positions','--json'],ok=False)
    call(['bash',str(repo/'scripts/impl-open.sh'),'fixture','--all','--compiled-positions','--json'],ok=False)
    print(json.dumps({'examples_path':str(temporary/'examples.json'),'checks':'compiled and legacy envelopes, canonical native preparation, separate wrapper identity, foreign target descriptors, registry refusal'}))
elif scenario == 'spec':
    document = {'schema_version': 1, 'track': 'full', 'investigations': [
        {'id': 'external', 'kind': 'fixed', 'question': 'External skill and agent applicability', 'complexity': 'simple', 'prefetch': []},
        {'id': 'preferences', 'kind': 'fixed', 'question': 'Preferences and conventions applicability', 'complexity': 'simple', 'prefetch': []},
        {'id': 'code', 'kind': 'lead-authored', 'question': 'Which bytes enter the investigator input? λ', 'complexity': 'moderate', 'prefetch': []}]}
    source = temporary / 'investigations.json'
    def spec_open(doc, ok=True):
        source.write_text(json.dumps(doc))
        proc = call(['bash', str(repo/'scripts/spec-open.sh'), 'fixture', '--investigations', str(source), '--json'], ok=ok)
        if not ok:
            return proc
        return json.loads(proc.stdout)
    first = spec_open(document)
    assert first['status'] == 'created'
    payload = first['directives'][2]['payload']
    reference = payload['position_dispatch']
    prepared = binder.validate_dispatch(reference['manifest_path'], reference['manifest_sha256'])
    assert payload['prompt'].encode() == Path(reference['payload_path']).read_bytes()
    assert prepared['producer']['template_id'] == 'position/investigator/codex'
    assert payload['producer']['template_version'] == prepared['producer']['template_version']
    assert prepared['wrapper']['template_version'] == first['source_manifest']['wrapper']['sha256'][:12]
    assert prepared['bindings']['report_path'] == str(item/'worker-reports'/(prepared['bindings']['report_id']+'.md'))
    assert prepared['bindings']['task_id'] is None and prepared['bindings']['revision_id'] is None
    packet = show(store, prepared['bindings']['packet_id'])
    assert packet['recipient_role'] == 'investigator' and packet['schema_version'] == '1'
    assert packet['template_version'] == first['source_manifest']['lead_template_version']
    assert json.loads(prepared['bindings']['assignment'])['question'] == document['investigations'][2]['question']
    assert Path(payload['descriptor']['body_path']).read_text() in payload['prompt']
    assert (repo/'agents/researcher.md').read_text() not in payload['prompt']
    assert first['source_manifest']['researcher_route']['native_binding'] == 'research-model'
    selected = binder.native_input(reference['manifest_path'], reference['manifest_sha256'])
    assert selected['tool'] == 'spawn_agent'
    assert selected['tool_input']['message'] == payload['prompt']
    assert selected['tool_input']['model'] == 'research-model'
    assert selected['registration'] is None
    assert payload['completion_input'] == {'position_dispatch':reference, 'lore_task_id':None}
    hook=['bash', str(repo/'scripts/task-completed-capture-check.sh')]
    call(hook, ok=False, input=json.dumps(payload['completion_input']).encode())
    report = f"""Template-version: {prepared['producer']['template_version']}
Position-dispatch-manifest: {reference['manifest_path']}
Position-dispatch-sha256: {reference['manifest_sha256']}
**Question:** {document['investigations'][2]['question']}
**Findings:**
The packet premise needs a scoped correction; the report retains that finding.
**Key files:** None
**Implications:** The collector reads the correction beside the finding.
**Assertions:** None
**Observations:** None
**Worker leads:** None
**Unknowns:** Native live inventory is outside this isolated fixture.
"""
    call(['bash',str(repo/'scripts/coordinate-report.sh'),'fixture','--report-id',prepared['bindings']['report_id'],'--kdir',str(store),'--json'], input=report.encode())
    landed=Path(prepared['bindings']['report_path']).read_text()
    assert report.rstrip()==landed.rstrip()
    call(hook,input=json.dumps(payload['completion_input']).encode())
    wrong=copy.deepcopy(payload['completion_input']);wrong['position_dispatch']['manifest_sha256']='0'*64
    call(hook,ok=False,input=json.dumps(wrong).encode())
    examples=[{'route':'native-codex','payload':payload,'native_input':selected,'report_path':prepared['bindings']['report_path']}]
    first_bytes = (item/'spec-dispatch.json').read_bytes()
    replay = spec_open(document)
    assert replay['status'] == 'reused'
    assert (item/'spec-dispatch.json').read_bytes() == first_bytes
    assert replay['directives'][2]['payload'] == payload
    saved_log=(item/'execution-log.md').read_bytes()
    for broken in ('completion_input','position_dispatch','model','route','framework','publication_state'):
        damaged=copy.deepcopy(replay)
        for key in ('status','artifact_path','artifact_sha256'):
            damaged.pop(key,None)
        if broken=='completion_input':
            damaged['directives'][2]['payload'][broken]['position_dispatch']['manifest_sha256']='0'*64
        elif broken=='position_dispatch':
            del damaged['directives'][2]['payload'][broken]
        else:
            damaged['directives'][2]['payload'][broken]={'model':'different-model','route':'session','framework':'opencode','publication_state':'pending-execution-root'}[broken]
        (item/'execution-log.md').unlink()
        (item/'spec-dispatch.json').write_text(json.dumps(damaged,sort_keys=True,separators=(',',':')))
        spec_open(document,ok=False)
        (item/'spec-dispatch.json').write_bytes(first_bytes)
        (item/'execution-log.md').write_bytes(saved_log)
    changed = copy.deepcopy(document)
    changed['investigations'][2]['question'] += ' Check exact retry identity.'
    retried = spec_open(changed)
    newer = retried['directives'][2]['payload']['bindings']
    assert newer['report_id'] != prepared['bindings']['report_id']
    assert newer['dispatch_attempt_id'] != prepared['bindings']['dispatch_attempt_id']
    legacy = spec_open({**document, 'template': 'researcher'})
    assert all(d['payload']['provenance'] == 'explicit-legacy-template' for d in legacy['directives'])
    assert all('position_dispatch' not in d['payload'] for d in legacy['directives'])
    assert all(d['payload']['template_path'] == str(repo/'agents/researcher.md') for d in legacy['directives'])
    for target, model in [('codex', 'research-model'), ('opencode', 'anthropic/opus')]:
        doc = copy.deepcopy(document)
        bound = fixture('investigator', 'spec-session-'+target)
        bound['assignment'] = json.dumps({k:doc['investigations'][2][k] for k in ('question','complexity')} | {'investigation_id':'code'})
        bound['report_path'] = str(item/'worker-reports'/(bound['report_id']+'.md'))
        doc['investigations'][2]['dispatch'] = {'framework':target, 'route':'session', 'model':model, 'bindings':bound}
        current = spec_open(doc)
        session_payload = current['directives'][2]['payload']
        assert session_payload['route'] == 'session'
        examples.append({'route':'session-'+target,'payload':session_payload})
        context_path = temporary / ('spec-session-'+target+'.json')
        context_path.write_text(json.dumps(session_payload['session_context']))
        before = set(pending())
        (instances/'fixture.json').touch()
        call(['bash', str(repo/'scripts/session-request.sh'), '--type','worker','--slug','fixture--w1','--anywhere',
              '--framework',target,'--model',model,'--worktree-id','fixture-worktree','--execution-dir',str(repo),
              '--context',str(context_path),'--kdir',str(store),'--json'])
        queued = json.loads(next(iter(set(pending())-before)).read_text())
        assert queued['extra_context'] == session_payload['session_context']
        launched = binder.launch_session(queued['extra_context'], framework=target, slug='fixture--w1', execution_root=str(repo), kdir=store)
        assert launched['payload'] == session_payload['prompt']
        assert launched['producer']['position'] == 'investigator'
        for field in ('task_id','revision_id','packet_id','packet_pointer'):
            invalid=copy.deepcopy(doc)
            invalid['investigations'][2]['dispatch']['bindings'][field]='mismatched'
            spec_open(invalid,ok=False)
        conflicting=copy.deepcopy(doc)
        conflicting['investigations'][2]['question'] += ' conflicting question'
        spec_open(conflicting,ok=False)
    (temporary/'spec-examples.json').write_text(json.dumps(examples,indent=2)+'\n')
    print('spec compiled bytes, original replay, fresh retries, legacy input, bound sessions and identity refusals checked')

elif scenario == 'spec-claims':
    call(['git', 'init', '-q'])
    call(['git', 'config', 'user.name', 'Fixture'])
    call(['git', 'config', 'user.email', 'fixture@example.invalid'])
    (repo / 'fixture.txt').write_text('grounded fixture bytes\n')
    call(['git', 'add', 'fixture.txt']); call(['git', 'commit', '-qm', 'Fixture source'])
    sha = call(['git', 'rev-parse', 'HEAD']).stdout.decode().strip()
    document = {'schema_version': 1, 'track': 'full', 'investigations': [
        {'id': 'external', 'kind': 'fixed', 'question': 'External skill and agent applicability', 'complexity': 'simple', 'prefetch': []},
        {'id': 'preferences', 'kind': 'fixed', 'question': 'Preferences and conventions applicability', 'complexity': 'simple', 'prefetch': []}]}
    for inv in document['investigations']:
        b = fixture('investigator', 'grounded-' + inv['id'])
        b['assignment'] = json.dumps({'investigation_id': inv['id'], 'question': inv['question'], 'complexity': inv['complexity']})
        b['report_path'] = str(item / 'worker-reports' / (b['report_id'] + '.md'))
        inv['dispatch'] = {'framework': 'codex', 'route': 'session', 'model': 'research-model', 'bindings': b}
    source = temporary / 'grounded-investigations.json'; source.write_text(json.dumps(document))
    opened = json.loads(call(['bash', str(repo / 'scripts/spec-open.sh'), 'fixture', '--investigations', str(source), '--json']).stdout)
    from snippet_normalize import hash_normalized
    for inv, directive in zip(document['investigations'], opened['directives']):
        payload = directive['payload']; b = payload['bindings']; ref = payload['position_dispatch']
        correct = inv['id'] == 'preferences'
        row = {'claim_id': 'claim-' + inv['id'], 'tier': 'task-evidence', 'claim': 'The fixture contains grounded fixture bytes.',
               'producer_role': 'researcher', 'protocol_slot': 'spec', 'task_id': b['task_id'] if correct else inv['id'],
               'scale': 'implementation', 'file': str(repo / 'fixture.txt'), 'line_range': '1-1',
               'exact_snippet': 'grounded fixture bytes', 'normalized_snippet_hash': hash_normalized('grounded fixture bytes'),
               'falsifier': 'The committed first line differs.', 'why_this_work_needs_it': 'Exercise bound investigator completion.',
               'captured_at_sha': sha, 'change_context': {'summary': 'Fixture source', 'changed_files': [str(repo / 'fixture.txt')], 'diff_ref': None},
               'significance': 'low', 'report_id': b['report_id'], 'dispatch_attempt_id': b['dispatch_attempt_id']}
        call(['bash', str(repo / 'scripts/evidence-append.sh'), '--work-item', 'fixture', '--kdir', str(store)], input=json.dumps(row).encode())
        headers = {'Template-version': payload['producer']['template_version'], 'Position-dispatch-manifest': ref['manifest_path'],
                   'Position-dispatch-sha256': ref['manifest_sha256'], 'Packet-id': b['packet_id'], 'Report-id': b['report_id'],
                   'Dispatch-attempt-id': b['dispatch_attempt_id'], 'Revision-id': b['revision_id']}
        assertion = {key: row[key] for key in ('claim_id', 'claim', 'file', 'line_range', 'exact_snippet', 'normalized_snippet_hash', 'falsifier', 'significance')}
        report = ''.join(f'{key}: {value}\n' for key, value in headers.items()) + '**Question:** ' + inv['question'] + '\n**Findings:** The committed fixture contains the named bytes.\n**Key files:** None\n**Implications:** Bound evidence retains the task identity.\n**Assertions:**\n' + yaml.safe_dump([assertion]) + '**Observations:** None\n**Worker leads:** None\n**Unknowns:** None\n'
        call(['bash', str(repo / 'scripts/coordinate-report.sh'), 'fixture', '--report-id', b['report_id'], '--kdir', str(store), '--json'], input=report.encode())
        result = call(['bash', str(repo / 'scripts/task-completed-capture-check.sh')], ok=correct, input=json.dumps(payload['completion_input']).encode())
        if not correct:
            assert b'assertion has no unique matching canonical claim' in result.stderr
    print('grounded self-emission rejects investigation labels for bound tasks and accepts the actual bound task')

elif scenario == 'spec-report-fields':
    # These are authored report inputs. Every packet, claim and report lands
    # through the same writers used by the collector.
    call(['git', 'init', '-q'])
    call(['git', 'config', 'user.name', 'Fixture'])
    call(['git', 'config', 'user.email', 'fixture@example.invalid'])
    (repo / 'fixture.txt').write_text('grounded fixture bytes\n')
    call(['git', 'add', 'fixture.txt']); call(['git', 'commit', '-qm', 'Fixture source'])
    sha = call(['git', 'rev-parse', 'HEAD']).stdout.decode().strip()
    from snippet_normalize import hash_normalized
    hook = ['bash', str(repo / 'scripts/task-completed-capture-check.sh')]
    cases = [
        ('valid', None), ('empty', None),
        ('key-capital-none', None), ('key-none', None), ('key-list-empty', None),
        ('observation-external', None), ('observation-parent', None), ('trailing-newlines', None),
        ('observations-unstructured', None), ('significance-unequal', None),
        ('preplan-task-vocabulary', None), ('observation-canonical-ref', None),
        ('observation-missing-ref', 'observation canonical claim reference missing or ambiguous'),
        ('key-line', 'existing absolute files'),
        ('key-relative', 'existing absolute files'),
        ('significance', 'malformed grounded investigator assertion'),
        ('wrong-role', 'canonical claim producer mismatch'),
        ('outside-root', 'is not in the subpath'),
        ('missing-revision-file', 'exists on disk, but not in'),
        ('wrong-header', 'Report-id mismatched'),
        ('plain-claim-ids', 'invalid Tier 2 evidence references'),
    ]
    for name, reason in cases:
        b = (unbound_fixture if name == 'preplan-task-vocabulary' else fixture)('investigator', 'fields-' + name)
        if name == 'preplan-task-vocabulary':
            b['assignment'] = json.dumps({'investigation_id': 'named-investigation', 'question': 'Which bytes exist?', 'complexity': 'simple'})
        b['report_path'] = str(item / 'worker-reports' / (b['report_id'] + '.md'))
        ref = bind(compile('investigator'), b)
        m = binder.validate_dispatch(ref['manifest_path'], ref['manifest_sha256'])
        source = repo / 'fixture.txt'
        if name == 'outside-root':
            source = temporary / 'outside.txt'; source.write_text('grounded fixture bytes\n')
        elif name == 'missing-revision-file':
            source = repo / 'uncommitted.txt'; source.write_text('grounded fixture bytes\n')
        row = {'claim_id': 'claim-fields-' + name, 'tier': 'task-evidence',
               'claim': 'The source contains grounded fixture bytes.',
               'producer_role': 'spec-lead' if name == 'wrong-role' else 'researcher',
               'protocol_slot': 'spec', 'task_id': 'different-legacy-vocabulary' if name == 'preplan-task-vocabulary' else b['task_id'], 'scale': 'implementation',
               'file': str(source), 'line_range': '1-1', 'exact_snippet': 'grounded fixture bytes',
               'normalized_snippet_hash': hash_normalized('grounded fixture bytes'),
               'falsifier': 'The committed first line differs.',
               'why_this_work_needs_it': 'Check source-bound report collection.',
               'captured_at_sha': sha, 'change_context': {'summary': 'Fixture source',
                    'changed_files': [str(source)], 'diff_ref': None},
               'significance': 'low', 'report_id': b['report_id'],
               'dispatch_attempt_id': b['dispatch_attempt_id'],
               'position_dispatch': {key: ref[key] for key in ('manifest_path', 'manifest_sha256')}}
        observation_only = name in ('observation-external', 'observation-parent')
        if name != 'empty' and not observation_only:
            call(['bash', str(repo / 'scripts/evidence-append.sh'), '--work-item', 'fixture', '--kdir', str(store)], input=json.dumps(row).encode())
        assertion = {key: row[key] for key in ('claim_id', 'claim', 'file', 'line_range', 'exact_snippet', 'normalized_snippet_hash', 'falsifier', 'significance')}
        if name == 'significance': assertion['significance'] = 'This affects collection.'
        if name == 'significance-unequal': assertion['significance'] = 'high'
        if name in ('observation-canonical-ref', 'observation-missing-ref'):
            assertion.pop('falsifier')
            if name == 'observation-missing-ref': assertion['claim_id'] = 'missing-canonical-row'
        if observation_only:
            external = temporary / (name + '.txt')
            external.write_text('External observation without a canonical source claim.\n')
            assertion = {'claim': 'An external observation file exists.',
                         'file': str(external) if name == 'observation-external' else '../' + external.name}
        key = str(repo / 'fixture.txt')
        if name == 'key-line': key += ':1'
        if name == 'key-relative': key = 'fixture.txt'
        headers = {'Template-version': m['producer']['template_version'],
                   'Position-dispatch-manifest': ref['manifest_path'], 'Position-dispatch-sha256': ref['manifest_sha256'],
                   'Report-id': 'different-report' if name == 'wrong-header' else b['report_id']}
        report = ''.join(f'{key}: {value}\n' for key, value in headers.items())
        key_body = {'key-capital-none': 'None\n', 'key-none': 'none\n', 'key-list-empty': '[]\n'}.get(name, yaml.safe_dump([key]))
        report += '**Question:** Which committed bytes ground the report?\n**Findings:** The named bytes are inspectable.\n**Key files:**\n' + key_body
        report += '**Implications:** Retain the source identity.\n**Assertions:**\n' + yaml.safe_dump([] if name == 'empty' else [assertion])
        observations = '[unparsed prose with no YAML fields' if name == 'observations-unstructured' else 'None'
        report += '**Observations:** ' + observations + '\n**Worker leads:** None\n**Unknowns:** None\n'
        if name == 'plain-claim-ids': report += '**Tier 2 evidence:**\n' + row['claim_id'] + '\n'
        if name == 'trailing-newlines': report += '\n\n\n'
        completion = {'position_dispatch': ref, 'lore_task_id': b['task_id']}
        # Missing durable output fails even when a complete response exists in memory.
        missing = call(hook, ok=False, input=json.dumps(completion).encode())
        assert b'durable report missing' in missing.stderr
        call(['bash', str(repo / 'scripts/coordinate-report.sh'), 'fixture', '--report-id', b['report_id'], '--kdir', str(store)], input=report.encode())
        before = Path(b['report_path']).read_bytes()
        assert before == report.rstrip('\n').encode() + b'\n'
        if name == 'trailing-newlines': assert before != report.encode()
        result = call(hook, ok=reason is None, input=json.dumps(completion).encode())
        if reason: assert reason.encode() in result.stderr, (name, result.stderr)
        repeat = call(['bash', str(repo / 'scripts/coordinate-report.sh'), 'fixture', '--report-id', b['report_id'], '--kdir', str(store)], ok=False, input=report.encode())
        assert repeat.returncode == 4 and Path(b['report_path']).read_bytes() == before
    print('real investigator report fields, source-root restrictions, write-once history and empty assertions checked')

elif scenario == 'spec-session':
    args, document, opened, examples = spec_sessions(('claude-code', 'codex', 'opencode'))
    original_artifact = (item / 'spec-dispatch.json').read_bytes()
    assert json.loads(call(args).stdout)['status'] == 'reused'
    assert (item / 'spec-dispatch.json').read_bytes() == original_artifact
    saved_log = (item / 'execution-log.md').read_bytes()
    # Recovery without an atom must still revalidate every admitted field.
    for field in ('completion_input', 'prompt', 'producer', 'bindings', 'session_context'):
        damaged = json.loads(original_artifact)
        payload = damaged['directives'][1]['payload']
        if field == 'session_context':
            payload[field]['position_preparation']['composition']['suffix'] += 'Altered collector'
        else:
            payload[field] = {'changed': True}
        (item / 'spec-dispatch.json').write_text(json.dumps(damaged))
        (item / 'execution-log.md').unlink()
        call(args, ok=False)
        (item / 'spec-dispatch.json').write_bytes(original_artifact)
        (item / 'execution-log.md').write_bytes(saved_log)
    for example in examples:
        payload = example['payload']; context = payload['session_context']
        pending = context['position_preparation']
        root = repo / ('physical-' + example['framework']); root.mkdir()
        refused(lambda: binder.session_reference(context, kdir=store))
        launched = binder.launch_session(context, framework=example['framework'], slug='fixture--w1', execution_root=str(root), kdir=store)
        selected = json.loads(call(['python3', str(repo / 'scripts/position-bind.py'), 'session-reference', '--kdir', str(store)], input=json.dumps(context).encode()).stdout)
        assert selected['reference'] == launched['reference']
        assert selected['bindings']['execution_root'] == str(root)
        assert selected['delivery_proven'] is False and selected['publication_state'] == 'prepared'
        assert selected['completion_input']['lore_task_id'] is None
        bundle = Path(launched['reference']['manifest_path']).parent
        assert (bundle / 'wrapper-prefix.md').read_text() == pending['composition']['prefix']
        assert (bundle / 'wrapper-suffix.md').read_text() == pending['composition']['suffix']
        assert (bundle / 'wrapper-source.md').read_text() == pending['composition']['wrapper_source']
        assert launched['payload'].endswith(pending['composition']['suffix'])
        assert json.loads(call(args).stdout)['directives'] == opened['directives']
        for field in ('prefix', 'suffix', 'wrapper_source'):
            changed = copy.deepcopy(context)
            changed['position_preparation']['composition'][field] += 'changed'
            refused(lambda: binder.session_reference(changed, kdir=store))
        changed = copy.deepcopy(context); changed['position_preparation']['bindings']['assignment'] += 'changed'
        refused(lambda: binder.session_reference(changed, kdir=store))
        fixed = {'dispatch_guidance': launched['payload'], 'position_dispatch': launched['reference']}
        refused(lambda: binder.launch_session(fixed, framework=example['framework'], slug='fixture--w1', execution_root=str(repo), kdir=store), 'execution_root mismatch')
        # The host retains the admitted wrapper source even if its live file changes.
        script = repo / 'scripts/spec-open.sh'; old = script.read_bytes(); script.write_bytes(old + b'\n# source drift\n')
        assert binder.launch_session(context, framework=example['framework'], slug='fixture--w1', execution_root=str(root), kdir=store)['reference'] == launched['reference']
        script.write_bytes(old)
        adapter = repo / 'adapters/agents' / (example['framework'] + '.sh')
        old_adapter = adapter.read_bytes(); adapter.write_bytes(old_adapter + b'\n# renderer drift\n')
        try:
            assert binder.session_reference(context, kdir=store)['reference'] == launched['reference']
            refused(lambda: binder.validate_session_preparation(pending, kdir=store), 'renderer changed')
            refused(lambda: binder.launch_session(context, framework=example['framework'], slug='fixture--w1', execution_root=str(root), kdir=store), 'renderer changed')
        finally:
            adapter.write_bytes(old_adapter)
        changed = copy.deepcopy(context); changed['position_preparation']['activation']['changed'] = True
        refused(lambda: binder.session_reference(changed, kdir=store), 'activation differs')
    print('ordinary spec queue, physical root binding, wrapper bytes, independent reference collection and replay/tamper controls checked')

elif scenario == 'spec-native':
    document={'schema_version':1,'track':'full','investigations':[
        {'id':'external','kind':'fixed','question':'External skill and agent applicability','complexity':'simple','prefetch':[]},
        {'id':'preferences','kind':'fixed','question':'Preferences and conventions applicability','complexity':'simple','prefetch':[]},
        {'id':'code','kind':'lead-authored','question':'Which native input is selected?','complexity':'moderate','prefetch':[]}]}
    source=temporary/'investigations.json'
    def spec_open(doc,ok=True):
        source.write_text(json.dumps(doc))
        proc=call(['bash',str(repo/'scripts/spec-open.sh'),'fixture','--investigations',str(source),'--json'],ok=ok)
        return json.loads(proc.stdout) if ok else proc
    env.update(LORE_FRAMEWORK='claude-code',LORE_MODEL_RESEARCHER='opus')
    claude=spec_open(document)
    payload=claude['directives'][2]['payload'];reference=payload['position_dispatch']
    selection=payload['native_selection']
    assert selection['tool']=='Agent'
    scope=repo/'.claude/agents';scope.mkdir(parents=True)
    refused(lambda:binder.native_input(reference['manifest_path'],reference['manifest_sha256'],scope),'registration')
    binder.register_native(reference['manifest_path'],reference['manifest_sha256'],scope)
    native=binder.native_input(reference['manifest_path'],reference['manifest_sha256'],scope)
    assert native['tool_input']['prompt']==payload['prompt']
    assert native['tool_input']['model']=='opus'
    name=native['tool_input']['subagent_type']
    assert name==native['readiness']['selection_name']
    assert (scope/(name+'.md')).read_bytes()==(Path(reference['manifest_path']).parent/'selection.md').read_bytes()
    assert Path(payload['descriptor']['body_path']).read_text() not in payload['prompt']
    assert native['readiness']['kind']=='native-agent-inventory'
    examples=[{'route':'native-claude','payload':payload,'native_input':native}]
    env.update(LORE_MODEL_RESEARCHER='codex/research-model')
    foreign=spec_open(document)['directives'][2]['payload']
    assert foreign['route']=='codex-chaperone' and foreign['framework']=='codex' and foreign['model']=='research-model'
    assert foreign['native_selection'] is None
    assert Path(foreign['descriptor']['body_path']).read_text() in foreign['prompt']
    assert (Path(foreign['position_dispatch']['manifest_path']).parent/'launch.json').exists()
    examples.append({'route':'foreign-codex','payload':foreign})
    env.update(LORE_FRAMEWORK='opencode',LORE_MODEL_RESEARCHER='anthropic/opus')
    before=(item/'spec-dispatch.json').read_bytes()
    failure=spec_open(document,ok=False)
    assert b'unsupported' in failure.stderr.lower() or b'unavailable' in failure.stderr.lower()
    assert (item/'spec-dispatch.json').read_bytes()==before
    sessions=copy.deepcopy(document)
    for inv, original in zip(sessions['investigations'],claude['directives']):
        binding=copy.deepcopy(original['payload']['bindings'])
        binding['dispatch_attempt_id']+='-session';binding['report_id']+='-session'
        binding['report_path']=str(item/'worker-reports'/(binding['report_id']+'.md'))
        assert binding['task_id'] is None and binding['revision_id'] is None
        inv['dispatch']={'framework':'opencode','route':'session','model':'anthropic/opus','bindings':binding}
    session_payload=spec_open(sessions)['directives'][2]['payload']
    context=temporary/'preplan-session.json';context.write_text(json.dumps(session_payload['session_context']))
    before_requests=set(pending());(instances/'fixture.json').touch()
    call(['bash',str(repo/'scripts/session-request.sh'),'--type','worker','--slug','fixture--w1','--anywhere',
          '--framework','opencode','--model',session_payload['model'],'--worktree-id','fixture-worktree','--execution-dir',str(repo),
          '--context',str(context),'--kdir',str(store),'--json'])
    queued=json.loads(next(iter(set(pending())-before_requests)).read_text())
    assert queued['extra_context']==session_payload['session_context']
    launched=binder.launch_session(queued['extra_context'],framework='opencode',slug='fixture--w1',execution_root=str(repo),kdir=store)
    assert launched['payload']==session_payload['prompt']
    assert 'OPENCODE_CONFIG_CONTENT' in launched['activation']['env']
    examples.append({'route':'preplan-session-opencode','payload':session_payload,'activation':launched['activation']})
    (temporary/'spec-native-examples.json').write_text(json.dumps(examples,indent=2)+'\n')
    print('spec Claude selected bytes/readiness, foreign Codex, OpenCode native refusal and pre-plan session checked')

elif scenario == 'native':
    def exercise_pair(pair):
        position,framework=pair
        d=compile(position,framework)
        b=fixture(position, position+'-'+framework, mode='planning' if position=='designer' else None)
        ref=bind(d,b); m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
        raw=Path(ref['native_path']).read_bytes(); payload=Path(ref['payload_path']).read_bytes()
        assert raw==Path(d['artifact_path']).read_bytes()
        assert native_prompt(raw,d['native_surface'],position)==Path(d['prompt_path']).read_bytes()
        if framework=='codex':
            assert not raw.startswith(b'---')
            assert Path(d['body_path']).read_bytes() in payload
            assert m['accounting']['native_definition_bytes']==0
        else:
            header=yaml.safe_load(raw.split(b'---\n',2)[1])
            if framework=='claude-code':
                assert header['name']=='position-'+position
                assert ('Edit' in header['tools'])==(position=='worker')
            else:
                assert header['mode']=='subagent'
                assert header['permission']['edit']==('allow' if position=='worker' else 'deny')
            assert Path(d['body_path']).read_bytes() not in payload
            assert m['accounting']['native_definition_bytes']==len(raw)
        assert sum(x['bytes'] for x in m['accounting']['payload_components'])==len(payload)
        assert m['accounting']['contract_delivery']=='referenced'
        assert not any(x['name']=='report_contract' for x in m['accounting']['payload_components'])
        contract=Path(d['contract_references'][0]['path']).read_bytes()
        assert contract not in payload
        assert show(store,b['packet_id'])==json.loads((Path(ref['manifest_path']).parent/'packet.json').read_bytes())
        return {'position':position,'framework':framework,**ref,'template_version':d['template_version']}
    pairs=[(position,framework) for position in binder.POSITIONS for framework in ('claude-code','codex','opencode')]
    with ThreadPoolExecutor(max_workers=4) as pool:
        examples=list(pool.map(exercise_pair,pairs))
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    print(json.dumps(examples))
elif scenario=='native-selection':
    scope=home/'.claude/agents';scope.mkdir(parents=True)
    def exercise_position(position):
        cases=[]
        d=compile(position,'claude-code')
        raw=Path(d['artifact_path']).read_bytes()
        original_header=yaml.safe_load(raw.split(b'---\n',2)[1])
        original_body=raw.split(b'---\n',2)[2]
        refs=[]
        for model in ('opus','sonnet'):
            b=fixture(position,position+'-'+model,mode='planning' if position=='designer' else None)
            g=guidance()
            ref=bind(d,b,g,native_model=model);refs.append(ref)
            m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
            root=Path(ref['manifest_path']).parent
            selection=json.loads((root/'selection.json').read_bytes())
            registered=(root/'selection.md').read_bytes()
            header=yaml.safe_load(registered.split(b'---\n',2)[1])
            assert header==dict(original_header,name=selection['tool_input']['subagent_type'])
            assert registered.split(b'---\n',2)[2]==original_body
            assert selection['tool']=='Agent' and selection['tool_input']['model']==model
            assert m['accounting']['native_definition_bytes']==len(registered)
            assert m['accounting']['prepared_input_bytes']==m['accounting']['payload_bytes']+len(registered)
            assert 'launch.json' not in m['files']
            assert bind(d,b,g,native_model=model)==ref
            refused(lambda:bind(d,b,g,native_model='haiku'),'changed payload')
            refused(lambda:binder.native_input(ref['manifest_path'],ref['manifest_sha256'],scope),'missing')
            receipt=binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope)
            assert binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope)==receipt
            path=Path(receipt['registration']['path']);assert path.read_bytes()==registered
            selected=binder.native_input(ref['manifest_path'],ref['manifest_sha256'],scope)
            assert selected['tool_input']['prompt']==Path(ref['payload_path']).read_text()
            assert selected['readiness']=={'kind':'native-agent-inventory','selection_name':header['name']}
            assert 'ready' not in selected and 'delivery_proven' not in selected
            path.write_bytes(registered+b'changed')
            refused(lambda:binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope),'conflicts')
            refused(lambda:binder.native_input(ref['manifest_path'],ref['manifest_sha256'],scope),'differs')
            path.unlink();path.symlink_to(root/'selection.md')
            refused(lambda:binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope),'conflicts')
            path.unlink();binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope)
            refused(lambda:binder.launch_session({'position_dispatch':ref,'dispatch_guidance':Path(ref['payload_path']).read_text()},framework='claude-code',slug='fixture--w1',execution_root=str(repo),kdir=store),'cannot launch as a session')
            if position=='worker' and model=='opus':
                output=call(['python3',str(repo/'scripts/position-bind.py'),'native-input',ref['manifest_path'],'--sha256',ref['manifest_sha256'],'--scope',str(scope)])
                assert json.loads(output.stdout)==selected
                call(['python3',str(repo/'scripts/position-bind.py'),'native-input',ref['manifest_path'],'--sha256',ref['manifest_sha256'],'--scope',str(scope),'--ready'],ok=False)
                refused(lambda:binder.register_native(ref['manifest_path'],ref['manifest_sha256'],home/'.claude/missing'),'existing physical')
            cases.append({'producer':m['producer'],'reference':ref,'selection':selection,'registration':receipt,'prepared_tool_input':selected})
        a,b=(binder.validate_dispatch(r['manifest_path']) for r in refs)
        assert a['producer']==b['producer'] and a['selection']['sha256']!=b['selection']['sha256']
        assert (Path(refs[0]['manifest_path']).parent/'selection.md').read_bytes()!=(Path(refs[1]['manifest_path']).parent/'selection.md').read_bytes()
        return cases
    with ThreadPoolExecutor(max_workers=4) as pool:
        examples=[case for group in pool.map(exercise_position,binder.POSITIONS) for case in group]
    d=compile('worker','codex');b=fixture(attempt='codex-native')
    ref=bind(d,b,native_model='gpt-6-astra-high');m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    selected=binder.native_input(ref['manifest_path'],ref['manifest_sha256'])
    assert selected['tool']=='spawn_agent'
    assert selected['tool_input']=={'message':Path(ref['payload_path']).read_text(),'model':'gpt-6-astra','reasoning_effort':'high'}
    assert Path(d['body_path']).read_bytes() in selected['tool_input']['message'].encode()
    assert m['accounting']['native_definition_bytes']==0
    assert m['accounting']['prepared_input_bytes']==len(selected['tool_input']['message'].encode())
    assert selected['registration'] is None
    refused(lambda:binder.register_native(ref['manifest_path'],ref['manifest_sha256'],scope),'does not use')
    refused(lambda:binder.native_input(ref['manifest_path'],ref['manifest_sha256'],scope),'does not accept')
    examples.append({'producer':m['producer'],'reference':ref,'prepared_tool_input':selected})
    d=compile('worker','opencode');b=fixture(attempt='opencode-native-unavailable')
    refused(lambda:bind(d,b,native_model='anthropic/opus'),'native subagent selection unavailable')
    assert not (item/'position-dispatch'/b['dispatch_attempt_id']).exists()
    bind(d,b)
    archived=store/'_archive/fixture';archived.parent.mkdir();item.rename(archived)
    for example in examples:
        ref=example['reference']
        resolved=binder.resolve_dispatch(ref['manifest_path'],ref['manifest_sha256'])
        assert resolved['manifest']['dispatch_route']=='native-subagent'
        refused(lambda:binder.native_input(ref['manifest_path'],ref['manifest_sha256'],scope),'active work item')
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    print(json.dumps({'examples_path':str(temporary/'examples.json'),'count':len(examples)}))
elif scenario=='launch':
    def exercise_launch(case):
        fw,position,mode=case
        b=fixture(position, fw+'-'+position+'-'+str(mode), mode=mode)
        b['execution_root']=None; b['absence_reasons']['execution_root']='ordinary host supplies final directory'
        r=json.loads(request(b, position, fw, flags=('--model','provider/opaque-model'), fixed=False).stdout)
        row_path=store/r['path']; row=json.loads(row_path.read_bytes())
        assert set(row['extra_context'])=={'position_preparation'}
        assert not (item/'position-dispatch'/b['dispatch_attempt_id']).exists()
        return {'position':position,'framework':fw,'mode':mode,'queue_path':str(row_path),'kdir':str(store)}
    cases=[(fw,position,mode) for fw in ('claude-code','codex','opencode')
           for position,mode in [('worker',None),('investigator',None),('designer','planning'),('designer','consultation'),('reviewer',None)]]
    with ThreadPoolExecutor(max_workers=4) as pool:
        examples=list(pool.map(exercise_launch,cases))
    b=unbound_fixture('investigator','ordinary-preplan-opencode')
    b['execution_root']=None;b['absence_reasons']['execution_root']='ordinary host supplies final directory'
    r=json.loads(request(b,'investigator','opencode',flags=('--model','provider/opaque-model'),fixed=False).stdout)
    row_path=store/r['path'];row=json.loads(row_path.read_bytes())
    prepared=row['extra_context']['position_preparation']
    assert prepared['bindings']['task_id'] is None and prepared['bindings']['revision_id'] is None
    assert not (item/'position-dispatch'/b['dispatch_attempt_id']).exists()
    # Mode here labels the test case; the actual investigator binding has no mode.
    examples.append({'position':'investigator','framework':'opencode','mode':'preplan','queue_path':str(row_path),'kdir':str(store)})
    occupied=fixture(attempt='occupied-report');bind(compile(),occupied)
    duplicate=fixture(attempt='duplicate-report')
    duplicate.update(execution_root=None,report_id=occupied['report_id'],report_path=occupied['report_path'])
    duplicate['absence_reasons']['execution_root']='host supplies final root'
    rejected=request(duplicate,fixed=False,flags=('--model','opaque'),ok=False)
    assert b'report_id already belongs' in rejected.stderr
    # Admission validates pending roots without weakening any other identity.
    bad=fixture(attempt='invalid-pending'); bad['execution_root']=None
    bad['absence_reasons']['execution_root']='host supplies root'
    for field in binder.TASK_BINDINGS:
        broken=copy.deepcopy(bad);broken[field]=None;broken['absence_reasons'][field]='missing'
        request(broken, fixed=False, flags=('--model','opaque'), ok=False)
    _, _, _, spec_examples = spec_sessions(('codex', 'codex', 'codex'))
    examples.extend({key: value for key, value in example.items() if key != 'payload'} for example in spec_examples[:1])
    examples.append(implement_session_recipe())
    implement_session_recipe(fixed=True)
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    print(json.dumps(examples))
elif scenario=='archive':
    metadata=json.loads((item/'_meta.json').read_text());metadata['status']='active'
    (item/'_meta.json').write_text(json.dumps(metadata))
    refs=[]
    for fw in ('claude-code','codex','opencode'):
        d=compile('reviewer',fw);b=fixture('reviewer','archive-'+fw)
        execution=repo/('execution-'+fw);execution.mkdir();b['execution_root']=str(execution)
        refs.append(bind(d,b));execution.rmdir()
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda r:binder.resolve_dispatch(r['manifest_path'],r['manifest_sha256']),refs))
    call(['bash',str(repo/'scripts/archive-work.sh'),'fixture'])
    archived=store/'_work/_archive/fixture'
    for ref in refs:
        result=binder.resolve_dispatch(ref['manifest_path'],ref['manifest_sha256'])
        assert result['manifest']['work_item_path']==str(item)
        assert Path(result['payload_path']).is_relative_to(archived)
        moved=Path(result['resolved_manifest_path'])
        binder.resolve_dispatch(moved,ref['manifest_sha256'])
        refused(lambda:binder.resolve_dispatch(moved,'0'*64),'digest mismatch')
        native=moved.parent/'native.md';raw=native.read_bytes();native.unlink()
        refused(lambda:binder.resolve_dispatch(moved,ref['manifest_sha256']),'membership mismatch');native.write_bytes(raw)
        dependency=Path(result['manifest']['contract_references'][0]['path']);raw=dependency.read_bytes();dependency.unlink()
        refused(lambda:binder.resolve_dispatch(moved,ref['manifest_sha256']));dependency.write_bytes(raw)
    refused(lambda:binder.resolve_dispatch(refs[0]['manifest_path'],refs[1]['manifest_sha256']),'digest mismatch')
    unrelated=store/'elsewhere';archived.rename(unrelated)
    refused(lambda:binder.resolve_dispatch(refs[0]['manifest_path'],refs[0]['manifest_sha256']))
    refused(lambda:binder.resolve_dispatch(unrelated/'position-dispatch/archive-claude-code/manifest.json',refs[0]['manifest_sha256']))
    unrelated.rename(archived)
    # The historical location remains readable without rewriting the manifest.
    legacy=store/'_archive/fixture';legacy.parent.mkdir();archived.rename(legacy)
    assert binder.resolve_dispatch(refs[0]['manifest_path'],refs[0]['manifest_sha256'])['resolved_manifest_path'].startswith(str(legacy))
    legacy.rename(archived)
    # Active item with the same slug cannot borrow an archived attempt.
    item.mkdir()
    refused(lambda:binder.resolve_dispatch(refs[0]['manifest_path'],refs[0]['manifest_sha256']))
    refused(lambda:binder.resolve_dispatch(archived/'position-dispatch/archive-claude-code/manifest.json',refs[0]['manifest_sha256']),'conflict')
elif scenario=='session':
    def exercise_session(case):
        position,mode=case
        b=fixture(position,position+'-'+str(mode),mode=mode)
        extra={'ceremony':'spec'} if mode=='planning' else {}
        p=request(b,position,extra=extra)
        result=json.loads(p.stdout); row_path=store/result['path']; row=json.loads(row_path.read_bytes())
        ref=row['extra_context']['position_dispatch']; m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
        actual=row['extra_context']['dispatch_guidance'].encode()
        assert actual==Path(ref['payload_path']).read_bytes()
        assert hashlib.sha256(actual).hexdigest()==ref['payload_sha256']
        assert 'prompt' not in row['extra_context'] and 'text' not in row['extra_context']
        assert row['execution_dir']==str(repo) and row['worktree_id']=='fixture-worktree'
        assert row['required_project_dir']==str(repo) and row['placement_stance']=='required_dir'
        assert row['framework']=='codex'
        assert row['model']=={'planning':'spec-model','consultation':'advisor-model'}.get(mode,{'reviewer':'review-model','investigator':'research-model','worker':'worker-model'}.get(position))
        old=Path(ref['payload_path']).read_bytes()
        repeat=json.loads(request(b,position,extra=extra).stdout)
        again=json.loads((store/repeat['path']).read_bytes())
        assert again['extra_context']==row['extra_context']
        assert Path(ref['payload_path']).read_bytes()==old
        return {'position':position,'mode':mode,'queue_path':str(row_path),**ref}
    cases=[('designer','planning'),('reviewer',None),('designer','consultation'),('investigator',None),('worker',None)]
    with ThreadPoolExecutor(max_workers=4) as pool:
        examples=list(pool.map(exercise_session,cases))
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    b=fixture(attempt='class-pin')
    r=json.loads(request(b,extra={'class':'mechanical'},flags=('--route','worker=pinned-fallback')).stdout)
    row=json.loads((store/r['path']).read_text()); assert row['model']=='pinned-fallback'
    b=fixture(attempt='explicit-pin')
    r=json.loads(request(b,flags=('--model','provider/explicit-model')).stdout)
    assert json.loads((store/r['path']).read_text())['model']=='provider/explicit-model'
    print(json.dumps(examples))
elif scenario=='invalid':
    d=compile(); b=fixture(); g=guidance()
    for field in binder.CORE+binder.TASK_BINDINGS:
        bad=copy.deepcopy(b); bad[field]=None; bad['absence_reasons'][field]='fixture absence'
        refused(lambda: bind(d,bad,g,required=binder.TASK_BINDINGS),'missing required')
    for field in ('work_item','task_id','revision_id','dispatch_attempt_id','packet_pointer'):
        bad=copy.deepcopy(b); bad[field]='abcdef123456' if field=='revision_id' else 'mismatch'
        refused(lambda: bind(d,bad,g))
    bad=copy.deepcopy(b); bad['mode']='planning'; bad['absence_reasons'].pop('mode')
    refused(lambda:bind(d,bad,g),'only for designer')
    dd=compile('designer'); db=fixture('designer','designer',mode='consultation')
    for field in ('mode','consultation_id','domain','reply_destination'):
        bad=copy.deepcopy(db); bad[field]=None; bad['absence_reasons'][field]='missing'
        refused(lambda:bind(dd,bad,g))
    # Honest absence is representable, but cannot satisfy a caller-required identity.
    absent=copy.deepcopy(b)
    for field in binder.TASK_BINDINGS:
        absent[field]=None; absent['absence_reasons'][field]='no plan/task/packet has been assigned'
    ref=bind(d,absent,g); binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    refused(lambda:bind(d,absent,g,required=binder.TASK_BINDINGS),'missing required')
    for position in ('unknown',''):
        request(b,position,ok=False)
    request(b,extra={'prompt':'must not shadow validated bytes'},ok=False)
    request(b,extra={'bindings':dict(b,mode='planning')},ok=False)
    request(db,'designer',extra={'bindings':dict(db,mode='invented')},ok=False)
    call(['bash',str(repo/'scripts/session-request.sh'),'--type','chat','--anywhere','--position','worker','--kdir',str(store)],ok=False)
    assert not pending()
elif scenario=='retry':
    d=compile(); b=fixture(); g=guidance(); ref=bind(d,b,g)
    assert bind(d,b,g)==ref
    with ThreadPoolExecutor(max_workers=3) as pool:
        assert list(pool.map(lambda _:bind(d,b,g), range(3))) == [ref]*3
    for name,data in [('descriptor.json',json.dumps(d).encode()),('bindings.json',json.dumps(b).encode()),('guidance.md',g)]:
        (temporary/name).write_bytes(data)
    result=call(['python3',str(repo/'scripts/position-bind.py'),'bind','--descriptor',str(temporary/'descriptor.json'),'--bindings',str(temporary/'bindings.json'),'--guidance-file',str(temporary/'guidance.md'),'--kdir',str(store)])
    assert json.loads(result.stdout)==ref
    call(['python3',str(repo/'scripts/position-bind.py'),'validate',ref['manifest_path'],'--sha256',ref['manifest_sha256']])
    bad=copy.deepcopy(b);bad['assignment']+='changed'
    refused(lambda:bind(d,bad,g),'changed payload')
    fresh=fixture(attempt='attempt-2'); fresh['report_id']=b['report_id']; fresh['report_path']=b['report_path']
    refused(lambda:bind(d,fresh,g),'report_id already')
    fresh['report_id']='report-attempt-2';fresh['report_path']=str(item/'worker-reports/report-attempt-2.md')
    second=bind(d,fresh,g);assert second['manifest_path']!=ref['manifest_path']
    changed=fixture(attempt='revision-2',revision='abcdef123456')
    assert bind(d,changed,g)['manifest_path']!=ref['manifest_path']
    bad=copy.deepcopy(b);bad['revision_id']='abcdef123456'
    refused(lambda:bind(d,bad,g),'packet revision_id mismatch')
    history=fixture(attempt='history'); execution=repo/'run';execution.mkdir();history['execution_root']=str(execution)
    historic=bind(d,history,g);execution.rmdir();binder.validate_dispatch(historic['manifest_path'],historic['manifest_sha256'])
    Path(ref['payload_path']).write_bytes(b'corrupt')
    refused(lambda:binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256']),'content mismatch')
elif scenario=='failures':
    d=compile(); b=fixture()
    dependency=Path(d['contract_references'][0]['path']); original_contract=dependency.read_bytes();dependency.unlink()
    p=request(b,extra={'descriptor':d},ok=False);assert not pending();assert b'report-contract.md' in p.stderr
    dependency.write_bytes(original_contract)
    publication=item/'position-dispatch';publication.write_text('not a directory')
    p=request(b,extra={'descriptor':d},ok=False);assert not pending();assert b'position-dispatch' in p.stderr;publication.unlink()
    registration=repo/'scripts/template-registry-register.sh';registration.write_text('#!/usr/bin/env bash\nexit 19\n')
    p=request(b,ok=False);assert not pending();assert b'template-registry-register.sh' in p.stderr;assert not publication.exists()
elif scenario=='replay':
    d=compile(); b=fixture(); g=guidance(); gp=temporary/'admitted.md';gp.write_bytes(g)
    ref=bind(d,b,g,contract_delivery='included');m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    assert sum(c['name']=='report_contract' for c in m['accounting']['payload_components'])==1
    b=fixture(attempt='wrapper')
    source=temporary/'wrapper.md';source.write_bytes(b'fixture wrapper')
    wrapper={'template_id':'fixture-wrapper','template_version':'abcdef123456','path':str(source),'sha256':hashlib.sha256(source.read_bytes()).hexdigest()}
    ref=bind(d,b,g,wrapper=wrapper,prefix=b'prefix\n',suffix=b'\nsuffix')
    m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256']);assert m['wrapper']==wrapper
    assert m['producer']['template_version']==d['template_version']!=wrapper['template_version']
    b=fixture(attempt='replay');r=json.loads(request(b,extra={'descriptor':d,'guidance_file':str(gp)}).stdout)
    row=json.loads((store/r['path']).read_bytes());ref=row['extra_context']['position_dispatch']
    (repo/'scripts/render-dispatch-guidance.sh').write_text('#!/usr/bin/env bash\nexit 17\n')
    request(b,extra={'descriptor':d,'guidance_file':str(gp)})
    assert Path(ref['payload_path']).read_bytes()==row['extra_context']['dispatch_guidance'].encode()
    gp.write_bytes(g.replace(b'=== Standing defaults in force (rendered ',b'=== Standing defaults in force (rendered changed-'))
    request(b,extra={'descriptor':d,'guidance_file':str(gp)},ok=False)
elif scenario=='preplan':
    row={'packet_id':'pkt-preplan','packet_scope':'session','work_item':'fixture','task_id':None,
         'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'}
    build_packet(store,row,assembly=('Pre-plan investigation.',{}),role='investigator',scales=['implementation'])
    synthesize(store, row['packet_id'], by='spec-lead')
    b=fixture('investigator','independent-attempt')
    b.update(task_id=None,revision_id=None,packet_id='pkt-preplan',packet_pointer=pointer(store,'pkt-preplan'))
    b['absence_reasons'].update(task_id='Investigation precedes tasks.',revision_id='No plan revision exists.')
    d=compile('investigator')
    ref=bind(d,b)
    m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    assert m['bindings']['dispatch_attempt_id']=='independent-attempt'
    assert show(store,'pkt-preplan').get('dispatch_attempt_id') is None
    conflict=copy.deepcopy(b);conflict['task_id']='task-1';del conflict['absence_reasons']['task_id']
    refused(lambda: bind(d,conflict),'task_id mismatch')
    bound=fixture('investigator','bound-attempt');bound['dispatch_attempt_id']='wrong-attempt'
    refused(lambda: bind(d,bound),'dispatch_attempt_id mismatch')
    for position,mode in [('investigator',None),('designer','planning'),('designer','consultation'),('reviewer',None)]:
        b=unbound_fixture(position,'session-'+position+'-'+str(mode),mode)
        b['execution_root']=None;b['absence_reasons']['execution_root']='host supplies final root'
        r=json.loads(request(b,position,fixed=False).stdout)
        pending_context=json.loads((store/r['path']).read_bytes())['extra_context']
        launched=binder.launch_session(pending_context,framework='codex',slug='fixture--w1',execution_root=str(repo),kdir=store)
        m=binder.validate_dispatch(launched['reference']['manifest_path'],launched['reference']['manifest_sha256'])
        assert m['bindings']['task_id'] is None and m['bindings']['revision_id'] is None
        assert set(m['required_bindings'])==set(binder.CORE)|{'packet_id','packet_pointer'}
        assert m['bindings']['packet_id']==b['packet_id']
        absent=copy.deepcopy(b);absent.update(packet_id=None,packet_pointer=None)
        absent['absence_reasons'].update(packet_id='No packet.',packet_pointer='No packet.')
        request(absent,position,fixed=False,ok=False)
    b=unbound_fixture('worker','worker-still-requires-task')
    b['execution_root']=None;b['absence_reasons']['execution_root']='host supplies final root'
    request(b,'worker',fixed=False,ok=False)
elif scenario=='synthesis':
    # A just-built packet is a candidate set: preparing a dispatch against it is refused and leaves no artifacts;
    # synthesis through the published CLI makes the same binding succeed; a builder-recorded waiver also binds.
    committed=publication(str(item),str(store)); revision=committed['revision_id']
    row={'packet_id':'pkt-unsynthesized','packet_scope':'task','work_item':'fixture','task_id':'task-1','revision_id':revision,
         'dispatch_attempt_id':'synth-attempt','source_head':committed['source_head'],'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'}
    build_packet(store,row,assembly=('Candidate content',{}),role='worker',scales=['implementation'])
    b=fixture(attempt='synth-fixture');b.update(packet_id='pkt-unsynthesized',packet_pointer=pointer(store,'pkt-unsynthesized'),dispatch_attempt_id='synth-attempt',report_id='report-synth')
    b['report_path']=str(item/'worker-reports/report-synth.md')
    d=compile()
    refused(lambda: bind(d,b),'candidate set nobody has synthesized')
    assert not (item/'position-dispatch'/'synth-attempt').exists()
    spec=temporary/'synthesis.json';spec.write_text(json.dumps({'dropped':[],'added':[]}))
    out=call(['bash',str(repo/'scripts/packet.sh'),'synthesize','pkt-unsynthesized','--by','fixture-lead','--spec',str(spec)]).stdout
    assert json.loads(out)['delivery_stage']=='synthesized'
    ref=bind(d,b);m=binder.validate_dispatch(ref['manifest_path'],ref['manifest_sha256'])
    assert m['bindings']['packet_id']=='pkt-unsynthesized'
    waived={'packet_id':'pkt-waived','packet_scope':'session','work_item':'fixture','task_id':None,'session_id':None,'phase':None,'arm':None,
            'task_scale_set':'implementation','synthesis_waiver':{'by':'spec-lead','reason':'assembled and dispatched in one verb'}}
    build_packet(store,waived,assembly=('Wave content',{}),role='investigator',scales=['implementation'])
    b=fixture('investigator','waived-attempt');b.update(task_id=None,revision_id=None,packet_id='pkt-waived',packet_pointer=pointer(store,'pkt-waived'))
    b['absence_reasons'].update(task_id='Investigation precedes tasks.',revision_id='No plan revision exists.')
    bind(compile('investigator'),b)
    # Re-validation of an existing publication is not a preparation: an assembled packet bound before the rule still validates there.
    hist={'packet_id':'pkt-historical','packet_scope':'task','work_item':'fixture','task_id':'task-1','revision_id':revision,
          'dispatch_attempt_id':'historical-attempt','source_head':committed['source_head'],'session_id':None,'phase':None,'arm':None,'task_scale_set':'implementation'}
    build_packet(store,hist,assembly=('Historical content',{}),role='worker',scales=['implementation'])
    hb=fixture(attempt='historical-fixture');hb.update(packet_id='pkt-historical',packet_pointer=pointer(store,'pkt-historical'),dispatch_attempt_id='historical-attempt',report_id='report-historical')
    hb['report_path']=str(item/'worker-reports/report-historical.md')
    assert binder.validate_bindings(hb,'worker',store,('task_id','revision_id','packet_id','packet_pointer'),preparation=False)['delivery_stage']=='assembled'
    refused(lambda: binder.validate_bindings(hb,'worker',store,('task_id','revision_id','packet_id','packet_pointer')),'candidate set nobody has synthesized')
elif scenario=='renderer-drift':
    d=compile(framework='claude-code')
    old=bind(d,fixture(attempt='before-drift'))
    adapter=repo/'adapters/agents/claude-code.sh'
    adapter.write_bytes(adapter.read_bytes()+b'\n# Different renderer revision.\n')
    refused(lambda: bind(d,fixture(attempt='stale-renderer')), 'renderer changed')
    assert not (item/'position-dispatch/stale-renderer').exists()
    binder.resolve_dispatch(old['manifest_path'],old['manifest_sha256'])
    fresh=compile(framework='claude-code')
    assert fresh['template_version'] != d['template_version']
    bind(fresh,fixture(attempt='fresh-renderer'))
    capabilities=repo/'adapters/capabilities.json'
    profiles=json.loads(capabilities.read_bytes())
    profiles['frameworks']['claude-code']['position_compilation']['activation_operation']='unsupported'
    capabilities.write_text(json.dumps(profiles))
    refused(lambda: bind(fresh,fixture(attempt='stale-surface')), 'surface changed')
    binder.resolve_dispatch(old['manifest_path'],old['manifest_sha256'])
else:
    raise AssertionError(scenario)
PY
}

@test "binding retains actual native definitions and prompt bytes for twelve position/framework pairs" {
  run exercise_binding native
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "position sessions retain exact queued prompt bytes, mode, routing, placement, and retries" {
  run exercise_binding session
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "position binding refuses invalid modes, missing or conflicting identities and incompatible sessions" {
  run exercise_binding invalid
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "binding retry verifies immutable bytes and requires fresh report and attempt identities" {
  run exercise_binding retry
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "descriptor dependency, registration, and publication failures prevent enqueue" {
  run exercise_binding failures
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "binding preserves replay guidance and counts included contracts and wrapper identity separately" {
  run exercise_binding replay
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "ordinary position queue preparation covers all frameworks and both designer modes" {
  run exercise_binding launch
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "immutable dispatch resolver survives only sanctioned item archival" {
  run exercise_binding archive
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "activation refuses renderer or surface drift while historical dispatches remain readable" {
  run exercise_binding renderer-drift
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "pre-plan packets preserve explicit absence while dispatch attempts remain independently bound" {
  run exercise_binding preplan
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "native subagent selection retains exact activation bytes and requires separate live readiness" {
  run exercise_binding native-selection
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec dispatch delivers compiled investigator inputs, durable reports, replay and explicit sessions" {
  run exercise_binding spec
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec native dispatch selects Claude definitions and preserves foreign and pre-plan session routes" {
  run exercise_binding spec-native
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "implement compiled envelopes preserve canonical native inputs, foreign targets and legacy identities" {
  run exercise_binding implement-envelope
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "implement compiled envelopes inventory rejects unmarked commands and unexercised or changed recipes" {
  run python3 "$REPO/tests/helpers/implement_recipes.py" --self-test --root "$CASE_ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  # Module caches can leave directories that rm cannot traverse for deletion.
  mkdir -p "$CASE_ROOT/readonly-cache/package"
  printf 'cached bytes\n' > "$CASE_ROOT/readonly-cache/package/source"
  chmod -R a-w "$CASE_ROOT/readonly-cache"
}

@test "implement compiled envelopes execute the published recipes through isolated writers" {
  recipe_root="$CASE_ROOT"
  if [ -n "${POSITION_DISPATCH_FIXTURES:-}" ]; then
    recipe_root="$POSITION_DISPATCH_FIXTURES/implement-recipes"
  fi
  run python3 "$REPO/tests/helpers/implement_recipes.py" --run --root "$recipe_root" \
    --source "${IMPLEMENT_RECIPE_SOURCE:-$REPO/skills/implement/SKILL.md}"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "ordinary spec sessions bind physical roots and collect independent prepared references" {
  run exercise_binding spec-session
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "bound spec investigator claims preserve task identity through canonical completion" {
  run exercise_binding spec-claims
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec investigator report fields reject malformed paths, roles and source identities" {
  run exercise_binding spec-report-fields
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "an unsynthesized packet refuses dispatch preparation until synthesized through the CLI; a recorded waiver binds" {
  run exercise_binding synthesis
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
