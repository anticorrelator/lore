"""The per-login session supervisor and store ensure(), run against a stub store host.

The stub implements the store host's side of the contract: `--session-host --scope
store` arguments (anything else exits 2), runtime.lock (held elsewhere: exit 3),
the store-scoped ready file and registry row, an idle withdraw that removes the
ready file under ensure.lock (exit 0), and restart.json honoured only when it
names this process (exit 75). Each launch records its argv, cwd and environment
names next to the ready file.
"""
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/fixtures/session_harness_env_names.json'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


m = load('managed_login', ROOT / 'scripts/session-managed.py')
runtime = m.RUNTIME
SANDBOXED = runtime.sandbox_reason()
SANDBOX_EXEC = shutil.which('sandbox-exec') if sys.platform == 'darwin' else None
PERMISSIVE = '(version 1)(allow default)'

STUB = r'''
import fcntl, json, os, sys, time
from pathlib import Path

args = sys.argv[1:]


def opt(name, default=None):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name('.%s.%d' % (path.name, os.getpid()))
    temp.write_text(json.dumps(value))
    os.replace(temp, path)


def read(path):
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


WATCH = ('LORE_KNOWLEDGE_DIR', 'TMUX_TMPDIR', 'LORE_SESSION_RUNTIME', 'LORE_SESSION_HOST_IDLE_TIMEOUT',
         'CLAUDE_CODE_USE_BEDROCK', 'SSH_AUTH_SOCK')
kdir, key, ready_file = opt('--kdir'), opt('--host-key'), opt('--ready-file')
kdir = str(Path(kdir).resolve()) if kdir else kdir
directory = Path(ready_file).parent if ready_file else None
if directory:
    atomic(directory / ('launch-%d.json' % os.getpid()), dict(
        pid=os.getpid(), argv=args, cwd=os.getcwd(), at=time.time(), env_names=sorted(os.environ),
        env={name: os.environ.get(name) for name in WATCH}))
VALUED = {'--scope', '--host-key', '--kdir', '--ready-file', '--idle-timeout', '--runtime'}
rest = args[1:] if args[:1] == ['--session-host'] else None
while rest:
    if rest[0] not in VALUED or len(rest) < 2:
        sys.exit(2)
    rest = rest[2:]
if rest is None or opt('--scope') != 'store' or not kdir or not key or not ready_file:
    sys.exit(2)
if opt('--runtime', '') != os.environ.get('LORE_SESSION_RUNTIME', ''):
    sys.exit(2)
if os.environ.get('LORE_KNOWLEDGE_DIR') and str(Path(os.environ['LORE_KNOWLEDGE_DIR']).resolve()) != kdir:
    sys.exit(1)
control = read(Path(kdir) / 'stub-control.json')
if 'exit' in control:
    sys.exit(control['exit'])
lock = open(directory / 'runtime.lock', 'a+')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(3)
pid = os.getpid()
name = 'stub-%d' % pid
started = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
capabilities = control.get('capabilities', ['position-preparation-v1'])
atomic(Path(kdir) / '_sessions/instances' / (name + '.json'), dict(
    name=name, pid=pid, role='session-host', host_key=key, scope='store',
    runtime=os.environ.get('LORE_SESSION_RUNTIME', ''), repo='stub', started=started,
    sessions=control.get('sessions', []), runtime_capabilities=capabilities))
atomic(ready_file, dict(schema_version=2, scope='store', host_key=key, instance_name=name, pid=pid,
                        knowledge_dir=kdir, ready=True, runtime_capabilities=capabilities,
                        build_sha='stub', build_time='2026-10-18T00:00:00Z'))


def work():
    sessions = Path(kdir) / '_sessions'
    for state in ('pending', 'claimed'):
        for path in (sessions / 'requests' / state).glob('*.json'):
            if read(path).get('host_key') == key:
                return True
    for path in (sessions / 'managed').glob('*.json'):
        manifest = read(path)
        if manifest.get('host_key') == key and manifest.get('state') in ('intent', 'enqueueing'):
            return True
    return False


def leave(code):
    with open(directory / 'ensure.lock', 'a+') as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        if code == 0 and work():
            return
        try:
            os.unlink(ready_file)
        except FileNotFoundError:
            pass
    sys.exit(code)


busy = time.monotonic()
while True:
    time.sleep(.05)
    restart = read(directory / 'restart.json')
    if restart.get('target_pid') == pid and restart.get('target_started') == started:
        leave(75)
    control = read(Path(kdir) / 'stub-control.json')
    if control.get('crash'):
        os._exit(control['crash'])
    idle = float(control.get('idle', opt('--idle-timeout', '30')))
    if work():
        busy = time.monotonic()
    elif idle > 0 and time.monotonic() - busy >= idle:
        leave(0)
        busy = time.monotonic()
'''


def write_stub(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f'#!{sys.executable}\n' + STUB)
    path.chmod(0o755)
    return path


def dead_pid():
    process = subprocess.Popen(['true'])
    process.wait()
    return process.pid


