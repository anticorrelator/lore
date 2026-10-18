"""Migration of per-checkout host keys from before store-scoped hosting onto the store key."""
import contextlib
import datetime
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load('managed_migration', ROOT / 'scripts/session-managed.py')
runtime = m.RUNTIME


def iso(seconds_ago):
    moment = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=seconds_ago)
    return moment.isoformat().replace('+00:00', 'Z')


def legacy_key(kdir, source):
    return hashlib.sha256((str(kdir) + '\0' + str(source)).encode()).hexdigest()[:24]


class MigrationCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.kdir = self.root / 'store'
        (self.kdir / '_sessions').mkdir(parents=True)
        self.source = self.root / 'checkout'
        self.source.mkdir()
        env = {k: v for k, v in os.environ.items() if k not in {'LORE_SESSION_RUNTIME', 'LORE_KNOWLEDGE_DIR'}}
        env['LORE_DATA_DIR'] = str(self.root / 'data')
        environment = patch.dict(os.environ, env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.store = runtime.store_host_key(self.kdir)
        self.old = legacy_key(self.kdir, self.source)
        self.output = io.StringIO()
        m.REPORTED_SKIPS.clear()

    def hosts(self, key):
        return self.kdir / '_sessions/hosts' / key

    def legacy_dir(self, key=None):
        directory = self.hosts(key or self.old)
        directory.mkdir(parents=True, exist_ok=True)
        for name in ('runtime.lock', 'supervisor.lock', 'ensure.lock'):
            (directory / name).touch()
        m.atomic(directory / 'supervisor.json', {'pid': 1, 'host_key': key or self.old})
        return directory

    def record(self, key, kind, name, text):
        path = self.hosts(key) / kind / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode())
        return path

    def manifest(self, handle, key=None, state='enqueued', age=3600, **extra):
        manifest = dict(schema_version=1, handle=handle, work_item=handle.split('--w')[0], host_key=key or self.old,
                        source_dir=str(self.source), request_id='managed-' + hashlib.sha256(handle.encode()).hexdigest()[:32],
                        state=state, created_at=iso(age), context='brief', key_token=None,
                        route={'framework': 'codex', 'model': 'm', 'routing_source': {'layer': 'override', 'role': 'worker'}},
                        framework='codex', model='m', routing_source='override', packet=None)
        manifest.update(extra)
        m.atomic(m.manifest_path(self.kdir, handle), manifest)
        return manifest

    def row(self, state, request_id, key=None, **extra):
        row = dict(request_id=request_id, host_key=key or self.old, type='worker', requested_at=iso(10))
        row.update(extra)
        m.atomic(self.kdir / '_sessions/requests' / state / (request_id + '.json'), row)
        return row

    def prepare(self):
        with contextlib.redirect_stdout(self.output):
            return m.prepare_store(self.kdir)

    def snapshot(self):
        sessions = self.kdir / '_sessions'
        return {str(p.relative_to(sessions)): p.read_bytes() for p in sorted(sessions.rglob('*')) if p.is_file()}

    def journal(self):
        path = self.kdir / '_sessions/events.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def read_manifest(self, handle):
        return m.read(m.manifest_path(self.kdir, handle))


