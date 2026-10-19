import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('watch_state', ROOT / 'scripts/coordinate_watch_state.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def ago(seconds):
    """An ISO stamp the given number of seconds before now, six fractional digits."""
    return m.lifecycle()._iso(int((time.time() - seconds) * 1e6))


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

    def test_compact_revalidates_freshness_beside_the_delivered_tier_of_a_confirmed_park(self):
        current = {'current': [{'slug': 'task--w1', 'peek': peek()}], 'complete': True}
        wake = self.delivery.publish(self.payload(matched={'event': 'needs_input', 'slug': 'task--w1'}, current_observations=current), self.identity, 0)
        self.assertNotIn('reevaluation', m.compact_wake(wake))
        with patch.object(m.time, 'time', return_value=time.time() + 10):
            compact = m.compact_wake(wake)
        self.assertEqual((compact['tier'], compact['authority']), ('confirmed', 'screen-signature'))
        self.assertEqual((compact['reevaluation']['tier'], compact['reevaluation']['authority']), ('advisory', 'none'))
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

    def test_host_stamps_with_trimmed_fractions_are_aged_on_every_python(self):
        # The host writes RFC3339Nano, which drops trailing zeros from the fraction.
        now = int(time.time())
        whole = time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(now))
        for digits in ('1', '12345', '123456', '12345678', '123456789'):
            self.assertAlmostEqual(m.epoch(whole + '.' + digits + 'Z'), now + float('0.' + digits), places=5)
        self.assertTrue(m.observation(peek(observed_at=whole + '.12345Z'))['fresh'])
        self.assertIsNone(m.epoch('not a time'))

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

    def test_a_session_that_left_the_registry_after_closing_raises_no_departure_delta(self):
        # The live run's wake-e84b5e11: a closed session's leaving the registry woke the seat a third time.
        state = self.kdir / 'observation.json'
        prior = {k: peek()['observation'].get(k) for k in ('activity', 'generation', 'session_id', 'authority', 'fresh')}
        m.atomic(state, {'states': {'task--w1': prior, 'task--w2': prior, 'task--w3': prior},
                         'meaningful': {'task--w1': prior}, 'pending': {}, 'reported_parks': {'task--w1': 'e0'}})
        journal = self.kdir / '_sessions/events.jsonl'
        journal.parent.mkdir(parents=True, exist_ok=True)
        rows = [dict(event='close_requested', slug='task--w1', ts=ago(3)), dict(event='worktree_quarantined', slug='task--w1', ts=ago(2)),
                dict(event='closed', slug='task--w1', ts=ago(1)), dict(event='close_requested', slug='task--w2', ts=ago(1))]
        journal.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        result = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        saved = m.read(state)
        self.assertEqual([row['slug'] for row in result['delta']], ['task--w3'])
        self.assertNotIn('task--w1', saved['states'])
        self.assertNotIn('task--w1', saved['meaningful'])
        self.assertNotIn('task--w1', saved['reported_parks'])
        # A teardown under way holds the departure quietly until its closed row lands.
        self.assertEqual(saved['states']['task--w2'], prior)
        with journal.open('a') as stream:
            stream.write(json.dumps(dict(event='closed', slug='task--w2', ts=ago(0))) + '\n')
        m.consume_delta(state, {'outcome': 'current_delta', 'current_delta': result['delta'],
                                'current_observations': {'delta': result['delta']}})
        again = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        self.assertEqual(again['delta'], [])
        self.assertEqual(sorted(m.read(state)['states']), ['task--w3'])
        # One whose close request has gone unanswered past the hold is an unexplained departure.
        with journal.open('a') as stream:
            stream.write(json.dumps(dict(event='close_requested', slug='task--w4', ts=ago(m.TEARDOWN_HOLD_SECONDS + 5))) + '\n')
        m.atomic(state, dict(m.read(state), states=dict(m.read(state)['states'], **{'task--w4': prior})))
        self.assertEqual([row['slug'] for row in m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)['delta']], ['task--w4'])

    def test_a_confirmed_current_delta_reads_confirmed_in_its_receipt_after_acknowledgement(self):
        # The live run's wake-a0362e4e: delivered confirmed, its stored receipt read advisory once acknowledged.
        captured = peek()
        row = {'slug': 'task--w1', 'peek': captured, 'observation': captured['observation']}
        wake = self.delivery.publish(self.payload(outcome='current_delta', tier='confirmed', authority='observation', matched=None,
                                                  current_delta=[row], current_observations={'current': [row], 'delta': [row], 'complete': True}),
                                     self.identity, 0)
        self.assertEqual(wake['tier'], 'confirmed')
        with patch.object(m.time, 'time', return_value=time.time() + 30):
            first = m.wake_receipt(self.kdir, wake['wake_id'], acknowledge=True)
            again = m.wake_receipt(self.kdir, wake['wake_id'])
        for receipt in (first, again):
            self.assertEqual((receipt['payload']['tier'], receipt['payload']['authority']), ('confirmed', 'observation'))
            self.assertTrue(receipt['payload']['current_delta'][0]['observation']['fresh'])
            self.assertNotIn('reevaluation', receipt['payload'])
            compact = m.compact_receipt(receipt)['payload']
            self.assertEqual(compact['tier'], 'confirmed')
            self.assertNotIn('reevaluation', compact)
        self.assertEqual(m.read(self.path)['wakes'][0]['delivered']['tier'], 'confirmed')

    def test_a_receipt_keeps_the_verdict_of_its_last_delivery(self):
        current = {'current': [{'slug': 'task--w1', 'peek': peek()}]}
        first = self.delivery.publish(self.payload(matched={'event': 'needs_input', 'slug': 'task--w1'}, current_observations=current), self.identity, 0)
        self.assertEqual(m.wake_receipt(self.kdir, first['wake_id'])['payload']['tier'], 'confirmed')
        replay = self.delivery.pending({'current': [{'slug': 'task--w1', 'peek': peek('working')}]})
        self.assertEqual(replay['tier'], 'advisory')
        receipt = m.wake_receipt(self.kdir, first['wake_id'], acknowledge=True)
        self.assertEqual((receipt['payload']['tier'], receipt['payload']['classification']['label']), ('advisory', 'current-working'))
        self.assertEqual(receipt['historical_payload']['tier'], 'confirmed')

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


