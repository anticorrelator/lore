#!/usr/bin/env python3
"""pk_search: SQLite FTS5-based knowledge search library for lore knowledge stores.

Pure library — provides Indexer, Searcher, Stats, LinkChecker.
CLI entry point is in pk_cli.py; backward compat via `if __name__ == "__main__"`.

Other extracted modules:
    pk_markdown.py — MarkdownParser
    pk_resolve.py  — Resolver, resolve_read_path, BACKLINK_RE
"""

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
SKIP_FILES = {"_inbox.md", "_index.md", "_meta.md", "_meta.json", "_index.json", "_self_test_results.md", "_manifest.json"}
SKIP_DIRS = {"_archive", "__pycache__", ".git", "_meta", "_meta_bak", "_inbox"}
CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas", "principles", "workflows", "domains"}
# Category priority order for tiebreaking: higher index = higher priority
CATEGORY_PRIORITY = ["domains", "architecture", "abstractions", "gotchas", "conventions", "workflows", "principles"]
CATEGORY_PRIORITY_MAP = {cat: i for i, cat in enumerate(CATEGORY_PRIORITY)}
CATEGORY_TIEBREAK_MAX = 0.04  # max bonus for highest-priority category (within 0.05 tiebreak range)
SNIPPET_MAX_CHARS = 500
DEFAULT_LIMIT = 10
DEFAULT_THRESHOLD = 0.0
KNOWLEDGE_BOOST = 2.0  # BM25 rank multiplier for knowledge entries in ORDER BY (rank is negative; higher multiplier = more negative = ranked higher)
SOURCE_TYPES = ("knowledge", "work", "plan", "thread", "source")
SOURCE_FILE_EXTENSIONS = {".py", ".sh"}
SOURCE_SKIP_DIRS = {"__pycache__", ".git", "node_modules", ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", "dist", "build", ".egg-info"}


# ---------------------------------------------------------------------------
# Markdown Parser (extracted to pk_markdown.py, re-exported here)
# ---------------------------------------------------------------------------

from pk_markdown import MarkdownParser  # noqa: E402
from pk_resolve import Resolver, BACKLINK_RE as _BACKLINK_RE, resolve_read_path as _resolve_read_path  # noqa: E402


# ---------------------------------------------------------------------------
# Indexer
# ---------------------------------------------------------------------------

class Indexer:
    """Builds and maintains the FTS5 index."""

    SCHEMA_VERSION = 7  # v7: concordance_results for precomputed see-also/related-files

    def __init__(self, knowledge_dir: str, repo_root: str | None = None):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.db_path = os.path.join(self.knowledge_dir, DB_FILENAME)
        self.repo_root = os.path.abspath(repo_root) if repo_root else None

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
                source_type,
                category UNINDEXED,
                confidence UNINDEXED,
                learned_date UNINDEXED,
                tokenize='porter unicode61'
            );

            CREATE TABLE IF NOT EXISTS file_meta (
                file_path TEXT PRIMARY KEY,
                mtime REAL,
                content_hash TEXT,
                source_type TEXT DEFAULT 'knowledge'
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

            CREATE VIRTUAL TABLE IF NOT EXISTS entry_terms USING fts5vocab(
                entries, 'row'
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS entry_terms_instance USING fts5vocab(
                entries, 'instance'
            );

            CREATE TABLE IF NOT EXISTS tfidf_vectors (
                file_path TEXT,
                heading TEXT,
                vector BLOB,
                source_type TEXT,
                updated_at REAL,
                PRIMARY KEY (file_path, heading)
            );

            CREATE TABLE IF NOT EXISTS concordance_results (
                file_path TEXT,
                heading TEXT,
                similar_entry_path TEXT,
                similar_entry_heading TEXT,
                similarity_score REAL,
                result_type TEXT,
                PRIMARY KEY (file_path, heading, similar_entry_path, similar_entry_heading, result_type)
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

    def _collect_md_files(self) -> list[tuple[str, str]]:
        """Find all indexable .md files in the knowledge directory.

        Returns list of (file_path, source_type) tuples.
        Walks category directories for file-per-entry knowledge files,
        plus _work/ and _threads/ directories.
        """
        results: list[tuple[str, str]] = []
        work_dir = os.path.join(self.knowledge_dir, "_work")
        threads_dir = os.path.join(self.knowledge_dir, "_threads")

        # Walk category directories for file-per-entry knowledge files
        for cat_dir in sorted(CATEGORY_DIRS):
            cat_path = os.path.join(self.knowledge_dir, cat_dir)
            if not os.path.isdir(cat_path):
                continue
            for root, dirs, files in os.walk(cat_path):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                for fname in sorted(files):
                    if not fname.endswith(".md"):
                        continue
                    if fname in SKIP_FILES:
                        continue
                    full = os.path.join(root, fname)
                    results.append((full, "knowledge"))

        # Walk _work/ — index plan.md and notes.md per work item subdir
        if os.path.isdir(work_dir):
            for item_name in sorted(os.listdir(work_dir)):
                item_path = os.path.join(work_dir, item_name)
                if not os.path.isdir(item_path) or item_name in SKIP_DIRS:
                    continue
                for fname in ("plan.md", "notes.md"):
                    fpath = os.path.join(item_path, fname)
                    if os.path.isfile(fpath):
                        results.append((fpath, "work"))

            # Walk _work/_archive/ — archived work items are still searchable
            archive_dir = os.path.join(work_dir, "_archive")
            if os.path.isdir(archive_dir):
                for item_name in sorted(os.listdir(archive_dir)):
                    item_path = os.path.join(archive_dir, item_name)
                    if not os.path.isdir(item_path):
                        continue
                    for fname in ("plan.md", "notes.md"):
                        fpath = os.path.join(item_path, fname)
                        if os.path.isfile(fpath):
                            results.append((fpath, "work"))

        # Walk _threads/ — index .md files
        # v2 format: _threads/<slug>/<date>.md (directory per thread, file per entry)
        # v1 format: _threads/<slug>.md (monolithic files)
        if os.path.isdir(threads_dir):
            # Detect format version from _index.json
            thread_format = 1
            index_json = os.path.join(threads_dir, "_index.json")
            if os.path.isfile(index_json):
                try:
                    with open(index_json, "r") as f:
                        thread_format = json.load(f).get("thread_format_version", 1)
                except (json.JSONDecodeError, OSError):
                    pass

            if thread_format >= 2:
                # v2: walk subdirectories for entry files
                for entry_name in sorted(os.listdir(threads_dir)):
                    entry_path = os.path.join(threads_dir, entry_name)
                    if not os.path.isdir(entry_path):
                        continue
                    if entry_name.startswith(".") or entry_name.startswith("_"):
                        continue
                    for fname in sorted(os.listdir(entry_path)):
                        if not fname.endswith(".md"):
                            continue
                        fpath = os.path.join(entry_path, fname)
                        if os.path.isfile(fpath):
                            results.append((fpath, "thread"))
            else:
                # v1: monolithic thread files at _threads/ root
                for fname in sorted(os.listdir(threads_dir)):
                    if not fname.endswith(".md"):
                        continue
                    if fname in SKIP_FILES or fname.startswith("_"):
                        continue
                    fpath = os.path.join(threads_dir, fname)
                    if os.path.isfile(fpath):
                        results.append((fpath, "thread"))

        return sorted(results, key=lambda x: x[0])

    def _collect_source_files(self) -> list[tuple[str, str]]:
        """Find indexable source files (.py, .sh, .md) from the repo root.

        Returns list of (file_path, "source") tuples.
        Only collects files if repo_root is set. Non-knowledge .md files
        (those outside the knowledge directory) are included.
        """
        if not self.repo_root or not os.path.isdir(self.repo_root):
            return []

        results: list[tuple[str, str]] = []
        knowledge_abs = os.path.abspath(self.knowledge_dir)

        for root, dirs, files in os.walk(self.repo_root):
            # Skip common non-content directories
            dirs[:] = [d for d in dirs if d not in SOURCE_SKIP_DIRS and not d.startswith(".")]

            # Skip if we're inside the knowledge directory (already indexed as knowledge)
            abs_root = os.path.abspath(root)
            if abs_root.startswith(knowledge_abs + os.sep) or abs_root == knowledge_abs:
                dirs.clear()
                continue

            for fname in sorted(files):
                if fname.startswith("."):
                    continue
                _, ext = os.path.splitext(fname)
                if ext not in SOURCE_FILE_EXTENSIONS:
                    continue
                full = os.path.join(root, fname)
                results.append((full, "source"))

        return sorted(results, key=lambda x: x[0])

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

    # Heading level per source type: threads use ## entries, everything else uses ###
    _SOURCE_HEADING_LEVEL = {
        "thread": "##",
    }

    def _is_entry_file(self, file_path: str) -> bool:
        """Check if a file is a file-per-entry knowledge file (lives in a category dir)."""
        try:
            rel = os.path.relpath(file_path, self.knowledge_dir)
        except ValueError:
            return False
        parts = rel.split(os.sep)
        return len(parts) >= 2 and parts[0] in CATEGORY_DIRS

    def _is_thread_entry_file(self, file_path: str) -> bool:
        """Check if a file is a v2 thread entry file (lives in _threads/<slug>/)."""
        try:
            rel = os.path.relpath(file_path, self.knowledge_dir)
        except ValueError:
            return False
        parts = rel.split(os.sep)
        # _threads/<slug>/<date>.md -> 3 parts
        return len(parts) >= 3 and parts[0] == "_threads"

    @staticmethod
    def _filename_to_heading(fname: str) -> str:
        """Reconstruct a thread entry heading from its filename.

        2026-02-06.md           -> 2026-02-06
        2026-02-06-s6.md        -> 2026-02-06 (Session 6)
        2026-02-07-s14-continued.md -> 2026-02-07 (Session 14, continued)
        2026-02-07-s14-2.md     -> 2026-02-07 (Session 14)
        """
        base = fname.replace(".md", "")
        date = base[:10]
        rest = base[10:]

        if not rest:
            return date

        rest = rest.lstrip("-")
        m = re.match(r"^s(\d+)(-.*)?$", rest)
        if m:
            session_num = m.group(1)
            suffix = m.group(2) or ""
            if not suffix:
                return f"{date} (Session {session_num})"
            elif re.match(r"^-\d+$", suffix):
                # Disambiguation suffix
                return f"{date} (Session {session_num})"
            else:
                qualifier = suffix.lstrip("-").replace("-", " ")
                return f"{date} (Session {session_num}, {qualifier})"

        return date

    def _extract_category(self, file_path: str) -> str | None:
        """Extract category from file path (first dir component if in CATEGORY_DIRS)."""
        try:
            rel = os.path.relpath(file_path, self.knowledge_dir)
        except ValueError:
            return None
        parts = rel.split(os.sep)
        if len(parts) >= 2 and parts[0] in CATEGORY_DIRS:
            return parts[0]
        return None

    def _index_file(self, conn: sqlite3.Connection, file_path: str, source_type: str = "knowledge") -> int:
        """Index a single file. Returns number of entries added."""
        # Remove old entries for this file
        conn.execute("DELETE FROM entries WHERE file_path = ?", (file_path,))

        # Source files: index whole file as a single entry
        if source_type == "source":
            try:
                content = Path(file_path).read_text(encoding="utf-8").strip()
            except (OSError, UnicodeDecodeError):
                content = ""
            if content:
                # Use relative path from repo root as heading
                if self.repo_root:
                    try:
                        heading = os.path.relpath(file_path, self.repo_root)
                    except ValueError:
                        heading = os.path.basename(file_path)
                else:
                    heading = os.path.basename(file_path)
                entries = [{"file_path": file_path, "heading": heading, "content": content}]
            else:
                entries = []
        # File-per-entry knowledge files: treat whole file as one entry
        elif source_type == "knowledge" and self._is_entry_file(file_path):
            entries = MarkdownParser.parse_entry_file(file_path)
        elif source_type == "thread" and self._is_thread_entry_file(file_path):
            # v2 thread entry: single entry per file, heading from filename
            try:
                content = Path(file_path).read_text(encoding="utf-8").strip()
            except (OSError, UnicodeDecodeError):
                content = ""
            if content:
                fname = os.path.basename(file_path)
                heading = self._filename_to_heading(fname)
                entries = [{"file_path": file_path, "heading": heading, "content": content}]
            else:
                entries = []
        else:
            heading_level = self._SOURCE_HEADING_LEVEL.get(source_type, "###")
            entries = MarkdownParser.parse_file(file_path, heading_level=heading_level)

        # Extract metadata for knowledge entries
        category = self._extract_category(file_path) if source_type == "knowledge" else None
        metadata = {"learned": None, "confidence": None}
        if source_type == "knowledge":
            try:
                raw_text = Path(file_path).read_text(encoding="utf-8")
                meta = MarkdownParser._extract_metadata(raw_text)
                metadata["learned"] = meta.get("learned")
                metadata["confidence"] = meta.get("confidence")
            except (OSError, UnicodeDecodeError):
                pass

        for entry in entries:
            conn.execute(
                "INSERT INTO entries (file_path, heading, content, source_type, category, confidence, learned_date) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (entry["file_path"], entry["heading"], entry["content"], source_type, category, metadata["confidence"], metadata["learned"]),
            )

        # Update file_meta
        mtime = os.path.getmtime(file_path) if os.path.exists(file_path) else 0.0
        content_hash = self._file_hash(file_path)
        conn.execute(
            "INSERT OR REPLACE INTO file_meta (file_path, mtime, content_hash, source_type) VALUES (?, ?, ?, ?)",
            (file_path, mtime, content_hash, source_type),
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
        source_files = self._collect_source_files()
        all_files = md_files + source_files
        total_entries = 0
        files_indexed = 0

        for fpath, source_type in all_files:
            count = self._index_file(conn, fpath, source_type)
            total_entries += count
            files_indexed += 1

        # Remove stale file_meta for deleted files
        existing_paths = {fp for fp, _ in all_files}
        rows = conn.execute("SELECT file_path FROM file_meta").fetchall()
        for (fp,) in rows:
            if fp not in existing_paths:
                conn.execute("DELETE FROM file_meta WHERE file_path = ?", (fp,))
                conn.execute("DELETE FROM entries WHERE file_path = ?", (fp,))

        # Record index timestamp
        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("last_indexed", str(time.time())),
        )
        conn.commit()
        conn.close()

        # Build TF-IDF concordance vectors
        concordance_stats = self.build_concordance()

        elapsed = time.time() - start_time
        return {
            "files_indexed": files_indexed,
            "total_entries": total_entries,
            "elapsed_seconds": round(elapsed, 3),
            "db_path": self.db_path,
            "concordance": concordance_stats,
        }

    def _collect_all_files(self) -> list[tuple[str, str]]:
        """Collect all indexable files: knowledge + source."""
        return self._collect_md_files() + self._collect_source_files()

    def get_stale_files(self) -> list[tuple[str, str]]:
        """Return list of (file_path, source_type) tuples that have changed since last index."""
        if not os.path.exists(self.db_path):
            return self._collect_all_files()

        try:
            conn = self._connect()
        except (sqlite3.DatabaseError, sqlite3.OperationalError):
            return self._collect_all_files()
        if not self._validate_db(conn):
            conn.close()
            return self._collect_all_files()

        stale: list[tuple[str, str]] = []
        all_files = self._collect_all_files()
        existing_paths = {fp for fp, _ in all_files}
        file_type_map = {fp: st for fp, st in all_files}

        # Check for new or changed files
        meta_rows = {
            fp: (mt, ch)
            for fp, mt, ch in conn.execute("SELECT file_path, mtime, content_hash FROM file_meta").fetchall()
        }

        for fpath, source_type in all_files:
            if fpath not in meta_rows:
                stale.append((fpath, source_type))
                continue
            stored_mtime, stored_hash = meta_rows[fpath]
            try:
                current_mtime = os.path.getmtime(fpath)
            except OSError:
                stale.append((fpath, source_type))
                continue
            if abs(current_mtime - stored_mtime) > 0.01:
                # mtime changed — verify with hash
                current_hash = self._file_hash(fpath)
                if current_hash != stored_hash:
                    stale.append((fpath, source_type))

        # Check for deleted files
        for fp in meta_rows:
            if fp not in existing_paths:
                stale.append((fp, file_type_map.get(fp, "knowledge")))

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
        all_files = self._collect_all_files()
        existing_paths = {fp for fp, _ in all_files}

        meta_rows = {
            fp: (mt, ch)
            for fp, mt, ch in conn.execute("SELECT file_path, mtime, content_hash FROM file_meta").fetchall()
        }

        files_reindexed = 0
        files_removed = 0
        total_entries_added = 0

        # Re-index new or changed files
        for fpath, source_type in all_files:
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
                count = self._index_file(conn, fpath, source_type)
                total_entries_added += count
                files_reindexed += 1

        # Remove deleted files
        for fp in meta_rows:
            if fp not in existing_paths:
                conn.execute("DELETE FROM entries WHERE file_path = ?", (fp,))
                conn.execute("DELETE FROM file_meta WHERE file_path = ?", (fp,))
                files_removed += 1

        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("last_indexed", str(time.time())),
        )
        conn.commit()
        conn.close()

        # Rebuild concordance vectors if entries changed
        concordance_stats = {}
        if files_reindexed > 0 or files_removed > 0:
            concordance_stats = self.build_concordance()

        elapsed = time.time() - start_time
        return {
            "files_reindexed": files_reindexed,
            "files_removed": files_removed,
            "entries_added": total_entries_added,
            "elapsed_seconds": round(elapsed, 3),
            "concordance": concordance_stats,
        }

    def build_concordance(self) -> dict:
        """Build TF-IDF concordance vectors from the current FTS5 index.

        Imports Concordance lazily to avoid circular imports.
        Returns stats dict from Concordance.build_vectors().
        """
        from pk_concordance import Concordance
        concordance = Concordance(self.db_path)
        return concordance.build_vectors()


# ---------------------------------------------------------------------------
# Searcher
# ---------------------------------------------------------------------------

class Searcher:
    """FTS5 BM25 search over indexed entries."""

    # FTS5 operators that indicate the user is writing an explicit query
    _FTS5_OPERATORS = re.compile(r'[":*]|\bAND\b|\bOR\b|\bNOT\b|\bNEAR\b', re.IGNORECASE)

    def __init__(self, knowledge_dir: str, repo_root: str | None = None):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.db_path = os.path.join(self.knowledge_dir, DB_FILENAME)
        self.indexer = Indexer(knowledge_dir, repo_root=repo_root)

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
        # Plain words — split on whitespace, then expand hyphens, quote each.
        # FTS5's porter unicode61 tokenizer treats hyphens as separators, so
        # a quoted phrase like "file-mutation" would never match.
        tokens = query.split()
        parts: list[str] = []
        for token in tokens:
            sub_tokens = token.split("-")
            for st in sub_tokens:
                if st:  # skip empty from leading/trailing hyphens
                    parts.append('"' + st.replace('"', '""') + '"')
        return " ".join(parts)

    def _log_search(self, query: str, source_type: str | None, result_count: int, elapsed_ms: float, caller: str | None = None) -> None:
        """Append a JSONL record to _meta/retrieval-log.jsonl."""
        meta_dir = os.path.join(self.knowledge_dir, "_meta")
        log_path = os.path.join(meta_dir, "retrieval-log.jsonl")
        record = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
            "event": "search",
            "query": query,
            "source_type": source_type,
            "result_count": result_count,
            "elapsed_ms": round(elapsed_ms, 1),
        }
        if caller:
            record["caller"] = caller
        try:
            os.makedirs(meta_dir, exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
        except OSError:
            pass  # logging is best-effort

    def search(
        self,
        query: str,
        limit: int = DEFAULT_LIMIT,
        threshold: float = DEFAULT_THRESHOLD,
        source_type: str | None = None,
        category: str | list[str] | None = None,
        exclude_category: str | list[str] | None = None,
        caller: str | None = None,
        include_archived: bool = False,
    ) -> list[dict]:
        """Search entries by query. Returns list of result dicts.

        Args:
            source_type: Filter by source type ("knowledge", "plan", "thread"). None = all.
            category: Filter by category (e.g. "architecture", ["conventions", "gotchas"]). None = all.
            exclude_category: Exclude entries in these categories (e.g. "domains"). None = no exclusion.
            caller: Identifier for the caller (e.g. "lead", "worker", "prefetch"). Logged to retrieval log.
            include_archived: If False (default), exclude entries from _archive/ paths.
        """
        search_start = time.time()
        self._ensure_index()

        prepared = self._prepare_query(query)

        # Use WHERE clause for filtering (not FTS5 column syntax)
        # to avoid syntax errors with OR queries
        extra_filters = ""
        filter_params: list = []
        if source_type and source_type in SOURCE_TYPES:
            extra_filters += " AND source_type = ?"
            filter_params.append(source_type)
        if category:
            if isinstance(category, str):
                extra_filters += " AND category = ?"
                filter_params.append(category)
            else:
                placeholders = ", ".join("?" for _ in category)
                extra_filters += f" AND category IN ({placeholders})"
                filter_params.extend(category)
        if exclude_category:
            if isinstance(exclude_category, str):
                extra_filters += " AND (category IS NULL OR category != ?)"
                filter_params.append(exclude_category)
            else:
                placeholders = ", ".join("?" for _ in exclude_category)
                extra_filters += f" AND (category IS NULL OR category NOT IN ({placeholders}))"
                filter_params.extend(exclude_category)
        if not include_archived:
            extra_filters += " AND file_path NOT LIKE '%\\_archive/%' ESCAPE '\\'"

        params: list = [prepared] + filter_params + [limit * 3]

        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row

        select_cols = "file_path, heading, content, source_type, category, confidence, learned_date, rank"
        order_expr = f"rank * CASE WHEN source_type = 'knowledge' THEN {KNOWLEDGE_BOOST} ELSE 1.0 END"

        try:
            rows = conn.execute(
                f"""
                SELECT {select_cols}
                FROM entries
                WHERE entries MATCH ?{extra_filters}
                ORDER BY {order_expr}
                LIMIT ?
                """,
                params,
            ).fetchall()
        except sqlite3.OperationalError as e:
            conn.close()
            if "fts5: syntax error" in str(e).lower():
                # Fall back to quoted phrase search
                escaped = '"' + query.replace('"', '""') + '"'
                fallback_params: list = [escaped] + filter_params + [limit * 3]
                conn = sqlite3.connect(self.db_path)
                conn.row_factory = sqlite3.Row
                rows = conn.execute(
                    f"""
                    SELECT {select_cols}
                    FROM entries
                    WHERE entries MATCH ?{extra_filters}
                    ORDER BY {order_expr}
                    LIMIT ?
                    """,
                    fallback_params,
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
                "source_type": row["source_type"],
                "category": row["category"],
                "confidence": row["confidence"],
                "learned_date": row["learned_date"],
                "score": round(score, 4),
                "snippet": snippet,
            })

            if len(results) >= limit:
                break

        conn.close()

        elapsed_ms = (time.time() - search_start) * 1000
        self._log_search(query, source_type, len(results), elapsed_ms, caller=caller)

        return results

    def composite_search(
        self,
        query: str,
        limit: int = DEFAULT_LIMIT,
        threshold: float = DEFAULT_THRESHOLD,
        source_type: str | None = None,
        category: str | list[str] | None = None,
        exclude_category: str | list[str] | None = None,
        caller: str | None = None,
        include_archived: bool = False,
        bm25_weight: float = 0.5,
        recency_weight: float = 0.3,
        tfidf_weight: float = 0.2,
    ) -> list[dict]:
        """Search with composite scoring: BM25 + recency + TF-IDF similarity.

        Fetches extra results from BM25, re-scores with composite weights,
        and returns the top `limit` results sorted by composite score.

        Each result dict includes an additional 'composite_score' field and
        'content' field (full file content for downstream consumers).
        """
        from pk_concordance import Concordance, sparse_cosine_similarity

        # Fetch more results than needed for re-ranking
        raw_results = self.search(
            query=query,
            limit=limit * 3,
            threshold=threshold,
            source_type=source_type,
            category=category,
            exclude_category=exclude_category,
            caller=caller,
            include_archived=include_archived,
        )

        # Build query TF-IDF vector using precomputed corpus stats
        concordance = Concordance(self.db_path)
        query_vector = concordance.build_query_vector(query)

        # Preload entry vectors for results
        entry_vectors: dict[tuple[str, str], dict[int, float]] = {}
        if query_vector:
            conn = sqlite3.connect(self.db_path)
            for r in raw_results:
                rel_path = r.get("file_path", "")
                abs_path = os.path.join(self.knowledge_dir, rel_path)
                heading = r.get("heading", "")
                row = conn.execute(
                    "SELECT vector FROM tfidf_vectors WHERE file_path = ? AND heading = ?",
                    (abs_path, heading),
                ).fetchone()
                if row and row[0]:
                    from pk_concordance import deserialize_sparse_vector
                    entry_vectors[(rel_path, heading)] = deserialize_sparse_vector(row[0])
            conn.close()

        now = time.time()
        scored = []
        for r in raw_results:
            rel_path = r.get("file_path", "")
            abs_path = os.path.join(self.knowledge_dir, rel_path)
            if not os.path.isfile(abs_path):
                continue

            # BM25 score (more negative = better match, normalize to 0-1)
            bm25_raw = r.get("score", 0)
            bm25_norm = min(1.0, abs(bm25_raw) / 10.0)

            # Recency score: use learned_date metadata, fall back to mtime
            recency_score = 0.0
            learned_date = r.get("learned_date")
            if learned_date:
                try:
                    from datetime import datetime
                    learned_dt = datetime.strptime(learned_date, "%Y-%m-%d")
                    days_ago = (now - learned_dt.timestamp()) / 86400
                    recency_score = max(0.0, 1.0 - (days_ago / 365))
                except (ValueError, OSError):
                    pass
            if recency_score == 0.0:
                try:
                    mtime = os.path.getmtime(abs_path)
                    days_ago = (now - mtime) / 86400
                    recency_score = max(0.0, 1.0 - (days_ago / 365))
                except OSError:
                    pass

            # TF-IDF similarity: cosine between query vector and entry vector
            tfidf_score = 0.0
            if query_vector:
                heading = r.get("heading", "")
                entry_vec = entry_vectors.get((rel_path, heading))
                if entry_vec:
                    tfidf_score = sparse_cosine_similarity(query_vector, entry_vec)

            # Read content for downstream consumers
            try:
                content = Path(abs_path).read_text(encoding="utf-8").rstrip("\n")
            except (OSError, UnicodeDecodeError):
                continue

            composite = (
                bm25_weight * bm25_norm
                + recency_weight * recency_score
                + tfidf_weight * tfidf_score
            )

            # Category-priority tiebreaker: small bonus for higher-priority categories
            entry_category = r.get("category")
            cat_rank = CATEGORY_PRIORITY_MAP.get(entry_category, 0) if entry_category else 0
            cat_bonus = CATEGORY_TIEBREAK_MAX * cat_rank / max(len(CATEGORY_PRIORITY) - 1, 1)
            composite += cat_bonus

            result = dict(r)
            result["composite_score"] = round(composite, 4)
            result["tfidf_score"] = round(tfidf_score, 4)
            result["content"] = content
            scored.append(result)

        # Sort by composite score descending
        scored.sort(key=lambda x: -x["composite_score"])
        return scored[:limit]

    def budget_search(
        self,
        query: str,
        budget_chars: int,
        limit: int = DEFAULT_LIMIT,
        threshold: float = DEFAULT_THRESHOLD,
        source_type: str | None = None,
        category: str | list[str] | None = None,
        exclude_category: str | list[str] | None = None,
        caller: str | None = None,
        include_archived: bool = False,
        bm25_weight: float = 0.5,
        recency_weight: float = 0.3,
        tfidf_weight: float = 0.2,
    ) -> dict:
        """Search with composite scoring and budget-aware result partitioning.

        Wraps composite_search() and partitions results into two tiers:
        - 'full': results whose cumulative content fits within budget_chars
        - 'titles_only': remaining results (heading + file_path only)

        Returns dict with keys:
            full: list of result dicts (with 'content' field)
            titles_only: list of result dicts (heading + file_path only)
            budget_used: total chars consumed by full results
            budget_total: the budget_chars parameter
        """
        results = self.composite_search(
            query=query,
            limit=limit,
            threshold=threshold,
            source_type=source_type,
            category=category,
            exclude_category=exclude_category,
            caller=caller,
            include_archived=include_archived,
            bm25_weight=bm25_weight,
            recency_weight=recency_weight,
            tfidf_weight=tfidf_weight,
        )

        full: list[dict] = []
        titles_only: list[dict] = []
        budget_used = 0

        for r in results:
            content = r.get("content", "")
            content_size = len(content)

            if budget_used + content_size <= budget_chars:
                full.append(r)
                budget_used += content_size
            else:
                titles_only.append({
                    "heading": r.get("heading", ""),
                    "file_path": r.get("file_path", ""),
                    "source_type": r.get("source_type", ""),
                    "category": r.get("category"),
                    "composite_score": r.get("composite_score", 0),
                })

        return {
            "full": full,
            "titles_only": titles_only,
            "budget_used": budget_used,
            "budget_total": budget_chars,
        }


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

            # Source type breakdown
            type_counts = {}
            try:
                for row in conn.execute("SELECT source_type, count(*) FROM file_meta GROUP BY source_type").fetchall():
                    type_counts[row[0] or "knowledge"] = row[1]
            except sqlite3.OperationalError:
                type_counts = {"knowledge": file_count}  # v1 schema fallback

            # Category breakdown (from UNINDEXED column, v5+)
            category_counts = {}
            try:
                for row in conn.execute(
                    "SELECT category, count(*) FROM entries WHERE category IS NOT NULL GROUP BY category"
                ).fetchall():
                    category_counts[row[0]] = row[1]
            except sqlite3.OperationalError:
                pass  # older schema without category column

            # Confidence distribution (from UNINDEXED column, v5+)
            confidence_counts = {}
            try:
                for row in conn.execute(
                    "SELECT confidence, count(*) FROM entries WHERE confidence IS NOT NULL GROUP BY confidence"
                ).fetchall():
                    confidence_counts[row[0]] = row[1]
            except sqlite3.OperationalError:
                pass  # older schema without confidence column

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
            "type_counts": type_counts,
            "category_counts": category_counts,
            "confidence_counts": confidence_counts,
            "db_size_bytes": db_size,
            "db_size_human": _human_size(db_size),
            "last_indexed": time.strftime(
                "%Y-%m-%d %H:%M:%S", time.localtime(last_indexed)
            )
            if last_indexed
            else "never",
            "stale_files": len(stale_files),
            "stale_file_list": [fp for fp, _ in stale_files],
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
# Backlink Resolver (extracted to pk_resolve.py, re-exported above)
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Link Checker
# ---------------------------------------------------------------------------

_FENCED_CODE_RE = re.compile(r"^```.*?^```", re.MULTILINE | re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`]+`")
_PLACEHOLDER_TARGETS = frozenset({"file", "slug", "...", "name"})


class LinkChecker:
    """Scan for broken [[backlink]] references across the knowledge store."""

    def __init__(self, knowledge_dir: str):
        self.knowledge_dir = os.path.abspath(knowledge_dir)
        self.resolver = Resolver(knowledge_dir)

    @staticmethod
    def _strip_code_blocks(text: str) -> str:
        """Remove fenced code blocks and inline code spans to avoid scanning template backlinks."""
        text = _FENCED_CODE_RE.sub("", text)
        text = _INLINE_CODE_RE.sub("", text)
        return text

    @staticmethod
    def _is_placeholder_backlink(match: re.Match) -> bool:
        """Check if a backlink match is a placeholder/template example."""
        target = match.group("target").strip()
        return target in _PLACEHOLDER_TARGETS

    def check_all(self, include_archived: bool = False, include_threads: bool = False) -> dict:
        """Scan all files for backlinks and check if they resolve.

        Returns dict with: total_links, broken_links, archived_links.
        Archived links resolve successfully but point to archived plans.

        Args:
            include_archived: If False (default), skip files under _work/_archive/.
            include_threads: If False (default), skip files under _threads/.
        """
        all_links: list[tuple[str, str]] = []  # (source_file, backlink)
        placeholder_count = 0
        skipped_archived_files = 0
        skipped_thread_files = 0

        # Collect all [[...]] references from all md files
        indexer = Indexer(self.knowledge_dir)
        md_files = indexer._collect_md_files()

        for fpath, _ in md_files:
            try:
                rel = os.path.relpath(fpath, self.knowledge_dir)
            except ValueError:
                rel = fpath

            if not include_archived and rel.startswith(os.path.join("_work", "_archive") + os.sep):
                skipped_archived_files += 1
                continue

            if not include_threads and rel.startswith("_threads" + os.sep):
                skipped_thread_files += 1
                continue
            try:
                text = Path(fpath).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            # Strip fenced code blocks to avoid false positives from
            # template/example backlinks in documentation
            text = self._strip_code_blocks(text)
            for match in _BACKLINK_RE.finditer(text):
                if self._is_placeholder_backlink(match):
                    placeholder_count += 1
                    continue
                all_links.append((fpath, match.group(0)))

        # Resolve each link
        broken: list[dict] = []
        archived: list[dict] = []
        for source_file, backlink in all_links:
            result = self.resolver.resolve(backlink)
            try:
                rel_source = os.path.relpath(source_file, self.knowledge_dir)
            except ValueError:
                rel_source = source_file

            if not result.get("resolved"):
                broken.append({
                    "source_file": rel_source,
                    "backlink": backlink,
                    "error": result.get("error", "Unknown"),
                })
            elif result.get("archived"):
                archived.append({
                    "source_file": rel_source,
                    "backlink": backlink,
                })

        return {
            "total_links": len(all_links),
            "broken_count": len(broken),
            "broken_links": broken,
            "archived_count": len(archived),
            "archived_links": archived,
            "placeholder_count": placeholder_count,
            "skipped_archived_files": skipped_archived_files,
            "skipped_thread_files": skipped_thread_files,
        }


# ---------------------------------------------------------------------------
# CLI (extracted to pk_cli.py, backward-compat entry point below)
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    from pk_cli import main  # noqa: E402
    main()

