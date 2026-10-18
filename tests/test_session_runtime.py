import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = load('session_runtime_under_test', 'session_runtime.py')
m = load('managed_runtime', 'session-managed.py')
watch = load('watch_runtime', 'coordinate_watch_state.py')


def without_runtime():
    env = dict(os.environ)
    env.pop('LORE_SESSION_RUNTIME', None)
    return env


class RuntimeNames(unittest.TestCase):
    def test_tmux_server_and_hosts_dir_follow_the_setting(self):
        kdir = Path('/store')
        for value, server, hosts in (
                (None, 'lore-tui', kdir / '_sessions/hosts'),
                ('', 'lore-tui', kdir / '_sessions/hosts'),
                ('dev', 'lore-tui-dev', kdir / '_sessions/runtimes/dev/hosts'),
                ('a' * 32, 'lore-tui-' + 'a' * 32, kdir / '_sessions/runtimes' / ('a' * 32) / 'hosts')):
            env = {} if value is None else {'LORE_SESSION_RUNTIME': value}
            self.assertEqual(runtime.tmux_server(env), server)
            self.assertEqual(runtime.hosts_dir(kdir, env), hosts)

    def test_invalid_names_never_fall_back_to_production(self):
        for value in ('Dev', 'dev_1', '../x', 'a/b', 'dev\n', 'a' * 33, 'é'):
            env = {'LORE_SESSION_RUNTIME': value}
            with self.assertRaises(ValueError):
                runtime.tmux_server(env)
            with self.assertRaises(ValueError):
                runtime.hosts_dir('/store', env)

    def test_bash_label_and_owner_liveness_follow_the_setting(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'tmux.log'
            fake = Path(tmp) / 'tmux'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TMUX_ARGS_LOG"\nexit 1\n')
            fake.chmod(0o755)
            script = 'source "$1"; lore_tmux_server; session_owner_alive "" seat || true'
            for value, server in (('', 'lore-tui'), ('dev', 'lore-tui-dev')):
                log.write_text('')
                env = dict(without_runtime(), LORE_SESSION_RUNTIME=value, TMUX_ARGS_LOG=str(log),
                           PATH=tmp + os.pathsep + os.environ['PATH'])
                result = subprocess.run(['bash', '-c', script, '_', str(ROOT / 'scripts/lib.sh')],
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], server)
                self.assertEqual(log.read_text(), f'-L {server} has-session -t seat\n')
            env = dict(without_runtime(), LORE_SESSION_RUNTIME='Not_Valid')
            result = subprocess.run(['bash', '-c', 'source "$1"; lore_tmux_server', '_', str(ROOT / 'scripts/lib.sh')],
                                    env=env, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('LORE_SESSION_RUNTIME', result.stderr)
            self.assertNotIn('lore-tui', result.stdout)

    def test_watcher_ownership_reads_the_runtime_server_only_when_identity_names_none(self):
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            return SimpleNamespace(returncode=1, stdout='')
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'dev'}), patch.object(watch.subprocess, 'run', side_effect=fake_run):
            self.assertFalse(watch.belongs({'owner_kind': 'tmux', 'owner_value': 'seat'}))
            self.assertFalse(watch.belongs({'owner_kind': 'tmux', 'owner_value': 'seat', 'tmux_server': 'recorded'}))
        self.assertEqual(calls[0][:3], ['tmux', '-L', 'lore-tui-dev'])
        self.assertEqual(calls[1][:3], ['tmux', '-L', 'recorded'])


