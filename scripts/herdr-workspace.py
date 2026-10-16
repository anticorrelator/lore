#!/usr/bin/env python3
"""Lay a lore project out as a Herdr workspace: coordination TUI plus live worker panes.

Usage:
  lore herdr up [DIR] [--max-panes N] [--interval SECONDS] [--focus|--no-focus]
  lore herdr down [DIR] [--close-workers]
  lore herdr watch --workspace ID --root PANE --dir DIR [--max-panes N] [--interval SECONDS]

`up` creates a Herdr workspace for DIR (default: cwd), runs lore-tui in its root
pane, and starts the watcher in a background `rail` tab. Re-running `up` for a
directory whose workspace already exists focuses it instead of creating another.

`down` closes DIR's workspace, which stops the watcher and detaches every worker
pane. Workers keep running in the lore tmux host: ending one is a coordination
act with publication consequences, so it happens only with --close-workers,
which runs `lore session close` on each live worker first and leaves the
workspace open if any close fails.

`watch` follows `lore session list --json` for the project and keeps one pane per
live tmux-hosted worker: the first splits right of the root pane, later ones split
the largest worker pane, and past --max-panes they overflow into a `workers` tab.
When a main-column worker ends, the oldest overflow pane moves up to take its slot.
Each pane attaches read-write with tmux's ignore-size client flag, so the lore
host's own client keeps dictating the window geometry its screen classifiers read.
A pane closes itself when its worker's tmux session ends; a pane you close by
hand stays closed for that worker.

Herdr's screen detector sees only a tmux client in these panes and does not
reliably recognize the harness behind it, so the watcher reports each pane's
sidebar state from the session journal (`lore session events`, cursor-followed).
It does not poll `lore session peek`: a managed peek persists a receipt per call.

The watcher is a viewer over the session substrate. It never starts, answers, or
closes a worker; those stay with `lore session` and the coordinator.

A workspace belongs to DIR when its label is `lore:<basename>` and its
coordination pane's cwd is DIR, so two projects sharing a basename never match.

Requires HERDR_ENV=1 (run from inside a Herdr pane) and tmux.
"""
import argparse
import json
import os
import shlex
import subprocess
import sys
import time

TMUX_LABEL = 'lore-tui'  # tui/internal/work/tmuxhost.go tmuxServerLabel
WORKER_PREFIX = 'w:'
COORD_LABEL = 'coordination'
SOURCE = 'lore'
# Journal events (docs/session-substrate.md, Event vocabulary) -> Herdr pane state.
EVENT_STATE = {
    'spawned': 'working', 'resumed': 'working', 'sent': 'working', 'recovered': 'working',
    'needs_input': 'idle', 'terminus_reached': 'idle',
    'modal_blocked': 'blocked',
}
# lore framework id -> Herdr agent kind.
HERDR_AGENT = {'claude-code': 'claude', 'codex': 'codex', 'opencode': 'opencode'}


