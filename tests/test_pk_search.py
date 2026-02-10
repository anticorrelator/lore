"""Tests for pk_search.py — SQLite FTS5 knowledge search."""

import json
import os
import sqlite3
import sys
import time

import pytest

# Add scripts dir to path so we can import pk_search
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from pk_search import (
    DEFAULT_LIMIT,
    KNOWLEDGE_BOOST,
    SOURCE_TYPES,
    Indexer,
    LinkChecker,
    MarkdownParser,
    Resolver,
    Searcher,
    Stats,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a sample knowledge directory with file-per-entry format, plans, and threads."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # architecture/ — two entry files
    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    (arch_dir / "service-mesh.md").write_text(
        "# Service Mesh\n"
        "The application uses a service mesh for inter-service communication. "
        "Envoy sidecars handle retries, circuit breaking, and mTLS.\n"
        "See also: [[conventions/api-versioning]].\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    (arch_dir / "database-sharding.md").write_text(
        "# Database Sharding\n"
        "PostgreSQL is sharded by tenant_id using Citus. Each shard handles "
        "roughly 10K tenants. Cross-shard queries go through a coordinator node.\n"
        "<!-- learned: 2025-02-15 | confidence: high -->\n",
        encoding="utf-8",
    )

    # conventions/ — two entry files
    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    (conv_dir / "api-versioning.md").write_text(
        "# API Versioning\n"
        "All HTTP APIs use URL-path versioning: `/v1/`, `/v2/`. Breaking changes "
        "require a version bump. Deprecated versions are supported for 6 months.\n",
        encoding="utf-8",
    )

    (conv_dir / "error-handling.md").write_text(
        "# Error Handling\n"
        "All service errors return a standard JSON envelope with `error_code`, "
        "`message`, and optional `details` array. HTTP status codes follow RFC 7231.\n",
        encoding="utf-8",
    )

    # gotchas/ — one entry with long content
    gotchas_dir = kd / "gotchas"
    gotchas_dir.mkdir()

    long_content = "This gotcha has a very long explanation. " * 50
    (gotchas_dir / "connection-pool-exhaustion.md").write_text(
        "# Connection Pool Exhaustion\n"
        f"{long_content}\n",
        encoding="utf-8",
    )

    # workflows/ — one entry
    wf_dir = kd / "workflows"
    wf_dir.mkdir()

    (wf_dir / "deploy-pipeline.md").write_text(
        "# Deploy Pipeline\n"
        "CI runs on every push. Merge to main triggers: build -> test -> deploy staging -> "
        "smoke tests -> deploy production. Rollback is automatic on smoke test failure.\n",
        encoding="utf-8",
    )

    # _inbox.md — should be skipped
    (kd / "_inbox.md").write_text(
        "## 2025-03-01\n- **Insight:** Something new\n",
        encoding="utf-8",
    )

    # _index.md — should be skipped
    (kd / "_index.md").write_text(
        "# Knowledge Index\n- [[architecture]]\n- [[conventions]]\n",
        encoding="utf-8",
    )

    # --- Work Items ---
    work_dir = kd / "_work" / "auth-refactor"
    work_dir.mkdir(parents=True)

    (work_dir / "plan.md").write_text(
        "# Auth Refactor Plan\n\n"
        "### Goals\n"
        "Migrate from session-based auth to JWT tokens.\n"
        "See [[knowledge:architecture#Service Mesh]] for transport layer.\n\n"
        "### Token Rotation\n"
        "Refresh tokens rotate on each use. Revocation list stored in Redis.\n\n"
        "### Migration Steps\n"
        "1. Add JWT middleware\n"
        "2. Dual-mode auth for 2 weeks\n"
        "3. Deprecate session endpoints\n",
        encoding="utf-8",
    )

    (work_dir / "notes.md").write_text(
        "# Auth Refactor Notes\n\n"
        "### 2025-03-10\n"
        "Started implementation. JWT library chosen: PyJWT.\n\n"
        "### 2025-03-15\n"
        "Dual-mode auth working in staging.\n",
        encoding="utf-8",
    )

    # _meta.json should be skipped by the indexer
    (work_dir / "_meta.json").write_text(
        json.dumps({"status": "active", "created": "2025-03-01"}),
        encoding="utf-8",
    )

    # --- Threads ---
    threads_dir = kd / "_threads"
    threads_dir.mkdir()

    (threads_dir / "working-style.md").write_text(
        "---\n"
        "tier: pinned\n"
        "topic: working-style\n"
        "---\n\n"
        "## 2025-03-01\n"
        "**Summary:** Established concise communication preferences.\n"
        "**Key points:**\n"
        "- Prefer bullet points over paragraphs\n"
        "- Show code snippets instead of describing changes\n"
        "**Related:** [[knowledge:conventions]]\n\n"
        "## 2025-03-10\n"
        "**Summary:** Refined thread capture cadence.\n"
        "**Key points:**\n"
        "- Only capture genuine shifts in thinking\n"
        "- Skip routine acknowledgments\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def empty_knowledge_dir(tmp_path):
    """Knowledge directory with an empty markdown file."""
    kd = tmp_path / "empty_knowledge"
    kd.mkdir()
    (kd / "empty.md").write_text("", encoding="utf-8")
    return kd


@pytest.fixture
def no_headings_dir(tmp_path):
    """Knowledge directory with a file that has no ### headings."""
    kd = tmp_path / "no_headings"
    kd.mkdir()
    (kd / "notes.md").write_text(
        "# Notes\n\nThis file has no section headings. Just raw notes.\n"
        "Some information about the project architecture.\n",
        encoding="utf-8",
    )
    return kd


@pytest.fixture
def unicode_dir(tmp_path):
    """Knowledge directory with unicode content in file-per-entry format."""
    kd = tmp_path / "unicode"
    kd.mkdir()

    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    (conv_dir / "lokalisierung.md").write_text(
        "# Lokalisierung\n"
        "Die Anwendung unterstützt Deutsch, Französisch und Japanisch (日本語).\n"
        "Zeichenketten werden in `.po`-Dateien gespeichert.\n",
        encoding="utf-8",
    )

    (conv_dir / "internationalization.md").write_text(
        "# 国際化\n"
        "アプリケーションは多言語対応しています。翻訳はgettext形式です。\n",
        encoding="utf-8",
    )
    return kd


@pytest.fixture
def link_check_dir(tmp_path):
    """Knowledge directory with valid and broken backlinks for link checking."""
    kd = tmp_path / "linkcheck"
    kd.mkdir()

    # architecture/ category dir with entry files containing backlinks
    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    (arch_dir / "service-mesh.md").write_text(
        "# Service Mesh\n"
        "Uses Envoy. See [[knowledge:api-versioning]] for API details.\n"
        "Also see [[work:auth-refactor]] for auth migration.\n"
        "Broken ref: [[knowledge:nonexistent-file]].\n"
        "Another broken: [[work:deleted-work]].\n"
        "Broken target: [[knowledge:totally-missing]].\n",
        encoding="utf-8",
    )

    # conventions/ category dir
    conv_dir = kd / "conventions"
    conv_dir.mkdir()

    (conv_dir / "api-versioning.md").write_text(
        "# API Versioning\n"
        "URL-path versioning: `/v1/`, `/v2/`.\n"
        "Thread ref: [[thread:working-style]].\n",
        encoding="utf-8",
    )

    # Work Items
    work_item_dir = kd / "_work" / "auth-refactor"
    work_item_dir.mkdir(parents=True)
    (work_item_dir / "plan.md").write_text(
        "# Auth Refactor Plan\n\n### Goals\nMigrate to JWT.\n",
        encoding="utf-8",
    )

    # Threads
    threads_dir = kd / "_threads"
    threads_dir.mkdir()
    (threads_dir / "working-style.md").write_text(
        "---\ntier: pinned\n---\n\n## 2025-03-01\nEstablished preferences.\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def archive_dir(tmp_path):
    """Knowledge directory with both active and archived plans."""
    kd = tmp_path / "archive_test"
    kd.mkdir()

    # Knowledge entry file referencing both active and archived work items
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "design-overview.md").write_text(
        "# Design Overview\n"
        "See [[work:auth-refactor]] for active auth work.\n"
        "See [[work:old-migration]] for the completed migration.\n"
        "See [[work:truly-missing]] for a nonexistent work item.\n",
        encoding="utf-8",
    )

    # Active work item
    active_work = kd / "_work" / "auth-refactor"
    active_work.mkdir(parents=True)
    (active_work / "plan.md").write_text(
        "# Auth Refactor\n\n### Goals\nMigrate to JWT tokens.\n",
        encoding="utf-8",
    )

    # Archived work item
    archive = kd / "_work" / "_archive" / "old-migration"
    archive.mkdir(parents=True)
    (archive / "plan.md").write_text(
        "# Old Migration Plan\n\n"
        "### Phase 1\nMigrate database schema.\n\n"
        "### Phase 2\nUpdate API endpoints.\n",
        encoding="utf-8",
    )
    (archive / "notes.md").write_text(
        "# Migration Notes\n\n### 2025-01-15\nCompleted migration.\n",
        encoding="utf-8",
    )

    return kd


# ---------------------------------------------------------------------------
# MarkdownParser Tests
# ---------------------------------------------------------------------------

class TestMarkdownParser:
    def test_parse_entry_file(self, knowledge_dir):
        """parse_entry_file treats the whole file as one entry with H1 heading."""
        entries = MarkdownParser.parse_entry_file(str(knowledge_dir / "architecture" / "service-mesh.md"))
        assert len(entries) == 1
        assert entries[0]["heading"] == "Service Mesh"
        assert "Envoy sidecars" in entries[0]["content"]

    def test_parse_entry_file_preserves_file_path(self, knowledge_dir):
        fpath = str(knowledge_dir / "conventions" / "api-versioning.md")
        entries = MarkdownParser.parse_entry_file(fpath)
        assert len(entries) == 1
        assert entries[0]["file_path"] == fpath

    def test_parse_entry_file_no_h1_uses_filename(self, tmp_path):
        """Without H1, parse_entry_file falls back to filename as heading."""
        f = tmp_path / "my-topic.md"
        f.write_text("Some content without a heading.\n", encoding="utf-8")
        entries = MarkdownParser.parse_entry_file(str(f))
        assert len(entries) == 1
        assert entries[0]["heading"] == "My Topic"

    def test_parse_entry_file_empty(self, empty_knowledge_dir):
        entries = MarkdownParser.parse_entry_file(str(empty_knowledge_dir / "empty.md"))
        assert entries == []

    def test_parse_entry_file_nonexistent(self, tmp_path):
        entries = MarkdownParser.parse_entry_file(str(tmp_path / "nonexistent.md"))
        assert entries == []

    def test_parse_file_with_headings(self, tmp_path):
        """parse_file still works for multi-section files (e.g. work items)."""
        f = tmp_path / "multi.md"
        f.write_text(
            "# Multi\n\n"
            "### Section A\nContent A.\n\n"
            "### Section B\nContent B.\n",
            encoding="utf-8",
        )
        entries = MarkdownParser.parse_file(str(f))
        assert len(entries) == 2
        assert entries[0]["heading"] == "Section A"
        assert entries[1]["heading"] == "Section B"

    def test_parse_file_no_headings(self, no_headings_dir):
        entries = MarkdownParser.parse_file(str(no_headings_dir / "notes.md"))
        assert len(entries) == 1
        assert entries[0]["heading"] == "(ungrouped)"
        assert "raw notes" in entries[0]["content"]

    def test_parse_empty_file(self, empty_knowledge_dir):
        entries = MarkdownParser.parse_file(str(empty_knowledge_dir / "empty.md"))
        assert entries == []

    def test_parse_nonexistent_file(self, tmp_path):
        entries = MarkdownParser.parse_file(str(tmp_path / "nonexistent.md"))
        assert entries == []

    def test_parse_unicode_entry_file(self, unicode_dir):
        """parse_entry_file handles unicode content correctly."""
        entries = MarkdownParser.parse_entry_file(str(unicode_dir / "conventions" / "lokalisierung.md"))
        assert len(entries) == 1
        assert entries[0]["heading"] == "Lokalisierung"
        assert "Deutsch" in entries[0]["content"]

        entries = MarkdownParser.parse_entry_file(str(unicode_dir / "conventions" / "internationalization.md"))
        assert len(entries) == 1
        assert entries[0]["heading"] == "国際化"
        assert "多言語対応" in entries[0]["content"]


# ---------------------------------------------------------------------------
# Indexer Tests
# ---------------------------------------------------------------------------

class TestIndexer:
    def test_index_creates_db(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        result = indexer.index_all()
        assert os.path.exists(indexer.db_path)
        # 6 knowledge entry files + 2 work (plan.md, notes.md) + 1 thread = 9 files
        assert result["files_indexed"] == 9
        # 6 knowledge entries (1 per file) +
        # plan.md(3: Goals, Token Rotation, Migration Steps) + notes.md(2: 2025-03-10, 2025-03-15) +
        # working-style.md(2: two ## entries)
        assert result["total_entries"] == 13

    def test_index_skips_inbox_and_index(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        paths = [
            r[0]
            for r in conn.execute("SELECT DISTINCT file_path FROM entries").fetchall()
        ]
        conn.close()

        for p in paths:
            assert "_inbox.md" not in p
            assert "_index.md" not in p

    def test_index_skips_meta_json(self, knowledge_dir):
        """_meta.json files should not be indexed."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        paths = [
            r[0]
            for r in conn.execute("SELECT DISTINCT file_path FROM entries").fetchall()
        ]
        conn.close()

        for p in paths:
            assert "_meta.json" not in p

    def test_index_finds_work_files(self, knowledge_dir):
        """Indexer should pick up plan.md and notes.md from _work/."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        work_paths = [
            r[0]
            for r in conn.execute(
                "SELECT DISTINCT file_path FROM entries WHERE file_path LIKE '%_work%'"
            ).fetchall()
        ]
        conn.close()

        work_basenames = [os.path.basename(p) for p in work_paths]
        assert "plan.md" in work_basenames
        assert "notes.md" in work_basenames

    def test_index_finds_thread_files(self, knowledge_dir):
        """Indexer should pick up .md files from _threads/."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        thread_paths = [
            r[0]
            for r in conn.execute(
                "SELECT DISTINCT file_path FROM entries WHERE file_path LIKE '%_threads%'"
            ).fetchall()
        ]
        conn.close()

        assert len(thread_paths) == 1
        assert "working-style.md" in thread_paths[0]

    def test_source_type_stored_correctly(self, knowledge_dir):
        """source_type column should reflect the origin of each entry."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)

        # Check knowledge entry files
        knowledge_count = conn.execute(
            "SELECT count(*) FROM file_meta WHERE source_type = 'knowledge'"
        ).fetchone()[0]
        assert knowledge_count == 6  # 2 arch + 2 conv + 1 gotcha + 1 workflow

        # Check work entries
        work_count = conn.execute(
            "SELECT count(*) FROM file_meta WHERE source_type = 'work'"
        ).fetchone()[0]
        assert work_count == 2  # plan.md, notes.md

        # Check thread entries
        thread_count = conn.execute(
            "SELECT count(*) FROM file_meta WHERE source_type = 'thread'"
        ).fetchone()[0]
        assert thread_count == 1  # working-style.md

        conn.close()

    def test_source_type_in_fts_entries(self, knowledge_dir):
        """FTS entries table should have source_type populated."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)

        # Work entries in FTS should have source_type='work'
        rows = conn.execute(
            "SELECT source_type FROM entries WHERE file_path LIKE '%_work/%'"
        ).fetchall()
        assert len(rows) > 0
        for (st,) in rows:
            assert st == "work"

        # Thread entries should have source_type='thread'
        rows = conn.execute(
            "SELECT source_type FROM entries WHERE file_path LIKE '%_threads%'"
        ).fetchall()
        assert len(rows) > 0
        for (st,) in rows:
            assert st == "thread"

        # Knowledge entry files should have source_type='knowledge'
        rows = conn.execute(
            "SELECT source_type FROM entries WHERE file_path LIKE '%architecture%'"
        ).fetchall()
        assert len(rows) > 0
        for (st,) in rows:
            assert st == "knowledge"

        conn.close()

    def test_knowledge_entry_files_indexed_as_single_entry(self, knowledge_dir):
        """Each knowledge entry file should produce exactly one FTS entry."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute(
            "SELECT heading, content FROM entries WHERE file_path LIKE '%service-mesh.md'"
        ).fetchall()
        conn.close()

        assert len(rows) == 1
        heading, content = rows[0]
        assert heading == "Service Mesh"
        assert "Envoy sidecars" in content

    def test_force_reindex(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()
        result = indexer.index_all(force=True)
        assert result["files_indexed"] == 9
        assert result["total_entries"] == 13

    def test_index_nonexistent_dir(self, tmp_path):
        indexer = Indexer(str(tmp_path / "nope"))
        result = indexer.index_all()
        assert "error" in result

    def test_file_meta_stored(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute("SELECT file_path, mtime, content_hash FROM file_meta").fetchall()
        conn.close()

        assert len(rows) == 9  # 6 knowledge entry files + 2 work + 1 thread
        for fp, mtime, chash in rows:
            assert mtime > 0
            assert len(chash) == 64  # SHA-256 hex digest

    def test_file_meta_source_type(self, knowledge_dir):
        """file_meta table should track source_type per file."""
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute("SELECT file_path, source_type FROM file_meta").fetchall()
        conn.close()

        type_map = {os.path.basename(fp): st for fp, st in rows}
        assert type_map.get("service-mesh.md") == "knowledge"
        assert type_map.get("database-sharding.md") == "knowledge"
        assert type_map.get("api-versioning.md") == "knowledge"
        assert type_map.get("plan.md") == "work"
        assert type_map.get("notes.md") == "work"
        assert type_map.get("working-style.md") == "thread"

    def test_corrupt_db_rebuilds(self, knowledge_dir):
        """If the DB is corrupt, index_all should recreate it."""
        indexer = Indexer(str(knowledge_dir))
        # Write garbage to the DB path
        with open(indexer.db_path, "w") as f:
            f.write("not a sqlite database")

        result = indexer.index_all()
        assert "error" not in result
        assert result["files_indexed"] == 9


# ---------------------------------------------------------------------------
# Search Tests
# ---------------------------------------------------------------------------

class TestSearcher:
    def test_basic_search(self, knowledge_dir):
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database sharding")
        assert len(results) > 0
        assert results[0]["heading"] == "Database Sharding"

    def test_search_ranking(self, knowledge_dir):
        """A query about 'service mesh' should rank the Service Mesh entry first."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("service mesh envoy")
        assert len(results) > 0
        assert results[0]["heading"] == "Service Mesh"

    def test_search_limit(self, knowledge_dir):
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("the", limit=2)
        assert len(results) <= 2

    def test_search_threshold(self, knowledge_dir):
        searcher = Searcher(str(knowledge_dir))
        # Very strict threshold — should filter out weak matches
        all_results = searcher.search("service")
        strict_results = searcher.search("service", threshold=-5.0)
        assert len(strict_results) <= len(all_results)

    def test_search_no_results(self, knowledge_dir):
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("xyzzy_nonexistent_term")
        assert results == []

    def test_snippet_truncation(self, knowledge_dir):
        """Entries with long content should have truncated snippets."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("connection pool exhaustion")
        assert len(results) > 0
        snippet = results[0]["snippet"]
        assert snippet.endswith("...")
        # Snippet should be at most SNIPPET_MAX_CHARS + 3 (for "...")
        assert len(snippet) <= 503

    def test_snippet_short_content(self, knowledge_dir):
        """Short content should not be truncated."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("deploy pipeline")
        assert len(results) > 0
        snippet = results[0]["snippet"]
        assert not snippet.endswith("...")

    def test_search_entry_file_returns_heading(self, knowledge_dir):
        """Search results for entry files should use the H1 as heading."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("service mesh envoy")
        assert len(results) > 0
        assert results[0]["heading"] == "Service Mesh"
        # file_path should be relative and include category dir
        assert "architecture" in results[0]["file_path"]
        assert "service-mesh.md" in results[0]["file_path"]

    def test_search_auto_indexes(self, knowledge_dir):
        """Search should auto-create index if DB doesn't exist."""
        db_path = os.path.join(str(knowledge_dir), ".pk_search.db")
        assert not os.path.exists(db_path)
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database")
        assert len(results) > 0
        assert os.path.exists(db_path)

    def test_relative_file_paths(self, knowledge_dir):
        """Result file_path should be relative to knowledge_dir."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database")
        for r in results:
            assert not os.path.isabs(r["file_path"])

    def test_search_unicode(self, unicode_dir):
        searcher = Searcher(str(unicode_dir))
        results = searcher.search("Deutsch")
        assert len(results) > 0
        assert results[0]["heading"] == "Lokalisierung"

    def test_search_multiword_query(self, knowledge_dir):
        """Multi-word queries should work without FTS5 column filter issues."""
        searcher = Searcher(str(knowledge_dir))
        # 'error handling' could be misinterpreted as column:filter
        results = searcher.search("error handling")
        assert len(results) > 0
        top = results[0]
        assert top["heading"] == "Error Handling"
        assert "conventions" in top["file_path"]

    def test_prepare_query_plain_words(self):
        assert Searcher._prepare_query("hello world") == '"hello" "world"'

    def test_prepare_query_single_word(self):
        assert Searcher._prepare_query("database") == '"database"'

    def test_prepare_query_with_operators(self):
        # Should be passed through unchanged
        assert Searcher._prepare_query('database OR sharding') == 'database OR sharding'
        assert Searcher._prepare_query('"exact phrase"') == '"exact phrase"'

    def test_prepare_query_empty(self):
        assert Searcher._prepare_query("") == ""
        assert Searcher._prepare_query("  ") == ""

    def test_prepare_query_hyphenated_single(self):
        """Hyphenated token should be split into individually quoted sub-tokens."""
        assert Searcher._prepare_query("file-mutation-as-mocking") == '"file" "mutation" "as" "mocking"'

    def test_prepare_query_hyphenated_multi_word(self):
        """Hyphenated tokens mixed with plain words should all be split and quoted."""
        assert Searcher._prepare_query("service-mesh envoy") == '"service" "mesh" "envoy"'

    def test_prepare_query_hyphenated_leading_trailing(self):
        """Leading/trailing hyphens should not produce empty quoted tokens."""
        assert Searcher._prepare_query("-leading") == '"leading"'
        assert Searcher._prepare_query("trailing-") == '"trailing"'

    def test_search_hyphenated_term_finds_results(self, knowledge_dir):
        """Searching for a hyphenated slug should match content with those words."""
        searcher = Searcher(str(knowledge_dir))
        # "service-mesh" should still find the Service Mesh entry
        results = searcher.search("service-mesh")
        assert len(results) > 0
        assert results[0]["heading"] == "Service Mesh"

    def test_search_hyphenated_multi_segment(self, knowledge_dir):
        """Multi-segment hyphenated query should match content."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("connection-pool-exhaustion")
        assert len(results) > 0
        assert results[0]["heading"] == "Connection Pool Exhaustion"

    def test_source_type_in_search_results(self, knowledge_dir):
        """Search results should include the source_type field."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database sharding")
        assert len(results) > 0
        for r in results:
            assert "source_type" in r
            assert r["source_type"] in SOURCE_TYPES


# ---------------------------------------------------------------------------
# Search Logging Tests
# ---------------------------------------------------------------------------

class TestSearchLogging:
    def test_search_creates_retrieval_log(self, knowledge_dir):
        """Search should create _meta/retrieval-log.jsonl with a JSONL record."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database sharding")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        assert os.path.exists(log_path)

        with open(log_path, encoding="utf-8") as f:
            lines = f.readlines()
        assert len(lines) == 1

        record = json.loads(lines[0])
        assert record["event"] == "search"
        assert record["query"] == "database sharding"
        assert record["source_type"] is None
        assert record["result_count"] > 0
        assert record["elapsed_ms"] >= 0
        assert "timestamp" in record

    def test_search_logging_appends(self, knowledge_dir):
        """Multiple searches should append to the same log file."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database")
        searcher.search("service mesh")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        with open(log_path, encoding="utf-8") as f:
            lines = f.readlines()
        assert len(lines) == 2

        first = json.loads(lines[0])
        second = json.loads(lines[1])
        assert first["query"] == "database"
        assert second["query"] == "service mesh"

    def test_search_logging_records_source_type(self, knowledge_dir):
        """Log should capture the source_type filter when provided."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("JWT", source_type="work")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        with open(log_path, encoding="utf-8") as f:
            record = json.loads(f.readline())
        assert record["source_type"] == "work"

    def test_search_logging_records_zero_results(self, knowledge_dir):
        """Log should record result_count=0 when no results found."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("xyzzy_nonexistent_term")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        with open(log_path, encoding="utf-8") as f:
            record = json.loads(f.readline())
        assert record["result_count"] == 0

    def test_search_logging_creates_meta_dir(self, knowledge_dir):
        """_log_search should create _meta/ if it doesn't exist."""
        meta_dir = os.path.join(str(knowledge_dir), "_meta")
        assert not os.path.exists(meta_dir)

        searcher = Searcher(str(knowledge_dir))
        searcher.search("database")

        assert os.path.isdir(meta_dir)

    def test_search_logging_caller_present(self, knowledge_dir):
        """When caller is provided, it should appear in the JSONL record."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database", caller="prefetch")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        with open(log_path, encoding="utf-8") as f:
            record = json.loads(f.readline())
        assert record["caller"] == "prefetch"

    def test_search_logging_caller_absent(self, knowledge_dir):
        """When caller is not provided, the field should not appear in the JSONL record."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database")

        log_path = os.path.join(str(knowledge_dir), "_meta", "retrieval-log.jsonl")
        with open(log_path, encoding="utf-8") as f:
            record = json.loads(f.readline())
        assert "caller" not in record


# ---------------------------------------------------------------------------
# Source Type Filter Tests
# ---------------------------------------------------------------------------

class TestSourceTypeFilter:
    def test_search_type_knowledge(self, knowledge_dir):
        """--type=knowledge should only return knowledge entries."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("the", source_type="knowledge")
        assert len(results) > 0
        for r in results:
            assert r["source_type"] == "knowledge"

    def test_search_type_work(self, knowledge_dir):
        """--type=work should only return work entries."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("JWT", source_type="work")
        assert len(results) > 0
        for r in results:
            assert r["source_type"] == "work"

    def test_search_type_thread(self, knowledge_dir):
        """--type=thread should only return thread entries."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("bullet points", source_type="thread")
        assert len(results) > 0
        for r in results:
            assert r["source_type"] == "thread"

    def test_search_no_type_returns_all(self, knowledge_dir):
        """No type filter should return results from all source types."""
        searcher = Searcher(str(knowledge_dir))
        # Use a broad query that should hit multiple types
        results = searcher.search("the", limit=20)
        types_seen = {r["source_type"] for r in results}
        # With our fixture data, we should see at least knowledge entries
        assert "knowledge" in types_seen

    def test_search_type_work_excludes_knowledge(self, knowledge_dir):
        """Work filter should not return knowledge entries."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database sharding", source_type="work")
        # "Database Sharding" is in architecture.md (knowledge), not work items
        headings = [r["heading"] for r in results]
        assert "Database Sharding" not in headings

    def test_search_type_thread_excludes_others(self, knowledge_dir):
        """Thread filter should not return work or knowledge entries."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("JWT migration", source_type="thread")
        # JWT migration is in work item, not thread
        assert all(r["source_type"] == "thread" for r in results)

    def test_source_type_field_present(self, knowledge_dir):
        """All search results should include source_type."""
        searcher = Searcher(str(knowledge_dir))
        for source_type in (None, "knowledge", "plan", "thread"):
            results = searcher.search("the", source_type=source_type)
            for r in results:
                assert "source_type" in r
                assert r["source_type"] in SOURCE_TYPES


# ---------------------------------------------------------------------------
# Auto-Reindex Tests
# ---------------------------------------------------------------------------

class TestAutoReindex:
    def test_stale_detection_new_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Add a new entry file in a category dir
        (knowledge_dir / "architecture" / "new-topic.md").write_text(
            "# New Topic\nBrand new content.\n",
            encoding="utf-8",
        )

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("new-topic.md" in f for f in stale_paths)

    def test_stale_detection_modified_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Modify an existing entry file (ensure mtime changes)
        entry_path = knowledge_dir / "architecture" / "service-mesh.md"
        time.sleep(0.05)
        entry_path.write_text(
            entry_path.read_text() + "\nAdded more content.\n",
            encoding="utf-8",
        )

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("service-mesh.md" in f for f in stale_paths)

    def test_stale_detection_deleted_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Delete an entry file
        (knowledge_dir / "gotchas" / "connection-pool-exhaustion.md").unlink()

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("connection-pool-exhaustion.md" in f for f in stale_paths)

    def test_incremental_reindex(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Modify one entry file
        time.sleep(0.05)
        (knowledge_dir / "conventions" / "api-versioning.md").write_text(
            "# New Convention\nThis replaces old content entirely.\n",
            encoding="utf-8",
        )

        result = indexer.incremental_index()
        assert result["files_reindexed"] >= 1

        # Verify the entry is updated
        conn = sqlite3.connect(indexer.db_path)
        headings = [
            r[0]
            for r in conn.execute(
                "SELECT heading FROM entries WHERE file_path LIKE '%api-versioning.md'"
            ).fetchall()
        ]
        conn.close()

        assert "New Convention" in headings
        assert "API Versioning" not in headings

    def test_incremental_removes_deleted(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Delete an entry file
        (knowledge_dir / "gotchas" / "connection-pool-exhaustion.md").unlink()

        result = indexer.incremental_index()
        assert result["files_removed"] >= 1

        # Verify entries removed
        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute(
            "SELECT * FROM entries WHERE file_path LIKE '%connection-pool-exhaustion.md'"
        ).fetchall()
        conn.close()
        assert len(rows) == 0

    def test_search_auto_reindexes_stale(self, knowledge_dir):
        """Searching after a file changes should auto-reindex."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database")  # triggers initial index

        # Add a new entry file in a category dir
        time.sleep(0.05)
        (knowledge_dir / "architecture" / "quantum-computing.md").write_text(
            "# Quantum Computing\nEntanglement-based key distribution.\n",
            encoding="utf-8",
        )

        # Search should find the new entry
        results = searcher.search("quantum computing")
        assert len(results) > 0
        assert results[0]["heading"] == "Quantum Computing"


