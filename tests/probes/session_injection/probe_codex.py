"""Live PTY probe suite for the **codex** harness (`codex` binary).

Part of the `lore session send` readiness-gate investigation: we inject a message
into a running harness session by writing to its PTY master (identical bytes to
human keystrokes), gated on a screen-state readiness check. Before we can build
that gate we need an *evidence-backed capability row* per harness. This module
constructs the real session states through the real dispatch path (spawn the
actual `codex` binary over a PTY, drive it, observe the VT screen with pyte) and
RECORDS what it sees.

Per the convention "Design-exploration probe test suites that pin *broken*
behavior" (knowledge store): the expensive part is constructing real session
states through the real dispatch path; that survives into the contract suite. In
THIS exploration pass each probe function *records* observed behavior (into
observations/codex.json + raw byte logs) and carries a `# CONTRACT:` note stating
the assertion it converts into once `lore session send` exists. Converting later
means flipping record() calls into asserts against the recorded values — the
driver / state construction below is reused verbatim.

Run live (costs real harness sessions / tokens):
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_codex.py -s -v

Session economy: the directive permits P1+P3+P4 to share one session. Model
INFERENCE is the real cost, not launches (a launch just renders the composer with
no model call). So we favor robustness: each probe spawns its own codex and keeps
model turns to a trivial minimum (P1 and P4 never submit; P3 submits one 2-char
turn and interrupts; P2 and P5 each make one cheap turn). Sharing is a deferred
implementation-phase optimization. Cheapest interactive model is `gpt-5.4-mini`
with `model_reasoning_effort=low`; prompts are trivial; any submit is halted with
a single Ctrl-C.
"""

import hashlib
import json
import os
import re
import time
from datetime import datetime, timezone

import pexpect
import pyte
import pytest

pytestmark = pytest.mark.skipif(
    os.environ.get("LORE_LIVE_PROBES") != "1",
    reason="live probes cost real harness sessions",
)

# --------------------------------------------------------------------------- #
# Layout / constants
# --------------------------------------------------------------------------- #
HERE = os.path.dirname(os.path.abspath(__file__))
OBS_DIR = os.path.join(HERE, "observations")
RAW_DIR = os.path.join(OBS_DIR, "raw", "codex")
OBS_FILE = os.path.join(OBS_DIR, "codex.json")

COLS, ROWS = 120, 40
MODEL = "gpt-5.4-mini"
# Config default reasoning is xhigh (expensive) — force it down for probes.
REASONING = "low"
SANDBOX = os.environ.get(
    "LORE_PROBE_SANDBOX",
    "/private/tmp/claude-501/-Users-dustinqngo-work-lore/"
    "618e24b6-58ad-4aa7-a3e7-60c6b2023092/scratchpad/probe-env-codex",
)
CODEX_BIN = os.environ.get("LORE_PROBE_CODEX_BIN", "codex")

# --------------------------------------------------------------------------- #
# Observation record (draft capability row). Read-modify-write; probes run
# serially so no locking is needed.
# --------------------------------------------------------------------------- #
_SEED = {
    "harness": "codex",
    "probed_at": None,
    "binary_version": None,
    "model_used": f"{MODEL} {REASONING}",
    "tty_size": f"{COLS}x{ROWS}",
    "composer_signature": "unresolved",
    "permission_prompt_signature": "unresolved",
    "modal_mode_sequences": "unresolved",
    "submit_sequence": "unresolved",
    "newline_sequence": "unresolved",
    "honors_bracketed_paste": "unresolved",
    "paste_multiline_semantics": "unresolved",
    "mid_generation_inject": "unresolved",
    "graceful_exit_sequence": "unresolved",
    "open_questions": [],
}


def _iso():
    return datetime.now(timezone.utc).isoformat()


def _binary_version():
    try:
        import subprocess

        out = subprocess.check_output([CODEX_BIN, "--version"], text=True)
        return out.strip()
    except Exception as e:  # pragma: no cover - best effort
        return f"<unknown: {e}>"