class ObservationMerge(unittest.TestCase):
    """observation() merges a session's own lifecycle hook rows when given the store."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.kdir = Path(self.temp.name)
        session = {'slug': 'task--w1', 'type': 'worker', 'started': '2026-10-18T09:00:00Z', 'request_id': 'managed-1'}
        m.atomic(self.kdir / '_sessions/instances/instance-a.json', {'name': 'instance-a', 'pid': os.getpid(), 'sessions': [session]})
        self.generation = m.lifecycle()._session_target().generation(session)
        self.hook = {'event': 'needs_input', 'slug': 'task--w1', 'session_type': 'worker', 'actor_instance': 'instance-a', 'event_id': 'hook-1',
                     'links': {'authority': 'hook-row', 'hook_event': 'StopFailure', 'activity': 'blocked', 'generation': self.generation,
                               'fired_at': '2026-10-18T10:00:01.000000Z', 'framework': 'claude-code', 'spawn_instance': 'instance-a', 'error': 'rate_limit'}}
        (self.kdir / '_sessions/events.jsonl').write_text(json.dumps(self.hook) + '\n')

    def unknown(self):
        return peek('unknown', authority='none', generation=self.generation, session_handle='task--w1', evidence={'matcher': 'screen-unknown-v1'})

    def test_hook_row_authority_is_fresh_without_the_store(self):
        merged = m.observation(self.unknown(), kdir=self.kdir)
        again = m.observation(dict(self.unknown(), observation=merged))
        self.assertTrue(again['fresh'])
        self.assertEqual((again['activity'], again['authority']), ('blocked', 'hook-row'))
        self.assertFalse(m.observation(peek('blocked', authority='hook-rows'))['fresh'])

    def test_peek_command_merges_only_when_given_the_store(self):
        argv = [sys.executable, str(ROOT / 'scripts/coordinate_watch_state.py'), 'peek']
        merged = subprocess.run(argv + ['--kdir', str(self.kdir)], input=json.dumps(self.unknown()), capture_output=True, text=True, check=True)
        plain = subprocess.run(argv, input=json.dumps(self.unknown()), capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(merged.stdout)['observation']['authority'], 'hook-row')
        self.assertEqual(json.loads(plain.stdout)['observation']['activity'], 'unknown')

    def test_classify_and_compact_read_a_merged_hook_park(self):
        merged = dict(self.unknown(), observation=m.observation(self.unknown(), kdir=self.kdir))
        result = m.classify(self.hook, merged)
        self.assertEqual((result['tier'], result['authority']), ('confirmed', 'hook-row'))
        wake = {'wake_id': 'wake-' + 'a' * 32, 'outcome': 'matched', 'tier': 'confirmed', 'authority': 'hook-row', 'matched': self.hook,
                'current_observations': {'current': [{'slug': 'task--w1', 'peek': merged}], 'complete': True}}
        compact = m.compact_wake(wake)
        self.assertEqual(compact['tier'], 'confirmed')
        self.assertEqual(compact['sessions'][0]['observation']['evidence']['reason'],
                         'hook says blocked since 2026-10-18T10:00:01.000000Z; screen unknown')

    def test_an_unreadable_journal_leaves_the_screen_standing_as_a_bounded_read(self):
        with patch.object(m.lifecycle(), 'open', side_effect=PermissionError(13, 'Permission denied'), create=True):
            value = m.observation(self.unknown(), kdir=self.kdir)
        self.assertEqual((value['activity'], value['authority']), ('unknown', 'none'))
        self.assertTrue(value['evidence']['truncated'])
        self.assertIn('could not be read', value['evidence']['journal_scan']['reason'])

    def test_sweep_keeps_the_previous_state_when_a_lifecycle_read_was_truncated(self):
        state = self.kdir / '_coordination/watch-observation.json'
        held = peek('idle', generation=self.generation)
        capped = peek('working', generation=self.generation)
        capped['observation']['evidence'] = {'matcher': 'fixture', 'truncated': True}
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(held), '')):
            m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        before = m.read(state)
        with patch.object(m.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(capped), '')):
            result = m.sweep(self.kdir, ROOT / 'scripts', state, ['task'], 8, 10)
        after = m.read(state)
        self.assertEqual(result['current'][0]['observation']['activity'], 'working')
        self.assertEqual((after['states'], after['meaningful'], after['pending']), (before['states'], before['meaningful'], before['pending']))


def stamp(second):
    """A hook's fired_at, six fractional digits, at 10:00:<second> on 2026-10-18."""
    return '2026-10-18T10:00:{:09.6f}Z'.format(second)


