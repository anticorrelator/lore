"""curate-scan.sh's renormalize flags: footer parsing, category coverage, and
related_files resolution against the checkout the store belongs to."""

import json
import os
import subprocess

import pytest

CURATE_SCAN = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "curate-scan.sh"
)


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _entry(title, related):
    """An entry whose footer has the field order capture.sh writes."""
    return (
        f"# {title}\nBody.\n"
        f"<!-- learned: 2026-09-01 | confidence: high | source: manual | "
        f"related_files: {related} | producer_role: worker | protocol_slot: Reflection | "
        f"work_item: some-work-item | scale: implementation | kind: fact | "
        f"captured_at_branch: main | captured_at_sha: abc123 | status: current -->\n"
    )


@pytest.fixture
def store(tmp_path):
    repo = tmp_path / "repo"
    (repo / "sub" / "dir").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    _write(repo / "scripts" / "present-file.sh", "echo\n")
    kd = tmp_path / "knowledge"
    _write(kd / "_work" / "some-item" / "plan.md", "# Plan\n")
    return repo, kd


def _scan(kd, cwd, **env):
    result = subprocess.run(
        ["bash", CURATE_SCAN, str(kd)],
        capture_output=True,
        text=True,
        cwd=cwd,
        env={**os.environ, "LORE_KNOWLEDGE_DIR": str(kd), **env},
    )
    assert result.returncode == 0, result.stderr
    flags = json.loads((kd / "_meta" / "renormalize-flags.json").read_text())
    return result.stdout, flags


def _stale(flags):
    return {e["entry"]: e["missing"] for e in flags["stale_related_files"]}


def test_modern_footer_yields_only_the_missing_paths(store):
    repo, kd = store
    _write(
        kd / "gotchas" / "entry.md",
        _entry("Entry", "scripts/present-file.sh, scripts/gone-away.sh"),
    )

    _, flags = _scan(kd, cwd=repo)

    assert _stale(flags) == {"gotchas/entry.md": ["scripts/gone-away.sh"]}


def test_every_category_is_scanned_at_any_depth(store):
    repo, kd = store
    for rel in (
        "design-rationale/why.md",
        "domains/evaluators/deep/eval.md",
        "preferences/pref.md",
        "conventions/nested/twice/conv.md",
    ):
        _write(kd / rel, _entry("E", "scripts/gone-away.sh"))
    _write(kd / "conventions" / "_drafts" / "hidden.md", _entry("H", "scripts/gone-away.sh"))

    _, flags = _scan(kd, cwd=repo)

    assert set(_stale(flags)) == {
        "design-rationale/why.md",
        "domains/evaluators/deep/eval.md",
        "preferences/pref.md",
        "conventions/nested/twice/conv.md",
    }


def test_store_relative_home_and_absolute_paths_resolve(store, tmp_path):
    repo, kd = store
    home = tmp_path / "home"
    _write(home / ".config" / "tool.json", "{}\n")
    absent = tmp_path / "nowhere" / "file.py"
    _write(
        kd / "architecture" / "paths.md",
        _entry(
            "Paths",
            f"_work/some-item/plan.md, ~/.config/tool.json, {repo}/scripts/present-file.sh, {absent}",
        ),
    )

    _, flags = _scan(kd, cwd=repo, HOME=str(home))

    assert _stale(flags) == {"architecture/paths.md": [str(absent)]}


def test_resolves_against_the_checkout_from_a_subdirectory(store):
    repo, kd = store
    _write(kd / "gotchas" / "entry.md", _entry("Entry", "scripts/present-file.sh"))

    stdout, flags = _scan(kd, cwd=repo / "sub" / "dir")

    assert flags["stale_related_files"] == []
    assert "not_checked" not in flags
    assert "## Renormalize flags: 0" in stdout


def test_outside_the_checkout_the_check_says_it_did_not_run(store, tmp_path):
    _, kd = store
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    _write(kd / "gotchas" / "entry.md", _entry("Entry", "scripts/present-file.sh"))

    stdout, flags = _scan(kd, cwd=elsewhere)

    assert flags["stale_related_files"] == []
    assert "stale_related_files" in flags["not_checked"]
    assert "stale related_files check did not run" in stdout


def test_retired_checks_keep_their_keys_empty(store):
    repo, kd = store
    for i in range(25):
        _write(kd / "conventions" / f"entry-{i}.md", _entry(f"E{i}", "scripts/present-file.sh"))
    _write(
        kd / "_meta" / "usage-report.json",
        json.dumps({"cold_entries": ["conventions/entry-0.md"]}),
    )
    log = kd / "_meta" / "retrieval-log.jsonl"
    log.write_text(
        "".join(
            json.dumps({"timestamp": f"2026-09-{d:02d}T00:00:00Z", "git_branch": "main"}) + "\n"
            for d in range(1, 16)
        )
    )

    _, flags = _scan(kd, cwd=repo)

    assert flags["oversized_categories"] == []
    assert flags["zero_access_entries"] == []
    assert flags["stale_related_files"] == []
