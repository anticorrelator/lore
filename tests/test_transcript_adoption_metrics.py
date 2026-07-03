"""Tests for the transcript-adoption measurement harness.

Covers the deterministic burst rule, the three-valued session
classification, event detection over real parse_transcript output
(two-pass alignment), and the degraded-provider exit contract.
"""

import importlib.util
import json
import os
import subprocess
import sys

_TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_DIR = os.path.dirname(_TESTS_DIR)

_HARNESS_PATH = os.path.join(_REPO_DIR, "scripts", "transcript-adoption-metrics.py")
_spec = importlib.util.spec_from_file_location("transcript_adoption_metrics", _HARNESS_PATH)
harness = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harness)

_TRANSCRIPT_PATH = os.path.join(_REPO_DIR, "scripts", "transcript.py")
_tspec = importlib.util.spec_from_file_location("transcript_legacy", _TRANSCRIPT_PATH)
transcript = importlib.util.module_from_spec(_tspec)
_tspec.loader.exec_module(transcript)


PATTERNS = {
    "version": 1,
    "retrieval_events": [
        {
            "tool": "Bash",
            "input_field": "command",
            "regex": r"(?:^|[\s;&|(`])lore\s+(?:search|prefetch)\b",
        }
    ],
    "exploration_events": {
        "tools": ["Grep", "Glob"],
        "agent_tools": ["Agent", "Task"],
        "agent_type_field": "subagent_type",
        "agent_types": ["Explore", "general-purpose"],
    },
    "skill_invocation": {"regex": r"<command-name>([^<]+)</command-name>"},
    "burst": {"max_gap_messages": 20},
}


def compiled():
    return harness.CompiledPatterns(PATTERNS)


# ---------------------------------------------------------------------------
# Burst rule
# ---------------------------------------------------------------------------

def test_no_exploration_yields_zero_bursts():
    assert harness.compute_bursts([], [(1, 0)], 20) == (0, 0)


def test_single_burst_covered_by_preceding_retrieval():
    exploration = [(5, 0), (6, 0), (7, 0)]
    retrieval = [(2, 0)]
    assert harness.compute_bursts(exploration, retrieval, 20) == (1, 1)


def test_single_burst_uncovered_without_retrieval():
    assert harness.compute_bursts([(5, 0), (6, 0)], [], 20) == (1, 0)


def test_gap_over_max_splits_bursts_and_early_retrieval_covers_only_first():
    # Two bursts split by a 30-message gap; the single early retrieval
    # covers the first burst only — each fresh dive must be re-preceded.
    exploration = [(5, 0), (6, 0), (40, 0), (41, 0)]
    retrieval = [(2, 0)]
    assert harness.compute_bursts(exploration, retrieval, 20) == (2, 1)


def test_intervening_retrieval_splits_burst_and_covers_second():
    exploration = [(5, 0), (10, 0)]
    retrieval = [(7, 0)]
    assert harness.compute_bursts(exploration, retrieval, 20) == (2, 1)


def test_retrieval_between_bursts_covers_second():
    exploration = [(5, 0), (40, 0)]
    retrieval = [(2, 0), (30, 0)]
    assert harness.compute_bursts(exploration, retrieval, 20) == (2, 2)


def test_gap_at_exactly_max_gap_stays_one_burst():
    exploration = [(5, 0), (25, 0)]
    assert harness.compute_bursts(exploration, [], 20) == (1, 0)


# ---------------------------------------------------------------------------
# Fixture helpers — claude-code-shaped JSONL lines
# ---------------------------------------------------------------------------

def _user(text, sidechain=False):
    return {
        "type": "user", "isSidechain": sidechain,
        "sessionId": "s1", "timestamp": "2026-06-10T08:00:00Z",
        "message": {"role": "user", "content": text},
    }


def _tool_result(text):
    return {
        "type": "user", "isSidechain": False,
        "sessionId": "s1", "timestamp": "2026-06-10T08:00:00Z",
        "message": {"role": "user",
                    "content": [{"type": "tool_result", "content": text}]},
    }


def _assistant(blocks, model="claude-fable-5", sidechain=False):
    return {
        "type": "assistant", "isSidechain": sidechain,
        "sessionId": "s1", "timestamp": "2026-06-10T08:00:01Z",
        "message": {"role": "assistant", "model": model, "content": blocks},
    }


def _bash(command):
    return {"type": "tool_use", "name": "Bash", "input": {"command": command}}


def _tool(name, **input_fields):
    return {"type": "tool_use", "name": name, "input": input_fields}


