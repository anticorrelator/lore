#!/usr/bin/env python3
"""Prove the host-key migration on a copy of real stores' session state.

For each store under ${LORE_DATA_DIR:-~/.lore}/repos that has _sessions/hosts,
copy only what the migration reads and writes (hosts/, managed/, requests/,
instances/, receipts/, start-keys.json, events.jsonl, and runtimes/*/hosts/;
never worktrees/ or bin/) into a temporary store, run prepare_store there in the
default runtime under an isolated LORE_DATA_DIR, run it again to show a re-run
changes nothing, and check the result. The real files are hashed before and
after. No session host is started.

Usage: session_migration_real_copy.py (--all-stores | --store PATH ...) [--keep]
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
SUBSET = ('hosts', 'managed', 'requests', 'instances', 'receipts', 'start-keys.json', 'events.jsonl')
LEDGERS = ('deliveries', 'allocations', 'cleanup')
RUN = r'''
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('managed', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print('RESULT ' + json.dumps(m.prepare_store(Path(sys.argv[2]))))
'''


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def subset_paths(sessions):
    paths = [sessions / name for name in SUBSET if (sessions / name).exists()]
    paths += sorted(p for p in (sessions / 'runtimes').glob('*/hosts') if p.is_dir())
    return paths


def digest(sessions):
    """A hash over the names, kinds and bytes of the migration's subset of a store."""
    hasher = hashlib.sha256()
    for top in subset_paths(sessions):
        for path in sorted([top, *top.rglob('*')] if top.is_dir() else [top]):
            mode = os.lstat(path).st_mode
            name = str(path.relative_to(sessions)).encode()
            if stat.S_ISLNK(mode):
                hasher.update(b'L' + name + b'\0' + os.readlink(path).encode() + b'\0')
            elif stat.S_ISREG(mode):
                hasher.update(b'F' + name + b'\0' + hashlib.sha256(path.read_bytes()).digest())
            elif stat.S_ISDIR(mode):
                hasher.update(b'D' + name + b'\0')
    return hasher.hexdigest()


def regular_only(directory, names):
    return [n for n in names if not (os.path.isdir(os.path.join(directory, n)) or os.path.islink(os.path.join(directory, n))
                                     or os.path.isfile(os.path.join(directory, n)))]


def copy_subset(real, copy):
    for path in subset_paths(real / '_sessions'):
        target = copy / path.relative_to(real)
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.is_dir():
            shutil.copytree(path, target, symlinks=True, ignore=regular_only)
        else:
            shutil.copy2(path, target, follow_symlinks=False)


def discover(repos):
    stores = []
    for depth in ('*', '*/*', '*/*/*', '*/*/*/*'):
        stores += [p for p in repos.glob(depth) if (p / '_sessions/hosts').is_dir()]
    return sorted(set(stores))


