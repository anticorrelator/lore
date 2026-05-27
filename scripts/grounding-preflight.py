#!/usr/bin/env python3
"""grounding-preflight.py — deterministic validator for omission claims.

Runs against reverse-auditor output before the correctness-gate adjudicates.
Pass/fail is binary; validation is mechanical (no LLM call); target runtime
is <10 ms per claim. Keeps the correctness-gate's prompt single-concern —
the gate only sees claims whose evidence pointers already resolve.

Contract lives at: $KDIR/architecture/evidence/audit-pipeline-contract.md
(Grounding-preflight reason enum + Reverse-auditor wrapper effects).

Usage:
    grounding-preflight.py [--claim <json>] [--claim-file <path>]
                           [--repo-root <path>] [--no-cascade]

Input: one JSON object, either:
    - A full reverse-auditor output: {"omission_claim": {...}, ...}
    - Or the bare claim object: {"file": ..., "line_range": ..., ...}

Silence (`omission_claim: null` or `verdict: "no-omission"`) passes trivially
with reason "silence" — silence is not a preflight failure.

Output: a JSON object to stdout with:
    {
      "pass": bool,
      "reason": "silence | ok | verified-with-drift | file-missing |
                 line-out-of-range | snippet-mismatch | field-missing |
                 provenance-unknown",
      "detail": "<optional, short prose>"
    }

Exit codes:
    0   validation ran to completion (pass=true or pass=false both exit 0)
    1   usage error (missing input, unparseable JSON, invalid line_range format)
    2   I/O error reading --repo-root or a claim-referenced file

Modern path — cwd-only drift-tolerant cascade (default):

    Given a claim with `file_relative`, attempt in precedence order:
      1. git show <captured_at_sha>:<file_relative>    — line-range hash compare
      2. git show <captured_origin_ref>:<file_relative> — line-range hash compare
      3. git show origin/main:<file_relative>          — line-range hash compare
      4. git show HEAD:<file_relative>                  — substring (grep -F)
      5. git show origin/main:<file_relative>           — substring (grep -F)

    Match in 1–3 → reason=ok. Match in 4–5 only → reason=verified-with-drift.

Fail reasons (aligned with audit-attempts.jsonl schema in contract.md):
    field-missing         required claim field is absent or empty
                          (file, line_range, exact_snippet, falsifier,
                          why_it_matters / why-it-matters), or line_range
                          fails to parse
    provenance-unknown    no `git show` blob was returned in any cascade step
                          AND no substring fallback hit. Environment-class
                          failure: the cwd repo + its origin refs cannot
                          witness the claim's content
    line-out-of-range     a blob was returned in steps 1–3 but
                          line_range exceeds the blob's line count
    snippet-mismatch      blob(s) returned with valid line range(s) in
                          1–3 had hash mismatch AND no substring fallback hit
    file-missing          retained ONLY when --no-cascade is set: claim.file
                          does not exist at the on-disk repo root

Pass reasons:
    ok                    cascade matched via steps 1–3 (line/hash anchored)
    verified-with-drift   cascade matched only via steps 4–5 (substring
                          fallback after the line/hash anchor drifted)

Legacy downgrade (D5):
    A claim without `file_relative` cannot be reconciled by the cascade —
    the cascade requires a path that is meaningful inside the cwd repo's
    git refs. Such claims short-circuit to:
        {"pass": false, "reason": "provenance-unknown",
         "detail": "legacy-pre-capture"}
    The cascade is NOT attempted, and `file` is NOT used as a fallback for
    `file_relative` (registry-prefix-strip was rejected in D2).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any

# The v1 content-anchor recipe lives in exactly one place. Import via an
# explicit sys.path injection so this script works whether or not the caller
# has PYTHONPATH set to the scripts directory.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)
from snippet_normalize import normalize as normalize_snippet  # noqa: E402
from snippet_normalize import hash_normalized as normalize_hash  # noqa: E402


REQUIRED_FIELDS = ("file", "line_range", "exact_snippet", "falsifier")
# why_it_matters accepts two casings for backward-compat with the plan's
# original spec ("why-it-matters") and the contract's preferred form
# ("why_it_matters"). At least one must be present and non-empty.
WHY_IT_MATTERS_KEYS = ("why_it_matters", "why-it-matters")

LINE_RANGE_RE = re.compile(r"^\s*(\d+)\s*-\s*(\d+)\s*$")


def extract_claim(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Return the bare claim object, or None for silence.

    Accepts either a full reverse-auditor output (with `omission_claim` or
    `claim` wrapper) or a bare claim dict.
    """
    if "omission_claim" in payload:
        return payload["omission_claim"]
    verdict = payload.get("verdict")
    if verdict in ("no-omission", "silence"):
        return None
    if "claim" in payload and isinstance(payload["claim"], dict):
        return payload["claim"]
    if any(k in payload for k in REQUIRED_FIELDS):
        return payload
    return None


