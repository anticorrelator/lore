#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$CASE_ROOT"
}

exercise() {
  python3 - "$REPO" "$CASE_ROOT" "$1" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import yaml

original, temporary, scenario = map(str, sys.argv[1:])
original, temporary = Path(original), Path(temporary)
repo, home = temporary / 'checkout', temporary / 'home'
repo.mkdir(); home.mkdir()
for name in ('scripts', 'adapters', 'agents', 'docs', 'cli', 'skills', 'claude-md'):
    shutil.copytree(original / name, repo / name)
shutil.copy2(original / 'install.sh', repo / 'install.sh')
store = home / '.lore'
(store / 'config').mkdir(parents=True)
(store / 'scripts').symlink_to(repo / 'scripts')
(store / 'config/settings.json').write_text('{"version":1}\n')
env = dict(os.environ, HOME=str(home), LORE_DATA_DIR=str(store), LORE_FRAMEWORK='codex', LORE_MODEL_WORKER='not-a-model/provider')
for name in ('LORE_KNOWLEDGE_DIR', 'LORE_REGISTRY_LOCK_HELD'):
    env.pop(name, None)

def call(args, ok=True, **kwargs):
    p = subprocess.run(args, cwd=repo, env=env, capture_output=True, **kwargs)
    if ok:
        assert p.returncode == 0, p.stderr.decode(errors='replace') + p.stdout.decode(errors='replace')
    else:
        assert p.returncode != 0, p.stdout
        assert not p.stdout, 'failure returned a descriptor'
    return p

def compile(position='worker', framework='codex', ok=True, extra=()):
    p = call(['bash', str(repo / 'cli/lore'), 'position', 'compile', position, '--framework', framework, '--kdir', str(store), *extra], ok=ok)
    return json.loads(p.stdout) if ok else p

def sha(data):
    return hashlib.sha256(data).hexdigest()

def inspect(d):
    data = Path(d['artifact_path']).read_bytes()
    prompt = Path(d['prompt_path']).read_bytes()
    assert sha(data) == d['artifact_sha256']
    assert sha(prompt) == d['prompt_sha256']
    assert len(d['template_version']) == 12
    assert sha(Path(d['descriptor_path']).read_bytes()) == d['descriptor_sha256']
    if d['framework'] == 'codex':
        assert data == prompt and not data.startswith(b'---')
    else:
        _, header, body = data.split(b'---\n', 2)
        meta = yaml.safe_load(header)
        assert body == prompt
        assert 'model' not in meta
        if d['framework'] == 'claude-code':
            assert meta['name'] == 'position-' + d['position']
            assert 'Bash' in meta['tools']
            assert ('Edit' in meta['tools']) == (d['position'] == 'worker')
        else:
            assert meta['mode'] == 'subagent'
            assert meta['permission']['bash'] == 'allow'
            assert meta['permission']['edit'] == ('allow' if d['position'] == 'worker' else 'deny')
    contract = d['contract_references'][0]
    assert Path(contract['path']).read_bytes() == (repo / 'docs/position-report-contracts.md').read_bytes()
    assert sha(Path(contract['path']).read_bytes()) == contract['sha256']
    source = (repo / 'agents/positions' / (d['position'] + '.md')).read_bytes()
    resolved = source.replace(b'docs/position-report-contracts.md', contract['path'].encode())
    assert prompt.endswith(resolved)
    assert b'docs/position-report-contracts.md' not in prompt
    assert b'{{template_version}}' not in prompt
    assert ('Template-version: ' + d['template_version']).encode() in prompt
    assert all(value is None for value in d['dispatch_bindings'].values())
    assert d['accounting']['prompt_bytes'] == len(prompt)
    assert d['accounting']['body_bytes'] + d['accounting']['guidance_bytes'] + 1 == len(prompt)
    call(['bash', str(repo / 'scripts/validate-dispatch-guidance.sh'), '--prompt-file', d['prompt_path']])
    spec = importlib.util.spec_from_file_location('position_compile', repo / 'scripts/position_compile.py')
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    mod.validate_descriptor(d)
    print(json.dumps({key:d[key] for key in ('position','framework','template_id','template_version','artifact_path','prompt_sha256')}))
    return mod

if scenario == 'matrix':
    pairs = [(p, f) for p in ('investigator','designer','worker','reviewer') for f in ('claude-code','codex','opencode')]
    with ThreadPoolExecutor(max_workers=4) as pool:
        descriptors = list(pool.map(lambda pair: compile(*pair), pairs))
    for d in descriptors: inspect(d)
    registry = json.loads((store / '_scorecards/template-registry.json').read_text())
    assert len(registry['entries']) == 12
    assert not list(store.rglob('task-claims.jsonl'))
    assert not list(store.rglob('results.jsonl'))
    assert not list(store.rglob('packets.jsonl'))
    assert {e['template_id'] for e in registry['entries']} == {d['template_id'] for d in descriptors}
    with ThreadPoolExecutor(max_workers=4) as pool:
        repeats = list(pool.map(lambda _: compile(), range(4)))
    assert len({d['descriptor_sha256'] for d in repeats}) == 1
    assert len(json.loads((store / '_scorecards/template-registry.json').read_text())['entries']) == 12
elif scenario == 'stability':
    first = compile(); inspect(first)
    guidance = Path(first['guidance_path']).read_text()
    for timestamp in ('2000-01-01T00:00:00Z', '2099-12-31T23:59:59Z'):
        path = temporary / 'guidance.md'
        path.write_text(guidance.replace('<invocation>',timestamp))
        d = compile(extra=('--guidance-file',str(path)))
        assert d == first
    contract_path = repo / 'docs/position-report-contracts.md'
    retained = Path(first['contract_references'][0]['path']).read_bytes()
    contract_path.write_bytes(contract_path.read_bytes() + b'\n')
    second = compile()
    assert second['template_version'] != first['template_version']
    assert Path(first['contract_references'][0]['path']).read_bytes() == retained
    for filename in ('agents/positions/worker.md','scripts/position_compile.py','adapters/agents/codex.sh'):
        path = repo / filename
        path.write_bytes(path.read_bytes()+b'\n')
        third = compile()
        assert third['template_version'] != second['template_version'], filename
        second = third
    (store / 'config/settings.json').write_text('{"version":1,"changed":true}\n')
    assert compile()['template_version'] != second['template_version']
elif scenario == 'invalid':
    compile('unknown',ok=False)
    compile(framework='unknown',ok=False)
    compile(extra=('--packet-id','not-a-compiler-binding'),ok=False)
    for filename in ('agents/positions/worker.md','docs/position-report-contracts.md'):
        path=repo/filename; content=path.read_bytes(); path.unlink()
        compile(ok=False); path.write_bytes(b'broken\n'); compile(ok=False); path.write_bytes(content)
    guidance = temporary/'bad-guidance.md'; guidance.write_text('wrong\n')
    compile(ok=False, extra=('--guidance-file',str(guidance)))
    renderer = repo/'adapters/agents/codex.sh'; content=renderer.read_bytes()
    renderer.write_text('#!/bin/bash\nprintf malformed\n')
    compile(ok=False); renderer.write_bytes(content)
    assert not (store/'_scorecards/template-registry.json').exists()
elif scenario == 'retained-failure':
    d=compile(); mod=inspect(d)
    retained=Path(d['contract_references'][0]['path']); data=retained.read_bytes()
    for replacement in (b'wrong\n',None):
        if replacement is None: retained.unlink()
        else: retained.write_bytes(replacement)
        try: mod.validate_descriptor(d)
        except (ValueError,OSError): pass
        else: raise AssertionError('invalid retained dependency accepted')
        compile(ok=False)
        retained.write_bytes(data)
    assert compile()==d
elif scenario == 'registry-failure':
    writer=repo/'scripts/template-registry-register.sh'; content=writer.read_bytes()
    writer.write_text('#!/bin/bash\necho "registration unavailable" >&2\nexit 1\n')
    p=compile(ok=False); assert b'registration unavailable' in p.stderr
    writer.write_bytes(content)
    d=compile(); inspect(d)
    registry=store/'_scorecards/template-registry.json'
    data=registry.read_bytes(); registry.write_text('malformed\n'); compile(ok=False); registry.write_bytes(data)
    rows=json.loads(data); rows['entries'][0]['template_path']='/wrong/path'
    registry.write_text(json.dumps(rows)); compile(ok=False)
    registry.write_bytes(data); assert compile()==d
elif scenario == 'installation':
    legacy={name:(repo/'agents'/name).read_bytes() for name in ('worker.md','researcher.md','advisor.md')}
    for fw in ('claude-code','codex','opencode'):
        p=call(['bash',str(repo/'install.sh'),'--framework',fw])
        print(p.stdout.decode())
        agents=home/('.codex/agents' if fw=='codex' else '.claude/agents')
        for pos in ('investigator','designer','worker','reviewer'):
            target=agents/f'position-{pos}-{fw}.md'
            assert target.is_symlink()
            d=json.loads((target.resolve().parent/'descriptor.json').read_text())
            d['descriptor_sha256']=sha(Path(d['descriptor_path']).read_bytes())
            inspect(d)
            assert Path(d['install_target'])==target
        for name,data in legacy.items():
            assert (agents/name).is_symlink() and (agents/name).read_bytes()==data
        instruction=home/({'claude-code':'.claude/CLAUDE.md','codex':'.codex/AGENTS.md','opencode':'.config/opencode/AGENTS.md'}[fw])
        assert instruction.is_file() and 'LORE:BEGIN' in instruction.read_text()
        call(['bash',str(repo/'scripts/assemble-instructions.sh'),'--framework',fw,'--check'])
    before={path:path.read_bytes() for path in store.glob('_templates/positions/*/*/*/native.md')}
    call(['bash',str(repo/'install.sh'),'--uninstall'])
    assert all(path.read_bytes()==data for path,data in before.items())
    assert not list(home.glob('.claude/agents/position-*.md'))
    assert not list(home.glob('.codex/agents/position-*.md'))
else:
    raise AssertionError(scenario)
PY
}

@test "all twelve native position artifacts preserve authored bytes and concurrent registrations" {
  exercise matrix
}

@test "timestamps reuse identity while every reusable dependency invalidates it" {
  exercise stability
}

@test "bad positions frameworks dependencies guidance and rendering emit no descriptor" {
  exercise invalid
}

@test "retained dependencies refuse corruption and missing bytes before reuse or dispatch" {
  exercise retained-failure
}

@test "registration failures and conflicting historical paths refuse and recover safely" {
  exercise registry-failure
}

@test "isolated installations resolve all native positions retain legacy links and assemble instructions" {
  exercise installation
}
