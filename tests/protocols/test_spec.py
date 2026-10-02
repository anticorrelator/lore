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


def test_plan_template_investigations_no_assertions() -> None:
    """Post-rewrite: the Plan.md Template's ## Investigations section must not contain **Assertions:**."""
    from lib import SKILLS_DIR, extract_embedded_template

    templates = extract_embedded_template((SKILLS_DIR / SKILL / "templates/plan.md").read_text(), r"[Pp]lan")
    assert templates, "the plan template's fenced Plan.md block is missing"

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


# ---------------------------------------------------------------------------
# Capability / intent-anchor preservation discipline
# ---------------------------------------------------------------------------

def test_scope_delta_line_named_for_the_anchor_gate(spec: str) -> None:
    """The `**Scope delta:**` line is the field publication and the finalize gate verify beside the anchor body."""
    scope_delta_hits = find_invocation(spec, "**Scope delta:**")
    assert len(scope_delta_hits) >= 1, (
        "`**Scope delta:**` line missing from spec/SKILL.md — "
        "this is the second verifier-enforced field alongside the anchor body"
    )
