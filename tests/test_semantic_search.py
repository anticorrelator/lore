"""
Tests for pk_semantic.py — semantic search module.

Uses mock embeddings throughout so that sentence-transformers is NOT required to run tests.
The mock produces deterministic vectors based on word overlap, allowing controlled testing
of cosine similarity, caching, hybrid scoring, and serialization.
"""

import math
import os
import sqlite3
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

# Add scripts directory to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import pk_semantic


# --- Mock embedding helpers ---

# Fixed vocabulary for deterministic mock embeddings.
# Each word maps to a dimension index. The mock embedding for a text
# is a bag-of-words vector over this vocabulary, then L2-normalized.
MOCK_VOCAB = [
    "python", "search", "vector", "database", "sqlite", "embedding",
    "semantic", "query", "index", "knowledge", "text", "file",
    "section", "heading", "content", "score", "result", "cache",
    "hash", "model", "hybrid", "bm25", "ranking", "token",
    "function", "module", "test", "data", "retrieval", "store",
]
MOCK_DIM = len(MOCK_VOCAB)


def mock_embed(text):
    """
    Deterministic mock embedding based on word overlap with MOCK_VOCAB.
    Returns a normalized vector of length MOCK_DIM.
    """
    words = set(text.lower().split())
    vec = [0.0] * MOCK_DIM
    for i, word in enumerate(MOCK_VOCAB):
        if word in words:
            vec[i] = 1.0
    # L2 normalize
    norm = math.sqrt(sum(x * x for x in vec))
    if norm > 0:
        vec = [x / norm for x in vec]
    return vec


def mock_embed_batch(texts):
    """Mock batch embedding."""
    return [mock_embed(t) for t in texts]


# --- Test Classes ---


class TestCosimeSimilarity(unittest.TestCase):
    """Test pure-Python cosine similarity implementation."""

    def test_identical_vectors(self):
        v = [1.0, 2.0, 3.0]
        self.assertAlmostEqual(pk_semantic.cosine_similarity(v, v), 1.0, places=6)

    def test_orthogonal_vectors(self):
        a = [1.0, 0.0, 0.0]
        b = [0.0, 1.0, 0.0]
        self.assertAlmostEqual(pk_semantic.cosine_similarity(a, b), 0.0, places=6)

    def test_opposite_vectors(self):
        a = [1.0, 0.0]
        b = [-1.0, 0.0]
        self.assertAlmostEqual(pk_semantic.cosine_similarity(a, b), -1.0, places=6)

    def test_known_value(self):
        a = [1.0, 2.0, 3.0]
        b = [4.0, 5.0, 6.0]
        # dot = 32, |a| = sqrt(14), |b| = sqrt(77)
        expected = 32.0 / (math.sqrt(14) * math.sqrt(77))
        self.assertAlmostEqual(pk_semantic.cosine_similarity(a, b), expected, places=6)

    def test_zero_vector(self):
        a = [0.0, 0.0, 0.0]
        b = [1.0, 2.0, 3.0]
        self.assertAlmostEqual(pk_semantic.cosine_similarity(a, b), 0.0)

    def test_length_mismatch_raises(self):
        with self.assertRaises(ValueError):
            pk_semantic.cosine_similarity([1.0, 2.0], [1.0])

    def test_single_dimension(self):
        self.assertAlmostEqual(pk_semantic.cosine_similarity([3.0], [5.0]), 1.0)
        self.assertAlmostEqual(pk_semantic.cosine_similarity([3.0], [-5.0]), -1.0)


