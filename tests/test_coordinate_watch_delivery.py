import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('watch_state', ROOT / 'scripts/coordinate_watch_state.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def peek(activity='idle', **fields):
    value = dict(schema_version=1, activity=activity, authority='screen-signature', observed_at=m.timestamp(),
                 session_id='session-a', generation='generation-a', instance='instance-a',
                 can_accept_input=True, fresh=True, max_age_seconds=5, evidence={'matcher': 'fixture'})
    value.update(fields)
    return {'ready': True, 'slug': 'task--w1', 'observation': value, 'rows': ['fixture']}


class WatchDelivery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.kdir = Path(self.temp.name)
        self.path = self.kdir / '_coordination/watch-delivery-fixture.json'
        self.delivery = m.Delivery(self.path)
        self.identity = dict(owner_kind='pid', owner_value=str(os.getpid()), key='fixture', scope='board')

    def payload(self, **fields):
        value = dict(outcome='matched', tier='confirmed', matched={'event': 'closed', 'slug': 'task--w1'},
                     next_cursor=42, current_delta=[], current_observations={'current': [], 'delta': []})
        value.update(fields)
        return value

    def test_working_with_input_eligibility_does_not_confirm_park(self):
        result = m.classify({'event': 'needs_input'}, peek('working'))
        self.assertEqual(result['tier'], 'advisory')
        self.assertEqual(result['observation']['activity'], 'working')

    def test_idle_requires_fresh_generation_bound_evidence(self):
        self.assertEqual(m.classify({'event': 'needs_input'}, peek())['tier'], 'confirmed')
        for observed in (peek(fresh=False), {'ready': True}, peek(generation='')):
            self.assertEqual(m.classify({'event': 'needs_input'}, observed)['tier'], 'advisory')
        self.assertEqual(m.classify({'event': 'needs_input', 'links': {'generation': 'old'}}, peek())['tier'], 'advisory')

    def test_lost_output_replays_identical_id_and_receipt_retires_it(self):
        first = self.delivery.publish(self.payload(), self.identity, 0)
        replay = m.Delivery(self.path).pending()
        self.assertEqual(first['wake_id'], replay['wake_id'])
        receipt = m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        self.assertTrue(receipt['acknowledged_at'])
        self.assertEqual(m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True), receipt)
        self.assertIsNone(self.delivery.pending())
        self.assertEqual(self.delivery.state()['observed_cursor'], 42)

    def test_other_owner_cannot_acknowledge(self):
        first = self.delivery.publish(self.payload(), dict(self.identity, owner_value='99999999'), 0)
        with self.assertRaisesRegex(ValueError, 'another owner'):
            m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        self.assertIsNotNone(self.delivery.pending())

    def test_scopes_have_independent_receipts(self):
        other = m.Delivery(self.kdir / '_coordination/watch-delivery-other.json')
        first = self.delivery.publish(self.payload(), self.identity, 0)
        second = other.publish(self.payload(), dict(self.identity, scope='other'), 0)
        m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        self.assertEqual(other.pending()['wake_id'], second['wake_id'])

    def test_quiet_replay_preserves_interval_and_new_action_wins(self):
        with patch.object(m.time, 'time', return_value=1000):
            quiet = self.delivery.publish(self.payload(outcome='timeout', tier='quiet', matched=None), self.identity, 600)
        with patch.object(m.time, 'time', return_value=1100):
            self.assertIsNone(self.delivery.pending())
            action = self.delivery.publish(self.payload(), self.identity, 0)
            self.assertNotEqual(action['wake_id'], quiet['wake_id'])
        m.wake_receipt(self.kdir, action['wake_id'], acknowledge=True)
        with patch.object(m.time, 'time', return_value=1600):
            self.assertEqual(self.delivery.pending()['wake_id'], quiet['wake_id'])

    def test_unchanged_actionable_replay_waits_for_interval(self):
        with patch.object(m.time, 'time', return_value=1000):
            first = self.delivery.publish(self.payload(), self.identity, 600)
        with patch.object(m.time, 'time', return_value=1100):
            self.assertIsNone(self.delivery.pending())
        with patch.object(m.time, 'time', return_value=1600):
            self.assertEqual(self.delivery.pending()['wake_id'], first['wake_id'])

    def test_replay_demotes_superseded_park(self):
        current = {'current': [{'slug': 'task--w1', 'peek': peek()}]}
        first = self.delivery.publish(self.payload(matched={'event': 'needs_input', 'slug': 'task--w1'}, current_observations=current), self.identity, 0)
        self.assertEqual(first['tier'], 'confirmed')
        replay = self.delivery.pending({'current': [{'slug': 'task--w1', 'peek': peek('working')}]})
        self.assertEqual(replay['wake_id'], first['wake_id'])
        self.assertEqual(replay['tier'], 'advisory')
        self.assertIn('original_classification', replay)

    def test_sweep_recovers_missing_edge_and_retains_it_until_wake(self):
        path = self.kdir / '_sessions/instances/instance-a.json'
        m.atomic(path, {'name': 'instance-a', 'sessions': [{'slug': 'task--w1', 'session_id': 'session-a'}]})
        state = self.kdir / '_coordination/watch-observation.json'
        response = subprocess.CompletedProcess([], 0, json.dumps(peek()), '')
        with patch.object(m.subprocess, 'run', return_value=response):
            first = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
            second = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
            self.assertEqual(first['delta'], second['delta'])
            m.consume_delta(state, {'current_observations': second})
            third = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        self.assertEqual(first['delta'][0]['observation']['activity'], 'idle')
        self.assertEqual(third['delta'], [])

    def test_fresh_unknown_capture_is_not_mislabeled_stale(self):
        value = m.observation(peek('unknown', authority='none'))
        self.assertTrue(value['fresh'])
        self.assertEqual(value['activity'], 'unknown')
        self.assertEqual(m.classify({'event': 'needs_input'}, peek('unknown', authority='none'))['tier'], 'advisory')

    def test_missing_previously_observed_session_is_an_explicit_delta(self):
        state = self.kdir / 'observation.json'
        prior = {k: peek()['observation'].get(k) for k in ('activity', 'generation', 'session_id', 'authority', 'fresh')}
        m.atomic(state, {'states': {'task--w1': prior}, 'pending': {}})
        result = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        self.assertFalse(result['complete'])
        self.assertEqual(result['delta'][0]['observation']['activity'], 'unknown')
        self.assertEqual(result['unavailable'][0]['slug'], 'task--w1')

    def test_round_robin_sweep_covers_peers_beyond_concurrency_limit(self):
        m.atomic(self.kdir / '_sessions/instances/instance-a.json', {'name': 'instance-a', 'sessions': [{'slug': 'task-' + str(n)} for n in range(8)]})
        def response(argv, **kwargs):
            payload = peek()
            payload['slug'] = argv[2]
            return subprocess.CompletedProcess(argv, 0, json.dumps(payload), '')
        state = self.kdir / 'observation.json'
        with patch.object(m.subprocess, 'run', side_effect=response):
            first = m.sweep(self.kdir, ROOT / 'scripts', state, [], 8, 10)
            second = m.sweep(self.kdir, ROOT / 'scripts', state, [], 8, 10)
        self.assertEqual(len(first['current']), 4)
        self.assertEqual(len(second['current']), 4)
        self.assertEqual(len({row['slug'] for row in first['current'] + second['current']}), 8)
        self.assertFalse(first['complete'])

    def test_unavailable_sweep_is_explicit_and_bounded(self):
        m.atomic(self.kdir / '_sessions/instances/a.json', {'sessions': [{'slug': 'task'}]})
        with patch.object(m.subprocess, 'run', side_effect=subprocess.TimeoutExpired('peek', 1)):
            result = m.sweep(self.kdir, ROOT / 'scripts', self.kdir / 'state.json', [], 1, 1)
        self.assertFalse(result['complete'])
        self.assertEqual(result['current'], [])
        self.assertEqual(result['unavailable'][0]['slug'], 'task')


