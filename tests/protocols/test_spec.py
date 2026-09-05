"""Sentinel tests for /spec skill.

Tests assert the skeleton-level structure of spec/SKILL.md.
"""
from __future__ import annotations

import pytest
from lib import read_skill, extract_section, find_invocation

SKILL = "spec"


@pytest.fixture(scope="module")
def spec() -> str:
    return read_skill(SKILL)


# ---------------------------------------------------------------------------
# Stage presence
# ---------------------------------------------------------------------------

def test_short_flow_section_present(spec: str) -> None:
    """Short Flow section must exist (single-agent path)."""
    body = extract_section(spec, "Short Flow (`/spec short`)")
    assert len(body) > 50


def test_full_flow_section_present(spec: str) -> None:
    """Full Flow section must exist (team investigation path)."""
    body = extract_section(spec, "Full Flow (`/spec`)")
    assert len(body) > 50


def test_synthesis_step_present(spec: str) -> None:
    """Synthesis step must be present in the full flow."""
    hits = find_invocation(spec, "Synthesize")
    assert any("Step 5" in line for _, line in hits), (
        "Expected 'Step 5: Synthesize' or similar — synthesis stage missing"
    )


def test_design_decisions_produced(spec: str) -> None:
    """Design Decisions section must be instructed in the plan output."""
    hits = find_invocation(spec, "Design Decisions")
    assert len(hits) >= 2, "Expected multiple references to 'Design Decisions' in spec"


# ---------------------------------------------------------------------------
# Forbidden / deprecated patterns (enforced post-spec-rewrite)
# ---------------------------------------------------------------------------

def test_step_4b_verifier_verdict_forbidden(spec: str) -> None:
    """Post-rewrite: Step 4b (verifier-verdict) must not appear in the rewritten skill."""
    hits = find_invocation(spec, "verifier-verdict")
    assert hits == [], (
        f"Found {len(hits)} reference(s) to 'verifier-verdict' — "
        "this stage is forbidden after spec-rewrite"
    )


def test_key_assertions_section_forbidden(spec: str) -> None:
    """Post-rewrite: ### Key Assertions must not appear in the rewritten skill."""
    hits = find_invocation(spec, "Key Assertions")
    assert hits == [], (
        f"Found {len(hits)} reference(s) to 'Key Assertions' — "
        "this section is forbidden after spec-rewrite"
    )


# ---------------------------------------------------------------------------
# Post-rewrite structural invariants (spec-rewrite Phase 2)
# ---------------------------------------------------------------------------

def test_without_verification_flag_absent(spec: str) -> None:
    """Post-rewrite: --without-verification must not appear anywhere in the skill."""
    hits = find_invocation(spec, "--without-verification")
    assert hits == [], (
        f"Found {len(hits)} reference(s) to '--without-verification' — "
        "this flag is retired after spec-rewrite"
    )




def test_plan_template_investigations_no_assertions(spec: str) -> None:
    """Post-rewrite: the Plan.md Template's ## Investigations section must not contain **Assertions:**."""
    from lib import extract_embedded_template

    # Pull fenced blocks whose opening line references a Plan.md template
    templates = extract_embedded_template(spec, r"[Pp]lan")
    if not templates:
        # No embedded Plan.md template found — pass vacuously (template may be inline prose)
        return

    for block in templates:
        investigations = extract_section(block, "Investigations")
        if not investigations:
            continue
        lines = investigations.splitlines()
        assertion_lines = [ln for ln in lines if "**Assertions:**" in ln]
        assert assertion_lines == [], (
            f"Plan.md Template ## Investigations contains {len(assertion_lines)} "
            "'**Assertions:**' line(s) — Assertions must not appear in Tier-1 Investigations"
        )


# ---------------------------------------------------------------------------
# Required CLI invocations
# ---------------------------------------------------------------------------

def test_lore_resolve_invoked(spec: str) -> None:
    """lore resolve must appear (path bootstrap step)."""
    hits = find_invocation(spec, "lore resolve")
    assert len(hits) >= 1


def test_investigation_plan_section_present(spec: str) -> None:
    """Full flow must include an Investigation Plan table section."""
    hits = find_invocation(spec, "Investigation Plan")
    assert len(hits) >= 1


# ---------------------------------------------------------------------------
# Capability / intent-anchor preservation discipline
# ---------------------------------------------------------------------------

def test_intent_anchor_preserved_verbatim_for_downstream(spec: str) -> None:
    """spec must require verbatim preservation of intent_anchor.

    Sentinel concept #4 (spec side) — spec/SKILL.md (line 69) instructs the
    spec to 'preserve the wording verbatim when restating it' and names the
    downstream consumers (Step 5.5 verifier, /implement anchor prompts) that
    detect drift by string comparison. The verbatim-preservation discipline
    is the load-bearing contract for the cross-skill audit chain.
    """
    assert "intent_anchor" in spec, (
        "intent_anchor not referenced in spec/SKILL.md — "
        "the capability anchor is the cross-skill audit chain's anchor field"
    )

    # The plan-section schema instruction must name `## Intent Anchor` as the
    # section that renders the anchor body verbatim from _meta.json.intent_anchor.
    intent_anchor_section_hits = find_invocation(spec, "## Intent Anchor")
    assert len(intent_anchor_section_hits) >= 1, (
        "spec must document the `## Intent Anchor` plan.md section — "
        "the section name is what the Step 5.5 verifier reads"
    )

    # The verbatim-preservation discipline must be stated explicitly so that
    # paraphrase by spec authors breaks the downstream string-comparison audit.
    verbatim_hits = find_invocation(spec, "verbatim")
    assert len(verbatim_hits) >= 3, (
        "spec must instruct verbatim preservation in multiple places "
        "(intake restatement, plan.md anchor section, plan template) — "
        "found fewer 'verbatim' references than expected for downstream-audit support"
    )

    # The Scope delta line is the second verifier-enforced field
    scope_delta_hits = find_invocation(spec, "**Scope delta:**")
    assert len(scope_delta_hits) >= 1, (
        "`**Scope delta:**` line missing from spec/SKILL.md — "
        "this is the second verifier-enforced field alongside the anchor body"
    )
