#!/usr/bin/env python3
"""grounding-preflight.py — deterministic validator for omission claims.

Runs against reverse-auditor output before the correctness-gate adjudicates.
Pass/fail is binary; validation is mechanical (no LLM call); target runtime
is <10 ms per claim. Keeps the correctness-gate's prompt single-concern —
the gate only sees claims whose evidence pointers already resolve.

Contract lives at: $KDIR/architecture/audit-pipeline/contract.md (Reverse-
auditor output shape + Wrapper-level side effects table).

Usage:
    grounding-preflight.py [--claim <json>] [--claim-file <path>] [--repo-root <path>]

Input: one JSON object, either:
    - A full reverse-auditor output: {"omission_claim": {...}, ...}
    - Or the bare claim object: {"file": ..., "line_range": ..., ...}

Silence (`omission_claim: null` or `verdict: "no-omission"`) passes trivially
with reason "silence" — silence is not a preflight failure.

Output: a JSON object to stdout with:
    {
      "pass": bool,
      "reason": "silence | ok | file-missing | line-out-of-range |
                 snippet-mismatch | field-missing",
      "detail": "<optional, short prose>"
    }

Exit codes:
    0   validation ran to completion (pass=true or pass=false both exit 0)
    1   usage error (missing input, unparseable JSON, invalid line_range format)
    2   I/O error reading --repo-root or a claim-referenced file

Fail reasons (aligned with audit-attempts.jsonl schema in contract.md):
    file-missing          claim.file does not exist at the repo root
    line-out-of-range     line_range is outside [1, file_line_count]
    snippet-mismatch      exact_snippet does not match file content at
                          line_range, and normalized hash does not match
                          either
    field-missing         required field is absent or empty
                          (file, line_range, exact_snippet, falsifier,
                          why_it_matters / why-it-matters)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from typing import Any


REQUIRED_FIELDS = ("file", "line_range", "exact_snippet", "falsifier")
# why_it_matters accepts two casings for backward-compat with the plan's
# original spec ("why-it-matters") and the contract's preferred form
# ("why_it_matters"). At least one must be present and non-empty.
WHY_IT_MATTERS_KEYS = ("why_it_matters", "why-it-matters")

LINE_RANGE_RE = re.compile(r"^\s*(\d+)\s*-\s*(\d+)\s*$")


def normalize_snippet(s: str) -> str:
    """Apply v1 content-anchor normalization.

    1. Quote-normalize: U+2018/2019 -> ', U+201C/201D -> "
    2. Whitespace-collapse: every \\s+ -> single ASCII space
    3. Trim leading/trailing whitespace
    """
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = re.sub(r"\s+", " ", s).strip()
    return s


def normalize_hash(s: str) -> str:
    return hashlib.sha256(normalize_snippet(s).encode("utf-8")).hexdigest()


def extract_claim(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Return the bare claim object, or None for silence.

    Accepts either a full reverse-auditor output (with `omission_claim` or
    `claim` wrapper) or a bare claim dict.
    """
    # Full reverse-auditor output shape from contract.md
    if "omission_claim" in payload:
        return payload["omission_claim"]  # may be None -> silence
    # Alternative shape used in the agent template (`claim` nested field,
    # surfacing under a `verdict` discriminator).
    verdict = payload.get("verdict")
    if verdict in ("no-omission", "silence"):
        return None
    if "claim" in payload and isinstance(payload["claim"], dict):
        return payload["claim"]
    # Bare-claim shape: must carry at least one required field to be
    # distinguishable from a silence envelope.
    if any(k in payload for k in REQUIRED_FIELDS):
        return payload
    # Unknown shape -> treat as absent-claim so caller distinguishes from
    # silence via the detail field.
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


def resolve_file_path(file_field: str, repo_root: str) -> str:
    """Resolve file field to an absolute path relative to repo_root.

    Absolute paths pass through unchanged. Relative paths are joined to
    repo_root so claim payloads can cite `scripts/audit-sample.sh` without
    hardcoding the caller's cwd.
    """
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
    # 1-indexed inclusive -> 0-indexed slice
    return "\n".join(lines[start - 1 : end])


def check_snippet_match(
    file_snippet: str,
    claim_snippet: str,
    claim_hash: str | None,
) -> tuple[bool, str]:
    """Return (matches, detail).

    Exact match first. If that fails, compare normalized forms. If a
    claim-provided hash exists, also verify the hash matches the normalized
    claim snippet (guards against the claim carrying a stale hash).
    """
    if file_snippet == claim_snippet:
        return True, "exact match"
    file_norm = normalize_snippet(file_snippet)
    claim_norm = normalize_snippet(claim_snippet)
    if file_norm == claim_norm:
        # If hash is present, verify it against the claim's own normalized
        # form. A mismatched hash means the claim shipped a stale fingerprint
        # — the file still matches but the claim's metadata is inconsistent;
        # per the plan's "fail closed" discipline this is still a snippet
        # mismatch.
        if claim_hash is not None:
            expected = hashlib.sha256(claim_norm.encode("utf-8")).hexdigest()
            if expected != claim_hash:
                return False, (
                    "normalized content matches file but "
                    "claim's normalized_snippet_hash is stale"
                )
        return True, "normalized match"
    return False, "neither exact nor normalized snippet matches file content"


def validate_claim(claim: dict[str, Any], repo_root: str) -> dict[str, Any]:
    # Field presence first — cheap and gives the clearest error.
    ok, detail = check_required_fields(claim)
    if not ok:
        return {"pass": False, "reason": "field-missing", "detail": detail}

    # Parse line_range.
    parsed = parse_line_range(str(claim["line_range"]))
    if parsed is None:
        return {
            "pass": False,
            "reason": "field-missing",
            "detail": "line_range must be 'N-M' with 1 <= N <= M",
        }
    start, end = parsed

    # File existence.
    path = resolve_file_path(str(claim["file"]), repo_root)
    if not check_file_exists(path):
        return {
            "pass": False,
            "reason": "file-missing",
            "detail": f"file does not exist at repo root: {claim['file']}",
        }

    # Line-range bounds.
    try:
        lines = read_file_lines(path)
    except OSError as e:
        # I/O error — surface separately since the preflight is supposed to
        # be deterministic and this is an environmental failure.
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

    # Snippet match (exact then normalized).
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
        help="Root directory for resolving relative `file` fields. Defaults to cwd.",
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
        result = validate_claim(claim, args.repo_root)
    except RuntimeError as e:
        print(f"[preflight] I/O error: {e}", file=sys.stderr)
        return 2

    emit(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
