#!/usr/bin/env python3
"""evidence-canonicalize-worktree-paths.py — re-express Tier 2 `file` references
that point into a removed git worktree as the repo-relative path that resolves.

A claim captured inside a temporary worktree recorded `file` as an absolute path
under that worktree. Once the worktree is reclaimed the path resolves nowhere
and the claim cannot be grounded. This driver rewrites `file` to the row's own
`file_relative` value and applies the same strip to every
`change_context.changed_files` entry under the same root — the shape
`evidence-append.sh` now writes for new captures.

Nothing about what the row asserts changes: claim text, snippet, hash, line
range, falsifier, producer identity, and capture sha stay as recorded. Only the
reference is re-expressed. That the mutation really is confined to the reference
is checked per row against the pre-image rather than assumed, and a refusal
aborts the run.

Writes go through `evidence-update.sh`, the sanctioned writer of the update
operation on task-claims.jsonl — one invocation per row.

Dry-run by default: the bare invocation classifies every row and writes nothing.
`--apply` is required to mutate. Idempotent: a repaired row no longer carries an
absolute worktree `file`, so a second run finds no candidates and writes nothing.

Deferral, not repair, when the worktree directory still exists. A dangling
prefix proves the capturing session is gone; a live one means a session may
still be appending to the same file, and `evidence-update.sh` rewrites via
read-modify-rename, so a concurrent append landing inside that window would be
lost. Deferred rows are picked up by a later run once the worktree is reclaimed.

Usage:
  python3 scripts/evidence-canonicalize-worktree-paths.py [--kdir <path>]
      [--apply --artifact-dir <dir>] [--json] [--verbose]
  python3 scripts/evidence-canonicalize-worktree-paths.py --verify
      --artifact-dir <dir> [--baseline <rev>]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

MANIFEST_NAME = "canonicalize-worktree-paths-manifest.json"
VERIFICATION_NAME = "canonicalize-worktree-paths-verification.md"

# Selects the cohort this driver repairs. Rows whose `file` is a dangling
# absolute path for some other reason (a deleted or renamed source file) are not
# repairable by a change of path form and are left alone.
WORKTREE_MARKER = "/worktrees/"


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def resolve_knowledge_dir(override: str | None) -> Path:
    if override:
        return Path(override)
    result = subprocess.run(
        [str(SCRIPT_DIR / "resolve-repo.sh")],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip())


def enumerate_files(kdir: Path) -> list[Path]:
    """Producer-log task-claims.jsonl files, depth-limited to one level.

    `_work/<slug>/verdicts/task-claims.jsonl` is a settlement verdict envelope
    that shares the filename and must never be mutated, so the walk never
    descends past the work-item directory.
    """
    paths: list[Path] = []
    work_root = kdir / "_work"
    if not work_root.is_dir():
        return paths
    for entry in sorted(work_root.iterdir()):
        if entry.name == "_archive" or not entry.is_dir():
            continue
        f = entry / "task-claims.jsonl"
        if f.is_file():
            paths.append(f)
    archive_root = work_root / "_archive"
    if archive_root.is_dir():
        for entry in sorted(archive_root.iterdir()):
            if not entry.is_dir():
                continue
            f = entry / "task-claims.jsonl"
            if f.is_file():
                paths.append(f)
    return paths


def read_rows(path: Path) -> tuple[list[str], list[tuple[int, str, dict]]]:
    """Return the file's raw lines plus every parseable object row with its line number."""
    with open(path, "r", encoding="utf-8") as fh:
        raw_lines = fh.readlines()
    rows: list[tuple[int, str, dict]] = []
    for idx, raw in enumerate(raw_lines):
        stripped = raw.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict):
            rows.append((idx + 1, stripped, row))
    return raw_lines, rows


def is_candidate(row: dict) -> bool:
    f = row.get("file")
    return isinstance(f, str) and f.startswith("/") and WORKTREE_MARKER in f


