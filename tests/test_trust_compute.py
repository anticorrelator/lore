"""Tests for trust-compute.py (the trust-ledger fold) and the pk_search trust integration.

The fold and codec tests are property-based with hand-rolled seeded generators
(hypothesis is not a dependency of this repo): each property runs against many
randomly generated ledgers under explicit `random.Random(seed)` instances, so
pytest-randomly's global reseeding cannot affect them.

Properties covered:
  - codec roundtrip: parse_ledger_line(serialize_row(row)) == row
  - fold order-independence across event permutations
  - fold idempotence under dedupe replay (rows + rows)
  - fold monotonicity under an added held event
  - event_id recomputation is byte-identical to the writer's (integration)
"""

import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys

import pytest

_SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, _SCRIPTS_DIR)

_spec = importlib.util.spec_from_file_location(
    "trust_compute", os.path.join(_SCRIPTS_DIR, "trust-compute.py")
)
tc = importlib.util.module_from_spec(_spec)
sys.modules["trust_compute"] = tc
_spec.loader.exec_module(tc)

from pk_search import Indexer, Searcher, render_trust_stamp  # noqa: E402

APPEND_SH = os.path.abspath(os.path.join(_SCRIPTS_DIR, "trust-event-append.sh"))

SEEDS = range(10)

_SOURCES = ("worker", "researcher", "spec-lead", "implement-lead", "drift-sweep", "audit")
_SNIPPET_POOL = (
    "import hashlib",
    'print("hÉllo — wörld")',
    "line one\nline two\ttabbed",
    'quotes "inside" and \\backslash\\',
    "  leading and trailing  ",
)


def _envelope(rng: random.Random, event: str, entry_path: str, payload: dict) -> dict:
    row = {
        "schema_version": "1",
        "event": event,
        "event_id": "",
        "entry_path": entry_path,
        "source": rng.choice(_SOURCES),
        "observed_at": "2026-07-03T00:00:00+0000",
        "captured_at_branch": rng.choice(["main", None]),
        "captured_at_sha": None,
        "captured_at_merge_base_sha": None,
        "payload": payload,
    }
    row["event_id"] = tc.compute_event_id(row)
    return row


def _gen_row(rng: random.Random, entry_pool: list[str], uniq: int) -> dict:
    """One random valid ledger row; `uniq` keeps dedupe bases distinct."""
    entry = rng.choice(entry_pool)
    kind = rng.choice(
        ("consumption-verification", "mechanical-check", "adjudication", "trust-confirmation")
    )
    if kind == "consumption-verification":
        payload = {
            "disposition": rng.choice(("held", "contradicted")),
            "file": f"/repo/src/file{uniq}.py",
            "line_range": f"{rng.randint(1, 500)}-{rng.randint(501, 999)}",
            "exact_snippet": rng.choice(_SNIPPET_POOL),
            "normalized_snippet_hash": "0" * 64,
        }
    elif kind == "trust-confirmation":
        payload = {
            "verdict": rng.choice(("held", "contradicted")),
            "sha": format(uniq, "07x"),
        }
    elif kind == "mechanical-check":
        payload = {
            "check_name": rng.choice(("drift-sweep", "anchor-check")),
            "target": f"target-{uniq}",
            "result": rng.choice(("pass", "fail", "error", "skip")),
            "run_id": f"run-{uniq}",
        }
    else:
        payload = {
            "claim_id": f"claim-{uniq}",
            "verdict": rng.choice(("confirmed", "rejected")),
            "template_id": "correctness-gate-assertion",
            "template_version": "abc123",
            "run_id": f"run-{uniq}",
        }
    return _envelope(rng, kind, entry, payload)


def _gen_migration(rng: random.Random, from_path: str, to_path: str) -> dict:
    payload = {
        "from_entry_path": from_path,
        "to_entry_path": to_path,
        "reason": rng.choice(("l3-supersede", "renormalize-restructure")),
    }
    return _envelope(rng, "provenance-migration", to_path, payload)


def _gen_ledger(rng: random.Random, n_rows: int = 40) -> list[dict]:
    entry_pool = [f"conventions/entry-{i}.md" for i in range(rng.randint(1, 6))]
    rows = [_gen_row(rng, entry_pool, uniq) for uniq in range(n_rows)]
    # Sprinkle a migration chain over a fraction of the ledgers
    if rng.random() < 0.5:
        rows.append(_gen_migration(rng, entry_pool[0], "conventions/moved-once.md"))
        if rng.random() < 0.5:
            rows.append(
                _gen_migration(rng, "conventions/moved-once.md", "conventions/moved-twice.md")
            )
    return rows