class TestNormalizeVector(unittest.TestCase):
    """Test L2 normalization."""

    def test_unit_vector_unchanged(self):
        v = [1.0, 0.0, 0.0]
        result = pk_semantic.normalize_vector(v)
        for a, b in zip(result, v):
            self.assertAlmostEqual(a, b)

    def test_normalization(self):
        v = [3.0, 4.0]
        result = pk_semantic.normalize_vector(v)
        norm = math.sqrt(sum(x * x for x in result))
        self.assertAlmostEqual(norm, 1.0, places=6)
        self.assertAlmostEqual(result[0], 0.6, places=6)
        self.assertAlmostEqual(result[1], 0.8, places=6)

    def test_zero_vector(self):
        v = [0.0, 0.0, 0.0]
        result = pk_semantic.normalize_vector(v)
        self.assertEqual(result, [0.0, 0.0, 0.0])


class TestVectorSerialization(unittest.TestCase):
    """Test struct-based vector serialization (no pickle)."""

    def test_roundtrip(self):
        original = [1.0, -2.5, 3.14159, 0.0, -0.001]
        data = pk_semantic.serialize_vector(original)
        recovered = pk_semantic.deserialize_vector(data)
        self.assertEqual(len(recovered), len(original))
        for a, b in zip(original, recovered):
            self.assertAlmostEqual(a, b, places=5)

    def test_empty_vector(self):
        data = pk_semantic.serialize_vector([])
        recovered = pk_semantic.deserialize_vector(data)
        self.assertEqual(recovered, [])

    def test_single_float(self):
        data = pk_semantic.serialize_vector([42.0])
        recovered = pk_semantic.deserialize_vector(data)
        self.assertEqual(len(recovered), 1)
        self.assertAlmostEqual(recovered[0], 42.0, places=5)

    def test_large_vector(self):
        original = [float(i) / 100.0 for i in range(384)]  # MiniLM dimension
        data = pk_semantic.serialize_vector(original)
        recovered = pk_semantic.deserialize_vector(data)
        self.assertEqual(len(recovered), 384)
        for a, b in zip(original, recovered):
            self.assertAlmostEqual(a, b, places=5)

    def test_serialized_is_bytes(self):
        data = pk_semantic.serialize_vector([1.0, 2.0, 3.0])
        self.assertIsInstance(data, bytes)
        self.assertEqual(len(data), 3 * struct.calcsize("f"))

    def test_no_pickle(self):
        """Verify serialization uses struct, not pickle (security)."""
        data = pk_semantic.serialize_vector([1.0, 2.0])
        # pickle data starts with 0x80; struct float data should not
        # (unless the float happens to encode to 0x80, which is unlikely for small values)
        # More importantly, the length should be exactly n * 4 bytes
        self.assertEqual(len(data), 2 * 4)


class TestContentHash(unittest.TestCase):
    """Test SHA-256 content hashing for embedding cache."""

    def test_deterministic(self):
        h1 = pk_semantic.content_hash("hello world")
        h2 = pk_semantic.content_hash("hello world")
        self.assertEqual(h1, h2)

    def test_different_content(self):
        h1 = pk_semantic.content_hash("hello")
        h2 = pk_semantic.content_hash("world")
        self.assertNotEqual(h1, h2)

    def test_is_hex_string(self):
        h = pk_semantic.content_hash("test")
        self.assertEqual(len(h), 64)  # SHA-256 hex
        self.assertTrue(all(c in "0123456789abcdef" for c in h))

    def test_whitespace_sensitive(self):
        h1 = pk_semantic.content_hash("hello world")
        h2 = pk_semantic.content_hash("hello  world")
        self.assertNotEqual(h1, h2)


