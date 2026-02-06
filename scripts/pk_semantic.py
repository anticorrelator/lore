"""
pk_semantic.py — Semantic search module for project-knowledge.

Provides vector embedding support using sentence-transformers (optional dependency).
Can be imported by pk_search.py for --semantic and --hybrid search modes.

External dependencies:
  - sentence-transformers (optional; graceful fallback if missing)
  - pytest (dev only, for tests)

All other functionality uses Python stdlib only.
"""

import hashlib
import math
import sqlite3
import struct
import time

# --- Lazy model loading ---

_model = None
_TRANSFORMERS_AVAILABLE = None


def _check_transformers():
    """Check if sentence-transformers is importable (cached)."""
    global _TRANSFORMERS_AVAILABLE
    if _TRANSFORMERS_AVAILABLE is None:
        try:
            __import__("sentence_transformers")
            _TRANSFORMERS_AVAILABLE = True
        except ImportError:
            _TRANSFORMERS_AVAILABLE = False
    return _TRANSFORMERS_AVAILABLE


def _get_model(model_name="all-MiniLM-L6-v2"):
    """Load the sentence-transformers model lazily."""
    global _model
    if _model is None:
        if not _check_transformers():
            raise ImportError(
                "sentence-transformers is not installed. "
                "Install it with: pip install sentence-transformers"
            )
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer(model_name)
    return _model


# --- Vector math (pure Python, no numpy dependency) ---


def cosine_similarity(a, b):
    """Compute cosine similarity between two vectors. Returns float in [-1, 1]."""
    if len(a) != len(b):
        raise ValueError(f"Vector length mismatch: {len(a)} vs {len(b)}")
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def normalize_vector(v):
    """L2-normalize a vector to unit length."""
    norm = math.sqrt(sum(x * x for x in v))
    if norm == 0:
        return v
    return [x / norm for x in v]


# --- Vector serialization (struct.pack, not pickle) ---


def serialize_vector(v):
    """Serialize a list of floats to bytes using struct.pack."""
    return struct.pack(f"{len(v)}f", *v)


def deserialize_vector(data):
    """Deserialize bytes back to a list of floats."""
    n = len(data) // struct.calcsize("f")
    return list(struct.unpack(f"{n}f", data))


# --- Content hashing ---


def content_hash(text):
    """SHA-256 hash of text content for cache dedup."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --- Embedding ---


def embed_text(text, model_name="all-MiniLM-L6-v2"):
    """
    Embed a single text string into a vector.

    Args:
        text: The text to embed.
        model_name: The sentence-transformers model to use.

    Returns:
        list[float]: The embedding vector (normalized).
    """
    model = _get_model(model_name)
    embedding = model.encode(text, convert_to_numpy=True)
    return normalize_vector(embedding.tolist())


def embed_texts(texts, model_name="all-MiniLM-L6-v2"):
    """
    Embed multiple texts in a batch (more efficient than calling embed_text in a loop).

    Args:
        texts: List of text strings.
        model_name: The sentence-transformers model to use.

    Returns:
        list[list[float]]: List of embedding vectors (normalized).
    """
    model = _get_model(model_name)
    embeddings = model.encode(texts, convert_to_numpy=True)
    return [normalize_vector(e.tolist()) for e in embeddings]


# --- SQLite schema and storage ---

EMBEDDINGS_SCHEMA = """\
CREATE TABLE IF NOT EXISTS embeddings (
    content_hash TEXT PRIMARY KEY,
    embedding BLOB,
    model_name TEXT,
    created_at REAL
);
"""


def ensure_embeddings_table(db_path):
    """Create the embeddings table if it doesn't exist."""
    conn = sqlite3.connect(db_path)
    conn.execute(EMBEDDINGS_SCHEMA)
    conn.commit()
    conn.close()