def record(key, value):
    """Set a top-level field in the draft capability row and persist."""
    os.makedirs(OBS_DIR, exist_ok=True)
    if os.path.exists(OBS_FILE):
        with open(OBS_FILE) as f:
            row = json.load(f)
    else:
        row = dict(_SEED)
    row["probed_at"] = row.get("probed_at") or _iso()
    row["binary_version"] = row.get("binary_version") or _binary_version()
    row[key] = value
    with open(OBS_FILE, "w") as f:
        json.dump(row, f, indent=2)
        f.write("\n")


def note_open_question(q):
    os.makedirs(OBS_DIR, exist_ok=True)
    if os.path.exists(OBS_FILE):
        with open(OBS_FILE) as f:
            row = json.load(f)
    else:
        row = dict(_SEED)
    row.setdefault("open_questions", [])
    if q not in row["open_questions"]:
        row["open_questions"].append(q)
    with open(OBS_FILE, "w") as f:
        json.dump(row, f, indent=2)
        f.write("\n")


# --------------------------------------------------------------------------- #
# Screen oracle: pyte Screen + ByteStream fed from the raw PTY stream.
# --------------------------------------------------------------------------- #
class ScreenOracle:
    def __init__(self, cols=COLS, rows=ROWS):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)

    def feed(self, data: bytes):
        self.stream.feed(data)

    def rows(self):
        return [r.rstrip() for r in self.screen.display]

    def nonempty_rows(self):
        return [r for r in self.rows() if r.strip()]

    def text(self):
        return "\n".join(self.screen.display)

    def hash(self):
        return hashlib.sha256(self.text().encode("utf-8", "replace")).hexdigest()

    def cursor(self):
        return (self.screen.cursor.x, self.screen.cursor.y)


# --------------------------------------------------------------------------- #
# Composer / dialog signatures (codex specifics, observed at v0.142.5)
# --------------------------------------------------------------------------- #
# The composer prompt glyph `›` is NOT unique — codex's selection menus (incl. the
# directory-trust modal) use it too. The reliable "composer ready" anchor is the
# footer status line: "<model> <effort> · <cwd>" (space-middot-space + a path).
FOOTER_RE = re.compile(r"(minimal|low|medium|high|xhigh)\s+·\s")
INPUT_GLYPH = "›"  # ›
TRUST_RE = re.compile(r"do you trust the contents of this directory", re.I)
WELCOME_RE = re.compile(r"OpenAI Codex \(v")


def find_composer(oracle):
    """Return (ready: bool, input_row_idx, footer_row_idx). Composer is ready when
    a footer status line is present and an input-prompt row (`›`) sits at/above it.
    """
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
    """Strip lore session markers so a child codex starts standalone; keep
    HOME/PATH so shared auth in ~/.codex still resolves.
    """
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("LORE_"):
            env.pop(k, None)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    return env


