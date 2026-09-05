"""Shared helpers for protocol unit tests."""
from __future__ import annotations

import re
from pathlib import Path


SKILLS_DIR = Path(__file__).resolve().parents[2] / "skills"
AGENTS_DIR = Path(__file__).resolve().parents[2] / "agents"


def read_skill(skill_name: str) -> str:
    return (SKILLS_DIR / skill_name / "SKILL.md").read_text()


def read_agent(agent_name: str) -> str:
    path = AGENTS_DIR / agent_name
    if not path.suffix:
        path = path.with_suffix(".md")
    return path.read_text()


def extract_section(markdown: str, heading: str) -> str:
    """Return the body of the first section whose heading text matches `heading`.

    Matching is case-insensitive, prefix-insensitive (strips leading #s and spaces).
    The body includes all lines up to (but not including) the next sibling or
    higher-level heading.
    """
    lines = markdown.splitlines(keepends=True)
    heading_re = re.compile(r"^(#{1,6})\s+(.*)")

    target_level: int | None = None
    in_section = False
    body_lines: list[str] = []

    for line in lines:
        m = heading_re.match(line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if not in_section:
                if text.lower() == heading.lower():
                    target_level = level
                    in_section = True
            else:
                # end on same-level or higher heading
                if target_level is not None and level <= target_level:
                    break
        if in_section:
            body_lines.append(line)

    # drop the heading line itself
    return "".join(body_lines[1:]) if body_lines else ""


def _fence_spans(lines: list[str]) -> list[tuple[int, int]]:
    """Return (start, end) inclusive line-index pairs for every fenced code block.

    Handles indented fences (e.g. `   ```bash`) as CommonMark allows up to 3 spaces
    of indentation on fence lines.
    """
    spans: list[tuple[int, int]] = []
    # Allow arbitrary leading whitespace — skill files use deeply indented fences inside
    # numbered lists (e.g. 9-space indent inside a sub-item), which exceeds CommonMark's
    # 3-space limit but is rendered as fenced code by all major renderers in this context.
    fence_re = re.compile(r"^\s*(`{3,}|~{3,})")
    start: int | None = None
    fence_char: str | None = None

    for i, line in enumerate(lines):
        m = fence_re.match(line)
        if m:
            char = m.group(1)[0]
            if start is None:
                start = i
                fence_char = char
            elif char == fence_char:
                spans.append((start, i))
                start = None
                fence_char = None

    return spans


def in_code_context(markdown: str, line_number: int) -> bool:
    """Return True if 1-based `line_number` falls inside a fenced code block."""
    lines = markdown.splitlines(keepends=True)
    idx = line_number - 1  # convert to 0-based
    for start, end in _fence_spans(lines):
        if start <= idx <= end:
            return True
    return False


def extract_embedded_template(markdown: str, delimiter_regex: str) -> list[str]:
    """Return every fenced code block whose opening fence line matches `delimiter_regex`.

    Each returned string is the full block including the opening and closing fence lines.
    """
    lines = markdown.splitlines(keepends=True)
    pattern = re.compile(delimiter_regex)
    results: list[str] = []

    for start, end in _fence_spans(lines):
        opening_line = lines[start]
        if pattern.search(opening_line):
            results.append("".join(lines[start : end + 1]))

    return results


def find_invocation(markdown: str, command: str) -> list[tuple[int, str]]:
    """Return (1-based line_number, line) tuples where `command` appears in the text."""
    results: list[tuple[int, str]] = []
    for i, line in enumerate(markdown.splitlines(keepends=True), start=1):
        if command in line:
            results.append((i, line.rstrip("\n")))
    return results
