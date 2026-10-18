#!/usr/bin/env python3
"""On-demand, durable session administration over the existing session substrate."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
import traceback

SCRIPTS = Path(__file__).resolve().parent
WARNED_CORRUPTION = set()
EVENT_CACHE = {}
TERMINAL = {'closed', 'request_cancelled', 'request_expired', 'request_abandoned', 'orphaned'}
REQUIRED_CAPABILITIES = frozenset({'position-preparation-v1'})
SUPERVISED_SCRIPTS = ('session-managed.py', 'session_runtime.py')

QUIET_SECONDS = 60
PASS_SECONDS = .2
STORE_PASS_SECONDS = 1
BINARY_CHECK_SECONDS = 10
STABLE_SECONDS = 5
CRASH_BUDGET = 6
HELD_ELSEWHERE_RETRY_SECONDS = 1
SELF_CHECK_SECONDS = 60
ENSURE_REFRESH_SECONDS = 1
STALE_INTENT_SECONDS = 24 * 60 * 60
EXPIRY_LOCK_WAIT_SECONDS = 5
EXPIRY_LOCK_RECLAIM_SECONDS = 60
MIGRATED_LEDGERS = ('deliveries', 'allocations', 'cleanup')
MANIFEST_HANDLE = re.compile(r'[a-zA-Z0-9][a-zA-Z0-9._-]*--w[0-9]+')
REPORTED_SKIPS = set()

# While the supervisor works on one store, the environment that store's
# subprocesses run with; None everywhere else.
STORE_ENV = None
WARNED_TMUX_TMPDIR = False


def sibling_module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    if spec is None or spec.loader is None:
        raise RuntimeError(f'{name} helper is unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNTIME = sibling_module('session_runtime')


def route_module():
    spec = importlib.util.spec_from_file_location('route_config', SCRIPTS / 'route_config.py')
    if spec is None or spec.loader is None:
        raise RuntimeError('canonical route helper is unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def canonical_start_route(args, source):
    """Validate all settings, then resolve or canonicalize one frozen worker route."""
    routes = route_module()
    settings_path = Path(os.environ.get('LORE_DATA_DIR', Path.home() / '.lore')) / 'config/settings.json'
    try:
        settings = json.loads(settings_path.read_text())
        routes.validate_settings(settings, SCRIPTS.parent)
        session_route = getattr(args, 'session_route', None)
        if session_route is not None:
            if args.framework is not None or args.model is not None:
                raise RuntimeError('--session-route conflicts with --framework/--model; pass one complete override')
            value = json.loads(session_route) if session_route.lstrip().startswith(('{', '[')) else session_route
            parsed = routes.parse_route(value, SCRIPTS.parent)
            if 'routing_source' not in parsed:
                parsed['routing_source'] = {'layer': 'override', 'role': 'worker'}
            return parsed
        if (args.framework is None) != (args.model is None):
            raise RuntimeError('--framework and --model are a pair: pass both to override the worker route, or neither to resolve it')
        if args.framework is not None:
            return routes.resolve_route_for_role('worker', repo_root=SCRIPTS.parent, settings=settings,
                                                 cwd=source, override=f'{args.framework}/{args.model}')
        return routes.resolve_route_for_role('worker', repo_root=SCRIPTS.parent, settings=settings, cwd=source)
    except routes.RouteConfigError as exc:
        location = f' at {exc.path}' if exc.path else ''
        raise RuntimeError(f'invalid route configuration ({exc.code}){location}: {exc.message}') from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f'invalid route configuration: cannot read {settings_path}: {exc}') from exc


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def read_quiet(path, default=None):
    """A record another process may be replacing or may have left damaged."""
    try:
        value = json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default
    return value if isinstance(value, dict) else default


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(value if isinstance(value, bytes) else (json.dumps(value) + '\n').encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def lock(path, blocking=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a+') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield


def held(path):
    try:
        with lock(path, False):
            return False
    except BlockingIOError:
        return True


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')


def instant(value):
    """Epoch seconds of a now() timestamp, or None."""
    try:
        return datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def subprocess_env(**overrides):
    env = dict(os.environ if STORE_ENV is None else STORE_ENV)
    env.update(overrides)
    return env


def run(argv, **kwargs):
    if STORE_ENV is not None:
        kwargs.setdefault('env', dict(STORE_ENV))
    result = subprocess.run([str(x) for x in argv], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f'{argv[0]} failed ({result.returncode})')
    return result.stdout.strip()


def resolve(source=None):
    return Path(run(['bash', SCRIPTS / 'resolve-repo.sh', *([source] if source else [])])).resolve()


def events(kdir, handle=None):
    path = kdir / '_sessions/events.jsonl'
    try:
        stat = path.stat()
    except FileNotFoundError:
        EVENT_CACHE.pop(str(path), None)
        return []
    identity = (stat.st_dev, stat.st_ino)
    cached = EVENT_CACHE.get(str(path))
    if (cached is None or cached['identity'] != identity or stat.st_size < cached['offset']
            or stat.st_size <= cached['offset'] and stat.st_mtime_ns != cached['mtime']):
        cached = dict(identity=identity, offset=0, line=0, mtime=0, rows=[], by_slug={})
        EVENT_CACHE[str(path)] = cached
    if stat.st_size > cached['offset']:
        with path.open('rb') as stream:
            stream.seek(cached['offset'])
            data = stream.read()
        for line in data.splitlines(keepends=True):
            if not line.endswith(b'\n'):
                break  # resume the incomplete trailing append on the next read
            cached['offset'] += len(line)
            cached['line'] += 1
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError('journal record is not an object')
            except (ValueError, UnicodeDecodeError):
                warning_key = (str(path), identity, cached['line'])
                if warning_key not in WARNED_CORRUPTION:
                    print(f"session: excluded malformed journal record at {path}:{cached['line']}", file=sys.stderr)
                    WARNED_CORRUPTION.add(warning_key)
                continue
            cached['rows'].append(row)
            cached['by_slug'].setdefault(row.get('slug'), []).append(row)
    cached['mtime'] = stat.st_mtime_ns
    return list(cached['rows'] if handle is None else cached['by_slug'].get(handle, []))


def append(kdir, row):
    run(['bash', SCRIPTS / 'session-event-append.sh', '--kdir', kdir], input=json.dumps(row))


def host_dir(kdir, key):
    return RUNTIME.hosts_dir(kdir) / key


def ready(kdir, key, source=None):
    """The readiness a live host published under key, or None.

    Without source the host must be store-scoped: it serves every checkout of
    the store and names none. With source it is a host from before store scope,
    which named the one checkout it served.
    """
    directory = host_dir(kdir, key)
    data = read(directory / 'ready.json', {})
    if not data.get('ready') or data.get('host_key') != key or data.get('knowledge_dir') != str(Path(kdir).resolve()):
        return None
    if (data.get('scope') != 'store') if source is None else (data.get('source_dir') != source):
        return None
    if not held(directory / 'runtime.lock'):
        return None
    try:
        os.kill(data['pid'], 0)
    except (ProcessLookupError, KeyError):
        return None
    registry = read(kdir / '_sessions/instances' / (data['instance_name'] + '.json'), {})
    if registry.get('host_key') != key or registry.get('role') != 'session-host':
        return None
    if source is None and registry.get('scope') != 'store':
        return None
    data['runtime_capabilities'] = sorted(capabilities(data) & capabilities(registry))
    return data


def installed_binary():
    return Path.home() / '.local/bin/lore-tui'


def checkout_identity(repo):
    """The build identity install.sh stamps: HEAD's short SHA and committer date in UTC."""
    try:
        sha = run(['git', '-C', repo, 'rev-parse', '--short', 'HEAD'])
    except (RuntimeError, OSError):
        sha = ''
    try:
        when = run(['git', '-C', repo, 'show', '-s', '--date=format-local:%Y-%m-%dT%H:%M:%SZ', '--format=%cd', 'HEAD'],
                   env=dict(os.environ, TZ='UTC'))
    except (RuntimeError, OSError):
        when = ''
    return sha, when


def checkout_binary(kdir):
    tui = SCRIPTS.parent / 'tui'
    sha, when = checkout_identity(SCRIPTS.parent)
    fingerprint = hashlib.sha256()
    for path in sorted(tui.rglob('*')):
        if path.is_file() and (path.suffix in {'.go', '.mod', '.sum', '.a', '.h'} or path.name == 'pkg-config-shim.sh'):
            stat = path.stat()
            fingerprint.update(f'{path}:{stat.st_mtime_ns}:{stat.st_size}'.encode())
    fingerprint.update(os.environ.get('LORE_TUI_BUILD_TAGS', '').encode())
    fingerprint.update(f'\0{sha}\0{when}'.encode())
    output = kdir / '_sessions/bin' / ('lore-session-host-' + fingerprint.hexdigest()[:24])
    with lock(output.parent / 'build.lock'):
        if not output.exists():
            env = dict(os.environ, CGO_ENABLED='1', PKG_CONFIG=str(tui / 'internal/work/libghostty/pkg-config-shim.sh'))
            args = ['go', 'build']
            if env.get('LORE_TUI_BUILD_TAGS'):
                args += ['-tags', env['LORE_TUI_BUILD_TAGS']]
            args += ['-ldflags', f'-X main.buildSHA={sha} -X main.buildTime={when}']
            args += ['-o', str(output) + '.tmp', '.']
            run(args, cwd=tui, env=env)
            os.replace(str(output) + '.tmp', output)
    return output


