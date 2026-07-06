"""Live PTY contract suite for the **codex** harness (`codex` binary).

Each probe constructs a real session state through the real dispatch path (spawn
the actual `codex` binary over a PTY, drive it, observe the VT screen with pyte)
and ASSERTS that live behavior matches the pinned interaction row in
adapters/capabilities.json (read dynamically, never hard-coded). Converged from
the record-mode exploration pass: the state construction survives; the
expectations flipped from record() to assert. Shared driver lives in _driver.py.

Run live (costs real harness sessions / tokens):
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_codex.py -s -v

Session economy: each probe spawns its own codex (a launch makes no model call;
inference is the cost) and keeps model turns trivial. Cheapest interactive model
is `gpt-5.4-mini` with `model_reasoning_effort=low`; any submit is halted with a
single Ctrl-C.
"""

import os
import re
import time
from datetime import datetime, timezone

import pexpect
import pytest

import _driver as d

pytestmark = pytest.mark.skipif(
    os.environ.get("LORE_LIVE_PROBES") != "1",
    reason="live probes cost real harness sessions",
)

FRAMEWORK = "codex"
HERE = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(HERE, "observations", "raw", "codex")

COLS, ROWS = d.COLS, d.ROWS
MODEL = "gpt-5.4-mini"
REASONING = "low"
SANDBOX = os.environ.get(
    "LORE_PROBE_SANDBOX",
    "/private/tmp/claude-501/-Users-dustinqngo-work-lore/"
    "618e24b6-58ad-4aa7-a3e7-60c6b2023092/scratchpad/probe-env-codex",
)
CODEX_BIN = os.environ.get("LORE_PROBE_CODEX_BIN", "codex")


def _iso():
    return datetime.now(timezone.utc).isoformat()


# Composer geometry: the reliable "ready" anchor is the footer status line
# "<model> <effort> · <cwd>". find_composer returns the geometry; the readiness
# *matcher* is the shared d.codex_composer_ready.
FOOTER_RE = re.compile(r"(minimal|low|medium|high|xhigh)\s+·\s")
INPUT_GLYPH = "›"
TRUST_RE = re.compile(r"do you trust the contents of this directory", re.I)
WELCOME_RE = re.compile(r"OpenAI Codex \(v")


def find_composer(oracle):
    """Return (ready, input_row_idx, footer_row_idx) for input-region slicing."""
    rows = oracle.rows()
    footer_idx = next((i for i, r in enumerate(rows) if FOOTER_RE.search(r)), None)
    if footer_idx is None:
        return (False, None, None)
    input_idx = None
    for i in range(footer_idx, -1, -1):
        if rows[i].lstrip().startswith(INPUT_GLYPH):
            input_idx = i
            break
    return (input_idx is not None, input_idx, footer_idx)


# --------------------------------------------------------------------------- #
# Session driver
# --------------------------------------------------------------------------- #
def _clean_env():
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("LORE_"):
            env.pop(k, None)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    return env


