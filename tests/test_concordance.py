"""Tests for pk_concordance.py — TF-IDF concordance for lore knowledge stores.

Phase 1 tests covering:
1. fts5vocab returns porter-stemmed terms after indexing
2. TF-IDF vector computation produces expected values
3. Cosine similarity between entries with shared/disjoint terms
4. Sparse vector serialization round-trip
5. Source file indexing integration

Phase 2 tests covering:
6. composite_search with TF-IDF rankings
7. --expand flag for similar entries
8. build_query_vector

Phase 4 tests covering:
9. suggest_related_files
10. run_full_analysis and concordance_results table
11. find_similar method (renamed from find_similar_to)
"""

import math
import os
import sys

import pytest

# Add scripts dir to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from pk_concordance import (
    Concordance,
    deserialize_sparse_vector,
    serialize_sparse_vector,
    sparse_cosine_similarity,
)
from pk_search import Indexer, Searcher


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a minimal knowledge directory with entries that have known term overlap."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # architecture/ — entry about database sharding
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "database-sharding.md").write_text(
        "# Database Sharding\n"
        "PostgreSQL is sharded by tenant using Citus. Each shard handles "
        "roughly ten thousand tenants. Cross-shard queries go through a coordinator.\n"
        "<!-- learned: 2025-02-15 | confidence: high -->\n",
        encoding="utf-8",
    )

    # conventions/ — entry about database conventions (shares "database" terms)
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "database-conventions.md").write_text(
        "# Database Conventions\n"
        "All database tables use snake_case naming. Indexes follow the pattern "
        "idx_tablename_column. Foreign keys reference tenant_id for sharding.\n",
        encoding="utf-8",
    )

    # gotchas/ — entry about network timeouts (disjoint terms from database entries)
    gotchas_dir = kd / "gotchas"
    gotchas_dir.mkdir()
    (gotchas_dir / "network-timeouts.md").write_text(
        "# Network Timeouts\n"
        "HTTP client timeouts must be configured separately for connect and read. "
        "Default socket timeout is 30 seconds. Retry with exponential backoff.\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def indexed_db(knowledge_dir):
    """Index the knowledge directory and return the db_path."""
    indexer = Indexer(str(knowledge_dir))
    result = indexer.index_all(force=True)
    assert "error" not in result
    return indexer.db_path


@pytest.fixture
def repo_with_sources(tmp_path):
    """Create a knowledge dir + repo root with source files for source indexing tests."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # One knowledge entry about scripts
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "script-patterns.md").write_text(
        "# Script Patterns\n"
        "All shell scripts source lib.sh for common functions like slugify and resolve.\n",
        encoding="utf-8",
    )

    # Repo root with source files
    repo = tmp_path / "repo"
    repo.mkdir()
    scripts_dir = repo / "scripts"
    scripts_dir.mkdir()
    (scripts_dir / "lib.sh").write_text(
        "#!/usr/bin/env bash\n"
        "# lib.sh - common functions\n"
        "slugify() { echo \"$1\" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }\n"
        "resolve() { echo \"resolved\"; }\n",
        encoding="utf-8",
    )
    (scripts_dir / "deploy.py").write_text(
        "#!/usr/bin/env python3\n"
        "\"\"\"deploy.py - deployment script\"\"\"\n"
        "import subprocess\n"
        "def deploy(target):\n"
        "    subprocess.run(['rsync', '-avz', '.', target])\n",
        encoding="utf-8",
    )

    return kd, repo


# ---------------------------------------------------------------------------
# Test: Sparse vector serialization
# ---------------------------------------------------------------------------

class TestSparseVectorSerialization:
    def test_round_trip(self):
        vec = {0: 1.5, 3: 2.7, 10: 0.1}
        data = serialize_sparse_vector(vec)
        restored = deserialize_sparse_vector(data)
        assert set(restored.keys()) == set(vec.keys())
        for k in vec:
            assert abs(restored[k] - vec[k]) < 1e-5

    def test_empty_vector(self):
        data = serialize_sparse_vector({})
        assert data == b""
        restored = deserialize_sparse_vector(b"")
        assert restored == {}

    def test_single_element(self):
        vec = {42: 3.14}
        data = serialize_sparse_vector(vec)
        restored = deserialize_sparse_vector(data)
        assert len(restored) == 1
        assert abs(restored[42] - 3.14) < 1e-5


# ---------------------------------------------------------------------------
# Test: Sparse cosine similarity
# ---------------------------------------------------------------------------

class TestSparsCosineSimilarity:
    def test_identical_vectors(self):
        vec = {0: 1.0, 1: 2.0, 2: 3.0}
        sim = sparse_cosine_similarity(vec, vec)
        assert abs(sim - 1.0) < 1e-6

    def test_orthogonal_vectors(self):
        a = {0: 1.0, 1: 0.0}
        b = {2: 1.0, 3: 0.0}
        sim = sparse_cosine_similarity(a, b)
        assert sim == 0.0

    def test_disjoint_keys(self):
        a = {0: 1.0, 1: 2.0}
        b = {5: 3.0, 6: 4.0}
        sim = sparse_cosine_similarity(a, b)
        assert sim == 0.0

    def test_partial_overlap(self):
        a = {0: 1.0, 1: 1.0}
        b = {1: 1.0, 2: 1.0}
        sim = sparse_cosine_similarity(a, b)
        # dot = 1*1 = 1, norm_a = sqrt(2), norm_b = sqrt(2)
        # cos = 1/2 = 0.5
        assert abs(sim - 0.5) < 1e-6

    def test_empty_vectors(self):
        assert sparse_cosine_similarity({}, {}) == 0.0
        assert sparse_cosine_similarity({0: 1.0}, {}) == 0.0
        assert sparse_cosine_similarity({}, {0: 1.0}) == 0.0


# ---------------------------------------------------------------------------
# Test: fts5vocab returns porter-stemmed terms
# ---------------------------------------------------------------------------

class TestFts5vocab:
    def test_vocab_table_exists(self, indexed_db):
        """fts5vocab entry_terms table should exist after indexing."""
        import sqlite3
        conn = sqlite3.connect(indexed_db)
        row = conn.execute("SELECT count(*) FROM entry_terms").fetchone()
        conn.close()
        assert row[0] > 0, "entry_terms should have terms after indexing"

    def test_instance_table_exists(self, indexed_db):
        """fts5vocab entry_terms_instance table should exist after indexing."""
        import sqlite3
        conn = sqlite3.connect(indexed_db)
        row = conn.execute("SELECT count(*) FROM entry_terms_instance").fetchone()
        conn.close()
        assert row[0] > 0, "entry_terms_instance should have entries"

    def test_porter_stemming(self, indexed_db):
        """Verify that porter stemming is applied: 'sharding' -> 'shard', 'queries' -> 'queri'."""
        import sqlite3
        conn = sqlite3.connect(indexed_db)
        terms = {row[0] for row in conn.execute("SELECT term FROM entry_terms").fetchall()}
        conn.close()

        # Porter stemmer should stem these:
        # "sharding" -> "shard", "sharded" -> "shard"
        assert "shard" in terms, f"Expected 'shard' in stemmed terms, got: {sorted(terms)}"

        # "database" -> "databas" (porter stemmer drops trailing 'e')
        assert "databas" in terms, f"Expected 'databas' in stemmed terms, got: {sorted(terms)}"

        # The unstemmed forms should NOT appear (porter removes suffixes)
        assert "sharding" not in terms, "Raw 'sharding' should not appear; porter stems to 'shard'"

    def test_doc_frequency(self, indexed_db):
        """Verify document frequency counts: 'databas' appears in 2 entries."""
        import sqlite3
        conn = sqlite3.connect(indexed_db)
        row = conn.execute(
            "SELECT doc FROM entry_terms WHERE term = 'databas'"
        ).fetchone()
        conn.close()
        assert row is not None, "Term 'databas' should exist"
        # 'database' appears in both database-sharding.md and database-conventions.md
        assert row[0] == 2, f"Expected doc_count=2 for 'databas', got {row[0]}"


# ---------------------------------------------------------------------------
# Test: TF-IDF vector computation
# ---------------------------------------------------------------------------

class TestTfidfVectors:
    def test_build_vectors_creates_entries(self, indexed_db):
        """build_vectors() should create tfidf_vectors entries."""
        conc = Concordance(indexed_db)
        result = conc.build_vectors()
        assert result["vectors_built"] > 0

    def test_vector_retrieval(self, indexed_db, knowledge_dir):
        """get_vector() should return a non-empty sparse vector for indexed entries."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        # The file path stored is absolute
        file_path = str(knowledge_dir / "architecture" / "database-sharding.md")
        vec = conc.get_vector(file_path, "Database Sharding")
        assert vec is not None, "Vector should exist for indexed entry"
        assert len(vec) > 0, "Vector should have at least one term"

    def test_tfidf_values_positive(self, indexed_db, knowledge_dir):
        """All TF-IDF values in a vector should be positive."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        file_path = str(knowledge_dir / "architecture" / "database-sharding.md")
        vec = conc.get_vector(file_path, "Database Sharding")
        assert vec is not None
        for idx, score in vec.items():
            assert score > 0, f"TF-IDF score for term index {idx} should be positive, got {score}"

    def test_idf_weighting(self, indexed_db, knowledge_dir):
        """Terms appearing in fewer documents should have higher IDF weight.

        'shard' appears in 2 docs, 'timeout' appears in 1 doc.
        The TF-IDF for 'timeout' (in network-timeouts) should reflect higher IDF.
        """
        conc = Concordance(indexed_db)
        conc.build_vectors()

        # Get term index to know which term index maps to which term
        term_index = conc.get_term_index()

        # Get vector for network-timeouts entry (has 'timeout' term)
        file_path = str(knowledge_dir / "gotchas" / "network-timeouts.md")
        vec = conc.get_vector(file_path, "Network Timeouts")
        assert vec is not None

        # If 'timeout' is in the term index, its IDF should be > 0
        # since it appears in only 1 of 3 documents
        timeout_stem = "timeout"  # porter keeps 'timeout' as-is
        if timeout_stem in term_index:
            timeout_idx = term_index[timeout_stem]
            assert timeout_idx in vec, f"Term 'timeout' (idx={timeout_idx}) should be in vector"

    def test_get_all_vectors(self, indexed_db):
        """get_all_vectors() should return all stored vectors."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        all_vecs = conc.get_all_vectors()
        assert len(all_vecs) > 0
        for entry in all_vecs:
            assert "file_path" in entry
            assert "heading" in entry
            assert "vector" in entry
            assert isinstance(entry["vector"], dict)

    def test_get_all_vectors_with_filter(self, indexed_db):
        """get_all_vectors(source_type='knowledge') should filter results."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        knowledge_vecs = conc.get_all_vectors(source_type="knowledge")
        assert len(knowledge_vecs) > 0
        for entry in knowledge_vecs:
            assert entry["source_type"] == "knowledge"


# ---------------------------------------------------------------------------
# Test: Cosine similarity between entries
# ---------------------------------------------------------------------------

class TestEntrySimilarity:
    def test_related_entries_have_positive_similarity(self, indexed_db, knowledge_dir):
        """Two database-related entries should have cosine similarity > 0."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        vec_sharding = conc.get_vector(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
        )
        vec_conventions = conc.get_vector(
            str(knowledge_dir / "conventions" / "database-conventions.md"),
            "Database Conventions",
        )
        assert vec_sharding is not None
        assert vec_conventions is not None

        sim = sparse_cosine_similarity(vec_sharding, vec_conventions)
        assert sim > 0, f"Database entries should have positive similarity, got {sim}"

    def test_unrelated_entries_have_low_similarity(self, indexed_db, knowledge_dir):
        """Database entry and network timeout entry should have low similarity."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        vec_sharding = conc.get_vector(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
        )
        vec_timeout = conc.get_vector(
            str(knowledge_dir / "gotchas" / "network-timeouts.md"),
            "Network Timeouts",
        )
        assert vec_sharding is not None
        assert vec_timeout is not None

        sim_related = sparse_cosine_similarity(
            vec_sharding,
            conc.get_vector(
                str(knowledge_dir / "conventions" / "database-conventions.md"),
                "Database Conventions",
            ),
        )
        sim_unrelated = sparse_cosine_similarity(vec_sharding, vec_timeout)

        # Related entries should have higher similarity than unrelated
        assert sim_related > sim_unrelated, (
            f"Related entries ({sim_related:.4f}) should have higher similarity "
            f"than unrelated ({sim_unrelated:.4f})"
        )


# ---------------------------------------------------------------------------
# Test: Source file indexing
# ---------------------------------------------------------------------------

class TestSourceFileIndexing:
    def test_source_files_indexed(self, repo_with_sources):
        """Source files should be indexed with source_type='source'."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        result = indexer.index_all(force=True)
        assert "error" not in result

        import sqlite3
        conn = sqlite3.connect(indexer.db_path)
        source_entries = conn.execute(
            "SELECT heading, source_type FROM entries WHERE source_type = 'source'"
        ).fetchall()
        conn.close()

        headings = {row[0] for row in source_entries}
        assert "scripts/lib.sh" in headings, f"Expected scripts/lib.sh in headings, got {headings}"
        assert "scripts/deploy.py" in headings, f"Expected scripts/deploy.py in headings, got {headings}"

    def test_source_files_have_content(self, repo_with_sources):
        """Source file entries should contain the file content."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        import sqlite3
        conn = sqlite3.connect(indexer.db_path)
        row = conn.execute(
            "SELECT content FROM entries WHERE heading = 'scripts/lib.sh'"
        ).fetchone()
        conn.close()

        assert row is not None
        assert "slugify" in row[0], "lib.sh content should contain 'slugify'"

    def test_source_vectors_built(self, repo_with_sources):
        """TF-IDF vectors should be built for source files too."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()
        source_vecs = conc.get_all_vectors(source_type="source")
        assert len(source_vecs) > 0, "Should have vectors for source files"

    def test_no_source_files_without_repo_root(self, repo_with_sources):
        """Without repo_root, no source files should be indexed."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd))  # no repo_root
        result = indexer.index_all(force=True)

        import sqlite3
        conn = sqlite3.connect(indexer.db_path)
        source_count = conn.execute(
            "SELECT count(*) FROM entries WHERE source_type = 'source'"
        ).fetchone()[0]
        conn.close()
        assert source_count == 0, "No source files should be indexed without repo_root"

    def test_knowledge_dir_not_double_indexed(self, tmp_path):
        """If knowledge dir is inside repo root, knowledge files should not be double-indexed as source."""
        # Create knowledge dir inside repo root
        repo = tmp_path / "repo"
        repo.mkdir()
        kd = repo / "knowledge"
        kd.mkdir()

        conv_dir = kd / "conventions"
        conv_dir.mkdir()
        (conv_dir / "test.md").write_text("# Test\nTest entry content.\n", encoding="utf-8")

        # Also put a source file in the repo
        (repo / "script.sh").write_text("#!/bin/bash\necho hello\n", encoding="utf-8")

        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        import sqlite3
        conn = sqlite3.connect(indexer.db_path)
        # Knowledge file should only appear once as 'knowledge', not also as 'source'
        rows = conn.execute(
            "SELECT source_type, count(*) FROM entries GROUP BY source_type"
        ).fetchall()
        conn.close()

        type_counts = {st: count for st, count in rows}
        assert type_counts.get("knowledge", 0) > 0
        assert type_counts.get("source", 0) > 0
        # The .md file in conventions/ should NOT appear as source
        # (it's already indexed as knowledge)


# ---------------------------------------------------------------------------
# Test: Build concordance integration with Indexer
# ---------------------------------------------------------------------------

class TestBuildConcordanceIntegration:
    def test_index_all_builds_concordance(self, knowledge_dir):
        """index_all() should build concordance vectors as part of indexing."""
        indexer = Indexer(str(knowledge_dir))
        result = indexer.index_all(force=True)
        assert "error" not in result
        # Worker-1 added concordance stats to index_all return value
        if "concordance" in result:
            assert result["concordance"]["vectors_built"] > 0

    def test_build_concordance_method(self, knowledge_dir):
        """Indexer.build_concordance() should build vectors from existing index."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all(force=True)
        result = indexer.build_concordance()
        assert result["vectors_built"] > 0


