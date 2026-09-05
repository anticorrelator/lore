"""Sentinel tests for ~/.claude/agents/advisor.md."""
from __future__ import annotations

import pytest

import lib

ADVISOR = lib.read_agent("advisor")


def test_advisor_has_consultation_response_section() -> None:
    """advisor.md must document a section covering how to respond to consultations.

    Workers message advisors with domain-specific questions. If the response
    protocol is absent, advisors have no contract for when and how to reply.
    """
    assert "Responding to Consultations" in ADVISOR or "consultation" in ADVISOR.lower(), (
        "advisor.md does not document a consultation response protocol"
    )


def test_advisor_response_uses_sendmessage() -> None:
    """advisor.md must instruct the advisor to reply via SendMessage.

    Advisors must route their guidance back to the requesting worker via
    SendMessage. A text-only reply is not delivered to the worker's inbox.
    """
    assert "SendMessage" in ADVISOR, (
        "advisor.md does not instruct the advisor to reply via SendMessage"
    )


def test_advisor_response_format_includes_guidance_field() -> None:
    """advisor.md must document a **Guidance:** field in the response format.

    Guidance is the primary actionable output. Without the field in the
    template, advisors may emit free-form prose that callers cannot parse.
    """
    assert "**Guidance:**" in ADVISOR, (
        "advisor.md response format does not include a **Guidance:** field"
    )


def test_advisor_documents_domain_context() -> None:
    """advisor.md must reference a domain context section or placeholder.

    The advisor's domain context (investigation findings, design rationale,
    key files) is what distinguishes domain-specific advice from generic
    guidance. It must be wired into the template.
    """
    assert "domain_context" in ADVISOR or "Domain Context" in ADVISOR, (
        "advisor.md does not reference domain_context — the advisor has no "
        "baseline for grounding domain-specific advice"
    )


def test_advisor_documents_persistent_membership() -> None:
    """advisor.md must document that advisors are persistent team members and
    do not auto-shutdown between consultations.

    Advisors accumulate domain context across a work item. If the template
    doesn't document this, agents may expect to restart fresh each time
    or may shut down after responding to one query.
    """
    text = ADVISOR.lower()
    assert "persistent" in text or "auto-shutdown" in text or "not.*shutdown" in text, (
        "advisor.md does not document persistent team membership or no-auto-shutdown behavior"
    )




def test_advisor_template_documents_version_field() -> None:
    """advisor.md should document the advisor_template_version field that workers
    record when citing a consultation.

    Having the field described in both templates (worker records it, advisor
    emits it) creates a closed loop. Currently advisor.md is silent on this.
    """
    assert "advisor_template_version" in ADVISOR, (
        "advisor.md does not document the advisor_template_version field"
    )