class LoginCase(unittest.TestCase):
    runtime_name = 'login-test'

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.stub = write_stub(self.root / 'bin/lore-tui-stub')
        self.processes = []
        drop = {'LORE_KNOWLEDGE_DIR', 'LORE_SESSION_RUNTIME', 'TMUX_TMPDIR', 'LORE_SESSION_HOST_BINARY',
                'LORE_SESSION_HOST_IDLE_TIMEOUT', 'LORE_SESSION_SUPERVISOR_QUIET_SECONDS', 'CODEX_SANDBOX',
                'CODEX_SANDBOX_NETWORK_DISABLED'}
        env = {k: v for k, v in os.environ.items() if k not in drop}
        env.update(HOME=str(self.home), LORE_DATA_DIR=str(self.root / 'data'), LORE_SESSION_HOST_BINARY=str(self.stub),
                   LORE_SESSION_HOST_IDLE_TIMEOUT='30', LORE_SESSION_SUPERVISOR_QUIET_SECONDS='30')
        if self.runtime_name:
            env['LORE_SESSION_RUNTIME'] = self.runtime_name
        environment = patch.dict(os.environ, env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.addCleanup(self.reap)
        m.WARNED_TMUX_TMPDIR = False
        self.login = runtime.login_dir()

    def reap(self):
        pids = set()
        for path in self.root.rglob('launch-*.json'):
            pids.add(m.read_quiet(path, {}).get('pid'))
        for log in self.root.rglob('supervisor.log'):
            pids.update(int(p) for p in re.findall(r'supervisor (\d+) started', log.read_text(errors='replace')))
        pids.update(process.pid for process in self.processes)
        for pid in pids:
            if not isinstance(pid, int) or pid <= 0:
                continue
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], text=True, capture_output=True).stdout
            if 'session-managed.py' in command or str(self.root) in command:
                with contextlib.suppress(OSError):
                    os.kill(pid, signal.SIGKILL)
        for process in self.processes:
            with contextlib.suppress(Exception):
                process.wait(timeout=5)

    def store(self, name, control=None):
        kdir = self.root / name
        (kdir / '_sessions').mkdir(parents=True)
        if control is not None:
            self.control(kdir, control)
        return kdir

    def control(self, kdir, value):
        m.atomic(kdir / 'stub-control.json', value)

    def directory(self, kdir):
        return m.host_dir(kdir, runtime.store_host_key(kdir))

    def launches(self, kdir):
        return sorted((m.read_quiet(p, {}) for p in self.directory(kdir).glob('launch-*.json')),
                      key=lambda r: r.get('at', 0))

    def until(self, predicate, timeout=20, step=.05, what='condition'):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(step)
        self.fail(f'timed out waiting for {what}')

    def supervisor_log(self):
        path = self.login / 'supervisor.log'
        return path.read_text(errors='replace') if path.exists() else ''

    def supervisor_pid(self):
        return m.read_quiet(self.login / 'supervisor.json', {}).get('pid')

    def ready_pid(self, kdir):
        status = m.ready(kdir, runtime.store_host_key(kdir))
        return status and status['pid']

    def ensure(self, kdir, timeout=20):
        with contextlib.redirect_stderr(io.StringIO()):
            return m.ensure(kdir, timeout=timeout)