class TestEmbeddingStorage(unittest.TestCase):
    """Test SQLite embedding cache: store, retrieve, dedup."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")
        pk_semantic.ensure_embeddings_table(self.db_path)

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    def test_table_creation(self):
        conn = sqlite3.connect(self.db_path)
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        conn.close()
        table_names = [t[0] for t in tables]
        self.assertIn("embeddings", table_names)

    def test_store_and_retrieve(self):
        vec = [1.0, 2.0, 3.0]
        h = "abc123"
        pk_semantic.store_embedding(self.db_path, h, vec)
        result = pk_semantic.get_embedding(self.db_path, h)
        self.assertIsNotNone(result)
        for a, b in zip(result, vec):
            self.assertAlmostEqual(a, b, places=5)

    def test_missing_hash_returns_none(self):
        result = pk_semantic.get_embedding(self.db_path, "nonexistent")
        self.assertIsNone(result)

    def test_upsert_overwrites(self):
        h = "same_hash"
        pk_semantic.store_embedding(self.db_path, h, [1.0, 2.0])
        pk_semantic.store_embedding(self.db_path, h, [3.0, 4.0])
        result = pk_semantic.get_embedding(self.db_path, h)
        self.assertAlmostEqual(result[0], 3.0, places=5)
        self.assertAlmostEqual(result[1], 4.0, places=5)

    def test_ensure_table_idempotent(self):
        pk_semantic.ensure_embeddings_table(self.db_path)
        pk_semantic.ensure_embeddings_table(self.db_path)
        # Should not raise

    def test_model_name_stored(self):
        pk_semantic.store_embedding(self.db_path, "h1", [1.0], model_name="test-model")
        conn = sqlite3.connect(self.db_path)
        row = conn.execute(
            "SELECT model_name FROM embeddings WHERE content_hash = ?", ("h1",)
        ).fetchone()
        conn.close()
        self.assertEqual(row[0], "test-model")

    def test_created_at_is_recent(self):
        import time
        before = time.time()
        pk_semantic.store_embedding(self.db_path, "h2", [1.0])
        after = time.time()
        conn = sqlite3.connect(self.db_path)
        row = conn.execute(
            "SELECT created_at FROM embeddings WHERE content_hash = ?", ("h2",)
        ).fetchone()
        conn.close()
        self.assertGreaterEqual(row[0], before)
        self.assertLessEqual(row[0], after)


class TestEmbeddingCaching(unittest.TestCase):
    """Test that get_or_embed uses cache properly (no re-embedding)."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")
        pk_semantic.ensure_embeddings_table(self.db_path)

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    @patch("pk_semantic.embed_text")
    def test_caches_on_first_call(self, mock_embed_fn):
        """First call should compute and store the embedding."""
        mock_embed_fn.return_value = [1.0, 2.0, 3.0]
        result = pk_semantic.get_or_embed(self.db_path, "test text")
        mock_embed_fn.assert_called_once()
        self.assertEqual(result, [1.0, 2.0, 3.0])

        # Verify it was stored
        h = pk_semantic.content_hash("test text")
        stored = pk_semantic.get_embedding(self.db_path, h)
        self.assertIsNotNone(stored)

    @patch("pk_semantic.embed_text")
    def test_uses_cache_on_second_call(self, mock_embed_fn):
        """Second call with same text should NOT re-embed."""
        mock_embed_fn.return_value = [1.0, 2.0, 3.0]

        # First call
        pk_semantic.get_or_embed(self.db_path, "same text")
        self.assertEqual(mock_embed_fn.call_count, 1)

        # Second call — should hit cache
        result = pk_semantic.get_or_embed(self.db_path, "same text")
        self.assertEqual(mock_embed_fn.call_count, 1)  # NOT called again
        for a, b in zip(result, [1.0, 2.0, 3.0]):
            self.assertAlmostEqual(a, b, places=5)

    @patch("pk_semantic.embed_text")
    def test_different_text_embeds_separately(self, mock_embed_fn):
        mock_embed_fn.side_effect = [[1.0], [2.0]]
        pk_semantic.get_or_embed(self.db_path, "text A")
        pk_semantic.get_or_embed(self.db_path, "text B")
        self.assertEqual(mock_embed_fn.call_count, 2)