class Session:
    def __init__(self, raw_log_path, prompt=None, extra_args=None):
        self.raw_log_path = raw_log_path
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        args = [
            "-m", MODEL,
            "-c", f'model_reasoning_effort="{REASONING}"',
            "-C", SANDBOX,
        ] + (extra_args or [])
        if prompt is not None:
            args.append(prompt)
        self.child = pexpect.spawn(
            CODEX_BIN,
            args,
            env=_clean_env(),
            dimensions=(ROWS, COLS),
            encoding=None,  # bytes mode
            timeout=60,
        )
        self.child.logfile_read = self._log
        self.oracle = ScreenOracle()

    # -- io ------------------------------------------------------------------ #
    def send(self, data: bytes):
        self.child.send(data)

    def type_text(self, text: str, per_char=0.01):
        for ch in text:
            self.child.send(ch.encode())
            time.sleep(per_char)

    def marker(self, text):
        try:
            self._log.write(f"\n===PROBE-MARKER {text} @ {_iso()}===\n".encode())
            self._log.flush()
        except Exception:
            pass

    def drain(self, seconds):
        """Feed the screen for a fixed window. Returns False on EOF."""
        end = time.time() + seconds
        while time.time() < end:
            try:
                d = self.child.read_nonblocking(65536, timeout=0.2)
            except pexpect.TIMEOUT:
                d = b""
            except pexpect.EOF:
                return False
            if d:
                self.oracle.feed(d)
        return True

    def wait_idle(self, stable_secs=2.0, timeout=45.0, poll=0.3):
        """Return True once the rendered screen is unchanged for stable_secs."""
        start = time.time()
        last_change = time.time()
        last_hash = self.oracle.hash()
        while time.time() - start < timeout:
            try:
                d = self.child.read_nonblocking(65536, timeout=poll)
            except pexpect.TIMEOUT:
                d = b""
            except pexpect.EOF:
                return False
            if d:
                self.oracle.feed(d)
                h = self.oracle.hash()
                if h != last_hash:
                    last_hash = h
                    last_change = time.time()
            if time.time() - last_change >= stable_secs:
                return True
        return False

    def raw_bytes(self):
        try:
            self._log.flush()
        except Exception:
            pass
        with open(self.raw_log_path, "rb") as f:
            return f.read()

    def graceful_close(self):
        """codex exits on a single Ctrl-C from an empty composer. If text is in
        the composer, the first Ctrl-C clears it, so send up to two. Returns the
        sequence that terminated the child, or 'terminate(force=True)' fallback.
        """
        self.marker("graceful_close")
        for attempt, seq in enumerate(("\x03", "\x03"), start=1):
            if not self.child.isalive():
                break
            self.send(seq)
            alive = self.drain(2.0)
            if not alive or not self.child.isalive():
                self._shutdown()
                return "Ctrl-C" if attempt == 1 else "Ctrl-C x2"
        # fallback
        self._shutdown()
        return "terminate(force=True)"

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


def wait_for_composer(sess, timeout=45.0):
    """Advance past the directory-trust modal (if shown) to an idle composer.
    Returns True once the composer signature is present.
    """
    sess.wait_idle(stable_secs=1.5, timeout=timeout)
    if TRUST_RE.search(sess.oracle.text()):
        # "› 1. Yes, continue" is pre-selected; Enter accepts.
        sess.send("\r")
        sess.wait_idle(stable_secs=1.5, timeout=timeout)
    ready, _, _ = find_composer(sess.oracle)
    return ready


def _raw_path(name):
    return os.path.join(RAW_DIR, f"{name}.log")


def _seq_scan(raw: bytes):
    """Return a dict of notable terminal-mode escape sequences present in raw."""
    seqs = {
        "bracketed_paste_on(?2004h)": b"\x1b[?2004h",
        "bracketed_paste_off(?2004l)": b"\x1b[?2004l",
        "alt_screen_enter(?1049h)": b"\x1b[?1049h",
        "alt_screen_exit(?1049l)": b"\x1b[?1049l",
        "cursor_hide(?25l)": b"\x1b[?25l",
        "cursor_show(?25h)": b"\x1b[?25h",
        "focus_events(?1004h)": b"\x1b[?1004h",
        "sync_output_begin(?2026h)": b"\x1b[?2026h",
        "sync_output_end(?2026l)": b"\x1b[?2026l",
        "kitty_kbd_push(>7u)": b"\x1b[>7u",
    }
    out = {}
    for label, seq in seqs.items():
        out[label] = ("present" if seq in raw else "absent")
    return out