class Session:
    def __init__(self, raw_log_path, prompt=None, extra_args=None,
                 tmux=False, pane_side_path=None):
        self.raw_log_path = raw_log_path
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        args = ["-m", MODEL, "-c", f'model_reasoning_effort="{REASONING}"', "-C", SANDBOX]
        args += (extra_args or [])
        if prompt is not None:
            args.append(prompt)
        self.tmux = None
        if tmux:
            # codex takes its cwd via -C in argv, so no tmux -c start-directory.
            self.tmux = d.TmuxHost(
                d.tmux_session_name("cx"), [CODEX_BIN] + args, env=_clean_env(),
                cols=COLS, rows=ROWS, pane_side_path=pane_side_path,
            )
            self.child = self.tmux.child
        else:
            self.child = pexpect.spawn(
                CODEX_BIN, args, env=_clean_env(),
                dimensions=(ROWS, COLS), encoding=None, timeout=60,
            )
        self.child.logfile_read = self._log
        self.oracle = d.ScreenOracle()

    def send(self, data):
        self.child.send(data)

    def type_text(self, text, per_char=0.01):
        for ch in text:
            self.child.send(ch.encode() if isinstance(ch, str) else ch)
            time.sleep(per_char)

    def marker(self, text):
        try:
            self._log.write(f"\n===PROBE-MARKER {text} @ {_iso()}===\n".encode())
            self._log.flush()
        except Exception:
            pass

    def drain(self, seconds):
        return d.drain(self.child, self.oracle, seconds)

    def wait_idle(self, stable_secs=2.0, timeout=45.0, poll=0.3):
        return d.wait_idle(self.child, self.oracle, stable_secs, timeout, poll)

    def raw_bytes(self):
        try:
            self._log.flush()
        except Exception:
            pass
        with open(self.raw_log_path, "rb") as f:
            return f.read()

    def graceful_close(self):
        """Send the capability graceful_exit_sequence and assert the child exits."""
        seq = d.sequence_bytes(FRAMEWORK, "graceful_exit_sequence")
        self.marker(f"graceful_close {_brepr(seq)}")
        if not self.child.isalive():
            self._shutdown()
            return
        # With text in the composer the first Ctrl-C clears it, so allow a retry.
        for _ in range(2):
            self.send(seq)
            self.drain(2.0)
            if not self.child.isalive():
                break
        exited = not self.child.isalive()
        self._shutdown()
        # CONTRACT: graceful_exit_sequence feeds the exit ladder's first rung.
        assert exited, f"graceful_exit_sequence {_brepr(seq)} did not terminate codex"

    def _shutdown(self):
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


def wait_for_composer(sess, timeout=45.0):
    sess.wait_idle(stable_secs=1.5, timeout=timeout)
    if TRUST_RE.search(sess.oracle.text()):
        sess.send(b"\r")
        sess.wait_idle(stable_secs=1.5, timeout=timeout)
    return find_composer(sess.oracle)[0]


def _raw_path(name):
    return os.path.join(RAW_DIR, f"{name}.log")


def _brepr(b: bytes):
    return "".join("\\x%02x" % c if (c < 0x20 or c > 0x7E) else chr(c) for c in b)


def _composer_text(oracle):
    ready, in_idx, foot_idx = find_composer(oracle)
    if not ready:
        return None
    rows = oracle.rows()
    return "\n".join(rows[in_idx:foot_idx])


def _interrupt_turn(sess):
    sess.marker("interrupt running turn (Esc)")
    sess.send(b"\x1b")
    sess.drain(1.5)
    return _composer_text(sess.oracle) or ""


# =========================================================================== #
# P1 — composer signature (stable across 2 launches)
# =========================================================================== #
def test_p1_composer_signature():
    for launch in (1, 2):
        sess = Session(_raw_path(f"p1_composer_launch{launch}"))
        try:
            assert wait_for_composer(sess), "composer never became ready"
            # CONTRACT: the shared composer matcher fires on the ready screen.
            assert d.codex_composer_ready(sess.oracle.rows())
        finally:
            sess.graceful_close()
    row = d.interaction_row(FRAMEWORK, "composer_signature")
    assert row["support"] != "none" and row["matcher"].strip()


# =========================================================================== #
# P2 — approval / permission-prompt signature
# =========================================================================== #
def _run_p2_attempt(name, prompt, extra_args):
    sess = Session(_raw_path(name), prompt=prompt, extra_args=extra_args)
    sess.wait_idle(stable_secs=1.5, timeout=45)
    if TRUST_RE.search(sess.oracle.text()):
        sess.send(b"\r")
        sess.wait_idle(stable_secs=1.5, timeout=30)
    sess.marker(f"await approval modal [{name}]")
    modal_seen = False
    deadline = time.time() + 90
    while time.time() < deadline:
        sess.wait_idle(stable_secs=1.5, timeout=30)
        if d.codex_permission_modal(sess.oracle.rows()):
            modal_seen = True
            break
        if find_composer(sess.oracle)[0] and re.search(r"•\s", sess.oracle.text()):
            break
        if not sess.child.isalive():
            break
    return modal_seen, sess


