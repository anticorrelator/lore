"""Live PTY contract suite for the **opencode** harness.

Each probe drives a REAL `opencode` TUI over a pexpect PTY, feeds the raw byte
stream through a pyte screen oracle, and ASSERTS live behavior matches the pinned
interaction row in adapters/capabilities.json (read dynamically, never hard-coded
here). Converged from the record-mode exploration pass: the fixtures (spawn +
screen oracle + idle-wait) survive; only the expectations flipped from record()
to assert. Shared driver lives in _driver.py.

Run live (costs real harness sessions / tokens):
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_opencode.py -s -v

Optional env:
    PROBE_MODEL     provider/model for --model (default openai/gpt-4o-mini)
    PROBE_SANDBOX   pre-made throwaway git dir to launch in (default: fresh mkdtemp)
"""

import json
import os
import pathlib
import re
import subprocess
import tempfile
import time

import pexpect
import pytest

import _driver as d

pytestmark = pytest.mark.skipif(
    os.environ.get("LORE_LIVE_PROBES") != "1",
    reason="live probes cost real harness sessions; set LORE_LIVE_PROBES=1 to run",
)

FRAMEWORK = "opencode"
HERE = pathlib.Path(__file__).resolve().parent
RAW_DIR = HERE / "observations" / "raw" / "opencode"
MODEL = os.environ.get("PROBE_MODEL", "openai/gpt-4o-mini")
COLS, ROWS = d.COLS, d.ROWS


# --------------------------------------------------------------------------- #
# Sandbox — NEVER launch the harness inside the lore repo.
# --------------------------------------------------------------------------- #
def _ensure_sandbox() -> str:
    env_dir = os.environ.get("PROBE_SANDBOX")
    if env_dir and pathlib.Path(env_dir).is_dir():
        return env_dir
    dir_ = tempfile.mkdtemp(prefix="opencode-probe-")
    subprocess.run(["git", "init", "-q"], cwd=dir_, check=False)
    (pathlib.Path(dir_) / "README.md").write_text("# opencode probe sandbox\n")
    subprocess.run(["git", "add", "-A"], cwd=dir_, check=False)
    subprocess.run(
        ["git", "-c", "user.email=probe@local", "-c", "user.name=probe",
         "commit", "-qm", "probe sandbox"],
        cwd=dir_, check=False,
    )
    return dir_


_SANDBOX_CACHE = None


def sandbox() -> str:
    global _SANDBOX_CACHE
    if _SANDBOX_CACHE is None:
        _SANDBOX_CACHE = _ensure_sandbox()
    return _SANDBOX_CACHE


def make_permission_sandbox(bash_mode: str = "ask") -> str:
    """A throwaway git dir whose opencode.json forces a bash permission decision."""
    dir_ = tempfile.mkdtemp(prefix="opencode-perm-")
    subprocess.run(["git", "init", "-q"], cwd=dir_, check=False)
    (pathlib.Path(dir_) / "README.md").write_text("# opencode permission probe\n")
    (pathlib.Path(dir_) / "opencode.json").write_text(json.dumps({
        "$schema": "https://opencode.ai/config.json",
        "permission": {"bash": bash_mode},
    }, indent=2))
    subprocess.run(["git", "add", "-A"], cwd=dir_, check=False)
    subprocess.run(
        ["git", "-c", "user.email=probe@local", "-c", "user.name=probe",
         "commit", "-qm", "perm sandbox"],
        cwd=dir_, check=False,
    )
    return dir_


# --------------------------------------------------------------------------- #
# Spawn + pump. The raw byte stream is teed to disk via pexpect logfile_read;
# the pyte oracle is the decoded view the readiness gate inspects.
# --------------------------------------------------------------------------- #
class Session:
    def __init__(self, raw_path: pathlib.Path, launch_dir: str = None,
                 tmux: bool = False, pane_side_path: str = None):
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        self.raw_path = raw_path
        self._log = open(raw_path, "wb")
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        argv = ["opencode", "--model", MODEL, launch_dir or sandbox()]
        self.tmux = None
        if tmux:
            # opencode takes its launch dir as a positional arg, so no tmux -c.
            self.tmux = d.TmuxHost(
                d.tmux_session_name("oc"), argv, env=env,
                cols=COLS, rows=ROWS, pane_side_path=pane_side_path,
            )
            self.child = self.tmux.child
        else:
            self.child = pexpect.spawn(
                argv[0], argv[1:],
                dimensions=(ROWS, COLS), env=env, encoding=None, timeout=60,
            )
        self.child.logfile_read = self._log
        self.oracle = d.ScreenOracle()

    def send(self, data):
        self.child.send(data)

    def pump(self, seconds):
        return d.drain(self.child, self.oracle, seconds)

    def wait_idle(self, stable_secs=1.5, max_wait=30.0):
        return d.wait_idle(self.child, self.oracle, stable_secs, max_wait)

    def raw_bytes(self) -> bytes:
        try:
            self._log.flush()
        except Exception:
            pass
        return self.raw_path.read_bytes()

    def close(self):
        try:
            self._log.flush()
            self._log.close()
        except Exception:
            pass
        try:
            self.child.close(force=True)
        except Exception:
            pass
        if self.tmux is not None:
            self.tmux.kill()


