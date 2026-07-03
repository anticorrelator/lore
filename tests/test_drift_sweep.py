"""Tests for the per-file git drift classifier in drift-sweep.py.

The classifier maps each related_file to one of {unchanged, changed, vanished,
unresolved} by comparing git blob ids at the entry's captured_at_sha against
HEAD. These tests build real git repos so the classification is exercised end to
end (no mocking of git).
"""

import hashlib
import importlib.util
import json
import os
import subprocess
import sys

import pytest

_SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "scripts", "drift-sweep.py")
_spec = importlib.util.spec_from_file_location("drift_sweep", _SCRIPT_PATH)
drift_sweep = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(drift_sweep)


# ---------------------------------------------------------------------------
# Git fixture helpers
# ---------------------------------------------------------------------------

def _git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, capture_output=True, text=True, check=True
    )


def _commit(repo, msg):
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", msg, "--no-gpg-sign")
    return _git(repo, "rev-parse", "HEAD").stdout.strip()


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "src"
    r.mkdir()
    _git(r, "init", "-q")
    (r / "stable.py").write_text("print('stable')\n")
    (r / "mutated.py").write_text("v = 1\n")
    (r / "deleted.py").write_text("doomed = True\n")
    base_sha = _commit(r, "baseline")
    return {"path": str(r), "base_sha": base_sha}


def _head(repo_path):
    return _git(repo_path, "rev-parse", "HEAD").stdout.strip()


# ---------------------------------------------------------------------------
# classify_file: the four states
# ---------------------------------------------------------------------------

def test_unchanged_file_classifies_unchanged(repo):
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "stable.py")
    assert out["drift_class"] == "unchanged"


def test_modified_file_classifies_changed(repo):
    (os.path.join(repo["path"], "mutated.py"))
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 2\n")
    _commit(repo["path"], "mutate")
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "mutated.py")
    assert out["drift_class"] == "changed"


def test_deleted_file_classifies_vanished(repo):
    os.remove(os.path.join(repo["path"], "deleted.py"))
    _commit(repo["path"], "delete")
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "deleted.py")
    assert out["drift_class"] == "vanished"


def test_file_absent_at_both_classifies_unresolved(repo):
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "never_existed.py")
    assert out["drift_class"] == "unresolved"


def test_file_added_after_baseline_classifies_changed(repo):
    # Present at HEAD but absent at the baseline tree → conservative re-audit.
    with open(os.path.join(repo["path"], "added.py"), "w") as fh:
        fh.write("new = True\n")
    _commit(repo["path"], "add new file")
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "added.py")
    assert out["drift_class"] == "changed"


def test_absolute_path_inside_repo_resolves(repo):
    head = _head(repo["path"])
    abs_path = os.path.join(repo["path"], "stable.py")
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, abs_path)
    assert out["drift_class"] == "unchanged"


def test_absolute_path_outside_repo_is_unresolved(repo):
    head = _head(repo["path"])
    out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, "/etc/hosts")
    assert out["drift_class"] == "unresolved"


# ---------------------------------------------------------------------------
# Property: classify_file always returns a member of the closed set
# ---------------------------------------------------------------------------

def test_classify_always_in_closed_set(repo):
    head = _head(repo["path"])
    candidates = [
        "stable.py", "mutated.py", "deleted.py", "never_existed.py",
        "/etc/hosts", "../escape.py", os.path.join(repo["path"], "stable.py"),
        "sub/dir/file.py", "",
    ]
    for rf in candidates:
        out = drift_sweep.classify_file(repo["path"], repo["base_sha"], head, rf)
        assert out["drift_class"] in drift_sweep.DRIFT_CLASSES


# ---------------------------------------------------------------------------
# Footer parsing: comma-separated multi-values become lists
# ---------------------------------------------------------------------------

def test_footer_multivalue_related_files_and_scale():
    text = (
        "# Title\nBody.\n"
        "<!-- learned: 2026-01-01 | related_files: a.py,b.py,c.py "
        "| scale: architecture,subsystem | captured_at_sha: deadbeef | status: current -->\n"
    )
    footer = drift_sweep.parse_footer(text)
    assert footer["related_files"] == ["a.py", "b.py", "c.py"]
    assert footer["scale"] == ["architecture", "subsystem"]
    assert footer["captured_at_sha"] == "deadbeef"
    assert footer["status"] == "current"


