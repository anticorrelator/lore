#!/usr/bin/env python3
"""retro-aggregate-compute.py — aggregate the retro pool into convergence-tagged groups.

Usage: retro-aggregate-compute.py <pool_dir>

Reads every bundle in <pool_dir>/<contributor_id>/*.json, groups cells by
(template_id, template_version, metric), and tags each group with:
  - convergent    ≥2 contributors, total_n ≥ 15, mean values agree on direction
  - idiosyncratic exactly 1 contributor (or 1 supplies >80% of rows)
  - mixed         ≥2 contributors but values disagree on direction (range too wide)
  - insufficient  total_n < 15, regardless of contributor count

Direction agreement is computed as: let mean_low = min contributor-mean,
mean_high = max contributor-mean; if (mean_high - mean_low) / max(|mean_high|, 0.01)
< 0.25, they agree. Otherwise mixed. This is a rough heuristic — the
research doc says threshold-tuning happens after early data, not at design
time.

Emits a single JSON object on stdout:
  {
    generated_at, source_bundles, contributors,
    groups: [{template_id, template_version, metric, tag,
              total_n, contributor_count,
              row_weighted_mean, contributor_balanced_mean,
              by_contributor: [{contributor_id, n, mean}]}, ...]
  }
"""
import glob
import json
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone


MIN_TOTAL_N = 15
DIRECTION_TOLERANCE = 0.25
IDIO_CONCENTRATION_THRESHOLD = 0.80


def main():
    if len(sys.argv) != 2:
        print(json.dumps({"error": "usage: retro-aggregate-compute.py <pool_dir>"}))
        sys.exit(2)

    pool_dir = sys.argv[1]
    bundles = sorted(glob.glob(os.path.join(pool_dir, "*", "*.json")))

    contributors = set()
    source_bundles = []
    # groups[key] = {contributor_id -> [cell, ...]}
    groups = defaultdict(lambda: defaultdict(list))

    for bpath in bundles:
        try:
            with open(bpath, "r", encoding="utf-8") as f:
                b = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        env = b.get("envelope") or {}
        contributor_id = env.get("contributor_id")
        if not contributor_id:
            continue
        contributors.add(contributor_id)
        source_bundles.append(os.path.relpath(bpath, pool_dir))

        for cell in b.get("scorecard_cells") or []:
            key = (
                cell.get("template_id") or "",
                cell.get("template_version") or "",
                cell.get("metric") or "",
            )
            groups[key][contributor_id].append(cell)

    def aggregate_by_contributor(contrib_cells):
        """Return {contributor_id: {n, mean}} for one group."""
        out = {}
        for cid, cells in contrib_cells.items():
            n_sum = 0
            weighted_value_sum = 0.0
            for c in cells:
                n = int(c.get("n") or 0)
                mean = c.get("value_mean")
                n_sum += n
                if isinstance(mean, (int, float)) and n > 0:
                    weighted_value_sum += mean * n
            out[cid] = {
                "n": n_sum,
                "mean": (weighted_value_sum / n_sum) if n_sum > 0 else None,
            }
        return out

    def tag_group(by_contrib):
        """Assign convergent | idiosyncratic | mixed | insufficient."""
        contributor_count = len(by_contrib)
        total_n = sum(v["n"] for v in by_contrib.values())

        if total_n < MIN_TOTAL_N:
            return "insufficient", total_n, contributor_count

        means = [v["mean"] for v in by_contrib.values() if v["mean"] is not None]

        # Idiosyncratic if only one contributor or one supplies the vast
        # majority of rows.
        if contributor_count < 2:
            return "idiosyncratic", total_n, contributor_count
        per_contrib_ns = sorted((v["n"] for v in by_contrib.values()), reverse=True)
        if per_contrib_ns and per_contrib_ns[0] / total_n >= IDIO_CONCENTRATION_THRESHOLD:
            return "idiosyncratic", total_n, contributor_count

        # Direction agreement on means.
        if len(means) < 2:
            return "insufficient", total_n, contributor_count
        mean_low, mean_high = min(means), max(means)
        denom = max(abs(mean_high), abs(mean_low), 0.01)
        spread = (mean_high - mean_low) / denom
        if spread < DIRECTION_TOLERANCE:
            return "convergent", total_n, contributor_count
        return "mixed", total_n, contributor_count

    out_groups = []
    for key, by_contrib_cells in groups.items():
        by_contrib = aggregate_by_contributor(by_contrib_cells)
        tag, total_n, contributor_count = tag_group(by_contrib)

        # Row-weighted mean (over all rows).
        total_weight = sum(v["n"] for v in by_contrib.values())
        row_weighted = None
        if total_weight > 0:
            s = 0.0
            for v in by_contrib.values():
                if v["mean"] is not None:
                    s += v["mean"] * v["n"]
            row_weighted = s / total_weight

        # Contributor-balanced mean (each contributor weighted equally).
        cb_values = [v["mean"] for v in by_contrib.values() if v["mean"] is not None]
        contributor_balanced = sum(cb_values) / len(cb_values) if cb_values else None

        out_groups.append({
            "template_id": key[0] or None,
            "template_version": key[1] or None,
            "metric": key[2] or None,
            "tag": tag,
            "total_n": total_n,
            "contributor_count": contributor_count,
            "row_weighted_mean": row_weighted,
            "contributor_balanced_mean": contributor_balanced,
            "by_contributor": [
                {"contributor_id": cid, "n": v["n"], "mean": v["mean"]}
                for cid, v in sorted(by_contrib.items())
            ],
        })

    out_groups.sort(key=lambda g: (g["tag"], -(g["total_n"] or 0)))

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source_bundles": source_bundles,
        "contributors": sorted(contributors),
        "groups": out_groups,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
