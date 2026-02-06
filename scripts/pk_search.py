#!/usr/bin/env python3
"""pk-search: SQLite FTS5-based knowledge search for project-knowledge stores.

Single-file CLI with zero external dependencies (stdlib only).

Usage:
    python pk_search.py index <knowledge_dir> [--force]
    python pk_search.py search <knowledge_dir> <query> [--limit N] [--threshold F] [--json]
    python pk_search.py stats <knowledge_dir>
"""

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DB_FILENAME = ".pk_search.db"
SKIP_FILES = {"_inbox.md", "_index.md", "_meta.md"}
SNIPPET_MAX_CHARS = 500
DEFAULT_LIMIT = 10
DEFAULT_THRESHOLD = 0.0


# ---------------------------------------------------------------------------
# Markdown Parser
# ---------------------------------------------------------------------------

class MarkdownParser:
    """Parse a markdown file into ### sections."""

    # Match lines that start with ### (but not #### or more)
    HEADING_RE = re.compile(r"^###\s+(.+)$", re.MULTILINE)

    @staticmethod
    def parse_file(file_path: str) -> list[dict]:
        """Parse a markdown file into a list of entries.

        Each entry is a dict with keys: file_path, heading, content.
        If the file has no ### headings, the entire content is returned
        as a single entry with heading='(ungrouped)'.
        """
        try:
            text = Path(file_path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return []

        entries = []
        matches = list(MarkdownParser.HEADING_RE.finditer(text))

        if not matches:
            # No ### headings — treat entire file as one entry
            content = text.strip()
            if content:
                entries.append({
                    "file_path": file_path,
                    "heading": "(ungrouped)",
                    "content": content,
                })
            return entries

        for i, match in enumerate(matches):
            heading = match.group(1).strip()
            start = match.end()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            content = text[start:end].strip()
            entries.append({
                "file_path": file_path,
                "heading": heading,
                "content": content,
            })

        return entries


# ---------------------------------------------------------------------------
# Indexer
# ---------------------------------------------------------------------------

class Indexer:
    """Builds and maintains the FTS5 index."""

    SCHEMA_VERSION = 1

    def __init__(self, knowledge_dir: str):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.db_path = os.path.join(self.knowledge_dir, DB_FILENAME)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_schema(self, conn: sqlite3.Connection) -> None:
        """Create tables if they don't exist."""
        conn.executescript("""
            CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
                file_path,
                heading,
                content,
                tokenize='porter unicode61'
            );

            CREATE TABLE IF NOT EXISTS file_meta (
                file_path TEXT PRIMARY KEY,
                mtime REAL,
                content_hash TEXT
            );

            CREATE TABLE IF NOT EXISTS index_meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );

            CREATE TABLE IF NOT EXISTS embeddings (
                content_hash TEXT PRIMARY KEY,
                embedding BLOB,
                model_name TEXT,
                created_at REAL
            );
        """)
        # Store schema version
        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("schema_version", str(self.SCHEMA_VERSION)),
        )
        conn.commit()

    def _validate_db(self, conn: sqlite3.Connection) -> bool:
        """Check if DB schema is valid. Returns False if corrupt or outdated."""
        try:
            row = conn.execute(
                "SELECT value FROM index_meta WHERE key='schema_version'"
            ).fetchone()
            if row is None or int(row[0]) != self.SCHEMA_VERSION:
                return False
            # Quick sanity check — make sure FTS table is queryable
            conn.execute("SELECT count(*) FROM entries")
            return True
        except (sqlite3.OperationalError, sqlite3.DatabaseError):
            return False

    def _rebuild_db(self) -> sqlite3.Connection:
        """Drop and recreate the database."""
        if os.path.exists(self.db_path):
            os.remove(self.db_path)
        conn = self._connect()
        self._init_schema(conn)
        return conn

    def _collect_md_files(self) -> list[str]:
        """Find all indexable .md files in the knowledge directory."""
        md_files = []
        for root, _dirs, files in os.walk(self.knowledge_dir):
            for fname in files:
                if not fname.endswith(".md"):
                    continue
                if fname in SKIP_FILES:
                    continue
                full = os.path.join(root, fname)
                md_files.append(full)
        return sorted(md_files)

    @staticmethod
    def _file_hash(file_path: str) -> str:
        """SHA-256 hash of file contents."""
        h = hashlib.sha256()
        try:
            with open(file_path, "rb") as f:
                for chunk in iter(lambda: f.read(8192), b""):
                    h.update(chunk)
        except OSError:
            return ""
        return h.hexdigest()

    def _index_file(self, conn: sqlite3.Connection, file_path: str) -> int:
        """Index a single file. Returns number of entries added."""
        # Remove old entries for this file
        conn.execute("DELETE FROM entries WHERE file_path = ?", (file_path,))

        entries = MarkdownParser.parse_file(file_path)
        for entry in entries:
            conn.execute(
                "INSERT INTO entries (file_path, heading, content) VALUES (?, ?, ?)",
                (entry["file_path"], entry["heading"], entry["content"]),
            )

        # Update file_meta
        mtime = os.path.getmtime(file_path) if os.path.exists(file_path) else 0.0
        content_hash = self._file_hash(file_path)
        conn.execute(
            "INSERT OR REPLACE INTO file_meta (file_path, mtime, content_hash) VALUES (?, ?, ?)",
            (file_path, mtime, content_hash),
        )
        return len(entries)

    def index_all(self, force: bool = False) -> dict:
        """Full index of all markdown files. Returns stats dict."""
        if not os.path.isdir(self.knowledge_dir):
            return {"error": f"Directory not found: {self.knowledge_dir}"}

        start_time = time.time()

        # Open or rebuild DB
        if force or not os.path.exists(self.db_path):
            conn = self._rebuild_db()
        else:
            try:
                conn = self._connect()
                if not self._validate_db(conn):
                    conn.close()
                    conn = self._rebuild_db()
                else:
                    self._init_schema(conn)
            except (sqlite3.DatabaseError, sqlite3.OperationalError):
                conn = self._rebuild_db()

        if force:
            # Clear everything on force
            conn.execute("DELETE FROM entries")
            conn.execute("DELETE FROM file_meta")
            conn.commit()

        md_files = self._collect_md_files()
        total_entries = 0
        files_indexed = 0

        for fpath in md_files:
            count = self._index_file(conn, fpath)
            total_entries += count
            files_indexed += 1

        # Remove stale file_meta for deleted files
        existing_set = set(md_files)
        rows = conn.execute("SELECT file_path FROM file_meta").fetchall()
        for (fp,) in rows:
            if fp not in existing_set:
                conn.execute("DELETE FROM file_meta WHERE file_path = ?", (fp,))
                conn.execute("DELETE FROM entries WHERE file_path = ?", (fp,))

        # Record index timestamp
        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("last_indexed", str(time.time())),
        )
        conn.commit()
        conn.close()

        elapsed = time.time() - start_time
        return {
            "files_indexed": files_indexed,
            "total_entries": total_entries,
            "elapsed_seconds": round(elapsed, 3),
            "db_path": self.db_path,
        }

    def get_stale_files(self) -> list[str]:
        """Return list of files that have changed since last index."""
        if not os.path.exists(self.db_path):
            return self._collect_md_files()

        try:
            conn = self._connect()
        except (sqlite3.DatabaseError, sqlite3.OperationalError):
            return self._collect_md_files()
        if not self._validate_db(conn):
            conn.close()
            return self._collect_md_files()

        stale = []
        md_files = self._collect_md_files()
        existing_set = set(md_files)

        # Check for new or changed files
        meta_rows = {
            fp: (mt, ch)
            for fp, mt, ch in conn.execute("SELECT file_path, mtime, content_hash FROM file_meta").fetchall()
        }

        for fpath in md_files:
            if fpath not in meta_rows:
                stale.append(fpath)
                continue
            stored_mtime, stored_hash = meta_rows[fpath]
            try:
                current_mtime = os.path.getmtime(fpath)
            except OSError:
                stale.append(fpath)
                continue
            if abs(current_mtime - stored_mtime) > 0.01:
                # mtime changed — verify with hash
                current_hash = self._file_hash(fpath)
                if current_hash != stored_hash:
                    stale.append(fpath)

        # Check for deleted files
        for fp in meta_rows:
            if fp not in existing_set:
                stale.append(fp)

        conn.close()
        return stale

    def incremental_index(self) -> dict:
        """Re-index only changed files. Returns stats dict."""
        if not os.path.isdir(self.knowledge_dir):
            return {"error": f"Directory not found: {self.knowledge_dir}"}

        if not os.path.exists(self.db_path):
            return self.index_all()

        try:
            conn = self._connect()
        except (sqlite3.DatabaseError, sqlite3.OperationalError):
            return self.index_all(force=True)
        if not self._validate_db(conn):
            conn.close()
            return self.index_all(force=True)

        start_time = time.time()
        md_files = self._collect_md_files()
        existing_set = set(md_files)

        meta_rows = {
            fp: (mt, ch)
            for fp, mt, ch in conn.execute("SELECT file_path, mtime, content_hash FROM file_meta").fetchall()
        }

        files_reindexed = 0
        files_removed = 0
        total_entries_added = 0

        # Re-index new or changed files
        for fpath in md_files:
            needs_index = False
            if fpath not in meta_rows:
                needs_index = True
            else:
                stored_mtime, stored_hash = meta_rows[fpath]
                try:
                    current_mtime = os.path.getmtime(fpath)
                except OSError:
                    continue
                if abs(current_mtime - stored_mtime) > 0.01:
                    current_hash = self._file_hash(fpath)
                    if current_hash != stored_hash:
                        needs_index = True

            if needs_index:
                count = self._index_file(conn, fpath)
                total_entries_added += count
                files_reindexed += 1

        # Remove deleted files
        for fp in meta_rows:
            if fp not in existing_set:
                conn.execute("DELETE FROM entries WHERE file_path = ?", (fp,))
                conn.execute("DELETE FROM file_meta WHERE file_path = ?", (fp,))
                files_removed += 1

        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("last_indexed", str(time.time())),
        )
        conn.commit()
        conn.close()

        elapsed = time.time() - start_time
        return {
            "files_reindexed": files_reindexed,
            "files_removed": files_removed,
            "entries_added": total_entries_added,
            "elapsed_seconds": round(elapsed, 3),
        }