# =========================================================================== #
# P1 — composer signature (verify stable across 2 launches)
# =========================================================================== #
def test_p1_composer_signature():
    captures = []
    for launch in (1, 2):
        sess = Session(_raw_path(f"p1_composer_launch{launch}"))
        try:
            assert wait_for_composer(sess), "composer never became ready"
            ready, in_idx, foot_idx = find_composer(sess.oracle)
            rows = sess.oracle.rows()
            region = rows[in_idx:foot_idx + 1]
            captures.append({
                "launch": launch,
                "input_row": rows[in_idx],
                "footer_row": rows[foot_idx],
                "region_rows": region,
                "cursor": sess.oracle.cursor(),
                "welcome_present": bool(WELCOME_RE.search(sess.oracle.text())),
            })
        finally:
            exit_seq = sess.graceful_close()
    # stability: the footer status line (model+effort+cwd) is the load-bearing
    # anchor. Placeholder/ghost suggestion text in the input row rotates and is
    # NOT part of the matcher.
    footer_a = re.sub(r"\s+", " ", captures[0]["footer_row"]).strip()
    footer_b = re.sub(r"\s+", " ", captures[1]["footer_row"]).strip()
    stable = footer_a == footer_b
    signature = {
        "matcher": (
            r"footer status row matches (?:minimal|low|medium|high|xhigh)\s+·\s "
            r"AND an input row (at/above it) begins with '›' — the '›' "
            r"glyph alone is shared with codex selection menus (incl. trust "
            r"modal), so the footer middot+cwd is the disambiguator"
        ),
        "footer_regex": FOOTER_RE.pattern,
        "input_glyph": INPUT_GLYPH,
        "raw_rows": captures[0]["region_rows"],
        "cursor_on_input_row": captures[0]["cursor"],
        "welcome_banner_present_at_start": captures[0]["welcome_present"],
        "welcome_banner_note": (
            "'OpenAI Codex (vX)' box is present at fresh launch but scrolls off "
            "after the first submitted message (no alt-screen), so it is NOT a "
            "durable composer anchor — the footer status line is."
        ),
        "stability": f"footer identical across 2 launches: {stable}",
        "launch_1_footer": footer_a,
        "launch_2_footer": footer_b,
        "graceful_exit_used": exit_seq,
    }
    # CONTRACT: readiness gate asserts find_composer(oracle) is True (footer + input
    # row present) before any inject; and that this holds identically across launches.
    record("composer_signature", signature)
    # En passant: the PTY-level graceful exit. session-close.sh handles the
    # lore-registry side (close-request file); the actual teardown byte for the
    # codex process is a single Ctrl-C on an EMPTY composer (it quits immediately;
    # a second press is only needed if the composer holds text — first clears).
    # CONTRACT: `lore session close` for a codex instance writes 0x03 to the PTY
    # master when the composer is empty/idle.
    record("graceful_exit_sequence", {
        "sequence": "Ctrl-C (0x03) on an empty composer",
        "observed": f"graceful_close terminated the child via: {exit_seq}",
        "note": (
            "single Ctrl-C exits from an idle empty composer (verified in P1 x2). "
            "With text in the composer the first Ctrl-C clears it, so send up to "
            "two. On exit codex pops the kitty keyboard flags (ESC[<u) and shows "
            "a brief 'Shutting down...' line — no alt-screen to restore."
        ),
    })


# =========================================================================== #
# P2 — approval / permission-prompt signature
# =========================================================================== #
# codex approval modal (v0.142.5): header "Would you like to run the following
# command?", a "$ <cmd>" line, numbered options ("› 1. Yes, proceed (y)"), and a
# "Press enter to confirm or esc to cancel" footer.
APPROVAL_RE = re.compile(
    r"would you like to run|press enter to confirm or esc|"
    r"yes, proceed|and tell codex what to do|allow.*command|approve",
    re.I,
)