# ---------------------------------------------------------------------------
# Codec properties
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", SEEDS)
def test_codec_roundtrip(seed):
    """parse_ledger_line(serialize_row(row)) == row, and one row is one line."""
    rng = random.Random(seed)
    for row in _gen_ledger(rng):
        line = tc.serialize_row(row)
        assert "\n" not in line
        parsed, warning = tc.parse_ledger_line(line + "\n")
        assert warning is None
        assert parsed == row


def test_codec_rejects_garbage():
    for bad in ("not json", "[1, 2]", '"just a string"', "{truncated"):
        parsed, warning = tc.parse_ledger_line(bad)
        assert parsed is None
        assert warning is not None
    # Blank lines are skipped silently, not warned
    assert tc.parse_ledger_line("   \n") == (None, None)


# ---------------------------------------------------------------------------
# Fold properties
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("seed", SEEDS)
def test_fold_order_independent(seed):
    """Any permutation of the ledger folds to identical scores and warnings."""
    rng = random.Random(seed)
    rows = _gen_ledger(rng)
    baseline = tc.fold_rows(rows)
    for _ in range(3):
        shuffled = rows[:]
        rng.shuffle(shuffled)
        assert tc.fold_rows(shuffled) == baseline


@pytest.mark.parametrize("seed", SEEDS)
def test_fold_idempotent_under_replay(seed):
    """Replaying already-seen rows (event_id dedupe) never changes the fold."""
    rng = random.Random(seed)
    rows = _gen_ledger(rng)
    baseline = tc.fold_rows(rows)
    assert tc.fold_rows(rows + rows) == baseline
    resample = rng.sample(rows, k=rng.randint(1, len(rows)))
    assert tc.fold_rows(rows + resample) == baseline


@pytest.mark.parametrize("seed", SEEDS)
def test_fold_monotonic_under_added_held(seed):
    """A fresh held verification strictly raises the target entry's trust."""
    rng = random.Random(seed)
    rows = _gen_ledger(rng)
    scores, migrations, _ = tc.fold_rows(rows)
    target = rng.choice(sorted({r["entry_path"] for r in rows}))
    key, _ = tc.resolve_entry_key(target, migrations)
    before = scores[key]["score"] if key in scores else 0.0

    held = _envelope(
        rng,
        "consumption-verification",
        target,
        {
            "disposition": "held",
            "file": "/repo/src/fresh-anchor.py",
            "line_range": "1-2",
            "exact_snippet": "fresh",
            "normalized_snippet_hash": "1" * 64,
        },
    )
    new_scores, new_migrations, _ = tc.fold_rows(rows + [held])
    new_key, _ = tc.resolve_entry_key(target, new_migrations)
    assert new_scores[new_key]["score"] > before


def test_fold_score_shape():
    """Score stays in (-1, 1); unobserved entries are absent, not scored."""
    rng = random.Random(99)
    scores, _, _ = tc.fold_rows(_gen_ledger(rng, n_rows=80))
    for summary in scores.values():
        assert -1.0 < summary["score"] < 1.0
    assert tc.score_for_entry(scores, {}, "conventions/never-observed.md") is None


def test_confirm_verdicts_fold_at_half_grounded_weight():
    """trust-confirmation verdicts weigh +0.5 held / -1.0 contradicted."""
    rng = random.Random(11)
    entry = "conventions/confirmed.md"
    rows = [
        _envelope(rng, "trust-confirmation", entry, {"verdict": "held", "sha": "aaaaaa1"}),
        _envelope(rng, "trust-confirmation", entry, {"verdict": "held", "sha": "aaaaaa2"}),
        _envelope(rng, "trust-confirmation", entry, {"verdict": "contradicted", "sha": "bbbbbb1"}),
    ]
    scores, _, warnings = tc.fold_rows(rows)
    summary = scores[entry]
    assert summary["counts"]["confirm_held"] == 2
    assert summary["counts"]["confirm_contradicted"] == 1
    # 2*(+0.5) + 1*(-1.0) == 0.0 — a cheap confirmation is half a grounded one.
    assert summary["signal"] == 0.0
    assert warnings == []
    # And the published constants are exactly half their grounded counterparts.
    assert tc.WEIGHT_CONFIRM_HELD == tc.WEIGHT_HELD / 2
    assert tc.WEIGHT_CONFIRM_CONTRADICTED == tc.WEIGHT_CONTRADICTED / 2


