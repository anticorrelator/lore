import argparse
import concurrent.futures
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextlib.contextmanager
def locked(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def timestamp():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace('+00:00', 'Z')


def epoch(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, AttributeError, TypeError):
        return None


def observation(peek, identity=None):
    value = dict(peek.get('observation') or {})
    at = epoch(value.get('observed_at'))
    age = time.time() - at if at is not None else None
    limit = value.get('max_age_seconds', 5)
    fresh = (value.get('schema_version') == 1 and value.get('fresh') is True
             and isinstance(limit, (int, float)) and 0 < limit <= 30
             and age is not None and -.5 <= age <= limit
             and (value.get('authority') in {'runtime', 'screen-signature'} or value.get('authority') == 'none' and value.get('activity') == 'unknown')
             and bool(value.get('session_id')) and bool(value.get('generation')))
    if identity:
        if identity.get('slug') and (value.get('session_handle') or peek.get('slug')) != identity['slug']:
            fresh = False
        for key in ('session_id', 'generation', 'instance'):
            if identity.get(key) and identity[key] != value.get(key):
                fresh = False
    value.update(fresh=fresh, age_seconds=age)
    value.setdefault('schema_version', 1)
    value.setdefault('authority', 'none')
    value.setdefault('can_accept_input', peek.get('ready', False))
    value.setdefault('evidence', {'reason': 'observation-unavailable'})
    if not fresh:
        value['activity'] = 'unknown'
    return value


def classify(row, peek):
    links = row.get('links') or {}
    identity = {k: row.get(k) or links.get(k) for k in ('session_id', 'generation')}
    value = observation(peek, identity)
    activity = value.get('activity', 'unknown')
    confirmed = value['fresh'] and (activity == 'blocked' or activity == 'idle' and row.get('event') != 'modal_blocked')
    return dict(tier='confirmed' if confirmed else 'advisory',
                authority=value.get('authority', 'none') if value['fresh'] else 'none',
                state='confirmed_park' if confirmed else 'park_unconfirmed',
                label=('current-' + activity) if value['fresh'] else 'observation-unavailable-stale-or-different-generation',
                observation=value)


def belongs(identity):
    kind, value = identity.get('owner_kind'), identity.get('owner_value')
    if kind == 'pid':
        targets = {int(value)}
    elif kind == 'tmux':
        result = subprocess.run(['tmux', '-L', identity.get('tmux_server', 'lore-tui'), 'list-panes', '-t', value, '-F', '#{pane_pid}'], capture_output=True, text=True, timeout=3)
        if result.returncode:
            return False
        targets = {int(p) for p in result.stdout.split() if p.isdigit()}
    else:
        return False
    pid = os.getpid()
    for _ in range(128):
        if pid in targets:
            return True
        if pid <= 1:
            return False
        result = subprocess.run(['ps', '-o', 'ppid=', '-p', str(pid)], capture_output=True, text=True, timeout=2)
        if result.returncode or not result.stdout.strip().isdigit():
            return False
        pid = int(result.stdout.strip())
    return False


def current_snapshot(current):
    result = dict(current)
    result['original_delta'] = current.get('original_delta', current.get('delta', []))
    result['unavailable'] = list(current.get('unavailable', []))
    for field in ('current', 'delta'):
        rows = []
        for row in current.get(field, []):
            screen = dict(row.get('peek') or {'observation': row.get('observation')})
            value = observation(screen)
            rows.append(dict(row, observation=value, **({'peek': dict(screen, observation=value)} if 'peek' in row else {})))
            if field == 'current' and not value['fresh']:
                result['complete'] = False
                result['unavailable'].append({'slug': row.get('slug'), 'error': 'observation-expired-or-unavailable'})
        result[field] = rows
    return result


class Delivery:
    def __init__(self, path):
        self.path = Path(path)
        self.lock = self.path.with_suffix('.lock')

    def state(self):
        return read(self.path, {'schema_version': 1, 'observed_cursor': None, 'wakes': []})

    def publish(self, payload, identity, interval):
        with locked(self.lock):
            state = self.state()
            basis = {k: payload.get(k) for k in ('outcome', 'matched', 'pending', 'next_cursor', 'current_delta')}
            if payload.get('outcome') == 'pending_stale':
                basis = {'outcome': 'pending_stale', 'requests': sorted({str(r['request_id']) for r in payload.get('pending', [])})}
            key = hashlib.sha256(json.dumps(basis, sort_keys=True).encode()).hexdigest()
            if payload.get('outcome') == 'pending_stale':
                previous = next((r for r in reversed(state['wakes']) if r['fingerprint'] == key), None)
                if previous and time.time() - previous.get('last_delivery', 0) < previous.get('interval', 600):
                    return None
            pending = [r for r in state['wakes'] if not r.get('acknowledged_at')]
            found = next((r for r in pending if r['fingerprint'] == key), None)
            if payload.get('tier') == 'quiet':
                found = next((r for r in pending if r['payload'].get('tier') == 'quiet'), found)
            if not found:
                found = dict(wake_id='wake-' + uuid.uuid4().hex, fingerprint=key, payload=payload,
                             identity=identity, created_at=timestamp(), last_delivery=0, interval=interval)
                state['wakes'].append(found)
            state['observed_cursor'] = payload.get('next_cursor')
            chosen = found
            if payload.get('tier') == 'quiet':
                actionable = [r for r in pending if r['payload'].get('tier') != 'quiet' and time.time() - r.get('last_delivery', 0) >= r.get('interval', 600)]
                if actionable:
                    chosen = actionable[-1]
            chosen['last_delivery'] = time.time()
            atomic(self.path, state)
            return self.present(chosen, payload.get('current_observations'))

    def pending(self, current=None):
        with locked(self.lock):
            state = self.state()
            pending = [r for r in state['wakes'] if not r.get('acknowledged_at')]
            due = [r for r in pending if time.time() - r.get('last_delivery', 0) >= r.get('interval', 600)]
            actionable = [r for r in due if r['payload'].get('tier') != 'quiet']
            choices = actionable or due
            if not choices:
                return None
            chosen = choices[-1] if actionable else choices[0]
            chosen['last_delivery'] = time.time()
            atomic(self.path, state)
            return self.present(chosen, current)

    def present(self, row, current=None):
        payload = dict(row['payload'], wake_id=row['wake_id'], created_at=row['created_at'],
                       acknowledgment_required=True, recipient=row['identity'])
        payload['original_observations'] = payload.get('current_observations')
        current = current_snapshot(current) if current is not None else None
        payload['current_observations'] = current if current is not None else {'current': [], 'complete': False, 'unavailable': [{'error': 'not-reconciled-by-receipt'}]}
        matched = payload.get('matched') or {}
        if matched.get('event') in {'needs_input', 'modal_blocked'}:
            snapshot = next((v for v in (current or {}).get('current', []) if v.get('slug') == matched.get('slug')), {})
            current_class = classify(matched, snapshot.get('peek', {}))
            payload['original_classification'] = payload.get('classification')
            payload['classification'] = dict(current_class, historical_event=matched)
            payload['tier'] = current_class['tier']
            payload['authority'] = current_class['authority']
        if payload.get('outcome') == 'current_delta':
            original = payload.get('current_delta', [])
            refreshed = []
            for old in original:
                snapshot = next((v for v in (current or {}).get('current', []) if v.get('slug') == old.get('slug')), {})
                value = observation(snapshot.get('peek', {}), old.get('observation'))
                refreshed.append({'slug': old.get('slug'), 'observation': value})
            payload['original_delta'] = original
            payload['current_delta'] = refreshed
            payload['tier'] = 'confirmed' if any(r['observation'].get('fresh') and r['observation'].get('activity') in {'idle', 'blocked'} for r in refreshed) else 'advisory'
        return payload


def wake_receipt(kdir, wake_id, acknowledge=False):
    if not re.fullmatch(r'wake-[a-f0-9]{32}', wake_id):
        raise ValueError('invalid wake id')
    for path in (Path(kdir) / '_coordination').glob('watch-delivery-*.json'):
        delivery = Delivery(path)
        with locked(delivery.lock):
            state = delivery.state()
            row = next((r for r in state['wakes'] if r['wake_id'] == wake_id), None)
            if not row:
                continue
            if not belongs(row['identity']):
                raise ValueError('wake receipt belongs to another owner')
            if acknowledge and not row.get('acknowledged_at'):
                row['acknowledged_at'] = timestamp()
                atomic(path, state)
            return dict(wake_id=wake_id, payload=delivery.present(row), historical_payload=row['payload'],
                        current_observation_available=False, recipient=row['identity'],
                        acknowledged_at=row.get('acknowledged_at'), acknowledgment_requested=True, action_completed=False)
    raise ValueError('unknown wake id in this store')


def matches(slug, scope):
    return not scope or slug in scope or re.sub(r'--w[0-9]+$', '', slug) in scope


def sweep(kdir, scripts, path, scope, budget, peek_timeout):
    deadline = time.monotonic() + budget
    targets = {}
    unavailable = []
    for registry in (Path(kdir) / '_sessions/instances').glob('*.json'):
        try:
            instance = read(registry, {})
            if time.time() - registry.stat().st_mtime > 30:
                unavailable.extend({'slug': row.get('slug'), 'error': 'stale-owner-registry'} for row in instance.get('sessions', []) if row.get('slug') and matches(row['slug'], scope))
                continue
            for session in instance.get('sessions', []):
                slug = session.get('slug')
                if slug and matches(slug, scope):
                    targets[slug] = dict(session, instance=instance.get('name'))
        except (ValueError, OSError) as error:
            unavailable.append({'registry': registry.name, 'error': str(error)})
    def fetch(item):
        slug, identity = item
        remaining = deadline - time.monotonic()
        if remaining <= 0 or peek_timeout <= 0:
            return {'slug': slug, 'error': 'reconciliation-budget-unavailable'}
        try:
            duration = min(remaining, peek_timeout)
            result = subprocess.run(['bash', str(Path(scripts) / 'session-peek.sh'), slug, '--json', '--timeout', str(max(1, math.ceil(duration))), '--kdir', str(kdir)], capture_output=True, text=True, timeout=duration)
            if result.returncode:
                return {'slug': slug, 'error': result.stderr.strip() or result.stdout.strip() or 'peek-unavailable'}
            peek = json.loads(result.stdout)
            value = observation(peek, identity)
            peek['observation'] = value
            return {'slug': slug, 'observation': value, 'peek': peek}
        except (ValueError, OSError, subprocess.TimeoutExpired) as error:
            return {'slug': slug, 'error': str(error)}
    saved = read(path, {})
    ordered = sorted(targets.items())
    offset = saved.get('next_index', 0) % len(ordered) if ordered else 0
    ordered = ordered[offset:] + ordered[:offset]
    selected = ordered[:4]
    unavailable.extend({'slug': slug, 'error': 'deferred-to-next-reconciliation'} for slug, _ in ordered[4:])
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(fetch, selected))
    current = [r for r in rows if 'observation' in r]
    unavailable.extend(r for r in rows if 'error' in r)
    with locked(Path(path).with_suffix('.lock')):
        saved = read(path, {})
        previous = saved.get('states', {})
        states = dict(previous)
        pending = saved.get('pending', {})
        for slug, prior in previous.items():
            if not matches(slug, scope):
                pending.pop(slug, None)
                continue
            if slug not in targets:
                value = dict(prior, schema_version=1, activity='unknown', authority='none', fresh=False,
                             observed_at=timestamp(), evidence={'reason': 'previous-session-not-in-live-registry'})
                current.append({'slug': slug, 'observation': value, 'peek': {'slug': slug, 'observation': value}})
                unavailable.append({'slug': slug, 'error': 'previous-session-not-in-live-registry'})
        for row in current:
            value = row['observation']
            token = {k: value.get(k) for k in ('activity', 'generation', 'session_id', 'authority', 'fresh')}
            if previous.get(row['slug']) != token:
                pending[row['slug']] = {'slug': row['slug'], 'previous': previous.get(row['slug']), 'observation': value}
            states[row['slug']] = token
        atomic(path, {'schema_version': 1, 'states': states, 'pending': pending, 'next_index': offset + len(selected), 'observed_at': timestamp()})
    return dict(observed_at=timestamp(), current=current, delta=list(pending.values()), unavailable=unavailable,
                complete=not unavailable, budget_seconds=budget)


