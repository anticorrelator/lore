"""pk_concordance.py — TF-IDF concordance for lore knowledge stores.

Computes TF-IDF vectors from FTS5-indexed content and stores them in SQLite.
Vectors are sparse dicts {term_index: tfidf_score} serialized via struct.pack.

Uses fts5vocab virtual tables for accurate porter-stemmed term statistics:
  - entry_terms (row-level): corpus-wide document frequency per term
  - entry_terms_instance (instance-level): per-document term occurrences

Dependencies: Python stdlib only (sqlite3, struct, math).
"""

import math
import sqlite3
import struct
import time
from collections import Counter


# ---------------------------------------------------------------------------
# Sparse vector serialization
# ---------------------------------------------------------------------------

def serialize_sparse_vector(vec: dict[int, float]) -> bytes:
    """Serialize a sparse vector {term_index: score} to bytes.

    Format: N pairs of (int32 index, float32 score), packed sequentially.
    """
    if not vec:
        return b""
    pairs = sorted(vec.items())
    fmt = f"{'if' * len(pairs)}"
    values = []
    for idx, score in pairs:
        values.append(idx)
        values.append(score)
    return struct.pack(fmt, *values)


def deserialize_sparse_vector(data: bytes) -> dict[int, float]:
    """Deserialize bytes back to a sparse vector {term_index: score}."""
    if not data:
        return {}
    pair_size = struct.calcsize("if")
    n_pairs = len(data) // pair_size
    fmt = f"{'if' * n_pairs}"
    values = struct.unpack(fmt, data)
    vec: dict[int, float] = {}
    for i in range(0, len(values), 2):
        vec[int(values[i])] = float(values[i + 1])
    return vec


def sparse_cosine_similarity(a: dict[int, float], b: dict[int, float]) -> float:
    """Compute cosine similarity between two sparse vectors. Returns float in [0, 1].

    Only iterates over shared keys for efficiency.
    """
    if not a or not b:
        return 0.0

    # Dot product over shared keys
    shared_keys = set(a.keys()) & set(b.keys())
    if not shared_keys:
        return 0.0

    dot = sum(a[k] * b[k] for k in shared_keys)
    norm_a = math.sqrt(sum(v * v for v in a.values()))
    norm_b = math.sqrt(sum(v * v for v in b.values()))

    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


# ---------------------------------------------------------------------------
# Concordance class
# ---------------------------------------------------------------------------

