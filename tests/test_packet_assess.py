"""Tests for packet-assess.py — packet/transcript joins and verdict classes.

Exercises assess_transcript() with a duck-typed provider over synthetic
transcripts, packet rows, and retrieval-log rows: session-id and Packet-id
marker joins, window-only unconfirmed rows, unused/harmful detection,
missing-gap emission in the miner's object-field contract, unattributed
retrieval classification, hook-mode state dedupe, and the adapter handoffs
(assessments.jsonl append via the sole writer; _pending_captures/ via the
miner).
"""

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

_scripts_dir = Path(__file__).resolve().parent.parent / "scripts"
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

_spec = importlib.util.spec_from_file_location(
    "packet_assess", _scripts_dir / "packet-assess.py"
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

import packet_schema
import transcript as transcript_module

HEX64 = "0" * 64
SESSION_ID = "sess-test"
# Transcript timestamps are Z-form; packets/log rows land inside the window.
T0 = "2026-07-01T12:00:00.000Z"
T1 = "2026-07-01T12:00:30.000Z"
T2 = "2026-07-01T12:01:00.000Z"


class FakeProvider:
    def __init__(self, session_id=SESSION_ID, prev_path=None):
        self._session_id = session_id
        self._prev_path = prev_path

    def read_raw_lines(self, path):
        with open(path, encoding="utf-8") as f:
            return f.readlines()

    def parse_transcript(self, path):
        return transcript_module.parse_transcript(path)

    def extract_file_paths(self, path):
        return transcript_module.extract_file_paths(path)

    def session_metadata(self, path):
        return {"session_id": self._session_id, "session_date": None}

    def previous_session_path(self, cwd):
        return self._prev_path


def assistant_line(ts, blocks, sidechain=False):
    return json.dumps({
        "type": "assistant",
        "timestamp": ts,
        "isSidechain": sidechain,
        "message": {"role": "assistant", "content": blocks},
    })


def text_block(text):
    return {"type": "text", "text": text}


def bash_block(command):
    return {"type": "tool_use", "name": "Bash", "input": {"command": command}}


def tool_block(name, **inputs):
    return {"type": "tool_use", "name": name, "input": inputs}


def write_transcript(tmp_path, lines, name="session.jsonl"):
    p = tmp_path / name
    p.write_text("\n".join(lines) + "\n")
    return str(p)


def delivered_entry(path, render_mode="full"):
    return {
        "path": path,
        "render_mode": render_mode,
        "ranking_path": "composite-rerank",
        "trust": {
            "score": None,
            "status": "current",
            "confidence": "unaudited",
            "correction_recency": None,
        },
    }


def packet_row(packet_id, scope="session", session_id=SESSION_ID, task_id=None,
               entries=None, delivered_at="2026-07-01T12:00:01Z"):
    row = {
        "packet_id": packet_id,
        "packet_scope": scope,
        "delivery_stage": "assembled",
        "session_id": session_id if scope == "session" else None,
        "work_item": None,
        "phase": None,
        "task_id": task_id,
        "arm": None,
        "task_scale_set": None,
        "delivered_entries": entries if entries is not None else [
            delivered_entry("conventions/used-entry.md"),
            delivered_entry("conventions/dusty-entry.md"),
        ],
        "budget": {"chars_used": 100, "chars_budget": 1000},
        "delivered_at": delivered_at,
        "trust_compute_sha": HEX64,
        "template_version": None,
        "schema_version": "1",
        "packet_schema_sha": HEX64,
        "model": "test-model",
        "captured_at_branch": None,
        "captured_at_sha": None,
        "captured_at_merge_base_sha": None,
    }
    if not row["delivered_entries"]:
        row["empty_reason"] = "test packet with no entries"
    return row


def make_kdir(tmp_path, packets, log_rows=()):
    kdir = tmp_path / "kdir"
    (kdir / "_packets").mkdir(parents=True)
    (kdir / "_meta").mkdir()
    (kdir / "_manifest.json").write_text("{}")
    rows = [json.dumps(p) for p in packets]
    (kdir / "_packets" / "packets.jsonl").write_text(
        "\n".join(rows) + ("\n" if rows else "")
    )
    if log_rows:
        (kdir / "_meta" / "retrieval-log.jsonl").write_text(
            "\n".join(json.dumps(r) for r in log_rows) + "\n"
        )
    return str(kdir)


def by_id(verdicts):
    return {v["packet_id"]: v for v in verdicts}


# --- session-scope join, unused, harmful ------------------------------------

def basic_transcript(tmp_path, extra_lines=()):
    lines = [
        assistant_line(T0, [text_block(
            "Per conventions/used-entry.md the appender validates first."
        )]),
        *extra_lines,
    ]
    return write_transcript(tmp_path, lines)


def test_session_packet_unused_and_dispatch_confirmed(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert len(verdicts) == 1
    v = verdicts[0]
    assert v["dispatch_confirmed"] is True
    assert v["session_id"] == SESSION_ID
    assert v["source_transcript"] == path
    assert len(v["assessor_schema_sha"]) == 64
    unused_paths = [u["path"] for u in v["unused"]]
    assert unused_paths == ["conventions/dusty-entry.md"]
    assert v["harmful"] == []
    assert metrics["unused_findings"] == 1
    assert metrics["dispatch_confirmed"] == 1


def test_suffixless_reference_counts_as_use(tmp_path):
    # Historical mixed form: references may omit the .md suffix.
    path = write_transcript(tmp_path, [
        assistant_line(T0, [text_block("see conventions/used-entry for why")]),
    ])
    kdir = make_kdir(tmp_path, [packet_row(
        "pkt-aaa", entries=[delivered_entry("conventions/used-entry.md")]
    )])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert verdicts[0]["unused"] == []


def test_prefix_collision_is_not_a_reference(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(T0, [text_block("see conventions/used-entry-extended.md")]),
    ])
    kdir = make_kdir(tmp_path, [packet_row(
        "pkt-aaa", entries=[delivered_entry("conventions/used-entry.md")]
    )])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert [u["path"] for u in verdicts[0]["unused"]] == ["conventions/used-entry.md"]


def test_contradicted_verification_is_harmful(tmp_path):
    path = basic_transcript(tmp_path, [
        assistant_line(T1, [bash_block(
            "lore verify conventions/used-entry.md contradicted "
            "--rationale 'stale claim'"
        )]),
    ])
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    harmful = verdicts[0]["harmful"]
    assert [h["path"] for h in harmful] == ["conventions/used-entry.md"]
    assert metrics["harmful_findings"] == 1


def test_empty_delivery_assesses_clean(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa", entries=[])])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert verdicts[0]["unused"] == []
    assert verdicts[0]["harmful"] == []


# --- task-scope join --------------------------------------------------------

def test_task_packet_marker_confirms_and_sidechain_gates_usage(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(T0, [tool_block(
            "Task", prompt="Packet-id: pkt-task1\ndo the work",
        )]),
        assistant_line(T1, [text_block(
            "reading conventions/used-entry.md now"
        )], sidechain=True),
    ])
    kdir = make_kdir(tmp_path, [packet_row(
        "pkt-task1", scope="task", task_id="4",
    )])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    v = verdicts[0]
    assert v["dispatch_confirmed"] is True
    assert [u["path"] for u in v["unused"]] == ["conventions/dusty-entry.md"]
    # No session-scope carrier: retrieval classes not assessable, with reasons.
    assert v["missing"] is None
    assert "no confirmed session-scope packet" in v["missing_not_assessable_reason"]
    assert v["unattributed_retrieval"] is None


def test_task_packet_dispatch_prompt_is_not_usage(tmp_path):
    # The Task input carries the packet content; paths there must not count.
    path = write_transcript(tmp_path, [
        assistant_line(T0, [tool_block(
            "Task",
            prompt="Packet-id: pkt-task1\nknowledge: conventions/dusty-entry.md",
        )]),
        assistant_line(T1, [text_block("working")], sidechain=True),
    ])
    kdir = make_kdir(tmp_path, [packet_row(
        "pkt-task1", scope="task", task_id="4",
        entries=[delivered_entry("conventions/dusty-entry.md")],
    )])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert [u["path"] for u in verdicts[0]["unused"]] == ["conventions/dusty-entry.md"]


def test_task_packet_without_sidechain_worker_is_not_assessable(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(T0, [tool_block(
            "Agent", prompt="Packet-id: pkt-task1\ndo the work",
        )]),
    ])
    kdir = make_kdir(tmp_path, [packet_row("pkt-task1", scope="task", task_id="4")])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    v = verdicts[0]
    assert v["dispatch_confirmed"] is True
    assert v["unused"] is None
    assert "separate session" in v["unused_not_assessable_reason"]
    assert v["harmful"] is None


