#!/usr/bin/env python3
"""falsifier-run.py — pure no-write runner for executable falsifiers.

Executes the optional `executable_falsifier` recorded on a producer row
(Tier 2 task-claims, Tier 3 observations, promoted-commons producer rows)
and reports whether the command's output matches the recorded shape.
Modeled on grounding-preflight.py's verdict/exit contract; the subprocess
harness (timeout / parse / graceful fallback) follows the settlement
relevance-hook and executor precedents.

This script performs NO writes: no ledger append, no entry mutation, no
enqueue. It emits evidence; the commons gate owns whether the claim holds.
Orchestrators that want the result durably recorded wrap this runner and
own the write, mirroring the drift-sweep planner/orchestrator split.

Usage:
    falsifier-run.py [--row <json>] [--row-file <path>]
                     [--repo-root <path>] [--timeout <seconds>]

Input: one JSON object, either:
    - A full producer row: {"claim_id": ..., "executable_falsifier": {...}, ...}
    - Or the bare falsifier object: {"command": ..., "expected_output_shape": ...}

Field shape (validated additively by validate-tier2.sh / validate-tier3.sh /
promote-commons-append.sh — never required):
    command               non-empty string; run via `bash -c` so recorded
                          commands may use pipes/redirects
    expected_output_shape non-empty string; a Python regex re.search()ed
                          against the command's stdout
    root                  optional non-empty string; working directory for
                          the command — absolute, or relative to --repo-root

A row WITHOUT the field is skipped silently: {"pass": null, "reason":
"skipped"} on stdout, exit 0 — mirroring grounding-preflight's trivial
"silence" verdict so batch drivers need no pre-filtering.

Commands run from --repo-root (defaults to cwd — grounding-preflight's
precedent: the source repo the claims anchor against), unless the falsifier
names its own `root`.

Output: a JSON object to stdout with:
    {
      "pass": true | false | null,
      "reason": "matched | output-mismatch | command-failed | timeout |
                 malformed-falsifier | runner-error | skipped",
      "detail": "<optional, short prose>"
    }

Verdict rules (definite, no judgment):
    matched              command exited 0 AND re.search(expected_output_shape,
                         stdout) hit                          -> pass=true
    output-mismatch      command exited 0, regex did not hit  -> pass=false
    command-failed       command exited non-zero (output not consulted)
                                                              -> pass=false
    timeout              command exceeded --timeout           -> pass=false
    malformed-falsifier  field present but wrong shape, regex does not
                         compile, or row-named root missing   -> pass=false
    runner-error         unexpected execution failure (OSError etc.)
                                                              -> pass=false
    skipped              row carries no executable_falsifier  -> pass=null

Exit codes (grounding-preflight contract):
    0   run completed (pass=true, pass=false, and skipped all exit 0)
    1   usage error (bad flags, empty/unparseable input, non-object input)
    2   I/O error (--row-file unreadable, --repo-root missing)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any

DEFAULT_TIMEOUT_SECONDS = 10
_STDOUT_TAIL = 300
_STDERR_TAIL = 300


def load_input(args: argparse.Namespace) -> dict[str, Any]:
    if args.row is not None:
        raw = args.row
    elif args.row_file is not None:
        try:
            with open(args.row_file, "r", encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            print(f"[falsifier-run] error reading --row-file: {e}", file=sys.stderr)
            sys.exit(2)
    else:
        raw = sys.stdin.read()
    raw = raw.strip()
    if not raw:
        print("[falsifier-run] error: empty input", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"[falsifier-run] error: input is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)


def extract_falsifier(payload: dict[str, Any]) -> Any:
    """Return the falsifier object, or None when the row carries none.

    A full producer row nominates it under `executable_falsifier`; a bare
    object (both required keys at top level) is accepted as the falsifier
    itself, mirroring grounding-preflight's row-or-bare-claim leniency.
    """
    if "executable_falsifier" in payload:
        return payload["executable_falsifier"]
    if "command" in payload and "expected_output_shape" in payload:
        return payload
    return None


def malformed(detail: str) -> dict[str, Any]:
    return {"pass": False, "reason": "malformed-falsifier", "detail": detail}


def run_falsifier(
    falsifier: dict[str, Any], repo_root: str, timeout: int
) -> dict[str, Any]:
    command = falsifier.get("command")
    shape = falsifier.get("expected_output_shape")
    if not isinstance(command, str) or not command.strip():
        return malformed("command must be a non-empty string")
    if not isinstance(shape, str) or not shape.strip():
        return malformed("expected_output_shape must be a non-empty string")

    run_root = repo_root
    if "root" in falsifier:
        root = falsifier["root"]
        if not isinstance(root, str) or not root.strip():
            return malformed("root, when present, must be a non-empty string")
        run_root = root if os.path.isabs(root) else os.path.join(repo_root, root)
        if not os.path.isdir(run_root):
            return malformed(f"row-named root does not exist: {run_root}")

    try:
        pattern = re.compile(shape)
    except re.error as e:
        return malformed(f"expected_output_shape is not a valid regex: {e}")

    try:
        proc = subprocess.run(
            ["bash", "-c", command],
            cwd=run_root,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return {
            "pass": False,
            "reason": "timeout",
            "detail": f"command exceeded {timeout}s",
        }
    except OSError as exc:
        return {"pass": False, "reason": "runner-error", "detail": str(exc)[-_STDERR_TAIL:]}

    if proc.returncode != 0:
        return {
            "pass": False,
            "reason": "command-failed",
            "detail": f"exit {proc.returncode}; stderr tail: {proc.stderr[-_STDERR_TAIL:]}",
        }
    if pattern.search(proc.stdout):
        return {
            "pass": True,
            "reason": "matched",
            "detail": f"stdout matched /{shape}/",
        }
    return {
        "pass": False,
        "reason": "output-mismatch",
        "detail": f"stdout did not match /{shape}/; stdout tail: {proc.stdout[-_STDOUT_TAIL:]}",
    }


def emit(result: dict[str, Any]) -> None:
    print(json.dumps(result, indent=2))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pure no-write runner for executable falsifiers.",
    )
    parser.add_argument(
        "--row",
        help="JSON row or bare falsifier object (inline). Mutually exclusive with --row-file.",
    )
    parser.add_argument(
        "--row-file",
        help="Path to a JSON file containing the row.",
    )
    parser.add_argument(
        "--repo-root",
        default=os.getcwd(),
        help="Working directory for the command. Defaults to cwd.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"Per-command timeout in seconds (default {DEFAULT_TIMEOUT_SECONDS}).",
    )
    args = parser.parse_args()

    if args.row is not None and args.row_file is not None:
        print("[falsifier-run] error: pass only one of --row / --row-file", file=sys.stderr)
        return 1

    if not os.path.isdir(args.repo_root):
        print(f"[falsifier-run] I/O error: --repo-root is not a directory: {args.repo_root}", file=sys.stderr)
        return 2

    payload = load_input(args)
    if not isinstance(payload, dict):
        print("[falsifier-run] error: input must be a JSON object", file=sys.stderr)
        return 1

    falsifier = extract_falsifier(payload)
    if falsifier is None:
        emit({
            "pass": None,
            "reason": "skipped",
            "detail": "row carries no executable_falsifier; nothing to run",
        })
        return 0

    if not isinstance(falsifier, dict):
        emit(malformed("executable_falsifier must be an object"))
        return 0

    emit(run_falsifier(falsifier, args.repo_root, args.timeout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
