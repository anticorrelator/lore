import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PeekHistoryCLI(unittest.TestCase):
    def exchange(self, args, response):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            instances = root / '_sessions/instances'
            instances.mkdir(parents=True)
            (instances / 'test-host.json').write_text(json.dumps(dict(name='test-host', pid=os.getpid(), repo='lore', sessions=[dict(slug='worker', type='implement', initiator='human', started='2026-09-05T00:00:00Z')])) )
            process = subprocess.Popen(['bash', str(ROOT / 'scripts/session-peek.sh'), 'worker', '--kdir', str(root), '--timeout', '5', '--json', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            request = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and process.poll() is None:
                paths = list((root / '_sessions/peek-requests').glob('*.json'))
                if paths:
                    request = json.loads(paths[0].read_text())
                    break
                time.sleep(.03)
            if request is not None:
                output = root / '_sessions/peek-responses'
                output.mkdir()
                (output / (request['request_id'] + '.json')).write_text(json.dumps(dict(request_id=request['request_id'], slug='worker', ready=True, captured_at='2026-09-05T00:00:00Z', **response)))
            stdout, stderr = process.communicate(timeout=8)
            return process.returncode, json.loads(stdout), request, stderr

    def test_summary_strips_legacy_bulk_but_keeps_modal(self):
        code, result, request, _ = self.exchange(['--summary'], dict(rows=['secret-large-row'], ansi='raw-large-row', screen={'width': 100}, history={'rows': ['older']}, modal={'title': 'Decision', 'options': [{'label': 'Keep waiting'}]}))
        self.assertEqual(code, 0)
        self.assertTrue(request['summary'])
        self.assertTrue(result['summary'])
        for key in ['rows', 'ansi', 'history', 'screen']:
            self.assertNotIn(key, result)
        self.assertEqual(result['modal']['title'], 'Decision')
        self.assertIn('observation', result)

    def test_legacy_host_refuses_history(self):
        code, result, request, _ = self.exchange(['--lines', '100'], dict(rows=['live-only']))
        self.assertEqual(code, 1)
        self.assertIn('history-unsupported-by-host', result['error'])
        self.assertEqual(request['lines'], 100)

    def test_paging_flags_and_refusal(self):
        code, result, request, _ = self.exchange(['--before', 'opaque-cursor', '--lines', '50', '--max-bytes', '900', '--raw'], dict(error='history-cursor-session-mismatch'))
        self.assertEqual(code, 1)
        self.assertEqual(result['error'], 'history-cursor-session-mismatch')
        self.assertEqual((request['before'], request['lines'], request['max_bytes'], request['raw']), ('opaque-cursor', 50, 900, True))

    def test_invalid_limits_refuse_before_enqueue(self):
        for args in [['--lines', '0'], ['--lines', '501'], ['--max-bytes', '0'], ['--max-bytes', '16385'], ['--summary', '--raw'], ['--summary', '--lines', '20']]:
            with self.subTest(args=args):
                code, _, request, _ = self.exchange(args, {})
                self.assertEqual(code, 1)
                self.assertIsNone(request)


if __name__ == '__main__':
    unittest.main()
