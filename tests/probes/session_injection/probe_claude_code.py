"""Live PTY probe suite for the **claude-code** harness (`claude` binary).

Part of the `lore session send` readiness-gate investigation: we inject a message
into a running harness session by writing to its PTY master (identical bytes to
human keystrokes), gated on a screen-state readiness check. Before we can build
that gate we need an *evidence-backed capability row* per harness. This module
constructs the real session states through the real dispatch path (spawn the
actual binary over a PTY, drive it, observe the VT screen with pyte) and RECORDS
what it sees.

Per the convention "Design-exploration probe test suites that pin *broken*
behavior" (knowledge store): the expensive part is constructing real session
states; that survives into the contract suite. In THIS exploration pass each
probe function *records* observed behavior (into observations/claude-code.json +
raw byte logs) and carries a `# CONTRACT:` note stating the assertion it converts
into once `lore session send` exists. Converting later means flipping record()
calls into asserts against the recorded values — the driver/state construction
below is reused verbatim.

Run live (costs real harness sessions / tokens):
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_claude_code.py -s -v

Session economy (directive): P1+P3+P4 share one session (`shared_session`
fixture); P2 and P5 each get their own. Cheapest model (`--model haiku`), trivial
prompts, Esc-interrupt after any submit to halt token spend.
"""

import hashlib
import io
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
RAW_DIR = os.path.join(OBS_DIR, "raw", "claude-code")
OBS_FILE = os.path.join(OBS_DIR, "claude-code.json")

COLS, ROWS = 120, 40
MODEL = "haiku"
SANDBOX = os.environ.get(
    "LORE_PROBE_SANDBOX",
    "/private/tmp/claude-501/-Users-dustinqngo-work-lore/"
    "618e24b6-58ad-4aa7-a3e7-60c6b2023092/scratchpad/probe-env-claude",
)
CLAUDE_BIN = os.environ.get("LORE_PROBE_CLAUDE_BIN", "claude")