def read(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def instant(value):
    try:
        return datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def prepare(copy, env):
    result = subprocess.run([sys.executable, '-c', RUN, str(SCRIPTS / 'session-managed.py'), str(copy)],
                            env=env, text=True, capture_output=True, timeout=600)
    if result.returncode:
        raise RuntimeError(f'prepare_store failed: {result.stderr.strip()}')
    lines = result.stdout.splitlines()
    return json.loads(lines[-1][len('RESULT '):]), lines[:-1]


def prove(real, workdir, env, managed, now):
    failures = []
    check = lambda ok, message: ok or failures.append(message)
    copy = workdir / 'repos' / real.relative_to(real.anchor)
    copy_subset(real, copy)
    copy = copy.resolve()
    sessions = copy / '_sessions'
    store = managed.RUNTIME.store_host_key(copy, {})
    bound = managed.STALE_INTENT_SECONDS
    hosts = sessions / 'hosts'
    legacy = sorted(p.name for p in hosts.iterdir() if p.is_dir() and p.name != store and not (p / 'migrated.json').exists())
    named = {k for k in legacy if any(p.is_dir() for p in (sessions / 'runtimes').glob(f'*/hosts/{k}'))}
    expected = [k for k in legacy if k not in named]
    manifests = {p.stem: read(p) for p in (sessions / 'managed').glob('*.json') if managed.MANIFEST_HANDLE.fullmatch(p.stem)}
    manifests = {h: v for h, v in manifests.items() if v is not None}
    rows = {(state, p.name): read(p) for state in ('pending', 'claimed') for p in (sessions / 'requests' / state).glob('*.json')}
    ledgers = {(k, kind, p.name): p.read_bytes() for k in expected for kind in LEDGERS
               for p in sorted((hosts / k / kind).glob('*.json')) if not p.name.startswith('.') and p.is_file()}
    old_files = {p: p.read_bytes() for k in expected for p in (hosts / k).rglob('*') if p.is_file()}

    def stale(manifest):
        created = instant(manifest.get('created_at'))
        return manifest.get('state') in {'intent', 'enqueueing'} and (created is None or now - created > bound)
    to_abandon = {h for h, v in manifests.items() if v.get('host_key') in expected and stale(v)}

    summary, log = prepare(copy, env)
    migrated = {done['key']: done for done in summary['migrated']}
    check(sorted(migrated) == expected, f'migrated keys {sorted(migrated)} != expected {expected}; skipped: {summary["skipped"]}')
    for key in expected:
        tombstone = read(hosts / key / 'migrated.json') or {}
        check({k: tombstone.get(k) for k in ('schema_version', 'from', 'to')} == {'schema_version': 1, 'from': key, 'to': store},
              f'{key}: migrated.json is {tombstone}')
    for key in named:
        check(not (hosts / key / 'migrated.json').exists(), f'{key}: migrated although it exists under a named runtime')
        check('named runtime' in summary['skipped'].get(key, ''), f'{key}: named-runtime skip not reported')
    journal = [json.loads(line) for line in (sessions / 'events.jsonl').read_text().splitlines() if line.strip()] \
        if (sessions / 'events.jsonl').exists() else []
    abandoned_rows = {r.get('request_id') for r in journal
                      if r.get('event') == 'request_abandoned' and r.get('reason') == 'stale-intent-at-migration'}
    abandoned_ids = set()
    for handle, before in manifests.items():
        after = read(sessions / 'managed' / (handle + '.json'))
        if before.get('host_key') not in expected:
            check(after == before, f'{handle}: a manifest of an unmigrated key changed')
        elif handle in to_abandon:
            abandoned_ids.add(before['request_id'])
            check(after.get('state') == 'request_abandoned' and after.get('host_key') == before['host_key']
                  and 'stale-intent-at-migration' in after.get('error', ''), f'{handle}: stale intent not abandoned: {after}')
            check(before['request_id'] in abandoned_rows, f'{handle}: no request_abandoned journal row')
        else:
            check(after == dict(before, host_key=store), f'{handle}: manifest not moved to the store key unchanged')
    for handle in manifests:
        after = read(sessions / 'managed' / (handle + '.json')) or {}
        check(not (after.get('host_key') == store and stale(after)), f'{handle}: a stale intent was revived on the store key')
    for (state, name), before in rows.items():
        after = read(sessions / 'requests' / state / name)
        if before and before.get('host_key') in expected and before.get('request_id') not in abandoned_ids:
            check(after == dict(before, host_key=store), f'requests/{state}/{name}: not moved to the store key')
        else:
            check(after == before, f'requests/{state}/{name}: changed although it was not migrated')
    by_name = {}
    for (key, kind, name), data in ledgers.items():
        by_name.setdefault((kind, name), []).append(data)
    collisions = sorted(f'{kind}/{name}' for (kind, name), sources in by_name.items() if len(sources) > 1)
    for (kind, name), sources in by_name.items():
        target = hosts / store / kind / name
        check(target.is_file() and target.read_bytes() in sources, f'{kind}/{name}: not copied byte for byte from its source')
    for path, data in old_files.items():
        check(path.is_file() and path.read_bytes() == data, f'{path}: an old record changed or vanished')
    once = digest(sessions)
    again, _ = prepare(copy, env)
    check(again['migrated'] == [], f'a re-run migrated again: {again["migrated"]}')
    check(digest(sessions) == once, 'a re-run changed the copied state')
    report = dict(store=str(real), legacy_keys=len(legacy), migrated=len(migrated), named_runtime_skips=sorted(named),
                  manifests=len(manifests),
                  manifests_moved=sum(d['manifests'] for d in migrated.values()),
                  intents_abandoned=sorted(to_abandon), request_rows_moved=sum(d['request_rows'] for d in migrated.values()),
                  ledger_records_copied=sum(d['ledger_records'] for d in migrated.values()),
                  ledger_records_seen=len(ledgers), ledger_name_collisions=collisions, skipped=summary['skipped'])
    return report, failures, log


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--all-stores', action='store_true')
    parser.add_argument('--store', action='append', default=[])
    parser.add_argument('--keep', action='store_true', help='keep the temporary copies')
    args = parser.parse_args()
    data = Path(os.environ.get('LORE_DATA_DIR') or Path.home() / '.lore')
    stores = [Path(s).resolve() for s in args.store]
    if args.all_stores:
        stores += discover(data / 'repos')
    if not stores:
        parser.error('name --all-stores or at least one --store')
    workdir = Path(tempfile.mkdtemp(prefix='lore-migration-proof-'))
    env = {k: v for k, v in os.environ.items() if k not in {'LORE_SESSION_RUNTIME', 'LORE_KNOWLEDGE_DIR'}}
    env['LORE_DATA_DIR'] = str(workdir / 'data')
    os.environ.pop('LORE_SESSION_RUNTIME', None)
    managed = load('managed_proof', SCRIPTS / 'session-managed.py')
    now = datetime.datetime.now(datetime.timezone.utc).timestamp()
    failed = False
    try:
        for real in stores:
            before = digest(real / '_sessions')
            report, failures, log = prove(real, workdir, env, managed, now)
            after = digest(real / '_sessions')
            if after != before:
                failures.append(f'the real session state of {real} changed during the proof')
            report['real_subset_sha256'] = before
            print(json.dumps(report, indent=2))
            for line in log:
                print('  log: ' + line)
            for failure in failures:
                print('FAIL: ' + failure)
            failed = failed or bool(failures)
            print(('FAILED ' if failures else 'OK ') + str(real))
    finally:
        if args.keep:
            print(f'copies kept in {workdir}')
        else:
            shutil.rmtree(workdir, ignore_errors=True)
    print('FAILED' if failed else f'OK: {len(stores)} store(s) proved')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