class WatchCommands(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.kdir = Path(self.temp.name)
        (self.kdir / '_sessions').mkdir()
        self.env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(self.kdir))
        self.env.pop('LORE_SESSION_INSTANCE', None)
        self.env.pop('LORE_SESSION_SLUG', None)
        self.env.pop('LORE_SESSION_TYPE', None)

    def watch(self, *args, timeout=15):
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-watch.sh'), '--kdir', str(self.kdir),
                                 '--owner-pid', str(os.getpid()), '--timeout', '0', '--pending-stale', '0',
                                 '--peek-timeout', '0', '--reconcile-budget', '0', '--json', *args],
                                env=self.env, text=True, capture_output=True, timeout=timeout)
        self.assertIn(result.returncode, (0, 2), result.stderr + result.stdout)
        return result, json.loads(result.stdout)

    def journal(self, rows):
        with (self.kdir / '_sessions/events.jsonl').open('w') as stream:
            for i, row in enumerate(rows):
                stream.write(json.dumps(dict(row, event_id=str(i), ts=m.timestamp())) + '\n')

    def test_shell_lost_output_and_explicit_status_receipt(self):
        self.journal([{'event': 'closed', 'slug': 'task--w1', 'request_id': 'r1'}])
        _, first = self.watch('--durable', '--since', '0')
        _, second = self.watch('--durable')
        self.assertEqual(first['wake_id'], second['wake_id'])
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-status.sh'), '--kdir', str(self.kdir), '--wake-id', first['wake_id'], '--json'], env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)['wake_receipt']['wake_id'], first['wake_id'])
        _, third = self.watch('--durable')
        self.assertNotEqual(third['wake_id'], first['wake_id'])
        self.assertEqual(third['outcome'], 'timeout')

    def test_arc_membership_change_does_not_strand_pending_receipt(self):
        path = self.kdir / '_work/_arcs/arc-a/_meta.json'
        m.atomic(path, {'schema_version': 1, 'slug': 'arc-a', 'status': 'active', 'members': ['task']})
        self.journal([{'event': 'closed', 'slug': 'task--w1', 'request_id': 'r1'}])
        _, first = self.watch('--durable', '--arc', 'arc-a', '--since', '0')
        m.atomic(path, {'schema_version': 1, 'slug': 'arc-a', 'status': 'active', 'members': ['task', 'new-task']})
        _, second = self.watch('--durable', '--arc', 'arc-a')
        self.assertEqual(first['wake_id'], second['wake_id'])
        self.assertEqual(len(list((self.kdir / '_coordination').glob('watch-delivery-*.json'))), 1)

    def test_historical_park_superseded_by_resume_is_not_confirmed(self):
        self.journal([{'event': 'needs_input', 'slug': 'task--w1', 'reason': 'idle'}, {'event': 'resumed', 'slug': 'task--w1'}])
        _, result = self.watch('--since', '0')
        self.assertEqual(result['outcome'], 'timeout')
        self.assertEqual(result['tier'], 'quiet')

    def test_quiet_lost_output_retries_on_window_not_immediately(self):
        _, first = self.watch('--durable')
        path = next((self.kdir / '_coordination').glob('watch-delivery-*.json'))
        state = m.read(path)
        state['wakes'][0]['interval'] = 1
        m.atomic(path, state)
        started = time.monotonic()
        _, replay = self.watch('--durable', '--timeout', '1')
        self.assertGreaterEqual(time.monotonic() - started, .8)
        self.assertEqual(replay['wake_id'], first['wake_id'])


if __name__ == '__main__':
    unittest.main()
