"""Sentinel tests for /evolve skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "evolve"


@pytest.fixture(scope="module")
def evolve() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Stage presence
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("step_label", [
    "Step 1",
    "Step 2",
    "Step 3",
    "Step 4",
    "Step 5",
    "Step 6",
    "Step 7",
    "Step 8",
    "Step 9",
])
def test_step_present(step_label: str) -> None:
    """Steps 1–9 must each appear as headings in evolve/SKILL.md (any heading level)."""
    text = read_skill(SKILL)
    # Accept any heading level (##, ###, ####) — header nesting is presentation, not contract
    hits = find_invocation(text, f"## {step_label}:") + find_invocation(text, f"### {step_label}:")
    assert len(hits) >= 1, f"'{step_label}' heading not found in evolve/SKILL.md"


# ---------------------------------------------------------------------------
# Required behaviors
# ---------------------------------------------------------------------------

def test_reads_retro_evolution_suggestions(evolve: str) -> None:
    """evolve must read retro-evolution journal entries as input."""
    hits = find_invocation(evolve, "retro-evolution")
    assert len(hits) >= 1, (
        "retro-evolution not referenced — evolve must consume retro's evolution output"
    )




def test_template_registry_registration(evolve: str) -> None:
    """template-registry must be referenced (scorecard citation gate)."""
    hits = find_invocation(evolve, "template-registry")
    assert len(hits) >= 1, (
        "template-registry not referenced in evolve — "
        "scorecard citation gate depends on template registry lookup"
    )






# ---------------------------------------------------------------------------
# Phase 4 / D9: Step 7.5 sequencing and evidence-class matrix
# ---------------------------------------------------------------------------





