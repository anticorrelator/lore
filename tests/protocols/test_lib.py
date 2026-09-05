"""Minimal self-tests for lib.py helpers (round-trip against real skill files)."""
import pytest
from lib import (
    extract_section,
    extract_embedded_template,
    find_invocation,
    in_code_context,
    read_skill,
    read_agent,
)


# ---------------------------------------------------------------------------
# read_skill / read_agent
# ---------------------------------------------------------------------------

def test_read_skill_returns_string():
    text = read_skill("spec")
    assert isinstance(text, str)
    assert len(text) > 0


def test_read_agent_returns_string():
    text = read_agent("worker")
    assert isinstance(text, str)
    assert len(text) > 0


# ---------------------------------------------------------------------------
# extract_section
# ---------------------------------------------------------------------------

SAMPLE_MD = """\
# Top

intro line

## Section A

content A line 1
content A line 2

### Sub-section

sub content

## Section B

content B
"""

def test_extract_section_basic():
    body = extract_section(SAMPLE_MD, "Section A")
    assert "content A line 1" in body
    assert "content A line 2" in body
    # Should not bleed into Section B
    assert "content B" not in body


def test_extract_section_includes_subsections():
    body = extract_section(SAMPLE_MD, "Section A")
    assert "sub content" in body


def test_extract_section_missing_returns_empty():
    body = extract_section(SAMPLE_MD, "Nonexistent")
    assert body == ""


def test_extract_section_case_insensitive():
    body = extract_section(SAMPLE_MD, "section a")
    assert "content A line 1" in body


def test_extract_section_real_skill():
    spec = read_skill("spec")
    body = extract_section(spec, "Short Flow (`/spec short`)")
    # Short Flow section must be non-empty in current prose
    assert len(body) > 10


# ---------------------------------------------------------------------------
# in_code_context
# ---------------------------------------------------------------------------

FENCED_MD = """\
prose before

```bash
lore capture --insight "x"
```

prose after
lore capture --insight "y"
"""

def test_in_code_context_inside_fence():
    # line 4 is "lore capture --insight "x""
    assert in_code_context(FENCED_MD, 4) is True


def test_in_code_context_outside_fence():
    # line 8 is "lore capture --insight "y""
    assert in_code_context(FENCED_MD, 8) is False


def test_in_code_context_fence_delimiter_line():
    # line 3 is the opening ```bash
    assert in_code_context(FENCED_MD, 3) is True


# ---------------------------------------------------------------------------
# extract_embedded_template
# ---------------------------------------------------------------------------

TEMPLATE_MD = """\
Some text

```completion-report
**Task:** foo
**Changes:** bar
```

Other text

```bash
lore capture
```
"""

def test_extract_embedded_template_by_name():
    blocks = extract_embedded_template(TEMPLATE_MD, r"completion-report")
    assert len(blocks) == 1
    assert "**Task:**" in blocks[0]


def test_extract_embedded_template_no_match():
    blocks = extract_embedded_template(TEMPLATE_MD, r"nonexistent")
    assert blocks == []


def test_extract_embedded_template_multiple():
    blocks = extract_embedded_template(TEMPLATE_MD, r"bash|completion-report")
    assert len(blocks) == 2


# ---------------------------------------------------------------------------
# find_invocation
# ---------------------------------------------------------------------------

def test_find_invocation_basic():
    hits = find_invocation(FENCED_MD, "lore capture")
    # Should find two hits: one in code block, one in prose
    assert len(hits) == 2


def test_find_invocation_returns_correct_line_numbers():
    hits = find_invocation(FENCED_MD, "lore capture")
    line_numbers = [ln for ln, _ in hits]
    assert 4 in line_numbers  # inside fence
    assert 8 in line_numbers  # outside fence


def test_find_invocation_none():
    hits = find_invocation(FENCED_MD, "lore promote")
    assert hits == []


def test_find_invocation_real_skill():
    spec = read_skill("spec")
    hits = find_invocation(spec, "lore resolve")
    assert len(hits) >= 1
