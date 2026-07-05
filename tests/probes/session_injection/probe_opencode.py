"""Live PTY probe suite: opencode harness.

Part of the `lore session send` readiness-gate investigation. These probes drive a
REAL `opencode` TUI session over a pexpect-owned PTY, feed the raw byte stream
through a pyte screen oracle, and RECORD observed interaction behavior into a draft
capability row (observations/opencode.json) plus per-probe raw byte logs.

This is an exploration pass. Each probe *records* what it sees rather than asserting,
and every `record(...)` call is annotated with a `# CONTRACT:` comment naming the
readiness-gate / send contract assertion it converts into during the implementation
phase. The fixtures (spawn + screen oracle + idle-wait) are built to survive that
conversion unchanged — only the record() calls flip to assertions.

Run with:
    LORE_LIVE_PROBES=1 python3 -m pytest tests/probes/session_injection/probe_opencode.py -s -v

Optional env:
    PROBE_MODEL     provider/model for --model (default openai/gpt-4o-mini)
    PROBE_SANDBOX   pre-made throwaway git dir to launch in (default: fresh mkdtemp)

Deps: pexpect (4.8.0), pyte. Both verified importable via python3.
"""

import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import time

import pexpect
import pyte
import pytest

# --------------------------------------------------------------------------- #
# Module gate — live probes cost real harness sessions (real tokens).
# --------------------------------------------------------------------------- #
pytestmark = pytest.mark.skipif(
    os.environ.get("LORE_LIVE_PROBES") != "1",
    reason="live probes cost real harness sessions; set LORE_LIVE_PROBES=1 to run",
)

HERE = pathlib.Path(__file__).resolve().parent
OBS_DIR = HERE / "observations"
RAW_DIR = OBS_DIR / "raw" / "opencode"
OBS_FILE = OBS_DIR / "opencode.json"

MODEL = os.environ.get("PROBE_MODEL", "openai/gpt-4o-mini")
COLS, ROWS = 120, 40
TTY_SIZE = f"{COLS}x{ROWS}"


# --------------------------------------------------------------------------- #
# Sandbox — NEVER launch the harness inside the lore repo. Default to a fresh
# throwaway git repo so the probe is self-contained and portable.
# --------------------------------------------------------------------------- #
def _ensure_sandbox() -> str:
    env_dir = os.environ.get("PROBE_SANDBOX")
    if env_dir and pathlib.Path(env_dir).is_dir():
        return env_dir
    d = tempfile.mkdtemp(prefix="opencode-probe-")
    subprocess.run(["git", "init", "-q"], cwd=d, check=False)
    (pathlib.Path(d) / "README.md").write_text("# opencode probe sandbox\n")
    subprocess.run(["git", "add", "-A"], cwd=d, check=False)
    subprocess.run(
        ["git", "-c", "user.email=probe@local", "-c", "user.name=probe",
         "commit", "-qm", "probe sandbox"],
        cwd=d, check=False,
    )
    return d


_SANDBOX_CACHE = None


def sandbox() -> str:
    """Lazily create/reuse the throwaway launch dir. Kept out of module import so
    plain pytest collection (LORE_LIVE_PROBES unset) has no filesystem side effects."""
    global _SANDBOX_CACHE
    if _SANDBOX_CACHE is None:
        _SANDBOX_CACHE = _ensure_sandbox()
    return _SANDBOX_CACHE


# --------------------------------------------------------------------------- #
# Screen oracle — pyte.Screen fed by a ByteStream, with a raw-byte tee to disk.
# The raw log is the ground-truth evidence; the pyte display is the decoded view
# the readiness gate will inspect (VT screen-state check).
# --------------------------------------------------------------------------- #
class ScreenOracle:
    def __init__(self, cols: int, rows: int, raw_path: pathlib.Path):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        raw_path.parent.mkdir(parents=True, exist_ok=True)
        self._raw = open(raw_path, "wb")
        self.raw_path = raw_path

    def feed(self, data: bytes) -> None:
        self._raw.write(data)
        self._raw.flush()
        self.stream.feed(data)

    def rows(self) -> list[str]:
        return [line.rstrip() for line in self.screen.display]

    def nonblank(self) -> list[tuple[int, str]]:
        return [(i, r) for i, r in enumerate(self.rows()) if r.strip()]

    def text(self) -> str:
        return "\n".join(self.rows())

    def cursor(self) -> tuple[int, int]:
        return (self.screen.cursor.x, self.screen.cursor.y)

    def raw_bytes(self) -> bytes:
        self._raw.flush()
        return self.raw_path.read_bytes()

    def close(self) -> None:
        try:
            self._raw.close()
        except Exception:
            pass