def test_p2_approval_prompt_signature():
    # Phase A: default mode auto-runs a trusted command (echo) — no modal expected.
    sess = None
    try:
        modal_seen, sess = _run_p2_attempt(
            "p2_approval_default",
            "Run this exact shell command: echo probe-ok",
            None,
        )
        # CONTRACT: default mode does not raise a modal for a trusted command.
        assert not modal_seen, "unexpected approval modal in default mode"
    finally:
        if sess is not None:
            sess.graceful_close()

    # Phase B: -a untrusted escalates a file write into the approval modal.
    sess = None
    try:
        modal_seen, sess = _run_p2_attempt(
            "p2_approval_untrusted",
            "Run this exact shell command: touch probe-approval-check.txt",
            ["-a", "untrusted"],
        )
        # CONTRACT: the permission matcher fires (gate must refuse to inject) and
        # the composer matcher does not (the modal owns the screen).
        rows = sess.oracle.rows()
        assert modal_seen and d.codex_permission_modal(rows), "approval modal not detected"
        assert not d.codex_composer_ready(rows), "composer matcher fired during a modal"
        row = d.interaction_row(FRAMEWORK, "permission_prompt_signature")
        assert row["support"] != "none" and row["matcher"].strip()
        sess.marker("decline modal (Esc)")
        sess.send(b"\x1b")
        sess.drain(2)
    finally:
        if sess is not None:
            sess.graceful_close()


# =========================================================================== #
# P3 — submit vs newline bytes, read from the capability row
# =========================================================================== #
def test_p3_submit_vs_newline():
    submit_seq = d.sequence_bytes(FRAMEWORK, "submit_sequence")
    newline_seq = d.sequence_bytes(FRAMEWORK, "newline_sequence")

    # newline_sequence inserts a newline without submitting (fresh session).
    sess = Session(_raw_path("p3_newline"))
    try:
        assert wait_for_composer(sess), "composer never became ready"
        sess.marker(f"newline_sequence {_brepr(newline_seq)}")
        sess.type_text("AAA")
        sess.drain(0.6)
        before = _composer_text(sess.oracle) or ""
        sess.send(newline_seq)
        sess.drain(0.8)
        sess.type_text("BBB")
        sess.drain(0.8)
        after = _composer_text(sess.oracle) or ""
        ready_after = find_composer(sess.oracle)[0]
        submitted = ("AAA" not in after) or (not ready_after)
        two_line = ("AAA" in after and "BBB" in after and after.count("\n") > before.count("\n"))
        # CONTRACT: newline_sequence inserts a newline; it must NOT submit.
        assert two_line and not submitted, (
            f"newline_sequence {_brepr(newline_seq)} did not insert a newline"
        )
    finally:
        sess.graceful_close()

    # submit_sequence commits the composer (one cheap model turn; interrupt after).
    sess = Session(_raw_path("p3_submit"))
    try:
        assert wait_for_composer(sess), "composer never became ready"
        sess.marker(f"submit_sequence {_brepr(submit_seq)}")
        sess.type_text("hi")
        sess.drain(0.6)
        sess.send(submit_seq)
        sess.drain(2.5)
        post_text = sess.oracle.text()
        composer_after = _composer_text(sess.oracle) or ""
        # CONTRACT: submit_sequence commits — 'hi' leaves the composer input band.
        assert "hi" not in composer_after and "hi" in post_text, (
            f"submit_sequence {_brepr(submit_seq)} did not submit"
        )
        _interrupt_turn(sess)
    finally:
        sess.graceful_close()