def store_embedding(db_path, text_hash, vector, model_name="all-MiniLM-L6-v2"):
    """Store an embedding in the database, keyed by content hash."""
    conn = sqlite3.connect(db_path)
    conn.execute(
        "INSERT OR REPLACE INTO embeddings (content_hash, embedding, model_name, created_at) "
        "VALUES (?, ?, ?, ?)",
        (text_hash, serialize_vector(vector), model_name, time.time()),
    )
    conn.commit()
    conn.close()


def get_embedding(db_path, text_hash):
    """Retrieve a cached embedding by content hash. Returns list[float] or None."""
    conn = sqlite3.connect(db_path)
    row = conn.execute(
        "SELECT embedding FROM embeddings WHERE content_hash = ?",
        (text_hash,),
    ).fetchone()
    conn.close()
    if row is None:
        return None
    return deserialize_vector(row[0])


def get_or_embed(db_path, text, model_name="all-MiniLM-L6-v2"):
    """
    Get cached embedding or compute and cache a new one.

    Args:
        db_path: Path to SQLite database.
        text: The text to embed.
        model_name: The sentence-transformers model to use.

    Returns:
        list[float]: The embedding vector.
    """
    text_hash = content_hash(text)
    cached = get_embedding(db_path, text_hash)
    if cached is not None:
        return cached
    vector = embed_text(text, model_name)
    store_embedding(db_path, text_hash, vector, model_name)
    return vector


# --- Semantic search ---


def search_semantic(query, db_path, sections, limit=10, model_name="all-MiniLM-L6-v2"):
    """
    Perform semantic search over a list of sections.

    Args:
        query: The search query string.
        db_path: Path to SQLite database (for embedding cache).
        sections: List of dicts with at least 'content', 'file', 'heading' keys.
        limit: Maximum number of results.
        model_name: The sentence-transformers model to use.

    Returns:
        List of dicts: [{'file', 'heading', 'content', 'score'}, ...] sorted by score desc.
    """
    ensure_embeddings_table(db_path)

    # Embed the query
    query_vec = embed_text(query, model_name)

    # Embed all sections (using cache)
    results = []
    for section in sections:
        section_vec = get_or_embed(db_path, section["content"], model_name)
        score = cosine_similarity(query_vec, section_vec)
        results.append({
            "file": section["file"],
            "heading": section["heading"],
            "content": section["content"],
            "score": score,
        })

    results.sort(key=lambda r: r["score"], reverse=True)
    return results[:limit]


# --- Hybrid scoring ---


def normalize_scores(scores):
    """Min-max normalize a list of scores to [0, 1]."""
    if not scores:
        return []
    min_s = min(scores)
    max_s = max(scores)
    if max_s == min_s:
        return [1.0] * len(scores)  # all equal -> all 1.0
    return [(s - min_s) / (max_s - min_s) for s in scores]