def test_window_only_join_is_unconfirmed_and_unassessable(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [
        packet_row("pkt-task1", scope="task", task_id="4"),  # no marker
        packet_row("pkt-anon", session_id="unknown"),
    ])
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert metrics["packets_joined"] == 2
    assert metrics["dispatch_confirmed"] == 0
    for v in verdicts:
        assert v["dispatch_confirmed"] is False
        assert v["not_assessable_reason"]
        for cls in packet_schema.VERDICT_CLASSES:
            assert v[cls] is None


def test_other_sessions_packet_does_not_join(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [
        packet_row("pkt-other", session_id="some-other-session"),
        packet_row("pkt-old", session_id="unknown",
                   delivered_at="2026-06-01T00:00:00Z"),
    ])
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert verdicts == []
    assert metrics["packets_joined"] == 0


def test_corrupt_packet_row_warned_and_excluded(tmp_path, capsys):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    with open(Path(kdir) / "_packets" / "packets.jsonl", "a") as f:
        f.write('{"packet_id": "pkt-bad"}\n')
        f.write("not json\n")
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert metrics["packets_corrupt"] == 2
    assert len(verdicts) == 1
    err = capsys.readouterr().err
    assert "packets.jsonl:2 corrupt" in err
    assert "packets.jsonl:3 corrupt" in err


