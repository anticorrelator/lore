"""Real lore-tui windows that view, type into and launch sessions their store's
background host runs, while hosting nothing themselves.

Run with LORE_SESSION_HOST_BINARY pointing at a lore-tui built from this tree. The
same binary is the store host the login supervisor launches and the window under
test. Each window runs in a driver tmux session on a socket of its own inside the
test's private TMUX_TMPDIR, and the test reads the window's screen with
capture-pane on that socket. Sessions' panes, their clients and their window
sizes are read on the runtime's own server. Every test owns its HOME,
LORE_DATA_DIR, store, checkout and TMUX_TMPDIR under one root (RuntimeFixture),
runs under a named LORE_SESSION_RUNTIME, and uses fake harnesses only.
"""
import datetime
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest

from tests.test_session_manager_integration import RuntimeFixture

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("session_runtime", REPO / "scripts/session_runtime.py")
session_runtime = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(session_runtime)

# Sits in front of the real lore CLI on a window's PATH. It records each call the
# window makes (arguments, working directory, parent pid, time, and which session
# identity variables were set) and then runs the real CLI with the same arguments.
WINDOW_LORE = r'''#!/usr/bin/env python3
import json, os, sys, time
row = {"argv": sys.argv[1:], "cwd": os.getcwd(), "ppid": os.getppid(), "at": time.time(),
       "session_identity": sorted(name for name in ("LORE_SESSION_INSTANCE", "LORE_SESSION_SLUG",
                                                    "LORE_SESSION_TYPE") if name in os.environ)}
fd = os.open(os.environ["LORE_WINDOW_CALL_LOG"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
try:
    os.write(fd, (json.dumps(row) + "\n").encode())
finally:
    os.close(fd)
os.execv(LORE_CLI, [LORE_CLI, *sys.argv[1:]])
'''.replace("LORE_CLI", repr(str(REPO / "cli/lore")))

# The name a lore-tui window from before store hosting gave itself: an
# adjective-noun pair, as its instance-name generator drew them.
OLD_WINDOW = "quiet-heron"


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


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


def lock_held(path):
    """Whether another process holds the flock on path; a missing file is never held."""
    if not Path(path).exists():
        return False
    with open(path, "a+") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(stream, fcntl.LOCK_UN)
        return False


def parent_pid(pid):
    result = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True)
    return int(result.stdout.strip()) if result.stdout.strip().isdigit() else None


def command_line(pid):
    return subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(pid)], capture_output=True,
                          text=True).stdout.strip()


def instant(value):
    """Seconds since the epoch of an ISO 8601 UTC timestamp."""
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


@unittest.skipUnless(os.environ.get("LORE_SESSION_HOST_BINARY") and shutil.which("tmux"),
                     "requires an explicitly built lore-tui and tmux")
