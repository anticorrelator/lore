#!/usr/bin/env python3
"""reverse-auditor-inline-evidence.py — resolve the RA packet's evidence inline.

The reverse-auditor adjudicates omissions from a packet of curated claims plus
the change under audit. Production historically handed the judge *pointers*
(exact_snippet text, change_context.changed_files), forcing it to dereference
them with Read/Bash — the turn spiral that timed audits out. This script
resolves those pointers deterministically at the wrapper so the judge has
nothing left to fetch:

  - for each curated claim: its exact_snippet located in the file at HEAD with a
    +/-WINDOW line context block (claim_windows[]);
  - for each change_context.changed_files entry: the diff hunks that introduced
    the audited change (diff_hunks[]);
  - per referenced file: content_locate_verdict in
    {verified, provenance-unknown, provenance-lost}.

Resolution is a pure manifest derivation over the RA input the wrapper already
assembled (artifact_id, work_item, curated_top_k, change_context,
referenced_files). Each file is resolved against the repo that owns it (the lore
checkout for repo-relative source paths; the knowledge KDIR repo for _work/
paths). `_work/<slug>/` paths that are absent at HEAD fall back to
`_work/_archive/<slug>/` before being declared unresolved. Unresolved markers
are themselves signal: the adjudicate-only template treats an inadequate packet
as grounds to abstain rather than spin.

Usage:
    reverse-auditor-inline-evidence.py <ra-input.json> <out.json>
        [--window N] [--diff-context N]
        [--lore-repo PATH] [--kdir PATH]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_WINDOW = 8
DEFAULT_DIFF_CONTEXT = 3

# content_locate_verdict values, per the verdict-envelope contract (D5).
VERIFIED = "verified"             # file + snippet/diff resolved at HEAD (or archive)
PROVENANCE_UNKNOWN = "provenance-unknown"  # file present but snippet not located
PROVENANCE_LOST = "provenance-lost"        # file absent at HEAD and archive

# _work/<slug>/... → _work/_archive/<slug>/... rewrite. A captured path points
# at the active work-item dir; once the item is archived the dir moves under
# _archive/, so a path absent at HEAD is retried at the archive location before
# being declared lost.
_WORK_PREFIX_RE = re.compile(r"^_work/(?!_archive/)([^/]+)/(.*)$")


def git_show(repo: Path, ref: str, rel: str) -> str | None:
    """Return the text of `git show <ref>:<rel>` in `repo`, or None on failure."""
    try:
        r = subprocess.run(
            ["git", "show", f"{ref}:{rel}"],
            cwd=str(repo),
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return r.stdout


def classify_repo(file_path: str, lore_repo: Path, kdir: Path) -> tuple[Path, str]:
    """Map a fixture file reference to (repo_root, repo-relative-path).

    Three shapes appear: absolute lore-checkout paths, repo-relative source
    paths (skills/, scripts/, …), and _work/ paths that live in the KDIR
    knowledge repo rather than the lore checkout.
    """
    fp = file_path
    if fp.startswith(str(lore_repo) + os.sep):
        return lore_repo, fp[len(str(lore_repo)) + 1:]
    if fp.startswith(str(kdir) + os.sep):
        return kdir, fp[len(str(kdir)) + 1:]
    if fp.startswith("_work/"):
        return kdir, fp
    return lore_repo, fp


def archive_fallback_rel(rel: str) -> str | None:
    """Rewrite _work/<slug>/<rest> → _work/_archive/<slug>/<rest>, or None."""
    m = _WORK_PREFIX_RE.match(rel)
    if not m:
        return None
    return f"_work/_archive/{m.group(1)}/{m.group(2)}"


def show_with_archive_fallback(
    repo: Path, ref: str, rel: str
) -> tuple[str | None, str]:
    """git show at `rel`, falling back to the _archive/ path. Returns
    (text_or_None, resolved_rel) — resolved_rel names which path matched."""
    text = git_show(repo, ref, rel)
    if text is not None:
        return text, rel
    alt = archive_fallback_rel(rel)
    if alt is not None:
        text = git_show(repo, ref, alt)
        if text is not None:
            return text, alt
    return None, rel


def parse_line_range(lr: str | None) -> tuple[int, int] | None:
    if not isinstance(lr, str) or "-" not in lr:
        return None
    a, _, b = lr.partition("-")
    try:
        start, end = int(a.strip()), int(b.strip())
    except ValueError:
        return None
    if start < 1 or end < start:
        return None
    return start, end


def locate_snippet(text: str, snippet: str) -> int | None:
    """Return the 1-based start line of the first occurrence of the snippet's
    first non-empty line in `text`, or None. Anchors on content, not position,
    so a window resolves even when the captured line_range has drifted."""
    if not snippet:
        return None
    needle = next((ln for ln in snippet.splitlines() if ln.strip()), "")
    if not needle:
        return None
    for i, ln in enumerate(text.splitlines(), start=1):
        if needle in ln:
            return i
    return None


def resolve_claim_window(
    claim: dict, window: int, lore_repo: Path, kdir: Path
) -> dict:
    """Resolve one curated claim to an inlined evidence window + locate verdict."""
    file_path = claim.get("file")
    snippet = claim.get("exact_snippet")
    lr = parse_line_range(claim.get("line_range"))
    out = {
        "claim_id": claim.get("claim_id"),
        "file": file_path,
        "captured_line_range": claim.get("line_range"),
        "resolved": False,
        "resolution": None,
        "content_locate_verdict": PROVENANCE_LOST,
        "window_text": None,
        "window_line_range": None,
    }
    if not file_path:
        out["resolution"] = "no-file-reference"
        return out

    repo, rel = classify_repo(file_path, lore_repo, kdir)
    text, resolved_rel = show_with_archive_fallback(repo, "HEAD", rel)
    if text is None:
        out["resolution"] = f"file-absent-at-HEAD ({rel})"
        out["content_locate_verdict"] = PROVENANCE_LOST
        return out

    file_lines = text.splitlines()
    n = len(file_lines)

    anchor = locate_snippet(text, snippet) if snippet else None
    if anchor is not None:
        center_start, center_end = anchor, anchor
        if snippet:
            snip_lines = max(1, len(snippet.splitlines()))
            center_end = min(n, anchor + snip_lines - 1)
        resolution = "snippet-anchored"
        locate_verdict = VERIFIED
    elif lr is not None and lr[0] <= n:
        center_start, center_end = lr[0], min(lr[1], n)
        resolution = "line-range-fallback"
        # File present, snippet not located by content — the window is the
        # captured line range but provenance of the exact snippet is unknown.
        locate_verdict = PROVENANCE_UNKNOWN
    else:
        out["resolution"] = (
            "snippet-not-found-and-line-range-out-of-bounds"
            if snippet
            else "no-snippet-and-no-usable-line-range"
        )
        out["content_locate_verdict"] = PROVENANCE_UNKNOWN
        return out

    win_start = max(1, center_start - window)
    win_end = min(n, center_end + window)
    out["resolved"] = True
    out["resolution"] = resolution
    out["content_locate_verdict"] = locate_verdict
    out["resolved_file_relative"] = resolved_rel
    out["window_line_range"] = f"{win_start}-{win_end}"
    out["window_text"] = "\n".join(file_lines[win_start - 1: win_end])
    return out


def resolve_diff_hunk(
    file_path: str, diff_ref: str | None, ctx: int, lore_repo: Path, kdir: Path
) -> dict:
    """Resolve the diff hunks that introduced the audited change to one file.

    `change_context.diff_ref` is the HEAD-at-capture session boundary, which
    frequently did NOT itself touch the file. So the derivation is the file's
    most recent change commit — bounded by diff_ref when that ref is reachable
    (`git log -p -1 <diff_ref> -- <file>`), else unbounded from HEAD — not
    `git show <diff_ref> -- <file>`, which would yield an empty hunk when the
    session boundary didn't modify the file. An unresolved marker is emitted
    when the file has no reachable history at HEAD or in the archive location.
    """
    out = {
        "file": file_path,
        "resolved": False,
        "resolution": None,
        "content_locate_verdict": PROVENANCE_LOST,
        "diff_text": None,
    }
    repo, rel = classify_repo(file_path, lore_repo, kdir)

    head_text, head_rel = show_with_archive_fallback(repo, "HEAD", rel)
    diff_ref_has_file = bool(
        diff_ref and git_show(repo, diff_ref, rel) is not None
    )
    if head_text is None and not diff_ref_has_file:
        out["resolution"] = f"file-absent-at-HEAD-and-diff-ref ({rel})"
        out["content_locate_verdict"] = PROVENANCE_LOST
        return out

    # When HEAD resolution required the archive fallback, derive history from
    # the archive path the file actually lives at.
    log_rel = head_rel if head_text is not None else rel

    candidates: list[tuple[str, list[str]]] = []
    if diff_ref and diff_ref != "HEAD" and diff_ref_has_file:
        candidates.append((
            f"git log -p -1 {diff_ref[:12]} -- {log_rel}",
            ["git", "log", "-p", "-1", f"-U{ctx}", diff_ref, "--", log_rel],
        ))
    candidates.append((
        f"git log -p -1 HEAD -- {log_rel}",
        ["git", "log", "-p", "-1", f"-U{ctx}", "HEAD", "--", log_rel],
    ))

    for desc, cmd in candidates:
        try:
            r = subprocess.run(
                cmd, cwd=str(repo), capture_output=True, text=True,
                check=False, timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0 and r.stdout.strip():
            out["resolved"] = True
            out["resolution"] = desc
            out["content_locate_verdict"] = VERIFIED
            out["resolved_file_relative"] = log_rel
            out["diff_text"] = r.stdout
            return out

    # File witnessed at HEAD/diff-ref but no commit history surfaced a hunk.
    out["resolution"] = "no-commit-history-for-file"
    out["content_locate_verdict"] = PROVENANCE_UNKNOWN
    return out


def build_inlined(
    ra_input: dict, window: int, diff_ctx: int, lore_repo: Path, kdir: Path
) -> dict:
    claim_windows = [
        resolve_claim_window(c, window, lore_repo, kdir)
        for c in ra_input.get("curated_top_k", [])
    ]
    cc = ra_input.get("change_context") or {}
    diff_ref = cc.get("diff_ref")
    changed = cc.get("changed_files") or []
    diff_hunks = [
        resolve_diff_hunk(f, diff_ref, diff_ctx, lore_repo, kdir)
        for f in changed
    ]

    resolved_claims = sum(1 for w in claim_windows if w["resolved"])
    resolved_hunks = sum(1 for h in diff_hunks if h["resolved"])
    out = dict(ra_input)
    out["inlined_evidence"] = {
        "window": window,
        "diff_context": diff_ctx,
        "diff_ref": diff_ref,
        "claim_windows": claim_windows,
        "diff_hunks": diff_hunks,
        "coverage": {
            "claims_total": len(claim_windows),
            "claims_resolved": resolved_claims,
            "changed_files_total": len(diff_hunks),
            "diff_hunks_resolved": resolved_hunks,
        },
    }
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ra_input")
    ap.add_argument("out")
    ap.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    ap.add_argument("--diff-context", type=int, default=DEFAULT_DIFF_CONTEXT)
    ap.add_argument(
        "--lore-repo",
        default=os.environ.get("LORE_REPO_ROOT", os.getcwd()),
        help="Repo root for repo-relative source paths (default: cwd).",
    )
    ap.add_argument(
        "--kdir",
        default=os.environ.get("KDIR", ""),
        help="Knowledge repo root for _work/ paths.",
    )
    args = ap.parse_args()

    ra_input_path = Path(args.ra_input)
    if not ra_input_path.is_file():
        print(f"error: {ra_input_path} not found", file=sys.stderr)
        return 1
    try:
        ra_input = json.loads(ra_input_path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        print(f"error: cannot read RA input: {e}", file=sys.stderr)
        return 1

    lore_repo = Path(args.lore_repo)
    kdir = Path(args.kdir) if args.kdir else lore_repo

    inlined = build_inlined(
        ra_input, args.window, args.diff_context, lore_repo, kdir
    )
    # ensure_ascii=False keeps non-ASCII evidence (em-dashes, arrows) verbatim
    # in the packet rather than as \uXXXX escapes the judge would have to
    # mentally unescape to reproduce file content for grounding.
    Path(args.out).write_text(
        json.dumps(inlined, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    cov = inlined["inlined_evidence"]["coverage"]
    print(
        f"[inline] claims {cov['claims_resolved']}/{cov['claims_total']} "
        f"resolved, diff-hunks {cov['diff_hunks_resolved']}/"
        f"{cov['changed_files_total']} resolved",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