def _write_session(tmp_path, entries, name="session.jsonl"):
    path = tmp_path / name
    with open(path, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")
    return str(path)


def _events_for(tmp_path, entries):
    path = _write_session(tmp_path, entries)
    messages = transcript.parse_transcript(path)
    with open(path) as f:
        raw_lines = f.readlines()
    return harness.detect_events(messages, raw_lines, compiled())


# ---------------------------------------------------------------------------
# Event detection (two-pass over real parse_transcript output)
# ---------------------------------------------------------------------------

def test_bash_lore_search_is_retrieval_and_plain_bash_is_not(tmp_path):
    events = _events_for(tmp_path, [
        _user("look into the parser"),
        _assistant([_bash('lore search "parser conventions" --scale-set subsystem')]),
        _assistant([_bash("grep -rn parser src/")]),
        _assistant([_tool("Grep", pattern="parser")]),
    ])
    assert len(events["retrieval"]) == 1
    # Bash grep is not an exploration event under these patterns; Grep tool_use is.
    assert len(events["exploration"]) == 1


def test_agent_spawn_counts_only_for_configured_types(tmp_path):
    events = _events_for(tmp_path, [
        _assistant([_tool("Agent", subagent_type="Explore", prompt="find X")]),
        _assistant([_tool("Agent", subagent_type="researcher", prompt="write Y")]),
        _assistant([_tool("Task", subagent_type="general-purpose", prompt="do Z")]),
    ])
    assert len(events["exploration"]) == 2


def test_sidechain_lines_are_excluded(tmp_path):
    events = _events_for(tmp_path, [
        _assistant([_tool("Grep", pattern="x")], sidechain=True),
        _user("hello", sidechain=True),
        _assistant([_bash("lore search q --scale-set abstract")], sidechain=True),
    ])
    assert events["message_count"] == 0
    assert events["exploration"] == []
    assert events["retrieval"] == []


def test_skill_tag_in_tool_result_does_not_count(tmp_path):
    events = _events_for(tmp_path, [
        _tool_result("transcript says <command-name>/spec</command-name>"),
        _user("<command-name>/implement</command-name> run it"),
    ])
    assert [cmd for _, cmd in events["skills"]] == ["/implement"]


def test_models_counted_from_non_sidechain_assistant_lines(tmp_path):
    events = _events_for(tmp_path, [
        _assistant([], model="claude-fable-5"),
        _assistant([], model="claude-fable-5"),
        _assistant([], model="claude-opus-4-8"),
        _assistant([], model="claude-haiku-4-5", sidechain=True),
    ])
    assert events["models"] == {"claude-fable-5": 2, "claude-opus-4-8": 1}


# ---------------------------------------------------------------------------
# Session classification (D2 three-valued rule)
# ---------------------------------------------------------------------------

def test_skill_before_first_exploration_is_skill_driven(tmp_path):
    events = _events_for(tmp_path, [
        _user("<command-name>/implement</command-name>"),
        _assistant([_tool("Grep", pattern="x")]),
    ])
    assert harness.classify_session(events) == "skill-driven"


def test_skill_only_after_first_exploration_is_mixed(tmp_path):
    events = _events_for(tmp_path, [
        _assistant([_tool("Grep", pattern="x")]),
        _user("<command-name>/spec</command-name>"),
    ])
    assert harness.classify_session(events) == "mixed"


def test_no_skill_invocation_is_interactive(tmp_path):
    events = _events_for(tmp_path, [
        _user("plain conversation"),
        _assistant([_tool("Grep", pattern="x")]),
    ])
    assert harness.classify_session(events) == "interactive"


def test_skill_with_no_exploration_is_skill_driven(tmp_path):
    events = _events_for(tmp_path, [
        _user("<command-name>/work</command-name>"),
        _assistant([]),
    ])
    assert harness.classify_session(events) == "skill-driven"


# ---------------------------------------------------------------------------
# Row assembly
# ---------------------------------------------------------------------------

def test_build_row_lore_first_and_consistency(tmp_path):
    entries = [
        _user("go"),
        _assistant([_bash("lore search q --scale-set subsystem")]),
        _assistant([_tool("Grep", pattern="x")]),
    ]
    path = _write_session(tmp_path, entries)
    messages = transcript.parse_transcript(path)
    with open(path) as f:
        raw_lines = f.readlines()
    events = harness.detect_events(messages, raw_lines, compiled())
    row = harness.build_row(path, {"session_id": "s1", "session_date": None},
                            events, compiled(), "abc123", "claude-code")
    assert row["lore_first"] is True
    assert row["burst_consistency"] == 1.0
    assert row["model_id"] == "claude-fable-5"
    assert row["session_class"] == "interactive"
    assert row["patterns_sha256"] == "abc123"


def test_build_row_null_lore_first_without_exploration(tmp_path):
    entries = [_user("just chatting"), _assistant([])]
    path = _write_session(tmp_path, entries)
    messages = transcript.parse_transcript(path)
    with open(path) as f:
        raw_lines = f.readlines()
    events = harness.detect_events(messages, raw_lines, compiled())
    row = harness.build_row(path, {"session_id": "s1", "session_date": None},
                            events, compiled(), "abc123", "claude-code")
    assert row["lore_first"] is None
    assert row["burst_consistency"] is None


def test_build_row_none_for_pure_sidechain_session(tmp_path):
    entries = [_assistant([_tool("Grep", pattern="x")], sidechain=True)]
    path = _write_session(tmp_path, entries)
    messages = transcript.parse_transcript(path)
    with open(path) as f:
        raw_lines = f.readlines()
    events = harness.detect_events(messages, raw_lines, compiled())
    row = harness.build_row(path, {"session_id": "s1", "session_date": None},
                            events, compiled(), "abc123", "claude-code")
    assert row is None


# ---------------------------------------------------------------------------
# Session-start window (--since/--until)
# ---------------------------------------------------------------------------

def test_session_start_utc_prefers_first_timestamped_entry(tmp_path):
    entries = [
        {"type": "mode", "sessionId": "s1"},
        _user("hi"),
    ]
    path = _write_session(tmp_path, entries)
    with open(path) as f:
        raw_lines = f.readlines()
    start = harness.session_start_utc(raw_lines, {"session_date": None})
    assert start is not None
    assert start.isoformat() == "2026-06-10T08:00:00+00:00"


def test_session_start_utc_falls_back_to_meta_date(tmp_path):
    from datetime import datetime as dt, timezone as tz
    raw_lines = ['{"type": "mode", "sessionId": "s1"}\n']
    meta = {"session_date": dt(2026, 6, 1, 12, 0, 0, tzinfo=tz.utc)}
    start = harness.session_start_utc(raw_lines, meta)
    assert start.isoformat() == "2026-06-01T12:00:00+00:00"


def test_until_excludes_sessions_starting_at_or_after_cutoff(tmp_path):
    home = tmp_path / "home"
    cwd = "/work/test-project"
    project_dir = home / ".claude" / "projects" / cwd.replace("/", "-")
    project_dir.mkdir(parents=True)

    def session(name, ts):
        entry = _user("hello")
        entry["timestamp"] = ts
        entry["sessionId"] = name
        with open(project_dir / f"{name}.jsonl", "w") as f:
            f.write(json.dumps(entry) + "\n")

    session("pre-window", "2026-07-01T00:00:00Z")
    session("post-window", "2026-07-03T08:00:00Z")

    data_dir = tmp_path / "lore-data"
    data_dir.mkdir()
    (data_dir / "scripts").symlink_to(os.path.join(_REPO_DIR, "scripts"))

    patterns_path = tmp_path / "patterns.json"
    patterns_path.write_text(json.dumps(PATTERNS))

    env = dict(os.environ)
    env.update({
        "HOME": str(home),
        "LORE_FRAMEWORK": "claude-code",
        "LORE_DATA_DIR": str(data_dir),
    })
    result = subprocess.run(
        [sys.executable, _HARNESS_PATH, "--patterns", str(patterns_path),
         "--framework", "claude-code", "--cwd", cwd,
         "--until", "2026-07-03T07:23:54Z"],
        capture_output=True, text=True, env=env,
    )
    assert result.returncode == 0, result.stderr
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    assert [r["session_id"] for r in rows] == ["pre-window"]
    assert rows[0]["session_start_utc"] == "2026-07-01T00:00:00+00:00"
    assert "1 outside window" in result.stderr


# ---------------------------------------------------------------------------
# Degraded-provider contract (canonical consumer behavior)
# ---------------------------------------------------------------------------

def _run_harness(tmp_path, framework, extra_env=None):
    patterns_path = tmp_path / "patterns.json"
    patterns_path.write_text(json.dumps(PATTERNS))
    env = dict(os.environ)
    env["LORE_FRAMEWORK"] = framework
    env.update(extra_env or {})
    return subprocess.run(
        [sys.executable, _HARNESS_PATH, "--patterns", str(patterns_path),
         "--framework", framework, "--cwd", str(tmp_path)],
        capture_output=True, text=True, env=env,
    )


def test_unknown_framework_exits_zero_with_degraded_notice(tmp_path):
    result = _run_harness(tmp_path, "unknown-harness")
    assert result.returncode == 0
    assert "transcript_provider=unavailable" in result.stderr


def test_partial_provider_emits_notice_and_exits_zero(tmp_path):
    # opencode is partial with list_session_paths unavailable → notice + clean exit.
    result = _run_harness(
        tmp_path, "opencode", extra_env={"LORE_DATA_DIR": str(tmp_path)}
    )
    assert result.returncode == 0
    assert "transcript_provider=partial" in result.stderr
    assert "Traceback" not in result.stderr