class TUIViewerIntegration(RuntimeFixture, unittest.TestCase):
    """A lore-tui window is a viewer: every session it shows or starts runs in its
    store's background host, and the window registers, claims and hosts nothing."""

    ROOT_PREFIX = "lore-tv-"
    DRIVER = "tview-driver"

    def setUp(self):
        self.open_root()
        self.runtime = os.environ.get("LORE_SESSION_RUNTIME") or "tview-" + str(os.getpid())
        self.env = self.base_env(self.runtime, LORE_SESSION_SUPERVISOR_QUIET_SECONDS="600")
        self.assert_private_tmux(self.env)
        self.binary = Path(self.env["LORE_SESSION_HOST_BINARY"]).resolve()
        self.server = session_runtime.tmux_server(self.env)
        # The driver server's socket lies in the same private directory as the runtime's.
        driver_socket = Path(self.env["TMUX_TMPDIR"]).resolve() / f"tmux-{os.getuid()}" / self.DRIVER
        self.assertTrue(driver_socket.is_relative_to(self.root), driver_socket)
        self.assertLess(len(str(driver_socket)), 104, "driver socket path exceeds the macOS limit")
        self.calls = self.root / "window-calls.jsonl"
        wrapper = self.root / "window-bin" / "lore"
        wrapper.parent.mkdir()
        wrapper.write_text(WINDOW_LORE)
        wrapper.chmod(0o755)
        # A window started by a person carries no harness session's markers.
        self.window_env = {k: v for k, v in self.env.items()
                           if not k.startswith(("CLAUDE", "CODEX_", "OPENCODE_")) and k not in ("AI_AGENT", "CLAUDECODE")}
        self.window_env.update(PATH=str(wrapper.parent) + os.pathsep + self.env["PATH"],
                               LORE_WINDOW_CALL_LOG=str(self.calls))
        self.assert_private_tmux(self.window_env)
        self.windows = {}
        # Runs before RuntimeFixture's teardown, so no window can start a host while it stops them.
        self.addCleanup(self.close_windows)

    # --- store, checkout and work items ---

    def git(self, cwd, *args):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True,
                                stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def make_store(self, name):
        kdir = self.data / "repos/example.test" / name
        kdir.mkdir(parents=True)
        (kdir / "_manifest.json").write_text("{}\n")
        self.stores.append(kdir)
        return kdir

    def make_checkout(self, store_name, dirname):
        path = self.root / dirname
        path.mkdir()
        self.git(path, "init", "-q", "-b", "main")
        self.git(path, "remote", "add", "origin", f"https://example.test/{store_name}.git")
        self.git(path, "config", "user.name", "Fixture")
        self.git(path, "config", "user.email", "fixture@example.test")
        (path / "seed").write_text("unchanged\n")
        self.git(path, "add", "seed")
        self.git(path, "commit", "-q", "-m", "seed")
        return path

    def lore(self, *args, cwd, env=None, timeout=90):
        return subprocess.run([str(REPO / "cli/lore"), *args], cwd=cwd, env=env or self.env, text=True,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)

    def lore_json(self, *args, cwd, env=None, timeout=90, check=True):
        result = self.lore(*args, "--json", cwd=cwd, env=env, timeout=timeout)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)
        try:
            return result, json.loads(result.stdout)
        except ValueError:
            self.fail("non-JSON response: " + result.stdout + "\n" + result.stderr)

    def create_item(self, kdir, checkout, title, declare=True):
        result = self.lore("work", "create", "--title", title, cwd=checkout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        slug = title.lower().replace(" ", "-")
        self.assertTrue((kdir / "_work" / slug / "_meta.json").is_file(), result.stdout)
        if declare:
            # Outside any session, the verb declares the checkout it runs in.
            _, meta = self.lore_json("work", "source-checkout", slug, cwd=checkout)
            self.assertEqual(meta["source_checkout"], str(checkout))
        return slug

    def request_chat(self, checkout, *extra):
        """A chat an agent asks for, through the same entry every caller uses."""
        _, value = self.lore_json("session", "request", "--type", "chat", "--initiator", "agent",
                                  "--prefer-dir", str(checkout), "--yes", *extra, cwd=checkout)
        return value

    # --- the store host and its records ---

    def key(self, kdir):
        return session_runtime.store_host_key(kdir, self.env)

    def host_dir(self, kdir):
        return session_runtime.hosts_dir(kdir, self.env) / self.key(kdir)

    def login(self):
        return session_runtime.login_dir(self.env)

    def ready(self, kdir):
        record = read_json(self.host_dir(kdir) / "ready.json")
        return record if record and record.get("ready") and alive(record.get("pid")) else None

    def wait_ready(self, kdir, timeout=60):
        return self.until(lambda: self.ready(kdir), timeout, f"the store host for {kdir} never became ready")

    def supervisors_running(self):
        """Supervisor processes whose environment names this test's data directory."""
        listing = subprocess.run(["ps", "-ww", "-E", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        return [int(line.split()[0]) for line in listing.splitlines()
                if "session-managed.py _supervise" in line and f"LORE_DATA_DIR={self.data}" in line]

    def supervisor_log(self):
        path = self.login() / "supervisor.log"
        return path.read_text() if path.exists() else ""

    def started(self, slug, timeout=60):
        return self.until(lambda: next((e for e in self.events() if e["event"] == "started" and e["slug"] == slug), None),
                          timeout, f"the harness for {slug} never started")

    def messages(self, body):
        return [e for e in self.events() if e["event"] == "message" and e.get("body") == body]

    def journal(self, kdir):
        path = kdir / "_sessions/events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines() if line] if path.exists() else []

    def registry(self, kdir):
        return {path.name: read_json(path) for path in sorted((kdir / "_sessions/instances").glob("*.json"))}

    def hosted(self, kdir, host, slug):
        """The session entry the store host's registry row lists for slug."""
        row = read_json(kdir / "_sessions/instances" / (host["instance_name"] + ".json")) or {}
        return next((s for s in row.get("sessions", []) if s.get("slug") == slug), None)

    def assert_only_the_store_host(self, kdir, host, claimants=()):
        """The registry holds one row, the store host's, and every claim and spawn is a
        store host's: this one's, or one of the earlier store hosts named in claimants."""
        rows = self.registry(kdir)
        self.assertEqual(list(rows), [host["instance_name"] + ".json"], rows)
        row = rows[host["instance_name"] + ".json"]
        self.assertEqual((row["role"], row["host_key"], row["scope"], row["pid"], row["runtime"]),
                         ("session-host", self.key(kdir), "store", host["pid"], self.runtime), row)
        self.assertNotIn(row["pid"], self.windows.values())
        acted = [e for e in self.journal(kdir) if e.get("event") in ("claimed", "spawned")]
        self.assertTrue(acted)
        self.assertLessEqual({e["actor_instance"] for e in acted}, {host["instance_name"], *claimants}, acted)
        self.assertEqual(list((kdir / "_sessions/requests").glob("*/*.json")), [])

    # --- the runtime's tmux server, where sessions run ---

    def tmux(self, *args, check=True):
        result = subprocess.run(["tmux", "-L", self.server, *args], env=self.env, capture_output=True, text=True,
                                stdin=subprocess.DEVNULL)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def window_size(self, name):
        return self.tmux("display-message", "-p", "-t", f"={name}:", "#{window_width}x#{window_height}").strip()

    def window_size_option(self, name):
        return self.tmux("show-options", "-w", "-v", "-t", f"={name}:", "window-size").strip()

    def clients(self, name):
        """Every tmux client attached to the session, with the process that started it."""
        rows = []
        for line in self.tmux("list-clients", "-t", f"={name}", "-F",
                              "#{client_pid} #{client_width}x#{client_height} #{client_flags}").splitlines():
            pid, size, flags = line.split(" ", 2)
            rows.append(dict(pid=int(pid), parent=parent_pid(int(pid)), size=size, flags=set(flags.split(","))))
        return rows

    # --- windows, each in its own driver tmux session ---

    def driver(self, *args, check=True):
        result = subprocess.run(["tmux", "-L", self.DRIVER, *args], env=self.window_env, capture_output=True,
                                text=True, stdin=subprocess.DEVNULL)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def open_window(self, name, cols, rows, cwd):
        """Start lore-tui as a person's terminal runs it, in a driver session of cols x rows."""
        self.driver("-f", "/dev/null", "new-session", "-d", "-s", name, "-x", str(cols), "-y", str(rows),
                    "-c", str(cwd), str(self.binary))
        pid = int(self.driver("display-message", "-p", "-t", f"={name}:", "#{pane_pid}").strip())
        self.assertTrue(command_line(pid).startswith(str(self.binary)), command_line(pid))
        self.windows[name] = pid
        return name

    def screen(self, window):
        return self.driver("capture-pane", "-p", "-t", f"={window}:")

    def keys(self, window, *keys):
        self.driver("send-keys", "-t", f"={window}:", *keys)

    def type_line(self, window, text):
        self.keys(window, "-l", text)
        self.keys(window, "Enter")

    def wait_screen(self, window, *texts, timeout=30):
        deadline = time.monotonic() + timeout
        while True:
            shown = self.screen(window)
            if all(text in shown for text in texts):
                return shown
            if time.monotonic() >= deadline:
                self.fail(f"{window} never showed {texts!r}; its screen:\n{shown}")
            time.sleep(0.2)

    def viewer_client(self, window, name):
        """The tmux client a window attached to the session, if it has one."""
        return next((c for c in self.clients(name) if c["parent"] == self.windows[window]), None)

    def open_viewer(self, window, name, key="Enter"):
        self.keys(window, key)
        client = self.until(lambda: self.viewer_client(window, name), 30, f"{window} attached no viewer to {name}")
        self.wait_screen(window, "? for shortcuts")
        return client

    def window_calls(self, window):
        """The lore calls one window made, oldest first."""
        if not self.calls.exists():
            return []
        rows = [json.loads(line) for line in self.calls.read_text().splitlines() if line]
        return [row for row in rows if row["ppid"] == self.windows[window]]

    def close_windows(self):
        subprocess.run(["tmux", "-L", self.DRIVER, "kill-server"], env=self.window_env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while any(alive(pid) for pid in self.windows.values()) and time.monotonic() < deadline:
            time.sleep(0.1)

    # --- scenarios ---

    def test_tui_views_and_types_into_a_store_hosted_session_without_hosting(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Viewer Fixture")
        request = self.request_chat(checkout, "--slug", item)
        self.assertEqual(request["host_key"], self.key(kdir))
        record = self.started(item)
        host = self.wait_ready(kdir)
        name = self.hosted(kdir, host, item)["tmux"]

        window = self.open_window("window", 200, 50, checkout)
        self.wait_screen(window, item, "v sessions (1)")
        client = self.open_viewer(window, name)
        self.assertIn("ignore-size", client["flags"])
        self.type_line(window, "typed-in-the-window")
        self.wait_screen(window, "received: typed-in-the-window")
        self.assertEqual([m["pid"] for m in self.messages("typed-in-the-window")], [record["pid"]])

        # The window registered nothing, claimed nothing, started no tmux session and asked for nothing.
        self.assertEqual(record["instance"], host["instance_name"])
        self.assert_only_the_store_host(kdir, host)
        self.assertEqual(self.tmux("list-sessions", "-F", "#{session_name}").split(), [name])
        hosts_client = [c for c in self.clients(name) if c["parent"] == host["pid"]]
        self.assertEqual(len(hosts_client), 1, self.clients(name))
        self.assertFalse([c for c in self.window_calls(window) if c["argv"][:2] == ["session", "request"]])

    def test_two_tuis_view_one_session_at_the_host_size(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Viewer Fixture")
        self.request_chat(checkout, "--slug", item)
        record = self.started(item)
        host = self.wait_ready(kdir)
        name = self.hosted(kdir, host, item)["tmux"]
        size = self.window_size(name)
        self.assertEqual(self.window_size_option(name), "manual")
        hosts_client = self.until(lambda: [c for c in self.clients(name) if c["parent"] == host["pid"]], 30)
        self.assertEqual(hosts_client[0]["size"], size)

        windows = [self.open_window("window-a", 200, 50, checkout), self.open_window("window-b", 120, 40, checkout)]
        viewers = {}
        for window in windows:
            self.wait_screen(window, item, "v sessions (1)")
            viewers[window] = self.open_viewer(window, name)
        clients = self.clients(name)
        self.assertEqual(sorted(c["parent"] for c in clients),
                         sorted([host["pid"], *(self.windows[w] for w in windows)]), clients)
        self.assertNotIn("ignore-size", hosts_client[0]["flags"])
        for window, client in viewers.items():
            self.assertIn("ignore-size", client["flags"], client)
        self.assertNotEqual(viewers["window-a"]["size"], viewers["window-b"]["size"])

        for typist in windows:
            body = "from-" + typist
            self.type_line(typist, body)
            for window in windows:
                self.wait_screen(window, "received: " + body)
            self.assertEqual([m["pid"] for m in self.messages(body)], [record["pid"]])
        self.assertEqual(self.window_size(name), size)
        self.assertEqual(self.window_size_option(name), "manual")
        self.assertEqual(self.tmux("display-message", "-p", "-t", f"={name}:", "#{pane_width}x#{pane_height}").strip(),
                         size)
        self.assert_only_the_store_host(kdir, host)

    def test_tui_launch_runs_in_the_store_host(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Launch Fixture")
        self.assertFalse(self.supervisors_running())

        window = self.open_window("window", 200, 50, checkout)
        self.wait_screen(window, item)
        # Opening a window starts nothing; the launch is what brings the store host up.
        self.assertFalse(self.supervisors_running())
        self.keys(window, "s")
        self.wait_screen(window, f"Run /spec for {item}?")
        self.keys(window, "Enter")
        record = self.started(item)
        host = self.wait_ready(kdir)
        launched = [c for c in self.window_calls(window) if c["argv"][:2] == ["session", "request"]]
        self.assertEqual(len(launched), 1, launched)
        argv = launched[0]["argv"]
        self.assertEqual(argv[:8], ["session", "request", "--type", "spec", "--initiator", "human",
                                    "--prefer-dir", str(checkout)], argv)
        self.assertEqual((argv[argv.index("--slug") + 1], argv[argv.index("--kdir") + 1]), (item, str(kdir)), argv)
        self.assertIn("--json", argv)
        self.assertEqual(launched[0]["cwd"], str(checkout))

        # The store host claimed the window's request and runs its session in a worktree of the checkout.
        self.assertEqual(record["instance"], host["instance_name"])
        self.assertEqual(record["values"]["LORE_SESSION_HOST_KEY"], self.key(kdir))
        self.assertEqual(record["values"]["LORE_SESSION_SOURCE_DIR"], str(checkout))
        self.assertTrue(Path(record["cwd"]).is_relative_to(kdir / "_sessions/worktrees"), record)
        spawned = self.until(lambda: next((e for e in self.journal(kdir)
                                           if e.get("event") == "spawned" and e.get("slug") == item), None),
                             30, "the store host never journaled the spawn")
        self.assertEqual(spawned["actor_instance"], host["instance_name"])
        self.assertIn(f"launched host pid {host['pid']} (requested)", self.supervisor_log())

        # Its viewer opens on its own; focusing it lets the person type into the session.
        name = self.hosted(kdir, host, item)["tmux"]
        self.until(lambda: self.viewer_client(window, name), 30, "the launched session's viewer never attached")
        self.wait_screen(window, "? for shortcuts")
        self.keys(window, "Enter")
        self.type_line(window, "after-the-launch")
        self.wait_screen(window, "received: after-the-launch")
        self.assertEqual([m["pid"] for m in self.messages("after-the-launch")], [record["pid"]])
        self.assert_only_the_store_host(kdir, host)

    def test_refused_launch_shows_its_reason(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Refusal Fixture", declare=False)

        window = self.open_window("window", 200, 50, checkout)
        self.wait_screen(window, item)
        self.keys(window, "s")
        self.wait_screen(window, f"Run /spec for {item}?")
        self.keys(window, "Enter")
        shown = self.wait_screen(window, "Launch refused", "declare and launch")
        launched = [c for c in self.window_calls(window) if c["argv"][:2] == ["session", "request"]]
        self.assertEqual(len(launched), 1, launched)
        self.assertIn("--json", launched[0]["argv"])

        # The window's own request, sent again from the same checkout, is refused with
        # the text the window shows, in full.
        again = self.lore(*launched[0]["argv"], cwd=launched[0]["cwd"])
        self.assertEqual(again.returncode, 1, again.stdout + again.stderr)
        text = json.loads(again.stdout)["error"]
        self.assertTrue(text.startswith(f"no checkout declared: run lore work source-checkout {item}"), text)
        self.assert_shows_in_full(shown, text)

        # Nothing was enqueued and no host was started for it.
        self.assertEqual(list((kdir / "_sessions/requests").glob("*/*.json")), [])
        self.assertFalse([e for e in self.journal(kdir) if e.get("event") == "requested"])
        self.assertFalse(self.supervisors_running())
        self.assertFalse(read_json(kdir / "_work" / item / "_meta.json").get("source_checkout"))

    def test_refusal_offer_declares_the_windows_checkout_and_launches_again(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Offer Fixture", declare=False)
        # A window opened from a shell inside another lore session carries that session's identity.
        identity = dict(LORE_SESSION_INSTANCE="calm-otter-0a1b2c", LORE_SESSION_SLUG="elsewhere",
                        LORE_SESSION_TYPE="chat")
        self.window_env.update(identity)

        window = self.open_window("window", 200, 50, checkout)
        self.wait_screen(window, item)
        self.keys(window, "s")
        self.wait_screen(window, f"Run /spec for {item}?")
        self.keys(window, "Enter")
        self.wait_screen(window, "Launch refused", "declare and launch")
        self.keys(window, "Enter")
        record = self.started(item)
        host = self.wait_ready(kdir)

        # The declaration ran in the window's checkout without the session identity, so it
        # declared that checkout; then the window sent the launch again.
        declared = [c for c in self.window_calls(window) if c["argv"][:2] == ["work", "source-checkout"]]
        self.assertEqual([(c["argv"], c["cwd"], c["session_identity"]) for c in declared],
                         [(["work", "source-checkout", item], str(checkout), [])])
        self.assertEqual(read_json(kdir / "_work" / item / "_meta.json")["source_checkout"], str(checkout))
        launched = [c for c in self.window_calls(window) if c["argv"][:2] == ["session", "request"]]
        self.assertEqual(len(launched), 2, launched)
        self.assertEqual(launched[0]["session_identity"], sorted(identity))
        self.assertLess(declared[0]["at"], launched[1]["at"])
        self.assertEqual(record["instance"], host["instance_name"])
        self.assertEqual(record["values"]["LORE_SESSION_SOURCE_DIR"], str(checkout))
        name = self.hosted(kdir, host, item)["tmux"]
        self.until(lambda: self.viewer_client(window, name), 30, "the launched session's viewer never attached")
        shown = self.wait_screen(window, "? for shortcuts")
        self.assertNotIn("Launch refused", shown)
        self.assert_only_the_store_host(kdir, host)

    def assert_shows_in_full(self, shown, text):
        """Every word of text appears on the screen, in order."""
        position = 0
        for word in text.split():
            found = shown.find(word, position)
            self.assertNotEqual(found, -1, f"{word!r} of the refusal is missing after offset {position}:\n{shown}")
            position = found + len(word)

    def test_quitting_the_tui_leaves_the_session_running(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Quit Fixture")

        window = self.open_window("window", 200, 50, checkout)
        self.wait_screen(window, item)
        self.keys(window, "c")
        self.wait_screen(window, f"Chat about {item}?")
        self.keys(window, "Enter")
        record = self.started(item)
        host = self.wait_ready(kdir)
        name = self.hosted(kdir, host, item)["tmux"]
        viewer = self.until(lambda: self.viewer_client(window, name), 30, "the launched session's viewer never attached")
        self.wait_screen(window, "? for shortcuts")

        tui = self.windows[window]
        self.keys(window, "q")
        self.until(lambda: not alive(tui), 15, "the window did not quit")
        self.until(lambda: not alive(viewer["pid"]), 15, "the window's viewer client outlived it")

        # The session keeps running in the store host, with only the host's client attached.
        self.assertTrue(alive(record["pid"]))
        self.tmux("has-session", "-t", f"={name}")
        self.assertEqual([c["parent"] for c in self.clients(name)], [host["pid"]])
        self.assertEqual(self.ready(kdir)["pid"], host["pid"])
        self.assertIsNotNone(self.hosted(kdir, host, item))
        ended = [e for e in self.journal(kdir) if e.get("slug") == item
                 and e.get("event") in ("closed", "close_requested", "orphaned")]
        self.assertEqual(ended, [])
        self.assertFalse([c for c in self.window_calls(window) if c["argv"][:2] == ["session", "close"]])
        self.lore_json("session", "send", item, "after-the-window-quit", "--wait", cwd=checkout)
        self.until(lambda: self.messages("after-the-window-quit"), 30, "the send never reached the harness")
        self.assertEqual([m["pid"] for m in self.messages("after-the-window-quit")], [record["pid"]])
        _, peek = self.lore_json("session", "peek", item, cwd=checkout)
        self.assertEqual(peek["observation"]["instance"], host["instance_name"])
        self.assertIn("received: after-the-window-quit", "\n".join(peek["rows"]))
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)

    def leave_to_a_dead_old_window(self, kdir, checkout, slug):
        """Leave a store-hosted session the way a lore-tui window from before store
        hosting leaves its sessions when it dies, with nothing running to adopt them.

        The store host and the login supervisor are killed, and the host's registry
        row is rewritten into the row such a window wrote: its own name and pid,
        unkeyed, with no role or scope, naming its checkout in project_dir, stamped
        with this runtime, and listing the surviving session. The session is the
        host's real one, so adoption's checks of its worktree identity, pane pid and
        pane cwd meet what an old window's session has."""
        host = self.wait_ready(kdir)
        instances = kdir / "_sessions/instances"
        # Until the host retires its launch checkpoint, that keyed row would let a new
        # host recover the session as its own instead of adopting the window's.
        self.until(lambda: self.hosted(kdir, host, slug) and not list(instances.glob("spawn-*.json"))
                   and any(e.get("event") == "spawned" and e.get("slug") == slug for e in self.journal(kdir)),
                   30, "the store host never finished launching the session")
        supervisor = read_json(self.login() / "supervisor.json")["pid"]
        os.kill(supervisor, signal.SIGSTOP)
        try:
            os.kill(host["pid"], signal.SIGKILL)
            self.until(lambda: not lock_held(self.host_dir(kdir) / "runtime.lock"), 30, "the store host was not killed")
        finally:
            os.kill(supervisor, signal.SIGKILL)
        self.until(lambda: not lock_held(self.login() / "supervisor.lock"), 10, "the supervisor was not killed")
        self.until(lambda: not alive(host["pid"]) and not alive(supervisor), 10)
        row = read_json(instances / (host["instance_name"] + ".json"))
        (instances / (host["instance_name"] + ".json")).unlink()
        for name in ("host_key", "role", "scope"):
            row.pop(name)
        row.update(name=OLD_WINDOW, project_dir=str(checkout), runtime=self.runtime)
        self.assertEqual([s["slug"] for s in row["sessions"]], [slug])
        (instances / (OLD_WINDOW + ".json")).write_text(json.dumps(row))
        return host, row

    def test_old_window_session_is_adopted_after_ensure(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        self.create_item(kdir, checkout, "Old Window Fixture")
        request = self.request_chat(checkout, "--context", "old window chat")
        slug = request["slug"]
        record = self.started(slug)
        dead_host, row = self.leave_to_a_dead_old_window(kdir, checkout, slug)
        name = row["sessions"][0]["tmux"]
        self.tmux("has-session", "-t", f"={name}")
        self.assertTrue(alive(record["pid"]))
        self.assertFalse(self.supervisors_running())
        self.assertFalse(lock_held(self.login() / "supervisor.lock"))

        window = self.open_window("window", 200, 50, checkout)
        ensured = self.until(lambda: next((c for c in self.window_calls(window)
                                           if c["argv"][:2] == ["session", "ensure"]), None),
                             30, "the window never asked for the store host")
        self.assertEqual(ensured["argv"], ["session", "ensure", "--if-work", "--json", "--kdir", str(kdir)])
        adopted = self.until(lambda: next((e for e in self.journal(kdir) if e.get("event") == "recovered"
                                           and e.get("slug") == slug), None), 60,
                             "the store host never adopted the old window's session")
        host = self.wait_ready(kdir)
        self.assertNotEqual(host["pid"], dead_host["pid"])
        self.assertEqual((adopted["actor_instance"], adopted["target_instance"]), (host["instance_name"], OLD_WINDOW))
        supervisor = read_json(self.login() / "supervisor.json")
        self.assertEqual(self.supervisors_running(), [supervisor["pid"]])
        self.assertGreaterEqual(instant(supervisor["started_at"]), ensured["at"])
        self.assertIn(f"launched host pid {host['pid']} (requested)", self.supervisor_log())
        self.assertEqual(self.hosted(kdir, host, slug)["source_dir"], str(checkout))
        self.assertEqual(list(self.registry(kdir)), [host["instance_name"] + ".json"])

        # The window now lists the adopted session and shows it, and typing reaches the same harness.
        self.keys(window, "v")
        self.wait_screen(window, "Sessions (1)", "chat:" + slug[len("chat-"):])
        self.open_viewer(window, name)
        self.type_line(window, "after-the-adoption")
        self.wait_screen(window, "received: after-the-adoption")
        self.assertEqual([m["pid"] for m in self.messages("after-the-adoption")], [record["pid"]])
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)
        self.assertEqual(len([c for c in self.window_calls(window) if c["argv"][:2] == ["session", "ensure"]]), 1)
        self.assert_only_the_store_host(kdir, host, claimants=[dead_host["instance_name"]])


if __name__ == "__main__":
    unittest.main()
