"""Tier B convention meta-tests.

These tests assert prose conventions that Tier A content-tests rely on:
  1. Canonical step-header form: `### Step N(.M)?[a-z]?: Name`
  2. Every `lore <cmd>` occurrence in prose is inside backticks or a fenced block
  3. Embedded agent-prompt blocks in spec/implement are wrapped in triple-backtick fences

Convention references: plan.md §D3
"""
from __future__ import annotations

import re
import pytest
from lib import (
    read_skill,
    find_invocation,
    in_code_context,
    extract_embedded_template,
)

# ---------------------------------------------------------------------------
# Test 1: canonical step-header form
# ---------------------------------------------------------------------------
# Canonical form per plan §D3: `^### Step \d+(\.\d+)?[a-z]?: Name`
# Current violations: most skills use `## Step` (two hashes) instead of `###`.
# Task-8 will canonicalize to `###` form.

STEP_HEADER_RE = re.compile(r"^#{1,6} Step ")
CANONICAL_STEP_RE = re.compile(r"^### Step \d+(\.\d+)?[a-z]?: \S")

TARGET_SKILLS = [
    "spec",
    "implement",
    "remember",
    "retro",
    "evolve",
    "memory",
    "renormalize",
    "bootstrap",
]

# Task-8 has canonicalized all step headers — no known violations remain.
_STEP_HEADER_KNOWN_VIOLATIONS: set[str] = set()


def _step_header_violations(skill_name: str) -> list[str]:
    """Return non-canonical step header lines for a skill."""
    text = read_skill(skill_name)
    violations = []
    for line in text.splitlines():
        if STEP_HEADER_RE.match(line):
            if not CANONICAL_STEP_RE.match(line):
                violations.append(line)
    return violations


@pytest.mark.parametrize("skill", TARGET_SKILLS)
def test_step_header_canonical_form(skill: str) -> None:
    """Every `Step N` heading must match `^### Step \\d+(\\.(\\d+))?[a-z]?: Name`.

    Current violations are xfail pending task-8 canonicalization.
    """
    if skill in _STEP_HEADER_KNOWN_VIOLATIONS:
        pytest.xfail(
            reason=f"{skill} uses non-canonical step-header level (## instead of ###); "
            "fix: task-8 mechanical canonicalization"
        )
    violations = _step_header_violations(skill)
    assert violations == [], (
        f"{skill}/SKILL.md has {len(violations)} non-canonical step headers:\n"
        + "\n".join(f"  {v!r}" for v in violations[:5])
    )


# ---------------------------------------------------------------------------
# Test 2: lore CLI invocations appear inside backticks or fenced code
# ---------------------------------------------------------------------------
# Convention: every `lore <subcommand>` in prose must be either:
#   - inline backtick: `lore capture ...`
#   - inside a fenced code block

# Subcommands to check — the most load-bearing ones.
LORE_SUBCOMMANDS = [
    "lore capture",
    "lore promote",
    "lore resolve",
    "lore search",
    "lore work",
]

# (skill, subcommand) pairs with known prose violations.
# Format: frozenset of (skill, command) pairs.
_LORE_BACKTICK_KNOWN_VIOLATIONS: set[tuple[str, str]] = {
    # spec: bare `lore resolve` on its own line in a code block is fine;
    # the known violation is prose mentions without backticks.
    # Populated after initial scan below — see notes.
}


def _bare_prose_invocations(skill_name: str, command: str) -> list[tuple[int, str]]:
    """Return invocations of `command` that are not in a fenced block or inline backtick."""
    text = read_skill(skill_name)
    results = []
    for lineno, line in find_invocation(text, command):
        if in_code_context(text, lineno):
            continue
        # Check for inline backtick: the command must appear inside `...`
        if re.search(r"`[^`]*" + re.escape(command) + r"[^`]*`", line):
            continue
        results.append((lineno, line))
    return results


# Skills known to have bare prose lore invocations (pending task-8).
# implement/SKILL.md was rewritten in implement-rewrite (D10); the rewrite
# backticks every prose `lore <cmd>` reference, so `implement` is now empty.
_LORE_PROSE_KNOWN_VIOLATIONS: dict[str, set[str]] = {
    "spec": {"lore capture", "lore work"},
    "implement": set(),
    "remember": {"lore capture", "lore work", "lore search", "lore resolve"},
    "retro": {"lore work"},
    "evolve": {"lore work"},
    "renormalize": set(),
    "self-test": {"lore resolve"},
    "bootstrap": set(),
    "memory": set(),
}


@pytest.mark.parametrize(
    "skill_cmd",
    [
        pytest.param(f"{skill}|{cmd}", id=f"{skill}-{cmd.replace(' ', '_')}")
        for skill in TARGET_SKILLS
        for cmd in LORE_SUBCOMMANDS
    ],
)
def test_lore_invocations_backticked(skill_cmd: str) -> None:
    """Every `lore <cmd>` occurrence in prose must be in backticks or a fenced block."""
    skill, command = skill_cmd.split("|", 1)
    known = _LORE_PROSE_KNOWN_VIOLATIONS.get(skill, set())
    bare = _bare_prose_invocations(skill, command)
    if bare and command in known:
        pytest.xfail(
            reason=f"{skill}: bare prose `{command}` invocations (known violation); "
            "fix: task-8 mechanical canonicalization"
        )
    assert bare == [], (
        f"{skill}/SKILL.md has {len(bare)} bare `{command}` prose invocations "
        "(not inside backticks or fenced code):\n"
        + "\n".join(f"  line {ln}: {txt!r}" for ln, txt in bare[:5])
    )


