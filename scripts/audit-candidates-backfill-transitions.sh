#!/usr/bin/env bash
# audit-candidates-backfill-transitions.sh — Drain audit-candidate rows stuck
# at `pending_correctness_gate` by replaying terminal omission runs through
# audit-candidate-transition.sh.
#
# Walks $KDIR/_settlement/runs/*.json, filters omission runs in a terminal
# status (completed | failed | blocked), collapses to the latest non-
# invalidated terminal run per (work_item, candidate_id), then applies the
# D2 verdict→status mapping by shelling out to audit-candidate-transition.sh:
#
#   verified                -> gate-passed
#   unverified|contradicted -> gate-failed
#   error|blocked|other     -> no transition (counted as `no-transition`)
#
# Scope guard (D5): only `_work/<slug>/audit-candidates.jsonl` paths matching
# the single-level glob are processed. Per-slug archives at
# `_work/_archive/<slug>/audit-candidates.jsonl` are SKIPPED and counted as
# `out-of-scope`. Rows whose `work_item` field is `_archive` (the consolidated
# archive at `_work/_archive/audit-candidates.jsonl`) ARE in scope.
#
# Idempotent: illegal-transition rejects from re-running against an already-
# terminal row are counted as `already-terminal`, NOT as errors.
#
# Usage:
#   audit-candidates-backfill-transitions.sh [--kdir <path>] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR_OVERRIDE=""
DRY_RUN="false"

usage() {
  sed -n '2,28p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir)    KDIR_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true";     shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[backfill] Error: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  echo "[backfill] Error: knowledge directory not found: $KDIR" >&2
  exit 2
fi

TRANSITION="$SCRIPT_DIR/audit-candidate-transition.sh"
if [[ ! -x "$TRANSITION" ]]; then
  echo "[backfill] Error: transition script not found or not executable: $TRANSITION" >&2
  exit 2
fi

export KDIR DRY_RUN TRANSITION

python3 <<'PYEOF'
import json
import os
import subprocess
import sys
from pathlib import Path

KDIR = Path(os.environ["KDIR"])
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"
TRANSITION = os.environ["TRANSITION"]

RUNS_DIR = KDIR / "_settlement" / "runs"
TERMINAL = {"completed", "failed", "blocked"}

# D2 verdict -> new status (None means "no transition; retry on next dispatch").
VERDICT_TO_STATUS = {
    "verified": "gate-passed",
    "unverified": "gate-failed",
    "contradicted": "gate-failed",
}

scanned = 0
transitioned = 0
already_terminal = 0
no_transition = 0
out_of_scope = 0
errors = 0


def is_invalidated(run):
    return bool(run.get("invalidated_at") or run.get("invalidated"))


def sort_key(run):
    # Latest = greatest completed_at (lexicographic ISO-8601 sort).
    return (str(run.get("completed_at") or ""), str(run.get("run_id") or ""))


def candidates_file_in_scope(work_item):
    """D5 scope guard. Returns (in_scope, target_path).

    In scope:
      - _work/<slug>/audit-candidates.jsonl  (single-level glob match)
      - _work/_archive/audit-candidates.jsonl  (work_item == "_archive")
    Out of scope:
      - _work/_archive/<slug>/audit-candidates.jsonl  (per-slug archive)
      - anything else with a '/' in the slug
    """
    if not work_item or "/" in work_item:
        return False, None
    target = KDIR / "_work" / work_item / "audit-candidates.jsonl"
    # Per-slug archives live one level deeper under _archive/. work_item="_archive"
    # targets the consolidated file directly under _work/_archive/; that file is
    # the single-level glob match and stays in scope.
    return True, target


if not RUNS_DIR.is_dir():
    print(f"scanned: 0, transitioned: 0, already-terminal: 0, no-transition: 0, out-of-scope: 0, errors: 0")
    sys.exit(0)

# Collapse to latest non-invalidated terminal omission run per (work_item, candidate_id).
latest = {}
for run_path in sorted(RUNS_DIR.glob("*.json")):
    try:
        run = json.loads(run_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        sys.stderr.write(f"[backfill] skipping unreadable run {run_path.name}: {exc}\n")
        continue
    if not isinstance(run, dict):
        continue
    if str(run.get("kind") or "") != "omission":
        continue
    if str(run.get("status") or "") not in TERMINAL:
        continue
    if is_invalidated(run):
        continue
    work_item = str(run.get("work_item") or "")
    candidate_id = str(run.get("source_id") or "")
    if not work_item or not candidate_id:
        continue
    key = (work_item, candidate_id)
    prev = latest.get(key)
    if prev is None or sort_key(run) > sort_key(prev):
        latest[key] = run

for (work_item, candidate_id), run in sorted(latest.items()):
    scanned += 1
    in_scope, cand_file = candidates_file_in_scope(work_item)
    if not in_scope:
        out_of_scope += 1
        continue
    if cand_file is None or not cand_file.exists():
        no_transition += 1
        continue
    verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
    verdict_value = str(verdict.get("verdict") or "").strip()
    new_status = VERDICT_TO_STATUS.get(verdict_value)
    if new_status is None:
        no_transition += 1
        continue
    if DRY_RUN:
        print(f"[backfill][dry-run] {work_item} {candidate_id} verdict={verdict_value} -> {new_status}")
        transitioned += 1
        continue
    cmd = [
        "bash", TRANSITION,
        "--kdir", str(KDIR),
        "--work-item", work_item,
        "--candidate-id", candidate_id,
        "--status", new_status,
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if proc.returncode == 0:
        transitioned += 1
        continue
    stderr_text = (proc.stderr or "").strip()
    # Idempotency: illegal-transition (re-run against an already-terminal row)
    # or unknown-status reads on an already-rewritten line aren't failures.
    if "illegal transition" in stderr_text or "unknown status" in stderr_text:
        already_terminal += 1
        continue
    # candidate_id missing (row was retired/removed) — also not a failure.
    if "not found in" in stderr_text:
        no_transition += 1
        continue
    errors += 1
    tail = stderr_text.splitlines()[-1] if stderr_text else f"exit {proc.returncode}"
    sys.stderr.write(
        f"[backfill] error work_item={work_item} candidate_id={candidate_id} exit={proc.returncode}: {tail[:200]}\n"
    )

print(
    f"scanned: {scanned}, transitioned: {transitioned}, already-terminal: {already_terminal}, "
    f"no-transition: {no_transition}, out-of-scope: {out_of_scope}, errors: {errors}"
)
sys.exit(0 if errors == 0 else 1)
PYEOF
