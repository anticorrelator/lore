"""Tests for backfill-preference-activities.py on a fixture store."""

import hashlib
import json
import os
import stat
import subprocess
import sys

import pytest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPTS)

import pk_activities  # noqa: E402

CLI = os.path.join(SCRIPTS, "backfill-preference-activities.py")

CUT = "preferences/a-cut-off.md"
PLAIN = "preferences/b-plain.md"
TAGGED = "preferences/c-tagged.md"
RETIRED = "preferences/d-retired.md"
INLINE = "preferences/e-inline-footer.md"
CORRECTED = "preferences/f-corrected.md"
TWO = "preferences/g-two-tagged.md"

FOOTER = "learned: 2026-08-01 | confidence: high | source: manual | scale: subsystem | kind: fact"


def entry_text(title, body, extra="", status="current", inline=False):
    fields = FOOTER + (f" | {extra}" if extra else "") + f" | status: {status}"
    sep = "" if inline else "\n"
    return f"# {title}\n{body}{sep}<!-- {fields} -->\n"


ORIGINAL = {
    CUT: entry_text(
        "Before Any Edit To The Coordinate Skill Lands,",
        "Before any edit to the coordinate skill lands, it is read against lore's purpose.",
    ),
    PLAIN: entry_text("PR bodies describe what shipped", "No chronology in a PR body.\n\nNotes hold the history."),
    TAGGED: entry_text("Arcs price themselves before running", "Surface projected spend.", extra="activity: coordination"),
    RETIRED: entry_text("An old routing posture", "Superseded.", status="retired"),
    INLINE: entry_text("Subagent spawns state their model", "A spawn without a model inherits it.", inline=True),
    CORRECTED: entry_text("A Corrected Entry Whose Title Is Cut", "Corrected entries are live.", status="corrected"),
    TWO: entry_text("Important specs go to the top tier", "Escalate.", extra="activity: model-routing, work-scoping"),
}

MAP_ROWS = [
    {
        "path": CUT,
        "activities": ["protocol-prose"],
        "current_title": "Before Any Edit To The Coordinate Skill Lands,",
        "title": "Edits to the coordinate skill are read against lore's purpose before they land",
    },
    {"path": PLAIN, "activities": ["pr-bodies"]},
    {"path": TAGGED, "activities": ["coordination"]},
    {"path": INLINE, "activities": ["model-routing"], "title": "Agent spawns state their model explicitly"},
    {
        "path": CORRECTED,
        "activities": ["human-writing", "protocol-prose"],
        "current_title": "A Corrected Entry Whose Title Is Cut",
        "title": "A corrected entry is retitled like any live one",
    },
    {"path": TWO, "activities": ["work-scoping", "model-routing"]},
]


@pytest.fixture
def store(tmp_path):
    kdir = tmp_path / "store"
    for rel, text in ORIGINAL.items():
        path = kdir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    (kdir / "preferences" / "README.md").write_text("# Preferences\nWhat the category holds.\n")
    (kdir / "conventions").mkdir()
    (kdir / "conventions" / "x.md").write_text(entry_text("A convention", "Not a preference."))
    return kdir


def write_map(tmp_path, rows, name="map.json"):
    path = tmp_path / name
    path.write_text(json.dumps({"entries": rows}, indent=2), encoding="utf-8")
    return path


def run(kdir, *args):
    return subprocess.run(
        [sys.executable, CLI, str(kdir), *[str(a) for a in args]],
        capture_output=True, text=True, timeout=60,
    )


def digest(kdir):
    out = {}
    for root, _dirs, files in os.walk(kdir):
        for name in files:
            path = os.path.join(root, name)
            with open(path, "rb") as handle:
                out[os.path.relpath(path, kdir)] = hashlib.sha256(handle.read()).hexdigest()
    return out


def read(kdir, rel):
    return (kdir / rel).read_text(encoding="utf-8")


def test_dry_run_reports_each_change_and_writes_nothing(store, tmp_path):
    before = digest(store)
    result = run(store, "--map", write_map(tmp_path, MAP_ROWS))
    assert result.returncode == 0, result.stderr
    assert digest(store) == before
    out = result.stdout
    assert f"{CUT}: would change" in out
    assert "  title:    Before Any Edit To The Coordinate Skill Lands," in out
    assert "         -> Edits to the coordinate skill are read against lore's purpose before they land" in out
    assert "  activity: protocol-prose" in out
    assert f"{PLAIN}: would change\n  activity: pr-bodies" in out
    assert f"{TAGGED}: unchanged (activity: coordination)" in out
    assert f"{TWO}: unchanged (activity: work-scoping, model-routing)" in out
    assert "6 entries in the map: 4 would change (3 titles, 4 activity fields), 2 unchanged." in out
    assert "No live preferences/ entry outside the map is left without an activity." in out
    assert "Dry run: nothing was written." in out


