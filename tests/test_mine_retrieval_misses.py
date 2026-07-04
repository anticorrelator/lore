"""Tests for mine-retrieval-misses.py — miss→derivation pairing and join audit.

Exercises mine_session() with a duck-typed provider over synthetic
transcripts and retrieval-log rows: the timestamp+query join (matched /
unmatched / ambiguous), miss detection across enriched and legacy rows,
sidechain filtering, and candidate emission in the /remember Step 0a format.
Also covers the packet-verdict candidate source: missing[] gap extraction,
not-assessable and malformed handling, and packet-scoped idempotent filenames.
"""

import importlib.util
import json
import sys
from pathlib import Path

_scripts_dir = Path(__file__).resolve().parent.parent / "scripts"
if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

_spec = importlib.util.spec_from_file_location(
    "mine_retrieval_misses", _scripts_dir / "mine-retrieval-misses.py"
)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

import transcript as transcript_module


class FakeProvider:
    """Duck-typed provider over scripts/transcript.py parsers."""

    def read_raw_lines(self, path):
        with open(path, encoding="utf-8") as f:
            return f.readlines()

    def parse_transcript(self, path):
        return transcript_module.parse_transcript(path)

    def extract_file_paths(self, path):
        return transcript_module.extract_file_paths(path)

    def session_metadata(self, path):
        return {"session_id": "sess-test", "session_date": None}


def assistant_line(ts, blocks, sidechain=False):
    return json.dumps({
        "type": "assistant",
        "timestamp": ts,
        "isSidechain": sidechain,
        "message": {"role": "assistant", "content": blocks},
    })


def bash_block(command):
    return {"type": "tool_use", "name": "Bash", "input": {"command": command}}


def tool_block(name, **inputs):
    return {"type": "tool_use", "name": name, "input": inputs}


def write_transcript(tmp_path, lines):
    p = tmp_path / "session.jsonl"
    p.write_text("\n".join(lines) + "\n")
    return str(p)


def log_index_from_rows(rows):
    index = {}
    for row in rows:
        ts = _mod.parse_ts(row["timestamp"])
        index.setdefault(row["query"], []).append((ts, row))
    return index


# 12:00:00Z == 08:00:00-0400; log rows land a few seconds after the call.
SEARCH_TS = "2026-07-01T12:00:00.000Z"

MISS_ROW = {
    "timestamp": "2026-07-01T08:00:03-0400",
    "event": "search",
    "query": "widget frobnication",
    "result_count": 0,
    "top_score": None,
    "miss": True,
}


def transcript_with_miss_and_derivation(tmp_path):
    return write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication" --scale-set subsystem --json')]),
        assistant_line("2026-07-01T12:00:30.000Z", [tool_block("Grep", pattern="frobnicate")]),
        assistant_line("2026-07-01T12:00:45.000Z", [tool_block("Read", file_path="/src/widget.py")]),
    ])


def test_miss_with_derivation_emits_candidate(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["retrieval_calls"] == 1
    assert metrics["matched"] == 1
    assert metrics["misses"] == 1
    assert metrics["miss_rows_paired"] == 1
    assert len(candidates) == 1
    filename, text = candidates[0]
    assert filename.endswith(".md")
    assert "**Trigger:** retrieval-miss" in text
    assert "**Query:** widget frobnication" in text
    assert "**Related files:** /src/widget.py" in text
    assert "Grep x1" in text and "Read x1" in text
    assert "**Evaluate:**" in text and "**Synthesis check:**" in text


def test_candidate_filename_is_idempotent(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    patterns = _mod.load_event_patterns()
    index = log_index_from_rows([MISS_ROW])
    first, _ = _mod.mine_session(FakeProvider(), path, index, patterns)
    second, _ = _mod.mine_session(FakeProvider(), path, index, patterns)
    assert first[0][0] == second[0][0]


def test_legacy_row_without_miss_field_uses_result_count(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    legacy = {
        "timestamp": "2026-07-01T08:00:03-0400",
        "event": "search",
        "query": "widget frobnication",
        "result_count": 0,
    }
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([legacy]), _mod.load_event_patterns()
    )
    assert metrics["misses"] == 1
    assert len(candidates) == 1


def test_hit_row_produces_no_candidate(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    hit = dict(MISS_ROW, result_count=5, top_score=-2.5, miss=False)
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([hit]), _mod.load_event_patterns()
    )
    assert metrics["matched"] == 1
    assert metrics["misses"] == 0
    assert candidates == []


def test_ambiguous_join_is_quarantined(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    twin = dict(MISS_ROW, timestamp="2026-07-01T08:00:09-0400")
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW, twin]), _mod.load_event_patterns()
    )
    assert metrics["ambiguous"] == 1
    assert metrics["matched"] == 0
    assert candidates == []


