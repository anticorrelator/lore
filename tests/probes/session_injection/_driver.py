"""Shared driver for the session-injection contract suite.

This module is the single home for the machinery the three per-harness probe
modules (probe_claude_code.py, probe_codex.py, probe_opencode.py) deliberately
duplicated during the record-mode exploration pass: the pyte screen oracle, the
idle/drain PTY pump helpers, the pure-function screen-state matchers, the
bracketed-paste encode/refuse helpers, and the loader that reads the pinned
interaction contract out of adapters/capabilities.json.

Two consumer classes:

- The live probes (LORE_LIVE_PROBES=1) spawn real harness sessions, drive them,
  and assert live behavior matches the capability row. They need pyte + pexpect.
- The always-on pure-function tests (test_matchers.py, test_encode.py) exercise
  the matchers against the recorded raw rows and the encode helpers against
  generated payloads. They need only the stdlib.

So pyte/pexpect are imported lazily: importing this module never requires them;
only instantiating ScreenOracle / spawning a session does. That keeps the pure
tests runnable in a minimal environment.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime, timezone

try:  # live-probe deps only; pure tests must import this module without them
    import pyte
except ImportError:  # pragma: no cover - env without pyte
    pyte = None
try:
    import pexpect
except ImportError:  # pragma: no cover - env without pexpect
    pexpect = None

HERE = os.path.dirname(os.path.abspath(__file__))
OBS_DIR = os.path.join(HERE, "observations")
# tests/probes/session_injection -> repo root is three levels up.
CAPABILITIES = os.path.abspath(
    os.path.join(HERE, "..", "..", "..", "adapters", "capabilities.json")
)

COLS, ROWS = 120, 40


# --------------------------------------------------------------------------- #
# Pinned interaction contract (adapters/capabilities.json). Read dynamically so
# a harness UI change fails the live contract test instead of drifting from a
# hard-coded literal.
# --------------------------------------------------------------------------- #
def load_capabilities():
    with open(CAPABILITIES) as f:
        return json.load(f)


def interaction_row(framework, name):
    """Return one interaction row dict for a framework, or raise KeyError."""
    return load_capabilities()["frameworks"][framework]["interaction"][name]


def sequence_bytes(framework, name):
    """The literal PTY bytes for a sequence row (submit/newline/graceful_exit)."""
    seq = interaction_row(framework, name)["sequence"]
    return seq.encode("latin-1")


def load_observation(harness):
    """Load the recorded observation JSON for a harness (evidence, not contract)."""
    with open(os.path.join(OBS_DIR, f"{harness}.json")) as f:
        return json.load(f)


# --------------------------------------------------------------------------- #
# Bracketed-paste encode / refuse helpers. The injection transport wraps a body
# in ESC[200~ .. ESC[201~ so embedded CR/LF are literal (not submits). A body
# that itself contains a bracketed-paste marker is unsafe: an embedded ESC[201~
# would terminate the paste early and the remainder would arrive as live
# keystrokes (a smuggling vector). PasteIsSafe is the gate; PasteEncode refuses
# an unsafe body rather than silently sanitizing — the caller decides.
# --------------------------------------------------------------------------- #
PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"


def paste_is_safe(body: bytes) -> bool:
    """True iff body embeds neither bracketed-paste marker."""
    if not isinstance(body, (bytes, bytearray)):
        raise TypeError("paste body must be bytes")
    return PASTE_START not in body and PASTE_END not in body


class UnsafePaste(ValueError):
    """Raised when PasteEncode is asked to wrap a body that embeds a marker."""


def paste_encode(body: bytes) -> bytes:
    """Wrap body in bracketed-paste markers; refuse an unsafe body."""
    if not paste_is_safe(body):
        raise UnsafePaste("paste body embeds a bracketed-paste marker (200~/201~)")
    return PASTE_START + bytes(body) + PASTE_END


def paste_decode(wrapped: bytes) -> bytes:
    """Inverse of paste_encode for a well-formed wrap; raises on a malformed one."""
    if not (wrapped.startswith(PASTE_START) and wrapped.endswith(PASTE_END)):
        raise ValueError("not a bracketed-paste wrap")
    return wrapped[len(PASTE_START):-len(PASTE_END)]


# --------------------------------------------------------------------------- #
# Pure-function screen-state matchers. Each returns True/False over a list of
# row strings. They tolerate rows that carry a leading "<idx>|" render prefix
# (opencode's recorded format) because they key on substrings/regex search, not
# absolute-anchored line matching — so the same function serves the live oracle
# rows and the recorded raw rows. These are the matchers the readiness gate's
# screen-state check implements; capabilities.json carries their human-readable
# description under interaction.<row>.matcher.
#
# NBSP tolerance is load-bearing and implicit here: these patterns use \s, and
# Python's re \s matches Unicode whitespace (incl. U+00A0 NBSP, U+2007, U+202F).
# claude-code renders its idle prompt with a NBSP after the glyph ('❯\xa0<text>'),
# so \s covers it for free. A port to an engine whose \s is ASCII-only (Go's
# regexp is [\t\n\f\r ]) MUST normalize Unicode spaces to ASCII before matching,
# or it will miss a real idle composer — see gateRows in tui/gate.go.
# --------------------------------------------------------------------------- #

# claude-code: a '❯' prompt row flanked by two full-width '─' rules.
_CC_RULE = re.compile(r"─{80,}")
_CC_PROMPT = re.compile(r"^\s*[❯>](\s|$)")


def claude_code_composer_ready(rows):
    # The permission modal renders in-band inside the composer chrome, so its
    # option rows ("❯ 1. Yes") and the box rules can satisfy the structural
    # anchors; "ready" means visible AND unobstructed — negate the modal.
    if claude_code_permission_modal(rows):
        return False
    rules = sum(1 for r in rows if _CC_RULE.search(r))
    prompt = any(_CC_PROMPT.match(r) for r in rows)
    return prompt and rules >= 2


def claude_code_permission_modal(rows):
    tail = rows[-14:]
    txt = "\n".join(tail)
    proceed = bool(re.search(r"do you want to (proceed|run|allow)", txt, re.I))
    footer = bool(re.search(r"esc to cancel|tab to amend|ctrl\+e to explain", txt, re.I))
    options = sum(1 for r in tail if re.search(r"[❯>]?\s*\d[.)]\s", r))
    return (proceed or footer) and options >= 2


# codex: footer status line "<model> <effort> · <cwd>" + a '›' input row.
_CX_FOOTER = re.compile(r"(minimal|low|medium|high|xhigh)\s+·\s")
_CX_GLYPH = "›"
_CX_MODAL_ANCHOR = re.compile(
    r"would you like to run|press enter to confirm or esc|"
    r"enter\s+to\s+(?:confirm|select)|select.*enter|use.*(?:↑|↓).*enter|"
    r"up/down|arrow keys",
    re.I,
)
_NUMBERED_OPTION = re.compile(r"^\s*([❯›>])?\s*(\d+)[.)]\s+\S")


def codex_composer_ready(rows):
    # "Ready" means visible AND unobstructed; the approval modal usually drops
    # the footer status row, but negate it explicitly for partial repaints.
    if codex_permission_modal(rows):
        return False
    footer_idx = next((i for i, r in enumerate(rows) if _CX_FOOTER.search(r)), None)
    if footer_idx is None:
        return False
    for i in range(footer_idx, -1, -1):
        if rows[i].lstrip().startswith(_CX_GLYPH):
            return True
    return False


def codex_permission_modal(rows):
    selected, available = codex_modal_options(rows)
    return selected is not None and len(available) >= 2


def codex_modal_options(rows):
    """Return (selected displayed number, available numbers in row order)."""
    tail = rows[-18:]
    text = "\n".join(tail)
    if _CX_FOOTER.search(text) or not _CX_MODAL_ANCHOR.search(text):
        return (None, [])
    selected = None
    selected_count = 0
    available = []
    for row in tail:
        match = _NUMBERED_OPTION.match(row)
        if not match:
            continue
        option = int(match.group(2))
        if option not in available:
            available.append(option)
        if match.group(1):
            selected_count += 1
            selected = option
    if selected_count != 1 or len(available) < 2:
        return (None, [])
    return (selected, available)


# opencode: '╹▀+' bottom border + a 'commands' key-hint + the '┃' left border.
_OC_BOTTOM = re.compile(r"╹▀{5,}")
_OC_ACTIONS = re.compile(r"Allow once\s+Allow always\s+Reject")


def opencode_composer_ready(rows):
    # The permission modal renders in-band inside the composer box, so the
    # border/hint anchors stay on screen; "ready" means visible AND
    # unobstructed — negate the modal.
    if opencode_permission_modal(rows):
        return False
    bottom = any(_OC_BOTTOM.search(r) for r in rows)
    hint = any("commands" in r for r in rows)
    left = any("┃" in r for r in rows)
    return bottom and hint and left


def opencode_permission_modal(rows):
    perm = any("Permission required" in r for r in rows)
    action = any(_OC_ACTIONS.search(r) for r in rows)
    return perm and action


MATCHERS = {
    "claude-code": {
        "composer": claude_code_composer_ready,
        "permission": claude_code_permission_modal,
    },
    "codex": {
        "composer": codex_composer_ready,
        "permission": codex_permission_modal,
    },
    "opencode": {
        "composer": opencode_composer_ready,
        "permission": opencode_permission_modal,
    },
}


# --------------------------------------------------------------------------- #
# Screen oracle: pyte Screen fed from the raw PTY byte stream. Live-probe only.
# --------------------------------------------------------------------------- #
class ScreenOracle:
    def __init__(self, cols=COLS, rows=ROWS):
        if pyte is None:  # pragma: no cover - env without pyte
            raise RuntimeError("pyte is required for live probes (ScreenOracle)")
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
# Shared PTY pump helpers. Live-probe only. Operate on a pexpect child + oracle.
# --------------------------------------------------------------------------- #
def require_live_deps():
    if pyte is None or pexpect is None:  # pragma: no cover
        raise RuntimeError("live probes require pyte and pexpect")


def drain(child, oracle, seconds):
    """Feed the screen for a fixed window. Returns False on EOF."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            d = child.read_nonblocking(65536, timeout=0.2)
        except pexpect.TIMEOUT:
            d = b""
        except pexpect.EOF:
            return False
        if d:
            oracle.feed(d)
    return True


