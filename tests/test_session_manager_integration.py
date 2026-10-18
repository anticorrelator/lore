"""Real host/CLI acceptance with fake coding tools; no model inference.

Run with LORE_SESSION_HOST_BINARY pointing at the built session-host binary.
Each test owns an isolated HOME, LORE_DATA_DIR, knowledge stores, Git
repositories and TMUX_TMPDIR under one temporary root, so its login supervisor,
store hosts and tmux servers never share state with the production runtime.
Teardown stops what that root's login directories and stores record (the login
supervisor first, then each store's host, then every tmux server under the
private TMUX_TMPDIR) and finally any process whose command line or environment
still names the root.
"""
import concurrent.futures
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import site
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("session_runtime", REPO / "scripts/session_runtime.py")
session_runtime = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(session_runtime)
# opencode routes name a provider/model; the other harnesses take a bare model.
MODELS = {"claude-code": "fixture-model", "codex": "fixture-model", "opencode": "fixture/fixture-model"}
# Variables the fake harness reports by value; every other name is reported without its value.
REPORTED_VALUES = ("LORE_KNOWLEDGE_DIR", "LORE_SESSION_SOURCE_DIR", "LORE_SESSION_STORE_ROOT",
                   "LORE_SESSION_HOST_KEY", "LORE_SESSION_RUNTIME", "FIXTURE_CARRIED", "TMUX")
FAKE_HARNESS = r'''#!/usr/bin/env python3
import json, os, select, sys, time, tty
from pathlib import Path
name = Path(sys.argv[0]).name
framework = {"claude": "claude-code", "codex": "codex", "opencode": "opencode"}[name]
log = os.environ["LORE_FAKE_HARNESS_LOG"]
def record(event, **values):
    row = dict(event=event, pid=os.getpid(), framework=framework, **values)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try: os.write(fd, (json.dumps(row) + "\n").encode())
    finally: os.close(fd)
state_path = Path(os.environ["LORE_FAKE_STATE_DIR"]) / os.environ["LORE_SESSION_SLUG"]
state = "composer"
def render(message="ready"):
    rule = "─" * 80
    rows = {
        "claude-code": [rule, "❯ ", rule, "  ? for shortcuts"],
        "codex": ["› ", "gpt-6-astra high · ~/fixture · Main [default]"],
        "opencode": ["┃ Ask anything...", "╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀", "/ commands"],
    }[framework]
    if state == "settled":
        message = {"claude-code": "✻ Worked for 4s", "codex": "─ Worked for 1m 23s ───", "opencode": "▣ Build · GPT-4o mini · 2.3s"}[framework]
        rows += ["Background display refresh " + str(time.monotonic())]
    if state == "working" or state.startswith("history:"):
        rows = ["esc interrupt" if framework == "opencode" else "• Working (4s • esc to interrupt)"] + rows
    elif state == "modal":
        rows = {
            "claude-code": [rule, "Bash command", "Do you want to proceed?", "❯ 1. Yes", "  2. No", "Esc to cancel", rule],
            "codex": ["Would you like to run the following command?", "› 1. Yes, proceed (y)", "  2. No, and tell Codex what to do differently (esc)"],
            "opencode": ["┃ △ Permission required", "╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀", "/ commands", "$ fixture command", "Allow once   Allow always   Reject"],
        }[framework]
    elif state == "unknown":
        rows = ["Unrecognized application screen", "fixture diagnostic: 42"]
    top = max(1, os.get_terminal_size(1).lines - len(rows) - 1)
    os.write(1, ("\x1b[2J\x1b[" + str(top) + ";1H" + message + "\r\n" + "\r\n".join(rows)).encode())
tty.setraw(0)
record("started", argv=sys.argv[1:], cwd=os.getcwd(), instance=os.environ.get("LORE_SESSION_INSTANCE"),
       slug=os.environ.get("LORE_SESSION_SLUG"), env=sorted(os.environ),
       values={key: os.environ.get(key) for key in REPORTED_VALUES})
render()
buffer = b""
while True:
    try:
        requested = state_path.read_text().strip()
    except FileNotFoundError:
        requested = "composer"
    if requested != state:
        state = requested
        if state.startswith("history:"):
            batch = state.split(":", 1)[1]
            output = "\x1b[H\x1b[2J" + "".join("\x1b[32mhistory-" + batch + "-" + str(i).zfill(4) + "\x1b[0m\r\n" for i in range(160))
            os.write(1, output.encode())
            record("history", batch=batch)
        render()
    if not select.select([0], [], [], 0.1)[0]:
        if state == "settled":
            render()
        continue
    chunk = os.read(0, 4096)
    if not chunk: break
    if b"\x04" in chunk or b"\x03" in chunk:
        record("exit")
        break
    buffer += chunk
    if b"\r" in buffer or b"\n" in buffer:
        body = buffer.replace(b"\x1b[200~", b"").replace(b"\x1b[201~", b"").strip(b"\r\n")
        record("message", body=body.decode(errors="replace"), slug=os.environ.get("LORE_SESSION_SLUG"))
        if body == b"kill-owner-after-input":
            store = os.environ.get("LORE_KNOWLEDGE_DIR") or os.environ["LORE_SESSION_STORE_ROOT"]
            for path in (Path(store) / "_sessions/instances").glob("*.json"):
                owner = json.loads(path.read_text())
                if any(row.get("slug") == os.environ["LORE_SESSION_SLUG"] for row in owner.get("sessions", [])):
                    try: os.kill(owner["pid"], 9)
                    except ProcessLookupError: pass
        render("received: " + body.decode(errors="replace"))
        buffer = b""
'''.replace("REPORTED_VALUES", repr(REPORTED_VALUES))

# Calls the CLI's own ensure() in a separate process, so a supervisor it starts
# is never a child of the test process.
ENSURE_SCRIPT = r'''
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("session_managed", sys.argv[1])
managed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(managed)
print(json.dumps(managed.ensure(Path(sys.argv[2]), timeout=float(sys.argv[3]))))
'''

# Builds the pending position preparation the /implement session recipe sends:
# a committed plan revision, a synthesized packet, a compiled worker position
# and the session-worker wrapper, validated by position-bind.py.
PREPARE_POSITION_SCRIPT = r'''
import hashlib, importlib.util, json, runpy, subprocess, sys, textwrap
from pathlib import Path
repo, store, item_slug, slug, attempt, framework, output = sys.argv[1:]
repo, store = Path(repo), Path(store)
item = store / "_work" / item_slug
sys.path.insert(0, str(repo / "scripts"))
spec = importlib.util.spec_from_file_location("position_bind", repo / "scripts/position-bind.py")
binder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binder)
from position_compile import compile_position
from packet_builder import build_packet, pointer, synthesize
def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True)
    if result.returncode:
        raise SystemExit(result.stderr.decode() + result.stdout.decode())
    return result.stdout
(item / "plan.md").write_text(textwrap.dedent("""\
    # Position Fixture

    ## Intent Anchor
    Exercise a position-bearing raw session request.

    **Scope delta:** none

    ## Tasks

    **Merge rationale:** One fixture task.

    ### Task 1: Inspect bytes
    **Deliverable:** Byte identity.
    **Files:** `seed`
    - [ ] Inspect bytes [class: mechanical]
    """))
decisions = item / "decisions.json"
decisions.write_text(json.dumps({
    "anchor_coverage": {"disposition": "covered", "by": "fixture-designer", "note": "Isolated test data."},
    "review_requirement": {"disposition": "not-required", "by": "fixture-designer", "note": "Isolated test data."},
    "dispatch_decision": {"disposition": "proceed", "by": "fixture-coordinator", "note": "Isolated test data.",
                          "task_ids": ["task-1"], "prior_review_refs": []}}))
run(["bash", repo / "scripts/plan-revise.sh", item_slug, "--decisions", decisions])
committed = runpy.run_path(str(repo / "scripts/work-evidence.py"))["publication_for_dispatch"](str(item), str(store))
packet_id = "pkt-" + attempt
build_packet(store, {"packet_id": packet_id, "packet_scope": "task", "work_item": item_slug, "task_id": "task-1",
                     "revision_id": committed["revision_id"], "dispatch_attempt_id": attempt,
                     "source_head": committed["source_head"], "session_id": None, "phase": None, "arm": None,
                     "task_scale_set": "implementation"},
             assembly=("Isolated packet content", {}), role="worker", scales=["implementation"])
synthesize(store, packet_id, by="spec-lead")
bindings = dict.fromkeys(binder.FIELDS)
bindings.update(work_item=item_slug, task_id="task-1", revision_id=committed["revision_id"], packet_id=packet_id,
                packet_pointer=pointer(store, packet_id), dispatch_attempt_id=attempt, assignment="Inspect bytes.\n",
                report_id="report-" + attempt,
                report_path=str(item / "worker-reports" / ("report-" + attempt + ".md")), execution_root=None, mode=None)
bindings["absence_reasons"] = {k: "not applicable to this assignment" for k, v in bindings.items() if v is None}
bindings["absence_reasons"]["execution_root"] = "the claiming session host supplies the root"
guidance = run(["bash", repo / "scripts/render-dispatch-guidance.sh"])
guidance_path = Path(output).with_suffix(".guidance.md")
guidance_path.write_bytes(guidance)
descriptor = compile_position("worker", framework, store, guidance_path)
wrapper_path = repo / "agents/session-worker.md"
wrapper_bytes = wrapper_path.read_bytes()
wrapper = {"template_id": "implement/session-worker", "template_version": hashlib.sha256(wrapper_bytes).hexdigest()[:12],
           "path": str(wrapper_path), "sha256": hashlib.sha256(wrapper_bytes).hexdigest()}
suffix = wrapper_bytes.decode().split("## Session note", 1)[1].split("```\n", 1)[1].split("\n```", 1)[0].encode()
for name, value in {"work item title": "Position Fixture", "task-id": "task-1", "derived-slug": slug, "slug": item_slug,
                    "packet-id": packet_id, "report-id": bindings["report_id"], "subject": "Inspect bytes",
                    "framework": framework}.items():
    suffix = suffix.replace(("<" + name + ">").encode(), value.encode())
prefix = "".join(f"{label}: {bindings[key]}\n" for label, key in [
    ("Packet-id", "packet_id"), ("Report-id", "report_id"), ("Revision-id", "revision_id"),
    ("Dispatch-attempt-id", "dispatch_attempt_id")]).encode()
context = binder.prepare_session_input(descriptor, bindings, store, guidance, slug=slug, wrapper=wrapper,
                                       prefix=prefix, suffix=suffix)
Path(output).write_text(json.dumps(context))
'''

