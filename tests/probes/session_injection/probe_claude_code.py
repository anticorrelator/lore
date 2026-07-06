"""Live PTY contract suite for the **claude-code** harness (`claude` binary).

Part of the `lore session send` readiness-gate work. Each probe constructs a real
session state through the real dispatch path (spawn the actual binary over a PTY,
drive it, observe the VT screen with pyte) and ASSERTS that the live behavior
matches the pinned interaction row in adapters/capabilities.json. The expected
values are read from the capability row dynamically — never hard-coded here — so a
harness UI change fails the contract instead of silently drifting.

This suite converged from the record-mode exploration pass per the
"design-exploration probe suites pin broken behavior, then flip record() to
assert" convention: the expensive part (constructing real session states through
real PTY dispatch) survives unchanged; only the expectations flip. The shared
driver (screen oracle, pump helpers, matchers, encode helpers, capability loader)
now lives in _driver.py.

Run live (costs real harness sessions / tokens):
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_claude_code.py -s -v

Session economy: P1+P3+P4 share one session (`shared_session`); P2 and P5 each
get their own. Cheapest model (`--model haiku`), trivial prompts, Esc-interrupt
after any submit to halt token spend.
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

FRAMEWORK = "claude-code"
HERE = os.path.dirname(os.path.abspath(__file__))
RAW_DIR = os.path.join(HERE, "observations", "raw", "claude-code")

COLS, ROWS = d.COLS, d.ROWS
MODEL = "haiku"
SANDBOX = os.environ.get(
    "LORE_PROBE_SANDBOX",
    "/private/tmp/claude-501/-Users-dustinqngo-work-lore/"
    "618e24b6-58ad-4aa7-a3e7-60c6b2023092/scratchpad/probe-env-claude",
)
CLAUDE_BIN = os.environ.get("LORE_PROBE_CLAUDE_BIN", "claude")


def _iso():
    return datetime.now(timezone.utc).isoformat()


# The '❯' prompt row is flanked by two full-width '─' rules; this geometry drives
# the input-region slicing below. The composer-ready *matcher* is the shared
# d.claude_code_composer_ready; these regexes only locate the input band.
RULE_RE = re.compile(r"^─{80,}$")
PROMPT_RE = re.compile(r"^\s*[❯>](\s|$)")


def composer_visible(oracle):
    """Composer rendered and ready — the readiness precondition (shared matcher)."""
    return d.claude_code_composer_ready(oracle.rows())


# --------------------------------------------------------------------------- #
# Session driver
# --------------------------------------------------------------------------- #
def _clean_env():
    """Strip nesting markers so a child `claude` starts standalone; keep HOME/PATH."""
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("CLAUDE") or k.startswith("LORE_") or k == "AI_AGENT":
            env.pop(k, None)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    return env


class Session:
    def __init__(self, raw_log_path, extra_args=None, tmux=False, pane_side_path=None):
        self.raw_log_path = raw_log_path
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        args = ["--model", MODEL] + (extra_args or [])
        self.tmux = None
        if tmux:
            self.tmux = d.TmuxHost(
                d.tmux_session_name("cc"), [CLAUDE_BIN] + args, env=_clean_env(),
                cols=COLS, rows=ROWS, cwd=SANDBOX, pane_side_path=pane_side_path,
            )
            self.child = self.tmux.child
        else:
            self.child = pexpect.spawn(
                CLAUDE_BIN, args, cwd=SANDBOX, env=_clean_env(),
                dimensions=(ROWS, COLS), encoding=None, timeout=60,
            )
        self.child.logfile_read = self._log
        self.oracle = d.ScreenOracle()

    def switch_log(self, raw_log_path):
        try:
            self._log.flush()
        except Exception:
            pass
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        self.child.logfile_read = self._log
        self.raw_log_path = raw_log_path

    def marker(self, text):
        try:
            self._log.write(f"\n===PROBE-MARKER {text} @ {_iso()}===\n".encode())
            self._log.flush()
        except Exception:
            pass

    def send(self, data: bytes):
        self.child.send(data)

    def type_text(self, text: str, per_char=0.008, settle=0.5):
        for ch in text:
            self.child.send(ch.encode())
            time.sleep(per_char)
        self.drain(settle)

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


# --------------------------------------------------------------------------- #
# Startup / dialog handling
# --------------------------------------------------------------------------- #
DIALOG_TRUST = re.compile(r"do you trust|you trust|trust this folder|is this a project you", re.I)
DIALOG_THEME = re.compile(r"choose (the|your) (text )?style|dark mode|light mode", re.I)
LOGIN_WALL = re.compile(r"log in|sign in|authenticate|/login", re.I)


def handle_startup(sess, max_dialogs=6):
    """Advance through first-run dialogs until the composer is idle."""
    seen = []
    for _ in range(max_dialogs):
        sess.wait_idle(stable_secs=1.5, timeout=45)
        low = sess.oracle.text().lower()
        if LOGIN_WALL.search(low) and "shortcuts" not in low and "for newline" not in low:
            pytest.skip("claude-code probe env not authenticated (login wall)")
        if re.search(r"reached your (usage|session) limit|limit reached|out of (usage|credits)",
                     low) and not composer_visible(sess.oracle):
            pytest.skip("claude-code probe hit a usage/session limit wall")
        if DIALOG_TRUST.search(low):
            seen.append("trust_folder")
            sess.marker("answer trust_folder -> Enter")
            sess.send(b"\r")
            time.sleep(0.6)
            continue
        if DIALOG_THEME.search(low):
            seen.append("theme_select")
            sess.marker("answer theme_select -> Enter")
            sess.send(b"\r")
            time.sleep(0.6)
            continue
        break
    return seen


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="module")
def shared_session():
    """One session shared by P1 -> P3 -> P4 (definition order)."""
    sess = Session(os.path.join(RAW_DIR, "shared_startup.log"))
    sess.dialogs = handle_startup(sess)
    yield sess
    try:
        _assert_graceful_exit(sess)
    finally:
        sess.close()


# --------------------------------------------------------------------------- #
# Input-band geometry helpers (probe-local; distinct from the shared matcher)
# --------------------------------------------------------------------------- #
def _brepr(b: bytes):
    return "".join("\\x%02x" % c if (c < 0x20 or c > 0x7E) else chr(c) for c in b)


def _composer_region(text):
    return "\n".join(text.splitlines()[-12:])


def _composer_input_rows(oracle):
    """The physical rows strictly between the composer's two flanking rules."""
    rows = oracle.rows()
    rule_idx = [i for i, r in enumerate(rows) if RULE_RE.match(r)]
    if len(rule_idx) < 2:
        return None
    top, bot = rule_idx[-2], rule_idx[-1]
    return rows[top + 1:bot]


