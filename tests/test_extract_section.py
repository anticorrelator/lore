"""Tests for extract_section.py"""

import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from extract_section import extract_section, heading_level


SAMPLE_MD = """\
# Conventions

## Category A

### Naming Patterns
We use camelCase for variables and PascalCase for classes.
This is a consistent pattern across the codebase.

### Import Order
Always import stdlib first, then third-party, then local.
Keep imports sorted alphabetically.

## Category B

### Error Handling
Use custom error classes for domain errors.
Never catch generic exceptions.

### Logging
Use structured logging with context fields.
"""

NESTED_MD = """\
# Top Level

## Section One

### Sub Section Alpha
Alpha content here.
More alpha content.

#### Deep Nested
Deep content.

### Sub Section Beta
Beta content here.

## Section Two

### Sub Section Gamma
Gamma content here.
"""


@pytest.fixture
def sample_file(tmp_path):
    f = tmp_path / "sample.md"
    f.write_text(SAMPLE_MD)
    return str(f)


@pytest.fixture
def nested_file(tmp_path):
    f = tmp_path / "nested.md"
    f.write_text(NESTED_MD)
    return str(f)


@pytest.fixture
def empty_file(tmp_path):
    f = tmp_path / "empty.md"
    f.write_text("")
    return str(f)


class TestHeadingLevel:
    def test_h1(self):
        assert heading_level("# Foo") == 1

    def test_h2(self):
        assert heading_level("## Bar") == 2

    def test_h3(self):
        assert heading_level("### Baz") == 3

    def test_not_heading(self):
        assert heading_level("Just text") == 0

    def test_no_space_after_hash(self):
        assert heading_level("#NoSpace") == 0


class TestExactMatch:
    def test_exact_heading(self, sample_file):
        result = extract_section(sample_file, "Naming Patterns", exact=True)
        assert result is not None
        assert result.startswith("### Naming Patterns")
        assert "camelCase" in result
        assert "Import Order" not in result

    def test_exact_no_match(self, sample_file):
        result = extract_section(sample_file, "naming patterns", exact=True)
        assert result is None

    def test_exact_case_sensitive(self, sample_file):
        result = extract_section(sample_file, "naming Patterns", exact=True)
        assert result is None


class TestSubstringMatch:
    def test_partial_match(self, sample_file):
        result = extract_section(sample_file, "naming")
        assert result is not None
        assert "### Naming Patterns" in result

    def test_case_insensitive(self, sample_file):
        result = extract_section(sample_file, "IMPORT ORDER")
        assert result is not None
        assert "### Import Order" in result

    def test_no_match(self, sample_file):
        result = extract_section(sample_file, "nonexistent")
        assert result is None


class TestNestedHeadings:
    def test_section_includes_deeper(self, nested_file):
        result = extract_section(nested_file, "Sub Section Alpha", exact=True)
        assert result is not None
        assert "Alpha content" in result
        assert "Deep Nested" in result
        assert "Deep content" in result
        assert "Sub Section Beta" not in result

    def test_parent_section(self, nested_file):
        result = extract_section(nested_file, "Section One", exact=True)
        assert result is not None
        assert "Sub Section Alpha" in result
        assert "Sub Section Beta" in result
        assert "Section Two" not in result

    def test_deep_section(self, nested_file):
        result = extract_section(nested_file, "Deep Nested", exact=True)
        assert result is not None
        assert "Deep content" in result
        assert "Sub Section Beta" not in result


class TestLastSection:
    def test_last_section_goes_to_eof(self, sample_file):
        result = extract_section(sample_file, "Logging", exact=True)
        assert result is not None
        assert "structured logging" in result

    def test_last_nested_section(self, nested_file):
        result = extract_section(nested_file, "Sub Section Gamma", exact=True)
        assert result is not None
        assert "Gamma content" in result


class TestEdgeCases:
    def test_empty_file(self, empty_file):
        result = extract_section(empty_file, "anything")
        assert result is None

    def test_missing_file(self):
        result = extract_section("/nonexistent/path.md", "anything")
        assert result is None

    def test_file_with_no_headings(self, tmp_path):
        f = tmp_path / "noheadings.md"
        f.write_text("Just some plain text\nwith no headings.\n")
        result = extract_section(str(f), "anything")
        assert result is None

    def test_result_is_stripped(self, sample_file):
        result = extract_section(sample_file, "Naming Patterns", exact=True)
        assert result is not None
        assert not result.endswith("\n")