# ---------------------------------------------------------------------------
# Resolver Tests
# ---------------------------------------------------------------------------

class TestResolver:
    def test_resolve_knowledge_entry_by_slug(self, knowledge_dir):
        """Resolve [[knowledge:service-mesh]] finds entry file in category dir."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:service-mesh]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "service-mesh"
        assert "Envoy sidecars" in result["content"]

    def test_resolve_knowledge_entry_by_category_path(self, knowledge_dir):
        """Resolve [[knowledge:architecture/service-mesh]] with explicit category."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:architecture/service-mesh]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert "Envoy sidecars" in result["content"]

    def test_resolve_knowledge_full_entry_file(self, knowledge_dir):
        """Resolve [[knowledge:api-versioning]] returns full entry content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:api-versioning]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "api-versioning"
        assert result["heading"] is None
        assert "URL-path versioning" in result["content"]

    def test_resolve_work(self, knowledge_dir):
        """Resolve [[work:auth-refactor]] returns plan.md content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[work:auth-refactor]]")
        assert result["resolved"] is True
        assert result["source_type"] == "work"
        assert result["target"] == "auth-refactor"
        assert "JWT tokens" in result["content"]

    def test_resolve_work_with_heading(self, knowledge_dir):
        """Resolve [[work:auth-refactor#Token Rotation]] returns section from work item."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[work:auth-refactor#Token Rotation]]")
        assert result["resolved"] is True
        assert result["source_type"] == "work"
        assert "Refresh tokens" in result["content"]
        assert "Redis" in result["content"]

    def test_resolve_plan_deprecated_alias(self, knowledge_dir):
        """Resolve [[plan:auth-refactor]] still works as deprecated alias."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[plan:auth-refactor]]")
        assert result["resolved"] is True
        assert result["source_type"] == "plan"
        assert result["target"] == "auth-refactor"
        assert "JWT tokens" in result["content"]

    def test_resolve_thread(self, knowledge_dir):
        """Resolve [[thread:working-style]] returns thread content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[thread:working-style]]")
        assert result["resolved"] is True
        assert result["source_type"] == "thread"
        assert result["target"] == "working-style"
        assert "bullet points" in result["content"]

    def test_resolve_nonexistent_target(self, knowledge_dir):
        """Resolving a nonexistent file returns resolved=False."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:nonexistent-file]]")
        assert result["resolved"] is False
        assert "error" in result
        assert "not found" in result["error"].lower()

    def test_resolve_nonexistent_work(self, knowledge_dir):
        """Resolving a nonexistent work item returns resolved=False."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[work:does-not-exist]]")
        assert result["resolved"] is False
        assert "error" in result

    def test_resolve_nonexistent_thread(self, knowledge_dir):
        """Resolving a nonexistent thread returns resolved=False."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[thread:nonexistent-thread]]")
        assert result["resolved"] is False
        assert "error" in result

    def test_resolve_batch(self, knowledge_dir):
        """resolve_batch should handle multiple backlinks."""
        resolver = Resolver(str(knowledge_dir))
        backlinks = [
            "[[knowledge:service-mesh]]",
            "[[work:auth-refactor]]",
            "[[thread:working-style]]",
            "[[knowledge:nonexistent]]",
        ]
        results = resolver.resolve_batch(backlinks)
        assert len(results) == 4
        assert results[0]["resolved"] is True
        assert results[1]["resolved"] is True
        assert results[2]["resolved"] is True
        assert results[3]["resolved"] is False

    def test_resolve_invalid_syntax(self, knowledge_dir):
        """Invalid backlink syntax returns error."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("not a backlink at all")
        assert result["resolved"] is False
        assert "error" in result
        assert "invalid" in result["error"].lower() or "syntax" in result["error"].lower()

    def test_resolve_invalid_syntax_partial(self, knowledge_dir):
        """Partial/malformed backlink returns error."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[badtype:something]]")
        assert result["resolved"] is False

    def test_resolve_work_heading_not_found(self, knowledge_dir):
        """Work item exists but heading does not."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[work:auth-refactor#Nonexistent Step]]")
        assert result["resolved"] is False
        assert "error" in result

    def test_resolve_bare_category(self, knowledge_dir):
        """[[knowledge:architecture]] resolves to a listing of entry titles."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:architecture]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "architecture"
        assert result["heading"] is None
        # Should contain H1 titles from entry files
        assert "Database Sharding" in result["content"]
        assert "Service Mesh" in result["content"]

    def test_resolve_category_with_heading(self, knowledge_dir):
        """[[knowledge:gotchas#Connection Pool Exhaustion]] resolves to the entry content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:gotchas#Connection Pool Exhaustion]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "gotchas"
        assert result["heading"] == "Connection Pool Exhaustion"
        assert "Connection Pool Exhaustion" in result["content"]

    def test_resolve_category_nonexistent_heading(self, knowledge_dir):
        """[[knowledge:gotchas#Nonexistent Heading]] returns resolved=False."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:gotchas#Nonexistent Heading]]")
        assert result["resolved"] is False
        assert "error" in result
        assert "not found" in result["error"].lower()

    def test_resolve_fully_qualified_entry_still_works(self, knowledge_dir):
        """[[knowledge:architecture/service-mesh]] still resolves (regression check)."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:architecture/service-mesh]]")
        assert result["resolved"] is True
        assert "Envoy sidecars" in result["content"]


# ---------------------------------------------------------------------------
# Link Checker Tests
# ---------------------------------------------------------------------------

class TestLinkChecker:
    def test_check_all_finds_broken_links(self, link_check_dir):
        """check_all should find broken backlinks."""
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()

        assert result["broken_count"] > 0
        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        assert any("nonexistent-file" in bl for bl in broken_backlinks)
        assert any("deleted-work" in bl for bl in broken_backlinks)
        assert any("totally-missing" in bl for bl in broken_backlinks)

    def test_check_all_counts_total_links(self, link_check_dir):
        """check_all should count all backlinks including valid ones."""
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()

        # Valid links: [[knowledge:api-versioning]], [[work:auth-refactor]],
        #              [[thread:working-style]]
        # Broken links: [[knowledge:nonexistent-file]], [[work:deleted-work]],
        #               [[knowledge:totally-missing]]
        assert result["total_links"] >= 6
        # At least 3 should be broken
        assert result["broken_count"] >= 3

    def test_check_all_valid_links_not_broken(self, link_check_dir):
        """Valid backlinks should not appear in broken_links."""
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()

        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        # These are valid and should NOT be in broken list
        assert not any("[[work:auth-refactor]]" == bl for bl in broken_backlinks)
        assert not any("[[thread:working-style]]" == bl for bl in broken_backlinks)

    def test_check_all_reports_source_file(self, link_check_dir):
        """Broken link reports should include the source file."""
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()

        for bl in result["broken_links"]:
            assert "source_file" in bl
            assert "error" in bl

    def test_check_all_no_links(self, tmp_path):
        """Directory with no backlinks should report zero total."""
        kd = tmp_path / "nolinks"
        kd.mkdir()
        (kd / "plain.md").write_text(
            "# Plain\n\n### Section\nNo backlinks here.\n",
            encoding="utf-8",
        )
        checker = LinkChecker(str(kd))
        result = checker.check_all()
        assert result["total_links"] == 0
        assert result["broken_count"] == 0

    def test_check_all_skips_code_blocks(self, tmp_path):
        """Backlinks inside fenced code blocks should be ignored."""
        kd = tmp_path / "codeblocks"
        kd.mkdir()
        (kd / "docs.md").write_text(
            "# Docs\n\n"
            "### Examples\n"
            "Here's how to use backlinks:\n\n"
            "```markdown\n"
            "See also: [[knowledge:fake-file#Fake Heading]]\n"
            "And: [[plan:fake-plan]]\n"
            "```\n\n"
            "The above are just examples.\n",
            encoding="utf-8",
        )
        checker = LinkChecker(str(kd))
        result = checker.check_all()
        # Backlinks inside code blocks should not be counted
        assert result["total_links"] == 0
        assert result["broken_count"] == 0

    def test_check_all_mixed_code_and_real_links(self, link_check_dir):
        """Real backlinks should still be found when code blocks also exist."""
        # Add an entry file with both real and code-block backlinks
        (link_check_dir / "conventions" / "mixed.md").write_text(
            "# Mixed\n"
            "See [[knowledge:api-versioning]].\n\n"
            "```python\n"
            '# Template: [[knowledge:nonexistent-template]]\n'
            "```\n",
            encoding="utf-8",
        )
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()
        # The real link in mixed.md should be found, but not the code-block one
        all_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        assert "[[knowledge:nonexistent-template]]" not in all_backlinks

    def test_strip_code_blocks_static_method(self):
        """_strip_code_blocks removes fenced blocks and preserves other content."""
        text = (
            "Before\n"
            "```\n"
            "[[knowledge:inside#Block]]\n"
            "```\n"
            "After [[knowledge:outside#Block]]\n"
        )
        stripped = LinkChecker._strip_code_blocks(text)
        assert "[[knowledge:inside#Block]]" not in stripped
        assert "[[knowledge:outside#Block]]" in stripped


# ---------------------------------------------------------------------------
# Schema Migration Tests
# ---------------------------------------------------------------------------

class TestSchemaMigration:
    def test_old_db_rebuilds_to_current(self, knowledge_dir):
        """An old-version database should be rebuilt on index_all."""
        kd_str = str(knowledge_dir)
        db_path = os.path.join(kd_str, ".pk_search.db")

        # Create a v1-style database manually
        conn = sqlite3.connect(db_path)
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
        """)
        # Store v1 schema version
        conn.execute(
            "INSERT OR REPLACE INTO index_meta (key, value) VALUES (?, ?)",
            ("schema_version", "1"),
        )
        conn.commit()
        conn.close()

        # Now run index_all — it should detect v1 and rebuild
        indexer = Indexer(kd_str)
        result = indexer.index_all()

        assert "error" not in result
        assert result["files_indexed"] == 9

        # Verify current schema version is now in place
        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key='schema_version'"
        ).fetchone()
        assert row is not None
        assert int(row[0]) == Indexer.SCHEMA_VERSION

        # Verify source_type column exists in entries (query should not error)
        rows = conn.execute("SELECT source_type FROM entries LIMIT 1").fetchall()
        assert len(rows) > 0

        # Verify source_type column exists in file_meta
        rows = conn.execute("SELECT source_type FROM file_meta LIMIT 1").fetchall()
        assert len(rows) > 0

        conn.close()

    def test_no_db_creates_current_schema(self, knowledge_dir):
        """Fresh index with no existing DB should create current schema."""
        kd_str = str(knowledge_dir)
        db_path = os.path.join(kd_str, ".pk_search.db")
        assert not os.path.exists(db_path)

        indexer = Indexer(kd_str)
        indexer.index_all()

        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key='schema_version'"
        ).fetchone()
        assert int(row[0]) == Indexer.SCHEMA_VERSION
        conn.close()