def binary(kdir):
    override = os.environ.get('LORE_SESSION_HOST_BINARY')
    if override:
        path = Path(override).resolve(strict=True)
        if not os.access(path, os.X_OK):
            raise RuntimeError(f'host binary is not executable: {path}')
        return path
    installed = installed_binary()
    if installed.is_file() and os.access(installed, os.X_OK):
        return installed
    print(f'session: hosting with a checkout build of {SCRIPTS.parent / "tui"} '
          f'(no installed lore-tui at {installed}); `bash install.sh` installs one', file=sys.stderr)
    return checkout_binary(kdir)


def installed_or_override_binary():
    """binary() without its checkout-build fallback, which would run go build."""
    override = os.environ.get('LORE_SESSION_HOST_BINARY')
    if override:
        try:
            path = Path(override).resolve(strict=True)
        except OSError:
            return None
        return path if os.access(path, os.X_OK) else None
    installed = installed_binary()
    return installed if installed.is_file() and os.access(installed, os.X_OK) else None


def file_identity(path):
    if path is None:
        return None
    try:
        stat = os.stat(path)
    except OSError:
        return None
    return dict(path=str(path), device=stat.st_dev, inode=stat.st_ino, size=stat.st_size, mtime_ns=stat.st_mtime_ns)


def script_identity():
    return {name: file_identity(SCRIPTS / name) for name in SUPERVISED_SCRIPTS}


def capabilities(status):
    values = status.get('runtime_capabilities', [])
    return set(values) if isinstance(values, list) and all(isinstance(v, str) for v in values) else set()


def require_capabilities(status):
    required = set(REQUIRED_CAPABILITIES)
    missing = required - capabilities(status)
    if missing:
        raise RuntimeError('running host ' + str(status.get('instance_name', '(unknown)'))
                           + ' lacks runtime capability ' + ', '.join(sorted(missing))
                           + '; coordinate host replacement before retrying; host was not restarted')
    return status


def log(message):
    print(f'{now()} {message}', flush=True)


def served_record(login):
    """served.json: the stores this login's supervisor serves, as ensure() registered them."""
    served = read_quiet(login / 'served.json', {})
    stores = served.get('stores')
    served['stores'] = {k: v for k, v in stores.items() if isinstance(v, dict)} if isinstance(stores, dict) else {}
    served.setdefault('schema_version', 1)
    return served


def register_store(login, kdir, pinned):
    """Record that kdir wants its host now; the caller holds served.lock."""
    served = served_record(login)
    served['stores'].setdefault(str(kdir), {}).update(wanted_at=now(), pin_knowledge_dir=bool(pinned))
    atomic(login / 'served.json', served)


def knowledge_dir_pinned(kdir):
    pinned = os.environ.get('LORE_KNOWLEDGE_DIR')
    if not pinned:
        return False
    try:
        return Path(pinned).resolve() == Path(kdir).resolve()
    except OSError:
        return False


def start_supervisor(login):
    login.mkdir(parents=True, exist_ok=True)
    with (login / 'supervisor.log').open('ab') as output:
        return subprocess.Popen([sys.executable, str(SCRIPTS / 'session-managed.py'), '_supervise'],
                                stdin=subprocess.DEVNULL, stdout=output, stderr=output, cwd=str(login),
                                start_new_session=True, close_fds=True)


def warn_tmux_tmpdir(login):
    global WARNED_TMUX_TMPDIR
    record = read_quiet(login / 'supervisor.json', {})
    if WARNED_TMUX_TMPDIR or 'tmux_tmpdir' not in record or not alive(record.get('pid')):
        return
    mine, theirs = os.environ.get('TMUX_TMPDIR') or None, record.get('tmux_tmpdir') or None
    if mine != theirs:
        WARNED_TMUX_TMPDIR = True
        print(f'session: TMUX_TMPDIR here is {mine or "unset"}, but the session supervisor started with '
              f'{theirs or "unset"}; its sessions run on the tmux server for that directory, and '
              '`lore session attach` uses it', file=sys.stderr)


def attach_environment():
    """The caller's environment with the TMUX_TMPDIR the session hosts' tmux server uses."""
    env = dict(os.environ)
    record = read_quiet(RUNTIME.login_dir() / 'supervisor.json', {})
    if 'tmux_tmpdir' in record:
        if record['tmux_tmpdir']:
            env['TMUX_TMPDIR'] = record['tmux_tmpdir']
        else:
            env.pop('TMUX_TMPDIR', None)
    return env


def refuse_recorded_failure(kdir, directory, since, resolved):
    """Fail at once on a recorded failure that waiting cannot fix.

    resolved caches this call's own host binary identity, which an exit 2 is
    judged against; it is resolved only when such a record exists.
    """
    record = read_quiet(directory / 'supervisor-error.json', {})
    if record.get('exit_code') == 2 and 'identity' not in resolved:
        resolved['identity'] = file_identity(binary(kdir))
    identity = resolved.get('identity')
    if record.get('exit_code') == 2 and identity is not None and record.get('binary_identity') == identity:
        raise RuntimeError(
            f'the store host for {kdir} cannot start: {identity["path"]} refused the store-host arguments '
            f'(exit 2, recorded {record.get("at")}), so this lore-tui predates store-scoped hosting. Run '
            f'`lore rebuild` (or `bash install.sh`) to install a current build, then retry; details are in '
            f'{directory / "host.log"} and {directory / "supervisor-error.json"}')
    if record.get('reason') == 'restart-budget' and (instant(record.get('at')) or 0) >= since:
        raise RuntimeError(
            f'the store host for {kdir} stopped after {CRASH_BUDGET} failed starts ({record.get("error")}); '
            f'durable intent retained; see {directory / "host.log"} and {directory / "supervisor-error.json"}, '
            'fix the cause, then retry')


def ensure(kdir, timeout=45):
    """Return the ready store host for kdir, starting the login's supervisor when none runs."""
    kdir = Path(kdir).resolve()
    key = RUNTIME.store_host_key(kdir)
    directory = host_dir(kdir, key)
    if STORE_ENV is not None:
        # Inside the supervisor, which launches hosts itself: waiting here would wait on itself.
        status = ready(kdir, key)
        if not status:
            raise RuntimeError(f'the store host for {kdir} is not ready')
        return require_capabilities(status)
    login = RUNTIME.login_dir()
    since = time.time()
    deadline = time.monotonic() + timeout
    pinned = knowledge_dir_pinned(kdir)
    warn_tmux_tmpdir(login)
    launched = refreshed = None
    resolved = {}
    while True:
        with lock(directory / 'ensure.lock'):
            status = ready(kdir, key)
        if status:
            require_capabilities(status)
            if held(login / 'supervisor.lock'):
                return status
        else:
            refuse_recorded_failure(kdir, directory, since, resolved)
        if status or refreshed is None or time.monotonic() - refreshed >= ENSURE_REFRESH_SECONDS:
            refreshed = time.monotonic()
            with lock(login / 'served.lock'):
                register_store(login, kdir, pinned)
                if not held(login / 'supervisor.lock') and (launched is None or launched.poll() is not None):
                    reason = RUNTIME.sandbox_reason()
                    if not reason:
                        launched = start_supervisor(login)
                    elif not status:
                        raise RuntimeError(
                            f'refusing to start the session supervisor from inside a sandbox ({reason}): it and '
                            'every session host it starts would stay confined to this sandbox, for every store, '
                            'until it exits. Rerun this command outside the sandbox (one escalated command with '
                            'the same arguments); once a supervisor is running, commands from inside a sandbox use it')
        if status:
            return status
        if time.monotonic() >= deadline:
            raise RuntimeError(f'the store host for {kdir} did not become ready within {timeout:g}s; durable intent '
                               f'retained; see {directory / "host.log"}, {directory / "supervisor-error.json"} '
                               f'and {login / "supervisor.log"}')
        time.sleep(.1)


class MigrationDeferred(Exception):
    """An old key cannot be migrated on this pass; a later pass tries again."""


@contextlib.contextmanager
def expiry_sweep_lock(kdir):
    """The request expiry sweep's mkdir lock, which it reclaims after 60 seconds."""
    path = Path(kdir) / '_sessions/requests/.expiry-sweep.lock'
    deadline = time.monotonic() + EXPIRY_LOCK_WAIT_SECONDS
    while True:
        try:
            os.mkdir(path)
            break
        except FileExistsError:
            try:
                age = time.time() - path.stat().st_mtime
            except FileNotFoundError:
                continue
            if age > EXPIRY_LOCK_RECLAIM_SECONDS:
                with contextlib.suppress(OSError):
                    os.rmdir(path)
                continue
            if time.monotonic() >= deadline:
                raise MigrationDeferred('the request expiry sweep holds its lock')
            time.sleep(.05)
    try:
        yield
    finally:
        with contextlib.suppress(OSError):
            os.rmdir(path)


def copy_ledgers(source, target):
    """Copy each ledger record the target lacks, byte for byte, by temp file and rename."""
    copied = 0
    for kind in MIGRATED_LEDGERS:
        for path in sorted((source / kind).glob('*.json')):
            destination = target / kind / path.name
            if path.name.startswith('.') or not path.is_file() or destination.exists():
                continue
            atomic(destination, path.read_bytes())
            copied += 1
    return copied


