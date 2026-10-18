import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import os

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('managed', ROOT / 'scripts/session-managed.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ManagedSessions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.kdir = Path(self.tmp.name)
        self.source = self.kdir / 'source'
        self.source.mkdir()
        m.atomic(self.kdir / '_work/task/_meta.json', {})
        self.context = self.kdir / 'context.txt'
        self.context.write_text('Do the task.')
        self.data = self.kdir / 'data'
        m.atomic(self.data / 'config/settings.json', {
            'version': 2, 'tui_launch_framework': 'codex',
            'routes': {'default': 'codex/default', 'worker': 'codex/model-a'},
            'harnesses': {'codex': {'args': [], 'native_models': {'default': 'gpt-5.5-high'}}}})
        environment = patch.dict(os.environ, {'LORE_DATA_DIR': str(self.data)})
        environment.start()
        self.addCleanup(environment.stop)
    def args(self, **kwargs):
        values = dict(workspace=str(self.source), handle='task', framework='codex',
                      model='model-a', context=str(self.context), key='request-a', timeout=0)
        values.update(kwargs)
        return type('Args', (), values)()

    def start(self, args):
        def enqueue(kdir, manifest):
            manifest['state'] = 'enqueued'
            m.atomic(m.manifest_path(kdir, manifest['handle']), manifest)
        with patch.object(m, 'resolve', return_value=self.kdir), patch.object(m, 'ensure'), patch.object(m, 'enqueue_start', side_effect=enqueue):
            return m.start(args, self.kdir)

    def test_key_reuses_handle_and_rejects_changed_intent(self):
        first = self.start(self.args())
        second = self.start(self.args())
        self.assertEqual(first['handle'], second['handle'])
        self.assertEqual(first['request_id'], second['request_id'])
        with self.assertRaisesRegex(RuntimeError, 'different start intent'):
            self.start(self.args(model='model-b'))
        self.context.write_text('Changed task')
        with self.assertRaisesRegex(RuntimeError, 'different start intent'):
            self.start(self.args())

    def test_crash_between_manifest_and_key_index_does_not_duplicate(self):
        first = self.start(self.args())
        (self.kdir / '_sessions/start-keys.json').unlink()
        second = self.start(self.args())
        self.assertEqual(first['handle'], second['handle'])

    def test_no_key_is_always_new(self):
        self.assertNotEqual(self.start(self.args(key=None))['handle'], self.start(self.args(key=None))['handle'])

    def test_mismatched_source_is_never_overwritten(self):
        path = self.kdir / '_work/task/_meta.json'
        m.atomic(path, {'source_checkout': '/different/source'})
        with self.assertRaisesRegex(RuntimeError, 'was not changed'):
            self.start(self.args())
        self.assertEqual(m.read(path)['source_checkout'], '/different/source')
        self.assertFalse((self.kdir / '_sessions/managed').exists())

    def test_uncertain_receipt_survives_cleanup(self):
        first = self.start(self.args())
        manifest = m.read(m.manifest_path(self.kdir, first['handle']))
        status = m.inspect(self.kdir, manifest)
        self.assertEqual(status['receipts'][0]['outcome'], 'uncertain')
        self.assertFalse(status['receipts'][0]['outcome_confirmed'])
        self.assertIsNone(status['owner'])

    def test_close_receipt_requires_own_correlation(self):
        manifest = {'handle': 'task--w123'}
        rows = [{'event': 'closed', 'slug': 'task--w123', 'request_id': 'other'}]
        with patch.object(m, 'events', return_value=rows):
            result = m.await_outcome(self.kdir, manifest, 'own', 'close', 0)
        self.assertEqual(result['outcome'], 'uncertain')
        m.atomic(m.host_dir(self.kdir, 'unknown') / 'cleanup/task--w123.json', {'cleaned': True})
        rows.append({'event': 'closed', 'slug': 'task--w123', 'close_request_ids': ['own']})
        with patch.object(m, 'events', return_value=rows):
            result = m.await_outcome(self.kdir, manifest, 'own', 'close', 0)
        self.assertEqual(result['outcome'], 'closed')

    def test_no_replay_when_spawn_event_outlives_queue(self):
        manifest = dict(handle='task--w123', request_id='managed-123', host_key='key', source_dir=str(self.source), state='enqueueing')
        with patch.object(m, 'events', return_value=[{'event': 'spawned', 'request_id': 'managed-123'}]), patch.object(m, 'run') as writer:
            m.enqueue_start(self.kdir, manifest)
        writer.assert_not_called()
        self.assertEqual(manifest['state'], 'enqueued')

    def test_receipt_only_intent_is_reconciled_but_attempted_input_is_not(self):
        manifest = dict(handle='task--w123', host_key='abc', source_dir=str(self.source))
        m.atomic(m.manifest_path(self.kdir, manifest['handle']), manifest)
        row = dict(request_id='op1', slug=manifest['handle'], target_instance='dead', body='hello')
        m.receipt(self.kdir, manifest, 'op1', 'send', 'uncertain', request=row)
        with patch.object(m, 'owner', return_value={'instance_name': 'current'}):
            m.reconcile_operations(self.kdir, 'abc')
        queue = self.kdir / '_sessions/send-requests/op1.json'
        self.assertEqual(m.read(queue)['target_instance'], 'current')
        queue.unlink()
        m.atomic(m.host_dir(self.kdir, 'abc') / 'deliveries/op1.json', {'terminal': False})
        with patch.object(m, 'owner', return_value={'instance_name': 'current'}):
            m.reconcile_operations(self.kdir, 'abc')
        self.assertFalse(queue.exists(), 'uncertain input must never be injected twice')

    def test_runtime_uncertain_refusal_is_not_reported_as_rejected_input(self):
        row = dict(event='send_refused', slug='task--w123', request_id='op1', reason='delivery-uncertain')
        with patch.object(m, 'events', return_value=[row]):
            result = m.await_outcome(self.kdir, {'handle': 'task--w123'}, 'op1', 'send', 0)
        self.assertEqual(result['outcome'], 'uncertain')
        self.assertFalse(result['outcome_confirmed'])

    def test_close_existing_links_correlation_and_quarantine_disposition(self):
        m.atomic(m.host_dir(self.kdir, 'unknown') / 'cleanup/task--w123.json', {'cleaned': True})
        rows = [dict(event='worktree_quarantined', slug='task--w123', reason='source changed', links={'result_ref': 'refs/kept'}),
                dict(event='closed', slug='task--w123', request_id='spawn', links={'close_requests': '["close-own"]'})]
        with patch.object(m, 'events', return_value=rows):
            result = m.await_outcome(self.kdir, {'handle': 'task--w123'}, 'close-own', 'close', 0)
        self.assertEqual(result['outcome'], 'closed')
        self.assertTrue(result['disposition']['cleanup_confirmed'])
        self.assertTrue(result['disposition']['composition_judgment_required'])
        self.assertFalse(result['disposition']['integrated'])
        self.assertEqual(result['disposition']['result_ref'], 'refs/kept')

    def test_closed_event_does_not_claim_unfinished_cleanup(self):
        row = dict(event='closed', slug='task--w123', request_id='own')
        with patch.object(m, 'events', return_value=[row]):
            result = m.await_outcome(self.kdir, {'handle': 'task--w123'}, 'own', 'close', 0)
        self.assertEqual(result['outcome'], 'uncertain')
        self.assertFalse(result['disposition']['cleanup_confirmed'])

    def test_close_settles_on_a_retained_checkout(self):
        # The host left the checkout on disk because its content is not in any
        # ref. Close reports that instead of waiting for a cleanup that cannot
        # happen and timing out as uncertain.
        reason = 'e1: session worktree content is not proven preserved: content at /tmp/x is not reachable from any preserved ref'
        m.atomic(m.host_dir(self.kdir, 'unknown') / 'cleanup/task--w123.json',
                 {'epoch': 'e1', 'cleaned': False, 'retained': reason})
        row = dict(event='closed', slug='task--w123', request_id='own')
        with patch.object(m, 'events', return_value=[row]):
            result = m.await_outcome(self.kdir, {'handle': 'task--w123'}, 'own', 'close', 0)
        self.assertEqual(result['outcome'], 'closed')
        self.assertFalse(result['disposition']['cleanup_confirmed'])
        self.assertEqual(result['disposition']['cleanup_retained'], reason)

    def test_real_appender_accepts_uncertain_answer(self):
        m.append(self.kdir, dict(event='answer_refused', slug='task--w123', request_id='op1', option=2, reason='delivery-uncertain'))
        self.assertEqual(m.events(self.kdir, 'task--w123')[0]['reason'], 'delivery-uncertain')

    def test_incremental_journal_resumes_torn_tail_and_rotation(self):
        path = self.kdir / '_sessions/events.jsonl'
        path.parent.mkdir()
        path.write_text('{"slug":"task--w1","event":"spawned"}\n{"slug":"task--w1"')
        self.assertEqual(len(m.events(self.kdir, 'task--w1')), 1)
        with path.open('a') as stream:
            stream.write(',"event":"closed"}\n')
        self.assertEqual([r['event'] for r in m.events(self.kdir, 'task--w1')], ['spawned', 'closed'])
        self.assertEqual(len(m.events(self.kdir, 'task--w1')), 2)
        path.unlink()
        path.write_text('{"slug":"task--w1","event":"recovered"}\n')
        self.assertEqual([r['event'] for r in m.events(self.kdir, 'task--w1')], ['recovered'])

    def test_packet_is_part_of_idempotent_dispatch_intent(self):
        first = self.start(self.args(packet='packet-a'))
        manifest = m.read(m.manifest_path(self.kdir, first['handle']))
        self.assertEqual(manifest['packet'], 'packet-a')
        with self.assertRaisesRegex(RuntimeError, 'different start intent'):
            self.start(self.args(packet='packet-b'))

    def test_recovered_process_confirms_start_without_spawned_event(self):
        manifest = dict(handle='task--w123', host_key='key', source_dir=str(self.source), state='enqueued')
        rows = [dict(event='recovered', slug=manifest['handle'], request_id='own')]
        with patch.object(m, 'events', return_value=rows), patch.object(m, 'owner', return_value={'instance_name': 'new'}):
            result = m.await_outcome(self.kdir, manifest, 'own', 'start', 0)
            self.assertEqual(m.inspect(self.kdir, manifest)['state'], 'running')
        self.assertEqual(result['outcome'], 'recovered')
        self.assertTrue(result['outcome_confirmed'])

    def test_timeout_cannot_overwrite_concurrent_confirmed_receipt(self):
        manifest = {'handle': 'task--w123'}
        m.receipt(self.kdir, manifest, 'own', 'send', 'sent')
        result = m.receipt(self.kdir, manifest, 'own', 'send', 'uncertain')
        self.assertEqual(result['outcome'], 'sent')
        self.assertTrue(result['outcome_confirmed'])

    def test_ready_runtime_regains_a_missing_supervisor(self):
        with patch.object(m, 'ready', return_value={'instance_name': 'alive', 'runtime_capabilities': ['position-preparation-v1']}), patch.object(m, 'held', return_value=False), patch.object(m, 'binary', return_value=Path('/fake/binary')) as binary, patch.object(m.RUNTIME, 'sandbox_reason', return_value=''), patch.object(m.subprocess, 'Popen') as launch:
            result = m.ensure(self.kdir, 0)
        self.assertEqual(result['instance_name'], 'alive')
        launch.assert_called_once()
        self.assertIn('_supervise', launch.call_args.args[0])
        binary.assert_not_called()
        served = m.read(self.data / 'session-runtime/served.json')
        self.assertIn(str(self.kdir.resolve()), served['stores'])

    def test_start_keys_the_manifest_to_the_store_host(self):
        first = self.start(self.args())
        manifest = m.read(m.manifest_path(self.kdir, first['handle']))
        self.assertEqual(manifest['host_key'], m.RUNTIME.store_host_key(self.kdir))
        self.assertEqual(manifest['source_dir'], str(self.source.resolve()))
        other = self.kdir / 'other-source'
        other.mkdir()
        second = self.start(self.args(workspace=str(other), key='request-b'))
        self.assertEqual(m.read(m.manifest_path(self.kdir, second['handle']))['host_key'], manifest['host_key'])

    def test_supervisor_replay_uses_the_supervisor_status_without_ensuring(self):
        manifest = dict(handle='task--w123', request_id='managed-123', host_key='key', source_dir=str(self.source),
                        work_item='task', state='intent', context='Do it.', route={'framework': 'codex'})
        status = {'instance_name': 'store-host', 'runtime_capabilities': ['position-preparation-v1']}
        calls = []
        with patch.object(m, 'ensure', side_effect=AssertionError('the supervisor never waits on itself')), \
                patch.object(m, 'ready', return_value=status), \
                patch.object(m, 'run', side_effect=lambda argv, **kw: calls.append([str(a) for a in argv]) or '{}'):
            m.enqueue_start(self.kdir, manifest, status)
        self.assertEqual(manifest['state'], 'enqueued')
        request = next(c for c in calls if c[1].endswith('session-request.sh'))
        self.assertEqual(request[request.index('--target') + 1], 'store-host')

    def test_ensure_inside_the_supervisor_never_waits(self):
        with patch.object(m, 'STORE_ENV', {'PATH': '/bin'}), patch.object(m, 'ready', return_value=None), \
                patch.object(m.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(RuntimeError, 'not ready'):
                m.ensure(self.kdir, 45)
        launch.assert_not_called()

    def test_owner_reads_the_manifest_key_fresh(self):
        store = m.RUNTIME.store_host_key(self.kdir)
        stale = dict(handle='task--w123', host_key='old-key', source_dir=str(self.source))
        m.atomic(m.manifest_path(self.kdir, stale['handle']), dict(stale, host_key=store))
        m.atomic(self.kdir / '_sessions/instances/store-host.json', {'sessions': [{'slug': 'task--w123'}]})
        asked = []

        def ready(kdir, key, source=None):
            asked.append((key, source))
            return {'instance_name': 'store-host'} if key == store and source is None else None
        with patch.object(m, 'ready', side_effect=ready):
            self.assertEqual(m.owner(self.kdir, stale)['instance_name'], 'store-host')
        self.assertEqual(asked, [(store, None)])

    def test_an_old_key_reaches_its_host_only_as_a_live_checkout_host(self):
        manifest = dict(handle='task--w123', host_key='old-key', source_dir=str(self.source))
        m.atomic(m.manifest_path(self.kdir, manifest['handle']), manifest)
        with patch.object(m, 'ready', return_value=None) as ready:
            self.assertIsNone(m.owner(self.kdir, manifest))
        ready.assert_called_once_with(self.kdir, 'old-key', str(self.source))

    def test_publish_checks_the_delivery_ledger_of_the_current_key(self):
        store = m.RUNTIME.store_host_key(self.kdir)
        stale = dict(handle='task--w123', host_key='old-key', source_dir=str(self.source))
        m.atomic(m.manifest_path(self.kdir, stale['handle']), dict(stale, host_key=store))
        m.atomic(m.host_dir(self.kdir, store) / 'deliveries/op1.json', {'terminal': False})
        row = dict(request_id='op1', slug='task--w123', body='hello')
        with patch.object(m, 'owner', return_value={'instance_name': 'store-host'}):
            m.publish_operation(self.kdir, stale, 'send', row)
        self.assertFalse((self.kdir / '_sessions/send-requests/op1.json').exists())

    def managed_close_from_the_tui(self, *extra):
        manifest = dict(handle='task--w123', host_key='abc', source_dir=str(self.source))
        m.atomic(m.manifest_path(self.kdir, manifest['handle']), manifest)
        published = []
        target = importlib.util.spec_from_file_location('session_target', ROOT / 'scripts/session_target.py')
        session_target = importlib.util.module_from_spec(target)
        target.loader.exec_module(session_target)
        environ = {k: v for k, v in os.environ.items() if k != 'LORE_SESSION_SLUG'}
        with patch.dict(sys.modules, {'session_target': session_target}), \
                patch.dict(os.environ, environ, clear=True), \
                patch.object(m, 'inspect', return_value={'state': 'running'}), patch.object(m, 'ensure'), \
                patch.object(m, 'owner', return_value={'instance_name': 'host', 'type': 'implement', 'session_id': 's1'}), \
                patch.object(m, 'publish_operation', side_effect=lambda kdir, manifest, verb, row: published.append(row)), \
                patch.object(m, 'append'), patch.object(m, 'await_outcome', return_value={'outcome': 'closed'}):
            code = m.main(['close', manifest['handle'], '--reason', 'human', *extra, '--kdir', str(self.kdir)])
        return code, published

    def test_managed_close_accepts_the_tui_requested_by(self):
        code, published = self.managed_close_from_the_tui('--requested-by', 'tui-instance')
        self.assertEqual(code, 0)
        self.assertEqual(published[0]['requested_by'], 'tui-instance')
        self.assertEqual(published[0]['reason'], 'human')
        code, published = self.managed_close_from_the_tui()
        self.assertEqual(published[0]['requested_by'], 'managed-cli')

    def test_path_escape_rejected(self):
        for handle in ['../../task--w1', '/tmp/task--w1', 'task--w../evil']:
            with self.assertRaises(RuntimeError):
                m.manifest_path(self.kdir, handle)

    def test_atomic_record_and_lock(self):
        path = self.kdir / 'a/b.json'
        m.atomic(path, {'a': 1})
        self.assertEqual(m.read(path), {'a': 1})
        with m.lock(self.kdir / 'lock'):
            self.assertTrue(m.held(self.kdir / 'lock'))
        self.assertFalse(m.held(self.kdir / 'lock'))



class RequestRefusalTest(unittest.TestCase):
    """lore session request refuses, with nothing enqueued, a request that names no
    checkout (before ensuring anything) and one whose store host cannot be ensured;
    under --json a refusal's only stdout is one JSON object carrying the whole text."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.kdir = self.root / 'store'
        self.checkout = self.root / 'checkout'
        self.checkout.mkdir()
        (self.kdir / '_sessions').mkdir(parents=True)
        self.data = self.root / 'data'
        (self.data / 'config').mkdir(parents=True)
        shutil.copy(ROOT / 'adapters/settings.template.json', self.data / 'config/settings.json')
        env = {k: v for k, v in os.environ.items()
               if k not in {'LORE_KNOWLEDGE_DIR', 'LORE_SESSION_RUNTIME'} and not k.startswith('LORE_SESSION_')}
        env.update(LORE_DATA_DIR=str(self.data), LORE_SESSION_RUNTIME='request-refusal')
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.diagnostics = m.host_dir(self.kdir, m.RUNTIME.store_host_key(self.kdir))

    def request(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = m.request([*argv, '--kdir', str(self.kdir)])
        return code, stdout.getvalue(), stderr.getvalue()

    def test_a_request_that_names_no_checkout_is_refused_by_the_writer_before_any_ensure(self):
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/session-managed.py'), 'request', '--type', 'chat',
                                 '--anywhere', '--kdir', str(self.kdir), '--json'], text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stdout)
        refusal = json.loads(result.stdout)
        self.assertEqual(list(refusal), ['error'])
        self.assertTrue(refusal['error'].startswith('request names no checkout; pass --prefer-dir <checkout>\n'))
        self.assertFalse((m.RUNTIME.login_dir() / 'served.json').exists(), 'nothing may ensure a host for it')
        self.assertFalse((self.kdir / '_sessions/requests').exists())

    def test_ensure_failure_refuses_with_the_error_and_the_host_diagnostics(self):
        with patch.object(m, 'ensure', side_effect=RuntimeError('the supervisor could not start')), \
                patch.object(m.subprocess, 'call') as writer:
            code, out, err = self.request('--type', 'chat', '--prefer-dir', str(self.checkout), '--json')
        writer.assert_not_called()
        self.assertEqual(code, 1)
        self.assertEqual(err, '')
        refusal = json.loads(out)
        self.assertEqual(list(refusal), ['error'])
        text = refusal['error']
        lead = text.split('\n', 1)[0]
        self.assertEqual(lead, 'store host did not start; fix the error below, retry')
        self.assertLessEqual(len(lead.encode('ascii')), 55)
        self.assertIn('the supervisor could not start', text)
        self.assertIn(str(self.diagnostics / 'host.log'), text)
        self.assertIn(str(self.diagnostics / 'supervisor-error.json'), text)
        self.assertIn('Nothing was enqueued', text)

        with patch.object(m, 'ensure', side_effect=RuntimeError('the supervisor could not start')):
            code, out, err = self.request('--type', 'chat', '--prefer-dir', str(self.checkout))
        self.assertEqual((code, out), (1, ''))
        self.assertTrue(err.startswith('Error: store host did not start; fix the error below, retry\n'), err)

    def test_a_host_that_keeps_withdrawing_is_a_refusal_not_a_fallback(self):
        with patch.object(m, 'ensure', return_value={'instance_name': 'store-host'}), \
                patch.object(m, 'ready', return_value=None), patch.object(m.subprocess, 'call') as writer:
            code, out, _ = self.request('--type', 'chat', '--prefer-dir', str(self.checkout), '--json')
        writer.assert_not_called()
        self.assertEqual(code, 1)
        self.assertTrue(json.loads(out)['error'].startswith('store host kept withdrawing; retry lore session request\n'))

    def test_a_ready_host_gets_the_row_under_its_ensure_lock_with_its_key(self):
        key = m.RUNTIME.store_host_key(self.kdir)
        with patch.object(m, 'ensure', return_value={'instance_name': 'store-host'}), \
                patch.object(m, 'ready', return_value={'instance_name': 'store-host'}), \
                patch.object(m.subprocess, 'call', return_value=0) as writer:
            code, _, _ = self.request('--type', 'chat', '--prefer-dir', str(self.checkout), '--json')
        self.assertEqual(code, 0)
        argv = writer.call_args.args[0]
        self.assertTrue(argv[1].endswith('session-request.sh'))
        self.assertEqual(argv[argv.index('--host-key') + 1], key)
        self.assertNotIn('--store-host-unavailable', argv)

if __name__ == '__main__':
    unittest.main()