class HookParkDelivery(unittest.TestCase):
    """A session's own hook park wakes once, on its own authority, whatever the screen rows do."""

    SLUG = 'task--w1'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.kdir = Path(self.temp.name)
        (self.kdir / '_sessions').mkdir()
        self.journal_path = self.kdir / '_sessions/events.jsonl'
        self.journal_path.write_text('')
        self.serial = 0
        self.session = {'slug': self.SLUG, 'type': 'worker', 'started': '2026-10-18T09:00:00Z', 'request_id': 'managed-1'}
        self.registry = self.kdir / '_sessions/instances/host-a.json'
        self.own(os.getpid())
        self.generation = m.lifecycle()._session_target().generation(self.session)
        self.env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(self.kdir))
        for key in ('LORE_SESSION_INSTANCE', 'LORE_SESSION_SLUG', 'LORE_SESSION_TYPE'):
            self.env.pop(key, None)

    def own(self, pid):
        m.atomic(self.registry, {'name': 'host-a', 'pid': pid, 'role': 'session-host', 'sessions': [self.session]})

    def hook(self, hook_event, activity, second, generation=None, **links):
        values = dict(authority='hook-row', hook_event=hook_event, activity=activity, generation=generation or self.generation,
                      fired_at=stamp(second), framework='claude-code', spawn_instance='host-a', **links)
        return dict(event='resumed' if activity == 'working' else 'needs_input', slug=self.SLUG, session_type='worker',
                    actor_instance='host-a', links=values)

    def screen(self, event, activity, second, block_signature=None):
        observed = dict(schema_version=1, activity=activity, authority='screen-signature', observed_at=stamp(second),
                        session_id=self.SLUG, generation=self.generation, instance='host-a', fresh=True, max_age_seconds=5,
                        evidence={'matcher': 'claude-code-fixture-v1'})
        if block_signature:
            observed['block_signature'] = block_signature
        return dict(event=event, slug=self.SLUG, session_type='worker', actor_instance='host-a',
                    links=dict(observation=json.dumps(observed), generation=self.generation, observed_at=stamp(second), activity=activity))

    def modal(self):
        return dict(event='modal_blocked', slug=self.SLUG, session_type='worker', actor_instance='host-a', reason='modal', modal_signature='Which?')

    def append(self, *rows):
        with self.journal_path.open('a') as stream:
            for row in rows:
                self.serial += 1
                stream.write(json.dumps(dict(row, event_id='e{}'.format(self.serial), ts='2026-10-18T10:00:00Z')) + '\n')
        return [json.loads(line) for line in self.journal_path.read_text().splitlines()][-len(rows):]

    def watch(self, *args):
        os.utime(self.registry)
        result = subprocess.run(['bash', str(ROOT / 'scripts/coordinate-watch.sh'), '--kdir', str(self.kdir),
                                 '--owner-pid', str(os.getpid()), '--timeout', '0', '--pending-stale', '0',
                                 '--peek-timeout', '0', '--reconcile-budget', '0', '--json', *args],
                                env=self.env, text=True, capture_output=True, timeout=60)
        self.assertIn(result.returncode, (0, 2), result.stderr + result.stdout)
        return json.loads(result.stdout)

    def wakes(self):
        path = next((self.kdir / '_coordination').glob('watch-delivery-*.json'), None)
        return [w for w in (m.read(path, {}) if path else {}).get('wakes', []) if w['payload'].get('tier') != 'quiet']

    def live(self, activity, block_signature=None):
        value = dict(schema_version=1, activity=activity, authority='none' if activity == 'unknown' else 'screen-signature',
                     observed_at=m.timestamp(), session_id=self.SLUG, session_handle=self.SLUG, generation=self.generation,
                     instance='host-a', can_accept_input=activity == 'idle', fresh=True, max_age_seconds=5,
                     evidence={'matcher': 'screen-unknown-v1' if activity == 'unknown' else 'claude-code-fixture-v1'})
        if block_signature:
            value['block_signature'] = block_signature
        return {'slug': self.SLUG, 'ready': activity == 'idle', 'observation': value}

    def test_a_hook_park_confirms_with_the_peek_disabled_and_through_present_and_compact(self):
        self.append(self.screen('resumed', 'working', 0), self.hook('StopFailure', 'blocked', 1, error='rate_limit'))
        wake = self.watch('--durable', '--since', '0')
        self.assertEqual((wake['outcome'], wake['tier'], wake['authority']), ('matched', 'confirmed', 'hook-row'))
        self.assertEqual(wake['classification']['label'], 'hook-StopFailure')
        self.assertEqual(wake['classification']['observation']['evidence']['screen']['matcher'], 'screen-not-read-v1')
        compact = m.compact_wake(wake)
        self.assertEqual((compact['tier'], compact['authority']), ('confirmed', 'hook-row'))
        self.assertEqual(compact['sessions'][0]['observation']['evidence']['reason'], 'hook says blocked since {}; screen unknown'.format(stamp(1)))
        delivery = m.Delivery(next((self.kdir / '_coordination').glob('watch-delivery-*.json')))
        state = delivery.state()
        state['wakes'][0]['last_delivery'] = 0
        m.atomic(delivery.path, state)
        replay = delivery.pending({'current': [], 'complete': False})
        self.assertEqual((replay['wake_id'], replay['tier'], replay['authority']), (wake['wake_id'], 'confirmed', 'hook-row'))
        self.assertEqual(m.compact_wake(replay)['tier'], 'confirmed')
        plain = self.watch('--compact')
        self.assertEqual((plain['wake_id'], plain['tier']), (wake['wake_id'], 'confirmed'))

    def answer_peeks(self, activities, answered):
        """Answer the watcher's peek requests in order, each with a screen read at answer time."""
        requests = self.kdir / '_sessions/peek-requests'
        responses = self.kdir / '_sessions/peek-responses'
        deadline = time.monotonic() + 30
        for activity in activities:
            found = []
            while not found and time.monotonic() < deadline:
                os.utime(self.registry)
                found = sorted(path for path in requests.glob('*.json') if not path.name.startswith('.')) if requests.exists() else []
                time.sleep(.05)
            if not found:
                return
            request = json.loads(found[0].read_text())
            found[0].unlink()
            responses.mkdir(parents=True, exist_ok=True)
            screen = self.live(activity)
            body = dict(request_id=request['request_id'], slug=self.SLUG, captured_at=screen['observation']['observed_at'],
                        ready=screen['ready'], rows=['fixture'], observation=screen['observation'])
            staged = responses / ('.' + request['request_id'])
            staged.write_text(json.dumps(body))
            staged.rename(responses / (request['request_id'] + '.json'))
            answered.append(screen['observation']['observed_at'])

    def test_a_hook_park_newer_than_the_observation_it_is_compared_with_confirms_from_the_journal(self):
        # The live run's wake-36b3338d: the sweep read the screen 12s before the Stop row fired.
        resumed = self.hook('UserPromptSubmit', 'working', 0)
        resumed['links']['fired_at'] = ago(30)
        self.append(resumed)
        swept = self.live('working')
        swept['observation']['observed_at'] = ago(12)
        merged = dict(swept, observation=m.observation(swept, kdir=self.kdir))
        self.assertIn('hook', merged['observation']['evidence'])
        stop = self.hook('Stop', 'idle', 0)
        stop['links']['fired_at'] = ago(.5)
        stop, = self.append(stop)
        result = m.classify(stop, merged, self.kdir)
        self.assertEqual((result['tier'], result['authority'], result['state'], result['label']),
                         ('confirmed', 'hook-row', 'confirmed_park', 'hook-Stop'))
        self.assertEqual(result['observation']['evidence']['hook']['event_id'], stop['event_id'])
        self.assertIn('before this row', result['observation']['evidence']['screen']['reason'])
        self.assertFalse(m.predates(result['observation'], stop))

    def test_the_watcher_reads_a_session_again_when_its_sample_predates_the_matched_park(self):
        rows = {'hook': lambda: dict(self.hook('Stop', 'idle', 0), links=dict(self.hook('Stop', 'idle', 0)['links'], fired_at=m.timestamp())),
                'screen': lambda: dict(self.screen('needs_input', 'idle', 0), links=dict(self.screen('needs_input', 'idle', 0)['links'], observed_at=m.timestamp()))}
        for source, make in rows.items():
            with self.subTest(source=source):
                for path in (self.kdir / '_coordination').glob('*'):
                    path.unlink()
                self.journal_path.write_text('')
                self.append(self.screen('resumed', 'working', 0))
                start = self.journal_path.stat().st_size
                os.utime(self.registry)
                answered = []
                host = threading.Thread(target=self.answer_peeks, args=(['working', 'idle'], answered))
                host.start()
                watcher = subprocess.Popen(['bash', str(ROOT / 'scripts/coordinate-watch.sh'), '--kdir', str(self.kdir), '--since', str(start),
                                            '--owner-pid', str(os.getpid()), '--durable', '--timeout', '10', '--pending-stale', '0',
                                            '--peek-timeout', '5', '--reconcile-budget', '5', '--json'],
                                           env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                # The row lands once the sweep that read the screen has finished,
                # as it did in the live run, so only the watcher's own look can see it.
                swept = lambda: next((self.kdir / '_coordination').glob('watch-observation-*.json'), None)
                while not (answered and swept()) and host.is_alive() and watcher.poll() is None:
                    time.sleep(.02)
                park, = self.append(make())
                out, err = watcher.communicate(timeout=60)
                host.join(timeout=30)
                self.assertEqual(watcher.returncode, 0, err)
                wake = json.loads(out)
                self.assertEqual(len(answered), 2, err)
                self.assertEqual(wake['matched']['event_id'], park['event_id'])
                self.assertEqual((wake['tier'], wake['classification']['state']), ('confirmed', 'confirmed_park'))
                self.assertLess(m.epoch(answered[0]), m.row_time(park))
                screen = wake['classification']['observation']
                screen = screen['evidence']['screen'] if source == 'hook' else screen
                self.assertEqual(screen['observed_at'], answered[1])
                compact = m.compact_wake(wake)
                self.assertEqual(compact['tier'], 'confirmed')
                self.assertNotIn('reevaluation', compact)
                self.assertEqual(compact['sessions'][0]['observation']['activity'], 'idle')

    def test_a_late_redelivery_of_a_hook_park_still_current_is_judged_by_the_journal(self):
        self.append(self.screen('resumed', 'working', 0), self.hook('Stop', 'idle', 1))
        wake = self.watch('--durable', '--since', '0')
        delivery = m.Delivery(next((self.kdir / '_coordination').glob('watch-delivery-*.json')))
        state = delivery.state()
        stored = state['wakes'][0]
        stored['last_delivery'] = 0
        stored['payload']['classification']['peek']['observation']['observed_at'] = ago(900)
        m.atomic(delivery.path, state)
        replay = delivery.pending({'current': [], 'complete': False})
        self.assertEqual((replay['wake_id'], replay['tier'], replay['authority']), (wake['wake_id'], 'confirmed', 'hook-row'))
        self.assertIn('no longer current', replay['classification']['observation']['evidence']['screen']['reason'])

    def test_a_hook_park_receipt_keeps_its_delivered_tier_and_reports_the_reevaluation(self):
        self.append(self.screen('resumed', 'working', 0), self.hook('Stop', 'idle', 1))
        wake = self.watch('--durable', '--since', '0')
        self.assertEqual(wake['tier'], 'confirmed')
        unchanged = m.wake_receipt(self.kdir, wake['wake_id'])['payload']
        self.assertEqual((unchanged['tier'], unchanged['reevaluation']['tier']), ('confirmed', 'confirmed'))
        self.append(self.hook('UserPromptSubmit', 'working', 2))
        receipt = m.wake_receipt(self.kdir, wake['wake_id'], acknowledge=True)
        payload = receipt['payload']
        self.assertEqual((payload['tier'], payload['authority'], payload['classification']['label']), ('confirmed', 'hook-row', 'hook-Stop'))
        self.assertEqual((payload['reevaluation']['tier'], payload['reevaluation']['classification']['label']), ('advisory', 'hook-Stop-not-current'))
        compact = m.compact_receipt(receipt)['payload']
        self.assertEqual((compact['tier'], compact['reevaluation']['tier'], compact['reevaluation']['label']),
                         ('confirmed', 'advisory', 'hook-Stop-not-current'))

    def test_sweeps_through_the_real_merge_add_no_pending_delta_for_a_reported_park(self):
        self.append(self.screen('resumed', 'working', 0))
        hook, = self.append(self.hook('PreToolUse', 'blocked', 1, tool_name='AskUserQuestion'))
        state = self.kdir / '_coordination/observation.json'
        sample = lambda screen: [{'slug': self.SLUG, 'observation': m.observation(screen, kdir=self.kdir)}]
        first = m.reconcile_samples({}, sample(self.live('unknown')))
        self.assertEqual(list(first['pending']), [self.SLUG])
        m.atomic(state, first)
        m.consume_delta(state, {'outcome': 'current_delta', 'current_delta': [first['pending'][self.SLUG]],
                                'current_observations': {'delta': [first['pending'][self.SLUG]]}})
        saved = m.read(state)
        self.assertEqual(saved['pending'], {})
        self.assertEqual(saved['reported_parks'], {self.SLUG: hook['event_id']})
        for screen, rows in ((self.live('working'), ()), (self.live('idle'), ()),
                             (self.live('blocked', 'sig-x'), (self.screen('needs_input', 'blocked', 2, 'sig-x'), self.modal()))):
            self.append(*rows)
            saved = m.reconcile_samples(saved, sample(screen))
            self.assertEqual(saved['pending'], {})
        # The watcher reading the hook row after that wake raises nothing new either.
        records = {'records': [{'event': hook, 'next_cursor': 0}]}
        verdict = m.annotate_records(self.kdir, records, state)['records'][0]['lifecycle']
        self.assertEqual(verdict, {'skip': True, 'reason': 'reported-by-observation'})

    def test_a_matched_hook_park_wake_leaves_later_sweeps_of_the_same_park_quiet(self):
        self.append(self.screen('resumed', 'working', 0))
        hook, = self.append(self.hook('PreToolUse', 'blocked', 1, tool_name='AskUserQuestion'))
        state = self.kdir / '_coordination/observation.json'
        m.atomic(state, {})
        classified = m.classify(hook, {}, self.kdir)
        m.consume_delta(state, {'outcome': 'matched', 'tier': classified['tier'], 'matched': hook,
                                'classification': classified, 'current_observations': {}})
        saved = m.read(state)
        for screen in (self.live('unknown'), self.live('idle'), self.live('blocked', 'sig-x')):
            saved = m.reconcile_samples(saved, [{'slug': self.SLUG, 'observation': m.observation(screen, kdir=self.kdir)}])
            self.assertEqual(saved['pending'], {})
        self.append(self.screen('resumed', 'working', 5), self.hook('Stop', 'idle', 9))
        saved = m.reconcile_samples(saved, [{'slug': self.SLUG, 'observation': m.observation(self.live('idle'), kdir=self.kdir)}])
        self.assertEqual(list(saved['pending']), [self.SLUG])

    def test_every_arrival_order_of_a_dialogs_rows_with_a_rearm_between_rows_gives_one_durable_wake(self):
        dialog = {'hook': lambda second: self.hook('PreToolUse', 'blocked', second, tool_name='AskUserQuestion'),
                  'host': lambda second: self.screen('needs_input', 'blocked', second, 'sig-x'),
                  'modal': lambda second: self.modal()}
        for order in itertools.permutations(dialog):
            with self.subTest(order=order):
                for path in (self.kdir / '_coordination').glob('*'):
                    path.unlink()
                self.journal_path.write_text('')
                self.append(self.screen('resumed', 'working', 0))
                delivered = []
                for arm, name in enumerate(order, start=1):
                    self.append(dialog[name](arm))
                    wake = self.watch('--durable', *(['--since', '0'] if arm == 1 else []))
                    if wake.get('tier') != 'quiet':
                        delivered.append((wake['wake_id'], wake['matched']['event'], (wake['matched'].get('links') or {}).get('authority')))
                        m.wake_receipt(self.kdir, wake['wake_id'], acknowledge=True)
                self.assertEqual(self.watch('--durable')['tier'], 'quiet')
                self.assertEqual(len(self.wakes()), 1, delivered)
                self.assertEqual(len({wake_id for wake_id, _, _ in delivered}), 1, delivered)
                first = dialog[order[0]](1)
                self.assertEqual(delivered[0][1:], (first['event'], (first.get('links') or {}).get('authority')))

    def test_a_superseded_late_landing_park_raises_no_wake(self):
        # The screen saw the next turn at :05; the previous turn's Stop, fired at :03, lands after it.
        self.append(self.hook('Stop', 'idle', 1), self.hook('UserPromptSubmit', 'working', 2),
                    self.screen('resumed', 'working', 5), self.hook('Stop', 'idle', 3))
        wake = self.watch('--since', '0')
        self.assertEqual((wake['outcome'], wake['tier']), ('timeout', 'quiet'))
        self.assertEqual(self.watch('--since', '0', '--durable')['tier'], 'quiet')
        self.assertEqual(self.wakes(), [])

    def test_journal_order_and_edge_time_disagreeing_keeps_a_park_a_late_resumed_row_followed(self):
        # The screen's resumed row for a half-second turn lands after the turn's StopFailure;
        # the journal-order rule would drop the park, edge time keeps it.
        self.append(self.hook('UserPromptSubmit', 'working', 1.0))
        failure, late = self.append(self.hook('StopFailure', 'blocked', 1.5, error='overloaded'), self.screen('resumed', 'working', 1.3))
        wake = self.watch('--since', '0')
        self.assertEqual((wake['outcome'], wake['tier'], wake['authority']), ('matched', 'confirmed', 'hook-row'))
        self.assertEqual(wake['matched']['event_id'], failure['event_id'])
        records = {'records': [{'event': failure, 'next_cursor': None}, {'event': late, 'next_cursor': None}]}
        self.assertEqual(m.annotate_records(self.kdir, records)['records'][0]['lifecycle']['skip'], False)

    def test_a_stale_generation_hook_park_raises_no_wake_and_an_unknown_generation_wakes_advisory(self):
        _, stale = self.append(self.screen('resumed', 'working', 0), self.hook('StopFailure', 'blocked', 1, generation='old/managed-0/1700000000'))
        self.assertEqual(self.watch('--since', '0')['outcome'], 'timeout')
        verdict = m.annotate_records(self.kdir, {'records': [{'event': stale, 'next_cursor': None}]})['records'][0]['lifecycle']
        self.assertEqual((verdict['skip'], verdict['reason']), (True, 'stale-generation'))
        dead = subprocess.Popen(['true'])
        dead.wait()
        self.own(dead.pid)
        unknown = self.watch('--since', '0')
        self.assertEqual((unknown['outcome'], unknown['tier'], unknown['authority']), ('matched', 'advisory', 'none'))
        self.assertEqual(unknown['classification']['label'], 'hook-StopFailure-generation-unknown')


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

    def append(self, row, delay=0):
        time.sleep(delay)
        with (self.kdir / '_sessions/events.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(row, event_id=row['event'] + '-late', ts=m.timestamp())) + '\n')

    def test_a_teardowns_worktree_outcome_and_closed_row_wake_once_together(self):
        # The live run's wake-dd2b6b9d and wake-a3196b41: one teardown, two confirmed wakes a second apart.
        self.journal([{'event': 'close_requested', 'slug': 'task--w1', 'request_id': 'c1'},
                      {'event': 'worktree_quarantined', 'slug': 'task--w1', 'reason': 'integration_pending'}])
        closing = threading.Thread(target=self.append, args=({'event': 'closed', 'slug': 'task--w1', 'request_id': 'c1'}, 2))
        closing.start()
        _, wake = self.watch('--durable', '--compact', '--since', '0')
        closing.join()
        self.assertEqual((wake['outcome'], wake['tier']), ('matched', 'confirmed'))
        self.assertEqual(wake['matched']['event'], 'closed')
        self.assertEqual([row['event'] for row in wake['journal_batch']], ['worktree_quarantined', 'closed'])
        receipt = m.wake_receipt(self.kdir, wake['wake_id'], acknowledge=True)
        self.assertEqual([row['event'] for row in receipt['payload']['journal_batch']], ['worktree_quarantined', 'closed'])
        _, after = self.watch('--durable')
        self.assertEqual(after['outcome'], 'timeout')

    def test_a_worktree_outcome_no_close_follows_wakes_alone_once_the_settle_bound_passes(self):
        self.journal([{'event': 'worktree_quarantined', 'slug': 'task--w1', 'reason': 'interrupted before harness launch'}])
        started = time.monotonic()
        _, wake = self.watch('--durable', '--since', '0', timeout=30)
        self.assertGreaterEqual(time.monotonic() - started, 7)
        self.assertEqual(wake['matched']['event'], 'worktree_quarantined')
        self.assertNotIn('journal_batch', wake)
        # Without --durable the single-event contract holds and nothing waits.
        started = time.monotonic()
        _, raw = self.watch('--since', '0')
        self.assertLess(time.monotonic() - started, 7)
        self.assertEqual(raw['matched']['event'], 'worktree_quarantined')

    def test_status_reads_a_delivered_confirmed_wake_as_confirmed_after_acknowledgement(self):
        path = self.kdir / '_coordination/watch-delivery-cli.json'
        captured = peek()
        row = {'slug': 'task--w1', 'peek': captured, 'observation': captured['observation']}
        identity = dict(owner_kind='pid', owner_value=str(os.getpid()), key='cli', scope='board')
        wake = m.Delivery(path).publish(dict(outcome='current_delta', tier='confirmed', authority='observation', next_cursor=0,
                                             current_delta=[row], current_observations={'current': [row], 'delta': [row], 'complete': True}),
                                        identity, 0)
        argv = ['bash', str(ROOT / 'scripts/coordinate-status.sh'), '--kdir', str(self.kdir), '--wake-id', wake['wake_id'],
                '--full-evidence', '--receipt-only', '--json']
        for _ in range(2):
            result = subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = json.loads(result.stdout)['wake_receipt']
            self.assertEqual(receipt['payload']['tier'], 'confirmed')
        self.assertTrue(receipt['acknowledged_at'])

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