class ManagedHostRuntime(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.kdir = self.root / 'store'
        self.kdir.mkdir()

    def test_host_dir_follows_the_setting(self):
        with patch.dict(os.environ, without_runtime(), clear=True):
            self.assertEqual(m.host_dir(self.kdir, 'k'), self.kdir / '_sessions/hosts/k')
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'dev'}):
            self.assertEqual(m.host_dir(self.kdir, 'k'), self.kdir / '_sessions/runtimes/dev/hosts/k')

    def test_attach_uses_the_runtime_server_and_the_supervisor_tmux_tmpdir(self):
        manifest = {'handle': 'task--w1', 'host_key': 'k', 'source_dir': str(self.root)}
        args = SimpleNamespace(verb='attach', timeout=0)
        data = self.root / 'data'
        m.atomic(data / 'session-runtimes/dev/supervisor.json', {'pid': 1, 'tmux_tmpdir': str(self.root / 'tmux')})

        class Attached(Exception):
            pass
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'dev', 'LORE_DATA_DIR': str(data),
                                     'TMUX_TMPDIR': str(self.root / 'elsewhere')}), \
                patch.object(m, 'inspect', return_value={'state': 'running'}), patch.object(m, 'ensure'), \
                patch.object(m, 'owner', return_value={'tmux': 'lore-i-task', 'instance_name': 'i'}), \
                patch.object(m.os, 'execvpe', side_effect=Attached) as execvpe:
            with self.assertRaises(Attached):
                m.operate_attempt(args, self.kdir, manifest)
        program, argv, env = execvpe.call_args.args
        self.assertEqual((program, argv), ('tmux', ['tmux', '-L', 'lore-tui-dev', 'attach-session', '-t', 'lore-i-task']))
        self.assertEqual(env['TMUX_TMPDIR'], str(self.root / 'tmux'))

    def test_invalid_setting_is_refused_before_any_verb_runs(self):
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'Not_Valid'}), patch.object(m, 'resolve') as resolve:
            with self.assertRaisesRegex(ValueError, 'LORE_SESSION_RUNTIME'):
                m.main(['inspect', 'task--w1', '--kdir', str(self.kdir)])
        resolve.assert_not_called()

    def supervise_once(self, environ, returncode):
        """One supervisor pass over a served store, with a host process that exits at once."""
        launches = []

        class Process:
            def __init__(self, args, **kwargs):
                launches.append((args, kwargs))
                self.pid = 4242
                self.returncode = returncode

            def poll(self):
                return self.returncode
        data = self.root / 'data'
        kdir = self.kdir.resolve()
        with patch.dict(os.environ, dict(environ, LORE_DATA_DIR=str(data), LORE_SESSION_HOST_BINARY='/bin/sh'),
                        clear=True), patch.object(m.subprocess, 'Popen', Process), \
                contextlib.redirect_stdout(io.StringIO()):
            login = runtime.login_dir()
            m.atomic(login / 'served.json', {'schema_version': 1, 'stores': {str(kdir): {'wanted_at': m.now()}}})
            with (login / 'supervisor.lock').open('a+') as stream:
                supervisor = m.Supervisor(stream)
                supervisor.tick()
                supervisor.tick()
            directory = m.host_dir(kdir, runtime.store_host_key(kdir))
        return launches, directory, login

    def test_supervisor_names_the_store_scope_and_runtime_to_the_host(self):
        kdir = self.kdir.resolve()
        launches, directory, login = self.supervise_once(without_runtime(), None)
        argv, options = launches[0]
        self.assertEqual(argv[1:6], ['--session-host', '--scope', 'store', '--host-key', runtime.store_host_key(kdir, {})])
        self.assertNotIn('--runtime', argv)
        self.assertNotIn('--source-dir', argv)
        self.assertEqual(argv[argv.index('--kdir') + 1], str(kdir))
        self.assertEqual(argv[argv.index('--ready-file') + 1], str(kdir / '_sessions/hosts' / runtime.store_host_key(kdir, {}) / 'ready.json'))
        self.assertEqual(options['cwd'], str(kdir))
        self.assertTrue((login / 'supervisor.json').exists())
        self.assertEqual(login, self.root / 'data/session-runtime')
        launches, directory, login = self.supervise_once(dict(without_runtime(), LORE_SESSION_RUNTIME='dev'), None)
        argv, _ = launches[0]
        key = runtime.store_host_key(kdir, {'LORE_SESSION_RUNTIME': 'dev'})
        self.assertEqual(argv[-2:], ['--runtime', 'dev'])
        self.assertEqual(argv[argv.index('--host-key') + 1], key)
        self.assertEqual(argv[argv.index('--ready-file') + 1], str(kdir / '_sessions/runtimes/dev/hosts' / key / 'ready.json'))
        self.assertEqual(login, self.root / 'data/session-runtimes/dev')

    def test_supervisor_explains_a_host_that_refuses_its_arguments(self):
        launches, directory, _ = self.supervise_once(dict(without_runtime(), LORE_SESSION_RUNTIME='dev'), 2)
        self.assertEqual(len(launches), 1)
        error = m.read(directory / 'supervisor-error.json')
        self.assertEqual(error['exit_code'], 2)
        self.assertIn('--runtime', error['error'])
        self.assertIn('bash install.sh', error['error'])
        self.assertIn('lore rebuild', error['error'])