class TestSemanticSearch(unittest.TestCase):
    """Test semantic search with mocked embeddings."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")
        pk_semantic.ensure_embeddings_table(self.db_path)

        self.sections = [
            {
                "file": "conventions.md",
                "heading": "Python Style",
                "content": "python function module test",
            },
            {
                "file": "architecture.md",
                "heading": "Database Design",
                "content": "sqlite database store index query",
            },
            {
                "file": "workflows.md",
                "heading": "Search Workflow",
                "content": "search query vector semantic embedding retrieval",
            },
            {
                "file": "gotchas.md",
                "heading": "Cache Invalidation",
                "content": "cache hash content data",
            },
        ]

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    @patch("pk_semantic.embed_text", side_effect=lambda text, model="all-MiniLM-L6-v2": mock_embed(text))
    @patch("pk_semantic.get_or_embed", side_effect=lambda db, text, model="all-MiniLM-L6-v2": mock_embed(text))
    def test_semantic_search_returns_ranked_results(self, _mock_gor, _mock_et):
        results = pk_semantic.search_semantic(
            "vector search semantic query embedding",
            self.db_path,
            self.sections,
            limit=4,
        )
        # The "Search Workflow" section should rank highest (most word overlap)
        self.assertEqual(results[0]["heading"], "Search Workflow")
        # Scores should be descending
        for i in range(len(results) - 1):
            self.assertGreaterEqual(results[i]["score"], results[i + 1]["score"])

    @patch("pk_semantic.embed_text", side_effect=lambda text, model="all-MiniLM-L6-v2": mock_embed(text))
    @patch("pk_semantic.get_or_embed", side_effect=lambda db, text, model="all-MiniLM-L6-v2": mock_embed(text))
    def test_semantic_search_limit(self, _mock_gor, _mock_et):
        results = pk_semantic.search_semantic(
            "database query",
            self.db_path,
            self.sections,
            limit=2,
        )
        self.assertEqual(len(results), 2)

    @patch("pk_semantic.embed_text", side_effect=lambda text, model="all-MiniLM-L6-v2": mock_embed(text))
    @patch("pk_semantic.get_or_embed", side_effect=lambda db, text, model="all-MiniLM-L6-v2": mock_embed(text))
    def test_semantic_search_result_fields(self, _mock_gor, _mock_et):
        results = pk_semantic.search_semantic(
            "python",
            self.db_path,
            self.sections,
            limit=1,
        )
        self.assertIn("file", results[0])
        self.assertIn("heading", results[0])
        self.assertIn("content", results[0])
        self.assertIn("score", results[0])


class TestNormalizeScores(unittest.TestCase):
    """Test min-max score normalization."""

    def test_basic(self):
        scores = [1.0, 2.0, 3.0, 4.0, 5.0]
        normed = pk_semantic.normalize_scores(scores)
        self.assertAlmostEqual(normed[0], 0.0)
        self.assertAlmostEqual(normed[-1], 1.0)
        self.assertAlmostEqual(normed[2], 0.5)

    def test_all_equal(self):
        scores = [3.0, 3.0, 3.0]
        normed = pk_semantic.normalize_scores(scores)
        # All equal -> all 1.0
        for s in normed:
            self.assertAlmostEqual(s, 1.0)

    def test_empty(self):
        self.assertEqual(pk_semantic.normalize_scores([]), [])

    def test_single_value(self):
        normed = pk_semantic.normalize_scores([5.0])
        self.assertAlmostEqual(normed[0], 1.0)

    def test_negative_values(self):
        scores = [-2.0, 0.0, 2.0]
        normed = pk_semantic.normalize_scores(scores)
        self.assertAlmostEqual(normed[0], 0.0)
        self.assertAlmostEqual(normed[1], 0.5)
        self.assertAlmostEqual(normed[2], 1.0)


class TestHybridSearch(unittest.TestCase):
    """Test hybrid BM25 + vector scoring."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")
        pk_semantic.ensure_embeddings_table(self.db_path)

        self.sections = [
            {"file": "a.md", "heading": "A", "content": "python function module"},
            {"file": "b.md", "heading": "B", "content": "search vector semantic query"},
            {"file": "c.md", "heading": "C", "content": "database sqlite store index"},
        ]

        # Simulated BM25 results (from Phase 2 pk_search.py)
        # FTS5 BM25 scores are negative — more negative = better match
        self.bm25_results = [
            {"file": "a.md", "heading": "A", "score": -2.5},
            {"file": "b.md", "heading": "B", "score": -5.0},
            {"file": "c.md", "heading": "C", "score": -1.0},
        ]

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    @patch("pk_semantic.search_semantic")
    def test_hybrid_combines_scores(self, mock_semantic):
        mock_semantic.return_value = [
            {"file": "a.md", "heading": "A", "content": "...", "score": 0.3},
            {"file": "b.md", "heading": "B", "content": "...", "score": 0.9},
            {"file": "c.md", "heading": "C", "content": "...", "score": 0.1},
        ]
        results = pk_semantic.hybrid_search(
            "query", self.db_path, self.sections, self.bm25_results,
            bm25_weight=0.3, vector_weight=0.7,
        )
        # Results should have hybrid score
        for r in results:
            self.assertIn("score", r)
            self.assertIn("bm25_score", r)
            self.assertIn("vector_score", r)
        # Scores should be in [0, 1] (normalized components)
        for r in results:
            self.assertGreaterEqual(r["score"], 0.0)
            self.assertLessEqual(r["score"], 1.0)

    @patch("pk_semantic.search_semantic")
    def test_hybrid_respects_weights(self, mock_semantic):
        # All semantic scores equal -> ranking determined by BM25
        mock_semantic.return_value = [
            {"file": "a.md", "heading": "A", "content": "...", "score": 0.5},
            {"file": "b.md", "heading": "B", "content": "...", "score": 0.5},
            {"file": "c.md", "heading": "C", "content": "...", "score": 0.5},
        ]
        results = pk_semantic.hybrid_search(
            "query", self.db_path, self.sections, self.bm25_results,
            bm25_weight=1.0, vector_weight=0.0,
        )
        # With only BM25 weight, b.md (score 5.0) should be first
        self.assertEqual(results[0]["file"], "b.md")

    @patch("pk_semantic.search_semantic")
    def test_hybrid_limit(self, mock_semantic):
        mock_semantic.return_value = [
            {"file": "a.md", "heading": "A", "content": "...", "score": 0.5},
            {"file": "b.md", "heading": "B", "content": "...", "score": 0.5},
            {"file": "c.md", "heading": "C", "content": "...", "score": 0.5},
        ]
        results = pk_semantic.hybrid_search(
            "query", self.db_path, self.sections, self.bm25_results,
            limit=1,
        )
        self.assertEqual(len(results), 1)

    @patch("pk_semantic.search_semantic")
    def test_hybrid_handles_disjoint_results(self, mock_semantic):
        """BM25 and semantic may return different result sets."""
        mock_semantic.return_value = [
            {"file": "a.md", "heading": "A", "content": "...", "score": 0.8},
            # b.md and c.md not in semantic results
        ]
        bm25_partial = [
            {"file": "b.md", "heading": "B", "score": -3.0},
            # a.md not in BM25 results
        ]
        results = pk_semantic.hybrid_search(
            "query", self.db_path, self.sections, bm25_partial,
        )
        files = [r["file"] for r in results]
        self.assertIn("a.md", files)
        self.assertIn("b.md", files)