# ---------------------------------------------------------------------------
# Stats Tests
# ---------------------------------------------------------------------------

class TestStats:
    def test_stats_after_index(self, knowledge_dir):
        Indexer(str(knowledge_dir)).index_all()
        stats = Stats(str(knowledge_dir)).get_stats()

        assert stats["entry_count"] == 13  # 6 knowledge + 5 work + 2 thread
        assert stats["file_count"] == 9  # 6 knowledge + 2 work + 1 thread
        assert stats["db_size_bytes"] > 0
        assert stats["last_indexed"] != "never"
        assert stats["stale_files"] == 0

    def test_stats_type_counts(self, knowledge_dir):
        """Stats should include per-type file counts."""
        Indexer(str(knowledge_dir)).index_all()
        stats = Stats(str(knowledge_dir)).get_stats()

        assert "type_counts" in stats
        tc = stats["type_counts"]
        assert tc.get("knowledge") == 6
        assert tc.get("work") == 2
        assert tc.get("thread") == 1

    def test_stats_no_db(self, tmp_path):
        kd = tmp_path / "noindex"
        kd.mkdir()
        stats = Stats(str(kd)).get_stats()
        assert "error" in stats

    def test_stats_shows_stale(self, knowledge_dir):
        Indexer(str(knowledge_dir)).index_all()

        # Add an entry file to make things stale
        (knowledge_dir / "architecture" / "extra.md").write_text(
            "# Extra\nBonus content.\n",
            encoding="utf-8",
        )

        stats = Stats(str(knowledge_dir)).get_stats()
        assert stats["stale_files"] >= 1


