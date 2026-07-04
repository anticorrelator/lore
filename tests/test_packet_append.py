"""Tests for the `_packets/` substrate: packet_schema.py and the two sole writers.

Property-based with hand-rolled seeded generators (hypothesis is not a
dependency of this repo, matching tests/test_trust_compute.py): each property
runs against many randomly generated rows under explicit `random.Random(seed)`
instances.

Properties covered:
  - generated valid rows validate clean (packet and assessment kinds)
  - codec roundtrip: json.loads(json.dumps(row, ensure_ascii=False)) == row,
    one row is one line, and the roundtripped row still validates
  - schema-reject completeness: removing any required field (top-level and
    nested) is rejected with an error naming the field
  - cross-field invariants: scope/task_id coupling, empty_reason coupling,
    verdict-null/reason coupling, row-level not_assessable_reason coupling
  - writer integration: append exactly one compacted line, stamps applied,
    reject-before-disk leaves no file, append-supersede (two appends = two
    rows), non-ASCII content survives verbatim
"""

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

import pytest

_SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, _SCRIPTS_DIR)

import packet_schema as ps  # noqa: E402

PACKET_APPEND_SH = os.path.abspath(os.path.join(_SCRIPTS_DIR, "packet-append.sh"))
ASSESSMENT_APPEND_SH = os.path.abspath(
    os.path.join(_SCRIPTS_DIR, "packet-assessment-append.sh")
)

SEEDS = range(10)

_TEXT_POOL = (
    "conventions/foo.md",
    "gotchas/hÉllo — wörld.md",
    'principles/quotes "inside" and \\backslash\\.md',
    "architecture/tabs\tand spaces.md",
)
_STATUS_POOL = ("current", "historical", "superseded")
_CONFIDENCE_POOL = ("high", "medium", "unaudited")
_HEX = "0123456789abcdef"


def _hex(rng: random.Random, n: int) -> str:
    return "".join(rng.choice(_HEX) for _ in range(n))


def _gen_entry(rng: random.Random, uniq: int) -> dict:
    return {
        "path": f"{rng.choice(_TEXT_POOL)}-{uniq}",
        "render_mode": rng.choice(ps.RENDER_MODES),
        "ranking_path": rng.choice(ps.RANKING_PATHS),
        "trust": {
            "score": rng.choice([None, round(rng.uniform(-1, 1), 3), 0, 1]),
            "status": rng.choice(_STATUS_POOL),
            "confidence": rng.choice(_CONFIDENCE_POOL),
            "correction_recency": rng.choice([None, "2026-06-01"]),
        },
    }


def _gen_stamps(rng: random.Random) -> dict:
    return {
        "delivered_at": "2026-07-04T00:00:00Z",
        "schema_version": "1",
        "packet_schema_sha": _hex(rng, 64),
        "trust_compute_sha": _hex(rng, 64),
        "template_version": rng.choice([None, _hex(rng, 12)]),
        "model": rng.choice(["unrecorded", "claude-fable-5"]),
        "captured_at_branch": rng.choice([None, "main"]),
        "captured_at_sha": rng.choice([None, _hex(rng, 40)]),
        "captured_at_merge_base_sha": None,
    }


def gen_packet_row(rng: random.Random) -> dict:
    scope = rng.choice(ps.PACKET_SCOPES)
    entries = [_gen_entry(rng, i) for i in range(rng.randint(0, 5))]
    row = {
        "packet_id": f"pkt-{_hex(rng, 8)}",
        "packet_scope": scope,
        "delivery_stage": "assembled" if scope == "task" else "delivered",
        "session_id": rng.choice([None, f"sess-{_hex(rng, 6)}"]),
        "work_item": rng.choice([None, "context-packet-as-evaluable-delivery-unit"]),
        "phase": rng.choice([None, 1, "1"]),
        "task_id": f"task-{rng.randint(1, 9)}" if scope == "task" else None,
        "arm": rng.choice([None, "A", "B"]),
        "task_scale_set": rng.choice([None, "subsystem,implementation"]),
        "delivered_entries": entries,
        "budget": {
            "chars_used": rng.choice([None, rng.randint(0, 9000)]),
            "chars_budget": rng.choice([None, rng.randint(1, 9000)]),
        },
    }
    if not entries:
        row["empty_reason"] = "no entries above relevance floor"
    row.update(_gen_stamps(rng))
    return row