@unittest.skipIf(SANDBOXED, f'a supervisor is never started inside a sandbox ({SANDBOXED})')
class OneSupervisorManyStores(LoginCase):
    def test_two_stores_share_one_supervisor_and_get_their_own_environment(self):
        a, b = self.store('a'), self.store('b')
        caller = dict(CLAUDECODE='1', CLAUDE_CODE_CHILD_SESSION='1', CLAUDE_CODE_ENTRYPOINT='cli',
                      CLAUDE_CODE_MESSAGING_SOCKET='/sock', CLAUDE_PID='1', CODEX_THREAD_ID='t',
                      OPENCODE_SESSION_ID='o', AI_AGENT='claude', LORE_POSITION_DISPATCH_MANIFEST='m',
                      LORE_SESSION_SLUG='item--w1', LORE_FRAMEWORK='codex', CLAUDE_CODE_USE_BEDROCK='1',
                      SSH_AUTH_SOCK='/agent', LORE_KNOWLEDGE_DIR=str(a), TMUX='x', TMUX_PANE='%1',
                      BAGGAGE='b', TRACEPARENT='00-a-b-01', USE_STAGING_OAUTH='1')
        with patch.dict(os.environ, caller):
            status_a = self.ensure(a)
        status_b = self.ensure(b)
        for kdir, status in ((a, status_a), (b, status_b)):
            self.assertEqual(status['scope'], 'store')
            self.assertEqual(status['host_key'], runtime.store_host_key(kdir))
            self.assertNotIn('source_dir', status)
        self.assertNotEqual(status_a['host_key'], status_b['host_key'])
        self.assertTrue(m.held(self.login / 'supervisor.lock'))
        self.assertEqual(len(re.findall(r'supervisor \d+ started', self.supervisor_log())), 1)
        served = m.read(self.login / 'served.json')
        self.assertEqual(served['schema_version'], 1)
        self.assertEqual(served['stores'][str(a)]['pin_knowledge_dir'], True)
        self.assertEqual(served['stores'][str(b)]['pin_knowledge_dir'], False)
        for kdir in (a, b):
            [launch] = self.launches(kdir)
            argv = launch['argv']
            self.assertEqual(argv[:4], ['--session-host', '--scope', 'store', '--host-key'])
            self.assertEqual(argv[argv.index('--runtime') + 1], 'login-test')
            self.assertEqual(launch['cwd'], str(kdir))
            names = set(launch['env_names'])
            for scrubbed in caller:
                if scrubbed not in {'CLAUDE_CODE_USE_BEDROCK', 'SSH_AUTH_SOCK', 'LORE_KNOWLEDGE_DIR'}:
                    self.assertNotIn(scrubbed, names, kdir)
            self.assertEqual(launch['env']['CLAUDE_CODE_USE_BEDROCK'], '1')
            self.assertEqual(launch['env']['SSH_AUTH_SOCK'], '/agent')
            self.assertEqual(launch['env']['LORE_SESSION_RUNTIME'], 'login-test')
            self.assertTrue((self.directory(kdir) / 'host.log').exists())
        self.assertEqual(self.launches(a)[0]['env']['LORE_KNOWLEDGE_DIR'], str(a))
        self.assertIsNone(self.launches(b)[0]['env']['LORE_KNOWLEDGE_DIR'])

    def test_tmux_tmpdir_is_recorded_warned_about_and_used_by_attach(self):
        a = self.store('a')
        with patch.dict(os.environ, {'TMUX_TMPDIR': str(self.root / 'tmux-a')}):
            self.ensure(a)
        self.assertEqual(m.read(self.login / 'supervisor.json')['tmux_tmpdir'], str(self.root / 'tmux-a'))
        self.assertEqual(self.launches(a)[0]['env']['TMUX_TMPDIR'], str(self.root / 'tmux-a'))
        err = io.StringIO()
        with patch.dict(os.environ, {'TMUX_TMPDIR': str(self.root / 'tmux-b')}), contextlib.redirect_stderr(err):
            m.ensure(a, timeout=5)
            self.assertEqual(m.attach_environment()['TMUX_TMPDIR'], str(self.root / 'tmux-a'))
        self.assertIn(str(self.root / 'tmux-a'), err.getvalue())
        self.assertIn(str(self.root / 'tmux-b'), err.getvalue())
        self.assertIn('lore session attach', err.getvalue())
        m.WARNED_TMUX_TMPDIR = False
        err = io.StringIO()
        with patch.dict(os.environ, {'TMUX_TMPDIR': str(self.root / 'tmux-a')}), contextlib.redirect_stderr(err):
            m.ensure(a, timeout=5)
        self.assertEqual(err.getvalue(), '')

    def test_children_it_did_not_start_are_tracked_and_reconciled(self):
        a = self.store('a', {'sessions': [{'slug': 'task--w1', 'type': 'implement'}]})
        directory = self.directory(a)
        manual = subprocess.Popen(
            [str(self.stub), '--session-host', '--scope', 'store', '--host-key', runtime.store_host_key(a),
             '--kdir', str(a), '--ready-file', str(directory / 'ready.json'), '--idle-timeout', '30',
             '--runtime', 'login-test'], cwd=str(a), stdin=subprocess.DEVNULL)
        self.processes.append(manual)
        self.until(lambda: self.ready_pid(a) == manual.pid, what='the manually started host')
        manifest = dict(handle='task--w1', host_key=runtime.store_host_key(a), source_dir=str(self.root), state='enqueued')
        m.atomic(m.manifest_path(a, 'task--w1'), manifest)
        row = dict(request_id='op1', slug='task--w1', target_instance='gone', body='hello')
        m.receipt(a, manifest, 'op1', 'send', 'uncertain', request=row)
        status = self.ensure(a)
        self.assertEqual(status['pid'], manual.pid)
        queued = a / '_sessions/send-requests/op1.json'
        self.until(queued.exists, what='operation reconciliation through the tracked host')
        self.assertEqual(m.read(queued)['target_instance'], f'stub-{manual.pid}')
        self.assertIn(f'tracking running host pid {manual.pid}', self.supervisor_log())
        self.assertEqual(len(self.launches(a)), 1)
        first_supervisor = self.supervisor_pid()
        os.kill(first_supervisor, signal.SIGKILL)
        self.until(lambda: not m.held(self.login / 'supervisor.lock'), what='the killed supervisor to release its lock')
        self.ensure(a)
        self.until(lambda: self.supervisor_pid() not in (None, first_supervisor), what='a new supervisor')
        self.until(lambda: self.supervisor_log().count(f'tracking running host pid {manual.pid}') == 2,
                   what='the new supervisor to track the running host')
        self.assertEqual(len(self.launches(a)), 1)
        manual.kill()
        manual.wait()
        self.until(lambda: 'withdrew' in self.supervisor_log().split(f'tracking running host pid {manual.pid}')[-1],
                   what='the supervisor to see the tracked host leave')
        time.sleep(1)
        self.assertEqual(len(self.launches(a)), 1, 'an older request does not relaunch the host')
        self.ensure(a)
        self.assertEqual(len(self.launches(a)), 2)


