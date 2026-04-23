#!/usr/bin/env python3
"""Emit retention_after_renormalize telemetry rows per entry.

Usage: renormalize-emit-retention.py <manifest.json> <run-id> [--prune-history <path>]

For each entry currently in the manifest, counts how many prior renormalize
cycles it survived (i.e., was NOT in any prune list). prune-history.jsonl
records pruned entries per run; absence of an entry in a run's prune set means
it survived that cycle.

If --prune-history is omitted or the file is absent, cycles_survived=0 for all
entries (correct for the first run; metric becomes meaningful over time).

Output: one JSON object per line, consumed by renormalize-emit-retention.sh.
"""
import argparse
import json
import sys
from datetime import datetime, timezone


def load_prune_history(path: str) -> dict[str, int]:
    """Return {entry_path: count_of_runs_it_was_pruned} from prune-history.jsonl.

    Each line in prune-history.jsonl should be a JSON object with at least:
      {"run_id": "<id>", "pruned": ["path/a.md", "path/b.md", ...]}
    or alternatively:
      {"run_id": "<id>", "entry": "<path>"}  (one line per pruned entry)

    Both formats are accepted; the dict returned maps path -> prune_count.
    We only need the inverse: which paths were pruned in how many runs, and
    which runs exist (for computing total cycles visible).
    """
    run_ids: list[str] = []
    pruned_in_run: dict[str, set[str]] = {}  # run_id -> set of pruned paths

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            run_id = obj.get("run_id", "")
            if run_id not in pruned_in_run:
                pruned_in_run[run_id] = set()
                run_ids.append(run_id)

            # Support batch format: {"run_id": "...", "pruned": [...]}
            for p in obj.get("pruned", []):
                pruned_in_run[run_id].add(p)

            # Support per-entry format: {"run_id": "...", "entry": "..."}
            entry = obj.get("entry", "")
            if entry:
                pruned_in_run[run_id].add(entry)

    return run_ids, pruned_in_run


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest_path")
    parser.add_argument("run_id")
    parser.add_argument("--prune-history", default=None, dest="prune_history")
    args = parser.parse_args()

    with open(args.manifest_path) as f:
        manifest = json.load(f)

    entries_list = manifest.get("entries", [])

    run_ids: list[str] = []
    pruned_in_run: dict[str, set[str]] = {}

    if args.prune_history:
        try:
            run_ids, pruned_in_run = load_prune_history(args.prune_history)
        except FileNotFoundError:
            pass  # treat as no history

    total_prior_runs = len(run_ids)
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for entry in entries_list:
        path = entry.get("path", "")
        if not path:
            continue

        template_id = entry.get("template_version") or "unknown"

        # Count runs where this entry was NOT pruned (i.e., survived)
        if total_prior_runs == 0:
            cycles_survived = 0
        else:
            prune_count = sum(
                1 for run in run_ids if path in pruned_in_run.get(run, set())
            )
            cycles_survived = total_prior_runs - prune_count

        row = {
            "schema_version": "1",
            "kind": "telemetry",
            "metric": "retention_after_renormalize",
            "calibration_state": "pre-calibration",
            "template_id": template_id,
            "entry_id": path,
            "cycles_survived": cycles_survived,
            "ts": now,
            "renormalize_run_id": args.run_id,
        }
        print(json.dumps(row))


if __name__ == "__main__":
    main()