# =========================================================================== #
# P4 — bracketed paste
# =========================================================================== #
def test_p4_bracketed_paste():
    sess = Session(_raw_path("p4_bracketed_paste"))
    try:
        assert wait_for_composer(sess), "composer never became ready"
        advertised = b"\x1b[?2004h" in sess.raw_bytes()
        # CONTRACT: honors_bracketed_paste matches whether the composer offered 2004h.
        assert advertised == d.interaction_row(FRAMEWORK, "honors_bracketed_paste")["value"]

        sess.marker("bracketed paste (no trailing submit)")
        sess.send(d.paste_encode(b"line-one\nline-two"))
        sess.drain(1.5)
        after_paste = _composer_text(sess.oracle) or ""
        composer_txt = sess.oracle.text()
        auto_submitted = ("line-one" not in after_paste) and ("line-one" in composer_txt)
        both_lines = ("line-one" in after_paste) and ("line-two" in after_paste)
        observed = (
            "auto-submit-on-close" if auto_submitted
            else "held-multiline-needs-submit" if both_lines
            else "unresolved"
        )
        # CONTRACT: paste_multiline_semantics matches the observed hold/submit behavior.
        assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], (
            f"paste semantics observed {observed!r}"
        )
        if both_lines and not auto_submitted:
            sess.marker("trailing submit_sequence to commit")
            sess.send(d.sequence_bytes(FRAMEWORK, "submit_sequence"))
            sess.drain(2.0)
            sess.send(b"\x03")
            sess.drain(1.0)
    finally:
        sess.graceful_close()


# =========================================================================== #
# P5 — mid-generation inject
# =========================================================================== #
def test_p5_mid_generation_inject():
    sess = Session(
        _raw_path("p5_midgen"),
        prompt="Count from 1 to 40, one number per line, no other text.",
    )
    try:
        assert wait_for_composer(sess), "composer never became ready"
        sess.marker("wait for generation to start")
        deadline = time.time() + 25
        while time.time() < deadline:
            sess.drain(0.5)
            txt = sess.oracle.text()
            if re.search(r"\b[1-9]\b", txt) and (
                "\n2\n" in txt or "\n3\n" in txt or re.search(r"^\s*[1-9]\s*$", txt, re.M)
            ):
                break
            if not sess.child.isalive():
                break

        sess.marker("INJECT mid-generation")
        sess.send(b"PING-MIDGEN" + d.sequence_bytes(FRAMEWORK, "submit_sequence"))
        sess.wait_idle(stable_secs=3.0, timeout=90)
        final_text = sess.oracle.text()
        composer_after = _composer_text(sess.oracle) or ""

        ping_in_composer = "PING-MIDGEN" in composer_after
        ping_submitted = ("PING-MIDGEN" in final_text) and not ping_in_composer
        if ping_submitted:
            observed = "queued-autosubmit"
        elif ping_in_composer:
            observed = "buffered-draft"
        else:
            observed = "dropped"
        # CONTRACT: mid_generation_semantics matches the observed mid-stream effect.
        # codex buffers the injected draft (trailing CR does NOT submit while a turn
        # is active), so the readiness gate must be strict.
        assert observed == d.interaction_row(FRAMEWORK, "mid_generation_semantics")["value"], (
            f"mid-generation semantics observed {observed!r}"
        )
        if ping_in_composer and sess.child.isalive():
            _interrupt_turn(sess)
    finally:
        sess.graceful_close()


# =========================================================================== #
# tmux tier — re-verify the contract set under a tmux attach client. Each
# assertion names the capability-row field it re-checks; divergences from the
# direct-PTY recordings are recorded in observations/codex.tmux.json, not
# silently absorbed into the rows.
# =========================================================================== #
TMUX_RAW = os.path.join(RAW_DIR, "tmux")


def _tmux_session(name, prompt=None, extra_args=None, pane_side=None):
    return Session(os.path.join(TMUX_RAW, f"{name}.log"), prompt=prompt,
                   extra_args=extra_args, tmux=True, pane_side_path=pane_side)


