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
    """A row that needs a capability or a build floor is admitted only to the live
    store host holding its key, the one process that claims it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.instances = self.root / '_sessions/instances'
        self.instances.mkdir(parents=True)

    def host(self, name='store-host', **fields):
        row = dict(name=name, role='session-host', scope='store', host_key='key', build_time='2026-09-05T00:00:00Z')
        row.update(fields)
        (self.instances / (name + '.json')).write_text(json.dumps(row))
        return row

    def row(self, **fields):
        row = dict(host_key='key', extra_context={'position_preparation': {}}, placement_stance='preferred_dir',
                   prefer_project_dir='/source')
        row.update(fields)
        return row

    def test_a_store_host_without_the_capability_cannot_take_new_payload(self):
        self.host()
        with self.assertRaisesRegex(RuntimeError, '^store host is too old: run lore rebuild, then retry\n'):
            a.admit(self.row(), self.instances)
        self.host(runtime_capabilities=[a.POSITION_CAPABILITY])
        row = a.admit(self.row(), self.instances)
        self.assertNotIn('target_instance', row)
        self.assertEqual(row['required_runtime_capabilities'], [a.POSITION_CAPABILITY])

    def test_only_the_live_store_host_holding_the_key_admits(self):
        (self.instances / 'tui.json').write_text(json.dumps(dict(
            name='tui', project_dir='/source', build_time='2026-09-05T00:00:00Z',
            runtime_capabilities=[a.POSITION_CAPABILITY])))
        self.host('other-store', host_key='other', runtime_capabilities=[a.POSITION_CAPABILITY])
        self.host('checkout-host', scope=None, runtime_capabilities=[a.POSITION_CAPABILITY])
        for row in (self.row(), self.row(host_key=''), self.row(host_key=None)):
            with self.subTest(row=row), self.assertRaisesRegex(RuntimeError, '^no live store host: run lore session ensure'):
                a.admit(row, self.instances)
        self.host(runtime_capabilities=[a.POSITION_CAPABILITY])
        os.utime(self.instances / 'store-host.json', (0, 0))
        with self.assertRaisesRegex(RuntimeError, '^no live store host'):
            a.admit(self.row(), self.instances)
        os.utime(self.instances / 'store-host.json')
        row = a.admit(self.row(), self.instances)
        self.assertNotIn('target_instance', row)
        self.assertEqual(row['required_runtime_capabilities'], [a.POSITION_CAPABILITY])

    def test_invalid_capability_metadata_is_not_support(self):
        for value in ('position-preparation-v1', {'position-preparation-v1': True}, None, [3]):
            self.host(runtime_capabilities=value)
            with self.assertRaises(RuntimeError):
                a.admit(self.row(), self.instances)
            with self.assertRaises(RuntimeError):
                m.require_capabilities({'runtime_capabilities': value})

    def test_floor_requires_valid_known_vintage(self):
        for value in (None, '', 'nonsense', '2026-09-01T00:00:00Z'):
            self.host(build_time=value)
            with self.assertRaisesRegex(RuntimeError, 'known build vintage'):
                a.admit(dict(host_key='key', min_vintage='2026-09-05T00:00:00Z'), self.instances)
        self.host()
        admitted = a.admit(dict(host_key='key', min_vintage='2026-09-05T00:00:00Z'), self.instances)
        self.assertNotIn('target_instance', admitted)
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

class StoreScopeAdmission(unittest.TestCase):
    """A store host serves every checkout of its store, checked as the host checks
    it at claim time: by resolving the checkout with LORE_KNOWLEDGE_DIR removed."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        env = {k: v for k, v in os.environ.items() if k not in {'LORE_KNOWLEDGE_DIR', 'LORE_SESSION_RUNTIME'}}
        env['LORE_DATA_DIR'] = str(self.root / 'data')
        (self.root / 'data/config').mkdir(parents=True)
        (self.root / 'data/config/settings.json').write_text((ROOT / 'adapters/settings.template.json').read_text())
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
            with self.subTest(required=required), self.assertRaisesRegex(RuntimeError, '^declared checkout is not in this store'):
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

    def test_placement_counts_only_the_store_host(self):
        (self.instances / 'tui.json').write_text(json.dumps(dict(name='tui', project_dir=self.foreign)))
        keyed = a.placement(self.instances, self.key, self.ours)
        self.assertEqual((keyed['served'], keyed['served_by']), (True, ['store-host']))
        self.assertEqual(a.placement(self.instances, self.key, self.foreign)['served_by'], [])
        for directory in (self.ours, self.foreign):
            unkeyed = a.placement(self.instances, '', directory)
            self.assertEqual((unkeyed['served'], unkeyed['servers']), (False, []))
        with self.assertRaisesRegex(RuntimeError, 'no live store host'):
            a.admit(self.row(self.ours, host_key=''), self.instances)

    def test_writer_floor_refuses_before_publication(self):
        host = json.loads((self.instances / 'store-host.json').read_text())
        (self.instances / 'store-host.json').write_text(json.dumps(dict(host, build_time='')))
        result = subprocess.run(['bash', str(ROOT / 'scripts/session-request.sh'), '--type', 'chat', '--prefer-dir', self.ours,
                                 '--min-vintage', '2026-09-05T00:00:00Z', '--kdir', str(self.kdir), '--json'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        error = json.loads(result.stdout)['error']
        self.assertTrue(error.startswith('store host is too old: run lore rebuild, then retry\n'), error)
        self.assertIn('known build vintage >= 2026-09-05T00:00:00Z', error)
        self.assertEqual(list((self.kdir / '_sessions/requests/pending').glob('*.json')), [])


if __name__ == '__main__':
    unittest.main()
