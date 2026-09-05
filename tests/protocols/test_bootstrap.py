"""Sentinel tests for /bootstrap skill.

Key invariant (D1): bootstrap is the fast-path commons writer.
Only the lead may call lore capture — explorer agents must NOT call it directly.
"""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation, in_code_context

SKILL = "bootstrap"


@pytest.fixture(scope="module")
def bootstrap() -> str:
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
])
def test_step_present(step_label: str) -> None:
    """Steps 1–8 must each appear as headings in bootstrap/SKILL.md."""
    text = read_skill(SKILL)
    hits = find_invocation(text, f"### {step_label}:")
    assert len(hits) >= 1, f"'{step_label}' heading not found in bootstrap/SKILL.md"


# ---------------------------------------------------------------------------
# D1 invariant: lead files via lore capture; explorers do NOT
# ---------------------------------------------------------------------------

def test_lead_invokes_lore_capture(bootstrap: str) -> None:
    """The bootstrap lead must invoke lore capture (fast-path commons writer per D1)."""
    hits = find_invocation(bootstrap, "lore capture")
    assert len(hits) >= 1, (
        "lore capture not referenced in bootstrap — "
        "the lead is responsible for all knowledge filing (D1 fast-path commons writer)"
    )




def test_synthesis_step_present(bootstrap: str) -> None:
    """Step 5 Synthesis must exist (where lead consolidates findings before filing)."""
    body = extract_section(bootstrap, "Step 5: Synthesize")
    assert len(body) > 50, "Step 5 Synthesis section too short or missing"


def test_confidence_medium_source_bootstrap(bootstrap: str) -> None:
    """Entries must be filed at confidence: medium with source: bootstrap."""
    hits_conf = find_invocation(bootstrap, "confidence: medium")
    hits_src = find_invocation(bootstrap, "source: bootstrap")
    assert len(hits_conf) >= 1, "confidence: medium not specified for bootstrap entries"
    assert len(hits_src) >= 1, "source: bootstrap not specified for bootstrap entries"