def test_footer_missing_status_is_none():
    text = "# Title\nBody.\n<!-- learned: 2026-01-01 | related_files: a.py -->\n"
    footer = drift_sweep.parse_footer(text)
    assert footer["status"] is None


def test_footer_confidence_extracted():
    text = (
        "# Title\nBody.\n"
        "<!-- learned: 2026-01-01 | confidence: unaudited | related_files: a.py "
        "| status: current -->\n"
    )
    footer = drift_sweep.parse_footer(text)
    assert footer["confidence"] == "unaudited"


def test_footer_confidence_advances_does_not_shadow_confidence():
    # confidence_advances is a distinct key; only `confidence:` may set the field.
    text = (
        "# Title\nBody.\n"
        '<!-- learned: 2026-01-01 | confidence: high | status: current '
        '| confidence_advances: [{"from": "unaudited", "to": "high"}] -->\n'
    )
    footer = drift_sweep.parse_footer(text)
    assert footer["confidence"] == "high"


# ---------------------------------------------------------------------------
# Claim synthesis: H1 + lead paragraph; falsifier extraction; unparseable
# ---------------------------------------------------------------------------

def test_extract_claim_joins_h1_and_lead_paragraph():
    text = (
        "# The Heading Line\n"
        "First body paragraph with the claim. Falsifier: if X then Y.\n"
        "<!-- learned: 2026-01-01 -->\n"
    )
    claim, falsifier = drift_sweep.extract_claim(text)
    assert claim.startswith("The Heading Line First body paragraph")
    assert falsifier == "if X then Y."


def test_extract_claim_unparseable_without_h1():
    text = "No heading here, just prose.\n<!-- learned: 2026-01-01 -->\n"
    claim, falsifier = drift_sweep.extract_claim(text)
    assert claim is None


def test_extract_claim_no_falsifier_returns_none_falsifier():
    text = "# Heading\nA paragraph with no falsifier line.\n<!-- x -->\n"
    claim, falsifier = drift_sweep.extract_claim(text)
    assert claim is not None
    assert falsifier is None


# ---------------------------------------------------------------------------
# slugify_path: deterministic and stable
# ---------------------------------------------------------------------------

def test_slugify_path_deterministic():
    p = "conventions/some-entry-name.md"
    assert drift_sweep.slugify_path(p) == drift_sweep.slugify_path(p)
    assert drift_sweep.slugify_path(p) == "conventions-some-entry-name"


def test_slugify_long_path_disambiguates_with_hash():
    a = "conventions/" + ("x" * 100) + ".md"
    b = "conventions/" + ("x" * 100) + "-other.md"
    # Same 80-char prefix but distinct paths must not collide.
    assert drift_sweep.slugify_path(a) != drift_sweep.slugify_path(b)


# ---------------------------------------------------------------------------
# plan_entry: scope gates skip without error; drift triggers synthesis payload
# ---------------------------------------------------------------------------

def _write_entry(kdir, rel, body, footer):
    path = os.path.join(kdir, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(body + "\n<!-- " + footer + " -->\n")
    return path


def test_plan_skips_non_current_status(tmp_path, repo):
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    _write_entry(
        kdir, "conventions/e.md", "# E\nBody.",
        "related_files: stable.py | scale: subsystem | "
        f"captured_at_sha: {repo['base_sha']} | status: historical",
    )
    head = _head(repo["path"])
    row = drift_sweep.plan_entry(kdir, repo["path"], head, os.path.join(kdir, "conventions/e.md"))
    assert row["drifted"] is False
    assert "skip_reason" in row
    assert row["enqueue"] == "skipped"


def test_plan_drifted_entry_emits_synthesized_payload(tmp_path, repo):
    # Mutate the related file so the entry drifts.
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 99\n")
    _commit(repo["path"], "mutate for plan")
    head = _head(repo["path"])

    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    _write_entry(
        kdir, "conventions/drifted.md",
        "# Drifted Entry\nThe claim body. Falsifier: if mutated.py reverts.",
        "related_files: mutated.py | scale: subsystem | "
        f"captured_at_sha: {repo['base_sha']} | status: current",
    )
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, os.path.join(kdir, "conventions/drifted.md"))
    assert row["drifted"] is True
    assert row["claim_id"] == "drift-conventions-drifted"
    payload = row["synthesized_payload"]
    assert payload["entry_path"] == "conventions/drifted.md"
    assert payload["related_files"] == ["mutated.py"]
    assert payload["falsifier"] == "if mutated.py reverts."
    assert payload["scale"] == "subsystem"
    assert payload["claim"].startswith("Drifted Entry The claim body")