def wait_idle(child, oracle, stable_secs=2.0, timeout=45.0, poll=0.3):
    """Return True once the rendered screen is unchanged for stable_secs."""
    start = time.time()
    last_change = time.time()
    last_hash = oracle.hash()
    while time.time() - start < timeout:
        try:
            d = child.read_nonblocking(65536, timeout=poll)
        except pexpect.TIMEOUT:
            d = b""
        except pexpect.EOF:
            return False
        if d:
            oracle.feed(d)
            h = oracle.hash()
            if h != last_hash:
                last_hash = h
                last_change = time.time()
        if time.time() - last_change >= stable_secs:
            return True
    return False


# --------------------------------------------------------------------------- #
# tmux hosting tier. Live-probe only. Production hosts a harness under a detached
# session on a dedicated `-L lore-tui -f /dev/null` server and drives it through
# an `attach-session` client running under the PTY — the PTY master stays the one
# read/write seam, so the emulator/gate/injection stack never learns tmux exists.
# TmuxHost reproduces that topology here: it creates the pinned session and hands
# back a pexpect attach client the per-harness probes drive exactly like a
# direct-PTY child.
#
# Each option pin removes one contract hazard, applied on the isolated server so
# the re-verified contract is the contract production runs:
#   prefix/prefix2 none   a C-b byte in a payload or keystroke reaches the harness
#   status off            no synthetic status row to break bottom-anchored matchers
#   remain-on-exit off  + pane death -> session death -> attach-client EOF (the
#   exit-empty on         existing StreamComplete teardown fires unchanged)
#   escape-time 0         a lone ESC (opencode's ESC-CR newline) isn't held as a
#                         meta prefix
#   window-size latest    the sole attached client dictates dimensions so resize
#                         forwarding keeps working
# --------------------------------------------------------------------------- #
TMUX_SOCKET = "lore-tui"