@unittest.skipIf(SANDBOXED, f'a supervisor is never started inside a sandbox ({SANDBOXED})')
class WithdrawAndRelaunch(LoginCase):
    def test_newer_wanted_at_relaunches_another_store_and_the_same_store_in_the_quiet_period(self):
        a, b = self.store('a', {'idle': 1000}), self.store('b', {'idle': .3})
        self.ensure(a)
        first_a = self.ready_pid(a)
        self.ensure(b)
        self.until(lambda: not self.ready_pid(b) and 'withdrew idle' in self.supervisor_log(), what='b to withdraw')
        time.sleep(.6)
        self.assertEqual(len(self.launches(b)), 1)
        self.ensure(b)
        self.assertEqual(len(self.launches(b)), 2)
        self.assertEqual(self.ready_pid(a), first_a)
        self.control(a, {'idle': .2})
        self.until(lambda: not self.ready_pid(a) and not self.ready_pid(b), what='both hosts to withdraw')
        supervisor = self.supervisor_pid()
        time.sleep(.6)
        self.assertEqual(len(self.launches(a)), 1)
        self.control(a, {'idle': 1000})
        self.ensure(a)
        self.assertEqual(len(self.launches(a)), 2)
        self.assertEqual(self.supervisor_pid(), supervisor)
        self.assertTrue(m.held(self.login / 'supervisor.lock'))

    def test_work_relaunches_a_withdrawn_host_but_a_row_it_will_not_adopt_does_not_flap(self):
        b = self.store('b', {'idle': .3})
        key = runtime.store_host_key(b)
        self.ensure(b)
        self.until(lambda: not self.ready_pid(b), what='b to withdraw')
        row = b / '_sessions/requests/pending/r1.json'
        m.atomic(row, {'request_id': 'r1', 'host_key': key})
        self.until(lambda: len(self.launches(b)) == 2 and self.ready_pid(b), what='a relaunch for the pending row')
        self.assertIn('(work)', self.supervisor_log())
        row.unlink()
        self.until(lambda: not self.ready_pid(b), what='b to withdraw again')
        m.atomic(b / '_sessions/instances/other-runtime.json', dict(
            name='other-runtime', pid=dead_pid(), host_key=key, role='session-host', runtime='elsewhere',
            sessions=[{'slug': 'x--w1'}]))
        time.sleep(1.5)
        self.assertEqual(len(self.launches(b)), 2, "another runtime's dead row is not this store's work")
        m.atomic(b / '_sessions/instances/dead-host.json', dict(
            name='dead-host', pid=dead_pid(), host_key=key, role='session-host', runtime='login-test',
            sessions=[{'slug': 'x--w2'}]))
        self.until(lambda: len(self.launches(b)) == 3, what='a relaunch for the dead row')
        self.until(lambda: not self.ready_pid(b) and self.supervisor_log().count('withdrew idle') >= 3,
                   what='the stub, which adopts nothing, to withdraw')
        time.sleep(2)
        self.assertEqual(len(self.launches(b)), 3, 'a dead row present at the last withdraw does not relaunch the host')

    def test_quiet_exit_and_ensure_are_serialized_by_served_lock(self):
        os.environ['LORE_SESSION_SUPERVISOR_QUIET_SECONDS'] = '1'
        a = self.store('a', {'idle': .3})
        self.ensure(a)
        supervisor = self.supervisor_pid()
        with (self.login / 'served.lock').open('a+') as served_lock:
            fcntl.flock(served_lock, fcntl.LOCK_EX)
            self.until(lambda: 'checking for new requests before exiting' in self.supervisor_log(),
                       what='the supervisor to reach its exit decision')
            served = m.read(self.login / 'served.json')
            served['stores'][str(a)]['wanted_at'] = m.now()
            m.atomic(self.login / 'served.json', served)
            self.assertTrue(m.held(self.login / 'supervisor.lock'))
        self.until(lambda: len(self.launches(a)) == 2, what='the relaunch the late registration asked for')
        self.assertEqual(self.supervisor_pid(), supervisor)
        self.assertNotIn(f'supervisor {supervisor} exiting', self.supervisor_log())
        self.until(lambda: f'supervisor {supervisor} exiting' in self.supervisor_log(), what='the quiet exit')
        self.until(lambda: not m.held(self.login / 'supervisor.lock'), what='the supervisor lock to be released')
        self.ensure(a)
        self.until(lambda: self.supervisor_pid() not in (None, supervisor), what='a new supervisor')
        self.assertEqual(len(self.launches(a)), 3)


@unittest.skipIf(SANDBOXED, f'a supervisor is never started inside a sandbox ({SANDBOXED})')
class ExitCodesAndBudgets(LoginCase):
    def test_crash_budget_is_per_store_and_a_new_request_retries(self):
        a, b = self.store('a', {'exit': 1}), self.store('b')
        self.ensure(b)
        healthy = self.ready_pid(b)
        with self.assertRaisesRegex(RuntimeError, 'failed starts') as caught:
            self.ensure(a, timeout=40)
        self.assertIn('host.log', str(caught.exception))
        self.assertIn('supervisor-error.json', str(caught.exception))
        self.assertEqual(len(self.launches(a)), m.CRASH_BUDGET)
        error = m.read(self.directory(a) / 'supervisor-error.json')
        self.assertEqual((error['reason'], error['exit_code']), ('restart-budget', 1))
        time.sleep(1)
        self.assertEqual(len(self.launches(a)), m.CRASH_BUDGET)
        self.assertEqual(self.ready_pid(b), healthy)
        self.assertFalse((self.directory(b) / 'supervisor-error.json').exists())
        self.control(a, {})
        status = self.ensure(a)
        self.assertEqual(len(self.launches(a)), m.CRASH_BUDGET + 1)
        self.assertEqual(status['pid'], self.launches(a)[-1]['pid'])
        self.until(lambda: not (self.directory(a) / 'supervisor-error.json').exists(), what='the record to clear')

    def test_exit_2_is_recorded_once_fails_ensure_fast_and_waits_for_a_new_binary(self):
        a = self.store('a', {'exit': 2})
        with self.assertRaisesRegex(RuntimeError, 'lore rebuild') as caught:
            self.ensure(a, timeout=40)
        self.assertIn('bash install.sh', str(caught.exception))
        self.assertIn('exit 2', str(caught.exception))
        error = m.read(self.directory(a) / 'supervisor-error.json')
        self.assertEqual(error['exit_code'], 2)
        self.assertEqual(error['binary_identity'], m.file_identity(self.stub))
        time.sleep(1.5)
        self.assertEqual(len(self.launches(a)), 1, 'exit 2 is not retried while the binary is unchanged')
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'bash install.sh'):
            self.ensure(a, timeout=40)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(len(self.launches(a)), 1)
        self.assertNotIn('failed starts', self.supervisor_log())
        self.control(a, {})
        with self.stub.open('a') as stream:
            stream.write('\n# rebuilt\n')
        status = self.ensure(a)
        self.assertEqual(len(self.launches(a)), 2)
        self.assertEqual(status['pid'], self.launches(a)[-1]['pid'])