# --- missing / unattributed ------------------------------------------------

MISS_ROW = {
    # 12:00:30Z == 08:00:30-0400; the log row lands seconds after the call.
    "timestamp": "2026-07-01T08:00:33-0400",
    "event": "search",
    "query": "widget frobnication",
    "result_count": 0,
    "top_score": None,
    "miss": True,
    "caller": "lead",
}


def test_missed_search_becomes_missing_gap_on_carrier(tmp_path):
    path = basic_transcript(tmp_path, [
        assistant_line(T1, [bash_block(
            'lore search "widget frobnication" --scale-set subsystem --json'
        )]),
    ])
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")], log_rows=[MISS_ROW])
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    v = verdicts[0]
    assert v["missing"] == [v["missing"][0]]
    gap = v["missing"][0]
    assert gap["query"] == "widget frobnication"  # miner's gap-text field contract
    assert "missed" in gap["evidence"]
    assert metrics["missing_gaps"] == 1
    # The matched call is attributed — not unattributed.
    assert v["unattributed_retrieval"] == []


def test_missing_gap_flows_through_miner_contract(tmp_path):
    path = basic_transcript(tmp_path, [
        assistant_line(T1, [bash_block('lore search "widget frobnication" --json')]),
    ])
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")], log_rows=[MISS_ROW])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    candidates, m = _mod.miner.mine_packet_verdicts(verdicts)
    assert m["gaps"] == 1
    assert m["gaps_skipped"] == 0
    filename, text = candidates[0]
    assert "**Trigger:** packet-gap" in text
    assert "**Query:** widget frobnication" in text