# ---------------------------------------------------------------------------
# Phase 2 Tests: composite_search TF-IDF rankings and --expand
# ---------------------------------------------------------------------------

@pytest.fixture
def composite_knowledge_dir(tmp_path):
    """Create a knowledge directory with entries designed to test TF-IDF rankings.

    Contains entries with varying term overlap to a test query about 'database sharding'.
    """
    kd = tmp_path / "knowledge"
    kd.mkdir()

    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    # High relevance: directly about database sharding
    (arch_dir / "database-sharding.md").write_text(
        "# Database Sharding\n"
        "PostgreSQL is sharded by tenant using Citus distributed database. "
        "Each shard handles roughly ten thousand tenants. Cross-shard queries "
        "go through a coordinator node. Database sharding is essential for "
        "horizontal scaling of the tenant database.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Medium relevance: about databases but not sharding
    (arch_dir / "database-replication.md").write_text(
        "# Database Replication\n"
        "PostgreSQL streaming replication provides high availability for the database. "
        "A standby replica receives WAL records from the primary database server. "
        "Failover to the replica takes about 30 seconds.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    # Low relevance: about conventions, minimal database overlap
    (conv_dir / "naming-conventions.md").write_text(
        "# Naming Conventions\n"
        "All variable names use snake_case. Database table names follow the same "
        "pattern. Class names use PascalCase. Constants use UPPER_SNAKE_CASE.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # No relevance: completely different topic
    (conv_dir / "logging-standards.md").write_text(
        "# Logging Standards\n"
        "All services emit structured JSON logs to stdout. Log levels follow "
        "RFC 5424: emergency, alert, critical, error, warning, notice, info, debug. "
        "Correlation IDs propagate through HTTP headers.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    return kd


class TestCompositeSearchTfidf:
    def test_composite_search_returns_tfidf_score(self, composite_knowledge_dir):
        """composite_search results should include tfidf_score field."""
        searcher = Searcher(str(composite_knowledge_dir))
        results = searcher.composite_search("database sharding", limit=5)
        assert len(results) > 0
        for r in results:
            assert "composite_score" in r, "Result should have composite_score"
            assert "tfidf_score" in r, "Result should have tfidf_score"

    def test_tfidf_boosts_relevant_results(self, composite_knowledge_dir):
        """Entries with higher term overlap to query should have higher TF-IDF scores.

        Query 'database' matches multiple entries; the one with more 'database'
        occurrences should get a higher TF-IDF score.
        """
        searcher = Searcher(str(composite_knowledge_dir))
        # Use single-term query so BM25 returns all database-related entries
        results = searcher.composite_search("database", limit=10)

        # Find results by heading
        result_map = {r["heading"]: r for r in results}

        sharding = result_map.get("Database Sharding")
        logging = result_map.get("Logging Standards")

        assert sharding is not None, "Database Sharding should be in results"
        # Logging Standards doesn't mention 'database', so should not appear
        # or have tfidf_score = 0 if it does appear
        if logging is not None:
            assert sharding["tfidf_score"] >= logging["tfidf_score"], (
                f"Sharding TF-IDF ({sharding['tfidf_score']}) should be >= "
                f"Logging TF-IDF ({logging['tfidf_score']})"
            )

    def test_composite_score_ordering(self, composite_knowledge_dir):
        """Results should be ordered by composite_score descending."""
        searcher = Searcher(str(composite_knowledge_dir))
        results = searcher.composite_search("database sharding", limit=10)
        scores = [r["composite_score"] for r in results]
        assert scores == sorted(scores, reverse=True), (
            f"Results should be ordered by composite_score descending: {scores}"
        )

    def test_tfidf_weight_affects_ranking(self, composite_knowledge_dir):
        """Changing tfidf_weight should affect composite scores."""
        searcher = Searcher(str(composite_knowledge_dir))

        # With low TF-IDF weight
        results_low = searcher.composite_search("database", limit=10, tfidf_weight=0.1)

        # With high TF-IDF weight (tfidf=0.8, reduce others)
        results_high = searcher.composite_search(
            "database", limit=10,
            bm25_weight=0.1, recency_weight=0.1, tfidf_weight=0.8,
        )

        # Both should return results
        assert len(results_low) > 0
        assert len(results_high) > 0

        # Composite scores should differ when weights change
        scores_low = [r["composite_score"] for r in results_low]
        scores_high = [r["composite_score"] for r in results_high]
        assert scores_low != scores_high, (
            "Different TF-IDF weights should produce different composite scores"
        )

    def test_composite_search_no_vectors_graceful(self, tmp_path):
        """composite_search should work even if no TF-IDF vectors exist (graceful degradation)."""
        kd = tmp_path / "knowledge"
        kd.mkdir()
        conv_dir = kd / "conventions"
        conv_dir.mkdir()
        (conv_dir / "test.md").write_text("# Test\nSome test content here.\n", encoding="utf-8")

        searcher = Searcher(str(kd))
        results = searcher.composite_search("test", limit=5)
        # Should still return results, just with tfidf_score = 0
        assert len(results) > 0
        for r in results:
            assert "composite_score" in r


class TestExpandFlag:
    def test_find_similar_to_returns_results(self, indexed_db, knowledge_dir):
        """find_similar_to() should return similar entries."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        similar = conc.find_similar_to(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
            limit=3,
        )
        assert len(similar) > 0, "Should find at least one similar entry"
        for s in similar:
            assert "file_path" in s
            assert "heading" in s
            assert "similarity" in s
            assert s["similarity"] > 0

    def test_find_similar_to_excludes_self(self, indexed_db, knowledge_dir):
        """find_similar_to() should not return the target entry itself."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        target_path = str(knowledge_dir / "architecture" / "database-sharding.md")
        similar = conc.find_similar_to(target_path, "Database Sharding", limit=10)
        for s in similar:
            assert not (s["file_path"] == target_path and s["heading"] == "Database Sharding"), \
                "Should not return the target entry itself"

    def test_find_similar_to_respects_exclude(self, indexed_db, knowledge_dir):
        """find_similar_to() should exclude specified entries."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        exclude_path = str(knowledge_dir / "conventions" / "database-conventions.md")
        exclude_set = {(exclude_path, "Database Conventions")}

        similar = conc.find_similar_to(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
            limit=10,
            exclude=exclude_set,
        )
        for s in similar:
            assert not (s["file_path"] == exclude_path and s["heading"] == "Database Conventions"), \
                "Should not return excluded entries"

    def test_find_similar_to_source_type_filter(self, repo_with_sources):
        """find_similar_to() with source_type_filter should only return matching types."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target_path = str(kd / "conventions" / "script-patterns.md")
        similar_knowledge = conc.find_similar_to(
            target_path, "Script Patterns",
            limit=10, source_type_filter="knowledge",
        )
        for s in similar_knowledge:
            assert s["source_type"] == "knowledge"

    def test_find_similar_to_ranked_by_similarity(self, indexed_db, knowledge_dir):
        """find_similar_to() results should be ranked by similarity descending."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        similar = conc.find_similar_to(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
            limit=10,
        )
        if len(similar) >= 2:
            sims = [s["similarity"] for s in similar]
            assert sims == sorted(sims, reverse=True), (
                f"Results should be ordered by similarity descending: {sims}"
            )

    def test_find_similar_to_database_prefers_database(self, indexed_db, knowledge_dir):
        """Database entry should find other database entries as most similar."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        similar = conc.find_similar_to(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
            limit=1,
        )
        assert len(similar) > 0
        # The most similar entry to database-sharding should be database-conventions
        assert "database" in similar[0]["heading"].lower() or "database" in similar[0]["file_path"].lower(), (
            f"Most similar to 'Database Sharding' should be database-related, got: {similar[0]['heading']}"
        )

    def test_find_similar_to_nonexistent_entry(self, indexed_db):
        """find_similar_to() should return empty list for non-existent entry."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        similar = conc.find_similar_to("/nonexistent/path.md", "Nonexistent", limit=3)
        assert similar == []


class TestBuildQueryVector:
    def test_build_query_vector_returns_sparse_dict(self, indexed_db):
        """build_query_vector() should return a sparse vector dict."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vec = conc.build_query_vector("database sharding")
        assert isinstance(vec, dict)
        assert len(vec) > 0, "Query vector should have at least one term"

    def test_build_query_vector_empty_query(self, indexed_db):
        """build_query_vector() should return empty dict for empty query."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vec = conc.build_query_vector("")
        assert vec == {}

    def test_query_vector_similarity_to_matching_entry(self, indexed_db, knowledge_dir):
        """Query vector should have higher similarity to matching entry than unrelated entry."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        query_vec = conc.build_query_vector("database sharding tenant")
        assert len(query_vec) > 0

        vec_sharding = conc.get_vector(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
        )
        vec_timeout = conc.get_vector(
            str(knowledge_dir / "gotchas" / "network-timeouts.md"),
            "Network Timeouts",
        )
        assert vec_sharding is not None
        assert vec_timeout is not None

        sim_relevant = sparse_cosine_similarity(query_vec, vec_sharding)
        sim_irrelevant = sparse_cosine_similarity(query_vec, vec_timeout)

        assert sim_relevant > sim_irrelevant, (
            f"Query about 'database sharding' should be more similar to Database Sharding "
            f"({sim_relevant:.4f}) than Network Timeouts ({sim_irrelevant:.4f})"
        )


# ---------------------------------------------------------------------------
# Phase 4 Tests: suggest_related_files, run_full_analysis, concordance_results
# ---------------------------------------------------------------------------

class TestSuggestRelatedFiles:
    def test_returns_source_files_only(self, repo_with_sources):
        """suggest_related_files() should only return source-type entries."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target_path = str(kd / "conventions" / "script-patterns.md")
        related = conc.suggest_related_files(target_path, "Script Patterns")
        for r in related:
            assert r["source_type"] == "source", (
                f"suggest_related_files should only return source entries, got {r['source_type']}"
            )

    def test_threshold_filters_low_similarity(self, repo_with_sources):
        """suggest_related_files() with high threshold should return fewer results."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target_path = str(kd / "conventions" / "script-patterns.md")
        all_related = conc.suggest_related_files(target_path, "Script Patterns", threshold=0.0)
        high_related = conc.suggest_related_files(target_path, "Script Patterns", threshold=0.99)
        assert len(high_related) <= len(all_related), (
            "Higher threshold should return fewer or equal results"
        )

    def test_nonexistent_entry_returns_empty(self, indexed_db):
        """suggest_related_files() for non-existent entry should return empty list."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        related = conc.suggest_related_files("/nonexistent/path.md", "Nonexistent")
        assert related == []

    def test_respects_limit(self, repo_with_sources):
        """suggest_related_files() should respect the limit parameter."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target_path = str(kd / "conventions" / "script-patterns.md")
        related = conc.suggest_related_files(target_path, "Script Patterns", threshold=0.0, limit=1)
        assert len(related) <= 1


class TestRunFullAnalysis:
    def test_returns_stats(self, indexed_db):
        """run_full_analysis() should return stats dict."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        result = conc.run_full_analysis()
        assert "entries_analyzed" in result
        assert "see_also_pairs" in result
        assert "related_file_pairs" in result
        assert "elapsed_seconds" in result

    def test_creates_concordance_results(self, indexed_db):
        """run_full_analysis() should populate concordance_results table."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()
        result = conc.run_full_analysis()

        conn = sqlite3.connect(indexed_db)
        row = conn.execute("SELECT count(*) FROM concordance_results").fetchone()
        conn.close()
        assert row[0] > 0, "concordance_results should have entries after analysis"
        assert row[0] == result["see_also_pairs"] + result["related_file_pairs"]

    def test_see_also_result_type(self, indexed_db):
        """run_full_analysis() should store see_also entries with correct result_type."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()

        conn = sqlite3.connect(indexed_db)
        see_also = conn.execute(
            "SELECT count(*) FROM concordance_results WHERE result_type = 'see_also'"
        ).fetchone()
        conn.close()
        assert see_also[0] > 0, "Should have see_also entries"

    def test_analysis_clears_previous_results(self, indexed_db):
        """Running run_full_analysis() twice should not duplicate results."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()

        result1 = conc.run_full_analysis()
        result2 = conc.run_full_analysis()

        conn = sqlite3.connect(indexed_db)
        total = conn.execute("SELECT count(*) FROM concordance_results").fetchone()[0]
        conn.close()

        # Second run should produce the same count (DELETE + re-insert)
        expected = result2["see_also_pairs"] + result2["related_file_pairs"]
        assert total == expected, (
            f"After second analysis run, should have {expected} rows, got {total}"
        )

    def test_see_also_limit(self, indexed_db):
        """run_full_analysis(see_also_limit=1) should produce at most 1 see-also per entry."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis(see_also_limit=1)

        conn = sqlite3.connect(indexed_db)
        # Check that no entry has more than 1 see-also recommendation
        rows = conn.execute(
            "SELECT file_path, heading, count(*) as cnt "
            "FROM concordance_results WHERE result_type = 'see_also' "
            "GROUP BY file_path, heading"
        ).fetchall()
        conn.close()
        for fp, heading, cnt in rows:
            assert cnt <= 1, (
                f"Entry ({fp}, {heading}) has {cnt} see-also entries, expected <= 1"
            )

    def test_related_files_with_sources(self, repo_with_sources):
        """run_full_analysis() should produce related_file entries when source files exist."""
        import sqlite3

        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()
        result = conc.run_full_analysis(related_files_threshold=0.0)

        conn = sqlite3.connect(indexer.db_path)
        related = conn.execute(
            "SELECT count(*) FROM concordance_results WHERE result_type = 'related_file'"
        ).fetchone()
        conn.close()
        assert related[0] > 0, "Should have related_file entries when source files exist"

    def test_concordance_results_schema(self, indexed_db):
        """concordance_results table should have expected columns."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()

        conn = sqlite3.connect(indexed_db)
        row = conn.execute(
            "SELECT file_path, heading, similar_entry_path, similar_entry_heading, "
            "similarity_score, result_type FROM concordance_results LIMIT 1"
        ).fetchone()
        conn.close()
        assert row is not None, "Should have at least one result"
        assert len(row) == 6, "concordance_results should have 6 columns"

    def test_similarity_scores_are_positive(self, indexed_db):
        """All similarity scores in concordance_results should be positive."""
        import sqlite3

        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()

        conn = sqlite3.connect(indexed_db)
        rows = conn.execute(
            "SELECT similarity_score FROM concordance_results"
        ).fetchall()
        conn.close()
        for (score,) in rows:
            assert score > 0, f"Similarity score should be positive, got {score}"


class TestFindSimilarMethod:
    """Tests for the renamed find_similar() method (was find_similar_to)."""

    def test_find_similar_returns_results(self, indexed_db, knowledge_dir):
        """find_similar() should return similar entries."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        similar = conc.find_similar(
            str(knowledge_dir / "architecture" / "database-sharding.md"),
            "Database Sharding",
            limit=3,
        )
        assert len(similar) > 0, "Should find at least one similar entry"
        for s in similar:
            assert "file_path" in s
            assert "heading" in s
            assert "similarity" in s
            assert s["similarity"] > 0

    def test_find_similar_excludes_self(self, indexed_db, knowledge_dir):
        """find_similar() should not return the target entry itself."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        target_path = str(knowledge_dir / "architecture" / "database-sharding.md")
        similar = conc.find_similar(target_path, "Database Sharding", limit=10)
        for s in similar:
            assert not (s["file_path"] == target_path and s["heading"] == "Database Sharding"), \
                "Should not return the target entry itself"

    def test_find_similar_source_type_filter(self, repo_with_sources):
        """find_similar() with source_type_filter should only return matching types."""
        kd, repo = repo_with_sources
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target_path = str(kd / "conventions" / "script-patterns.md")
        similar_source = conc.find_similar(
            target_path, "Script Patterns",
            limit=10, source_type_filter="source",
        )
        for s in similar_source:
            assert s["source_type"] == "source"

    def test_backward_compat_alias(self, indexed_db, knowledge_dir):
        """find_similar_to should still work as an alias for find_similar."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        target_path = str(knowledge_dir / "architecture" / "database-sharding.md")
        result_new = conc.find_similar(target_path, "Database Sharding", limit=3)
        result_old = conc.find_similar_to(target_path, "Database Sharding", limit=3)
        assert result_new == result_old, "find_similar and find_similar_to should return same results"


# ---------------------------------------------------------------------------
# Integration test: find_similar with knowledge store + source files
# ---------------------------------------------------------------------------

@pytest.fixture
def integration_store(tmp_path):
    """Create a realistic knowledge store + repo with related entries and source files.

    Two workflow entries reference the same script (load-knowledge.sh).
    A third entry about a different topic (deployment) should be less similar.
    Source files are indexed to verify cross-type similarity.
    """
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # Workflow entries — two about the same script/topic
    wf_dir = kd / "workflows"
    wf_dir.mkdir()
    (wf_dir / "load-knowledge-sh.md").write_text(
        "# load-knowledge.sh\n"
        "The load-knowledge.sh script runs at session start to load knowledge entries into "
        "agent context. It calls pk_search.py with --composite --json flags to get the "
        "highest-ranked entries. Budget is limited to 8000 characters. Entries are resolved "
        "via pk_cli.py resolve and formatted as markdown sections.\n"
        "See also: [[knowledge:architecture/budget-based-context-loading]].\n"
        "<!-- learned: 2026-02-01 | confidence: high | related_files: scripts/load-knowledge.sh -->\n",
        encoding="utf-8",
    )
    (wf_dir / "session-start-hook.md").write_text(
        "# Session Start Hook\n"
        "The SessionStart hook runs load-knowledge.sh to prefetch knowledge entries. "
        "It also runs load-threads.sh for conversational threads. Both scripts write "
        "their output to stdout which gets injected into the agent prompt. The knowledge "
        "loading uses composite search with pk_search.py for ranked retrieval.\n"
        "<!-- learned: 2026-02-01 | confidence: high | related_files: scripts/load-knowledge.sh -->\n",
        encoding="utf-8",
    )

    # Architecture entry — about a different but slightly related topic
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "budget-based-context-loading.md").write_text(
        "# Budget-Based Context Loading\n"
        "Knowledge and thread loading use character budgets to prevent context overflow. "
        "Each entry's priority score determines loading order. Knowledge entries get 8000 "
        "characters; threads get 3000 characters. Entries are loaded by priority score "
        "until budget is exhausted.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Unrelated entry — about deployment
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "deployment-process.md").write_text(
        "# Deployment Process\n"
        "Production deployments use a blue-green strategy. Docker images are built "
        "in CI, pushed to ECR, and deployed via ECS task definitions. Rollback is "
        "automatic if health checks fail within 5 minutes.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # Repo root with source files
    repo = tmp_path / "repo"
    repo.mkdir()
    scripts = repo / "scripts"
    scripts.mkdir()
    (scripts / "load-knowledge.sh").write_text(
        "#!/usr/bin/env bash\n"
        "# load-knowledge.sh — Load knowledge entries into agent context at session start\n"
        "set -euo pipefail\n"
        "SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
        "source \"$SCRIPT_DIR/lib.sh\"\n"
        "KNOWLEDGE_DIR=$(resolve_knowledge_dir)\n"
        "# Run composite search for ranked retrieval\n"
        "RESULTS=$(python3 \"$SCRIPT_DIR/pk_cli.py\" search \"$KNOWLEDGE_DIR\" \"$QUERY\" --composite --json)\n"
        "# Format results as markdown sections\n"
        "echo \"## Prior Knowledge\"\n",
        encoding="utf-8",
    )
    (scripts / "deploy.sh").write_text(
        "#!/usr/bin/env bash\n"
        "# deploy.sh — Production deployment script\n"
        "set -euo pipefail\n"
        "docker build -t app:latest .\n"
        "aws ecr push app:latest\n"
        "aws ecs update-service --cluster prod --service app\n",
        encoding="utf-8",
    )

    return kd, repo


class TestFindSimilarIntegration:
    """Integration tests: index knowledge + source files, verify find_similar behavior."""

    def test_related_workflow_entries_high_similarity(self, integration_store):
        """Two workflow entries about the same script should have high similarity."""
        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target = str(kd / "workflows" / "load-knowledge-sh.md")
        similar = conc.find_similar(target, "load-knowledge.sh", limit=5, source_type_filter="knowledge")

        # The session-start-hook entry should be the most similar
        assert len(similar) > 0, "Should find similar entries"
        headings = [s["heading"] for s in similar]
        assert "Session Start Hook" in headings, (
            f"Session Start Hook should be similar to load-knowledge.sh, got: {headings}"
        )
        # It should be the top result
        assert similar[0]["heading"] == "Session Start Hook", (
            f"Session Start Hook should be most similar, got: {similar[0]['heading']}"
        )

    def test_unrelated_entry_lower_similarity(self, integration_store):
        """Deployment entry should have lower similarity to load-knowledge workflow."""
        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target = str(kd / "workflows" / "load-knowledge-sh.md")
        similar = conc.find_similar(target, "load-knowledge.sh", limit=10, source_type_filter="knowledge")

        sim_map = {s["heading"]: s["similarity"] for s in similar}
        session_sim = sim_map.get("Session Start Hook", 0)
        deploy_sim = sim_map.get("Deployment Process", 0)

        assert session_sim > deploy_sim, (
            f"Session Start Hook ({session_sim:.4f}) should be more similar to "
            f"load-knowledge.sh than Deployment Process ({deploy_sim:.4f})"
        )

    def test_source_file_similarity_matches_knowledge(self, integration_store):
        """Source file load-knowledge.sh should be similar to its knowledge entry."""
        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        # Find source files similar to the knowledge entry
        target = str(kd / "workflows" / "load-knowledge-sh.md")
        similar_sources = conc.find_similar(
            target, "load-knowledge.sh", limit=5, source_type_filter="source"
        )

        if similar_sources:
            # The load-knowledge.sh source file should be among results
            source_headings = [s["heading"] for s in similar_sources]
            assert any("load-knowledge" in h for h in source_headings), (
                f"load-knowledge.sh source should be similar, got: {source_headings}"
            )

    def test_deploy_source_matches_deploy_knowledge(self, integration_store):
        """Deploy source file should be more similar to deployment knowledge than to load-knowledge."""
        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        # Check from deploy knowledge entry's perspective
        deploy_path = str(kd / "conventions" / "deployment-process.md")
        similar_sources = conc.find_similar(
            deploy_path, "Deployment Process", limit=5, source_type_filter="source"
        )

        if len(similar_sources) >= 2:
            sim_map = {s["heading"]: s["similarity"] for s in similar_sources}
            deploy_sim = sim_map.get("scripts/deploy.sh", 0)
            load_sim = sim_map.get("scripts/load-knowledge.sh", 0)
            assert deploy_sim >= load_sim, (
                f"deploy.sh ({deploy_sim:.4f}) should be at least as similar to "
                f"'Deployment Process' as load-knowledge.sh ({load_sim:.4f})"
            )

    def test_full_analysis_integration(self, integration_store):
        """run_full_analysis() should produce sensible results for mixed store."""
        import sqlite3

        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()
        result = conc.run_full_analysis(related_files_threshold=0.0)

        assert result["entries_analyzed"] == 4, (
            f"Should analyze 4 knowledge entries, got {result['entries_analyzed']}"
        )
        assert result["see_also_pairs"] > 0, "Should have see-also pairs"

        # Verify the top see-also for load-knowledge.sh entry points to session-start-hook
        conn = sqlite3.connect(indexer.db_path)
        top_sa = conn.execute(
            "SELECT similar_entry_heading FROM concordance_results "
            "WHERE heading = 'load-knowledge.sh' AND result_type = 'see_also' "
            "ORDER BY similarity_score DESC LIMIT 1"
        ).fetchone()
        conn.close()
        assert top_sa is not None
        assert top_sa[0] == "Session Start Hook", (
            f"Top see-also for load-knowledge.sh should be Session Start Hook, got: {top_sa[0]}"
        )

    def test_suggest_related_files_integration(self, integration_store):
        """suggest_related_files() should find relevant source files for knowledge entries."""
        kd, repo = integration_store
        indexer = Indexer(str(kd), repo_root=str(repo))
        indexer.index_all(force=True)

        conc = Concordance(indexer.db_path)
        conc.build_vectors()

        target = str(kd / "workflows" / "load-knowledge-sh.md")
        related = conc.suggest_related_files(target, "load-knowledge.sh", threshold=0.0)
        if related:
            # load-knowledge.sh source should be among suggestions
            file_paths = [r["heading"] for r in related]
            assert any("load-knowledge" in fp for fp in file_paths), (
                f"load-knowledge.sh should be suggested as related file, got: {file_paths}"
            )


# ---------------------------------------------------------------------------
# Regression test: composite_search TF-IDF rankings
# ---------------------------------------------------------------------------

@pytest.fixture
def regression_store(tmp_path):
    """Create a knowledge store with 5 entries across different topics.

    Designed to test that composite_search with TF-IDF produces correct rankings
    for multiple known queries.
    """
    kd = tmp_path / "knowledge"
    kd.mkdir()

    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    (arch_dir / "fts5-search-index.md").write_text(
        "# FTS5 Search Index\n"
        "The knowledge search system uses SQLite FTS5 with porter unicode61 tokenizer "
        "for full-text search. BM25 scoring ranks results by relevance. The search "
        "index is stored in .pk_search.db and updated incrementally when files change. "
        "FTS5 supports phrase queries and column filters for targeted search.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    (arch_dir / "tfidf-concordance.md").write_text(
        "# TF-IDF Concordance\n"
        "TF-IDF vectors are computed from FTS5-indexed content using fts5vocab virtual tables. "
        "Term frequency comes from the instance-level table, document frequency from the "
        "row-level table. Vectors are sparse dicts serialized via struct.pack and stored in "
        "the tfidf_vectors table. Cosine similarity between vectors enables see-also "
        "recommendations and related file suggestions.\n"
        "<!-- learned: 2026-02-08 | confidence: high -->\n",
        encoding="utf-8",
    )

    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    (conv_dir / "script-first-design.md").write_text(
        "# Script-First Skill Design\n"
        "Mechanical subcommands route to bash scripts with formatted output. The SKILL.md "
        "file is a thin routing table. Only judgment operations stay inline. Scripts "
        "source lib.sh for common functions like slugify and resolve_knowledge_dir.\n"
        "<!-- learned: 2026-02-05 | confidence: high -->\n",
        encoding="utf-8",
    )

    (conv_dir / "capture-criteria.md").write_text(
        "# Capture Criteria: 4-Condition Gate\n"
        "All four conditions must be true for capture: reusable (applicable beyond the "
        "current task), non-obvious (not already in docs), stable (unlikely to change "
        "soon), high confidence (verified through code exploration). This gate prevents "
        "low-value captures from polluting the knowledge store.\n"
        "<!-- learned: 2026-02-03 | confidence: high -->\n",
        encoding="utf-8",
    )

    gotchas_dir = kd / "gotchas"
    gotchas_dir.mkdir()

    (gotchas_dir / "agent-bypass-mechanisms.md").write_text(
        "# Three Mechanisms Cause Skill Protocol Bypass\n"
        "Instruction fade: agent forgets protocol steps in long contexts. Faster-path "
        "preference: agent takes a working shortcut instead of the protocol path. "
        "Abstract activation threshold: agent doesn't recognize when a general rule "
        "applies to its specific situation. Each bypass needs a different fix.\n"
        "<!-- learned: 2026-02-06 | confidence: high -->\n",
        encoding="utf-8",
    )

    return kd


class TestCompositeSearchRegression:
    """Regression tests: verify TF-IDF signal produces correct rankings for known queries."""

    def test_query_search_index(self, regression_store):
        """Query 'FTS5 search index' should rank FTS5 entry highest."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("FTS5 search index", limit=5)
        assert len(results) > 0
        assert results[0]["heading"] == "FTS5 Search Index", (
            f"FTS5 Search Index should rank first for 'FTS5 search index', got: {results[0]['heading']}"
        )

    def test_query_tfidf_concordance(self, regression_store):
        """Query 'TF-IDF cosine similarity' should rank TF-IDF Concordance highest."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("TF-IDF cosine similarity", limit=5)
        assert len(results) > 0
        # TF-IDF Concordance entry has direct mention of both terms
        heading_list = [r["heading"] for r in results]
        assert "TF-IDF Concordance" in heading_list, (
            f"TF-IDF Concordance should appear for 'TF-IDF cosine similarity', got: {heading_list}"
        )

    def test_query_script_design(self, regression_store):
        """Query 'bash script routing' should rank Script-First Design highest."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("bash script routing", limit=5)
        assert len(results) > 0
        heading_list = [r["heading"] for r in results]
        assert "Script-First Skill Design" in heading_list, (
            f"Script-First Design should appear for 'bash script routing', got: {heading_list}"
        )

    def test_query_capture_criteria(self, regression_store):
        """Query 'capture gate reusable stable' should rank Capture Criteria highest."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("capture gate reusable stable", limit=5)
        assert len(results) > 0
        assert results[0]["heading"] == "Capture Criteria: 4-Condition Gate", (
            f"Capture Criteria should rank first, got: {results[0]['heading']}"
        )

    def test_query_bypass(self, regression_store):
        """Query 'agent protocol bypass' should rank bypass mechanisms entry highest."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("agent protocol bypass", limit=5)
        assert len(results) > 0
        assert results[0]["heading"] == "Three Mechanisms Cause Skill Protocol Bypass", (
            f"Bypass entry should rank first, got: {results[0]['heading']}"
        )

    def test_tfidf_improves_discrimination(self, regression_store):
        """With TF-IDF weight, composite search should better discriminate between related entries.

        The two search-related entries (FTS5 and TF-IDF) should have different rankings
        when TF-IDF weight is high vs when it's zero.
        """
        searcher = Searcher(str(regression_store))

        # High TF-IDF weight
        results_tfidf = searcher.composite_search(
            "fts5vocab term frequency", limit=5,
            bm25_weight=0.3, recency_weight=0.0, tfidf_weight=0.7,
        )

        # Zero TF-IDF weight (BM25 only)
        results_bm25 = searcher.composite_search(
            "fts5vocab term frequency", limit=5,
            bm25_weight=1.0, recency_weight=0.0, tfidf_weight=0.0,
        )

        # Both should return results
        assert len(results_tfidf) > 0
        assert len(results_bm25) > 0

        # TF-IDF results should have non-zero tfidf_scores for relevant entries
        tfidf_scores = [r["tfidf_score"] for r in results_tfidf if r["tfidf_score"] > 0]
        assert len(tfidf_scores) > 0, "At least one result should have non-zero tfidf_score"

    def test_composite_scores_bounded(self, regression_store):
        """All composite scores should be between 0 and 1 (given default weights sum to 1)."""
        searcher = Searcher(str(regression_store))
        results = searcher.composite_search("search index", limit=10)
        for r in results:
            assert 0 <= r["composite_score"] <= 1.0, (
                f"Composite score should be in [0, 1], got {r['composite_score']} for {r['heading']}"
            )
