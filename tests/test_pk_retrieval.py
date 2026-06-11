"""Unit tests for pk_retrieval — the shared retrieval-core primitives
(dedupe, budget partitioning, block rendering, budget degradation)."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))

import pk_retrieval  # noqa: E402


# ---------------------------------------------------------------------------
# Entry-field access
# ---------------------------------------------------------------------------

def test_entry_path_prefers_path_over_file_path():
    assert pk_retrieval.entry_path({"path": "a.md", "file_path": "b.md"}) == "a.md"
    assert pk_retrieval.entry_path({"file_path": "b.md"}) == "b.md"
    assert pk_retrieval.entry_path({}) == ""


def test_entry_heading_prefers_heading_over_title():
    assert pk_retrieval.entry_heading({"heading": "H", "title": "T"}) == "H"
    assert pk_retrieval.entry_heading({"title": "T"}) == "T"
    assert pk_retrieval.entry_heading({}) == ""


def test_backlink_for_strips_md_and_renders_fragment():
    assert pk_retrieval.backlink_for("conventions/foo.md", "Bar") == "[[knowledge:conventions/foo#Bar]]"
    assert pk_retrieval.backlink_for("conventions/foo", None) == "[[knowledge:conventions/foo]]"
    assert pk_retrieval.backlink_for("conventions/foo.md", "") == "[[knowledge:conventions/foo]]"


# ---------------------------------------------------------------------------
# Dedupe
# ---------------------------------------------------------------------------

def test_dedupe_entries_preserves_order_and_drops_repeats():
    entries = [
        {"file_path": "a.md", "heading": "A"},
        {"file_path": "b.md", "heading": "B"},
        {"file_path": "a.md", "heading": "A"},
    ]
    out = pk_retrieval.dedupe_entries(entries)
    assert [e["heading"] for e in out] == ["A", "B"]


def test_dedupe_entries_shared_seen_set_spans_pools():
    seen = set()
    pool1 = pk_retrieval.dedupe_entries(
        [{"file_path": "a.md", "heading": "A"}], seen=seen)
    pool2 = pk_retrieval.dedupe_entries(
        [{"file_path": "a.md", "heading": "A"}, {"file_path": "c.md", "heading": "C"}], seen=seen)
    assert len(pool1) == 1
    assert [e["heading"] for e in pool2] == ["C"]


def test_dedupe_entries_path_key_drops_empty_paths():
    entries = [{"file_path": "", "heading": "X"}, {"file_path": "a.md", "heading": "A"}]
    out = pk_retrieval.dedupe_entries(entries, key_fn=pk_retrieval.entry_path)
    assert [e["heading"] for e in out] == ["A"]


def test_exclude_by_paths_matches_with_and_without_md():
    entries = [
        {"file_path": "conventions/a.md"},
        {"file_path": "conventions/b.md"},
        {"file_path": "gotchas/c.md"},
    ]
    exclude = pk_retrieval.path_exclusion_set(["conventions/a", "gotchas/c.md"])
    out = pk_retrieval.exclude_by_paths(entries, exclude)
    assert [e["file_path"] for e in out] == ["conventions/b.md"]


def test_exclude_by_paths_empty_set_is_noop():
    entries = [{"file_path": "a.md"}]
    assert pk_retrieval.exclude_by_paths(entries, set()) == entries


# ---------------------------------------------------------------------------
# Budget partitioning
# ---------------------------------------------------------------------------

def test_partition_two_tier_splits_on_cumulative_content_size():
    results = [
        {"heading": "A", "file_path": "a.md", "source_type": "knowledge",
         "category": "conventions", "composite_score": 0.9, "content": "x" * 60},
        {"heading": "B", "file_path": "b.md", "source_type": "knowledge",
         "category": None, "composite_score": 0.5, "content": "y" * 60},
    ]
    out = pk_retrieval.partition_two_tier(results, budget_chars=100)
    assert [e["heading"] for e in out["full"]] == ["A"]
    assert [e["heading"] for e in out["titles_only"]] == ["B"]
    assert out["budget_used"] == 60
    assert out["budget_total"] == 100
    # titles_only entries carry no content
    assert "content" not in out["titles_only"][0]
    assert out["titles_only"][0]["composite_score"] == 0.5


def test_partition_two_tier_skips_oversized_then_admits_smaller():
    results = [
        {"heading": "BIG", "file_path": "big.md", "content": "x" * 200},
        {"heading": "SMALL", "file_path": "small.md", "content": "y" * 50},
    ]
    out = pk_retrieval.partition_two_tier(results, budget_chars=100)
    assert [e["heading"] for e in out["full"]] == ["SMALL"]
    assert [e["heading"] for e in out["titles_only"]] == ["BIG"]


def test_budget_json_payload_exposes_composite_as_score():
    result = {
        "full": [{"heading": "A", "file_path": "a.md", "content": "c",
                  "composite_score": 0.7, "category": "gotchas", "snippet": "internal"}],
        "titles_only": [{"heading": "B", "file_path": "b.md", "composite_score": 0.2,
                         "category": None}],
        "budget_used": 1,
        "budget_total": 10,
    }
    payload = pk_retrieval.budget_json_payload(result)
    assert payload["full"] == [{"heading": "A", "file_path": "a.md", "content": "c",
                                "score": 0.7, "category": "gotchas"}]
    assert payload["titles_only"] == [{"heading": "B", "file_path": "b.md",
                                       "score": 0.2, "category": None}]
    assert payload["budget_used"] == 1
    assert payload["budget_total"] == 10


# ---------------------------------------------------------------------------
# Budget degradation
# ---------------------------------------------------------------------------

def _renderers():
    return (
        lambda item: "F" * item["full"],
        lambda item: "S" * item["snippet"],
        lambda item: "B" * item["backlink"],
    )


def test_emit_degrading_full_when_budget_allows():
    full, snippet, backlink = _renderers()
    items = [{"full": 10, "snippet": 5, "backlink": 2}] * 2
    blocks, remaining = pk_retrieval.emit_degrading(items, 100, full, snippet, backlink)
    assert blocks == ["F" * 10, "F" * 10]
    assert remaining == 80


def test_emit_degrading_steps_down_per_item():
    full, snippet, backlink = _renderers()
    items = [
        {"full": 10, "snippet": 5, "backlink": 2},
        {"full": 10, "snippet": 5, "backlink": 2},
        {"full": 10, "snippet": 5, "backlink": 2},
    ]
    # 10 fits, second full (10) doesn't fit in 8 -> snippet (5), third gets backlink (2)
    blocks, remaining = pk_retrieval.emit_degrading(items, 18, full, snippet, backlink)
    assert blocks == ["F" * 10, "S" * 5, "B" * 2]
    assert remaining == 1


def test_emit_degrading_stops_when_backlink_does_not_fit():
    full, snippet, backlink = _renderers()
    items = [
        {"full": 10, "snippet": 5, "backlink": 2},
        {"full": 10, "snippet": 8, "backlink": 6},
        {"full": 1, "snippet": 1, "backlink": 1},
    ]
    blocks, _ = pk_retrieval.emit_degrading(items, 15, full, snippet, backlink)
    # Second item: full(10)>5, snippet(8)>5, backlink(6)>5 -> stop entirely;
    # the third item is not emitted even though it would fit.
    assert blocks == ["F" * 10]


def test_degrade_section_under_budget_keeps_all_full():
    full, snippet, backlink = _renderers()
    cands = [{"full": 10, "snippet": 5, "backlink": 2}] * 2
    out = pk_retrieval.degrade_section(cands, budget=100, floor=1, header_chars=5,
                                       render_full=full, render_snippet=snippet,
                                       render_backlink=backlink)
    assert [m for _, m, _ in out["rendered_blocks"]] == ["full", "full"]
    assert out["content_degraded"] is False
    assert out["shrunk_for_budget"] is False


def test_degrade_section_steps_last_block_down_first():
    full, snippet, backlink = _renderers()
    cands = [{"full": 10, "snippet": 5, "backlink": 2}] * 3
    # header 0 + 30 full > 26: degrade from the back until it fits
    out = pk_retrieval.degrade_section(cands, budget=26, floor=1, header_chars=0,
                                       render_full=full, render_snippet=snippet,
                                       render_backlink=backlink)
    assert [m for _, m, _ in out["rendered_blocks"]] == ["full", "full", "snippet"]
    assert out["content_degraded"] is True
    assert out["shrunk_for_budget"] is False


def test_degrade_section_drops_entries_to_floor():
    full, snippet, backlink = _renderers()
    cands = [{"full": 10, "snippet": 5, "backlink": 4}] * 3
    # Even all-backlinks (12) exceeds 8: drop entries from the bottom to floor.
    out = pk_retrieval.degrade_section(cands, budget=8, floor=1, header_chars=0,
                                       render_full=full, render_snippet=snippet,
                                       render_backlink=backlink)
    assert len(out["rendered_blocks"]) == 2
    assert [m for _, m, _ in out["rendered_blocks"]] == ["backlink", "backlink"]
    assert out["shrunk_for_budget"] is True


def test_degrade_section_never_drops_below_floor():
    full, snippet, backlink = _renderers()
    cands = [{"full": 10, "snippet": 5, "backlink": 4}] * 3
    out = pk_retrieval.degrade_section(cands, budget=1, floor=3, header_chars=0,
                                       render_full=full, render_snippet=snippet,
                                       render_backlink=backlink)
    # Over budget but floor binds: all 3 stay, fully degraded.
    assert len(out["rendered_blocks"]) == 3
    assert [m for _, m, _ in out["rendered_blocks"]] == ["backlink"] * 3
