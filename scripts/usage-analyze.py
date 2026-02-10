#!/usr/bin/env python3
"""usage-analyze.py — Analyze knowledge store retrieval patterns.

Reads _meta/retrieval-log.jsonl and cross-references with _manifest.json
to produce per-entry access stats and identify cold entries.

Usage:
    python usage-analyze.py <knowledge_dir> [--sessions N] [--json] [--cold-threshold N]

Output: Writes _meta/usage-report.json and prints a human-readable summary.
"""

import argparse
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CATEGORY_DIRS = {"abstractions", "architecture", "conventions", "gotchas",
                 "principles", "workflows", "domains"}


# ---------------------------------------------------------------------------
# Log Parser
# ---------------------------------------------------------------------------

def parse_retrieval_log(log_path: str) -> tuple[list[dict], list[dict]]:
    """Parse retrieval-log.jsonl into session-start events and search events.

    Returns:
        Tuple of (session_events, search_events).
    """
    session_events: list[dict] = []
    search_events: list[dict] = []

    if not os.path.isfile(log_path):
        return session_events, search_events

    with open(log_path, "r", encoding="utf-8") as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue

            if record.get("event") == "search":
                search_events.append(record)
            elif "budget_used" in record:
                # Session-start load event (no explicit "event" field)
                session_events.append(record)

    return session_events, search_events


# ---------------------------------------------------------------------------
# Entry Collector
# ---------------------------------------------------------------------------

def collect_manifest_entries(knowledge_dir: str) -> list[dict]:
    """Read entries from _manifest.json.

    Returns list of entry dicts with 'path' and 'category' keys.
    """
    manifest_path = os.path.join(knowledge_dir, "_manifest.json")
    if not os.path.isfile(manifest_path):
        return []

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (json.JSONDecodeError, OSError):
        return []

    return manifest.get("entries", [])