def gen_assessment_row(rng: random.Random) -> dict:
    row = {
        "packet_id": f"pkt-{_hex(rng, 8)}",
        "assessed_at": "2026-07-04T01:00:00Z",
        "assessor_schema_sha": _hex(rng, 64),
        "source_transcript": f"/sessions/{_hex(rng, 6)}.jsonl",
        "dispatch_confirmed": rng.choice([True, False]),
        "schema_version": "1",
        "packet_schema_sha": _hex(rng, 64),
        "model": "unrecorded",
        "captured_at_branch": rng.choice([None, "main"]),
        "captured_at_sha": None,
        "captured_at_merge_base_sha": None,
    }
    for cls in ps.VERDICT_CLASSES:
        if rng.random() < 0.25:
            row[cls] = None
            row[f"{cls}_not_assessable_reason"] = f"{cls} not derivable from transcript"
        else:
            row[cls] = [
                {"path": rng.choice(_TEXT_POOL), "rationale": "hÉllo — wörld"}
                for _ in range(rng.randint(0, 3))
            ]
    return row


# ---------------------------------------------------------------------------
# Generator validity + codec roundtrip
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", SEEDS)
def test_generated_packet_rows_validate_clean(seed):
    rng = random.Random(seed)
    for _ in range(20):
        row = gen_packet_row(rng)
        assert ps.validate_packet_row(row) == []


@pytest.mark.parametrize("seed", SEEDS)
def test_generated_assessment_rows_validate_clean(seed):
    rng = random.Random(seed)
    for _ in range(20):
        row = gen_assessment_row(rng)
        assert ps.validate_assessment_row(row) == []


@pytest.mark.parametrize("seed", SEEDS)
def test_codec_roundtrip(seed):
    """One row serializes to one line, roundtrips exactly, and stays valid."""
    rng = random.Random(seed)
    for gen, validate in (
        (gen_packet_row, ps.validate_packet_row),
        (gen_assessment_row, ps.validate_assessment_row),
    ):
        for _ in range(10):
            row = gen(rng)
            line = json.dumps(row, ensure_ascii=False)
            assert "\n" not in line
            parsed = json.loads(line)
            assert parsed == row
            assert validate(parsed) == []


def test_validator_rejects_non_objects():
    for bad in (None, [], "row", 3, True):
        assert ps.validate_packet_row(bad) == ["row must be a JSON object"]
        assert ps.validate_assessment_row(bad) == ["row must be a JSON object"]


# ---------------------------------------------------------------------------
# Schema-reject completeness
# ---------------------------------------------------------------------------

PACKET_TOP_LEVEL_REQUIRED = (
    "packet_id", "packet_scope", "delivery_stage", "session_id", "work_item",
    "phase", "task_id", "arm", "task_scale_set", "delivered_entries", "budget",
    "delivered_at", "schema_version", "packet_schema_sha", "trust_compute_sha",
    "template_version", "model", "captured_at_branch", "captured_at_sha",
    "captured_at_merge_base_sha",
)

ASSESSMENT_TOP_LEVEL_REQUIRED = (
    "packet_id", "assessed_at", "assessor_schema_sha", "source_transcript",
    "dispatch_confirmed", "unused", "harmful", "missing",
    "unattributed_retrieval", "schema_version", "packet_schema_sha", "model",
    "captured_at_branch", "captured_at_sha", "captured_at_merge_base_sha",
)


@pytest.mark.parametrize("seed", SEEDS)
@pytest.mark.parametrize("key", PACKET_TOP_LEVEL_REQUIRED)
def test_packet_reject_on_each_missing_field(seed, key):
    rng = random.Random(seed)
    row = gen_packet_row(rng)
    row.pop(key, None)
    errors = ps.validate_packet_row(row)
    assert errors, f"deleting {key} was not rejected"
    assert any(key.split(".")[-1] in e for e in errors), (key, errors)


@pytest.mark.parametrize("seed", SEEDS)
@pytest.mark.parametrize("key", ASSESSMENT_TOP_LEVEL_REQUIRED)
def test_assessment_reject_on_each_missing_field(seed, key):
    rng = random.Random(seed)
    row = gen_assessment_row(rng)
    # A missing verdict class is its own error even when a per-class reason
    # is present, so drop the companion reason to isolate the deletion.
    row.pop(f"{key}_not_assessable_reason", None)
    row.pop(key, None)
    errors = ps.validate_assessment_row(row)
    assert errors, f"deleting {key} was not rejected"
    assert any(key in e for e in errors), (key, errors)