def check_required_fields(claim: dict[str, Any]) -> tuple[bool, str]:
    for field in REQUIRED_FIELDS:
        if not claim.get(field):
            return False, f"required field '{field}' is absent or empty"
    if not any(claim.get(k) for k in WHY_IT_MATTERS_KEYS):
        return False, (
            "required field 'why_it_matters' (or 'why-it-matters') "
            "is absent or empty"
        )
    return True, ""


def parse_line_range(line_range: str) -> tuple[int, int] | None:
    m = LINE_RANGE_RE.match(line_range)
    if not m:
        return None
    start, end = int(m.group(1)), int(m.group(2))
    if start < 1 or end < start:
        return None
    return start, end


# ---------------------------------------------------------------------------
# Legacy --no-cascade path (kept for callers that explicitly opt out of the
# cwd-cascade. The default modern path uses git show, never the on-disk file).
# ---------------------------------------------------------------------------

def resolve_file_path(file_field: str, repo_root: str) -> str:
    if os.path.isabs(file_field):
        return file_field
    return os.path.join(repo_root, file_field)


def check_file_exists(path: str) -> bool:
    return os.path.isfile(path)


def read_file_lines(path: str) -> list[str]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read().splitlines(keepends=False)


def check_line_range(lines: list[str], start: int, end: int) -> bool:
    return 1 <= start <= end <= len(lines)


def extract_snippet_from_file(lines: list[str], start: int, end: int) -> str:
    return "\n".join(lines[start - 1 : end])


def check_snippet_match(
    file_snippet: str,
    claim_snippet: str,
    claim_hash: str | None,
) -> tuple[bool, str]:
    if file_snippet == claim_snippet:
        return True, "exact match"
    file_norm = normalize_snippet(file_snippet)
    claim_norm = normalize_snippet(claim_snippet)
    if file_norm == claim_norm:
        if claim_hash is not None:
            expected = normalize_hash(claim_snippet)
            if expected != claim_hash:
                return False, (
                    "normalized content matches file but "
                    "claim's normalized_snippet_hash is stale"
                )
        return True, "normalized match"
    return False, "neither exact nor normalized snippet matches file content"


def validate_claim_no_cascade(
    claim: dict[str, Any], repo_root: str
) -> dict[str, Any]:
    """Pre-cascade behavior: file existence + line-range on disk.

    Reachable only via --no-cascade. Retains the legacy `file-missing` reason
    for callers that haven't migrated to the cwd cascade.
    """
    ok, detail = check_required_fields(claim)
    if not ok:
        return {"pass": False, "reason": "field-missing", "detail": detail}

    parsed = parse_line_range(str(claim["line_range"]))
    if parsed is None:
        return {
            "pass": False,
            "reason": "field-missing",
            "detail": "line_range must be 'N-M' with 1 <= N <= M",
        }
    start, end = parsed

    path = resolve_file_path(str(claim["file"]), repo_root)
    if not check_file_exists(path):
        return {
            "pass": False,
            "reason": "file-missing",
            "detail": f"file does not exist at repo root: {claim['file']}",
        }

    try:
        lines = read_file_lines(path)
    except OSError as e:
        raise RuntimeError(f"failed to read {path}: {e}") from e
    if not check_line_range(lines, start, end):
        return {
            "pass": False,
            "reason": "line-out-of-range",
            "detail": (
                f"line_range {start}-{end} is outside file bounds "
                f"(1-{len(lines)})"
            ),
        }

    file_snippet = extract_snippet_from_file(lines, start, end)
    matched, match_detail = check_snippet_match(
        file_snippet,
        str(claim["exact_snippet"]),
        claim.get("normalized_snippet_hash"),
    )
    if not matched:
        return {
            "pass": False,
            "reason": "snippet-mismatch",
            "detail": match_detail,
        }

    return {"pass": True, "reason": "ok", "detail": match_detail}


