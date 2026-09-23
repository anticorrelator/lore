"""Readers of concordance_results refuse an unbuilt table and report build age.

Covers `pk_cli.py analyze-merge-candidates`, `pk_cli.py generate-backlinks`,
and the duplicate-candidate and medium-confidence sections of curate-scan.sh.
"""

import json
import os
import re
import sqlite3
import subprocess
import sys

import pytest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPTS)

from pk_concordance import Concordance  # noqa: E402
from pk_search import DB_FILENAME, Indexer  # noqa: E402

PK_CLI = os.path.join(SCRIPTS, "pk_cli.py")
CURATE_SCAN = os.path.join(SCRIPTS, "curate-scan.sh")
SHARDING = (
    "PostgreSQL is sharded by tenant using Citus. Each shard handles roughly "
    "ten thousand tenants. Cross-shard queries go through a coordinator.\n"
)
BUILT_LINE = re.compile(r"concordance built \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ")


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.fixture
def kdir(tmp_path):
    kd = tmp_path / "knowledge"
    _write(
        kd / "architecture" / "database-sharding.md",
        "# Database Sharding\n" + SHARDING + "<!-- learned: 2025-02-15 | confidence: high -->\n",
    )
    _write(
        kd / "conventions" / "sharding-restated.md",
        "# Sharding Restated\n" + SHARDING + "<!-- learned: 2025-02-16 | confidence: high -->\n",
    )
    _write(
        kd / "gotchas" / "network-timeouts.md",
        "# Network Timeouts\n"
        "HTTP client timeouts must be configured separately for connect and read.\n"
        "<!-- learned: 2025-02-17 | confidence: high -->\n",
    )
    Indexer(str(kd)).index_all()
    return kd


def _pk(*args, cwd):
    return subprocess.run(
        [sys.executable, PK_CLI, *args], capture_output=True, text=True, cwd=cwd
    )


def _scan(kd):
    return subprocess.run(
        ["bash", CURATE_SCAN, str(kd)], capture_output=True, text=True, cwd=kd.parent
    )


def _build(kd):
    result = _pk("analyze-concordance", str(kd), "--json", cwd=kd.parent)
    assert result.returncode == 0, result.stderr
    return result


def _see_also_rows(kd):
    conn = sqlite3.connect(kd / DB_FILENAME)
    count = conn.execute(
        "SELECT count(*) FROM concordance_results WHERE result_type = 'see_also'"
    ).fetchone()[0]
    conn.close()
    return count


class TestEmptyTableRefusal:
    def test_merge_candidates_exits_nonzero_and_names_the_repair(self, kdir):
        assert _see_also_rows(kdir) == 0

        result = _pk("analyze-merge-candidates", str(kdir), "--json", cwd=kdir.parent)

        assert result.returncode != 0
        assert "lore analyze concordance" in result.stderr
        assert "minutes" in result.stderr
        assert result.stdout == ""
        assert not (kdir / "_meta" / "merge-candidates.json").exists()

    def test_generate_backlinks_exits_nonzero_and_names_the_repair(self, kdir):
        entry = kdir / "architecture" / "database-sharding.md"
        before = entry.read_text(encoding="utf-8")

        result = _pk("generate-backlinks", str(kdir), cwd=kdir.parent)

        assert result.returncode != 0
        assert "lore analyze concordance" in result.stderr
        assert "Pairs checked" not in result.stdout
        assert entry.read_text(encoding="utf-8") == before