@pytest.mark.parametrize("seed", SEEDS)
def test_packet_reject_on_missing_entry_fields(seed):
    rng = random.Random(seed)
    for key in ("path", "render_mode", "ranking_path", "trust"):
        row = gen_packet_row(rng)
        row["delivered_entries"] = [_gen_entry(rng, 0)]
        row.pop("empty_reason", None)
        del row["delivered_entries"][0][key]
        errors = ps.validate_packet_row(row)
        assert any(key in e for e in errors), (key, errors)
    for key in ("score", "status", "confidence", "correction_recency"):
        row = gen_packet_row(rng)
        row["delivered_entries"] = [_gen_entry(rng, 0)]
        row.pop("empty_reason", None)
        del row["delivered_entries"][0]["trust"][key]
        errors = ps.validate_packet_row(row)
        assert any(key in e for e in errors), (key, errors)


@pytest.mark.parametrize("seed", SEEDS)
def test_packet_reject_on_missing_budget_fields(seed):
    rng = random.Random(seed)
    for key in ("chars_used", "chars_budget"):
        row = gen_packet_row(rng)
        del row["budget"][key]
        errors = ps.validate_packet_row(row)
        assert any(key in e for e in errors), (key, errors)


@pytest.mark.parametrize("seed", SEEDS)
def test_packet_reject_on_bad_enums_and_types(seed):
    rng = random.Random(seed)
    corruptions = (
        ("packet_scope", "global"),
        ("delivery_stage", "handed-off"),
        ("schema_version", "2"),
        ("packet_schema_sha", "not-a-sha"),
        ("trust_compute_sha", "ABC"),
        ("template_version", "not-12-hex"),
        ("model", ""),
        ("budget", {"chars_used": True, "chars_budget": 100}),
        ("budget", {"chars_used": -1, "chars_budget": 100}),
        ("budget", {"chars_used": 0, "chars_budget": 0}),
        ("delivered_entries", "not-a-list"),
    )
    for key, bad in corruptions:
        row = gen_packet_row(rng)
        row[key] = bad
        assert ps.validate_packet_row(row), f"corrupting {key}={bad!r} was not rejected"


# ---------------------------------------------------------------------------
# Cross-field invariants
# ---------------------------------------------------------------------------

def _valid_task_row(rng):
    row = gen_packet_row(rng)
    row["packet_scope"] = "task"
    row["delivery_stage"] = "assembled"
    row["task_id"] = "task-1"
    return row


@pytest.mark.parametrize("seed", SEEDS)
def test_scope_task_id_coupling(seed):
    rng = random.Random(seed)

    row = _valid_task_row(rng)
    row["task_id"] = None
    assert any("task_id" in e for e in ps.validate_packet_row(row))

    row = _valid_task_row(rng)
    row["packet_scope"] = "session"
    assert any("task_id" in e for e in ps.validate_packet_row(row))


@pytest.mark.parametrize("seed", SEEDS)
def test_empty_entries_require_empty_reason(seed):
    rng = random.Random(seed)

    row = gen_packet_row(rng)
    row["delivered_entries"] = []
    row.pop("empty_reason", None)
    assert any("empty_reason" in e for e in ps.validate_packet_row(row))

    row["empty_reason"] = "no entries above relevance floor"
    assert ps.validate_packet_row(row) == []

    row["delivered_entries"] = [_gen_entry(rng, 0)]
    assert any("empty_reason" in e for e in ps.validate_packet_row(row))
    row["empty_reason"] = None
    assert ps.validate_packet_row(row) == []


@pytest.mark.parametrize("seed", SEEDS)
def test_null_verdict_class_requires_reason(seed):
    rng = random.Random(seed)

    row = gen_assessment_row(rng)
    row["harmful"] = None
    row.pop("harmful_not_assessable_reason", None)
    row.pop("not_assessable_reason", None)
    assert any("harmful_not_assessable_reason" in e for e in ps.validate_assessment_row(row))

    row["harmful_not_assessable_reason"] = "receiving agent produced no diff"
    assert ps.validate_assessment_row(row) == []


@pytest.mark.parametrize("seed", SEEDS)
def test_row_level_not_assessable_reason(seed):
    rng = random.Random(seed)

    row = gen_assessment_row(rng)
    row["not_assessable_reason"] = "transcript missing"
    for cls in ps.VERDICT_CLASSES:
        row[cls] = None
        row.pop(f"{cls}_not_assessable_reason", None)
    assert ps.validate_assessment_row(row) == []

    row["unused"] = []
    assert any("unused" in e for e in ps.validate_assessment_row(row))


# ---------------------------------------------------------------------------
# Writer integration (shell appenders)
# ---------------------------------------------------------------------------

pytestmark_shell = pytest.mark.skipif(
    shutil.which("jq") is None, reason="jq required for writer integration"
)