def test_apply_rewrites_h1_and_appends_activity_to_footer_end(store, tmp_path):
    result = run(store, "--map", write_map(tmp_path, MAP_ROWS), "--apply")
    assert result.returncode == 0, result.stderr
    assert f"{CUT}: changed" in result.stdout
    assert "Dry run" not in result.stdout

    expected_cut = ORIGINAL[CUT].replace(
        "# Before Any Edit To The Coordinate Skill Lands,",
        "# Edits to the coordinate skill are read against lore's purpose before they land",
    ).replace("status: current -->", "status: current | activity: protocol-prose -->")
    assert read(store, CUT) == expected_cut
    assert read(store, PLAIN) == ORIGINAL[PLAIN].replace(
        "status: current -->", "status: current | activity: pr-bodies -->"
    )
    assert read(store, INLINE) == ORIGINAL[INLINE].replace(
        "# Subagent spawns state their model", "# Agent spawns state their model explicitly"
    ).replace("status: current -->", "status: current | activity: model-routing -->")
    assert read(store, CORRECTED).endswith("status: corrected | activity: human-writing, protocol-prose -->\n")
    for rel in (TAGGED, TWO, RETIRED):
        assert read(store, rel) == ORIGINAL[rel]
    assert read(store, "conventions/x.md") == entry_text("A convention", "Not a preference.")


def test_applied_entries_read_back_through_the_activity_reader(store, tmp_path):
    assert run(store, "--map", write_map(tmp_path, MAP_ROWS), "--apply").returncode == 0
    groups = pk_activities.index(str(store))
    assert pk_activities.UNTAGGED not in groups
    titles = {e["path"]: e["title"] for e in pk_activities.live_entries(str(store))}
    assert titles[CUT] == "Edits to the coordinate skill are read against lore's purpose before they land"
    assert [e["path"] for e in groups["protocol-prose"]] == [CUT, CORRECTED]
    assert [e["path"] for e in groups["model-routing"]] == [INLINE, TWO]
    statuses = {e["path"]: e["status"] for e in pk_activities.live_entries(str(store))}
    assert statuses[CORRECTED] == "corrected"
    assert statuses[CUT] == "current"
    assert RETIRED not in statuses


def test_second_apply_changes_nothing(store, tmp_path):
    map_path = write_map(tmp_path, MAP_ROWS)
    assert run(store, "--map", map_path, "--apply").returncode == 0
    after_first = digest(store)
    again = run(store, "--map", map_path, "--apply")
    assert again.returncode == 0, again.stderr
    assert digest(store) == after_first
    assert "6 entries in the map: 0 changed (0 titles, 0 activity fields), 6 unchanged." in again.stdout
    assert ": changed" not in again.stdout


def test_apply_keeps_file_mode(store, tmp_path):
    os.chmod(store / PLAIN, 0o640)
    assert run(store, "--map", write_map(tmp_path, MAP_ROWS), "--apply").returncode == 0
    assert stat.S_IMODE(os.stat(store / PLAIN).st_mode) == 0o640
    assert not [n for n in os.listdir(store / "preferences") if n.endswith(".tmp")]


def test_check_names_untagged_live_entries_and_passes_after_apply(store, tmp_path):
    before = run(store, "--check")
    assert before.returncode == 1
    assert "4 live preferences/ entries carry no activity:" in before.stdout
    for rel in (CUT, PLAIN, INLINE, CORRECTED):
        assert rel in before.stdout
    for rel in (TAGGED, TWO, RETIRED, "preferences/README.md"):
        assert rel not in before.stdout

    assert run(store, "--map", write_map(tmp_path, MAP_ROWS), "--apply").returncode == 0
    after = run(store, "--check")
    assert after.returncode == 0, after.stdout
    assert after.stdout.strip() == "All 6 live preferences/ entries carry an activity."


def test_map_that_misses_a_live_entry_fails_check(store, tmp_path):
    rows = [row for row in MAP_ROWS if row["path"] != PLAIN]
    applied = run(store, "--map", write_map(tmp_path, rows), "--apply")
    assert applied.returncode == 0, applied.stderr
    assert "the map does not name, which carry no activity (1):" in applied.stdout
    assert f"  {PLAIN}  PR bodies describe what shipped" in applied.stdout

    check = run(store, "--check")
    assert check.returncode == 1
    assert "1 live preferences/ entry carries no activity:" in check.stdout
    assert f"  {PLAIN}  PR bodies describe what shipped" in check.stdout


def test_existing_tag_in_another_order_is_not_a_conflict(store, tmp_path):
    rows = [{"path": TWO, "activities": ["model-routing", "work-scoping"]}]
    result = run(store, "--map", write_map(tmp_path, rows), "--apply")
    assert result.returncode == 0, result.stderr
    assert read(store, TWO) == ORIGINAL[TWO]


