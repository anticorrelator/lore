"""Sentinel tests for /renormalize skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "renormalize"


@pytest.fixture(scope="module")
def renorm() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Stage presence
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("step_label", ["Step 1", "Step 2", "Step 3", "Step 4", "Step 5"])
def test_step_present(step_label: str) -> None:
    """Steps 1–5 must each appear as headings in renormalize/SKILL.md."""
    text = read_skill(SKILL)
    hits = find_invocation(text, f"### {step_label}:")
    assert len(hits) >= 1, f"'{step_label}' heading not found in renormalize/SKILL.md"


# ---------------------------------------------------------------------------
# Full-store renormalization operations
# ---------------------------------------------------------------------------

def test_prune_operation_documented(renorm: str) -> None:
    """Prune (stale + cold entries) must be documented in the planning step."""
    body = extract_section(renorm, "Step 4: Plan (lead synthesis)")
    assert "prune" in body.lower(), "prune operation not documented in planning step"


def test_dedupe_merge_documented(renorm: str) -> None:
    """Merge/deduplicate near-duplicate entries must be documented."""
    hits = find_invocation(renorm, "Merge")
    merge_hits = [(ln, line) for ln, line in hits if "list" in line.lower() or "near" in line.lower()]
    assert len(merge_hits) >= 1 or any("merge" in line.lower() for _, line in hits), (
        "Merge/deduplicate operation not documented in renormalize"
    )


def test_backlink_maintenance_documented(renorm: str) -> None:
    """Backlink maintenance must be in the renormalize plan."""
    hits = find_invocation(renorm, "Backlink")
    assert len(hits) >= 1, (
        "Backlink maintenance not documented — "
        "renormalize must maintain backlink relationships"
    )


def test_staleness_analysis_step(renorm: str) -> None:
    """Staleness analysis must be run in Step 2."""
    body = extract_section(renorm, "Step 1: Analyze (direct verbs)")
    assert "staleness" in body.lower(), "staleness analysis not in Step 2"
