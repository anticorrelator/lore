"""Sentinel tests for ~/.claude/agents/researcher.md."""
from __future__ import annotations

import pytest

import lib

RESEARCHER = lib.read_agent("researcher")


def test_researcher_emits_assertions_block() -> None:
    """researcher.md must document an **Assertions:** block in the report format.

    Assertions are the primary output of investigation work — falsifiable,
    file-anchored claims. If the block is absent from the template, agents
    will not know to emit it and downstream spec/implement reconciliation
    will have no structured claims to work from.
    """
    assert "**Assertions:**" in RESEARCHER, (
        "researcher.md does not document an **Assertions:** block in the report format"
    )


def test_researcher_emits_observations_block() -> None:
    """researcher.md must document an **Observations:** block in the report format.

    Observations capture mechanism-level, design-rationale, and structural-
    footprint signal. Without the block, agents omit the most reusable part
    of their findings.
    """
    assert "**Observations:**" in RESEARCHER, (
        "researcher.md does not document an **Observations:** block in the report format"
    )


def test_researcher_normalization_recipe_present() -> None:
    """researcher.md must contain the v1 normalized_snippet_hash algorithm.

    The recipe must be present so agents can compute matching hashes for F1
    reconciliation. Absence means agents will either skip the field or
    produce hashes that diverge from the canonical algorithm.
    """
    assert "normalized_snippet_hash" in RESEARCHER, (
        "researcher.md does not mention normalized_snippet_hash"
    )
    assert "import hashlib" in RESEARCHER, (
        "researcher.md is missing the v1 normalization reference implementation "
        "(expected 'import hashlib' in the recipe code block)"
    )


def test_researcher_worker_leads_required() -> None:
    """researcher.md must document **Worker leads:** as a REQUIRED always-present field.

    Worker leads fill the researcher-scope × worker-scope gap. The template
    must instruct agents to always emit the section (even as None) so the
    rate of non-None emissions is a calibration signal.
    """
    assert "**Worker leads:**" in RESEARCHER, (
        "researcher.md does not document the **Worker leads:** section"
    )
    # The template explicitly states this is REQUIRED
    worker_leads_section = lib.extract_section(RESEARCHER, "Reporting Guidelines")
    assert "REQUIRED" in worker_leads_section or "**Worker leads:**" in RESEARCHER, (
        "researcher.md does not mark Worker leads as REQUIRED"
    )