def test_pool_fanout_pair_matches_as_one_invocation(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    work_row = dict(MISS_ROW, source_type="work")
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW, work_row]), _mod.load_event_patterns()
    )
    assert metrics["ambiguous"] == 0
    assert metrics["matched"] == 1
    assert metrics["misses"] == 1
    assert len(candidates) == 1
    assert "2 search pool(s)" in candidates[0][1]


def test_pool_fanout_partial_hit_is_not_a_miss(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    work_hit = dict(MISS_ROW, source_type="work", result_count=4, top_score=-1.5, miss=False)
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW, work_hit]), _mod.load_event_patterns()
    )
    assert metrics["matched"] == 1
    assert metrics["misses"] == 0
    assert candidates == []


def test_unmatched_call_is_counted(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([]), _mod.load_event_patterns()
    )
    assert metrics["unmatched"] == 1
    assert metrics["matched"] == 0
    assert candidates == []


def test_out_of_window_row_is_unmatched(tmp_path):
    path = transcript_with_miss_and_derivation(tmp_path)
    stale = dict(MISS_ROW, timestamp="2026-07-01T09:30:00-0400")
    _, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([stale]), _mod.load_event_patterns()
    )
    assert metrics["unmatched"] == 1


def test_sidechain_search_and_derivation_are_ignored(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication"')], sidechain=True),
        assistant_line("2026-07-01T12:00:30.000Z", [tool_block("Grep", pattern="x")], sidechain=True),
    ])
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["retrieval_calls"] == 0
    assert candidates == []


def test_miss_without_derivation_is_not_paired(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication"')]),
        assistant_line("2026-07-01T12:00:30.000Z", [{"type": "text", "text": "done"}]),
    ])
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["misses"] == 1
    assert metrics["miss_rows_paired"] == 0
    assert candidates == []


def test_explore_agent_counts_as_derivation(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication"')]),
        assistant_line(
            "2026-07-01T12:00:30.000Z",
            [tool_block("Task", subagent_type="Explore", prompt="find frobnication")],
        ),
    ])
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["miss_rows_paired"] == 1
    assert "Task(Explore) x1" in candidates[0][1]


def test_non_explore_agent_is_not_derivation(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication"')]),
        assistant_line(
            "2026-07-01T12:00:30.000Z",
            [tool_block("Task", subagent_type="statusline-setup", prompt="x")],
        ),
    ])
    candidates, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["miss_rows_paired"] == 0
    assert candidates == []


def test_prefetch_calls_counted_but_not_joined(tmp_path):
    path = write_transcript(tmp_path, [
        assistant_line(SEARCH_TS, [bash_block('lore prefetch "widget frobnication" --scale-set subsystem')]),
    ])
    _, metrics = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    assert metrics["prefetch_calls"] == 1
    assert metrics["retrieval_calls"] == 0
    assert metrics["matched"] == 0


def test_load_log_index_skips_corrupt_rows(tmp_path):
    kdir = tmp_path / "kdir"
    (kdir / "_meta").mkdir(parents=True)
    (kdir / "_meta" / "retrieval-log.jsonl").write_text(
        json.dumps(MISS_ROW) + "\n"
        + "{not json\n"
        + json.dumps({"timestamp": "2026-07-01T08:00:00-0400", "event": "prefetch", "loaded_paths": []}) + "\n"
    )
    index, skipped = _mod.load_log_index(str(kdir))
    assert skipped == 1
    assert list(index) == ["widget frobnication"]


def test_select_sessions_bounds_and_spans():
    paths = [f"s{i}" for i in range(100)]
    picked = _mod.select_sessions(paths, 10)
    assert len(picked) == 10
    assert picked[0] == "s0"
    assert len(set(picked)) == 10
    assert _mod.select_sessions(paths[:5], 10) == paths[:5]


VERDICT = {
    "packet_id": "pkt-abc123",
    "session_id": "sess-test",
    "dispatch_confirmed": True,
    "unused": [],
    "harmful": [],
    "unattributed_retrieval": [],
    "missing": [
        {
            "query": "widget frobnication lifecycle",
            "evidence": "worker derived the lifecycle from source after the packet lacked it",
            "related_files": ["/src/widget.py"],
        },
    ],
}


def test_packet_missing_gap_emits_step0a_candidate():
    candidates, metrics = _mod.mine_packet_verdicts([VERDICT])
    assert metrics["verdicts"] == 1
    assert metrics["gaps"] == 1
    assert len(candidates) == 1
    filename, text = candidates[0]
    assert filename.endswith(".md")
    assert "**Trigger:** packet-gap" in text
    assert "**Query:** widget frobnication lifecycle" in text
    assert "**Session:** sess-test" in text
    assert "**Packet:** pkt-abc123" in text
    assert "**Related files:** /src/widget.py" in text
    assert "Assessor evidence: worker derived" in text
    assert "**Evaluate:**" in text and "**Synthesis check:**" in text


