"""Tests for migrate-general-bucket.py on a fixture store."""

import hashlib
import json
import os
import re
import subprocess
import sys

import pytest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
CLI = os.path.join(SCRIPTS, "migrate-general-bucket.py")

WORK_ITEM = "demo-item"
LIST_REL = f"_work/{WORK_ITEM}/general-bucket.md"

THREADS = {
    "how-we-work": {
        "topic": "How We Work",
        "tier": "pinned",
        "notes": [
            "Commit to one choice with a reason",
            "Settle open questions from the design's own principle",
            "Keep exploring proposals tentative",
            "Informational feedback: short, no emoji",
            "Spec before implement for UI work",
            "TUI confirmations for archive and delete",
        ],
        "ascii": True,
    },
    "memory-system-design": {
        "topic": "Memory System Design",
        "tier": "active",
        "notes": [
            "Articulate invariants rather than option lists — synthesis stays with the model",
            "Coordinators read reports first",
        ],
        "ascii": False,
    },
}

LIST_TEXT = """# General bucket

Intro prose that names no entry.

## Proposed entries

### 1. Commit to one choice with its reason, not a menu of options.

- **Activities:** general
- **Context:** Supply the precision once the direction is set.
- **Why these fold together:** One move.

| Thread | Preference (verbatim) | First seen | Last reinforced |
|---|---|---|---|
| how-we-work | Commit to one choice with a reason | 2026-04-22 | 2026-10-23 |
| how-we-work | Settle open questions from the design's own principle | 2026-07-25 | 2026-07-25 |
| memory-system-design | Articulate invariants rather than option lists — synthesis stays with the model | 2026-05-01 | 2026-05-01 |

### 2. Keep proposals tentative while ideas are explored

- **Activities:** general, work-scoping
- **Context:** Exploring mode records findings and stops before synthesis.
- **Why these fold together:** Same mode.

| Thread | Preference (verbatim) | First seen | Last reinforced |
|---|---|---|---|
| how-we-work | Keep exploring proposals tentative | 2026-04-23 | 2026-05-19 |

### 4. Coordinators work from reports, not files.

- **Activities:** coordination
- **Context:** Source files are opened only when a report cannot settle the question.
- **Why these fold together:** Context preservation.

| Thread | Preference (verbatim) | First seen | Last reinforced |
|---|---|---|---|
| memory-system-design | Coordinators read reports first | 2026-07-16 | 2026-07-16 |

### 5. Archive and delete in the TUI always ask first.

- **Activities:** tui-design
- **Context:** Lifecycle transitions confirm even when reversible.
- **Why these fold together:** One rule.

| Thread | Preference (verbatim) | First seen | Last reinforced |
|---|---|---|---|
| how-we-work | TUI confirmations for archive and delete | 2026-02-25 | 2026-02-25 |

## Stale

| Thread | Preference (verbatim) | First seen | Last reinforced | Why it is retired |
|---|---|---|---|---|
| how-we-work | Informational feedback: short, no emoji | 2026-02-06 | 2026-02-06 | Held by a convention. |

## Already in preferences/

| Thread | Preference (verbatim) | First seen | Last reinforced | Carried by |
|---|---|---|---|---|
| how-we-work | Spec before implement for UI work | 2026-02-24 | 2026-02-24 | preferences/existing-coordination.md |

Write the date after the label below once the list reads right; filing waits for it.

**Accepted:** 2026-10-26

## Counts

- Proposed entries: 4
"""

EXISTING = {
    "preferences/existing-coordination.md": "coordination",
    "preferences/existing-scoping.md": "work-scoping",
    "preferences/existing-writing.md": "preference-writing",
}


def thread_meta(spec):
    return {
        "topic": spec["topic"],
        "tier": spec["tier"],
        "created": "2026-02-06T03:00:00Z",
        "updated": "2026-10-23T18:20:27Z",
        "sessions": 3,
        "accumulated_preferences": [
            {
                "preference": note,
                "first_seen": "2026-02-06",
                "last_reinforced": "2026-02-06",
                "source_entries": ["2026-02-06.md"],
            }
            for note in spec["notes"]
        ],
    }


def write_meta(kdir, slug, meta, ascii_only=True):
    path = kdir / "_threads" / slug / "_meta.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(meta, indent=2, ensure_ascii=ascii_only) + "\n", encoding="utf-8")


