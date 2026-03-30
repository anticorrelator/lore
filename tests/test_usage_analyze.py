"""Tests for parse_retrieval_log() in usage-analyze.py."""

import importlib.util
import json
import os

import pytest

# usage-analyze.py has a hyphen, so use importlib to load it
_SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts", "usage-analyze.py")
_spec = importlib.util.spec_from_file_location("usage_analyze", _SCRIPT_PATH)
usage_analyze = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(usage_analyze)

parse_retrieval_log = usage_analyze.parse_retrieval_log


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def write_log(tmp_path, records):
    """Write a list of dicts as JSONL to a retrieval-log.jsonl file."""
    log_file = tmp_path / "retrieval-log.jsonl"
    with open(log_file, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    return str(log_file)


# ---------------------------------------------------------------------------
# Return type and structure
# ---------------------------------------------------------------------------

def test_returns_three_tuple_on_missing_file(tmp_path):
    result = parse_retrieval_log(str(tmp_path / "nonexistent.jsonl"))
    assert len(result) == 3
    session_events, search_events, per_entry_counts = result
    assert session_events == []
    assert search_events == []
    assert per_entry_counts == {}


def test_returns_three_tuple_on_empty_log(tmp_path):
    log_file = tmp_path / "retrieval-log.jsonl"
    log_file.write_text("", encoding="utf-8")
    session_events, search_events, per_entry_counts = parse_retrieval_log(str(log_file))
    assert session_events == []
    assert search_events == []
    assert per_entry_counts == {}


def test_per_entry_counts_is_plain_dict(tmp_path):
    log_path = write_log(tmp_path, [])
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert type(per_entry_counts) is dict


# ---------------------------------------------------------------------------
# Session events without loaded_paths (legacy format)
# ---------------------------------------------------------------------------

def test_session_events_no_loaded_paths_produces_empty_counts(tmp_path):
    records = [
        {"timestamp": "2026-01-01T00:00:00Z", "budget_used": 8000, "budget_total": 8000},
        {"timestamp": "2026-01-02T00:00:00Z", "budget_used": 6000, "budget_total": 8000},
    ]
    log_path = write_log(tmp_path, records)
    session_events, _, per_entry_counts = parse_retrieval_log(log_path)
    assert len(session_events) == 2
    assert per_entry_counts == {}


# ---------------------------------------------------------------------------
# Session events with loaded_paths
# ---------------------------------------------------------------------------

def test_session_events_with_loaded_paths_counted(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": ["conventions/script-first.md", "architecture/layers.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts["conventions/script-first.md"] == 1
    assert per_entry_counts["architecture/layers.md"] == 1


def test_session_events_accumulate_across_sessions(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": ["conventions/script-first.md"],
        },
        {
            "timestamp": "2026-01-02T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": ["conventions/script-first.md", "architecture/layers.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts["conventions/script-first.md"] == 2
    assert per_entry_counts["architecture/layers.md"] == 1


# ---------------------------------------------------------------------------
# Prefetch events
# ---------------------------------------------------------------------------

def test_prefetch_events_counted(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/script-first.md", "gotchas/fts5-quoting.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts["conventions/script-first.md"] == 1
    assert per_entry_counts["gotchas/fts5-quoting.md"] == 1


def test_prefetch_events_accumulate(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/script-first.md"],
        },
        {
            "timestamp": "2026-01-02T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/script-first.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts["conventions/script-first.md"] == 2


def test_prefetch_events_not_included_in_session_events(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/script-first.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    session_events, _, _ = parse_retrieval_log(log_path)
    assert session_events == []


# ---------------------------------------------------------------------------
# Mixed events: session + prefetch + search accumulate together
# ---------------------------------------------------------------------------

def test_session_and_prefetch_counts_merged(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": ["conventions/script-first.md"],
        },
        {
            "timestamp": "2026-01-02T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/script-first.md", "architecture/layers.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts["conventions/script-first.md"] == 2
    assert per_entry_counts["architecture/layers.md"] == 1


def test_search_events_do_not_contribute_to_per_entry_counts(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "event": "search",
            "query": "script-first design",
            "result_count": 3,
            "elapsed_ms": 12.5,
        },
    ]
    log_path = write_log(tmp_path, records)
    _, search_events, per_entry_counts = parse_retrieval_log(log_path)
    assert len(search_events) == 1
    assert per_entry_counts == {}


def test_all_event_types_together(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": ["conventions/a.md"],
        },
        {
            "timestamp": "2026-01-01T01:00:00Z",
            "event": "search",
            "query": "some query",
            "result_count": 2,
        },
        {
            "timestamp": "2026-01-01T02:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["conventions/a.md", "gotchas/b.md"],
        },
    ]
    log_path = write_log(tmp_path, records)
    session_events, search_events, per_entry_counts = parse_retrieval_log(log_path)
    assert len(session_events) == 1
    assert len(search_events) == 1
    assert per_entry_counts == {"conventions/a.md": 2, "gotchas/b.md": 1}


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

def test_empty_loaded_paths_array_ignored(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "budget_used": 8000,
            "budget_total": 8000,
            "loaded_paths": [],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts == {}


def test_empty_string_paths_skipped(tmp_path):
    records = [
        {
            "timestamp": "2026-01-01T00:00:00Z",
            "event": "prefetch",
            "loaded_paths": ["", "conventions/a.md", ""],
        },
    ]
    log_path = write_log(tmp_path, records)
    _, _, per_entry_counts = parse_retrieval_log(log_path)
    assert per_entry_counts == {"conventions/a.md": 1}


def test_malformed_json_lines_skipped(tmp_path):
    log_file = tmp_path / "retrieval-log.jsonl"
    log_file.write_text(
        '{"budget_used": 100, "budget_total": 8000, "loaded_paths": ["conventions/a.md"]}\n'
        'not valid json\n'
        '{"event": "prefetch", "loaded_paths": ["gotchas/b.md"]}\n',
        encoding="utf-8",
    )
    _, _, per_entry_counts = parse_retrieval_log(str(log_file))
    assert per_entry_counts["conventions/a.md"] == 1
    assert per_entry_counts["gotchas/b.md"] == 1
