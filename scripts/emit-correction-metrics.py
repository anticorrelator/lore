#!/usr/bin/env python3
"""Emit correction_rate and precedent_rate telemetry rows.

Usage:
    emit-correction-metrics.py <manifest.json> <registry.json> <run-id>
        [--window-days N] [--kdir <path>]

correction_rate (per scale):
    corrections_in_window / max(entries_at_scale, 1)
    Counts entries that have at least one correction[] item within the window.

precedent_rate (per scale_id / registry group):
    l3_corrections_in_window / max(corrections_in_window, 1)
    L3 = entry has both corrections[] AND precedent_note: in META block.

Output: one JSON object per line (mix of correction_rate and precedent_rate rows).
Called by emit-correction-metrics.sh which pipes output into scorecard-append.sh.
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone


_CORRECTIONS_RE = re.compile(r"\|\s*corrections:\s*(\[.*?\])\s*(?:-->|\|)", re.DOTALL)
_PRECEDENT_NOTE_RE = re.compile(r"\|\s*precedent_note:", re.IGNORECASE)
_SCALE_RE = re.compile(r"\|\s*scale:\s*(?P<scale>[^\s|>]+)", re.IGNORECASE)


def parse_timestamp(ts: str) -> datetime | None:
    ts = ts.strip()
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            dt = datetime.strptime(ts, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def read_entry_meta(kdir: str, rel_path: str) -> dict:
    """Read corrections[], precedent_note presence, and scale from entry META block."""
    abs_path = os.path.join(kdir, rel_path)
    result = {"corrections": [], "has_precedent_note": False, "scale": "unknown"}
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return result

    m = _CORRECTIONS_RE.search(text)
    if m:
        try:
            items = json.loads(m.group(1))
            result["corrections"] = [it for it in items if isinstance(it, dict)]
        except (json.JSONDecodeError, TypeError):
            pass

    result["has_precedent_note"] = bool(_PRECEDENT_NOTE_RE.search(text))

    sm = _SCALE_RE.search(text)
    if sm:
        result["scale"] = sm.group("scale").strip().lower()

    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Emit correction_rate and precedent_rate telemetry rows"
    )
    parser.add_argument("manifest_path", help="Path to _manifest.json")
    parser.add_argument("registry_path", help="Path to scale-registry.json")
    parser.add_argument("run_id", help="Run identifier")
    parser.add_argument("--window-days", type=int, default=30, dest="window_days")
    parser.add_argument("--kdir", default=None)
    args = parser.parse_args()

    now = datetime.now(timezone.utc)
    window_start = now - timedelta(days=args.window_days)
    now_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    kdir = args.kdir or os.path.dirname(args.manifest_path)

    with open(args.manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    with open(args.registry_path, encoding="utf-8") as f:
        registry = json.load(f)

    entries_list = manifest.get("entries", [])
    scale_ids = [s["id"] for s in registry.get("scales", [])]
    if not scale_ids:
        scale_ids = ["implementation", "subsystem", "architectural"]

    # Per-scale accumulators
    # corrections_in_window: entries that have ≥1 correction within window
    # entries_at_scale: total entries at that scale
    scale_corrected: dict[str, int] = {s: 0 for s in scale_ids}
    scale_corrected["unknown"] = 0
    scale_total: dict[str, int] = {s: 0 for s in scale_ids}
    scale_total["unknown"] = 0

    # Per-scale L3 accumulators (entries with corrections + precedent_note)
    scale_l3: dict[str, int] = {s: 0 for s in scale_ids}
    scale_l3["unknown"] = 0

    for entry in entries_list:
        rel_path = entry.get("path", "")
        if not rel_path:
            continue

        meta = read_entry_meta(kdir, rel_path)
        scale = meta["scale"] if meta["scale"] in scale_total else "unknown"

        scale_total[scale] = scale_total.get(scale, 0) + 1

        # Check if entry has any correction within the window
        corrections_in_window = []
        for c in meta["corrections"]:
            date_str = c.get("date", "")
            if not date_str:
                continue
            dt = parse_timestamp(date_str)
            if dt and dt >= window_start:
                corrections_in_window.append(c)

        if corrections_in_window:
            scale_corrected[scale] = scale_corrected.get(scale, 0) + 1
            if meta["has_precedent_note"]:
                scale_l3[scale] = scale_l3.get(scale, 0) + 1

    # Emit correction_rate rows (one per scale in registry + "unknown")
    emit_scales = list(scale_ids) + (["unknown"] if scale_total.get("unknown", 0) > 0 else [])
    for scale in emit_scales:
        entries_at = scale_total.get(scale, 0)
        corrected = scale_corrected.get(scale, 0)
        value = round(corrected / max(entries_at, 1), 6)
        row = {
            "schema_version": "1",
            "kind": "telemetry",
            "calibration_state": "pre-calibration",
            "metric": "correction_rate",
            "scale": scale,
            "corrections_in_window": corrected,
            "entries_at_scale": entries_at,
            "value": value,
            "window_days": args.window_days,
            "ts": now_str,
            "renormalize_run_id": args.run_id,
        }
        print(json.dumps(row))

    # Emit precedent_rate rows (one per registry scale_id)
    for scale in emit_scales:
        corrected = scale_corrected.get(scale, 0)
        l3 = scale_l3.get(scale, 0)
        value = round(l3 / max(corrected, 1), 6)
        row = {
            "schema_version": "1",
            "kind": "telemetry",
            "calibration_state": "pre-calibration",
            "metric": "precedent_rate",
            "scale_id": scale,
            "l3_corrections_in_window": l3,
            "corrections_in_window": corrected,
            "value": value,
            "window_days": args.window_days,
            "ts": now_str,
            "renormalize_run_id": args.run_id,
        }
        print(json.dumps(row))


if __name__ == "__main__":
    main()
