#!/usr/bin/env python3
"""Emit downstream_adoption_rate telemetry rows per entry, stratified by status.

Usage:
    emit-downstream-adoption.py <manifest.json> <retrieval-log.jsonl> <run-id>
        [--window-days N] [--kdir <path>]

For each entry in the manifest, counts how many times it was loaded (cited)
within the rolling window, divided by total retrieval opportunities (sessions +
prefetch events) in the same window. Status is read from the entry's HTML META
block; entries without a status field default to "current".

Output: one JSON object per line, consumed by emit-downstream-adoption.sh which
pipes each line into scorecard-append.sh.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone


_META_STATUS_RE = re.compile(r"\|\s*status:\s*(\S+?)(?:\s*\||\s*-->)")


def read_entry_status(kdir: str, path: str) -> str:
    """Read status field from an entry's HTML META block. Defaults to 'current'."""
    full_path = os.path.join(kdir, path)
    if not os.path.isfile(full_path):
        return "current"
    try:
        with open(full_path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return "current"
    m = _META_STATUS_RE.search(content)
    return m.group(1) if m else "current"


def parse_timestamp(ts: str) -> datetime | None:
    """Parse ISO-8601 timestamp (with or without timezone offset)."""
    if not ts:
        return None
    # Normalize: replace space with T, handle Z and ±HH:MM offsets
    ts = ts.strip().replace(" ", "T")
    for fmt in (
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S+00:00",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def parse_retrieval_log(
    log_path: str,
    window_start: datetime,
) -> tuple[int, dict[str, int]]:
    """Parse retrieval-log.jsonl within [window_start, now].

    Returns:
        (opportunities, citations_by_path) where:
        - opportunities = total sessions + prefetch events in window
        - citations_by_path = {entry_path: count of times loaded in window}
    """
    opportunities = 0
    citations_by_path: dict[str, int] = {}

    if not os.path.isfile(log_path):
        return 0, {}

    with open(log_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = parse_timestamp(record.get("timestamp", ""))
            if ts is None or ts < window_start:
                continue

            event = record.get("event")
            loaded = record.get("loaded_paths", [])

            if event == "prefetch":
                opportunities += 1
                for path in loaded:
                    if path:
                        citations_by_path[path] = citations_by_path.get(path, 0) + 1
            elif event == "search":
                # Search events don't load entries directly — skip for opportunity count
                pass
            elif "budget_used" in record:
                # Session-start load event
                opportunities += 1
                for path in loaded:
                    if path:
                        citations_by_path[path] = citations_by_path.get(path, 0) + 1

    return opportunities, citations_by_path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Emit downstream_adoption_rate telemetry rows per entry"
    )
    parser.add_argument("manifest_path", help="Path to _manifest.json")
    parser.add_argument("retrieval_log_path", help="Path to retrieval-log.jsonl")
    parser.add_argument("run_id", help="Renormalize run identifier")
    parser.add_argument(
        "--window-days", type=int, default=30,
        help="Rolling window in days (default: 30)",
    )
    parser.add_argument(
        "--kdir", default=None,
        help="Knowledge store root (to read status from META blocks)",
    )
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    window_start = now - timedelta(days=args.window_days)
    now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Infer kdir from manifest path if not provided
    kdir = args.kdir or os.path.dirname(args.manifest_path)

    with open(args.manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    entries_list = manifest.get("entries", [])

    opportunities, citations_by_path = parse_retrieval_log(
        args.retrieval_log_path, window_start
    )

    for entry in entries_list:
        path = entry.get("path", "")
        if not path:
            continue

        status = read_entry_status(kdir, path)
        citations = citations_by_path.get(path, 0)
        value = round(citations / max(opportunities, 1), 6)

        row = {
            "schema_version": "1",
            "kind": "telemetry",
            "tier": "telemetry",
            "calibration_state": "pre-calibration",
            "metric": "downstream_adoption_rate",
            "entry_id": path,
            "status": status,
            "citations": citations,
            "opportunities": opportunities,
            "value": value,
            "window_days": args.window_days,
            "ts": now_str,
            "renormalize_run_id": args.run_id,
        }
        print(json.dumps(row))


if __name__ == "__main__":
    main()