def collect_entry_files(knowledge_dir: str) -> list[str]:
    """Walk category directories and return relative paths of all entry files.

    Returns paths like 'conventions/script-first-skill-design.md'.
    """
    entries: list[str] = []
    for cat_dir in sorted(CATEGORY_DIRS):
        cat_path = os.path.join(knowledge_dir, cat_dir)
        if not os.path.isdir(cat_path):
            continue
        for fname in sorted(os.listdir(cat_path)):
            if not fname.endswith(".md"):
                continue
            entries.append(f"{cat_dir}/{fname}")
    return entries


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def analyze_usage(
    knowledge_dir: str,
    cold_threshold: int = 0,
) -> dict:
    """Analyze retrieval log and produce usage report.

    Args:
        knowledge_dir: Path to knowledge store root.
        cold_threshold: Entries with total_accesses <= this are "cold".
            Default 0 means entries with zero accesses.

    Returns:
        Usage report dict.
    """
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    session_events, search_events = parse_retrieval_log(log_path)

    # Collect all known entries from manifest
    manifest_entries = collect_manifest_entries(knowledge_dir)
    # Also collect from filesystem for entries not yet in manifest
    fs_entries = collect_entry_files(knowledge_dir)

    # Build canonical entry set (use manifest paths as primary, fill from fs)
    all_entry_paths: set[str] = set()
    for entry in manifest_entries:
        all_entry_paths.add(entry["path"])
    for path in fs_entries:
        all_entry_paths.add(path)

    # --- Per-entry access stats ---
    # Search events reference entries via file_path (relative to knowledge_dir)
    # and heading. In v2 format, each search result's file_path points to an
    # entry file like "conventions/script-first-skill-design.md".
    entry_stats: dict[str, dict] = {}
    for path in sorted(all_entry_paths):
        entry_stats[path] = {
            "path": path,
            "search_appearances": 0,
            "last_search_appearance": None,
            "queries_matched": [],
        }

    # Count search result appearances per entry
    # Search events log the query and result_count, but don't list individual
    # result paths. However, we can re-derive which entries match by checking
    # if the search event's source_type includes knowledge entries.
    #
    # Since the log only records aggregate search metadata (query + count),
    # we approximate by running each unique query against the index to find
    # which entries it matches. For efficiency, we batch unique queries.
    #
    # Alternative approach: count based on query terms appearing in entry
    # titles/content. But the most accurate approach uses the FTS5 index.

    # For now, use a simpler heuristic: track unique queries and their
    # timestamps. We'll note this limitation in the report.

    # --- Session stats ---
    total_sessions = len(session_events)
    session_timestamps = [e.get("timestamp", "") for e in session_events]

    # Sessions with context signals (branch-based loading)
    sessions_with_context = sum(
        1 for e in session_events
        if e.get("context_signal", "").strip()
    )

    # Budget utilization across sessions
    budget_utilizations = []
    for e in session_events:
        used = e.get("budget_used", 0)
        total = e.get("budget_total", 1)
        if total > 0:
            budget_utilizations.append(round(used / total, 3))

    avg_budget_util = (
        round(sum(budget_utilizations) / len(budget_utilizations), 3)
        if budget_utilizations else 0.0
    )

    # --- Search stats ---
    total_searches = len(search_events)
    query_counts: dict[str, int] = defaultdict(int)
    query_timestamps: dict[str, str] = {}  # most recent timestamp per query

    for e in search_events:
        query = e.get("query", "").strip()
        if not query:
            continue
        query_counts[query] += 1
        ts = e.get("timestamp", "")
        if ts > query_timestamps.get(query, ""):
            query_timestamps[query] = ts

    # Top queries by frequency
    top_queries = sorted(
        query_counts.items(), key=lambda x: (-x[1], x[0])
    )[:20]

    # Searches with zero results
    zero_result_searches = sum(
        1 for e in search_events if e.get("result_count", 0) == 0
    )

    # Average search latency
    search_latencies = [
        e.get("elapsed_ms", 0) for e in search_events
        if "elapsed_ms" in e
    ]
    avg_search_latency = (
        round(sum(search_latencies) / len(search_latencies), 1)
        if search_latencies else 0.0
    )

    # --- Cross-reference: find entries with zero search appearances ---
    # Since the retrieval log doesn't record per-entry access for session loads
    # or search results, we identify "cold" entries as those that have never
    # appeared in any search result. We use the FTS5 index for this.
    #
    # Strategy: replay each unique search query and track which entries appear.
    accessed_entries: set[str] = set()

    try:
        # Import the search module from the same directory
        script_dir = os.path.dirname(os.path.abspath(__file__))
        sys.path.insert(0, script_dir)
        from pk_search import Searcher  # noqa: E402

        searcher = Searcher(knowledge_dir)
        searcher._ensure_index()

        for query in query_counts:
            try:
                results = searcher.search(
                    query=query,
                    limit=50,  # generous limit to capture all appearances
                    source_type="knowledge",
                )
                for r in results:
                    fp = r.get("file_path", "")
                    accessed_entries.add(fp)
            except Exception:
                continue
    except ImportError:
        # pk_search not available — skip cross-reference
        pass

    # Update entry stats with access info
    for path in entry_stats:
        if path in accessed_entries:
            entry_stats[path]["search_appearances"] = 1  # at least once
            # We don't have exact counts without per-result logging
        else:
            entry_stats[path]["search_appearances"] = 0

    # Cold entries: never appeared in any search result
    cold_entries = [
        path for path, stats in entry_stats.items()
        if stats["search_appearances"] <= cold_threshold
    ]

    # --- Build report ---
    report = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "knowledge_dir": knowledge_dir,
        "summary": {
            "total_entries": len(all_entry_paths),
            "total_sessions": total_sessions,
            "total_searches": total_searches,
            "sessions_with_context_signal": sessions_with_context,
            "avg_budget_utilization": avg_budget_util,
            "avg_search_latency_ms": avg_search_latency,
            "zero_result_searches": zero_result_searches,
            "cold_entry_count": len(cold_entries),
            "cold_threshold": cold_threshold,
        },
        "top_queries": [
            {"query": q, "count": c, "last_seen": query_timestamps.get(q, "")}
            for q, c in top_queries
        ],
        "cold_entries": sorted(cold_entries),
        "entry_access": {
            path: {
                "search_appearances": stats["search_appearances"],
            }
            for path, stats in sorted(entry_stats.items())
        },
        "session_history": {
            "count": total_sessions,
            "timestamps": session_timestamps[-20:],  # last 20
            "budget_utilizations": budget_utilizations[-20:],
        },
    }

    return report


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="usage-analyze",
        description="Analyze knowledge store retrieval patterns",
    )
    parser.add_argument("knowledge_dir", help="Path to knowledge directory")
    parser.add_argument(
        "--cold-threshold", type=int, default=0,
        help="Entries with total accesses <= this are 'cold' (default: 0)",
    )
    parser.add_argument(
        "--json", action="store_true",
        help="Output full report as JSON to stdout",
    )
    parser.add_argument(
        "--write", action="store_true",
        help="Write report to _meta/usage-report.json",
    )

    args = parser.parse_args()
    knowledge_dir = os.path.abspath(args.knowledge_dir)

    if not os.path.isdir(knowledge_dir):
        print(f"Error: directory not found: {knowledge_dir}", file=sys.stderr)
        sys.exit(1)

    report = analyze_usage(knowledge_dir, cold_threshold=args.cold_threshold)

    # Write report file if requested
    if args.write:
        meta_dir = os.path.join(knowledge_dir, "_meta")
        os.makedirs(meta_dir, exist_ok=True)
        report_path = os.path.join(meta_dir, "usage-report.json")
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
            f.write("\n")
        print(f"Report written to: {report_path}", file=sys.stderr)

    if args.json:
        print(json.dumps(report, indent=2))
        return

    # Human-readable summary
    s = report["summary"]
    print(f"Knowledge Store Usage Analysis")
    print(f"{'=' * 40}")
    print(f"Entries:          {s['total_entries']}")
    print(f"Sessions logged:  {s['total_sessions']}")
    print(f"  With context:   {s['sessions_with_context_signal']}")
    print(f"  Avg budget use: {s['avg_budget_utilization']:.0%}")
    print(f"Searches logged:  {s['total_searches']}")
    print(f"  Zero results:   {s['zero_result_searches']}")
    print(f"  Avg latency:    {s['avg_search_latency_ms']}ms")
    print(f"Cold entries:     {s['cold_entry_count']} / {s['total_entries']}")
    print()

    if report["top_queries"]:
        print("Top Queries:")
        for q in report["top_queries"][:10]:
            print(f"  {q['count']}x  {q['query']}")
        print()

    if report["cold_entries"]:
        print(f"Cold Entries (never matched in search, threshold={args.cold_threshold}):")
        for entry in report["cold_entries"][:20]:
            print(f"  - {entry}")
        remaining = len(report["cold_entries"]) - 20
        if remaining > 0:
            print(f"  ... and {remaining} more")
        print()


if __name__ == "__main__":
    main()
