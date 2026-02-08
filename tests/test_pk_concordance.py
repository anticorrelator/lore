"""Tests for pk_concordance.py — TF-IDF concordance from FTS5 index."""

import math
import os
import sqlite3
import sys

import pytest

# Add scripts dir to path so we can import pk_concordance
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from pk_concordance import (
    Concordance,
    deserialize_sparse_vector,
    serialize_sparse_vector,
    sparse_cosine_similarity,
)
from pk_search import Indexer


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a sample knowledge directory with entries for concordance tests."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    # Entry with unique terms + shared terms
    (conv_dir / "testing-patterns.md").write_text(
        "# Testing Patterns\n"
        "Unit tests should cover edge cases and error paths.\n"
        "Integration tests verify component interaction and testing boundaries.\n",
        encoding="utf-8",
    )

    # Entry with different unique terms + shared terms
    (conv_dir / "architecture-guide.md").write_text(
        "# Architecture Guide\n"
        "Modular architecture with clear boundaries.\n"
        "Each module should have a well-defined interface and clean architecture.\n",
        encoding="utf-8",
    )

    # Entry that overlaps with both above
    (conv_dir / "test-architecture.md").write_text(
        "# Test Architecture\n"
        "Test architecture should mirror the production architecture.\n"
        "Unit tests for modules, integration tests for boundaries and interfaces.\n",
        encoding="utf-8",
    )

    # Entry with completely unique vocabulary
    (conv_dir / "database-naming.md").write_text(
        "# Database Naming\n"
        "Tables use snake_case plural nouns. Columns use snake_case singular.\n"
        "Foreign keys follow the pattern: referenced_table_id.\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def indexed_db(knowledge_dir):
    """Index the knowledge directory and return db_path."""
    idx = Indexer(str(knowledge_dir))
    idx.index_all()
    return os.path.join(str(knowledge_dir), ".pk_search.db")


# ---------------------------------------------------------------------------
# Serialization tests
# ---------------------------------------------------------------------------

class TestSparseVectorSerialization:
    """Tests for serialize/deserialize sparse vectors."""

    def test_roundtrip(self):
        vec = {0: 1.5, 10: 2.3, 100: 0.7}
        blob = serialize_sparse_vector(vec)
        recovered = deserialize_sparse_vector(blob)
        assert set(recovered.keys()) == set(vec.keys())
        for k in vec:
            assert abs(recovered[k] - vec[k]) < 1e-4

    def test_empty_vector(self):
        assert serialize_sparse_vector({}) == b""
        assert deserialize_sparse_vector(b"") == {}

    def test_single_element(self):
        vec = {42: 3.14}
        blob = serialize_sparse_vector(vec)
        recovered = deserialize_sparse_vector(blob)
        assert 42 in recovered
        assert abs(recovered[42] - 3.14) < 1e-4

    def test_large_indices(self):
        vec = {0: 0.1, 1000: 0.5, 50000: 0.9}
        blob = serialize_sparse_vector(vec)
        recovered = deserialize_sparse_vector(blob)
        for k in vec:
            assert abs(recovered[k] - vec[k]) < 1e-4

    def test_sorted_output(self):
        """Keys should be sorted in serialized output."""
        vec = {100: 0.3, 1: 0.1, 50: 0.2}
        blob = serialize_sparse_vector(vec)
        recovered = deserialize_sparse_vector(blob)
        assert list(recovered.keys()) == [1, 50, 100]


# ---------------------------------------------------------------------------
# Cosine similarity tests
# ---------------------------------------------------------------------------

class TestSparseCosine:
    """Tests for sparse cosine similarity."""

    def test_identical_vectors(self):
        vec = {0: 1.0, 1: 2.0, 2: 3.0}
        assert abs(sparse_cosine_similarity(vec, vec) - 1.0) < 1e-6

    def test_orthogonal_vectors(self):
        a = {0: 1.0, 1: 0.0}
        b = {2: 1.0, 3: 0.0}
        assert sparse_cosine_similarity(a, b) == 0.0

    def test_no_shared_keys(self):
        a = {0: 1.0, 1: 2.0}
        b = {10: 1.0, 11: 2.0}
        assert sparse_cosine_similarity(a, b) == 0.0

    def test_partial_overlap(self):
        a = {0: 1.0, 1: 1.0, 2: 1.0}
        b = {1: 1.0, 2: 1.0, 3: 1.0}
        # shared: keys 1, 2; dot=2; norm_a=sqrt(3); norm_b=sqrt(3); cos=2/3
        expected = 2.0 / 3.0
        assert abs(sparse_cosine_similarity(a, b) - expected) < 1e-6

    def test_empty_vectors(self):
        assert sparse_cosine_similarity({}, {0: 1.0}) == 0.0
        assert sparse_cosine_similarity({0: 1.0}, {}) == 0.0
        assert sparse_cosine_similarity({}, {}) == 0.0

    def test_result_in_range(self):
        """Cosine similarity should be in [0, 1] for non-negative vectors."""
        a = {0: 0.5, 1: 1.5, 2: 0.3}
        b = {0: 1.0, 1: 0.7, 3: 2.0}
        sim = sparse_cosine_similarity(a, b)
        assert 0.0 <= sim <= 1.0


# ---------------------------------------------------------------------------
# fts5vocab tests
# ---------------------------------------------------------------------------

class TestFts5Vocab:
    """Tests that fts5vocab returns porter-stemmed terms."""

    def test_vocab_returns_stemmed_terms(self, indexed_db):
        conn = sqlite3.connect(indexed_db)
        rows = conn.execute("SELECT term FROM entry_terms ORDER BY term").fetchall()
        terms = {r[0] for r in rows}
        conn.close()

        # "architecture" -> porter stem "architectur"
        assert "architectur" in terms, f"Expected stemmed 'architectur', terms: {sorted(terms)}"
        # "testing" -> porter stem "test"
        assert "test" in terms, f"Expected stemmed 'test', terms: {sorted(terms)}"
        # "boundaries" -> porter stem "boundari"
        assert "boundari" in terms, f"Expected stemmed 'boundari', terms: {sorted(terms)}"

    def test_vocab_doc_frequency(self, indexed_db):
        """Document frequency should reflect how many entries contain the term."""
        conn = sqlite3.connect(indexed_db)
        # "architectur" appears in architecture-guide.md and test-architecture.md
        row = conn.execute(
            "SELECT doc FROM entry_terms WHERE term = 'architectur'"
        ).fetchone()
        conn.close()
        assert row is not None
        assert row[0] >= 2, f"Expected doc freq >= 2 for 'architectur', got {row[0]}"

    def test_instance_vocab_per_doc_terms(self, indexed_db):
        """Instance-level fts5vocab should provide per-document term occurrences."""
        conn = sqlite3.connect(indexed_db)
        rows = conn.execute(
            "SELECT term, doc, col FROM entry_terms_instance WHERE col = 'content' LIMIT 10"
        ).fetchall()
        conn.close()
        assert len(rows) > 0, "Instance vocab should have rows for content column"
        # Each row should have term, doc_rowid, col
        for term, doc_rowid, col in rows:
            assert isinstance(term, str)
            assert isinstance(doc_rowid, int)
            assert col == "content"


# ---------------------------------------------------------------------------
# TF-IDF vector computation tests
# ---------------------------------------------------------------------------

class TestBuildVectors:
    """Tests for Concordance.build_vectors()."""

    def test_builds_vectors_for_all_entries(self, indexed_db):
        conc = Concordance(indexed_db)
        result = conc.build_vectors()
        assert result["vectors_built"] == 4  # 4 entries indexed
        assert result["elapsed_seconds"] >= 0

    def test_vectors_stored_in_db(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        assert len(vecs) == 4
        for v in vecs:
            assert "file_path" in v
            assert "heading" in v
            assert "vector" in v
            assert isinstance(v["vector"], dict)
            assert len(v["vector"]) > 0

    def test_vector_values_are_positive(self, indexed_db):
        """TF-IDF values should all be positive."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        for v in conc.get_all_vectors():
            for idx, score in v["vector"].items():
                assert score > 0, f"Expected positive TF-IDF, got {score} at index {idx}"

    def test_tfidf_manual_verification(self, indexed_db):
        """Verify TF-IDF values match manual calculation for a known term."""
        conc = Concordance(indexed_db)
        conc.build_vectors()

        # Get corpus stats
        conn = sqlite3.connect(indexed_db)
        total_docs = conn.execute("SELECT count(*) FROM entries").fetchone()[0]

        # Get DF for 'architectur' (appears in 2+ docs)
        df_row = conn.execute(
            "SELECT doc FROM entry_terms WHERE term = 'architectur'"
        ).fetchone()
        df = df_row[0]
        expected_idf = math.log(total_docs / df)

        # Get TF for 'architectur' in architecture-guide.md from instance table
        # Find the rowid of architecture-guide entry
        arch_row = conn.execute(
            "SELECT rowid FROM entries WHERE file_path LIKE '%architecture-guide.md'"
        ).fetchone()
        arch_rowid = arch_row[0]

        # Count occurrences of 'architectur' in that doc's content
        tf_rows = conn.execute(
            "SELECT count(*) FROM entry_terms_instance WHERE term = 'architectur' AND doc = ? AND col = 'content'",
            (arch_rowid,),
        ).fetchone()
        tf = tf_rows[0]
        conn.close()

        expected_tfidf = (1.0 + math.log(tf)) * expected_idf

        # Get the actual vector and find the term index for 'architectur'
        term_index = conc.get_term_index()
        assert "architectur" in term_index

        # Get the vector for architecture-guide
        vecs = conc.get_all_vectors()
        arch_vec = None
        for v in vecs:
            if "architecture-guide.md" in v["file_path"]:
                arch_vec = v["vector"]
                break
        assert arch_vec is not None

        tidx = term_index["architectur"]
        assert tidx in arch_vec
        actual_tfidf = arch_vec[tidx]
        assert abs(actual_tfidf - expected_tfidf) < 1e-4, \
            f"TF-IDF mismatch: expected {expected_tfidf:.4f}, got {actual_tfidf:.4f}"

    def test_source_type_filter(self, indexed_db):
        """source_type_filter should limit which entries get vectors."""
        conc = Concordance(indexed_db)
        result = conc.build_vectors(source_type_filter="knowledge")
        assert result["vectors_built"] == 4  # all are knowledge type

        # Filter by nonexistent source type
        result2 = conc.build_vectors(source_type_filter="nonexistent")
        assert result2["vectors_built"] == 0

    def test_empty_index(self, tmp_path):
        """build_vectors on empty index should return 0 vectors."""
        kd = tmp_path / "empty"
        kd.mkdir()
        idx = Indexer(str(kd))
        idx.index_all()
        db_path = os.path.join(str(kd), ".pk_search.db")
        conc = Concordance(db_path)
        result = conc.build_vectors()
        assert result["vectors_built"] == 0

    def test_get_vector_returns_none_for_missing(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        assert conc.get_vector("/nonexistent", "no heading") is None

    def test_get_vector_roundtrip(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        v = vecs[0]
        retrieved = conc.get_vector(v["file_path"], v["heading"])
        assert retrieved is not None
        assert set(retrieved.keys()) == set(v["vector"].keys())
        for k in v["vector"]:
            assert abs(retrieved[k] - v["vector"][k]) < 1e-4


# ---------------------------------------------------------------------------
# Concordance similarity tests
# ---------------------------------------------------------------------------

class TestConcordanceSimilarity:
    """Tests for TF-IDF cosine similarity between entries."""

    def test_related_entries_have_positive_similarity(self, indexed_db):
        """Entries sharing terms (test-architecture + architecture-guide) should have sim > 0."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = {os.path.basename(v["file_path"]): v["vector"] for v in conc.get_all_vectors()}

        sim = sparse_cosine_similarity(
            vecs["test-architecture.md"],
            vecs["architecture-guide.md"],
        )
        assert sim > 0, f"Expected positive similarity, got {sim}"

    def test_related_entries_testing(self, indexed_db):
        """test-architecture and testing-patterns share testing terms."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = {os.path.basename(v["file_path"]): v["vector"] for v in conc.get_all_vectors()}

        sim = sparse_cosine_similarity(
            vecs["test-architecture.md"],
            vecs["testing-patterns.md"],
        )
        assert sim > 0, f"Expected positive similarity, got {sim}"

    def test_unrelated_entries_low_similarity(self, indexed_db):
        """database-naming has very different vocabulary from testing-patterns."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = {os.path.basename(v["file_path"]): v["vector"] for v in conc.get_all_vectors()}

        sim = sparse_cosine_similarity(
            vecs["database-naming.md"],
            vecs["testing-patterns.md"],
        )
        # Should be 0 or very low
        assert sim < 0.1, f"Expected low similarity for unrelated entries, got {sim}"

    def test_self_similarity_is_one(self, indexed_db):
        """Each entry should have cosine similarity 1.0 with itself."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        for v in conc.get_all_vectors():
            sim = sparse_cosine_similarity(v["vector"], v["vector"])
            assert abs(sim - 1.0) < 1e-6, \
                f"Self-similarity should be 1.0 for {v['heading']}, got {sim}"


# ---------------------------------------------------------------------------
# Term index tests
# ---------------------------------------------------------------------------

class TestTermIndex:
    """Tests for Concordance.get_term_index()."""

    def test_returns_porter_stemmed_terms(self, indexed_db):
        conc = Concordance(indexed_db)
        term_idx = conc.get_term_index()
        assert "architectur" in term_idx  # porter stem of "architecture"
        assert "test" in term_idx  # porter stem of "testing"

    def test_indices_are_sequential(self, indexed_db):
        conc = Concordance(indexed_db)
        term_idx = conc.get_term_index()
        indices = sorted(term_idx.values())
        assert indices == list(range(len(indices))), "Term indices should be sequential 0..N-1"

    def test_indices_are_alphabetically_ordered(self, indexed_db):
        conc = Concordance(indexed_db)
        term_idx = conc.get_term_index()
        terms_by_idx = sorted(term_idx.keys(), key=lambda t: term_idx[t])
        assert terms_by_idx == sorted(terms_by_idx), "Terms should be in alphabetical order by index"


# ---------------------------------------------------------------------------
# Integration with Indexer.build_concordance()
# ---------------------------------------------------------------------------

class TestIndexerConcordance:
    """Tests for Indexer.build_concordance() integration."""

    def test_index_all_includes_concordance(self, knowledge_dir):
        idx = Indexer(str(knowledge_dir))
        result = idx.index_all()
        assert "concordance" in result
        assert result["concordance"]["vectors_built"] == 4

    def test_build_concordance_standalone(self, knowledge_dir):
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        result = idx.build_concordance()
        assert result["vectors_built"] == 4

    def test_incremental_no_changes_skips_concordance(self, knowledge_dir):
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        result = idx.incremental_index()
        assert result.get("concordance") == {}

    def test_incremental_with_changes_rebuilds_concordance(self, knowledge_dir):
        idx = Indexer(str(knowledge_dir))
        idx.index_all()

        # Add a new file
        new_file = knowledge_dir / "conventions" / "new-convention.md"
        new_file.write_text(
            "# New Convention\nA brand new convention about something.\n",
            encoding="utf-8",
        )

        result = idx.incremental_index()
        assert result["files_reindexed"] == 1
        assert result["concordance"]["vectors_built"] == 5  # now 5 entries


# ---------------------------------------------------------------------------
# Phase 2: composite_search TF-IDF rankings
# ---------------------------------------------------------------------------

class TestCompositeSearchTfidf:
    """Tests for composite_search with TF-IDF signal replacing frequency."""

    def test_composite_search_returns_tfidf_score(self, knowledge_dir):
        """composite_search results should include tfidf_score field."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))
        results = s.composite_search("architecture boundaries", limit=5)
        assert len(results) > 0
        for r in results:
            assert "tfidf_score" in r, "Missing tfidf_score field"
            assert "composite_score" in r, "Missing composite_score field"

    def test_tfidf_boosts_relevant_results(self, knowledge_dir):
        """Architecture query should give architecture-guide a positive tfidf_score."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))
        results = s.composite_search("architecture modular boundaries", limit=5)
        arch_result = [r for r in results if "architecture-guide" in r["file_path"]]
        assert len(arch_result) > 0, "Expected architecture-guide in results"
        assert arch_result[0]["tfidf_score"] > 0, "Expected positive tfidf_score for architecture query"

    def test_unrelated_query_low_tfidf(self, knowledge_dir):
        """A query about databases should give low tfidf to architecture entries."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))
        results = s.composite_search("database snake_case naming", limit=5)
        for r in results:
            if "architecture-guide" in r["file_path"]:
                assert r["tfidf_score"] < 0.1, \
                    f"Expected low tfidf for architecture on database query, got {r['tfidf_score']}"

    def test_tfidf_weight_parameter(self, knowledge_dir):
        """Adjusting tfidf_weight should change composite scores."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))

        results_default = s.composite_search("architecture", limit=3, tfidf_weight=0.2)
        results_high = s.composite_search("architecture", limit=3, tfidf_weight=0.8)

        # With higher tfidf_weight, TF-IDF has more influence on composite score
        if results_default and results_high:
            # Scores should differ
            default_scores = [r["composite_score"] for r in results_default]
            high_scores = [r["composite_score"] for r in results_high]
            assert default_scores != high_scores, "Changing tfidf_weight should change scores"

    def test_composite_score_components(self, knowledge_dir):
        """Composite score should be weighted sum of bm25, recency, and tfidf."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))

        # Use extreme weights to verify tfidf is contributing
        results_tfidf_only = s.composite_search(
            "architecture", limit=3,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        if results_tfidf_only:
            for r in results_tfidf_only:
                # With tfidf_weight=1.0 and others=0.0, composite should equal tfidf
                # plus a small category-priority tiebreaker bonus (up to 0.04)
                from pk_search import CATEGORY_TIEBREAK_MAX
                assert abs(r["composite_score"] - r["tfidf_score"]) <= CATEGORY_TIEBREAK_MAX + 0.001, \
                    f"With tfidf_weight=1.0, composite should be close to tfidf: {r['composite_score']} vs {r['tfidf_score']}"

    def test_no_frequency_weight_param(self, knowledge_dir):
        """Verify old frequency_weight parameter no longer exists."""
        from pk_search import Searcher
        import inspect
        sig = inspect.signature(Searcher.composite_search)
        assert "tfidf_weight" in sig.parameters
        assert "frequency_weight" not in sig.parameters

    def test_composite_includes_content(self, knowledge_dir):
        """composite_search results should include full content for downstream."""
        from pk_search import Searcher
        idx = Indexer(str(knowledge_dir))
        idx.index_all()
        s = Searcher(str(knowledge_dir))
        results = s.composite_search("architecture", limit=3)
        for r in results:
            assert "content" in r, "Missing content field"
            assert len(r["content"]) > 0, "Content should not be empty"


# ---------------------------------------------------------------------------
# Phase 2: build_query_vector tests
# ---------------------------------------------------------------------------

class TestBuildQueryVector:
    """Tests for Concordance.build_query_vector()."""

    def test_query_vector_has_matching_terms(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vec = conc.build_query_vector("architecture boundaries")
        assert len(vec) > 0, "Query vector should have non-zero terms"
        term_idx = conc.get_term_index()
        # 'architectur' (stemmed) should be in the vector
        assert term_idx["architectur"] in vec, "Expected stemmed 'architectur' in query vector"

    def test_query_vector_similarity_with_entries(self, indexed_db):
        """Query vector for 'architecture' should be similar to architecture entry."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        query_vec = conc.build_query_vector("architecture modular boundaries")
        arch_vec = None
        for v in conc.get_all_vectors():
            if "architecture-guide" in v["file_path"]:
                arch_vec = v["vector"]
                break
        assert arch_vec is not None
        sim = sparse_cosine_similarity(query_vec, arch_vec)
        assert sim > 0, f"Expected positive similarity, got {sim}"

    def test_empty_query_returns_empty_vector(self, indexed_db):
        conc = Concordance(indexed_db)
        assert conc.build_query_vector("") == {}
        assert conc.build_query_vector("   ") == {}

    def test_unknown_terms_ignored(self, indexed_db):
        """Query terms not in corpus vocabulary should be ignored."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vec = conc.build_query_vector("xyzabc123 nonexistent_term")
        assert vec == {}, "Unknown terms should produce empty vector"

    def test_query_vector_uses_porter_stemming(self, indexed_db):
        """'architecture' should stem to 'architectur' in the vector."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        # 'architecture' stems to 'architectur' which appears in 2 of 4 docs (IDF > 0)
        vec = conc.build_query_vector("architecture")
        term_idx = conc.get_term_index()
        assert "architectur" in term_idx
        assert term_idx["architectur"] in vec, "Expected porter-stemmed 'architectur' in query vector for 'architecture'"


# ---------------------------------------------------------------------------
# Phase 2: --expand (find_similar_to) tests
# ---------------------------------------------------------------------------

class TestExpand:
    """Tests for find_similar_to and --expand integration."""

    def test_find_similar_to_returns_related(self, indexed_db):
        """test-architecture should be similar to architecture-guide."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        test_arch = [v for v in vecs if "test-architecture" in v["file_path"]][0]
        similar = conc.find_similar_to(test_arch["file_path"], test_arch["heading"])
        assert len(similar) > 0, "Expected at least one similar entry"
        similar_files = [s["file_path"] for s in similar]
        # architecture-guide or testing-patterns should be in similar
        has_related = any(
            "architecture-guide" in f or "testing-patterns" in f
            for f in similar_files
        )
        assert has_related, f"Expected related entry in similar results: {similar_files}"

    def test_find_similar_excludes_self(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar_to(entry["file_path"], entry["heading"])
        for s in similar:
            assert not (s["file_path"] == entry["file_path"] and s["heading"] == entry["heading"]), \
                "find_similar_to should exclude self"

    def test_find_similar_respects_limit(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar_to(entry["file_path"], entry["heading"], limit=1)
        assert len(similar) <= 1

    def test_find_similar_source_type_filter(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar_to(
            entry["file_path"], entry["heading"],
            source_type_filter="nonexistent",
        )
        assert len(similar) == 0, "Filtering by nonexistent source_type should return empty"

    def test_find_similar_with_explicit_exclude(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        # Exclude all other entries
        exclude = {(v["file_path"], v["heading"]) for v in vecs}
        similar = conc.find_similar_to(entry["file_path"], entry["heading"], exclude=exclude)
        assert len(similar) == 0, "All entries excluded, should return empty"

    def test_find_similar_returns_similarity_score(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar_to(entry["file_path"], entry["heading"])
        for s in similar:
            assert "similarity" in s
            assert 0 < s["similarity"] <= 1.0, f"Similarity should be in (0, 1], got {s['similarity']}"

    def test_find_similar_sorted_by_similarity(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar_to(entry["file_path"], entry["heading"], limit=10)
        if len(similar) > 1:
            sims = [s["similarity"] for s in similar]
            assert sims == sorted(sims, reverse=True), "Results should be sorted by similarity descending"


# ---------------------------------------------------------------------------
# Tests: find_similar() (canonical name, not alias)
# ---------------------------------------------------------------------------

class TestFindSimilar:
    """Tests for Concordance.find_similar() — the canonical method name."""

    def test_find_similar_is_callable(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar(entry["file_path"], entry["heading"])
        assert isinstance(similar, list)

    def test_find_similar_and_alias_return_same(self, indexed_db):
        """find_similar() and find_similar_to() should return identical results."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        via_new = conc.find_similar(entry["file_path"], entry["heading"], limit=5)
        via_alias = conc.find_similar_to(entry["file_path"], entry["heading"], limit=5)
        assert len(via_new) == len(via_alias)
        for a, b in zip(via_new, via_alias):
            assert a["file_path"] == b["file_path"]
            assert a["heading"] == b["heading"]
            assert abs(a["similarity"] - b["similarity"]) < 1e-6

    def test_find_similar_default_limit_is_five(self, indexed_db):
        """Default limit should be 5."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        similar = conc.find_similar(entry["file_path"], entry["heading"])
        # We have 4 entries total, self excluded = 3 max, all <= 5
        assert len(similar) <= 5


# ---------------------------------------------------------------------------
# Tests: suggest_related_files()
# ---------------------------------------------------------------------------

@pytest.fixture
def repo_with_sources(tmp_path):
    """Knowledge dir + repo root with source files sharing vocabulary."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "script-patterns.md").write_text(
        "# Script Patterns\n"
        "All shell scripts source lib.sh for common functions like slugify and resolve.\n"
        "Scripts handle deployment, testing, and database migrations.\n",
        encoding="utf-8",
    )
    (conv_dir / "database-naming.md").write_text(
        "# Database Naming\n"
        "Tables use snake_case plural nouns. Columns use snake_case singular.\n"
        "Foreign keys follow the pattern: referenced_table_id.\n",
        encoding="utf-8",
    )

    repo = tmp_path / "repo"
    repo.mkdir()
    scripts_dir = repo / "scripts"
    scripts_dir.mkdir()
    (scripts_dir / "lib.sh").write_text(
        "#!/usr/bin/env bash\n"
        "# lib.sh - common functions for shell scripts\n"
        "slugify() { echo \"$1\" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }\n"
        "resolve() { echo \"resolved\"; }\n"
        "deploy() { rsync -avz . \"$1\"; }\n",
        encoding="utf-8",
    )
    (scripts_dir / "migrate.py").write_text(
        "#!/usr/bin/env python3\n"
        '"""migrate.py - database migration script"""\n'
        "import subprocess\n"
        "def migrate_database(target):\n"
        "    subprocess.run(['psql', '-c', 'ALTER TABLE ...'])\n",
        encoding="utf-8",
    )

    return kd, repo


@pytest.fixture
def indexed_with_sources(repo_with_sources):
    """Index knowledge + source files and return (db_path, kd, repo)."""
    kd, repo = repo_with_sources
    indexer = Indexer(str(kd), repo_root=str(repo))
    indexer.index_all(force=True)
    return indexer.db_path, kd, repo


class TestSuggestRelatedFiles:
    """Tests for Concordance.suggest_related_files()."""

    def test_returns_only_source_type(self, indexed_with_sources):
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        results = conc.suggest_related_files(target, "Script Patterns")
        for r in results:
            assert r["source_type"] == "source", f"Expected source type, got {r['source_type']}"

    def test_respects_threshold(self, indexed_with_sources):
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        # Very high threshold should return fewer or no results
        results_high = conc.suggest_related_files(target, "Script Patterns", threshold=0.99)
        results_low = conc.suggest_related_files(target, "Script Patterns", threshold=0.0)
        assert len(results_high) <= len(results_low)

    def test_all_results_above_threshold(self, indexed_with_sources):
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        threshold = 0.1
        target = str(kd / "conventions" / "script-patterns.md")
        results = conc.suggest_related_files(target, "Script Patterns", threshold=threshold)
        for r in results:
            assert r["similarity"] >= threshold, \
                f"Result below threshold: {r['similarity']} < {threshold}"

    def test_respects_limit(self, indexed_with_sources):
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        results = conc.suggest_related_files(target, "Script Patterns", limit=1)
        assert len(results) <= 1

    def test_nonexistent_entry_returns_empty(self, indexed_with_sources):
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        results = conc.suggest_related_files("/nonexistent/path.md", "No Such Entry")
        assert results == []

    def test_no_sources_indexed_returns_empty(self, knowledge_dir):
        """Without source files, suggest_related_files returns empty."""
        idx = Indexer(str(knowledge_dir))  # no repo_root
        idx.index_all()
        db_path = os.path.join(str(knowledge_dir), ".pk_search.db")
        conc = Concordance(db_path)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        results = conc.suggest_related_files(entry["file_path"], entry["heading"])
        assert results == [], "No source files indexed, should return empty"


# ---------------------------------------------------------------------------
# Tests: run_full_analysis()
# ---------------------------------------------------------------------------

class TestRunFullAnalysis:
    """Tests for Concordance.run_full_analysis()."""

    def test_analyzes_all_knowledge_entries(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        result = conc.run_full_analysis()
        assert result["entries_analyzed"] == 4  # 4 knowledge entries

    def test_produces_see_also_pairs(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        result = conc.run_full_analysis(see_also_limit=3)
        assert result["see_also_pairs"] > 0, "Should produce see-also pairs"

    def test_stores_results_in_db(self, indexed_db):
        import sqlite3
        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()
        conn = sqlite3.connect(indexed_db)
        rows = conn.execute("SELECT count(*) FROM concordance_results").fetchone()
        conn.close()
        assert rows[0] > 0, "concordance_results table should have entries"

    def test_result_types_in_db(self, indexed_db):
        import sqlite3
        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()
        conn = sqlite3.connect(indexed_db)
        types = {row[0] for row in conn.execute(
            "SELECT DISTINCT result_type FROM concordance_results"
        ).fetchall()}
        conn.close()
        assert "see_also" in types, "Should have see_also results"

    def test_see_also_limit_respected(self, indexed_db):
        import sqlite3
        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis(see_also_limit=1)
        conn = sqlite3.connect(indexed_db)
        # Each entry should have at most 1 see_also result
        rows = conn.execute(
            "SELECT file_path, heading, count(*) FROM concordance_results "
            "WHERE result_type = 'see_also' GROUP BY file_path, heading"
        ).fetchall()
        conn.close()
        for fp, heading, count in rows:
            assert count <= 1, \
                f"Entry {heading} has {count} see_also results, expected <= 1"

    def test_elapsed_seconds_non_negative(self, indexed_db):
        conc = Concordance(indexed_db)
        conc.build_vectors()
        result = conc.run_full_analysis()
        assert result["elapsed_seconds"] >= 0

    def test_rerun_clears_previous_results(self, indexed_db):
        import sqlite3
        conc = Concordance(indexed_db)
        conc.build_vectors()
        conc.run_full_analysis()
        conn = sqlite3.connect(indexed_db)
        count1 = conn.execute("SELECT count(*) FROM concordance_results").fetchone()[0]
        conn.close()
        # Run again — should replace, not accumulate
        conc.run_full_analysis()
        conn = sqlite3.connect(indexed_db)
        count2 = conn.execute("SELECT count(*) FROM concordance_results").fetchone()[0]
        conn.close()
        assert count1 == count2, "Re-running should clear previous results, not accumulate"

    def test_with_source_files(self, indexed_with_sources):
        """With source files indexed, should produce related_file pairs."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        result = conc.run_full_analysis(related_files_threshold=0.0)
        # With threshold=0.0, any source file with non-zero similarity should appear
        assert result["entries_analyzed"] > 0

    def test_empty_index(self, tmp_path):
        """run_full_analysis on empty index should return zero counts."""
        kd = tmp_path / "empty"
        kd.mkdir()
        idx = Indexer(str(kd))
        idx.index_all()
        db_path = os.path.join(str(kd), ".pk_search.db")
        conc = Concordance(db_path)
        conc.build_vectors()
        result = conc.run_full_analysis()
        assert result["entries_analyzed"] == 0
        assert result["see_also_pairs"] == 0
        assert result["related_file_pairs"] == 0


# ---------------------------------------------------------------------------
# Tests: get_codebase_vocabulary()
# ---------------------------------------------------------------------------

class TestGetCodebaseVocabulary:
    """Tests for Concordance.get_codebase_vocabulary()."""

    def test_returns_set_of_ints(self, indexed_with_sources):
        """get_codebase_vocabulary should return a set of integer term indices."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        assert isinstance(vocab, set)
        for idx in vocab:
            assert isinstance(idx, int)

    def test_nonempty_with_source_files(self, indexed_with_sources):
        """With source files indexed, vocabulary should be non-empty."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        assert len(vocab) > 0, "Codebase vocabulary should be non-empty when source files are indexed"

    def test_empty_without_source_files(self, indexed_db):
        """Without source files indexed, vocabulary should be empty."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        assert vocab == set(), "Codebase vocabulary should be empty when no source files are indexed"

    def test_vocabulary_is_subset_of_term_index(self, indexed_with_sources):
        """All vocabulary indices should be valid term indices."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        term_index = conc.get_term_index()
        all_indices = set(term_index.values())
        assert vocab.issubset(all_indices), "Vocabulary indices should be valid term indices"

    def test_vocabulary_contains_source_terms(self, indexed_with_sources):
        """Vocabulary should contain terms from source file content."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        term_index = conc.get_term_index()
        # 'slugifi' is the porter stem of 'slugify' which appears in lib.sh
        if "slugifi" in term_index:
            assert term_index["slugifi"] in vocab, \
                "Expected 'slugifi' (stem of 'slugify') in codebase vocabulary"

    def test_empty_index_returns_empty(self, tmp_path):
        """get_codebase_vocabulary on empty index should return empty set."""
        kd = tmp_path / "empty"
        kd.mkdir()
        idx = Indexer(str(kd))
        idx.index_all()
        db_path = os.path.join(str(kd), ".pk_search.db")
        conc = Concordance(db_path)
        conc.build_vectors()
        vocab = conc.get_codebase_vocabulary()
        assert vocab == set()


# ---------------------------------------------------------------------------
# Regression tests: composite_search TF-IDF rankings
# ---------------------------------------------------------------------------

@pytest.fixture
def multi_domain_kd(tmp_path):
    """Knowledge dir with 6 entries across 3 distinct domains for regression tests.

    Domains:
      - Database (2 entries): sharding, replication
      - Deployment (2 entries): CI/CD pipelines, container orchestration
      - Testing (2 entries): unit test patterns, integration test patterns
    """
    kd = tmp_path / "knowledge"
    kd.mkdir()

    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "database-sharding.md").write_text(
        "# Database Sharding\n"
        "PostgreSQL is sharded by tenant using Citus distributed database. "
        "Each shard handles roughly ten thousand tenants. Cross-shard database "
        "queries go through a coordinator node. Database sharding is essential "
        "for horizontal scaling of the tenant database.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    (arch_dir / "database-replication.md").write_text(
        "# Database Replication\n"
        "PostgreSQL streaming replication provides high availability for the database. "
        "A standby replica receives WAL records from the primary database server. "
        "Failover to the replica database takes about 30 seconds.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    (arch_dir / "container-orchestration.md").write_text(
        "# Container Orchestration\n"
        "Kubernetes orchestrates container deployment across the cluster. "
        "Pods run containers with resource limits. Services expose container "
        "endpoints. Helm charts template container deployment manifests.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "ci-cd-pipelines.md").write_text(
        "# CI/CD Pipelines\n"
        "Continuous integration runs on every push. Continuous deployment "
        "triggers after merge to main. Pipeline stages: lint, test, build, "
        "deploy. Container images are built and pushed to registry.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    (conv_dir / "unit-test-patterns.md").write_text(
        "# Unit Test Patterns\n"
        "Unit tests should cover edge cases, error paths, and boundary conditions. "
        "Each test focuses on a single unit of behavior. Mocks isolate external "
        "dependencies. Test fixtures provide repeatable test state.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    (conv_dir / "integration-test-patterns.md").write_text(
        "# Integration Test Patterns\n"
        "Integration tests verify component interaction across boundaries. "
        "Test fixtures set up real service connections. Integration tests run "
        "slower than unit tests but catch interface mismatches.\n"
        "<!-- learned: 2026-02-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def multi_domain_searcher(multi_domain_kd):
    """Index the knowledge dir and return a Searcher."""
    from pk_search import Searcher
    idx = Indexer(str(multi_domain_kd))
    idx.index_all(force=True)
    return Searcher(str(multi_domain_kd))


class TestCompositeSearchTfidfRegression:
    """Regression tests: TF-IDF signal produces semantically correct rankings.

    IMPORTANT: Test function names must use neutral prefixes (r1_, r2_, etc.)
    because pytest creates tmp_path directories named after the test function.
    FTS5 indexes the file_path column, so query terms in the directory path
    leak into the vocabulary and distort IDF calculations.
    """

    def test_r1_storage_query_ranks_storage_above_qa(self, multi_domain_searcher):
        """Query 'database' should rank database entries above testing entries."""
        results = multi_domain_searcher.composite_search(
            "database", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        assert len(results) >= 2
        result_map = {r["heading"]: r for r in results}
        db_entries = [r for h, r in result_map.items() if "Database" in h]
        test_entries = [r for h, r in result_map.items() if "Test" in h]
        assert len(db_entries) >= 1
        if test_entries:
            max_db_tfidf = max(r["tfidf_score"] for r in db_entries)
            max_test_tfidf = max(r["tfidf_score"] for r in test_entries)
            assert max_db_tfidf > max_test_tfidf, (
                f"Database TF-IDF ({max_db_tfidf}) should exceed "
                f"Testing TF-IDF ({max_test_tfidf}) for 'database' query"
            )

    def test_r2_qa_query_ranks_qa_above_cicd(self, multi_domain_searcher):
        """Query 'fixtures' should rank testing entries above CI/CD entry.

        Uses 'fixtures' instead of 'test' because pytest tmp_path always contains
        'test_' in the path, which would make 'test' appear in all entries via
        the indexed file_path column (IDF=0 → empty query vector).
        """
        results = multi_domain_searcher.composite_search(
            "fixtures", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        assert len(results) >= 1
        result_map = {r["heading"]: r for r in results}
        test_entries = [r for h, r in result_map.items() if "Test" in h]
        assert len(test_entries) >= 1, (
            f"Expected testing entries for 'fixtures' query, got: "
            f"{[r['heading'] for r in results]}"
        )

    def test_r3_infra_query_ranks_orchestration_above_cicd(self, multi_domain_searcher):
        """Query 'container' should rank Container Orchestration above CI/CD."""
        results = multi_domain_searcher.composite_search(
            "container", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        assert len(results) >= 1
        result_map = {r["heading"]: r for r in results}
        orchestration = result_map.get("Container Orchestration")
        cicd = result_map.get("CI/CD Pipelines")
        assert orchestration is not None, "Container Orchestration should be in results"
        if cicd:
            assert orchestration["tfidf_score"] > cicd["tfidf_score"], (
                f"Container Orchestration ({orchestration['tfidf_score']}) should exceed "
                f"CI/CD ({cicd['tfidf_score']}) for 'container' query"
            )

    def test_r4_specific_query_ranks_exact_match(self, multi_domain_searcher):
        """Query 'database sharding' should rank Database Sharding first."""
        results = multi_domain_searcher.composite_search(
            "database sharding", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        assert len(results) >= 1
        assert results[0]["heading"] == "Database Sharding", \
            f"Expected 'Database Sharding' at top, got '{results[0]['heading']}'"

    def test_r5_tfidf_positive_for_matches(self, multi_domain_searcher):
        """TF-IDF score should be positive for entries matching the query."""
        results = multi_domain_searcher.composite_search(
            "database", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        for r in results:
            assert r["tfidf_score"] > 0, \
                f"TF-IDF should be positive for BM25 matches, got {r['tfidf_score']} for {r['heading']}"

    def test_r6_tfidf_weight_changes_scores(self, multi_domain_searcher):
        """With TF-IDF weight, composite scores should differ from BM25-only scores."""
        results_bm25_only = multi_domain_searcher.composite_search(
            "database", limit=6,
            bm25_weight=1.0, recency_weight=0.0, tfidf_weight=0.0,
        )
        results_with_tfidf = multi_domain_searcher.composite_search(
            "database", limit=6,
            bm25_weight=0.5, recency_weight=0.0, tfidf_weight=0.5,
        )
        scores_bm25 = [r["composite_score"] for r in results_bm25_only]
        scores_tfidf = [r["composite_score"] for r in results_with_tfidf]
        assert scores_bm25 != scores_tfidf, \
            "Adding TF-IDF weight should change composite scores vs BM25-only"

    def test_r7_intra_domain_ranking(self, multi_domain_searcher):
        """Query 'unit test patterns' should rank Unit Test Patterns above Integration."""
        results = multi_domain_searcher.composite_search(
            "unit test patterns", limit=6,
            bm25_weight=0.0, recency_weight=0.0, tfidf_weight=1.0,
        )
        assert len(results) >= 1
        result_map = {r["heading"]: r for r in results}
        unit = result_map.get("Unit Test Patterns")
        integration = result_map.get("Integration Test Patterns")
        assert unit is not None, "Unit Test Patterns should be in results"
        if integration:
            assert unit["tfidf_score"] >= integration["tfidf_score"], (
                f"Unit ({unit['tfidf_score']}) should rank >= "
                f"Integration ({integration['tfidf_score']}) for 'unit test patterns'"
            )


# ---------------------------------------------------------------------------
# Phase 2: budget_search tests
# ---------------------------------------------------------------------------

class TestBudgetSearch:
    """Tests for Searcher.budget_search() — budget enforcement, tiered partitioning."""

    @pytest.fixture
    def budget_knowledge_dir(self, tmp_path):
        """Knowledge dir with entries of known sizes across categories."""
        kd = tmp_path / "knowledge"
        kd.mkdir()

        # principles/ — short entry (~80 chars)
        principles_dir = kd / "principles"
        principles_dir.mkdir()
        (principles_dir / "core-values.md").write_text(
            "# Core Values\n"
            "Ship quality code. Test thoroughly. Document decisions.\n",
            encoding="utf-8",
        )

        # conventions/ — medium entry (~150 chars)
        conv_dir = kd / "conventions"
        conv_dir.mkdir()
        (conv_dir / "naming-patterns.md").write_text(
            "# Naming Patterns\n"
            "Variables use camelCase. Classes use PascalCase. Constants use UPPER_SNAKE_CASE. "
            "File names use kebab-case. Database columns use snake_case.\n",
            encoding="utf-8",
        )

        # architecture/ — longer entry (~200 chars)
        arch_dir = kd / "architecture"
        arch_dir.mkdir()
        (arch_dir / "service-design.md").write_text(
            "# Service Design\n"
            "Microservices communicate via gRPC. Each service owns its database. "
            "Shared state goes through event bus. Service mesh handles routing, "
            "retries, and circuit breaking transparently.\n",
            encoding="utf-8",
        )

        # gotchas/ — entry with shared vocabulary
        gotchas_dir = kd / "gotchas"
        gotchas_dir.mkdir()
        (gotchas_dir / "naming-collisions.md").write_text(
            "# Naming Collisions\n"
            "Service names must be unique across the cluster. "
            "Check the service registry before naming a new service.\n",
            encoding="utf-8",
        )

        return kd

    def test_budget_search_returns_both_tiers(self, budget_knowledge_dir):
        """budget_search should return full and titles_only lists."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=5000, limit=10)
        assert "full" in result
        assert "titles_only" in result
        assert "budget_used" in result
        assert "budget_total" in result
        assert result["budget_total"] == 5000

    def test_budget_enforcement_full_within_budget(self, budget_knowledge_dir):
        """Full entries' total content should not exceed budget."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=200, limit=10)
        total_chars = sum(len(r.get("content", "")) for r in result["full"])
        assert total_chars <= 200, f"Full entries exceed budget: {total_chars} > 200"
        assert result["budget_used"] <= 200

    def test_budget_overflow_goes_to_titles_only(self, budget_knowledge_dir):
        """Entries that exceed budget should appear in titles_only."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        # Very small budget forces most results to titles_only
        result = s.budget_search("naming service", budget_chars=100, limit=10)
        total_results = len(result["full"]) + len(result["titles_only"])
        assert total_results > 0, "Should have at least some results"

        # titles_only entries should have heading and file_path but NOT content
        for r in result["titles_only"]:
            assert "heading" in r
            assert "file_path" in r
            assert "content" not in r

    def test_budget_zero_all_titles_only(self, budget_knowledge_dir):
        """With budget=0, all results should go to titles_only."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=0, limit=10)
        assert len(result["full"]) == 0, "No entries should fit in zero budget"
        assert result["budget_used"] == 0

    def test_budget_large_all_full(self, budget_knowledge_dir):
        """With a very large budget, all results should be in full."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=100000, limit=10)
        assert len(result["titles_only"]) == 0, "All entries should fit in large budget"
        if result["full"]:
            assert result["budget_used"] > 0

    def test_budget_search_empty_query(self, budget_knowledge_dir):
        """Empty query results in no results."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("xyznonexistent_zqzqzq", budget_chars=5000, limit=10)
        assert len(result["full"]) == 0
        assert len(result["titles_only"]) == 0
        assert result["budget_used"] == 0

    def test_full_entries_have_content(self, budget_knowledge_dir):
        """Full-tier entries should include the content field."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=5000, limit=10)
        for r in result["full"]:
            assert "content" in r, "Full entries must include content"
            assert len(r["content"]) > 0, "Content should not be empty"

    def test_titles_only_has_composite_score(self, budget_knowledge_dir):
        """titles_only entries should still have composite_score for ordering."""
        from pk_search import Searcher
        idx = Indexer(str(budget_knowledge_dir))
        idx.index_all()
        s = Searcher(str(budget_knowledge_dir))

        result = s.budget_search("naming service", budget_chars=50, limit=10)
        for r in result["titles_only"]:
            assert "composite_score" in r, "titles_only should include composite_score"


# ---------------------------------------------------------------------------
# Phase 2: Category-priority tiebreaker tests
# ---------------------------------------------------------------------------

class TestCategoryTiebreaker:
    """Tests for category-priority tiebreaker in composite scoring."""

    def test_category_priority_constants_defined(self):
        """CATEGORY_PRIORITY and related constants should be importable."""
        from pk_search import CATEGORY_PRIORITY, CATEGORY_PRIORITY_MAP, CATEGORY_TIEBREAK_MAX
        assert len(CATEGORY_PRIORITY) == 7
        assert "principles" in CATEGORY_PRIORITY_MAP
        assert "domains" in CATEGORY_PRIORITY_MAP
        assert CATEGORY_TIEBREAK_MAX > 0
        assert CATEGORY_TIEBREAK_MAX < 0.05  # must be within tiebreak zone

    def test_principles_has_highest_priority(self):
        """Principles should have the highest priority rank."""
        from pk_search import CATEGORY_PRIORITY_MAP
        assert CATEGORY_PRIORITY_MAP["principles"] > CATEGORY_PRIORITY_MAP["domains"]
        assert CATEGORY_PRIORITY_MAP["principles"] > CATEGORY_PRIORITY_MAP["architecture"]
        assert CATEGORY_PRIORITY_MAP["principles"] > CATEGORY_PRIORITY_MAP["conventions"]

    def test_priority_order_matches_spec(self):
        """Priority order: principles > workflows > conventions > gotchas > abstractions > architecture > domains."""
        from pk_search import CATEGORY_PRIORITY_MAP
        order = ["principles", "workflows", "conventions", "gotchas", "abstractions", "architecture", "domains"]
        for i in range(len(order) - 1):
            assert CATEGORY_PRIORITY_MAP[order[i]] > CATEGORY_PRIORITY_MAP[order[i + 1]], \
                f"{order[i]} should have higher priority than {order[i + 1]}"

    @pytest.fixture
    def tiebreaker_knowledge_dir(self, tmp_path):
        """Knowledge dir with similar-content entries in different categories."""
        kd = tmp_path / "knowledge"
        kd.mkdir()

        # Create entries with identical vocabulary across different categories
        # so they would have nearly identical BM25 and TF-IDF scores.
        categories = ["principles", "conventions", "architecture"]
        for cat in categories:
            cat_dir = kd / cat
            cat_dir.mkdir()
            (cat_dir / "code-review.md").write_text(
                f"# Code Review ({cat.title()})\n"
                "Code review ensures quality and knowledge sharing across the team. "
                "Every pull request requires at least one approval before merging.\n",
                encoding="utf-8",
            )

        return kd

    def test_tiebreaker_favors_higher_priority_category(self, tiebreaker_knowledge_dir):
        """When scores are similar, higher-priority category should rank first."""
        from pk_search import Searcher, CATEGORY_PRIORITY_MAP
        idx = Indexer(str(tiebreaker_knowledge_dir))
        idx.index_all()
        s = Searcher(str(tiebreaker_knowledge_dir))

        results = s.composite_search("code review quality", limit=10)
        assert len(results) >= 2, "Need at least 2 results for tiebreaker test"

        # Find entries from different categories
        result_categories = [r.get("category") for r in results if r.get("category")]
        assert len(result_categories) >= 2, f"Need entries from multiple categories: {result_categories}"

        # The first result should be from the highest-priority category
        first_cat = results[0].get("category")
        for r in results[1:]:
            other_cat = r.get("category")
            if other_cat and first_cat:
                first_rank = CATEGORY_PRIORITY_MAP.get(first_cat, 0)
                other_rank = CATEGORY_PRIORITY_MAP.get(other_cat, 0)
                # First result's category should have >= priority
                assert first_rank >= other_rank, \
                    f"First result ({first_cat}, rank={first_rank}) should have >= priority than {other_cat} (rank={other_rank})"


# ---------------------------------------------------------------------------
# Tests: compute_vocabulary_drift()
# ---------------------------------------------------------------------------

class TestComputeVocabularyDrift:
    """Tests for Concordance.compute_vocabulary_drift()."""

    def test_nonexistent_entry_returns_unavailable(self, indexed_with_sources):
        """Entry not in DB should return available=False."""
        db_path, _, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        result = conc.compute_vocabulary_drift("/nonexistent/path.md", "No Such Entry")
        assert result["available"] is False
        assert result["score"] == 0.0
        assert result["detail"]["top_k_terms"] == 0

    def test_entry_with_source_overlap_scores_low(self, indexed_with_sources):
        """Entry whose terms overlap with source files should have low drift score."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result = conc.compute_vocabulary_drift(target, "Script Patterns")
        assert result["available"] is True
        # script-patterns.md shares vocabulary with lib.sh (slugify, resolve, script, etc.)
        # So drift score should be less than 1.0
        assert result["score"] < 1.0

    def test_returns_correct_structure(self, indexed_with_sources):
        """Result should have score, available, and detail with expected keys."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result = conc.compute_vocabulary_drift(target, "Script Patterns")
        assert "score" in result
        assert "available" in result
        assert "detail" in result
        detail = result["detail"]
        assert "top_k_terms" in detail
        assert "absent_terms" in detail
        assert "absent_term_names" in detail
        assert isinstance(detail["absent_term_names"], list)

    def test_top_k_parameter(self, indexed_with_sources):
        """top_k parameter should limit how many terms are checked."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result_5 = conc.compute_vocabulary_drift(target, "Script Patterns", top_k=5)
        result_3 = conc.compute_vocabulary_drift(target, "Script Patterns", top_k=3)
        assert result_5["detail"]["top_k_terms"] <= 5
        assert result_3["detail"]["top_k_terms"] <= 3

    def test_absent_terms_count_consistent(self, indexed_with_sources):
        """absent_terms count should match length of absent_term_names."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result = conc.compute_vocabulary_drift(target, "Script Patterns")
        assert result["detail"]["absent_terms"] == len(result["detail"]["absent_term_names"])

    def test_score_is_fraction_of_absent(self, indexed_with_sources):
        """Score should equal absent_terms / top_k_terms."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result = conc.compute_vocabulary_drift(target, "Script Patterns")
        if result["available"] and result["detail"]["top_k_terms"] > 0:
            expected = result["detail"]["absent_terms"] / result["detail"]["top_k_terms"]
            assert abs(result["score"] - round(expected, 4)) < 1e-4

    def test_no_source_vectors_returns_unavailable(self, indexed_db):
        """When no source files are indexed, codebase vocabulary is empty -> unavailable."""
        conc = Concordance(indexed_db)
        conc.build_vectors()
        vecs = conc.get_all_vectors()
        entry = vecs[0]
        result = conc.compute_vocabulary_drift(entry["file_path"], entry["heading"])
        # No source vectors -> codebase vocabulary is empty -> available=False
        assert result["available"] is False

    def test_absent_term_names_are_strings(self, indexed_with_sources):
        """absent_term_names should contain human-readable string terms."""
        db_path, kd, _ = indexed_with_sources
        conc = Concordance(db_path)
        conc.build_vectors()
        target = str(kd / "conventions" / "script-patterns.md")
        result = conc.compute_vocabulary_drift(target, "Script Patterns")
        for name in result["detail"]["absent_term_names"]:
            assert isinstance(name, str)
            assert not name.startswith("<unknown:")
