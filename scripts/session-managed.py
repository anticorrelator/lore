#!/usr/bin/env python3
"""On-demand, durable session administration over the existing session substrate."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time

SCRIPTS = Path(__file__).resolve().parent
WARNED_CORRUPTION = set()
EVENT_CACHE = {}
TERMINAL = {'closed', 'request_cancelled', 'request_expired', 'request_abandoned', 'orphaned'}


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


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


def run(argv, **kwargs):
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
    return kdir / '_sessions/hosts' / key


def ready(kdir, key, source):
    directory = host_dir(kdir, key)
    data = read(directory / 'ready.json', {})
    if (not data.get('ready') or data.get('host_key') != key
            or data.get('source_dir') != source or data.get('knowledge_dir') != str(kdir)
            or not held(directory / 'runtime.lock')):
        return None
    try:
        os.kill(data['pid'], 0)
    except (ProcessLookupError, KeyError):
        return None
    registry = read(kdir / '_sessions/instances' / (data['instance_name'] + '.json'), {})
    if registry.get('host_key') != key or registry.get('role') != 'session-host':
        return None
    return data


def binary(kdir):
    override = os.environ.get('LORE_SESSION_HOST_BINARY')
    if override:
        path = Path(override).resolve(strict=True)
        if not os.access(path, os.X_OK):
            raise RuntimeError(f'host binary is not executable: {path}')
        return path
    tui = SCRIPTS.parent / 'tui'
    fingerprint = hashlib.sha256()
    for path in sorted(tui.rglob('*')):
        if path.is_file() and (path.suffix in {'.go', '.mod', '.sum', '.a', '.h'} or path.name == 'pkg-config-shim.sh'):
            stat = path.stat()
            fingerprint.update(f'{path}:{stat.st_mtime_ns}:{stat.st_size}'.encode())
    fingerprint.update(os.environ.get('LORE_TUI_BUILD_TAGS', '').encode())
    output = kdir / '_sessions/bin' / ('lore-session-host-' + fingerprint.hexdigest()[:24])
    with lock(output.parent / 'build.lock'):
        if not output.exists():
            env = dict(os.environ, CGO_ENABLED='1', PKG_CONFIG=str(tui / 'internal/work/libghostty/pkg-config-shim.sh'))
            args = ['go', 'build']
            if env.get('LORE_TUI_BUILD_TAGS'):
                args += ['-tags', env['LORE_TUI_BUILD_TAGS']]
            args += ['-o', str(output) + '.tmp', '.']
            run(args, cwd=tui, env=env)
            os.replace(str(output) + '.tmp', output)
    return output


def ensure(kdir, key, source, timeout=45):
    directory = host_dir(kdir, key)
    deadline = time.monotonic() + timeout
    while True:
        with lock(directory / 'ensure.lock'):
            status = ready(kdir, key, source)
            if not held(directory / 'supervisor.lock'):
                executable = binary(kdir)
                directory.mkdir(parents=True, exist_ok=True)
                with (directory / 'host.log').open('ab') as log:
                    subprocess.Popen([sys.executable, str(SCRIPTS / 'session-managed.py'), '_supervise',
                                      '--kdir', str(kdir), '--host-key', key, '--workspace', source,
                                      '--binary', str(executable)], stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log, start_new_session=True, close_fds=True)
            if status:
                return status
        if time.monotonic() >= deadline:
            raise RuntimeError(f'host readiness timed out; durable intent retained; see {directory / "host.log"}')
        time.sleep(.1)


def supervise(args):
    kdir = Path(args.kdir).resolve()
    directory = host_dir(kdir, args.host_key)
    try:
        with lock(directory / 'supervisor.lock', False):
            atomic(directory / 'supervisor.json', {'pid': os.getpid(), 'host_key': args.host_key, 'started_at': now()})
            for attempt in range(6):
                while held(directory / 'runtime.lock'):
                    time.sleep(.2)
                process = subprocess.Popen([args.binary, '--session-host', '--host-key', args.host_key,
                                         '--kdir', str(kdir), '--source-dir', args.workspace,
                                         '--ready-file', str(directory / 'ready.json'),
                                         '--idle-timeout', os.environ.get('LORE_SESSION_HOST_IDLE_TIMEOUT', '30')],
                                        stdin=subprocess.DEVNULL)
                while process.poll() is None:
                    if ready(kdir, args.host_key, args.workspace):
                        for path in (kdir / '_sessions/managed').glob('*.json'):
                            manifest = read(path, {})
                            if manifest.get('host_key') != args.host_key or manifest.get('state') not in {'intent', 'enqueueing'}:
                                continue
                            try:
                                with lock(path.with_suffix('.lock'), False):
                                    manifest = read(path)
                                    if manifest['state'] in {'intent', 'enqueueing'}:
                                        enqueue_start(kdir, manifest)
                            except BlockingIOError:
                                pass
                            except (RuntimeError, OSError) as error:
                                print(f'intent reconciliation: {error}', flush=True)
                    reconcile_operations(kdir, args.host_key)
                    time.sleep(.2)
                if process.returncode == 0:
                    return 0
                time.sleep(min(2 ** attempt * .2, 5))
            atomic(directory / 'supervisor-error.json', {'at': now(), 'error': 'host restart budget exhausted'})
            return 1
    except BlockingIOError:
        return 0


def manifest_path(kdir, handle):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*--w[0-9]+', handle):
        raise RuntimeError('invalid managed session handle')
    return kdir / '_sessions/managed' / (handle + '.json')


def owner(kdir, manifest):
    status = ready(kdir, manifest['host_key'], manifest['source_dir'])
    if not status:
        return None
    instance = read(kdir / '_sessions/instances' / (status['instance_name'] + '.json'), {})
    for session in instance.get('sessions', []):
        if session.get('slug') == manifest['handle']:
            return dict(session, instance_name=status['instance_name'])
    return None


def disposition(kdir, handle):
    history = events(kdir, handle)
    outcomes = [r for r in history if r.get('event') in {'worktree_published', 'worktree_quarantined', 'restore_refused'}]
    latest = outcomes[-1] if outcomes else {}
    outcome = latest.get('event', 'pending')
    links = latest.get('links', {})
    closed = any(r.get('event') == 'closed' for r in history)
    manifest = read(manifest_path(kdir, handle), {})
    cleanup = read(host_dir(kdir, manifest.get('host_key', 'unknown')) / 'cleanup' / (handle + '.json'), {})
    cleaned = closed and cleanup.get('cleaned') is True
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
                integrated=outcome == 'worktree_published',
                composition_judgment_required=outcome in {'worktree_quarantined', 'restore_refused'},
                reason=latest.get('reason'))


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


def enqueue_start(kdir, manifest):
    key, source = manifest['host_key'], manifest['source_dir']
    path = manifest_path(kdir, manifest['handle'])
    rid = manifest['request_id']
    existing = any(p.exists() for p in [kdir / '_sessions/requests/pending' / (rid + '.json')])
    existing = existing or any(row.get('request_id') == rid for row in events(kdir))
    existing = existing or any(p.name.startswith(rid) for p in (kdir / '_sessions/requests').rglob('*') if p.is_file())
    if not existing:
        status = ensure(kdir, key, source)
        with lock(host_dir(kdir, key) / 'ensure.lock'):
            if not ready(kdir, key, source):
                raise RuntimeError('host withdrew readiness; retry the same start key')
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
                        cwd=source, env=dict(os.environ, LORE_KNOWLEDGE_DIR=str(kdir)))
            context_path = path.with_suffix('.context')
            atomic(context_path, {'dispatch_guidance': manifest['context']})
            manifest['state'] = 'enqueueing'
            atomic(path, manifest)
            run(['bash', SCRIPTS / 'session-request.sh', '--type', 'worker', '--slug', manifest['handle'],
                 '--target', status['instance_name'], '--framework', manifest['framework'], '--model', manifest['model'],
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
    intent = dict(work_item=args.handle, source_dir=source, framework=args.framework, model=args.model, context=context, packet=getattr(args, 'packet', None))
    key = hashlib.sha256((str(kdir) + '\0' + source).encode()).hexdigest()[:24]
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
        ensure(kdir, key, source)
    result = await_outcome(kdir, manifest, manifest['request_id'], 'start', args.timeout)
    result['session_state'] = inspect(kdir, manifest)['state']
    return result


def publish_operation(kdir, manifest, operation, row):
    """Publish persisted intent only when durable evidence proves no input attempt."""
    rid = row['request_id']
    with lock(kdir / '_sessions/operation-locks' / (rid + '.lock')):
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
                        data['observation'] = observation(data)
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
                if operation == 'close' and event == 'closed' and not disposition(kdir, manifest['handle'])['cleanup_confirmed']:
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
            if args.verb == 'close' and current['state'] == 'closed' and not current['disposition']['cleanup_confirmed']:
                ensure(kdir, manifest['host_key'], manifest['source_dir'])
                deadline = time.monotonic() + args.timeout
                while time.monotonic() < deadline:
                    current = inspect(kdir, manifest)
                    if current['disposition']['cleanup_confirmed']:
                        return current
                    time.sleep(.15)
                current.update(outcome='uncertain', outcome_confirmed=False)
            return current
        raise RuntimeError('session has ended; no live screen is available; inspect retains durable state')
    ensure(kdir, manifest['host_key'], manifest['source_dir'])
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
        os.execvp('tmux', ['tmux', '-L', 'lore-tui', 'attach-session', '-t', live['tmux']])
    if args.verb == 'wait':
        path = kdir / '_sessions/managed' / (manifest['handle'] + '.wait.json')
        with lock(path.with_suffix('.lock')):
            seen = set(read(path, {}).get('seen', []))
            while True:
                history = events(kdir, manifest['handle'])
                wanted = set((args.until or 'terminus_reached,needs_input,modal_blocked,closed,request_expired,request_cancelled,request_abandoned,orphaned,close_failed').split(','))
                matches = [r for r in history if r.get('event') in wanted and r.get('event_id') not in seen]
                if matches:
                    seen.update(r.get('event_id') for r in matches)
                    atomic(path, {'seen': list(seen)})
                    return {'handle': manifest['handle'], 'events': matches, 'outcome': 'observed', 'outcome_confirmed': True}
                if time.monotonic() >= deadline:
                    return {'handle': manifest['handle'], 'outcome': 'uncertain', 'outcome_confirmed': False}
                time.sleep(.15)
    rid = 'managed-' + secrets.token_hex(16)
    row = dict(request_id=rid, slug=manifest['handle'], target_instance=live['instance_name'],
               requested_by=os.environ.get('LORE_SESSION_SLUG', 'managed-cli'), requested_at=now())
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
        row['reason'] = args.reason or 'coordinator'
    elif args.verb == 'peek':
        row['raw'] = args.raw
    receipt(kdir, manifest, rid, args.verb, 'uncertain', detail='Intent persisted; operation outcome pending.', request=row)
    publish_operation(kdir, manifest, args.verb, row)
    if args.verb == 'peek':
        response = kdir / '_sessions/peek-responses' / (rid + '.json')
        while time.monotonic() < deadline:
            data = read(response)
            if data is not None:
                from coordinate_watch_state import observation
                data['observation'] = observation(data)
                result = receipt(kdir, manifest, rid, 'peek', 'observed', response=data)
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


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('verb', choices=['start', 'inspect', 'attach', 'send', 'answer', 'peek', 'close', 'wait', '_supervise', '_source-owner'])
    parser.add_argument('handle', nargs='?')
    parser.add_argument('text', nargs='?')
    parser.add_argument('--kdir')
    parser.add_argument('--workspace')
    parser.add_argument('--framework', choices=['codex', 'claude-code', 'opencode'])
    parser.add_argument('--model')
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
    parser.add_argument('--raw', action='store_true')
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
            os.execv('/bin/bash', ['bash', str(SCRIPTS / ('session-' + verb + '.sh')), *argv[1:]])
    args = parser.parse_args(argv)
    if args.verb == '_supervise':
        return supervise(args)
    if args.timeout < 0:
        parser.error('--timeout must be nonnegative')
    kdir = Path(args.kdir).resolve() if args.kdir else resolve(args.workspace)
    if args.self:
        args.handle = os.environ.get('LORE_SESSION_SLUG')
    if args.verb == 'start':
        if not all([args.handle, args.framework, args.model, args.context]):
            parser.error('start requires work item, --framework, --model, and --context FILE')
        result = start(args, kdir)
    else:
        if not args.handle:
            parser.error('a session handle is required')
        manifest = read(manifest_path(kdir, args.handle))
        if not manifest:
            raise RuntimeError('unknown managed session handle')
        if args.verb == '_source-owner':
            status = ensure(kdir, manifest['host_key'], manifest['source_dir'])
            print(status['instance_name'])
            return 0
        result = operate(args, kdir, manifest)
    if args.json or args.verb == 'inspect':
        print(json.dumps(result))
    else:
        print(f"{result.get('handle', args.handle)}: {result.get('outcome', result.get('state', 'observed'))}")
        if args.verb == 'peek':
            print('\n'.join(result.get('response', {}).get('rows', [])))
            from coordinate_watch_state import peek_summary
            print(peek_summary(result.get('response', {})))
        if result.get('request_id'):
            print('request: ' + result['request_id'])
        if args.verb == 'close' and result.get('disposition'):
            disposition = result['disposition']
            print('result: ' + disposition['worktree_outcome'])
            print('cleanup: ' + ('confirmed' if disposition['cleanup_confirmed'] else 'pending'))
            if disposition.get('result_ref'):
                print('retained result: ' + disposition['result_ref'])
            if disposition['composition_judgment_required']:
                print('Integration judgment required.')
    return 1 if result.get('outcome') == 'uncertain' else (3 if result.get('outcome', '').endswith(('_refused', '_failed', '_expired', '_cancelled')) else 0)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError) as error:
        print(json.dumps({'error': str(error), 'outcome_confirmed': False}) if '--json' in sys.argv else f'session: {error}', file=sys.stdout if '--json' in sys.argv else sys.stderr)
        sys.exit(1)
