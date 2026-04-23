#!/usr/bin/env python3
"""pk_markdown: Markdown parser for lore knowledge stores.

Parses markdown files into heading-delimited sections for FTS5 indexing.
Zero external dependencies (stdlib only).
"""

import re
from pathlib import Path


class MarkdownParser:
    """Parse a markdown file into heading-delimited sections."""

    # Default heading pattern: ### (but not #### or more)
    HEADING_RE = re.compile(r"^###\s+(.+)$", re.MULTILINE)

    # Cache compiled patterns by heading level
    _heading_patterns: dict[str, re.Pattern] = {}

    @classmethod
    def _get_heading_re(cls, heading_level: str) -> re.Pattern:
        """Get a compiled regex for the given heading level (e.g. '##', '###')."""
        if heading_level not in cls._heading_patterns:
            # Escape the hashes and match exactly that level (not deeper)
            n = len(heading_level)
            # Match exactly N hashes followed by space, not N+1 hashes
            pattern = rf"^{'#' * n}(?!#)\s+(.+)$"
            cls._heading_patterns[heading_level] = re.compile(pattern, re.MULTILINE)
        return cls._heading_patterns[heading_level]

    _FRONTMATTER_RE = re.compile(r"\A---\n.*?\n---\n", re.DOTALL)

    @classmethod
    def _strip_frontmatter(cls, text: str) -> str:
        """Strip YAML frontmatter (--- delimited block at start of file)."""
        return cls._FRONTMATTER_RE.sub("", text)

    _H1_RE = re.compile(r"^#\s+(.+)$", re.MULTILINE)
    _HTML_COMMENT_RE = re.compile(r"<!--.*?-->", re.DOTALL)
    # Matches any HTML comment that starts with "learned:" — the primary lore metadata block.
    # We use a flexible KV parser rather than a rigid regex to handle evolving field sets.
    _METADATA_COMMENT_START_RE = re.compile(r"<!--\s*learned:", re.DOTALL)
    _METADATA_COMMENT_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
    # Matches individual key: value pairs separated by |
    _METADATA_KV_RE = re.compile(r"(\w+):\s*([^|>]+?)(?=\s*\||\s*-->|\s*$)")

    @staticmethod
    def _extract_metadata(text: str) -> dict:
        """Extract metadata from HTML comments in markdown text.

        Parses lore metadata comments of the form:
            <!-- learned: DATE | confidence: high | source: ... | scale: val | status: current -->

        Returns dict with keys: learned, confidence, source, scale, entry_status (None if not found).
        Unrecognized fields are silently ignored.
        """
        # Find the first HTML comment that contains "learned:"
        for m in MarkdownParser._METADATA_COMMENT_RE.finditer(text):
            inner = m.group(1)
            if "learned:" not in inner:
                continue
            # Parse all key: value pairs from the comment
            kv: dict[str, str] = {}
            for kv_match in MarkdownParser._METADATA_KV_RE.finditer(inner):
                key = kv_match.group(1).strip()
                val = kv_match.group(2).strip()
                kv[key] = val
            return {
                "learned": kv.get("learned"),
                "confidence": kv.get("confidence"),
                "source": kv.get("source"),
                "scale": kv.get("scale"),
                "entry_status": kv.get("status"),
                "template_version": kv.get("template_version"),
            }
        return {"learned": None, "confidence": None, "source": None, "scale": None, "entry_status": None, "template_version": None}

    @staticmethod
    def parse_entry_file(file_path: str) -> list[dict]:
        """Parse a file-per-entry markdown file as a single entry.

        The H1 heading (# Title) becomes the entry heading.
        The entire file content (minus frontmatter and HTML comments) is the body.
        Returns a list with zero or one entry dict.
        """
        try:
            text = Path(file_path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return []

        text = MarkdownParser._strip_frontmatter(text)
        content = text.strip()
        if not content:
            return []

        # Extract H1 heading for the entry title
        h1_match = MarkdownParser._H1_RE.search(text)
        if h1_match:
            heading = h1_match.group(1).strip()
        else:
            # Fall back to filename without extension
            heading = Path(file_path).stem.replace("-", " ").title()

        return [{
            "file_path": file_path,
            "heading": heading,
            "content": content,
        }]

    @staticmethod
    def parse_file(file_path: str, heading_level: str = "###") -> list[dict]:
        """Parse a markdown file into a list of entries.

        Each entry is a dict with keys: file_path, heading, content.
        If the file has no headings at the specified level, the entire
        content is returned as a single entry with heading='(ungrouped)'.

        YAML frontmatter (--- delimited block at file start) is stripped
        before parsing so it does not appear in indexed content.

        Args:
            file_path: Path to the markdown file.
            heading_level: Heading prefix to split on (default '###').
                           Use '##' for threads, '###' for knowledge/work.
        """
        try:
            text = Path(file_path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return []

        text = MarkdownParser._strip_frontmatter(text)
        heading_re = MarkdownParser._get_heading_re(heading_level)
        entries = []
        matches = list(heading_re.finditer(text))

        if not matches:
            # No headings at this level — treat entire file as one entry
            content = text.strip()
            if content:
                entries.append({
                    "file_path": file_path,
                    "heading": "(ungrouped)",
                    "content": content,
                })
            return entries

        for i, match in enumerate(matches):
            heading = match.group(1).strip()
            start = match.end()
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            content = text[start:end].strip()
            entries.append({
                "file_path": file_path,
                "heading": heading,
                "content": content,
            })

        return entries