def test_unattributed_rows_classified_not_ignored(tmp_path):
    path = basic_transcript(tmp_path)
    log_rows = [
        # Agent-caller search with no transcript call -> unattributed.
        {"timestamp": "2026-07-01T08:00:10-0400", "event": "search",
         "query": "phantom topic", "result_count": 3, "miss": False,
         "caller": "worker-2"},
        # Callerless row: session-startup machinery -> attributed.
        {"timestamp": "2026-07-01T08:00:10-0400", "event": "search",
         "query": "startup relevance", "result_count": 5, "miss": False},
        # Machinery caller -> attributed.
        {"timestamp": "2026-07-01T08:00:10-0400", "event": "search",
         "query": "background", "result_count": 1, "miss": False,
         "caller": "lore-query"},
        # Outside the window -> ignored.
        {"timestamp": "2026-06-01T08:00:10-0400", "event": "search",
         "query": "ancient", "result_count": 0, "miss": True,
         "caller": "worker"},
        # Prefetch with agent caller, no transcript call -> unattributed.
        {"timestamp": "2026-07-01T08:00:20-0400", "event": "prefetch",
         "loaded_paths": [], "caller": "worker", "scale_declared": "subsystem"},
        # manifest_load matching a confirmed task packet -> attributed.
        {"timestamp": "2026-07-01T08:00:20-0400", "event": "manifest_load",
         "task_id": "4", "loaded_paths": []},
        # manifest_load for an unknown task -> unattributed.
        {"timestamp": "2026-07-01T08:00:20-0400", "event": "manifest_load",
         "task_id": "99", "loaded_paths": []},
    ]
    lines_extra = [
        assistant_line(T1, [tool_block(
            "Task", prompt="Packet-id: pkt-task1\ngo",
        )]),
        assistant_line(T2, [text_block("done")], sidechain=True),
    ]
    path = basic_transcript(tmp_path, lines_extra)
    kdir = make_kdir(
        tmp_path,
        [packet_row("pkt-aaa"), packet_row("pkt-task1", scope="task", task_id="4")],
        log_rows=log_rows,
    )
    verdicts, metrics = _mod.assess_transcript(FakeProvider(), path, kdir)
    carrier = by_id(verdicts)["pkt-aaa"]
    events = sorted(
        (u["event"], u.get("caller") or u.get("task_id"))
        for u in carrier["unattributed_retrieval"]
    )
    assert events == [
        ("manifest_load", "99"), ("prefetch", "worker"), ("search", "worker-2"),
    ]
    assert metrics["unattributed_rows"] == 3
    task_v = by_id(verdicts)["pkt-task1"]
    assert task_v["unattributed_retrieval"] is None
    assert "pkt-aaa" in task_v["unattributed_retrieval_not_assessable_reason"]


def test_sidechain_worker_search_is_attributed(tmp_path):
    # extract_retrieval_calls (miner) skips sidechains, but attribution
    # must see worker searches so they are not misclassified.
    path = write_transcript(tmp_path, [
        assistant_line(T0, [text_block("lead text")]),
        assistant_line(T1, [bash_block(
            'lore search "widget frobnication" --caller worker --json'
        )], sidechain=True),
    ])
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")], log_rows=[
        {**MISS_ROW, "caller": "worker"},
    ])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    v = verdicts[0]
    assert v["unattributed_retrieval"] == []
    # Sidechain calls do not feed missing[] (miner semantics preserved).
    assert v["missing"] == []


# --- verdict rows validate and append through the sole writer ---------------