class SupervisorInProcess(LoginCase):
    """Supervisor passes driven from the test, with the stub hosts as this process's children."""

    def supervisor(self, stores):
        self.login.mkdir(parents=True, exist_ok=True)
        m.atomic(self.login / 'served.json', {'schema_version': 1, 'stores': {
            str(kdir): {'wanted_at': m.now(), 'pin_knowledge_dir': pinned} for kdir, pinned in stores}})
        stream = (self.login / 'supervisor.lock').open('a+')
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(stream.close)
        self.output = io.StringIO()
        with contextlib.redirect_stdout(self.output):
            supervisor = m.Supervisor(stream)
        self.addCleanup(self.stop_children, supervisor)
        return supervisor

    def stop_children(self, supervisor):
        for slot in supervisor.slots.values():
            if slot.process is not None:
                slot.process.kill()
                slot.process.wait()

    def drive(self, supervisor, predicate, timeout=15, what='condition'):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
                supervisor.tick()
            value = predicate()
            if value:
                return value
            time.sleep(.05)
        self.fail(f'timed out waiting for {what}:\n{self.output.getvalue()}')

    def test_exit_codes_follow_the_host_contract(self):
        a = self.store('a')
        supervisor = self.supervisor([(a, False)])
        slot = supervisor.slot(a)
        slot.pid, slot.launch_identity = 111, m.file_identity(self.stub)
        identity = slot.launch_identity
        with contextlib.redirect_stdout(self.output):
            m.atomic(slot.directory / 'restart.json', {'target_pid': 111})
            supervisor.exited(slot, 75)
            self.assertTrue(slot.relaunch)
            self.assertEqual(slot.attempts, 0)
            self.assertFalse((slot.directory / 'restart.json').exists())
            self.assertEqual(supervisor.launch_reason(slot, None), 'restart')
            slot.relaunch = False
            supervisor.exited(slot, 0)
            self.assertIsNone(supervisor.launch_reason(slot, {'wanted_at': '2020-01-01T00:00:00Z'}))
            self.assertEqual(supervisor.launch_reason(slot, {'wanted_at': m.now()}), 'requested')
            supervisor.exited(slot, 3)
            self.assertEqual(slot.attempts, 0)
            self.assertGreater(slot.not_before, time.monotonic())
            delays = []
            for attempt in range(1, m.CRASH_BUDGET):
                supervisor.exited(slot, 1)
                self.assertEqual(slot.attempts, attempt)
                delays.append(slot.not_before - time.monotonic())
            self.assertEqual(delays, sorted(delays))
            self.assertIsNone(slot.blocked)
            supervisor.exited(slot, 1)
            self.assertEqual(slot.blocked, 'budget')
            self.assertEqual(m.read(slot.directory / 'supervisor-error.json')['reason'], 'restart-budget')
            self.assertIsNone(supervisor.launch_reason(slot, {'wanted_at': '2020-01-01T00:00:00Z'}))
            time.sleep(.01)
            self.assertEqual(supervisor.launch_reason(slot, {'wanted_at': m.now()}), 'requested again')
            b = self.store('b')
            other = supervisor.slot(b)
            other.pid, other.launch_identity = 222, identity
            supervisor.exited(other, 2)
            self.assertEqual((other.blocked, other.attempts), ('refused', 0))
            record = m.read(other.directory / 'supervisor-error.json')
            self.assertEqual((record['exit_code'], record['binary_identity']), (2, identity))
            self.assertIsNone(supervisor.launch_reason(other, {'wanted_at': m.now()}))
            with self.stub.open('a') as stream:
                stream.write('\n# rebuilt\n')
            self.assertEqual(supervisor.launch_reason(other, None), 'the host binary changed')

    def test_binary_change_restarts_hosts_by_restart_file_without_building(self):
        installed = self.home / '.local/bin/lore-tui'
        write_stub(installed)
        del os.environ['LORE_SESSION_HOST_BINARY']
        a, b = self.store('a'), self.store('b')
        builds = []
        with patch.object(m, 'checkout_binary', side_effect=lambda kdir: builds.append(kdir)), \
                patch.object(m, 'BINARY_CHECK_SECONDS', .2), patch.object(m, 'STABLE_SECONDS', .4):
            supervisor = self.supervisor([(a, False), (b, False)])
            self.drive(supervisor, lambda: self.ready_pid(a) and self.ready_pid(b), what='both hosts')
            before = {kdir: self.ready_pid(kdir) for kdir in (a, b)}
            row = m.request_restart(a, 'probe')
            registry = m.read(a / '_sessions/instances' / f'stub-{before[a]}.json')
            self.assertEqual((row['target_pid'], row['target_started']), (before[a], registry['started']))
            self.assertEqual(row['schema_version'], 1)
            m.atomic(self.directory(a) / 'restart.json', dict(row, target_pid=before[a] + 100000))
            time.sleep(.5)
            self.assertEqual(self.ready_pid(a), before[a], 'a restart file naming another process is ignored')
            (self.directory(a) / 'restart.json').unlink()
            for _ in range(10):
                with contextlib.redirect_stdout(self.output):
                    supervisor.tick()
                time.sleep(.05)
            self.assertFalse((self.directory(a) / 'restart.json').exists(), 'an unchanged binary restarts nothing')
            with installed.open('a') as stream:
                stream.write('\n# reinstalled\n')
            new_identity = m.file_identity(installed)
            self.drive(supervisor, lambda: all(self.ready_pid(k) and self.ready_pid(k) != before[k] for k in (a, b)),
                       what='both hosts to restart onto the new binary')
            for kdir in (a, b):
                slot = supervisor.slot(kdir)
                self.assertEqual(slot.launch_identity, new_identity)
                self.assertEqual(slot.attempts, 0)
                self.assertFalse((self.directory(kdir) / 'restart.json').exists())
                self.assertEqual(len(self.launches(kdir)), 2)
            self.assertIn('drained for a restart', self.output.getvalue())
            for _ in range(15):
                with contextlib.redirect_stdout(self.output):
                    supervisor.tick()
                time.sleep(.05)
            self.assertEqual([len(self.launches(k)) for k in (a, b)], [2, 2])
        self.assertEqual(builds, [])
        installed.unlink()
        self.assertIsNone(m.installed_or_override_binary())

    def test_supervisor_subprocesses_run_with_the_store_environment(self):
        os.environ.update(CLAUDECODE='1', CLAUDE_CODE_CHILD_SESSION='1', CODEX_THREAD_ID='t',
                          LORE_POSITION_DISPATCH_MANIFEST='m', LORE_SESSION_SLUG='x--w1')
        a, b = self.store('a'), self.store('b')
        os.environ['LORE_KNOWLEDGE_DIR'] = str(a)
        base = dict(os.environ)
        for kdir in (a, b):
            m.atomic(kdir / '_work/item/_meta.json', {})
            m.atomic(m.manifest_path(kdir, 'item--w1'), dict(
                handle='item--w1', request_id='managed-' + kdir.name, host_key=runtime.store_host_key(kdir),
                source_dir=str(self.root), work_item='item', state='intent', context='brief',
                route={'framework': 'codex', 'model': 'm'}))
        calls = []

        def record(argv, **kwargs):
            calls.append((Path(str(argv[1])).name, kwargs.get('env')))
            return subprocess.CompletedProcess(argv, 0, '{}', '')
        supervisor = self.supervisor([(a, True), (b, False)])
        with patch.object(m.subprocess, 'run', side_effect=record):
            self.drive(supervisor, lambda: all(m.read(m.manifest_path(k, 'item--w1'))['state'] == 'enqueued' for k in (a, b)),
                       what='intent replay in both stores')
        self.assertEqual(sorted(script for script, _ in calls), ['session-request.sh', 'session-request.sh',
                                                                 'set-work-meta.sh', 'set-work-meta.sh'])
        for script, env in calls:
            for name in ('CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CODEX_THREAD_ID',
                         'LORE_POSITION_DISPATCH_MANIFEST', 'LORE_SESSION_SLUG'):
                self.assertNotIn(name, env, script)
        meta = {env['LORE_KNOWLEDGE_DIR'] for script, env in calls if script == 'set-work-meta.sh'}
        self.assertEqual(meta, {str(a), str(b)})
        writers = [env for script, env in calls if script == 'session-request.sh']
        self.assertEqual(len(writers), 2)
        self.assertIn(runtime.child_environment(base, a, True), writers)
        self.assertIn(runtime.child_environment(base, b, False), writers)
        for kdir, pinned in ((a, str(a)), (b, None)):
            launch = self.launches(kdir)[0]
            self.assertEqual(launch['env']['LORE_KNOWLEDGE_DIR'], pinned)
            self.assertNotIn('CLAUDE_CODE_CHILD_SESSION', launch['env_names'])


