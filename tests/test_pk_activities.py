"""Tests for pk_activities.py — the activity axis over preferences/."""

import json
import os
import subprocess
import sys

import pytest

SCRIPTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")
sys.path.insert(0, SCRIPTS)

import pk_activities  # noqa: E402
from pk_activities import (  # noqa: E402
    ActivityError,
    UnknownActivity,
    block,
    canonical,
    check,
    entries,
    index,
    starts,
)
from pk_markdown import MarkdownParser  # noqa: E402

CLI = os.path.join(SCRIPTS, "pk_activities.py")


def write_entry(kdir, rel, title, body, activity=None, status="current", learned="2026-10-01"):
    fields = [f"learned: {learned}", "confidence: high", "scale: subsystem", "kind: fact"]
    if activity is not None:
        fields.append(f"activity: {activity}")
    if status is not None:
        fields.append(f"status: {status}")
    path = kdir / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"# {title}\n{body}\n<!-- {' | '.join(fields)} -->\n", encoding="utf-8")
    return path


@pytest.fixture
def store(tmp_path):
    kdir = tmp_path / "store"
    (kdir / "preferences").mkdir(parents=True)
    (kdir / "_manifest.json").write_text("{}\n")
    write_entry(kdir, "preferences/b-pr-bodies-plain.md", "PR bodies describe what shipped",
                "No chronology in a PR body.\n\nThe notes hold the history.", activity="pr-bodies")
    write_entry(kdir, "preferences/a-routing.md", "Every role routes to one model",
                "Routing is uniform for now.", activity="model-routing, coordination")
    write_entry(kdir, "preferences/c-cost.md", "Arcs price themselves before running",
                "Coordinators surface projected spend.", activity="coordination")
    write_entry(kdir, "preferences/d-untagged.md", "An entry filed before activities",
                "Still live, carries no activity.")
    write_entry(kdir, "preferences/e-no-status.md", "An entry with no status field",
                "Absent status reads as current.", activity="pr-bodies", status=None)
    write_entry(kdir, "preferences/f-corrected.md", "A corrected entry stays live",
                "Corrected is a live status.", activity="pr-bodies", status="corrected")
    write_entry(kdir, "preferences/g-retired.md", "A retired entry is not in force",
                "Retired entries never list.", activity="retired-only", status="retired")
    write_entry(kdir, "preferences/_draft.md", "An underscore draft", "Skipped.", activity="drafts")
    (kdir / "preferences" / "README.md").write_text("# preferences/\nLists pr-bodies and coordination.\n")
    write_entry(kdir, "conventions/not-a-preference.md", "A convention", "Not listed.", activity="coordination")
    return kdir


# --- canonical ---------------------------------------------------------------

@pytest.mark.parametrize("raw, folded", [
    ("coordination", "coordination"),
    ("Model Routing", "model-routing"),
    ("  pr-bodies  ", "pr-bodies"),
    ("Review   Comments", "review-comments"),
    ("pass2", "pass2"),
])
def test_canonical_folds_case_and_whitespace(raw, folded):
    assert canonical(raw) == folded


@pytest.mark.parametrize("raw", ["", "   ", "commit_messages", "pr|bodies", "a>b", "a,b", "café"])
def test_canonical_refuses_names_outside_the_alphabet(raw):
    with pytest.raises(ActivityError):
        canonical(raw)


# --- index / entries ---------------------------------------------------------

def test_index_groups_live_entries_by_activity(store):
    groups = index(str(store))
    assert list(groups) == ["coordination", "general", "model-routing", "pr-bodies", "untagged"]
    paths = {name: [e["path"] for e in group] for name, group in groups.items()}
    assert paths["coordination"] == ["preferences/a-routing.md", "preferences/c-cost.md"]
    assert paths["model-routing"] == ["preferences/a-routing.md"]
    assert paths["pr-bodies"] == [
        "preferences/b-pr-bodies-plain.md",
        "preferences/e-no-status.md",
        "preferences/f-corrected.md",
    ]
    assert paths["untagged"] == ["preferences/d-untagged.md"]
    assert paths["general"] == []


def test_index_skips_readme_underscore_retired_and_other_categories(store):
    listed = {e["path"] for group in index(str(store)).values() for e in group}
    assert "preferences/README.md" not in listed
    assert "preferences/_draft.md" not in listed
    assert "preferences/g-retired.md" not in listed
    assert not any(p.startswith("conventions/") for p in listed)
    assert "drafts" not in index(str(store))
    assert "retired-only" not in index(str(store))


def test_general_is_present_in_an_empty_store(tmp_path):
    assert index(str(tmp_path)) == {"general": []}
    (tmp_path / "preferences").mkdir()
    assert index(str(tmp_path)) == {"general": []}