class StoreKeysAndLoginState(unittest.TestCase):
    def test_store_host_key_carries_the_runtime_name(self):
        default = runtime.store_host_key('/store', {})
        self.assertEqual(default, __import__('hashlib').sha256(b'/store').hexdigest()[:24])
        dev = runtime.store_host_key('/store', {'LORE_SESSION_RUNTIME': 'dev'})
        self.assertEqual(dev, __import__('hashlib').sha256(b'/store\0runtime\0dev').hexdigest()[:24])
        self.assertNotEqual(default, dev)
        self.assertNotEqual(default, runtime.store_host_key('/other', {}))
        self.assertEqual(len(default), 24)
        with self.assertRaises(ValueError):
            runtime.store_host_key('/store', {'LORE_SESSION_RUNTIME': 'Bad'})

    def test_login_dir_is_outside_every_store(self):
        self.assertEqual(runtime.login_dir({'LORE_DATA_DIR': '/data'}), Path('/data/session-runtime'))
        self.assertEqual(runtime.login_dir({'LORE_DATA_DIR': '/data', 'LORE_SESSION_RUNTIME': 'dev'}),
                         Path('/data/session-runtimes/dev'))
        self.assertEqual(runtime.login_dir({'HOME': '/home/u'}), Path('/home/u/.lore/session-runtime'))
        self.assertEqual(runtime.login_dir({'HOME': '/home/u', 'LORE_DATA_DIR': ''}), Path('/home/u/.lore/session-runtime'))

    def test_child_environment_scrubs_harness_and_session_identity(self):
        base = {'PATH': '/bin', 'HOME': '/home/u', 'SSH_AUTH_SOCK': '/s', 'GH_TOKEN': 't', 'HTTPS_PROXY': 'p',
                'ANTHROPIC_API_KEY': 'k', 'CLAUDECODE': '1', 'CLAUDE_CODE_CHILD_SESSION': '1',
                'CLAUDE_CODE_ENTRYPOINT': 'cli', 'CLAUDE_CODE_MESSAGING_SOCKET': '/sock', 'CLAUDE_PID': '1',
                'CLAUDE_AGENT_SDK_VERSION': '1', 'AI_AGENT': 'x', 'CODEX_THREAD_ID': 't', 'CODEX_SANDBOX': 'seatbelt',
                'OPENCODE_SESSION_ID': 's', 'CLAUDE_CODE_USE_BEDROCK': '1', 'CLAUDE_CODE_OAUTH_TOKEN': 'o',
                'CODEX_HOME': '/c', 'OPENCODE_CONFIG_DIR': '/o', 'LORE_POSITION_DISPATCH_MANIFEST': 'm',
                'LORE_SESSION_SLUG': 's', 'LORE_SESSION_HOST_BINARY': '/b', 'LORE_SESSION_HOST_IDLE_TIMEOUT': '5',
                'LORE_SESSION_RUNTIME': 'dev', 'LORE_FRAMEWORK': 'codex', 'LORE_MODEL_WORKER': 'x',
                'LORE_WORKTREE_ID': 'w', 'LORE_EXECUTION_DIR': '/e', 'LORE_KNOWLEDGE_DIR': '/first-caller-store',
                'LORE_DATA_DIR': '/data', 'TMUX': 't', 'TMUX_PANE': '%1', 'TMUX_TMPDIR': '/tmux', 'PWD': '/p',
                'OLDPWD': '/o', 'SHLVL': '2', 'BAGGAGE': 'b', 'TRACEPARENT': '00-a-b-01', 'TRACESTATE': 's',
                'USE_STAGING_OAUTH': '1', 'USE_LOCAL_OAUTH': '1', 'ANTHROPIC_BASE_URL': 'https://gateway'}
        env = runtime.child_environment(base, '/store-b', False)
        self.assertEqual(sorted(env), sorted([
            'PATH', 'HOME', 'SSH_AUTH_SOCK', 'GH_TOKEN', 'HTTPS_PROXY', 'ANTHROPIC_API_KEY', 'CLAUDE_CODE_USE_BEDROCK',
            'CLAUDE_CODE_OAUTH_TOKEN', 'CODEX_HOME', 'OPENCODE_CONFIG_DIR', 'LORE_SESSION_HOST_BINARY',
            'LORE_SESSION_HOST_IDLE_TIMEOUT', 'LORE_SESSION_RUNTIME', 'LORE_DATA_DIR', 'TMUX_TMPDIR',
            'ANTHROPIC_BASE_URL']))
        pinned = runtime.child_environment(base, '/store-a', True)
        self.assertEqual(pinned['LORE_KNOWLEDGE_DIR'], '/store-a')
        self.assertEqual(base['LORE_KNOWLEDGE_DIR'], '/first-caller-store')