def dismiss_update_modal(sess, poll_secs: float = 10.0) -> bool:
    """opencode may show an async 'Update Available' overlay on launch; ESC clears
    it. It is env-dependent (only when a newer release exists) so it is NOT part of
    the stable composer signature — the gate treats it as NOT-composer-ready."""
    deadline = time.time() + poll_secs
    while time.time() < deadline:
        if "Update Available" in sess.oracle.text():
            sess.send(b"\x1b")
            sess.wait_idle(stable_secs=1.0, max_wait=6)
            return "Update Available" not in sess.oracle.text()
        sess.pump(0.5)
    return False


def assert_graceful_exit(sess) -> None:
    """Send the capability graceful_exit_sequence and assert the child exits."""
    seq = d.sequence_bytes(FRAMEWORK, "graceful_exit_sequence")
    if not sess.child.isalive():
        sess.close()
        return
    # The row's contract is exit-from-clean-idle; settle any in-flight turn
    # before sending, so Ctrl-C isn't consumed as a generation interrupt. The
    # queued follow-up a mid-generation inject dispatches needs the longer
    # budget. With text in the composer the first Ctrl-C clears it; retry once.
    sess.wait_idle(stable_secs=2.0, max_wait=60)
    for _ in range(2):
        sess.send(seq)
        sess.wait_idle(stable_secs=1.0, max_wait=4)
        if not sess.child.isalive():
            break
    exited = not sess.child.isalive()
    if sess.child.isalive():
        sess.child.terminate(force=True)
    sess.close()
    # CONTRACT: graceful_exit_sequence feeds the exit ladder's first rung.
    assert exited, "graceful_exit_sequence did not terminate opencode from idle"


def _strip_ansi(raw: bytes) -> str:
    t = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", raw)
    t = re.sub(rb"\x1b\][^\x07]*\x07", b"", t)
    t = t.replace(b"\x1b", b"")
    return t.decode("utf-8", "replace")


def _composer_band(oracle) -> str:
    """Text of the lower composer band (rows 16..bottom)."""
    return "\n".join(oracle.rows()[16:])


def _live_composer_input(oracle) -> str:
    """ONLY the live composer INPUT text — the '┃'-bordered rows between the input
    box top and the status row above the '╹▀+' bottom border. Distinguishes the
    live input from transcript user bubbles (also '┃'-bordered) that a scrolled
    transcript pushes into the lower rows."""
    rows = oracle.rows()
    bb = None
    for i, r in enumerate(rows):
        if re.search(r"╹▀{5,}", r):
            bb = i
    if bb is None:
        return ""
    status = None
    for i in range(bb - 1, -1, -1):
        if "┃" in rows[i] and "OpenAI" in rows[i]:
            status = i
            break
    if status is None:
        status = bb
    input_rows = []
    for i in range(status - 1, -1, -1):
        if "┃" in rows[i]:
            input_rows.append(rows[i])
        else:
            break
    return "\n".join(reversed(input_rows)).replace("┃", " ")


def _ready(sess) -> bool:
    return d.opencode_composer_ready(sess.oracle.rows())


def _settle_to_composer(sess, first_pump=2.0):
    sess.pump(first_pump)
    dismiss_update_modal(sess)
    sess.wait_idle(stable_secs=1.5, max_wait=25)


