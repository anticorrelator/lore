import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


W = load('watch_state_under_test', ROOT / 'scripts/coordinate_watch_state.py')
L = W.lifecycle()
T = load('session_target_under_test', ROOT / 'scripts/session_target.py')

SLUG = 'task--w1'
STARTED = '2026-10-18T09:00:00Z'
REQUEST = 'managed-0123456789abcdef'
GENERATION = T.generation({'slug': SLUG, 'started': STARTED, 'request_id': REQUEST})


def hook_stamp(second):
    """A hook's fired_at: six fractional digits."""
    return '2026-10-18T10:00:{:09.6f}Z'.format(second)


def ago(seconds):
    """A hook-style stamp the given number of seconds before now."""
    return L._iso(int((time.time() - seconds) * 1e6))


def host_stamp(second):
    """A host's observed_at: Go RFC3339Nano, nine digits with trailing zeros trimmed."""
    whole, fraction = divmod(round(second * 1e9), 10 ** 9)
    text = '2026-10-18T10:00:{:02d}'.format(whole)
    if fraction:
        text += '.' + '{:09d}'.format(fraction).rstrip('0')
    return text + 'Z'


def hook_row(event, hook_event, activity, second, generation=GENERATION, **links):
    values = dict(authority='hook-row', hook_event=hook_event, activity=activity, generation=generation,
                  fired_at=hook_stamp(second), framework='claude-code', spawn_instance='host-a')
    values.update(links)
    return dict(event=event, slug=SLUG, session_type='worker', actor_instance='host-a', links=values)


def screen_row(event, activity, second, generation=GENERATION, matcher='claude-code-fixture-v1', block_signature=None):
    observed = dict(schema_version=1, activity=activity, authority='screen-signature', observed_at=host_stamp(second),
                    session_id=SLUG, generation=generation, instance='host-a', fresh=True, max_age_seconds=5,
                    evidence=dict(matcher=matcher, reason='fixture screen'))
    if block_signature:
        observed['block_signature'] = block_signature
    return dict(event=event, slug=SLUG, session_type='worker', actor_instance='host-a',
                links=dict(observation=json.dumps(observed), session_id=SLUG, generation=generation,
                           observed_at=host_stamp(second), activity=activity))


def modal_row():
    return dict(event='modal_blocked', slug=SLUG, session_type='worker', actor_instance='host-a',
                reason='modal', modal_signature='Which option?')


def interrupt_row(event='interrupt_uncertain'):
    return dict(event=event, slug=SLUG, request_id='interrupt-1', actor_instance='host-a', reason='delivery-uncertain',
                links=dict(session_id=SLUG, escape_written='true'))


def live(activity, matcher='claude-code-fixture-v1', block_signature=None, fresh=True, generation=GENERATION):
    value = dict(schema_version=1, activity=activity,
                 authority='none' if activity in ('unknown',) else 'runtime' if activity in ('starting', 'exited') else 'screen-signature',
                 observed_at=W.timestamp(), session_id=SLUG, session_handle=SLUG, generation=generation,
                 instance='host-a', can_accept_input=activity == 'idle', fresh=fresh, max_age_seconds=5,
                 evidence=dict(matcher=matcher if activity != 'unknown' else 'screen-unknown-v1', reason='live fixture'))
    if block_signature:
        value['block_signature'] = block_signature
    return value


def peek(value):
    return {'slug': SLUG, 'ready': value.get('activity') == 'idle', 'observation': value, 'rows': ['fixture']}


