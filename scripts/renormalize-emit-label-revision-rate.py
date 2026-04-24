#!/usr/bin/env python3
"""Emit label_revision_rate telemetry rows per scale_id.

Usage: renormalize-emit-label-revision-rate.py <scale-registry.json> <run-id> [--window N]

For each scale_id, counts how many times its label changed in the last N entries
of label_history (default N=5). Emits one telemetry row per scale_id, plus a
registry_design_flag row when revisions_in_last_N_runs >= 2.

Output: one JSON object per line, consumed by renormalize-emit-label-revision-rate.sh.
"""
import argparse
import json
import sys
from datetime import datetime, timezone


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("registry_path")
    parser.add_argument("run_id")
    parser.add_argument("--window", type=int, default=5)
    args = parser.parse_args()

    with open(args.registry_path) as f:
        registry = json.load(f)

    scale_ids = [s["id"] for s in sorted(registry.get("scales", []), key=lambda e: e["ordinal"])]
    label_history = registry.get("label_history", [])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    N = args.window

    for scale_id in scale_ids:
        # Count how many history entries changed this scale_id's label.
        # Each history entry stores labels *before* the relabel at that version.
        # Two consecutive entries differ for scale_id iff its label changed between them.
        # We look at the last N history entries to bound the window.
        relevant = label_history[-N:] if len(label_history) > N else label_history

        revisions = 0
        for i in range(1, len(relevant)):
            prev_label = relevant[i - 1].get("labels", {}).get(scale_id)
            curr_label = relevant[i].get("labels", {}).get(scale_id)
            if prev_label is not None and curr_label is not None and prev_label != curr_label:
                revisions += 1
        # Also count if the most recent history entry differs from current label
        if relevant:
            last_label = relevant[-1].get("labels", {}).get(scale_id)
            current_label = registry.get("labels", {}).get(scale_id)
            if last_label is not None and current_label is not None and last_label != current_label:
                revisions += 1

        rate_row = {
            "schema_version": "1",
            "kind": "telemetry",
            "tier": "telemetry",
            "metric": "label_revision_rate",
            "calibration_state": "pre-calibration",
            "scale_id": scale_id,
            "revisions_in_last_N_runs": revisions,
            "N": N,
            "ts": now,
            "renormalize_run_id": args.run_id,
        }
        print(json.dumps(rate_row))

        if revisions >= 2:
            flag_row = {
                "schema_version": "1",
                "kind": "telemetry",
                "tier": "telemetry",
                "metric": "registry_design_flag",
                "calibration_state": "pre-calibration",
                "scale_id": scale_id,
                "reason": "registry-design review",
                "revisions_in_last_N_runs": revisions,
                "N": N,
                "ts": now,
                "renormalize_run_id": args.run_id,
            }
            print(json.dumps(flag_row))


if __name__ == "__main__":
    main()