# ---------------------------------------------------------------------------
# Searcher
# ---------------------------------------------------------------------------

class Searcher:
    """FTS5 BM25 search over indexed entries."""

    # FTS5 operators that indicate the user is writing an explicit query
    _FTS5_OPERATORS = re.compile(r'[":*]|\bAND\b|\bOR\b|\bNOT\b|\bNEAR\b', re.IGNORECASE)

    def __init__(self, knowledge_dir: str):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.db_path = os.path.join(self.knowledge_dir, DB_FILENAME)
        self.indexer = Indexer(knowledge_dir)

    def _ensure_index(self) -> None:
        """Auto-index if DB missing or stale."""
        if not os.path.exists(self.db_path):
            result = self.indexer.index_all()
            if "error" in result:
                print(f"Error: {result['error']}", file=sys.stderr)
                sys.exit(1)
            return

        stale = self.indexer.get_stale_files()
        if stale:
            self.indexer.incremental_index()

    @classmethod
    def _prepare_query(cls, query: str) -> str:
        """Prepare a user query for FTS5.

        If the query looks like plain words (no FTS5 operators), quote each
        token individually so that column names like 'content' or 'heading'
        are not misinterpreted as column filters.
        """
        query = query.strip()
        if not query:
            return query
        if cls._FTS5_OPERATORS.search(query):
            return query
        # Plain words — quote each token for safety
        tokens = query.split()
        if len(tokens) == 1:
            return '"' + tokens[0].replace('"', '""') + '"'
        return " ".join('"' + t.replace('"', '""') + '"' for t in tokens)

    def search(
        self,
        query: str,
        limit: int = DEFAULT_LIMIT,
        threshold: float = DEFAULT_THRESHOLD,
    ) -> list[dict]:
        """Search entries by query. Returns list of result dicts."""
        self._ensure_index()

        prepared = self._prepare_query(query)
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row

        try:
            rows = conn.execute(
                """
                SELECT file_path, heading, content, rank
                FROM entries
                WHERE entries MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                (prepared, limit * 3),  # fetch extra to allow threshold filtering
            ).fetchall()
        except sqlite3.OperationalError as e:
            conn.close()
            if "fts5: syntax error" in str(e).lower():
                # Fall back to quoted phrase search
                escaped = '"' + query.replace('"', '""') + '"'
                conn = sqlite3.connect(self.db_path)
                conn.row_factory = sqlite3.Row
                rows = conn.execute(
                    """
                    SELECT file_path, heading, content, rank
                    FROM entries
                    WHERE entries MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                    (escaped, limit * 3),
                ).fetchall()
            else:
                raise

        results = []
        for row in rows:
            score = row["rank"]
            # FTS5 rank: more negative = better match. Threshold filters out
            # weak matches (scores closer to 0 than the threshold).
            if threshold < 0 and score > threshold:
                continue
            content = row["content"]
            snippet = content[:SNIPPET_MAX_CHARS]
            if len(content) > SNIPPET_MAX_CHARS:
                snippet += "..."

            # Make file_path relative to knowledge_dir for readability
            abs_path = row["file_path"]
            try:
                rel_path = os.path.relpath(abs_path, self.knowledge_dir)
            except ValueError:
                rel_path = abs_path

            results.append({
                "heading": row["heading"],
                "file_path": rel_path,
                "score": round(score, 4),
                "snippet": snippet,
            })

            if len(results) >= limit:
                break

        conn.close()
        return results


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