def test_packet_candidate_filename_is_idempotent_and_packet_scoped():
    first, _ = _mod.mine_packet_verdicts([VERDICT])
    second, _ = _mod.mine_packet_verdicts([json.loads(json.dumps(VERDICT))])
    assert first[0][0] == second[0][0]
    other_packet = dict(VERDICT, packet_id="pkt-def456")
    third, _ = _mod.mine_packet_verdicts([other_packet])
    assert third[0][0] != first[0][0]


def test_packet_missing_string_element_is_the_gap_text():
    verdict = dict(VERDICT, missing=["widget frobnication lifecycle"])
    candidates, metrics = _mod.mine_packet_verdicts([verdict])
    assert metrics["gaps"] == 1
    assert "**Query:** widget frobnication lifecycle" in candidates[0][1]
    assert "**Related files:** none" in candidates[0][1]


def test_packet_missing_null_is_not_assessable():
    verdict = dict(VERDICT, missing=None)
    candidates, metrics = _mod.mine_packet_verdicts([verdict])
    assert metrics["missing_not_assessable"] == 1
    assert candidates == []


def test_packet_missing_empty_list_emits_nothing():
    verdict = dict(VERDICT, missing=[])
    candidates, metrics = _mod.mine_packet_verdicts([verdict])
    assert metrics["verdicts"] == 1
    assert metrics["gaps"] == 0
    assert candidates == []


def test_packet_verdict_without_packet_id_is_skipped():
    verdict = {k: v for k, v in VERDICT.items() if k != "packet_id"}
    candidates, metrics = _mod.mine_packet_verdicts([verdict, "not a dict"])
    assert metrics["verdicts_skipped"] == 2
    assert candidates == []


def test_packet_gap_without_text_is_skipped():
    verdict = dict(VERDICT, missing=[{"severity": "high"}, ""])
    candidates, metrics = _mod.mine_packet_verdicts([verdict])
    assert metrics["gaps_skipped"] == 2
    assert candidates == []


def test_packet_missing_malformed_is_counted():
    verdict = dict(VERDICT, missing="not a list")
    candidates, metrics = _mod.mine_packet_verdicts([verdict])
    assert metrics["missing_malformed"] == 1
    assert candidates == []


def test_load_verdicts_accepts_object_array_and_jsonl(tmp_path):
    obj = tmp_path / "one.json"
    obj.write_text(json.dumps(VERDICT))
    verdicts, skipped = _mod.load_verdicts(str(obj))
    assert len(verdicts) == 1 and skipped == 0

    arr = tmp_path / "arr.json"
    arr.write_text(json.dumps([VERDICT, VERDICT]))
    verdicts, skipped = _mod.load_verdicts(str(arr))
    assert len(verdicts) == 2 and skipped == 0

    jsonl = tmp_path / "verdicts.jsonl"
    jsonl.write_text(json.dumps(VERDICT) + "\n{not json\n" + json.dumps(VERDICT) + "\n")
    verdicts, skipped = _mod.load_verdicts(str(jsonl))
    assert len(verdicts) == 2 and skipped == 1


def test_run_packet_verdicts_mode_writes_to_output_dir(tmp_path, capsys):
    import argparse
    verdict_file = tmp_path / "verdicts.jsonl"
    verdict_file.write_text(json.dumps(VERDICT) + "\n")
    out_dir = tmp_path / "out"
    args = argparse.Namespace(
        packet_verdicts=str(verdict_file), output_dir=str(out_dir),
        knowledge_dir=None, cwd=str(tmp_path),
    )
    _mod.run_packet_verdicts_mode(args)
    files = list(out_dir.glob("*.md"))
    assert len(files) == 1
    assert "**Trigger:** packet-gap" in files[0].read_text()
    err = capsys.readouterr().err
    assert "packet-verdicts" in err and "candidates_emitted=1" in err


def test_related_files_cap(tmp_path):
    lines = [assistant_line(SEARCH_TS, [bash_block('lore search "widget frobnication"')])]
    for i in range(12):
        lines.append(assistant_line(
            f"2026-07-01T12:00:{30 + i:02d}.000Z",
            [tool_block("Read", file_path=f"/src/f{i}.py")],
        ))
    path = write_transcript(tmp_path, lines)
    candidates, _ = _mod.mine_session(
        FakeProvider(), path, log_index_from_rows([MISS_ROW]), _mod.load_event_patterns()
    )
    related_line = next(
        line for line in candidates[0][1].splitlines()
        if line.startswith("**Related files:**")
    )
    assert len(related_line.split(",")) == _mod.RELATED_FILES_LIMIT
