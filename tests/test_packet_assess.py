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