class Stats:
    """Provide statistics about the search index."""

    def __init__(self, knowledge_dir: str):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.db_path = os.path.join(self.knowledge_dir, DB_FILENAME)

    def get_stats(self) -> dict:
        if not os.path.exists(self.db_path):
            return {"error": "No index found. Run 'pk_search.py index' first."}

        try:
            conn = sqlite3.connect(self.db_path)
        except sqlite3.DatabaseError:
            return {"error": "Database is corrupt. Run 'pk_search.py index --force'."}

        try:
            entry_count = conn.execute("SELECT count(*) FROM entries").fetchone()[0]
            file_count = conn.execute("SELECT count(*) FROM file_meta").fetchone()[0]

            last_indexed_row = conn.execute(
                "SELECT value FROM index_meta WHERE key='last_indexed'"
            ).fetchone()
            last_indexed = float(last_indexed_row[0]) if last_indexed_row else 0.0

            db_size = os.path.getsize(self.db_path)
        except (sqlite3.OperationalError, sqlite3.DatabaseError):
            conn.close()
            return {"error": "Database is corrupt. Run 'pk_search.py index --force'."}

        conn.close()

        # Check for stale files
        indexer = Indexer(self.knowledge_dir)
        stale_files = indexer.get_stale_files()

        return {
            "knowledge_dir": self.knowledge_dir,
            "entry_count": entry_count,
            "file_count": file_count,
            "db_size_bytes": db_size,
            "db_size_human": _human_size(db_size),
            "last_indexed": time.strftime(
                "%Y-%m-%d %H:%M:%S", time.localtime(last_indexed)
            )
            if last_indexed
            else "never",
            "stale_files": len(stale_files),
            "stale_file_list": stale_files,
        }


