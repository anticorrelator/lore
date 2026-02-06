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
    Indexer,
    MarkdownParser,
    Searcher,
    Stats,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a sample knowledge directory with markdown files."""
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
        assert result["files_indexed"] == 4  # arch, conv, gotchas, workflows
        assert result["total_entries"] == 6

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

    def test_force_reindex(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()
        result = indexer.index_all(force=True)
        assert result["files_indexed"] == 4
        assert result["total_entries"] == 6

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

        assert len(rows) == 4
        for fp, mtime, chash in rows:
            assert mtime > 0
            assert len(chash) == 64  # SHA-256 hex digest

    def test_corrupt_db_rebuilds(self, knowledge_dir):
        """If the DB is corrupt, index_all should recreate it."""
        indexer = Indexer(str(knowledge_dir))
        # Write garbage to the DB path
        with open(indexer.db_path, "w") as f:
            f.write("not a sqlite database")

        result = indexer.index_all()
        assert "error" not in result
        assert result["files_indexed"] == 4


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
        assert any("new_topic.md" in f for f in stale)

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
        assert any("architecture.md" in f for f in stale)

    def test_stale_detection_deleted_file(self, knowledge_dir):
        indexer = Indexer(str(knowledge_dir))
        indexer.index_all()

        # Delete a file
        (knowledge_dir / "gotchas.md").unlink()

        stale = indexer.get_stale_files()
        assert any("gotchas.md" in f for f in stale)

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
# Stats Tests
# ---------------------------------------------------------------------------

class TestStats:
    def test_stats_after_index(self, knowledge_dir):
        Indexer(str(knowledge_dir)).index_all()
        stats = Stats(str(knowledge_dir)).get_stats()

        assert stats["entry_count"] == 6
        assert stats["file_count"] == 4
        assert stats["db_size_bytes"] > 0
        assert stats["last_indexed"] != "never"
        assert stats["stale_files"] == 0

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
