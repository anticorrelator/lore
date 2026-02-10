#!/usr/bin/env python3
"""staleness-scan: Score knowledge entries by freshness, confidence, and file validity.

For each entry file in category directories, extracts `learned` date, `confidence`,
and `related_files` from HTML comment metadata. Cross-references `related_files`
against the codebase. Scores staleness as:
  - stale:  >180 days + low confidence + missing related files
  - aging:  >90 days OR medium confidence
  - fresh:  recent + high confidence

Output: _meta/staleness-report.json

Usage:
    python staleness-scan.py <knowledge_dir> [--repo-root PATH] [--json]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas", "principles", "workflows", "domains"}
SKIP_FILES = {"_inbox.md", "_index.md", "_meta.md", "_meta.json", "_index.json", "_self_test_results.md", "_manifest.json"}

# Staleness thresholds (days)
STALE_DAYS = 180
AGING_DAYS = 90

# Metadata regex: <!-- learned: YYYY-MM-DD | confidence: high|medium|low | source: tag | related_files: path1,path2 -->
_META_RE = re.compile(
    r"<!--\s*"
    r"learned:\s*(?P<learned>\S+)"
    r"\s*\|\s*confidence:\s*(?P<confidence>\w+)"
    r"(?:\s*\|\s*source:\s*(?P<source>[^|]+?))?"
    r"(?:\s*\|\s*related_files:\s*(?P<related_files>[^-]+?))?"
    r"\s*-->",
    re.DOTALL,
)


# ---------------------------------------------------------------------------
# Entry Scanner
# ---------------------------------------------------------------------------

def collect_entry_files(knowledge_dir: str) -> list[str]:
    """Find all .md entry files in category directories."""
    results: list[str] = []
    for cat_dir in sorted(CATEGORY_DIRS):
        cat_path = os.path.join(knowledge_dir, cat_dir)
        if not os.path.isdir(cat_path):
            continue
        for root, dirs, files in os.walk(cat_path):
            dirs[:] = [d for d in dirs if not d.startswith("_") and d != "__pycache__"]
            for fname in sorted(files):
                if not fname.endswith(".md"):
                    continue
                if fname in SKIP_FILES:
                    continue
                results.append(os.path.join(root, fname))
    return results


def parse_metadata(file_path: str) -> dict:
    """Extract metadata from HTML comment in a knowledge entry file.

    Returns dict with keys: learned (str|None), confidence (str|None),
    source (str|None), related_files (list[str]).
    """
    try:
        text = Path(file_path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {"learned": None, "confidence": None, "source": None, "related_files": []}

    match = _META_RE.search(text)
    if not match:
        return {"learned": None, "confidence": None, "source": None, "related_files": []}

    learned = match.group("learned").strip() if match.group("learned") else None
    confidence = match.group("confidence").strip().lower() if match.group("confidence") else None
    source = match.group("source").strip() if match.group("source") else None

    related_files: list[str] = []
    rf_str = match.group("related_files")
    if rf_str:
        rf_str = rf_str.strip()
        if rf_str:
            related_files = [f.strip() for f in rf_str.split(",") if f.strip()]

    return {
        "learned": learned,
        "confidence": confidence,
        "source": source,
        "related_files": related_files,
    }


def compute_age_days(learned_date: str | None) -> int | None:
    """Compute age in days from a YYYY-MM-DD learned date. Returns None if unparseable."""
    if not learned_date:
        return None
    # Handle template placeholder
    if "YYYY" in learned_date:
        return None
    try:
        dt = datetime.strptime(learned_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        return (now - dt).days
    except ValueError:
        return None


def check_related_files(related_files: list[str], repo_root: str) -> dict:
    """Check which related files exist relative to repo root.

    Returns dict with: existing (list), missing (list), total (int).
    """
    existing: list[str] = []
    missing: list[str] = []
    for rf in related_files:
        full_path = os.path.join(repo_root, rf)
        if os.path.exists(full_path):
            existing.append(rf)
        else:
            missing.append(rf)
    return {
        "existing": existing,
        "missing": missing,
        "total": len(related_files),
    }


def compute_file_drift(repo_root: str, learned_date: str | None, related_files: list[str]) -> dict:
    """Compute file drift by counting git commits touching related files since learned date.

    Returns dict with: commit_count (int), score (float), available (bool).
    Score mapping: 0 commits = 0.0, 1-3 = 0.3, 4-9 = 0.6, 10+ = 1.0.
    Weight: 0.6 (applied by caller).
    """
    if not related_files or not learned_date:
        return {"commit_count": 0, "score": 0.0, "available": False}

    # Validate learned_date is parseable
    if "YYYY" in learned_date:
        return {"commit_count": 0, "score": 0.0, "available": False}
    try:
        datetime.strptime(learned_date, "%Y-%m-%d")
    except ValueError:
        return {"commit_count": 0, "score": 0.0, "available": False}

    # Check that repo_root is a git repo
    if not os.path.isdir(os.path.join(repo_root, ".git")):
        return {"commit_count": 0, "score": 0.0, "available": False}

    try:
        cmd = [
            "git", "log", "--oneline",
            f"--after={learned_date}",
            "--",
        ] + related_files
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=30,
        )
        if result.returncode != 0:
            return {"commit_count": 0, "score": 0.0, "available": False}

        lines = [line for line in result.stdout.strip().splitlines() if line]
        commit_count = len(lines)
    except (subprocess.TimeoutExpired, OSError):
        return {"commit_count": 0, "score": 0.0, "available": False}

    # Normalize score
    if commit_count == 0:
        score = 0.0
    elif commit_count <= 3:
        score = 0.3
    elif commit_count <= 9:
        score = 0.6
    else:
        score = 1.0

    return {"commit_count": commit_count, "score": score, "available": True}


# Backlink pattern — matches [[type:target]] and [[type:target#heading]]
_BACKLINK_RE = re.compile(
    r"\[\[(?:knowledge|work|plan|thread):[^\]]+\]\]"
)


def compute_backlink_drift(file_path: str, knowledge_dir: str) -> dict:
    """Compute backlink drift by resolving [[...]] references in an entry.

    Extracts all backlinks from the entry text, resolves each via Resolver
    from pk_search.py. Returns dict with: total (int), broken (int),
    broken_links (list[str]), score (float), available (bool).

    Score: binary — all resolve = 0.0, any broken = 1.0. Weight: 0.25 (applied by caller).
    """
    try:
        text = Path(file_path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return {"total": 0, "broken": 0, "broken_links": [], "score": 0.0, "available": False}

    backlinks = _BACKLINK_RE.findall(text)
    if not backlinks:
        return {"total": 0, "broken": 0, "broken_links": [], "score": 0.0, "available": False}

    # Import Resolver from pk_resolve (co-located script)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, script_dir)
    try:
        from pk_resolve import Resolver
    finally:
        sys.path.pop(0)

    resolver = Resolver(knowledge_dir)
    broken_links: list[str] = []
    for bl in backlinks:
        result = resolver.resolve(bl)
        if not result.get("resolved"):
            broken_links.append(bl)

    score = 1.0 if broken_links else 0.0

    return {
        "total": len(backlinks),
        "broken": len(broken_links),
        "broken_links": broken_links,
        "score": score,
        "available": True,
    }


# ---------------------------------------------------------------------------
# Drift weights and thresholds
# ---------------------------------------------------------------------------

WEIGHT_FILE_DRIFT = 0.6
WEIGHT_BACKLINK_DRIFT = 0.25
WEIGHT_CONFIDENCE = 0.15

CONFIDENCE_SCORES = {"high": 0.0, "medium": 0.5, "low": 1.0}

FRESH_THRESHOLD = 0.3
STALE_THRESHOLD = 0.6


def score_entry(
    file_drift: dict,
    backlink_drift: dict,
    confidence: str | None,
) -> tuple[float, str, dict]:
    """Score an entry using weighted drift signals.

    Args:
        file_drift: Result from compute_file_drift() with keys: score, available, commit_count.
        backlink_drift: Result from compute_backlink_drift() with keys: score, available, total, broken.
        confidence: Confidence level string ("high", "medium", "low") or None.

    Returns:
        (drift_score, status, signals) where:
        - drift_score: float in [0.0, 1.0]
        - status: "fresh", "aging", or "stale"
        - signals: dict with sub-dicts for each signal (weight, score, detail)
    """
    # Confidence signal
    conf_score = CONFIDENCE_SCORES.get(confidence, CONFIDENCE_SCORES["medium"])

    # Weight redistribution when signals are unavailable
    fd_available = file_drift.get("available", False)
    bd_available = backlink_drift.get("available", False)

    if fd_available and bd_available:
        w_fd = WEIGHT_FILE_DRIFT
        w_bd = WEIGHT_BACKLINK_DRIFT
        w_conf = WEIGHT_CONFIDENCE
    elif fd_available and not bd_available:
        # Redistribute backlink weight to file drift
        w_fd = WEIGHT_FILE_DRIFT + WEIGHT_BACKLINK_DRIFT
        w_bd = 0.0
        w_conf = WEIGHT_CONFIDENCE
    elif not fd_available and bd_available:
        # Redistribute file drift weight to backlink
        w_fd = 0.0
        w_bd = WEIGHT_BACKLINK_DRIFT + WEIGHT_FILE_DRIFT
        w_conf = WEIGHT_CONFIDENCE
    else:
        # Neither available — score is confidence-only
        w_fd = 0.0
        w_bd = 0.0
        w_conf = 1.0

    fd_score = file_drift.get("score", 0.0) if fd_available else 0.0
    bd_score = backlink_drift.get("score", 0.0) if bd_available else 0.0

    drift_score = (w_fd * fd_score) + (w_bd * bd_score) + (w_conf * conf_score)
    # Clamp to [0.0, 1.0]
    drift_score = max(0.0, min(1.0, drift_score))

    # Determine status from thresholds
    if drift_score >= STALE_THRESHOLD:
        status = "stale"
    elif drift_score >= FRESH_THRESHOLD:
        status = "aging"
    else:
        status = "fresh"

    signals = {
        "file_drift": {
            "weight": w_fd,
            "score": fd_score,
            "available": fd_available,
            "commit_count": file_drift.get("commit_count", 0),
        },
        "backlink_drift": {
            "weight": w_bd,
            "score": bd_score,
            "available": bd_available,
            "total": backlink_drift.get("total", 0),
            "broken": backlink_drift.get("broken", 0),
        },
        "confidence": {
            "weight": w_conf,
            "score": conf_score,
            "level": confidence or "medium",
        },
    }

    return drift_score, status, signals


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_scan(knowledge_dir: str, repo_root: str) -> dict:
    """Run staleness scan across all knowledge entries.

    Returns full report dict.
    """
    knowledge_dir = os.path.abspath(knowledge_dir)
    repo_root = os.path.abspath(repo_root)

    entry_files = collect_entry_files(knowledge_dir)
    entries: list[dict] = []
    counts = {"stale": 0, "aging": 0, "fresh": 0}

    for fpath in entry_files:
        meta = parse_metadata(fpath)
        age_days = compute_age_days(meta["learned"])
        file_check = check_related_files(meta["related_files"], repo_root)
        file_drift = compute_file_drift(repo_root, meta["learned"], meta["related_files"])
        backlink_drift = compute_backlink_drift(fpath, knowledge_dir)
        drift_score, status, signals = score_entry(file_drift, backlink_drift, meta["confidence"])

        try:
            rel_path = os.path.relpath(fpath, knowledge_dir)
        except ValueError:
            rel_path = fpath

        entry = {
            "file": rel_path,
            "status": status,
            "drift_score": drift_score,
            "signals": signals,
            "learned": meta["learned"],
            "confidence": meta["confidence"],
            "age_days": age_days,
        }
        if meta["related_files"]:
            entry["related_files"] = file_check

        entries.append(entry)
        counts[status] += 1

    report = {
        "scan_time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "knowledge_dir": knowledge_dir,
        "repo_root": repo_root,
        "total_entries": len(entries),
        "counts": counts,
        "entries": entries,
    }
    return report


def _top_signal(signals: dict) -> str:
    """Return a short description of the highest-contributing signal."""
    candidates = []
    fd = signals.get("file_drift", {})
    if fd.get("available"):
        candidates.append((fd["weight"] * fd["score"], f"file drift ({fd['commit_count']} commits)"))
    bd = signals.get("backlink_drift", {})
    if bd.get("available"):
        candidates.append((bd["weight"] * bd["score"], f"backlinks ({bd['broken']}/{bd['total']} broken)"))
    conf = signals.get("confidence", {})
    candidates.append((conf.get("weight", 0) * conf.get("score", 0), f"confidence: {conf.get('level', '?')}"))

    if not candidates:
        return "no signals"
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="staleness-scan",
        description="Score knowledge entries by freshness, confidence, and file validity",
    )
    parser.add_argument("knowledge_dir", help="Path to knowledge directory")
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Path to source repo root for related_files checks (default: cwd)",
    )
    parser.add_argument("--json", action="store_true", help="Output as JSON only")

    args = parser.parse_args()

    knowledge_dir = os.path.abspath(args.knowledge_dir)
    if not os.path.isdir(knowledge_dir):
        print(f"[staleness-scan] Error: directory not found: {knowledge_dir}", file=sys.stderr)
        sys.exit(1)

    repo_root = os.path.abspath(args.repo_root) if args.repo_root else os.getcwd()

    report = run_scan(knowledge_dir, repo_root)

    # Write report to _meta/staleness-report.json
    meta_dir = os.path.join(knowledge_dir, "_meta")
    os.makedirs(meta_dir, exist_ok=True)
    report_path = os.path.join(meta_dir, "staleness-report.json")
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    if args.json:
        print(json.dumps(report, indent=2))
        return

    # Human-readable output
    print(f"Staleness scan: {report['total_entries']} entries")
    print(f"  Fresh: {report['counts']['fresh']}")
    print(f"  Aging: {report['counts']['aging']}")
    print(f"  Stale: {report['counts']['stale']}")

    stale_entries = [e for e in report["entries"] if e["status"] == "stale"]
    aging_entries = [e for e in report["entries"] if e["status"] == "aging"]

    if stale_entries:
        print(f"\nStale ({len(stale_entries)}):")
        for e in stale_entries:
            top = _top_signal(e["signals"])
            print(f"  {e['file']}  (drift: {e['drift_score']:.2f}, top: {top})")

    if aging_entries:
        print(f"\nAging ({len(aging_entries)}):")
        for e in aging_entries:
            top = _top_signal(e["signals"])
            print(f"  {e['file']}  (drift: {e['drift_score']:.2f}, top: {top})")

    print(f"\nReport written to: {report_path}")


if __name__ == "__main__":
    main()
