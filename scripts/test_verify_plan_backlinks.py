"""Tests for verify-plan-backlinks.sh.

Tests invoke the script as a subprocess against a minimal knowledge fixture.
Run with: python3 -m pytest scripts/test_verify_plan_backlinks.py -v
Or from repo root: pytest scripts/test_verify_plan_backlinks.py -v
"""

import json
import os
import subprocess

import pytest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
VERIFY_SCRIPT = os.path.join(SCRIPT_DIR, "verify-plan-backlinks.sh")
PK_CLI = os.path.join(SCRIPT_DIR, "pk_cli.py")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def knowledge_dir(tmp_path):
    """Create a minimal knowledge store with one valid entry in each relevant category."""
    kd = tmp_path / "knowledge"
    kd.mkdir()

    # conventions/ category with one entry
    conv_dir = kd / "conventions"
    conv_dir.mkdir()
    (conv_dir / "shell-script-conventions.md").write_text(
        "# Shell Script Conventions\n"
        "All scripts use set -euo pipefail.\n"
        "<!-- learned: 2026-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # architecture/ category with one entry
    arch_dir = kd / "architecture"
    arch_dir.mkdir()
    (arch_dir / "service-mesh.md").write_text(
        "# Service Mesh\n"
        "The application uses a service mesh.\n"
        "<!-- learned: 2026-01-01 | confidence: high -->\n",
        encoding="utf-8",
    )

    # _work/ directory with one active work item
    work_dir = kd / "_work"
    work_dir.mkdir()
    item_dir = work_dir / "my-feature"
    item_dir.mkdir()
    (item_dir / "_meta.json").write_text(
        json.dumps({"title": "My Feature", "status": "active", "slug": "my-feature"}),
        encoding="utf-8",
    )
    (item_dir / "plan.md").write_text(
        "# My Feature\n## Goal\nDo something.\n",
        encoding="utf-8",
    )

    # Index the knowledge store so search works
    subprocess.run(
        ["python3", PK_CLI, "index", str(kd), "--force"],
        capture_output=True,
        check=True,
    )

    return kd


def run_verify(plan_path, knowledge_dir, extra_args=None) -> dict:
    """Run verify-plan-backlinks.sh and return parsed JSON output."""
    cmd = ["bash", VERIFY_SCRIPT, str(plan_path), str(knowledge_dir)]
    if extra_args:
        cmd.extend(extra_args)

    result = subprocess.run(cmd, capture_output=True, text=True)

    assert result.returncode == 0, (
        f"Script failed with returncode {result.returncode}\n"
        f"stdout: {result.stdout}\n"
        f"stderr: {result.stderr}"
    )
    return json.loads(result.stdout)


def run_verify_raw(plan_path, knowledge_dir, extra_args=None) -> subprocess.CompletedProcess[str]:
    """Run verify-plan-backlinks.sh and return the raw CompletedProcess."""
    cmd = ["bash", VERIFY_SCRIPT, str(plan_path), str(knowledge_dir)]
    if extra_args:
        cmd.extend(extra_args)

    return subprocess.run(cmd, capture_output=True, text=True)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestNoBacklinks:
    """Plan with no backlinks — should return all-zero result immediately."""

    def test_no_backlinks_returns_empty_result(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text("# My Plan\n## Goal\nNo backlinks here.\n", encoding="utf-8")

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 0
        assert result["corrected"] == []
        assert result["unresolved"] == []

    def test_plan_with_only_thread_backlinks_ignored(self, tmp_path, knowledge_dir):
        """Thread backlinks are not extracted (only knowledge/work/plan types)."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[thread:how-we-work]] is a thread reference.\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 0
        assert result["corrected"] == []
        assert result["unresolved"] == []


class TestAllResolved:
    """Plan where all backlinks resolve successfully."""

    def test_valid_knowledge_backlink(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[knowledge:conventions/shell-script-conventions]] — use this.\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 1
        assert result["corrected"] == []
        assert result["unresolved"] == []

    def test_valid_work_backlink(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\nSee [[work:my-feature]] for context.\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 1
        assert result["corrected"] == []
        assert result["unresolved"] == []

    def test_multiple_valid_backlinks(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n"
            "- [[knowledge:conventions/shell-script-conventions]]\n"
            "- [[knowledge:architecture/service-mesh]]\n"
            "- [[work:my-feature]]\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 3
        assert result["corrected"] == []
        assert result["unresolved"] == []

    def test_deduplicated_backlinks_counted_once(self, tmp_path, knowledge_dir):
        """Duplicate backlinks in the plan should be deduplicated before resolution."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n"
            "[[knowledge:conventions/shell-script-conventions]] and again "
            "[[knowledge:conventions/shell-script-conventions]].\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        # Deduplicated to 1 unique backlink
        assert result["verified"] == 1
        assert result["corrected"] == []
        assert result["unresolved"] == []


class TestTrulyMissingBacklink:
    """Backlinks that don't exist and can't be auto-corrected."""

    def test_nonexistent_knowledge_path(self, tmp_path, knowledge_dir):
        """A backlink that doesn't resolve appears in either corrected (if search found a candidate)
        or unresolved (if no candidate). In both cases it is NOT in verified."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[knowledge:nonexistent-category/no-such-entry]]\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 0
        # The broken backlink must appear in corrected OR unresolved (not silently dropped)
        all_bad_backlinks = (
            [item["from"] for item in result["corrected"]]
            + [item["backlink"] for item in result["unresolved"]]
        )
        assert "[[knowledge:nonexistent-category/no-such-entry]]" in all_bad_backlinks

    def test_placeholder_backlink_reported_as_unresolved(self, tmp_path, knowledge_dir):
        """[[knowledge:...]] placeholder templates are flagged as unresolved."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[knowledge:...]] — fill this in.\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        # Placeholder can't resolve and slug parts "..." are too short for search
        assert result["verified"] == 0
        broken_backlinks = [u["backlink"] for u in result["unresolved"]]
        assert "[[knowledge:...]]" in broken_backlinks


class TestMixedScenarios:
    """Mixed valid and invalid backlinks."""

    def test_mixed_valid_and_invalid(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n"
            "- [[knowledge:conventions/shell-script-conventions]] — good\n"
            "- [[knowledge:totally-wrong/path]] — bad\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 1
        assert len(result["unresolved"]) + len(result["corrected"]) == 1

    def test_work_placeholder_with_valid_knowledge(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n"
            "- [[knowledge:architecture/service-mesh]] — valid\n"
            "- [[work:...]] — placeholder\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        assert result["verified"] == 1
        broken_backlinks = [u["backlink"] for u in result["unresolved"]]
        assert "[[work:...]]" in broken_backlinks


class TestFixMode:
    """--fix flag applies corrections in-place."""

    def test_fix_rewrites_corrected_backlinks(self, tmp_path, knowledge_dir):
        """A corrected backlink is rewritten in the plan file."""
        plan = tmp_path / "plan.md"
        original_content = (
            "# Plan\n"
            "[[knowledge:conventions/shell-script-conventions]] is good.\n"
            "[[knowledge:totally-missing/no-such-file]] is broken.\n"
        )
        plan.write_text(original_content, encoding="utf-8")

        result = run_verify(plan, knowledge_dir, extra_args=["--fix"])

        # If a correction was found, the file should be modified
        if result["corrected"]:
            new_content = plan.read_text(encoding="utf-8")
            for item in result["corrected"]:
                assert item["from"] not in new_content, (
                    f"Old backlink {item['from']} still present after --fix"
                )
                assert item["to"] in new_content, (
                    f"New backlink {item['to']} not written after --fix"
                )

    def test_fix_does_not_modify_clean_plan(self, tmp_path, knowledge_dir):
        """--fix on a plan with all valid backlinks leaves the file unchanged."""
        plan = tmp_path / "plan.md"
        original_content = (
            "# Plan\n[[knowledge:conventions/shell-script-conventions]]\n"
        )
        plan.write_text(original_content, encoding="utf-8")

        result = run_verify(plan, knowledge_dir, extra_args=["--fix"])

        assert result["verified"] == 1
        assert result["corrected"] == []
        assert plan.read_text(encoding="utf-8") == original_content

    def test_no_fix_does_not_modify_file(self, tmp_path, knowledge_dir):
        """Without --fix, broken backlinks are only reported, file unchanged."""
        plan = tmp_path / "plan.md"
        original_content = (
            "# Plan\n[[knowledge:some/broken-path]] is broken.\n"
        )
        plan.write_text(original_content, encoding="utf-8")

        run_verify(plan, knowledge_dir)

        # File content should be unchanged regardless of corrections found
        assert plan.read_text(encoding="utf-8") == original_content


class TestErrorHandling:
    """Error cases — missing files, invalid args."""

    def test_missing_plan_file_exits_with_error(self, tmp_path, knowledge_dir):
        result = run_verify_raw(tmp_path / "nonexistent.md", knowledge_dir)
        assert result.returncode != 0
        output = json.loads(result.stdout) if result.stdout.strip() else {}
        assert "error" in output

    def test_missing_knowledge_dir_exits_with_error(self, tmp_path):
        plan = tmp_path / "plan.md"
        plan.write_text("# Plan\n", encoding="utf-8")
        result = run_verify_raw(plan, tmp_path / "nonexistent_kdir")
        assert result.returncode != 0
        output = json.loads(result.stdout) if result.stdout.strip() else {}
        assert "error" in output

    def test_no_args_exits_with_error(self):
        result = subprocess.run(
            ["bash", VERIFY_SCRIPT], capture_output=True, text=True
        )
        assert result.returncode != 0
        output = json.loads(result.stdout) if result.stdout.strip() else {}
        assert "error" in output


class TestOutputSchema:
    """JSON output always contains required keys."""

    def test_output_always_has_required_keys(self, tmp_path, knowledge_dir):
        plan = tmp_path / "plan.md"
        plan.write_text("# Plan\nNo backlinks.\n", encoding="utf-8")

        result = run_verify(plan, knowledge_dir)

        assert "verified" in result
        assert "corrected" in result
        assert "unresolved" in result
        assert isinstance(result["verified"], int)
        assert isinstance(result["corrected"], list)
        assert isinstance(result["unresolved"], list)

    def test_corrected_items_have_from_to_keys(self, tmp_path, knowledge_dir):
        """Each corrected item must have 'from' and 'to' keys."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[knowledge:conventions/shell-script-conventions]]\n"
            "[[knowledge:broken/missing-entry]]\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        for item in result["corrected"]:
            assert "from" in item
            assert "to" in item
            assert item["from"].startswith("[[")
            assert item["to"].startswith("[[")

    def test_unresolved_items_have_backlink_and_error_keys(self, tmp_path, knowledge_dir):
        """Each unresolved item must have 'backlink' and 'error' keys."""
        plan = tmp_path / "plan.md"
        plan.write_text(
            "# Plan\n[[knowledge:totally-nonexistent/entry]]\n",
            encoding="utf-8",
        )

        result = run_verify(plan, knowledge_dir)

        # May go to corrected or unresolved depending on search results
        for item in result["unresolved"]:
            assert "backlink" in item
            assert "error" in item