# Stands in for a host and supervisor from before store-scoped hosting that are
# still running: it holds both of the old key's locks until it is killed.
OLD_HOST_SCRIPT = r'''
import fcntl, sys, time
streams = [open(path, "a+") for path in sys.argv[1:]]
for stream in streams:
    fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("holding", flush=True)
while True:
    time.sleep(60)
'''


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def instant(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


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


def command_line(pid, environment=False):
    """The process's command line, and with environment its environment too (macOS ps -E)."""
    result = subprocess.run(["ps", "-ww", *(["-E"] if environment else []), "-o", "command=", "-p", str(pid)],
                            capture_output=True, text=True)
    return result.stdout.strip()


class RuntimeFixture:
    """One private root per test: HOME, LORE_DATA_DIR, stores, checkouts and TMUX_TMPDIR."""

    ROOT_PREFIX = "lore-rt-"

    def open_root(self):
        self.root = Path(tempfile.mkdtemp(prefix=self.ROOT_PREFIX, dir="/tmp")).resolve()
        self.addCleanup(self.release_runtime)
        self.home = self.root / "home"
        self.data = self.home / ".lore"
        self.bin = self.root / "bin"
        self.tmux_dir = self.root / "tmux"
        self.log = self.root / "harness.jsonl"
        self.state_dir = self.root / "states"
        self.stores = []
        self.extra_pids = []
        for directory in (self.data, self.bin, self.tmux_dir, self.state_dir):
            directory.mkdir(parents=True, exist_ok=True)
        (self.data / "scripts").symlink_to(REPO / "scripts", target_is_directory=True)
        (self.bin / "lore").symlink_to(REPO / "cli/lore")
        for binary in ("claude", "codex", "opencode"):
            path = self.bin / binary
            path.write_text(FAKE_HARNESS)
            path.chmod(0o755)
        settings = self.data / "config/settings.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"version": 2, "tui_launch_framework": "claude-code",
            "routes": {"default": "claude-code/fixture-model", "worker": "claude-code/fixture-model"},
            "harnesses": {h: {"enabled": True, "args": [], "autonomous_args": [],
                "native_models": {"default": MODELS[h]}} for h in MODELS}}))

    def base_env(self, runtime, **values):
        """The caller's environment with every location this test owns pointed into its root.

        Lore's own variables from the outer environment never reach the test: a
        LORE_KNOWLEDGE_DIR there would resolve every directory to a real store.
        """
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("LORE_", "TMUX", "GIT_")) or k == "LORE_SESSION_HOST_BINARY"}
        env.update(HOME=str(self.home), LORE_DATA_DIR=str(self.data), TMUX_TMPDIR=str(self.tmux_dir),
                   PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   LORE_FAKE_HARNESS_LOG=str(self.log), LORE_FAKE_STATE_DIR=str(self.state_dir),
                   LORE_SESSION_HOST_IDLE_TIMEOUT="2",
                   # The relocated HOME moves Python's user site; keep the caller's.
                   PYTHONUSERBASE=site.getuserbase())
        if runtime:
            env["LORE_SESSION_RUNTIME"] = runtime
        env.update(values)
        return env

    def assert_private_tmux(self, env):
        """Run before any tmux call: every location the runtime writes lies under this test's root."""
        for name in ("HOME", "LORE_DATA_DIR", "TMUX_TMPDIR"):
            location = Path(env[name]).resolve()
            self.assertTrue(location.is_relative_to(self.root), f"{name} {location} is outside {self.root}")
        socket = Path(env["TMUX_TMPDIR"]).resolve() / f"tmux-{os.getuid()}" / session_runtime.tmux_server(env)
        self.assertLess(len(str(socket)), 104, "tmux socket path exceeds the macOS limit")

    def until(self, predicate, timeout=30, message="condition not reached before deadline"):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        self.fail(message)

    def events(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line]

    def ours(self, pid):
        return alive(pid) and str(self.root) in command_line(pid, environment=True)

    def stop(self, pid, released=None, timeout=10):
        """Stop one recorded process that belongs to this root; wait for its lock to be released."""
        if not self.ours(pid):
            return
        for sig in (signal.SIGTERM, signal.SIGCONT):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                return
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self.ours(pid) and (released is None or not lock_held(released)):
                return
            time.sleep(0.1)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def release_runtime(self):
        # Login supervisors first, so none relaunches a host while the hosts stop.
        for login in [self.data / "session-runtime", *sorted((self.data / "session-runtimes").glob("*"))]:
            self.stop((read_json(login / "supervisor.json") or {}).get("pid"), login / "supervisor.lock")
        for kdir in self.stores:
            sessions = Path(kdir) / "_sessions"
            for directory in [*sessions.glob("hosts/*"), *sessions.glob("runtimes/*/hosts/*")]:
                for name in ("child.json", "ready.json", "supervisor.json"):
                    self.stop((read_json(directory / name) or {}).get("pid"), directory / "runtime.lock")
        for pid in self.extra_pids:
            self.stop(pid)
        for socket in sorted((self.tmux_dir / f"tmux-{os.getuid()}").glob("*")):
            # Only servers whose socket lies under this root are ever addressed.
            if socket.resolve().is_relative_to(self.root):
                subprocess.run(["tmux", "-S", str(socket), "kill-server"], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        stray = self.sweep()
        shutil.rmtree(self.root, ignore_errors=True)
        if stray:
            print(f"\nteardown stopped processes no record named: {stray}", file=sys.stderr)

    def sweep(self, grace=5):
        """Kill any process whose command line or environment still names this root."""
        deadline = time.monotonic() + grace
        while True:
            listing = subprocess.run(["ps", "-ww", "-E", "-axo", "pid=,command="], capture_output=True, text=True).stdout
            stray = {}
            for line in listing.splitlines():
                pid, _, command = line.strip().partition(" ")
                if pid.isdigit() and int(pid) != os.getpid() and str(self.root) in command:
                    stray[int(pid)] = command.split(" ", 1)[0]
            if not stray or time.monotonic() >= deadline:
                break
            time.sleep(0.2)
        for pid in stray:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        return stray


@unittest.skipUnless(os.environ.get("LORE_SESSION_HOST_BINARY") and shutil.which("tmux"),
                     "requires an explicitly built host binary and tmux")
class ManagedSessionIntegration(RuntimeFixture, unittest.TestCase):
    ROOT_PREFIX = "lore-ms-"

    def setUp(self):
        self.open_root()
        self.source = self.root / "source workspace"
        self.kdir = self.root / "store"
        for directory in (self.source, self.kdir):
            directory.mkdir(parents=True)
        self.stores.append(self.kdir)
        self.env = self.base_env(os.environ.get("LORE_SESSION_RUNTIME") or "itest-" + str(os.getpid()),
                                 LORE_KNOWLEDGE_DIR=str(self.kdir))
        self.assert_private_tmux(self.env)
        self.tmux_server = session_runtime.tmux_server(self.env)
        self.hosts = session_runtime.hosts_dir(self.kdir, self.env)
        self.run_command(["git", "init", "-b", "main"], self.source)
        self.run_command(["git", "config", "user.name", "Fixture"], self.source)
        self.run_command(["git", "config", "user.email", "fixture@example.test"], self.source)
        (self.source / "seed").write_text("unchanged\n")
        self.run_command(["git", "add", "seed"], self.source)
        self.run_command(["git", "commit", "-m", "seed"], self.source)
        (self.kdir / "_manifest.json").write_text("{}\n")
        result = self.run_command([str(REPO / "cli/lore"), "work", "create", "--title", "Managed Fixture"], self.source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.item = "managed-fixture"
        self.context = self.root / "brief.txt"
        self.context.write_text("Fixture task: remain available for session-control tests.\n")
        self.handles = []

    def run_command(self, args, cwd=None, timeout=60):
        return subprocess.run(args, cwd=cwd or self.source, env=self.env, text=True,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)

    def session(self, *args, check=True, timeout=60):
        result = self.run_command([str(REPO / "cli/lore"), "session", *args, "--json"], timeout=timeout)
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + "\n" + result.stderr)
        try:
            value = json.loads(result.stdout)
        except ValueError:
            self.fail("non-JSON session response: " + result.stdout + "\n" + result.stderr)
        return result, value

    def peek_activity(self, handle, activity, raw=False):
        def observed():
            _, receipt = self.session("peek", handle, *( ["--raw"] if raw else []))
            snapshot = receipt["response"]
            return snapshot if snapshot["observation"]["activity"] == activity else None
        return self.until(observed)

    def start(self, framework="codex", key="fixture"):
        _, value = self.session("start", self.item, "--workspace", str(self.source),
            "--framework", framework, "--model", MODELS[framework], "--context", str(self.context), "--key", key)
        handle = value["handle"]
        if handle not in self.handles:
            self.handles.append(handle)
        return value

    def tearDown(self):
        for handle in getattr(self, "handles", []):
            try:
                self.session("close", handle, timeout=30, check=False)
            except (subprocess.TimeoutExpired, AssertionError):
                pass

    def test_all_harnesses_share_host_without_a_human_tui(self):
        starts = [self.start(framework, framework) for framework in ("claude-code", "codex", "opencode")]
        self.assertEqual(len({value["handle"] for value in starts}), 3)
        rows = self.until(lambda: self.events() if len([e for e in self.events() if e["event"] == "started"]) == 3 else None)
        started = [row for row in rows if row["event"] == "started"]
        self.assertEqual({row["framework"] for row in started}, {"claude-code", "codex", "opencode"})
        self.assertEqual(len({row["instance"] for row in started}), 1)
        for record in started:
            self.assertIn(MODELS[record["framework"]], record["argv"])
            self.assertNotEqual(record["cwd"], str(self.source))
            self.assertTrue((Path(record["cwd"]) / "seed").exists())
        for value in starts:
            handle = value["handle"]
            self.session("send", handle, "message-" + handle)
        self.until(lambda: len([e for e in self.events() if e["event"] == "message"]) >= 3)
        for value in starts:
            self.session("close", value["handle"])
        for record in started:
            self.assertFalse(Path(record["cwd"]).exists(), "close returned before worktree cleanup")
        self.assertEqual((self.source / "seed").read_text(), "unchanged\n")
        self.until(lambda: not list(self.hosts.glob("*/ready.json")), timeout=20)
        for value in starts:
            _, state = self.session("inspect", value["handle"])
            self.assertTrue(state["disposition"]["cleanup_confirmed"])
            self.assertEqual(state["state"], "closed")

    def test_host_keeps_to_its_runtime(self):
        handle = self.start("codex", "runtime")["handle"]
        self.until(lambda: any(e["event"] == "started" for e in self.events()))
        self.assertTrue(list(self.hosts.glob("*/ready.json")))
        self.assertFalse((self.kdir / "_sessions/hosts").exists())
        listed = self.run_command(["tmux", "-L", self.tmux_server, "list-sessions", "-F", "#{session_name}"])
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertTrue(listed.stdout.strip())
        production = self.run_command(["tmux", "-L", "lore-tui", "list-sessions"])
        self.assertNotEqual(production.returncode, 0, production.stdout)
        # The visible TUI closes with this argument shape (tui/sessions_view.go).
        _, closed = self.session("close", handle, "--reason", "human", "--requested-by", "tui-instance")
        self.assertEqual(closed["outcome"], "closed", closed)

    def test_peek_separates_input_activity_and_modal_evidence(self):
        for framework in ("claude-code", "codex", "opencode"):
            with self.subTest(framework=framework):
                handle = self.start(framework, "observation-" + framework)["handle"]
                self.until(lambda: any(e["event"] == "started" and e["framework"] == framework for e in self.events()))
                control = self.state_dir / handle
                control.write_text("working")
                peek = self.peek_activity(handle, "working")
                obs = peek["observation"]
                self.assertEqual(obs["activity"], "working", peek)
                self.assertTrue(peek["ready"], peek)
                self.assertTrue(obs["can_accept_input"])
                self.assertTrue(obs["fresh"])
                self.assertTrue(obs["generation"])
                self.assertTrue(obs["observed_at"])
                self.assertEqual(peek["framework"], framework)
                self.assertTrue(obs["evidence"]["matcher"])
                _, compact = self.session("peek", handle, "--summary")
                compact = compact["response"]
                self.assertEqual(compact["observation"]["activity"], "working", compact)
                self.assertFalse(compact.get("rows"))
                self.assertFalse(compact.get("ansi"))
                self.assertNotIn("history", compact)
                control.write_text("settled")
                settled = self.peek_activity(handle, "idle")
                self.assertEqual(settled["observation"]["activity"], "idle", settled)
                self.assertTrue(settled["ready"])
                control.write_text("working")
                self.session("send", handle, "steer-" + framework)
                self.until(lambda: any(e.get("body") == "steer-" + framework for e in self.events()))
                control.write_text("modal")
                peek = self.peek_activity(handle, "blocked")
                self.assertEqual(peek["observation"]["activity"], "blocked", peek)
                self.assertFalse(peek["ready"], peek)
                self.assertIn("modal", peek)
                self.assertTrue(peek["rows"])
                count = len([e for e in self.events() if e["event"] == "message"])
                control.write_text("unknown")
                peek = self.peek_activity(handle, "unknown", raw=True)
                self.assertEqual(peek["observation"]["activity"], "unknown", peek)
                self.assertFalse(peek["ready"], peek)
                self.assertIn("fixture diagnostic: 42", "\n".join(peek["rows"]))
                self.assertTrue(peek["ansi"])
                self.assertEqual(len([e for e in self.events() if e["event"] == "message"]), count)
                control.write_text("composer")
                self.session("close", handle)

    def test_peek_history_is_bounded_and_stable_while_output_changes(self):
        handle = self.start("codex", "history")["handle"]
        control = self.state_dir / handle
        control.write_text("history:first")
        self.until(lambda: any(e.get("batch") == "first" for e in self.events()))
        self.peek_activity(handle, "working")
        before_messages = [e for e in self.events() if e["event"] == "message"]
        _, receipt = self.session("peek", handle, "--lines", "50", "--max-bytes", "4096")
        first = receipt["response"]
        history = first["history"]
        self.assertTrue(history["available"], first)
        self.assertTrue(history["more"], first)
        self.assertTrue(history["next_cursor"])
        self.assertLessEqual(history["bytes"], 4096)
        self.assertEqual(first["observation"]["activity"], "working")
        self.assertIn("history-first-", "\n".join(history["rows"]))
        self.assertFalse(first.get("rows"))
        control.write_text("history:second")
        self.until(lambda: any(e.get("batch") == "second" for e in self.events()))
        pages = [history]
        cursor = history["next_cursor"]
        for _ in range(12):
            if not cursor:
                break
            _, receipt = self.session("peek", handle, "--before", cursor, "--lines", "50")
            page = receipt["response"]["history"]
            self.assertEqual(page["snapshot_id"], history["snapshot_id"])
            self.assertEqual(page["end"], pages[-1]["start"])
            self.assertNotIn("history-second-", "\n".join(page["rows"]))
            self.assertLessEqual(page["bytes"], 4096)
            self.assertEqual(receipt["response"]["observation"]["activity"], "working")
            pages.append(page)
            cursor = page.get("next_cursor")
        self.assertFalse(cursor, "bounded snapshot did not finish paging")
        self.assertEqual(pages[-1]["start"], 0)
        _, receipt = self.session("peek", handle, "--lines", "500", "--max-bytes", "128", "--raw")
        bounded = receipt["response"]["history"]
        self.assertLessEqual(bounded["bytes"], 128)
        self.assertTrue(bounded["truncated"] or bounded["more"])
        other = self.start("claude-code", "different-history")["handle"]
        result, _ = self.session("peek", other, "--before", history["next_cursor"], check=False)
        self.assertNotEqual(result.returncode, 0)
        result, _ = self.session("peek", handle, "--before", "not-a-cursor", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([e for e in self.events() if e["event"] == "message"], before_messages)
        current = self.peek_activity(handle, "working")
        self.assertNotIn("history-first-", "\n".join(current["rows"]))

    def test_watcher_recovers_current_state_and_retains_receipt(self):
        handle = self.start("claude-code", "watcher")["handle"]
        self.until(lambda: any(e["event"] == "started" for e in self.events()))
        (self.state_dir / handle).write_text("settled")
        peek = self.peek_activity(handle, "idle")
        self.assertEqual(peek["observation"]["activity"], "idle", peek)
        cursor = self.run_command([str(REPO / "cli/lore"), "session", "events", "--cursor-only"]).stdout.strip()
        args = [str(REPO / "cli/lore"), "coordinate", "watch", "--compact", "--owner-pid", str(os.getpid()),
                "--timeout", "1", "--pending-stale", "0", "--json"]
        first = self.run_command(args + ["--since", cursor], timeout=30)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        wake = json.loads(first.stdout)
        self.assertEqual(wake["outcome"], "current_delta", wake)
        self.assertEqual(wake["tier"], "confirmed", wake)
        self.assertLessEqual(len(first.stdout.encode()), 8192)
        self.assertNotIn('"rows":', first.stdout)
        self.assertNotIn('"ansi":', first.stdout)
        second = self.run_command(args, timeout=30)
        replay = json.loads(second.stdout)
        self.assertEqual(replay["wake_id"], wake["wake_id"])
        ack_args = [str(REPO / "cli/lore"), "coordinate", "status", "--wake-id", wake["wake_id"], "--json"]
        ack = self.run_command(ack_args)
        self.assertEqual(ack.returncode, 0, ack.stdout + ack.stderr)
        self.assertEqual(json.loads(ack.stdout)["wake_receipt"]["wake_id"], wake["wake_id"])
        duplicate = self.run_command(ack_args)
        self.assertEqual(duplicate.returncode, 0, duplicate.stdout + duplicate.stderr)
        self.assertTrue(json.loads(duplicate.stdout)["wake_receipt"]["acknowledged_at"])
        expanded = self.run_command(ack_args + ["--full-evidence"])
        self.assertEqual(expanded.returncode, 0, expanded.stdout + expanded.stderr)
        exact = json.loads(expanded.stdout)["wake_receipt"]["historical_payload"]
        self.assertEqual(exact["outcome"], "current_delta")
        self.assertTrue(exact["current_observations"]["current"][0]["peek"]["rows"])
        quiet = self.run_command(args, timeout=30)
        self.assertEqual(quiet.returncode, 2, quiet.stdout + quiet.stderr)
        quiet_wake = json.loads(quiet.stdout)
        self.assertEqual(quiet_wake["tier"], "quiet", quiet_wake)
        self.assertNotEqual(quiet_wake["wake_id"], wake["wake_id"])
        self.assertFalse([e for e in self.events() if e["event"] == "message"])

    def test_idempotent_start_and_conflicting_intent(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(lambda _: self.start(key="same"), range(2)))
        self.assertEqual(values[0]["handle"], values[1]["handle"])
        self.until(lambda: any(e["event"] == "started" for e in self.events()))
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)
        result, _ = self.session("start", self.item, "--workspace", str(self.source), "--framework", "codex",
            "--model", "different-model", "--context", str(self.context), "--key", "same", check=False)
        self.assertNotEqual(result.returncode, 0)

    def test_host_crash_after_input_never_replays_uncertain_delivery(self):
        value = self.start()
        original = self.until(lambda: next((e for e in self.events() if e["event"] == "started"), None))
        result, receipt = self.session("send", value["handle"], "kill-owner-after-input", check=False, timeout=90)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(receipt["outcome"], "uncertain")
        self.assertEqual(receipt["event"]["reason"], "delivery-uncertain")
        self.session("send", value["handle"], "after-uncertain")
        messages = [e for e in self.events() if e["event"] == "message"]
        self.assertEqual(sum(e["body"] == "kill-owner-after-input" for e in messages), 1)
        self.assertTrue(all(e["pid"] == original["pid"] for e in messages))
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)
        _, state = self.session("inspect", value["handle"])
        saved = next(r for r in state["receipts"] if r["request_id"] == receipt["request_id"])
        self.assertEqual(saved["outcome"], "uncertain")
        self.session("close", value["handle"])
        self.assertFalse(Path(original["cwd"]).exists())

    def test_host_crash_recovers_same_harness_and_handle(self):
        value = self.start()
        handle = value["handle"]
        original = self.until(lambda: next((e for e in self.events() if e["event"] == "started"), None))
        registry = self.kdir / "_sessions/instances" / (original["instance"] + ".json")
        owner = json.loads(registry.read_text())
        _, before = self.session("peek", handle)
        before = before["response"]
        os.kill(owner["pid"], signal.SIGKILL)
        # No TUI selection or recovery verb: the next normal operation owns recovery.
        self.session("send", handle, "after-recovery", timeout=90)
        received = self.until(lambda: next((e for e in self.events() if e["event"] == "message" and e.get("body") == "after-recovery"), None))
        self.assertEqual(received["pid"], original["pid"], "history restart substituted for live-process recovery")
        _, after = self.session("peek", handle)
        after = after["response"]
        self.assertEqual(after["observation"]["generation"], before["observation"]["generation"])
        self.assertNotEqual(after["observation"]["instance"], before["observation"]["instance"])
        self.assertEqual(after["slug"], handle)
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)
        self.session("close", handle)
        self.assertFalse(Path(original["cwd"]).exists())


