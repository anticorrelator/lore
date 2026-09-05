"""Sentinel tests for ~/.claude/agents/worker.md."""
from __future__ import annotations

import lib

WORKER = lib.read_agent("worker")

# Required fields for the **Observations:** YAML-list entry, as specified in
# the worker template's completion report format.
OBSERVATION_REQUIRED_FIELDS = [
    "claim",
    "file",
    "line_range",
    "exact_snippet",
    "normalized_snippet_hash",
    "falsifier",
    "significance",
]


def test_worker_observations_block_present() -> None:
    """worker.md must document an **Observations:** block in the completion report.

    Observations are the primary structured output of implementation work.
    The block must appear in the report format so the TaskCompleted validator
    can find and check it.
    """
    assert "**Observations:**" in WORKER, (
        "worker.md does not document an **Observations:** block in the completion report"
    )


def test_worker_observations_required_fields_documented() -> None:
    """worker.md must document all required Observations fields.

    The YAML-list schema (claim, file, line_range, exact_snippet,
    normalized_snippet_hash, falsifier, significance) must be present in the
    template so workers know what to emit and validators know what to check.
    """
    observations_section = lib.extract_section(WORKER, "Observations")
    # Fall back to full text if section extraction yields nothing — the
    # fields appear in a sub-block inside the step 6 code fence.
    search_text = observations_section if observations_section.strip() else WORKER

    missing = [f for f in OBSERVATION_REQUIRED_FIELDS if f not in search_text]
    assert not missing, (
        f"worker.md Observations schema is missing required fields: {missing}"
    )


def test_worker_template_version_echo() -> None:
    """worker.md completion report must include a Template-version: echo line.

    Template-version is the mechanism by which scorecard rows are attributed
    to specific template revisions. Without it, advisor-impact and producer-
    evaluation scoring cannot be computed.
    """
    assert "Template-version:" in WORKER, (
        "worker.md completion report format does not include 'Template-version:' echo"
    )


def test_worker_sendmessage_to_team_lead() -> None:
    """worker.md must instruct the worker to send the completion report via SendMessage.

    The team lead depends on SendMessage delivery to receive completion
    reports. If the template only says TaskUpdate, the lead never gets the
    report and cannot route follow-on work.
    """
    assert "SendMessage" in WORKER, (
        "worker.md does not mention SendMessage for the completion report"
    )
    # The recipient must be the team lead placeholder
    assert "team_lead" in WORKER or "team-lead" in WORKER, (
        "worker.md SendMessage does not reference team_lead as the recipient"
    )


def test_worker_advisor_consultations_section_documented() -> None:
    """worker.md must document the **Advisor consultations:** section with its contract.

    The section is the calibration channel for advisor templates
    (consultation_rate and advice_followed_rate). The contract must be in
    the template so workers know when and what to emit.
    """
    assert "**Consultations:**" in WORKER, (
        "worker.md does not document the **Advisor consultations:** section"
    )


def test_worker_advisor_consultations_requires_template_version() -> None:
    """worker.md Advisor consultations entries must require advisor_template_version.

    Without this field, a consultation cannot be attributed to a specific
    advisor template revision, making the scorecard row unactionable.
    """
    assert "advisor_template_version" in WORKER, (
        "worker.md Advisor consultations schema does not document the "
        "required advisor_template_version field"
    )


def test_worker_surfaced_concerns_required() -> None:
    """worker.md must document **Surfaced concerns:** as a REQUIRED always-present field.

    Surfaced concerns fill the worker-scope × architectural-scope gap.
    The template must instruct workers to always emit the section (even as
    None) so cross-cutting issues are not silently dropped.
    """
    assert "**Surfaced concerns:**" in WORKER, (
        "worker.md does not document the **Surfaced concerns:** section"
    )
    assert "REQUIRED" in WORKER, (
        "worker.md does not mark any section as REQUIRED — expected at least "
        "Surfaced concerns to carry this designation"
    )


# ---------------------------------------------------------------------------
# Tier 2 + Tier 3 schema extension (D1 in _work/implement-rewrite/plan.md)
# ---------------------------------------------------------------------------

# Required Tier 2 fields per validate-tier2.sh (13 fields). worker.md must
# name every one of these so workers know what to emit. Hash-identity is
# enforced separately via test_normalized_snippet_hash_algorithm_identity.
TIER2_REQUIRED_FIELDS = [
    "claim_id",
    "tier",
    "claim",
    "producer_role",
    "protocol_slot",
    "task_id",
    "phase_id",
    "scale",
    "file",
    "line_range",
    "falsifier",
    "why_this_work_needs_it",
    "captured_at_sha",
]

# Required Tier 3 fields per validate-tier3.sh (13 fields). The optional
# Tier 3 candidates YAML block in the worker report uses the full shape
# MINUS `confidence`, which `lore promote` forces — so the worker-side
# block must still name the other 12.
TIER3_CANDIDATE_FIELDS = [
    "claim_id",
    "tier",
    "claim",
    "producer_role",
    "protocol_slot",
    "scale",
    "why_future_agent_cares",
    "falsifier",
    "related_files",
    "source_artifact_ids",
    "work_item",
    "captured_at_sha",
]


