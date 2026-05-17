#!/usr/bin/env python3
"""Content-anchor normalization (v1) — single source of truth.

The v1 recipe is:
  1. Quote-normalize: U+2018, U+2019 -> ASCII ', and U+201C, U+201D -> ASCII "
  2. Whitespace-collapse: every run of `\\s+` -> a single ASCII space
  3. Trim leading/trailing whitespace
  4. Hash: sha256 over the UTF-8 bytes of the normalized string; full 64-char
     lowercase hex.

This module is the ONLY place the recipe is implemented. Bash callers invoke
it via stdin:

    python3 "$SCRIPT_DIR/snippet_normalize.py" --normalize < snippet.txt
    python3 "$SCRIPT_DIR/snippet_normalize.py" --hash      < snippet.txt

Python callers import directly (set PYTHONPATH to the scripts dir).
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys


_CURLY_SINGLE_OPEN = "‘"
_CURLY_SINGLE_CLOSE = "’"
_CURLY_DOUBLE_OPEN = "“"
_CURLY_DOUBLE_CLOSE = "”"

_WHITESPACE_RE = re.compile(r"\s+")


def normalize(text: str) -> str:
    """Apply the v1 content-anchor normalization recipe."""
    s = text.replace(_CURLY_SINGLE_OPEN, "'").replace(_CURLY_SINGLE_CLOSE, "'")
    s = s.replace(_CURLY_DOUBLE_OPEN, '"').replace(_CURLY_DOUBLE_CLOSE, '"')
    s = _WHITESPACE_RE.sub(" ", s).strip()
    return s


def hash_normalized(text: str) -> str:
    """sha256 hex (lowercase, 64 chars) over the UTF-8 bytes of normalize(text)."""
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Apply v1 content-anchor normalization (read snippet from stdin).",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--normalize",
        action="store_true",
        help="Print the normalized snippet to stdout (no trailing newline).",
    )
    group.add_argument(
        "--hash",
        action="store_true",
        help="Print sha256(normalize(snippet)) as 64-char lowercase hex.",
    )
    args = parser.parse_args(argv)

    raw = sys.stdin.read()
    if args.normalize:
        sys.stdout.write(normalize(raw))
        return 0
    if args.hash:
        sys.stdout.write(hash_normalized(raw))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