@unittest.skipUnless(os.environ.get("LORE_SESSION_HOST_BINARY") and shutil.which("tmux"),
                     "requires an explicitly built host binary and tmux")
class LoginRuntimeIntegration(RuntimeFixture, unittest.TestCase):
    """The per-login runtime end to end: one supervisor per login, one store host
    per store, real tmux, and no visible TUI unless a scenario starts one.

    Stores live where lore resolves them, under $LORE_DATA_DIR/repos/<remote>,
    and no LORE_KNOWLEDGE_DIR is set, so every checkout reaches its store through
    the same resolution a real caller uses. Scenarios run under a named
    LORE_SESSION_RUNTIME except the ones about host keys from before store
    scope, which run in the default runtime because only it migrates those keys;
    their private TMUX_TMPDIR keeps even the default server name inside the root.
    """

    ROOT_PREFIX = "lore-lr-"

    def setUp(self):
        self.open_root()
        self.brief = self.root / "brief.txt"
        self.brief.write_text("Fixture task: remain available for login-runtime tests.\n")
        self.use_runtime(os.environ.get("LORE_SESSION_RUNTIME") or "itest-" + str(os.getpid()))

    def use_runtime(self, runtime, **values):
        values.setdefault("LORE_SESSION_SUPERVISOR_QUIET_SECONDS", "600")
        self.runtime = runtime
        self.env = self.base_env(runtime, **values)
        self.assert_private_tmux(self.env)
        self.binary = Path(self.env["LORE_SESSION_HOST_BINARY"]).resolve()

    def make_store(self, name):
        kdir = self.data / "repos/example.test" / name
        kdir.mkdir(parents=True)
        (kdir / "_manifest.json").write_text("{}\n")
        self.stores.append(kdir)
        return kdir

    def git(self, cwd, *args):
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True,
                                stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def make_checkout(self, store_name, dirname, clone_of=None):
        path = self.root / dirname
        if clone_of:
            self.git(self.root, "clone", "-q", str(clone_of), str(path))
            self.git(path, "remote", "set-url", "origin", f"https://example.test/{store_name}.git")
        else:
            path.mkdir()
            self.git(path, "init", "-q", "-b", "main")
            self.git(path, "remote", "add", "origin", f"https://example.test/{store_name}.git")
        self.git(path, "config", "user.name", "Fixture")
        self.git(path, "config", "user.email", "fixture@example.test")
        if not clone_of:
            (path / "seed").write_text("unchanged\n")
            self.git(path, "add", "seed")
            self.git(path, "commit", "-q", "-m", "seed")
        return path

    def create_item(self, kdir, checkout, title):
        result = self.lore("work", "create", "--title", title, cwd=checkout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        slug = title.lower().replace(" ", "-")
        self.assertTrue((kdir / "_work" / slug / "_meta.json").is_file(), result.stdout)
        return slug

    def declare_checkout(self, kdir, item, checkout):
        status = self.ensure_host(kdir)
        result = self.lore("work", "source-checkout", item, "--from-instance", status["instance_name"],
                           "--json", cwd=checkout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(read_json(kdir / "_work" / item / "_meta.json")["source_checkout"], str(checkout))

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

    def ensure_host(self, kdir, env=None, timeout=60):
        result = subprocess.run([sys.executable, "-c", ENSURE_SCRIPT, str(REPO / "scripts/session-managed.py"),
                                 str(kdir), str(timeout)], cwd=self.root, env=env or self.env, text=True,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout + 30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def position_context(self, kdir, checkout, item, slug, attempt):
        """The context file of a position-bearing request for slug, as the /implement recipe prepares it."""
        context = self.root / (attempt + ".context.json")
        prepared = subprocess.run([sys.executable, "-c", PREPARE_POSITION_SCRIPT, str(REPO), str(kdir), item, slug,
                                   attempt, "claude-code", str(context)],
                                  cwd=checkout, env=self.env, capture_output=True, text=True, timeout=300)
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        self.assertEqual(set(read_json(context)), {"position_preparation"})
        return context

    def assert_position_launched(self, kdir, item, attempt, record):
        """The claiming host published the preparation for the worktree the session runs in."""
        manifest = read_json(kdir / "_work" / item / "position-dispatch" / attempt / "manifest.json")
        self.assertEqual(Path(manifest["bindings"]["execution_root"]).resolve(), Path(record["cwd"]).resolve())

    def raw_request(self, checkout, slug, *extra, env=None):
        _, value = self.lore_json("session", "request", "--type", "worker", "--slug", slug, "--anywhere",
                                  "--initiator", "agent", *extra, cwd=checkout, env=env)
        return value

    def start(self, kdir, item, checkout, key):
        _, value = self.lore_json("session", "start", item, "--workspace", str(checkout),
                                  "--context", str(self.brief), "--key", key, cwd=checkout)
        return value["handle"]

    def send(self, checkout, slug, body, managed=False, timeout=90):
        args = ["session", "send", slug, body, *(["--timeout", str(timeout)] if managed else ["--wait"])]
        _, value = self.lore_json(*args, cwd=checkout, timeout=timeout + 30)
        if managed:
            self.assertEqual(value["outcome"], "sent", value)
        self.until(lambda: any(e["event"] == "message" and e.get("body") == body for e in self.events()),
                   message=f"{body!r} never reached the harness")
        return value

    def login(self, env=None):
        return session_runtime.login_dir(env or self.env)

    def key(self, kdir, env=None):
        return session_runtime.store_host_key(kdir, env or self.env)

    def host_dir(self, kdir, env=None):
        env = env or self.env
        return session_runtime.hosts_dir(kdir, env) / session_runtime.store_host_key(kdir, env)

    def ready(self, kdir, env=None):
        record = read_json(self.host_dir(kdir, env) / "ready.json")
        return record if record and record.get("ready") and alive(record.get("pid")) else None

    def wait_ready(self, kdir, env=None, timeout=60):
        return self.until(lambda: self.ready(kdir, env), timeout, f"the store host for {kdir} never became ready")

    def wait_withdrawn(self, kdir, pid, timeout=30):
        """The host with pid withdrew idle and the supervisor saw its exit 0."""
        directory = self.host_dir(kdir)
        def withdrawn():
            child = read_json(directory / "child.json") or {}
            return (not (directory / "ready.json").exists() and child.get("pid") == pid
                    and child.get("exit_code") == 0 and not alive(pid))
        self.until(withdrawn, timeout, f"host {pid} of {kdir} did not withdraw idle")
        return read_json(directory / "child.json")

    def supervisor_pid(self):
        record = read_json(self.login() / "supervisor.json") or {}
        self.assertTrue(alive(record.get("pid")), record)
        self.assertTrue(lock_held(self.login() / "supervisor.lock"))
        return record["pid"]

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

    def assert_worktree_of(self, record, checkout, kdir):
        cwd = Path(record["cwd"])
        self.assertTrue(cwd.is_relative_to(kdir / "_sessions/worktrees"), record)
        common = self.git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
        self.assertEqual(Path(common).resolve(), (checkout / ".git").resolve(), record)
        self.assertEqual(record["values"]["LORE_SESSION_SOURCE_DIR"], str(checkout), record)

    def test_login_runtime_contract(self):
        self.use_runtime(self.runtime, LORE_SESSION_HOST_IDLE_TIMEOUT="8", LORE_SESSION_SUPERVISOR_QUIET_SECONDS="3")
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        key = self.key(kdir)
        directory = self.host_dir(kdir)
        server = session_runtime.tmux_server(self.env)
        self.assertNotEqual(subprocess.run(["tmux", "-L", server, "list-sessions"], env=self.env,
                                           capture_output=True).returncode, 0)

        # Both refusals come before the host touches tmux or the store, so nothing is created.
        scratch = self.root / "refused"
        for argv in (["--session-host", "--source-dir", str(checkout), "--host-key", key, "--kdir", str(kdir),
                      "--ready-file", str(scratch / "a/ready.json"), "--runtime", self.runtime],
                     ["--session-host", "--scope", "store", "--host-key", "0" * 24, "--kdir", str(kdir),
                      "--ready-file", str(scratch / "b/ready.json"), "--idle-timeout", "8", "--runtime", self.runtime]):
            refused = subprocess.run([str(self.binary), *argv], env=self.env, cwd=self.root, capture_output=True,
                                     text=True, stdin=subprocess.DEVNULL, timeout=30)
            self.assertEqual(refused.returncode, 2, refused.stdout + refused.stderr)
        self.assertFalse(scratch.exists())

        status = self.ensure_host(kdir)
        login = self.login()
        self.assertEqual(login, self.data / "session-runtimes" / self.runtime)
        supervisor = read_json(login / "supervisor.json")
        self.assertTrue(alive(supervisor["pid"]))
        self.assertTrue(lock_held(login / "supervisor.lock"))
        self.assertEqual(supervisor["runtime"], self.runtime)
        self.assertEqual(supervisor["tmux_tmpdir"], str(self.tmux_dir))
        self.assertEqual(set(supervisor["scripts"]), {"session-managed.py", "session_runtime.py"})
        served = read_json(login / "served.json")
        self.assertEqual(set(served["stores"]), {str(kdir)})
        self.assertIs(served["stores"][str(kdir)]["pin_knowledge_dir"], False)
        self.assertTrue(served["stores"][str(kdir)]["wanted_at"])

        ready = read_json(directory / "ready.json")
        self.assertEqual(set(ready), {"schema_version", "scope", "host_key", "instance_name", "pid", "knowledge_dir",
                                      "ready", "runtime_capabilities", "build_sha", "build_time"})
        self.assertEqual((ready["schema_version"], ready["scope"], ready["host_key"], ready["ready"]),
                         (2, "store", key, True))
        self.assertEqual(ready["knowledge_dir"], str(kdir))
        self.assertIn("position-preparation-v1", ready["runtime_capabilities"])
        self.assertEqual((status["pid"], status["instance_name"], status["scope"]),
                         (ready["pid"], ready["instance_name"], "store"))
        self.assertTrue(lock_held(directory / "runtime.lock"))

        row = read_json(kdir / "_sessions/instances" / (ready["instance_name"] + ".json"))
        self.assertEqual((row["role"], row["host_key"], row["scope"], row["runtime"], row["pid"], row["repo"]),
                         ("session-host", key, "store", self.runtime, ready["pid"], "example.test/alpha"))
        self.assertNotIn("project_dir", row)

        child = read_json(directory / "child.json")
        self.assertEqual((child["pid"], child["supervisor_pid"], child["binary"]),
                         (ready["pid"], supervisor["pid"], str(self.binary)))
        self.assertEqual(child["binary_identity"]["inode"], os.stat(self.binary).st_ino)
        argv = command_line(ready["pid"]).split()
        expected = ["--session-host", "--scope", "store", "--host-key", key, "--kdir", str(kdir),
                    "--ready-file", str(directory / "ready.json"), "--idle-timeout", "8", "--runtime", self.runtime]
        self.assertEqual(argv[1:], expected)

        listed = self.lore("session", "list", cwd=checkout)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn(f"instance {ready['instance_name']} (pid {ready['pid']}) — store host serving every checkout "
                      f"of {kdir}", listed.stdout)
        _, inventory = self.lore_json("session", "list", cwd=checkout)
        self.assertEqual([r["name"] for r in inventory["instances"] if r.get("scope") == "store"],
                         [ready["instance_name"]])

        child = self.wait_withdrawn(kdir, ready["pid"], timeout=30)
        self.assertTrue(child["exited_at"])
        self.assertFalse(lock_held(directory / "runtime.lock"))
        self.until(lambda: not lock_held(login / "supervisor.lock"), 30, "the supervisor did not quiet out")
        self.assertIn(f"supervisor {supervisor['pid']} exiting", self.supervisor_log())
        self.until(lambda: not self.supervisors_running(), 10, "the supervisor process outlived its lock")

    def test_raw_requests_run_on_the_store_host_with_no_tui(self):
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Raw Fixture")
        self.declare_checkout(kdir, item, checkout)
        key = self.key(kdir)

        plain = self.raw_request(checkout, item + "--w1", "--context", str(self.brief))
        self.assertEqual((plain["host_key"], plain["required_project_dir"], plain["placement_stance"]),
                         (key, str(checkout), "required_dir"), plain)

        # The pending preparation the /implement session recipe enqueues, built by the real binder.
        context = self.position_context(kdir, checkout, item, item + "--w2", "attempt-raw-1")
        positioned = self.raw_request(checkout, item + "--w2", "--session-route", "claude-code/fixture-model",
                                      "--context", str(context))
        self.assertEqual((positioned["host_key"], positioned["required_project_dir"]), (key, str(checkout)), positioned)

        records = [self.started(item + "--w1"), self.started(item + "--w2")]
        ready = self.wait_ready(kdir)
        for record in records:
            self.assert_worktree_of(record, checkout, kdir)
            self.assertEqual(record["instance"], ready["instance_name"], record)
            self.assertEqual(record["values"]["LORE_SESSION_HOST_KEY"], key, record)
        self.assert_position_launched(kdir, item, "attempt-raw-1", records[1])

        rows = [read_json(p) for p in (kdir / "_sessions/instances").glob("*.json")]
        self.assertTrue(rows)
        self.assertTrue(all(r.get("host_key") == key and r.get("role", "").startswith("session-host") for r in rows), rows)

        for slug in (item + "--w1", item + "--w2"):
            self.send(checkout, slug, "hello-" + slug)
            self.assertEqual([m["pid"] for m in self.messages("hello-" + slug)],
                             [next(r["pid"] for r in records if r["slug"] == slug)])
        _, peek = self.lore_json("session", "peek", item + "--w1", cwd=checkout)
        self.assertEqual((peek["slug"], peek["observation"]["instance"]), (item + "--w1", ready["instance_name"]), peek)
        self.assertIn("received: hello-" + item + "--w1", "\n".join(peek["rows"]))

    def test_raw_request_relaunches_a_store_host_that_withdrew_idle(self):
        """Once while the supervisor sits in its quiet period, once while it serves another store."""
        alpha, beta = self.make_store("alpha"), self.make_store("beta")
        alpha_one = self.make_checkout("alpha", "alpha-one")
        beta_one = self.make_checkout("beta", "beta-one")
        alpha_item = self.create_item(alpha, alpha_one, "Alpha Fixture")
        beta_item = self.create_item(beta, beta_one, "Beta Fixture")
        self.declare_checkout(alpha, alpha_item, alpha_one)
        self.declare_checkout(beta, beta_item, beta_one)
        supervisor = self.supervisor_pid()
        first = read_json(self.host_dir(alpha) / "child.json")["pid"]
        self.wait_withdrawn(alpha, first)
        self.wait_withdrawn(beta, read_json(self.host_dir(beta) / "child.json")["pid"])

        self.assertEqual(self.supervisor_pid(), supervisor)
        self.raw_request(alpha_one, alpha_item + "--w1", "--context", str(self.brief))
        record = self.started(alpha_item + "--w1")
        relaunched = self.wait_ready(alpha)["pid"]
        self.assertNotEqual(relaunched, first)
        self.assertIn(f"launched host pid {relaunched} (requested)", self.supervisor_log())
        self.assert_worktree_of(record, alpha_one, alpha)
        self.send(alpha_one, alpha_item + "--w1", "after-quiet-withdraw")

        self.raw_request(beta_one, beta_item + "--w1", "--context", str(self.brief))
        self.started(beta_item + "--w1")
        beta_host = self.wait_ready(beta)["pid"]
        self.lore_json("session", "close", alpha_item + "--w1", cwd=alpha_one)
        self.wait_withdrawn(alpha, relaunched)
        self.assertEqual(self.ready(beta)["pid"], beta_host)
        context = self.position_context(alpha, alpha_one, alpha_item, alpha_item + "--w2", "attempt-relaunch-1")
        self.raw_request(alpha_one, alpha_item + "--w2", "--session-route", "claude-code/fixture-model",
                         "--context", str(context))
        record = self.started(alpha_item + "--w2")
        again = self.wait_ready(alpha)["pid"]
        self.assertNotIn(again, (first, relaunched))
        self.assert_worktree_of(record, alpha_one, alpha)
        self.assert_position_launched(alpha, alpha_item, "attempt-relaunch-1", record)
        self.send(alpha_one, alpha_item + "--w2", "while-serving-beta")
        self.assertEqual(self.ready(beta)["pid"], beta_host)
        self.assertEqual(self.supervisor_pid(), supervisor)
        self.assertEqual(self.supervisors_running(), [supervisor])

    def test_two_checkouts_and_a_second_store_share_one_supervisor(self):
        alpha, beta = self.make_store("alpha"), self.make_store("beta")
        alpha_one = self.make_checkout("alpha", "alpha-one")
        alpha_two = self.make_checkout("alpha", "alpha-two", clone_of=alpha_one)
        beta_one = self.make_checkout("beta", "beta-one")
        items = {alpha_one: self.create_item(alpha, alpha_one, "Alpha One"),
                 alpha_two: self.create_item(alpha, alpha_two, "Alpha Two"),
                 beta_one: self.create_item(beta, beta_one, "Beta One")}
        stores = {alpha_one: alpha, alpha_two: alpha, beta_one: beta}
        handles = {checkout: self.start(stores[checkout], item, checkout, "share-" + item)
                   for checkout, item in items.items()}
        records = {checkout: self.started(handle) for checkout, handle in handles.items()}

        supervisor = self.supervisor_pid()
        self.assertEqual(self.supervisors_running(), [supervisor])
        hosts = {}
        for kdir in (alpha, beta):
            ready = self.wait_ready(kdir)
            hosts[kdir] = ready["instance_name"]
            self.assertEqual(read_json(self.host_dir(kdir) / "child.json")["supervisor_pid"], supervisor)
            _, inventory = self.lore_json("session", "list", cwd=alpha_one if kdir == alpha else beta_one)
            store_hosts = [r for r in inventory["instances"] if r.get("scope") == "store"]
            self.assertEqual([r["name"] for r in store_hosts], [ready["instance_name"]], inventory)
            self.assertEqual(sorted(s["slug"] for s in store_hosts[0]["sessions"]),
                             sorted(h for c, h in handles.items() if stores[c] == kdir))
        self.assertNotEqual(hosts[alpha], hosts[beta])
        for checkout, record in records.items():
            self.assert_worktree_of(record, checkout, stores[checkout])
            self.assertEqual(record["instance"], hosts[stores[checkout]])
            _, state = self.lore_json("session", "inspect", handles[checkout], cwd=checkout)
            self.assertEqual(state["host_key"], self.key(stores[checkout]))
            self.assertEqual(state["owner"]["instance_name"], hosts[stores[checkout]])
            self.send(checkout, handles[checkout], "hello-" + items[checkout], managed=True)
        served = read_json(self.login() / "served.json")
        self.assertEqual(set(served["stores"]), {str(alpha), str(beta)})

    def legacy_key(self, kdir, checkout):
        """The host key a per-checkout host from before store scope used."""
        return hashlib.sha256((str(kdir) + "\0" + str(checkout)).encode()).hexdigest()[:24]

    def leave_uncertain_send_on_a_dead_host(self, kdir, checkout, handle):
        """Send input the harness answers by killing its owner, with nothing left to recover it.

        The supervisor is stopped first, so it neither relaunches the host nor
        settles the delivery: the store host's ledger keeps the attempted,
        unterminated record a crash leaves behind.
        """
        ready = self.wait_ready(kdir)
        supervisor = self.supervisor_pid()
        os.kill(supervisor, signal.SIGSTOP)
        try:
            result, receipt = self.lore_json("session", "send", handle, "kill-owner-after-input", "--timeout", "8",
                                             cwd=checkout, timeout=60, check=False)
            self.assertEqual(receipt["outcome"], "uncertain", receipt)
            self.until(lambda: not lock_held(self.host_dir(kdir) / "runtime.lock"), 30, "the host was not killed")
        finally:
            os.kill(supervisor, signal.SIGKILL)
        self.until(lambda: not lock_held(self.login() / "supervisor.lock"), 10)
        record = read_json(self.host_dir(kdir) / "deliveries" / (receipt["request_id"] + ".json"))
        self.assertEqual((record["kind"], record["terminal"], record["event"]["reason"]),
                         ("send", False, "delivery-uncertain"), record)
        self.assertEqual(len(self.messages("kill-owner-after-input")), 1)
        return ready, supervisor, receipt["request_id"]

    def regress_to_legacy_key(self, kdir, checkout, handle, ready, supervisor):
        """Rewrite one store host's records into the shape a per-checkout host from
        before store scope left: its key directory with ready.json naming source_dir,
        a registry row naming project_dir, and the manifest on that key."""
        store_key, key = self.key(kdir), self.legacy_key(kdir, checkout)
        hosts = kdir / "_sessions/hosts"
        old = hosts / key
        (hosts / store_key).rename(old)
        for name in ("child.json", "restart.json", "supervisor-error.json"):
            (old / name).unlink(missing_ok=True)
        for path in old.rglob("*.json"):
            path.write_text(path.read_text().replace(store_key, key))
        (old / "ready.json").write_text(json.dumps({
            "schema_version": 1, "host_key": key, "instance_name": ready["instance_name"], "pid": ready["pid"],
            "source_dir": str(checkout), "knowledge_dir": str(kdir), "ready": True,
            "runtime_capabilities": ready["runtime_capabilities"]}))
        (old / "supervisor.json").write_text(json.dumps({"pid": supervisor, "host_key": key,
                                                         "started_at": "2026-10-01T00:00:00Z"}))
        for name in ("runtime.lock", "supervisor.lock", "ensure.lock"):
            (old / name).touch()
        registry = kdir / "_sessions/instances" / (ready["instance_name"] + ".json")
        row = json.loads(registry.read_text().replace(store_key, key))
        row.pop("scope", None)
        row.pop("runtime", None)
        row["project_dir"] = str(checkout)
        registry.write_text(json.dumps(row))
        manifest_path = kdir / "_sessions/managed" / (handle + ".json")
        manifest_path.write_text(manifest_path.read_text().replace(store_key, key))
        for state in ("pending", "claimed"):
            for path in (kdir / "_sessions/requests" / state).glob("*.json"):
                path.write_text(path.read_text().replace(store_key, key))
        # Per-login state did not exist before store-scoped hosting.
        shutil.rmtree(self.login())
        self.assertFalse((hosts / store_key).exists())
        return key

    def test_dead_legacy_host_key_is_migrated_before_the_store_host_serves(self):
        """The next ordinary operation starts the supervisor, which migrates the key before launching the host."""
        self.use_runtime("")
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Legacy Fixture")
        handle = self.start(kdir, item, checkout, "legacy")
        original = self.started(handle)
        ready, supervisor, rid = self.leave_uncertain_send_on_a_dead_host(kdir, checkout, handle)
        key = self.regress_to_legacy_key(kdir, checkout, handle, ready, supervisor)
        store_key = self.key(kdir)
        _, before = self.lore_json("session", "inspect", handle, cwd=checkout)
        self.assertEqual((before["host_key"], before["owner"]), (key, None))

        self.send(checkout, handle, "after-migration", managed=True)
        tombstone = read_json(kdir / "_sessions/hosts" / key / "migrated.json")
        self.assertEqual((tombstone["from"], tombstone["to"]), (key, store_key))
        child = read_json(self.host_dir(kdir) / "child.json")
        self.assertLessEqual(instant(tombstone["at"]), instant(child["launched_at"]))
        self.assertIn(f"migrated host key {key} to {store_key}", self.supervisor_log())
        copied = read_json(self.host_dir(kdir) / "deliveries" / (rid + ".json"))
        self.assertTrue(copied["terminal"] and copied["committed"], copied)

        _, after = self.lore_json("session", "inspect", handle, cwd=checkout)
        self.assertEqual(after["host_key"], store_key)
        self.assertEqual(after["owner"]["instance_name"], self.ready(kdir)["instance_name"])
        self.assertEqual(after["state"], "running")
        saved = next(r for r in after["receipts"] if r["request_id"] == rid)
        self.assertEqual(saved["outcome"], "uncertain", saved)
        settled = [e for e in self.journal(kdir) if e.get("request_id") == rid and e.get("event") == "send_refused"]
        self.assertEqual([e.get("reason") for e in settled], ["delivery-uncertain"])
        self.assertTrue(any(e.get("event") == "recovered" and e.get("slug") == handle for e in self.journal(kdir)))
        self.assertEqual(len(self.messages("kill-owner-after-input")), 1)
        self.assertEqual([m["pid"] for m in self.messages("after-migration")], [original["pid"]])
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)
        self.assertTrue(Path(original["cwd"]).is_dir())

    def test_legacy_host_dying_while_the_store_host_serves_is_recovered_in_place(self):
        """The old key is left alone while its host runs, then migrated and adopted without a host restart."""
        self.use_runtime("")
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Legacy Fixture")
        old_handle = self.start(kdir, item, checkout, "legacy")
        original = self.started(old_handle)
        ready, supervisor, rid = self.leave_uncertain_send_on_a_dead_host(kdir, checkout, old_handle)
        key = self.regress_to_legacy_key(kdir, checkout, old_handle, ready, supervisor)
        old = kdir / "_sessions/hosts" / key
        holder = subprocess.Popen([sys.executable, "-c", OLD_HOST_SCRIPT, str(old / "runtime.lock"),
                                   str(old / "supervisor.lock")], stdout=subprocess.PIPE, text=True)
        self.extra_pids.append(holder.pid)
        self.addCleanup(lambda: (holder.kill(), holder.wait(), holder.stdout.close()))
        self.assertEqual(holder.stdout.readline().strip(), "holding")
        registry = kdir / "_sessions/instances" / (ready["instance_name"] + ".json")
        registry.write_text(json.dumps(dict(read_json(registry), pid=holder.pid)))
        (old / "ready.json").write_text(json.dumps(dict(read_json(old / "ready.json"), pid=holder.pid)))

        new_handle = self.start(kdir, item, checkout, "fresh")
        self.started(new_handle)
        serving = self.wait_ready(kdir)["pid"]
        self.until(lambda: f"not migrating host key {key}: its host or supervisor from before store-scoped "
                           "hosting is still running" in self.supervisor_log(), 10)
        self.assertFalse((old / "migrated.json").exists())
        self.assertEqual(read_json(kdir / "_sessions/managed" / (old_handle + ".json"))["host_key"], key)

        holder.kill()
        holder.wait()
        self.until(lambda: (old / "migrated.json").exists(), 15, "the old key was not migrated after its host died")
        self.send(checkout, old_handle, "after-old-host-died", managed=True, timeout=120)
        self.assertEqual(self.ready(kdir)["pid"], serving)
        self.assertEqual(len(self.messages("kill-owner-after-input")), 1)
        self.assertEqual([m["pid"] for m in self.messages("after-old-host-died")], [original["pid"]])
        _, state = self.lore_json("session", "inspect", old_handle, cwd=checkout)
        self.assertEqual(state["host_key"], self.key(kdir))
        self.assertEqual(next(r for r in state["receipts"] if r["request_id"] == rid)["outcome"], "uncertain")
        self.send(checkout, new_handle, "new-session-unaffected", managed=True)
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 2)

    def test_binary_swap_drains_the_host_while_an_idle_session_survives(self):
        built = self.binary
        private = self.root / "hostbin/lore-tui"
        private.parent.mkdir()
        shutil.copy2(built, private)
        self.use_runtime(self.runtime, LORE_SESSION_HOST_BINARY=str(private))
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        item = self.create_item(kdir, checkout, "Swap Fixture")
        handle = self.start(kdir, item, checkout, "swap")
        original = self.started(handle)
        before = self.wait_ready(kdir)
        first = read_json(self.host_dir(kdir) / "child.json")
        self.assertEqual(first["binary_identity"]["inode"], os.stat(private).st_ino)

        replacement = private.with_name(".lore-tui.new")
        shutil.copy2(built, replacement)
        os.replace(replacement, private)
        swapped = os.stat(private).st_ino
        self.assertNotEqual(swapped, first["binary_identity"]["inode"])
        after = self.until(lambda: (lambda r: r if r and r["pid"] != before["pid"] else None)(self.ready(kdir)),
                           90, "the host was not restarted onto the new binary")
        log = self.supervisor_log()
        self.assertIn(f"changed; asked host pid {before['pid']} to restart", log)
        self.assertIn(f"host pid {before['pid']} drained for a restart; relaunching it", log)
        self.assertEqual(read_json(self.host_dir(kdir) / "child.json")["binary_identity"]["inode"], swapped)
        self.assertFalse((self.host_dir(kdir) / "restart.json").exists())

        self.assertTrue(alive(original["pid"]))
        self.send(checkout, handle, "after-swap", managed=True)
        self.assertEqual([m["pid"] for m in self.messages("after-swap")], [original["pid"]])
        _, peek = self.lore_json("session", "peek", handle, cwd=checkout)
        self.assertEqual(peek["response"]["observation"]["instance"], after["instance_name"])
        self.assertIn("received: after-swap", "\n".join(peek["response"]["rows"]))
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)

    def test_store_host_adopts_a_dead_tui_session(self):
        """A real lore-tui claims an unkeyed chat request and dies; with no command from anyone, the
        supervisor counts its rows as work and the store host adopts the session."""
        kdir = self.make_store("alpha")
        checkout = self.make_checkout("alpha", "alpha-one")
        self.create_item(kdir, checkout, "Tui Fixture")
        first = self.ensure_host(kdir)
        supervisor = self.supervisor_pid()
        self.wait_withdrawn(kdir, first["pid"])

        tui_env = {k: v for k, v in self.env.items()
                   if not k.startswith(("CLAUDE", "CODEX_", "OPENCODE_")) and k not in ("AI_AGENT", "CLAUDECODE")}
        server = session_runtime.tmux_server(self.env)
        launch = ["tmux", "-L", server, "new-session", "-d", "-s", "visible-tui", "-x", "200", "-y", "50",
                  "-c", str(checkout)]
        for name, value in tui_env.items():
            launch += ["-e", f"{name}={value}"]
        result = subprocess.run([*launch, str(self.binary)], env=tui_env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        tui = self.until(lambda: next((r for r in map(read_json, (kdir / "_sessions/instances").glob("*.json"))
                                       if r and not r.get("host_key") and alive(r.get("pid"))), None),
                         30, "the visible TUI never registered")
        self.assertEqual((tui["runtime"], tui["project_dir"]), (self.runtime, str(checkout)))
        _, request = self.lore_json("session", "request", "--type", "chat", "--anywhere", "--context", "hello",
                                    cwd=checkout)
        self.assertNotIn("host_key", request)
        slug = request["slug"]
        record = self.started(slug)
        self.assertEqual(record["instance"], tui["name"])

        os.kill(tui["pid"], signal.SIGKILL)
        adopted = self.until(lambda: next((e for e in self.journal(kdir) if e.get("event") == "recovered"
                                           and e.get("slug") == slug), None), 60,
                             "the store host never adopted the dead TUI's session")
        host = self.wait_ready(kdir)
        self.assertEqual((adopted["actor_instance"], adopted["target_instance"]), (host["instance_name"], tui["name"]))
        self.assertIn(f"launched host pid {host['pid']} (work)", self.supervisor_log())
        self.assertEqual(self.supervisor_pid(), supervisor)
        row = read_json(kdir / "_sessions/instances" / (host["instance_name"] + ".json"))
        session = next(s for s in row["sessions"] if s["slug"] == slug)
        self.assertEqual(session["source_dir"], str(checkout))
        handle = "chat:" + slug[len("chat-"):]
        self.send(checkout, handle, "after-tui-died")
        self.assertEqual([m["pid"] for m in self.messages("after-tui-died")], [record["pid"]])
        _, peek = self.lore_json("session", "peek", handle, cwd=checkout)
        self.assertEqual(peek["observation"]["instance"], host["instance_name"])
        self.assertEqual(len([e for e in self.events() if e["event"] == "started"]), 1)

    def test_hosts_get_the_first_callers_environment_scrubbed_per_store(self):
        self.use_runtime(self.runtime, LORE_SESSION_SUPERVISOR_QUIET_SECONDS="1")
        alpha, beta = self.make_store("alpha"), self.make_store("beta")
        alpha_one = self.make_checkout("alpha", "alpha-one")
        beta_one = self.make_checkout("beta", "beta-one")
        alpha_item = self.create_item(alpha, alpha_one, "Alpha Fixture")
        beta_item = self.create_item(beta, beta_one, "Beta Fixture")
        self.declare_checkout(alpha, alpha_item, alpha_one)
        self.declare_checkout(beta, beta_item, beta_one)
        self.until(lambda: not lock_held(self.login() / "supervisor.lock"), 30, "the setup supervisor did not quiet out")

        # The caller that starts the next supervisor runs inside a harness session pinned to beta.
        first_caller = dict(self.env, CLAUDECODE="1", CLAUDE_CODE_CHILD_SESSION="1",
                            CLAUDE_CODE_SESSION_ID="caller-session", AI_AGENT="claude-code",
                            LORE_POSITION_DISPATCH_MANIFEST="/caller/manifest.json", LORE_KNOWLEDGE_DIR=str(beta),
                            CLAUDE_CODE_USE_BEDROCK="1", FIXTURE_CARRIED="carried",
                            LORE_SESSION_SUPERVISOR_QUIET_SECONDS="600")
        self.raw_request(alpha_one, alpha_item + "--w1", "--kdir", str(alpha), "--context", str(self.brief),
                         env=first_caller)
        self.raw_request(beta_one, beta_item + "--w1", "--context", str(self.brief), env=first_caller)
        records = {alpha: self.started(alpha_item + "--w1"), beta: self.started(beta_item + "--w1")}
        served = read_json(self.login() / "served.json")["stores"]
        self.assertIs(served[str(alpha)]["pin_knowledge_dir"], False)
        self.assertIs(served[str(beta)]["pin_knowledge_dir"], True)
        self.assertEqual(read_json(self.login() / "supervisor.json")["tmux_tmpdir"], str(self.tmux_dir))
        for kdir, record in records.items():
            names = set(record["env"])
            for scrubbed in ("CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "AI_AGENT",
                             "LORE_POSITION_DISPATCH_MANIFEST"):
                self.assertNotIn(scrubbed, names, f"{scrubbed} reached a session of {kdir}")
            # tmux sets TMUX in each pane; it names this runtime's server under the private socket directory.
            self.assertTrue(record["values"]["TMUX"].startswith(
                str(self.tmux_dir / f"tmux-{os.getuid()}" / session_runtime.tmux_server(self.env)) + ","), record)
            self.assertIn("CLAUDE_CODE_USE_BEDROCK", names)
            self.assertEqual(record["values"]["FIXTURE_CARRIED"], "carried")
            self.assertEqual(record["values"]["LORE_SESSION_STORE_ROOT"], str(kdir))
            self.assertEqual(record["values"]["LORE_SESSION_RUNTIME"], self.runtime)
        self.assertIsNone(records[alpha]["values"]["LORE_KNOWLEDGE_DIR"], "beta's pin reached alpha's session")
        self.assertEqual(records[beta]["values"]["LORE_KNOWLEDGE_DIR"], str(beta))

        elsewhere = dict(self.env, TMUX_TMPDIR=str(self.root / "other-tmux"))
        self.assert_private_tmux(elsewhere)
        warned = subprocess.run([sys.executable, "-c", ENSURE_SCRIPT, str(REPO / "scripts/session-managed.py"),
                                 str(alpha), "30"], cwd=self.root, env=elsewhere, text=True, capture_output=True,
                                stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertIn(f"TMUX_TMPDIR here is {self.root / 'other-tmux'}, but the session supervisor started with "
                      f"{self.tmux_dir}", warned.stderr)


if __name__ == "__main__":
    unittest.main()
