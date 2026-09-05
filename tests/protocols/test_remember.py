"""Sentinel tests for /remember skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation, in_code_context

SKILL = "remember"


@pytest.fixture(scope="module")
def remember() -> str:
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
])
def test_step_present(step_label: str) -> None:
    """Steps 1–5 must each be present as a heading."""
    text = read_skill(SKILL)
    hits = find_invocation(text, f"### {step_label}:")
    assert len(hits) >= 1, f"'{step_label}' heading not found in remember/SKILL.md"


# ---------------------------------------------------------------------------
# Required invocations
# ---------------------------------------------------------------------------

def test_lore_capture_invoked(remember: str) -> None:
    """lore capture must be referenced (primary capture mechanism)."""
    hits = find_invocation(remember, "lore capture")
    assert len(hits) >= 1


def test_pending_captures_handler_referenced(remember: str) -> None:
    """Post-rewrite: remember must reference the _pending_captures session-start handler."""
    hits = find_invocation(remember, "_pending_captures")
    assert len(hits) >= 1, (
        "_pending_captures not referenced in remember — "
        "session-start pending-capture review is a load-bearing handler"
    )


# ---------------------------------------------------------------------------
# Post-rewrite targets (xfail until remember-rewrite-with-claude-md)
# ---------------------------------------------------------------------------

def test_tier3_emission_uses_lore_promote(remember: str) -> None:
    """Post-rewrite: Tier 3 knowledge captures must use `lore promote`, not `lore capture`."""
    hits = find_invocation(remember, "lore promote")
    assert len(hits) >= 1, (
        "lore promote not found in remember — "
        "Tier 3 emission must route through lore promote after rewrite"
    )


def test_lore_capture_in_step5(remember: str) -> None:
    """Step 5 (Act) must instruct lore capture."""
    body = extract_section(remember, "Step 5: Act")
    assert "lore capture" in body


# ---------------------------------------------------------------------------
# Canonical capture-gate bodies (Step 2)
# ---------------------------------------------------------------------------

def test_4_condition_gate_canonical_body_in_step2(remember: str) -> None:
    """Step 2 must define the 4-condition gate with the exact criteria list.

    Sentinel #1 — the 4-condition gate canonical body lives in remember/SKILL.md
    Step 2 (lines 143-147). The phrase 'all 4 conditions must be true' plus the
    four labeled criteria (Reusable, Non-obvious, Stable, High confidence) are
    the load-bearing canonical body that consumers (self-test, CLAUDE.md, etc.)
    reference by name.
    """
    body = extract_section(remember, "Step 2: Evaluate against capture gate")
    if not body:
        # Fall back to whole-skill search if heading text drifts slightly
        body = remember
    assert "all 4 conditions must be true" in body, (
        "remember Step 2 must state 'all 4 conditions must be true' verbatim — "
        "the canonical body is what consumer references like self-test point to"
    )
    for criterion in ["Reusable", "Non-obvious", "Stable", "High confidence"]:
        assert criterion in body, (
            f"4-condition gate criterion '{criterion}' missing from remember Step 2 — "
            "all four labeled criteria are load-bearing"
        )


def test_orientation_gate_five_conditions_in_step2(remember: str) -> None:
    """Step 2 must define the orientation gate with all 5 body tokens.

    Sentinel #2 — orientation gate body lives in remember/SKILL.md Step 2
    (lines 153-158). Assert the body content tokens (Cross-boundary, Canonical,
    Anchored, --related-files, 'Stable at architecture or subsystem altitude')
    not the verbatim header phrases. The orientation gate is the parallel path
    to the 4-condition gate for system-map captures.
    """
    body = extract_section(remember, "Step 2: Evaluate against capture gate")
    if not body:
        body = remember
    assert "Orientation gate" in body, (
        "Orientation gate heading missing from remember Step 2 — "
        "the parallel-path gate is load-bearing for system-map captures"
    )
    assert "all 5 conditions must be true" in body, (
        "Orientation gate must state 'all 5 conditions must be true' verbatim"
    )
    for token in ["Cross-boundary", "Canonical", "Anchored", "--related-files"]:
        assert token in body, (
            f"Orientation gate body token '{token}' missing from remember Step 2"
        )
    assert "Stable at architecture or subsystem altitude" in body, (
        "Orientation gate altitude constraint 'Stable at architecture or subsystem "
        "altitude' missing from remember Step 2 — implementation-scale orientation "
        "is the failure mode this token names"
    )