def _unstamped_packet_row(rng: random.Random) -> dict:
    row = gen_packet_row(rng)
    for key in (
        "delivered_at", "schema_version", "packet_schema_sha",
        "trust_compute_sha", "template_version", "model",
        "captured_at_branch", "captured_at_sha", "captured_at_merge_base_sha",
    ):
        row.pop(key, None)
    return row


@pytest.fixture()
def kdir(tmp_path):
    return str(tmp_path)


def _run_writer(script, row_json, kdir):
    return subprocess.run(
        ["bash", script, "--kdir", kdir],
        input=row_json,
        capture_output=True,
        text=True,
    )


@pytestmark_shell
def test_writer_appends_one_stamped_compact_line(kdir):
    rng = random.Random(0)
    row = _unstamped_packet_row(rng)
    result = _run_writer(PACKET_APPEND_SH, json.dumps(row, ensure_ascii=False), kdir)
    assert result.returncode == 0, result.stderr

    rows_file = os.path.join(kdir, "_packets", "packets.jsonl")
    with open(rows_file, encoding="utf-8") as fh:
        lines = fh.readlines()
    assert len(lines) == 1
    stored = json.loads(lines[0])
    assert ps.validate_packet_row(stored) == []
    assert stored["schema_version"] == "1"
    assert stored["packet_schema_sha"] == ps.schema_sha()
    assert stored["model"] == "unrecorded"
    assert stored["delivered_at"]
    assert stored["template_version"] is None
    assert len(stored["trust_compute_sha"]) == 64
    assert os.path.isfile(os.path.join(kdir, "_packets", "README.md"))


@pytestmark_shell
def test_writer_rejects_before_any_disk_touch(kdir):
    rng = random.Random(1)
    row = _unstamped_packet_row(rng)
    del row["budget"]
    result = _run_writer(PACKET_APPEND_SH, json.dumps(row), kdir)
    assert result.returncode != 0
    assert "budget" in result.stderr
    # Validation precedes directory creation: a rejected first append leaves
    # the store byte-identical, including no _packets/ dir.
    assert not os.path.exists(os.path.join(kdir, "_packets"))


@pytestmark_shell
def test_append_supersede_two_appends_two_rows(kdir):
    rng = random.Random(2)
    row_json = json.dumps(_unstamped_packet_row(rng), ensure_ascii=False)
    assert _run_writer(PACKET_APPEND_SH, row_json, kdir).returncode == 0
    assert _run_writer(PACKET_APPEND_SH, row_json, kdir).returncode == 0
    rows_file = os.path.join(kdir, "_packets", "packets.jsonl")
    with open(rows_file, encoding="utf-8") as fh:
        assert len(fh.readlines()) == 2


@pytestmark_shell
def test_non_ascii_content_survives_verbatim(kdir):
    rng = random.Random(3)
    row = _unstamped_packet_row(rng)
    row["delivered_entries"] = [_gen_entry(rng, 0)]
    row.pop("empty_reason", None)
    row["delivered_entries"][0]["path"] = "gotchas/hÉllo — wörld.md"
    result = _run_writer(PACKET_APPEND_SH, json.dumps(row, ensure_ascii=False), kdir)
    assert result.returncode == 0, result.stderr
    raw = open(
        os.path.join(kdir, "_packets", "packets.jsonl"), encoding="utf-8"
    ).read()
    # A judge later quotes packet content verbatim: printable Unicode must be
    # stored raw, not as \uXXXX escapes.
    assert "hÉllo — wörld" in raw
    assert "\\u" not in raw


@pytestmark_shell
def test_assessment_writer_roundtrip_and_reject(kdir):
    rng = random.Random(4)
    row = gen_assessment_row(rng)
    for key in (
        "schema_version", "packet_schema_sha", "model",
        "captured_at_branch", "captured_at_sha", "captured_at_merge_base_sha",
    ):
        row.pop(key, None)
    result = _run_writer(ASSESSMENT_APPEND_SH, json.dumps(row, ensure_ascii=False), kdir)
    assert result.returncode == 0, result.stderr
    rows_file = os.path.join(kdir, "_packets", "assessments.jsonl")
    with open(rows_file, encoding="utf-8") as fh:
        lines = fh.readlines()
    assert len(lines) == 1
    stored = json.loads(lines[0])
    assert ps.validate_assessment_row(stored) == []
    assert stored["packet_schema_sha"] == ps.schema_sha()

    bad = dict(row)
    bad["dispatch_confirmed"] = "yes"
    result = _run_writer(ASSESSMENT_APPEND_SH, json.dumps(bad, ensure_ascii=False), kdir)
    assert result.returncode != 0
    assert "dispatch_confirmed" in result.stderr
    with open(rows_file, encoding="utf-8") as fh:
        assert len(fh.readlines()) == 1
