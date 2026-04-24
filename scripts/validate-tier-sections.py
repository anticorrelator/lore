#!/usr/bin/env python3
"""validate-tier-sections.py — shape-check Tier 2 / Tier 3 sections in a worker completion report.

Invoked by scripts/task-completed-capture-check.sh as a second-pass check after the
primary Observations/Assertions validation (validate-structured-report.py) succeeds.

Reads the full report text on stdin. Prints one line to stdout:

  PASS                 — both sections are absent OR present-and-well-shaped
  FAIL: <reason>       — a present section fails shape rules

Exits 0 on pass, 1 on fail.

Shape rules (hook-scope: structure only, no claim-content validation — those are the
sole-writer responsibilities of evidence-append.sh and lore-promote.sh):

  **Tier 2 evidence:**  (optional heading)
    - Body until next `**Heading:**` must contain zero or more list lines of the form
      `- <token>`. Non-list, non-empty lines in the body fail the shape check.
    - Empty list (no entries) is accepted.

  **Tier 3 candidates:**  (optional heading)
    - Each YAML-style list entry starts with `- claim:` and must carry ALL of:
        claim, why_future_agent_cares, falsifier, source_artifact_ids
    - `source_artifact_ids` must be an array literal with at least one element —
      accepted forms:  source_artifact_ids: [a, b]   or   source_artifact_ids: ["a"]
      An empty array (`source_artifact_ids: []`) or a missing value fails.
    - If the heading is present but contains zero entries, FAIL (a deliberately empty
      candidates block signals nothing promotable and should be omitted).
"""
from __future__ import annotations

import re
import sys


TIER3_REQUIRED_FIELDS = ("claim", "why_future_agent_cares", "falsifier", "source_artifact_ids")


def _extract_section(text: str, heading: str) -> str | None:
    """Return the body under `**heading:**` up to the next `**Heading:**`, or None if absent."""
    heading_pat = re.compile(rf'\*\*{re.escape(heading)}:\*\*', re.IGNORECASE)
    m = heading_pat.search(text)
    if not m:
        return None
    section = text[m.end():]
    next_h = re.search(r'\n\*\*[A-Z][a-zA-Z0-9 ]+:\*\*', section)
    if next_h:
        section = section[:next_h.start()]
    return section


def check_tier2(text: str) -> tuple[bool, str | None]:
    body = _extract_section(text, "Tier 2 evidence")
    if body is None:
        return True, None
    # Every non-blank line must be either a list item `- <token>` or a comment-ish blank.
    for raw_line in body.splitlines():
        line = raw_line.rstrip()
        if not line.strip():
            continue
        if re.match(r'^\s*-\s+\S', line):
            continue
        return False, (
            f"**Tier 2 evidence:** body contains a non-list line: {line.strip()!r} — "
            f"each entry must be of the form `- <claim_id>`"
        )
    return True, None


def _split_tier3_entries(section: str) -> list[str]:
    """Split the Tier 3 candidates section into per-entry substrings by top-level `- claim:` lines."""
    claim_starts = [m.start() for m in re.finditer(r'(?m)^\s*-\s*claim\s*[:=]', section)]
    entries: list[str] = []
    for i, pos in enumerate(claim_starts):
        end = claim_starts[i + 1] if i + 1 < len(claim_starts) else len(section)
        entries.append(section[pos:end])
    return entries


def _source_artifact_ids_nonempty_array(entry: str) -> bool:
    """Accept `source_artifact_ids: [a, b, ...]` with at least one non-whitespace element."""
    m = re.search(
        r'\bsource_artifact_ids\s*[:=]\s*\[(?P<inner>[^\]]*)\]',
        entry,
        re.IGNORECASE,
    )
    if not m:
        return False
    inner = m.group("inner").strip()
    if not inner:
        return False
    # Split on commas and ensure at least one non-empty element remains.
    items = [x.strip().strip('"\'') for x in inner.split(",")]
    return any(item for item in items)


def check_tier3(text: str) -> tuple[bool, str | None]:
    body = _extract_section(text, "Tier 3 candidates")
    if body is None:
        return True, None
    entries = _split_tier3_entries(body)
    if not entries:
        return False, (
            "**Tier 3 candidates:** heading present but contains no entries — "
            "omit the section entirely if there are no candidates to promote"
        )
    for idx, entry in enumerate(entries, start=1):
        missing: list[str] = []
        for field in TIER3_REQUIRED_FIELDS:
            if not re.search(rf'\b{field}\s*[:=]', entry, re.IGNORECASE):
                missing.append(field)
        if missing:
            return False, (
                f"Tier 3 candidate entry {idx} is missing required field(s): "
                f"{', '.join(missing)} — required: {', '.join(TIER3_REQUIRED_FIELDS)}"
            )
        if not _source_artifact_ids_nonempty_array(entry):
            return False, (
                f"Tier 3 candidate entry {idx} has invalid source_artifact_ids — "
                f"must be a non-empty array literal, e.g. source_artifact_ids: [\"claim-id-1\"]"
            )
    return True, None


def main() -> int:
    text = sys.stdin.read()

    ok, err = check_tier2(text)
    if not ok:
        print(f"FAIL: {err}")
        return 1

    ok, err = check_tier3(text)
    if not ok:
        print(f"FAIL: {err}")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