def abandon_stale_intent(kdir, path, manifest):
    """Retire a start intent too old to spawn: journal it, then mark the manifest."""
    reason = 'stale-intent-at-migration'
    append(kdir, dict(event_id='request-abandoned-' + hashlib.sha256(manifest['request_id'].encode()).hexdigest()[:32],
                      event='request_abandoned', request_id=manifest['request_id'], slug=manifest['handle'],
                      reason=reason))
    if manifest.get('state') != 'request_abandoned':
        manifest.update(state='request_abandoned', abandoned_at=now(), error=(
            f'this start intent, created {manifest.get("created_at") or "at an unknown time"}, was more than '
            f'{STALE_INTENT_SECONDS // 3600} hours old when its host key moved to the store host, so it was abandoned '
            f'({reason}) rather than started; start it again with a new --key if it is still wanted'))
        atomic(path, manifest)


def migrate_manifests(kdir, old, store):
    """Rewrite the old key's manifests to the store key; return the request ids of abandoned intents."""
    abandoned, rewritten = set(), 0
    for path in sorted((Path(kdir) / '_sessions/managed').glob('*.json')):
        if not MANIFEST_HANDLE.fullmatch(path.stem) or read_quiet(path, {}).get('host_key') != old:
            continue
        try:
            with lock(path.with_suffix('.lock'), False):
                manifest = read_quiet(path, {})
                if manifest.get('host_key') != old or manifest.get('handle') != path.stem:
                    continue
                created = instant(manifest.get('created_at'))
                stale = created is None or time.time() - created > STALE_INTENT_SECONDS
                if manifest.get('state') == 'request_abandoned' or (
                        manifest.get('state') in {'intent', 'enqueueing'} and stale):
                    abandon_stale_intent(kdir, path, manifest)
                    abandoned.add(manifest['request_id'])
                    continue
                manifest['host_key'] = store
                atomic(path, manifest)
                rewritten += 1
        except BlockingIOError:
            raise MigrationDeferred(f'managed session {path.stem} is busy') from None
    return abandoned, rewritten


def migrate_request_rows(kdir, old, store, abandoned):
    requests = Path(kdir) / '_sessions/requests'
    if not (requests / 'pending').is_dir() and not (requests / 'claimed').is_dir():
        return 0
    rewritten = 0
    with expiry_sweep_lock(kdir):
        for state in ('pending', 'claimed'):
            for path in sorted((requests / state).glob('*.json')):
                row = read_quiet(path)
                if row is None or row.get('host_key') != old or row.get('request_id') in abandoned:
                    continue
                row['host_key'] = store
                atomic(path, row)
                rewritten += 1
    return rewritten


def migrate_key(kdir, old, store):
    """Move one old per-checkout key onto the store key, or say why not on this pass."""
    directory = Path(kdir) / '_sessions/hosts' / old
    if (directory / 'migrated.json').exists():
        return None, None
    elsewhere = sorted(str(p) for p in (Path(kdir) / '_sessions/runtimes').glob(f'*/hosts/{old}') if p.is_dir())
    if elsewhere:
        return None, ('it also exists under a named runtime (' + ', '.join(elsewhere)
                      + '), so its records may belong to that runtime')
    try:
        with lock(directory / 'runtime.lock', False), lock(directory / 'supervisor.lock', False):
            copied = copy_ledgers(directory, Path(kdir) / '_sessions/hosts' / store)
            abandoned, manifests = migrate_manifests(kdir, old, store)
            rows = migrate_request_rows(kdir, old, store, abandoned)
            atomic(directory / 'migrated.json', dict(schema_version=1, **{'from': old}, to=store, at=now()))
    except BlockingIOError:
        return None, 'its host or supervisor from before store-scoped hosting is still running'
    except MigrationDeferred as deferred:
        return None, f'{deferred}; a later pass retries'
    return dict(key=old, ledger_records=copied, manifests=manifests, request_rows=rows,
                abandoned=sorted(abandoned)), None


def prepare_store(kdir):
    """Move the records of per-checkout hosts from before store scope onto the store key.

    Runs before each launch of a store's host and on each supervisor pass. Only
    the default runtime migrates: old keys carry no runtime name, while the
    manifests, queue and registry they index are shared by every runtime.
    """
    kdir = Path(kdir).resolve()
    summary = dict(migrated=[], skipped={})
    hosts = kdir / '_sessions/hosts'
    if RUNTIME.runtime_name() or not hosts.is_dir():
        return summary
    store = RUNTIME.store_host_key(kdir)
    for old in sorted(p.name for p in hosts.iterdir() if p.is_dir() and p.name != store):
        try:
            done, skipped = migrate_key(kdir, old, store)
        except (OSError, ValueError, RuntimeError, KeyError) as error:
            done, skipped = None, f'migration failed ({type(error).__name__}: {error}); a later pass retries'
        if done:
            summary['migrated'].append(done)
            log(f'{kdir}: migrated host key {old} to {store}: {done["ledger_records"]} ledger records, '
                f'{done["manifests"]} manifests, {done["request_rows"]} queued requests'
                + (f', {len(done["abandoned"])} stale start intents abandoned' if done['abandoned'] else ''))
        elif skipped:
            summary['skipped'][old] = skipped
            if (str(kdir), old, skipped) not in REPORTED_SKIPS:
                REPORTED_SKIPS.add((str(kdir), old, skipped))
                log(f'{kdir}: not migrating host key {old}: {skipped}')
    return summary


def serving_host(kdir, manifest):
    """The ready host that serves a manifest's key: the store host, or a host
    from before store scope that is still live and ready for its checkout."""
    key = manifest.get('host_key')
    if not key:
        return None
    if key == RUNTIME.store_host_key(kdir):
        return ready(kdir, key)
    return ready(kdir, key, manifest.get('source_dir'))


def current_manifest(kdir, manifest):
    """The manifest as it is on disk now, since a migration may have moved its key."""
    try:
        return read_quiet(manifest_path(kdir, manifest['handle']), None) or manifest
    except RuntimeError:
        return manifest


def repo_identifier(kdir):
    """The repo name lore-tui records on its registry rows."""
    data = os.environ.get('LORE_DATA_DIR') or str(Path.home() / '.lore')
    for root in (data, str(Path(data).resolve())):
        prefix = os.path.join(root, 'repos') + os.sep
        if str(kdir).startswith(prefix):
            return str(kdir)[len(prefix):]
    return Path(kdir).name


def adoptable_keys(kdir, key):
    keys = {key}
    if not RUNTIME.runtime_name():
        for path in (Path(kdir) / '_sessions/hosts').glob('*/migrated.json'):
            record = read_quiet(path, {})
            if record.get('to') == key and record.get('from'):
                keys.add(record['from'])
    return keys


def store_work(kdir, key=None):
    """Identifiers of what a store's host would act on: its queue rows, unsent
    managed starts, and dead registry rows whose sessions it would adopt."""
    key = key or RUNTIME.store_host_key(kdir)
    sessions = Path(kdir) / '_sessions'
    work = set()
    for state in ('pending', 'claimed'):
        for path in (sessions / 'requests' / state).glob('*.json'):
            if read_quiet(path, {}).get('host_key') == key:
                work.add(f'{state}:{path.stem}')
    for path in (sessions / 'managed').glob('*.json'):
        manifest = read_quiet(path, {})
        if manifest.get('host_key') == key and manifest.get('state') in {'intent', 'enqueueing'}:
            work.add('manifest:' + path.stem)
    keys, runtime, repo = adoptable_keys(kdir, key), RUNTIME.runtime_name(), repo_identifier(kdir)
    instances = sessions / 'instances'
    for path in [*instances.glob('*.json'), *instances.glob('*.json.adopting.*')]:
        if '.json.adopting.' in path.name:
            try:
                if alive(int(path.name.rsplit('.', 1)[1])):
                    continue
            except ValueError:
                continue
        row = read_quiet(path, {})
        if not row.get('sessions') or alive(row.get('pid')):
            continue
        if row.get('runtime', '') != runtime:
            continue
        if row.get('host_key') in keys or (not row.get('host_key') and row.get('role') != 'session-host'
                                            and row.get('repo') == repo):
            work.add('dead:' + path.name)
    return work


def store_has_work(kdir, key=None):
    return bool(store_work(kdir, key))


def running_host(kdir, key):
    """The pid and start time a live store host published, or None."""
    directory = host_dir(kdir, key)
    data = read_quiet(directory / 'ready.json', {})
    name = data.get('instance_name')
    if not data.get('ready') or data.get('host_key') != key or not name or not alive(data.get('pid')):
        return None
    registry = read_quiet(Path(kdir) / '_sessions/instances' / (name + '.json'), {})
    if registry.get('pid') != data['pid'] or not registry.get('started') or not held(directory / 'runtime.lock'):
        return None
    return dict(pid=data['pid'], started=registry['started'], instance_name=name)


def request_restart(kdir, reason):
    """Ask the store's running host to restart at its next quiescent moment."""
    key = RUNTIME.store_host_key(kdir)
    target = running_host(kdir, key)
    if not target:
        return None
    row = dict(schema_version=1, reason=reason, target_pid=target['pid'], target_started=target['started'],
               requested_at=now())
    atomic(host_dir(kdir, key) / 'restart.json', row)
    return row