def test_plan_unchanged_entry_no_payload(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    _write_entry(
        kdir, "conventions/clean.md", "# Clean\nBody.",
        "related_files: stable.py | scale: subsystem | "
        f"captured_at_sha: {repo['base_sha']} | status: current",
    )
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, os.path.join(kdir, "conventions/clean.md"))
    assert row["drifted"] is False
    assert "synthesized_payload" not in row
    assert row["producer_row"] == "skipped"
    assert row["enqueue"] == "skipped"


def test_plan_drifted_but_unparseable_never_enqueues(tmp_path, repo):
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 123\n")
    _commit(repo["path"], "mutate for unparseable")
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    # No H1 → unparseable. Drifted file, but must not enqueue.
    _write_entry(
        kdir, "conventions/noh1.md", "Just prose, no heading.",
        "related_files: mutated.py | scale: subsystem | "
        f"captured_at_sha: {repo['base_sha']} | status: current",
    )
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, os.path.join(kdir, "conventions/noh1.md"))
    assert row["drifted"] is True
    assert row.get("unparseable") is True
    assert "synthesized_payload" not in row
    assert row["enqueue"] == "skipped"


# ---------------------------------------------------------------------------
# Unaudited arm: --include-unaudited / --unaudited-only eligibility, settled-run
# suppression, enqueue_reason, and falsifier wording
# ---------------------------------------------------------------------------

WORK_ITEM = "proactive-drift-sweep-re-hash-commons-snippets-vs"


def _write_run(kdir, item_id, status="completed", verdict="verified", invalidated=False):
    runs = os.path.join(kdir, "_settlement", "runs")
    os.makedirs(runs, exist_ok=True)
    run = {
        "run_id": f"run-{item_id}",
        "item_id": item_id,
        "status": status,
        "verdict": {"verdict": verdict},
    }
    if invalidated:
        run["invalidated_at"] = "2026-01-02T00:00:00Z"
    with open(os.path.join(runs, f"run-{item_id}.json"), "w") as fh:
        json.dump(run, fh)


def _unaudited_entry(kdir, rel="conventions/unaudited.md", related="stable.py",
                     sha=None, body="The stable module returns one."):
    footer = f"related_files: {related} | scale: subsystem | confidence: unaudited"
    if sha:
        footer += f" | captured_at_sha: {sha}"
    footer += " | status: current"
    _write_entry(kdir, rel, "# Unaudited Entry\n" + body, footer)
    return os.path.join(kdir, rel)


def test_commons_item_id_mirrors_settlement_identity():
    digest = hashlib.sha256(b"commons:wi:claim-1").hexdigest()[:20]
    assert drift_sweep.commons_item_id("wi", "claim-1") == f"commons-{digest}"


def test_unchanged_unaudited_entry_enqueues_only_with_flag(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, sha=repo["base_sha"])

    # Without the flag: unchanged entries stay unenqueued exactly as today.
    row = drift_sweep.plan_entry(kdir, repo["path"], head, path)
    assert row["drifted"] is False
    assert "synthesized_payload" not in row

    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=set(), work_item=WORK_ITEM)
    assert row["drifted"] is False
    assert row["enqueue_reason"] == "unaudited"
    assert row["claim_id"] == "drift-conventions-unaudited"
    payload = row["synthesized_payload"]
    # Never-audited fallback wording — must not assert a code change.
    assert payload["falsifier"].startswith(
        "promoted claim has never been independently audited")
    assert "stable.py" in payload["falsifier"]


def test_high_confidence_unchanged_entry_not_enqueued_by_flag(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    _write_entry(
        kdir, "conventions/high.md", "# High\nBody.",
        "related_files: stable.py | scale: subsystem | confidence: high | "
        f"captured_at_sha: {repo['base_sha']} | status: current",
    )
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, os.path.join(kdir, "conventions/high.md"),
        include_unaudited=True, settled_ids=set(), work_item=WORK_ITEM)
    assert "synthesized_payload" not in row
    assert "enqueue_reason" not in row