def test_verdicts_pass_assessment_schema_after_writer_stamps(tmp_path):
    path = basic_transcript(tmp_path, [
        assistant_line(T1, [bash_block('lore search "widget frobnication" --json')]),
    ])
    kdir = make_kdir(
        tmp_path,
        [packet_row("pkt-aaa"),
         packet_row("pkt-task1", scope="task", task_id="4"),
         packet_row("pkt-anon", session_id="unknown")],
        log_rows=[MISS_ROW],
    )
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    assert len(verdicts) == 3
    for v in verdicts:
        stamped = {
            **v,
            "schema_version": "1",
            "packet_schema_sha": HEX64,
            "model": "test-model",
            "assessed_at": "2026-07-01T12:05:00Z",
            "captured_at_branch": None,
            "captured_at_sha": None,
            "captured_at_merge_base_sha": None,
        }
        assert packet_schema.validate_assessment_row(stamped) == []


def test_append_assessments_via_sole_writer(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    appended, failures = _mod.append_assessments(verdicts, kdir)
    assert (appended, failures) == (1, 0)
    rows_file = Path(kdir) / "_packets" / "assessments.jsonl"
    rows = [json.loads(l) for l in rows_file.read_text().splitlines()]
    assert len(rows) == 1
    assert rows[0]["packet_id"] == "pkt-aaa"
    assert rows[0]["dispatch_confirmed"] is True
    assert packet_schema.validate_assessment_row(rows[0]) == []


def test_miner_handoff_writes_pending_capture(tmp_path):
    verdicts = [{
        "packet_id": "pkt-aaa",
        "session_id": SESSION_ID,
        "missing": [{"query": "widget frobnication", "evidence": "missed"}],
    }]
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    assert _mod.handoff_to_miner(verdicts, kdir, cwd=str(tmp_path)) is True
    pending = list((Path(kdir) / "_pending_captures").glob("*.md"))
    assert len(pending) == 1
    text = pending[0].read_text()
    assert "**Trigger:** packet-gap" in text
    assert "**Query:** widget frobnication" in text


# --- hook mode: dedupe and no-write discipline -------------------------------

def test_hook_mode_dedupes_by_state_file(tmp_path, monkeypatch):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    provider = FakeProvider(prev_path=path)
    monkeypatch.setattr(_mod.miner, "resolve_gated_provider",
                        lambda *a, **k: provider)

    args = type("A", (), {
        "knowledge_dir": kdir, "cwd": str(tmp_path), "framework": None,
    })()
    _mod.run_hook_mode(args)

    rows_file = Path(kdir) / "_packets" / "assessments.jsonl"
    assert len(rows_file.read_text().splitlines()) == 1
    state = json.loads((Path(kdir) / "_meta" / "packet-assessor-state.json").read_text())
    assert "session.jsonl" in state["assessed"]

    # Re-run over the same session: no-op — no second row.
    _mod.run_hook_mode(args)
    assert len(rows_file.read_text().splitlines()) == 1


def test_hook_mode_skips_when_no_packets_file(tmp_path, monkeypatch):
    kdir = tmp_path / "kdir"
    (kdir / "_meta").mkdir(parents=True)
    (kdir / "_manifest.json").write_text("{}")
    called = []
    monkeypatch.setattr(_mod.miner, "resolve_gated_provider",
                        lambda *a, **k: called.append(1))
    args = type("A", (), {
        "knowledge_dir": str(kdir), "cwd": str(tmp_path), "framework": None,
    })()
    _mod.run_hook_mode(args)
    assert called == []
    assert not (kdir / "_meta" / "packet-assessor-state.json").exists()


def test_transcript_mode_is_pure(tmp_path, monkeypatch, capsys):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row("pkt-aaa")])
    provider = FakeProvider()
    monkeypatch.setattr(_mod.miner, "resolve_gated_provider",
                        lambda *a, **k: provider)
    args = type("A", (), {
        "knowledge_dir": kdir, "cwd": str(tmp_path), "framework": None,
        "transcript": path,
    })()
    _mod.run_transcript_mode(args)
    out = capsys.readouterr().out
    lines = [json.loads(l) for l in out.strip().splitlines()]
    assert len(lines) == 1 and lines[0]["packet_id"] == "pkt-aaa"
    # Pure runner: no state write, no assessment rows, no candidates.
    assert not (Path(kdir) / "_meta" / "packet-assessor-state.json").exists()
    assert not (Path(kdir) / "_packets" / "assessments.jsonl").exists()
    assert not (Path(kdir) / "_pending_captures").exists()