def replay_intents(kdir, key, status):
    for path in (Path(kdir) / '_sessions/managed').glob('*.json'):
        manifest = read_quiet(path, {})
        if manifest.get('host_key') != key or manifest.get('state') not in {'intent', 'enqueueing'}:
            continue
        try:
            with lock(path.with_suffix('.lock'), False):
                manifest = read(path)
                if manifest['state'] in {'intent', 'enqueueing'}:
                    enqueue_start(kdir, manifest, status)
        except BlockingIOError:
            pass
        except (RuntimeError, OSError, ValueError, KeyError) as error:
            log(f'intent reconciliation: {error}')


class StoreSlot:
    """What the supervisor knows about one store's host, from its own handle and from files."""

    def __init__(self, kdir):
        self.kdir = Path(kdir).resolve()
        self.key = RUNTIME.store_host_key(self.kdir)
        self.directory = host_dir(self.kdir, self.key)
        self.process = None
        self.pid = None
        self.waitable = False
        self.external = False
        self.launch_identity = None
        self.exited_at = None
        self.attempts = 0
        self.not_before = 0.0
        self.relaunch = False
        self.blocked = None
        self.blocked_identity = None
        self.blocked_at = 0.0
        self.identity_checked = 0.0
        self.restart_for = None
        self.dead_at_exit = set()
        self.was_ready = False
        self.wanted = None
        self.next_pass = 0.0
        self.work = set()
        self.work_checked = None
        record = read_quiet(self.directory / 'child.json', {})
        if isinstance(record.get('pid'), int):
            self.pid = record['pid']
            self.launch_identity = record.get('binary_identity')
            self.exited_at = instant(record['exited_at']) if record.get('exited_at') else None
            # A supervisor that re-executed itself is still the parent of the hosts it launched.
            self.waitable = record.get('supervisor_pid') == os.getpid() and self.exited_at is None
        failure = read_quiet(self.directory / 'supervisor-error.json', {})
        if failure.get('exit_code') == 2:
            self.blocked, self.blocked_identity = 'refused', failure.get('binary_identity')
        elif failure.get('reason') == 'restart-budget':
            self.blocked, self.blocked_at = 'budget', instant(failure.get('at')) or 0.0

    def live(self):
        return self.process is not None or self.waitable or self.external


class Supervisor:
    """One per login and runtime: one store-scoped host per served store."""

    def __init__(self, lock_stream):
        self.lock_stream = lock_stream
        self.login = RUNTIME.login_dir()
        self.slots = {}
        self.quiet_since = None
        try:
            self.quiet_seconds = float(os.environ.get('LORE_SESSION_SUPERVISOR_QUIET_SECONDS') or QUIET_SECONDS)
        except ValueError:
            self.quiet_seconds = float(QUIET_SECONDS)
        self.binary_candidate = self.binary_seen = None
        self.next_binary_check = 0.0
        self.scripts = script_identity()
        self.script_candidate = self.script_seen = self.script_rejected = None
        atomic(self.login / 'supervisor.json', dict(
            schema_version=1, pid=os.getpid(), started_at=now(), runtime=RUNTIME.runtime_name(),
            tmux_tmpdir=os.environ.get('TMUX_TMPDIR') or None, scripts=self.scripts))
        log(f'supervisor {os.getpid()} started')

    def run(self):
        while True:
            code = self.tick()
            if code is not None:
                return code
            time.sleep(PASS_SECONDS)

    def slot(self, kdir):
        if str(kdir) not in self.slots:
            self.slots[str(kdir)] = StoreSlot(kdir)
        return self.slots[str(kdir)]

    def tick(self):
        stores = served_record(self.login)['stores']
        for kdir in stores:
            if Path(kdir).is_dir():
                self.slot(kdir)
        for name, slot in list(self.slots.items()):
            try:
                self.tend(slot, stores.get(name))
            except Exception:
                # One store's failure must not stop the supervisor from serving the others.
                log(f'{slot.kdir}: {traceback.format_exc().strip()}')
            if not slot.live() and not slot.kdir.is_dir():
                del self.slots[name]
        self.check_binary()
        if self.check_scripts():
            try:
                self.reexec()
            except OSError as error:
                self.script_rejected = script_identity()
                atomic(self.login / 'supervisor-error.json', dict(
                    schema_version=1, at=now(), scripts=self.script_rejected,
                    error=f're-executing the supervisor failed ({error}); it keeps running its current code'))
                log(f're-exec failed: {error}')
        return self.check_quiet()

    def tend(self, slot, entry):
        self.observe(slot)
        if slot.live():
            slot.wanted = None
            status = ready(slot.kdir, slot.key)
            if status and not slot.was_ready:
                slot.was_ready = True
                (slot.directory / 'supervisor-error.json').unlink(missing_ok=True)
                log(f'{slot.kdir}: host {status["instance_name"]} (pid {status["pid"]}) is ready')
            if status and time.monotonic() >= slot.next_pass:
                slot.next_pass = time.monotonic() + STORE_PASS_SECONDS
                self.store_pass(slot, entry, status)
            return
        slot.was_ready = False
        slot.wanted = self.launch_reason(slot, entry)
        if slot.wanted and time.monotonic() >= slot.not_before:
            self.launch(slot, entry, slot.wanted)

    def observe(self, slot):
        if slot.process is not None:
            code = slot.process.poll()
            if code is not None:
                slot.process = None
                self.exited(slot, code)
            return
        if slot.waitable:
            try:
                pid, status = os.waitpid(slot.pid, os.WNOHANG)
            except ChildProcessError:
                slot.waitable = False
            else:
                if pid:
                    slot.waitable = False
                    self.exited(slot, os.waitstatus_to_exitcode(status))
                return
        lock_held = held(slot.directory / 'runtime.lock')
        if lock_held:
            current = read_quiet(slot.directory / 'ready.json', {}).get('pid')
            if isinstance(current, int) and current != slot.pid:
                slot.pid, slot.launch_identity = current, None
            if not slot.external:
                slot.external = True
                log(f'{slot.kdir}: tracking running host pid {slot.pid} through its lock and ready file')
        elif slot.external:
            slot.external = False
            self.exited(slot, None)

    def exited(self, slot, code):
        slot.exited_at = time.time()
        slot.was_ready = False
        slot.work_checked = None
        restart = read_quiet(slot.directory / 'restart.json', {})
        requested = restart.get('target_pid') == slot.pid
        if requested:
            (slot.directory / 'restart.json').unlink(missing_ok=True)
        slot.restart_for = None
        record = read_quiet(slot.directory / 'child.json', {})
        if record.get('pid') == slot.pid:
            atomic(slot.directory / 'child.json', dict(record, exited_at=now(), exit_code=code))
        if code == 75 or (code is None and requested):
            slot.relaunch = True
            log(f'{slot.kdir}: host pid {slot.pid} drained for a restart; relaunching it')
        elif code == 2:
            slot.blocked, slot.blocked_identity = 'refused', slot.launch_identity
            binary_path = (slot.launch_identity or {}).get('path')
            self.record_failure(slot, exit_code=2, binary=binary_path, error=(
                f'{binary_path} refused the store-host arguments (exit 2); a lore-tui older than this lore checkout '
                'does not know --scope store or --runtime. Run `lore rebuild` or `bash install.sh`'))
            log(f'{slot.kdir}: {binary_path} refused the store-host arguments (exit 2); waiting for a new binary')
        elif code == 3:
            slot.not_before = time.monotonic() + HELD_ELSEWHERE_RETRY_SECONDS
            log(f'{slot.kdir}: another host holds the store (exit 3)')
        elif code in (0, None):
            slot.attempts = 0
            slot.dead_at_exit = {item for item in store_work(slot.kdir, slot.key) if item.startswith('dead:')}
            log(f'{slot.kdir}: host pid {slot.pid} withdrew' + (' idle' if code == 0 else ''))
        else:
            self.crashed(slot, f'exit {code}', code)

    def crashed(self, slot, error, code):
        slot.attempts += 1
        if slot.attempts >= CRASH_BUDGET:
            slot.blocked, slot.blocked_at = 'budget', time.time()
            self.record_failure(slot, reason='restart-budget', exit_code=code,
                                binary=(slot.launch_identity or {}).get('path'),
                                error=f'host restart budget exhausted; last failure: {error}')
            log(f'{slot.kdir}: host failed {slot.attempts} starts ({error}); waiting for a new request')
        else:
            slot.not_before = time.monotonic() + min(2 ** (slot.attempts - 1) * .2, 5)
            log(f'{slot.kdir}: host failed ({error}); retry {slot.attempts} of {CRASH_BUDGET - 1}')

    def record_failure(self, slot, **fields):
        atomic(slot.directory / 'supervisor-error.json', dict(
            schema_version=1, at=now(), store=str(slot.kdir), host_key=slot.key,
            binary_identity=slot.launch_identity, **fields))

    def launch_reason(self, slot, entry):
        wanted = instant((entry or {}).get('wanted_at'))
        if slot.blocked == 'refused':
            return 'the host binary changed' if self.refusal_lifted(slot) else None
        if slot.blocked == 'budget':
            return 'requested again' if wanted and wanted > slot.blocked_at else None
        if slot.relaunch:
            return 'restart'
        if slot.attempts:
            return 'retry'
        if wanted and (slot.exited_at is None or wanted > slot.exited_at):
            return 'requested'
        if slot.work_checked is None or time.monotonic() - slot.work_checked >= STORE_PASS_SECONDS:
            slot.work, slot.work_checked = store_work(slot.kdir, slot.key), time.monotonic()
        # A dead row present when the host last withdrew is one it would not adopt.
        return 'work' if slot.work - slot.dead_at_exit else None

    def refusal_lifted(self, slot):
        current = installed_or_override_binary()
        if current is None:
            if time.monotonic() - slot.identity_checked < BINARY_CHECK_SECONDS:
                return False
            slot.identity_checked = time.monotonic()
            try:
                current = binary(slot.kdir)
            except (RuntimeError, OSError):
                return False
        return file_identity(current) != slot.blocked_identity

    def store_environment(self, slot, entry):
        return RUNTIME.child_environment(os.environ, slot.kdir, bool((entry or {}).get('pin_knowledge_dir')))

    def launch(self, slot, entry, reason):
        global STORE_ENV
        if slot.blocked:
            log(f'{slot.kdir}: trying the host again ({reason})')
            slot.blocked, slot.blocked_identity, slot.attempts = None, None, 0
            (slot.directory / 'supervisor-error.json').unlink(missing_ok=True)
        env = self.store_environment(slot, entry)
        STORE_ENV = env
        try:
            prepare_store(slot.kdir)
            executable = binary(slot.kdir)
        except Exception as error:
            # A failed preparation or binary resolution is a failed start, bounded by the crash budget.
            self.crashed(slot, f'{type(error).__name__}: {error}', None)
            return
        finally:
            STORE_ENV = None
        runtime = RUNTIME.runtime_name()
        argv = [str(executable), '--session-host', '--scope', 'store', '--host-key', slot.key,
                '--kdir', str(slot.kdir), '--ready-file', str(slot.directory / 'ready.json'),
                '--idle-timeout', os.environ.get('LORE_SESSION_HOST_IDLE_TIMEOUT', '30'),
                *(['--runtime', runtime] if runtime else [])]
        slot.directory.mkdir(parents=True, exist_ok=True)
        (slot.directory / 'restart.json').unlink(missing_ok=True)
        identity = file_identity(executable)
        try:
            with (slot.directory / 'host.log').open('ab') as output:
                process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                                           cwd=str(slot.kdir), env=env, close_fds=True)
        except OSError as error:
            slot.launch_identity = identity
            self.crashed(slot, str(error), None)
            return
        slot.process, slot.pid, slot.launch_identity = process, process.pid, identity
        slot.relaunch = slot.external = slot.waitable = False
        slot.restart_for = None
        atomic(slot.directory / 'child.json', dict(schema_version=1, pid=process.pid, binary=str(executable),
                                                   binary_identity=identity, launched_at=now(),
                                                   supervisor_pid=os.getpid()))
        log(f'{slot.kdir}: launched host pid {process.pid} ({reason}) from {executable}')

    def store_pass(self, slot, entry, status):
        global STORE_ENV
        STORE_ENV = self.store_environment(slot, entry)
        try:
            prepare_store(slot.kdir)
            replay_intents(slot.kdir, slot.key, status)
            reconcile_operations(slot.kdir, slot.key)
        finally:
            STORE_ENV = None

    def check_binary(self):
        moment = time.monotonic()
        if moment < self.next_binary_check:
            return
        identity = file_identity(installed_or_override_binary())
        if identity != self.binary_candidate:
            self.binary_candidate, self.binary_seen = identity, moment
            self.next_binary_check = moment + STABLE_SECONDS
            return
        if moment - self.binary_seen < STABLE_SECONDS:
            self.next_binary_check = self.binary_seen + STABLE_SECONDS
            return
        self.next_binary_check = moment + BINARY_CHECK_SECONDS
        if identity is None:
            return
        for slot in self.slots.values():
            if not slot.live() or slot.launch_identity in (None, identity) or slot.restart_for == slot.pid:
                continue
            row = request_restart(slot.kdir, 'binary-changed')
            if row:
                slot.restart_for = row['target_pid']
                log(f'{slot.kdir}: {identity["path"]} changed; asked host pid {row["target_pid"]} to restart')

    def check_scripts(self):
        current = script_identity()
        if current == self.scripts:
            self.script_candidate = None
            return False
        if current == self.script_rejected:
            return False
        moment = time.monotonic()
        if current != self.script_candidate:
            self.script_candidate, self.script_seen = current, moment
            return False
        if moment - self.script_seen < STABLE_SECONDS:
            return False
        try:
            check = subprocess.run([sys.executable, str(SCRIPTS / 'session-managed.py'), '_self-check'],
                                   stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                   timeout=SELF_CHECK_SECONDS, cwd=str(self.login))
            passed, output = check.returncode == 0, (check.stdout + check.stderr).strip()
        except (OSError, subprocess.TimeoutExpired) as error:
            passed, output = False, str(error)
        if passed:
            return True
        self.script_rejected = current
        atomic(self.login / 'supervisor-error.json', dict(
            schema_version=1, at=now(), scripts=current, output=output[-4000:],
            error='the changed supervisor scripts failed their self-check; the supervisor keeps running its current code'))
        log('changed supervisor scripts failed their self-check; keeping the current code')
        return False

    def reexec(self):
        log('supervisor scripts changed and passed their self-check; re-executing')
        sys.stdout.flush()
        sys.stderr.flush()
        os.execv(sys.executable, [sys.executable, str(SCRIPTS / 'session-managed.py'), '_supervise'])

    def check_quiet(self):
        if any(slot.live() or slot.wanted for slot in self.slots.values()):
            self.quiet_since = None
            return None
        moment = time.monotonic()
        if self.quiet_since is None:
            self.quiet_since = moment
        if moment - self.quiet_since < self.quiet_seconds:
            return None
        log(f'no host and no work for {self.quiet_seconds:g}s; checking for new requests before exiting')
        with lock(self.login / 'served.lock'):
            served = served_record(self.login)
            gone = [kdir for kdir in served['stores'] if not Path(kdir).is_dir()]
            if gone:
                for kdir in gone:
                    del served['stores'][kdir]
                atomic(self.login / 'served.json', served)
            for kdir, entry in served['stores'].items():
                slot = self.slot(kdir)
                if slot.live() or held(slot.directory / 'runtime.lock') or self.launch_reason(slot, entry):
                    self.quiet_since = None
                    return None
            log(f'supervisor {os.getpid()} exiting')
            # Released before served.lock, so an ensure() that waited on served.lock starts a new supervisor.
            self.lock_stream.close()
            return 0