@pytest.fixture
def store(tmp_path):
    kdir = tmp_path / "data" / "repos" / "example" / "store"
    kdir.mkdir(parents=True)
    (kdir / "_manifest.json").write_text(json.dumps({"format_version": 2}))
    for rel, activity in EXISTING.items():
        path = kdir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"# Existing {activity} preference\nBody.\n"
            f"<!-- learned: 2026-08-01 | confidence: high | source: manual | scale: subsystem | kind: fact"
            f" | activity: {activity} | status: current -->\n",
            encoding="utf-8",
        )
    (kdir / "conventions").mkdir()
    (kdir / "conventions" / "a-convention.md").write_text(
        "# A convention about naming\nNames share a prefix.\n"
        "<!-- learned: 2026-08-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->\n"
    )
    for slug, spec in THREADS.items():
        write_meta(kdir, slug, thread_meta(spec), spec["ascii"])
        (kdir / "_threads" / slug / "2026-02-06.md").write_text("**Summary:** A session.\n")
    (kdir / "_threads" / "_index.json").write_text(
        json.dumps({"threads": [{"slug": s, "tier": t["tier"]} for s, t in THREADS.items()]})
    )
    work = kdir / "_work" / WORK_ITEM
    work.mkdir(parents=True)
    (work / "_meta.json").write_text(json.dumps({"slug": WORK_ITEM, "title": "Demo item"}))
    (kdir / LIST_REL).write_text(LIST_TEXT, encoding="utf-8")
    return kdir


def run(kdir, *args, env_extra=None):
    env = dict(os.environ)
    env["LORE_DATA_DIR"] = str(kdir.parents[2])
    env["LORE_KNOWLEDGE_DIR"] = str(kdir)
    env.pop("LORE_AGENT_DISABLED", None)
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, CLI, "--kdir", str(kdir), "--list", str(kdir / LIST_REL), *args],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(kdir),
    )