def hybrid_search(
    query,
    db_path,
    sections,
    bm25_results,
    limit=10,
    bm25_weight=0.3,
    vector_weight=0.7,
    model_name="all-MiniLM-L6-v2",
):
    """
    Combine BM25 and semantic search results into a hybrid ranked list.

    Args:
        query: The search query string.
        db_path: Path to SQLite database (for embedding cache).
        sections: List of dicts with 'content', 'file', 'heading' keys.
        bm25_results: List of dicts from BM25 search, each with 'file', 'heading', 'score'.
        limit: Maximum number of results.
        bm25_weight: Weight for BM25 score component (default 0.3).
        vector_weight: Weight for vector similarity component (default 0.7).
        model_name: The sentence-transformers model to use.

    Returns:
        List of dicts with 'file', 'heading', 'content', 'score', 'bm25_score', 'vector_score'.
    """
    # Get semantic results
    semantic_results = search_semantic(query, db_path, sections, limit=len(sections), model_name=model_name)

    # Build lookup maps keyed by (file, heading)
    semantic_map = {}
    for r in semantic_results:
        key = (r["file"], r["heading"])
        semantic_map[key] = r["score"]

    bm25_map = {}
    for r in bm25_results:
        key = (r["file"], r["heading"])
        bm25_map[key] = r["score"]

    # Union of all keys
    all_keys = set(semantic_map.keys()) | set(bm25_map.keys())

    # Collect raw scores
    raw_bm25 = []
    raw_vector = []
    key_list = list(all_keys)

    for key in key_list:
        raw_bm25.append(bm25_map.get(key, 0.0))
        raw_vector.append(semantic_map.get(key, 0.0))

    # FTS5 BM25 scores are negative (more negative = better match).
    # Negate before normalizing so best matches get highest normalized scores.
    negated_bm25 = [-s for s in raw_bm25]
    norm_bm25 = normalize_scores(negated_bm25)
    norm_vector = normalize_scores(raw_vector)

    # Combine
    combined = []
    for i, key in enumerate(key_list):
        hybrid_score = vector_weight * norm_vector[i] + bm25_weight * norm_bm25[i]
        # Find content from sections or semantic results
        content = ""
        for s in sections:
            if (s["file"], s["heading"]) == key:
                content = s["content"]
                break
        combined.append({
            "file": key[0],
            "heading": key[1],
            "content": content,
            "score": hybrid_score,
            "bm25_score": raw_bm25[i],
            "vector_score": raw_vector[i],
            "bm25_normalized": norm_bm25[i],
            "vector_normalized": norm_vector[i],
        })

    combined.sort(key=lambda r: r["score"], reverse=True)
    return combined[:limit]


def hybrid_search_safe(
    query,
    db_path,
    sections,
    bm25_results,
    limit=10,
    bm25_weight=0.3,
    vector_weight=0.7,
    model_name="all-MiniLM-L6-v2",
):
    """
    Hybrid search with graceful fallback.
    If sentence-transformers is not available, returns BM25 results only with a warning.

    Returns:
        tuple: (results_list, warning_message_or_None)
    """
    if not _check_transformers():
        # Fallback to BM25 only
        bm25_sorted = sorted(bm25_results, key=lambda r: r["score"], reverse=True)
        return (
            bm25_sorted[:limit],
            "sentence-transformers not installed; using BM25-only results. "
            "Install with: pip install sentence-transformers",
        )
    results = hybrid_search(
        query, db_path, sections, bm25_results,
        limit=limit, bm25_weight=bm25_weight, vector_weight=vector_weight,
        model_name=model_name,
    )
    return (results, None)


# --- Integration with pk_search.py ---


def load_all_sections(db_path):
    """
    Load all indexed sections from a pk_search.py FTS5 database.
    Returns list of dicts with 'file', 'heading', 'content' keys
    (mapped from pk_search.py's 'file_path' column).
    """
    conn = sqlite3.connect(db_path)
    rows = conn.execute("SELECT file_path, heading, content FROM entries").fetchall()
    conn.close()
    return [
        {"file": row[0], "heading": row[1], "content": row[2]}
        for row in rows
    ]


def adapt_bm25_results(bm25_results):
    """
    Adapt pk_search.py BM25 result dicts (file_path, heading, score, snippet)
    to the format expected by hybrid_search (file, heading, score).
    """
    return [
        {
            "file": r.get("file_path", r.get("file", "")),
            "heading": r["heading"],
            "score": r["score"],
        }
        for r in bm25_results
    ]


def format_result_for_cli(result, knowledge_dir=None):
    """
    Format a semantic/hybrid result dict for CLI output,
    matching pk_search.py's output style.
    """
    import os
    file_path = result.get("file", result.get("file_path", ""))
    if knowledge_dir:
        try:
            file_path = os.path.relpath(file_path, knowledge_dir)
        except ValueError:
            pass
    content = result.get("content", "")
    snippet = content[:500] + ("..." if len(content) > 500 else "")
    return {
        "heading": result["heading"],
        "file_path": file_path,
        "score": round(result["score"], 4),
        "snippet": snippet,
    }
