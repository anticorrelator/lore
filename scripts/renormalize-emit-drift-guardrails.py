#!/usr/bin/env python3
"""Aggregate classifier disagreements by producer_role and emit scale_drift_rate rows.

Usage: renormalize-emit-drift-guardrails.py <classification-report.json> <manifest.json> <run-id>

Outputs one JSON object per line (one per role with corpus entries).
Called by renormalize-emit-drift-guardrails.sh which pipes output into scorecard-append.sh.
"""
import json
import sys
from datetime import datetime, timezone


def main() -> None:
    report_path, manifest_path, run_id = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(report_path) as f:
        report = json.load(f)
    with open(manifest_path) as f:
        manifest = json.load(f)

    entries_list = manifest.get("entries", [])
    role_by_path: dict[str, str] = {}
    role_corpus_count: dict[str, int] = {}
    for e in entries_list:
        path = e.get("path", "")
        role = e.get("producer_role") or "unknown"
        if path:
            role_by_path[path] = role
        role_corpus_count[role] = role_corpus_count.get(role, 0) + 1

    total_corpus = max(len(entries_list), 1)
    total_audited = report.get("summary", {}).get("entries_audited", 0)

    role_disagreements: dict[str, int] = {}
    for d in report.get("disagreements", []):
        entry = d.get("entry", "")
        role = role_by_path.get(entry, "unknown")
        role_disagreements[role] = role_disagreements.get(role, 0) + 1

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    for role in sorted(role_corpus_count):
        corpus_count = role_corpus_count[role]
        # Estimate entries_audited for this role proportionally to corpus share.
        entries_audited = max(1, round(total_audited * corpus_count / total_corpus))
        disagreement_count = role_disagreements.get(role, 0)
        drift_rate = disagreement_count / entries_audited

        row = {
            "schema_version": "1",
            "kind": "telemetry",
            "metric": "scale_drift_rate",
            "calibration_state": "pre-calibration",
            "role": role,
            "value": round(drift_rate, 4),
            "disagreements": disagreement_count,
            "entries_audited": entries_audited,
            "ts": now,
            "renormalize_run_id": run_id,
        }
        print(json.dumps(row))


if __name__ == "__main__":
    main()
