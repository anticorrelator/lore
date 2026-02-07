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
    """Create a sample knowledge directory with markdown files, plans, and threads."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # architecture.md — two entries
    (kd / "architecture.md").write_text(
        "# Architecture\n\n"
        "### Service Mesh\n"
        "The application uses a service mesh for inter-service communication. "
        "Envoy sidecars handle retries, circuit breaking, and mTLS.\n"
        "See also: [[conventions#API Versioning]].\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n\n"
        "### Database Sharding\n"
        "PostgreSQL is sharded by tenant_id using Citus. Each shard handles "
        "roughly 10K tenants. Cross-shard queries go through a coordinator node.\n"
        "<!-- learned: 2025-02-15 | confidence: high -->\n",
        encoding="utf-8",
    )

    # conventions.md — two entries
    (kd / "conventions.md").write_text(
        "# Conventions\n\n"
        "### API Versioning\n"
        "All HTTP APIs use URL-path versioning: `/v1/`, `/v2/`. Breaking changes "
        "require a version bump. Deprecated versions are supported for 6 months.\n\n"
        "### Error Handling\n"
        "All service errors return a standard JSON envelope with `error_code`, "
        "`message`, and optional `details` array. HTTP status codes follow RFC 7231.\n",
        encoding="utf-8",
    )

    # gotchas.md — one entry with long content
    long_content = "This gotcha has a very long explanation. " * 50
    (kd / "gotchas.md").write_text(
        "# Gotchas\n\n"
        "### Connection Pool Exhaustion\n"
        f"{long_content}\n",
        encoding="utf-8",
    )

    # workflows.md — one entry
    (kd / "workflows.md").write_text(
        "# Workflows\n\n"
        "### Deploy Pipeline\n"
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
    """Knowledge directory with unicode content."""
    kd = tmp_path / "unicode"
    kd.mkdir()
    (kd / "international.md").write_text(
        "# International\n\n"
        "### Lokalisierung\n"
        "Die Anwendung unterstützt Deutsch, Französisch und Japanisch (日本語).\n"
        "Zeichenketten werden in `.po`-Dateien gespeichert.\n\n"
        "### 国際化\n"
        "アプリケーションは多言語対応しています。翻訳はgettext形式です。\n",
        encoding="utf-8",
    )
    return kd


@pytest.fixture
def link_check_dir(tmp_path):
    """Knowledge directory with valid and broken backlinks for link checking."""
    kd = tmp_path / "linkcheck"
    kd.mkdir()

    # A file with valid and broken backlinks
    (kd / "architecture.md").write_text(
        "# Architecture\n\n"
        "### Service Mesh\n"
        "Uses Envoy. See [[knowledge:conventions#API Versioning]] for API details.\n"
        "Also see [[work:auth-refactor]] for auth migration.\n"
        "Broken ref: [[knowledge:nonexistent-file#Heading]].\n"
        "Another broken: [[work:deleted-work]].\n"
        "Broken heading: [[knowledge:architecture#Nonexistent Section]].\n",
        encoding="utf-8",
    )

    (kd / "conventions.md").write_text(
        "# Conventions\n\n"
        "### API Versioning\n"
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

    # Knowledge file referencing both active and archived work items
    (kd / "architecture.md").write_text(
        "# Architecture\n\n"
        "### Design Overview\n"
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
    def test_parse_file_with_headings(self, knowledge_dir):
        entries = MarkdownParser.parse_file(str(knowledge_dir / "architecture.md"))
        assert len(entries) == 2
        assert entries[0]["heading"] == "Service Mesh"
        assert "Envoy sidecars" in entries[0]["content"]
        assert entries[1]["heading"] == "Database Sharding"
        assert "PostgreSQL" in entries[1]["content"]

    def test_parse_file_preserves_file_path(self, knowledge_dir):
        fpath = str(knowledge_dir / "conventions.md")
        entries = MarkdownParser.parse_file(fpath)
        for entry in entries:
            assert entry["file_path"] == fpath

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

    def test_parse_unicode_content(self, unicode_dir):
        entries = MarkdownParser.parse_file(str(unicode_dir / "international.md"))
        assert len(entries) == 2
        assert entries[0]["heading"] == "Lokalisierung"
        assert "Deutsch" in entries[0]["content"]
        assert entries[1]["heading"] == "国際化"
        assert "多言語対応" in entries[1]["content"]

    def test_content_between_headings(self, knowledge_dir):
        """Content for an entry should only include text up to the next ###."""
        entries = MarkdownParser.parse_file(str(knowledge_dir / "conventions.md"))
        api_entry = entries[0]
        assert api_entry["heading"] == "API Versioning"
        # Should NOT contain content from Error Handling entry
        assert "error_code" not in api_entry["content"]


# ---------------------------------------------------------------------------
# Indexer Tests
# ---------------------------------------------------------------------------