def test_mixed_packet_retries_keep_revision_identity_and_null_assessments(tmp_path):
    old = packet_row('legacy', scope='task', task_id='task-1')
    first = packet_row('first', scope='task', task_id='task-1')
    first.update(schema_version='2', work_item='fixture', revision_id='a' * 12,
                 dispatch_attempt_id='dispatch-first', source_head=None)
    retry = dict(first, packet_id='retry', dispatch_attempt_id='dispatch-retry')
    kdir = make_kdir(tmp_path, [old, first, retry])
    transcript = write_transcript(tmp_path, [
        assistant_line(T0, [text_block('Beginning.')]),
        assistant_line(T1, [text_block('Packet-id: first')]),
        assistant_line(T2, [text_block('Finished.')]),
    ])
    loaded, corrupt = _mod.load_packets(kdir)
    assert corrupt == 0 and len(loaded) == 3
    verdicts, stats = _mod.assess_transcript(FakeProvider(), transcript, kdir)
    rows = by_id(verdicts)
    assert rows['first']['dispatch_confirmed'] is True
    assert rows['retry']['dispatch_confirmed'] is False
    assert rows['first']['revision_id'] == rows['retry']['revision_id'] == 'a' * 12
    assert rows['first']['dispatch_attempt_id'] != rows['retry']['dispatch_attempt_id']
    assert 'revision_id' not in rows['legacy']
    assert all(rows['retry'][name] is None for name in packet_schema.VERDICT_CLASSES)
    assert rows['first']['missing'] is None
    assert rows['first']['unattributed_retrieval'] is None


# The retrospective reader consumes the actual writer schema, with a captured
# cycle membership snapshot instead of opening a second mutable work view.
_reader_spec = importlib.util.spec_from_file_location(
    'packet_assessments_read', _scripts_dir / 'packet-assessments-read.py')
_reader = importlib.util.module_from_spec(_reader_spec)
_reader_spec.loader.exec_module(_reader)


def summary_work(*ids, state='read'):
    return {'evidence': {'sources': {'packets': {'state': state}}, 'packet_summary': [
        {'packet_id': pid, 'delivery_stage': 'assembled', 'binding': {'state': 'current'},
         'receipt': 'unknown', 'synthesis': None} for pid in ids]}}


def assessment_row(pid='pkt-aaa', transcript='/private/transcript.jsonl', at=T1, **changes):
    return dict(packet_id=pid, source_transcript=transcript, assessed_at=at,
                schema_version='1', packet_schema_sha=HEX64, assessor_schema_sha=HEX64,
                model='test', captured_at_branch=None, captured_at_sha=None,
                captured_at_merge_base_sha=None, dispatch_confirmed=True,
                **{name: [] for name in packet_schema.VERDICT_CLASSES}) | changes


def assessment_summary(tmp_path, rows, work=None):
    ledger = tmp_path / '_packets/assessments.jsonl'
    ledger.parent.mkdir(exist_ok=True)
    ledger.write_text(''.join(json.dumps(row) + '\n' for row in rows))
    return _reader.read_summary(tmp_path, work or summary_work('pkt-aaa'), T0, T2)


def test_reader_real_assessor_writer_contract(tmp_path):
    path = basic_transcript(tmp_path)
    kdir = make_kdir(tmp_path, [packet_row('pkt-aaa')])
    verdicts, _ = _mod.assess_transcript(FakeProvider(), path, kdir)
    for row in verdicts:
        row['assessed_at'] = T1
    assert _mod.append_assessments(verdicts, kdir) == (1, 0)
    result = _reader.read_summary(kdir, summary_work('pkt-aaa'), T0, T2)
    assert result['status'] == 'available'
    summary = result['summary']
    assert summary['observations'] == summary['confirmed_observations'] == 1
    assert summary['classes']['missing']['findings'] == 0
    assert summary['classes']['unused']['findings'] == 1
    assert path not in json.dumps(result)