def _human_size(size_bytes: int) -> str:
    """Convert bytes to human-readable size."""
    size = float(size_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def cmd_index(args: argparse.Namespace) -> None:
    indexer = Indexer(args.knowledge_dir)
    result = indexer.index_all(force=args.force)
    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)
    print(f"Indexed {result['files_indexed']} files, {result['total_entries']} entries in {result['elapsed_seconds']}s")
    print(f"Database: {result['db_path']}")


def cmd_search(args: argparse.Namespace) -> None:
    mode = "bm25"
    if getattr(args, "semantic", False):
        mode = "semantic"
    elif getattr(args, "hybrid", False):
        mode = "hybrid"

    searcher = Searcher(args.knowledge_dir)

    if mode == "bm25":
        results = searcher.search(
            query=args.query,
            limit=args.limit,
            threshold=args.threshold,
        )
    else:
        # Semantic or hybrid mode — requires pk_semantic
        try:
            import pk_semantic
        except ImportError:
            print(
                "Error: pk_semantic.py not found. Ensure it is in the same directory as pk_search.py.",
                file=sys.stderr,
            )
            sys.exit(1)

        # Ensure index is up to date
        searcher._ensure_index()
        db_path = searcher.db_path

        # Load all sections from the FTS5 database
        sections = pk_semantic.load_all_sections(db_path)

        if mode == "semantic":
            if not pk_semantic._check_transformers():
                print(
                    "Error: sentence-transformers not installed. "
                    "Install with: pip install sentence-transformers",
                    file=sys.stderr,
                )
                sys.exit(1)
            results = pk_semantic.search_semantic(
                args.query, db_path, sections, limit=args.limit,
            )
            results = [pk_semantic.format_result_for_cli(r, searcher.knowledge_dir) for r in results]
        else:
            # Hybrid mode
            bm25_results = searcher.search(
                query=args.query,
                limit=args.limit * 3,  # fetch more for union
                threshold=args.threshold,
            )
            adapted_bm25 = pk_semantic.adapt_bm25_results(bm25_results)
            bm25_weight = getattr(args, "bm25_weight", 0.3)
            vector_weight = getattr(args, "vector_weight", 0.7)
            results, warning = pk_semantic.hybrid_search_safe(
                args.query, db_path, sections, adapted_bm25,
                limit=args.limit,
                bm25_weight=bm25_weight,
                vector_weight=vector_weight,
            )
            if warning:
                print(f"Warning: {warning}", file=sys.stderr)
            results = [pk_semantic.format_result_for_cli(r, searcher.knowledge_dir) for r in results]

    if args.json:
        print(json.dumps(results, indent=2))
        return

    if not results:
        print(f'No results for "{args.query}"')
        return

    for i, r in enumerate(results, 1):
        print(f"\n--- Result {i} (score: {r['score']}) ---")
        print(f"  File: {r['file_path']}")
        print(f"  Heading: {r['heading']}")
        print(f"  Snippet: {r['snippet']}")