def test_fold_excludes_malformed_with_warnings():
    rng = random.Random(7)
    good = _gen_row(rng, ["conventions/x.md"], 0)
    malformed = [
        {"event": "unknown-kind", "event_id": "e1", "entry_path": "a.md", "payload": {}},
        {"event": "mechanical-check", "entry_path": "a.md", "payload": {}},  # no event_id
        {"event": "adjudication", "event_id": "e2", "payload": {}},  # no entry_path
        {"event": "consumption-verification", "event_id": "e3", "entry_path": "a.md"},
    ]
    scores, _, warnings = tc.fold_rows([good] + malformed)
    assert len(warnings) == 4
    assert list(scores) == ["conventions/x.md"]


def test_missing_ledger_is_unobserved_not_error(tmp_path):
    scores, migrations, warnings = tc.compute_trust(str(tmp_path))
    assert scores == {} and migrations == {} and warnings == []


# ---------------------------------------------------------------------------
# Migration chains
# ---------------------------------------------------------------------------

def test_migration_chain_redirects_old_rows():
    rng = random.Random(3)
    old = "conventions/old.md"
    rows = [
        _gen_row(rng, [old], uniq) for uniq in range(5)
    ] + [
        _gen_migration(rng, old, "conventions/mid.md"),
        _gen_migration(rng, "conventions/mid.md", "conventions/new.md"),
    ]
    scores, migrations, warnings = tc.fold_rows(rows)
    assert list(scores) == ["conventions/new.md"]
    key, warning = tc.resolve_entry_key(old, migrations)
    assert key == "conventions/new.md" and warning is None
    assert warnings == []


def test_migration_loop_warns_without_rewriting():
    rng = random.Random(4)
    rows = [
        _gen_row(rng, ["a.md"], 0),
        _gen_migration(rng, "a.md", "b.md"),
        _gen_migration(rng, "b.md", "a.md"),
    ]
    scores, _, warnings = tc.fold_rows(rows)
    assert list(scores) == ["a.md"]  # rows stay under their recorded path
    assert any("loop" in w for w in warnings)


def test_migration_conflict_warns_and_drops_mapping():
    rng = random.Random(5)
    rows = [
        _gen_row(rng, ["a.md"], 0),
        _gen_migration(rng, "a.md", "b.md"),
        _gen_migration(rng, "a.md", "c.md"),
    ]
    scores, migrations, warnings = tc.fold_rows(rows)
    assert list(scores) == ["a.md"]
    assert "a.md" not in migrations
    assert any("conflicting" in w for w in warnings)


# ---------------------------------------------------------------------------
# event_id byte-identity with the writer (integration)
# ---------------------------------------------------------------------------

def _writer_available() -> bool:
    return shutil.which("jq") is not None and os.access(APPEND_SH, os.X_OK)