def test_tmux_composer_decset_paste():
    """composer signature, DECSET 2004 visibility, paste-hold (no inference)."""
    pane_side = os.path.join(TMUX_RAW, "pane_side.raw")
    sess = _tmux_session("composer_paste", pane_side=pane_side)
    try:
        assert wait_for_composer(sess), "composer_signature: never became ready under tmux"
        assert d.codex_composer_ready(sess.oracle.rows()), \
            "composer_signature: matcher did not fire under tmux"

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

        sess.marker("tmux bracketed paste (no trailing submit)")
        sess.send(d.paste_encode(b"line-one\nline-two"))
        sess.drain(1.5)
        after_paste = _composer_text(sess.oracle) or ""
        composer_txt = sess.oracle.text()
        auto = ("line-one" not in after_paste) and ("line-one" in composer_txt)
        both = ("line-one" in after_paste) and ("line-two" in after_paste)
        observed = ("auto-submit-on-close" if auto
                    else "held-multiline-needs-submit" if both else "unresolved")
        d.record_tmux_observation(FRAMEWORK, "paste_multiline_semantics", {
            "observed": observed,
            "capability_row_value": d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"],
        })
        assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], \
            f"paste_multiline_semantics: observed {observed!r} under tmux"
    finally:
        sess.graceful_close()


def test_tmux_submit_and_newline():
    """newline_sequence inserts without submitting; submit_sequence commits."""
    submit_seq = d.sequence_bytes(FRAMEWORK, "submit_sequence")
    newline_seq = d.sequence_bytes(FRAMEWORK, "newline_sequence")
    sess = _tmux_session("submit_newline")
    try:
        assert wait_for_composer(sess), "composer never became ready under tmux"
        sess.marker(f"tmux newline_sequence {_brepr(newline_seq)}")
        sess.type_text("AAA")
        sess.drain(0.6)
        before = _composer_text(sess.oracle) or ""
        sess.send(newline_seq)
        sess.drain(0.8)
        sess.type_text("BBB")
        sess.drain(0.8)
        after = _composer_text(sess.oracle) or ""
        ready_after = find_composer(sess.oracle)[0]
        submitted = ("AAA" not in after) or (not ready_after)
        two_line = ("AAA" in after and "BBB" in after and after.count("\n") > before.count("\n"))
        # newline_sequence (ESC-guarded LF) must survive escape-time 0 without submitting.
        assert two_line and not submitted, \
            f"newline_sequence {_brepr(newline_seq)}: did not insert a newline under tmux"

        before_submit = _composer_text(sess.oracle) or ""
        sess.marker(f"tmux submit_sequence {_brepr(submit_seq)}")
        sess.send(submit_seq)
        sess.drain(2.5)
        composer_after = _composer_text(sess.oracle) or ""
        assert "AAA" in before_submit and "AAA" not in composer_after, \
            f"submit_sequence {_brepr(submit_seq)}: did not submit under tmux"
        d.record_tmux_observation(FRAMEWORK, "submit_newline", {
            "newline_inserts": True, "submit_commits": True,
        })
        _interrupt_turn(sess)
    finally:
        sess.graceful_close()


def test_tmux_permission_modal():
    """permission_prompt_signature — -a untrusted escalates a write to the modal."""
    sess = _tmux_session(
        "permission",
        prompt="Run this exact shell command: touch probe-approval-tmux.txt",
        extra_args=["-a", "untrusted"],
    )
    try:
        sess.wait_idle(stable_secs=1.5, timeout=45)
        if TRUST_RE.search(sess.oracle.text()):
            sess.send(b"\r")
            sess.wait_idle(stable_secs=1.5, timeout=30)
        sess.marker("tmux await approval modal")
        modal_seen = False
        deadline = time.time() + 90
        while time.time() < deadline:
            sess.wait_idle(stable_secs=1.5, timeout=30)
            if d.codex_permission_modal(sess.oracle.rows()):
                modal_seen = True
                break
            if find_composer(sess.oracle)[0] and re.search(r"•\s", sess.oracle.text()):
                break
            if not sess.child.isalive():
                break
        rows = sess.oracle.rows()
        assert modal_seen and d.codex_permission_modal(rows), \
            "permission_prompt_signature: approval modal not detected under tmux"
        assert not d.codex_composer_ready(rows), \
            "composer matcher fired during a modal under tmux"
        d.record_tmux_observation(FRAMEWORK, "permission_prompt_signature", {
            "modal_detected": True, "composer_suppressed": True,
        })
        sess.marker("tmux decline modal (Esc)")
        sess.send(b"\x1b")
        sess.drain(2)
    finally:
        sess.graceful_close()
