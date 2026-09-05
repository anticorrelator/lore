#!/usr/bin/env python3
"""Interrupt the turn active when the exact session owner handles the request.

Never starts a host, closes a session, or retries an ambiguous ESC attempt.
"""
import argparse
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import secrets
import sys
import time

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('session_managed', SCRIPTS / 'session-managed.py')
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)


def bind(kdir, handle, now=None):
    now = time.time() if now is None else now
    owners = []
    for path in (kdir / '_sessions/instances').glob('*.json'):
        if now - path.stat().st_mtime > 30:
            continue
        instance = managed.read(path, {})
        for session in instance.get('sessions', []):
            if session.get('slug') == handle:
                owners.append((instance, session))
    if len(owners) != 1:
        raise RuntimeError('exactly one fresh live owner is required')
    owner, session = owners[0]
    if 'interrupt-current-turn-v1' not in owner.get('runtime_capabilities', []):
        raise RuntimeError('owner does not support interrupt-current-turn')
    if session.get('harness') not in {'claude-code', 'codex', 'opencode'}:
        raise RuntimeError('unsupported harness')
    epoch = (session.get('worktree') or {}).get('epoch')
    if not all((session.get('session_id'), session.get('request_id'), epoch, owner.get('name'), owner.get('pid'), owner.get('started'), session.get('pid'))):
        raise RuntimeError('exact launch/native/epoch/owner identity unavailable')
    try:
        os.kill(int(owner['pid']), 0)
        os.kill(int(session['pid']), 0)
    except (ProcessLookupError, PermissionError, ValueError):
        raise RuntimeError('session owner or process is unavailable')
    return dict(target_instance=owner['name'], owner_pid=owner['pid'], owner_started=owner['started'],
                session_id=session['session_id'], launch_request_id=session['request_id'],
                epoch=epoch, session_pid=session['pid'])


def interrupt(kdir, handle, timeout=15):
    identity = bind(kdir, handle)
    rid = 'interrupt-' + secrets.token_hex(16)
    at = dt.datetime.now(dt.timezone.utc)
    row = dict(identity, request_id=rid, slug=handle, requested_at=at.isoformat(),
               expires_at=(at + dt.timedelta(seconds=15)).isoformat())
    # Intent is visible before publication. No automatic republisher exists:
    # a crashed producer cannot revive an expired intervention later.
    managed.append(kdir, dict(event='interrupt_requested', request_id=rid, slug=handle,
                             target_instance=identity['target_instance'],
                             links={key: str(value) for key, value in identity.items()}))
    managed.atomic(kdir / '_sessions/interrupt-requests' / (rid + '.json'), row)
    deadline = time.monotonic() + max(0, min(timeout, 30))
    while True:
        for event in reversed(managed.events(kdir, handle)):
            if event.get('request_id') == rid and event.get('event') in {'interrupt_refused', 'interrupt_uncertain'}:
                return dict(request_id=rid, identity=identity, outcome=event['event'], turn_ended=None, event=event)
        if time.monotonic() >= deadline:
            return dict(request_id=rid, identity=identity, outcome='interrupt_uncertain', turn_ended=None,
                        detail='No terminal receipt observed; do not infer interruption or repeat this request.')
        time.sleep(.1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('handle', help='exact live session handle (identity frozen at submission)')
    parser.add_argument('--kdir')
    parser.add_argument('--timeout', type=float, default=15)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    try:
        kdir = Path(args.kdir).resolve() if args.kdir else managed.resolve()
        result = interrupt(kdir, args.handle, args.timeout)
        print(json.dumps(result))
        return 1 if result['outcome'] == 'interrupt_refused' else 0
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
