#!/usr/bin/env python3
"""retro-export-aggregate-cells.py — aggregate kind=scored rows by (template_id, template_version, metric).

Usage: retro-export-aggregate-cells.py <rows.jsonl> <since_iso> <contributor_id>

Emits a JSON array of cell objects on stdout. Each cell:
  {
    cell_id, contributor_id, window_id, template_id, template_version,
    protocol_slot, artifact_type, metric, kind, n, numerator, denominator,
    outcome_counts, judge, calibrated_only, context_buckets
  }

Per multi-user-evolution-design.md §9. This script is called by
retro-export.sh and is not a user-facing entry point. Aggregating in
Python rather than jq because the grouping + numeric aggregation is more
legible and fewer edge cases with null fields.

Corrupt rows (missing kind or calibration_state) are silently dropped —
the scorecard-rollup emits its own warnings elsewhere; this script just
produces the export.
"""
import hashlib
import json
import sys
import uuid
from collections import defaultdict
from datetime import datetime
from typing import Any, Dict


def parse_iso(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00")
        return datetime.fromisoformat(s)
    except Exception:
        return None


def _make_group() -> Dict[str, Any]:
    return {
        "n": 0,
        "sample_size_total": 0,
        "value_sum": 0.0,
        "value_count": 0,
        "outcome_counts": defaultdict(int),
        "calibration_states": set(),
        "window_start": None,
        "window_end": None,
        "calibrated_only": True,
        "template_id": None,
        "template_version": None,
        "metric": None,
        "kind": None,
    }


def main():
    if len(sys.argv) != 4:
        print("Usage: retro-export-aggregate-cells.py <rows.jsonl> <since_iso> <contributor_id>", file=sys.stderr)
        sys.exit(2)

    rows_path, since_iso, contributor_id = sys.argv[1], sys.argv[2], sys.argv[3]
    since_dt = parse_iso(since_iso)

    groups = defaultdict(_make_group)

    try:
        with open(rows_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                kind = row.get("kind")
                calib = row.get("calibration_state")
                if kind not in ("scored", "telemetry"):
                    continue
                if calib not in ("calibrated", "pre-calibration", "unknown"):
                    continue
                if kind != "scored":
                    continue

                row_window_end = parse_iso(row.get("window_end"))
                if since_dt and row_window_end and row_window_end < since_dt:
                    continue

                key = (
                    row.get("template_id") or "",
                    row.get("template_version") or "",
                    row.get("metric") or "",
                )
                g = groups[key]
                g["template_id"] = row.get("template_id")
                g["template_version"] = row.get("template_version")
                g["metric"] = row.get("metric")
                g["kind"] = kind
                g["n"] += 1
                g["sample_size_total"] += int(row.get("sample_size") or 0)

                v = row.get("value")
                if isinstance(v, (int, float)):
                    g["value_sum"] += float(v)
                    g["value_count"] += 1

                outcome = row.get("outcome")
                if isinstance(outcome, str):
                    g["outcome_counts"][outcome] += 1

                if calib:
                    g["calibration_states"].add(calib)
                if calib != "calibrated":
                    g["calibrated_only"] = False

                ws = parse_iso(row.get("window_start"))
                we = parse_iso(row.get("window_end"))
                if ws and (g["window_start"] is None or ws < g["window_start"]):
                    g["window_start"] = ws
                if we and (g["window_end"] is None or we > g["window_end"]):
                    g["window_end"] = we
    except FileNotFoundError:
        print("[]")
        return

    cells = []
    for key, g in groups.items():
        template_id, template_version, metric = key
        ws = g["window_start"].isoformat().replace("+00:00", "Z") if g["window_start"] else None
        we = g["window_end"].isoformat().replace("+00:00", "Z") if g["window_end"] else None
        window_id = f"{ws}..{we}" if ws and we else "unknown"
        cell = {
            "cell_id": str(uuid.uuid4()),
            "contributor_id": contributor_id,
            "window_id": window_id,
            "template_id": template_id or None,
            "template_version": template_version or None,
            "metric": metric or None,
            "kind": g["kind"],
            "n": g["n"],
            "sample_size_total": g["sample_size_total"],
            "value_mean": (g["value_sum"] / g["value_count"]) if g["value_count"] else None,
            "outcome_counts": dict(g["outcome_counts"]),
            "calibration_states": sorted(g["calibration_states"]),
            "calibrated_only": g["calibrated_only"],
            "window_start": ws,
            "window_end": we,
        }
        cells.append(cell)

    cells.sort(key=lambda c: (c["template_id"] or "", c["template_version"] or "", c["metric"] or ""))
    print(json.dumps(cells))


if __name__ == "__main__":
    main()
