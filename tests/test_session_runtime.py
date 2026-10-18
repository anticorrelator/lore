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

    def test_attach_uses_the_runtime_server(self):
        manifest = {'handle': 'task--w1', 'host_key': 'k', 'source_dir': str(self.root)}
        args = SimpleNamespace(verb='attach', timeout=0)

        class Attached(Exception):
            pass
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'dev'}), \
                patch.object(m, 'inspect', return_value={'state': 'running'}), patch.object(m, 'ensure'), \
                patch.object(m, 'owner', return_value={'tmux': 'lore-i-task', 'instance_name': 'i'}), \
                patch.object(m.os, 'execvp', side_effect=Attached) as execvp:
            with self.assertRaises(Attached):
                m.operate_attempt(args, self.kdir, manifest)
        execvp.assert_called_once_with('tmux', ['tmux', '-L', 'lore-tui-dev', 'attach-session', '-t', 'lore-i-task'])

    def test_invalid_setting_is_refused_before_any_verb_runs(self):
        with patch.dict(os.environ, {'LORE_SESSION_RUNTIME': 'Not_Valid'}), patch.object(m, 'resolve') as resolve:
            with self.assertRaisesRegex(ValueError, 'LORE_SESSION_RUNTIME'):
                m.main(['inspect', 'task--w1', '--kdir', str(self.kdir)])
        resolve.assert_not_called()

    def supervise(self, environ, returncode):
        argv = []

        class Process:
            def __init__(self, args, **kwargs):
                argv.append(args)
                self.returncode = returncode

            def poll(self):
                return self.returncode
        out = io.StringIO()
        with patch.dict(os.environ, environ, clear=True), patch.object(m.subprocess, 'Popen', Process), \
                patch.object(m, 'ready', return_value=None), patch.object(m.time, 'sleep'), \
                contextlib.redirect_stdout(out):
            code = m.supervise(SimpleNamespace(kdir=str(self.kdir), host_key='k', workspace=str(self.root), binary='/host'))
        return code, argv, out.getvalue()

    def test_supervisor_names_the_runtime_to_the_host(self):
        code, argv, _ = self.supervise(without_runtime(), 0)
        self.assertEqual(code, 0)
        self.assertNotIn('--runtime', argv[0])
        self.assertTrue((self.kdir.resolve() / '_sessions/hosts/k/supervisor.json').exists())
        code, argv, _ = self.supervise(dict(without_runtime(), LORE_SESSION_RUNTIME='dev'), 0)
        self.assertEqual(code, 0)
        self.assertEqual(argv[0][-2:], ['--runtime', 'dev'])
        self.assertEqual(argv[0][argv[0].index('--ready-file') + 1],
                         str(self.kdir.resolve() / '_sessions/runtimes/dev/hosts/k/ready.json'))

    def test_supervisor_explains_a_host_that_refuses_the_runtime(self):
        code, argv, out = self.supervise(dict(without_runtime(), LORE_SESSION_RUNTIME='dev'), 2)
        self.assertEqual(code, 1)
        self.assertEqual(len(argv), 6)
        self.assertIn('rejects --runtime', out)
        self.assertIn('bash install.sh', out)


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
