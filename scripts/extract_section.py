#!/usr/bin/env python3
"""extract_section.py — Extract a section from a markdown file by heading.

Given a markdown file path and a heading name, returns just that section's content
(from the heading line through to the next heading of equal or higher level, or EOF).

Usage:
    python extract_section.py <file_path> <heading_name> [--exact]

Examples:
    python extract_section.py conventions.md "Naming Patterns"
    python extract_section.py conventions.md "naming" --exact

Both importable and CLI-callable.
"""

import argparse
import re
import sys
from pathlib import Path


def heading_level(line: str) -> int:
    """Return the heading level (number of leading #), or 0 if not a heading."""
    match = re.match(r'^(#{1,6})\s', line)
    return len(match.group(1)) if match else 0


def extract_section(filepath: str, heading_name: str, exact: bool = False) -> str | None:
    """Extract a section from a markdown file by heading name.

    Args:
        filepath: Path to the markdown file.
        heading_name: The heading text to search for (without # prefix).
        exact: If True, require exact match. If False, case-insensitive substring match.

    Returns:
        The section content (including the heading line) as a string,
        or None if the heading is not found.
    """
    path = Path(filepath)
    if not path.exists():
        return None

    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return None

    lines = text.splitlines(keepends=True)
    search = heading_name.strip()

    # Find the target heading
    start_idx = None
    start_level = 0

    for i, line in enumerate(lines):
        level = heading_level(line)
        if level == 0:
            continue
        # Extract heading text (strip # prefix and whitespace)
        heading_text = re.sub(r'^#{1,6}\s+', '', line).strip()
        if exact:
            if heading_text == search:
                start_idx = i
                start_level = level
                break
        else:
            if search.lower() in heading_text.lower():
                start_idx = i
                start_level = level
                break

    if start_idx is None:
        return None

    # Find the end of this section (next heading of same or higher level)
    end_idx = len(lines)
    for i in range(start_idx + 1, len(lines)):
        level = heading_level(lines[i])
        if level > 0 and level <= start_level:
            end_idx = i
            break

    section = ''.join(lines[start_idx:end_idx]).rstrip('\n')
    return section


def main():
    parser = argparse.ArgumentParser(
        description="Extract a section from a markdown file by heading name."
    )
    parser.add_argument("file", help="Path to the markdown file")
    parser.add_argument("heading", help="Heading text to search for")
    parser.add_argument(
        "--exact", action="store_true",
        help="Require exact heading match (default: case-insensitive substring)"
    )
    args = parser.parse_args()

    result = extract_section(args.file, args.heading, exact=args.exact)
    if result is None:
        print(f"Section '{args.heading}' not found in {args.file}", file=sys.stderr)
        sys.exit(1)
    print(result)


if __name__ == "__main__":
    main()
