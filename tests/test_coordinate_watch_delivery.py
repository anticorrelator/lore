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

    def test_compact_many_peers_and_unicode_stays_bounded_without_losing_evidence(self):
        rows = []
        for i in range(60):
            screen = peek('blocked')
            screen['rows'] = ['retained-screen-' + str(i) + '界' * 10000]
            screen['ansi'] = 'retained-ansi'
            screen['modal'] = {'title': 'decision' + '😀' * 1000, 'answerable': True,
                               'selected': 1, 'options': [{'number': j, 'label': 'option' + '界' * 500} for j in range(30)]}
            rows.append({'slug': 'task--w' + str(i), 'peek': screen, 'observation': screen['observation']})
        original = self.payload(outcome='current_delta', matched=None, current_delta=rows,
                                current_observations={'current': rows, 'delta': rows, 'complete': True})
        wake = self.delivery.publish(original, self.identity, 0)
        before = self.path.read_bytes()
        compact = m.compact_wake(wake)
        self.assertLessEqual(len(json.dumps(compact, ensure_ascii=True, indent=2).encode()) + 1, 8192)
        self.assertGreater(compact['omitted']['sessions'], 0)
        self.assertGreater(compact['omitted']['strings_truncated'], 0)
        self.assertNotIn('retained-screen-', json.dumps(compact))
        self.assertNotIn('retained-ansi', json.dumps(compact))
        self.assertEqual(compact['full_evidence']['wake_id'], wake['wake_id'])
        self.assertEqual(self.path.read_bytes(), before)
        receipt = m.wake_receipt(self.kdir, compact['wake_id'])
        self.assertEqual(receipt['historical_payload'], original)
        self.assertIsNone(receipt['acknowledged_at'])
        self.assertLessEqual(len(json.dumps(m.compact_receipt(receipt), ensure_ascii=True, indent=2).encode()), 8192)
        self.assertEqual(self.delivery.pending()['wake_id'], wake['wake_id'])

    def test_compact_modal_options_are_explicitly_partial(self):
        screen = peek('blocked')
        screen['modal'] = {'title': 'Choose a destination', 'answerable': True, 'selected_option': 2, 'matcher': 'permission-menu',
                           'options': [{'number': j, 'label': 'choice ' + str(j)} for j in range(9)]}
        current = {'current': [{'slug': 'task--w1', 'peek': screen}], 'complete': True}
        wake = self.delivery.publish(self.payload(matched={'event': 'modal_blocked', 'slug': 'task--w1'}, current_observations=current), self.identity, 0)
        compact = m.compact_wake(wake)
        modal = compact['sessions'][0]['modal']
        self.assertEqual(modal['title'], 'Choose a destination')
        self.assertEqual(modal['selected_option'], 2)
        self.assertEqual(modal['matcher'], 'permission-menu')
        self.assertEqual(modal['options_total'], 9)
        self.assertEqual(modal['options_omitted'], 5)
        self.assertEqual(len(modal['options']), 4)
        self.assertTrue(compact['sessions'][0]['observation']['fresh'])
        self.assertEqual(compact['sessions'][0]['observation']['generation'], 'generation-a')

    def test_compact_revalidates_freshness_before_presenting_confirmed_park(self):
        current = {'current': [{'slug': 'task--w1', 'peek': peek()}], 'complete': True}
        wake = self.delivery.publish(self.payload(matched={'event': 'needs_input', 'slug': 'task--w1'}, current_observations=current), self.identity, 0)
        with patch.object(m.time, 'time', return_value=time.time() + 10):
            compact = m.compact_wake(wake)
        self.assertEqual(compact['tier'], 'advisory')
        self.assertFalse(compact['sessions'][0]['observation']['fresh'])
        self.assertEqual(compact['sessions'][0]['observation']['activity'], 'unknown')

    def test_compact_abbreviated_identifiers_are_explicitly_marked(self):
        slug = 'task-' + 'x' * 1000 + '--w1'
        screen = peek()
        screen['slug'] = slug
        screen['observation']['session_id'] = 'id-' + 'x' * 1000
        original = self.payload(matched={'event': 'closed', 'slug': slug}, current_observations={'current': [{'slug': slug, 'peek': screen}]})
        compact = m.compact_wake(self.delivery.publish(original, self.identity, 0))
        self.assertTrue(compact['matched']['slug_truncated'])
        self.assertTrue(compact['sessions'][0]['slug_truncated'])
        self.assertTrue(compact['sessions'][0]['observation']['session_id_truncated'])
        self.assertNotEqual(compact['sessions'][0]['slug'], slug)

    def test_compact_quiet_omits_unchanged_session_bodies(self):
        current = {'current': [{'slug': f'task--w{i}', 'peek': peek('working')} for i in range(60)], 'complete': True}
        wake = self.delivery.publish(self.payload(outcome='timeout', tier='quiet', matched=None, current_observations=current), self.identity, 600)
        compact = m.compact_wake(wake)
        self.assertNotIn('sessions', compact)
        self.assertEqual(compact['coverage']['observed_sessions'], 60)
        self.assertEqual(compact['omitted']['sessions'], 60)
        self.assertLess(len(json.dumps(compact).encode()), 1500)
        self.assertIsNone(self.delivery.pending())

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

    def test_pending_stale_age_and_cursor_changes_do_not_bypass_cadence(self):
        payload = self.payload(outcome='pending_stale', tier='advisory', matched=None,
                               pending=[{'request_id': 'r1', 'age_seconds': 301}])
        with patch.object(m.time, 'time', return_value=1000):
            first = self.delivery.publish(payload, self.identity, 600)
        changed = dict(payload, next_cursor=99, pending=[{'request_id': 'r1', 'age_seconds': 401}])
        with patch.object(m.time, 'time', return_value=1100):
            self.assertIsNone(self.delivery.publish(changed, self.identity, 600))
            newer = self.delivery.publish(dict(changed, pending=changed['pending'] + [{'request_id': 'r2'}]), self.identity, 600)
            self.assertNotEqual(first['wake_id'], newer['wake_id'])
        with patch.object(m.time, 'time', return_value=1600):
            self.assertEqual(self.delivery.publish(changed, self.identity, 600)['wake_id'], first['wake_id'])
        m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        with patch.object(m.time, 'time', return_value=1700):
            self.assertIsNone(self.delivery.publish(changed, self.identity, 600))

    def test_pending_replay_demotes_expired_cached_snapshot(self):
        captured = peek()
        current = {'current': [{'slug': 'task--w1', 'peek': captured, 'observation': captured['observation']}], 'complete': True}
        first = self.delivery.publish(self.payload(current_observations=current), self.identity, 0)
        with patch.object(m.time, 'time', return_value=time.time() + 10):
            replay = self.delivery.pending(current)
        self.assertEqual(replay['wake_id'], first['wake_id'])
        snapshot = replay['current_observations']
        self.assertFalse(snapshot['complete'])
        self.assertFalse(snapshot['current'][0]['observation']['fresh'])
        self.assertFalse(snapshot['current'][0]['peek']['observation']['fresh'])
        self.assertEqual(snapshot['current'][0]['observation']['activity'], 'unknown')

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
            delivered = self.delivery.publish(self.payload(current_observations=m.current_snapshot(second)), self.identity, 0)
            m.consume_delta(state, delivered)
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

    def test_compact_notification_is_retained_and_full_receipt_is_exact(self):
        self.journal([{'event': 'closed', 'slug': 'task--w1', 'request_id': 'r1', 'links': {'diagnostic': 'omitted evidence ' * 1000}}])
        _, first = self.watch('--compact', '--since', '0')
        self.assertEqual(first['presentation'], 'compact')
        _, replay = self.watch('--compact')
        self.assertEqual(first['wake_id'], replay['wake_id'])
        self.assertNotIn('omitted evidence', json.dumps(first))
        state = m.read(next((self.kdir / '_coordination').glob('watch-delivery-*.json')))
        self.assertIsNone(state['wakes'][0].get('acknowledged_at'))
        argv = ['bash', str(ROOT / 'scripts/coordinate-status.sh'), '--kdir', str(self.kdir), '--wake-id', first['wake_id'], '--json']
        result = subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('buckets', json.loads(result.stdout))
        receipt = json.loads(result.stdout)['wake_receipt']
        self.assertEqual(receipt['payload']['presentation'], 'compact')
        self.assertNotIn('historical_payload', receipt)
        pointer = first['full_evidence']['argv']
        self.assertEqual(pointer[pointer.index('--kdir') + 1], str(self.kdir.resolve()))
        other_store = self.kdir / 'different-store'
        other_store.mkdir()
        full = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-status.sh'), *pointer[3:]],
                              cwd=other_store, env=dict(self.env, LORE_KNOWLEDGE_DIR=str(other_store)), text=True, capture_output=True, timeout=30)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertEqual(set(json.loads(full.stdout)), {'schema_version', 'wake_receipt'})
        self.assertEqual(json.loads(full.stdout)['wake_receipt']['historical_payload'], state['wakes'][0]['payload'])
        self.assertTrue(m.read(next((self.kdir / '_coordination').glob('watch-delivery-*.json')))['wakes'][0]['acknowledged_at'])
        _, quiet = self.watch('--compact')
        self.assertNotEqual(first['wake_id'], quiet['wake_id'])

    def test_durable_wake_shaped_emits_one_compact_envelope(self):
        self.journal([{'event': 'closed', 'slug': 'task--w1', 'request_id': 'r1'}])
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-watch.sh'), '--kdir', str(self.kdir),
                                 '--owner-pid', str(os.getpid()), '--durable', '--wake-shaped', '--timeout', '0',
                                 '--pending-stale', '0', '--reconcile-budget', '0', '--since', '0'],
                                env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, '')
        compact = json.loads(result.stderr)
        self.assertEqual(compact['presentation'], 'compact')
        self.assertLessEqual(len(result.stderr.encode()), 8192)
        self.assertIsNone(m.wake_receipt(self.kdir, compact['wake_id'])['acknowledged_at'])

    def test_compact_requires_owner_and_full_evidence_requires_exact_receipt(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-watch.sh'), '--kdir', str(self.kdir), '--compact'],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('owner', result.stderr)
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-status.sh'), '--kdir', str(self.kdir), '--full-evidence'],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--wake-id', result.stderr)

    def test_durable_close_batch_is_delivered_and_acknowledged_once(self):
        rows = [{'event': 'closed', 'slug': 'task--w' + str(i), 'request_id': 'r' + str(i)} for i in range(4)]
        self.journal(rows)
        _, first = self.watch('--durable', '--since', '0')
        self.assertEqual(len(first['journal_batch']), 4)
        self.assertEqual([r['request_id'] for r in first['journal_batch']], ['r0', 'r1', 'r2', 'r3'])
        m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        _, second = self.watch('--durable')
        self.assertEqual(second['outcome'], 'timeout')

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

    def test_shell_unchanged_stale_request_waits_before_replay(self):
        m.atomic(self.kdir / '_sessions/requests/pending/r1.json',
                 {'request_id': 'r1', 'slug': 'task--w1', 'requested_at': '2000-01-01T00:00:00Z'})
        _, first = self.watch('--durable', '--pending-stale', '1', '--timeout', '2')
        self.assertEqual(first['outcome'], 'pending_stale')
        started = time.monotonic()
        _, replay = self.watch('--durable', '--pending-stale', '1', '--timeout', '2')
        self.assertGreaterEqual(time.monotonic() - started, 1)
        self.assertEqual(replay['wake_id'], first['wake_id'])

    def test_deadline_runs_a_final_sweep_before_quiet_delivery(self):
        scripts = self.kdir / 'scripts'
        scripts.mkdir()
        for source in (ROOT / 'scripts').iterdir():
            if source.name != 'coordinate_watch_state.py':
                (scripts / source.name).symlink_to(source)
        helper = scripts / 'coordinate_watch_state.py'
        helper.write_text("import json, pathlib, runpy, sys, time\n"
                          "if sys.argv[1] == 'sweep':\n"
                          "    with pathlib.Path(__file__).with_suffix('.calls').open('a') as f: f.write(str(time.time()) + '\\n')\n"
                          "    print(json.dumps({'current': [], 'delta': [], 'complete': True, 'unavailable': [], 'observed_at_epoch': time.time()}))\n"
                          "else:\n"
                          f"    runpy.run_path({str(ROOT / 'scripts/coordinate_watch_state.py')!r}, run_name='__main__')\n")
        result = subprocess.run(['bash', str(scripts / 'coordinate-watch.sh'), '--kdir', str(self.kdir),
                                 '--owner-pid', str(os.getpid()), '--timeout', '2', '--pending-stale', '0',
                                 '--reconcile-interval', '15', '--json'], env=self.env, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 2, result.stderr)
        calls = [float(v) for v in helper.with_suffix('.calls').read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertGreater(calls[-1] - calls[0], 1)
        self.assertLess(abs(json.loads(result.stdout)['current_observations']['observed_at_epoch'] - calls[-1]), .1)

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
