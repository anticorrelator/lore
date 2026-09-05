"""Real host/CLI acceptance with fake coding tools; no model inference.

Run with LORE_SESSION_HOST_BINARY pointing at the built session-host binary.
Each test owns an isolated HOME, knowledge store, Git repository and tmux socket.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
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
    if state == "working":
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
record("started", argv=sys.argv[1:], cwd=os.getcwd(), instance=os.environ.get("LORE_SESSION_INSTANCE"), slug=os.environ.get("LORE_SESSION_SLUG"))
render()
buffer = b""
while True:
    try:
        requested = state_path.read_text().strip()
    except FileNotFoundError:
        requested = "composer"
    if requested != state:
        state = requested
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
        record("message", body=body.decode(errors="replace"))
        if body == b"kill-owner-after-input":
            for path in (Path(os.environ["LORE_KNOWLEDGE_DIR"]) / "_sessions/instances").glob("*.json"):
                owner = json.loads(path.read_text())
                if any(row.get("slug") == os.environ["LORE_SESSION_SLUG"] for row in owner.get("sessions", [])):
                    try: os.kill(owner["pid"], 9)
                    except ProcessLookupError: pass
        render("received: " + body.decode(errors="replace"))
        buffer = b""
'''


@unittest.skipUnless(os.environ.get("LORE_SESSION_HOST_BINARY") and shutil.which("tmux"),
                     "requires an explicitly built host binary and tmux")
class ManagedSessionIntegration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lore-ms-", dir="/tmp")
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.source = self.root / "source workspace"
        self.kdir = self.root / "store"
        self.bin = self.root / "bin"
        self.tmux_dir = self.root / "tmux"
        for directory in (self.home / ".lore", self.source, self.kdir, self.bin, self.tmux_dir):
            directory.mkdir(parents=True)
        (self.home / ".lore/scripts").symlink_to(REPO / "scripts", target_is_directory=True)
        (self.bin / "lore").symlink_to(REPO / "cli/lore")
        for binary in ("claude", "codex", "opencode"):
            path = self.bin / binary
            path.write_text(FAKE_HARNESS)
            path.chmod(0o755)
        settings = self.home / ".lore/config/settings.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"version": 1, "tui_launch_framework": "claude-code",
            "harnesses": {h: {"enabled": True, "args": [], "autonomous_args": [],
                "roles": {"default": "fixture-model", "worker": "fixture-model"}}
                for h in ("claude-code", "codex", "opencode")}}))
        self.log = self.root / "harness.jsonl"
        self.state_dir = self.root / "states"
        self.state_dir.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), LORE_DATA_DIR=str(self.home / ".lore"),
            LORE_KNOWLEDGE_DIR=str(self.kdir), TMUX_TMPDIR=str(self.tmux_dir),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            LORE_FAKE_HARNESS_LOG=str(self.log), LORE_FAKE_STATE_DIR=str(self.state_dir),
            LORE_SESSION_HOST_IDLE_TIMEOUT="2")
        for key in list(self.env):
            if key.startswith("LORE_SESSION_") and key not in ("LORE_SESSION_HOST_BINARY", "LORE_SESSION_HOST_IDLE_TIMEOUT"):
                del self.env[key]
        self.env.pop("TMUX", None)
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

    def events(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line]

    def until(self, predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.1)
        self.fail("condition not reached before deadline")

    def start(self, framework="codex", key="fixture"):
        _, value = self.session("start", self.item, "--workspace", str(self.source),
            "--framework", framework, "--model", "fixture-model", "--context", str(self.context), "--key", key)
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
        # Stop only process IDs recorded inside this test's private store.
        for name in ("supervisor.json", "ready.json"):
            for record in (self.kdir / "_sessions/hosts").glob("*/" + name):
                try:
                    os.kill(json.loads(record.read_text())["pid"], signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError, KeyError):
                    pass
        # This socket namespace belongs only to this test, never the user's server.
        subprocess.run(["tmux", "-L", "lore-tui", "kill-server"], env=self.env,
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Allow a drained host/supervisor to exit before removing its state.
        time.sleep(3)
        self.temp.cleanup()

    def test_all_harnesses_share_host_without_a_human_tui(self):
        starts = [self.start(framework, framework) for framework in ("claude-code", "codex", "opencode")]
        self.assertEqual(len({value["handle"] for value in starts}), 3)
        rows = self.until(lambda: self.events() if len([e for e in self.events() if e["event"] == "started"]) == 3 else None)
        started = [row for row in rows if row["event"] == "started"]
        self.assertEqual({row["framework"] for row in started}, {"claude-code", "codex", "opencode"})
        self.assertEqual(len({row["instance"] for row in started}), 1)
        for record in started:
            self.assertIn("fixture-model", record["argv"])
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
        self.until(lambda: not list((self.kdir / "_sessions/hosts").glob("*/ready.json")), timeout=20)
        for value in starts:
            _, state = self.session("inspect", value["handle"])
            self.assertTrue(state["disposition"]["cleanup_confirmed"])
            self.assertEqual(state["state"], "closed")

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

    def test_watcher_recovers_current_state_and_retains_receipt(self):
        handle = self.start("claude-code", "watcher")["handle"]
        self.until(lambda: any(e["event"] == "started" for e in self.events()))
        (self.state_dir / handle).write_text("settled")
        peek = self.peek_activity(handle, "idle")
        self.assertEqual(peek["observation"]["activity"], "idle", peek)
        cursor = self.run_command([str(REPO / "cli/lore"), "session", "events", "--cursor-only"]).stdout.strip()
        args = [str(REPO / "cli/lore"), "coordinate", "watch", "--durable", "--owner-pid", str(os.getpid()),
                "--timeout", "1", "--pending-stale", "0", "--json"]
        first = self.run_command(args + ["--since", cursor], timeout=30)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        wake = json.loads(first.stdout)
        self.assertEqual(wake["outcome"], "current_delta", wake)
        self.assertEqual(wake["tier"], "confirmed", wake)
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


if __name__ == "__main__":
    unittest.main()