class TestFilledTable:
    def test_build_records_its_time(self, kdir):
        _build(kdir)

        conn = sqlite3.connect(kdir / DB_FILENAME)
        row = conn.execute(
            "SELECT value FROM index_meta WHERE key = 'concordance_built_at'"
        ).fetchone()
        conn.close()
        assert row is not None and float(row[0]) > 0

    def test_merge_candidates_match_the_concordance_pairs(self, kdir):
        _build(kdir)
        expected = Concordance(str(kdir / DB_FILENAME)).find_merge_candidates(threshold=0.5)
        for c in expected:
            for key in ("target_path", "source_path"):
                c[key] = os.path.relpath(c[key], kdir)

        result = _pk("analyze-merge-candidates", str(kdir), "--json", cwd=kdir.parent)

        assert result.returncode == 0, result.stderr
        assert BUILT_LINE.search(result.stderr)
        assert json.loads(result.stdout) == expected
        assert {(c["target_path"], c["source_path"]) for c in expected} == {
            ("architecture/database-sharding.md", "conventions/sharding-restated.md")
        }

    def test_generate_backlinks_reads_the_pairs(self, kdir):
        _build(kdir)

        result = _pk("generate-backlinks", str(kdir), "--dry-run", "--json", cwd=kdir.parent)

        assert result.returncode == 0, result.stderr
        assert BUILT_LINE.search(result.stderr)
        out = json.loads(result.stdout)
        assert out["pairs_checked"] > 0
        assert {(d["source"], d["target"]) for d in out["added"]} >= {
            ("architecture/database-sharding.md", "conventions/sharding-restated.md"),
            ("conventions/sharding-restated.md", "architecture/database-sharding.md"),
        }

    def test_unrecorded_build_time_is_said_not_refused(self, kdir):
        Concordance(str(kdir / DB_FILENAME)).run_full_analysis()

        result = _pk("analyze-merge-candidates", str(kdir), "--json", cwd=kdir.parent)

        assert result.returncode == 0, result.stderr
        assert "build time not recorded" in result.stderr
        assert len(json.loads(result.stdout)) == 1

    def test_recorded_build_with_no_pairs_is_an_honest_empty(self, tmp_path):
        kd = tmp_path / "knowledge"
        _write(kd / "gotchas" / "lonely.md", "# Lonely\nNothing else shares these words.\n")
        Indexer(str(kd)).index_all()
        _build(kd)
        assert _see_also_rows(kd) == 0

        result = _pk("analyze-merge-candidates", str(kd), "--json", cwd=tmp_path)

        assert result.returncode == 0, result.stderr
        assert BUILT_LINE.search(result.stderr)
        assert json.loads(result.stdout) == []

    def test_generate_backlinks_skips_pairs_whose_entry_is_gone(self, kdir):
        _build(kdir)
        (kdir / "conventions" / "sharding-restated.md").unlink()
        source = kdir / "architecture" / "database-sharding.md"

        result = _pk("generate-backlinks", str(kdir), "--json", cwd=kdir.parent)

        assert result.returncode == 0, result.stderr
        out = json.loads(result.stdout)
        assert out["pairs_stale"] >= 2
        assert all("sharding-restated" not in d["target"] for d in out["added"])
        assert "sharding-restated" not in source.read_text(encoding="utf-8")


class TestCurateScan:
    def test_finds_medium_confidence_two_directories_deep(self, kdir):
        _write(
            kdir / "architecture" / "knowledge" / "capture" / "nested-claim.md",
            "# Nested Claim\nSomething.\n<!-- learned: 2025-03-01 | confidence: medium -->\n",
        )
        _write(
            kdir / "architecture" / "knowledge" / "_drafts" / "hidden-claim.md",
            "# Hidden Claim\nSomething.\n<!-- learned: 2025-03-01 | confidence: medium -->\n",
        )

        result = _scan(kdir)

        assert result.returncode == 0, result.stderr
        assert "  architecture/knowledge/capture/nested-claim.md\n" in result.stdout
        assert "hidden-claim" not in result.stdout
        assert "Entries without backlinks" not in result.stdout

    def test_duplicate_section_says_it_did_not_run_on_an_empty_table(self, kdir):
        result = _scan(kdir)

        assert result.returncode == 0, result.stderr
        line = next(
            ln for ln in result.stdout.splitlines() if ln.startswith("## Duplicate candidates")
        )
        assert "did not run" in line
        assert "lore analyze concordance" in result.stdout

    def test_duplicate_section_says_it_did_not_run_without_an_index(self, tmp_path):
        kd = tmp_path / "knowledge"
        _write(kd / "gotchas" / "entry.md", "# Entry\nText.\n")

        result = _scan(kd)

        assert result.returncode == 0, result.stderr
        assert "## Duplicate candidates: check did not run" in result.stdout
        assert not (kd / DB_FILENAME).exists()

    def test_duplicate_section_lists_pairs_with_build_age(self, kdir):
        _build(kdir)

        result = _scan(kdir)

        assert result.returncode == 0, result.stderr
        assert "## Duplicate candidates (similarity >= 0.6): 1" in result.stdout
        assert BUILT_LINE.search(result.stdout)
        assert "architecture/database-sharding.md" in result.stdout
        assert "<-> conventions/sharding-restated.md" in result.stdout