# =========================================================================== #
# P1 — composer signature (stable across 2 launches)
# =========================================================================== #
def test_p1_composer_signature():
    for n in (1, 2):
        sess = Session(RAW_DIR / f"p1_composer_launch{n}.raw")
        try:
            _settle_to_composer(sess)
            # CONTRACT: the shared composer matcher fires on the ready screen.
            assert _ready(sess), f"composer not ready on launch {n}"
        finally:
            assert_graceful_exit(sess)
    row = d.interaction_row(FRAMEWORK, "composer_signature")
    assert row["support"] != "none" and row["matcher"].strip()


# =========================================================================== #
# Graceful exit — the capability sequence exits from a clean idle composer
# =========================================================================== #
def test_graceful_exit_sequence():
    sess = Session(RAW_DIR / "exit_ctrl_c.raw")
    _settle_to_composer(sess)
    assert _ready(sess), "composer not ready before exit probe"
    # assert_graceful_exit sends the capability graceful_exit_sequence and asserts
    # the child exits — the whole point of this probe.
    assert_graceful_exit(sess)


# =========================================================================== #
# P2 — permission-prompt signature
# =========================================================================== #
PERMISSION_PROMPT = b"Run this exact shell command: echo probe-ok"


def _induce_bash(sess):
    _settle_to_composer(sess)
    sess.send(PERMISSION_PROMPT)
    sess.wait_idle(stable_secs=0.8, max_wait=8)
    sess.send(b"\r")


def test_p2_permission_prompt_signature():
    # Part A: default config auto-runs bash (documents the no-gate baseline).
    sess = Session(RAW_DIR / "p2a_default_autorun.raw")
    try:
        _induce_bash(sess)
        sess.wait_idle(stable_secs=2.0, max_wait=40)
        screen = sess.oracle.text()
        asked = bool(re.search(r"(?i)Permission required|Allow (once|always)", screen))
        # CONTRACT: default config does NOT gate bash (no modal).
        assert not asked, "unexpected permission modal under default config"
    finally:
        assert_graceful_exit(sess)

    # Part B: permission.bash=ask forces the modal.
    perm_dir = make_permission_sandbox(bash_mode="ask")
    sess = Session(RAW_DIR / "p2b_permission_modal.raw", launch_dir=perm_dir)
    try:
        _induce_bash(sess)
        deadline = time.time() + 30
        appeared = False
        while time.time() < deadline:
            sess.pump(0.5)
            if "Permission required" in sess.oracle.text():
                appeared = True
                break
        sess.wait_idle(stable_secs=0.8, max_wait=6)
        # CONTRACT: the permission matcher fires (gate must refuse to inject) and
        # the composer matcher does not.
        rows = sess.oracle.rows()
        assert appeared and d.opencode_permission_modal(rows), "permission modal not detected"
        assert not d.opencode_composer_ready(rows), "composer matcher fired during a modal"
        row = d.interaction_row(FRAMEWORK, "permission_prompt_signature")
        assert row["support"] != "none" and row["matcher"].strip()
        sess.send(b"\x1b")  # decline
        sess.wait_idle(stable_secs=1.0, max_wait=8)
    finally:
        assert_graceful_exit(sess)


# =========================================================================== #
# P3 — submit vs newline bytes, read from the capability row
# =========================================================================== #
def test_p3_submit_vs_newline():
    submit_seq = d.sequence_bytes(FRAMEWORK, "submit_sequence")
    newline_seq = d.sequence_bytes(FRAMEWORK, "newline_sequence")
    sess = Session(RAW_DIR / "p3_submit_newline.raw")
    try:
        _settle_to_composer(sess)
        sess.send(b"aaa-probe")
        sess.wait_idle(stable_secs=0.8, max_wait=6)

        # newline_sequence inserts a newline, keeping the draft.
        before = _composer_band(sess.oracle)
        sess.send(newline_seq)
        sess.wait_idle(stable_secs=1.0, max_wait=8)
        after = _composer_band(sess.oracle)
        # CONTRACT: newline_sequence keeps the marker and changes the composer (no submit).
        assert "aaa-probe" in after and after != before, (
            "newline_sequence did not insert a newline"
        )

        # submit_sequence commits the composer (marker leaves the LIVE input).
        # Check the precise live-input locator, not the band: the submitted
        # message echoes as a '┃'-bordered bubble adjacent to the composer and
        # sits inside the band until the reply scrolls it away.
        before_submit = _live_composer_input(sess.oracle)
        sess.send(submit_seq)
        sess.wait_idle(stable_secs=1.5, max_wait=25)
        assert "aaa-probe" in before_submit and "aaa-probe" not in _live_composer_input(sess.oracle), (
            "submit_sequence did not submit"
        )
    finally:
        assert_graceful_exit(sess)