def supervise(args=None):
    """Run the login's supervisor until no store has had a host or work for the quiet period."""
    login = RUNTIME.login_dir()
    login.mkdir(parents=True, exist_ok=True)
    stream = (login / 'supervisor.lock').open('a+')
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        stream.close()
        log(f'supervisor {os.getpid()}: another supervisor holds {login / "supervisor.lock"}; exiting')
        return 0
    return Supervisor(stream).run()


def self_check():
    """What a changed supervisor script must survive before the running supervisor re-executes it."""
    sample = Path(tempfile.gettempdir()) / 'lore-session-self-check-store'
    RUNTIME.store_host_key(sample)
    RUNTIME.child_environment({'PATH': os.defpath, 'CLAUDECODE': '1'}, sample, True)
    served_record(RUNTIME.login_dir())
    store_work(sample)
    if not callable(getattr(Supervisor, 'run', None)) or not callable(supervise):
        raise RuntimeError('supervisor entry point is missing')
    print(json.dumps({'self_check': 'ok'}))
    return 0


def manifest_path(kdir, handle):
    if not MANIFEST_HANDLE.fullmatch(handle):
        raise RuntimeError('invalid managed session handle')
    return kdir / '_sessions/managed' / (handle + '.json')


def owner(kdir, manifest):
    status = serving_host(kdir, current_manifest(kdir, manifest))
    if not status:
        return None
    instance = read(kdir / '_sessions/instances' / (status['instance_name'] + '.json'), {})
    for session in instance.get('sessions', []):
        if session.get('slug') == manifest['handle']:
            return dict(session, instance_name=status['instance_name'])
    return None


def disposition(kdir, handle):
    history = events(kdir, handle)
    outcomes = [r for r in history if r.get('event') in {'worktree_no_changes', 'worktree_published', 'worktree_quarantined', 'restore_refused'}]
    latest = outcomes[-1] if outcomes else {}
    outcome = latest.get('event', 'pending')
    links = latest.get('links', {})
    closed = any(r.get('event') == 'closed' for r in history)
    manifest = read(manifest_path(kdir, handle), {})
    cleanup = read(host_dir(kdir, manifest.get('host_key', 'unknown')) / 'cleanup' / (handle + '.json'), {})
    cleaned = closed and cleanup.get('cleaned') is True
    # A retained receipt is settled: the host left the checkout on disk because
    # its content is not proven preserved, and no later pass will reclaim it
    # until someone preserves or discards that content.
    retained = cleanup.get('retained') if closed and not cleaned else None
    worktree_path = links.get('worktree_path')
    if closed and not cleaned and worktree_path and not Path(worktree_path).exists():
        source = manifest.get('source_dir')
        if source:
            try:
                registry = run(['git', '-C', source, 'worktree', 'list', '--porcelain'])
                cleaned = ('worktree ' + worktree_path) not in registry.splitlines()
            except (RuntimeError, OSError):
                pass
    return dict(worktree_outcome=outcome, result_ref=links.get('result_ref'),
                result_oid=links.get('result_oid'), patch_path=links.get('patch_path'),
                destination_path=links.get('destination_path'),
                cleanup_confirmed=cleaned,
                cleanup_retained=retained or None,
                integrated=outcome == 'worktree_published',
                composition_judgment_required=outcome in {'worktree_quarantined', 'restore_refused'},
                reason=latest.get('reason'))


