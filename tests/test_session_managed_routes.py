import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('managed_routes', ROOT / 'scripts/session-managed.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ManagedRoutes(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / 'data'
        self.source = self.root / 'source'
        self.kdir = self.root / 'knowledge'
        self.source.mkdir()
        (self.data / 'config').mkdir(parents=True)
        shutil.copy(ROOT / 'adapters/settings.template.json', self.data / 'config/settings.json')
        m.atomic(self.kdir / '_work/task/_meta.json', {'source_checkout': str(self.source)})
        self.context = self.root / 'context.md'
        self.context.write_text('work')
        self.env = patch.dict(os.environ, {'LORE_DATA_DIR': str(self.data)}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)

    def args(self, **changes):
        values = dict(workspace=str(self.source), handle='task', framework=None, model=None,
                      session_route=None, context=str(self.context), key='same', packet=None, timeout=0)
        values.update(changes)
        return type('Args', (), values)()

    def test_resolves_complete_route_in_requested_source_cwd(self):
        (self.source / '.lore.config').write_text('model_for_worker=codex/gpt-5.6-sol-high\n')
        route = m.canonical_start_route(self.args(), str(self.source))
        self.assertEqual(route['framework'], 'codex')
        self.assertEqual(route['model'], 'gpt-5.6-sol')
        self.assertEqual(route['options'], {'effort': 'high'})
        self.assertEqual(route['routing_source'], {'layer': 'per-repo', 'role': 'worker'})

    def test_explicit_route_still_validates_the_complete_settings_tree(self):
        settings = json.loads((self.data / 'config/settings.json').read_text())
        settings['routes']['spectator'] = 'claude-code/opus'
        (self.data / 'config/settings.json').write_text(json.dumps(settings))
        with self.assertRaisesRegex(RuntimeError, r'invalid route configuration \(unknown_role\).*routes.spectator'):
            m.canonical_start_route(self.args(session_route='codex/gpt-5.6-sol-high'), str(self.source))

    def test_canonical_session_route_preserves_options_and_provenance(self):
        frozen = {'framework': 'codex', 'model': 'gpt-5.6-sol',
                  'options': {'effort': 'high', 'service_tier': 'fast'},
                  'routing_source': {'layer': 'routes', 'role': 'worker'}}
        self.assertEqual(m.canonical_start_route(self.args(session_route=json.dumps(frozen)), str(self.source)), frozen)

    def test_retry_forwards_frozen_route_after_settings_change(self):
        frozen = {'framework': 'codex', 'model': 'gpt-5.6-sol',
                  'options': {'effort': 'high', 'service_tier': 'fast'},
                  'routing_source': {'layer': 'routes', 'role': 'worker'}}
        manifest = dict(handle='task--w1', host_key='host', source_dir=str(self.source.resolve()),
                        work_item='task', request_id='request-1', context='work', state='intent',
                        route=frozen, framework='codex', model='gpt-5.6-sol', routing_source='routes')
        changed = json.loads((self.data / 'config/settings.json').read_text())
        changed['routes']['worker'] = 'claude-code/opus'
        (self.data / 'config/settings.json').write_text(json.dumps(changed))
        calls = []
        def invoke(argv, **kwargs):
            calls.append([str(x) for x in argv])
            return '{}'
        with patch.object(m, 'ensure', return_value={'instance_name': 'instance'}), \
             patch.object(m, 'ready', return_value={'instance_name': 'instance'}), \
             patch.object(m, 'run', side_effect=invoke):
            m.enqueue_start(self.kdir, manifest)
        request = next(call for call in calls if call[1].endswith('session-request.sh'))
        route_arg = request[request.index('--session-route') + 1]
        self.assertEqual(json.loads(route_arg), frozen)
        self.assertNotIn('--framework', request)

    def test_shorthand_override_gets_explicit_provenance(self):
        route = m.canonical_start_route(self.args(session_route='codex/gpt-5.6-sol-high'), str(self.source))
        self.assertEqual(route['routing_source'], {'layer': 'override', 'role': 'worker'})
        self.assertEqual(route['options'], {'effort': 'high'})

    def test_legacy_pair_preserves_effort_suffix_and_empty_half_refuses(self):
        route = m.canonical_start_route(self.args(framework='codex', model='gpt-5.5-high'), str(self.source))
        self.assertEqual(route['model'], 'gpt-5.5')
        self.assertEqual(route['options'], {'effort': 'high'})
        with self.assertRaisesRegex(RuntimeError, 'pair'):
            m.canonical_start_route(self.args(framework=None, model=''), str(self.source))

    def test_absent_override_retry_reuses_frozen_intent_after_valid_settings_change(self):
        def enqueue(kdir, manifest):
            manifest['state'] = 'enqueued'
            m.atomic(m.manifest_path(kdir, manifest['handle']), manifest)
        patches = (patch.object(m, 'resolve', return_value=self.kdir), patch.object(m, 'ensure'),
                   patch.object(m, 'enqueue_start', side_effect=enqueue))
        with patches[0], patches[1], patches[2]:
            first = m.start(self.args(), self.kdir)
            settings = json.loads((self.data / 'config/settings.json').read_text())
            settings['routes']['worker'] = 'codex/gpt-5.6-sol-high'
            (self.data / 'config/settings.json').write_text(json.dumps(settings))
            second = m.start(self.args(), self.kdir)
        self.assertEqual(first['handle'], second['handle'])
        manifest = m.read(m.manifest_path(self.kdir, first['handle']))
        self.assertEqual(manifest['route']['framework'], 'claude-code')


if __name__ == '__main__':
    unittest.main()