class TestGracefulFallback(unittest.TestCase):
    """Test behavior when sentence-transformers is not installed."""

    def test_fallback_returns_bm25_only(self):
        bm25_results = [
            {"file": "a.md", "heading": "A", "score": -5.0},
            {"file": "b.md", "heading": "B", "score": -3.0},
            {"file": "c.md", "heading": "C", "score": -1.0},
        ]
        sections = [
            {"file": "a.md", "heading": "A", "content": "..."},
            {"file": "b.md", "heading": "B", "content": "..."},
            {"file": "c.md", "heading": "C", "content": "..."},
        ]

        with patch.object(pk_semantic, "_TRANSFORMERS_AVAILABLE", False):
            with patch("pk_semantic._check_transformers", return_value=False):
                results, warning = pk_semantic.hybrid_search_safe(
                    "query", "/tmp/fake.db", sections, bm25_results,
                )

        self.assertIsNotNone(warning)
        self.assertIn("sentence-transformers not installed", warning)
        self.assertEqual(len(results), 3)
        # Fallback sorts by raw score descending: -1.0 > -3.0 > -5.0
        self.assertEqual(results[0]["file"], "c.md")
        self.assertEqual(results[1]["file"], "b.md")

    def test_no_warning_when_available(self):
        with patch.object(pk_semantic, "_TRANSFORMERS_AVAILABLE", True):
            with patch("pk_semantic._check_transformers", return_value=True):
                with patch("pk_semantic.hybrid_search") as mock_hybrid:
                    mock_hybrid.return_value = []
                    results, warning = pk_semantic.hybrid_search_safe(
                        "query", "/tmp/fake.db", [], [],
                    )
        self.assertIsNone(warning)


