"""Exercise the actual disposition reader and shell event selectors."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('managed_no_changes', ROOT / 'scripts/session-managed.py')
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)


class NoChanges(unittest.TestCase):
    def test_composition_requires_only_actionable_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            for event, reason, expected in [
                ('worktree_quarantined', 'no_changes', False),
                ('worktree_quarantined', 'integration_pending', True),
                ('worktree_quarantined', '', True),
                ('restore_refused', 'no_changes', True),
                ('worktree_no_changes', 'no_changes', False),
            ]:
                with self.subTest(event=event, reason=reason), patch.object(managed, 'events', return_value=[dict(event=event, reason=reason)]):
                    result = managed.disposition(Path(tmp), 'demo--w123')
                    self.assertEqual(result['composition_judgment_required'], expected)
                    self.assertFalse(result['integrated'])

    def test_default_wait_skips_no_changes_but_keeps_close_and_explicit_audit(self):
        for script in ['session-wait.sh', 'coordinate-watch.sh']:
            source = (ROOT / 'scripts' / script).read_text()
            function = source.split('first_match_record() {', 1)[1].split('\n}', 1)[0]
            lib = (ROOT / 'scripts/lib.sh').read_text()
            predicate = lib.split("SESSION_SCOPE_JQ_PREDICATE='", 1)[1].split("'", 1)[0]
            for explicit, reason, expected in [(0, 'no_changes', 2), (1, 'no_changes', 1), (0, 'integration_pending', 1), (0, 'no_changes: unknown', 1)]:
                records = dict(records=[
                    dict(event=dict(event='worktree_quarantined', reason=reason, slug='demo'), next_cursor=1),
                    dict(event=dict(event='closed', slug='demo'), next_cursor=2)])
                command = '''SLUG=demo; REQUEST_ID=''; REQUEST_ID_SET=0; WORK_ITEM_SET=0; DURABLE=0
UNTIL_JSON='["worktree_quarantined","closed"]'; SCOPE_SLUGS_JSON='[]'; SCOPED=0
UNTIL_EXPLICIT="$2"
SESSION_SCOPE_JQ_PREDICATE="$3"
first_match_record() {''' + function + '\n}\nfirst_match_record "$1"'
                result = subprocess.run(['bash', '-c', command, 'selector', json.dumps(records), str(explicit), predicate], text=True, capture_output=True, check=True)
                with self.subTest(script=script, explicit=explicit, reason=reason):
                    self.assertEqual(json.loads(result.stdout)['next_cursor'], expected)

    def test_default_wait_skips_worktree_no_changes_but_explicit_filter_returns_it(self):
        lib = (ROOT / 'scripts/lib.sh').read_text()
        predicate = lib.split("SESSION_SCOPE_JQ_PREDICATE='", 1)[1].split("'", 1)[0]
        actionable = lib.split('SESSION_ACTIONABLE_EVENTS="', 1)[1].split('"', 1)[0].split()
        records = dict(records=[
            dict(event=dict(event='worktree_no_changes', reason='no_changes', slug='demo'), next_cursor=1),
            dict(event=dict(event='closed', slug='demo'), next_cursor=2)])
        for script in ['session-wait.sh', 'coordinate-watch.sh']:
            source = (ROOT / 'scripts' / script).read_text()
            function = source.split('first_match_record() {', 1)[1].split('\n}', 1)[0]
            for explicit, until, expected in [(0, actionable, 2), (1, ['worktree_no_changes', 'closed'], 1)]:
                command = '''SLUG=demo; REQUEST_ID=''; REQUEST_ID_SET=0; WORK_ITEM_SET=0; DURABLE=0
SCOPE_SLUGS_JSON='[]'; SCOPED=0
UNTIL_EXPLICIT="$2"; UNTIL_JSON="$3"
SESSION_SCOPE_JQ_PREDICATE="$4"
first_match_record() {''' + function + '\n}\nfirst_match_record "$1"'
                result = subprocess.run(['bash', '-c', command, 'selector', json.dumps(records), str(explicit), json.dumps(until), predicate], text=True, capture_output=True, check=True)
                with self.subTest(script=script, explicit=explicit):
                    self.assertEqual(json.loads(result.stdout)['next_cursor'], expected)


if __name__ == '__main__':
    unittest.main()