def derive_strip_prefix(row: dict) -> str | None:
    """The directory `file_relative` is relative to, derived from the row's own pair.

    This is the worktree's git root — the same root `evidence-append.sh` strips
    when it writes a new row. Deriving it from `file`/`file_relative` rather
    than from a worktree naming convention is what keeps the strip exact: the
    prefix is whatever those two values disagree by, or nothing.
    """
    f = row.get("file")
    rel = row.get("file_relative")
    if not isinstance(f, str) or not isinstance(rel, str) or not rel:
        return None
    suffix = "/" + rel
    if not f.endswith(suffix):
        return None
    prefix = f[: -len(suffix)]
    return prefix or None


def plan_row(row: dict, strip_prefix: str) -> tuple[str, list[str]]:
    """The post-mutation `file` and `changed_files` values."""
    pfx = strip_prefix + "/"
    new_file = row["file"][len(pfx) :]
    cc = row.get("change_context")
    changed = (cc.get("changed_files") if isinstance(cc, dict) else None) or []
    new_changed = [
        entry[len(pfx) :] if isinstance(entry, str) and entry.startswith(pfx) else entry
        for entry in changed
    ]
    return new_file, new_changed


def check_confinement(
    pre_row: dict,
    post_row: dict,
    strip_prefix: str,
    expected_file: str,
    expected_changed: list[str],
) -> list[str]:
    """Field-level differences between pre- and post-mutation rows that are not the reference.

    Returns a list of violations; empty means the mutation touched `file` and
    `change_context.changed_files` only. Comparison is on decoded JSON values,
    because `evidence-update.sh` re-serializes the whole line with
    `ensure_ascii=True` — a row carrying non-ASCII text gets different bytes for
    fields whose values did not change.
    """
    violations: list[str] = []
    pfx = strip_prefix + "/"

    if list(post_row.keys()) != list(pre_row.keys()):
        violations.append(
            f"key set or order changed: {list(pre_row.keys())} -> {list(post_row.keys())}"
        )

    for key in pre_row:
        if key in ("file", "change_context"):
            continue
        if key not in post_row:
            violations.append(f"field dropped: {key}")
        elif post_row[key] != pre_row[key]:
            violations.append(f"field changed outside the reference: {key}")

    if post_row.get("file") != expected_file:
        violations.append(f"file is {post_row.get('file')!r}, expected {expected_file!r}")

    pre_cc = pre_row.get("change_context")
    post_cc = post_row.get("change_context")
    if not isinstance(post_cc, dict) or not isinstance(pre_cc, dict):
        violations.append("change_context is not an object on both sides")
        return violations

    if list(post_cc.keys()) != list(pre_cc.keys()):
        violations.append(
            f"change_context key set or order changed: {list(pre_cc.keys())} -> {list(post_cc.keys())}"
        )
    for key in pre_cc:
        if key == "changed_files":
            continue
        if post_cc.get(key) != pre_cc.get(key):
            violations.append(f"change_context.{key} changed")

    pre_changed = pre_cc.get("changed_files") or []
    post_changed = post_cc.get("changed_files") or []
    if len(post_changed) != len(pre_changed):
        violations.append(
            f"changed_files length {len(pre_changed)} -> {len(post_changed)}"
        )
    else:
        for i, (before, after) in enumerate(zip(pre_changed, post_changed)):
            if after == before:
                continue
            if not (isinstance(before, str) and before.startswith(pfx)):
                violations.append(
                    f"changed_files[{i}] changed but was not under the derived prefix"
                )
            elif after != before[len(pfx) :]:
                violations.append(
                    f"changed_files[{i}] changed by something other than the derived strip"
                )
    if post_changed != expected_changed:
        violations.append("changed_files does not match the planned strip")

    return violations