class TestCheckTransformers(unittest.TestCase):
    """Test the lazy import check for sentence-transformers."""

    def test_check_caches_result(self):
        # Reset cached state
        original = pk_semantic._TRANSFORMERS_AVAILABLE
        try:
            pk_semantic._TRANSFORMERS_AVAILABLE = None
            # Even if sentence-transformers isn't installed, the function should
            # return a boolean and cache it
            result = pk_semantic._check_transformers()
            self.assertIsInstance(result, bool)
            # Second call should use cached value
            result2 = pk_semantic._check_transformers()
            self.assertEqual(result, result2)
        finally:
            pk_semantic._TRANSFORMERS_AVAILABLE = original


class TestMockEmbeddingSanity(unittest.TestCase):
    """Sanity checks on the mock embedding function used in tests."""

    def test_identical_text_same_embedding(self):
        e1 = mock_embed("python search vector")
        e2 = mock_embed("python search vector")
        self.assertEqual(e1, e2)

    def test_similar_text_high_similarity(self):
        e1 = mock_embed("python search vector")
        e2 = mock_embed("python search vector database")
        sim = pk_semantic.cosine_similarity(e1, e2)
        self.assertGreater(sim, 0.8)

    def test_dissimilar_text_low_similarity(self):
        e1 = mock_embed("python function module")
        e2 = mock_embed("database sqlite store")
        sim = pk_semantic.cosine_similarity(e1, e2)
        self.assertLess(sim, 0.1)

    def test_no_vocab_words_zero_vector(self):
        e = mock_embed("xyzzy foobar baz")
        # All zeros -> normalized to all zeros
        self.assertTrue(all(x == 0.0 for x in e))

    def test_normalized(self):
        e = mock_embed("python search vector")
        norm = math.sqrt(sum(x * x for x in e))
        self.assertAlmostEqual(norm, 1.0, places=6)