# ---------------------------------------------------------------------------
# CLI Integration Tests
# ---------------------------------------------------------------------------

class TestCLI:
    def test_cli_index(self, knowledge_dir):
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Indexed" in result.stdout

    def test_cli_search_human(self, knowledge_dir):
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        # Index first
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )
        result = subprocess.run(
            [sys.executable, script, "search", str(knowledge_dir), "database"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Database Sharding" in result.stdout

    def test_cli_search_json(self, knowledge_dir):
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )
        result = subprocess.run(
            [sys.executable, script, "search", str(knowledge_dir), "database", "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert isinstance(data, list)
        assert len(data) > 0
        assert "heading" in data[0]
        assert "score" in data[0]
        assert "source_type" in data[0]

    def test_cli_search_with_type_filter(self, knowledge_dir):
        """CLI search with --type flag should filter results."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )
        result = subprocess.run(
            [sys.executable, script, "search", str(knowledge_dir), "JWT", "--type", "work", "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        for entry in data:
            assert entry["source_type"] == "work"

    def test_cli_stats(self, knowledge_dir):
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )
        result = subprocess.run(
            [sys.executable, script, "stats", str(knowledge_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Files indexed:" in result.stdout
        assert "Total entries:" in result.stdout
        assert "By type:" in result.stdout

    def test_cli_no_results(self, knowledge_dir):
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )
        result = subprocess.run(
            [sys.executable, script, "search", str(knowledge_dir), "xyzzy_nothing"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "No results" in result.stdout

    def test_cli_incremental_index(self, knowledge_dir):
        """CLI incremental-index subcommand."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        # Full index first
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )

        # Run incremental with no changes — should say "up to date"
        result = subprocess.run(
            [sys.executable, script, "incremental-index", str(knowledge_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "up to date" in result.stdout.lower() or "Reindexed" in result.stdout

    def test_cli_incremental_index_detects_changes(self, knowledge_dir):
        """CLI incremental-index should detect and reindex changed files."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        subprocess.run(
            [sys.executable, script, "index", str(knowledge_dir)],
            capture_output=True,
        )

        # Modify an entry file
        time.sleep(0.05)
        (knowledge_dir / "conventions" / "api-versioning.md").write_text(
            "# Shiny New Convention\nBrand new.\n",
            encoding="utf-8",
        )

        result = subprocess.run(
            [sys.executable, script, "incremental-index", str(knowledge_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Reindexed" in result.stdout

    def test_cli_resolve_human(self, knowledge_dir):
        """CLI resolve subcommand with human-readable output."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "resolve", str(knowledge_dir),
             "[[knowledge:service-mesh]]"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Service Mesh" in result.stdout
        assert "Envoy" in result.stdout

    def test_cli_resolve_json(self, knowledge_dir):
        """CLI resolve subcommand with --json output."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "resolve", str(knowledge_dir),
             "[[knowledge:service-mesh]]", "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert isinstance(data, list)
        assert len(data) == 1
        assert data[0]["resolved"] is True
        assert "Envoy" in data[0]["content"]

    def test_cli_resolve_multiple(self, knowledge_dir):
        """CLI resolve with multiple backlinks."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "resolve", str(knowledge_dir),
             "[[knowledge:api-versioning]]", "[[work:auth-refactor]]", "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert len(data) == 2
        assert data[0]["resolved"] is True
        assert data[1]["resolved"] is True

    def test_cli_resolve_broken(self, knowledge_dir):
        """CLI resolve with a broken backlink."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "resolve", str(knowledge_dir),
             "[[knowledge:nonexistent]]", "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert len(data) == 1
        assert data[0]["resolved"] is False

    def test_cli_check_links_human(self, link_check_dir):
        """CLI check-links subcommand with human-readable output."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "check-links", str(link_check_dir)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Total backlinks scanned:" in result.stdout
        assert "Broken links:" in result.stdout

    def test_cli_check_links_json(self, link_check_dir):
        """CLI check-links subcommand with --json output."""
        import subprocess

        script = os.path.join(os.path.dirname(__file__), "..", "scripts", "pk_search.py")
        result = subprocess.run(
            [sys.executable, script, "check-links", str(link_check_dir), "--json"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert "total_links" in data
        assert "broken_count" in data
        assert "broken_links" in data
        assert data["broken_count"] >= 3


# ---------------------------------------------------------------------------
# Archive-Aware Tests
# ---------------------------------------------------------------------------

class TestArchiveIndexing:
    """Test that archived plans are indexed and searchable."""

    def test_collect_md_files_includes_archive(self, archive_dir):
        """_collect_md_files should include files from _work/_archive/."""
        indexer = Indexer(str(archive_dir))
        md_files = indexer._collect_md_files()
        paths = [fp for fp, _ in md_files]

        # Active work item should be found
        assert any("auth-refactor" in p and "plan.md" in p for p in paths)
        # Archived work item files should also be found
        assert any("_archive" in p and "old-migration" in p and "plan.md" in p for p in paths)
        assert any("_archive" in p and "old-migration" in p and "notes.md" in p for p in paths)

    def test_collect_md_files_archive_source_type(self, archive_dir):
        """Archived work item files should have source_type 'work'."""
        indexer = Indexer(str(archive_dir))
        md_files = indexer._collect_md_files()
        archive_files = [(fp, st) for fp, st in md_files if "_work/_archive/" in fp]

        assert len(archive_files) == 2  # plan.md + notes.md
        for _, source_type in archive_files:
            assert source_type == "work"

    def test_index_includes_archived_entries(self, archive_dir):
        """Full index should contain entries from archived work items."""
        indexer = Indexer(str(archive_dir))
        result = indexer.index_all()

        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute(
            "SELECT heading FROM entries WHERE file_path LIKE '%_archive%old-migration%'"
        ).fetchall()
        conn.close()

        headings = [r[0] for r in rows]
        assert "Phase 1" in headings
        assert "Phase 2" in headings

    def test_search_finds_archived_work_content(self, archive_dir):
        """Search should return results from archived work items when include_archived=True."""
        searcher = Searcher(str(archive_dir))
        results = searcher.search("database schema", include_archived=True)

        assert len(results) > 0
        assert any("old-migration" in r["file_path"] for r in results)

    def test_incremental_index_includes_archive(self, archive_dir):
        """Incremental index should detect changes in archived work items."""
        indexer = Indexer(str(archive_dir))
        indexer.index_all()

        # Modify an archived work item
        time.sleep(0.05)
        archive_plan = archive_dir / "_work" / "_archive" / "old-migration" / "plan.md"
        archive_plan.write_text(
            "# Old Migration Plan\n\n### Phase 1 (Revised)\nUpdated schema migration.\n",
            encoding="utf-8",
        )

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("old-migration" in p for p in stale_paths)

    def test_stats_count_includes_archive(self, archive_dir):
        """Stats should count archived work item files."""
        Indexer(str(archive_dir)).index_all()
        stats = Stats(str(archive_dir)).get_stats()

        # 1 knowledge entry file + 1 active work item + 2 archived work item files = 4
        assert stats["file_count"] == 4
        assert stats["type_counts"].get("knowledge") == 1
        assert stats["type_counts"].get("work") == 3  # 1 active + 2 archived


class TestArchiveResolver:
    """Test that the resolver falls back to _work/_archive/."""

    def test_resolve_archived_work(self, archive_dir):
        """Resolving an archived work item should succeed."""
        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:old-migration]]")

        assert result["resolved"] is True
        assert result["source_type"] == "work"
        assert result["target"] == "old-migration"
        assert "database schema" in result["content"].lower() or "Migration Plan" in result["content"]

    def test_resolve_archived_work_has_archived_flag(self, archive_dir):
        """Archived work item resolution should include archived=True."""
        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:old-migration]]")

        assert result["resolved"] is True
        assert result.get("archived") is True

    def test_resolve_active_work_no_archived_flag(self, archive_dir):
        """Active work item resolution should NOT have archived flag."""
        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:auth-refactor]]")

        assert result["resolved"] is True
        assert "archived" not in result

    def test_resolve_archived_work_with_heading(self, archive_dir):
        """Resolving a heading from an archived work item should work."""
        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:old-migration#Phase 1]]")

        assert result["resolved"] is True
        assert result.get("archived") is True
        assert "database schema" in result["content"].lower()

    def test_resolve_truly_missing_work(self, archive_dir):
        """A work item that doesn't exist anywhere should still fail."""
        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:truly-missing]]")

        assert result["resolved"] is False
        assert "not found" in result["error"].lower()

    def test_resolve_prefers_active_over_archive(self, archive_dir):
        """If a work item exists in both active and archive, prefer active."""
        # Create same slug in both locations
        active = archive_dir / "_work" / "dual-item"
        active.mkdir(parents=True)
        (active / "plan.md").write_text("# Active Version\n\n### Goals\nActive content.\n")

        archived = archive_dir / "_work" / "_archive" / "dual-item"
        archived.mkdir(parents=True)
        (archived / "plan.md").write_text("# Archived Version\n\n### Goals\nArchived content.\n")

        resolver = Resolver(str(archive_dir))
        result = resolver.resolve("[[work:dual-item]]")

        assert result["resolved"] is True
        assert "Active content" in result["content"] or "Active Version" in result["content"]
        assert "archived" not in result  # should resolve from active path