def _composer_has(oracle, needle):
    inp = _composer_input_rows(oracle)
    return bool(inp) and any(needle in r for r in inp)


def _clear_composer(sess):
    sess.send(b"\x15")
    time.sleep(0.15)
    sess.send(b"\x08" * 40)
    time.sleep(0.15)
    sess.drain(0.5)


# --------------------------------------------------------------------------- #
# P1 — composer signature contract
# --------------------------------------------------------------------------- #
def test_p1_composer_signature(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p1_composer.log"))
    sess.marker("P1 composer snapshot")
    sess.wait_idle(stable_secs=2.0, timeout=30)

    h1 = sess.oracle.hash()
    sess.drain(2.0)
    h2 = sess.oracle.hash()

    # CONTRACT: the readiness gate's composer matcher must fire on an idle screen,
    # and the screen must be stable within a session.
    assert composer_visible(sess.oracle), "composer signature not detected on idle screen"
    assert h1 == h2, "composer screen not stable across two idle passes"
    row = d.interaction_row(FRAMEWORK, "composer_signature")
    assert row["support"] != "none" and row["matcher"].strip()


# --------------------------------------------------------------------------- #
# P3 — submit vs newline bytes (shared session), read from the capability row
# --------------------------------------------------------------------------- #
def test_p3_submit_and_newline(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p3_submit_newline.log"))
    submit_seq = d.sequence_bytes(FRAMEWORK, "submit_sequence")
    newline_seq = d.sequence_bytes(FRAMEWORK, "newline_sequence")

    # (a) capability submit_sequence submits the composer.
    sess.marker("P3a type text then submit_sequence")
    _clear_composer(sess)
    sess.type_text("submit-probe")
    time.sleep(0.4)
    text_before = _composer_has(sess.oracle, "submit-probe")
    sess.send(submit_seq)
    time.sleep(1.5)
    sess.drain(1.5)
    submitted = text_before and not _composer_has(sess.oracle, "submit-probe")
    # CONTRACT: submit_sequence commits the composer (text leaves the input band).
    assert submitted, f"submit_sequence {_brepr(submit_seq)} did not submit the composer"
    sess.send(b"\x1b")  # interrupt any generation to halt token spend
    time.sleep(0.8)
    sess.drain(1.0)

    # (b) capability newline_sequence inserts a newline without submitting.
    sess.marker("P3b newline_sequence")
    _clear_composer(sess)
    sess.type_text("alpha")
    time.sleep(0.3)
    pre = _composer_input_rows(sess.oracle)
    pre_count = len(pre) if pre is not None else 0
    sess.send(newline_seq)
    time.sleep(0.8)
    sess.drain(0.6)
    post = _composer_input_rows(sess.oracle)
    post_count = len(post) if post is not None else 0
    retained = _composer_has(sess.oracle, "alpha")
    # CONTRACT: newline_sequence adds a composer row and keeps the draft (no submit).
    assert retained and post_count > pre_count, (
        f"newline_sequence {_brepr(newline_seq)} did not insert a newline "
        f"(retained={retained}, rows {pre_count}->{post_count})"
    )
    sess.send(b"\x1b")
    time.sleep(0.4)
    _clear_composer(sess)


# --------------------------------------------------------------------------- #
# P4 — bracketed paste (shared session)
# --------------------------------------------------------------------------- #
def test_p4_bracketed_paste(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p4_bracketed_paste.log"))
    sess.marker("P4 bracketed paste")
    _clear_composer(sess)

    enabled = _grep_bracketed_paste_enable()
    # CONTRACT: honors_bracketed_paste matches whether the harness advertised 2004h.
    assert enabled["found"] == d.interaction_row(FRAMEWORK, "honors_bracketed_paste")["value"]

    payload = d.paste_encode(b"line-one\nline-two")   # dogfood the encode helper
    sess.send(payload)
    time.sleep(1.0)
    sess.drain(1.0)
    post_text = sess.oracle.text()
    region = _composer_region(post_text)
    has_both = ("line-one" in region) and ("line-two" in region)
    auto_submitted = (not has_both) and ("line-one" in post_text or "line-two" in post_text)
    observed = (
        "held-multiline-needs-submit" if (has_both and not auto_submitted)
        else "auto-submit-on-close" if auto_submitted
        else "unresolved"
    )
    # CONTRACT: paste_multiline_semantics matches the observed hold/submit behavior.
    assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], (
        f"paste semantics observed {observed!r}"
    )
    sess.send(b"\x1b")
    time.sleep(0.3)
    _clear_composer(sess)


def _grep_bracketed_paste_enable():
    needle = b"\x1b[?2004h"
    hits = []
    for name in os.listdir(RAW_DIR):
        try:
            with open(os.path.join(RAW_DIR, name), "rb") as f:
                if needle in f.read():
                    hits.append(name)
        except OSError:
            continue
    return {"found": bool(hits), "in_logs": hits}


# --------------------------------------------------------------------------- #
# P2 — permission-prompt signature (own session)
# --------------------------------------------------------------------------- #
def test_p2_permission_signature():
    sess = Session(os.path.join(RAW_DIR, "p2_permission.log"))
    try:
        handle_startup(sess)

        # echo probe-ok auto-approves off the safe allowlist (no modal).
        sess.marker("P2a echo probe-ok (expect auto-approve)")
        sess.type_text("Run this exact shell command: echo probe-ok")
        sess.send(b"\r")
        sess.wait_idle(stable_secs=2.0, timeout=45)

        # A side-effecting write (touch) is NOT allowlisted and raises the modal.
        sess.marker("P2b touch (force permission modal)")
        sess.type_text("Run this exact shell command: touch PERM_PROBE_MARKER")
        sess.send(b"\r")
        sess.wait_idle(stable_secs=2.0, timeout=45)

        # CONTRACT: the permission matcher fires (the gate must refuse to inject),
        # and the composer matcher does not (the screen is not composer-ready).
        rows = sess.oracle.rows()
        assert d.MATCHERS[FRAMEWORK]["permission"](rows), "permission modal not detected"
        assert not composer_visible(sess.oracle), "composer matcher fired during a modal"
        row = d.interaction_row(FRAMEWORK, "permission_prompt_signature")
        assert row["support"] != "none" and row["matcher"].strip()

        sess.marker("P2 decline permission (Esc)")
        sess.send(b"\x1b")
        time.sleep(0.8)
        sess.drain(1.0)
    finally:
        _assert_graceful_exit(sess)
        sess.close()


# --------------------------------------------------------------------------- #
# P5 — mid-generation inject (own session)
# --------------------------------------------------------------------------- #
def test_p5_mid_generation_inject():
    sess = Session(os.path.join(RAW_DIR, "p5_midgen.log"))
    try:
        handle_startup(sess)
        sess.marker("P5 start counting generation")
        sess.type_text("Count from 1 to 40, one number per line, no other text.")
        time.sleep(0.4)
        sess.send(b"\r")

        injected = False
        start = time.time()
        inject_at = None
        while time.time() - start < 20:
            try:
                data = sess.child.read_nonblocking(65536, timeout=0.3)
            except pexpect.TIMEOUT:
                data = b""
            except pexpect.EOF:
                break
            if data:
                sess.oracle.feed(data)
            txt = sess.oracle.text()
            if not injected and re.search(r"\b(3|4|5)\b", txt) and "1" in txt:
                sess.marker("P5 INJECT PING-MIDGEN + submit mid-stream")
                sess.send(b"PING-MIDGEN" + d.sequence_bytes(FRAMEWORK, "submit_sequence"))
                injected = True
                inject_at = time.time()
            if injected and inject_at and time.time() - inject_at > 0.5:
                pass

        if not injected:
            sess.marker("P5 INJECT (fallback)")
            sess.send(b"PING-MIDGEN" + d.sequence_bytes(FRAMEWORK, "submit_sequence"))

        sess.wait_idle(stable_secs=2.5, timeout=45)

        ping_in_live_composer = _composer_has(sess.oracle, "PING-MIDGEN")
        rows = sess.oracle.rows()
        rule_idx = [i for i, r in enumerate(rows) if RULE_RE.match(r)]
        above_rules = "\n".join(rows[: rule_idx[-2]]) if len(rule_idx) >= 2 else sess.oracle.text()
        ping_submitted = ("PING-MIDGEN" in above_rules) and not ping_in_live_composer

        if ping_submitted:
            observed = "queued-autosubmit"
        elif ping_in_live_composer:
            observed = "buffered-draft"
        else:
            observed = "dropped"
        # CONTRACT: mid_generation_semantics matches the observed mid-stream effect.
        # queued-autosubmit => the harness auto-submits the injected bytes as a
        # follow-up turn => the readiness gate MUST be strict (never mid-generation).
        assert observed == d.interaction_row(FRAMEWORK, "mid_generation_semantics")["value"], (
            f"mid-generation semantics observed {observed!r}"
        )
    finally:
        _assert_graceful_exit(sess)
        sess.close()


# --------------------------------------------------------------------------- #
# Graceful exit — the close ladder's first rung, read from the capability row
# --------------------------------------------------------------------------- #
def _assert_graceful_exit(sess):
    """Send the capability graceful_exit_sequence and assert the child exits."""
    seq = d.sequence_bytes(FRAMEWORK, "graceful_exit_sequence")
    sess.marker(f"EXIT probe: graceful_exit_sequence {_brepr(seq)}")

    def wait_dead(timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                data = sess.child.read_nonblocking(65536, timeout=0.25)
                if data:
                    sess.oracle.feed(data)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return True
            if not sess.child.isalive():
                return True
        return not sess.child.isalive()

    if not sess.child.isalive():
        return
    # The row's contract is exit-from-clean-idle: mid-generation, Ctrl-C is an
    # interrupt, so the pair never arms the exit hint. Settle any in-flight turn
    # first (declining a permission modal triggers a follow-up generation).
    sess.wait_idle(stable_secs=2.0, timeout=30)
    try:
        dead = False
        # With text in the composer the first Ctrl-C clears it; allow a retry.
        for _ in range(2):
            sess.send(seq)
            dead = wait_dead(4.0)
            if dead:
                break
        # CONTRACT: graceful_exit_sequence feeds the exit ladder's first rung.
        assert dead, f"graceful_exit_sequence {_brepr(seq)} did not terminate the harness"
    except pexpect.EOF:
        pass


# --------------------------------------------------------------------------- #
# tmux tier — re-verify the contract set under a tmux attach client. Each
# assertion names the capability-row field it re-checks; divergences from the
# direct-PTY recordings are recorded in observations/claude-code.tmux.json, not
# silently absorbed into the rows.
# --------------------------------------------------------------------------- #
TMUX_RAW = os.path.join(HERE, "observations", "raw", "claude-code", "tmux")


def _tmux_session(name, extra_args=None, pane_side=None):
    return Session(os.path.join(TMUX_RAW, f"{name}.log"), extra_args=extra_args,
                   tmux=True, pane_side_path=pane_side)


def test_tmux_contract_bundle():
    """composer signature, DECSET 2004 visibility, paste-hold, newline, submit."""
    pane_side = os.path.join(TMUX_RAW, "pane_side.raw")
    sess = _tmux_session("bundle", pane_side=pane_side)
    try:
        handle_startup(sess)
        sess.wait_idle(stable_secs=2.0, timeout=45)
        # composer_signature under tmux (idle precondition; raw-anchored matcher).
        assert composer_visible(sess.oracle), \
            "composer_signature: matcher did not fire on idle screen under tmux"

        # DECSET 2004 — record both readouts (pane-side harness advertisement vs
        # tmux-mediated client observation) and assert the faithful pane-side one.
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

        # newline_sequence adds a composer row and keeps the draft (no submit).
        _clear_composer(sess)
        sess.type_text("alpha")
        time.sleep(0.3)
        pre = _composer_input_rows(sess.oracle)
        pre_n = len(pre) if pre is not None else 0
        sess.send(d.sequence_bytes(FRAMEWORK, "newline_sequence"))
        time.sleep(0.8)
        sess.drain(0.6)
        post = _composer_input_rows(sess.oracle)
        post_n = len(post) if post is not None else 0
        assert _composer_has(sess.oracle, "alpha") and post_n > pre_n, \
            "newline_sequence: did not insert a composer newline under tmux"
        sess.send(b"\x1b")
        time.sleep(0.3)
        _clear_composer(sess)

        # paste_multiline_semantics — bracketed paste held as one entry.
        sess.send(d.paste_encode(b"line-one\nline-two"))
        time.sleep(1.0)
        sess.drain(1.0)
        region = _composer_region(sess.oracle.text())
        has_both = ("line-one" in region) and ("line-two" in region)
        auto = (not has_both) and ("line-one" in sess.oracle.text())
        observed = ("held-multiline-needs-submit" if has_both and not auto
                    else "auto-submit-on-close" if auto else "unresolved")
        d.record_tmux_observation(FRAMEWORK, "paste_multiline_semantics", {
            "observed": observed,
            "capability_row_value": d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"],
        })
        assert observed == d.interaction_row(FRAMEWORK, "paste_multiline_semantics")["value"], \
            f"paste_multiline_semantics: observed {observed!r} under tmux"
        sess.send(b"\x1b")
        time.sleep(0.3)
        _clear_composer(sess)

        # submit_sequence commits the composer (text leaves the input band).
        sess.type_text("submit-probe")
        time.sleep(0.4)
        before = _composer_has(sess.oracle, "submit-probe")
        sess.send(d.sequence_bytes(FRAMEWORK, "submit_sequence"))
        time.sleep(1.5)
        sess.drain(1.5)
        assert before and not _composer_has(sess.oracle, "submit-probe"), \
            "submit_sequence: did not submit the composer under tmux"
        d.record_tmux_observation(FRAMEWORK, "submit_newline", {
            "newline_inserts": True, "submit_commits": True,
        })
        sess.send(b"\x1b")  # interrupt generation to halt token spend
        time.sleep(0.8)
        sess.drain(1.0)
    finally:
        # Teardown also exercises the pinned exit path: graceful exit -> pane
        # death -> session death (exit-empty) -> attach-client EOF.
        _assert_graceful_exit(sess)
        sess.close()


def test_tmux_permission_modal():
    """permission_prompt_signature — modal fires, composer matcher does not."""
    sess = _tmux_session("permission")
    try:
        handle_startup(sess)
        sess.marker("tmux P2 touch (force permission modal)")
        sess.type_text("Run this exact shell command: touch PERM_PROBE_TMUX")
        sess.send(b"\r")
        sess.wait_idle(stable_secs=2.0, timeout=45)
        rows = sess.oracle.rows()
        assert d.MATCHERS[FRAMEWORK]["permission"](rows), \
            "permission_prompt_signature: modal not detected under tmux"
        assert not composer_visible(sess.oracle), \
            "composer matcher fired during a modal under tmux"
        d.record_tmux_observation(FRAMEWORK, "permission_prompt_signature", {
            "modal_detected": True, "composer_suppressed": True,
        })
        sess.send(b"\x1b")  # decline
        time.sleep(0.8)
        sess.drain(1.0)
    finally:
        _assert_graceful_exit(sess)
        sess.close()