class TestIntegrationBridge(unittest.TestCase):
    """Test bridge functions for pk_search.py integration."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    def test_load_all_sections_from_fts5_db(self):
        """Load sections from a pk_search.py-style FTS5 database."""
        conn = sqlite3.connect(self.db_path)
        conn.executescript("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
                file_path, heading, content, tokenize='porter unicode61'
            );
        """)
        conn.execute(
            "INSERT INTO entries (file_path, heading, content) VALUES (?, ?, ?)",
            ("/path/to/conventions.md", "Python Style", "Use snake_case for functions"),
        )
        conn.execute(
            "INSERT INTO entries (file_path, heading, content) VALUES (?, ?, ?)",
            ("/path/to/architecture.md", "Database", "SQLite FTS5 for search"),
        )
        conn.commit()
        conn.close()

        sections = pk_semantic.load_all_sections(self.db_path)
        self.assertEqual(len(sections), 2)
        self.assertEqual(sections[0]["file"], "/path/to/conventions.md")
        self.assertEqual(sections[0]["heading"], "Python Style")
        self.assertEqual(sections[0]["content"], "Use snake_case for functions")
        # Verify keys match pk_semantic format (file, not file_path)
        self.assertIn("file", sections[0])
        self.assertNotIn("file_path", sections[0])

    def test_adapt_bm25_results_from_file_path(self):
        """Adapt pk_search.py result format to pk_semantic format."""
        bm25_results = [
            {"file_path": "conventions.md", "heading": "A", "score": -5.0, "snippet": "..."},
            {"file_path": "arch.md", "heading": "B", "score": -3.0, "snippet": "..."},
        ]
        adapted = pk_semantic.adapt_bm25_results(bm25_results)
        self.assertEqual(len(adapted), 2)
        self.assertEqual(adapted[0]["file"], "conventions.md")
        self.assertEqual(adapted[0]["heading"], "A")
        self.assertEqual(adapted[0]["score"], -5.0)
        self.assertNotIn("snippet", adapted[0])
        self.assertNotIn("file_path", adapted[0])

    def test_adapt_bm25_results_from_file_key(self):
        """Also works if results already use 'file' key."""
        bm25_results = [
            {"file": "a.md", "heading": "A", "score": 1.0},
        ]
        adapted = pk_semantic.adapt_bm25_results(bm25_results)
        self.assertEqual(adapted[0]["file"], "a.md")

    def test_format_result_for_cli(self):
        result = {
            "file": "/knowledge/conventions.md",
            "heading": "Python Style",
            "content": "Use snake_case for functions. " * 30,
            "score": 0.8765,
        }
        formatted = pk_semantic.format_result_for_cli(result, knowledge_dir="/knowledge")
        self.assertEqual(formatted["heading"], "Python Style")
        self.assertEqual(formatted["file_path"], "conventions.md")
        self.assertEqual(formatted["score"], 0.8765)
        self.assertLessEqual(len(formatted["snippet"]), 504)  # 500 + "..."

    def test_format_result_short_content(self):
        result = {
            "file": "a.md",
            "heading": "Short",
            "content": "brief",
            "score": 0.5,
        }
        formatted = pk_semantic.format_result_for_cli(result)
        self.assertEqual(formatted["snippet"], "brief")
        self.assertNotIn("...", formatted["snippet"])