def consume_delta(path, payload):
    with locked(Path(path).with_suffix('.lock')):
        saved = read(path, {})
        pending = saved.get('pending', {})
        current = payload.get('current_observations', {})
        for row in current.get('original_delta', current.get('delta', [])):
            if pending.get(row['slug']) == row:
                pending.pop(row['slug'])
        saved['pending'] = pending
        atomic(path, saved)


def peek_summary(peek):
    value = observation(peek)
    lines = ["[session] activity={} authority={} fresh={} age_seconds={} observed_at={} session={} generation={} instance={}".format(value.get('activity', 'unknown'), value.get('authority', 'none'), value['fresh'], value['age_seconds'], value.get('observed_at'), value.get('session_id'), value.get('generation'), value.get('instance')),
             "[session] input_eligible={} framework={} evidence={}".format(peek.get('ready', False), peek.get('framework', 'unknown'), json.dumps(value.get('evidence', {})))]
    for field in ('screen', 'modal'):
        if peek.get(field):
            lines.append('[session] ' + field + '=' + json.dumps(peek[field]))
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['publish', 'pending', 'cursor', 'classify', 'sweep', 'consume', 'peek', 'peek-text', 'current'])
    parser.add_argument('--path')
    parser.add_argument('--kdir')
    parser.add_argument('--scripts')
    parser.add_argument('--scope', default='[]')
    parser.add_argument('--identity', default='{}')
    parser.add_argument('--interval', type=float, default=600)
    parser.add_argument('--budget', type=float, default=3)
    parser.add_argument('--peek-timeout', type=float, default=3)
    args = parser.parse_args()
    if args.command == 'cursor':
        print(json.dumps(Delivery(args.path).state().get('observed_cursor')))
    elif args.command == 'sweep':
        print(json.dumps(sweep(args.kdir, args.scripts, args.path, json.loads(args.scope), args.budget, args.peek_timeout)))
    else:
        payload = json.load(sys.stdin)
        if args.command == 'peek-text':
            print(peek_summary(payload))
            return
        if args.command == 'current':
            result = current_snapshot(payload)
        elif args.command == 'peek':
            result = dict(payload, observation=observation(payload))
        elif args.command == 'consume':
            consume_delta(args.path, payload)
            result = True
        elif args.command == 'classify':
            result = classify(payload['row'], payload['peek'])
        elif args.command == 'publish':
            result = Delivery(args.path).publish(payload, json.loads(args.identity), args.interval)
        else:
            result = Delivery(args.path).pending(payload)
        print(json.dumps(result))


if __name__ == '__main__':
    main()