class Concordance:
    """Computes and manages TF-IDF vectors from the FTS5 index.

    Uses fts5vocab virtual tables for porter-stemmed term statistics:
      - entry_terms (row): document frequency for IDF
      - entry_terms_instance (instance): per-document term frequency for TF
    Vectors are stored in the tfidf_vectors table.
    """

    def __init__(self, db_path: str):
        self.db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _get_doc_count(self, conn: sqlite3.Connection) -> int:
        """Get total number of documents (entries) in the FTS5 index."""
        row = conn.execute("SELECT count(*) FROM entries").fetchone()
        return row[0] if row else 0

    def _get_doc_frequencies(self, conn: sqlite3.Connection) -> dict[str, int]:
        """Get document frequency for each term from content column only.

        Uses instance-level fts5vocab filtered to col='content' so that terms
        appearing only in file_path or heading columns don't inflate IDF.
        Returns dict mapping porter-stemmed term -> number of documents containing it.
        """
        rows = conn.execute(
            "SELECT term, COUNT(DISTINCT doc) FROM entry_terms_instance "
            "WHERE col = 'content' GROUP BY term"
        ).fetchall()
        return {term: doc_count for term, doc_count in rows}

    def _build_term_index(self, doc_freqs: dict[str, int]) -> dict[str, int]:
        """Build a stable term -> integer index mapping, sorted alphabetically."""
        return {term: idx for idx, term in enumerate(sorted(doc_freqs.keys()))}

    def _get_instance_term_frequencies(self, conn: sqlite3.Connection) -> dict[int, Counter]:
        """Get per-document term frequencies from fts5vocab instance table.

        Uses entry_terms_instance which provides (term, doc_rowid, col, offset)
        for each term occurrence. Groups by doc_rowid to get TF per document.
        Only counts terms in the 'content' column (col='content').

        Returns dict mapping doc_rowid -> Counter({term: count}).
        """
        # entry_terms_instance columns: term, doc (rowid), col (column name), offset
        # Filter to content column only to avoid counting file paths and headings
        rows = conn.execute(
            "SELECT term, doc FROM entry_terms_instance WHERE col = 'content'"
        ).fetchall()

        doc_tfs: dict[int, Counter] = {}
        for term, doc_rowid in rows:
            if doc_rowid not in doc_tfs:
                doc_tfs[doc_rowid] = Counter()
            doc_tfs[doc_rowid][term] += 1

        return doc_tfs

    def _get_entry_rowids(self, conn: sqlite3.Connection, source_type_filter: str | None = None) -> dict[int, tuple[str, str, str]]:
        """Map FTS5 rowids to (file_path, heading, source_type).

        FTS5 rowids are accessible via the special 'rowid' column.
        """
        query = "SELECT rowid, file_path, heading, source_type FROM entries"
        params: list = []
        if source_type_filter:
            query += " WHERE source_type = ?"
            params.append(source_type_filter)

        rows = conn.execute(query, params).fetchall()
        return {rowid: (fp, heading, st) for rowid, fp, heading, st in rows}

    def build_vectors(self, source_type_filter: str | None = None) -> dict:
        """Compute TF-IDF vectors for all entries and store in tfidf_vectors table.

        Uses fts5vocab instance table for per-document TF (porter-stemmed) and
        fts5vocab row table for IDF. TF-IDF = (1 + log(tf)) * log(N / df).

        Args:
            source_type_filter: If set, only build vectors for entries of this source_type.

        Returns:
            Stats dict with vectors_built, elapsed_seconds.
        """
        start_time = time.time()
        conn = self._connect()

        # Get corpus stats from fts5vocab
        total_docs = self._get_doc_count(conn)
        if total_docs == 0:
            conn.close()
            return {"vectors_built": 0, "elapsed_seconds": 0.0}

        doc_freqs = self._get_doc_frequencies(conn)
        term_index = self._build_term_index(doc_freqs)

        # Precompute IDF: log(N / df) for each term
        idf: dict[str, float] = {}
        for term, df in doc_freqs.items():
            idf[term] = math.log(total_docs / df) if df > 0 else 0.0

        # Get per-document term frequencies from instance-level fts5vocab
        doc_tfs = self._get_instance_term_frequencies(conn)

        # Map rowids to entry metadata
        entry_map = self._get_entry_rowids(conn, source_type_filter)

        vectors_built = 0
        now = time.time()

        for rowid, (file_path, heading, source_type) in entry_map.items():
            tf_counts = doc_tfs.get(rowid)
            if not tf_counts:
                continue

            # Build sparse TF-IDF vector using porter-stemmed terms
            # TF-IDF = (1 + log(tf)) * idf for tf > 0
            vec: dict[int, float] = {}
            for term, count in tf_counts.items():
                if term in term_index and term in idf:
                    tf_weight = 1.0 + math.log(count) if count > 0 else 0.0
                    tfidf = tf_weight * idf[term]
                    if tfidf > 0:
                        vec[term_index[term]] = tfidf

            if not vec:
                continue

            # Store vector
            blob = serialize_sparse_vector(vec)
            conn.execute(
                "INSERT OR REPLACE INTO tfidf_vectors (file_path, heading, vector, source_type, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (file_path, heading, blob, source_type, now),
            )
            vectors_built += 1

        conn.commit()
        conn.close()

        elapsed = time.time() - start_time
        return {
            "vectors_built": vectors_built,
            "elapsed_seconds": round(elapsed, 3),
        }

    def get_vector(self, file_path: str, heading: str) -> dict[int, float] | None:
        """Retrieve a single TF-IDF vector by file_path and heading.

        Returns sparse vector dict {term_index: score}, or None if not found.
        """
        conn = self._connect()
        row = conn.execute(
            "SELECT vector FROM tfidf_vectors WHERE file_path = ? AND heading = ?",
            (file_path, heading),
        ).fetchone()
        conn.close()

        if row is None or row[0] is None:
            return None
        return deserialize_sparse_vector(row[0])

    def get_all_vectors(self, source_type: str | None = None) -> list[dict]:
        """Retrieve all stored TF-IDF vectors.

        Args:
            source_type: If set, filter by source_type.

        Returns:
            List of dicts with file_path, heading, vector, source_type.
        """
        conn = self._connect()
        query = "SELECT file_path, heading, vector, source_type FROM tfidf_vectors"
        params: list = []
        if source_type:
            query += " WHERE source_type = ?"
            params.append(source_type)

        rows = conn.execute(query, params).fetchall()
        conn.close()

        results = []
        for file_path, heading, blob, st in rows:
            results.append({
                "file_path": file_path,
                "heading": heading,
                "vector": deserialize_sparse_vector(blob) if blob else {},
                "source_type": st,
            })
        return results

    def get_codebase_vocabulary(self) -> set[int]:
        """Return the set of term indices present across all source-type vectors.

        Retrieves all TF-IDF vectors with source_type='source' and unions their
        term indices. This represents "terms that exist in the codebase" — used
        by vocabulary drift scoring to detect knowledge entries referencing terms
        no longer present in source code.
        """
        source_vectors = self.get_all_vectors(source_type="source")
        vocab: set[int] = set()
        for entry in source_vectors:
            vocab.update(entry["vector"].keys())
        return vocab

    def compute_vocabulary_drift(
        self, file_path: str, heading: str, top_k: int = 10
    ) -> dict:
        """Score how much a knowledge entry's vocabulary has drifted from the codebase.

        Takes the entry's top-K TF-IDF terms (by weight) and checks what fraction
        are absent from the current codebase vocabulary. A high score means many of
        the entry's key terms no longer appear in any source file.

        Args:
            file_path: File path of the knowledge entry.
            heading: Heading of the knowledge entry.
            top_k: Number of top TF-IDF terms to check (default 10).

        Returns:
            Dict with:
              - score: float in [0, 1] — fraction of top-K terms absent from codebase
              - available: bool — whether computation was possible
              - detail: dict with top_k_terms, absent_terms, absent_term_names
        """
        vec = self.get_vector(file_path, heading)
        if not vec:
            return {
                "score": 0.0,
                "available": False,
                "detail": {"top_k_terms": 0, "absent_terms": 0, "absent_term_names": []},
            }

        codebase_vocab = self.get_codebase_vocabulary()
        if not codebase_vocab:
            return {
                "score": 0.0,
                "available": False,
                "detail": {"top_k_terms": 0, "absent_terms": 0, "absent_term_names": []},
            }

        # Get top-K terms by TF-IDF weight
        sorted_terms = sorted(vec.items(), key=lambda x: -x[1])[:top_k]
        top_indices = [idx for idx, _ in sorted_terms]

        # Build reverse term index for debuggability
        reverse_index = self.get_reverse_term_index()

        # Check which top terms are absent from codebase vocabulary
        absent_indices = [idx for idx in top_indices if idx not in codebase_vocab]
        absent_names = [reverse_index.get(idx, f"<unknown:{idx}>") for idx in absent_indices]

        n_top = len(top_indices)
        n_absent = len(absent_indices)
        score = n_absent / n_top if n_top > 0 else 0.0

        return {
            "score": round(score, 4),
            "available": True,
            "detail": {
                "top_k_terms": n_top,
                "absent_terms": n_absent,
                "absent_term_names": absent_names,
            },
        }

    def find_similar(
        self,
        file_path: str,
        heading: str,
        limit: int = 5,
        source_type_filter: str | None = None,
        exclude: set[tuple[str, str]] | None = None,
    ) -> list[dict]:
        """Find entries most similar to the given entry by TF-IDF cosine similarity.

        Two modes via source_type_filter:
          - "knowledge" for see-also recommendations between knowledge entries
          - "source" for related_files matching (entry-to-source-file)

        Args:
            file_path: File path of the target entry.
            heading: Heading of the target entry.
            limit: Maximum number of similar entries to return.
            source_type_filter: If set, only consider entries of this source_type.
            exclude: Set of (file_path, heading) tuples to exclude from results.

        Returns:
            List of dicts with file_path, heading, source_type, similarity.
        """
        target_vec = self.get_vector(file_path, heading)
        if not target_vec:
            return []

        candidates = self.get_all_vectors(source_type=source_type_filter)
        exclude = exclude or set()
        exclude.add((file_path, heading))  # always exclude self

        scored = []
        for entry in candidates:
            key = (entry["file_path"], entry["heading"])
            if key in exclude:
                continue
            sim = sparse_cosine_similarity(target_vec, entry["vector"])
            if sim > 0:
                scored.append({
                    "file_path": entry["file_path"],
                    "heading": entry["heading"],
                    "source_type": entry["source_type"],
                    "similarity": round(sim, 4),
                })

        scored.sort(key=lambda x: -x["similarity"])
        return scored[:limit]

    # Alias for backwards compatibility (used by pk_cli.py --expand)
    find_similar_to = find_similar

    def suggest_related_files(
        self,
        file_path: str,
        heading: str,
        threshold: float = 0.05,
        limit: int = 10,
    ) -> list[dict]:
        """Suggest source files related to a knowledge entry via TF-IDF similarity.

        Finds source files whose content is similar to the knowledge entry,
        returning candidates for the related_files field in _manifest.json.

        Default threshold 0.05 was empirically tuned: at 0.05 it captures ~26%
        of known related_files matches with ~4 suggestions per entry. Lower
        thresholds (0.03) increase recall to 84% but produce 14+ suggestions.
        Higher thresholds (0.15) miss all matches because code-vs-prose
        vocabulary overlap produces low cosine similarity scores.

        Args:
            file_path: File path of the knowledge entry.
            heading: Heading of the knowledge entry.
            threshold: Minimum cosine similarity to include (default 0.05).
            limit: Maximum number of related files to return.

        Returns:
            List of dicts with file_path, heading, source_type, similarity,
            filtered to similarity >= threshold.
        """
        candidates = self.find_similar(
            file_path, heading,
            limit=limit,
            source_type_filter="source",
        )
        return [c for c in candidates if c["similarity"] >= threshold]

    @staticmethod
    def _stem_and_count(text: str) -> Counter:
        """Stem tokens using FTS5's porter unicode61 tokenizer and count occurrences.

        Creates a temporary in-memory FTS5 table to leverage the exact same
        tokenizer used by the main entries table, ensuring term alignment.
        """
        conn = sqlite3.connect(":memory:")
        conn.execute("CREATE VIRTUAL TABLE _stem USING fts5(t, tokenize='porter unicode61')")
        conn.execute("CREATE VIRTUAL TABLE _stem_v USING fts5vocab(_stem, 'instance')")
        conn.execute("INSERT INTO _stem(rowid, t) VALUES (1, ?)", (text,))
        rows = conn.execute("SELECT term FROM _stem_v WHERE col = 't'").fetchall()
        conn.close()
        return Counter(r[0] for r in rows)

    def build_query_vector(self, query: str) -> dict[int, float]:
        """Build a TF-IDF vector for a query string.

        Uses FTS5's porter tokenizer for stemming and the corpus IDF from
        fts5vocab. Returns sparse vector compatible with entry vectors.
        """
        if not query or not query.strip():
            return {}

        conn = self._connect()
        total_docs = self._get_doc_count(conn)
        if total_docs == 0:
            conn.close()
            return {}

        doc_freqs = self._get_doc_frequencies(conn)
        term_index = self._build_term_index(doc_freqs)
        conn.close()

        # Stem query tokens using FTS5's porter tokenizer
        tf_counts = self._stem_and_count(query)

        # Build sparse TF-IDF vector
        vec: dict[int, float] = {}
        for term, count in tf_counts.items():
            if term in term_index and term in doc_freqs:
                df = doc_freqs[term]
                idf = math.log(total_docs / df) if df > 0 else 0.0
                tf_weight = 1.0 + math.log(count) if count > 0 else 0.0
                tfidf = tf_weight * idf
                if tfidf > 0:
                    vec[term_index[term]] = tfidf

        return vec

    def run_full_analysis(
        self,
        see_also_limit: int = 3,
        related_files_threshold: float = 0.15,
        related_files_limit: int = 10,
    ) -> dict:
        """Run concordance analysis for all knowledge entries.

        For each knowledge entry, computes:
          - see_also: top-N similar knowledge entries
          - related_files: source files above similarity threshold

        Stores results in the concordance_results table and returns a summary.

        Args:
            see_also_limit: Max see-also recommendations per entry.
            related_files_threshold: Min cosine similarity for related files.
            related_files_limit: Max related files per entry.

        Returns:
            Stats dict with entries_analyzed, see_also_pairs, related_file_pairs,
            elapsed_seconds.
        """
        start_time = time.time()
        conn = self._connect()

        # Clear previous results
        conn.execute("DELETE FROM concordance_results")

        # Get all knowledge entries
        rows = conn.execute(
            "SELECT DISTINCT file_path, heading FROM entries WHERE source_type = 'knowledge'"
        ).fetchall()
        conn.close()

        entries_analyzed = 0
        see_also_pairs = 0
        related_file_pairs = 0

        # Use a single connection for all inserts
        write_conn = self._connect()

        for file_path, heading in rows:
            # See-also: similar knowledge entries
            similar = self.find_similar(
                file_path, heading,
                limit=see_also_limit,
                source_type_filter="knowledge",
            )
            for s in similar:
                write_conn.execute(
                    "INSERT OR REPLACE INTO concordance_results "
                    "(file_path, heading, similar_entry_path, similar_entry_heading, similarity_score, result_type) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (file_path, heading, s["file_path"], s["heading"], s["similarity"], "see_also"),
                )
                see_also_pairs += 1

            # Related files: similar source files
            related = self.suggest_related_files(
                file_path, heading,
                threshold=related_files_threshold,
                limit=related_files_limit,
            )
            for r in related:
                write_conn.execute(
                    "INSERT OR REPLACE INTO concordance_results "
                    "(file_path, heading, similar_entry_path, similar_entry_heading, similarity_score, result_type) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (file_path, heading, r["file_path"], r["heading"], r["similarity"], "related_file"),
                )
                related_file_pairs += 1

            entries_analyzed += 1

        write_conn.commit()
        write_conn.close()

        elapsed = time.time() - start_time
        return {
            "entries_analyzed": entries_analyzed,
            "see_also_pairs": see_also_pairs,
            "related_file_pairs": related_file_pairs,
            "elapsed_seconds": round(elapsed, 3),
        }

    def find_merge_candidates(self, threshold: float = 0.5) -> list[dict]:
        """Find knowledge-to-knowledge pairs above a similarity threshold.

        Queries concordance_results for see_also pairs above threshold,
        deduplicates symmetric pairs (keeps lower file_path as canonical),
        and returns sorted results.

        Args:
            threshold: Minimum similarity score to include (default 0.5).

        Returns:
            List of dicts with target_path, source_path, similarity,
            target_title, source_title — sorted by similarity descending.
        """
        conn = self._connect()
        rows = conn.execute(
            "SELECT file_path, heading, similar_entry_path, similar_entry_heading, similarity_score "
            "FROM concordance_results "
            "WHERE result_type = 'see_also' AND similarity_score >= ?",
            (threshold,),
        ).fetchall()
        conn.close()

        # Deduplicate symmetric pairs: keep lower path as target (canonical)
        seen: set[tuple[str, str, str, str]] = set()
        candidates: list[dict] = []

        for fp, heading, sim_fp, sim_heading, score in rows:
            # Canonical key: sort the two entries so (A,B) and (B,A) map to same key
            if (fp, heading) <= (sim_fp, sim_heading):
                key = (fp, heading, sim_fp, sim_heading)
                target_path, target_title = fp, heading
                source_path, source_title = sim_fp, sim_heading
            else:
                key = (sim_fp, sim_heading, fp, heading)
                target_path, target_title = sim_fp, sim_heading
                source_path, source_title = fp, heading

            if key in seen:
                continue
            seen.add(key)

            candidates.append({
                "target_path": target_path,
                "source_path": source_path,
                "similarity": round(score, 4),
                "target_title": target_title,
                "source_title": source_title,
            })

        candidates.sort(key=lambda x: -x["similarity"])
        return candidates

    def get_term_index(self) -> dict[str, int]:
        """Build and return the current term -> integer index mapping.

        Reads from fts5vocab to get the current vocabulary.
        """
        conn = self._connect()
        doc_freqs = self._get_doc_frequencies(conn)
        conn.close()
        return self._build_term_index(doc_freqs)

    def get_reverse_term_index(self) -> dict[int, str]:
        """Build and return the current integer index -> term mapping.

        Inverts get_term_index() for mapping term indices back to human-readable
        porter-stemmed terms. Used by vocabulary drift for debuggability.
        """
        return {idx: term for term, idx in self.get_term_index().items()}
