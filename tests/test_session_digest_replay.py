"""Tests for digest replay: content-derived session dates and the
durable digested-session ledger.

Two mtime dependencies used to chain into a replay — `_pending_digest.md`
presenting an already-consumed old session as the previous session's
highlights:

1. `claude_code.py::session_metadata` read only the transcript's first line
   and fell back to file mtime when that line carried no `timestamp`. A
   2026-07-10 session was stamped `**Date:** 2026-07-24 14:13:51` — its
   file's mtime to the second.
2. The already-processed guard in `extract-session-digest.py` compared
   `_pending_digest.md`'s mtime against the transcript's, so any touch of an
   old transcript re-opened a digest for a session already consumed and
   deleted.

Sessions are staged as real files and the writer runs as a real subprocess,
so both the provider path and the hook's exit behavior are exercised end to
end.
"""

import importlib.util
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

import pytest

_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

_DIGEST_SCRIPT = os.path.join(_REPO_ROOT, "scripts", "extract-session-digest.py")
_spec = importlib.util.spec_from_file_location("extract_session_digest_under_test", _DIGEST_SCRIPT)
digest_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(digest_mod)

from adapters.transcripts import claude_code  # noqa: E402  (after sys.path setup)


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

CWD = "/work/digest-replay-test"

# The mtime the observed bug leaked into the digest header.
MTIME_2026_07_24 = datetime(2026, 7, 24, 14, 13, 51).timestamp()


def _user(text, ts, extra=None, session_id="replay-sess"):
    rec = {
        "sessionId": session_id,
        "type": "user",
        "entrypoint": "cli",
        "promptSource": "typed",
        "message": {"role": "user", "content": text},
    }
    if ts is not None:
        rec["timestamp"] = ts
    if extra:
        rec.update(extra)
    return rec


def _assistant(text, ts, session_id="replay-sess"):
    rec = {
        "sessionId": session_id,
        "type": "assistant",
        "message": {"role": "assistant", "content": [{"type": "text", "text": text}]},
    }
    if ts is not None:
        rec["timestamp"] = ts
    return rec


def _write_jsonl(path, entries):
    with open(path, "w", encoding="utf-8") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")
    return str(path)


def _conversational_entries(day="2026-07-10", first_line_timestamp=None, session_id="replay-sess"):
    """Three user turns plus an assistant turn — enough to clear the
    fewer-than-3-user-messages skip.

    `first_line_timestamp` defaults to None: the observed failure shape is a
    transcript whose FIRST line carries no `timestamp` while later lines do.
    """
    return [
        _user("first substantive request about the subsystem design",
              first_line_timestamp, session_id=session_id),
        _user("second message refining the approach and constraints",
              f"{day}T09:30:00Z", session_id=session_id),
        _user("third message confirming the direction to take",
              f"{day}T09:45:00Z", session_id=session_id),
        _assistant("Acknowledged.", f"{day}T09:45:05Z", session_id=session_id),
    ]


@pytest.fixture
def stage(tmp_path):
    """Stage a fake HOME with a claude-code project dir and a knowledge store.

    The transcript under test is written as `previous.jsonl` and a newer
    `current.jsonl` dummy is created so `previous_session_path` (which returns
    the second-most-recent by mtime) selects the fixture.
    """
    home = tmp_path / "home"
    proj_dir = home / ".claude" / "projects" / CWD.replace("/", "-")
    proj_dir.mkdir(parents=True)
    kd = tmp_path / "knowledge"
    (kd / "_threads").mkdir(parents=True)
    (kd / "_manifest.json").write_text("{}")

    current = proj_dir / "current.jsonl"
    current.write_text("{}\n")

    return {
        "home": str(home),
        "proj_dir": proj_dir,
        "kd": kd,
        "transcript": proj_dir / "previous.jsonl",
        "current": current,
        "digest": kd / "_threads" / "_pending_digest.md",
        "ledger": kd / "_threads" / digest_mod.DIGESTED_LEDGER_NAME,
    }


def _order_sessions(stage_dict, prev_mtime=MTIME_2026_07_24):
    """Make the fixture the second-most-recent session."""
    os.utime(stage_dict["transcript"], (prev_mtime, prev_mtime))
    newer = prev_mtime + 60
    os.utime(stage_dict["current"], (newer, newer))


def _run_writer(stage_dict):
    env = dict(os.environ)
    env["HOME"] = stage_dict["home"]
    # The provider loads transcript.py / extract-session-digest.py from
    # $LORE_DATA_DIR/scripts (claude_code.py::_resolve_scripts_dir).
    env["LORE_DATA_DIR"] = _REPO_ROOT
    env["LORE_FRAMEWORK"] = "claude-code"
    return subprocess.run(
        [
            sys.executable, _DIGEST_SCRIPT,
            "--knowledge-dir", str(stage_dict["kd"]),
            "--cwd", CWD,
            "--framework", "claude-code",
        ],
        capture_output=True, text=True, env=env,
    )