def cleanup_settled(disposition):
    return disposition['cleanup_confirmed'] or bool(disposition.get('cleanup_retained'))


def inspect(kdir, manifest):
    history = events(kdir, manifest['handle'])
    result = dict(manifest)
    result['owner'] = owner(kdir, manifest)
    result['events'] = history
    for row in history:
        event = row.get('event')
        if event in TERMINAL:
            result['state'] = event
        elif event in {'spawned', 'recovered'}:
            result['state'] = 'recovering'
    if result['owner'] and result['state'] not in TERMINAL:
        result['state'] = 'running'
    result['disposition'] = disposition(kdir, manifest['handle'])
    result['receipts'] = [read(p) for p in sorted((kdir / '_sessions/receipts' / manifest['handle']).glob('*.json'))]
    return result


def receipt(kdir, manifest, rid, operation, outcome, **fields):
    with lock(kdir / '_sessions/receipt-locks' / (rid + '.lock')):
        return write_receipt(kdir, manifest, rid, operation, outcome, **fields)


def write_receipt(kdir, manifest, rid, operation, outcome, **fields):
    row = dict(handle=manifest['handle'], request_id=rid, operation=operation,
               outcome=outcome, outcome_confirmed=outcome != 'uncertain', at=now(), **fields)
    if outcome == 'uncertain' and fields.get('event', {}).get('reason') == 'delivery-uncertain':
        row['terminal_evidence'] = True
    if operation == 'close':
        row['disposition'] = disposition(kdir, manifest['handle'])
    path = kdir / '_sessions/receipts' / manifest['handle'] / (rid + '.json')
    previous = read(path, {})
    if outcome == 'uncertain' and (previous.get('outcome_confirmed') or previous.get('terminal_evidence')):
        return previous
    if outcome == 'uncertain' and 'request' not in row:
        if previous.get('request'):
            row['request'] = previous['request']
    atomic(path, row)
    return row


def enqueue_start(kdir, manifest, status=None):
    key, source = manifest['host_key'], manifest['source_dir']
    path = manifest_path(kdir, manifest['handle'])
    rid = manifest['request_id']
    existing = any(p.exists() for p in [kdir / '_sessions/requests/pending' / (rid + '.json')])
    existing = existing or any(row.get('request_id') == rid for row in events(kdir))
    existing = existing or any(p.name.startswith(rid) for p in (kdir / '_sessions/requests').rglob('*') if p.is_file())
    if not existing:
        if status is None:
            ensure(kdir)
        with lock(host_dir(kdir, key) / 'ensure.lock'):
            current = serving_host(kdir, manifest)
            if not current:
                raise RuntimeError('host withdrew readiness; retry the same start key')
            status = require_capabilities(current)
            with lock(kdir / '_sessions/source-locks' / (manifest['work_item'] + '.lock')):
                meta_path = kdir / '_work' / manifest['work_item'] / '_meta.json'
                meta = read(meta_path, {})
                declared = meta.get('source_checkout')
                if declared and str(Path(declared).resolve()) != source:
                    manifest['state'] = 'refused'
                    manifest['error'] = 'work item source checkout differs from --workspace; declaration was not changed'
                    atomic(path, manifest)
                    raise RuntimeError(manifest['error'])
                if not declared:
                    run(['bash', SCRIPTS / 'set-work-meta.sh', manifest['work_item'], '--seed-source-checkout',
                         '--from-instance', status['instance_name'], '--json'],
                        cwd=source, env=subprocess_env(LORE_KNOWLEDGE_DIR=str(kdir)))
            context_path = path.with_suffix('.context')
            atomic(context_path, {'dispatch_guidance': manifest['context']})
            manifest['state'] = 'enqueueing'
            atomic(path, manifest)
            # A store host claims every row carrying its key, so its rows need no name
            # pin, which would strand them if the host restarted under a new name.
            placement = ['--anywhere'] if status.get('scope') == 'store' else ['--target', status['instance_name']]
            run(['bash', SCRIPTS / 'session-request.sh', '--type', 'worker', '--slug', manifest['handle'],
                 *placement, '--session-route', json.dumps(manifest['route'], separators=(',', ':')),
                 '--context', context_path, '--initiator', 'agent', '--auto-close', 'true', '--yes', '--kdir', kdir,
                 '--request-id', rid, '--host-key', key, '--json',
                 *(['--packet', manifest['packet']] if manifest.get('packet') else [])], cwd=source)
    manifest['state'] = 'enqueued'
    atomic(path, manifest)


def start(args, kdir):
    source = str(Path(args.workspace or os.environ.get('LORE_SESSION_SOURCE_DIR') or os.getcwd()).resolve(strict=True))
    if not Path(source).is_dir():
        raise RuntimeError('--workspace must be a directory')
    if resolve(source) != kdir:
        raise RuntimeError('workspace resolves to a different knowledge store')
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', args.handle):
        raise RuntimeError('invalid work item slug')
    meta = read(kdir / '_work' / args.handle / '_meta.json')
    if meta is None:
        raise RuntimeError('work item does not exist')
    if meta.get('source_checkout') and str(Path(meta['source_checkout']).resolve()) != source:
        raise RuntimeError('work item source checkout differs from --workspace; declaration was not changed')
    context = Path(args.context).read_bytes().decode('utf-8')
    if '\x00' in context:
        raise RuntimeError('context must not contain NUL bytes')
    route = canonical_start_route(args, source)
    intent = dict(work_item=args.handle, source_dir=source, route=route,
                  framework=route['framework'], model=route['model'], routing_source=route['routing_source']['layer'],
                  context=context, packet=getattr(args, 'packet', None))
    key = RUNTIME.store_host_key(kdir)
    with lock(kdir / '_sessions/managed.lock'):
        index_path = kdir / '_sessions/start-keys.json'
        index = read(index_path, {})
        token = hashlib.sha256(args.key.encode()).hexdigest() if args.key else None
        if token and token not in index:
            for path in (kdir / '_sessions/managed').glob('*.json'):
                saved = read(path, {})
                if saved.get('key_token') == token:
                    index[token] = saved['handle']
                    atomic(index_path, index)
                    break
        if token and token in index:
            manifest = read(manifest_path(kdir, index[token]))
            if getattr(args, 'session_route', None) is None and args.framework is None and args.model is None:
                # An absent-override retry means "the same managed start", not
                # "reselect from today's settings". Current settings were
                # validated above; preserve the route frozen in the intent.
                for field in ('route', 'framework', 'model', 'routing_source'):
                    intent[field] = manifest[field]
            if any(manifest.get(k) != v for k, v in intent.items()):
                raise RuntimeError('idempotency key already names a different start intent')
        else:
            handle = args.handle + '--w' + str(secrets.randbits(128))
            while manifest_path(kdir, handle).exists():
                handle = args.handle + '--w' + str(secrets.randbits(128))
            manifest = dict(intent, schema_version=1, handle=handle, host_key=key, key_token=token,
                            request_id='managed-' + secrets.token_hex(16), state='intent', created_at=now())
            atomic(manifest_path(kdir, handle), manifest)
            if token:
                index[token] = handle
                atomic(index_path, index)
    with lock(kdir / '_sessions/managed' / (manifest['handle'] + '.lock')):
        manifest = read(manifest_path(kdir, manifest['handle']))
        if manifest['state'] in {'intent', 'enqueueing'}:
            enqueue_start(kdir, manifest)
    if not any(row.get('event') in TERMINAL for row in events(kdir, manifest['handle'])):
        ensure(kdir)
    result = await_outcome(kdir, manifest, manifest['request_id'], 'start', args.timeout)
    result['session_state'] = inspect(kdir, manifest)['state']
    return result


def publish_operation(kdir, manifest, operation, row):
    """Publish persisted intent only when durable evidence proves no input attempt."""
    rid = row['request_id']
    with lock(kdir / '_sessions/operation-locks' / (rid + '.lock')):
        manifest = current_manifest(kdir, manifest)
        ledger = host_dir(kdir, manifest['host_key']) / 'deliveries' / (rid + '.json')
        queue = kdir / '_sessions' / (operation + '-requests') / (rid + '.json')
        if ledger.exists() or queue.exists():
            return
        history = events(kdir, manifest['handle'])
        if any(e.get('request_id') == rid and e.get('event') in {
                'sent', 'send_refused', 'answered', 'answer_refused', 'closed', 'close_failed'} for e in history):
            return
        live = owner(kdir, manifest)
        if not live:
            return
        row = dict(row, target_instance=live['instance_name'])
        atomic(queue, row)