class Store(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.kdir = Path(self.temp.name)
        (self.kdir / '_sessions/instances').mkdir(parents=True)
        self.journal = self.kdir / '_sessions/events.jsonl'
        self.serial = 0
        self.owner()

    def owner(self, name='host-a', pid=None, role='session-host', started=STARTED, request_id=REQUEST, slug=SLUG, revision=None):
        row = dict(name=name, pid=os.getpid() if pid is None else pid, role=role,
                   sessions=[dict(slug=slug, type='worker', started=started, request_id=request_id)])
        if revision is not None:
            row['revision'] = revision
        path = self.kdir / '_sessions/instances' / (name + '.json')
        path.write_text(json.dumps(row))
        return path

    def append(self, *rows):
        with self.journal.open('a') as stream:
            for row in rows:
                self.serial += 1
                stream.write(json.dumps(dict(row, event_id='e{}'.format(self.serial), ts='2026-10-18T10:00:00Z'),
                                        separators=(',', ':')) + '\n')

    def rows(self):
        return [json.loads(line) for line in self.journal.read_text().splitlines()]

    def edges(self, generation=GENERATION):
        return L.edges(self.kdir, SLUG, generation)

    def merged(self, value):
        return W.observation(peek(value), kdir=self.kdir)


class D5Rules(Store):
    def test_rule1_process_exit_stands_over_a_hook_park(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1))
        result = self.merged(live('exited'))
        self.assertEqual((result['activity'], result['authority']), ('exited', 'runtime'))
        self.assertNotIn('hook', result['evidence'])

    def test_rule2a_cross_source_parks_of_different_activities_corroborate_and_record_the_disagreement(self):
        self.append(screen_row('resumed', 'working', 0),
                    hook_row('needs_input', 'StopFailure', 'blocked', 1, error='rate_limit'),
                    screen_row('needs_input', 'idle', 2))
        hook, screen = self.rows()[1:]
        found = self.edges()
        self.assertFalse(L.corroborates(hook, found))
        self.assertTrue(L.corroborates(screen, found))
        result = self.merged(live('idle'))
        self.assertEqual((result['activity'], result['authority']), ('blocked', 'hook-row'))
        self.assertEqual([r['event_id'] for r in result['evidence']['corroborated_by']], [screen['event_id']])
        disagreement = result['evidence']['disagreement']
        self.assertIn({'source': 'screen', 'activity': 'idle', 'event': 'needs_input', 'event_id': screen['event_id'],
                       'edge_time': host_stamp(2)}, disagreement)
        self.assertEqual(result['evidence']['hook']['error'], 'rate_limit')

    def test_rule2b_every_arrival_order_of_a_dialogs_three_rows_has_one_establishing_edge(self):
        dialog = {'hook': lambda second: hook_row('needs_input', 'PreToolUse', 'blocked', second, tool_name='AskUserQuestion'),
                  'host': lambda second: screen_row('needs_input', 'blocked', second, block_signature='sig-x'),
                  'modal': lambda second: modal_row()}
        for order in itertools.permutations(dialog):
            with self.subTest(order=order):
                self.journal.write_text('')
                self.append(screen_row('resumed', 'working', 0))
                for second, name in enumerate(order, start=1):
                    self.append(dialog[name](second))
                rows = self.rows()[1:]
                found = self.edges()
                establishing = [row['event_id'] for row in rows if not L.corroborates(row, found)]
                self.assertEqual(len(establishing), 1)
                self.assertEqual(establishing[0], rows[0]['event_id'])
                self.assertFalse(any(L.superseded(row, found) for row in rows))
                result = self.merged(live('blocked', block_signature='sig-x'))
                self.assertEqual(result['activity'], 'blocked')
                self.assertEqual(len(result['evidence']['corroborated_by']), 2)

    def test_rule2_same_source_parks_other_than_the_dialog_pair_stay_separate(self):
        self.append(screen_row('resumed', 'working', 0), hook_row('needs_input', 'Stop', 'idle', 1),
                    hook_row('needs_input', 'PermissionRequest', 'blocked', 2, tool_name='Bash'))
        stop, permission = self.rows()[1:]
        self.assertFalse(L.corroborates(permission, self.edges()))
        self.assertTrue(L.superseded(stop, self.edges()))
        self.assertEqual(self.merged(live('unknown'))['evidence']['hook']['hook_event'], 'PermissionRequest')

    def test_rule3_journal_order_and_edge_time_disagree(self):
        # The screen saw the next turn start at :05; the previous turn's Stop
        # hook, fired at :03, lands after it.
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), hook_row('resumed', 'UserPromptSubmit', 'working', 2),
                    screen_row('resumed', 'working', 5), hook_row('needs_input', 'Stop', 'idle', 3))
        late = self.rows()[-1]
        found = self.edges()
        self.assertTrue(L.superseded(late, found))
        self.assertFalse(L.corroborates(late, found))
        result = self.merged(live('working'))
        self.assertEqual((result['activity'], result['authority']), ('working', 'screen-signature'))
        # In journal order the same rows would leave the session parked.
        reordered = [row for row in self.rows()]
        reordered[-1]['links']['fired_at'] = hook_stamp(6)
        self.assertFalse(L.superseded(reordered[-1], reordered))

    def test_rule3_a_park_followed_by_a_newer_edge_is_superseded_but_not_by_its_corroboration(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), screen_row('needs_input', 'idle', 2))
        stop, screen = self.rows()
        self.assertFalse(L.superseded(stop, self.edges()))
        self.append(screen_row('resumed', 'working', 3))
        self.assertTrue(L.superseded(stop, self.edges()))
        self.assertTrue(L.superseded(screen, self.edges()))

    def test_rule3_a_late_screen_resumed_does_not_split_a_short_turns_park(self):
        # A turn ends on an API error half a second after it starts; the
        # screen's resumed row for that turn lands after the StopFailure row.
        self.append(hook_row('resumed', 'UserPromptSubmit', 'working', 1.0),
                    hook_row('needs_input', 'StopFailure', 'blocked', 1.5, error='overloaded'),
                    screen_row('resumed', 'working', 1.3), screen_row('needs_input', 'idle', 3))
        failure, resumed, settled = self.rows()[1:]
        found = self.edges()
        self.assertTrue(L.superseded(resumed, found))
        self.assertTrue(L.corroborates(settled, found))
        self.assertEqual(self.merged(live('idle'))['authority'], 'hook-row')

    def test_rule3_orders_a_trimmed_host_stamp_by_instant_not_by_text(self):
        # '...05.1Z' sorts after '...05.123456Z' as text but is 23 ms earlier.
        self.append(hook_row('needs_input', 'StopFailure', 'blocked', 5.123456), screen_row('resumed', 'working', 5.1))
        resumed = self.rows()[-1]
        self.assertEqual(resumed['links']['observed_at'], '2026-10-18T10:00:05.1Z')
        self.assertTrue(L.superseded(resumed, self.edges()))
        self.assertEqual(self.merged(live('unknown'))['authority'], 'hook-row')

    def test_rule4_park_keeps_authority_matcher_and_block_signature_while_the_screen_agrees_and_the_dialog_is_drawn(self):
        self.append(screen_row('resumed', 'working', 0),
                    hook_row('needs_input', 'PreToolUse', 'blocked', 1, tool_name='AskUserQuestion'))
        before = self.merged(live('working', matcher='claude-code-working-v1'))
        self.assertEqual((before['activity'], before['authority']), ('blocked', 'hook-row'))
        self.assertEqual(before['evidence']['matcher'], 'claude-code-hook-pre-tool-use-v1')
        self.assertEqual(before['evidence']['disagreement'][-1]['activity'], 'working')
        tokens = [W.semantic_observation(before)]
        self.append(screen_row('needs_input', 'blocked', 2, matcher='claude-code-numbered-modal-v1', block_signature='sig-x'))
        tokens.append(W.semantic_observation(self.merged(live('blocked', matcher='claude-code-numbered-modal-v1', block_signature='sig-x'))))
        self.append(modal_row())
        drawn = self.merged(live('blocked', matcher='claude-code-numbered-modal-v1', block_signature='sig-x'))
        tokens.append(W.semantic_observation(drawn))
        self.assertEqual(tokens[0], tokens[1])
        self.assertEqual(tokens[0], tokens[2])
        self.assertEqual((tokens[0]['authority'], tokens[0]['matcher'], tokens[0]['block_signature']),
                         ('hook-row', 'claude-code-hook-pre-tool-use-v1', None))
        self.assertEqual([r['event'] for r in drawn['evidence']['corroborated_by']], ['needs_input', 'modal_blocked'])
        self.assertEqual(drawn['evidence']['screen']['block_signature'], 'sig-x')

    def test_rule4_a_screen_established_park_keeps_its_values_when_the_screen_turns_unknown(self):
        self.append(screen_row('resumed', 'working', 0),
                    screen_row('needs_input', 'blocked', 1, matcher='claude-code-numbered-modal-v1', block_signature='sig-x'),
                    hook_row('needs_input', 'PreToolUse', 'blocked', 2, tool_name='AskUserQuestion'))
        seen = self.merged(live('blocked', matcher='claude-code-numbered-modal-v1', block_signature='sig-x'))
        lost = self.merged(live('unknown'))
        self.assertEqual(W.semantic_observation(seen), W.semantic_observation(lost))
        self.assertEqual((lost['activity'], lost['authority'], lost['block_signature']), ('blocked', 'screen-signature', 'sig-x'))
        self.assertTrue(lost['evidence']['reason'].startswith('hook says blocked since ' + hook_stamp(2)))

    def test_rule5_an_unknown_screen_yields_the_hook_parks_activity_on_hook_row_authority(self):
        self.append(screen_row('resumed', 'working', 0),
                    hook_row('needs_input', 'StopFailure', 'blocked', 1, error='rate_limit'))
        for screen in ('unknown', 'starting'):
            with self.subTest(screen=screen):
                result = self.merged(live(screen))
                self.assertTrue(result['fresh'])
                self.assertEqual((result['activity'], result['authority']), ('blocked', 'hook-row'))
                self.assertEqual(result['evidence']['screen']['activity'], screen)
                self.assertEqual(result['evidence']['hook']['fired_at'], hook_stamp(1))
                self.assertEqual(result['evidence']['reason'], 'hook says blocked since {}; screen {}'.format(hook_stamp(1), screen))
        unavailable = self.merged(live('unknown', fresh=False))
        self.assertEqual((unavailable['activity'], unavailable['authority'], unavailable['fresh']), ('blocked', 'hook-row', True))

    def test_rule5_an_unknown_screen_stays_unknown_beside_a_hook_working_edge_past_the_turns_hold(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), hook_row('resumed', 'UserPromptSubmit', 'working', 2))
        result = self.merged(live('unknown'))
        self.assertEqual((result['activity'], result['authority']), ('unknown', 'none'))
        self.assertFalse(result['evidence']['turn']['held'])
        self.assertEqual(result['evidence']['hook']['activity'], 'working')
        self.assertEqual(result['evidence']['hook']['fired_at'], hook_stamp(2))
        self.assertEqual(result['evidence']['screen']['activity'], 'unknown')
        self.assertEqual(result['evidence']['reason'], 'hook says working since {}; screen unknown'.format(hook_stamp(2)))
        text = W.peek_summary(dict(peek(live('unknown')), observation=result))
        self.assertIn('hook says working since {}; screen unknown'.format(hook_stamp(2)), text)

    def test_rule5_a_turn_the_hook_reported_starting_reads_working_over_an_unknown_screen_within_its_hold(self):
        # The live run's mid-turn peek: the hook's and the screen's resumed rows, then a shell
        # command no signature matches, read activity=unknown authority=none.
        self.append(hook_row('needs_input', 'Stop', 'idle', 1),
                    dict(hook_row('resumed', 'UserPromptSubmit', 'working', 2), links=dict(hook_row('resumed', 'UserPromptSubmit', 'working', 2)['links'], fired_at=ago(62))))
        started = self.rows()[-1]
        later = screen_row('resumed', 'working', 0)
        later['links']['observed_at'] = ago(60)
        self.append(later)
        for screen in ('unknown', 'starting'):
            with self.subTest(screen=screen):
                result = self.merged(live(screen))
                self.assertTrue(result['fresh'])
                self.assertEqual((result['activity'], result['authority']), ('working', 'hook-row'))
                self.assertEqual(result['evidence']['matcher'], 'claude-code-hook-user-prompt-submit-v1')
                self.assertEqual(result['evidence']['hook']['event_id'], started['event_id'])
                self.assertEqual(result['evidence']['corroborated_by'][0]['source'], 'screen')
                self.assertTrue(result['evidence']['turn']['held'])
                self.assertEqual(result['evidence']['turn']['last_sign_at'], later['links']['observed_at'])
                self.assertEqual(result['evidence']['reason'], 'hook says working since {}; screen {}'.format(started['links']['fired_at'], screen))
                self.assertEqual(result['can_accept_input'], False)
        # A known screen still decides, as before.
        working = live('working')
        self.assertIs(L.merge(working, self.edges()), working)

    def test_rule5_the_turns_hold_runs_from_its_last_sign_and_ends_with_any_edge_but_a_resume(self):
        bound = L.TURN_HOLD_SECONDS
        self.append(dict(hook_row('resumed', 'UserPromptSubmit', 'working', 1), links=dict(hook_row('resumed', 'UserPromptSubmit', 'working', 1)['links'], fired_at=ago(bound + 30))))
        self.assertEqual(self.merged(live('unknown'))['activity'], 'unknown')
        # Output the screen last saw while it could still read the turn is a sign of it.
        progressed = dict(live('unknown'), progress_observed_at=ago(bound - 30))
        result = self.merged(progressed)
        self.assertEqual((result['activity'], result['authority']), ('working', 'hook-row'))
        self.assertEqual(result['evidence']['turn']['last_sign_at'], progressed['progress_observed_at'])
        for ending in (interrupt_row(), screen_row('needs_input', 'idle', 3), dict(event='closed', slug=SLUG, request_id='close-1')):
            with self.subTest(ending=ending['event']):
                self.journal.write_text('')
                self.append(dict(hook_row('resumed', 'UserPromptSubmit', 'working', 1), links=dict(hook_row('resumed', 'UserPromptSubmit', 'working', 1)['links'], fired_at=ago(5))))
                self.assertEqual(self.merged(live('unknown'))['activity'], 'working')
                ending = dict(ending)
                if ending['event'] == 'needs_input':
                    ending['links'] = dict(ending['links'], observed_at=ago(1))
                self.append(ending)
                self.assertNotEqual(self.merged(live('unknown'))['activity'], 'working')

    def test_rule6_a_newer_separated_screen_edge_overrides_an_older_hook_edge(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), screen_row('resumed', 'working', 2))
        working = live('working')
        self.assertIs(L.merge(working, self.edges()), working)
        self.append(screen_row('needs_input', 'idle', 3))
        idle = live('idle')
        self.assertIs(L.merge(idle, self.edges()), idle)
        result = self.merged(live('unknown'))
        self.assertEqual((result['activity'], result['authority']), ('unknown', 'none'))

    def test_rule7_a_known_screen_that_differs_from_a_newer_hook_edge_is_recorded_not_acted_on(self):
        self.append(screen_row('needs_input', 'idle', 0), hook_row('resumed', 'UserPromptSubmit', 'working', 1))
        result = self.merged(live('idle', matcher='claude-code-worked-for-v1'))
        self.assertEqual((result['activity'], result['authority']), ('working', 'hook-row'))
        self.assertEqual(result['can_accept_input'], True)
        self.assertEqual(result['evidence']['disagreement'], [{'source': 'screen', 'activity': 'idle', 'matcher': 'claude-code-worked-for-v1',
                                                               'authority': 'screen-signature', 'observed_at': result['evidence']['screen']['observed_at']}])

    def test_rule8_a_stale_generation_hook_row_confirms_nothing(self):
        stale = hook_row('needs_input', 'StopFailure', 'blocked', 1, generation='old-launch/managed-old/1700000000')
        self.append(screen_row('resumed', 'working', 0), stale)
        row = self.rows()[-1]
        found = self.edges()
        self.assertTrue(L.stale_generation(row, GENERATION))
        self.assertTrue(L.superseded(row, found))
        self.assertFalse(L.corroborates(row, found))
        result = self.merged(live('unknown'))
        self.assertEqual((result['activity'], result['authority']), ('unknown', 'none'))
        self.assertEqual(result['evidence']['stale_hook_rows'][0]['event_id'], row['event_id'])
        self.assertEqual(W.classify(row, peek(result))['tier'], 'advisory')
        self.append(screen_row('needs_input', 'idle', 2))
        self.assertFalse(L.corroborates(self.rows()[-1], self.edges()))

    def test_rule8_while_no_live_owner_lists_the_session_hook_rows_decide_nothing(self):
        self.owner(pid=999999)
        self.assertIsNone(L.current_generation(self.kdir, SLUG))
        self.append(hook_row('needs_input', 'StopFailure', 'blocked', 1))
        result = self.merged(live('unknown'))
        self.assertEqual((result['activity'], result['authority']), ('unknown', 'none'))
        self.assertEqual(result['evidence']['hook_unconfirmed']['hook_event'], 'StopFailure')

    def test_lores_interrupt_row_ends_a_hook_working_edge_and_a_hook_park(self):
        self.append(hook_row('resumed', 'UserPromptSubmit', 'working', 1), interrupt_row())
        result = self.merged(live('unknown'))
        self.assertEqual((result['activity'], result['authority']), ('unknown', 'none'))
        self.assertNotIn('hook', result['evidence'])
        self.append(hook_row('needs_input', 'Stop', 'idle', 2), interrupt_row('interrupt_sent'))
        self.assertEqual(self.merged(live('unknown'))['activity'], 'unknown')
        self.assertTrue(L.superseded(self.rows()[-2], self.edges()))

    def test_a_closed_row_ends_a_hook_park(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), dict(event='closed', slug=SLUG, request_id='close-1'))
        self.assertEqual(self.merged(live('unknown'))['activity'], 'unknown')
        self.assertTrue(L.superseded(self.rows()[0], self.edges()))