def herdr(*args, check=True):
    proc = subprocess.run(['herdr', *args], capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise RuntimeError(f"herdr {' '.join(args)}: {proc.stderr.strip() or proc.stdout.strip()}")
    if proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    return json.loads(out)['result'] if out.startswith('{') else out


def log(msg):
    print(time.strftime('%H:%M:%S'), msg, flush=True)


def workspace_label(directory):
    return f'lore:{os.path.basename(directory.rstrip("/")) or directory}'


def find_workspace(directory):
    """The workspace `up` opened for directory, or None."""
    label = workspace_label(directory)
    for ws in herdr('workspace', 'list')['workspaces']:
        if ws.get('label') != label:
            continue
        for p in herdr('pane', 'list', '--workspace', ws['workspace_id'])['panes']:
            if p.get('label') == COORD_LABEL and os.path.realpath(p.get('cwd') or '') == directory:
                return ws['workspace_id']
    return None


def cmd_up(args):
    directory = os.path.realpath(args.dir or os.getcwd())
    label = workspace_label(directory)
    existing = find_workspace(directory)
    if existing:
        herdr('workspace', 'focus', existing)
        print(f'[herdr] {label} already open as {existing}; focused')
        return 0
    created = herdr('workspace', 'create', '--cwd', directory, '--label', label,
                    '--focus' if args.focus else '--no-focus')
    ws_id = created['workspace']['workspace_id']
    root = created['root_pane']['pane_id']
    herdr('tab', 'rename', created['tab']['tab_id'], 'lore')
    herdr('pane', 'rename', root, COORD_LABEL)
    herdr('pane', 'run', root, 'lore-tui')

    rail = herdr('tab', 'create', '--workspace', ws_id, '--cwd', directory,
                 '--label', 'rail', '--no-focus')
    rail_pane = rail['root_pane']['pane_id']
    herdr('pane', 'rename', rail_pane, 'watcher')
    watch = ['lore', 'herdr', 'watch', '--workspace', ws_id, '--root', root,
             '--dir', directory, '--max-panes', str(args.max_panes),
             '--interval', str(args.interval)]
    herdr('pane', 'run', rail_pane, shlex.join(watch))
    print(f'[herdr] {label}: workspace {ws_id}, coordination {root}, watcher {rail_pane}')
    return 0


def cmd_down(args):
    directory = os.path.realpath(args.dir or os.getcwd())
    label = workspace_label(directory)
    ws = find_workspace(directory)
    try:
        workers = live_workers(directory)
    except RuntimeError as e:
        if args.close_workers:
            raise
        print(f'[herdr] cannot list workers ({e}); closing the workspace only', file=sys.stderr)
        workers = {}
    if args.close_workers:
        failed = 0
        for s in workers.values():
            slug = s.get('slug') or s.get('tmux')
            proc = subprocess.run(['lore', 'session', 'close', slug, '--json'], cwd=directory,
                                  capture_output=True, text=True)
            try:
                outcome = json.loads(proc.stdout).get('outcome')
            except json.JSONDecodeError:
                outcome = None
            ok = proc.returncode == 0 and outcome == 'closed'
            failed += not ok
            print(f"[herdr] {'closed' if ok else 'FAILED to close'} {slug}"
                  + ('' if ok else f": {(proc.stdout or proc.stderr).strip()[:300]}"))
        if failed:
            print(f'[herdr] {failed} worker(s) did not close; leaving {label} open', file=sys.stderr)
            return 1
        workers = {}
    if ws is None:
        print(f'[herdr] no workspace open for {directory}')
    else:
        herdr('workspace', 'close', ws)
        print(f'[herdr] closed {label} ({ws})')
    if workers:
        print(f'[herdr] {len(workers)} worker(s) still running; `lore herdr up` reattaches, '
              '`lore herdr down --close-workers` ends them')
    return 0


def live_workers(directory):
    proc = subprocess.run(['lore', 'session', 'list', '--json'], cwd=directory,
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stdout.strip() or proc.stderr.strip())
    workers = {}
    for inst in json.loads(proc.stdout).get('instances', []):
        for s in inst.get('sessions') or []:
            name = s.get('tmux')
            if name and tmux_alive(name):
                workers[name] = s
    return workers


def tmux_alive(name):
    return subprocess.run(['tmux', '-L', TMUX_LABEL, 'has-session', '-t', name],
                          capture_output=True).returncode == 0


class Journal:
    """Last state-bearing journal event per slug, followed from an opaque cursor."""

    def __init__(self, directory):
        self.dir = directory
        self.cursor = None
        self.state = {}

    def poll(self):
        args = ['lore', 'session', 'events', '--json']
        if self.cursor is not None:
            args += ['--since', str(self.cursor)]
        proc = subprocess.run(args, cwd=self.dir, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(proc.stdout.strip() or proc.stderr.strip())
        out = json.loads(proc.stdout)
        for ev in out.get('events', []):
            state = EVENT_STATE.get(ev.get('event'))
            if state and ev.get('slug'):
                self.state[ev['slug']] = state
        self.cursor = out.get('next_cursor', self.cursor)



class Watcher:
    def __init__(self, args):
        self.ws = args.workspace
        self.root = args.root
        self.dir = os.path.realpath(args.dir)
        self.max_panes = args.max_panes
        self.main_tab = herdr('pane', 'get', self.root)['pane']['tab_id']
        self.overflow_tab = None
        self.panes = {}       # tmux name -> pane id
        self.dismissed = set()  # tmux names whose pane the user closed
        self.reported = {}    # pane id -> state last reported to Herdr
        self.journal = Journal(self.dir)

    def worker_panes(self):
        """Pane id -> (label, tab id) for every worker pane still in the workspace."""
        found = {}
        for p in herdr('pane', 'list', '--workspace', self.ws)['panes']:
            label = p.get('label') or ''
            if label.startswith(WORKER_PREFIX):
                found[p['pane_id']] = (label, p['tab_id'])
        return found

    def adopt(self, workers):
        """Rebind panes left by an earlier watcher so a restart does not duplicate them."""
        existing = self.worker_panes()
        by_label = {label: pane for pane, (label, _) in existing.items()}
        for name, s in workers.items():
            pane = by_label.get(self.label(s))
            if pane:
                self.panes[name] = pane
                log(f'adopted {pane} for {s.get("slug")}')

    @staticmethod
    def label(session):
        # Managed handles are <item>--w<128-bit decimal>; keep the item and a short tag.
        slug = session.get('slug') or session.get('tmux')
        item, sep, tag = slug.partition('--')
        return WORKER_PREFIX + (f'{item}·{tag[:6]}' if sep else slug)

    def split_target(self, panes_in_tab):
        """Largest worker pane in tab, split along its longer visual axis."""
        layout = herdr('pane', 'layout', '--pane', panes_in_tab[0])['layout']
        rects = {p['pane_id']: p['rect'] for p in layout['panes'] if p['pane_id'] in panes_in_tab}
        pane = max(rects, key=lambda k: rects[k]['width'] * rects[k]['height'])
        r = rects[pane]
        # Terminal cells are roughly twice as tall as wide.
        return pane, 'right' if r['width'] > 2.2 * r['height'] else 'down'

    def place(self):
        """Create and return the pane id for a new worker, splitting or overflowing as needed."""
        live = self.worker_panes()
        main = [p for p, (_, tab) in live.items() if tab == self.main_tab]
        if not main:
            return herdr('pane', 'split', self.root, '--direction', 'right', '--ratio', '0.45',
                         '--cwd', self.dir, '--no-focus')['pane']['pane_id']
        if len(main) < self.max_panes:
            pane = max(main, key=lambda p: self.rect_area(p))
            return herdr('pane', 'split', pane, '--direction', 'down', '--cwd', self.dir,
                         '--no-focus')['pane']['pane_id']
        over = [p for p, (_, tab) in live.items() if tab == self.overflow_tab]
        if self.overflow_tab is None or not self.tab_exists(self.overflow_tab):
            tab = herdr('tab', 'create', '--workspace', self.ws, '--cwd', self.dir,
                        '--label', 'workers', '--no-focus')
            self.overflow_tab = tab['tab']['tab_id']
            return tab['root_pane']['pane_id']
        if not over:
            # Overflow tab survives with only non-worker panes; start a fresh one.
            self.overflow_tab = None
            return self.place()
        pane, direction = self.split_target(over)
        return herdr('pane', 'split', pane, '--direction', direction, '--cwd', self.dir,
                     '--no-focus')['pane']['pane_id']

    def rect_area(self, pane):
        layout = herdr('pane', 'layout', '--pane', pane)['layout']
        for p in layout['panes']:
            if p['pane_id'] == pane:
                return p['rect']['width'] * p['rect']['height']
        return 0

    def tab_exists(self, tab):
        return herdr('tab', 'get', tab, check=False) is not None

    def open(self, name, session):
        pane = self.place()
        herdr('pane', 'rename', pane, self.label(session))
        attach = ['tmux', '-L', TMUX_LABEL, 'attach-session', '-f', 'ignore-size', '-t', name]
        herdr('pane', 'run', pane, 'exec ' + shlex.join(attach))
        self.panes[name] = pane
        log(f'opened {pane} for {session.get("slug")} ({name})')

    def promote(self):
        """Move overflow panes into the main column while it has free slots."""
        live = self.worker_panes()
        main = [p for p, (_, tab) in live.items() if tab == self.main_tab]
        over = [p for p, (_, tab) in live.items() if tab != self.main_tab]
        by_pane = {pane: name for name, pane in self.panes.items()}
        opened = list(self.panes.values())  # dicts keep insertion (open) order
        over.sort(key=lambda p: opened.index(p) if p in opened else len(opened))
        for pane in over[:max(0, self.max_panes - len(main))]:
            if main:
                target = max(main, key=self.rect_area)
                moved = herdr('pane', 'move', pane, '--tab', self.main_tab, '--split', 'down',
                              '--target-pane', target, '--no-focus')
            else:
                moved = herdr('pane', 'move', pane, '--tab', self.main_tab, '--split', 'right',
                              '--target-pane', self.root, '--ratio', '0.45', '--no-focus')
            new = moved['move_result']['pane']['pane_id']
            main.append(new)
            self.reported.pop(pane, None)
            if pane in by_pane:
                self.panes[by_pane[pane]] = new
            log(f'promoted {pane} -> {new}')

    def report(self, pane, session):
        state = self.journal.state.get(session.get('slug'), 'unknown')
        if self.reported.get(pane) == state:
            return
        agent = HERDR_AGENT.get(session.get('harness'), session.get('harness') or 'agent')
        if herdr('pane', 'report-agent', pane, '--source', SOURCE, '--agent', agent,
                 '--state', state, check=False) is not None:
            self.reported[pane] = state

    def tick(self):
        workers = live_workers(self.dir)
        self.journal.poll()
        present = self.worker_panes()
        for name, pane in list(self.panes.items()):
            if name not in workers:
                herdr('pane', 'close', pane, check=False)
                log(f'closed {pane}: worker {name} ended')
            elif pane in present:
                continue
            else:
                self.dismissed.add(name)
                log(f'{pane} closed by hand; not reopening {name}')
            del self.panes[name]
            self.reported.pop(pane, None)
        self.dismissed &= workers.keys()
        self.promote()
        for name, s in workers.items():
            if name in self.dismissed:
                continue
            if name not in self.panes:
                self.open(name, s)
            self.report(self.panes[name], s)

    def run(self, interval):
        log(f'watching {self.dir} into {self.ws} (root {self.root}, max {self.max_panes})')
        try:
            self.adopt(live_workers(self.dir))
        except RuntimeError as e:
            log(f'adopt skipped: {e}')
        while True:
            try:
                self.tick()
            except RuntimeError as e:
                log(f'tick failed: {e}')
            time.sleep(interval)


def cmd_watch(args):
    Watcher(args).run(args.interval)
    return 0


def main():
    if os.environ.get('HERDR_ENV') != '1':
        print('[herdr] not running inside a Herdr pane (HERDR_ENV != 1)', file=sys.stderr)
        return 1
    parser = argparse.ArgumentParser(prog='lore herdr', description=__doc__.split('\n\n')[0])
    sub = parser.add_subparsers(dest='verb', required=True)
    up = sub.add_parser('up', help='Open a lore workspace for a directory')
    up.add_argument('dir', nargs='?')
    up.add_argument('--focus', dest='focus', action='store_true', default=True)
    up.add_argument('--no-focus', dest='focus', action='store_false')
    down = sub.add_parser('down', help="Close a directory's lore workspace")
    down.add_argument('dir', nargs='?')
    down.add_argument('--close-workers', action='store_true',
                      help='End each live worker with `lore session close` first')
    watch = sub.add_parser('watch', help='Keep worker panes in step with live sessions')
    watch.add_argument('--workspace', required=True)
    watch.add_argument('--root', required=True)
    watch.add_argument('--dir', required=True)
    for p in (up, watch):
        p.add_argument('--max-panes', type=int, default=4)
        p.add_argument('--interval', type=float, default=2.0)
    args = parser.parse_args()
    try:
        return {'up': cmd_up, 'down': cmd_down, 'watch': cmd_watch}[args.verb](args)
    except RuntimeError as e:
        print(f'[herdr] {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