def test_reader_cycle_time_duplicate_and_transcript_selection(tmp_path):
    first = assessment_row(at=T0, harmful=[{'private': 'old finding'}])
    latest = assessment_row(at=T1, unused=[{'private': 'new finding'}])
    other = assessment_row(transcript='/private/second.jsonl', dispatch_confirmed=False,
                           **{k: None for k in packet_schema.VERDICT_CLASSES},
                           not_assessable_reason='dispatch-unconfirmed')
    end = assessment_row(at=T2, missing=[{'query': 'excluded at end'}])
    unrelated = assessment_row(pid='cycle-b', unused=[{}] * 10)
    result = assessment_summary(tmp_path, [first, latest, latest, other, end, unrelated])
    s = result['summary']
    assert s['observations'] == 2 and s['observed_packets'] == 1
    assert s['confirmed_observations'] == s['unconfirmed_observations'] == 1
    assert s['exact_duplicates_collapsed'] == s['superseded_observations'] == 1
    assert s['classes']['unused'] == {'assessable_observations': 1, 'findings': 1,
        'not_assessable_observations': 1, 'reason_counts': {'dispatch-unconfirmed': 1}}
    assert s['classes']['harmful']['findings'] == 0
    assert s['row_reason_counts'] == {'dispatch-unconfirmed': 1}
    assert s['packet_schema_hash_counts'] == {HEX64: 2}  # historical stamp accepted
    text = json.dumps(result)
    assert '/private/' not in text and 'new finding' not in text and 'excluded at end' not in text
    changed = assessment_summary(tmp_path, [first, latest, latest, other, end, unrelated,
                                          assessment_row(pid='cycle-c')])
    assert result == changed
    # A late observation outside this window does not replace the earlier one.
    changed = assessment_summary(tmp_path, [first, latest, latest, other, end, unrelated,
                                          assessment_row(at='2026-07-02T00:00:00Z')])
    assert result == changed


def test_reader_empty_missing_malformed_and_unreadable(tmp_path):
    missing = _reader.read_summary(tmp_path, summary_work('pkt-aaa'), T0, T2)
    assert missing['coverage'] == 'absent' and missing['summary'] is None
    empty = assessment_summary(tmp_path, [])
    assert empty['coverage'] == 'read' and empty['summary']['observations'] == 0
    assert empty['summary']['classes']['unused']['findings'] is None
    assert empty['summary']['packets_without_observations'] == ['pkt-aaa']
    ledger = tmp_path / '_packets/assessments.jsonl'
    ledger.write_text('{broken\n')
    bad = _reader.read_summary(tmp_path, summary_work('pkt-aaa'), T0, T2)
    assert bad['status'] == 'not-computable' and bad['summary'] is None
    assert bad['diagnostics'][0]['reason'] == 'malformed-json'
    ledger.unlink()
    ledger.mkdir()
    unreadable = _reader.read_summary(tmp_path, summary_work('pkt-aaa'), T0, T2)
    assert unreadable['coverage'] == 'unreadable' and unreadable['summary'] is None


def test_reader_invalid_schema_timestamp_and_unknown_membership(tmp_path):
    for changes in ({'packet_schema_sha': 'bad'}, {'dispatch_confirmed': None},
                    {'assessed_at': '2026-07-01'}, {'assessed_at': '2026-02-30T12:00:00Z'},
                    {'unused': None}, {'unused': None, 'unused_not_assessable_reason': {},
                                       'not_assessable_reason': 'unconfirmed',
                                       'harmful': None, 'missing': None, 'unattributed_retrieval': None}):
        result = assessment_summary(tmp_path, [assessment_row(**changes)])
        assert result['status'] == 'not-computable' and result['diagnostics']
    for state in ('absent', 'unreadable'):
        result = assessment_summary(tmp_path, [], summary_work(state=state))
        assert result['summary'] is None and result['membership']['state'] == 'unknown'
    assert _reader.packet_delivery(None)['values'] is None
    assert _reader.packet_delivery({'evidence': None})['status'] == 'not-computable'
    assert _reader.packet_delivery({'evidence': {'sources': {'packets': {'state': 'read'}}}})['values'] is None
    work = summary_work('pkt-aaa')
    work['evidence']['packet_summary'][0].update(binding={'state': []}, delivery_stage={}, receipt=[])
    assert _reader.packet_delivery(work)['values']['invalid_bindings'] == 1
    assert _reader.packet_delivery(summary_work())['values']['unique_packets'] == 0