# ---------------------------------------------------------------------------
# Test 3: embedded agent-prompt blocks are wrapped in triple-backtick fences
# ---------------------------------------------------------------------------
# Embedded templates are the bare ``` blocks containing Task: YAML or /remember
# invocations in spec/implement. The convention is that these must be fenced
# (already satisfied in current prose — this test catches future regressions).

AGENT_PROMPT_SKILLS = ["spec", "implement"]

# Patterns that identify an embedded agent-prompt block's content.
AGENT_PROMPT_CONTENT_PATTERNS = [
    r"subagent_type:",    # Task: YAML spawn blocks
    r"/remember .+findings",  # /remember invocation blocks
]


def _has_unfenced_agent_template(skill_name: str) -> list[str]:
    """Return lines that look like agent-template content outside a fenced block."""
    text = read_skill(skill_name)
    violations = []
    for pattern in AGENT_PROMPT_CONTENT_PATTERNS:
        for lineno, line in find_invocation(text, "subagent_type:") + find_invocation(text, "/remember "):
            if not re.search(pattern, line):
                continue
            if not in_code_context(text, lineno):
                violations.append(f"line {lineno}: {line.strip()!r}")
    return violations




# ---------------------------------------------------------------------------
# Test 4: review skills carry the Sound/Weak/Unsound classification rubric
# ---------------------------------------------------------------------------
# Cross-cutting Tier B invariant: every review-pipeline skill names the three
# grounding-quality classifications by literal token. The rubric body lives in
# `severity.md`; each consumer skill must reference all three labels by name so
# the rubric stays a load-bearing contract, not a dangling import.

REVIEW_SKILLS = ["pr-review", "pr-self-review", "pr-revise"]




# ---------------------------------------------------------------------------
# Test 5: review skills carry the mechanism→consequence grounding chain
# ---------------------------------------------------------------------------
# pr-review and pr-self-review embed the literal `**Grounding:**` template line
# chaining mechanism→consequence. pr-revise expresses the same chain by
# applying the Grounding Quality Rubric to reviewer findings; its prose places
# `**Grounding:**` under reviewer-finding labeling rather than lens output, so
# we assert the cross-skill invariant as: `**Grounding:**` template present
# AND mechanism + consequence tokens co-occur.

GROUNDING_TEMPLATE_RE = re.compile(r"\*\*Grounding:\*\*")




# ---------------------------------------------------------------------------
# Test 6: intent_anchor is referenced with a verbatim-preservation discipline
# ---------------------------------------------------------------------------
# Downstream gates detect anchor drift by string comparison, so every skill
# that reads or restates `_meta.json.intent_anchor` must commit to a verbatim
# preservation discipline. pr-create is excluded (no `intent_anchor` prose
# surface today; tracked as a follow-on in the plan's Open Questions).

INTENT_ANCHOR_SKILLS = ["spec", "implement"]


@pytest.mark.parametrize(
    "skill",
    [pytest.param(s, id=s) for s in INTENT_ANCHOR_SKILLS],
)
def test_intent_anchor_referenced_with_verbatim_preservation(skill: str) -> None:
    """Skills consuming `intent_anchor` must commit to verbatim preservation."""
    text = read_skill(skill)
    assert "intent_anchor" in text, (
        f"{skill}/SKILL.md does not reference the `intent_anchor` token"
    )
    assert "verbatim" in text, (
        f"{skill}/SKILL.md references `intent_anchor` but does not name a "
        "verbatim-preservation discipline (token `verbatim` missing)"
    )


# ---------------------------------------------------------------------------
# Test 7: spawn skills document a parallel agent/team/lens dispatch model
# ---------------------------------------------------------------------------
# Skills that fan out work across agents must name a parallel-dispatch
# mechanism (parallel + at least one of agent|team|lens|worker|skill), not
# just a rationale paragraph. The phrase shape varies per skill; the invariant
# is "names a parallel-dispatch mechanism in prose."

SPAWN_SKILLS = ["spec", "renormalize", "pr-review"]
PARALLEL_DISPATCH_NOUNS = ("agent", "team", "lens", "worker", "skill")


@pytest.mark.parametrize(
    "skill",
    [pytest.param(s, id=s) for s in SPAWN_SKILLS],
)
def test_spawn_skills_document_parallel_execution_model(skill: str) -> None:
    """Every spawn skill names a parallel agent/team/lens dispatch model in prose."""
    text = read_skill(skill).lower()
    assert "parallel" in text, (
        f"{skill}/SKILL.md does not mention `parallel` in prose"
    )
    present = [n for n in PARALLEL_DISPATCH_NOUNS if n in text]
    assert present, (
        f"{skill}/SKILL.md mentions `parallel` but does not name a dispatch "
        f"unit from {PARALLEL_DISPATCH_NOUNS}"
    )