# =========================================================================== #
# P4 — bracketed paste
# =========================================================================== #
def test_p4_bracketed_paste():
    sess = Session(RAW_DIR / "p4_bracketed_paste.raw")
    try:
        _settle_to_composer(sess)
        advertised = b"\x1b[?2004h" in sess.raw_bytes()
        # CONTRACT: honors_bracketed_paste matches whether the composer offered 2004h.
        assert advertised == d.interaction_row(FRAMEWORK, "honors_bracketed_paste")["value"]

        before_band = _composer_band(sess.oracle)
        sess.send(d.paste_encode(b"paste-line-one\npaste-line-two"))
        sess.wait_idle(stable_secs=1.2, max_wait=8)
        after_band = _composer_band(sess.oracle)
        both = ("paste-line-one" in after_band) and ("paste-line-two" in after_band)
        transcript = "\n".join(sess.oracle.rows()[:16])
        in_transcript = "paste-line-one" in transcript
        observed = (
            "held-multiline-needs-submit" if (both and not in_transcript)
            else "auto-submit-on-close" if in_transcript
            else "unresolved"
        )
        # CONTRACT: paste_multiline_semantics matches the observed hold/submit behavior.
        assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], (
            f"paste semantics observed {observed!r}"
        )
        if both and not in_transcript:
            sess.send(d.sequence_bytes(FRAMEWORK, "submit_sequence"))
            sess.wait_idle(stable_secs=1.5, max_wait=25)
    finally:
        assert_graceful_exit(sess)


# =========================================================================== #
# P5 — mid-generation inject
# =========================================================================== #
def test_p5_mid_generation_inject():
    sess = Session(RAW_DIR / "p5_mid_generation.raw")
    try:
        _settle_to_composer(sess)
        sess.send(b"Count from 1 to 40, one number per line, no other text.")
        sess.wait_idle(stable_secs=0.8, max_wait=8)
        sess.send(d.sequence_bytes(FRAMEWORK, "submit_sequence"))

        deadline = time.time() + 12
        while time.time() < deadline:
            sess.pump(0.5)
            txt = sess.oracle.text()
            if re.search(r"\b1\b", txt) and re.search(r"\b2\b", txt):
                break

        sess.send(b"PING-MIDGEN" + d.sequence_bytes(FRAMEWORK, "submit_sequence"))
        sess.wait_idle(stable_secs=2.5, max_wait=45)

        full = sess.oracle.text()
        live_input = _live_composer_input(sess.oracle)
        in_live_composer = "PING-MIDGEN" in live_input
        in_transcript = ("PING-MIDGEN" in full) and not in_live_composer
        # The visible screen is a 40-row viewport: after the queued message
        # auto-dispatches and draws a reply, both the PING echo and the count
        # tail can scroll off. The QUEUED badge in the raw byte stream is the
        # scroll-immune signal that the injection was held and auto-sent.
        queued_badge = b"QUEUED" in sess.raw_bytes()
        if (queued_badge or in_transcript) and not in_live_composer:
            observed = "queued-autosubmit"
        elif in_live_composer:
            observed = "buffered-draft"
        elif not re.search(r"\b40\b", full):
            observed = "interrupts"
        else:
            observed = "dropped"
        # CONTRACT: mid_generation_semantics matches the observed mid-stream effect.
        # opencode holds the injection (native QUEUED badge) and auto-sends it as the
        # next message, so the readiness gate must be strict.
        assert observed == d.interaction_row(FRAMEWORK, "mid_generation_semantics")["value"], (
            f"mid-generation semantics observed {observed!r}"
        )
    finally:
        assert_graceful_exit(sess)


# =========================================================================== #
# tmux tier — re-verify the contract set under a tmux attach client. Each
# assertion names the capability-row field it re-checks; divergences from the
# direct-PTY recordings are recorded in observations/opencode.tmux.json, not
# silently absorbed into the rows.
# =========================================================================== #
TMUX_RAW = RAW_DIR / "tmux"


def _tmux_session(name, launch_dir=None, pane_side=None):
    return Session(TMUX_RAW / f"{name}.raw", launch_dir=launch_dir,
                   tmux=True, pane_side_path=pane_side)