def check_sibling_lines(pre_lines: list[str], post_lines: list[str], target_idx: int) -> list[str]:
    """Every line but the target must survive the rewrite unchanged.

    Lines appended after the snapshot are tolerated and reported: an append that
    landed after the writer's rename survived it. A *missing* line means a
    concurrent append was swallowed by the read-modify-rename window.
    """
    violations: list[str] = []
    if len(post_lines) < len(pre_lines):
        violations.append(
            f"file lost lines: {len(pre_lines)} -> {len(post_lines)} (concurrent append overwritten)"
        )
        return violations
    for i, before in enumerate(pre_lines):
        if i == target_idx:
            continue
        if post_lines[i] != before:
            violations.append(f"line {i + 1} changed but was not the target row")
    return violations


def call_update(target: Path, claim_id: str, merge: dict, updater: Path) -> tuple[bool, str]:
    proc = subprocess.run(
        [
            "bash",
            str(updater),
            "--task-claims-path",
            str(target),
            "--claim-id",
            claim_id,
            "--from-stdin",
            "--quiet",
        ],
        input=json.dumps(merge),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return (False, f"rc={proc.returncode} stderr={proc.stderr.strip()}")
    return (True, proc.stdout.strip())


def classify(files: list[Path]) -> tuple[list[dict], list[dict], list[dict]]:
    """Split every candidate row into repairable, deferred, and refused."""
    repairable: list[dict] = []
    deferred: list[dict] = []
    refused: list[dict] = []

    for path in files:
        _, rows = read_rows(path)
        id_counts = Counter(
            str(row.get("claim_id")) for _, _, row in rows if row.get("claim_id")
        )
        candidates = [(ln, raw, row) for ln, raw, row in rows if is_candidate(row)]
        if not candidates:
            continue

        # A live worktree prefix anywhere in the file means a session is
        # plausibly still appending to it, so no row in it is safe to rewrite.
        live_prefixes = sorted(
            {
                p
                for _, _, row in candidates
                if (p := derive_strip_prefix(row)) and os.path.isdir(p)
            }
        )

        for line_no, raw, row in candidates:
            claim_id = str(row.get("claim_id") or "")
            base = {
                "work_item": path.parent.name,
                "archived": path.parent.parent.name == "_archive",
                "task_claims_path": str(path),
                "line": line_no,
                "claim_id": claim_id,
                "pre_image_sha256": sha256_text(raw),
                "file_before": row.get("file"),
                "file_relative": row.get("file_relative"),
            }

            strip_prefix = derive_strip_prefix(row)
            if strip_prefix is None:
                refused.append(
                    {
                        **base,
                        "reason": "file does not end with '/' + file_relative, so no strip prefix is derivable",
                    }
                )
                continue

            if id_counts.get(claim_id, 0) != 1:
                refused.append(
                    {
                        **base,
                        "reason": f"claim_id occurs {id_counts.get(claim_id, 0)} times in this file; "
                        "evidence-update.sh matches the first, which would leave a sibling unrepaired",
                    }
                )
                continue

            cc = row.get("change_context")
            changed = cc.get("changed_files") if isinstance(cc, dict) else None
            if not isinstance(changed, list) or row["file"] not in changed:
                refused.append(
                    {
                        **base,
                        "reason": "change_context.changed_files does not contain `file` verbatim, "
                        "so the coupled rewrite the validator requires is not well defined",
                    }
                )
                continue

            if os.path.isdir(strip_prefix):
                deferred.append(
                    {
                        **base,
                        "strip_prefix": strip_prefix,
                        "reason": "worktree directory still exists; a session may be appending to this file",
                    }
                )
                continue

            if live_prefixes:
                deferred.append(
                    {
                        **base,
                        "strip_prefix": strip_prefix,
                        "reason": "another row in this file anchors to a live worktree "
                        f"({live_prefixes[0]}); the file has an active capturing session",
                    }
                )
                continue

            new_file, new_changed = plan_row(row, strip_prefix)
            repairable.append(
                {
                    **base,
                    "strip_prefix": strip_prefix,
                    "file_after": new_file,
                    "changed_files_before": changed,
                    "changed_files_after": new_changed,
                }
            )

    return repairable, deferred, refused


def write_manifest(dest: Path, kdir: Path, repairable: list[dict], deferred: list[dict], refused: list[dict]) -> None:
    payload = {
        "artifact": "canonicalize-worktree-paths pre-image manifest",
        "produced_by": "scripts/evidence-canonicalize-worktree-paths.py",
        "kdir": str(kdir),
        "counts": {
            "repairable": len(repairable),
            "deferred": len(deferred),
            "refused": len(refused),
        },
        "repairable": repairable,
        "deferred": deferred,
        "refused": refused,
    }
    dest.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def build_verification_report(
    kdir: Path,
    manifest_path: Path,
    planned: list[dict],
    results: dict[str, dict],
    deferred: list[dict],
    refused: list[dict],
    baseline: str | None = None,
) -> tuple[str, int]:
    """Re-derive every repaired row from the file on disk and report confinement.

    Returns the report text and the number of confinement problems found.
    """
    lines: list[str] = []
    lines.append("# Canonicalize worktree paths — post-run verification")
    lines.append("")
    source = (
        f"the knowledge store at `{baseline}`"
        if baseline
        else f"`{manifest_path.name}`"
    )
    lines.append(
        "Every row below was re-read from its `task-claims.jsonl` on disk after the run "
        f"and compared field by field against its pre-image taken from {source}. "
        "A reader who did not run the driver can confirm confinement from this report "
        "plus the knowledge store's git diff."
    )
    lines.append("")

    by_file: dict[str, list[str]] = {}
    for row in planned:
        by_file.setdefault(row["task_claims_path"], []).append(row["claim_id"])

    disk_rows: dict[tuple[str, str], dict] = {}
    for path_str in by_file:
        _, rows = read_rows(Path(path_str))
        for _, _, row in rows:
            cid = str(row.get("claim_id") or "")
            if cid:
                disk_rows[(path_str, cid)] = row

    confined = 0
    reencoded: list[str] = []
    problems: list[str] = []
    for row in planned:
        key = (row["task_claims_path"], row["claim_id"])
        post = disk_rows.get(key)
        result = results.get(row["claim_id"], {})
        if post is None:
            problems.append(f"{row['claim_id']}: not found on disk after the run")
            continue
        pre = result.get("pre_row")
        if pre is None:
            problems.append(f"{row['claim_id']}: no pre-image row captured")
            continue
        violations = check_confinement(
            pre, post, row["strip_prefix"], row["file_after"], row["changed_files_after"]
        )
        if violations:
            problems.extend(f"{row['claim_id']}: {v}" for v in violations)
        else:
            confined += 1
        if result.get("reencoded"):
            reencoded.append(row["claim_id"])

    lines.append("## Summary")
    lines.append("")
    lines.append(f"- rows repaired and re-verified as confined: {confined} / {len(planned)}")
    lines.append(f"- rows deferred (live worktree): {len(deferred)}")
    lines.append(f"- rows refused (failed a precondition): {len(refused)}")
    lines.append(
        f"- rows whose raw line bytes changed beyond the reference fields purely because "
        f"`evidence-update.sh` re-serializes with `ensure_ascii=True`: {len(reencoded)}"
    )
    lines.append("")
    if reencoded:
        lines.append(
            "Those rows carry non-ASCII text. The escape form differs from the `jq -c` "
            "output the append writer produced, so the store's git diff shows `\\uXXXX` "
            "sequences on fields whose decoded values are unchanged. Confinement above is "
            "checked on decoded JSON values, which is the level at which the fields are "
            "identical."
        )
        lines.append("")
    if problems:
        lines.append("## Confinement violations")
        lines.append("")
        for p in problems:
            lines.append(f"- {p}")
        lines.append("")

    lines.append("## Repaired rows")
    lines.append("")
    lines.append("| work item | line | claim_id | file before | file after | changed_files stripped | confined |")
    lines.append("|---|---|---|---|---|---|---|")
    for row in planned:
        key = (row["task_claims_path"], row["claim_id"])
        post = disk_rows.get(key)
        result = results.get(row["claim_id"], {})
        pre = result.get("pre_row")
        if post is None or pre is None:
            verdict = "NOT VERIFIED"
        else:
            verdict = (
                "yes"
                if not check_confinement(
                    pre, post, row["strip_prefix"], row["file_after"], row["changed_files_after"]
                )
                else "NO"
            )
        n_stripped = sum(
            1
            for b, a in zip(row["changed_files_before"], row["changed_files_after"])
            if b != a
        )
        lines.append(
            f"| {row['work_item']}{' (archived)' if row['archived'] else ''} "
            f"| {row['line']} | `{row['claim_id']}` | `{row['file_before']}` "
            f"| `{row['file_after']}` | {n_stripped}/{len(row['changed_files_before'])} | {verdict} |"
        )
    lines.append("")

    if deferred:
        lines.append("## Deferred rows")
        lines.append("")
        lines.append("| work item | line | claim_id | reason |")
        lines.append("|---|---|---|---|")
        for row in deferred:
            lines.append(
                f"| {row['work_item']} | {row['line']} | `{row['claim_id']}` | {row['reason']} |"
            )
        lines.append("")

    if refused:
        lines.append("## Refused rows")
        lines.append("")
        lines.append("| work item | line | claim_id | reason |")
        lines.append("|---|---|---|---|")
        for row in refused:
            lines.append(
                f"| {row['work_item']} | {row['line']} | `{row['claim_id']}` | {row['reason']} |"
            )
        lines.append("")

    return "\n".join(lines) + "\n", len(problems)


def git_blob(git_root: Path, path: Path, ref: str) -> str | None:
    # `git rev-parse --show-toplevel` returns a fully resolved path, so resolve
    # ours too before taking the relative form (/var vs /private/var on macOS).
    rel = path.resolve().relative_to(git_root.resolve())
    proc = subprocess.run(
        ["git", "-C", str(git_root), "show", f"{ref}:{rel}"],
        capture_output=True,
        text=True,
    )
    return proc.stdout if proc.returncode == 0 else None


def rows_by_claim_id(text: str) -> tuple[list[str], dict[str, dict]]:
    lines = text.splitlines(keepends=True)
    out: dict[str, dict] = {}
    for raw in lines:
        s = raw.strip()
        if not s:
            continue
        try:
            row = json.loads(s)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("claim_id"):
            out[str(row["claim_id"])] = row
    return lines, out


def verify_against_git(kdir: Path, artifact_dir: Path, baseline: str) -> int:
    """Re-derive the manifest and verification report from the store's committed pre-images.

    The knowledge store is a git repository, so every repaired row's pre-image
    is still available as a blob at `baseline`. Deriving both artifacts from
    there rather than from a run's memory means a reviewer can reproduce them
    without having run the backfill. `baseline` is the revision that still holds
    the pre-images: `HEAD` while the mutations are uncommitted, or the commit
    before the one that recorded them once they are committed.
    """
    proc = subprocess.run(
        ["git", "-C", str(kdir), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(f"knowledge store is not a git repository: {kdir}", file=sys.stderr)
        return 1
    git_root = Path(proc.stdout.strip())

    repaired: list[dict] = []
    outstanding: list[dict] = []
    results: dict[str, dict] = {}
    line_notes: list[str] = []

    for path in enumerate_files(kdir):
        head_text = git_blob(git_root, path, baseline)
        if head_text is None:
            continue
        head_lines, head_rows = rows_by_claim_id(head_text)
        disk_text = path.read_text(encoding="utf-8")
        disk_lines, disk_rows = rows_by_claim_id(disk_text)

        changed_line_numbers = [
            i + 1
            for i, before in enumerate(head_lines)
            if i < len(disk_lines) and disk_lines[i] != before
        ]
        if len(disk_lines) < len(head_lines):
            line_notes.append(
                f"{path.parent.name}: file lost {len(head_lines) - len(disk_lines)} line(s) since {baseline}"
            )

        touched: list[int] = []
        for claim_id, head_row in head_rows.items():
            if not is_candidate(head_row):
                continue
            strip_prefix = derive_strip_prefix(head_row)
            disk_row = disk_rows.get(claim_id)
            if strip_prefix is None or disk_row is None:
                continue
            if disk_row.get("file") == head_row.get("file"):
                live = os.path.isdir(strip_prefix)
                outstanding.append(
                    {
                        "work_item": path.parent.name,
                        "line": next(
                            (
                                i + 1
                                for i, raw in enumerate(disk_lines)
                                if raw.strip()
                                and json.loads(raw.strip()).get("claim_id") == claim_id
                            ),
                            0,
                        ),
                        "claim_id": claim_id,
                        "file": head_row.get("file"),
                        "strip_prefix": strip_prefix,
                        "reason": "worktree directory still exists; deferred"
                        if live
                        else "worktree directory absent but the row is unrepaired",
                    }
                )
                continue
            new_file, new_changed = plan_row(head_row, strip_prefix)
            head_line = next(
                (
                    i + 1
                    for i, raw in enumerate(head_lines)
                    if raw.strip() and json.loads(raw.strip()).get("claim_id") == claim_id
                ),
                0,
            )
            head_cc = head_row.get("change_context") or {}
            repaired.append(
                {
                    "work_item": path.parent.name,
                    "archived": path.parent.parent.name == "_archive",
                    "task_claims_path": str(path),
                    "line": head_line,
                    "claim_id": claim_id,
                    "pre_image_sha256": sha256_text(head_lines[head_line - 1].strip()),
                    "file_before": head_row.get("file"),
                    "file_relative": head_row.get("file_relative"),
                    "strip_prefix": strip_prefix,
                    "file_after": new_file,
                    "changed_files_before": head_cc.get("changed_files") or [],
                    "changed_files_after": new_changed,
                }
            )
            disk_raw = disk_lines[head_line - 1].strip() if head_line - 1 < len(disk_lines) else ""
            results[claim_id] = {
                "pre_row": head_row,
                "reencoded": _reencode_only_delta(
                    head_lines[head_line - 1].strip(), disk_raw, head_row, disk_row
                ),
            }
            touched.append(head_line)

        unexplained = sorted(set(changed_line_numbers) - set(touched))
        if unexplained:
            line_notes.append(
                f"{path.parent.name}: line(s) {unexplained} differ from {baseline} but are not repaired rows"
            )

    manifest_path = artifact_dir / MANIFEST_NAME
    write_manifest(manifest_path, kdir, repaired, outstanding, [])
    report, report_problems = build_verification_report(
        kdir, manifest_path, repaired, results, outstanding, [], baseline=baseline
    )
    if line_notes:
        report += f"\n## Lines differing from {baseline} that are not repaired rows\n\n"
        report += "\n".join(f"- {n}" for n in line_notes) + "\n"
    else:
        report += (
            "\nEvery line that differs from the store's committed pre-image is one of the "
            "repaired rows above; no other line in any producer log changed.\n"
        )
    (artifact_dir / VERIFICATION_NAME).write_text(report, encoding="utf-8")
    print(f"[canonicalize] pre-image manifest: {manifest_path}")
    print(f"[canonicalize] verification report: {artifact_dir / VERIFICATION_NAME}")
    print(
        f"[canonicalize] re-derived against {baseline}: {len(repaired)} repaired, "
        f"{len(outstanding)} still worktree-anchored, {report_problems} confinement problem(s), "
        f"{len(line_notes)} unexplained line delta(s)"
    )
    return 1 if (line_notes or report_problems) else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kdir", help="Override the knowledge store directory.")
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Mutate the store. Without it the driver classifies rows and writes nothing.",
    )
    parser.add_argument(
        "--artifact-dir",
        help="Directory for the pre-image manifest and verification report. Required with --apply.",
    )
    parser.add_argument(
        "--evidence-update",
        help="Path to evidence-update.sh (default: alongside this script).",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Mutate nothing; re-derive the manifest and verification report by comparing "
        "the working tree against the store's committed pre-images. Requires --artifact-dir.",
    )
    parser.add_argument(
        "--baseline",
        default="HEAD",
        help="With --verify: the store revision holding the pre-images (default HEAD). Pass the "
        "commit before the one that recorded the mutations if they have since been committed.",
    )
    parser.add_argument("--json", action="store_true", help="Emit the run summary as JSON.")
    parser.add_argument("--verbose", action="store_true", help="Per-row progress.")
    args = parser.parse_args(argv)

    kdir = resolve_knowledge_dir(args.kdir)
    if not kdir.is_dir():
        print(f"knowledge store not found at: {kdir}", file=sys.stderr)
        return 1

    updater = Path(args.evidence_update) if args.evidence_update else SCRIPT_DIR / "evidence-update.sh"
    if args.apply and not updater.is_file():
        print(f"evidence-update.sh not found at: {updater}", file=sys.stderr)
        return 1

    if args.apply and args.verify:
        print("--apply and --verify are mutually exclusive", file=sys.stderr)
        return 1

    artifact_dir: Path | None = None
    if args.apply or args.verify:
        if not args.artifact_dir:
            flag = "--apply" if args.apply else "--verify"
            print(f"{flag} requires --artifact-dir for the manifest and verification report", file=sys.stderr)
            return 1
        artifact_dir = Path(args.artifact_dir)
        if not artifact_dir.is_dir():
            print(f"artifact dir not found: {artifact_dir}", file=sys.stderr)
            return 1

    if args.verify:
        assert artifact_dir is not None
        return verify_against_git(kdir, artifact_dir, args.baseline)

    files = enumerate_files(kdir)
    repairable, deferred, refused = classify(files)

    summary = {
        "kdir": str(kdir),
        "producer_log_files": len(files),
        "candidates": len(repairable) + len(deferred) + len(refused),
        "repairable": len(repairable),
        "deferred": len(deferred),
        "refused": len(refused),
        "applied": 0,
        "noop": 0,
        "mode": "apply" if args.apply else "dry-run",
    }

    if not args.apply:
        if args.json:
            print(json.dumps({**summary, "rows": repairable, "deferred_rows": deferred, "refused_rows": refused}, indent=2))
        else:
            print(f"[canonicalize] dry-run over {len(files)} producer-log files under {kdir}/_work")
            print(f"[canonicalize] candidates {summary['candidates']}: "
                  f"{len(repairable)} repairable, {len(deferred)} deferred, {len(refused)} refused")
            for row in repairable if args.verbose else []:
                print(f"  would repair {row['work_item']}:{row['line']} {row['claim_id']}: "
                      f"{row['file_before']} -> {row['file_after']}")
            for row in refused:
                print(f"  REFUSED {row['work_item']}:{row['line']} {row['claim_id']}: {row['reason']}")
            print("[canonicalize] dry-run wrote nothing; pass --apply --artifact-dir <dir> to mutate")
        return 1 if refused else 0

    assert artifact_dir is not None
    if not repairable and not refused:
        # Nothing to mutate means nothing to record. Writing the artifacts here
        # would replace the ones describing the run that did the work.
        print(f"[canonicalize] nothing to repair; {len(deferred)} deferred, wrote nothing")
        if args.json:
            print(json.dumps(summary, indent=2))
        return 0

    manifest_path = artifact_dir / MANIFEST_NAME
    write_manifest(manifest_path, kdir, repairable, deferred, refused)
    print(f"[canonicalize] pre-image manifest: {manifest_path}")

    if refused:
        for row in refused:
            print(f"[canonicalize] REFUSED {row['work_item']}:{row['line']} "
                  f"{row['claim_id']}: {row['reason']}", file=sys.stderr)
        print(f"[canonicalize] {len(refused)} row(s) failed a precondition; nothing mutated", file=sys.stderr)
        return 1

    results: dict[str, dict] = {}
    for row in repairable:
        target = Path(row["task_claims_path"])
        pre_lines, pre_rows = read_rows(target)
        pre_row = next(
            (r for _, _, r in pre_rows if str(r.get("claim_id") or "") == row["claim_id"]),
            None,
        )
        if pre_row is None:
            print(f"[canonicalize] row vanished before mutation: {row['claim_id']}", file=sys.stderr)
            return 1
        target_idx = row["line"] - 1
        pre_raw = pre_lines[target_idx].strip()
        if sha256_text(pre_raw) != row["pre_image_sha256"]:
            print(f"[canonicalize] pre-image changed under us: {row['claim_id']} at "
                  f"{target}:{row['line']}", file=sys.stderr)
            return 1

        merge = {
            "file": row["file_after"],
            "change_context": {
                **pre_row["change_context"],
                "changed_files": row["changed_files_after"],
            },
        }
        ok, detail = call_update(target, row["claim_id"], merge, updater)
        if not ok:
            print(f"[canonicalize] evidence-update.sh rejected {row['claim_id']}: {detail}", file=sys.stderr)
            return 1

        post_lines, post_rows = read_rows(target)
        post_row = next(
            (r for _, _, r in post_rows if str(r.get("claim_id") or "") == row["claim_id"]),
            None,
        )
        if post_row is None:
            print(f"[canonicalize] row missing after mutation: {row['claim_id']}", file=sys.stderr)
            return 1

        violations = check_confinement(
            pre_row, post_row, row["strip_prefix"], row["file_after"], row["changed_files_after"]
        )
        violations += check_sibling_lines(pre_lines, post_lines, target_idx)
        if violations:
            print(f"[canonicalize] CONFINEMENT VIOLATION on {row['claim_id']} at "
                  f"{target}:{row['line']}", file=sys.stderr)
            for v in violations:
                print(f"    {v}", file=sys.stderr)
            print("[canonicalize] stopping; the store holds every mutation up to and "
                  "including this row", file=sys.stderr)
            return 1

        post_raw = post_lines[target_idx].strip()
        reencoded = _reencode_only_delta(pre_raw, post_raw, pre_row, post_row)
        results[row["claim_id"]] = {"pre_row": pre_row, "reencoded": reencoded}
        summary["noop" if post_raw == pre_raw else "applied"] += 1
        if args.verbose:
            print(f"  repaired {row['work_item']}:{row['line']} {row['claim_id']}: "
                  f"{row['file_before']} -> {row['file_after']}")

    report_path = artifact_dir / VERIFICATION_NAME
    report_text, report_problems = build_verification_report(
        kdir, manifest_path, repairable, results, deferred, refused
    )
    report_path.write_text(report_text, encoding="utf-8")
    print(f"[canonicalize] verification report: {report_path}")

    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"[canonicalize] repaired {summary['applied']}, no-op {summary['noop']}, "
              f"deferred {summary['deferred']}, refused {summary['refused']}")
    return 0


def _reencode_only_delta(pre_raw: str, post_raw: str, pre_row: dict, post_row: dict) -> bool:
    """True when the raw line's bytes changed beyond the reference fields without any value changing.

    `evidence-update.sh` re-serializes the whole line with Python's default
    `ensure_ascii=True`, so a row containing non-ASCII text comes back with
    `\\uXXXX` escapes where `jq -c` had written raw UTF-8. Flagging it keeps the
    verification report honest about what a reader of the git diff will see.
    """
    if pre_raw == post_raw:
        return False
    neutral_pre = dict(pre_row)
    neutral_post = dict(post_row)
    for d in (neutral_pre, neutral_post):
        d.pop("file", None)
        cc = d.get("change_context")
        if isinstance(cc, dict):
            cc = dict(cc)
            cc.pop("changed_files", None)
            d["change_context"] = cc
    if neutral_pre != neutral_post:
        return False
    return any(ord(c) > 127 for c in pre_raw)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