def _digest_date_line(digest_path):
    for line in digest_path.read_text().splitlines():
        if line.startswith("**Date:**"):
            return line
    raise AssertionError(f"no **Date:** line in {digest_path}")


def _ledger_records(ledger_path):
    if not ledger_path.exists():
        return []
    return [json.loads(line) for line in ledger_path.read_text().splitlines() if line.strip()]


# ---------------------------------------------------------------------------
# Fault 1 — session_date must come from transcript content, never mtime
# ---------------------------------------------------------------------------

def test_first_line_without_timestamp_does_not_yield_mtime_date(tmp_path):
    """The observed failure: no `timestamp` on line 1, a mtime days later."""
    path = _write_jsonl(tmp_path / "t.jsonl", _conversational_entries(day="2026-07-10"))
    os.utime(path, (MTIME_2026_07_24, MTIME_2026_07_24))

    meta = claude_code.session_metadata(path)

    assert meta["session_id"] == "replay-sess"
    date = meta["session_date"]
    assert date is not None
    assert (date.year, date.month, date.day) == (2026, 7, 10), date
    # The bug printed the mtime to the second; assert we are not near it.
    assert date.strftime("%Y-%m-%d %H:%M:%S") != "2026-07-24 14:13:51"


def test_session_date_is_the_earliest_timestamp_not_the_first_seen(tmp_path):
    """Out-of-order entries: the earliest stamp identifies when the session ran."""
    entries = [
        _user("later-stamped opening turn", "2026-07-10T11:00:00Z"),
        _user("earliest stamp lives here", "2026-07-10T08:15:00Z"),
        _user("third", "2026-07-10T12:00:00Z"),
    ]
    path = _write_jsonl(tmp_path / "t.jsonl", entries)

    date = claude_code.session_metadata(path)["session_date"]

    assert date.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M") == "2026-07-10 08:15"


def test_no_timestamp_anywhere_yields_none_not_mtime(tmp_path):
    """An honest `unknown` beats a confident wrong date."""
    entries = [_user(f"message {i}", None) for i in range(3)]
    path = _write_jsonl(tmp_path / "t.jsonl", entries)
    os.utime(path, (MTIME_2026_07_24, MTIME_2026_07_24))

    meta = claude_code.session_metadata(path)

    assert meta["session_id"] == "replay-sess"
    assert meta["session_date"] is None


def test_unparseable_timestamps_yield_none(tmp_path):
    entries = [_user(f"message {i}", "not-a-timestamp") for i in range(3)]
    path = _write_jsonl(tmp_path / "t.jsonl", entries)

    assert claude_code.session_metadata(path)["session_date"] is None


def test_missing_file_returns_sentinels(tmp_path):
    meta = claude_code.session_metadata(str(tmp_path / "absent.jsonl"))
    assert meta == {"session_id": "unknown", "session_date": None}


def test_digest_header_carries_the_content_date(stage):
    _write_jsonl(stage["transcript"], _conversational_entries(day="2026-07-10"))
    _order_sessions(stage)

    result = _run_writer(stage)

    assert result.returncode == 0, result.stderr
    assert stage["digest"].exists(), result.stderr
    date_line = _digest_date_line(stage["digest"])
    assert "2026-07-10" in date_line, date_line
    assert "2026-07-24" not in date_line, date_line


def test_digest_header_says_unknown_when_no_timestamps(stage):
    entries = [_user(f"message number {i} with enough substance", None) for i in range(3)]
    _write_jsonl(stage["transcript"], entries)
    _order_sessions(stage)

    result = _run_writer(stage)

    assert result.returncode == 0, result.stderr
    assert _digest_date_line(stage["digest"]) == "**Date:** unknown"


# ---------------------------------------------------------------------------
# Fault 2 — the digested-session ledger replaces the mtime staleness guard
# ---------------------------------------------------------------------------

def test_session_is_not_redigested_after_transcript_mtime_bump(stage):
    """The replay: consume the digest (as /remember Step 0b does), then touch
    the transcript. The old mtime guard reopened it; the ledger must not."""
    _write_jsonl(stage["transcript"], _conversational_entries())
    _order_sessions(stage)

    first = _run_writer(stage)
    assert first.returncode == 0, first.stderr
    assert stage["digest"].exists()
    assert len(_ledger_records(stage["ledger"])) == 1

    # Step 0b consumes and deletes the pending digest.
    stage["digest"].unlink()

    # Touch the transcript so it is newer than anything else on disk.
    bumped = MTIME_2026_07_24 + 86400 * 30
    os.utime(stage["transcript"], (bumped, bumped))
    os.utime(stage["current"], (bumped + 60, bumped + 60))

    second = _run_writer(stage)

    assert second.returncode == 0, second.stderr
    assert not stage["digest"].exists(), "already-digested session was replayed"
    assert len(_ledger_records(stage["ledger"])) == 1


def test_ledger_survives_pending_digest_deletion(stage):
    _write_jsonl(stage["transcript"], _conversational_entries())
    _order_sessions(stage)
    _run_writer(stage)
    stage["digest"].unlink()

    records = _ledger_records(stage["ledger"])

    assert len(records) == 1
    assert records[0]["key"] == "session-id:replay-sess"
    assert records[0]["transcript"] == "previous.jsonl"
    assert records[0]["digested_at"].endswith("Z")


