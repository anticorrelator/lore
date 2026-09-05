"""Sentinel tests for /memory skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "memory"


@pytest.fixture(scope="module")
def memory() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Command surface
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("command", ["search", "curate", "heal", "add", "view", "init"])
def test_command_documented(command: str) -> None:
    """Each /memory subcommand must be documented with its own subsection."""
    text = read_skill(SKILL)
    hits = find_invocation(text, f"`{command}")
    assert len(hits) >= 1, (
        f"/memory {command} subcommand not documented in memory/SKILL.md"
    )


# ---------------------------------------------------------------------------
# Required CLI invocations
# ---------------------------------------------------------------------------

def test_lore_search_invoked(memory: str) -> None:
    """`lore search` must be referenced in the search command section."""
    body = extract_section(memory, "`search <query>`")
    assert "lore search" in body, "lore search not in search subcommand section"


def test_lore_curate_invoked(memory: str) -> None:
    """`lore curate` must be referenced in the curate command section."""
    body = extract_section(memory, "`curate`")
    assert "lore curate" in body, "lore curate not in curate subcommand section"


def test_lore_heal_invoked(memory: str) -> None:
    """`lore heal` must be referenced in the heal command section."""
    body = extract_section(memory, "`heal`")
    assert "lore heal" in body, "lore heal not in heal subcommand section"


def test_renormalize_redirects(memory: str) -> None:
    """`/memory renormalize` must redirect to /renormalize skill."""
    body = extract_section(memory, "`renormalize`")
    assert "/renormalize" in body, (
        "/memory renormalize must redirect to /renormalize skill"
    )