@pytest.mark.parametrize(
    "row, message",
    [
        ({"path": "preferences/no-such-entry.md", "activities": ["coordination"]},
         "preferences/no-such-entry.md: not a preferences/ entry in"),
        ({"path": "conventions/x.md", "activities": ["coordination"]},
         "conventions/x.md: not a preferences/ entry in"),
        ({"path": "preferences/README.md", "activities": ["coordination"]},
         "preferences/README.md: not a preferences/ entry in"),
        ({"path": "preferences/../conventions/x.md", "activities": ["coordination"]},
         "not a preferences/ entry in"),
        ({"path": RETIRED, "activities": ["model-routing"]},
         f"{RETIRED}: status is retired; only live entries are filed under an activity"),
        ({"path": PLAIN, "activities": ["PR-Bodies"]},
         f'{PLAIN}: activity name "PR-Bodies" is outside [a-z0-9-]+'),
        ({"path": PLAIN, "activities": ["pr_bodies"]},
         f'{PLAIN}: activity name "pr_bodies" is outside [a-z0-9-]+'),
        ({"path": PLAIN, "activities": ["pr-bodies", "shipping", "human-writing"]},
         f"{PLAIN}: 3 activities given; an entry takes at most 2"),
        ({"path": PLAIN, "activities": []}, f"{PLAIN}: no activities given"),
        ({"path": PLAIN, "activities": ["untagged"]}, f'{PLAIN}: "untagged" is reserved'),
        ({"path": PLAIN, "activities": ["pr-bodies", "pr-bodies"]}, f'{PLAIN}: activity "pr-bodies" is named twice'),
        ({"path": TAGGED, "activities": ["model-routing"]},
         f'{TAGGED}: already carries "activity: coordination"; the map gives "model-routing"'),
        ({"path": TWO, "activities": ["model-routing"]},
         f'{TWO}: already carries "activity: model-routing, work-scoping"; the map gives "model-routing"'),
        ({"path": PLAIN, "activities": ["pr-bodies"], "title": "Two\nlines"},
         f"{PLAIN}: title must be one non-empty line"),
        ({"path": PLAIN, "activities": ["pr-bodies"], "current_title": "Some other title",
          "title": "PR bodies are plain descriptions of what shipped"},
         f'{PLAIN}: H1 is "PR bodies describe what shipped", which matches neither'),
        ({"path": PLAIN, "activites": ["pr-bodies"]}, f"{PLAIN}: unknown map field(s) activites"),
    ],
)
def test_each_refusal_writes_nothing(store, tmp_path, row, message):
    before = digest(store)
    for flag in ([], ["--apply"]):
        result = run(store, "--map", write_map(tmp_path, [row]), *flag)
        assert result.returncode == 1, result.stdout
        assert message in result.stderr
        assert "nothing was written" in result.stderr
        assert digest(store) == before


def test_one_bad_row_stops_the_whole_map(store, tmp_path):
    before = digest(store)
    rows = MAP_ROWS + [{"path": "preferences/missing.md", "activities": ["coordination"]}]
    result = run(store, "--map", write_map(tmp_path, rows), "--apply")
    assert result.returncode == 1
    assert "1 problem in the map; nothing was written." in result.stderr
    assert digest(store) == before


def test_a_path_named_twice_is_refused(store, tmp_path):
    rows = [{"path": PLAIN, "activities": ["pr-bodies"]}, {"path": PLAIN, "activities": ["shipping"]}]
    result = run(store, "--map", write_map(tmp_path, rows), "--apply")
    assert result.returncode == 1
    assert f"refused: {PLAIN}: named more than once in the map" in result.stderr
    assert read(store, PLAIN) == ORIGINAL[PLAIN]


def test_all_problems_are_listed_together(store, tmp_path):
    rows = [
        {"path": PLAIN, "activities": ["Bad"]},
        {"path": TAGGED, "activities": ["pr-bodies"]},
    ]
    result = run(store, "--map", write_map(tmp_path, rows))
    assert result.returncode == 1
    assert result.stderr.count("refused: ") == 2
    assert "2 problems in the map; nothing was written." in result.stderr


def test_title_already_mapped_is_unchanged_even_with_stale_current_title(store, tmp_path):
    rows = [{"path": PLAIN, "activities": ["pr-bodies"], "current_title": "Whatever it was",
             "title": "PR bodies describe what shipped"}]
    result = run(store, "--map", write_map(tmp_path, rows), "--apply")
    assert result.returncode == 0, result.stderr
    assert read(store, PLAIN).startswith("# PR bodies describe what shipped\n")
    assert f"{PLAIN}: changed\n  activity: pr-bodies" in result.stdout


@pytest.mark.parametrize(
    "args, message",
    [
        (["--check", "--map", "m.json"], "--check reads only the store"),
        (["--check", "--apply"], "--check reads only the store"),
        ([], "--map is required unless --check is given"),
    ],
)
def test_usage_errors(store, args, message):
    result = run(store, *args)
    assert result.returncode == 2
    assert message in result.stderr


def test_missing_store_and_unreadable_map(store, tmp_path):
    missing = run(tmp_path / "nowhere", "--check")
    assert missing.returncode == 2
    assert "no knowledge store at" in missing.stderr

    bad = tmp_path / "bad.json"
    bad.write_text("{not json")
    result = run(store, "--map", bad)
    assert result.returncode == 2
    assert "is not valid JSON" in result.stderr

    wrong = tmp_path / "wrong.json"
    wrong.write_text(json.dumps([{"path": PLAIN}]))
    result = run(store, "--map", wrong)
    assert result.returncode == 2
    assert 'must be a JSON object with an "entries" list' in result.stderr
