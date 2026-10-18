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
        self.root = Path(self.tmp.name).resolve()
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
                m.ensure(self.root, timeout=0)
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

class StoreScopeAdmission(unittest.TestCase):
    """A store host serves every checkout of its store, checked as the host checks
    it at claim time: by resolving the checkout with LORE_KNOWLEDGE_DIR removed."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        env = {k: v for k, v in os.environ.items() if k not in {'LORE_KNOWLEDGE_DIR', 'LORE_SESSION_RUNTIME'}}
        env['LORE_DATA_DIR'] = str(self.root / 'data')
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.kdir = self.root / 'data/repos/github.com/acme/widget'
        self.instances = self.kdir / '_sessions/instances'
        self.instances.mkdir(parents=True)
        self.key = m.RUNTIME.store_host_key(self.kdir)
        self.ours = self.checkout('ours', 'https://github.com/acme/widget.git')
        self.foreign = self.checkout('foreign', 'https://github.com/other/thing.git')
        self.unresolvable = self.checkout('unresolvable', None)
        (self.instances / 'store-host.json').write_text(json.dumps(dict(
            name='store-host', pid=os.getpid(), role='session-host', scope='store', host_key=self.key,
            runtime_capabilities=[a.POSITION_CAPABILITY], build_time='2026-10-18T00:00:00Z')))

    def checkout(self, name, remote):
        path = self.root / 'checkouts' / name
        path.mkdir(parents=True)
        subprocess.run(['git', '-C', str(path), 'init', '-q'], check=True)
        if remote:
            subprocess.run(['git', '-C', str(path), 'remote', 'add', 'origin', remote], check=True)
        return str(path)

    def row(self, required, **fields):
        row = dict(host_key=self.key, required_project_dir=required, extra_context={'position_preparation': {}})
        row.update(fields)
        return row

    def test_a_checkout_of_the_store_is_admitted_to_its_store_host_without_a_name_pin(self):
        self.assertNotIn('LORE_KNOWLEDGE_DIR', os.environ)
        row = a.admit(self.row(self.ours), self.instances)
        self.assertNotIn('target_instance', row)
        self.assertEqual(row['required_runtime_capabilities'], [a.POSITION_CAPABILITY])

    def test_a_foreign_checkout_or_one_inside_the_store_is_refused(self):
        inside = self.kdir / '_coordination/worktrees/tree'
        inside.mkdir(parents=True)
        subprocess.run(['git', '-C', str(inside), 'init', '-q'], check=True)
        for required in (self.foreign, str(inside), str(self.root / 'checkouts')):
            with self.subTest(required=required), self.assertRaisesRegex(RuntimeError, 'no live compatible runtime'):
                a.admit(self.row(required), self.instances)
        self.assertIn('belongs to knowledge store', a.placement(self.instances, self.key, self.foreign)['store_checkout_error'])
        self.assertIn('lies inside the knowledge store', a.placement(self.instances, self.key, str(inside))['store_checkout_error'])

    def test_a_pinned_store_skips_resolution(self):
        with self.assertRaises(RuntimeError):
            a.admit(self.row(self.unresolvable), self.instances)
        served = m.RUNTIME.login_dir() / 'served.json'
        served.parent.mkdir(parents=True)
        served.write_text(json.dumps({'schema_version': 1, 'stores': {str(self.kdir): {'pin_knowledge_dir': True}}}))
        self.assertNotIn('target_instance', a.admit(self.row(self.unresolvable), self.instances))
        with self.assertRaises(RuntimeError):
            a.admit(self.row(str(self.kdir / '_sessions')), self.instances)

    def test_placement_counts_only_rows_that_would_claim(self):
        (self.instances / 'tui.json').write_text(json.dumps(dict(name='tui', project_dir=self.foreign)))
        keyed = a.placement(self.instances, self.key, self.ours)
        self.assertEqual((keyed['served'], keyed['served_by']), (True, ['store-host']))
        self.assertEqual(a.placement(self.instances, self.key, self.foreign)['served_by'], [])
        unkeyed = a.placement(self.instances, '', self.ours)
        self.assertEqual((unkeyed['served'], unkeyed['servers']), (False, [f'tui: {self.foreign}']))
        self.assertEqual(a.placement(self.instances, '', self.foreign)['served_by'], ['tui'])
        with self.assertRaisesRegex(RuntimeError, 'no live compatible runtime'):
            a.admit(self.row(self.ours, host_key=''), self.instances)


if __name__ == '__main__':
    unittest.main()