class HostBinaryResolution(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.kdir = self.root / 'store'
        self.home = self.root / 'home'
        self.kdir.mkdir()
        self.home.mkdir()
        env = without_runtime()
        env.pop('LORE_SESSION_HOST_BINARY', None)
        env['HOME'] = str(self.home)
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.builds = []
        real_run = m.run

        def run(argv, **kwargs):
            if argv[0] == 'go':
                self.builds.append(list(argv))
                Path(argv[argv.index('-o') + 1]).write_text('built')
                return ''
            return real_run(argv, **kwargs)
        run_patch = patch.object(m, 'run', side_effect=run)
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/sh\n')
        path.chmod(0o755)
        return path

    def resolve(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            path = m.binary(self.kdir)
        return path, err.getvalue()

    def test_override_wins_over_installed(self):
        self.executable(self.home / '.local/bin/lore-tui')
        override = self.executable(self.root / 'override')
        os.environ['LORE_SESSION_HOST_BINARY'] = str(override)
        path, notice = self.resolve()
        self.assertEqual(path, override.resolve())
        self.assertEqual((notice, self.builds), ('', []))

    def test_installed_binary_hosts_without_building(self):
        installed = self.executable(self.home / '.local/bin/lore-tui')
        path, notice = self.resolve()
        self.assertEqual(path, installed)
        self.assertEqual((notice, self.builds), ('', []))

    def test_checkout_fallback_announces_itself_and_stamps_install_identity(self):
        path, notice = self.resolve()
        self.assertEqual(len(notice.strip().splitlines()), 1)
        self.assertIn('checkout build', notice)
        self.assertIn('bash install.sh', notice)
        self.assertEqual(path.parent, self.kdir / '_sessions/bin')
        self.assertTrue(path.exists())
        sha = subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'],
                             text=True, capture_output=True, check=True).stdout.strip()
        when = subprocess.run(['git', '-C', str(ROOT), 'show', '-s', '--date=format-local:%Y-%m-%dT%H:%M:%SZ',
                               '--format=%cd', 'HEAD'], text=True, capture_output=True, check=True,
                              env=dict(os.environ, TZ='UTC')).stdout.strip()
        self.assertTrue(sha and when)
        build = self.builds[0]
        self.assertEqual(build[build.index('-ldflags') + 1], f'-X main.buildSHA={sha} -X main.buildTime={when}')
        again, _ = self.resolve()
        self.assertEqual((again, len(self.builds)), (path, 1))

    def test_checkout_build_is_rebuilt_when_the_stamped_identity_moves(self):
        with patch.object(m, 'checkout_identity', return_value=('aaaaaaa', '2026-01-01T00:00:00Z')):
            first, _ = self.resolve()
        with patch.object(m, 'checkout_identity', return_value=('bbbbbbb', '2026-01-02T00:00:00Z')):
            second, _ = self.resolve()
        self.assertNotEqual(first, second)
        self.assertEqual([b[b.index('-ldflags') + 1] for b in self.builds],
                         ['-X main.buildSHA=aaaaaaa -X main.buildTime=2026-01-01T00:00:00Z',
                          '-X main.buildSHA=bbbbbbb -X main.buildTime=2026-01-02T00:00:00Z'])

    def test_non_executable_installed_file_is_not_hosted(self):
        installed = self.home / '.local/bin/lore-tui'
        installed.parent.mkdir(parents=True)
        installed.write_text('not a program')
        path, notice = self.resolve()
        self.assertNotEqual(path, installed)
        self.assertIn('checkout build', notice)


if __name__ == '__main__':
    unittest.main()