class TestIndexer:
    def test_index_creates_db(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        result = indexer.index_all()
        assert os.path.exists(indexer.db_path)
        # 4 knowledge + 2 plan (plan.md, notes.md) + 1 thread = 7 files
        assert result["files_indexed"] == 7
        # architecture(2) + conventions(2) + gotchas(1) + workflows(1) +
        # plan.md(3: Goals, Token Rotation, Migration Steps) + notes.md(2: 2025-03-10, 2025-03-15) +
        # working-style.md(1: ungrouped because ## headings, not ###)
        assert result["total_entries"] > 6

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

        # Check knowledge entries
        knowledge_count = conn.execute(
            "SELECT count(*) FROM file_meta WHERE source_type = 'knowledge'"
        ).fetchone()[0]
        assert knowledge_count == 4  # architecture, conventions, gotchas, workflows

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

        conn.close()

    def test_force_reindex(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()
        result = indexer.index_all(force=True)
        assert result["files_indexed"] == 7
        assert result["total_entries"] > 6

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

        assert len(rows) == 7  # 4 knowledge + 2 plan + 1 thread
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
        assert type_map.get("architecture.md") == "knowledge"
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
        assert result["files_indexed"] == 7


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
        assert "Lokalisierung" in results[0]["heading"]

    def test_search_multiword_query(self, knowledge_dir):
        """Multi-word queries should work without FTS5 column filter issues."""
        searcher = Searcher(str(knowledge_dir))
        # 'error handling' could be misinterpreted as column:filter
        results = searcher.search("error handling")
        assert len(results) > 0
        top = results[0]
        assert top["heading"] == "Error Handling"

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

    def test_source_type_in_search_results(self, knowledge_dir):
        """Search results should include the source_type field."""
        searcher = Searcher(str(knowledge_dir))
        results = searcher.search("database sharding")
        assert len(results) > 0
        for r in results:
            assert "source_type" in r
            assert r["source_type"] in SOURCE_TYPES


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

        # Add a new file
        (knowledge_dir / "new_topic.md").write_text(
            "# New Topic\n\n### Fresh Entry\nBrand new content.\n",
            encoding="utf-8",
        )

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("new_topic.md" in f for f in stale_paths)

    def test_stale_detection_modified_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Modify an existing file (ensure mtime changes)
        arch_path = knowledge_dir / "architecture.md"
        time.sleep(0.05)
        arch_path.write_text(
            arch_path.read_text() + "\n### New Section\nAdded content.\n",
            encoding="utf-8",
        )

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("architecture.md" in f for f in stale_paths)

    def test_stale_detection_deleted_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Delete a file
        (knowledge_dir / "gotchas.md").unlink()

        stale = indexer.get_stale_files()
        stale_paths = [fp for fp, _ in stale]
        assert any("gotchas.md" in f for f in stale_paths)

    def test_incremental_reindex(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Modify one file
        time.sleep(0.05)
        (knowledge_dir / "conventions.md").write_text(
            "# Conventions\n\n"
            "### New Convention\nThis replaces old content entirely.\n",
            encoding="utf-8",
        )

        result = indexer.incremental_index()
        assert result["files_reindexed"] >= 1

        # Verify the old entries are gone and new one exists
        conn = sqlite3.connect(indexer.db_path)
        headings = [
            r[0]
            for r in conn.execute(
                "SELECT heading FROM entries WHERE file_path LIKE '%conventions.md'"
            ).fetchall()
        ]
        conn.close()

        assert "New Convention" in headings
        assert "API Versioning" not in headings

    def test_incremental_removes_deleted(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Delete a file
        (knowledge_dir / "gotchas.md").unlink()

        result = indexer.incremental_index()
        assert result["files_removed"] >= 1

        # Verify entries removed
        conn = sqlite3.connect(indexer.db_path)
        rows = conn.execute(
            "SELECT * FROM entries WHERE file_path LIKE '%gotchas.md'"
        ).fetchall()
        conn.close()
        assert len(rows) == 0

    def test_search_auto_reindexes_stale(self, knowledge_dir):
        """Searching after a file changes should auto-reindex."""
        searcher = Searcher(str(knowledge_dir))
        searcher.search("database")  # triggers initial index

        # Add a new entry
        time.sleep(0.05)
        (knowledge_dir / "new.md").write_text(
            "# New\n\n### Quantum Computing\nEntanglement-based key distribution.\n",
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
    def test_resolve_knowledge_with_heading(self, knowledge_dir):
        """Resolve [[knowledge:architecture#Service Mesh]] returns section content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:architecture#Service Mesh]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "architecture"
        assert result["heading"] == "Service Mesh"
        assert "Envoy sidecars" in result["content"]

    def test_resolve_knowledge_full_file(self, knowledge_dir):
        """Resolve [[knowledge:conventions]] returns full file content."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:conventions]]")
        assert result["resolved"] is True
        assert result["source_type"] == "knowledge"
        assert result["target"] == "conventions"
        assert result["heading"] is None
        # Should contain content from both sections
        assert "API Versioning" in result["content"]
        assert "Error Handling" in result["content"]

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

    def test_resolve_nonexistent_heading(self, knowledge_dir):
        """Resolving a nonexistent heading returns resolved=False."""
        resolver = Resolver(str(knowledge_dir))
        result = resolver.resolve("[[knowledge:architecture#Nonexistent Section]]")
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
            "[[knowledge:architecture#Service Mesh]]",
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
        assert any("Nonexistent Section" in bl for bl in broken_backlinks)

    def test_check_all_counts_total_links(self, link_check_dir):
        """check_all should count all backlinks including valid ones."""
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()

        # Valid links: [[knowledge:conventions#API Versioning]], [[work:auth-refactor]],
        #              [[thread:working-style]]
        # Broken links: [[knowledge:nonexistent-file#Heading]], [[work:deleted-work]],
        #               [[knowledge:architecture#Nonexistent Section]]
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
        # Add a file with both real and code-block backlinks
        (link_check_dir / "mixed.md").write_text(
            "# Mixed\n\n"
            "### Real Links\n"
            "See [[knowledge:conventions#API Versioning]].\n\n"
            "```python\n"
            '# Template: [[knowledge:nonexistent-template#Heading]]\n'
            "```\n",
            encoding="utf-8",
        )
        checker = LinkChecker(str(link_check_dir))
        result = checker.check_all()
        # The real link in mixed.md should be found, but not the code-block one
        all_backlinks = [bl["backlink"] for bl in result["broken_links"]]
        assert "[[knowledge:nonexistent-template#Heading]]" not in all_backlinks

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
    def test_v1_db_rebuilds_to_v2(self, knowledge_dir):
        """A v1 database (without source_type) should be rebuilt to v2 on index_all."""
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
        assert result["files_indexed"] == 7

        # Verify v2 schema is now in place
        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key='schema_version'"
        ).fetchone()
        assert row is not None
        assert int(row[0]) == 2

        # Verify source_type column exists in entries (query should not error)
        rows = conn.execute("SELECT source_type FROM entries LIMIT 1").fetchall()
        assert len(rows) > 0

        # Verify source_type column exists in file_meta
        rows = conn.execute("SELECT source_type FROM file_meta LIMIT 1").fetchall()
        assert len(rows) > 0

        conn.close()

    def test_no_db_creates_v2(self, knowledge_dir):
        """Fresh index with no existing DB should create v2 schema."""
        kd_str = str(knowledge_dir)
        db_path = os.path.join(kd_str, ".pk_search.db")
        assert not os.path.exists(db_path)

        indexer = Indexer(kd_str)
        indexer.index_all()

        conn = sqlite3.connect(db_path)
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key='schema_version'"
        ).fetchone()
        assert int(row[0]) == 2
        conn.close()


# ---------------------------------------------------------------------------
# Stats Tests
# ---------------------------------------------------------------------------

class TestStats:
    def test_stats_after_index(self, knowledge_dir):
        Indexer(str(knowledge_dir)).index_all()
        stats = Stats(str(knowledge_dir)).get_stats()

        assert stats["entry_count"] > 6  # knowledge + plan + thread entries
        assert stats["file_count"] == 7  # 4 knowledge + 2 plan + 1 thread
        assert stats["db_size_bytes"] > 0
        assert stats["last_indexed"] != "never"
        assert stats["stale_files"] == 0

    def test_stats_type_counts(self, knowledge_dir):
        """Stats should include per-type file counts."""
        Indexer(str(knowledge_dir)).index_all()
        stats = Stats(str(knowledge_dir)).get_stats()

        assert "type_counts" in stats
        tc = stats["type_counts"]
        assert tc.get("knowledge") == 4
        assert tc.get("work") == 2
        assert tc.get("thread") == 1

    def test_stats_no_db(self, tmp_path):
        kd = tmp_path / "noindex"
        kd.mkdir()
        stats = Stats(str(kd)).get_stats()
        assert "error" in stats

    def test_stats_shows_stale(self, knowledge_dir):
        Indexer(str(knowledge_dir)).index_all()

        # Add a file to make things stale
        (knowledge_dir / "extra.md").write_text(
            "# Extra\n\n### Bonus\nContent.\n",
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

        # Modify a file
        time.sleep(0.05)
        (knowledge_dir / "conventions.md").write_text(
            "# Conventions\n\n### Shiny New Convention\nBrand new.\n",
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
             "[[knowledge:architecture#Service Mesh]]"],
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
             "[[knowledge:architecture#Service Mesh]]", "--json"],
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
             "[[knowledge:conventions]]", "[[work:auth-refactor]]", "--json"],
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
        """Search should return results from archived work items."""
        searcher = Searcher(str(archive_dir))
        results = searcher.search("database schema")

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

        # 1 knowledge + 1 active work item + 2 archived work item files = 4
        assert stats["file_count"] == 4
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