# --------------------------------------------------------------------------- #
# Spawn + pump helpers.
# --------------------------------------------------------------------------- #
def spawn_session(raw_path: pathlib.Path, launch_dir: str = None):
    """Spawn an opencode TUI over a PTY. Returns (child, oracle)."""
    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    child = pexpect.spawn(
        "opencode",
        ["--model", MODEL, launch_dir or sandbox()],
        dimensions=(ROWS, COLS),
        env=env,
        encoding=None,  # raw bytes — identical byte-level fidelity to a human PTY
        timeout=60,
    )
    oracle = ScreenOracle(COLS, ROWS, raw_path)
    return child, oracle


def make_permission_sandbox(bash_mode: str = "ask") -> str:
    """A throwaway git dir carrying an opencode.json that forces a bash permission
    decision. Default opencode config AUTO-RUNS bash (no modal); setting
    permission.bash induces the Permission-required modal used by P2."""
    d = tempfile.mkdtemp(prefix="opencode-perm-")
    subprocess.run(["git", "init", "-q"], cwd=d, check=False)
    (pathlib.Path(d) / "README.md").write_text("# opencode permission probe\n")
    (pathlib.Path(d) / "opencode.json").write_text(json.dumps({
        "$schema": "https://opencode.ai/config.json",
        "permission": {"bash": bash_mode},
    }, indent=2))
    subprocess.run(["git", "add", "-A"], cwd=d, check=False)
    subprocess.run(
        ["git", "-c", "user.email=probe@local", "-c", "user.name=probe",
         "commit", "-qm", "perm sandbox"],
        cwd=d, check=False,
    )
    return d


def pump(child, oracle, duration: float) -> bool:
    """Read for a fixed wall-clock duration. False on EOF."""
    end = time.time() + duration
    while time.time() < end:
        try:
            data = child.read_nonblocking(size=4096, timeout=0.2)
        except pexpect.TIMEOUT:
            continue
        except pexpect.EOF:
            return False
        if data:
            oracle.feed(data)
    return True


def wait_idle(child, oracle, stable_secs: float = 1.5, max_wait: float = 30.0) -> bool:
    """Poll the byte stream until quiescent: no new bytes for `stable_secs`.

    This is the quiescence half of the readiness gate — the send path must not
    inject while the harness is still painting. Returns True if quiescence was
    reached, False on EOF.
    """
    deadline = time.time() + max_wait
    last_data = time.time()
    while time.time() < deadline:
        try:
            data = child.read_nonblocking(size=4096, timeout=0.2)
        except pexpect.TIMEOUT:
            if time.time() - last_data >= stable_secs:
                return True
            continue
        except pexpect.EOF:
            return False
        if data:
            oracle.feed(data)
            last_data = time.time()
    return (time.time() - last_data) >= stable_secs


def dismiss_update_modal(child, oracle, poll_secs: float = 10.0) -> bool:
    """opencode shows an 'Update Available' modal on launch when a newer release
    exists. It arrives ASYNCHRONOUSLY (~6s after launch, after the background
    update check resolves), overlays the composer, and is dismissed cleanly with
    ESC (verified: modal leaves screen, composer placeholder returns, input then
    reaches the composer). Poll for it up to `poll_secs`, dismiss, and confirm.

    This overlay is environment-dependent (only shown when a newer release exists),
    so it is NOT part of the stable composer signature — it is a transient launch
    distractor the readiness gate must treat as NOT-composer-ready until cleared.
    Returns True if a modal was seen and dismissed."""
    deadline = time.time() + poll_secs
    while time.time() < deadline:
        if "Update Available" in oracle.text():
            child.send(b"\x1b")  # ESC
            wait_idle(child, oracle, stable_secs=1.0, max_wait=6)
            return "Update Available" not in oracle.text()
        pump(child, oracle, 0.5)
    return False


def graceful_exit(child, oracle) -> str:
    """En-passant probe: discover the sequence that cleanly exits the TUI.
    Returns a label describing what worked."""
    if not child.isalive():
        return "already-dead"
    child.send(b"\x03")  # ctrl-c
    wait_idle(child, oracle, stable_secs=1.0, max_wait=4)
    if not child.isalive():
        return "single-ctrl-c"
    child.send(b"\x03")  # ctrl-c again
    wait_idle(child, oracle, stable_secs=1.0, max_wait=4)
    if not child.isalive():
        return "double-ctrl-c"
    child.terminate(force=True)
    return "forced-terminate"