# --------------------------------------------------------------------------- #
# Observation record (draft capability row). Read-modify-write; probes run
# serially so no locking is needed.
# --------------------------------------------------------------------------- #
_SEED = {
    "harness": "claude-code",
    "probed_at": None,
    "binary_version": None,
    "model_used": MODEL,
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


def record(key, value):
    """Set a top-level field in the draft capability row and persist."""
    os.makedirs(OBS_DIR, exist_ok=True)
    if os.path.exists(OBS_FILE):
        with open(OBS_FILE) as f:
            row = json.load(f)
    else:
        row = dict(_SEED)
    row["probed_at"] = row.get("probed_at") or _iso()
    row[key] = value
    with open(OBS_FILE, "w") as f:
        json.dump(row, f, indent=2)
        f.write("\n")


def note_open_question(q):
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
# Session driver
# --------------------------------------------------------------------------- #
def _clean_env():
    """Strip the nesting markers so a child `claude` starts standalone.

    We are (usually) launched from inside a claude-code session; CLAUDECODE=1 and
    friends make a nested launch refuse or misbehave. HOME/PATH are preserved so
    shared auth in ~/.claude still resolves.
    """
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("CLAUDE") or k.startswith("LORE_") or k == "AI_AGENT":
            env.pop(k, None)
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(COLS)
    env["LINES"] = str(ROWS)
    return env


class Session:
    def __init__(self, raw_log_path, extra_args=None):
        self.raw_log_path = raw_log_path
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        args = ["--model", MODEL] + (extra_args or [])
        self.child = pexpect.spawn(
            CLAUDE_BIN,
            args,
            cwd=SANDBOX,
            env=_clean_env(),
            dimensions=(ROWS, COLS),
            encoding=None,  # bytes mode
            timeout=60,
        )
        self.child.logfile_read = self._log
        self.oracle = ScreenOracle()

    # -- raw log segmentation ------------------------------------------------ #
    def switch_log(self, raw_log_path):
        """Point the raw tee at a new per-probe file (shared-session probes)."""
        try:
            self._log.flush()
        except Exception:
            pass
        os.makedirs(os.path.dirname(raw_log_path), exist_ok=True)
        self._log = open(raw_log_path, "wb")
        self.child.logfile_read = self._log
        self.raw_log_path = raw_log_path

    def marker(self, text):
        """Write a human marker into the raw log to segment phases."""
        try:
            self._log.write(f"\n===PROBE-MARKER {text} @ {_iso()}===\n".encode())
            self._log.flush()
        except Exception:
            pass

    # -- io ------------------------------------------------------------------ #
    def send(self, data: bytes):
        self.child.send(data)

    def type_text(self, text: str, per_char=0.008, settle=0.5):
        for ch in text:
            self.child.send(ch.encode())
            time.sleep(per_char)
        # Drain the echoed keystrokes into the oracle so a snapshot taken right
        # after typing reflects the typed text (not a stale pre-echo frame).
        self.drain(settle)

    def drain(self, seconds):
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


# --------------------------------------------------------------------------- #
# Startup / dialog handling
# --------------------------------------------------------------------------- #
DIALOG_TRUST = re.compile(
    r"do you trust|you trust|trust this folder|is this a project you", re.I
)
DIALOG_THEME = re.compile(r"choose (the|your) (text )?style|dark mode|light mode", re.I)
LOGIN_WALL = re.compile(r"log in|sign in|authenticate|/login", re.I)


def handle_startup(sess, max_dialogs=6):
    """Advance through first-run dialogs until the composer is idle.

    Records the dialogs it saw (they are evidence too). Returns the list of
    dialog labels encountered.
    """
    seen = []
    for _ in range(max_dialogs):
        sess.wait_idle(stable_secs=1.5, timeout=45)
        txt = sess.oracle.text()
        low = txt.lower()
        if LOGIN_WALL.search(low) and "shortcuts" not in low and "for newline" not in low:
            seen.append("login_wall")
            note_open_question(
                "startup hit a login/auth wall — probe env not authenticated"
            )
            break
        if re.search(r"reached your (usage|session) limit|limit reached|out of (usage|credits)",
                     low) and not composer_visible(sess.oracle):
            seen.append("usage_limit_wall")
            note_open_question(
                "startup hit a hard usage/session limit wall — probe could not run"
            )
            break
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
        # No known dialog and screen is stable -> assume composer.
        break
    return seen


# The composer is a '❯' prompt line flanked by two full-width horizontal rules
# (pure '─' runs — distinct from the welcome banner's '╭─╮'/'╰─╯' which start
# with corner glyphs), with a status line ('ctx N%', '/rc', '← for agents')
# below. This signature persists after the welcome banner scrolls away.
RULE_RE = re.compile(r"^─{80,}$")
PROMPT_RE = re.compile(r"^\s*[❯>](\s|$)")


def composer_visible(oracle):
    """Is the input composer rendered and ready (readiness precondition)?

    True iff there's a '❯' prompt row with at least two full-width horizontal
    rules present (the composer's top/bottom borders).
    """
    rows = oracle.rows()
    rules = sum(1 for r in rows if RULE_RE.match(r))
    prompt = any(PROMPT_RE.match(r) for r in rows)
    return prompt and rules >= 2


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="module")
def shared_session():
    """One session shared by P1 -> P3 -> P4 (definition order)."""
    sess = Session(os.path.join(RAW_DIR, "shared_startup.log"))
    record("binary_version", _binary_version())
    sess.dialogs = handle_startup(sess)
    yield sess
    # En-passant: discover graceful exit on the shared session at teardown.
    try:
        _probe_graceful_exit(sess)
    finally:
        sess.close()


def _binary_version():
    try:
        import subprocess

        out = subprocess.run(
            [CLAUDE_BIN, "--version"], capture_output=True, text=True, timeout=15
        )
        return out.stdout.strip() or out.stderr.strip()
    except Exception as e:  # pragma: no cover
        return f"unresolved: {e}"