def test_untagged_is_absent_when_every_live_entry_is_tagged(tmp_path):
    write_entry(tmp_path, "preferences/x.md", "X", "x", activity="general")
    assert list(index(str(tmp_path))) == ["general"]


def test_entry_shape_and_body(store):
    (entry,) = [e for e in entries(str(store), "pr-bodies") if e["path"].endswith("b-pr-bodies-plain.md")]
    assert set(entry) == {"path", "title", "body", "activities", "learned", "status"}
    assert entry["title"] == "PR bodies describe what shipped"
    assert entry["body"] == "No chronology in a PR body.\n\nThe notes hold the history."
    assert entry["activities"] == ["pr-bodies"]
    assert entry["learned"] == "2026-10-01"
    assert entry["status"] == "current"


def test_entry_without_status_reads_as_current(store):
    (entry,) = [e for e in entries(str(store), "pr-bodies") if e["path"].endswith("e-no-status.md")]
    assert entry["status"] == "current"


def test_two_activities_split_on_comma(store):
    (entry,) = entries(str(store), "model-routing")
    assert entry["activities"] == ["model-routing", "coordination"]


def test_entries_folds_the_requested_name(store):
    assert [e["path"] for e in entries(str(store), "Model Routing")] == ["preferences/a-routing.md"]


def test_entries_for_general_is_empty_not_unknown(store):
    assert entries(str(store), "general") == []


@pytest.mark.parametrize("name", ["commit-messages", "retired-only", "not_valid"])
def test_entries_unknown_name_names_the_known_ones(store, name):
    with pytest.raises(UnknownActivity) as exc:
        entries(str(store), name)
    assert exc.value.known == ["coordination", "general", "model-routing", "pr-bodies", "untagged"]
    assert "coordination, general, model-routing, pr-bodies, untagged" in str(exc.value)


def test_footer_value_with_bad_name_lands_under_untagged(tmp_path):
    write_entry(tmp_path, "preferences/x.md", "X", "x", activity="Not_Valid")
    groups = index(str(tmp_path))
    assert [e["path"] for e in groups["untagged"]] == ["preferences/x.md"]


def test_footer_value_is_folded_on_read(tmp_path):
    write_entry(tmp_path, "preferences/x.md", "X", "x", activity="Model Routing")
    assert [e["path"] for e in index(str(tmp_path))["model-routing"]] == ["preferences/x.md"]


# --- STARTS / starts ---------------------------------------------------------

def test_starts_table_is_seeded():
    assert starts("arc open") == ["coordination", "model-routing"]
    assert starts("arc close") == ["human-writing"]
    assert starts("spec start") == ["work-scoping"]
    assert starts("impl start") == ["model-routing"]
    assert starts("capture --category preferences") == ["preference-writing"]
    assert starts("/pr-create") == ["pr-bodies", "shipping", "human-writing"]
    assert starts("/pr-review") == ["review-comments"]
    assert starts("/evolve") == ["protocol-prose"]
    assert starts("/remember") == ["preference-writing"]


def test_starts_unknown_command_is_empty():
    assert starts("lore nothing") == []


def test_starts_returns_a_copy():
    starts("arc open").append("x")
    assert starts("arc open") == ["coordination", "model-routing"]


def test_starts_names_are_canonical():
    for names in pk_activities.STARTS.values():
        assert all(canonical(n) == n for n in names)


# --- block -------------------------------------------------------------------

def test_block_renders_full_text(store):
    assert block(str(store), ["pr-bodies"]) == (
        "Preferences for pr-bodies (3):\n"
        "- PR bodies describe what shipped\n"
        "  No chronology in a PR body.\n"
        "\n"
        "  The notes hold the history.\n"
        "- An entry with no status field\n"
        "  Absent status reads as current.\n"
        "- A corrected entry stays live\n"
        "  Corrected is a live status.\n"
        "Full set: lore search --preferences --activity pr-bodies\n"
    )


def test_block_for_an_activity_with_no_entries(store):
    assert block(str(store), ["general"]) == "Preferences for general: none filed.\n"
    assert block(str(store), ["shipping"]) == "Preferences for shipping: none filed.\n"


def test_block_separates_activities_and_keeps_their_order(store):
    text = block(str(store), ["shipping", "model-routing", "shipping"])
    assert text == (
        "Preferences for shipping: none filed.\n"
        "\n"
        "Preferences for model-routing (1):\n"
        "- Every role routes to one model\n"
        "  Routing is uniform for now.\n"
        "Full set: lore search --preferences --activity model-routing\n"
    )


def test_block_refuses_an_invalid_name(store):
    with pytest.raises(ActivityError):
        block(str(store), ["not valid!"])


# --- check -------------------------------------------------------------------

