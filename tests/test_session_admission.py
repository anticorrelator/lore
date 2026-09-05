import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

a = load('admission', 'session-admission.py')
m = load('managed_admission', 'session-managed.py')

class Admission(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.instances = self.root / '_sessions/instances'
        self.instances.mkdir(parents=True)

    def host(self, name, **fields):
        row = dict(name=name, project_dir='/source', build_time='2026-09-05T00:00:00Z')
        row.update(fields)
        (self.instances / (name + '.json')).write_text(json.dumps(row))
        return row

    def row(self, **fields):
        row = dict(extra_context={'position_preparation': {}}, placement_stance='any')
        row.update(fields)
        return row

    def test_legacy_reader_cannot_claim_new_payload(self):
        self.host('legacy')
        self.host('compatible', runtime_capabilities=[a.POSITION_CAPABILITY])
        row = a.admit(self.row(), self.instances)
        # The old reader ignores extra fields and enforces only its known target.
        legacy_claim = lambda name: not row.get('target_instance') or row['target_instance'] == name
        self.assertFalse(legacy_claim('legacy'))
        self.assertTrue(legacy_claim('compatible'))
        (self.instances / 'compatible.json').unlink()
        self.assertFalse(legacy_claim('legacy'))  # loss never broadens an existing pin
        with self.assertRaisesRegex(RuntimeError, a.POSITION_CAPABILITY):
            a.admit(self.row(), self.instances)

    def test_hard_placement_unknown_support_and_preference(self):
        self.host('old')
        self.host('wrong-dir', project_dir='/other', runtime_capabilities=[a.POSITION_CAPABILITY])
        for row in (self.row(target_instance='old'), self.row(required_project_dir='/source')):
            with self.assertRaisesRegex(RuntimeError, 'no live compatible'):
                a.admit(row, self.instances)
        self.host('preferred', runtime_capabilities=[a.POSITION_CAPABILITY])
        row = a.admit(self.row(prefer_project_dir='/source'), self.instances)
        self.assertEqual(row['target_instance'], 'preferred')
        self.assertEqual(row['prefer_project_dir'], '/source')

    def test_stale_and_managed_hosts_do_not_serve_ordinary_requests(self):
        self.host('stale', runtime_capabilities=[a.POSITION_CAPABILITY])
        os.utime(self.instances / 'stale.json', (0, 0))
        self.host('managed', host_key='key', runtime_capabilities=[a.POSITION_CAPABILITY])
        with self.assertRaises(RuntimeError):
            a.admit(self.row(), self.instances)
        self.assertEqual(a.admit(self.row(host_key='key'), self.instances)['target_instance'], 'managed')

    def test_invalid_capability_metadata_is_not_support(self):
        for value in ('position-preparation-v1', {'position-preparation-v1': True}, None, [3]):
            self.host('invalid', runtime_capabilities=value)
            with self.assertRaises(RuntimeError):
                a.admit(self.row(), self.instances)
            with self.assertRaises(RuntimeError):
                m.require_capabilities({'runtime_capabilities': value})

    def test_floor_requires_valid_known_vintage(self):
        for value in (None, '', 'nonsense', '2026-09-01T00:00:00Z'):
            self.host('host', build_time=value)
            with self.assertRaises(RuntimeError):
                a.admit(dict(min_vintage='2026-09-05T00:00:00Z'), self.instances)
        self.host('host')
        self.assertEqual(a.admit(dict(min_vintage='2026-09-05T00:00:00Z'), self.instances)['target_instance'], 'host')
        self.assertEqual(a.admit({}, self.instances), {})

    def test_managed_old_host_refused_without_binary_or_restart(self):
        with patch.object(m, 'ready', return_value={'instance_name': 'old'}), patch.object(m, 'binary') as binary, patch.object(m.subprocess, 'Popen') as spawn:
            with self.assertRaisesRegex(RuntimeError, 'coordinate host replacement'):
                m.ensure(self.root, 'key', '/source', timeout=0)
        binary.assert_not_called()
        spawn.assert_not_called()

    def test_ready_requires_both_runtime_records(self):
        directory = m.host_dir(self.root, 'key')
        m.atomic(directory / 'ready.json', dict(ready=True, host_key='key', source_dir='/source', knowledge_dir=str(self.root), pid=os.getpid(), instance_name='host', runtime_capabilities=[a.POSITION_CAPABILITY]))
        self.host('host', host_key='key', role='session-host')
        with patch.object(m, 'held', return_value=True):
            status = m.ready(self.root, 'key', '/source')
        with self.assertRaises(RuntimeError):
            m.require_capabilities(status)

    def test_writer_floor_refuses_before_publication(self):
        self.host('unknown', build_time='')
        result = subprocess.run(['bash', str(ROOT / 'scripts/session-request.sh'), '--type', 'chat', '--anywhere', '--min-vintage', '2026-09-05T00:00:00Z', '--kdir', str(self.root), '--json'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('known build vintage', result.stderr)
        self.assertEqual(list((self.root / '_sessions/requests/pending').glob('*.json')), [])

if __name__ == '__main__':
    unittest.main()