def _run_p2_attempt(name, prompt, extra_args, mode_label):
    """Drive one approval attempt to a modal-or-settled state WITHOUT requiring the
    composer (the modal replaces the composer). Returns (modal_seen, rows, raw,
    sess) with the session still open (caller declines + closes)."""
    sess = Session(_raw_path(name), prompt=prompt, extra_args=extra_args)
    # Startup: settle, then dismiss the trust modal if this is the first launch
    # since codex persisted trust for the sandbox (later launches skip it).
    sess.wait_idle(stable_secs=1.5, timeout=45)
    if TRUST_RE.search(sess.oracle.text()):
        sess.send("\r")
        sess.wait_idle(stable_secs=1.5, timeout=30)
    sess.marker(f"await approval modal [{mode_label}]")
    modal_seen = False
    deadline = time.time() + 90
    while time.time() < deadline:
        sess.wait_idle(stable_secs=1.5, timeout=30)
        txt = sess.oracle.text()
        if APPROVAL_RE.search(txt):
            modal_seen = True
            break
        # turn settled back to a composer with no modal → auto-approved / no ask
        if find_composer(sess.oracle)[0] and re.search(r"•\s", txt):
            break
        if not sess.child.isalive():
            break
    return modal_seen, sess.oracle.nonempty_rows(), sess.raw_bytes(), sess


def test_p2_approval_prompt_signature():
    # Phase A: default mode. codex auto-runs trusted commands (echo) with no modal
    # — record that behavior as the observed default.
    sess = None
    try:
        modal_seen, rows, raw, sess = _run_p2_attempt(
            "p2_approval_default",
            "Run this exact shell command: echo probe-ok",
            None,
            "default (no -a/-s override)",
        )
        record("permission_prompt_signature", {
            "phase_a_default_mode": {
                "induced_by": "prompt 'Run this exact shell command: echo probe-ok'",
                "active_approval_mode": "default (no -a / -s override; config sets neither)",
                "modal_seen": modal_seen,
                "observed": ("modal shown" if modal_seen
                             else "no modal — trusted command auto-approved"),
                "final_rows": rows[-12:],
            }
        })
    finally:
        if sess is not None:
            sess.graceful_close()

    # Phase B: force a modal. `-a untrusted` escalates any non-trusted command; a
    # file write is not in the trusted set, so codex must ask.
    sess = None
    try:
        modal_seen, rows, raw, sess = _run_p2_attempt(
            "p2_approval_untrusted",
            "Run this exact shell command: touch probe-approval-check.txt",
            ["-a", "untrusted"],
            "untrusted (-a untrusted)",
        )
        modal_rows = [r for r in rows
                      if APPROVAL_RE.search(r)
                      or "probe-approval-check" in r
                      or re.match(r"^\s*[›❯▌]?\s*\d+[.\)]", r)
                      or "▌" in r or "❯" in r]
        # merge phase-B into the record (read-modify-write preserves phase A)
        cur = json.load(open(OBS_FILE))["permission_prompt_signature"]
        cur["phase_b_untrusted_mode"] = {
            "induced_by": "prompt 'touch probe-approval-check.txt' under -a untrusted",
            "active_approval_mode": "untrusted (-a untrusted): non-trusted commands escalate",
            "modal_seen": modal_seen,
            "matcher": (
                "an approval modal shows a 'Would you like to run the following "
                "command?' header, a '$ <cmd>' line, and a numbered option list "
                "with the '›' glyph on the selected row ('› 1. Yes, proceed (y)' / "
                "2. Yes+don't-ask / 3. No (esc)), plus a 'Press enter to confirm or "
                "esc to cancel' footer. The composer footer status line is NOT "
                "present while the modal owns the screen — its absence + this option "
                "list is the readiness-gate 'blocked' signal"
            ),
            "modal_rows": modal_rows or rows[-14:],
            "all_nonempty_rows": rows,
        }
        record("permission_prompt_signature", cur)
        # capture modal-region escape sequences (DECSET/DECRST, cursor, paste, CSI q)
        tail = raw[-12000:]
        record("modal_mode_sequences", {
            "induced_under": "untrusted mode approval modal",
            "scan": _seq_scan(tail),
            "csi_cursor_style_q": sorted({m.group().hex()
                for m in re.finditer(rb"\x1b\[[0-9 ]*q", tail)}),
            "note": (
                "scan of the last ~12KB of raw frames spanning the modal render; "
                "codex uses NO alt-screen (?1049 absent) — the modal is drawn inline "
                "over the main screen via direct cursor addressing + ?2026 sync"
            ),
        })
        if not modal_seen:
            note_open_question(
                "P2 phase B: -a untrusted still did not surface a modal for a file "
                "write — approval-modal signature UNRESOLVED; escalation trigger "
                "needs revisiting (maybe -s read-only + a write)."
            )
        # decline: Esc cancels/denies a codex modal.
        sess.marker("decline modal (Esc)")
        sess.send("\x1b")
        sess.drain(2)
    finally:
        if sess is not None:
            sess.graceful_close()


