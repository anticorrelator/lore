"""Tests for scripts/capture-similar.py — the similar-entry check capture.sh runs after filing."""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

import pytest

SCRIPTS_DIR = os.path.join(os.path.dirname(__file__), "..", "scripts")
sys.path.insert(0, SCRIPTS_DIR)

from pk_search import INDEX_LOCK_FILENAME, Indexer  # noqa: E402

HELPER = os.path.join(SCRIPTS_DIR, "capture-similar.py")

RATE_LIMIT = (
    "The API rate limiter counts requests in a sliding sixty-second window keyed by tenant, "
    "so a burst from one tenant never throttles another tenant sharing the gateway."
)

SEED = {
    "gotchas/api-rate-limiter-counts-requests.md": RATE_LIMIT,
    "conventions/database-columns-use-snake-case.md": (
        "Database column names use snake_case and every table carries created_at and "
        "updated_at timestamps maintained by triggers."
    ),
    "conventions/deploys-need-vpn.md": (
        "Production deploys run from the bastion host and need the corporate VPN; the deploy "
        "script refuses to start without it."
    ),
    "gotchas/flaky-browser-tests-share-fixtures.md": (
        "Browser tests flake when two specs mutate the shared seed fixture; each spec must "
        "clone the fixture before writing to it."
    ),
}


def write_entry(kd, rel, body):
    path = kd / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    title = os.path.splitext(os.path.basename(rel))[0].replace("-", " ").title()
    path.write_text(
        f"# {title}\n{body}\n"
        "<!-- learned: 2026-01-01 | confidence: high | source: manual | scale: implementation "
        "| kind: fact | status: current -->\n",
        encoding="utf-8",
    )
    return path


@pytest.fixture
def store(tmp_path):
    kd = tmp_path / "knowledge"
    kd.mkdir()
    for rel, body in SEED.items():
        write_entry(kd, rel, body)
    Indexer(str(kd)).index_all()
    return kd


