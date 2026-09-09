import importlib.util
from pathlib import Path
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
        with patch.object(m, 'ready', return_value={'instance_name': 'alive'}), patch.object(m, 'held', return_value=False), patch.object(m, 'binary', return_value=Path('/fake/binary')), patch.object(m.subprocess, 'Popen') as launch:
            result = m.ensure(self.kdir, 'key', str(self.source), 0)
        self.assertEqual(result['instance_name'], 'alive')
        launch.assert_called_once()
        self.assertIn('_supervise', launch.call_args.args[0])

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


if __name__ == '__main__':
    unittest.main()
