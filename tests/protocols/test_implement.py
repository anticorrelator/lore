"""Sentinel tests for /implement skill."""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "implement"

# Canonical section headings produced by the implement-rewrite (D10). Tests
# below assert load-bearing content under each heading. If worker-3 renames a
# heading, update the constant here in one place.
STEP_1_HEADING = "Step 1: Load work item and validate"
STEP_3_HEADING = "Step 3: Spawn agents"
STEP_4_HEADING = "Step 4: Collect progress"
STEP_5_HEADING = "Step 5: Promote accepted Tier 3 candidates"


@pytest.fixture(scope="module")
def impl() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Stage presence (Steps 1–7)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("step_label", [
    "Step 1",
    "Step 2",
    "Step 3",
    "Step 4",
    "Step 5",
    "Step 6",
])
def test_step_present(step_label: str) -> None:
    """Each of Steps 1–7 must appear as a heading in implement/SKILL.md."""
    impl = read_skill(SKILL)
    hits = find_invocation(impl, f"### {step_label}:")
    assert len(hits) >= 1, f"'{step_label}' heading not found in implement/SKILL.md"


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
# Anchor-coverage gate (Step 1.5b) and lead-inline gate (Step 3.0)
# ---------------------------------------------------------------------------







def test_step_6_capability_anchor_reconciliation(impl: str) -> None:
    """Step 6 must declare the trichotomous full|partial|none verdict shape.

    Sentinel #10 — implement/SKILL.md Step 6 (line 724) names the
    capability-anchor reconciliation gate with the trichotomous verdict
    `full | partial | none`, and Step 6.2 requires `capability_loop_summary`
    on full and partial. Both anchors are load-bearing for closure-laundering
    prevention.
    """
    assert "### Step 6:" in impl, "Step 6 heading missing from implement/SKILL.md"

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
