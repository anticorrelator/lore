#!/usr/bin/env python3
"""Publish requests only when the store's session host can interpret their payload,
and answer whether that live host would claim a request for a checkout.

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


def store_hosts(instances, host_key, ttl, now):
    """The live store-scope rows holding host_key: the store's session host, the
    one process that claims a row carrying that key."""
    if not host_key:
        return
    for row in live_rows(instances, ttl, now):
        if row.get('scope') == 'store' and row.get('host_key') == host_key:
            yield row


def placement(instances, host_key, directory, ttl=30, clock=None):
    """Whether the live store host holding host_key would claim a request for
    directory: it serves every checkout that belongs to its store."""
    now = time.time() if clock is None else clock
    kdir = Path(instances).resolve().parent.parent
    membership = Membership(kdir, directory)
    served_by, servers = [], []
    for row in store_hosts(instances, host_key, ttl, now):
        servers.append(f"{row['name']}: the store's session host, for every checkout of this store")
        if directory and membership.check()[0] is not None:
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
    needs = POSITION_CAPABILITY if position else 'a known build vintage >= ' + str(floor)
    hosts = list(store_hosts(instances, row.get('host_key'), ttl, now))
    if not hosts:
        raise RuntimeError(
            'no live store host: run lore session ensure, then retry\n'
            f'This request needs {needs} from the store\'s session host, and no live host holds '
            'its key. Nothing was enqueued.')
    if required and membership.check()[0] is None:
        raise RuntimeError(
            'declared checkout is not in this store: re-declare it\n'
            f'The store\'s session host cannot serve {required}: {membership.check()[1]}. From inside a '
            'checkout of this store, run lore work source-checkout <slug>. Nothing was enqueued.')
    candidates = []
    for host in hosts:
        capabilities = host.get('runtime_capabilities', [])
        if position and (not isinstance(capabilities, list) or not all(isinstance(v, str) for v in capabilities)
                         or POSITION_CAPABILITY not in capabilities):
            continue
        if floor and (not vintage(floor) or not vintage(host.get('build_time')) or vintage(host['build_time']) < vintage(floor)):
            continue
        candidates.append(host)
    if not candidates:
        raise RuntimeError(
            'store host is too old: run lore rebuild, then retry\n'
            f'This request needs {needs}, and the live store host ({hosts[0]["name"]}) does not '
            'provide it. After lore rebuild (or bash install.sh) installs a current lore-tui, the '
            'supervisor restarts the host on it. Nothing was enqueued.')
    # A keyed row is claimed only by the host holding that key, so it needs no
    # name pin, which would strand it when the host restarts under a new name.
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
    except RuntimeError as error:
        sys.exit(str(error))
    except (ValueError, OSError, IndexError) as error:
        sys.exit('session admission: ' + str(error))