def test_tmux_composer_decset_paste():
    """composer signature, DECSET 2004 visibility, paste-hold (no inference)."""
    pane_side = str(TMUX_RAW / "pane_side.raw")
    sess = _tmux_session("composer_paste", pane_side=pane_side)
    try:
        _settle_to_composer(sess)
        assert _ready(sess), "composer_signature: matcher did not fire under tmux"

        payload = d.decset_observation(
            FRAMEWORK,
            client_2004h=b"\x1b[?2004h" in sess.raw_bytes(),
            pane_2004h=b"\x1b[?2004h" in sess.tmux.pane_side_bytes(),
        )
        d.record_tmux_observation(FRAMEWORK, "honors_bracketed_paste", payload)
        # The production injection encoder reads the attach-client stream; under tmux
        # it observes paste mode enabled (tmux advertises to any capable client), so the
        # load-bearing signal is the client-side visibility. A pane-side mismatch (the
        # harness defers bracketed paste to tmux) is recorded as a divergence finding.
        assert payload["client_observes_2004h"], \
            "honors_bracketed_paste: attach client did not observe DECSET 2004 under tmux"

        before_band = _composer_band(sess.oracle)
        sess.send(d.paste_encode(b"paste-line-one\npaste-line-two"))
        sess.wait_idle(stable_secs=1.2, max_wait=8)
        after_band = _composer_band(sess.oracle)
        both = ("paste-line-one" in after_band) and ("paste-line-two" in after_band)
        transcript = "\n".join(sess.oracle.rows()[:16])
        in_transcript = "paste-line-one" in transcript
        observed = ("held-multiline-needs-submit" if (both and not in_transcript)
                    else "auto-submit-on-close" if in_transcript else "unresolved")
        d.record_tmux_observation(FRAMEWORK, "paste_multiline_semantics", {
            "observed": observed,
            "capability_row_value": d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"],
        })
        assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], \
            f"paste_multiline_semantics: observed {observed!r} under tmux"
    finally:
        assert_graceful_exit(sess)


def test_tmux_submit_and_newline():
    """newline_sequence (ESC-CR) inserts under escape-time 0; submit_sequence commits."""
    submit_seq = d.sequence_bytes(FRAMEWORK, "submit_sequence")
    newline_seq = d.sequence_bytes(FRAMEWORK, "newline_sequence")
    sess = _tmux_session("submit_newline")
    try:
        _settle_to_composer(sess)
        sess.send(b"aaa-probe")
        sess.wait_idle(stable_secs=0.8, max_wait=6)

        before = _composer_band(sess.oracle)
        sess.send(newline_seq)
        sess.wait_idle(stable_secs=1.0, max_wait=8)
        after = _composer_band(sess.oracle)
        # ESC-CR must reach the pane as ESC then CR (escape-time 0), not a held meta.
        assert "aaa-probe" in after and after != before, \
            "newline_sequence: ESC-CR did not insert a newline under tmux"

        before_submit = _live_composer_input(sess.oracle)
        sess.send(submit_seq)
        sess.wait_idle(stable_secs=1.5, max_wait=25)
        assert "aaa-probe" in before_submit and "aaa-probe" not in _live_composer_input(sess.oracle), \
            "submit_sequence: did not submit under tmux"
        d.record_tmux_observation(FRAMEWORK, "submit_newline", {
            "newline_inserts": True, "submit_commits": True,
        })
    finally:
        assert_graceful_exit(sess)


def test_tmux_permission_modal():
    """permission_prompt_signature — permission.bash=ask forces the modal."""
    perm_dir = make_permission_sandbox(bash_mode="ask")
    sess = _tmux_session("permission", launch_dir=perm_dir)
    try:
        _induce_bash(sess)
        deadline = time.time() + 30
        appeared = False
        while time.time() < deadline:
            sess.pump(0.5)
            if "Permission required" in sess.oracle.text():
                appeared = True
                break
        sess.wait_idle(stable_secs=0.8, max_wait=6)
        rows = sess.oracle.rows()
        assert appeared and d.opencode_permission_modal(rows), \
            "permission_prompt_signature: modal not detected under tmux"
        assert not d.opencode_composer_ready(rows), \
            "composer matcher fired during a modal under tmux"
        d.record_tmux_observation(FRAMEWORK, "permission_prompt_signature", {
            "modal_detected": True, "composer_suppressed": True,
        })
        sess.send(b"\x1b")  # decline
        sess.wait_idle(stable_secs=1.0, max_wait=8)
    finally:
        assert_graceful_exit(sess)