class StoreWork(LoginCase):
    def test_store_work_uses_the_host_predicates(self):
        kdir = self.store('repos-store')
        key = runtime.store_host_key(kdir)
        sessions = kdir / '_sessions'
        self.assertFalse(m.store_has_work(kdir))
        m.atomic(sessions / 'requests/pending/other.json', {'host_key': 'someone-else'})
        m.atomic(sessions / 'requests/pending/unkeyed.json', {})
        m.atomic(sessions / 'managed/x--w1.json', {'host_key': key, 'state': 'enqueued'})
        m.atomic(sessions / 'instances/alive.json', dict(name='alive', pid=os.getpid(), host_key=key,
                                                          runtime='login-test', sessions=[{'slug': 'a'}]))
        m.atomic(sessions / 'instances/empty.json', dict(name='empty', pid=dead_pid(), host_key=key,
                                                          runtime='login-test', sessions=[]))
        m.atomic(sessions / 'instances/unstamped.json', dict(name='unstamped', pid=dead_pid(), host_key=key,
                                                              sessions=[{'slug': 'u'}]))
        m.atomic(sessions / 'instances/foreign-tui.json', dict(name='foreign-tui', pid=dead_pid(), repo='other',
                                                                runtime='login-test', sessions=[{'slug': 'f'}]))
        self.assertEqual(m.store_work(kdir), set())
        m.atomic(sessions / 'requests/pending/r1.json', {'host_key': key})
        m.atomic(sessions / 'requests/claimed/r2.json', {'host_key': key})
        m.atomic(sessions / 'managed/y--w1.json', {'host_key': key, 'state': 'intent'})
        m.atomic(sessions / 'managed/z--w1.json', {'host_key': key, 'state': 'enqueueing'})
        m.atomic(sessions / 'instances/dead.json', dict(name='dead', pid=dead_pid(), host_key=key,
                                                         runtime='login-test', sessions=[{'slug': 'd'}]))
        m.atomic(sessions / 'instances/tui.json', dict(name='tui', pid=dead_pid(), repo=m.repo_identifier(kdir),
                                                        runtime='login-test', sessions=[{'slug': 't'}]))
        m.atomic(sessions / f'instances/claimed.json.adopting.{dead_pid()}', dict(
            name='claimed', pid=dead_pid(), host_key=key, runtime='login-test', sessions=[{'slug': 'c'}]))
        self.assertEqual({w.split(':')[0] + ':' + w.split(':')[1].split('.adopting.')[0] for w in m.store_work(kdir)},
                         {'pending:r1', 'claimed:r2', 'manifest:y--w1', 'manifest:z--w1', 'dead:dead.json',
                          'dead:tui.json', 'dead:claimed.json'})

    def test_migrated_keys_count_only_in_the_default_runtime(self):
        kdir = self.store('s')
        os.environ.pop('LORE_SESSION_RUNTIME')
        key = runtime.store_host_key(kdir)
        m.atomic(kdir / '_sessions/hosts/legacy/migrated.json', {'schema_version': 1, 'from': 'legacy', 'to': key})
        m.atomic(kdir / '_sessions/instances/old.json', dict(name='old', pid=dead_pid(), host_key='legacy',
                                                              sessions=[{'slug': 'o'}]))
        self.assertEqual(m.store_work(kdir), {'dead:old.json'})
        os.environ['LORE_SESSION_RUNTIME'] = 'login-test'
        self.assertEqual(m.store_work(kdir), set())