# --------------------------------------------------------------------------- #
# Observation recording — writes the draft capability row incrementally.
# One writer per harness file; sibling researchers write claude/codex files.
# --------------------------------------------------------------------------- #
def _seed_metadata() -> None:
    OBS_DIR.mkdir(parents=True, exist_ok=True)
    data = _load()
    try:
        ver = subprocess.run(
            ["opencode", "--version"], capture_output=True, text=True, timeout=15
        ).stdout.strip()
    except Exception:
        ver = "unresolved"
    data.setdefault("harness", "opencode")
    data["probed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    data["binary_version"] = ver
    data["model_used"] = MODEL
    data["tty_size"] = TTY_SIZE
    data.setdefault("open_questions", [])
    _store(data)


def _load() -> dict:
    if OBS_FILE.exists():
        try:
            return json.loads(OBS_FILE.read_text())
        except ValueError:
            return {}
    return {}


def _store(data: dict) -> None:
    OBS_DIR.mkdir(parents=True, exist_ok=True)
    OBS_FILE.write_text(json.dumps(data, indent=2) + "\n")


def record(key: str, value) -> None:
    data = _load()
    data[key] = value
    _store(data)


def add_open_question(q: str) -> None:
    data = _load()
    qs = data.setdefault("open_questions", [])
    if q not in qs:
        qs.append(q)
    _store(data)


# --------------------------------------------------------------------------- #
# DEC/CSI mode-sequence scanner — used to capture modal_mode_sequences verbatim.
# --------------------------------------------------------------------------- #
MODE_MARKERS = {
    rb"\x1b\[\?2004h": "bracketed-paste ENABLE",
    rb"\x1b\[\?2004l": "bracketed-paste DISABLE",
    rb"\x1b\[\?25h": "cursor SHOW",
    rb"\x1b\[\?25l": "cursor HIDE",
    rb"\x1b\[\?1049h": "alt-screen ENTER",
    rb"\x1b\[\?1049l": "alt-screen LEAVE",
    rb"\x1b\[\?2026h": "sync-update BEGIN",
    rb"\x1b\[\?2026l": "sync-update END",
    rb"\x1b\[[0-9]* q": "cursor-style (DECSCUSR)",
    rb"\x1b\[\?1000h": "mouse X10",
    rb"\x1b\[\?1002h": "mouse btn-event",
    rb"\x1b\[\?1003h": "mouse any-event",
    rb"\x1b\[\?1006h": "mouse SGR",
}


def _strip_ansi(raw: bytes) -> str:
    """Decode raw PTY bytes to plain text with CSI/OSC/ESC control sequences removed
    — for keyword scanning of on-screen affordances (e.g. the 'QUEUED' badge)."""
    t = re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", raw)
    t = re.sub(rb"\x1b\][^\x07]*\x07", b"", t)
    t = t.replace(b"\x1b", b"")
    return t.decode("utf-8", "replace")


def scan_mode_sequences(raw: bytes) -> dict:
    """Return {label: count} for DEC/CSI mode toggles present in raw bytes."""
    out = {}
    for pat, label in MODE_MARKERS.items():
        n = len(re.findall(pat, raw))
        if n:
            out[label] = n
    return out


def _seed_once():
    if not getattr(_seed_once, "done", False):
        _seed_metadata()
        _seed_once.done = True


# =========================================================================== #
# P1 — composer signature
# =========================================================================== #
def test_p1_composer_signature():
    """Identify a STABLE 'composer visible and ready' signature, verified across
    two launches. Records raw composer rows, cursor position, a proposed matcher,
    and the startup mode sequences."""
    _seed_once()
    launches = []
    mode_seqs = None
    modal_dismissed = []
    for n in (1, 2):
        raw_path = RAW_DIR / f"p1_composer_launch{n}.raw"
        child, oracle = spawn_session(raw_path)
        try:
            pump(child, oracle, 2)
            modal_dismissed.append(dismiss_update_modal(child, oracle))
            wait_idle(child, oracle, stable_secs=1.5, max_wait=25)
            rows = oracle.nonblank()
            cur = oracle.cursor()
            if n == 1:
                mode_seqs = scan_mode_sequences(oracle.raw_bytes())
            launches.append({"launch": n, "cursor": {"x": cur[0], "y": cur[1]},
                             "rows": [f"{i}|{r}" for i, r in rows]})
        finally:
            exit_label = graceful_exit(child, oracle)
            oracle.close()

    # A composer-ready row set is anchored on three model-independent glyphs seen
    # in every launch: the left border '┃', the composer bottom border '╹▀+', and
    # the key-hint row containing 'commands'. The placeholder 'Ask anything...'
    # marks specifically the empty-and-ready state.
    def has_anchor(launch, needle):
        return any(needle in r for r in launch["rows"])

    stability = {
        "left_border_bar": all("┃" in " ".join(l["rows"]) for l in launches),
        "bottom_border": all(
            any(re.search(r"╹▀{5,}", r) for r in l["rows"]) for l in launches
        ),
        "hint_row_commands": all(has_anchor(l, "commands") for l in launches),
        "placeholder_ask_anything": all(has_anchor(l, "Ask anything") for l in launches),
    }

    signature = {
        "matcher": (
            r"composer-ready := (row matches /╹▀{5,}/  bottom border) AND "
            r"(some row contains 'commands' key-hint) AND (left border '┃' present); "
            r"empty-and-ready adds a row containing 'Ask anything...'"
        ),
        "raw_rows_launch1": launches[0]["rows"],
        "raw_rows_launch2": launches[1]["rows"],
        "cursor_launch1": launches[0]["cursor"],
        "cursor_launch2": launches[1]["cursor"],
        "stability": stability,
        "verified_across_launches": 2,
        "graceful_exit_observed": exit_label,
        "startup_mode_sequences": mode_seqs,
    }
    # CONTRACT: readiness gate asserts composer-ready == all(stability.values() for the
    # anchor set) before any inject; empty-composer inject additionally requires the
    # 'Ask anything...' placeholder row (proves no pending draft would be corrupted).
    record("composer_signature", signature)
    record("modal_mode_sequences_startup", mode_seqs)
    # CONTRACT: readiness gate treats the async 'Update Available' launch overlay as
    # NOT-composer-ready; it is dismissible with ESC and is NOT part of the stable
    # signature (env-dependent on a pending release).
    record("launch_distractor_overlay", {
        "name": "Update Available",
        "arrival": "asynchronous, ~6s post-launch (background update check)",
        "dismiss": "ESC (verified: overlay leaves, composer placeholder returns)",
        "input_blocking": "overlays composer; input reaches composer after ESC dismiss",
        "dismissed_each_launch": modal_dismissed,
        "env_dependent": "only shown when a newer release exists",
    })


# =========================================================================== #
# En-passant — graceful exit sequence (no LLM calls; all idle exits)
# =========================================================================== #
def test_graceful_exit_sequence():
    """Discover the harness keystroke chords that cleanly exit the TUI. Note:
    scripts/session-close.sh governs lore's session-substrate close-request enqueue,
    NOT the harness keystroke exit — this probes that gap. Records ctrl-c / ctrl-d /
    '/exit' behavior from a clean idle empty composer (no generation in flight)."""
    _seed_once()
    results = {}

    def clean_idle(raw_name):
        child, oracle = spawn_session(RAW_DIR / raw_name)
        pump(child, oracle, 2)
        dismiss_update_modal(child, oracle)
        wait_idle(child, oracle, stable_secs=1.5, max_wait=25)
        return child, oracle

    # ctrl-c from clean idle
    child, oracle = clean_idle("exit_ctrl_c.raw")
    child.send(b"\x03")
    wait_idle(child, oracle, stable_secs=1.0, max_wait=5)
    results["ctrl_c_single_from_idle"] = "exited" if not child.isalive() else "still-alive"
    if child.isalive():
        child.send(b"\x03")
        wait_idle(child, oracle, stable_secs=1.0, max_wait=5)
        results["ctrl_c_second"] = "exited" if not child.isalive() else "still-alive"
    if child.isalive():
        child.terminate(force=True)
    oracle.close()

    # ctrl-d from clean idle
    child, oracle = clean_idle("exit_ctrl_d.raw")
    child.send(b"\x04")
    wait_idle(child, oracle, stable_secs=1.0, max_wait=5)
    results["ctrl_d_from_idle"] = "exited" if not child.isalive() else "still-alive"
    if child.isalive():
        child.terminate(force=True)
    oracle.close()

    # /exit slash command
    child, oracle = clean_idle("exit_slash.raw")
    child.send(b"/exit")
    wait_idle(child, oracle, stable_secs=0.8, max_wait=5)
    results["slash_exit_palette_row"] = [
        r for _, r in oracle.nonblank() if "/exit" in r or "Exit the app" in r
    ]
    child.send(b"\r")
    wait_idle(child, oracle, stable_secs=1.0, max_wait=5)
    results["slash_exit_submits"] = "exited" if not child.isalive() else "still-alive"
    if child.isalive():
        child.terminate(force=True)
    oracle.close()

    recommended = "/exit + \\r  (explicit 'Exit the app' command; never ambiguous)"
    # CONTRACT: teardown after a send uses graceful_exit_sequence; the send path must
    # NOT confuse the active-generation 'esc interrupt' affordance with exit — ESC
    # interrupts the running turn, ctrl-c from idle exits.
    record("graceful_exit_sequence", {
        "recommended": recommended,
        "ctrl_c_single_from_idle": results.get("ctrl_c_single_from_idle"),
        "ctrl_d_from_idle": results.get("ctrl_d_from_idle"),
        "slash_exit_submits": results.get("slash_exit_submits"),
        "slash_exit_palette_row": results.get("slash_exit_palette_row"),
        "interrupt_vs_exit": (
            "During an ACTIVE generation the footer shows 'esc interrupt' — ESC "
            "interrupts the running turn (does NOT exit). ctrl-c from a clean idle "
            "composer exits. Distinguish by screen state before sending."
        ),
        "note": (
            "scripts/session-close.sh is lore's session-substrate close-request "
            "enqueue, not the harness keystroke exit; these are the harness chords."
        ),
        "raw_results": results,
    })


# =========================================================================== #
# P2 — permission-prompt signature
# =========================================================================== #
PERMISSION_PROMPT = b"Run this exact shell command: echo probe-ok"


def _induce_bash(child, oracle) -> int:
    """Dismiss launch overlay, submit the echo prompt, return the raw-byte offset
    captured just before submit (for slicing modal sequences)."""
    pump(child, oracle, 2)
    dismiss_update_modal(child, oracle)
    wait_idle(child, oracle, stable_secs=1.5, max_wait=25)
    pre_offset = len(oracle.raw_bytes())
    child.send(PERMISSION_PROMPT)
    wait_idle(child, oracle, stable_secs=0.8, max_wait=8)
    child.send(b"\r")
    return pre_offset


def test_p2_permission_prompt_signature():
    """Two-part probe. (A) Default config: opencode AUTO-RUNS bash — no modal.
    (B) With opencode.json permission.bash=ask: capture the real Permission-required
    modal signature + the in-band mode/cursor sequences around it, then decline."""
    _seed_once()

    # -- Part A: default config auto-runs bash (documents the no-gate baseline) --
    raw_a = RAW_DIR / "p2a_default_autorun.raw"
    child, oracle = spawn_session(raw_a)
    default_behavior = "unresolved"
    try:
        _induce_bash(child, oracle)
        wait_idle(child, oracle, stable_secs=2.0, max_wait=40)
        screen = oracle.text()
        asked = bool(re.search(r"(?i)Permission required|Allow (once|always)", screen))
        ran = "probe-ok" in screen
        default_behavior = (
            "asked-permission" if asked
            else ("auto-ran (no modal)" if ran else "no-output-observed")
        )
    finally:
        graceful_exit(child, oracle)
        oracle.close()

    # -- Part B: force a permission decision, capture the real modal --------------
    perm_dir = make_permission_sandbox(bash_mode="ask")
    raw_b = RAW_DIR / "p2b_permission_modal.raw"
    child, oracle = spawn_session(raw_b, launch_dir=perm_dir)
    modal = {"induced_by": f"permission.bash=ask + prompt: {PERMISSION_PROMPT.decode()}"}
    try:
        pre_offset = _induce_bash(child, oracle)
        # Poll specifically for the modal anchor.
        appeared = False
        deadline = time.time() + 30
        while time.time() < deadline:
            pump(child, oracle, 0.5)
            if "Permission required" in oracle.text():
                appeared = True
                break
        wait_idle(child, oracle, stable_secs=0.8, max_wait=6)

        rows = oracle.nonblank()
        modal_slice = oracle.raw_bytes()[pre_offset:]
        modal["appeared"] = appeared
        modal["behavior"] = "asked-permission" if appeared else "no-modal"
        # The modal renders IN-BAND inside the composer box (▲ header + action row),
        # not as a separate alt-screen layer.
        modal["matcher"] = (
            r"permission-modal := a row containing '△ Permission required' AND an "
            r"action row matching /Allow once\s+Allow always\s+Reject/"
        )
        modal["raw_rows"] = [f"{i}|{r}" for i, r in rows]
        modal["mode_sequences_around_modal"] = scan_mode_sequences(modal_slice)
        seqs = re.findall(rb"\x1b\[[0-9;?]* ?[A-Za-z]", modal_slice)
        seen, verbatim = set(), []
        for s in seqs:
            rep = repr(s)
            if rep not in seen:
                seen.add(rep)
                verbatim.append(rep)
        modal["modal_mode_sequences_verbatim"] = verbatim[:60]

        # Decline: ESC cancels the permission decision (safe teardown). Verify the
        # modal cleared and the command did NOT run.
        if appeared:
            child.send(b"\x1b")
            wait_idle(child, oracle, stable_secs=1.0, max_wait=8)
            modal["esc_dismisses_modal"] = "Permission required" not in oracle.text()
    finally:
        modal["graceful_exit_observed"] = graceful_exit(child, oracle)
        oracle.close()

    # CONTRACT: readiness gate MUST classify the permission-modal screen state as
    # NOT-composer-ready (block inject) and expose permission_prompt_signature so the
    # send path can distinguish 'awaiting user approval' from 'awaiting user message'.
    record("default_bash_behavior", default_behavior)
    record("permission_prompt_signature", {
        "induced_by": modal["induced_by"],
        "default_config_behavior": default_behavior,
        "behavior_with_ask": modal["behavior"],
        "matcher": modal["matcher"],
        "raw_rows": modal["raw_rows"],
        "esc_dismisses": modal.get("esc_dismisses_modal"),
    })
    record("modal_mode_sequences", {
        "note": "modal renders in-band in the composer box; no dedicated DECSET layer",
        "counts": modal["mode_sequences_around_modal"],
        "verbatim_csi_dec": modal["modal_mode_sequences_verbatim"],
    })


# =========================================================================== #
# P3 — submit vs newline bytes
# =========================================================================== #
def test_p3_submit_vs_newline():
    """Determine which byte submits the composer and which chord inserts a literal
    newline without submitting. Tests alt-enter (ESC CR), shift-enter CSI-u
    (ESC[13;2u), then plain CR."""
    _seed_once()
    raw_path = RAW_DIR / "p3_submit_newline.raw"
    child, oracle = spawn_session(raw_path)
    findings = {}
    try:
        pump(child, oracle, 5)
        dismiss_update_modal(child, oracle)
        wait_idle(child, oracle, stable_secs=1.5, max_wait=25)

        def composer_text():
            # the composer occupies the lower band; return joined nonblank text
            return oracle.text()

        def submitted(before_rows, after_rows):
            """A submit clears the typed draft from the composer and/or spawns a
            user message bubble + generation. Heuristic: the marker text left the
            composer input line."""
            return ("aaa" in before_rows) and ("aaa" not in _composer_band(oracle))

        marker = b"aaa-probe"
        child.send(marker)
        wait_idle(child, oracle, stable_secs=0.8, max_wait=6)
        band_typed = _composer_band(oracle)
        findings["typed_marker_visible"] = "aaa-probe" in band_typed
        y_typed = oracle.cursor()[1]

        def classify(chord_bytes, label):
            before_band = _composer_band(oracle)
            child.send(chord_bytes)
            wait_idle(child, oracle, stable_secs=1.0, max_wait=8)
            after_band = _composer_band(oracle)
            marker_present = "aaa-probe" in after_band
            # count composer input rows containing the marker or continuation
            gone = ("aaa-probe" in before_band) and (not marker_present)
            if gone:
                kind = "SUBMITTED (marker left composer)"
            elif after_band != before_band and marker_present:
                kind = "NEWLINE-or-edit (marker preserved, composer changed)"
            elif after_band == before_band:
                kind = "NOOP (composer unchanged)"
            else:
                kind = "OTHER"
            return {"chord": repr(chord_bytes), "result": kind,
                    "cursor_y": oracle.cursor()[1]}

        submitted_flag = False
        # alt-enter
        r_alt = classify(b"\x1b\r", "alt-enter")
        findings["alt_enter"] = r_alt
        if "SUBMITTED" in r_alt["result"]:
            submitted_flag = True

        # shift-enter CSI-u (only if not already submitted)
        if not submitted_flag:
            r_su = classify(b"\x1b[13;2u", "shift-enter-csiu")
            findings["shift_enter_csiu"] = r_su
            if "SUBMITTED" in r_su["result"]:
                submitted_flag = True

        # plain CR — expected submit (only meaningful if not already submitted)
        if not submitted_flag:
            r_cr = classify(b"\r", "plain-cr")
            findings["plain_cr"] = r_cr
            if "SUBMITTED" in r_cr["result"]:
                submitted_flag = True
        # let any triggered generation settle before exit
        wait_idle(child, oracle, stable_secs=1.5, max_wait=25)
    finally:
        findings["graceful_exit_observed"] = graceful_exit(child, oracle)
        oracle.close()

    # derive submit / newline sequences from the classifications
    submit_seq = "unresolved"
    newline_seq = "unresolved"
    for key, seq in (("plain_cr", "\\r"), ("alt_enter", "\\x1b\\r"),
                     ("shift_enter_csiu", "\\x1b[13;2u")):
        f = findings.get(key)
        if f and "SUBMITTED" in f["result"] and submit_seq == "unresolved":
            submit_seq = seq
        if f and "NEWLINE" in f["result"] and newline_seq == "unresolved":
            newline_seq = seq

    # CONTRACT: send path uses submit_sequence to commit a single-line message and
    # newline_sequence inside PasteEncode fallback for harnesses that do NOT honor
    # bracketed paste. These bytes are asserted exact-match against these findings.
    record("submit_sequence", submit_seq)
    record("newline_sequence", newline_seq)
    record("submit_newline_probe", findings)


def _composer_band(oracle: ScreenOracle) -> str:
    """Return the text of the lower composer band (rows 16..bottom), where the
    input box + status live. Keeps submit/newline detection out of the transcript."""
    rows = oracle.rows()
    band = rows[16:]
    return "\n".join(band)


def _live_composer_input(oracle: ScreenOracle) -> str:
    """Return ONLY the live composer INPUT text — the '┃'-bordered rows between the
    top of the input box and the status row (`· <model> OpenAI`) directly above the
    `╹▀+` bottom border. This distinguishes the live input from transcript user
    bubbles, which opencode also renders with a '┃' left border but which sit ABOVE
    the composer box. Essential for P5: a scrolled transcript pushes old user
    bubbles into the lower rows, so a naive band scan misreads them as composer text.
    """
    rows = oracle.rows()
    # bottom border row
    bb = None
    for i, r in enumerate(rows):
        if re.search(r"╹▀{5,}", r):
            bb = i
    if bb is None:
        return ""
    # status row is the last '┃' row above the bottom border containing ' OpenAI'
    status = None
    for i in range(bb - 1, -1, -1):
        if "┃" in rows[i] and "OpenAI" in rows[i]:
            status = i
            break
    if status is None:
        # no status row found; treat the row just above the border as the boundary
        status = bb
    # input rows: contiguous '┃' rows above the status row
    input_rows = []
    for i in range(status - 1, -1, -1):
        if "┃" in rows[i]:
            input_rows.append(rows[i])
        else:
            break
    text = "\n".join(reversed(input_rows))
    # strip the border glyph so residual '┃' does not pollute matches
    return text.replace("┃", " ")


# =========================================================================== #
# P4 — bracketed paste
# =========================================================================== #
def test_p4_bracketed_paste():
    """Confirm opencode advertises bracketed paste (ESC[?2004h) at the composer,
    then inject a 200~..201~-wrapped two-line payload and record whether it lands
    as one multi-line composer entry, needs a trailing submit, or auto-submits."""
    _seed_once()
    raw_path = RAW_DIR / "p4_bracketed_paste.raw"
    child, oracle = spawn_session(raw_path)
    findings = {}
    try:
        pump(child, oracle, 5)
        dismiss_update_modal(child, oracle)
        wait_idle(child, oracle, stable_secs=1.5, max_wait=25)

        advertised = b"\x1b[?2004h" in oracle.raw_bytes()
        findings["advertises_2004h_at_composer"] = advertised

        before_band = _composer_band(oracle)
        payload = b"\x1b[200~paste-line-one\npaste-line-two\x1b[201~"
        child.send(payload)
        wait_idle(child, oracle, stable_secs=1.2, max_wait=8)
        after_band = _composer_band(oracle)

        both_lines = ("paste-line-one" in after_band) and ("paste-line-two" in after_band)
        auto_submitted = both_lines is False and (
            "paste-line-one" in oracle.text() and "paste-line-two" in oracle.text()
            and "paste-line-one" not in after_band
        )
        # If both lines sit in the composer band without a transcript bubble, the
        # paste is HELD (needs trailing submit). Detect a transcript bubble by the
        # marker appearing ABOVE the composer band.
        transcript = "\n".join(oracle.rows()[:16])
        in_transcript = "paste-line-one" in transcript

        if both_lines and not in_transcript:
            semantics = "HELD as one multi-line composer entry (needs trailing submit)"
        elif in_transcript:
            semantics = "AUTO-SUBMITTED on paste (marker reached transcript)"
        elif ("paste-line-one" in after_band) and ("paste-line-two" not in after_band):
            semantics = "NEWLINE-AS-SUBMIT TRAP (second line lost / split submit)"
        else:
            semantics = "UNRESOLVED"
        findings["after_band_has_both_lines"] = both_lines
        findings["reached_transcript_without_submit"] = in_transcript
        findings["semantics"] = semantics
        findings["composer_band_after_paste"] = [
            r for r in after_band.split("\n") if r.strip()
        ]

        # If held, confirm a trailing CR submits it as a SINGLE message.
        if both_lines and not in_transcript:
            child.send(b"\r")
            wait_idle(child, oracle, stable_secs=1.5, max_wait=25)
            post = oracle.text()
            findings["trailing_cr_submits_single"] = (
                "paste-line-one" in post and "paste-line-two" in post
            )
    finally:
        findings["graceful_exit_observed"] = graceful_exit(child, oracle)
        oracle.close()

    # CONTRACT: if honors_bracketed_paste, the send path wraps multiline in 200~/201~
    # and appends submit_sequence exactly once (asserted: one user message, N lines).
    # If NOT honored, PasteEncode must fall back to newline_sequence per line.
    adv = findings.get("advertises_2004h_at_composer")
    lands = findings.get("after_band_has_both_lines")
    summary = (
        f"{'YES' if adv and lands else 'PARTIAL/NO'} — "
        f"advertises ESC[?2004h at composer: {adv}; "
        f"200~..201~ wrap with embedded \\n lands as one multi-line composer entry: "
        f"{lands}; single trailing \\r submits it as one message: "
        f"{findings.get('trailing_cr_submits_single')}"
    )
    record("honors_bracketed_paste", summary)
    record("honors_bracketed_paste_detail", {
        "advertises_2004h": adv,
        "wrap_lands_multiline": lands,
        "trailing_cr_submits_single": findings.get("trailing_cr_submits_single"),
    })
    record("paste_multiline_semantics", findings.get("semantics"))
    record("bracketed_paste_probe", findings)


# =========================================================================== #
# P5 — mid-generation inject
# =========================================================================== #
def test_p5_mid_generation_inject():
    """During an active generation, inject 'PING-MIDGEN\\r'. After completion +
    idle, classify: buffered / dropped / submitted (queued) / interrupted. This
    decides strict-gate vs queue-and-hold for the readiness design."""
    _seed_once()
    raw_path = RAW_DIR / "p5_mid_generation.raw"
    child, oracle = spawn_session(raw_path)
    findings = {}
    try:
        pump(child, oracle, 5)
        dismiss_update_modal(child, oracle)
        wait_idle(child, oracle, stable_secs=1.5, max_wait=25)

        child.send(b"Count from 1 to 40, one number per line, no other text.")
        wait_idle(child, oracle, stable_secs=0.8, max_wait=8)
        child.send(b"\r")  # submit the counting task

        # Let generation begin, then inject mid-stream. We watch for the first
        # streamed digits to confirm we're mid-generation before injecting.
        began = False
        deadline = time.time() + 12
        while time.time() < deadline:
            pump(child, oracle, 0.5)
            txt = oracle.text()
            if re.search(r"\b1\b", txt) and re.search(r"\b2\b", txt):
                began = True
                break
        findings["generation_began_before_inject"] = began

        inject_offset = len(oracle.raw_bytes())
        child.send(b"PING-MIDGEN\r")
        findings["injected_marker"] = "PING-MIDGEN"

        # Wait for full completion + quiescence.
        wait_idle(child, oracle, stable_secs=2.5, max_wait=45)

        full = oracle.text()
        live_input = _live_composer_input(oracle)      # ONLY the live input box
        in_live_composer = "PING-MIDGEN" in live_input
        # anywhere on screen minus the live input box == transcript region
        in_transcript = ("PING-MIDGEN" in full) and not in_live_composer
        # a second assistant turn responding to the injected marker == it was sent
        got_second_response = full.count("Build · GPT-4o mini ·") >= 2
        counted_to_40 = bool(re.search(r"\b40\b", full))

        if in_transcript and got_second_response:
            klass = "SUBMITTED-QUEUED (held during gen, auto-sent as 2nd message after gen finished)"
        elif in_transcript:
            klass = "SUBMITTED (marker reached transcript as a user message)"
        elif in_live_composer:
            klass = "BUFFERED (held in live composer input, trailing CR NOT consumed)"
        elif not counted_to_40:
            klass = "INTERRUPTED (first generation did not finish)"
        else:
            klass = "DROPPED (marker not present anywhere after completion)"

        findings["marker_in_live_composer"] = in_live_composer
        findings["marker_in_transcript"] = in_transcript
        findings["got_second_assistant_response"] = got_second_response
        findings["first_gen_reached_40"] = counted_to_40
        findings["live_composer_input_after"] = [
            r for r in live_input.split("\n") if r.strip()
        ]
        findings["classification"] = klass
        findings["final_screen_nonblank"] = [
            f"{i}|{r}" for i, r in oracle.nonblank()
        ]
        # Native affordance: opencode paints a 'QUEUED' badge on the held message
        # during generation and shows 'esc interrupt' on the active turn. Scan the
        # persisted raw log (ANSI stripped) for both — strong mechanism evidence.
        plain = _strip_ansi(oracle.raw_bytes())
        findings["native_queued_badge_seen"] = "QUEUED" in plain
        findings["esc_interrupt_hint_seen"] = "esc interrupt" in plain
    finally:
        findings["graceful_exit_observed"] = graceful_exit(child, oracle)
        oracle.close()

    # CONTRACT: if BUFFERED/DROPPED -> readiness gate is a STRICT precondition (never
    # inject mid-generation). If SUBMITTED(queued) -> queue-and-hold is viable but the
    # gate still must confirm the message landed as intended, not merged into a draft.
    record("mid_generation_inject", findings.get("classification"))
    record("mid_generation_probe", findings)