def test_sha_unresolvable_unaudited_entry_is_eligible(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, sha="f" * 40)

    # Without the flag the bad baseline skips the entry entirely.
    row = drift_sweep.plan_entry(kdir, repo["path"], head, path)
    assert "skip_reason" in row and "not resolvable" in row["skip_reason"]

    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=set(), work_item=WORK_ITEM)
    assert row["drift_check"] == "skipped"
    assert "not resolvable" in row["drift_skip_reason"]
    assert row["drifted"] is False
    assert row["enqueue_reason"] == "unaudited"
    assert row["synthesized_payload"]["claim_id"] == "drift-conventions-unaudited"


def test_missing_sha_unaudited_entry_is_eligible(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, sha=None)
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=set(), work_item=WORK_ITEM)
    assert row["drift_check"] == "skipped"
    assert row["drift_skip_reason"] == "missing captured_at_sha"
    assert row["enqueue_reason"] == "unaudited"


def test_settled_run_suppresses_unaudited_arm_with_distinct_report(tmp_path, repo):
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, sha=repo["base_sha"])
    item_id = drift_sweep.commons_item_id(WORK_ITEM, "drift-conventions-unaudited")
    _write_run(kdir, item_id, status="completed", verdict="contradicted")

    settled = drift_sweep.load_settled_item_ids(kdir)
    assert item_id in settled

    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=settled, work_item=WORK_ITEM)
    assert row["already_settled"] is True
    assert "synthesized_payload" not in row
    assert "enqueue_reason" not in row


def test_non_settling_runs_do_not_suppress(tmp_path):
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    # failed/blocked stay re-reachable; skipped is not a real gate verdict;
    # invalidated runs never count.
    _write_run(kdir, "commons-aaaa", status="failed", verdict="verified")
    _write_run(kdir, "commons-bbbb", status="completed", verdict="skipped")
    _write_run(kdir, "commons-cccc", status="completed", verdict="verified",
               invalidated=True)
    _write_run(kdir, "commons-dddd", status="blocked", verdict="contradicted")
    assert drift_sweep.load_settled_item_ids(kdir) == set()


def test_drifted_unaudited_entry_reports_both_arms(tmp_path, repo):
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 7\n")
    _commit(repo["path"], "mutate for both arms")
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, related="mutated.py", sha=repo["base_sha"])
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=set(), work_item=WORK_ITEM)
    assert row["drifted"] is True
    assert row["enqueue_reason"] == "drift+unaudited"
    # A real code change happened, so the drift wording is the honest fallback.
    assert row["synthesized_payload"]["falsifier"].startswith(
        "entry claim no longer matches cited code at HEAD")


def test_settled_run_leaves_drift_arm_unaffected(tmp_path, repo):
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 8\n")
    _commit(repo["path"], "mutate for settled drift")
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    path = _unaudited_entry(kdir, related="mutated.py", sha=repo["base_sha"])
    item_id = drift_sweep.commons_item_id(WORK_ITEM, "drift-conventions-unaudited")
    _write_run(kdir, item_id)
    settled = drift_sweep.load_settled_item_ids(kdir)

    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, settled_ids=settled, work_item=WORK_ITEM)
    assert row["already_settled"] is True
    assert row["enqueue_reason"] == "drift"
    assert "synthesized_payload" in row


def test_unaudited_only_suppresses_purely_drifted_entries(tmp_path, repo):
    with open(os.path.join(repo["path"], "mutated.py"), "w") as fh:
        fh.write("v = 9\n")
    _commit(repo["path"], "mutate for unaudited-only")
    head = _head(repo["path"])
    kdir = str(tmp_path / "k")
    os.makedirs(kdir)
    _write_entry(
        kdir, "conventions/drifted-high.md", "# Drifted High\nBody.",
        "related_files: mutated.py | scale: subsystem | confidence: high | "
        f"captured_at_sha: {repo['base_sha']} | status: current",
    )
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, os.path.join(kdir, "conventions/drifted-high.md"),
        include_unaudited=True, unaudited_only=True,
        settled_ids=set(), work_item=WORK_ITEM)
    # Drift is still classified and reported, but nothing is planned for enqueue.
    assert row["drifted"] is True
    assert "synthesized_payload" not in row
    assert "enqueue_reason" not in row

    path = _unaudited_entry(kdir, related="stable.py", sha=repo["base_sha"])
    row = drift_sweep.plan_entry(
        kdir, repo["path"], head, path,
        include_unaudited=True, unaudited_only=True,
        settled_ids=set(), work_item=WORK_ITEM)
    assert row["enqueue_reason"] == "unaudited"


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-v"]))
