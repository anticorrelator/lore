"""Tests for parse_retrieval_log() in usage-analyze.py."""

import importlib.util
import json
import os


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

def test_returns_four_tuple_on_missing_file(tmp_path):
    result = parse_retrieval_log(str(tmp_path / "nonexistent.jsonl"))
    assert len(result) == 4
    session_events, search_events, per_entry_counts, manifest_load_events = result
    assert session_events == []
    assert search_events == []
    assert per_entry_counts == {}
    assert manifest_load_events == []


def test_returns_four_tuple_on_empty_log(tmp_path):
    log_file = tmp_path / "retrieval-log.jsonl"
    log_file.write_text("", encoding="utf-8")
    session_events, search_events, per_entry_counts, manifest_load_events = parse_retrieval_log(str(log_file))
    assert session_events == []
    assert search_events == []
    assert per_entry_counts == {}
    assert manifest_load_events == []


def test_per_entry_counts_is_plain_dict(tmp_path):
    log_path = write_log(tmp_path, [])
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
    assert isinstance(per_entry_counts, dict)


# ---------------------------------------------------------------------------
# Session events without loaded_paths (legacy format)
# ---------------------------------------------------------------------------

def test_session_events_no_loaded_paths_produces_empty_counts(tmp_path):
    records = [
        {"timestamp": "2026-01-01T00:00:00Z", "budget_used": 8000, "budget_total": 8000},
        {"timestamp": "2026-01-02T00:00:00Z", "budget_used": 6000, "budget_total": 8000},
    ]
    log_path = write_log(tmp_path, records)
    session_events, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    session_events, _, _, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, search_events, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    session_events, search_events, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
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
    _, _, per_entry_counts, _ = parse_retrieval_log(log_path)
    assert per_entry_counts == {"conventions/a.md": 1}


def test_malformed_json_lines_skipped(tmp_path):
    log_file = tmp_path / "retrieval-log.jsonl"
    log_file.write_text(
        '{"budget_used": 100, "budget_total": 8000, "loaded_paths": ["conventions/a.md"]}\n'
        'not valid json\n'
        '{"event": "prefetch", "loaded_paths": ["gotchas/b.md"]}\n',
        encoding="utf-8",
    )
    _, _, per_entry_counts, _ = parse_retrieval_log(str(log_file))
    assert per_entry_counts["conventions/a.md"] == 1
    assert per_entry_counts["gotchas/b.md"] == 1


# ---------------------------------------------------------------------------
# Epistemic-kind holds on the cold list
# ---------------------------------------------------------------------------

analyze_usage = usage_analyze.analyze_usage

UNTESTED = "conventions/untested-hypothesis.md"
FACT = "conventions/plain-fact.md"


def write_kind_store(tmp_path):
    """A store holding one untested hypothesis and one plain fact.

    The retrieval log records a single load of the hypothesis, so the report's
    per-entry counts come from loaded_paths rather than the FTS5 replay fallback,
    and a caller can tell a preserved count from a zeroed one.
    """
    conventions = tmp_path / "conventions"
    conventions.mkdir()
    (tmp_path / UNTESTED).write_text(
        "# Untested Hypothesis\n\nBody prose.\n"
        "<!-- learned: 2025-06-01 | confidence: medium | scale: subsystem "
        "| kind: hypothesis | kind_status: untested | status: current -->\n",
        encoding="utf-8",
    )
    (tmp_path / FACT).write_text(
        "# Plain Fact\n\nBody prose.\n"
        "<!-- learned: 2025-06-01 | confidence: high | scale: subsystem "
        "| kind: fact | status: current -->\n",
        encoding="utf-8",
    )
    meta = tmp_path / "_meta"
    meta.mkdir()
    (meta / "retrieval-log.jsonl").write_text(
        json.dumps({
            "timestamp": "2026-08-01T00:00:00Z",
            "budget_used": 100, "budget_total": 8000,
            "loaded_paths": [UNTESTED],
        }) + "\n",
        encoding="utf-8",
    )
    return str(tmp_path)


def test_unresolved_kind_held_out_of_the_cold_list(tmp_path):
    """The cold list feeds cleanup candidacy, so an unsettled entry is reported apart from it."""
    report = analyze_usage(write_kind_store(tmp_path), cold_threshold=1)

    assert FACT in report["cold_entries"]
    assert UNTESTED not in report["cold_entries"]
    assert [h["path"] for h in report["prune_holds"]["held"]] == [UNTESTED]
    assert report["prune_holds"]["registry_available"] is True
    assert report["summary"]["kind_held_count"] == 1
    assert report["summary"]["cold_entry_count"] == len(report["cold_entries"])


def test_held_entry_keeps_its_real_access_count(tmp_path):
    """Holding an entry back from cleanup must not hide it from staleness scoring.

    staleness-scan reads entry_access for its usage-freshness signal, so a held
    entry has to stay there carrying the count it actually earned.
    """
    report = analyze_usage(write_kind_store(tmp_path), cold_threshold=1)

    assert report["entry_access"][UNTESTED]["retrieval_count"] == 1
    assert report["entry_access"][FACT]["retrieval_count"] == 0
    assert report["summary"]["total_entries"] == 2


def test_unreadable_kind_registry_is_reported_not_assumed_empty(tmp_path, monkeypatch, capsys):
    """Losing the kind reader falls back to pre-kind behavior, and says so."""
    knowledge_dir = write_kind_store(tmp_path)
    monkeypatch.setattr(usage_analyze, "_load_kind_reader", lambda: None)

    report = analyze_usage(knowledge_dir, cold_threshold=1)

    assert report["prune_holds"]["registry_available"] is False
    assert report["prune_holds"]["held"] == []
    assert UNTESTED in report["cold_entries"]
    assert "kind registry unreadable" in capsys.readouterr().err