def test_worker_tier2_evidence_section_documented() -> None:
    """worker.md must document a **Tier 2 evidence:** section in the report.

    The section carries `claim_id` references into `task-claims.jsonl` rows
    the worker wrote during the task. The TaskCompleted hook looks for this
    literal string to route report validation down the extended-shape path.
    """
    assert "**Tier 2 evidence:**" in WORKER, (
        "worker.md does not document a **Tier 2 evidence:** section in the "
        "completion report"
    )


def test_worker_tier2_emission_cli_referenced() -> None:
    """worker.md must name `evidence-append.sh` as the Tier 2 emission CLI.

    Workers emit Tier 2 rows via the sole-writer
    `evidence-append.sh --work-item <slug>` during the task. If the CLI is
    not named, the Tier 2 section is advisory rather than actionable.
    """
    assert "evidence-append.sh" in WORKER, (
        "worker.md does not name evidence-append.sh as the Tier 2 sole-writer "
        "emission CLI"
    )
    assert "--work-item" in WORKER, (
        "worker.md does not show the required `--work-item <slug>` flag for "
        "evidence-append.sh invocations"
    )


def test_worker_tier2_required_fields_named() -> None:
    """worker.md must name all 13 required Tier 2 fields from validate-tier2.sh.

    `evidence-append.sh` rejects rows missing any of these — workers need
    to see the full list in the template to produce conformant rows.
    """
    missing = [f for f in TIER2_REQUIRED_FIELDS if f not in WORKER]
    assert not missing, (
        f"worker.md Tier 2 emission schema is missing required fields: {missing}"
    )


def test_worker_tier2_one_call_per_claim_rule_present() -> None:
    """worker.md must instruct workers to emit one Tier 2 row per call.

    `evidence-append.sh` validates one row per invocation and appends one
    JSONL line. Batching multiple objects into one call corrupts the file.
    The rule must be explicit in the template.
    """
    assert "one call per claim" in WORKER.lower() or "one-call-per-claim" in WORKER.lower(), (
        "worker.md does not state the one-call-per-claim rule for "
        "evidence-append.sh invocations"
    )


def test_worker_tier3_candidates_section_documented() -> None:
    """worker.md must document the **Tier 3 candidates:** section verbatim.

    "Tier 3 candidates" is the sole accepted label. The TaskCompleted hook
    validates literal-prefix-match on this string — any alias silently
    drops the section from the promotion path.
    """
    assert "**Tier 3 candidates:**" in WORKER, (
        "worker.md does not document the **Tier 3 candidates:** section using "
        "the required literal label"
    )


def test_worker_tier3_candidates_naming_standard_callout() -> None:
    """worker.md must warn against aliasing the Tier 3 candidates label.

    The callout preserves literal-prefix-match compatibility with the
    TaskCompleted hook and with `/implement` SKILL.md Step 5. At least one
    wrong alias must be named explicitly so workers do not substitute.
    """
    aliases_warned = [
        "Tier 3 claims",
        "Tier 3 observations",
        "Tier 3 promotion",
    ]
    present = [a for a in aliases_warned if a in WORKER]
    assert present, (
        "worker.md does not explicitly warn against any of the Tier 3 label "
        f"aliases {aliases_warned} — the naming-standard callout is missing"
    )


def test_worker_tier3_candidates_fields_named() -> None:
    """worker.md Tier 3 candidates YAML must name the 12 producer-side fields.

    The block is the full Tier 3 shape minus `confidence` (which
    `lore promote` forces to "unaudited"). Workers need to see the complete
    field list to produce a candidate the lead can promote without
    additional synthesis.
    """
    missing = [f for f in TIER3_CANDIDATE_FIELDS if f not in WORKER]
    assert not missing, (
        f"worker.md Tier 3 candidates schema is missing required fields: {missing}"
    )


def test_worker_tier3_source_artifact_ids_links_tier2() -> None:
    """worker.md must link Tier 3 `source_artifact_ids` to Tier 2 claim_ids.

    Tier 3 rows cite back to Tier 2 evidence from the same session. Without
    this linkage, `lore promote` cannot verify the candidate is grounded
    and the lead cannot defend against fabricated references.
    """
    assert "source_artifact_ids" in WORKER, (
        "worker.md does not name source_artifact_ids in the Tier 3 candidates "
        "schema"
    )
    lowered = WORKER.lower()
    assert "tier 2" in lowered and "source_artifact_ids" in WORKER, (
        "worker.md does not tie Tier 3 source_artifact_ids back to the "
        "worker's Tier 2 evidence list"
    )


def test_worker_mustache_variables_preserved() -> None:
    """worker.md must preserve all four mustache-style injection variables.

    {{team_name}}, {{team_lead}}, {{prior_knowledge}}, {{template_version}}
    are the injection contract with `/implement`'s worker-spawn path. Any
    rename silently breaks template expansion and the TaskCompleted hook
    scorecard attribution.
    """
    for var in ("{{team_name}}", "{{team_lead}}", "{{prior_knowledge}}", "{{template_version}}"):
        assert var in WORKER, (
            f"worker.md is missing the mustache variable {var} — "
            "injection contract with /implement is broken"
        )
