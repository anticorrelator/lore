#!/usr/bin/env python3
"""Publish requests only to runtimes that can interpret their payload, and answer
which live runtimes would claim a request for a checkout.

  session-admission.py <instances-dir> <ttl>          admit the row on stdin
  session-admission.py placement <instances-dir> <host-key> <dir> [<ttl>]
  session-admission.py checkout <kdir> <dir>          the store checkout <dir> is, or why not
"""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

POSITION_CAPABILITY = 'position-preparation-v1'
SCRIPTS = Path(__file__).resolve().parent


def vintage(value):
    try:
        result = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def store_pinned(kdir):
    """Whether this store's host runs with LORE_KNOWLEDGE_DIR naming the store, as
    the login's served.json records; resolve-repo.sh then answers the pin for
    every directory, so membership cannot be checked by resolution."""
    spec = importlib.util.spec_from_file_location('session_runtime', SCRIPTS / 'session_runtime.py')
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    try:
        served = json.loads((runtime.login_dir() / 'served.json').read_text())
        entry = served['stores'][str(Path(kdir).resolve())]
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return isinstance(entry, dict) and entry.get('pin_knowledge_dir') is True


def store_checkout(kdir, directory, pinned=None):
    """(checkout, None) when directory is a checkout of this store, else (None, why).

    A checkout belongs to the store when it is the top level of an existing git
    checkout, lies outside the store directory (so in neither _sessions/worktrees
    nor _coordination/worktrees), and resolve-repo.sh, run without
    LORE_KNOWLEDGE_DIR, resolves it to this store. A pinned store skips that last
    clause. The store host applies the same rule when it claims.
    """
    if not directory or not os.path.isabs(directory):
        return None, f'{directory!r} is not an absolute path'
    path = os.path.realpath(directory)
    if not os.path.isdir(path):
        return None, f'{directory} is not an existing directory'
    store = os.path.realpath(kdir)
    if path == store or path.startswith(store + os.sep):
        return None, f'{directory} lies inside the knowledge store {store}'
    try:
        top = subprocess.run(['git', '-C', path, 'rev-parse', '--show-toplevel'], text=True, capture_output=True)
    except OSError as error:
        return None, f'git could not inspect {directory}: {error}'
    if top.returncode:
        return None, f'{directory} is not a git checkout'
    if os.path.realpath(top.stdout.strip()) != path:
        return None, f'{directory} is not the top level of its git checkout ({top.stdout.strip()} is)'
    if store_pinned(kdir) if pinned is None else pinned:
        return path, None
    env = {k: v for k, v in os.environ.items() if k != 'LORE_KNOWLEDGE_DIR'}
    resolved = subprocess.run(['bash', str(SCRIPTS / 'resolve-repo.sh'), path], cwd=path, env=env,
                              text=True, capture_output=True)
    if resolved.returncode:
        return None, f'resolve-repo.sh could not resolve the knowledge store of {directory}'
    owner = os.path.realpath(resolved.stdout.strip())
    if owner != store:
        return None, f'{directory} belongs to knowledge store {owner}, not {store}'
    return path, None


def live_rows(instances, ttl, now):
    for path in sorted(Path(instances).glob('*.json')):
        try:
            if now - path.stat().st_mtime > ttl:
                continue
            row = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(row, dict) and row.get('name') and path.stem == row['name']:
            yield row


class Membership:
    """Store membership of one directory, checked at most once."""

    def __init__(self, kdir, directory):
        self.kdir, self.directory, self.result = kdir, directory, None

    def check(self):
        if self.result is None:
            self.result = store_checkout(self.kdir, self.directory)
        return self.result


def serves(row, directory, membership):
    """Whether a live registry row serves a checkout: it runs in exactly that
    checkout, or it is the store host and the checkout belongs to the store."""
    if row.get('scope') == 'store':
        return membership.check()[0] is not None
    project_dir = row.get('project_dir')
    return bool(project_dir) and os.path.realpath(project_dir) == os.path.realpath(directory)


def placement(instances, host_key, directory, ttl=30, clock=None):
    """The live rows that would claim a request keyed host_key ('' for an unkeyed
    request, which only an unkeyed TUI claims) and whether one serves directory."""
    now = time.time() if clock is None else clock
    kdir = Path(instances).resolve().parent.parent
    membership = Membership(kdir, directory)
    served_by, servers = [], []
    for row in live_rows(instances, ttl, now):
        if row.get('host_key', '') != host_key:
            continue
        if row.get('scope') == 'store':
            servers.append(f"{row['name']}: the store's session host, for every checkout of this store")
        elif row.get('project_dir'):
            servers.append(f"{row['name']}: {row['project_dir']}")
        else:
            continue
        if directory and serves(row, directory, membership):
            served_by.append(row['name'])
    error = membership.result[1] if membership.result else None
    return dict(served=bool(served_by), served_by=served_by, servers=servers, store_checkout_error=error)


def admit(row, instances, ttl=30, clock=None):
    context = row.get('extra_context') or {}
    position = isinstance(context, dict) and any(k in context for k in ('position_preparation', 'position_dispatch'))
    floor = row.get('min_vintage')
    if not position and not floor:
        return row
    now = time.time() if clock is None else clock
    required = row.get('required_project_dir')
    membership = Membership(Path(instances).resolve().parent.parent, required)
    candidates = []
    for host in live_rows(instances, ttl, now):
        name = host['name']
        if row.get('target_instance') and row['target_instance'] != name:
            continue
        if host.get('host_key', '') != row.get('host_key', ''):
            continue
        if required and not serves(host, required, membership):
            continue
        capabilities = host.get('runtime_capabilities', [])
        if position and (not isinstance(capabilities, list) or not all(isinstance(v, str) for v in capabilities)
                         or POSITION_CAPABILITY not in capabilities):
            continue
        if floor and (not vintage(floor) or not vintage(host.get('build_time')) or vintage(host['build_time']) < vintage(floor)):
            continue
        candidates.append(host)
    if not candidates:
        needs = POSITION_CAPABILITY if position else 'known build vintage >= ' + str(floor)
        placement_name = row.get('target_instance') or required or 'requested placement'
        raise RuntimeError(f'no live compatible runtime for {placement_name}: requires {needs}; start a compatible host in that placement and retry; nothing was enqueued')
    prefer = row.get('prefer_project_dir')
    candidates.sort(key=lambda h: (h.get('project_dir') != prefer if prefer else False, h['name']))
    # A keyed row is claimed only by the host holding that key, so a store host
    # needs no name pin; pinning one would strand the row if the host restarts
    # under a new instance name before claiming. Legacy readers ignore new fields
    # but already honor the name pin, so every other row keeps it.
    if not (candidates[0].get('scope') == 'store' and row.get('host_key')):
        row['target_instance'] = candidates[0]['name']
    if position:
        row['required_runtime_capabilities'] = [POSITION_CAPABILITY]
    return row


def main(argv):
    if argv[:1] == ['placement']:
        instances, host_key, directory = argv[1:4]
        ttl = int(argv[4]) if len(argv) > 4 else 30
        print(json.dumps(placement(instances, host_key, directory, ttl)))
        return 0
    if argv[:1] == ['checkout']:
        checkout, why = store_checkout(argv[1], argv[2])
        if checkout is None:
            print(why, file=sys.stderr)
            return 1
        print(checkout)
        return 0
    print(json.dumps(admit(json.load(sys.stdin), argv[0], int(argv[1]))))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (RuntimeError, ValueError, OSError, IndexError) as error:
        sys.exit('session admission: ' + str(error))
