#!/usr/bin/env python3
"""evidence-backfill-snippets.py — one-time Tier 2 snippet+hash backfill.

Walks `$KDIR/_work/*/task-claims.jsonl` AND `$KDIR/_work/_archive/*/task-claims.jsonl`,
recovers each row's source bytes via `git show <captured_at_sha>:<file>`,
slices by `line_range`, applies the v1 content-anchor normalization recipe
from `scripts/snippet_normalize.py`, computes the sha256, and writes the
result back through the sole-writer `scripts/evidence-update.sh`.

Rows whose source bytes are unrecoverable (sha unreachable, file no longer in
tree at that sha, line_range out of range, etc.) are marked
`provenance: "legacy-no-snippet"` — the explicit slow-path terminal state
defined in `architecture/artifacts/tier2-evidence-schema.md`. The migration
writer is the only sanctioned emitter of this marker.

Per D2 in the phase plan, every post-migration row ends in exactly one of two
exclusive terminal states (validated by `scripts/validate-tier2.sh`):

  fast-path  — exact_snippet + normalized_snippet_hash matching
               sha256(v1_normalize(exact_snippet)); no legacy marker.
  slow-path  — provenance == "legacy-no-snippet"; snippet/hash absent.

Idempotent: re-running over a fully-migrated store is a no-op. Rows already in
the fast-path are skipped. Rows in the slow-path are re-evaluated: if the
source bytes are now recoverable (e.g. a new commit reachable from HEAD covers
the previously-unreachable sha), the legacy marker is stripped and snippet+hash
are populated — the D2 state-2 → state-1 transition.

Origin-preserving: `producer_role` is never mutated. The update writer
enforces this at the writer level too.

Usage:
  python3 scripts/evidence-backfill-snippets.py [--kdir <path>] [--dry-run]
                                                [--repo-root <path>]
                                                [--verbose]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import snippet_normalize  # noqa: E402


HASH_RE = re.compile(r"^[0-9a-f]{64}$")

# Deterministic scale-id aliases for canonical renames that happened after some
# rows were originally captured. The migration applies these when marking a row
# legacy (slow-path terminal state) so the row passes validate-tier2.sh's
# scale-registry enum check. This is a one-time rename map, not a schema
# extension: the canonical ids in scripts/scale-registry.sh are the truth; this
# table only renames deprecated aliases at migration boundary. Add entries here
# ONLY for canonical renames that have a 1:1 mapping; ambiguous cases stay as
# surfaced concerns.
_SCALE_ALIAS_REMAP = {
    "architectural": "architecture",
}


def row_is_verdict_envelope(row: dict) -> bool:
    """True when the row is a settlement-pipeline verdict envelope, not a Tier 2 producer row.

    Verdict envelopes carry `judge` / `judge_template_version` / `verdicts[]`
    and lack the producer fields (`claim_id`, `tier`). They got commingled
    into task-claims.jsonl via an upstream writer-pipeline bug. The migration
    quarantines them to a sibling `verdict-envelopes.jsonl` so the producer
    file ends up containing only Tier 2 producer rows.

    Detection is OR-on-judge-fields AND AND-on-missing-producer-fields, so a
    legitimate producer row that happens to mention "judge" as a value
    (rather than carry the field) is unaffected.
    """
    has_judge_fields = (
        "verdicts" in row
        or "judge" in row
        or "judge_template_version" in row
        or "judge_run_at" in row
        or "artifact_id" in row
    )
    has_producer_fields = bool(row.get("claim_id")) or bool(row.get("tier"))
    return has_judge_fields and not has_producer_fields


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


def resolve_repo_root(override: str | None) -> Path:
    if override:
        return Path(override)
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(result.stdout.strip())


def row_is_compliant(row: dict) -> bool:
    """True when the row is already in the D2 fast-path terminal state."""
    snippet = row.get("exact_snippet")
    h = row.get("normalized_snippet_hash")
    if not isinstance(snippet, str) or not snippet:
        return False
    if not isinstance(h, str) or not HASH_RE.match(h):
        return False
    if row.get("provenance") == "legacy-no-snippet":
        return False
    try:
        expected = snippet_normalize.hash_normalized(snippet)
    except Exception:
        return False
    return expected == h


def row_is_legacy_marked(row: dict) -> bool:
    """True when the row is in the D2 slow-path terminal state."""
    return (
        row.get("provenance") == "legacy-no-snippet"
        and not row.get("exact_snippet")
        and not row.get("normalized_snippet_hash")
    )


# Required Tier 2 fields outside the snippet/hash/provenance triad. Rows missing
# any of these CANNOT pass validate-tier2.sh post-mutation regardless of what we
# set for snippet/hash, so the migration short-circuits them into a separate
# bucket. The validator (and thus the strict cutover) treats them as out-of-
# scope for Phase 2.
#
# `change_context` is NOT in this list: the D2 grandfather waiver in
# validate-tier2.sh permits slow-path (legacy-no-snippet) rows to omit it,
# which is the natural fallback for pre-Phase-1 rows. The migration will
# still recover snippet+hash when source bytes are reachable; on recovery
# failure it marks the row legacy and the row passes the (waived) validation.
_OTHER_REQUIRED_FIELDS = (
    "claim_id",
    "tier",
    "claim",
    "producer_role",
    "protocol_slot",
    "task_id",
    "phase_id",
    "scale",
    "file",
    "line_range",
    "falsifier",
    "why_this_work_needs_it",
    "captured_at_sha",
)


def row_missing_non_snippet_required_fields(row: dict) -> list[str]:
    """Return the list of required non-snippet fields that are missing.

    The migration only owns snippet/hash/provenance. Rows missing OTHER
    required fields are unmigrable — they'd be rejected by validate-tier2.sh
    post-mutation regardless of the snippet/hash work. We short-circuit them
    so the migration completes in bounded time and surfaces the gap clearly.
    """
    return [f for f in _OTHER_REQUIRED_FIELDS if row.get(f) is None]


def relativize_path(file_field: str, repo_root: Path) -> str | None:
    """Convert the producer-emitted `file` field to a repo-relative path.

    The worker template (agents/worker.md:296) instructs producers to emit
    ABSOLUTE paths. `git show <sha>:<abs-path>` fails because git wants a
    path relative to the repo root. If the absolute path is outside the
    repo, return None (unrecoverable).
    """
    if not file_field:
        return None
    p = Path(file_field)
    if not p.is_absolute():
        # Already relative — trust it. (Older rows may pre-date the absolute
        # convention.)
        return str(p)
    try:
        rel = p.relative_to(repo_root)
    except ValueError:
        return None
    return str(rel)


def parse_line_range(s: str) -> tuple[int, int] | None:
    if not s or "-" not in s:
        return None
    a, _, b = s.partition("-")
    try:
        n = int(a)
        m = int(b)
    except ValueError:
        return None
    if n < 1 or m < n:
        return None
    return (n, m)


def recover_snippet(
    row: dict,
    repo_root: Path,
    failure_counter: Counter,
) -> tuple[str, str] | None:
    """Attempt to recover (snippet, hash) for `row`.

    Returns the (snippet, hash) tuple on success, or None if any recovery
    step fails. Updates `failure_counter` with a short failure-mode tag plus
    a per-sha and per-file tag for the operator's failure-mode surfacing.
    """
    sha = row.get("captured_at_sha")
    file_field = row.get("file")
    lr_field = row.get("line_range")

    if not sha or not isinstance(sha, str):
        failure_counter["no_captured_at_sha"] += 1
        return None
    if not file_field or not isinstance(file_field, str):
        failure_counter["no_file_field"] += 1
        return None

    rel = relativize_path(file_field, repo_root)
    if rel is None:
        failure_counter["file_outside_repo"] += 1
        failure_counter[f"file_outside_repo:{file_field}"] += 1
        return None

    lr = parse_line_range(lr_field or "")
    if lr is None:
        failure_counter["bad_line_range"] += 1
        return None
    n, m = lr

    proc = subprocess.run(
        ["git", "-C", str(repo_root), "show", f"{sha}:{rel}"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.lower()
        if "exists on disk" in stderr or "not in" in stderr or "does not exist" in stderr:
            failure_counter["file_not_at_sha"] += 1
            failure_counter[f"file_not_at_sha:{rel}@{sha[:12]}"] += 1
        elif "bad revision" in stderr or "unknown revision" in stderr:
            failure_counter["sha_unreachable"] += 1
            failure_counter[f"sha_unreachable:{sha[:12]}"] += 1
        else:
            failure_counter["git_show_failed"] += 1
            failure_counter[f"git_show_failed:{sha[:12]}:{rel}"] += 1
        return None

    source = proc.stdout
    src_lines = source.split("\n")
    if m > len(src_lines):
        failure_counter["line_range_out_of_bounds"] += 1
        return None

    slice_lines = src_lines[n - 1 : m]
    snippet = "\n".join(slice_lines)
    if not snippet:
        failure_counter["empty_slice"] += 1
        return None

    try:
        h = snippet_normalize.hash_normalized(snippet)
    except Exception:
        failure_counter["hash_failed"] += 1
        return None

    return (snippet, h)


def enumerate_files(kdir: Path) -> list[Path]:
    paths: list[Path] = []
    work_root = kdir / "_work"
    if not work_root.exists():
        return paths
    for entry in sorted(work_root.iterdir()):
        if entry.name == "_archive":
            continue
        if not entry.is_dir():
            continue
        f = entry / "task-claims.jsonl"
        if f.exists():
            paths.append(f)
    archive_root = work_root / "_archive"
    if archive_root.exists():
        for entry in sorted(archive_root.iterdir()):
            if not entry.is_dir():
                continue
            f = entry / "task-claims.jsonl"
            if f.exists():
                paths.append(f)
    return paths


def call_update(
    target_path: Path,
    claim_id: str,
    merge: dict,
    dry_run: bool,
) -> tuple[bool, str]:
    """Invoke evidence-update.sh with --task-claims-path and a JSON merge."""
    if dry_run:
        return (True, f"DRY-RUN: would mutate {target_path} claim_id={claim_id} merge={merge}")
    proc = subprocess.run(
        [
            "bash",
            str(SCRIPT_DIR / "evidence-update.sh"),
            "--task-claims-path",
            str(target_path),
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
        return (False, f"evidence-update.sh failed: rc={proc.returncode} stderr={proc.stderr.strip()}")
    return (True, proc.stdout.strip())


def quarantine_verdict_envelopes(
    path: Path,
    summary: Counter,
    per_file_quarantine: dict,
    dry_run: bool,
    verbose: bool,
) -> None:
    """Split verdict envelopes out of `path` into a sibling sidecar.

    Walks task-claims.jsonl once, identifies verdict envelopes via
    `row_is_verdict_envelope`, and rewrites the file in two atomic moves:
      - producer rows go back to `task-claims.jsonl` (excluding the envelopes).
      - envelopes are appended to `<dir>/verdict-envelopes.jsonl`.

    Idempotent: if there are zero envelopes in the file, no I/O happens.
    Re-running on an already-cleaned file is a no-op.

    This is one-time data hygiene from a separate writer-pipeline bug; we do
    NOT investigate or fix the upstream contamination source here. The
    summary counter surfaces the count so a followup writer-pipeline fix has
    a starting point.
    """
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    keep_lines: list[str] = []
    envelope_lines: list[str] = []
    for raw in lines:
        stripped = raw.strip()
        if not stripped:
            keep_lines.append(raw)
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            # Not parseable — leave it for the producer-row loop to flag as malformed.
            keep_lines.append(raw)
            continue
        if not isinstance(row, dict):
            keep_lines.append(raw)
            continue
        if row_is_verdict_envelope(row):
            envelope_lines.append(raw if raw.endswith("\n") else raw + "\n")
        else:
            keep_lines.append(raw)

    n_envelopes = len(envelope_lines)
    if n_envelopes == 0:
        return

    summary["quarantined_verdict_envelopes"] += n_envelopes
    per_file_quarantine[str(path)] = n_envelopes
    if verbose:
        print(f"  [{path}] quarantining {n_envelopes} verdict envelope(s)")

    if dry_run:
        return

    sidecar = path.parent / "verdict-envelopes.jsonl"

    # Append envelopes to the sidecar (preserves earlier quarantines on
    # re-run; the producer-file cleanup is idempotent because the envelopes
    # are gone from the producer file after this pass).
    with open(sidecar, "a", encoding="utf-8") as fh:
        fh.writelines(envelope_lines)

    # Atomic rewrite of the producer file (tmp + rename).
    tmp = path.with_suffix(path.suffix + f".tmp.{path.name}")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(keep_lines)
    tmp.replace(path)


def process_file(
    path: Path,
    repo_root: Path,
    failure_counter: Counter,
    summary: Counter,
    per_file: dict,
    dry_run: bool,
    verbose: bool,
) -> None:
    with open(path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    file_summary = Counter()

    for line_no, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            summary["malformed"] += 1
            file_summary["malformed"] += 1
            continue
        if not isinstance(row, dict):
            summary["malformed"] += 1
            file_summary["malformed"] += 1
            continue

        claim_id = row.get("claim_id")
        if not claim_id:
            summary["missing_claim_id"] += 1
            file_summary["missing_claim_id"] += 1
            continue

        # State 1: fully compliant — skip.
        if row_is_compliant(row):
            summary["already_compliant"] += 1
            file_summary["already_compliant"] += 1
            continue

        # Short-circuit unmigrable rows: anything missing a required non-
        # snippet field (excluding `change_context`, which is waived for the
        # slow-path terminal state) will be rejected by validate-tier2.sh
        # post-mutation regardless of what we set for snippet/hash. Bucket
        # them separately so the migration completes in bounded time.
        missing_other = row_missing_non_snippet_required_fields(row)
        if missing_other:
            summary["unmigrable_missing_required_fields"] += 1
            file_summary["unmigrable_missing_required_fields"] += 1
            for f in missing_other:
                failure_counter[f"unmigrable_missing:{f}"] += 1
            continue

        # Rows missing `change_context` go directly to the slow-path legacy
        # terminal state. The validator's D2 grandfather waiver permits these
        # rows to lack change_context on the slow-path; attempting fast-path
        # recovery would produce a row that fails validation anyway because
        # change_context is required for non-legacy rows. Faithful to the
        # team-lead's framing: pre-Phase-1 rows are grandfathered as
        # slow-path even if snippet bytes are recoverable.
        if not row.get("change_context"):
            was_legacy = row_is_legacy_marked(row)
            if was_legacy:
                summary["already_legacy_skipped"] += 1
                file_summary["already_legacy_skipped"] += 1
                continue
            merge: dict = {
                "provenance": "legacy-no-snippet",
                "exact_snippet": None,
                "normalized_snippet_hash": None,
            }
            # Apply deterministic scale-alias remap so rows with deprecated
            # scale ids (e.g. "architectural" → "architecture") pass the
            # validator's scale-registry enum check. Only applied at the
            # mark-legacy boundary; we never mutate scale on fast-path rows.
            current_scale = row.get("scale")
            if current_scale in _SCALE_ALIAS_REMAP:
                merge["scale"] = _SCALE_ALIAS_REMAP[current_scale]
                failure_counter[f"scale_alias_remap:{current_scale}->{_SCALE_ALIAS_REMAP[current_scale]}"] += 1
            ok, msg = call_update(path, claim_id, merge, dry_run)
            if ok:
                summary["marked_legacy"] += 1
                file_summary["marked_legacy"] += 1
                failure_counter["marked_legacy_pre_phase1"] += 1
                if verbose:
                    print(f"  [{path}:{line_no}] marked legacy (pre-Phase-1, no change_context): {claim_id}")
            else:
                summary["update_failed"] += 1
                file_summary["update_failed"] += 1
                print(
                    f"  [{path}:{line_no}] FAILED to mark legacy (pre-Phase-1): {claim_id} — {msg}",
                    file=sys.stderr,
                )
            continue

        # Attempt source recovery for all other rows. This treats state-2
        # (already-legacy-marked) rows the same as state-3 (missing both
        # fields, no marker): if recovery succeeds we transition to state-1.
        was_legacy = row_is_legacy_marked(row)

        recovered = recover_snippet(row, repo_root, failure_counter)

        if recovered is None:
            # Recovery failed.
            if was_legacy:
                # Already in slow-path terminal state — nothing to do.
                summary["already_legacy_skipped"] += 1
                file_summary["already_legacy_skipped"] += 1
                continue
            # Mark as legacy. Strip any partial snippet/hash to satisfy the
            # D2 exclusive-terminal-state rule. The update writer + validator
            # will reject a mixed-state result, so we explicitly NULL the
            # snippet/hash via the merge.
            merge: dict = {
                "provenance": "legacy-no-snippet",
                "exact_snippet": None,
                "normalized_snippet_hash": None,
            }
            # Deterministic scale-alias remap — see _SCALE_ALIAS_REMAP.
            current_scale = row.get("scale")
            if current_scale in _SCALE_ALIAS_REMAP:
                merge["scale"] = _SCALE_ALIAS_REMAP[current_scale]
                failure_counter[f"scale_alias_remap:{current_scale}->{_SCALE_ALIAS_REMAP[current_scale]}"] += 1
            # Drop nulls only AFTER mutation — but evidence-update.sh's stdin
            # path will set them to JSON null, and validate-tier2.sh treats
            # null as "absent" (validator uses `has(f) and (.[$f] != null)`).
            ok, msg = call_update(path, claim_id, merge, dry_run)
            if ok:
                summary["marked_legacy"] += 1
                file_summary["marked_legacy"] += 1
                if verbose:
                    print(f"  [{path}:{line_no}] marked legacy: {claim_id}")
            else:
                summary["update_failed"] += 1
                file_summary["update_failed"] += 1
                print(
                    f"  [{path}:{line_no}] FAILED to mark legacy: {claim_id} — {msg}",
                    file=sys.stderr,
                )
            continue

        # Recovery succeeded — write fast-path terminal state.
        snippet, h = recovered
        merge: dict = {
            "exact_snippet": snippet,
            "normalized_snippet_hash": h,
        }
        if was_legacy:
            # State-2 → state-1 transition: strip the legacy marker.
            merge["provenance"] = None

        ok, msg = call_update(path, claim_id, merge, dry_run)
        if ok:
            if was_legacy:
                summary["state2_to_state1_transitions"] += 1
                file_summary["state2_to_state1_transitions"] += 1
                if verbose:
                    print(f"  [{path}:{line_no}] state-2 → state-1: {claim_id}")
            else:
                summary["backfilled"] += 1
                file_summary["backfilled"] += 1
                if verbose:
                    print(f"  [{path}:{line_no}] backfilled: {claim_id}")
        else:
            summary["update_failed"] += 1
            file_summary["update_failed"] += 1
            print(
                f"  [{path}:{line_no}] FAILED to backfill: {claim_id} — {msg}",
                file=sys.stderr,
            )

    per_file[str(path)] = dict(file_summary)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kdir", help="Override the knowledge store directory.")
    parser.add_argument(
        "--repo-root",
        help="Override the git repo root used for `git show` source recovery.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Walk every row but do not mutate the store. Useful for previewing recovery rate.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Per-row progress to stdout (otherwise only the summary is printed).",
    )
    args = parser.parse_args(argv)

    kdir = resolve_knowledge_dir(args.kdir)
    if not kdir.exists():
        print(f"knowledge store not found at: {kdir}", file=sys.stderr)
        return 1

    repo_root = resolve_repo_root(args.repo_root)

    files = enumerate_files(kdir)
    if not files:
        print(f"no task-claims.jsonl files found under {kdir}/_work", file=sys.stderr)
        return 0

    summary: Counter = Counter()
    failure_counter: Counter = Counter()
    per_file: dict = {}
    per_file_quarantine: dict = {}

    # Quarantine pass: split verdict envelopes out of task-claims.jsonl into a
    # sibling sidecar BEFORE the per-row producer-migration loop runs. This
    # is one-time data hygiene from a separate writer-pipeline bug; see
    # quarantine_verdict_envelopes() for the rationale.
    for path in files:
        quarantine_verdict_envelopes(
            path,
            summary,
            per_file_quarantine,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )

    for path in files:
        process_file(
            path,
            repo_root,
            failure_counter,
            summary,
            per_file,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )

    # Summary report — stdout, structured.
    rows_scanned = (
        summary["already_compliant"]
        + summary["backfilled"]
        + summary["marked_legacy"]
        + summary["already_legacy_skipped"]
        + summary["state2_to_state1_transitions"]
        + summary["update_failed"]
        + summary["unmigrable_missing_required_fields"]
        + summary["malformed"]
        + summary["missing_claim_id"]
    )

    # Recovery rate over "this-run-targets" = rows the migration tried to
    # backfill OR mark legacy this run (i.e. rows not already compliant and
    # not already in the slow-path terminal state).
    this_run_targets = (
        summary["backfilled"]
        + summary["marked_legacy"]
        + summary["state2_to_state1_transitions"]
        + summary["update_failed"]
    )
    recovered_fast = summary["backfilled"] + summary["state2_to_state1_transitions"]
    if this_run_targets > 0:
        recovery_rate = recovered_fast / this_run_targets
    else:
        recovery_rate = 1.0  # nothing to recover → vacuously 100%

    report = {
        "files_scanned": len(files),
        "rows_scanned": rows_scanned,
        "already_compliant": summary["already_compliant"],
        "backfilled": summary["backfilled"],
        "state2_to_state1_transitions": summary["state2_to_state1_transitions"],
        "marked_legacy": summary["marked_legacy"],
        "already_legacy_skipped": summary["already_legacy_skipped"],
        "unmigrable_missing_required_fields": summary["unmigrable_missing_required_fields"],
        "quarantined_verdict_envelopes": summary["quarantined_verdict_envelopes"],
        "update_failed": summary["update_failed"],
        "malformed": summary["malformed"],
        "missing_claim_id": summary["missing_claim_id"],
        "recovery_rate": round(recovery_rate, 4),
        "recovery_rate_denominator": this_run_targets,
        "dry_run": args.dry_run,
    }

    # Pure JSON to stdout so consumers can parse the report directly.
    print(json.dumps(report, indent=2))

    # Failure-mode breakdown — to stderr so it stays out of the JSON channel.
    # Only show the top-15 most-common tags so the operator can evaluate the
    # dominant failure modes for the ≥50% floor.
    if failure_counter:
        print("\n# Failure modes (top 15)", file=sys.stderr)
        for tag, n in failure_counter.most_common(15):
            print(f"  {n:5d}  {tag}", file=sys.stderr)

    # Quarantine breakdown — surfaces the upstream writer-pipeline bug that
    # commingled verdict envelopes into task-claims.jsonl. The top-source
    # files are the starting points for the followup writer-pipeline fix.
    if per_file_quarantine:
        print("\n# Verdict envelopes quarantined (top 15 by source file)", file=sys.stderr)
        ranked = sorted(per_file_quarantine.items(), key=lambda kv: kv[1], reverse=True)
        for path, n in ranked[:15]:
            print(f"  {n:5d}  {path}", file=sys.stderr)

    if args.verbose:
        print("\n# Per-file breakdown", file=sys.stderr)
        for path, counts in per_file.items():
            print(f"  {path}: {counts}", file=sys.stderr)

    if summary["update_failed"] > 0:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