class HarnessEnvironmentFixture(unittest.TestCase):
    def test_scrub_is_pinned_by_names_from_real_sessions(self):
        fixture = json.loads(FIXTURE.read_text())
        names = sorted(set().union(*(capture['names'] for capture in fixture['captures'].values())))
        self.assertEqual(set(fixture['captures']), {'claude-code-desktop', 'claude-code-cli', 'codex', 'opencode'})
        for capture in fixture['captures'].values():
            self.assertTrue(capture['names'], capture['how'])
            self.assertTrue(all('=' not in name for name in capture['names']), 'the fixture holds names only')
        env = runtime.child_environment({name: 'x' for name in names}, '/store', False)
        self.assertEqual(sorted(set(names) - set(env)), fixture['scrubbed'])
        self.assertEqual(sorted(env), fixture['kept'])
        for marker in ('CLAUDECODE', 'CLAUDE_CODE_CHILD_SESSION', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_MESSAGING_SOCKET',
                       'CLAUDE_CODE_HOST_SESSION_ID', 'CLAUDE_PID', 'CLAUDE_AGENT_SDK_VERSION', 'AI_AGENT',
                       'CODEX_SANDBOX', 'CODEX_THREAD_ID', 'OPENCODE_SESSION_ID'):
            self.assertIn(marker, fixture['scrubbed'])

    def test_keep_list_is_pinned_by_documented_settings(self):
        fixture = json.loads(FIXTURE.read_text())
        settings = sorted(set().union(*fixture['user_settings']['names'].values()))
        env = runtime.child_environment({name: 'x' for name in settings}, '/store', False)
        self.assertEqual(sorted(env), settings)
        family_keeps = {name for name in runtime.KEEP_NAMES if not name.startswith('LORE_')}
        self.assertEqual(family_keeps, {n for n in settings if not n.startswith(runtime.KEEP_PREFIXES)})
        for name in runtime.KEEP_NAMES:
            self.assertTrue(name.startswith(runtime.SCRUB_PREFIXES), f'{name} restores nothing a family removes')


class SandboxRefusal(LoginCase):
    def sandboxed(self, code, *, via_shell=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith('CODEX_SANDBOX')}
        argv = [sys.executable, '-c', code]
        if via_shell:
            argv = ['/bin/sh', '-c', ' '.join(f"'{a}'" for a in argv)]
        return subprocess.run([SANDBOX_EXEC, '-p', PERMISSIVE, *argv], env=env, text=True, capture_output=True,
                              timeout=60)

    def test_environment_markers_refuse_a_start_without_launching(self):
        a = self.store('a')
        with patch.dict(os.environ, {'CODEX_SANDBOX': 'seatbelt'}), \
                patch.object(m.subprocess, 'Popen', side_effect=AssertionError('no supervisor may start')):
            with self.assertRaisesRegex(RuntimeError, 'outside the sandbox'):
                self.ensure(a, timeout=5)
        self.assertEqual(runtime.sandbox_reason({'CODEX_SANDBOX_NETWORK_DISABLED': '1'}),
                         'CODEX_SANDBOX_NETWORK_DISABLED is set')
        self.assertFalse((self.login / 'supervisor.json').exists())

    @unittest.skipUnless(SANDBOX_EXEC, 'sandbox-exec is macOS only')
    def test_detection_follows_process_ancestry(self):
        probe = (f'import importlib.util as u; s = u.spec_from_file_location("r", "{ROOT}/scripts/session_runtime.py"); '
                 'r = u.module_from_spec(s); s.loader.exec_module(r); print(repr(r.sandbox_reason()))')
        self.assertEqual(subprocess.run([sys.executable, '-c', probe], text=True, capture_output=True,
                                        env={k: v for k, v in os.environ.items() if not k.startswith('CODEX_SANDBOX')}
                                        ).stdout.strip(), "''")
        for via_shell in (False, True):
            result = self.sandboxed(probe, via_shell=via_shell)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('macOS sandbox', result.stdout)

    @unittest.skipUnless(SANDBOX_EXEC, 'sandbox-exec is macOS only')
    @unittest.skipIf(SANDBOXED, f'a supervisor is never started inside a sandbox ({SANDBOXED})')
    def test_sandboxed_caller_cannot_start_a_supervisor_but_uses_a_running_one(self):
        a = self.store('a', {'idle': .5})
        call = (f'import importlib.util as u, json, sys; from pathlib import Path; '
                f's = u.spec_from_file_location("m", "{ROOT}/scripts/session-managed.py"); m = u.module_from_spec(s); '
                f's.loader.exec_module(m); print(json.dumps(m.ensure(Path("{a}"), timeout=15)))')
        refused = self.sandboxed(call)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('refusing to start the session supervisor from inside a sandbox', refused.stderr)
        self.assertIn('macOS sandbox', refused.stderr)
        self.assertFalse(m.held(self.login / 'supervisor.lock'))
        self.assertFalse((self.login / 'supervisor.json').exists())
        self.assertEqual(self.launches(a), [])
        self.control(a, {'idle': 1000})
        self.ensure(a)
        used = self.sandboxed(call)
        self.assertEqual(used.returncode, 0, used.stderr)
        self.assertEqual(json.loads(used.stdout)['pid'], self.ready_pid(a))
        self.control(a, {'idle': .2})
        self.until(lambda: not self.ready_pid(a), what='the host to withdraw')
        self.control(a, {'idle': 1000})
        relaunched = self.sandboxed(call)
        self.assertEqual(relaunched.returncode, 0, relaunched.stderr)
        self.assertEqual(len(self.launches(a)), 2, 'the running supervisor relaunched the host for a sandboxed caller')
        self.assertEqual(len(re.findall(r'supervisor \d+ started', self.supervisor_log())), 1)


