#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
KDIR=$(resolve_knowledge_dir)
python3 - "$SCRIPT_DIR" "$KDIR" "$@" <<'PY'
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import runpy
import selectors
import signal
import subprocess
import sys
import time
import uuid

scripts, root = Path(sys.argv[1]), Path(sys.argv[2])
api = runpy.run_path(str(scripts / 'work-evidence.py'))
canonical, sha = api['canonical'], api['sha256']
interrupted = None

def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def sync(directory):
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

def immutable(path, value):
    raw = canonical(value) + b'\n'
    if path.exists():
        if path.read_bytes() != raw:
            raise ValueError('immutable artifact collision: ' + path.name)
        return
    temporary = path.with_name('.' + path.name + '.tmp')
    with open(temporary, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync(path.parent)

def checkpoint(name):
    if os.environ.get('LORE_CRITERIA_FAIL_AT') == name:
        raise OSError('injected publication failure: ' + name)

def lock(directory, nonblocking=False):
    fd = os.open(directory, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
    except BaseException:
        os.close(fd)
        raise ValueError('execution is still supervised; recover after it stops')
    return fd

def ledger(path, kind):
    source = api['read_ledger'](path, path.parent, {'1', '2'} if kind == 'packets' else {'1'})
    api['validate_records'](source, kind)
    if source['state'] != 'read':
        raise ValueError(kind + ' history unavailable: ' + str(source['reason']))
    return source['rows']

def select(args, item):
    if not args.task_id or not args.criterion_id or not args.execution_worktree:
        raise ValueError('new run requires task, criterion, and --execution-worktree')
    revision, dispatch = args.revision, args.dispatch_attempt_id
    if args.packet_id is not None:
        if args.unbound_reason is not None:
            raise ValueError('packet binding and unbound reason are mutually exclusive')
        packets = ledger(root / '_packets' / 'packets.jsonl', 'packets')
        matches = [p for p in packets if p.get('packet_id') == args.packet_id]
        if not matches:
            raise ValueError('packet must identify a recorded packet')
        # Rows supersede by append (assembled, then synthesized); the latest row is the packet,
        # and every row in the chain must agree on the identity the result binds to.
        packet = matches[-1]
        if any(m.get(k) != packet.get(k) for m in matches
               for k in ('schema_version', 'work_item', 'task_id', 'revision_id', 'dispatch_attempt_id')):
            raise ValueError('packet supersede chain disagrees on identity')
        if str(packet.get('schema_version')) != '2':
            raise ValueError('selected packet has no immutable revision binding')
        if packet.get('work_item') != args.slug or packet.get('task_id') != args.task_id:
            raise ValueError('packet task or work item disagrees with caller')
        if revision is not None and revision != packet['revision_id']:
            raise ValueError('packet revision disagrees with caller')
        if dispatch is not None and dispatch != packet['dispatch_attempt_id']:
            raise ValueError('packet dispatch attempt disagrees with caller')
        revision, dispatch = packet['revision_id'], packet['dispatch_attempt_id']
    elif not revision or not args.unbound_reason or not args.unbound_reason.strip() or dispatch:
        raise ValueError('outside dispatch requires --revision and --unbound-reason, without dispatch attempt')
    rows = ledger(item / 'revisions.jsonl', 'revisions')
    selected = [r for r in rows if r.get('record_type', 'revision') == 'revision' and r['revision_id'] == revision]
    if len(selected) != 1:
        raise ValueError('selected revision must identify exactly one committed snapshot')
    row = selected[0]
    source = api['read_file'](item / row['tasks_path'], item, json_file=True)
    if source['state'] != 'read' or source['sha256'] != row['tasks_sha256']:
        raise ValueError('selected task snapshot unavailable or hash mismatch')
    tasks = [t for t in api['task_rows'](source['data']) if t.get('id') == args.task_id]
    if len(tasks) != 1:
        raise ValueError('task unavailable in selected revision')
    criteria = [c for c in tasks[0].get('close_criteria', []) if c.get('id') == args.criterion_id]
    if len(criteria) != 1:
        raise ValueError('criterion unavailable in selected task')
    criterion = criteria[0]
    version = api['criterion_version'](criterion)
    if criterion.get('criterion_version') != version:
        raise ValueError('criterion definition hash mismatch')
    return {'schema_version': 1, 'task_id': args.task_id, 'criterion_id': args.criterion_id,
            'criterion_version': version, 'criterion': criterion, 'revision_id': revision,
            'packet_id': args.packet_id, 'dispatch_attempt_id': dispatch,
            'unbound_reason': args.unbound_reason, 'work_item': args.slug,
            'execution_worktree': str(Path(args.execution_worktree).resolve())}

def identity(inputs, item):
    return api['code_identity'](inputs['execution_worktree'], result_exclusion=(item, inputs['result_id']))

def observe(command, inputs, directory, name):
    started = time.monotonic()
    result = {'argv': command['argv'], 'cwd': command['cwd'], 'resolved_cwd': None,
              'exit': None, 'signal': None, 'timed_out': False, 'duration_ms': 0,
              'output_path': None, 'output_sha256': None, 'reason': None}
    child, output, selector = None, None, selectors.DefaultSelector()
    output_error = False
    try:
        worktree = Path(inputs['execution_worktree']).resolve(strict=True)
        cwd = (worktree / command['cwd']).resolve(strict=True)
        cwd.relative_to(worktree)
        if not cwd.is_dir():
            raise OSError('cwd is not a directory')
        result['resolved_cwd'] = str(cwd)
    except (OSError, ValueError, RuntimeError):
        result['reason'] = 'cwd-unavailable'
    try:
        output_path = directory / (name + '.out')
        output = open(output_path, 'xb')
        if result['reason'] is None and interrupted is None:
            try:
                child = subprocess.Popen(command['argv'], cwd=result['resolved_cwd'], stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            except (OSError, ValueError) as exc:
                result['reason'] = 'executable-unavailable' if isinstance(exc, FileNotFoundError) else 'launch-failed'
            if child is not None:
                immutable(directory / (name + '-process.json'), {'schema_version': 1, 'pid': child.pid,
                          'process_group': child.pid, 'supervisor_pid': os.getpid(), 'timestamp': timestamp()})
                os.set_blocking(child.stdout.fileno(), False)
                selector.register(child.stdout, selectors.EVENT_READ)
        killed = False
        drain_deadline = None
        while child is not None and (selector.get_map() or child.poll() is None):
            elapsed = time.monotonic() - started
            if not killed and (elapsed >= command['timeout'] or interrupted is not None or output_error):
                result['timed_out'] = elapsed >= command['timeout'] and interrupted is None and not output_error
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError:
                    # A departed leader may leave no group we can signal.
                    if child.poll() is None:
                        child.kill()
                killed = True
                drain_deadline = time.monotonic() + 0.5
            # An escaped descendant can retain stdout beyond the process group's lifetime.
            if drain_deadline is not None and time.monotonic() >= drain_deadline:
                for key in list(selector.get_map().values()):
                    selector.unregister(key.fileobj)
                break
            for key, _ in selector.select(0.05):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                elif not output_error:
                    try:
                        if os.environ.get('LORE_CRITERIA_FAIL_AT') == 'output-write':
                            raise OSError('injected output failure')
                        output.write(chunk)
                    except OSError:
                        output_error = True
        if child is not None:
            status = child.wait()
            result['exit'] = status if status >= 0 else None
            result['signal'] = -status if status < 0 else None
        if interrupted is not None:
            result['reason'] = 'supervision-interrupted'
        if output_error:
            raise OSError('output write failed')
        if os.environ.get('LORE_CRITERIA_FAIL_AT') == 'output-sync':
            raise OSError('injected output sync failure')
        output.flush()
        os.fsync(output.fileno())
        output.close()
        output = None
        sync(directory)
        result.update(output_path=f"results/{inputs['result_id']}/{name}.out", output_sha256=sha(output_path.read_bytes()))
    except OSError:
        result['reason'] = 'output-persistence-failed'
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    finally:
        selector.close()
        if child is not None and child.stdout is not None:
            child.stdout.close()
        if output is not None:
            try:
                output.close()
            except OSError:
                pass
    result['duration_ms'] = round((time.monotonic() - started) * 1000)
    return result

def execute(inputs, item, directory):
    start = identity(inputs, item)
    immutable(directory / 'started.json', {'schema_version': 1, 'source_start': start})
    criterion = inputs['criterion']
    row = {k: v for k, v in inputs.items() if k != 'execution_worktree'}
    row.update(source_start=start, source_head=start.get('head'), worktree_digest=start.get('digest'),
               digest_version=api['RESULT_CODE_DIGEST_VERSION'], argv=criterion['argv'], cwd=criterion['cwd'],
               resolved_cwd=None, exit=None, signal=None, timed_out=False, duration_ms=0, output_path=None, output_sha256=None,
               applicability=None, state='unavailable', reason='source-identity-unavailable')
    if start['state'] == 'read':
        applicable = True
        if 'applicability' in criterion:
            predicate = criterion['applicability']
            observed = observe(predicate, inputs, directory, 'applicability')
            row['applicability'] = {'definition': predicate, 'observation': observed}
            row.update(duration_ms=observed['duration_ms'], output_path=observed['output_path'],
                       output_sha256=observed['output_sha256'])
            applicable = False
            if observed['reason']:
                row['reason'] = 'applicability-' + observed['reason']
            elif observed['timed_out']:
                row['reason'] = 'applicability-timeout'
            elif observed['signal']:
                row['reason'] = 'applicability-signal'
            elif observed['exit'] == predicate['inapplicable_exit']:
                row.update(state='skipped', reason='condition-inapplicable')
            elif observed['exit'] == predicate['applicable_exit']:
                applicable = True
            else:
                row['reason'] = 'applicability-unexpected-exit'
        if applicable:
            observed = observe(criterion, inputs, directory, 'output')
            predicate_duration = row['duration_ms']
            row.update(observed)
            row['duration_ms'] += predicate_duration
            if observed['reason']:
                row.update(state='unavailable', reason=observed['reason'])
            elif observed['timed_out']:
                row.update(state='fail', reason='timeout')
            elif observed['signal']:
                row.update(state='fail', reason='signal')
            elif observed['exit'] != criterion['expected_exit']:
                row.update(state='fail', reason='unexpected-exit')
            else:
                row.update(state='pass', reason='expected-exit')
    row['source_end'] = identity(inputs, item)
    if row['source_end']['state'] != 'read':
        row.update(state='unavailable', reason='source-identity-unavailable-at-completion')
    row['completed_at'] = timestamp()
    return row

def publish(item, directory, inputs, row):
    # The completion journal precedes ledger publication so recovery never launches a child.
    immutable(directory / 'completion.json', {'schema_version': 1, 'inputs_sha256': sha(canonical(inputs)), 'result': row})
    checkpoint('after-completion')
    fd = lock(item / 'results')
    try:
        path = item / 'results.jsonl'
        if path.is_symlink():
            raise ValueError('result ledger must not be a symlink')
        raw = path.read_bytes() if path.exists() else b''
        line = canonical(row) + b'\n'
        full, _, tail = raw.rpartition(b'\n')
        previous = [json.loads(value) for value in full.splitlines() if value]
        matching = [r for r in previous if r.get('result_id') == row['result_id']]
        if matching:
            if len(matching) != 1 or canonical(matching[0]) + b'\n' != line:
                raise ValueError('result ID collision in published history')
            if tail:
                raise ValueError('result publication has an unrelated incomplete tail')
            return
        if tail and not line.startswith(tail):
            raise ValueError('result history has an unrelated incomplete tail')
        checkpoint('before-publication')
        ledger_fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(ledger_fd, 'ab') as stream:
            if os.environ.get('LORE_CRITERIA_FAIL_AT') == 'partial-publication':
                stream.write(line[:len(line)//2])
                stream.flush()
                os.fsync(stream.fileno())
                raise OSError('injected partial publication')
            stream.write(line[len(tail):])
            stream.flush()
            os.fsync(stream.fileno())
        sync(item)
    finally:
        os.close(fd)

def recover(args, item, directory):
    inputs = json.loads((directory / 'inputs.json').read_text())
    if inputs['result_id'] != args.recover or inputs['work_item'] != args.slug:
        raise ValueError('recovery input identity mismatch')
    for name in ('task_id', 'criterion_id', 'packet_id', 'dispatch_attempt_id', 'revision', 'unbound_reason', 'execution_worktree'):
        supplied = getattr(args, name)
        if supplied is not None:
            if name == 'execution_worktree':
                supplied = str(Path(supplied).resolve())
            if supplied != inputs['revision_id' if name == 'revision' else name]:
                raise ValueError('recovery input disagrees: ' + name)
    completed = directory / 'completion.json'
    if completed.exists():
        completion = json.loads(completed.read_text())
        if completion['inputs_sha256'] != sha(canonical(inputs)):
            raise ValueError('recovery completion input hash mismatch')
        row = completion['result']
        for artifact in api['references'](row, item, item):
            if artifact['state'] != 'read':
                raise ValueError('completed output unavailable or changed; publication refused')
    else:
        source = identity(inputs, item)
        started = directory / 'started.json'
        start = json.loads(started.read_text())['source_start'] if started.exists() else None
        row = {k: v for k, v in inputs.items() if k != 'execution_worktree'}
        row.update(state='unavailable', reason='interrupted-without-durable-completion',
                   source_start=start, source_end=source, source_head=(start or {}).get('head'), worktree_digest=(start or {}).get('digest'),
                   digest_version=api['RESULT_CODE_DIGEST_VERSION'], argv=inputs['criterion']['argv'], cwd=inputs['criterion']['cwd'],
                   resolved_cwd=None, exit=None, signal=None, timed_out=False, duration_ms=0, output_path=None, output_sha256=None,
                   applicability=None, completed_at=timestamp())
    publish(item, directory, inputs, row)
    return row

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)

parser = Parser(description='Execute an immutable plan-owned criterion, or recover publication without executing.')
parser.add_argument('slug')
parser.add_argument('task_id', nargs='?')
parser.add_argument('criterion_id', nargs='?')
parser.add_argument('--revision')
parser.add_argument('--packet-id')
parser.add_argument('--dispatch-attempt-id')
parser.add_argument('--execution-worktree')
parser.add_argument('--unbound-reason')
parser.add_argument('--recover', metavar='RESULT_ID')
parser.add_argument('--json', action='store_true')

def on_signal(number, frame):
    global interrupted
    interrupted = number

try:
    args = parser.parse_args(sys.argv[3:])
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', args.slug):
        raise ValueError('invalid work item slug')
    item = root / '_work' / args.slug
    if not (item / '_meta.json').is_file() or item.is_symlink():
        raise ValueError('active work item unavailable')
    results = item / 'results'
    if results.is_symlink():
        raise ValueError('results directory must not be a symlink')
    if args.recover:
        if not re.fullmatch(r'result-[0-9a-f]{32}', args.recover):
            raise ValueError('invalid recovery result ID')
        directory = results / args.recover
        if directory.is_symlink():
            raise ValueError('result directory must not be a symlink')
        fd = lock(directory, nonblocking=True)
        try:
            row = recover(args, item, directory)
        finally:
            os.close(fd)
        status = 'recovered'
    else:
        inputs = select(args, item)
        results.mkdir(exist_ok=True)
        fd = lock(results)
        execution_fd = None
        try:
            history_path = item / 'results.jsonl'
            if history_path.is_symlink():
                raise ValueError('result ledger must not be a symlink')
            history = ledger(history_path, 'results') if history_path.exists() else []
            sequences = [row.get('execution_sequence', 0) for row in history]
            sequences.extend(json.loads(p.read_text()).get('execution_sequence', 0)
                             for p in results.glob('result-*/inputs.json'))
            if any(type(value) is not int or value < 0 for value in sequences):
                raise ValueError('allocation history has an invalid execution sequence')
            sequence = max(sequences, default=0) + 1
            inputs.update(execution_sequence=sequence, result_id='result-' + uuid.uuid4().hex, execution_attempt_id='execution-' + uuid.uuid4().hex,
                          timestamp=timestamp())
            directory = results / inputs['result_id']
            directory.mkdir()
            execution_fd = lock(directory)
            immutable(directory / 'inputs.json', inputs)
        finally:
            os.close(fd)
        try:
            print(json.dumps({'schema_version': 1, 'status': 'allocated', 'result_id': inputs['result_id'],
                              'execution_attempt_id': inputs['execution_attempt_id']}), file=sys.stderr, flush=True)
            checkpoint('after-allocation')
            for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(number, on_signal)
            row = execute(inputs, item, directory)
            publish(item, directory, inputs, row)
        finally:
            if execution_fd is not None:
                os.close(execution_fd)
        status = 'published'
    print(json.dumps({'schema_version': 1, 'status': status, 'result': row}, ensure_ascii=False))
    raise SystemExit({'pass': 0, 'skipped': 0, 'fail': 1, 'unavailable': 2}[row['state']])
except (ValueError, OSError, KeyError, TypeError) as exc:
    print(json.dumps({'schema_version': 1, 'status': 'refused', 'error': str(exc)}, ensure_ascii=False), file=sys.stderr)
    raise SystemExit(3)
PY
