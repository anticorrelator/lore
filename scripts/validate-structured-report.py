#!/usr/bin/env python3
"""validate-structured-report.py — hard-validate a task completion report.

Invoked by scripts/task-completed-capture-check.sh.

Reads the full report text on stdin; takes the section heading to search under as arg 1
("Observations" or "Assertions"). Prints one line to stdout:

  PASS_STRUCTURED:<N>   — report contains N valid structured entries under the section
  PASS_ESCALATION       — report contains a well-formed escalation verdict
  FAIL: <reason>        — neither present; reason is a single-line diagnostic

Exits 0 on pass, 1 on fail.

When the section heading is "Observations" (the worker report path), a present-and-
populated `Convention handling:` section is additionally required: the worker dispositions
each woven norm there, and the field is always emitted (`none in scope` when no norm was
woven). Researcher ("Assertions") reports do not carry this field. The escalation path
bypasses the requirement — an escalating report ships no convention dispositions.

Structured entry contract (per task #20 / #21): YAML-style list entry under the section
heading, starting with `- claim:` and carrying all of:
  claim, file, line_range, falsifier, significance
where `significance` must be one of `low`, `medium`, `high`.

Escalation verdict contract (per task #22): a block containing both
  escalation: "task-too-trivial-for-solo-decomposition"
  rationale: "<one-sentence reason, >=5 chars>"
anywhere in the report (field order does not matter; JSON-style `=` also accepted).

Task #23 layers a backwards-compat gate on top of this (caller-side): the validator only
fires when the report carries a `template_version` line; legacy reports warn but pass.
That gate is NOT encoded here.
"""
from __future__ import annotations

import re
import sys


REQUIRED_FIELDS = ("claim", "file", "line_range", "falsifier", "significance")
SIGNIFICANCE_VALUES = {"low", "medium", "high"}
VALID_ESCALATION = "task-too-trivial-for-solo-decomposition"

# Exact label, casing, and trailing colon are a protocol constant — worker.md,
# this validator, and the hook all match the same literal. Workers report it
# alongside Surfaced concerns; only the Observations (worker) path requires it.
CONVENTION_HANDLING_HEADING = "Convention handling"


def find_escalation(s: str):
    """Return (escalation_value, rationale) if present, else None.

    Accepts both YAML-ish (`escalation: "X"`) and JSON-ish (`escalation="X"`) forms,
    in either order of the two fields within a 400-char window.
    """
    # Forward: escalation then rationale
    fwd = re.compile(
        r'escalation[:=]\s*["\']?(?P<val>[a-z0-9_\-]+)["\']?'
        r'.{0,400}?rationale[:=]\s*["\']?(?P<rat>[^\n"\']{5,})["\']?',
        re.DOTALL | re.IGNORECASE,
    )
    # Reverse: rationale then escalation
    rev = re.compile(
        r'rationale[:=]\s*["\']?(?P<rat>[^\n"\']{5,})["\']?'
        r'.{0,400}?escalation[:=]\s*["\']?(?P<val>[a-z0-9_\-]+)["\']?',
        re.DOTALL | re.IGNORECASE,
    )
    for pat in (fwd, rev):
        m = pat.search(s)
        if m:
            return m.group("val"), m.group("rat").strip()
    return None


def find_structured_entries(s: str, section_heading: str):
    """Return (valid_entry_count, error_reason_or_None)."""
    heading_pat = re.compile(rf'\*\*{re.escape(section_heading)}:\*\*', re.IGNORECASE)
    m = heading_pat.search(s)
    if not m:
        return 0, f"missing required section: **{section_heading}:**"
    section = s[m.end():]
    # Truncate at the next top-level **Heading:** if any.
    next_h = re.search(r'\n\*\*[A-Z][a-zA-Z ]+:\*\*', section)
    if next_h:
        section = section[:next_h.start()]

    # Entry windows start at each `- claim:` line.
    claim_starts = [mm.start() for mm in re.finditer(r'(?m)^\s*-\s*claim\s*[:=]', section)]
    entries = []
    for i, pos in enumerate(claim_starts):
        end = claim_starts[i + 1] if i + 1 < len(claim_starts) else len(section)
        entries.append(section[pos:end])

    if not entries:
        return 0, (
            f"no structured entries found under **{section_heading}:** — "
            f"expected at least one YAML-style entry starting with `- claim:` and "
            f"carrying all of: {', '.join(REQUIRED_FIELDS)}"
        )

    valid_count = 0
    failures: list[str] = []
    for idx, entry in enumerate(entries, start=1):
        missing = [f for f in REQUIRED_FIELDS if not re.search(rf'\b{f}\s*[:=]', entry, re.IGNORECASE)]
        if missing:
            failures.append(f"entry {idx} missing: {', '.join(missing)}")
            continue
        sig_m = re.search(r'\bsignificance\s*[:=]\s*["\']?([a-zA-Z]+)["\']?', entry, re.IGNORECASE)
        if sig_m and sig_m.group(1).lower() not in SIGNIFICANCE_VALUES:
            failures.append(
                f"entry {idx} significance '{sig_m.group(1)}' must be one of {sorted(SIGNIFICANCE_VALUES)}"
            )
            continue
        valid_count += 1

    if valid_count >= 1:
        return valid_count, None
    return 0, f"no valid structured entries under **{section_heading}:** — failures: {'; '.join(failures)}"


def find_convention_handling(s: str):
    """Return None if the report carries a present, non-empty Convention handling
    section, else a single-line error reason.

    Presence only — the section's dispositions (honored / diverged / none in scope)
    are assessed by the lead, not the hook. The body must be non-empty: an empty
    section is the silent-omission shape the always-emit contract closes.
    """
    heading_pat = re.compile(
        rf'\*\*{re.escape(CONVENTION_HANDLING_HEADING)}:\*\*', re.IGNORECASE
    )
    m = heading_pat.search(s)
    if not m:
        return (
            f"missing required section: **{CONVENTION_HANDLING_HEADING}:** — "
            f"disposition each woven norm by stable label "
            f"(honored: <label>[ — <rationale>] / diverged: <label> — <why>), "
            f"or `none in scope`"
        )
    section = s[m.end():]
    next_h = re.search(r'\n\*\*[A-Z][a-zA-Z0-9 ]+:\*\*', section)
    if next_h:
        section = section[:next_h.start()]
    if not section.strip():
        return (
            f"**{CONVENTION_HANDLING_HEADING}:** present but empty — emit one "
            f"disposition per woven norm, or `none in scope` when none was woven"
        )
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("FAIL: usage: validate-structured-report.py <section-heading>", file=sys.stderr)
        return 1

    section_heading = sys.argv[1]
    text = sys.stdin.read()

    # Escalation path takes precedence — if present and valid, pass.
    esc = find_escalation(text)
    if esc is not None:
        val, rat = esc
        if val == VALID_ESCALATION and len(rat) >= 5:
            print("PASS_ESCALATION")
            return 0
        print(
            f"FAIL: escalation present but malformed — value must be "
            f"'{VALID_ESCALATION}' (got '{val}'); rationale must be a one-sentence "
            f"reason (>=5 chars, got {len(rat)} chars)"
        )
        return 1

    count, err = find_structured_entries(text, section_heading)
    if err is not None:
        print(f"FAIL: {err}")
        return 1

    # Worker reports (Observations) must also carry the convention-handling
    # disposition. Researcher (Assertions) reports do not.
    if section_heading.lower() == "observations":
        conv_err = find_convention_handling(text)
        if conv_err is not None:
            print(f"FAIL: {conv_err}")
            return 1

    print(f"PASS_STRUCTURED:{count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