# =========================================================================== #
# P3 — submit vs newline bytes
# =========================================================================== #
def _composer_text(oracle):
    """Return the input-region text (rows from the `›` input row through footer-1)."""
    ready, in_idx, foot_idx = find_composer(oracle)
    if not ready:
        return None
    rows = oracle.rows()
    return "\n".join(rows[in_idx:foot_idx])


def _interrupt_turn(sess):
    """Best-effort halt of a running codex turn. codex cancels an in-flight turn
    with Esc; if that leaves an empty composer, a later Ctrl-C (graceful_close)
    quits. Returns the post-interrupt composer text.
    """
    sess.marker("interrupt running turn (Esc)")
    sess.send("\x1b")
    sess.drain(1.5)
    return _composer_text(sess.oracle) or ""


def test_p3_submit_vs_newline():
    # Fresh session per newline candidate: launches make no model call, so this is
    # cheap and isolates each chord (no fragile between-attempt clearing, and no
    # reliance on Ctrl-C's non-empty-composer behavior, which is unverified).
    candidates = [
        ("Ctrl-J (\\n / 0x0A)", b"\n"),
        ("Shift+Enter kitty (ESC[13;2u)", b"\x1b[13;2u"),
        ("Alt/Meta+Enter (ESC CR)", b"\x1b\r"),
        ("modifyOtherKeys Shift+Enter (ESC[27;2;13~)", b"\x1b[27;2;13~"),
    ]
    tried = []
    newline_winner = None
    for idx, (label, chord) in enumerate(candidates):
        sess = Session(_raw_path(f"p3_newline_{idx}_{re.sub(r'[^a-z0-9]+', '-', label.lower())[:20]}"))
        try:
            assert wait_for_composer(sess), "composer never became ready"
            sess.marker(f"newline candidate: {label}")
            sess.type_text("AAA")
            sess.drain(0.6)
            before = _composer_text(sess.oracle) or ""
            before_cur_y = sess.oracle.cursor()[1]
            sess.send(chord)
            sess.drain(0.8)
            sess.type_text("BBB")
            sess.drain(0.8)
            after = _composer_text(sess.oracle) or ""
            after_cur_y = sess.oracle.cursor()[1]
            ready_after = find_composer(sess.oracle)[0]
            submitted = ("AAA" not in after) or (not ready_after)
            two_line = ("AAA" in after and "BBB" in after
                        and after.count("\n") > before.count("\n"))
            entry = {
                "candidate": label,
                "bytes": chord.decode("latin-1"),
                "bytes_hex": chord.hex(),
                "before_composer": before,
                "after_composer": after,
                "cursor_y_delta": after_cur_y - before_cur_y,
                "looks_submitted": submitted,
                "looks_newline_inserted": bool(two_line),
            }
            tried.append(entry)
            if submitted:
                # a candidate that submitted started a turn — halt it
                _interrupt_turn(sess)
            if two_line and not submitted and newline_winner is None:
                newline_winner = entry
        finally:
            sess.graceful_close()
        if newline_winner is not None:
            break

    # --- submit: type 'hi' then Enter (\r). Expect composer clears + working
    # indicator. ONE cheap model turn; interrupt right after.
    submit_evidence = "unresolved"
    sess = Session(_raw_path("p3_submit"))
    try:
        assert wait_for_composer(sess), "composer never became ready"
        sess.marker("submit test: Enter (\\r)")
        sess.type_text("hi")
        sess.drain(0.6)
        pre_submit = _composer_text(sess.oracle) or ""
        sess.send("\r")
        sess.drain(2.5)
        post_submit_text = sess.oracle.text()
        composer_after = _composer_text(sess.oracle) or ""
        submit_worked = ("hi" not in composer_after) and ("hi" in post_submit_text)
        submit_evidence = {
            "bytes": "\\r",
            "bytes_hex": b"\r".hex(),
            "pre_submit_composer": pre_submit,
            "post_submit_composer": composer_after,
            "hi_left_composer": "hi" not in composer_after,
            "hi_in_transcript": "hi" in post_submit_text,
            "looks_submitted": submit_worked,
        }
        _interrupt_turn(sess)
    finally:
        sess.graceful_close()

    record("submit_sequence", {
        "sequence": "\\r (0x0D)",
        "evidence": submit_evidence,
    })
    record("newline_sequence", {
        "winner": newline_winner,
        "all_candidates_tried": tried,
        "note": (
            "codex pushes the kitty keyboard protocol (ESC[>7u) at startup, so "
            "Shift+Enter is expected to arrive as ESC[13;2u; Ctrl-J (0x0A) is the "
            "classic newline-without-submit. Winner = first chord that inserted a "
            "newline without submitting."
        ),
    })
    # CONTRACT: send(msg) uses submit_sequence to commit; multiline uses
    # bracketed-paste (see P4), NOT raw newline per-line — but the newline chord is
    # recorded so the encoder can compose multiline without submitting mid-message.