def test_reader_null_classes_empty_arrays_and_content_identity(tmp_path):
    row = assessment_row(unused=None, unused_not_assessable_reason='no-body', missing=[{'query': 'private-a'}])
    result = assessment_summary(tmp_path, [row])
    classes = result['summary']['classes']
    assert classes['unused']['findings'] is None
    assert classes['unused']['reason_counts'] == {'no-body': 1}
    assert classes['harmful']['findings'] == 0
    assert classes['missing']['findings'] == 1
    changed = assessment_summary(tmp_path, [row | {'missing': [{'query': 'private-b'}]}])
    assert changed['content_identity'] != result['content_identity']
    assert changed['summary']['classes'] == classes


def test_packet_delivery_counts_keep_unknown_synthesis_and_invalid_binding(tmp_path):
    work = summary_work('assembled', 'synthesized', 'waived', 'receipt', 'unknown', 'invalid')
    rows = work['evidence']['packet_summary']
    rows[1].update(delivery_stage='synthesized', synthesis={'by': 'lead', 'kept': 2, 'dropped': 0, 'added': True})
    rows[2]['synthesis_waiver'] = {'by': 'lead', 'reason': 'empty candidates'}
    rows[3].update(delivery_stage='delivered', receipt='delivered')
    rows[4]['delivery_stage'] = 'future-state'
    rows[5].update(delivery_stage='synthesized', binding={'state': 'invalid'}, synthesis={'kept': 999, 'dropped': 999, 'added': 999})
    result = _reader.packet_delivery(work)['values']
    assert result['unique_packets'] == 6
    assert result['synthesized_packets'] == result['waivers'] == result['unknown_states'] == result['invalid_bindings'] == 1
    assert result['receipt_state_counts'] == {'unknown': 5, 'delivered': 1}
    assert result['synthesis_counts']['kept']['total'] == 2
    assert result['synthesis_counts']['dropped']['total'] == 0
    assert result['synthesis_counts']['added']['total'] is None
    assert result['synthesis_counts']['kept']['excluded_packets'] == 5
    assert result['synthesis_counts']['added']['exclusion_reasons']['invalid-count'] == 1
    # Latest-row semantics also protect a caller handing over repeated summaries.
    rows.append(rows[0] | {'delivery_stage': 'synthesized', 'synthesis': {'kept': 1, 'dropped': 0, 'added': 0}})
    assert _reader.packet_delivery(work)['values']['unique_packets'] == 6
    assert _reader.packet_delivery(work)['values']['synthesis_counts']['kept']['total'] == 3


def test_reader_boundaries_offsets_and_ties(tmp_path):
    included = assessment_row(at='2026-07-01T08:00:00-04:00')
    end = assessment_row(at='2026-07-01T08:01:00-04:00', harmful=[{}])
    before = assessment_row(at='2026-07-01T11:59:59.999999Z', missing=[{}])
    result = assessment_summary(tmp_path, [included, end, before])
    assert result['summary']['observations'] == 1
    assert result['summary']['classes']['harmful']['findings'] == 0
    replacement = included | {'harmful': [{}]}
    result = assessment_summary(tmp_path, [included, replacement])
    assert result['summary']['classes']['harmful']['findings'] == 1