class TestArchiveLinkChecker:
    """Test that check-links distinguishes archived from broken."""

    def test_check_links_separates_archived_from_broken(self, archive_dir):
        """check_all should report archived refs separately from broken ones."""
        checker = LinkChecker(str(archive_dir))
        result = checker.check_all()

        # [[work:old-migration]] should be archived, not broken
        archived_backlinks = [al["backlink"] for al in result["archived_links"]]
        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]

        assert any("old-migration" in bl for bl in archived_backlinks)
        assert not any("old-migration" in bl for bl in broken_backlinks)

        # [[work:truly-missing]] should be broken, not archived
        assert any("truly-missing" in bl for bl in broken_backlinks)
        assert not any("truly-missing" in bl for bl in archived_backlinks)

    def test_check_links_active_work_not_reported(self, archive_dir):
        """Active work items should not appear in archived or broken."""
        checker = LinkChecker(str(archive_dir))
        result = checker.check_all()

        archived_backlinks = [al["backlink"] for al in result["archived_links"]]
        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]

        assert not any("auth-refactor" in bl for bl in archived_backlinks)
        assert not any("auth-refactor" in bl for bl in broken_backlinks)

    def test_check_links_json_includes_archived(self, archive_dir):
        """JSON output should include archived_count and archived_links."""
        checker = LinkChecker(str(archive_dir))
        result = checker.check_all()

        assert "archived_count" in result
        assert "archived_links" in result
        assert result["archived_count"] >= 1