def cmd_stats(args: argparse.Namespace) -> None:
    stats = Stats(args.knowledge_dir)
    result = stats.get_stats()

    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)

    print(f"Knowledge dir: {result['knowledge_dir']}")
    print(f"Files indexed: {result['file_count']}")
    print(f"Total entries: {result['entry_count']}")
    print(f"Database size: {result['db_size_human']}")
    print(f"Last indexed:  {result['last_indexed']}")
    print(f"Stale files:   {result['stale_files']}")
    if result["stale_file_list"]:
        for f in result["stale_file_list"]:
            print(f"  - {f}")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="pk-search",
        description="SQLite FTS5 search for project-knowledge stores",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # index
    p_index = subparsers.add_parser("index", help="Build or rebuild the search index")
    p_index.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_index.add_argument("--force", action="store_true", help="Force full re-index")
    p_index.set_defaults(func=cmd_index)

    # search
    p_search = subparsers.add_parser("search", help="Search indexed entries")
    p_search.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_search.add_argument("query", help="Search query (FTS5 syntax)")
    p_search.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="Max results")
    p_search.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD, help="Min relevance score (e.g. -5.0 = only strong matches; 0 = all)")
    p_search.add_argument("--json", action="store_true", help="Output as JSON")
    p_search.add_argument("--semantic", action="store_true", help="Use vector similarity search (requires sentence-transformers)")
    p_search.add_argument("--hybrid", action="store_true", help="Combine BM25 + vector similarity (requires sentence-transformers)")
    p_search.add_argument("--bm25-weight", type=float, default=0.3, help="BM25 weight for hybrid search (default: 0.3)")
    p_search.add_argument("--vector-weight", type=float, default=0.7, help="Vector weight for hybrid search (default: 0.7)")
    p_search.set_defaults(func=cmd_search)

    # stats
    p_stats = subparsers.add_parser("stats", help="Show index statistics")
    p_stats.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_stats.set_defaults(func=cmd_stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
