#!/usr/bin/env python3
"""Shared aggregator for judge rollup --aggregate-window mode.

Invoked by correctness-gate-rollup.sh, curator-rollup.sh, and
reverse-auditor-rollup.sh. Reads $KDIR/_scorecards/rows.jsonl, filters to
tier=reusable rows for the named judge in the half-open window
[window_start, window_end), groups by (template_id, template_version),
computes weighted-average per metric, and emits one tier=template row per
(template, metric) via scorecard-append.sh.

D8 step 3a: normalizes legacy template_version sentinels via an explicit
per-sentinel mapping to canonical template paths and hashes them via
template-version.sh + registers them via template-registry-register.sh.

D8 step 5: call-site dedupe before each scorecard-append.sh invocation —
skip if a matching aggregate key already exists in rows.jsonl.

D10: calibration_state downgrades conservatively (mixed-state → "unknown",
any pre-calibration/calibration-failed → "pre-calibration").

D9: emits verdict_source on every tier=template row.

Stderr emits a final summary line parsed by execute_item:
  [rollup] Aggregated: templates=<N> rows=<M> window=<W_start..W_end>
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent

# D8 step 3a: per-sentinel mapping. Sentinels appear in audit-artifact.sh:1056
# where the audit extractor labels the producer_template_version literally
# (because no canonical template hash was computed at audit time).
TEMPLATE_SENTINEL_TO_PATH: dict[str, str] = {
    "task-claims-jsonl": "agents/worker.md",
    "audit-candidates-jsonl": "agents/reverse-auditor.md",
    # consumption-contradictions are routed through the consumer-contradiction-channel
    # producer. The sole-writer for the channel is consumption-contradiction-append.sh;
    # that script's template-version is the canonical hash for the channel's tier=template
    # attribution. Mirrors the producer-attribution decision originally proposed in the
    # deleted 10-phase wire-judge-rollups plan (D2 mapping).
    "consumption-contradictions-jsonl": "scripts/consumption-contradiction-append.sh",
}


def is_12_hex(value: str) -> bool:
    if not isinstance(value, str) or len(value) != 12:
        return False
    return all(c in "0123456789abcdef" for c in value)


def resolve_template_version(template_version: str, repo_root: Path, kdir: Path, registry_cache: dict[str, str]) -> tuple[str, str]:
    """Return (resolved_version, error_or_empty).

    If already 12-char hex, returns it unchanged. Otherwise resolves the
    sentinel via TEMPLATE_SENTINEL_TO_PATH + template-version.sh, then
    registers via template-registry-register.sh. Unresolvable sentinels
    return ("", sentinel).
    """
    if is_12_hex(template_version):
        return template_version, ""
    if template_version in registry_cache:
        return registry_cache[template_version], ""
    template_path_rel = TEMPLATE_SENTINEL_TO_PATH.get(template_version)
    if not template_path_rel:
        return "", template_version
    template_path = repo_root / template_path_rel
    if not template_path.exists():
        return "", template_version
    try:
        proc = subprocess.run(
            ["bash", str(SCRIPT_DIR / "template-version.sh"), str(template_path)],
            text=True, capture_output=True, check=False, timeout=30,
        )
    except (subprocess.TimeoutExpired, OSError):
        return "", template_version
    if proc.returncode != 0:
        return "", template_version
    new_version = proc.stdout.strip()
    if not is_12_hex(new_version):
        return "", template_version
    # Register the (template_id derived from the path stem, new_version) pair
    # so /retro and /evolve can resolve the hash back to a template.
    template_id = template_path.stem
    try:
        subprocess.run(
            [
                "bash", str(SCRIPT_DIR / "template-registry-register.sh"),
                "--template-id", template_id,
                "--template-version", new_version,
                "--template-path", template_path_rel,
                "--kdir", str(kdir),
            ],
            text=True, capture_output=True, check=False, timeout=30,
        )
    except (subprocess.TimeoutExpired, OSError):
        pass  # registration is best-effort; aggregation continues
    registry_cache[template_version] = new_version
    return new_version, ""


def aggregate_calibration_state(states: list[str]) -> str:
    """D10: conservative downgrade.

    - all rows share one state → that state
    - any pre-calibration / calibration-failed → that state (most restrictive)
    - mixed otherwise → "unknown"
    """
    distinct = sorted({s for s in states if s})
    if not distinct:
        return "unknown"
    if len(distinct) == 1:
        return distinct[0]
    # Mixed. Priority order: calibration-failed > pre-calibration > unknown > calibrated.
    if "calibration-failed" in distinct:
        return "calibration-failed"
    if "pre-calibration" in distinct:
        return "pre-calibration"
    return "unknown"


def load_existing_aggregates(rows_path: Path, judge: str, window_start: str, window_end: str) -> set[tuple[str, str, str]]:
    """D8 step 5: scan existing tier=template rows to dedupe before emission.

    Returns the set of (template_id, template_version, metric) tuples already
    present for this (judge, window) aggregate key.
    """
    seen: set[tuple[str, str, str]] = set()
    if not rows_path.exists():
        return seen
    try:
        with rows_path.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(row, dict):
                    continue
                if row.get("tier") != "template":
                    continue
                if row.get("kind") != "scored":
                    continue
                if row.get("verdict_source") != judge:
                    continue
                if row.get("window_start") != window_start:
                    continue
                if row.get("window_end") != window_end:
                    continue
                key = (
                    str(row.get("template_id") or ""),
                    str(row.get("template_version") or ""),
                    str(row.get("metric") or ""),
                )
                seen.add(key)
    except OSError:
        pass
    return seen


def emit_row(row: dict[str, Any], kdir: Path) -> tuple[bool, str]:
    cmd = [
        "bash", str(SCRIPT_DIR / "scorecard-append.sh"),
        "--kdir", str(kdir),
        "--row", json.dumps(row, separators=(",", ":"), sort_keys=True),
    ]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, check=False, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, f"scorecard-append exception: {exc}"
    if proc.returncode != 0:
        return False, f"scorecard-append exit {proc.returncode}: {proc.stderr[-300:]}"
    return True, ""


# Per-judge metric sets. Keys are the verdict_source values; values are the
# metric names the rollup emits as tier=template + kind=scored rows. Metrics
# that the per-claim emit blocks write as tier=telemetry (e.g. reverse-auditor's
# grounding_failure_rate) are NOT aggregated into tier=template — they remain
# diagnostic-only per the canonical Tier Contract.
JUDGE_METRICS: dict[str, set[str]] = {
    "correctness-gate-assertion": {"factual_precision", "falsifier_quality", "audit_contradiction_rate"},
    "correctness-gate-omission": {"factual_precision", "falsifier_quality", "audit_contradiction_rate"},
    "correctness-gate-contradiction": {"factual_precision", "falsifier_quality", "audit_contradiction_rate"},
    "curator": {"curated_rate", "triviality_rate"},
    "reverse-auditor": {"omission_rate", "coverage_quality"},
}


def aggregate_window(judge: str, window_start: str, window_end: str, kdir: Path, repo_root: Path) -> int:
    rows_path = kdir / "_scorecards" / "rows.jsonl"
    allowed_metrics = JUDGE_METRICS.get(judge)
    if allowed_metrics is None:
        sys.stderr.write(f"[rollup] Error: unknown judge: {judge}\n")
        return 2
    # --- Read and filter rows ---
    matched_rows: list[dict[str, Any]] = []
    if rows_path.exists():
        try:
            with rows_path.open(encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    if row.get("tier") != "reusable":
                        continue
                    if row.get("verdict_source") != judge:
                        continue
                    w_start = row.get("window_start")
                    if not isinstance(w_start, str):
                        continue
                    # Half-open [W_start, W_end). The next week's first row is NOT in this window.
                    if not (window_start <= w_start < window_end):
                        continue
                    matched_rows.append(row)
        except OSError as exc:
            sys.stderr.write(f"[rollup] Error: read rows.jsonl: {exc}\n")
            return 2
    if not matched_rows:
        sys.stderr.write(f"[rollup] no rows in window\n")
        sys.stderr.write(f"[rollup] Aggregated: templates=0 rows=0 window={window_start}..{window_end}\n")
        return 0
    # --- Group by (template_id, template_version) with sentinel resolution ---
    registry_cache: dict[str, str] = {}
    skipped_sentinels: dict[str, int] = defaultdict(int)
    groups: dict[tuple[str, str], dict[str, Any]] = {}
    for row in matched_rows:
        template_id = str(row.get("template_id") or "")
        raw_version = str(row.get("template_version") or "")
        metric = str(row.get("metric") or "")
        if not template_id or not metric:
            continue
        if metric not in allowed_metrics:
            # tier=reusable rows for this judge may carry metrics not in the
            # tier=template set (e.g. reverse-auditor's grounding_failure_rate
            # is emitted as telemetry, not aggregated to template). Skip rather
            # than mis-aggregate.
            continue
        resolved_version, unresolved = resolve_template_version(raw_version, repo_root, kdir, registry_cache)
        if unresolved:
            skipped_sentinels[unresolved] += 1
            continue
        key = (template_id, resolved_version)
        group = groups.setdefault(key, {
            "template_id": template_id,
            "template_version": resolved_version,
            # Per-metric state. claim_anchor_sum is tracked PER metric so the
            # reverse-auditor aggregate-provenance gate (scorecard-append.sh:158)
            # can compare source_anchor_count == sample_size for that metric's
            # emitted tier=template row.
            "metrics": defaultdict(lambda: {"weighted_sum": 0.0, "sample_sum": 0, "claim_anchor_sum": 0}),
            "calibration_states": [],
            "artifact_ids": [],
        })
        try:
            value = float(row.get("value"))
            sample_size = int(row.get("sample_size") or 0)
        except (TypeError, ValueError):
            continue
        if sample_size <= 0:
            continue
        group["metrics"][metric]["weighted_sum"] += value * sample_size
        group["metrics"][metric]["sample_sum"] += sample_size
        cal = row.get("calibration_state")
        if isinstance(cal, str) and cal:
            group["calibration_states"].append(cal)
        # source_artifact_ids: capture distinct ids from row's source_artifact_ids
        # (tier=reusable rows have non-empty arrays — enforced by scorecard-append.sh:199).
        for aid in row.get("source_artifact_ids") or []:
            if isinstance(aid, str) and aid and aid not in group["artifact_ids"]:
                group["artifact_ids"].append(aid)
        # Reverse-auditor aggregate-provenance branch in scorecard-append.sh:158
        # requires source_anchor_count == sample_size on tier=template rows.
        # Per-claim tier=reusable rows have sample_size=1 in production, so a
        # row with a grounded claim_anchor contributes its own sample_size to
        # claim_anchor_sum. (For aggregated synthetic test rows with sample_size>1,
        # the same row's sample_size flows through, keeping the gate equation true.)
        ca = row.get("claim_anchor")
        if isinstance(ca, dict) and (ca.get("file") and ca.get("line_range") and ca.get("exact_snippet")):
            group["metrics"][metric]["claim_anchor_sum"] += sample_size
    # --- Emit one tier=template row per (template, metric) ---
    existing = load_existing_aggregates(rows_path, judge, window_start, window_end)
    emitted = 0
    skipped_dedupe = 0
    emit_errors: list[str] = []
    for (template_id, template_version), group in groups.items():
        cal_state = aggregate_calibration_state(group["calibration_states"])
        artifact_ids = group["artifact_ids"]
        truncated = False
        if len(artifact_ids) > 50:
            artifact_ids = artifact_ids[:50]
            truncated = True
        for metric, metric_state in group["metrics"].items():
            sample_sum = metric_state["sample_sum"]
            if sample_sum <= 0:
                continue
            key = (template_id, template_version, metric)
            if key in existing:
                skipped_dedupe += 1
                continue
            weighted_value = metric_state["weighted_sum"] / sample_sum
            row: dict[str, Any] = {
                "schema_version": "1",
                "kind": "scored",
                "tier": "template",
                "calibration_state": cal_state,
                "verdict_source": judge,
                "template_id": template_id,
                "template_version": template_version,
                "metric": metric,
                "value": weighted_value,
                "sample_size": int(sample_sum),
                "window_start": window_start,
                "window_end": window_end,
                "source_artifact_ids": artifact_ids,
                "granularity": "window-aggregate",
            }
            if truncated:
                row["source_artifact_ids_truncated"] = True
            if judge == "reverse-auditor":
                row["source_anchor_count"] = int(metric_state["claim_anchor_sum"])
            ok, err = emit_row(row, kdir)
            if ok:
                emitted += 1
                existing.add(key)
            else:
                emit_errors.append(f"{template_id}@{template_version}:{metric}: {err}")
    if skipped_sentinels:
        for sentinel, n in sorted(skipped_sentinels.items()):
            sys.stderr.write(f"[rollup] skipped_unresolvable_template_version: {sentinel} (rows={n})\n")
    if skipped_dedupe:
        sys.stderr.write(f"[rollup] skipped_existing_aggregate_rows: {skipped_dedupe}\n")
    if emit_errors:
        for msg in emit_errors:
            sys.stderr.write(f"[rollup] emit_error: {msg}\n")
    summary = f"[rollup] Aggregated: templates={len(groups)} rows={emitted} window={window_start}..{window_end}"
    sys.stderr.write(summary + "\n")
    return 1 if emit_errors else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="rollup_aggregate.py")
    ap.add_argument("--judge", required=True)
    ap.add_argument("--window-start", required=True)
    ap.add_argument("--window-end", required=True)
    ap.add_argument("--kdir", required=True)
    ap.add_argument("--repo-root", required=True, help="Path to lore checkout root (where agents/ lives)")
    args = ap.parse_args()
    kdir = Path(args.kdir)
    repo_root = Path(args.repo_root)
    return aggregate_window(args.judge, args.window_start, args.window_end, kdir, repo_root)


if __name__ == "__main__":
    raise SystemExit(main())