@unittest.skipIf(SANDBOXED, f'a supervisor is never started inside a sandbox ({SANDBOXED})')
class ScriptReexec(LoginCase):
    """The supervisor runs from a copy of its two scripts so the test can change them."""

    def setUp(self):
        super().setUp()
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        for name in m.SUPERVISED_SCRIPTS:
            shutil.copy2(ROOT / 'scripts' / name, self.scripts / name)

    def start(self, **env):
        self.login.mkdir(parents=True, exist_ok=True)
        with (self.login / 'supervisor.log').open('ab') as output:
            process = subprocess.Popen([sys.executable, str(self.scripts / 'session-managed.py'), '_supervise'],
                                       env=dict(os.environ, **env), stdin=subprocess.DEVNULL, stdout=output,
                                       stderr=output, start_new_session=True, cwd=str(self.login))
        self.processes.append(process)
        return process

    def serve(self, kdir):
        m.atomic(self.login / 'served.json', {'schema_version': 1, 'stores': {
            str(kdir): {'wanted_at': m.now(), 'pin_knowledge_dir': False}}})

    def edit(self, name, text):
        path = self.scripts / name
        path.write_text(path.read_text() + text)
        return time.time()

    def log_time(self, marker):
        for line in self.supervisor_log().splitlines():
            if marker in line:
                return m.instant(line.split(' ', 1)[0])
        return None

    def test_reexec_only_after_a_stable_change_passes_its_self_check(self):
        a = self.store('a')
        self.serve(a)
        supervisor = self.start()
        self.until(lambda: self.ready_pid(a), what='the host')
        host = self.ready_pid(a)
        original = (self.scripts / 'session_runtime.py').read_text()
        self.edit('session_runtime.py', '\ndef broken(:\n')
        error = self.login / 'supervisor-error.json'
        self.until(error.exists, timeout=30, what='the failed self-check record')
        self.assertIn('self-check', m.read(error)['error'])
        self.assertIn('SyntaxError', m.read(error)['output'])
        self.assertIsNone(supervisor.poll())
        self.assertNotIn('re-executing', self.supervisor_log())
        (self.scripts / 'session_runtime.py').write_text(original)
        changed = self.edit('session-managed.py', '\n# a later revision\n')
        self.until(lambda: 're-executing' in self.supervisor_log(), timeout=30, what='the re-exec')
        self.assertGreaterEqual(self.log_time('re-executing') - changed, m.STABLE_SECONDS - .5)
        self.until(lambda: len(re.findall(rf'supervisor {supervisor.pid} started', self.supervisor_log())) == 2,
                   what='the re-executed supervisor')
        record = m.read(self.login / 'supervisor.json')
        self.assertEqual(record['pid'], supervisor.pid)
        self.assertEqual(record['scripts']['session-managed.py'], m.file_identity(self.scripts / 'session-managed.py'))
        self.assertTrue(m.held(self.login / 'supervisor.lock'))
        time.sleep(1)
        self.assertEqual(self.ready_pid(a), host)
        self.assertEqual(len(self.launches(a)), 1, 'the host survives the re-exec and is not relaunched')
        self.control(a, {'idle': .2})
        self.until(lambda: 'withdrew idle' in self.supervisor_log(), what='the re-executed supervisor to see its child exit')

    def test_a_supervisor_started_in_the_reexec_gap_keeps_the_lock(self):
        a = self.store('a')
        self.serve(a)
        first = self.start(LORE_TEST_SUPERVISOR_GAP='3')
        self.until(lambda: self.ready_pid(a), what='the host')
        host = self.ready_pid(a)
        source = (self.scripts / 'session-managed.py').read_text()
        gap = ("\nif sys.argv[1:2] == ['_supervise'] and os.environ.get('LORE_TEST_SUPERVISOR_GAP'):\n"
               "    time.sleep(float(os.environ['LORE_TEST_SUPERVISOR_GAP']))\n")
        (self.scripts / 'session-managed.py').write_text(source.replace('\nSCRIPTS = ', gap + '\nSCRIPTS = ', 1))
        self.until(lambda: 're-executing' in self.supervisor_log(), timeout=30, what='the re-exec')
        self.until(lambda: not m.held(self.login / 'supervisor.lock'), timeout=5, step=.01, what='the gap')
        second = self.start()
        self.until(lambda: m.read_quiet(self.login / 'supervisor.json', {}).get('pid') == second.pid,
                   what='the gap winner')
        self.assertEqual(first.wait(timeout=15), 0)
        self.assertIn(f'supervisor {first.pid}: another supervisor holds', self.supervisor_log())
        self.assertIsNone(second.poll())
        self.until(lambda: f'tracking running host pid {host}' in self.supervisor_log(), what='the winner to track the host')
        self.assertEqual(self.ready_pid(a), host)
        self.assertEqual(len(self.launches(a)), 1)


if __name__ == '__main__':
    unittest.main()