def tree_hashes(kdir):
    out = {}
    for root, dirs, files in os.walk(kdir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if name.startswith(".pk_search"):
                continue
            path = os.path.join(root, name)
            with open(path, "rb") as handle:
                out[os.path.relpath(path, kdir)] = hashlib.sha256(handle.read()).hexdigest()
    return out


def edit_list(kdir, old, new, count=1):
    path = kdir / LIST_REL
    text = path.read_text(encoding="utf-8")
    assert text.count(old) == count, old
    path.write_text(text.replace(old, new), encoding="utf-8")


def preference_files(kdir):
    return sorted(p.name for p in (kdir / "preferences").glob("*.md"))


# --- --check ---------------------------------------------------------------


def test_check_accepts_a_complete_list_with_a_numbering_gap(store):
    proc = run(store, "--check")
    assert proc.returncode == 0, proc.stderr
    assert "8 thread notes, each placed once" in proc.stdout
    assert "4 proposed entries carry 6 notes; 2 notes sit in the other tables." in proc.stdout
    assert "New activity names this list creates: tui-design." in proc.stdout


def test_check_writes_nothing(store):
    before = tree_hashes(store)
    assert run(store, "--check").returncode == 0
    assert tree_hashes(store) == before


def test_check_refuses_a_thread_note_missing_from_the_list(store):
    meta = thread_meta(THREADS["how-we-work"])
    meta["accumulated_preferences"].append(
        {"preference": "A note recorded after the list was written", "first_seen": "2026-10-25",
         "last_reinforced": "2026-10-25", "source_entries": []}
    )
    write_meta(store, "how-we-work", meta)
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert 'missing from the list: how-we-work: "A note recorded after the list was written"' in proc.stderr
    assert "nothing was written" in proc.stderr


def test_check_refuses_a_note_dropped_from_the_list(store):
    edit_list(store, "| memory-system-design | Coordinators read reports first | 2026-07-16 | 2026-07-16 |\n", "")
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert 'missing from the list: memory-system-design: "Coordinators read reports first"' in proc.stderr


def test_check_refuses_a_duplicated_thread_note(store):
    edit_list(
        store,
        "| how-we-work | Keep exploring proposals tentative | 2026-04-23 | 2026-05-19 |\n",
        "| how-we-work | Keep exploring proposals tentative | 2026-04-23 | 2026-05-19 |\n"
        "| how-we-work | Commit to one choice with a reason | 2026-04-22 | 2026-10-23 |\n",
    )
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert re.search(r'listed 2 times \(line \d+ \(entry 1\), line \d+ \(entry 2\)\): how-we-work: "Commit to one choice with a reason"', proc.stderr), proc.stderr


def test_check_refuses_a_row_no_thread_holds(store):
    edit_list(store, "| how-we-work | Keep exploring proposals tentative |", "| how-we-work | Keep exploring proposal tentative |")
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert 'no such note in that thread: how-we-work: "Keep exploring proposal tentative"' in proc.stderr
    assert 'missing from the list: how-we-work: "Keep exploring proposals tentative"' in proc.stderr


def test_check_matches_across_whitespace_and_escaped_pipes(store):
    meta = thread_meta(THREADS["how-we-work"])
    meta["accumulated_preferences"].append(
        {"preference": "Pipes | survive\nline breaks", "first_seen": "2026-10-25",
         "last_reinforced": "2026-10-25", "source_entries": []}
    )
    write_meta(store, "how-we-work", meta)
    edit_list(
        store,
        "| how-we-work | Informational feedback: short, no emoji | 2026-02-06 | 2026-02-06 | Held by a convention. |\n",
        "| how-we-work | Informational feedback: short, no emoji | 2026-02-06 | 2026-02-06 | Held by a convention. |\n"
        "| how-we-work | Pipes \\| survive line breaks | 2026-10-25 | 2026-10-25 | Test. |\n",
    )
    proc = run(store, "--check")
    assert proc.returncode == 0, proc.stderr


@pytest.mark.parametrize("line", ["**Accepted:**", "**Accepted:** ", "**Accepted:** <date>", "**Accepted:** pending"])
def test_check_refuses_an_unfilled_acceptance_line(store, line):
    edit_list(store, "**Accepted:** 2026-10-26", line)
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert "**Accepted:** line" in proc.stderr and "is not filled" in proc.stderr


def test_check_refuses_a_list_with_no_acceptance_line(store):
    edit_list(store, "**Accepted:** 2026-10-26\n", "")
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert "no **Accepted:** line" in proc.stderr


def test_check_refuses_an_entry_without_activities_or_context(store):
    edit_list(store, "- **Activities:** coordination\n", "")
    edit_list(store, "- **Context:** Exploring mode records findings and stops before synthesis.\n", "")
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert "entry 4" in proc.stderr and "has no **Activities:** line" in proc.stderr
    assert "entry 2" in proc.stderr and "has no **Context:** line" in proc.stderr


def test_check_refuses_three_activities(store):
    edit_list(store, "- **Activities:** general, work-scoping", "- **Activities:** general, work-scoping, coordination")
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert "at most 2" in proc.stderr


# --- --apply ---------------------------------------------------------------


def test_apply_needs_a_producer_role(store):
    before = tree_hashes(store)
    proc = run(store, "--apply")
    assert proc.returncode == 2
    assert "--producer-role" in proc.stderr
    proc = run(store, "--apply", "--producer-role", "nobody")
    assert proc.returncode == 2
    assert tree_hashes(store) == before


def test_apply_refuses_a_failing_list_and_writes_nothing(store):
    edit_list(store, "**Accepted:** 2026-10-26", "**Accepted:**")
    before = tree_hashes(store)
    proc = run(store, "--apply", "--producer-role", "worker")
    assert proc.returncode == 1
    assert tree_hashes(store) == before


def footer(text):
    m = re.search(r"<!--(.*?)-->", text, re.DOTALL)
    return dict(
        (k.strip(), v.strip())
        for k, _, v in (part.partition(":") for part in m.group(1).split("|"))
    )


def test_apply_files_writes_back_empties_and_is_idempotent(store):
    hwm_before = (store / "_threads" / "how-we-work" / "_meta.json").read_text()
    proc = run(store, "--apply", "--producer-role", "worker")
    assert proc.returncode == 0, proc.stderr
    assert "4 entries filed in this run, 2 threads emptied." in proc.stdout

    listing = (store / LIST_REL).read_text(encoding="utf-8")
    filed = re.findall(r"^- \*\*Filed:\*\* (preferences/\S+\.md)$", listing, re.MULTILINE)
    assert len(filed) == 4
    expected = [
        ("Commit to one choice with its reason, not a menu of options", "general",
         "Supply the precision once the direction is set."),
        ("Keep proposals tentative while ideas are explored", "general, work-scoping",
         "Exploring mode records findings and stops before synthesis."),
        ("Coordinators work from reports, not files", "coordination",
         "Source files are opened only when a report cannot settle the question."),
        ("Archive and delete in the TUI always ask first", "tui-design",
         "Lifecycle transitions confirm even when reversible."),
    ]
    for rel, (title, activity, body) in zip(filed, expected):
        text = (store / rel).read_text(encoding="utf-8")
        assert text.splitlines()[0] == f"# {title}"
        assert text.splitlines()[1] == body
        meta = footer(text)
        assert meta["activity"] == activity
        assert meta["scale"] == "subsystem"
        assert meta["producer_role"] == "worker"
        assert meta["protocol_slot"] == "migrate-general-bucket"
        assert meta["work_item"] == WORK_ITEM
        assert meta["status"] == "current"

    # Each Filed line sits in its own entry, after the entry's last field line.
    for number, rel in zip((1, 2, 4, 5), filed):
        section = listing.split(f"### {number}. ", 1)[1].split("\n| Thread", 1)[0]
        assert section.rstrip().endswith(f"- **Filed:** {rel}")

    for slug in THREADS:
        path = store / "_threads" / slug / "_meta.json"
        meta = json.loads(path.read_text(encoding="utf-8"))
        assert meta["accumulated_preferences"] == []
        note = meta["preferences_migrated"]
        assert note["to"] == "preferences/ activity general"
        assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", note["date"])
        assert note["record"] == LIST_REL
        assert list(meta) == ["topic", "tier", "created", "updated", "sessions",
                              "accumulated_preferences", "preferences_migrated"]
        assert meta["updated"] == "2026-10-23T18:20:27Z"
    assert hwm_before.endswith("\n")
    assert (store / "_threads" / "how-we-work" / "_meta.json").read_text().endswith("\n")

    # A second run files nothing and changes nothing.
    before = tree_hashes(store)
    files_before = preference_files(store)
    again = run(store, "--apply", "--producer-role", "worker")
    assert again.returncode == 0, again.stderr
    assert "0 entries filed in this run, 0 threads emptied." in again.stdout
    assert preference_files(store) == files_before
    assert tree_hashes(store) == before

    # And the record still checks out against the emptied threads.
    check = run(store, "--check")
    assert check.returncode == 0, check.stderr
    assert "how-we-work: already migrated on" in check.stdout
    assert "Nothing left to do: every entry is filed and every thread is migrated." in check.stdout


def test_apply_skips_an_entry_that_already_carries_a_filed_path(store):
    edit_list(
        store,
        "- **Why these fold together:** Context preservation.\n",
        "- **Why these fold together:** Context preservation.\n- **Filed:** preferences/existing-coordination.md\n",
    )
    proc = run(store, "--apply", "--producer-role", "worker")
    assert proc.returncode == 0, proc.stderr
    assert "entry 4: already filed at preferences/existing-coordination.md" in proc.stdout
    assert "3 entries filed in this run" in proc.stdout
    assert len(preference_files(store)) == len(EXISTING) + 3


def test_check_refuses_a_filed_path_missing_from_the_store(store):
    edit_list(
        store,
        "- **Why these fold together:** Context preservation.\n",
        "- **Why these fold together:** Context preservation.\n- **Filed:** preferences/gone.md\n",
    )
    proc = run(store, "--check")
    assert proc.returncode == 1
    assert "preferences/gone.md, which is not in" in proc.stderr


def test_notes_recorded_after_migration_are_left_alone(store):
    assert run(store, "--apply", "--producer-role", "worker").returncode == 0
    path = store / "_threads" / "how-we-work" / "_meta.json"
    meta = json.loads(path.read_text())
    meta["accumulated_preferences"].append(
        {"preference": "A later note", "first_seen": "2026-11-01", "last_reinforced": "2026-11-01",
         "source_entries": []}
    )
    path.write_text(json.dumps(meta, indent=2) + "\n")
    check = run(store, "--check")
    assert check.returncode == 0, check.stderr
    assert "1 notes recorded since are not part of this list" in check.stdout
    again = run(store, "--apply", "--producer-role", "worker")
    assert again.returncode == 0, again.stderr
    assert json.loads(path.read_text())["accumulated_preferences"][0]["preference"] == "A later note"


def test_new_activity_is_passed_only_for_names_no_live_entry_carries(store, tmp_path):
    # A capture.sh stand-in that records its arguments shows which calls carry --new-activity.
    log = tmp_path / "argv.log"
    fake = tmp_path / "scripts"
    fake.mkdir()
    for name in os.listdir(SCRIPTS):
        if name.endswith(".py") or name.endswith(".json"):
            os.symlink(os.path.join(os.path.abspath(SCRIPTS), name), fake / name)
    os.unlink(fake / "migrate-general-bucket.py")
    with open(os.path.join(SCRIPTS, "migrate-general-bucket.py")) as src:
        (fake / "migrate-general-bucket.py").write_text(src.read())
    counter = tmp_path / "count"
    (fake / "capture.sh").write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s\\n" "$*" >> "{log}"\n'
        f'n=$(( $(cat "{counter}" 2>/dev/null || echo 0) + 1 )); echo "$n" > "{counter}"\n'
        'printf \'{"path": "preferences/fake-%s.md", "similar": []}\\n\' "$n"\n'
    )
    proc = subprocess.run(
        [sys.executable, str(fake / "migrate-general-bucket.py"), "--kdir", str(store),
         "--list", str(store / LIST_REL), "--apply", "--producer-role", "worker"],
        capture_output=True, text=True, env=dict(os.environ, LORE_KNOWLEDGE_DIR=str(store)),
    )
    assert proc.returncode == 0, proc.stderr
    calls = log.read_text().splitlines()
    assert len(calls) == 4
    with_new = [c for c in calls if "--new-activity" in c]
    assert len(with_new) == 1 and "--activity tui-design" in with_new[0]
    assert any("--activity general, work-scoping" in c for c in calls)
