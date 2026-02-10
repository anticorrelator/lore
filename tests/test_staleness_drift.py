"""Tests for drift-based staleness scoring in staleness-scan.py."""

import importlib.util
import os
import sys

import pytest

# staleness-scan.py has a hyphen, so use importlib to load it
_SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts", "staleness-scan.py")
_spec = importlib.util.spec_from_file_location("staleness_scan", _SCRIPT_PATH)
staleness_scan = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(staleness_scan)

compute_backlink_drift = staleness_scan.compute_backlink_drift
compute_file_drift = staleness_scan.compute_file_drift
score_entry = staleness_scan.score_entry


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a minimal knowledge directory with resolvable entries."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # conventions/ directory with one entry
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "api-versioning.md").write_text(
        "# API Versioning\n"
        "All APIs use URL-path versioning.\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # architecture/ directory with one entry
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "service-mesh.md").write_text(
        "# Service Mesh\n"
        "The app uses a service mesh.\n"
        "<!-- learned: 2025-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    return kd


@pytest.fixture
def entry_with_good_backlinks(knowledge_dir):
    """Create an entry file whose backlinks all resolve."""
    gotchas_dir = knowledge_dir / "gotchas"
    gotchas_dir.mkdir(exist_ok=True)
    entry = gotchas_dir / "test-entry-good.md"
    entry.write_text(
        "# Test Entry Good\n"
        "Refers to [[knowledge:api-versioning]] and [[knowledge:service-mesh]].\n"
        "<!-- learned: 2025-06-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    return str(entry)


@pytest.fixture
def entry_with_broken_backlinks(knowledge_dir):
    """Create an entry file with at least one broken backlink."""
    gotchas_dir = knowledge_dir / "gotchas"
    gotchas_dir.mkdir(exist_ok=True)
    entry = gotchas_dir / "test-entry-broken.md"
    entry.write_text(
        "# Test Entry Broken\n"
        "Refers to [[knowledge:api-versioning]] and [[knowledge:nonexistent-target]].\n"
        "<!-- learned: 2025-06-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    return str(entry)


@pytest.fixture
def entry_all_broken_backlinks(knowledge_dir):
    """Create an entry file where all backlinks are broken."""
    gotchas_dir = knowledge_dir / "gotchas"
    gotchas_dir.mkdir(exist_ok=True)
    entry = gotchas_dir / "test-entry-all-broken.md"
    entry.write_text(
        "# Test Entry All Broken\n"
        "Refers to [[knowledge:does-not-exist]] and [[work:missing-plan]].\n"
        "<!-- learned: 2025-06-01 | confidence: low -->\n",
        encoding="utf-8",
    )
    return str(entry)


@pytest.fixture
def entry_no_backlinks(knowledge_dir):
    """Create an entry file with no backlinks."""
    gotchas_dir = knowledge_dir / "gotchas"
    gotchas_dir.mkdir(exist_ok=True)
    entry = gotchas_dir / "test-entry-no-links.md"
    entry.write_text(
        "# Test Entry No Links\n"
        "This entry has no backlinks at all.\n"
        "<!-- learned: 2025-06-01 | confidence: high -->\n",
        encoding="utf-8",
    )
    return str(entry)


# ---------------------------------------------------------------------------
# Tests: compute_backlink_drift
# ---------------------------------------------------------------------------

class TestComputeBacklinkDrift:
    """Unit tests for compute_backlink_drift()."""

    def test_all_backlinks_resolve(self, knowledge_dir, entry_with_good_backlinks):
        result = compute_backlink_drift(entry_with_good_backlinks, str(knowledge_dir))
        assert result["available"] is True
        assert result["total"] == 2
        assert result["broken"] == 0
        assert result["broken_links"] == []
        assert result["score"] == 0.0

    def test_some_backlinks_broken(self, knowledge_dir, entry_with_broken_backlinks):
        result = compute_backlink_drift(entry_with_broken_backlinks, str(knowledge_dir))
        assert result["available"] is True
        assert result["total"] == 2
        assert result["broken"] == 1
        assert len(result["broken_links"]) == 1
        assert "nonexistent-target" in result["broken_links"][0]
        assert result["score"] == 1.0  # binary: any broken = 1.0

    def test_all_backlinks_broken(self, knowledge_dir, entry_all_broken_backlinks):
        result = compute_backlink_drift(entry_all_broken_backlinks, str(knowledge_dir))
        assert result["available"] is True
        assert result["total"] == 2
        assert result["broken"] == 2
        assert result["score"] == 1.0

    def test_no_backlinks(self, knowledge_dir, entry_no_backlinks):
        result = compute_backlink_drift(entry_no_backlinks, str(knowledge_dir))
        assert result["available"] is False
        assert result["total"] == 0
        assert result["broken"] == 0
        assert result["score"] == 0.0

    def test_nonexistent_file(self, knowledge_dir):
        result = compute_backlink_drift("/nonexistent/file.md", str(knowledge_dir))
        assert result["available"] is False
        assert result["total"] == 0
        assert result["score"] == 0.0

    def test_unreadable_file(self, knowledge_dir, tmp_path):
        # Create a binary file that can't be decoded as UTF-8
        bad_file = tmp_path / "bad.md"
        bad_file.write_bytes(b"\x80\x81\x82\x83")
        result = compute_backlink_drift(str(bad_file), str(knowledge_dir))
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_backlink_types_recognized(self, knowledge_dir):
        """Verify all four backlink types are extracted."""
        gotchas_dir = knowledge_dir / "gotchas"
        gotchas_dir.mkdir(exist_ok=True)
        entry = gotchas_dir / "test-all-types.md"
        entry.write_text(
            "# All Types\n"
            "Links: [[knowledge:api-versioning]] [[work:some-item]] "
            "[[plan:old-plan]] [[thread:some-thread]]\n",
            encoding="utf-8",
        )
        result = compute_backlink_drift(str(entry), str(knowledge_dir))
        assert result["available"] is True
        assert result["total"] == 4

    def test_non_backlink_brackets_ignored(self, knowledge_dir):
        """Verify that [[random:thing]] is not treated as a backlink."""
        gotchas_dir = knowledge_dir / "gotchas"
        gotchas_dir.mkdir(exist_ok=True)
        entry = gotchas_dir / "test-non-backlink.md"
        entry.write_text(
            "# Non Backlink\n"
            "This has [[random:thing]] and [[other:stuff]] but no real backlinks.\n",
            encoding="utf-8",
        )
        result = compute_backlink_drift(str(entry), str(knowledge_dir))
        assert result["available"] is False
        assert result["total"] == 0


# ---------------------------------------------------------------------------
# Tests: compute_file_drift
# ---------------------------------------------------------------------------

class TestComputeFileDrift:
    """Unit tests for compute_file_drift() with mocked git output."""

    def test_no_related_files(self):
        result = compute_file_drift("/some/repo", "2025-01-01", [])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_no_learned_date(self):
        result = compute_file_drift("/some/repo", None, ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_template_placeholder_date(self):
        result = compute_file_drift("/some/repo", "YYYY-MM-DD", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_invalid_date_format(self):
        result = compute_file_drift("/some/repo", "not-a-date", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_no_git_repo(self, tmp_path):
        """Non-git directory returns unavailable."""
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_zero_commits(self, tmp_path, monkeypatch):
        """Zero commits since learned date = score 0.0."""
        # Create .git dir to pass the git repo check
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = ""
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 0
        assert result["score"] == 0.0

    def test_three_commits(self, tmp_path, monkeypatch):
        """1-3 commits = score 0.3."""
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = "abc1234 commit 1\ndef5678 commit 2\nghi9012 commit 3\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 3
        assert result["score"] == 0.3

    def test_ten_plus_commits(self, tmp_path, monkeypatch):
        """10+ commits = score 1.0."""
        (tmp_path / ".git").mkdir()
        import subprocess
        lines = "\n".join(f"abc{i:04d} commit {i}" for i in range(12))
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = lines + "\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 12
        assert result["score"] == 1.0

    def test_mid_range_commits(self, tmp_path, monkeypatch):
        """4-9 commits = score 0.6."""
        (tmp_path / ".git").mkdir()
        import subprocess
        lines = "\n".join(f"abc{i:04d} commit {i}" for i in range(7))
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = lines + "\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 7
        assert result["score"] == 0.6

    def test_one_commit_boundary(self, tmp_path, monkeypatch):
        """1 commit = lower boundary of 0.3 bucket."""
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = "abc0001 commit 1\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 1
        assert result["score"] == 0.3

    def test_four_commits_boundary(self, tmp_path, monkeypatch):
        """4 commits = lower boundary of 0.6 bucket."""
        (tmp_path / ".git").mkdir()
        import subprocess
        lines = "\n".join(f"abc{i:04d} commit {i}" for i in range(4))
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = lines + "\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 4
        assert result["score"] == 0.6

    def test_nine_commits_boundary(self, tmp_path, monkeypatch):
        """9 commits = upper boundary of 0.6 bucket."""
        (tmp_path / ".git").mkdir()
        import subprocess
        lines = "\n".join(f"abc{i:04d} commit {i}" for i in range(9))
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = lines + "\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 9
        assert result["score"] == 0.6

    def test_ten_commits_boundary(self, tmp_path, monkeypatch):
        """10 commits = lower boundary of 1.0 bucket."""
        (tmp_path / ".git").mkdir()
        import subprocess
        lines = "\n".join(f"abc{i:04d} commit {i}" for i in range(10))
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 0
                stdout = lines + "\n"
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is True
        assert result["commit_count"] == 10
        assert result["score"] == 1.0

    def test_git_nonzero_returncode(self, tmp_path, monkeypatch):
        """Non-zero git exit code returns unavailable."""
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            class Result:
                returncode = 128
                stdout = ""
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_git_timeout(self, tmp_path, monkeypatch):
        """Subprocess timeout returns unavailable."""
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            raise subprocess.TimeoutExpired(cmd="git", timeout=30)
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_git_os_error(self, tmp_path, monkeypatch):
        """OSError (e.g., git not found) returns unavailable."""
        (tmp_path / ".git").mkdir()
        import subprocess
        def mock_run(*args, **kwargs):
            raise OSError("git not found")
        monkeypatch.setattr(subprocess, "run", mock_run)
        result = compute_file_drift(str(tmp_path), "2025-01-01", ["file.py"])
        assert result["available"] is False
        assert result["score"] == 0.0

    def test_multiple_related_files(self, tmp_path, monkeypatch):
        """Multiple related files are all passed to git."""
        (tmp_path / ".git").mkdir()
        import subprocess
        captured_args = []
        def mock_run(*args, **kwargs):
            captured_args.append(args[0])
            class Result:
                returncode = 0
                stdout = ""
            return Result()
        monkeypatch.setattr(subprocess, "run", mock_run)
        compute_file_drift(str(tmp_path), "2025-01-01", ["src/a.py", "src/b.py", "lib/c.py"])
        cmd = captured_args[0]
        dash_idx = cmd.index("--")
        assert cmd[dash_idx + 1:] == ["src/a.py", "src/b.py", "lib/c.py"]


# ---------------------------------------------------------------------------
# Tests: score_entry (drift-based)
# ---------------------------------------------------------------------------

class TestScoreEntry:
    """Unit tests for the drift-based score_entry()."""

    def test_all_signals_fresh(self):
        fd = {"score": 0.0, "available": True, "commit_count": 0}
        bd = {"score": 0.0, "available": True, "total": 2, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, "high")
        assert status == "fresh"
        assert drift_score == 0.0

    def test_high_file_drift_causes_stale(self):
        fd = {"score": 1.0, "available": True, "commit_count": 15}
        bd = {"score": 0.0, "available": True, "total": 1, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, "high")
        assert drift_score == pytest.approx(0.6)
        assert status == "stale"

    def test_broken_backlinks_cause_aging(self):
        fd = {"score": 0.0, "available": True, "commit_count": 0}
        bd = {"score": 1.0, "available": True, "total": 2, "broken": 1}
        drift_score, status, signals = score_entry(fd, bd, "high")
        assert drift_score == pytest.approx(0.25)
        assert status == "fresh"  # 0.25 < 0.3 threshold

    def test_low_confidence_only(self):
        fd = {"score": 0.0, "available": False, "commit_count": 0}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, "low")
        # confidence-only: weight=1.0, low=1.0 -> drift_score=1.0
        assert drift_score == pytest.approx(1.0)
        assert status == "stale"

    def test_weight_redistribution_no_backlinks(self):
        fd = {"score": 0.5, "available": True, "commit_count": 5}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, "high")
        # file_drift weight = 0.6 + 0.25 = 0.85, confidence weight = 0.15
        # score = 0.85 * 0.5 + 0.15 * 0.0 = 0.425
        assert signals["file_drift"]["weight"] == pytest.approx(0.85)
        assert signals["backlink_drift"]["weight"] == 0.0
        assert drift_score == pytest.approx(0.425)
        assert status == "aging"

    def test_weight_redistribution_no_file_drift(self):
        fd = {"score": 0.0, "available": False, "commit_count": 0}
        bd = {"score": 1.0, "available": True, "total": 3, "broken": 2}
        drift_score, status, signals = score_entry(fd, bd, "high")
        # backlink weight = 0.25 + 0.6 = 0.85
        assert signals["backlink_drift"]["weight"] == pytest.approx(0.85)
        assert signals["file_drift"]["weight"] == 0.0
        assert drift_score == pytest.approx(0.85)
        assert status == "stale"

    def test_medium_confidence_contributes(self):
        fd = {"score": 0.0, "available": False, "commit_count": 0}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, "medium")
        # confidence-only: weight=1.0, medium=0.5
        assert drift_score == pytest.approx(0.5)
        assert status == "aging"

    def test_none_confidence_defaults_medium(self):
        fd = {"score": 0.0, "available": False, "commit_count": 0}
        bd = {"score": 0.0, "available": False, "total": 0, "broken": 0}
        drift_score, status, signals = score_entry(fd, bd, None)
        assert drift_score == pytest.approx(0.5)
        assert signals["confidence"]["level"] == "medium"


# ---------------------------------------------------------------------------
# Integration tests: run_scan() against real knowledge store
# ---------------------------------------------------------------------------

run_scan = staleness_scan.run_scan

# Resolve the real knowledge store path
_KNOWLEDGE_DIR = None
_REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
try:
    import subprocess as _sp
    _result = _sp.run(
        ["bash", os.path.join(_REPO_ROOT, "cli", "lore"), "resolve"],
        capture_output=True, text=True, cwd=_REPO_ROOT,
    )
    if _result.returncode == 0 and _result.stdout.strip():
        _candidate = _result.stdout.strip()
        if os.path.isdir(_candidate):
            _KNOWLEDGE_DIR = _candidate
except Exception:
    pass

_skip_no_knowledge = pytest.mark.skipif(
    _KNOWLEDGE_DIR is None,
    reason="No knowledge store found (lore resolve failed)",
)


@_skip_no_knowledge
class TestRunScanIntegration:
    """Integration tests running run_scan() against the real knowledge store."""

    def test_report_has_required_top_level_keys(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        for key in ("scan_time", "knowledge_dir", "repo_root", "total_entries", "counts", "entries"):
            assert key in report, f"Missing top-level key: {key}"
        assert report["total_entries"] > 0

    def test_counts_sum_matches_total(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        total = sum(report["counts"].values())
        assert total == report["total_entries"]
        assert total == len(report["entries"])

    def test_every_entry_has_drift_score_and_signals(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        for entry in report["entries"]:
            assert "drift_score" in entry, f"Missing drift_score in {entry['file']}"
            assert isinstance(entry["drift_score"], float)
            assert 0.0 <= entry["drift_score"] <= 1.0, f"drift_score out of range: {entry['drift_score']}"

            assert "signals" in entry, f"Missing signals in {entry['file']}"
            signals = entry["signals"]
            for signal_name in ("file_drift", "backlink_drift", "confidence"):
                assert signal_name in signals, f"Missing signal {signal_name} in {entry['file']}"

    def test_entry_status_values_valid(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        valid_statuses = {"fresh", "aging", "stale"}
        for entry in report["entries"]:
            assert entry["status"] in valid_statuses, f"Invalid status: {entry['status']} in {entry['file']}"

    def test_signal_sub_dicts_have_expected_keys(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        entry = report["entries"][0]
        signals = entry["signals"]

        fd = signals["file_drift"]
        assert "weight" in fd
        assert "score" in fd
        assert "available" in fd
        assert "commit_count" in fd

        bd = signals["backlink_drift"]
        assert "weight" in bd
        assert "score" in bd
        assert "available" in bd
        assert "total" in bd
        assert "broken" in bd

        conf = signals["confidence"]
        assert "weight" in conf
        assert "score" in conf
        assert "level" in conf

    def test_weights_sum_to_one(self):
        report = run_scan(_KNOWLEDGE_DIR, os.path.abspath(_REPO_ROOT))
        for entry in report["entries"]:
            signals = entry["signals"]
            total_weight = (
                signals["file_drift"]["weight"]
                + signals["backlink_drift"]["weight"]
                + signals["confidence"]["weight"]
            )
            assert total_weight == pytest.approx(1.0), (
                f"Weights don't sum to 1.0 for {entry['file']}: {total_weight}"
            )