def test_a_different_session_is_still_digested(stage):
    """Guard against over-suppression: the ledger keys on identity, not on
    'a digest was produced once'."""
    _write_jsonl(stage["transcript"], _conversational_entries(session_id="sess-one"))
    _order_sessions(stage)
    assert _run_writer(stage).returncode == 0
    assert stage["digest"].exists()
    stage["digest"].unlink()

    _write_jsonl(stage["transcript"], _conversational_entries(day="2026-07-12", session_id="sess-two"))
    _order_sessions(stage)

    assert _run_writer(stage).returncode == 0
    assert stage["digest"].exists()
    assert "2026-07-12" in _digest_date_line(stage["digest"])
    assert [r["key"] for r in _ledger_records(stage["ledger"])] == [
        "session-id:sess-one", "session-id:sess-two",
    ]


def test_session_identity_falls_back_to_content_hash(tmp_path):
    path = _write_jsonl(tmp_path / "t.jsonl", _conversational_entries())

    key = digest_mod.session_identity("unknown", path)

    assert key.startswith("sha256:")
    # Stable across an mtime bump; changed content gets a different key.
    os.utime(path, (MTIME_2026_07_24, MTIME_2026_07_24))
    assert digest_mod.session_identity("unknown", path) == key
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(_user("appended", "2026-07-10T13:00:00Z")) + "\n")
    assert digest_mod.session_identity("unknown", path) != key


def test_ledger_trims_to_its_bound(tmp_path):
    kd = tmp_path / "kd"
    (kd / "_threads").mkdir(parents=True)
    transcript = _write_jsonl(tmp_path / "t.jsonl", _conversational_entries())

    overflow = digest_mod.MAX_LEDGER_RECORDS + 25
    for i in range(overflow):
        digest_mod.record_digested(str(kd), f"session-id:s{i}", transcript)

    records = _ledger_records(kd / "_threads" / digest_mod.DIGESTED_LEDGER_NAME)
    assert len(records) == digest_mod.MAX_LEDGER_RECORDS
    # The tail is kept: the oldest keys fall off the head.
    assert records[-1]["key"] == f"session-id:s{overflow - 1}"
    assert records[0]["key"] == f"session-id:s{overflow - digest_mod.MAX_LEDGER_RECORDS}"


# ---------------------------------------------------------------------------
# Existing skip paths must not regress
# ---------------------------------------------------------------------------

def test_headless_session_still_skipped(stage):
    """`claude -p` traffic must not clobber _pending_digest.md, and must not
    consume a ledger slot."""
    headless = {"entrypoint": "sdk-cli", "promptSource": "sdk"}
    entries = [
        _user("first substantive request about the subsystem design",
              "2026-07-10T09:00:00Z", extra=headless),
        _user("second message refining the approach", "2026-07-10T09:30:00Z", extra=headless),
        _user("third message confirming direction", "2026-07-10T09:45:00Z", extra=headless),
    ]
    # entrypoint/promptSource are set explicitly; strip the interactive defaults.
    for e in entries:
        e["entrypoint"] = "sdk-cli"
        e["promptSource"] = "sdk"
    _write_jsonl(stage["transcript"], entries)
    _order_sessions(stage)

    result = _run_writer(stage)

    assert result.returncode == 0, result.stderr
    assert not stage["digest"].exists()
    assert _ledger_records(stage["ledger"]) == []


def test_too_short_session_still_skipped(stage):
    entries = [
        _user("only two user turns here", "2026-07-10T09:00:00Z"),
        _user("second and last", "2026-07-10T09:05:00Z"),
    ]
    _write_jsonl(stage["transcript"], entries)
    _order_sessions(stage)

    result = _run_writer(stage)

    assert result.returncode == 0, result.stderr
    assert not stage["digest"].exists()
    assert _ledger_records(stage["ledger"]) == []


def test_no_previous_session_is_a_silent_no_op(stage):
    """Only the in-flight session exists — nothing to digest."""
    stage["transcript"].unlink(missing_ok=True)

    result = _run_writer(stage)

    assert result.returncode == 0, result.stderr
    assert not stage["digest"].exists()


def test_unsupported_framework_skips_without_writing(stage):
    _write_jsonl(stage["transcript"], _conversational_entries())
    _order_sessions(stage)
    env = dict(os.environ)
    env["HOME"] = stage["home"]
    env["LORE_DATA_DIR"] = _REPO_ROOT

    result = subprocess.run(
        [
            sys.executable, _DIGEST_SCRIPT,
            "--knowledge-dir", str(stage["kd"]),
            "--cwd", CWD,
            "--framework", "no-such-harness",
        ],
        capture_output=True, text=True, env=env,
    )

    assert result.returncode == 0
    assert "transcript_provider=unavailable" in result.stderr
    assert not stage["digest"].exists()