class LedgersAndKeys(MigrationCase):
    def test_ledgers_copy_byte_for_byte_where_absent(self):
        self.legacy_dir()
        sources = [self.record(self.old, 'deliveries', 'op1.json', '{"event": {"event_id": "e1"},  "terminal": false}\n'),
                   self.record(self.old, 'allocations', 'r1.json', '{\n  "epoch": "x"\n}'),
                   self.record(self.old, 'cleanup', 'task--w1.json', '{"cleaned":true}')]
        self.record(self.old, 'deliveries', '.op9.json.tmp', 'partial')
        self.record(self.old, 'deliveries', 'op2.json', '{"from": "old"}')
        existing = self.record(self.store, 'deliveries', 'op2.json', '{"from": "store"}')
        summary = self.prepare()
        self.assertEqual(summary['migrated'][0]['ledger_records'], 3)
        for source in sources:
            target = self.hosts(self.store) / source.parent.name / source.name
            self.assertEqual(target.read_bytes(), source.read_bytes())
        self.assertEqual(existing.read_text(), '{"from": "store"}', 'an existing store record is never replaced')
        self.assertFalse((self.hosts(self.store) / 'deliveries/.op9.json.tmp').exists())
        self.assertTrue(all(p.exists() for p in sources), 'the old records stay in place')

    def test_a_crash_mid_copy_leaves_no_truncated_record(self):
        self.legacy_dir()
        source = self.record(self.old, 'deliveries', 'op1.json', '{"terminal": false}' * 100)
        real_replace = os.replace

        def interrupted(src, dst):
            if str(dst).endswith('deliveries/op1.json'):
                raise OSError('interrupted')
            return real_replace(src, dst)
        with patch.object(m.os, 'replace', side_effect=interrupted):
            summary = self.prepare()
        self.assertIn('migration failed', summary['skipped'][self.old])
        target_dir = self.hosts(self.store) / 'deliveries'
        self.assertEqual(sorted(p.name for p in target_dir.iterdir()) if target_dir.exists() else [], [])
        self.assertFalse((self.hosts(self.old) / 'migrated.json').exists())
        self.prepare()
        self.assertEqual((target_dir / 'op1.json').read_bytes(), source.read_bytes())

    def test_manifests_and_queue_rows_move_to_the_store_key_and_a_tombstone_is_left(self):
        directory = self.legacy_dir()
        other = self.legacy_dir('f' * 24)
        (other / 'migrated.json').write_text('{"schema_version": 1, "from": "ffffffffffffffffffffffff", "to": "x"}')
        moved = self.manifest('task--w1')
        fresh_intent = self.manifest('task--w2', state='intent', age=3600)
        foreign = self.manifest('task--w3', key='e' * 24)
        m.atomic(self.kdir / '_sessions/managed/task--w1.wait.json', {'seen': ['a']})
        pending = self.row('pending', 'p1')
        claimed = self.row('claimed', 'c1', claimed_by='old-host')
        self.row('pending', 'p2', key='e' * 24)
        self.row('expiring', 'x1')
        before = self.snapshot()
        summary = self.prepare()
        [done] = summary['migrated']
        self.assertEqual((done['key'], done['manifests'], done['request_rows'], done['abandoned']), (self.old, 2, 2, []))
        self.assertEqual(self.read_manifest('task--w1'), dict(moved, host_key=self.store))
        self.assertEqual(self.read_manifest('task--w2'), dict(fresh_intent, host_key=self.store))
        self.assertEqual(self.read_manifest('task--w3'), foreign)
        rows = self.kdir / '_sessions/requests'
        self.assertEqual(m.read(rows / 'pending/p1.json'), dict(pending, host_key=self.store))
        self.assertEqual(m.read(rows / 'claimed/c1.json'), dict(claimed, host_key=self.store))
        self.assertEqual(m.read(rows / 'pending/p2.json')['host_key'], 'e' * 24)
        self.assertEqual(m.read(rows / 'expiring/x1.json')['host_key'], self.old)
        tombstone = m.read(directory / 'migrated.json')
        self.assertEqual({k: tombstone[k] for k in ('schema_version', 'from', 'to')},
                         {'schema_version': 1, 'from': self.old, 'to': self.store})
        self.assertIsNotNone(m.instant(tombstone['at']))
        after = self.snapshot()
        for name in ('managed/task--w1.wait.json', f'hosts/{self.old}/supervisor.json', f'hosts/{"f" * 24}/migrated.json'):
            self.assertEqual(after[name], before[name])
        self.assertIn(f'migrated host key {self.old} to {self.store}', self.output.getvalue())