# ---------------------------------------------------------------------------
# Modern path — cwd-only drift-tolerant cascade.
# ---------------------------------------------------------------------------


def git_show_blob(ref: str, file_relative: str, repo_root: str) -> bytes | None:
    """Return raw blob bytes from `git show <ref>:<file_relative>`, or None.

    Returns None on any failure (ref not found, path not in that tree, git
    invocation error). The cascade silently advances to the next step.
    """
    try:
        result = subprocess.run(
            ["git", "show", f"{ref}:{file_relative}"],
            cwd=repo_root,
            capture_output=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def extract_lines_from_blob(blob: bytes, start: int, end: int) -> str | None:
    """Slice blob[start-1:end] of lines, return decoded snippet, or None.

    Returns None if the requested line range exceeds the blob's line count.
    """
    text = blob.decode("utf-8", errors="replace")
    lines = text.splitlines(keepends=False)
    if not (1 <= start <= end <= len(lines)):
        return None
    return "\n".join(lines[start - 1 : end])


def line_hash_matches(
    blob: bytes,
    start: int,
    end: int,
    claim_hash: str | None,
    claim_snippet: str,
) -> tuple[bool, str]:
    """Compare normalize_hash(blob[start-1:end]) against the claim.

    Returns:
        (True, "matched")     if hashes equal (or, when no claim_hash, the
                              extracted snippet matches normalized claim)
        (False, "range")      if line_range exceeds blob bounds
        (False, "mismatch")   if the range was valid but hashes differ
    """
    extracted = extract_lines_from_blob(blob, start, end)
    if extracted is None:
        return False, "range"
    extracted_hash = normalize_hash(extracted)
    if claim_hash:
        if extracted_hash == claim_hash.lower():
            return True, "matched"
        return False, "mismatch"
    # No claim_hash → compare against the claim's own exact_snippet hash.
    if extracted_hash == normalize_hash(claim_snippet):
        return True, "matched"
    return False, "mismatch"


def substring_present(blob: bytes, snippet: str) -> bool:
    """Literal substring presence in raw blob bytes (mirrors `grep -F`).

    Bytes comparison preserves the literal-substring semantics regardless
    of whether `snippet` carries internal newlines or non-ASCII bytes.
    """
    needle = snippet.encode("utf-8", errors="replace")
    return needle in blob


def check_content_anchor(
    claim: dict[str, Any], repo_root: str
) -> dict[str, Any]:
    """Run the five-step cwd-only drift-tolerant cascade.

    Precondition: `claim` has already passed `check_required_fields` and
    `parse_line_range`. `file_relative` presence is checked here.
    """
    file_relative = claim.get("file_relative")
    if not file_relative:
        # D5 legacy downgrade — pre-Phase-1 rows never captured this.
        return {
            "pass": False,
            "reason": "provenance-unknown",
            "detail": "legacy-pre-capture",
        }

    start, end = parse_line_range(str(claim["line_range"]))  # already validated
    claim_snippet = str(claim["exact_snippet"])
    claim_hash = claim.get("normalized_snippet_hash")

    # Build the ordered list of (ref, mode) attempts. Skip steps whose ref
    # is unavailable on the claim (captured_at_sha, captured_origin_ref).
    hash_refs: list[str] = []
    if claim.get("captured_at_sha"):
        hash_refs.append(str(claim["captured_at_sha"]))
    if claim.get("captured_origin_ref"):
        hash_refs.append(str(claim["captured_origin_ref"]))
    hash_refs.append("origin/main")
    substring_refs: list[str] = ["HEAD", "origin/main"]

    any_blob_returned = False
    saw_range_error = False
    saw_hash_mismatch = False

    # Steps 1–3: line-range hash compare on each available ref.
    for ref in hash_refs:
        blob = git_show_blob(ref, file_relative, repo_root)
        if blob is None:
            continue
        any_blob_returned = True
        matched, kind = line_hash_matches(
            blob, start, end, claim_hash, claim_snippet
        )
        if matched:
            return {
                "pass": True,
                "reason": "ok",
                "detail": f"line-hash match on {ref}",
            }
        if kind == "range":
            saw_range_error = True
        elif kind == "mismatch":
            saw_hash_mismatch = True

    # Steps 4–5: substring fallback on raw blob bytes (literal grep -F).
    for ref in substring_refs:
        blob = git_show_blob(ref, file_relative, repo_root)
        if blob is None:
            continue
        any_blob_returned = True
        if substring_present(blob, claim_snippet):
            return {
                "pass": True,
                "reason": "verified-with-drift",
                "detail": f"substring match on {ref} (line/hash anchor drifted)",
            }

    # Failure precedence: range error > hash mismatch > no provenance.
    if saw_range_error and not saw_hash_mismatch:
        return {
            "pass": False,
            "reason": "line-out-of-range",
            "detail": (
                f"line_range {start}-{end} exceeds blob length "
                f"in every ref that returned content"
            ),
        }
    if saw_hash_mismatch:
        return {
            "pass": False,
            "reason": "snippet-mismatch",
            "detail": (
                "blob(s) returned with valid line range but normalized "
                "snippet hash differed, and no substring fallback hit"
            ),
        }
    if not any_blob_returned:
        return {
            "pass": False,
            "reason": "provenance-unknown",
            "detail": (
                f"no blob reachable for {file_relative}; try `git fetch origin`"
            ),
        }
    # Defensive: blob returned but neither range nor mismatch was set
    # (substring search ran on a different ref than the hash steps and
    # also missed). Surface as provenance-unknown so the rollup bucket
    # is environmental rather than producer-class.
    return {
        "pass": False,
        "reason": "provenance-unknown",
        "detail": (
            f"blob reachable for {file_relative} but neither line-hash "
            f"nor substring fallback resolved"
        ),
    }


def validate_claim(
    claim: dict[str, Any], repo_root: str, use_cascade: bool = True
) -> dict[str, Any]:
    """Validate a claim. Default path is the cwd-cascade; `use_cascade=False`
    routes to the legacy on-disk path (file-missing reason retained)."""
    ok, detail = check_required_fields(claim)
    if not ok:
        return {"pass": False, "reason": "field-missing", "detail": detail}

    parsed = parse_line_range(str(claim["line_range"]))
    if parsed is None:
        return {
            "pass": False,
            "reason": "field-missing",
            "detail": "line_range must be 'N-M' with 1 <= N <= M",
        }

    if not use_cascade:
        return validate_claim_no_cascade(claim, repo_root)

    return check_content_anchor(claim, repo_root)


def load_input(args: argparse.Namespace) -> dict[str, Any]:
    if args.claim is not None:
        raw = args.claim
    elif args.claim_file is not None:
        try:
            with open(args.claim_file, "r", encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            print(f"[preflight] error reading --claim-file: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        raw = sys.stdin.read()
    raw = raw.strip()
    if not raw:
        print("[preflight] error: empty input", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"[preflight] error: input is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)


def emit(result: dict[str, Any]) -> None:
    print(json.dumps(result, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Deterministic validator for omission claims.",
    )
    parser.add_argument(
        "--claim",
        help="JSON claim payload (inline). Mutually exclusive with --claim-file.",
    )
    parser.add_argument(
        "--claim-file",
        help="Path to a JSON file containing the claim payload.",
    )
    parser.add_argument(
        "--repo-root",
        default=os.getcwd(),
        help="Root directory for resolving claim references. Defaults to cwd.",
    )
    parser.add_argument(
        "--no-cascade",
        action="store_true",
        help=(
            "Disable the cwd drift-tolerant cascade and use the legacy "
            "on-disk file/line check (retains the file-missing reason). "
            "Default behavior runs the cascade."
        ),
    )
    args = parser.parse_args()

    if args.claim is not None and args.claim_file is not None:
        print("[preflight] error: pass only one of --claim / --claim-file", file=sys.stderr)
        return 1

    payload = load_input(args)
    if not isinstance(payload, dict):
        print("[preflight] error: input must be a JSON object", file=sys.stderr)
        return 1

    claim = extract_claim(payload)
    if claim is None:
        emit({
            "pass": True,
            "reason": "silence",
            "detail": "reverse-auditor emitted explicit silence; preflight is a no-op",
        })
        return 0

    if not isinstance(claim, dict):
        print("[preflight] error: claim must be a JSON object", file=sys.stderr)
        return 1

    try:
        result = validate_claim(
            claim, args.repo_root, use_cascade=not args.no_cascade
        )
    except RuntimeError as e:
        print(f"[preflight] I/O error: {e}", file=sys.stderr)
        return 2

    emit(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