@pytest.mark.skipif(not _writer_available(), reason="jq or writer script unavailable")
@pytest.mark.parametrize("kind", ["consumption-verification", "mechanical-check", "adjudication", "provenance-migration", "trust-confirmation"])
def test_event_id_matches_writer(tmp_path, kind):
    """compute_event_id reproduces the writer's dedupe basis byte-identically."""
    kdir = tmp_path / "kd"
    (kdir / "conventions").mkdir(parents=True)
    (kdir / "conventions" / "e.md").write_text("# E\n", encoding="utf-8")
    common = ["bash", APPEND_SH, "--kdir", str(kdir), "--event", kind, "--source", "worker"]
    payload_flags = {
        "consumption-verification": [
            "--entry-path", "conventions/e.md", "--disposition", "held",
            "--file", "/tmp/x.py", "--line-range", "3-9",
            "--exact-snippet", 'snippet with "quotes" and — unicode',
        ],
        "mechanical-check": [
            "--entry-path", "conventions/e.md", "--check-name", "drift-sweep",
            "--target", "t1", "--result", "pass", "--run-id", "r1",
        ],
        "adjudication": [
            "--entry-path", "conventions/e.md", "--claim-id", "c1",
            "--verdict", "confirmed", "--template-id", "tmpl",
            "--template-version", "v1", "--run-id", "r1",
        ],
        "provenance-migration": [
            "--from-entry-path", "conventions/e.md",
            "--to-entry-path", "conventions/e2.md",
            "--reason", "renormalize-restructure",
        ],
        "trust-confirmation": [
            "--entry-path", "conventions/e.md", "--verdict", "held",
            "--sha", "a1b2c3d",
        ],
    }[kind]
    proc = subprocess.run(common + payload_flags, capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    ledger = kdir / "_trust" / "trust-events.jsonl"
    row = json.loads(ledger.read_text(encoding="utf-8").strip())
    assert tc.compute_event_id(row) == row["event_id"]
    # The writer also touches the rank-staleness marker on every append
    assert (kdir / "_trust" / ".rank-stale").exists()


# ---------------------------------------------------------------------------
# pk_search integration: rank column, staleness marker, stamp display
# ---------------------------------------------------------------------------

@pytest.fixture
def store(tmp_path):
    """Two knowledge entries of comparable BM25 relevance."""
    kd = tmp_path / "knowledge"
    (kd / "conventions").mkdir(parents=True)
    for name in ("alpha", "beta"):
        (kd / "conventions" / f"{name}.md").write_text(
            f"# {name.title()} widget retry policy\n"
            f"The {name} widget retries three times with exponential backoff.\n"
            "<!-- learned: 2026-01-01 | confidence: medium -->\n",
            encoding="utf-8",
        )
    return str(kd)


def _append_held(kdir: str, entry: str, uniq: str) -> None:
    proc = subprocess.run(
        [
            "bash", APPEND_SH, "--kdir", kdir,
            "--event", "consumption-verification", "--entry-path", entry,
            "--source", "worker", "--disposition", "held",
            "--file", f"/tmp/anchor-{uniq}.py", "--line-range", "1-2",
            "--exact-snippet", f"anchor {uniq}",
        ],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, proc.stderr


@pytest.mark.skipif(not _writer_available(), reason="jq or writer script unavailable")
def test_trusted_entry_outranks_unaudited(store):
    _append_held(store, "conventions/beta.md", "a")
    _append_held(store, "conventions/beta.md", "b")
    searcher = Searcher(store)
    results = searcher.search("widget retry policy", source_type="knowledge")
    paths = [r["file_path"] for r in results]
    assert paths[0] == "conventions/beta.md"
    by_path = {r["file_path"]: r for r in results}
    assert by_path["conventions/beta.md"]["trust_score"] > 0.0
    assert by_path["conventions/alpha.md"]["trust_score"] == 0.0


@pytest.mark.skipif(not _writer_available(), reason="jq or writer script unavailable")
def test_append_marker_refreshes_rank_without_manual_reindex(store):
    searcher = Searcher(store)
    results = searcher.search("widget retry policy", source_type="knowledge")
    assert all(r["trust_score"] == 0.0 for r in results)

    # Ledger append does not touch entry files...
    _append_held(store, "conventions/alpha.md", "c")
    indexer = Indexer(store)
    assert indexer.get_stale_files() == []
    # ...but the marker makes the next search absorb it into the rank column.
    assert indexer.trust_rank_stale()
    results = searcher.search("widget retry policy", source_type="knowledge")
    by_path = {r["file_path"]: r for r in results}
    assert by_path["conventions/alpha.md"]["trust_score"] > 0.0
    assert results[0]["file_path"] == "conventions/alpha.md"
    assert not Indexer(store).trust_rank_stale()


@pytest.mark.skipif(not _writer_available(), reason="jq or writer script unavailable")
def test_stamp_shows_live_ledger_component(store):
    searcher = Searcher(store)
    results = searcher.search("widget retry policy", source_type="knowledge")
    by_path = {r["file_path"]: r for r in results}

    stamp = render_trust_stamp(by_path["conventions/alpha.md"], store)
    assert "ledger=unobserved" in stamp

    # Live display: append lands in the stamp with no reindex of any kind
    _append_held(store, "conventions/alpha.md", "d")
    stamp = render_trust_stamp(by_path["conventions/alpha.md"], store)
    assert "ledger=+0.500" in stamp

    # Backwards-compatible callers (no knowledge_dir) get no ledger field
    assert "ledger=" not in render_trust_stamp(by_path["conventions/alpha.md"])