class Fences(MigrationCase):
    def test_skips_while_the_old_host_or_its_supervisor_is_live(self):
        directory = self.legacy_dir()
        self.manifest('task--w1')
        for held in ('runtime.lock', 'supervisor.lock'):
            with (directory / held).open('a+') as stream:
                fcntl.flock(stream, fcntl.LOCK_EX)
                before = self.snapshot()
                summary = self.prepare()
                self.assertEqual(summary['migrated'], [])
                self.assertIn('still running', summary['skipped'][self.old])
                self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.prepare()['migrated'][0]['key'], self.old)
        self.assertEqual(self.read_manifest('task--w1')['host_key'], self.store)

    def test_a_key_that_also_exists_under_a_named_runtime_is_skipped_and_reported_once(self):
        self.legacy_dir()
        self.manifest('task--w1')
        (self.kdir / '_sessions/runtimes/dev/hosts' / self.old).mkdir(parents=True)
        before = self.snapshot()
        for _ in range(3):
            summary = self.prepare()
            self.assertIn('named runtime', summary['skipped'][self.old])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.output.getvalue().count(f'not migrating host key {self.old}'), 1)
        self.assertIn(str(self.kdir / '_sessions/runtimes/dev/hosts' / self.old), self.output.getvalue())

    def test_a_named_runtime_never_migrates(self):
        self.legacy_dir()
        self.manifest('task--w1', state='intent', age=40 * 86400)
        self.row('pending', 'p1')
        before = self.snapshot()
        os.environ['LORE_SESSION_RUNTIME'] = 'dev'
        self.assertEqual(self.prepare(), {'migrated': [], 'skipped': {}})
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.journal(), [])

    def test_a_pending_row_the_sweep_expires_is_never_revived(self):
        self.legacy_dir()
        self.manifest('task--w1')
        row = self.row('pending', 'p1', requested_at=iso(7200), slug='task--w1')
        self.row('expiring', 'x1', slug='task--w1')
        lock = self.kdir / '_sessions/requests/.expiry-sweep.lock'
        lock.mkdir()
        with patch.object(m, 'EXPIRY_LOCK_WAIT_SECONDS', .2):
            summary = self.prepare()
        self.assertIn('expiry sweep holds its lock', summary['skipped'][self.old])
        self.assertFalse((self.hosts(self.old) / 'migrated.json').exists())
        self.assertEqual(m.read(self.kdir / '_sessions/requests/pending/p1.json'), row)
        lock.rmdir()
        sweeps = []
        real_atomic = m.atomic

        def sweep_during_rewrite(path, value):
            if Path(path).parent.name == 'pending':
                sweeps.append(subprocess.run(['bash', str(ROOT / 'scripts/session-request-expire.sh'), '--kdir',
                                              str(self.kdir), '--ttl', '60'], text=True, capture_output=True))
                self.assertTrue(Path(path).exists(), 'a sweep that finds the lock held moves nothing')
            return real_atomic(path, value)
        with patch.object(m, 'atomic', side_effect=sweep_during_rewrite):
            self.prepare()
        self.assertEqual([s.returncode for s in sweeps], [0])
        self.assertEqual(m.read(self.kdir / '_sessions/requests/pending/p1.json')['host_key'], self.store)
        self.assertFalse(lock.exists())
        result = subprocess.run(['bash', str(ROOT / 'scripts/session-request-expire.sh'), '--kdir', str(self.kdir),
                                 '--ttl', '60'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list((self.kdir / '_sessions/requests/pending').glob('*.json')), [])
        self.assertIn('p1', [r['request_id'] for r in self.journal() if r['event'] == 'request_expired'])
        self.prepare()
        self.assertEqual(list((self.kdir / '_sessions/requests/pending').glob('*.json')), [])


class Convergence(MigrationCase):
    def build(self):
        self.legacy_dir()
        self.record(self.old, 'deliveries', 'op1.json', '{"terminal": false}')
        self.record(self.old, 'cleanup', 'task--w1.json', '{"cleaned": true}')
        self.manifest('task--w1')
        self.manifest('task--w2', state='intent', age=30 * 86400)
        self.row('pending', 'p1')

    def normalized(self):
        result = {}
        for name, data in self.snapshot().items():
            if name.endswith('.json') or name.endswith('.jsonl'):
                rows = [json.loads(line) for line in data.decode().splitlines() if line.strip()]
                for row in rows:
                    for field in ('at', 'abandoned_at', 'ts', 'error', 'created_at', 'requested_at'):
                        row.pop(field, None)
                result[name] = rows
            else:
                result[name] = data
        return result

    def test_a_rerun_changes_nothing(self):
        self.build()
        first = self.prepare()
        self.assertEqual(len(first['migrated']), 1)
        before = self.snapshot()
        self.assertEqual(self.prepare(), {'migrated': [], 'skipped': {}})
        self.assertEqual(self.snapshot(), before)

    def test_a_crash_between_any_two_steps_converges_on_the_same_result(self):
        self.build()
        self.prepare()
        expected = self.normalized()
        for step in ('migrate_manifests', 'migrate_request_rows', 'atomic-tombstone', 'abandon_stale_intent'):
            with self.subTest(step=step):
                for path in list((self.kdir / '_sessions').iterdir()):
                    if path.is_dir():
                        subprocess.run(['rm', '-rf', str(path)], check=True)
                    else:
                        path.unlink()
                self.build()
                if step == 'atomic-tombstone':
                    real_atomic = m.atomic

                    def crash(path, value, real=real_atomic):
                        if Path(path).name == 'migrated.json':
                            raise OSError('crashed before the tombstone')
                        return real(path, value)
                    patcher = patch.object(m, 'atomic', side_effect=crash)
                else:
                    patcher = patch.object(m, step, side_effect=RuntimeError('crashed'))
                with patcher:
                    summary = self.prepare()
                self.assertIn('migration failed', summary['skipped'][self.old])
                self.assertFalse((self.hosts(self.old) / 'migrated.json').exists())
                self.prepare()
                self.assertEqual(self.normalized(), expected)
                self.assertEqual(sum(1 for r in self.journal() if r['event'] == 'request_abandoned'), 1)


class StaleIntents(MigrationCase):
    def test_phoenix_shaped_intents_are_abandoned_with_a_journal_row_and_a_recent_one_moves(self):
        stale_key, recent_key = 'a' * 24, 'b' * 24
        stale_dir = self.legacy_dir(stale_key)
        m.atomic(stale_dir / 'supervisor-error.json', {'at': iso(30 * 86400), 'error': 'host restart budget exhausted'})
        self.legacy_dir(recent_key)
        stale = self.manifest('old-item--w1', key=stale_key, state='intent', age=30 * 86400)
        stale_enqueueing = self.manifest('old-item--w2', key=stale_key, state='enqueueing', age=2 * 86400)
        recent = self.manifest('new-item--w1', key=recent_key, state='intent', age=3600)
        summary = self.prepare()
        by_key = {done['key']: done for done in summary['migrated']}
        self.assertEqual(sorted(by_key[stale_key]['abandoned']), sorted([stale['request_id'], stale_enqueueing['request_id']]))
        for manifest in (stale, stale_enqueueing):
            saved = self.read_manifest(manifest['handle'])
            self.assertEqual(saved['state'], 'request_abandoned')
            self.assertEqual(saved['host_key'], stale_key, 'an abandoned intent is not moved to the store key')
            self.assertIn('stale-intent-at-migration', saved['error'])
            self.assertIn('--key', saved['error'])
        rows = [r for r in self.journal() if r['event'] == 'request_abandoned']
        self.assertEqual(sorted(r['request_id'] for r in rows), sorted([stale['request_id'], stale_enqueueing['request_id']]))
        self.assertTrue(all(r['reason'] == 'stale-intent-at-migration' for r in rows))
        self.assertEqual({r['slug'] for r in rows}, {'old-item--w1', 'old-item--w2'})
        self.assertEqual(self.read_manifest('new-item--w1'), dict(recent, host_key=self.store))
        self.assertEqual(m.store_work(self.kdir), {'manifest:new-item--w1'})

    def test_a_same_key_retry_of_an_abandoned_start_reports_the_abandonment(self):
        self.legacy_dir()
        token = hashlib.sha256(b'start-key').hexdigest()
        context = self.root / 'brief.md'
        context.write_text('brief')
        m.atomic(self.kdir / '_work/task/_meta.json', {})
        manifest = self.manifest('task--w1', state='intent', age=30 * 86400, key_token=token)
        m.atomic(self.kdir / '_sessions/start-keys.json', {token: 'task--w1'})
        self.prepare()
        args = SimpleNamespace(workspace=str(self.source), handle='task', framework=None, model=None, session_route=None,
                               context=str(context), key='start-key', packet=None, timeout=0)
        with patch.object(m, 'resolve', return_value=self.kdir), \
                patch.object(m, 'canonical_start_route', return_value=manifest['route']), \
                patch.object(m, 'enqueue_start', side_effect=AssertionError('an abandoned start never spawns')), \
                patch.object(m, 'ensure', side_effect=AssertionError('an abandoned start needs no host')):
            result = m.start(args, self.kdir)
        self.assertEqual((result['handle'], result['outcome']), ('task--w1', 'request_abandoned'))
        self.assertEqual(result['session_state'], 'request_abandoned')


class SingleKeyReaders(MigrationCase):
    def store_host(self, sessions, key=None, name='store-host', source=None):
        key = key or self.store
        directory = self.hosts(key)
        ready = dict(schema_version=2, host_key=key, instance_name=name, pid=os.getpid(), knowledge_dir=str(self.kdir),
                     ready=True, runtime_capabilities=['position-preparation-v1'])
        if source:
            ready.update(schema_version=1, source_dir=source)
        else:
            ready.update(scope='store')
        m.atomic(directory / 'ready.json', ready)
        row = dict(name=name, pid=os.getpid(), role='session-host', host_key=key, sessions=sessions,
                   runtime_capabilities=['position-preparation-v1'])
        if not source:
            row['scope'] = 'store'
        m.atomic(self.kdir / '_sessions/instances' / (name + '.json'), row)
        stream = (directory / 'runtime.lock').open('a+')
        fcntl.flock(stream, fcntl.LOCK_EX)
        self.addCleanup(stream.close)
        return stream

    def test_owner_is_reached_after_a_migration_lands_during_its_wait_loop(self):
        self.legacy_dir()
        stale = self.manifest('task--w1')
        self.store_host([{'slug': 'task--w1', 'tmux': 'lore-store-task'}])
        args = SimpleNamespace(verb='attach', timeout=5)
        migrated = []

        def migrate_then_wait(seconds):
            if not migrated:
                migrated.append(self.prepare())

        class Attached(Exception):
            pass
        with patch.object(m, 'ensure'), patch.object(m.time, 'sleep', side_effect=migrate_then_wait), \
                patch.object(m.os, 'execvpe', side_effect=Attached) as attach:
            with self.assertRaises(Attached):
                m.operate_attempt(args, self.kdir, stale)
        self.assertEqual(migrated[0]['migrated'][0]['key'], self.old)
        self.assertEqual(attach.call_args.args[1][-1], 'lore-store-task')

    def test_an_uncertain_send_whose_delivery_record_was_copied_is_never_republished(self):
        self.legacy_dir()
        self.record(self.old, 'deliveries', 'op1.json', '{"event": {"event_id": "old-host-attempt"}, "terminal": false}')
        stale = self.manifest('task--w1')
        row = dict(request_id='op1', slug='task--w1', target_instance='old-host', body='hello')
        m.receipt(self.kdir, stale, 'op1', 'send', 'uncertain', request=row)
        self.prepare()
        (self.hosts(self.old) / 'deliveries/op1.json').unlink()
        queue = self.kdir / '_sessions/send-requests/op1.json'
        with patch.object(m, 'owner', return_value={'instance_name': 'store-host'}):
            m.reconcile_operations(self.kdir, self.store)
            m.publish_operation(self.kdir, stale, 'send', row)
        self.assertFalse(queue.exists(), 'the copied record proves the old host attempted the input')
        m.receipt(self.kdir, stale, 'op2', 'send', 'uncertain', request=dict(row, request_id='op2'))
        with patch.object(m, 'owner', return_value={'instance_name': 'store-host'}):
            m.reconcile_operations(self.kdir, self.store)
        self.assertEqual(m.read(self.kdir / '_sessions/send-requests/op2.json')['target_instance'], 'store-host')

    def test_a_live_old_host_serves_its_manifests_until_it_exits(self):
        self.legacy_dir()
        manifest = self.manifest('task--w1')
        old_host = self.store_host([{'slug': 'task--w1', 'tmux': 'lore-old-task'}], key=self.old, name='old-host',
                                   source=str(self.source))
        self.assertIn('still running', self.prepare()['skipped'][self.old])
        self.assertEqual(m.owner(self.kdir, manifest)['instance_name'], 'old-host')
        out = io.StringIO()
        with patch.object(m, 'ensure', return_value={'instance_name': 'store-host'}), contextlib.redirect_stdout(out):
            self.assertEqual(m.main(['_source-owner', 'task--w1', '--kdir', str(self.kdir)]), 0)
        self.assertEqual(out.getvalue().strip(), 'old-host')
        old_host.close()
        self.assertIsNone(m.owner(self.kdir, manifest))
        self.assertEqual(self.prepare()['migrated'][0]['key'], self.old)
        self.store_host([{'slug': 'task--w1', 'tmux': 'lore-store-task'}])
        self.assertEqual(m.owner(self.kdir, manifest)['instance_name'], 'store-host')
        out = io.StringIO()
        with patch.object(m, 'ensure', return_value={'instance_name': 'store-host'}), contextlib.redirect_stdout(out):
            m.main(['_source-owner', 'task--w1', '--kdir', str(self.kdir)])
        self.assertEqual(out.getvalue().strip(), 'store-host')


if __name__ == '__main__':
    unittest.main()
