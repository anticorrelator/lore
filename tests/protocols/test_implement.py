"""Sentinel tests for /implement skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "implement"

@pytest.fixture(scope="module")
def impl() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Required load-bearing instructions (preserved from pre-rewrite)
# ---------------------------------------------------------------------------







# ---------------------------------------------------------------------------
# D10 protocol tests — Tier 2/3 wiring in the rewritten SKILL.md
# ---------------------------------------------------------------------------
#
# Each test below pins a single load-bearing claim in the prose. Tests are
# named falsifiable claims about SKILL.md — the test name describes what the
# prose must document; the assertion falsifies the claim when prose drifts.







def test_tier2_tier3_emission_documented(impl: str) -> None:
    """Both Tier 2 emission (evidence-append.sh) and Tier 3 candidates
    (lore promote) must be documented in the skill prose. Per D10: the
    skill is the single source of truth for the implement-side tier
    contract — worker.md and the TaskCompleted hook are downstream of it."""
    tier2_hits = find_invocation(impl, "Tier 2")
    tier3_hits = find_invocation(impl, "Tier 3")
    assert len(tier2_hits) >= 1, (
        "Tier 2 emission not documented in implement/SKILL.md"
    )
    assert len(tier3_hits) >= 1, (
        "Tier 3 candidates not documented in implement/SKILL.md"
    )
    # Both sides of the contract — write path + promote path — must appear.
    assert "evidence-append.sh" in impl, (
        "Tier 2 write path (evidence-append.sh) not documented"
    )
    assert "lore promote" in impl, (
        "Tier 3 promote path (lore promote) not documented"
    )






# ---------------------------------------------------------------------------
# Closure verdict
# ---------------------------------------------------------------------------







def test_step_6_capability_anchor_reconciliation(impl: str) -> None:
    """The closure verdict keeps its three-way shape and its summary field.

    `full | partial | none` is the vocabulary `lore impl close` validates, and
    `capability_loop_summary` is the one-line summary a full or partial verdict
    carries; both are load-bearing for the closure record.
    """
    # The trichotomous verdict pipe-string is the canonical shape signal
    trichotomous_hits = find_invocation(impl, "full | partial | none")
    assert len(trichotomous_hits) >= 1, (
        "Step 6 must reference the trichotomous verdict `full | partial | none` — "
        "this pipe-string is the canonical closure-time verdict shape"
    )

    # capability_loop_summary is the per-verdict attestation field
    summary_hits = find_invocation(impl, "capability_loop_summary")
    assert len(summary_hits) >= 1, (
        "`capability_loop_summary` not referenced in implement/SKILL.md — "
        "the one-line attestation is what prevents empty/silent `full` verdicts"
    )
