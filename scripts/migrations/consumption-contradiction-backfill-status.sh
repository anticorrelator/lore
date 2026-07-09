#!/usr/bin/env bash
# Replay completed consumption-contradiction settlement verdicts through the
# sanctioned sidecar status updater. Safe to re-run: same-terminal calls are
# reported as idempotent and never rewrite a row.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPTS="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_SCRIPTS/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: consumption-contradiction-backfill-status.sh [--kdir <path>] [--dry-run] [--json]

Scans hot and archived settlement run records, selects the latest completed,
non-invalidated terminal consumption-contradiction verdict per
(work_item, source_id), and replays it through the sanctioned status updater.
EOF
}

KDIR_OVERRIDE=""
DRY_RUN=0
JSON_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "[cc-backfill] Error: unknown flag '$1'" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || { echo "[cc-backfill] Error: knowledge store not found: $KNOWLEDGE_DIR" >&2; exit 1; }

KDIR="$KNOWLEDGE_DIR" \
UPDATER="$REPO_SCRIPTS/consumption-contradiction-update-status.sh" \
DRY_RUN="$DRY_RUN" \
JSON_MODE="$JSON_MODE" \
python3 <<'PY'
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

kdir = Path(os.environ["KDIR"])
updater = os.environ["UPDATER"]
dry_run = os.environ["DRY_RUN"] == "1"
json_mode = os.environ["JSON_MODE"] == "1"


def load_object(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


latest: dict[tuple[str, str], dict[str, Any]] = {}
run_paths = sorted((kdir / "_settlement" / "runs").glob("*.json"))
run_paths += sorted((kdir / "_settlement" / "archive" / "runs").glob("*.json"))
for path in run_paths:
    run = load_object(path)
    if not run or run.get("kind") != "consumption-contradiction":
        continue
    verdict_block = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
    verdict = verdict_block.get("verdict")
    if (
        run.get("status") != "completed"
        or run.get("invalidated_at")
        or verdict not in {"verified", "contradicted"}
    ):
        continue
    work_item = run.get("work_item")
    source_id = run.get("source_id")
    completed_at = run.get("completed_at")
    run_id = run.get("run_id")
    if not all(isinstance(v, str) and v for v in (work_item, source_id, completed_at, run_id)):
        continue
    key = (work_item, source_id)
    previous = latest.get(key)
    if previous is None or (completed_at, run_id) > (previous["completed_at"], previous["run_id"]):
        latest[key] = run


def find_row(work_item: str, contradiction_id: str) -> tuple[str | None, dict[str, Any] | None, str | None]:
    candidates = [
        ("active", kdir / "_work" / work_item / "consumption-contradictions.jsonl"),
        ("archive", kdir / "_work" / "_archive" / work_item / "consumption-contradictions.jsonl"),
    ]
    matches: list[tuple[str, dict[str, Any]]] = []
    for location, path in candidates:
        if not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            return None, None, f"read failed: {exc}"
        for raw in lines:
            try:
                row = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if (
                isinstance(row, dict)
                and row.get("work_item") == work_item
                and row.get("contradiction_id") == contradiction_id
            ):
                matches.append((location, row))
    if len(matches) != 1:
        reason = "missing row" if not matches else f"ambiguous identity ({len(matches)} matches)"
        return None, None, reason
    return matches[0][0], matches[0][1], None


split = {
    "active": {"matched": 0, "applied": 0, "idempotent": 0, "failed": 0},
    "archive": {"matched": 0, "applied": 0, "idempotent": 0, "failed": 0},
}
failures: list[dict[str, str]] = []

for work_item, contradiction_id in sorted(latest):
    run = latest[(work_item, contradiction_id)]
    verdict = str(run["verdict"]["verdict"])
    location, row, locate_error = find_row(work_item, contradiction_id)
    if locate_error or location is None or row is None:
        failures.append({
            "work_item": work_item,
            "contradiction_id": contradiction_id,
            "run_id": str(run["run_id"]),
            "reason": locate_error or "row lookup failed",
        })
        continue

    current = row.get("status")
    if current == "pending":
        split[location]["matched"] += 1

    if dry_run:
        if current == "pending":
            split[location]["applied"] += 1
        elif current == verdict:
            split[location]["idempotent"] += 1
        else:
            split[location]["failed"] += 1
            failures.append({
                "work_item": work_item,
                "contradiction_id": contradiction_id,
                "run_id": str(run["run_id"]),
                "reason": f"writer would refuse current status {current!r} -> {verdict!r}",
            })
        continue

    proc = subprocess.run(
        [
            "bash", updater,
            "--kdir", str(kdir),
            "--work-item", work_item,
            "--contradiction-id", contradiction_id,
            "--status", verdict,
            "--settled-at", str(run["completed_at"]),
            "--settled-by-run-id", str(run["run_id"]),
            "--json",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    structured = None
    for line in proc.stdout.splitlines():
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and candidate.get("status") in {"applied", "idempotent"}:
            structured = candidate
            break
    if proc.returncode == 0 and structured is not None:
        split[location][str(structured["status"])] += 1
    else:
        split[location]["failed"] += 1
        failures.append({
            "work_item": work_item,
            "contradiction_id": contradiction_id,
            "run_id": str(run["run_id"]),
            "reason": (proc.stderr or proc.stdout or "updater returned no structured result")[-1000:].strip(),
        })

totals = {
    key: sum(split[loc][key] for loc in ("active", "archive"))
    for key in ("matched", "applied", "idempotent", "failed")
}
totals["failed"] = len(failures)

result = {
    "dry_run": dry_run,
    "selected_runs": len(latest),
    **totals,
    "split": split,
    "failures": failures,
}

if json_mode:
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
else:
    mode = "dry-run" if dry_run else "apply"
    print(
        f"[cc-backfill] {mode}: selected={result['selected_runs']} matched={result['matched']} "
        f"applied={result['applied']} idempotent={result['idempotent']} failed={result['failed']}"
    )
    for location in ("active", "archive"):
        counts = split[location]
        print(
            f"[cc-backfill] {location}: matched={counts['matched']} applied={counts['applied']} "
            f"idempotent={counts['idempotent']} failed={counts['failed']}"
        )
    for failure in failures:
        print(
            f"[cc-backfill] ERROR work_item={failure['work_item']} "
            f"contradiction_id={failure['contradiction_id']} run_id={failure['run_id']}: {failure['reason']}",
            file=sys.stderr,
        )

raise SystemExit(1 if failures else 0)
PY