# ---------------------------------------------------------------------------
# Scope Filtering Tests (include_archived / include_threads)
# ---------------------------------------------------------------------------

@pytest.fixture
def filtering_dir(tmp_path):
    """Knowledge directory with archived work files and thread files containing backlinks."""
    kd = tmp_path / "filtering"
    kd.mkdir()

    # Knowledge entry — clean, no broken links
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "api-versioning.md").write_text(
        "# API Versioning\nURL-path versioning.\n",
        encoding="utf-8",
    )

    # Active work item (valid target for backlinks)
    active_work = kd / "_work" / "auth-refactor"
    active_work.mkdir(parents=True)
    (active_work / "plan.md").write_text(
        "# Auth Refactor\n\n### Goals\nMigrate to JWT.\n"
        "See [[knowledge:api-versioning]].\n",
        encoding="utf-8",
    )

    # Archived work item with broken backlinks inside its files
    archive = kd / "_work" / "_archive" / "old-migration"
    archive.mkdir(parents=True)
    (archive / "plan.md").write_text(
        "# Old Migration Plan\n\n### Phase 1\n"
        "See [[knowledge:deleted-convention]].\n"
        "And [[work:nonexistent-work]].\n",
        encoding="utf-8",
    )
    (archive / "notes.md").write_text(
        "# Migration Notes\n\n### 2025-01-15\n"
        "Ref: [[knowledge:another-missing]].\n",
        encoding="utf-8",
    )

    # Thread file with broken backlinks inside
    threads_dir = kd / "_threads"
    threads_dir.mkdir()
    (threads_dir / "working-style.md").write_text(
        "---\ntier: pinned\n---\n\n## 2025-03-01\n"
        "See [[knowledge:thread-only-broken-ref]].\n"
        "And [[work:thread-missing-work]].\n",
        encoding="utf-8",
    )

    return kd


class TestCheckAllFiltering:
    """Test check_all() scope filtering with include_archived and include_threads."""

    def test_default_excludes_archived_work_files(self, filtering_dir):
        """Default check_all() should not report broken links from _work/_archive/ source files."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all()

        source_files = [bl["source_file"] for bl in result["broken_links"]]
        # No broken links should come from archived source files
        assert not any("_archive" in sf for sf in source_files)
        # The archived files have broken links, so if they were included they'd appear
        # Verify active work item's valid link is not broken
        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        assert not any("api-versioning" in bl for bl in broken_backlinks)

    def test_default_excludes_thread_files(self, filtering_dir):
        """Default check_all() should not report broken links from _threads/ source files."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all()

        source_files = [bl["source_file"] for bl in result["broken_links"]]
        # No broken links should come from thread source files
        assert not any("_threads" in sf for sf in source_files)

    def test_include_all_includes_archived_and_threads(self, filtering_dir):
        """check_all(include_archived=True, include_threads=True) includes all files."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all(include_archived=True, include_threads=True)

        source_files = [bl["source_file"] for bl in result["broken_links"]]
        # Archived work files should now contribute broken links
        assert any("_archive" in sf for sf in source_files)
        # Thread files should now contribute broken links
        assert any("_threads" in sf for sf in source_files)

        # Verify specific broken links from archived files are present
        broken_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        assert any("deleted-convention" in bl for bl in broken_backlinks)
        assert any("nonexistent-work" in bl for bl in broken_backlinks)
        assert any("another-missing" in bl for bl in broken_backlinks)
        # Verify specific broken links from thread files are present
        assert any("thread-only-broken-ref" in bl for bl in broken_backlinks)
        assert any("thread-missing-work" in bl for bl in broken_backlinks)

    def test_skipped_counts_when_filtering(self, filtering_dir):
        """Return dict should include skipped file counts when filtering is active."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all()

        assert "skipped_archived_files" in result
        assert "skipped_thread_files" in result
        # archive has 2 files (plan.md, notes.md), thread has 1 file
        assert result["skipped_archived_files"] == 2
        assert result["skipped_thread_files"] == 1

    def test_skipped_counts_zero_when_including_all(self, filtering_dir):
        """Skipped counts should be 0 when include_archived=True, include_threads=True."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all(include_archived=True, include_threads=True)

        assert result["skipped_archived_files"] == 0
        assert result["skipped_thread_files"] == 0

    def test_include_archived_only(self, filtering_dir):
        """include_archived=True alone should include archived but still skip threads."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all(include_archived=True, include_threads=False)

        source_files = [bl["source_file"] for bl in result["broken_links"]]
        # Archived files should contribute broken links
        assert any("_archive" in sf for sf in source_files)
        # Thread files should still be excluded
        assert not any("_threads" in sf for sf in source_files)
        assert result["skipped_archived_files"] == 0
        assert result["skipped_thread_files"] == 1

    def test_include_threads_only(self, filtering_dir):
        """include_threads=True alone should include threads but still skip archived."""
        checker = LinkChecker(str(filtering_dir))
        result = checker.check_all(include_archived=False, include_threads=True)

        source_files = [bl["source_file"] for bl in result["broken_links"]]
        # Thread files should contribute broken links
        assert any("_threads" in sf for sf in source_files)
        # Archived files should still be excluded
        assert not any("_archive" in sf for sf in source_files)
        assert result["skipped_archived_files"] == 2
        assert result["skipped_thread_files"] == 0