def run_helper(kd, entry, *extra):
    result = subprocess.run(
        [sys.executable, HELPER, "--kdir", str(kd), "--entry", str(entry), *extra],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0
    return result.stdout.splitlines()


def test_deleted_entry_is_not_reported(store):
    (store / "gotchas/api-rate-limiter-counts-requests.md").unlink()
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    assert run_helper(store, entry) == []


def test_reports_at_most_three_matches_most_similar_first(store):
    for i in range(4):
        write_entry(store, f"gotchas/rate-limiter-copy-{i}.md", RATE_LIMIT + " Copy." * i)
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(store, entry)
    assert len(lines) == 3
    scores = [float(line.rsplit("similarity ", 1)[1].rstrip(")")) for line in lines]
    assert scores == sorted(scores, reverse=True)
    assert not any("rate-limiter-again" in line for line in lines)


def test_busy_index_lock_prints_one_skip_line(store, tmp_path):
    ready = tmp_path / "ready"
    holder = subprocess.Popen([
        sys.executable, "-c",
        "import fcntl, os, sys, time\n"
        "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)\n"
        "fcntl.flock(fd, fcntl.LOCK_EX)\n"
        "open(sys.argv[2], 'w').close()\n"
        "time.sleep(60)\n",
        str(store / INDEX_LOCK_FILENAME), str(ready),
    ])
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            assert time.monotonic() < deadline
            time.sleep(0.02)
        entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
        lines = run_helper(store, entry)
        assert len(lines) == 1
        assert lines[0].startswith("[capture] similarity check skipped: ")

        payload = json.loads("\n".join(run_helper(store, entry, "--json")))
        assert payload["similar"] is None
        assert payload["skipped"]
    finally:
        holder.kill()
        holder.wait()


def test_index_built_at_another_path_prints_one_skip_line(store, tmp_path):
    moved = tmp_path / "moved"
    shutil.move(str(store), str(moved))
    entry = write_entry(moved, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(moved, entry)
    assert len(lines) == 1
    assert lines[0].startswith("[capture] similarity check skipped: ")


def test_store_reached_through_a_symlink_still_matches(store, tmp_path):
    alias = tmp_path / "alias"
    alias.symlink_to(store)
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(alias, alias / "gotchas/rate-limiter-again.md")
    assert [line.split(" (similarity")[0] for line in lines] == [
        "[capture] similar entry: gotchas/api-rate-limiter-counts-requests.md"
    ]
    assert entry.exists()


def test_index_built_through_a_symlink_still_matches(tmp_path):
    real = tmp_path / "real"
    real.mkdir()
    for rel, body in SEED.items():
        write_entry(real, rel, body)
    alias = tmp_path / "alias"
    alias.symlink_to(real)
    Indexer(str(alias)).index_all()
    entry = write_entry(real, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(real, entry)
    assert [line.split(" (similarity")[0] for line in lines] == [
        "[capture] similar entry: gotchas/api-rate-limiter-counts-requests.md"
    ]


@pytest.mark.parametrize("status", ["retired", "superseded", "historical", "expired"])
def test_entries_withheld_from_default_search_are_not_reported(store, status):
    path = store / "gotchas/api-rate-limiter-counts-requests.md"
    path.write_text(path.read_text().replace("status: current", f"status: {status}"))
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    assert run_helper(store, entry) == []


def test_corrected_entries_are_still_reported(store):
    path = store / "gotchas/api-rate-limiter-counts-requests.md"
    path.write_text(path.read_text().replace("status: current", "status: corrected"))
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    assert [line.split(" (similarity")[0] for line in run_helper(store, entry)] == [
        "[capture] similar entry: gotchas/api-rate-limiter-counts-requests.md"
    ]


@pytest.mark.parametrize("status", ["retired", "superseded"])
def test_a_withheld_match_does_not_use_up_the_limit(store, status):
    for i in range(3):
        write_entry(store, f"gotchas/rate-limiter-copy-{i}.md", RATE_LIMIT + " Copy." * i)
    withheld = store / "gotchas/api-rate-limiter-counts-requests.md"
    withheld.write_text(withheld.read_text().replace("status: current", f"status: {status}"))
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(store, entry)
    assert len(lines) == 3
    assert not any("api-rate-limiter-counts-requests" in line for line in lines)


SESSION_FOOTER = (
    "<!-- learned: 2026-09-23 | confidence: high | source: manual "
    "| related_files: scripts/uploader.sh | producer_role: worker | protocol_slot: implement "
    "| template_version: 9f3c2a1b7d4e | capturer_role: worker "
    "| source_artifact_ids: probe-artifact-7731 | work_item: quarterly-ledger-reconciliation-probe "
    "| scale: implementation | kind: fact | captured_at_branch: ledger-reconcile-probe "
    "| captured_at_sha: 3b9e2c4d8f1a6e7b5c0d9a8f7e6d5c4b3a291807 "
    "| captured_at_merge_base_sha: 7f6e5d4c3b2a19087f6e5d4c3b2a19087f6e5d4c | status: current -->"
)


def write_session_entry(kd, rel, body, footer=SESSION_FOOTER):
    path = kd / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    title = os.path.splitext(os.path.basename(rel))[0].replace("-", " ").title()
    path.write_text(f"# {title}\n{body}\n{footer}\n", encoding="utf-8")
    return path


def test_entries_sharing_only_a_footer_are_not_reported(store):
    write_session_entry(store, "gotchas/ledger-export-rounds-half-even.md",
                        "Ledger exports round half-even, so cent totals drift from the bank statement.")
    Indexer(str(store)).index_all()
    entry = write_session_entry(store, "gotchas/pager-rotation-skips-holidays.md",
                                "The pager rotation skips public holidays and doubles the next shift.")
    assert run_helper(store, entry) == []


def test_a_duplicate_captured_in_the_same_session_is_still_reported(store):
    write_session_entry(store, "gotchas/ledger-export-rounds-half-even.md",
                        "Ledger exports round half-even, so cent totals drift from the bank statement.")
    Indexer(str(store)).index_all()
    entry = write_session_entry(store, "gotchas/ledger-exports-drift-from-bank.md",
                                "Ledger exports round half-even, which makes cent totals drift from the bank statement.")
    assert [line.split(" (similarity")[0] for line in run_helper(store, entry)] == [
        "[capture] similar entry: gotchas/ledger-export-rounds-half-even.md"
    ]


def test_vectors_built_before_footer_stripping_print_one_skip_line(store):
    conn = sqlite3.connect(str(store / ".pk_search.db"))
    conn.execute("DELETE FROM index_meta WHERE key = 'tfidf_vector_text'")
    conn.commit()
    conn.close()
    entry = write_entry(store, "gotchas/rate-limiter-again.md", RATE_LIMIT)
    lines = run_helper(store, entry)
    assert len(lines) == 1
    assert lines[0].startswith("[capture] similarity check skipped: ")

    Indexer(str(store)).build_concordance()
    assert [line.split(" (similarity")[0] for line in run_helper(store, entry)] == [
        "[capture] similar entry: gotchas/api-rate-limiter-counts-requests.md"
    ]