def tmux_available():
    return shutil.which("tmux") is not None


def tmux_version():
    try:
        return subprocess.run(["tmux", "-V"], capture_output=True, text=True).stdout.strip()
    except OSError:  # pragma: no cover
        return "unknown"


def tmux_session_name(prefix):
    return f"lore-{prefix}-{uuid.uuid4().hex[:8]}"


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class TmuxHost:
    """Host `argv` under a pinned detached tmux session; expose the attach client.

    `child` is a pexpect attach-session client whose PTY master is the same
    byte-stream seam the direct-PTY probes drive. When `pane_side_path` is given,
    `pipe-pane` tees the harness's raw pane output there — the un-re-encoded
    stream that answers "does the harness itself advertise ESC[?2004h under tmux",
    which is distinct from what the (tmux-mediated) attach client observes: tmux
    advertises bracketed paste to any capable attach client regardless of the pane.
    """

    def __init__(self, name, argv, env, cols=COLS, rows=ROWS, cwd=None,
                 socket=TMUX_SOCKET, history_limit=2000, timeout=60,
                 pane_side_path=None):
        require_live_deps()
        if not tmux_available():
            raise RuntimeError("tmux tier requires tmux on PATH")
        self.name = name
        self.pane_side_path = pane_side_path
        self._base = ["tmux", "-L", socket, "-f", "/dev/null"]
        create = self._base + ["new-session", "-d", "-s", name,
                               "-x", str(cols), "-y", str(rows)]
        if cwd:
            create += ["-c", cwd]
        create += ["--", *argv]
        subprocess.run(create, env=env, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if pane_side_path:
            os.makedirs(os.path.dirname(pane_side_path), exist_ok=True)
            open(pane_side_path, "wb").close()
            # Tap first (before option pins and attach) so the harness's startup
            # mode setup — including any 2004h — lands in the pane-side capture.
            self._tmux(["pipe-pane", "-o", "-t", name, f"cat >> {pane_side_path}"])
        self._pin_options(history_limit)
        self.child = pexpect.spawn(
            self._base[0], self._base[1:] + ["attach-session", "-t", name],
            env=env, dimensions=(rows, cols), encoding=None, timeout=timeout,
        )

    def _tmux(self, args):
        return subprocess.run(self._base + args, check=False,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def _pin_options(self, history_limit):
        for opt in (["set", "-s", "escape-time", "0"],
                    ["set", "-s", "exit-empty", "on"],
                    ["set", "-t", self.name, "prefix", "none"],
                    ["set", "-t", self.name, "prefix2", "none"],
                    ["set", "-t", self.name, "status", "off"],
                    ["set", "-t", self.name, "history-limit", str(history_limit)],
                    ["setw", "-t", self.name, "remain-on-exit", "off"],
                    ["setw", "-t", self.name, "window-size", "latest"]):
            self._tmux(opt)

    def pane_pid(self):
        return self._tmux(
            ["display-message", "-p", "-t", self.name, "#{pane_pid}"]
        ).stdout.decode().strip()

    def pane_side_bytes(self):
        if not self.pane_side_path or not os.path.exists(self.pane_side_path):
            return b""
        with open(self.pane_side_path, "rb") as f:
            return f.read()

    def kill(self):
        self._tmux(["kill-session", "-t", self.name])


def decset_observation(harness, client_2004h, pane_2004h):
    """Both DECSET-2004 readouts plus their interpretation, for the tmux tier.

    pane_2004h (pipe-pane, un-re-encoded) is the faithful harness advertisement,
    comparable to honors_bracketed_paste. client_2004h (attach stream) is what a
    production emulator would see, but tmux advertises bracketed paste to any
    capable attach client regardless of the pane, so it is tmux-mediated.
    """
    row_val = interaction_row(harness, "honors_bracketed_paste")["value"]
    return {
        "harness_advertises_2004h_pane_side": pane_2004h,
        "client_observes_2004h": client_2004h,
        "capability_row_value": row_val,
        "pane_side_matches_capability_row": pane_2004h == row_val,
        "divergence_from_direct_tier": pane_2004h != row_val,
        "note": "client-side 2004h is tmux-mediated (tmux advertises to any capable "
                "client regardless of the pane); pane-side (pipe-pane) is the faithful "
                "harness signal. A harness that defers bracketed paste to tmux emits no "
                "pane-side 2004h even when its direct-PTY row is True.",
    }


def record_tmux_observation(harness, section, payload):
    """Merge one section into observations/<harness>.tmux.json (evidence, not contract)."""
    path = os.path.join(OBS_DIR, f"{harness}.tmux.json")
    doc = {}
    if os.path.exists(path):
        with open(path) as f:
            try:
                doc = json.load(f)
            except ValueError:
                doc = {}
    doc["harness"] = harness
    doc["tier"] = "tmux-attach-client"
    doc["tty_size"] = f"{COLS}x{ROWS}"
    doc["tmux_version"] = tmux_version()
    doc["probed_at"] = _now_iso()
    doc[section] = payload
    with open(path, "w") as f:
        json.dump(doc, f, indent=2)
    return path