def test_check_requires_a_value_and_lists_existing(store):
    for value in (None, "", " , "):
        with pytest.raises(ActivityError) as exc:
            check(str(store), value)
        assert str(exc.value) == (
            "--activity is required for --category preferences; "
            "existing: coordination, general, model-routing, pr-bodies"
        )


def test_check_refuses_unknown_without_new_activity(store):
    with pytest.raises(ActivityError) as exc:
        check(str(store), "commit-msg")
    assert str(exc.value) == (
        '--activity "commit-msg" is not an existing activity '
        "(existing: coordination, general, model-routing, pr-bodies); "
        "pass --new-activity to create it"
    )


def test_check_admits_known_and_folded_names(store):
    assert check(str(store), "Model Routing") == ["model-routing"]
    assert check(str(store), "pr-bodies, coordination") == ["pr-bodies", "coordination"]
    assert check(str(store), "general") == ["general"]


def test_check_admits_new_names_with_new_activity(store):
    assert check(str(store), "commit-messages", allow_new=True) == ["commit-messages"]
    assert check(str(store), "commit-messages,pr-bodies", allow_new=True) == ["commit-messages", "pr-bodies"]


@pytest.mark.parametrize("value, fragment", [
    ("a,b,c", "at most 2 names"),
    ("pr-bodies, pr-bodies", "must be distinct"),
    ("Pr Bodies,pr-bodies", "must be distinct"),
    ("untagged", "reserved"),
    ("commit_msg", "not a valid activity name"),
])
def test_check_refusals(store, value, fragment):
    with pytest.raises(ActivityError) as exc:
        check(str(store), value, allow_new=True)
    assert fragment in str(exc.value)


def test_retired_names_are_not_in_the_vocabulary(store):
    with pytest.raises(ActivityError):
        check(str(store), "retired-only")


# --- footer parser -----------------------------------------------------------

def test_extract_metadata_returns_activity_raw():
    meta = MarkdownParser._extract_metadata(
        "<!-- learned: 2026-10-01 | activity: coordination, model-routing | status: current -->"
    )
    assert meta["activity"] == "coordination, model-routing"
    assert meta["entry_status"] == "current"
    assert MarkdownParser._extract_metadata("<!-- learned: 2026-10-01 -->")["activity"] is None
    assert MarkdownParser._extract_metadata("# no footer")["activity"] is None


# --- CLI ---------------------------------------------------------------------

def run_cli(kdir, *args):
    return subprocess.run(
        [sys.executable, CLI, "--kdir", str(kdir), *args],
        capture_output=True, text=True, timeout=60,
    )


def test_cli_index(store):
    r = run_cli(store, "index")
    assert r.returncode == 0
    assert r.stdout == "coordination (2)\ngeneral (0)\nmodel-routing (1)\npr-bodies (3)\nuntagged (1)\n"
    r = run_cli(store, "index", "--json")
    rows = json.loads(r.stdout)["activities"]
    assert [(row["name"], row["count"]) for row in rows] == [
        ("coordination", 2), ("general", 0), ("model-routing", 1), ("pr-bodies", 3), ("untagged", 1),
    ]
    assert rows[2]["entries"] == [{"path": "preferences/a-routing.md", "title": "Every role routes to one model"}]


def test_cli_entries_and_unknown(store):
    r = run_cli(store, "entries", "model-routing")
    assert r.returncode == 0
    assert r.stdout == (
        "# Every role routes to one model\n"
        "Routing is uniform for now.\n"
        "path: preferences/a-routing.md\n"
        "\n"
        "Preferences for model-routing: 1 entry.\n"
    )
    r = run_cli(store, "entries", "pr-bodies", "--json")
    payload = json.loads(r.stdout)
    assert payload["activity"] == "pr-bodies" and payload["count"] == 3
    r = run_cli(store, "entries", "nope")
    assert r.returncode == 1
    assert r.stdout == ""
    assert "coordination, general, model-routing, pr-bodies, untagged" in r.stderr


def test_cli_starts_block_check(store):
    assert run_cli(store, "starts", "arc", "open").stdout == "coordination\nmodel-routing\n"
    assert json.loads(run_cli(store, "starts", "/pr-review", "--json").stdout) == ["review-comments"]
    r = run_cli(store, "block", "general", "model-routing")
    assert r.stdout == block(str(store), ["general", "model-routing"])
    r = run_cli(store, "check", "Model Routing, pr-bodies")
    assert (r.returncode, r.stdout) == (0, "model-routing, pr-bodies\n")
    r = run_cli(store, "check", "commit-msg")
    assert r.returncode == 1
    assert "pass --new-activity to create it" in r.stderr
    r = run_cli(store, "check", "--new-activity", "commit-msg")
    assert (r.returncode, r.stdout) == (0, "commit-msg\n")