def reconcile_operations(kdir, key):
    for path in (kdir / '_sessions/managed').glob('*.json'):
        manifest = read(path, {})
        if manifest.get('host_key') != key:
            continue
        for receipt_path in (kdir / '_sessions/receipts' / manifest['handle']).glob('*.json'):
            saved = read(receipt_path, {})
            if saved.get('outcome') != 'uncertain' or saved.get('terminal_evidence') or not saved.get('request'):
                continue
            operation = saved['operation']
            if operation not in {'send', 'answer', 'close', 'peek'}:
                continue
            try:
                if operation == 'peek':
                    response = kdir / '_sessions/peek-responses' / (saved['request_id'] + '.json')
                    data = read(response)
                    if data is not None:
                        from coordinate_watch_state import observation
                        data['observation'] = observation(data, kdir=kdir)
                        receipt(kdir, manifest, saved['request_id'], operation, 'observed', response=data)
                        continue
                else:
                    history = events(kdir, manifest['handle'])
                    if any(r.get('request_id') == saved['request_id'] and r.get('event') in {
                            'sent', 'send_refused', 'answered', 'answer_refused', 'closed', 'close_failed'}
                           or r.get('event') == 'closed' and saved['request_id'] in r.get('links', {}).get('close_requests', '')
                           for r in history):
                        await_outcome(kdir, manifest, saved['request_id'], operation, 0)
                        continue
                publish_operation(kdir, manifest, operation, saved['request'])
            except (RuntimeError, OSError) as error:
                print(f'operation reconciliation: {error}', flush=True)


def await_outcome(kdir, manifest, rid, operation, timeout):
    deadline = time.monotonic() + timeout
    terminals = {'start': {'spawned', 'recovered', 'request_expired', 'request_cancelled', 'request_abandoned', 'orphaned'},
                 'send': {'sent', 'send_refused', 'send_uncertain'},
                 'answer': {'answered', 'answer_refused', 'answer_uncertain'},
                 'close': {'closed', 'close_failed', 'close_refused', 'close_uncertain'}}[operation]
    while True:
        for row in reversed(events(kdir, manifest['handle'])):
            close_ids = row.get('links', {}).get('close_requests', '[]')
            if isinstance(close_ids, str):
                try:
                    close_ids = json.loads(close_ids)
                except ValueError:
                    close_ids = []
            matches = row.get('request_id') == rid or rid in (close_ids or []) or rid in row.get('close_request_ids', [])
            if matches and row.get('event') in terminals:
                event = row['event']
                if operation == 'close' and event == 'closed' and not cleanup_settled(disposition(kdir, manifest['handle'])):
                    continue
                outcome = 'uncertain' if event.endswith('_uncertain') or row.get('reason') == 'delivery-uncertain' else event
                return receipt(kdir, manifest, rid, operation, outcome, event=row)
        if time.monotonic() >= deadline:
            return receipt(kdir, manifest, rid, operation, 'uncertain', detail='The operation has not reached a confirmed outcome before the timeout; inspect retains available evidence. Do not infer delivery or retry ambiguous input.')
        time.sleep(.15)


def operate(args, kdir, manifest):
    deadline = time.monotonic() + args.timeout
    while True:
        args.timeout = max(0, deadline - time.monotonic())
        result = operate_attempt(args, kdir, manifest)
        if not result.pop('_retry_send', False):
            return result


def operate_attempt(args, kdir, manifest):
    if args.verb == 'inspect':
        return inspect(kdir, manifest)
    current = inspect(kdir, manifest)
    if current['state'] in TERMINAL:
        if args.verb in {'wait', 'close'}:
            if args.verb == 'close' and current['state'] == 'closed' and not cleanup_settled(current['disposition']):
                ensure(kdir)
                deadline = time.monotonic() + args.timeout
                while time.monotonic() < deadline:
                    current = inspect(kdir, manifest)
                    if cleanup_settled(current['disposition']):
                        return current
                    time.sleep(.15)
                current.update(outcome='uncertain', outcome_confirmed=False)
            return current
        raise RuntimeError('session has ended; no live screen is available; inspect retains durable state')
    ensure(kdir)
    deadline = time.monotonic() + args.timeout
    live = owner(kdir, manifest)
    while not live and time.monotonic() < deadline:
        time.sleep(.15)
        live = owner(kdir, manifest)
    if not live:
        raise RuntimeError('current session ownership is not established; inspect retains durable state')
    if args.verb == 'attach':
        if not live.get('tmux'):
            raise RuntimeError('session has no surviving tmux terminal to attach')
        os.execvpe('tmux', ['tmux', '-L', RUNTIME.tmux_server(), 'attach-session', '-t', live['tmux']],
                   attach_environment())
    if args.verb == 'wait':
        path = kdir / '_sessions/managed' / (manifest['handle'] + '.wait.json')
        with lock(path.with_suffix('.lock')):
            seen = set(read(path, {}).get('seen', []))
            # A park row that corroborates a park already reported, a superseded
            # park, or a hook park of another generation is no new park; it is
            # recorded as seen and never returned.
            from coordinate_watch_state import lifecycle_verdict
            skipped = set()
            while True:
                history = events(kdir, manifest['handle'])
                wanted = set((args.until or 'terminus_reached,needs_input,modal_blocked,closed,request_expired,request_cancelled,request_abandoned,orphaned,close_failed').split(','))
                cache = {}
                matches = []
                for r in history:
                    if r.get('event') not in wanted or r.get('event_id') in seen or r.get('event_id') in skipped:
                        continue
                    if (lifecycle_verdict(kdir, r, cache=cache) or {}).get('skip') and r.get('event_id'):
                        skipped.add(r['event_id'])
                        continue
                    matches.append(r)
                if matches:
                    seen.update(r.get('event_id') for r in matches)
                    seen.update(skipped)
                    atomic(path, {'seen': list(seen)})
                    return {'handle': manifest['handle'], 'events': matches, 'outcome': 'observed', 'outcome_confirmed': True}
                if time.monotonic() >= deadline:
                    return {'handle': manifest['handle'], 'outcome': 'uncertain', 'outcome_confirmed': False}
                time.sleep(.15)
    rid = 'managed-' + secrets.token_hex(16)
    row = dict(request_id=rid, slug=manifest['handle'], target_instance=live['instance_name'],
               requested_by=args.requested_by or os.environ.get('LORE_SESSION_SLUG', 'managed-cli'), requested_at=now())
    if args.verb == 'send':
        body = args.message if args.message is not None else args.text
        if not body:
            raise RuntimeError('send requires a nonempty message')
        row['body'] = body
    elif args.verb == 'answer':
        if not args.option or args.option < 1 or not args.expect:
            raise RuntimeError('answer requires --option N and --expect literal')
        row.update(option=args.option, expect=args.expect)
        if args.registration_id:
            row['registration_id'] = args.registration_id
    elif args.verb == 'close':
        from session_target import generation
        target_generation = generation(live)
        if args.generation and args.generation != target_generation:
            raise RuntimeError('generation mismatch: live type=' + str(live.get('type')) + ' generation=' + target_generation)
        row.update(generation=target_generation, session_type=live.get('type', ''), session_id=live.get('session_id', ''))
        row['reason'] = args.reason or 'coordinator'
    elif args.verb == 'peek':
        row.update(raw=args.raw, summary=args.summary, lines=args.lines, before=args.before, max_bytes=args.max_bytes)
    receipt(kdir, manifest, rid, args.verb, 'uncertain', detail='Intent persisted; operation outcome pending.', request=row)
    publish_operation(kdir, manifest, args.verb, row)
    if args.verb == 'peek':
        response = kdir / '_sessions/peek-responses' / (rid + '.json')
        while time.monotonic() < deadline:
            data = read(response)
            if data is not None:
                from coordinate_watch_state import observation
                data['observation'] = observation(data, kdir=kdir)
                if args.summary:
                    data = {key: value for key, value in data.items() if key not in {'rows', 'ansi', 'history', 'screen'}}
                    data['summary'] = True
                if (args.lines or args.before or args.max_bytes) and 'history' not in data and not data.get('error'):
                    data['error'] = 'history-unsupported-by-host'
                result = receipt(kdir, manifest, rid, 'peek', 'peek_failed' if data.get('error') else 'observed', response=data)
                response.unlink(missing_ok=True)
                return result
            time.sleep(.1)
        return receipt(kdir, manifest, rid, 'peek', 'uncertain')
    event = dict(event=args.verb + '_requested', request_id=rid, slug=manifest['handle'], target_instance=live['instance_name'])
    if args.verb == 'answer':
        event['option'] = args.option
    append(kdir, event)
    result = await_outcome(kdir, manifest, rid, args.verb, max(0, deadline - time.monotonic()))
    if (args.verb == 'send' and result['outcome'] == 'send_refused'
            and result.get('event', {}).get('reason') in {'no-signature', 'generating'}
            and time.monotonic() + .3 < deadline):
        time.sleep(.25)
        result['_retry_send'] = True
        return result
    return result


REQUEST_VALUE_FLAGS = frozenset({
    '--type', '--slug', '--target', '--initiator', '--auto-close', '--requested-by', '--context', '--packet',
    '--position', '--route', '--session-route', '--min-vintage', '--track', '--model', '--framework',
    '--routing-source', '--worktree-identity', '--worktree-id', '--execution-dir', '--prefer-dir', '--request-id',
    '--host-key', '--kdir', '--store-host-unavailable'})
LEGACY_ENSURE_SECONDS = 10
INSTANCE_LIVENESS_SECONDS = 30


def request_options(argv):
    """The session-request.sh options this entry routes on; the writer parses the rest."""
    options, index = {}, 0
    while index < len(argv):
        if argv[index] in REQUEST_VALUE_FLAGS:
            options[argv[index]] = argv[index + 1] if index + 1 < len(argv) else ''
            index += 2
        else:
            options[argv[index]] = True
            index += 1
    return options