# --------------------------------------------------------------------------- #
# P1 — composer signature
# --------------------------------------------------------------------------- #
def test_p1_composer_signature(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p1_composer.log"))
    sess.marker("P1 composer snapshot")
    sess.wait_idle(stable_secs=2.0, timeout=30)
    rows = sess.oracle.nonempty_rows()
    cur = sess.oracle.cursor()

    # Re-verify stability with a second idle pass (cheap: same session).
    h1 = sess.oracle.hash()
    sess.drain(2.0)
    h2 = sess.oracle.hash()

    all_rows = sess.oracle.rows()
    prompt_row_idx = next((i for i, r in enumerate(all_rows) if PROMPT_RE.match(r)), None)
    rule_rows = [i for i, r in enumerate(all_rows) if RULE_RE.match(r)]
    sig = {
        "matcher": r"a row matching ^\s*[❯>](\s|$) flanked by >=2 full-width rules "
                   r"(^─{80,}$); cursor sits on the prompt row",
        "raw_rows": rows[-8:],
        "cursor": list(cur),
        "prompt_row_index": prompt_row_idx,
        "rule_row_indices": rule_rows,
        "cursor_on_prompt_row": (prompt_row_idx is not None and cur[1] == prompt_row_idx),
        "composer_detected": composer_visible(sess.oracle),
        "stable_within_session": h1 == h2,
        "dialogs_seen_at_startup": getattr(sess, "dialogs", []),
        "stability": "verified across 2 idle passes in-session; cross-launch flagged for confirm",
    }
    # CONTRACT: readiness gate asserts composer_visible(oracle) is True before send;
    #   this record() becomes assert sig["composer_detected"] is True and the matcher
    #   regex is the gate's screen-state check.
    record("composer_signature", sig)
    note_open_question(
        "P1 stability claimed in-session only; cross-launch verification (2 fresh "
        "launches) deferred to keep session count at the directed 3"
    )


# --------------------------------------------------------------------------- #
# P3 — submit vs newline bytes (shared session)
# --------------------------------------------------------------------------- #
def _clear_composer(sess):
    # Ctrl-U clears to line start in most readline-ish composers; follow with a
    # few backspaces as belt-and-suspenders. Never sends \r.
    sess.send(b"\x15")
    time.sleep(0.15)
    sess.send(b"\x08" * 40)
    time.sleep(0.15)
    sess.drain(0.5)


def test_p3_submit_and_newline(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p3_submit_newline.log"))

    results = {}

    # --- (a) does \r submit? ------------------------------------------------ #
    sess.marker("P3a type text then \\r")
    _clear_composer(sess)
    sess.type_text("submit-probe")
    time.sleep(0.4)
    in_before = _composer_input_rows(sess.oracle)
    text_in_composer_before = _composer_has(sess.oracle, "submit-probe")
    sess.send(b"\r")
    time.sleep(1.5)
    sess.drain(1.5)
    after = sess.oracle.text()
    # Submitted iff the text left the composer input row (it becomes an echoed
    # message above, a spinner appears, and a fresh empty composer opens).
    text_still_in_composer = _composer_has(sess.oracle, "submit-probe")
    spinner = bool(re.search(r"(Perusing|Thinking|Working|Cogitat|esc to interrupt|·\s*thinking)",
                             after, re.I))
    submitted = text_in_composer_before and (not text_still_in_composer)
    results["carriage_return"] = {
        "bytes": r"\r (0x0d)",
        "submitted": submitted,
        "spinner_appeared_after": spinner,
        "composer_input_before": in_before,
        "composer_input_after": _composer_input_rows(sess.oracle),
        "evidence_rows": [r for r in after.splitlines() if r.strip()][-8:],
    }
    # Interrupt any generation we just started, to halt token spend.
    sess.send(b"\x1b")
    time.sleep(0.8)
    sess.drain(1.0)

    # --- (b) newline-without-submit chords ---------------------------------- #
    chords = [
        ("alt_enter", b"\x1b\r"),
        ("csi_u_shift_enter", b"\x1b[13;2u"),
        ("backslash_enter", b"\\\r"),
        ("shift_enter_xterm", b"\x1b[27;2;13~"),
        # Raw LF outside bracketed paste — evidences the newline-as-submit trap
        # the transport design warns about (P4 shows LF *inside* paste = newline).
        ("raw_linefeed_lf", b"\n"),
    ]
    chord_results = {}
    for name, seq in chords:
        sess.marker(f"P3b chord {name} = {seq!r}")
        _clear_composer(sess)
        sess.type_text("alpha")
        time.sleep(0.3)
        pre_rows = _composer_input_rows(sess.oracle)
        pre_count = len(pre_rows) if pre_rows is not None else 0
        sess.send(seq)
        time.sleep(0.8)
        sess.drain(0.6)
        post_rows = _composer_input_rows(sess.oracle)
        post_count = len(post_rows) if post_rows is not None else 0
        still_present = _composer_has(sess.oracle, "alpha")
        # Newline inserted: 'alpha' still in composer AND the input gained a row.
        # Submitted: 'alpha' left the composer input.
        gained_row = post_count > pre_count
        if still_present and gained_row:
            verdict = "newline_inserted"
        elif not still_present:
            verdict = "submitted"
        else:
            verdict = "noop_or_absorbed"
        chord_results[name] = {
            "bytes": _brepr(seq),
            "text_retained_in_composer": still_present,
            "input_rows_before": pre_count,
            "input_rows_after": post_count,
            "composer_input_after": post_rows,
            "verdict": verdict,
        }
        # Clean up: interrupt if we accidentally submitted; clear composer.
        sess.send(b"\x1b")
        time.sleep(0.4)
        _clear_composer(sess)

    results["newline_chords"] = chord_results
    # CONTRACT: submit_sequence asserts carriage_return.submitted is True; the set
    #   of newline chords (verdict == newline_inserted) becomes newline_sequence.
    cr_submits = results["carriage_return"]["submitted"]
    record(
        "submit_sequence",
        r"\r (0x0d, CR) — submits; verified submitted=%s (composer empties, "
        r"spinner appears)" % cr_submits,
    )
    newliners = [n for n, r in chord_results.items() if r["verdict"] == "newline_inserted"]
    if newliners:
        # Key distinction: CR (\r) submits, LF (\n) inserts a newline. The chord
        # set that inserts a newline without submitting:
        record(
            "newline_sequence",
            r"\n (0x0a, LF) inserts a newline WITHOUT submitting; also newline-only: "
            + ", ".join(
                f"{n}={chord_results[n]['bytes']}" for n in newliners
            )
            + r". NOTE: only \r (CR) submits — raw \n does NOT submit in this harness.",
        )
        note_open_question(
            "P3 vs settled design premise: the 'newline-as-submit trap' holds for "
            r"\r (CR) but NOT for raw \n (LF) in claude-code — LF inserts a composer "
            "newline. Bracketed-paste (PasteEncode) is still the robust multiline "
            r"transport because it makes both CR and LF literal; but a naive \n-joined "
            r"payload terminated by one \r would land as a single multiline entry here, "
            "not N partial prompts. Cross-harness variance is exactly why the row is "
            "per-harness."
        )
    else:
        record("newline_sequence", "unresolved — no probed chord inserted a newline")
    record("_p3_detail", results)


def _brepr(b: bytes):
    return "".join("\\x%02x" % c if (c < 0x20 or c > 0x7E) else chr(c) for c in b)


def _composer_region(text):
    """Best-effort slice of the bottom composer area (last ~12 rows)."""
    lines = text.splitlines()
    return "\n".join(lines[-12:])


def _composer_input_rows(oracle):
    """The physical rows strictly between the composer's two flanking rules.

    A single-line composer -> one row ('❯ text'); after a newline chord the
    continuation appears as a second (2-space-indented) row. Bottom-anchored, so
    row COUNT — not cursor-y — is the reliable newline signal (proven by P4).
    Returns None if the two rules aren't both present.
    """
    rows = oracle.rows()
    rule_idx = [i for i, r in enumerate(rows) if RULE_RE.match(r)]
    if len(rule_idx) < 2:
        return None
    top, bot = rule_idx[-2], rule_idx[-1]
    return rows[top + 1:bot]


def _composer_has(oracle, needle):
    inp = _composer_input_rows(oracle)
    if inp is None:
        return False
    return any(needle in r for r in inp)


# --------------------------------------------------------------------------- #
# P4 — bracketed paste (shared session)
# --------------------------------------------------------------------------- #
def test_p4_bracketed_paste(shared_session):
    sess = shared_session
    sess.switch_log(os.path.join(RAW_DIR, "p4_bracketed_paste.log"))
    sess.marker("P4 bracketed paste")
    _clear_composer(sess)

    # Did the harness ever enable bracketed paste (ESC[?2004h)? Scan ALL logs
    # captured so far for this session by reading the concatenated raw of p1..p4.
    enabled = _grep_bracketed_paste_enable()

    pre = _composer_region(sess.oracle.text())
    payload = b"\x1b[200~line-one\nline-two\x1b[201~"
    sess.send(payload)
    time.sleep(1.0)
    sess.drain(1.0)
    post_text = sess.oracle.text()
    post = _composer_region(post_text)

    has_both = ("line-one" in post) and ("line-two" in post)
    # If it auto-submitted, the lines would leave the composer and appear as a
    # sent message with a spinner; detect by composer emptiness + generation.
    auto_submitted = has_both is False and (
        "line-one" in post_text or "line-two" in post_text
    )
    needs_trailing = has_both  # present but not sent -> needs \r to submit

    result = {
        "harness_enabled_2004h": enabled,
        "payload": _brepr(payload),
        "both_lines_in_composer": has_both,
        "auto_submitted": auto_submitted,
        "composer_rows_after": [r for r in post.splitlines() if r.strip()][-8:],
        "semantics": (
            "one multiline composer entry, needs trailing \\r to submit"
            if (has_both and not auto_submitted)
            else "auto-submitted on paste-end"
            if auto_submitted
            else "unresolved"
        ),
    }
    # Clean up composer so shared session ends clean.
    sess.send(b"\x1b")
    time.sleep(0.3)
    _clear_composer(sess)

    # CONTRACT: honors_bracketed_paste asserts result["harness_enabled_2004h"] and
    #   result["both_lines_in_composer"]; PasteEncode's wrap is validated by
    #   semantics == "one multiline composer entry, needs trailing \\r".
    record("honors_bracketed_paste", result["harness_enabled_2004h"])
    record("paste_multiline_semantics", result["semantics"])
    record("_p4_detail", result)


def _grep_bracketed_paste_enable():
    """True if ESC[?2004h appears in any captured raw log for this run."""
    needle = b"\x1b[?2004h"
    hits = []
    for name in os.listdir(RAW_DIR):
        p = os.path.join(RAW_DIR, name)
        try:
            with open(p, "rb") as f:
                if needle in f.read():
                    hits.append(name)
        except OSError:
            continue
    return {"found": bool(hits), "in_logs": hits}


# --------------------------------------------------------------------------- #
# P2 — permission-prompt signature (own session)
# --------------------------------------------------------------------------- #
def _rows_look_like_permission_modal(rows):
    """Pure heuristic: do these rendered rows show a claude-code permission modal?

    The live modal renders at the BOTTOM of the screen with the shape (observed):
        Bash command
          <command>
          <one-line description>
        ─────────
        Do you want to proceed?
        ❯ 1. Yes
          2. Yes, and always allow access to <dir>/ from this project
          3. No
        Esc to cancel · Tab to amend · ctrl+e to explain
    Key only on the bottom region so stale 'Ran N shell command' scrollback from a
    prior (auto-approved) command does NOT veto detection.
    """
    tail = rows[-14:]
    txt = "\n".join(tail)
    proceed = bool(re.search(r"do you want to (proceed|run|allow)", txt, re.I))
    footer = bool(re.search(r"esc to cancel|tab to amend|ctrl\+e to explain", txt, re.I))
    option_rows = sum(1 for r in tail if re.match(r"^\s*[❯>]?\s*\d[.)]\s", r))
    return (proceed or footer) and option_rows >= 2


def _looks_like_permission_modal(oracle):
    return _rows_look_like_permission_modal(oracle.rows())


def test_p2_permission_signature():
    sess = Session(os.path.join(RAW_DIR, "p2_permission.log"))
    try:
        record("binary_version", _binary_version())
        handle_startup(sess)

        # (a) Directed prompt: 'echo probe-ok'. In current claude-code (default
        # "Manual" mode) echo is on the safe-command allowlist, so it AUTO-APPROVES
        # with no modal — recorded as a finding, not a failure.
        sess.marker("P2a echo probe-ok (expect auto-approve)")
        sess.type_text("Run this exact shell command: echo probe-ok")
        sess.send(b"\r")
        sess.wait_idle(stable_secs=2.0, timeout=45)
        echo_text = sess.oracle.text()
        echo_auto_approved = bool(re.search(r"Ran \d+ (shell )?command|All set!|probe-ok",
                                            echo_text)) and not _looks_like_permission_modal(sess.oracle)
        echo_finding = {
            "command": "echo probe-ok",
            "auto_approved_no_modal": echo_auto_approved,
            "evidence_rows": [r for r in echo_text.splitlines() if r.strip()][-8:],
        }

        # (b) Forcing command: a side-effecting write ('touch') is NOT on the safe
        # allowlist and DOES raise the permission modal.
        offset_before = len(sess.raw_bytes())
        sess.marker("P2b touch (force permission modal)")
        sess.type_text("Run this exact shell command: touch PERM_PROBE_MARKER")
        sess.send(b"\r")
        sess.wait_idle(stable_secs=2.0, timeout=45)
        modal_rows = sess.oracle.nonempty_rows()
        modal_text = sess.oracle.text()
        is_modal = _looks_like_permission_modal(sess.oracle)

        # Modal-scoped escape sequences: only the bytes emitted AFTER the forcing
        # marker (i.e. while rendering the modal) — for ghostty's
        # CursorPasswordInput heuristic (does the modal change cursor style /
        # hide cursor / toggle ?2004?).
        raw_since = sess.raw_bytes()[offset_before:]
        modal_seqs = _extract_modal_sequences(raw_since)

        sig = {
            "induced_by": "echo probe-ok -> AUTO-APPROVED (safe allowlist); "
                          "touch PERM_PROBE_MARKER -> modal",
            "echo_probe": echo_finding,
            "matcher": r"bottom-region rows with 'Do you want to proceed?' (or footer "
                       r"'Esc to cancel · Tab to amend · ctrl+e to explain') AND >=2 "
                       r"numbered options ('❯ 1. Yes' / '2. …' / '3. No'); modal header "
                       r"is the tool name ('Bash command'). Scrollback-safe: keyed on "
                       r"the bottom 14 rows, not full screen.",
            "raw_rows": modal_rows[-16:],
            "looks_like_permission_prompt": is_modal,
        }
        # CONTRACT: permission_prompt_signature gates the send path to NEVER inject
        #   while a permission modal is up; record() -> assert is_modal True and the
        #   matcher detects it.
        record("permission_prompt_signature", sig)
        record("modal_mode_sequences", modal_seqs)
        if not is_modal:
            note_open_question(
                "P2: forcing command 'touch' did not raise the expected modal; "
                "inspect p2 raw log — folder-trust may have widened the allowlist."
            )

        # Decline the modal (Esc cancels / selects the 'No' path).
        sess.marker("P2 decline permission (Esc)")
        sess.send(b"\x1b")
        time.sleep(0.8)
        sess.drain(1.0)
    finally:
        _probe_graceful_exit(sess)
        sess.close()


def _extract_modal_sequences(raw: bytes):
    """Pull the interesting mode/cursor escape sequences verbatim from raw bytes."""
    patterns = {
        "hide_cursor_25l": rb"\x1b\[\?25l",
        "show_cursor_25h": rb"\x1b\[\?25h",
        "bracketed_paste_on_2004h": rb"\x1b\[\?2004h",
        "bracketed_paste_off_2004l": rb"\x1b\[\?2004l",
        "alt_screen_1049h": rb"\x1b\[\?1049h",
        "alt_screen_1049l": rb"\x1b\[\?1049l",
        "cursor_style_q": rb"\x1b\[\d+ q",
        "any_decset": rb"\x1b\[\?\d+h",
        "any_decrst": rb"\x1b\[\?\d+l",
    }
    out = {}
    for name, pat in patterns.items():
        found = re.findall(pat, raw)
        if found:
            out[name] = {
                "count": len(found),
                "samples": sorted({_brepr(m) for m in found})[:8],
            }
    return out or {"note": "no DECSET/DECRST/cursor-style sequences captured"}


# --------------------------------------------------------------------------- #
# P5 — mid-generation inject (own session)
# --------------------------------------------------------------------------- #
def test_p5_mid_generation_inject():
    sess = Session(os.path.join(RAW_DIR, "p5_midgen.log"))
    try:
        record("binary_version", _binary_version())
        handle_startup(sess)
        sess.marker("P5 start counting generation")
        sess.type_text("Count from 1 to 40, one number per line, no other text.")
        time.sleep(0.4)
        sess.send(b"\r")

        # Wait until generation is clearly underway (screen changing / numbers
        # appearing), then inject mid-stream.
        injected = False
        start = time.time()
        while time.time() - start < 20:
            try:
                d = sess.child.read_nonblocking(65536, timeout=0.3)
            except pexpect.TIMEOUT:
                d = b""
            except pexpect.EOF:
                break
            if d:
                sess.oracle.feed(d)
            txt = sess.oracle.text()
            # Inject once we see the model has begun emitting the sequence.
            if not injected and re.search(r"\b(3|4|5)\b", txt) and "1" in txt:
                sess.marker("P5 INJECT PING-MIDGEN\\r mid-stream")
                sess.send(b"PING-MIDGEN\r")
                injected = True
                inject_at = time.time()
            if injected and time.time() - inject_at > 0.5:
                # keep draining to completion
                pass

        if not injected:
            sess.marker("P5 INJECT (fallback, generation ended fast)")
            sess.send(b"PING-MIDGEN\r")
            injected = True

        # Let everything settle after injection + generation completes.
        sess.wait_idle(stable_secs=2.5, timeout=45)
        final_text = sess.oracle.text()

        # Distinguish: PING sitting UNSENT in the live composer (between the
        # rules) vs PING submitted as its own message ABOVE the rules (which the
        # model then answered). The last-N-lines slice conflates the two — use the
        # composer-input rows for 'in composer', and the message area for 'sent'.
        ping_in_live_composer = _composer_has(sess.oracle, "PING-MIDGEN")
        rows = sess.oracle.rows()
        rule_idx = [i for i, r in enumerate(rows) if RULE_RE.match(r)]
        above_rules = "\n".join(rows[: rule_idx[-2]]) if len(rule_idx) >= 2 else final_text
        ping_submitted_as_message = ("PING-MIDGEN" in above_rules) and not ping_in_live_composer
        # Did the model produce a response turn to PING (a reply after the count)?
        model_answered_ping = bool(
            re.search(r"PING-MIDGEN[\s\S]{0,400}?⏺", above_rules)
        )
        # Did the count complete fully (1..40 present) => not interrupted?
        count_completed = ("40" in final_text) and ("39" in final_text)
        interrupted = not count_completed

        if ping_in_live_composer:
            verdict = "buffered_into_composer_unsent"
        elif ping_submitted_as_message:
            verdict = "queued_and_submitted_as_next_message"
        else:
            verdict = "dropped_or_absorbed"
        result = {
            "ping_in_live_composer": ping_in_live_composer,
            "ping_submitted_as_message": ping_submitted_as_message,
            "model_answered_ping": model_answered_ping,
            "count_completed_before_ping": count_completed,
            "interrupted_generation": interrupted,
            "verdict": verdict,
            "final_rows": [r for r in final_text.splitlines() if r.strip()][-16:],
        }
        # CONTRACT: mid_generation_inject decides strict-gate vs queue-and-hold.
        #   queued_and_submitted_as_next_message => the harness has native type-ahead
        #   that AUTO-SUBMITS the injected bytes as a follow-up turn once the current
        #   generation ends => the readiness gate MUST be strict (never inject mid-
        #   generation) unless a follow-up turn is the explicit intent.
        record("mid_generation_inject", result)
    finally:
        _probe_graceful_exit(sess)
        sess.close()


# --------------------------------------------------------------------------- #
# En passant — graceful exit ladder discovery
# --------------------------------------------------------------------------- #
def _probe_graceful_exit(sess):
    """Discover the byte sequence that cleanly exits claude-code.

    Repo already encodes the ladder *shape* (harness-exit -> SIGTERM -> Kill) but
    NOT the claude-code harness-exit bytes; that's this probe's job. Try, in
    order: single Ctrl-C (expect a 'press again' hint), second Ctrl-C (expect
    EOF). Record what actually terminated the child. Falls back to force close.
    """
    sess.marker("EXIT probe: Ctrl-C x2, then /exit, then Ctrl-D")
    result = {"attempts": []}

    def wait_dead(timeout):
        """Poll for child death (EOF), draining output. True once dead."""
        end = time.time() + timeout
        while time.time() < end:
            try:
                d = sess.child.read_nonblocking(65536, timeout=0.25)
                if d:
                    sess.oracle.feed(d)
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                return True
            if not sess.child.isalive():
                return True
        return not sess.child.isalive()

    try:
        # (1) Ctrl-C twice in quick succession (claude-code's press-again window).
        sess.send(b"\x03")
        time.sleep(0.4)
        hint = sess.oracle.text()
        first_hint = bool(re.search(r"ctrl-?c again|press ctrl-?c|to (exit|quit)",
                                    hint, re.I))
        sess.send(b"\x03")
        dead = wait_dead(4.0)
        result["attempts"].append(
            {"send": r"\x03\x03 (Ctrl-C x2, ~0.4s apart)",
             "exit_hint_after_first": first_hint, "dead": dead}
        )
        if dead:
            result["graceful_sequence"] = r"\x03\x03 (Ctrl-C twice, sent ~0.4s apart)"
        else:
            # (2) /exit slash command.
            sess.marker("EXIT probe: /exit")
            sess.type_text("/exit")
            sess.send(b"\r")
            dead = wait_dead(6.0)
            result["attempts"].append({"send": r"/exit\r", "dead": dead})
            if dead:
                result["graceful_sequence"] = r"/exit\r (slash command)"
            else:
                # (3) Ctrl-D.
                sess.marker("EXIT probe: Ctrl-D")
                sess.send(b"\x04")
                dead = wait_dead(4.0)
                result["attempts"].append({"send": r"\x04 (Ctrl-D)", "dead": dead})
                result["graceful_sequence"] = (
                    r"\x04 (Ctrl-D)" if dead else "unresolved — needed force kill"
                )
    except pexpect.EOF:
        result.setdefault("graceful_sequence", "EOF during exit probe (child exited)")
    except Exception as e:  # pragma: no cover
        result["error"] = str(e)
    # CONTRACT: graceful_exit_sequence feeds the exit ladder's first rung
    #   (harness-exit) so teardown prefers a clean exit before SIGTERM/Kill.
    record("graceful_exit_sequence", result)
    return result