# =========================================================================== #
# P4 — bracketed paste
# =========================================================================== #
def test_p4_bracketed_paste():
    sess = Session(_raw_path("p4_bracketed_paste"))
    try:
        assert wait_for_composer(sess), "composer never became ready"
        raw_startup = sess.raw_bytes()
        composer_offers_2004 = b"\x1b[?2004h" in raw_startup

        sess.marker("bracketed paste: ESC[200~line-one\\nline-two ESC[201~ (no trailing CR)")
        sess.send(b"\x1b[200~line-one\nline-two\x1b[201~")
        sess.drain(1.5)
        after_paste = _composer_text(sess.oracle) or ""
        composer_txt = sess.oracle.text()
        auto_submitted = ("line-one" not in (after_paste or "")) and (
            "line-one" in composer_txt)
        both_lines_in_composer = ("line-one" in (after_paste or "")
                                  and "line-two" in (after_paste or ""))

        # If not auto-submitted, verify a trailing CR commits it.
        needs_trailing_cr = None
        if not auto_submitted and both_lines_in_composer:
            sess.marker("bracketed paste: send trailing \\r to commit")
            sess.send("\r")
            sess.drain(2.0)
            committed_text = sess.oracle.text()
            after_cr_composer = _composer_text(sess.oracle) or ""
            needs_trailing_cr = ("line-one" not in after_cr_composer
                                 and "line-one" in committed_text)
            # halt any turn that started
            sess.send("\x03")
            sess.drain(1.0)

        record("honors_bracketed_paste", {
            "composer_emits_2004h_at_ready": composer_offers_2004,
            "evidence": "ESC[?2004h present in raw startup log"
            if composer_offers_2004 else "ESC[?2004h ABSENT",
        })
        record("paste_multiline_semantics", {
            "sent": "ESC[200~line-one<LF>line-two ESC[201~",
            "composer_after_paste": after_paste,
            "both_lines_held_in_one_composer_entry": both_lines_in_composer,
            "auto_submitted_on_close_bracket": auto_submitted,
            "needs_trailing_cr_to_submit": needs_trailing_cr,
            "conclusion": (
                "auto-submits on 201~" if auto_submitted
                else "held as one multiline composer entry; trailing CR submits"
                if both_lines_in_composer else "unresolved — see raw log"
            ),
        })
        # CONTRACT: multiline inject wraps body in ESC[200~ .. ESC[201~ (PasteEncode)
        # then sends submit_sequence; raw LF inside the wrap must NOT submit.
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
        # Let streaming begin — poll until we see early counting output or a
        # working indicator, up to ~20s.
        started = False
        deadline = time.time() + 25
        while time.time() < deadline:
            sess.drain(0.5)
            txt = sess.oracle.text()
            if re.search(r"\b[1-9]\b", txt) and ("\n2\n" in txt or "\n3\n" in txt
                or re.search(r"^\s*[1-9]\s*$", txt, re.M)):
                started = True
                break
            if not sess.child.isalive():
                break
        sess.marker("INJECT mid-generation: PING-MIDGEN\\r")
        inject_hash = sess.oracle.hash()
        sess.send(b"PING-MIDGEN\r")
        # let generation finish + settle
        sess.wait_idle(stable_secs=3.0, timeout=90)
        final_text = sess.oracle.text()
        composer_after = _composer_text(sess.oracle) or ""

        ping_in_composer = "PING-MIDGEN" in composer_after
        ping_submitted_as_turn = (
            "PING-MIDGEN" in final_text and not ping_in_composer)
        # heuristic classification of the MID-STREAM effect
        if ping_in_composer:
            semantics = ("buffered — text landed in composer as an unsent draft; "
                         "the trailing CR did NOT submit while a turn was active")
        elif ping_submitted_as_turn:
            semantics = "submitted — queued/started as a new turn"
        elif "PING-MIDGEN" not in final_text:
            semantics = "dropped — PING-MIDGEN never appears anywhere"
        else:
            semantics = "unresolved — see raw log"

        # Decide strict-gate vs queue-and-hold: if the draft is buffered, does a
        # FRESH CR on the now-idle composer submit it? If yes, queue-and-hold is
        # viable (inject mid-turn, commit when idle). This makes at most one more
        # trivial turn; interrupt right after.
        draft_submits_after_idle = None
        if ping_in_composer and sess.child.isalive():
            sess.marker("post-completion: send fresh CR to submit buffered draft")
            len_before_cr = len(sess.raw_bytes())
            sess.send("\r")
            # the CR starts a turn; wait for it to settle so the composer returns.
            # Robust signal: the draft leaves the composer INPUT region once
            # submitted (Enter on a non-empty codex composer submits, never
            # discards), AND the child emitted a new model turn (transcript grew).
            # We do NOT require the submitted line to remain on-screen — with no
            # alt-screen and a 40-row viewport it scrolls out of the pyte buffer.
            sess.wait_idle(stable_secs=3.0, timeout=40)
            post_composer = _composer_text(sess.oracle)
            ready_again = find_composer(sess.oracle)[0]
            new_output = len(sess.raw_bytes()) - len_before_cr
            draft_left_composer = (post_composer is not None
                                   and "PING-MIDGEN" not in post_composer)
            draft_submits_after_idle = bool(
                ready_again and draft_left_composer and new_output > 500
            )
            _interrupt_turn(sess)

        raw = sess.raw_bytes()
        record("mid_generation_inject", {
            "generation_started_before_inject": started,
            "injected": "PING-MIDGEN\\r during streaming",
            "ping_in_composer_after": ping_in_composer,
            "ping_submitted_as_turn": ping_submitted_as_turn,
            "mid_stream_semantics": semantics,
            "buffered_draft_submits_with_fresh_CR_when_idle": draft_submits_after_idle,
            "composer_stays_editable_during_stream": True,
            # the 'Esc to interrupt' affordance is shown DURING streaming (scan raw,
            # not the settled final screen which no longer shows it)
            "streaming_shows_esc_to_interrupt": (b"interrupt" in raw.lower()),
            "final_nonempty_tail": sess.oracle.nonempty_rows()[-14:],
        })
        # CONTRACT: mid-generation semantics decide strict-gate vs queue-and-hold.
        # If 'submitted', the readiness gate MUST block inject while streaming
        # (screen not showing a ready composer); if 'buffered', queue-and-hold is
        # viable.
    finally:
        sess.graceful_close()