class JournalScan(Store):
    def filler(self, size, slug='someone-else--w9'):
        row = json.dumps(dict(event='resumed', slug=slug, links=dict(activity='working', observation='x' * 900)),
                         separators=(',', ':')) + '\n'
        with self.journal.open('a') as stream:
            stream.write(row * (size // len(row) + 1))

    def test_an_establishing_edge_beyond_the_scan_cap_is_reported_truncated_and_the_previous_state_is_kept(self):
        self.append(screen_row('resumed', 'working', 0), hook_row('needs_input', 'StopFailure', 'blocked', 1))
        held = self.merged(live('unknown'))
        self.assertEqual((held['activity'], held['authority']), ('blocked', 'hook-row'))
        token = W.semantic_observation(held)
        state = W.reconcile_samples({}, [{'slug': SLUG, 'observation': held}])
        self.filler(256 * 1024)
        self.append(screen_row('needs_input', 'blocked', 2))
        with patch.object(L, 'SCAN_LIMIT_BYTES', 64 * 1024), patch.object(L, 'SCAN_CHUNK_BYTES', 4096):
            found = self.edges()
            self.assertTrue(found['truncated'])
            self.assertLessEqual(found['scanned_bytes'], 64 * 1024)
            capped = self.merged(live('unknown'))
        self.assertTrue(capped['evidence']['truncated'])
        self.assertEqual(capped['evidence']['journal_scan']['limit_bytes'], 64 * 1024)
        self.assertEqual(capped['activity'], 'unknown')
        after = W.reconcile_samples(json.loads(json.dumps(state)), [{'slug': SLUG, 'observation': capped}])
        self.assertEqual(after, state)
        self.assertEqual(W.reconcile_samples({}, [{'slug': SLUG, 'observation': capped}])['states'], {})
        self.assertIn('scan reached its bound', W.peek_summary(dict(peek(live('unknown')), observation=capped)))
        uncapped = self.merged(live('unknown'))
        self.assertEqual((uncapped['activity'], uncapped['authority']), ('blocked', 'hook-row'))
        self.assertEqual(W.semantic_observation(uncapped), token)

    def test_the_scan_reads_only_the_tail_when_where_the_state_began_is_near_the_end(self):
        self.filler(3 * 1024 * 1024)
        self.append(screen_row('needs_input', 'idle', 0), screen_row('resumed', 'working', 1),
                    hook_row('needs_input', 'Stop', 'idle', 2))
        found = self.edges()
        self.assertFalse(found['truncated'])
        self.assertLessEqual(found['scanned_bytes'], L.SCAN_CHUNK_BYTES)
        self.assertEqual([e['event'] for e in found['edges']], ['needs_input', 'resumed', 'needs_input'])

    def test_a_timed_resumed_row_with_nothing_older_nearby_settles_within_the_late_window(self):
        self.append(screen_row('needs_input', 'idle', 0))
        self.filler(3 * 1024 * 1024)
        self.append(screen_row('resumed', 'working', 1))
        found = self.edges()
        self.assertFalse(found['truncated'])
        self.assertLess(found['scanned_bytes'], L.LATE_WINDOW_BYTES + 2 * L.SCAN_CHUNK_BYTES)
        self.assertEqual([e['event'] for e in found['edges']], ['resumed'])

    def test_the_scan_stops_at_the_sessions_spawned_row(self):
        self.append(hook_row('needs_input', 'Stop', 'idle', 1), dict(event='spawned', slug=SLUG, request_id=REQUEST),
                    screen_row('needs_input', 'idle', 2))
        found = self.edges()
        self.assertEqual(found['boundary']['event'], 'spawned')
        self.assertEqual([e['event_id'] for e in found['edges']], ['e3'])
        self.assertTrue(L.superseded(self.rows()[0], found, position=len(self.journal.read_bytes().splitlines(True)[0])))
        self.assertIs(L.merge(live('idle'), found)['activity'], 'idle')

    def test_rows_longer_than_a_chunk_and_an_unfinished_last_row_are_read_correctly(self):
        self.append(screen_row('resumed', 'working', 0), hook_row('needs_input', 'Stop', 'idle', 1))
        with self.journal.open('a') as stream:
            stream.write(json.dumps(hook_row('resumed', 'UserPromptSubmit', 'working', 2)))
        with patch.object(L, 'SCAN_CHUNK_BYTES', 64):
            found = self.edges()
        self.assertEqual([(e['event'], e['source']) for e in found['edges']], [('resumed', 'screen'), ('needs_input', 'hook')])
        lines = self.journal.read_bytes().split(b'\n')
        self.assertEqual(found['edges'][1]['start'], len(lines[0]) + 1)
        self.assertEqual(found['edges'][1]['end'], len(lines[0]) + len(lines[1]) + 2)

    def test_edge_times_compare_hook_and_host_stamps_by_instant(self):
        self.assertGreater('2026-10-18T10:00:05.1Z', '2026-10-18T10:00:05.123456Z')
        self.assertLess(L.edge_time('2026-10-18T10:00:05.1Z'), L.edge_time('2026-10-18T10:00:05.123456Z'))
        self.assertEqual(L.edge_time('2026-10-18T10:00:05.123456789Z'), L.edge_time('2026-10-18T10:00:05.123456Z'))
        self.assertEqual(L.edge_time('2026-10-18T12:00:05+02:00'), L.edge_time('2026-10-18T10:00:05Z'))
        for bad in ('2026-02-30T10:00:00Z', '2026-10-18 10:00:00Z', '', None, 5):
            self.assertIsNone(L.edge_time(bad))
        result = subprocess.run(['/usr/bin/python3', '-c', 'import sys; sys.path.insert(0, sys.argv[1]); import session_lifecycle as l; '
                                 'print(l.edge_time("2026-10-18T10:00:05.123456789Z") - l.edge_time("2026-10-18T10:00:05.1Z"))',
                                 str(ROOT / 'scripts')], capture_output=True, text=True)
        if result.returncode == 0:
            self.assertEqual(result.stdout.strip(), '23456')


class CurrentGeneration(Store):
    def test_the_current_generation_comes_from_the_newest_live_owner_row(self):
        later = T.generation({'slug': SLUG, 'started': '2026-10-18T09:30:00Z', 'request_id': REQUEST})
        dead = subprocess.Popen(['true'])
        dead.wait()
        self.owner(name='dead-host', pid=dead.pid, started='2026-10-18T09:40:00Z')
        stale = self.owner(name='stale-host', started='2026-10-18T09:45:00Z')
        os.utime(stale, (time.time() - 60, time.time() - 60))
        self.owner(name='spawn-checkpoint', role='session-host-spawn', started='2026-10-18T09:50:00Z')
        self.assertEqual(L.current_generation(self.kdir, SLUG), GENERATION)
        os.utime(self.kdir / '_sessions/instances/host-a.json', (time.time() - 5, time.time() - 5))
        self.owner(name='host-b', started='2026-10-18T09:30:00Z')
        self.assertEqual(L.current_generation(self.kdir, SLUG), later)
        self.assertEqual(L.current_owner(self.kdir, SLUG)[0], 'host-b')
        # A newer registration outranks a more recent heartbeat.
        self.owner(name='host-c', started='2026-10-18T09:20:00Z', revision=2)
        self.owner(name='host-d', started='2026-10-18T09:10:00Z', revision=1)
        self.assertEqual(L.current_owner(self.kdir, SLUG)[0], 'host-c')
        self.assertIsNone(L.current_generation(self.kdir, 'nobody--w2'))


class ScreenOnly(Store):
    def test_a_screen_only_sessions_observation_is_unchanged(self):
        self.append(screen_row('resumed', 'working', 0), screen_row('needs_input', 'blocked', 1), modal_row(),
                    interrupt_row(), dict(event='closed', slug='other--w3'))
        for value in (live('idle'), live('unknown'), live('blocked', block_signature='sig-x'), live('working', fresh=False)):
            with self.subTest(activity=value['activity']):
                plain = W.observation(peek(value))
                merged = self.merged(value)
                plain.pop('age_seconds')
                merged.pop('age_seconds')
                self.assertEqual(json.dumps(merged, sort_keys=True), json.dumps(plain, sort_keys=True))
                assessed = W.assessed(peek(value))
                self.assertIs(L.merge(assessed, self.edges()), assessed)
        self.journal.unlink()
        assessed = W.assessed(peek(live('idle')))
        self.assertIs(L.merge(assessed, self.edges()), assessed)


if __name__ == '__main__':
    unittest.main()