# ---------------------------------------------------------------------------
# Archive Exclusion in Search Tests
# ---------------------------------------------------------------------------

@pytest.fixture
def archive_search_dir(tmp_path):
    """Knowledge directory with active work, archived work, and knowledge entries
    sharing overlapping search terms for testing archive exclusion in search."""
    kd = tmp_path / "archive_search"
    kd.mkdir()

    # Knowledge entry — uses "migration" keyword
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "migration-strategy.md").write_text(
        "# Migration Strategy\n"
        "Database migration follows blue-green deployment. "
        "Each migration step is reversible and idempotent.\n",
        encoding="utf-8",
    )

    # Active work item — also uses "migration" keyword
    active_work = kd / "_work" / "db-migration"
    active_work.mkdir(parents=True)
    (active_work / "plan.md").write_text(
        "# DB Migration Plan\n\n"
        "### Goals\n"
        "Migrate the primary database from MySQL to PostgreSQL.\n\n"
        "### Steps\n"
        "1. Schema migration\n"
        "2. Data migration\n"
        "3. Cutover\n",
        encoding="utf-8",
    )

    # Archived work item — uses "migration" keyword heavily
    archive = kd / "_work" / "_archive" / "legacy-migration"
    archive.mkdir(parents=True)
    (archive / "plan.md").write_text(
        "# Legacy Migration Plan\n\n"
        "### Phase 1\n"
        "Migration of legacy monolith to microservices.\n"
        "Complete migration of all API endpoints.\n\n"
        "### Phase 2\n"
        "Migration of data layer. Full database migration completed.\n",
        encoding="utf-8",
    )
    (archive / "notes.md").write_text(
        "# Legacy Migration Notes\n\n"
        "### 2024-06-01\n"
        "Migration kickoff. Identified all migration targets.\n\n"
        "### 2024-09-15\n"
        "Migration complete. All services migrated successfully.\n",
        encoding="utf-8",
    )

    return kd


class TestArchiveExclusion:
    """Test that Searcher.search() excludes archived work items by default."""

    def test_default_excludes_archived(self, archive_search_dir):
        """Default search should not return results from _work/_archive/."""
        searcher = Searcher(str(archive_search_dir))
        results = searcher.search("migration", limit=20)

        # Should have results from knowledge and active work
        assert len(results) > 0

        # No result should come from an archived path
        for r in results:
            assert "_archive" not in r["file_path"], (
                f"Archived result should be excluded by default: {r['file_path']}"
            )

        # Verify we DO get the non-archived items
        paths = [r["file_path"] for r in results]
        assert any("migration-strategy.md" in p for p in paths), (
            "Knowledge entry should appear in default results"
        )
        assert any("db-migration" in p for p in paths), (
            "Active work item should appear in default results"
        )

    def test_include_archived_flag(self, archive_search_dir):
        """Passing include_archived=True should return archived work items."""
        searcher = Searcher(str(archive_search_dir))
        results = searcher.search("migration", limit=20, include_archived=True)

        assert len(results) > 0

        # Should now include archived items
        paths = [r["file_path"] for r in results]
        assert any("_archive" in p and "legacy-migration" in p for p in paths), (
            "Archived work item should appear when include_archived=True"
        )

        # Non-archived items should still be present
        assert any("migration-strategy.md" in p for p in paths)
        assert any("db-migration" in p for p in paths)

    def test_type_work_still_excludes_archived(self, archive_search_dir):
        """source_type='work' should still exclude archived by default."""
        searcher = Searcher(str(archive_search_dir))
        results = searcher.search("migration", source_type="work", limit=20)

        assert len(results) > 0

        for r in results:
            assert r["source_type"] == "work"
            assert "_archive" not in r["file_path"], (
                f"Archived work should be excluded even with source_type='work': {r['file_path']}"
            )

    def test_type_work_with_include_archived(self, archive_search_dir):
        """source_type='work' with include_archived=True should include archived."""
        searcher = Searcher(str(archive_search_dir))
        results = searcher.search(
            "migration", source_type="work", include_archived=True, limit=20,
        )

        assert len(results) > 0

        # All should be work type
        for r in results:
            assert r["source_type"] == "work"

        # Should include archived work items
        paths = [r["file_path"] for r in results]
        assert any("_archive" in p for p in paths), (
            "Archived work should appear with source_type='work' + include_archived=True"
        )

    def test_include_archived_does_not_affect_knowledge(self, archive_search_dir):
        """include_archived should only affect work items, not knowledge entries."""
        searcher = Searcher(str(archive_search_dir))

        results_default = searcher.search("migration", source_type="knowledge")
        results_with_flag = searcher.search(
            "migration", source_type="knowledge", include_archived=True,
        )

        # Knowledge results should be the same regardless of include_archived
        default_headings = {r["heading"] for r in results_default}
        flag_headings = {r["heading"] for r in results_with_flag}
        assert default_headings == flag_headings

    def test_default_result_count_less_than_include_archived(self, archive_search_dir):
        """Default search should return fewer results than include_archived=True."""
        searcher = Searcher(str(archive_search_dir))

        default_results = searcher.search("migration", limit=20)
        archived_results = searcher.search("migration", limit=20, include_archived=True)

        assert len(archived_results) > len(default_results), (
            "include_archived=True should yield more results than default"
        )


# ---------------------------------------------------------------------------
# Knowledge Boost in Search Tests
# ---------------------------------------------------------------------------

@pytest.fixture
def boost_dir(tmp_path):
    """Knowledge directory with many entries so BM25 IDF produces meaningful scores.

    Only one knowledge entry and one work entry mention 'resilience' and 'circuit breaker',
    ensuring both match the same query. The KNOWLEDGE_BOOST should push the knowledge
    entry above the work entry in ORDER BY despite similar raw BM25 scores.
    A corpus of 10+ knowledge entries is needed for BM25 to produce non-zero scores.
    """
    kd = tmp_path / "boost_test"
    kd.mkdir()

    arch_dir = kd / "architecture"
    arch_dir.mkdir()

    # 10 diverse knowledge entries — only 'resilience-patterns' uses the target keywords
    knowledge_entries = [
        ("resilience-patterns", "Resilience Patterns",
         "Circuit breakers protect against cascading failures. "
         "Bulkhead isolation limits blast radius. Retry with exponential backoff."),
        ("data-pipeline", "Data Pipeline",
         "ETL jobs run nightly on Spark. Raw logs processed into aggregated tables."),
        ("auth-system", "Auth System",
         "OAuth2 with JWT tokens. Session store in Redis with TTL-based expiry."),
        ("messaging", "Messaging Architecture",
         "RabbitMQ for async work. Dead letter queues for failed messages."),
        ("monitoring", "Monitoring Stack",
         "Prometheus metrics. Grafana dashboards. PagerDuty alerting on SLO breaches."),
        ("deployment", "Deployment Strategy",
         "Blue-green deployments with canary releases. ArgoCD for GitOps workflows."),
        ("testing", "Testing Strategy",
         "Unit tests with pytest. Integration tests in Docker. E2E with Playwright."),
        ("storage", "Storage Architecture",
         "S3 for objects. EBS for block storage. EFS for shared filesystem access."),
        ("networking", "Network Architecture",
         "VPC peering across regions. Transit gateway for hub-and-spoke topology."),
        ("caching", "Caching Layer",
         "Redis for session cache. Memcached for computed results. TTL per key type."),
    ]
    for slug, title, content in knowledge_entries:
        (arch_dir / f"{slug}.md").write_text(
            f"# {title}\n{content}\n", encoding="utf-8",
        )

    # Work entry — mentions resilience and circuit breaker with similar density
    work_dir = kd / "_work" / "resilience-upgrade"
    work_dir.mkdir(parents=True)
    (work_dir / "plan.md").write_text(
        "# Resilience Upgrade Plan\n\n"
        "### Goals\n"
        "Improve system resilience. Add circuit breakers to external calls. "
        "Implement bulkhead pattern for critical services.\n\n"
        "### Steps\n"
        "1. Audit resilience gaps\n"
        "2. Deploy circuit breakers\n"
        "3. Load test failure scenarios\n",
        encoding="utf-8",
    )

    # Thread entry — also mentions resilience
    threads_dir = kd / "_threads"
    threads_dir.mkdir()
    (threads_dir / "reliability.md").write_text(
        "---\ntier: active\ntopic: reliability\n---\n\n"
        "## 2025-04-01\n"
        "**Summary:** Discussed resilience improvements.\n"
        "**Key points:**\n"
        "- Circuit breaker adoption is low\n"
        "- Need resilience testing framework\n",
        encoding="utf-8",
    )

    return kd