class TestHybridEndToEnd(unittest.TestCase):
    """End-to-end tests for hybrid scoring with mock embeddings."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")
        pk_semantic.ensure_embeddings_table(self.db_path)

        self.sections = [
            {"file": "arch.md", "heading": "Service Mesh", "content": "search vector semantic query embedding retrieval"},
            {"file": "conv.md", "heading": "API Style", "content": "python function module test"},
            {"file": "gotchas.md", "heading": "Cache Bug", "content": "cache hash content data store"},
            {"file": "workflows.md", "heading": "Deploy", "content": "database sqlite index query store"},
        ]

        self.bm25_results = [
            {"file": "arch.md", "heading": "Service Mesh", "score": -8.0},
            {"file": "conv.md", "heading": "API Style", "score": -2.0},
            {"file": "gotchas.md", "heading": "Cache Bug", "score": -5.0},
            {"file": "workflows.md", "heading": "Deploy", "score": -3.0},
        ]

    def tearDown(self):
        if os.path.exists(self.db_path):
            os.unlink(self.db_path)
        os.rmdir(self.tmpdir)

    @patch("pk_semantic.embed_text", side_effect=lambda text, model="all-MiniLM-L6-v2": mock_embed(text))
    @patch("pk_semantic.get_or_embed", side_effect=lambda db, text, model="all-MiniLM-L6-v2": mock_embed(text))
    def test_hybrid_ranks_by_combined_score(self, _mock_gor, _mock_et):
        """Hybrid search should combine BM25 and vector scores."""
        results = pk_semantic.hybrid_search(
            "vector search semantic query",
            self.db_path,
            self.sections,
            self.bm25_results,
            bm25_weight=0.3,
            vector_weight=0.7,
        )
        # Service Mesh has the highest vector similarity for the query
        # and also the best BM25 score, so it should rank first
        self.assertEqual(results[0]["heading"], "Service Mesh")
        # All results should have both score components
        for r in results:
            self.assertIn("bm25_normalized", r)
            self.assertIn("vector_normalized", r)
            self.assertGreaterEqual(r["bm25_normalized"], 0.0)
            self.assertLessEqual(r["bm25_normalized"], 1.0)
            self.assertGreaterEqual(r["vector_normalized"], 0.0)
            self.assertLessEqual(r["vector_normalized"], 1.0)

    @patch("pk_semantic.embed_text", side_effect=lambda text, model="all-MiniLM-L6-v2": mock_embed(text))
    @patch("pk_semantic.get_or_embed", side_effect=lambda db, text, model="all-MiniLM-L6-v2": mock_embed(text))
    def test_hybrid_custom_weights(self, _mock_gor, _mock_et):
        """Custom weights should shift ranking."""
        # With 100% BM25 weight, ranking should follow BM25 scores
        results_bm25_only = pk_semantic.hybrid_search(
            "database query",
            self.db_path,
            self.sections,
            self.bm25_results,
            bm25_weight=1.0,
            vector_weight=0.0,
        )
        # BM25 score -8.0 is best (most negative = best in FTS5)
        # After normalization, -8.0 maps to 1.0 (highest)
        self.assertEqual(results_bm25_only[0]["heading"], "Service Mesh")

        # With 100% vector weight, ranking should follow semantic similarity
        results_vec_only = pk_semantic.hybrid_search(
            "database sqlite index query store",
            self.db_path,
            self.sections,
            self.bm25_results,
            bm25_weight=0.0,
            vector_weight=1.0,
        )
        # "Deploy" has content "database sqlite index query store" = exact match
        self.assertEqual(results_vec_only[0]["heading"], "Deploy")

    def test_hybrid_safe_fallback_preserves_order(self):
        """When falling back to BM25 only, results should be sorted by raw BM25 score descending."""
        with patch.object(pk_semantic, "_TRANSFORMERS_AVAILABLE", False):
            with patch("pk_semantic._check_transformers", return_value=False):
                results, warning = pk_semantic.hybrid_search_safe(
                    "database",
                    self.db_path,
                    self.sections,
                    self.bm25_results,
                    bm25_weight=0.3,
                    vector_weight=0.7,
                )
        self.assertIsNotNone(warning)
        # Fallback sorts by raw score descending: -2.0 > -3.0 > -5.0 > -8.0
        self.assertEqual(results[0]["score"], -2.0)


class TestPkSearchEmbeddingsTable(unittest.TestCase):
    """Test that pk_search.py creates the embeddings table in its schema."""

    def test_schema_includes_embeddings(self):
        """The Indexer schema should include the embeddings table."""
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
        from pk_search import Indexer

        tmpdir = tempfile.mkdtemp()
        kd = os.path.join(tmpdir, "knowledge")
        os.makedirs(kd)

        # Write a minimal .md file
        with open(os.path.join(kd, "test.md"), "w") as f:
            f.write("# Test\n\n### Entry\nContent.\n")

        indexer = Indexer(kd)
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        tables = [
            t[0]
            for t in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        ]
        conn.close()

        self.assertIn("embeddings", tables)

        # Cleanup
        import shutil
        shutil.rmtree(tmpdir)


if __name__ == "__main__":
    unittest.main()
