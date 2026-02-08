"""Tests for compute_neighbor_drift() in staleness-scan.py.

Verifies that entries whose TF-IDF neighbors have been updated more recently
get a positive neighbor drift score, and entries with no neighbors return
available=False.
"""

import os
import sys

import pytest

# Add scripts dir to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from pk_search import Indexer
from pk_concordance import Concordance

# Import staleness-scan.py dynamically (filename has a hyphen)
import importlib.util

_ss_path = os.path.join(os.path.dirname(__file__), "..", "scripts", "staleness-scan.py")
_spec = importlib.util.spec_from_file_location("staleness_scan", _ss_path)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

compute_neighbor_drift = _mod.compute_neighbor_drift
score_entry = _mod.score_entry


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def neighbor_store(tmp_path):
    """Create a knowledge store where entry A is similar to B and C.

    A and C are old (learned 2025-01-01), B is new (learned 2026-02-01).
    A should have positive neighbor drift because B (a neighbor) is newer.
    """
    kd = tmp_path / "knowledge"
    kd.mkdir()

    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    # Entry A: old, about search indexing
    (arch_dir / "search-indexing.md").write_text(
        "# Search Indexing\n"
        "The search index uses SQLite FTS5 with porter stemming. BM25 scoring "
        "ranks results by term frequency. Incremental indexing detects changed "
        "files via mtime comparison. The index is stored in .pk_search.db.\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Entry B: new, about search ranking (similar to A — shares "search", "FTS5", "BM25" terms)
    (arch_dir / "search-ranking.md").write_text(
        "# Search Ranking\n"
        "Search ranking combines BM25 scores from FTS5 with TF-IDF cosine similarity. "
        "The composite scoring formula weights BM25, recency, and TF-IDF to produce "
        "a unified relevance score. Search results are sorted by composite score.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Entry C: old, about search architecture (similar to both A and B)
    (arch_dir / "search-architecture.md").write_text(
        "# Search Architecture\n"
        "The search subsystem consists of an FTS5 index, BM25 scoring, and a "
        "concordance module for TF-IDF vectors. Search is triggered by CLI commands "
        "or hooks. The SQLite database stores both the FTS5 index and TF-IDF vectors.\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Entry D: unrelated topic (deployment)
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "deployment.md").write_text(
        "# Deployment Process\n"
        "Docker images are built in CI and pushed to ECR. Production deployments "
        "use ECS task definitions. Health checks validate before traffic shift.\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Index everything
    indexer = Indexer(str(kd))
    indexer.index_all(force=True)

    return kd


@pytest.fixture
def isolated_store(tmp_path):
    """Create a knowledge store where one entry has no similar neighbors."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # One entry with unique vocabulary
    gotchas_dir = kd / "gotchas"
    gotchas_dir.mkdir()
    (gotchas_dir / "unique-entry.md").write_text(
        "# Xylophone Quartz Zebra\n"
        "Completely unique vocabulary that shares no terms with any other entry. "
        "Xylophone quartz zebra flamingo umbrella.\n"
        "<!-- learned: 2025-06-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Index
    indexer = Indexer(str(kd))
    indexer.index_all(force=True)

    return kd


# ---------------------------------------------------------------------------
# Tests: compute_neighbor_drift
# ---------------------------------------------------------------------------

class TestComputeNeighborDrift:
    def test_old_entry_with_new_neighbor(self, neighbor_store):
        """Entry A (old) should have positive drift because neighbor B is newer."""
        file_path = str(neighbor_store / "architecture" / "search-indexing.md")
        result = compute_neighbor_drift(
            file_path, "Search Indexing", "2025-01-01", str(neighbor_store)
        )
        assert result["available"] is True, "Should be available (has neighbors)"
        assert result["score"] > 0, (
            f"Old entry with new neighbor should have positive drift, got {result['score']}"
        )
        assert result["detail"]["neighbors_updated"] > 0

    def test_new_entry_low_drift(self, neighbor_store):
        """Entry B (newest) should have zero or low drift (no newer neighbors)."""
        file_path = str(neighbor_store / "architecture" / "search-ranking.md")
        result = compute_neighbor_drift(
            file_path, "Search Ranking", "2026-02-01", str(neighbor_store)
        )
        assert result["available"] is True
        # B is the newest entry, so neighbors_updated should be 0
        assert result["detail"]["neighbors_updated"] == 0
        assert result["score"] == 0.0

    def test_old_similar_entry_also_has_drift(self, neighbor_store):
        """Entry C (old, similar to A and B) should also have positive drift."""
        file_path = str(neighbor_store / "architecture" / "search-architecture.md")
        result = compute_neighbor_drift(
            file_path, "Search Architecture", "2025-01-01", str(neighbor_store)
        )
        assert result["available"] is True
        assert result["score"] > 0, (
            f"Old entry with new neighbor should have positive drift, got {result['score']}"
        )

    def test_no_learned_date_returns_unavailable(self, neighbor_store):
        """Entry with no learned_date should return available=False."""
        file_path = str(neighbor_store / "architecture" / "search-indexing.md")
        result = compute_neighbor_drift(
            file_path, "Search Indexing", None, str(neighbor_store)
        )
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_placeholder_date_returns_unavailable(self, neighbor_store):
        """Entry with YYYY-MM-DD placeholder should return available=False."""
        file_path = str(neighbor_store / "architecture" / "search-indexing.md")
        result = compute_neighbor_drift(
            file_path, "Search Indexing", "YYYY-MM-DD", str(neighbor_store)
        )
        assert result["available"] is False

    def test_no_similar_neighbors_returns_unavailable(self, isolated_store):
        """Entry with no similar neighbors should return available=False."""
        file_path = str(isolated_store / "gotchas" / "unique-entry.md")
        result = compute_neighbor_drift(
            file_path, "Xylophone Quartz Zebra", "2025-06-01", str(isolated_store)
        )
        # Either no neighbors found or no neighbors with parseable dates
        assert result["available"] is False or result["detail"].get("neighbors_checked", 0) == 0

    def test_nonexistent_db_returns_unavailable(self, tmp_path):
        """If no search DB exists, should return available=False."""
        kd = tmp_path / "no_db"
        kd.mkdir()
        result = compute_neighbor_drift(
            str(kd / "test.md"), "Test", "2025-01-01", str(kd)
        )
        assert result["available"] is False

    def test_drift_detail_has_expected_keys(self, neighbor_store):
        """Drift detail should contain neighbors_checked, neighbors_updated, weighted_score."""
        file_path = str(neighbor_store / "architecture" / "search-indexing.md")
        result = compute_neighbor_drift(
            file_path, "Search Indexing", "2025-01-01", str(neighbor_store)
        )
        assert result["available"] is True
        detail = result["detail"]
        assert "neighbors_checked" in detail
        assert "neighbors_updated" in detail
        assert "weighted_score" in detail
        assert detail["neighbors_checked"] > 0


class TestScoreEntryWithNeighborDrift:
    """Tests for score_entry() integration with neighbor_drift signal."""

    def test_neighbor_drift_affects_score(self):
        """score_entry should incorporate neighbor_drift when available."""
        fd = {"score": 0.0, "available": False, "commit_count": 0}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}
        nd = {"score": 0.8, "available": True, "detail": {"neighbors_checked": 3, "neighbors_updated": 2, "weighted_score": 0.8}}

        drift_score, status, signals = score_entry(fd, bd, "high", neighbor_drift=nd)
        assert drift_score > 0, "Positive neighbor drift should produce positive score"
        assert "neighbor_drift" in signals

    def test_without_neighbor_drift_fallback(self):
        """Without neighbor_drift, its weight should transfer to confidence."""
        fd = {"score": 0.5, "available": True, "commit_count": 3}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}

        # With neighbor drift available
        nd = {"score": 0.0, "available": True, "detail": {"neighbors_checked": 2, "neighbors_updated": 0, "weighted_score": 0.0}}
        score_with, _, signals_with = score_entry(fd, bd, "low", neighbor_drift=nd)

        # Without neighbor drift (None)
        score_without, _, signals_without = score_entry(fd, bd, "low", neighbor_drift=None)

        # Both should produce valid scores
        assert 0 <= score_with <= 1.0
        assert 0 <= score_without <= 1.0

    def test_high_neighbor_drift_increases_staleness(self):
        """Entry with high neighbor drift should score higher (more stale)."""
        fd = {"score": 0.3, "available": True, "commit_count": 2}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}

        nd_low = {"score": 0.0, "available": True, "detail": {"neighbors_checked": 3, "neighbors_updated": 0, "weighted_score": 0.0}}
        nd_high = {"score": 1.0, "available": True, "detail": {"neighbors_checked": 3, "neighbors_updated": 3, "weighted_score": 1.0}}

        score_low, _, _ = score_entry(fd, bd, "high", neighbor_drift=nd_low)
        score_high, _, _ = score_entry(fd, bd, "high", neighbor_drift=nd_high)

        assert score_high > score_low, (
            f"High neighbor drift ({score_high}) should produce higher staleness than low ({score_low})"
        )
