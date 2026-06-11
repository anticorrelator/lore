#!/usr/bin/env python3
"""reanchor-omission-claim.py — deterministic anchor correction for RA claims.

Runs in the settlement wrapper between persisting the reverse-auditor emission
and the grounding preflight. Given one reverse-auditor output object and the
resolved repo root, it tries to locate the content the judge already quoted in
the on-disk file and rewrite the claim's pointer to it — so a subsequent
`--no-cascade` preflight pass certifies a *true* anchor.

Authority boundary: this corrects the anchor for content the judge quoted; it
never infers, repairs, or substitutes evidence. No fuzzy content rewriting, no
picking the "closest" of several matches, no synthesizing a snippet the judge
did not claim. A non-unique or absent match leaves the claim untouched, and the
preflight fails it exactly as it would today.

Contract:
    Input  — one JSON object on stdin (or --claim-file): a full reverse-auditor
             output with an `omission_claim` object (or a bare claim). Silence
             (`omission_claim: null`, or `verdict`/`coverage_state` indicating
             no claim) passes through verbatim.
    Output — exactly one JSON object on stdout: the (possibly rewritten) input.
             Diagnostics go to stderr ONLY — one stray stdout byte fails every
             settlement run with unparseable-JSON.
    Exit   — 0 for both a successful rewrite AND a no-match pass-through.
             Non-zero is reserved for tool errors (malformed input, unreadable
             file, hash recomputation failure); the wrapper warns and passes the
             ORIGINAL claim to preflight on any non-zero exit.

Search ladder (first rung yielding a UNIQUE match wins):
    1. exact-substring        — exact_snippet appears verbatim in the file
    2. diff-prefix-strip      — every snippet line carries a `+`/`-`/space diff
                                marker; strip leading markers and match the
                                post-image (`-`-only deleted content is rejected)
    3. whitespace-normalized  — match the v1-normalized snippet against
                                v1-normalized file windows of equal line count

On a unique match the claim's `line_range`, `exact_snippet`, and
`normalized_snippet_hash` are rewritten to the verbatim file content at the
located range, and a `reanchor` provenance block is added (original snippet,
original line_range, ladder rung). Ambiguous (multiple) or absent matches leave
the claim unchanged with no provenance block.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
from snippet_normalize import normalize as normalize_snippet  # noqa: E402
from snippet_normalize import hash_normalized as normalize_hash  # noqa: E402


# Mirrors grounding-preflight's REQUIRED_FIELDS detector for the bare-claim form.
_CLAIM_MARKER_FIELDS = ("file", "line_range", "exact_snippet", "falsifier")


def log(msg: str) -> None:
    """Diagnostics to stderr only — stdout is reserved for the one JSON object."""
    print(f"[reanchor] {msg}", file=sys.stderr)


def extract_claim(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Return the bare omission_claim object, or None when there is no claim.

    Accepts a full reverse-auditor output (`omission_claim` wrapper) or a bare
    claim dict. Silence and abstention carry no claim and return None.
    """
    if "omission_claim" in payload:
        oc = payload["omission_claim"]
        return oc if isinstance(oc, dict) else None
    if payload.get("verdict") in ("no-omission", "silence"):
        return None
    if payload.get("coverage_state") == "insufficient-evidence":
        return None
    if any(k in payload for k in _CLAIM_MARKER_FIELDS):
        return payload
    return None