class TestKnowledgeBoost:
    """Test that KNOWLEDGE_BOOST makes knowledge entries rank above equally-matched work entries."""

    def test_knowledge_ranks_above_work(self, boost_dir):
        """Knowledge entry should rank above work entry with similar keyword density."""
        searcher = Searcher(str(boost_dir))
        results = searcher.search("resilience circuit breaker", limit=10)

        assert len(results) > 0

        # Find the knowledge and work results
        knowledge_results = [r for r in results if r["source_type"] == "knowledge"]
        work_results = [r for r in results if r["source_type"] == "work"]

        assert len(knowledge_results) > 0, "Should have knowledge results"
        assert len(work_results) > 0, "Should have work results"

        # The first result overall should be the knowledge entry
        assert results[0]["source_type"] == "knowledge", (
            f"Knowledge entry should rank first, but got {results[0]['source_type']}: {results[0]['heading']}"
        )

    def test_knowledge_boost_constant_positive(self):
        """KNOWLEDGE_BOOST should be > 1.0 to have any boosting effect."""
        assert KNOWLEDGE_BOOST > 1.0, (
            f"KNOWLEDGE_BOOST should be > 1.0, got {KNOWLEDGE_BOOST}"
        )

    def test_raw_score_not_boosted(self, boost_dir):
        """The score field in results should contain the raw BM25 rank, not the boosted value."""
        searcher = Searcher(str(boost_dir))
        results = searcher.search("resilience", limit=10)

        assert len(results) > 0

        # Get a knowledge result and verify its score is the raw rank
        # by querying the DB directly for the raw BM25 rank
        knowledge_results = [r for r in results if r["source_type"] == "knowledge"]
        assert len(knowledge_results) > 0

        kr = knowledge_results[0]

        # Query the DB directly for the raw rank of this entry
        db_path = os.path.join(str(boost_dir), ".pk_search.db")
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        prepared = Searcher._prepare_query("resilience")
        rows = conn.execute(
            "SELECT heading, rank FROM entries WHERE entries MATCH ? AND source_type = 'knowledge'",
            (prepared,),
        ).fetchall()
        conn.close()

        # Find the matching entry's raw rank
        raw_ranks = {row["heading"]: row["rank"] for row in rows}
        assert kr["heading"] in raw_ranks, (
            f"Knowledge heading '{kr['heading']}' not found in raw DB results"
        )

        raw_rank = raw_ranks[kr["heading"]]
        # The score in the result should match the raw rank, NOT rank * KNOWLEDGE_BOOST
        assert abs(kr["score"] - round(raw_rank, 4)) < 0.001, (
            f"Score {kr['score']} should match raw rank {round(raw_rank, 4)}, "
            f"not boosted rank {round(raw_rank * KNOWLEDGE_BOOST, 4)}"
        )

    def test_threshold_unaffected_by_boost(self, boost_dir):
        """Threshold filtering should use raw BM25 rank, not boosted rank."""
        searcher = Searcher(str(boost_dir))

        # First get all results to find the raw score range
        all_results = searcher.search("resilience", limit=20)
        assert len(all_results) > 0

        # All BM25 scores should be non-positive
        for r in all_results:
            assert r["score"] <= 0, f"BM25 score should be non-positive, got {r['score']}"

        # Find the strongest (most negative) knowledge score
        knowledge_scores = [r["score"] for r in all_results if r["source_type"] == "knowledge"]
        assert len(knowledge_scores) > 0

        # Set threshold to the strongest knowledge score (most negative)
        # This should include it since threshold filtering keeps scores <= threshold
        strongest_knowledge = min(knowledge_scores)  # most negative
        threshold = strongest_knowledge + 0.001  # slightly less strict

        filtered_results = searcher.search("resilience", limit=20, threshold=threshold)

        # The knowledge entry should still appear (threshold is on raw score)
        knowledge_in_filtered = [r for r in filtered_results if r["source_type"] == "knowledge"]
        assert len(knowledge_in_filtered) > 0, (
            "Knowledge entry should pass threshold based on raw score"
        )

    def test_boost_does_not_affect_non_knowledge(self, boost_dir):
        """Work and thread entries should not receive any boost."""
        searcher = Searcher(str(boost_dir))
        results = searcher.search("resilience", limit=20)

        work_results = [r for r in results if r["source_type"] == "work"]
        thread_results = [r for r in results if r["source_type"] == "thread"]

        # Verify work and thread scores match their raw ranks
        db_path = os.path.join(str(boost_dir), ".pk_search.db")
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row
        prepared = Searcher._prepare_query("resilience")
        rows = conn.execute(
            "SELECT heading, rank, source_type FROM entries WHERE entries MATCH ?",
            (prepared,),
        ).fetchall()
        conn.close()

        raw_ranks = {row["heading"]: row["rank"] for row in rows}

        for r in work_results + thread_results:
            if r["heading"] in raw_ranks:
                assert abs(r["score"] - round(raw_ranks[r["heading"]], 4)) < 0.001, (
                    f"{r['source_type']} entry '{r['heading']}' score {r['score']} "
                    f"should match raw rank {round(raw_ranks[r['heading']], 4)}"
                )


# ---------------------------------------------------------------------------
# Combined Archive Exclusion + Knowledge Boost Integration Tests
# ---------------------------------------------------------------------------

@pytest.fixture
def combined_dir(tmp_path):
    """Knowledge directory with knowledge, active work, and archived work entries
    all competing for the same search terms — for testing combined boost + exclusion."""
    kd = tmp_path / "combined_test"
    kd.mkdir()

    # Knowledge entry — uses "deployment" keyword
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "deployment-strategy.md").write_text(
        "# Deployment Strategy\n"
        "The deployment pipeline uses blue-green deployment. "
        "Each deployment is validated with smoke tests. "
        "Rollback deployment is automated via health checks.\n",
        encoding="utf-8",
    )

    # Active work item — uses "deployment" keyword with similar density
    active_work = kd / "_work" / "deploy-v2"
    active_work.mkdir(parents=True)
    (active_work / "plan.md").write_text(
        "# Deploy V2 Plan\n\n"
        "### Goals\n"
        "Upgrade the deployment system to v2. "
        "New deployment approach uses canary deployment.\n\n"
        "### Steps\n"
        "1. Update deployment scripts\n"
        "2. Test deployment in staging\n"
        "3. Roll out deployment to production\n",
        encoding="utf-8",
    )

    # Archived work item — uses "deployment" keyword heavily
    archive = kd / "_work" / "_archive" / "old-deploy"
    archive.mkdir(parents=True)
    (archive / "plan.md").write_text(
        "# Old Deployment Plan\n\n"
        "### Phase 1\n"
        "Legacy deployment migration. Manual deployment replaced with CI. "
        "Deployment frequency increased to daily deployment.\n\n"
        "### Phase 2\n"
        "Deployment monitoring added. Deployment success rate tracked.\n",
        encoding="utf-8",
    )
    (archive / "notes.md").write_text(
        "# Old Deployment Notes\n\n"
        "### 2024-01-01\n"
        "Deployment pipeline established. First automated deployment.\n\n"
        "### 2024-06-01\n"
        "Deployment complete. All services migrated to new deployment.\n",
        encoding="utf-8",
    )

    return kd


class TestCombinedBoostAndExclusion:
    """Integration tests verifying archive exclusion + knowledge boost work together."""

    def test_default_settings_prefer_knowledge(self, combined_dir):
        """With defaults (archive excluded + knowledge boost), knowledge entries
        appear in top results and archived items don't appear at all."""
        searcher = Searcher(str(combined_dir))
        results = searcher.search("deployment", limit=20)

        assert len(results) > 0

        # No archived items should appear
        for r in results:
            assert "_archive" not in r["file_path"], (
                f"Archived item should not appear in default results: {r['file_path']}"
            )

        # Knowledge entry should rank first due to boost
        assert results[0]["source_type"] == "knowledge", (
            f"Knowledge should rank first with defaults, got {results[0]['source_type']}: {results[0]['heading']}"
        )

        # Active work should still be present
        work_results = [r for r in results if r["source_type"] == "work"]
        assert len(work_results) > 0, "Active work items should still appear"

    def test_include_archived_still_boosts_knowledge(self, combined_dir):
        """With include_archived=True, archived items appear but knowledge
        still ranks above equally-matched work entries."""
        searcher = Searcher(str(combined_dir))
        results = searcher.search("deployment", limit=20, include_archived=True)

        assert len(results) > 0

        # Archived items should now appear
        archived = [r for r in results if "_archive" in r["file_path"]]
        assert len(archived) > 0, "Archived items should appear with include_archived=True"

        # Knowledge should still rank first due to boost
        assert results[0]["source_type"] == "knowledge", (
            f"Knowledge should still rank first even with archived included, "
            f"got {results[0]['source_type']}: {results[0]['heading']}"
        )

    def test_explicit_type_work_gets_active_only(self, combined_dir):
        """source_type='work' returns only active work items (no archived, no knowledge)."""
        searcher = Searcher(str(combined_dir))
        results = searcher.search("deployment", source_type="work", limit=20)

        assert len(results) > 0

        for r in results:
            assert r["source_type"] == "work", (
                f"Expected only work results, got {r['source_type']}"
            )
            assert "_archive" not in r["file_path"], (
                f"Archived work should be excluded by default: {r['file_path']}"
            )