def request_names_checkout(kdir, options):
    """Whether the writer will place this request in a checkout: a work item that
    declares an existing one, or an explicit preference. A targeted request names
    an instance instead and keeps its unkeyed path."""
    if '--target' in options:
        return False
    slug = options.get('--slug') or ''
    if slug:
        worker = re.fullmatch(r'(.+)--w[0-9]+', slug)
        item = worker.group(1) if worker else slug
        for meta in (kdir / '_work' / item / '_meta.json', kdir / '_work/_archive' / item / '_meta.json'):
            if meta.is_file():
                declared = read_quiet(meta, {}).get('source_checkout')
                return bool(declared) and Path(declared).is_dir()
    return '--prefer-dir' in options or '--prefer-cwd' in options


def request(argv):
    """lore session request: send a request that names a checkout to the store's
    session host, ensured first, with the writer run under the host's ensure.lock
    so the host cannot withdraw before the row lands. Any other request keeps the
    unkeyed path a visible lore-tui claims."""
    writer = ['bash', str(SCRIPTS / 'session-request.sh')]
    options = request_options(argv)
    if options.keys() & {'-h', '--help', '--host-key', '--request-id', '--store-host-unavailable'}:
        os.execv('/bin/bash', [*writer, *argv])
    try:
        kdir = Path(options['--kdir']).resolve() if options.get('--kdir') else resolve()
    except RuntimeError:
        os.execv('/bin/bash', [*writer, *argv])
    if not request_names_checkout(kdir, options):
        os.execv('/bin/bash', [*writer, *argv])
    argv = [*argv, '--kdir', str(kdir)]
    key = RUNTIME.store_host_key(kdir)
    unavailable = 'the store host withdrew its readiness each time the request was about to be written'
    for _ in range(3):
        try:
            ensure(kdir)
        except (RuntimeError, OSError) as error:
            unavailable = str(error)
            break
        with lock(host_dir(kdir, key) / 'ensure.lock'):
            if ready(kdir, key):
                return subprocess.call([*writer, *argv, '--host-key', key])
    return subprocess.call([*writer, *argv, '--store-host-unavailable', unavailable])


def live_owner(kdir, handle):
    """The live registry row that lists a session, by name."""
    slug = 'chat-' + handle[len('chat:'):] if handle.startswith('chat:') else handle
    now = time.time()
    for path in sorted((Path(kdir) / '_sessions/instances').glob('*.json')):
        try:
            if now - path.stat().st_mtime > INSTANCE_LIVENESS_SECONDS:
                continue
        except OSError:
            continue
        row = read_quiet(path, {})
        if any(isinstance(s, dict) and s.get('slug') == slug for s in row.get('sessions') or []):
            return row.get('name') or path.stem
    return None


def ensure_for_unowned_session(kdir, handle):
    """A session no live host lists may be one the store host would adopt or claim,
    so bring that host up, for a bounded wait, before the enqueue-only verb runs."""
    if not handle or handle.startswith('-') or live_owner(kdir, handle):
        return
    try:
        ensure(kdir, timeout=LEGACY_ENSURE_SECONDS)
    except (RuntimeError, OSError):
        pass


def source_owner(kdir, handle):
    """The instance that hosts a session now, for seeding its work item's checkout."""
    try:
        manifest = read(manifest_path(kdir, handle))
    except RuntimeError:
        manifest = None
    if manifest:
        status = ensure(kdir)
        return (serving_host(kdir, current_manifest(kdir, manifest)) or status)['instance_name']
    return live_owner(kdir, handle) or ensure(kdir)['instance_name']


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    RUNTIME.runtime_name()
    if argv[:1] == ['request']:
        return request(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('verb', choices=['start', 'inspect', 'attach', 'send', 'answer', 'peek', 'close', 'wait',
                                         '_supervise', '_self-check', '_source-owner'])
    parser.add_argument('handle', nargs='?')
    parser.add_argument('text', nargs='?')
    parser.add_argument('--kdir')
    parser.add_argument('--workspace')
    parser.add_argument('--framework', choices=['codex', 'claude-code', 'opencode'])
    parser.add_argument('--model')
    parser.add_argument('--session-route')
    parser.add_argument('--context')
    parser.add_argument('--key')
    parser.add_argument('--packet')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--timeout', type=float, default=45)
    parser.add_argument('--self', action='store_true')
    parser.add_argument('--message')
    parser.add_argument('--option', type=int)
    parser.add_argument('--expect')
    parser.add_argument('--registration-id')
    parser.add_argument('--reason')
    parser.add_argument('--requested-by')
    parser.add_argument('--generation')
    parser.add_argument('--raw', action='store_true')
    parser.add_argument('--summary', action='store_true')
    parser.add_argument('--lines', type=int, default=0)
    parser.add_argument('--before', default='')
    parser.add_argument('--max-bytes', type=int, default=0)
    parser.add_argument('--wait', action='store_true')
    parser.add_argument('--until')
    parser.add_argument('--host-key')
    parser.add_argument('--binary')
    verb = argv[0] if argv else ''
    if verb in {'send', 'answer', 'peek', 'close', 'wait'}:
        if '--help' in argv or '-h' in argv:
            os.execv('/bin/bash', ['bash', str(SCRIPTS / ('session-' + verb + '.sh')), *argv[1:]])
        karg = argv[argv.index('--kdir') + 1] if '--kdir' in argv else None
        kdir = Path(karg).resolve() if karg else resolve()
        handle = os.environ.get('LORE_SESSION_SLUG', '') if '--self' in argv else (argv[1] if len(argv) > 1 else '')
        try:
            managed = manifest_path(kdir, handle).is_file()
        except RuntimeError:
            managed = False
        if not managed:
            ensure_for_unowned_session(kdir, handle)
            os.execv('/bin/bash', ['bash', str(SCRIPTS / ('session-' + verb + '.sh')), *argv[1:]])
    args = parser.parse_args(argv)
    if (any(arg == '--lines' or arg.startswith('--lines=') for arg in argv) and args.lines < 1) or (any(arg == '--max-bytes' or arg.startswith('--max-bytes=') for arg in argv) and args.max_bytes < 1):
        parser.error('history limits must be positive')
    if args.summary and (args.raw or args.lines or args.before or args.max_bytes):
        parser.error('--summary cannot combine with --raw or history options')
    if not 0 <= args.lines <= 500 or not 0 <= args.max_bytes <= 16384 or len(args.before) > 512:
        parser.error('history limits exceed 500 rows or 16384 bytes, or cursor is invalid')
    if args.verb == '_supervise':
        return supervise(args)
    if args.verb == '_self-check':
        return self_check()
    if args.timeout < 0:
        parser.error('--timeout must be nonnegative')
    kdir = Path(args.kdir).resolve() if args.kdir else resolve(args.workspace)
    if args.self:
        args.handle = os.environ.get('LORE_SESSION_SLUG')
    if args.verb == 'start':
        if not all([args.handle, args.context]):
            parser.error('start requires work item and --context FILE (--framework/--model resolve from the worker route when omitted)')
        result = start(args, kdir)
    else:
        if not args.handle:
            parser.error('a session handle is required')
        if args.verb == '_source-owner':
            print(source_owner(kdir, args.handle))
            return 0
        manifest = read(manifest_path(kdir, args.handle))
        if not manifest:
            raise RuntimeError('unknown managed session handle')
        result = operate(args, kdir, manifest)
    if args.json or args.verb == 'inspect':
        print(json.dumps(result))
    else:
        print(f"{result.get('handle', args.handle)}: {result.get('outcome', result.get('state', 'observed'))}")
        if args.verb == 'peek':
            response = result.get('response', {})
            history = response.get('history', {})
            if not args.summary:
                print(history.get('ansi', response.get('ansi', '')) if args.raw else '\n'.join(history.get('rows', response.get('rows', []))))
            if history:
                print(json.dumps({key: value for key, value in history.items() if key not in {'rows', 'ansi'}}))
            if response.get('modal'):
                print(json.dumps(response['modal']))
            if response.get('error'):
                print(response['error'], file=sys.stderr)
            from coordinate_watch_state import peek_summary
            print(peek_summary(result.get('response', {})))
        if result.get('request_id'):
            print('request: ' + result['request_id'])
        if args.verb == 'close' and result.get('disposition'):
            disposition = result['disposition']
            print('result: ' + disposition['worktree_outcome'])
            if disposition['cleanup_confirmed']:
                print('cleanup: confirmed')
            elif disposition.get('cleanup_retained'):
                print('cleanup: retained — ' + disposition['cleanup_retained'])
            else:
                print('cleanup: pending')
            if disposition.get('result_ref'):
                print('retained result: ' + disposition['result_ref'])
            if disposition['composition_judgment_required']:
                print('Integration judgment required.')
    return 1 if result.get('response', {}).get('error') or result.get('outcome') == 'uncertain' else (3 if result.get('outcome', '').endswith(('_refused', '_failed', '_expired', '_cancelled')) else 0)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(json.dumps({'error': str(error), 'outcome_confirmed': False}) if '--json' in sys.argv else f'session: {error}', file=sys.stdout if '--json' in sys.argv else sys.stderr)
        sys.exit(1)