def read_file_lines(path: str) -> list[str]:
    """Read on-disk file lines, matching grounding-preflight's slicing basis.

    `splitlines(keepends=False)` + later `"\\n".join(...)` is exactly how the
    --no-cascade validator reconstructs a snippet from a line range, so the
    rewritten anchor round-trips through that validator unchanged.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines(keepends=False)


def snippet_at(lines: list[str], start: int, end: int) -> str:
    """Verbatim file content at the 1-based inclusive line range [start, end]."""
    return "\n".join(lines[start - 1 : end])


def _find_block(
    file_lines: list[str], needle_lines: list[str]
) -> list[tuple[int, int]]:
    """Exact line-block matches of `needle_lines` within `file_lines`.

    Returns 1-based inclusive (start, end) ranges. Multiple hits → ambiguous.
    """
    matches: list[tuple[int, int]] = []
    n = len(needle_lines)
    if n == 0:
        return matches
    for i in range(0, len(file_lines) - n + 1):
        if file_lines[i : i + n] == needle_lines:
            matches.append((i + 1, i + n))
    return matches


def _strip_diff_prefixes(snippet: str) -> str | None:
    """Strip leading diff markers from every line, returning the post-image.

    Requires every line to begin with `+`, `-`, or a space (a real diff hunk
    body). A line carrying only `-`-prefixed (deleted) content quotes content
    that is no longer in the post-image file, so the whole snippet is rejected
    (returns None) rather than re-anchored to deleted code.
    """
    lines = snippet.split("\n")
    post_image: list[str] = []
    saw_marker = False
    for line in lines:
        if line == "":
            # Tolerate a trailing blank line from a snippet ending in newline.
            post_image.append("")
            continue
        marker = line[0]
        if marker not in ("+", "-", " "):
            return None
        saw_marker = True
        if marker == "-":
            # Deleted line — not part of the post-image file content.
            continue
        post_image.append(line[1:])
    if not saw_marker or not post_image:
        return None
    return "\n".join(post_image)


def _find_normalized_block(
    file_lines: list[str], needle_lines: list[str]
) -> list[tuple[int, int]]:
    """Match a snippet against equal-length file windows under v1 normalization.

    Compares the normalized whole snippet to the normalized join of each
    candidate window of the same line count. Returns 1-based inclusive ranges.
    """
    matches: list[tuple[int, int]] = []
    n = len(needle_lines)
    if n == 0:
        return matches
    needle_norm = normalize_snippet("\n".join(needle_lines))
    for i in range(0, len(file_lines) - n + 1):
        window = "\n".join(file_lines[i : i + n])
        if normalize_snippet(window) == needle_norm:
            matches.append((i + 1, i + n))
    return matches


def locate(
    file_lines: list[str], exact_snippet: str
) -> tuple[int, int, str] | None:
    """Run the search ladder; return (start, end, rung) for a UNIQUE match.

    Returns None when no rung yields a match or the first matching rung is
    ambiguous (more than one hit). Rungs are tried in order; the first rung
    that produces any match decides the outcome — a later rung never rescues
    an ambiguous earlier one (that would be guessing past the judge's intent).
    """
    # Rung 1: exact substring (whole-snippet line block).
    exact_lines = exact_snippet.split("\n")
    hits = _find_block(file_lines, exact_lines)
    if hits:
        return (*hits[0], "exact-substring") if len(hits) == 1 else None

    # Rung 2: diff-prefix-strip — quote a diff hunk body, match the post-image.
    post_image = _strip_diff_prefixes(exact_snippet)
    if post_image is not None:
        hits = _find_block(file_lines, post_image.split("\n"))
        if hits:
            return (*hits[0], "diff-prefix-strip") if len(hits) == 1 else None

    # Rung 3: whitespace-normalized line-sequence match.
    hits = _find_normalized_block(file_lines, exact_lines)
    if hits:
        return (*hits[0], "whitespace-normalized") if len(hits) == 1 else None

    return None


def resolve_file_path(file_field: str, repo_root: str) -> str:
    if os.path.isabs(file_field):
        return file_field
    return os.path.join(repo_root, file_field)


def reanchor_claim(claim: dict[str, Any], repo_root: str) -> bool:
    """Attempt to re-anchor `claim` in place. Return True iff rewritten.

    Raises RuntimeError on a tool error (unreadable file, hash failure) so the
    caller can exit non-zero and have the wrapper fall back to the original.
    """
    file_field = claim.get("file")
    exact_snippet = claim.get("exact_snippet")
    if not file_field or not exact_snippet:
        log("claim missing file or exact_snippet — passing through unchanged")
        return False

    path = resolve_file_path(str(file_field), repo_root)
    if not os.path.isfile(path):
        # Not a tool error: the file genuinely is not on disk. Let the
        # preflight render the verdict (file-missing) on the original claim.
        log(f"file not on disk: {path} — passing through unchanged")
        return False

    try:
        file_lines = read_file_lines(path)
    except OSError as e:
        raise RuntimeError(f"failed to read {path}: {e}") from e

    located = locate(file_lines, str(exact_snippet))
    if located is None:
        log("no unique confident match — passing through unchanged")
        return False

    start, end, rung = located
    new_snippet = snippet_at(file_lines, start, end)
    try:
        new_hash = normalize_hash(new_snippet)
    except Exception as e:  # pragma: no cover — hashing is total over str
        raise RuntimeError(f"hash recomputation failed: {e}") from e

    claim["reanchor"] = {
        "original_line_range": claim.get("line_range"),
        "original_exact_snippet": claim.get("exact_snippet"),
        "ladder_rung": rung,
    }
    claim["line_range"] = f"{start}-{end}"
    claim["exact_snippet"] = new_snippet
    claim["normalized_snippet_hash"] = new_hash
    log(f"re-anchored to {start}-{end} via {rung}")
    return True


def load_input(args: argparse.Namespace) -> Any:
    if args.claim_file is not None:
        with open(args.claim_file, "r", encoding="utf-8") as fh:
            raw = fh.read()
    else:
        raw = sys.stdin.read()
    raw = raw.strip()
    if not raw:
        raise ValueError("empty input")
    return json.loads(raw)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Deterministically re-anchor a reverse-auditor omission claim.",
    )
    parser.add_argument(
        "--claim-file",
        help="Path to a JSON file with the reverse-auditor output (else stdin).",
    )
    parser.add_argument(
        "--repo-root",
        default=os.getcwd(),
        help="Root for resolving the claim's relative file path. Defaults to cwd.",
    )
    args = parser.parse_args()

    # Tool errors (malformed input) → non-zero; wrapper falls back to original.
    try:
        payload = load_input(args)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        log(f"error: could not read input: {e}")
        return 1
    if not isinstance(payload, dict):
        log("error: input must be a JSON object")
        return 1

    claim = extract_claim(payload)
    if claim is None:
        # Silence / abstention / no claim — emit verbatim, exit 0.
        sys.stdout.write(json.dumps(payload, ensure_ascii=False))
        return 0

    try:
        reanchor_claim(claim, args.repo_root)
    except RuntimeError as e:
        log(f"error: {e}")
        return 2

    # The claim object was mutated in place inside `payload` (it is the same
    # dict reference for the omission_claim / bare-claim form), so re-serialize
    # the whole payload. ensure_ascii=False keeps non-ASCII evidence verbatim.
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
