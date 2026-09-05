#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
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
import runpy
from pathlib import Path
import shutil
import subprocess
import sys

import yaml

original, temporary, scenario = sys.argv[1:]
original, temporary = Path(original).resolve(), Path(temporary).resolve()
if os.environ.get('POSITION_DISPATCH_FIXTURES') and scenario in ('native', 'session', 'launch'):
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
from packet_builder import build_packet, pointer, show

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
    b = dict.fromkeys(binder.FIELDS)
    b.update(work_item='fixture', task_id='task-1', revision_id=revision, packet_id=packet_id, packet_pointer=pointer(store, packet_id),
             dispatch_attempt_id=attempt, assignment='Inspect actual bytes.\nPreserve Unicode: λ and trailing newline.\n', report_id='report-' + attempt,
             report_path=str(item / ('worker-reports' if position == 'worker' else 'outputs') / ('report-' + attempt + '.md')),
             execution_root=str(repo), mode=mode)
    if mode == 'consultation':
        b.update(consultation_id='consult-1', domain='storage', reply_destination='requesting-worker')
    b['absence_reasons'] = {key: 'not applicable to this assignment' for key,value in b.items() if value is None}
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
    path = temporary / 'context.json'; path.write_text(json.dumps(context))
    return call(['bash', str(repo / 'scripts/session-request.sh'), '--type', 'worker', '--slug', 'fixture--w1', '--anywhere',
                 '--position', position, '--framework', framework, '--packet', b['packet_id'] or '',
                 *(['--worktree-id', 'fixture-worktree', '--execution-dir', str(repo)] if fixed else []), '--context', str(path), '--kdir', str(store), '--json', *flags], ok=ok)

def pending():
    return list((store / '_sessions/requests/pending').glob('*.json'))

if scenario == 'native':
    examples=[]
    for position in binder.POSITIONS:
        for framework in ('claude-code','codex','opencode'):
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
            examples.append({'position':position,'framework':framework,**ref,'template_version':d['template_version']})
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    print(json.dumps(examples))
elif scenario=='launch':
    examples=[]
    for fw in ('claude-code', 'codex', 'opencode'):
        for position,mode in [('worker',None),('investigator',None),('designer','planning'),('designer','consultation'),('reviewer',None)]:
            b=fixture(position, fw+'-'+position+'-'+str(mode), mode=mode)
            b['execution_root']=None; b['absence_reasons']['execution_root']='ordinary host supplies final directory'
            r=json.loads(request(b, position, fw, flags=('--model','provider/opaque-model'), fixed=False).stdout)
            row_path=store/r['path']; row=json.loads(row_path.read_bytes())
            assert set(row['extra_context'])=={'position_preparation'}
            assert not (item/'position-dispatch'/b['dispatch_attempt_id']).exists()
            examples.append({'position':position,'framework':fw,'mode':mode,'queue_path':str(row_path),'kdir':str(store)})
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
    (temporary/'examples.json').write_text(json.dumps(examples,indent=2))
    print(json.dumps(examples))
elif scenario=='archive':
    refs=[]
    for fw in ('claude-code','codex','opencode'):
        d=compile('reviewer',fw);b=fixture('reviewer','archive-'+fw)
        execution=repo/('execution-'+fw);execution.mkdir();b['execution_root']=str(execution)
        refs.append(bind(d,b));execution.rmdir()
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda r:binder.resolve_dispatch(r['manifest_path'],r['manifest_sha256']),refs))
    archived=store/'_archive/fixture';archived.parent.mkdir();item.rename(archived)
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
    # Active item with the same slug cannot borrow an archived attempt.
    item.mkdir()
    refused(lambda:binder.resolve_dispatch(refs[0]['manifest_path'],refs[0]['manifest_sha256']))
    refused(lambda:binder.resolve_dispatch(archived/'position-dispatch/archive-claude-code/manifest.json',refs[0]['manifest_sha256']),'conflict')
elif scenario=='session':
    examples=[]
    for position,mode in [('designer','planning'),('reviewer',None),('designer','consultation'),('investigator',None),('worker',None)]:
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
        examples.append({'position':position,'mode':mode,'queue_path':str(row_path),**ref})
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
