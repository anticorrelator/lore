"""pk_cli: CLI interface for lore knowledge search and management.

Extracted from pk_search.py. All cmd_* functions and argument parsing live here.
pk_search.py is now a pure library (Indexer, Searcher, Stats, LinkChecker).

Usage:
    python pk_cli.py index <knowledge_dir> [--force]
    python pk_cli.py search <knowledge_dir> <query> [--limit N] [--threshold F] [--json] [--budget N]
    python pk_cli.py stats <knowledge_dir>
    python pk_cli.py resolve <knowledge_dir> <backlinks...> [--json]
    python pk_cli.py read <knowledge_dir> <file> [--query Q] [--type T]
    python pk_cli.py check-links <knowledge_dir> [--json] [--all]
"""

import argparse
import json
import os
import sqlite3
import sys
from pathlib import Path

# Library imports from the same directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_search import (  # noqa: E402
    Indexer,
    Searcher,
    Stats,
    LinkChecker,
    DEFAULT_LIMIT,
    DEFAULT_THRESHOLD,
    SOURCE_TYPES,
)
from pk_resolve import Resolver, resolve_read_path  # noqa: E402


# ---------------------------------------------------------------------------
# CLI command handlers
# ---------------------------------------------------------------------------

def cmd_index(args: argparse.Namespace) -> None:
    repo_root = getattr(args, "repo_root", None)
    indexer = Indexer(args.knowledge_dir, repo_root=repo_root)
    result = indexer.index_all(force=args.force)
    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)
    print(f"Indexed {result['files_indexed']} files, {result['total_entries']} entries in {result['elapsed_seconds']}s")
    print(f"Database: {result['db_path']}")


def cmd_search(args: argparse.Namespace) -> None:
    mode = "bm25"
    if getattr(args, "composite", False):
        mode = "composite"
    elif getattr(args, "semantic", False):
        mode = "semantic"
    elif getattr(args, "hybrid", False):
        mode = "hybrid"

    searcher = Searcher(args.knowledge_dir)
    source_type = getattr(args, "type", None)
    category = getattr(args, "category", None)
    exclude_category = getattr(args, "exclude_category", None)
    caller = getattr(args, "caller", None)
    include_archived = getattr(args, "include_archived", False)

    # --budget: budget-aware search with two-tier JSON output
    budget = getattr(args, "budget", None)
    if budget is not None:
        result = searcher.budget_search(
            query=args.query,
            budget_chars=budget,
            limit=args.limit,
            threshold=args.threshold,
            source_type=source_type,
            category=category,
            exclude_category=exclude_category,
            caller=caller,
            include_archived=include_archived,
        )
        # Normalize full entries for JSON output
        full_out = []
        for r in result["full"]:
            full_out.append({
                "heading": r.get("heading", ""),
                "file_path": r.get("file_path", ""),
                "content": r.get("content", ""),
                "score": r.get("composite_score", 0),
                "category": r.get("category"),
            })
        titles_out = []
        for r in result["titles_only"]:
            titles_out.append({
                "heading": r.get("heading", ""),
                "file_path": r.get("file_path", ""),
                "score": r.get("composite_score", 0),
                "category": r.get("category"),
            })
        print(json.dumps({
            "full": full_out,
            "titles_only": titles_out,
            "budget_used": result["budget_used"],
            "budget_total": result["budget_total"],
        }, indent=2))
        return

    if mode == "composite":
        results = searcher.composite_search(
            query=args.query,
            limit=args.limit,
            threshold=args.threshold,
            source_type=source_type,
            category=category,
            exclude_category=exclude_category,
            caller=caller,
            include_archived=include_archived,
        )
    elif mode == "bm25":
        results = searcher.search(
            query=args.query,
            limit=args.limit,
            threshold=args.threshold,
            source_type=source_type,
            category=category,
            exclude_category=exclude_category,
            caller=caller,
            include_archived=include_archived,
        )
    else:
        # Semantic or hybrid mode — requires pk_semantic
        try:
            import pk_semantic
        except ImportError:
            print(
                "Error: pk_semantic.py not found. Ensure it is in the same directory as pk_search.py.",
                file=sys.stderr,
            )
            sys.exit(1)

        # Ensure index is up to date
        searcher._ensure_index()
        db_path = searcher.db_path

        # Load all sections from the FTS5 database
        sections = pk_semantic.load_all_sections(db_path)

        if mode == "semantic":
            if not pk_semantic._check_transformers():
                print(
                    "Error: sentence-transformers not installed. "
                    "Install with: pip install sentence-transformers",
                    file=sys.stderr,
                )
                sys.exit(1)
            results = pk_semantic.search_semantic(
                args.query, db_path, sections, limit=args.limit,
            )
            results = [pk_semantic.format_result_for_cli(r, searcher.knowledge_dir) for r in results]
        else:
            # Hybrid mode
            bm25_results = searcher.search(
                query=args.query,
                limit=args.limit * 3,  # fetch more for union
                threshold=args.threshold,
                source_type=source_type,
                category=category,
                caller=caller,
                include_archived=include_archived,
            )
            adapted_bm25 = pk_semantic.adapt_bm25_results(bm25_results)
            bm25_weight = getattr(args, "bm25_weight", 0.3)
            vector_weight = getattr(args, "vector_weight", 0.7)
            results, warning = pk_semantic.hybrid_search_safe(
                args.query, db_path, sections, adapted_bm25,
                limit=args.limit,
                bm25_weight=bm25_weight,
                vector_weight=vector_weight,
            )
            if warning:
                print(f"Warning: {warning}", file=sys.stderr)
            results = [pk_semantic.format_result_for_cli(r, searcher.knowledge_dir) for r in results]

    # --expand: enrich results with similar entries from TF-IDF concordance
    expand = getattr(args, "expand", False)
    if expand and results:
        try:
            from pk_concordance import Concordance
            concordance = Concordance(searcher.db_path)
            knowledge_dir_abs = os.path.abspath(args.knowledge_dir)
            # Collect already-seen entries to avoid duplicates across results
            seen: set[tuple[str, str]] = set()
            for r in results:
                abs_path = os.path.join(knowledge_dir_abs, r["file_path"])
                seen.add((abs_path, r["heading"]))

            for r in results:
                abs_path = os.path.join(knowledge_dir_abs, r["file_path"])
                similar = concordance.find_similar(
                    abs_path, r["heading"],
                    limit=3,
                    source_type_filter="knowledge",
                    exclude=set(seen),
                )
                # Convert absolute paths back to relative for display
                for s in similar:
                    try:
                        s["file_path"] = os.path.relpath(s["file_path"], knowledge_dir_abs)
                    except ValueError:
                        pass
                r["similar_entries"] = similar
        except (ImportError, Exception):
            pass  # gracefully degrade if concordance not available

    if args.json:
        print(json.dumps(results, indent=2))
        return

    if not results:
        print(f'No results for "{args.query}"')
        return

    for i, r in enumerate(results, 1):
        st = r.get("source_type", "knowledge")
        print(f"\n--- Result {i} [{st}] (score: {r['score']}) ---")
        print(f"  File: {r['file_path']}")
        if st == "thread":
            # Thread entries have dates as headings (e.g. "2026-02-07 (Session 24)")
            print(f"  Entry: {r['heading']}")
        else:
            print(f"  Heading: {r['heading']}")
        if r.get("category"):
            print(f"  Category: {r['category']}")
        if r.get("confidence"):
            print(f"  Confidence: {r['confidence']}")
        if r.get("learned_date"):
            print(f"  Learned: {r['learned_date']}")
        print(f"  Snippet: {r['snippet']}")
        if r.get("similar_entries"):
            print("  See also:")
            for s in r["similar_entries"]:
                print(f"    - {s['heading']} ({s['file_path']}, sim: {s['similarity']})")


def cmd_stats(args: argparse.Namespace) -> None:
    stats = Stats(args.knowledge_dir)
    result = stats.get_stats()

    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)

    print(f"Knowledge dir: {result['knowledge_dir']}")
    print(f"Files indexed: {result['file_count']}")
    type_counts = result.get("type_counts", {})
    if type_counts:
        parts = [f"{v} {k}" for k, v in sorted(type_counts.items())]
        print(f"  By type:     {', '.join(parts)}")
    category_counts = result.get("category_counts", {})
    if category_counts:
        parts = [f"{v} {k}" for k, v in sorted(category_counts.items())]
        print(f"  By category: {', '.join(parts)}")
    confidence_counts = result.get("confidence_counts", {})
    if confidence_counts:
        parts = [f"{v} {k}" for k, v in sorted(confidence_counts.items())]
        print(f"  By confidence: {', '.join(parts)}")
    print(f"Total entries: {result['entry_count']}")
    print(f"Database size: {result['db_size_human']}")
    print(f"Last indexed:  {result['last_indexed']}")
    print(f"Stale files:   {result['stale_files']}")
    if result["stale_file_list"]:
        for f in result["stale_file_list"]:
            print(f"  - {f}")


def cmd_incremental_index(args: argparse.Namespace) -> None:
    repo_root = getattr(args, "repo_root", None)
    indexer = Indexer(args.knowledge_dir, repo_root=repo_root)
    result = indexer.incremental_index()
    if "error" in result:
        print(f"Error: {result['error']}", file=sys.stderr)
        sys.exit(1)
    reindexed = result["files_reindexed"]
    removed = result["files_removed"]
    if reindexed == 0 and removed == 0:
        print("Index up to date.")
    else:
        print(f"Reindexed {reindexed} files, removed {removed} in {result['elapsed_seconds']}s")


def cmd_resolve(args: argparse.Namespace) -> None:
    resolver = Resolver(args.knowledge_dir)
    backlinks = args.backlinks

    results = resolver.resolve_batch(backlinks)

    if args.json:
        print(json.dumps(results, indent=2))
        return

    for r in results:
        print(f"\n--- {r['backlink']} ---")
        if r.get("resolved"):
            content = r["content"]
            if len(content) > 2000:
                content = content[:2000] + "\n... (truncated)"
            print(content)
        else:
            print(f"  ERROR: {r.get('error', 'Unknown')}")


def cmd_read(args: argparse.Namespace) -> None:
    """Read a knowledge file, optionally filtered by query relevance.

    Without --query: output full file content.
    With --query: FTS5 search scoped to file — matching sections full,
    non-matching sections as heading-only list.
    """
    knowledge_dir = os.path.abspath(args.knowledge_dir)
    file_arg = args.file
    query = getattr(args, "query", None)
    source_type = getattr(args, "type", None)

    # Resolve file path relative to knowledge dir
    file_path = resolve_read_path(knowledge_dir, file_arg, source_type)
    if not file_path:
        print(f"Error: file not found: {file_arg}", file=sys.stderr)
        sys.exit(1)

    # v2 thread directory: concatenate all entries for display
    if os.path.isdir(file_path):
        resolver = Resolver(knowledge_dir)
        content = resolver._resolve_thread_dir(file_path, None)
        if content is None:
            content = ""
        if not query:
            print(content, end="")
            return
        # For query-based read on a thread directory, search all entry files
        searcher = Searcher(knowledge_dir)
        searcher._ensure_index()
        conn = sqlite3.connect(searcher.db_path)
        conn.row_factory = sqlite3.Row
        # Get entries for all files in this directory
        all_headings = []
        for fname in sorted(os.listdir(file_path)):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(file_path, fname)
            rows = conn.execute(
                "SELECT heading, content FROM entries WHERE file_path = ?",
                (fpath,),
            ).fetchall()
            all_headings.extend(rows)
        if not all_headings:
            conn.close()
            print(content, end="")
            return
        # Search within these entry files
        prepared = Searcher._prepare_query(query)
        matched_rows = []
        for fname in sorted(os.listdir(file_path)):
            if not fname.endswith(".md"):
                continue
            fpath = os.path.join(file_path, fname)
            try:
                rows = conn.execute(
                    """SELECT heading, content, rank FROM entries
                       WHERE entries MATCH ? AND file_path = ?
                       ORDER BY rank""",
                    (prepared, fpath),
                ).fetchall()
                matched_rows.extend(rows)
            except sqlite3.OperationalError:
                pass
        conn.close()
        matched_headings = {row["heading"] for row in matched_rows}
        rel_path = os.path.relpath(file_path, knowledge_dir)
        print(f"# {rel_path}/ (query: {query})")
        print(f"# {len(matched_headings)} matching, {len(all_headings) - len(matched_headings)} summarized")
        print()
        for row in matched_rows:
            print(f"## {row['heading']}")
            print(row["content"])
            print()
        non_matching = [h for h in all_headings if h["heading"] not in matched_headings]
        if non_matching:
            print("## Other entries (heading only)")
            for h in non_matching:
                print(f"- {h['heading']}")
            print()
        return

    if not query:
        # Simple read — output full content
        try:
            content = Path(file_path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"Error reading {file_path}: {e}", file=sys.stderr)
            sys.exit(1)
        print(content, end="")
        return

    # Query-based read — search FTS5 entries scoped to this file
    searcher = Searcher(knowledge_dir)
    searcher._ensure_index()

    conn = sqlite3.connect(searcher.db_path)
    conn.row_factory = sqlite3.Row

    # Get all indexed headings for this file
    all_headings = conn.execute(
        "SELECT heading, content FROM entries WHERE file_path = ?",
        (file_path,),
    ).fetchall()

    if not all_headings:
        # No indexed entries — fall back to full file
        conn.close()
        try:
            content = Path(file_path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            print(f"Error reading {file_path}: {e}", file=sys.stderr)
            sys.exit(1)
        print(content, end="")
        return

    # Search within this file's entries
    prepared = Searcher._prepare_query(query)
    try:
        matched_rows = conn.execute(
            """
            SELECT heading, content, rank
            FROM entries
            WHERE entries MATCH ? AND file_path = ?
            ORDER BY rank
            """,
            (prepared, file_path),
        ).fetchall()
    except sqlite3.OperationalError:
        # FTS5 syntax error — fall back to quoted phrase
        escaped = '"' + query.replace('"', '""') + '"'
        matched_rows = conn.execute(
            """
            SELECT heading, content, rank
            FROM entries
            WHERE entries MATCH ? AND file_path = ?
            ORDER BY rank
            """,
            (escaped, file_path),
        ).fetchall()

    conn.close()

    matched_headings = {row["heading"] for row in matched_rows}

    # Output: matching sections in full, non-matching as heading-only
    rel_path = os.path.relpath(file_path, knowledge_dir)
    print(f"# {rel_path} (query: {query})")
    print(f"# {len(matched_headings)} matching, {len(all_headings) - len(matched_headings)} summarized")
    print()

    # Matching sections first (in relevance order)
    for row in matched_rows:
        print(f"### {row['heading']}")
        print(row["content"])
        print()

    # Non-matching sections as heading-only list
    non_matching = [h for h in all_headings if h["heading"] not in matched_headings]
    if non_matching:
        print("### Other sections (heading only)")
        for h in non_matching:
            print(f"- {h['heading']}")
        print()


def cmd_analyze_concordance(args: argparse.Namespace) -> None:
    from pk_concordance import Concordance

    searcher = Searcher(args.knowledge_dir)
    searcher._ensure_index()

    concordance = Concordance(searcher.db_path)
    see_also_limit = getattr(args, "see_also_limit", 3)
    related_threshold = getattr(args, "related_files_threshold", 0.15)

    result = concordance.run_full_analysis(
        see_also_limit=see_also_limit,
        related_files_threshold=related_threshold,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    print(f"Concordance analysis complete.")
    print(f"  Entries analyzed: {result['entries_analyzed']}")
    print(f"  See-also pairs:   {result['see_also_pairs']}")
    print(f"  Related files:    {result['related_file_pairs']}")
    print(f"  Elapsed:          {result['elapsed_seconds']}s")

    # Print summary of see-also recommendations
    knowledge_dir_abs = os.path.abspath(args.knowledge_dir)
    conn = sqlite3.connect(searcher.db_path)
    see_also_rows = conn.execute(
        "SELECT file_path, heading, similar_entry_path, similar_entry_heading, similarity_score "
        "FROM concordance_results WHERE result_type = 'see_also' "
        "ORDER BY file_path, heading, similarity_score DESC"
    ).fetchall()
    conn.close()

    if see_also_rows:
        print(f"\nSee-also recommendations ({len(see_also_rows)} pairs):")
        current_entry = None
        for fp, heading, sim_fp, sim_heading, score in see_also_rows:
            entry_key = (fp, heading)
            if entry_key != current_entry:
                try:
                    rel_fp = os.path.relpath(fp, knowledge_dir_abs)
                except ValueError:
                    rel_fp = fp
                print(f"\n  {heading} ({rel_fp})")
                current_entry = entry_key
            try:
                rel_sim_fp = os.path.relpath(sim_fp, knowledge_dir_abs)
            except ValueError:
                rel_sim_fp = sim_fp
            print(f"    -> {sim_heading} ({rel_sim_fp}, sim: {score:.4f})")


def cmd_analyze_merge_candidates(args: argparse.Namespace) -> None:
    from pk_concordance import Concordance

    searcher = Searcher(args.knowledge_dir)
    searcher._ensure_index()

    concordance = Concordance(searcher.db_path)
    threshold = getattr(args, "threshold", 0.5)

    candidates = concordance.find_merge_candidates(threshold=threshold)

    # Write to _meta/merge-candidates.json
    knowledge_dir_abs = os.path.abspath(args.knowledge_dir)
    meta_dir = os.path.join(knowledge_dir_abs, "_meta")
    os.makedirs(meta_dir, exist_ok=True)
    output_path = os.path.join(meta_dir, "merge-candidates.json")

    # Convert absolute paths to relative for the output file
    output = []
    for c in candidates:
        entry = dict(c)
        for key in ("target_path", "source_path"):
            try:
                entry[key] = os.path.relpath(entry[key], knowledge_dir_abs)
            except ValueError:
                pass
        output.append(entry)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
        f.write("\n")

    if args.json:
        print(json.dumps(output, indent=2))
        return

    print(f"Found {len(candidates)} merge candidates (threshold >= {threshold})")
    print(f"Written to: {output_path}")
    for c in candidates:
        target_rel = c["target_path"]
        source_rel = c["source_path"]
        try:
            target_rel = os.path.relpath(c["target_path"], knowledge_dir_abs)
        except ValueError:
            pass
        try:
            source_rel = os.path.relpath(c["source_path"], knowledge_dir_abs)
        except ValueError:
            pass
        print(f"  {c['similarity']:.4f}  {c['target_title']} ({target_rel})")
        print(f"           <-> {c['source_title']} ({source_rel})")


def cmd_check_links(args: argparse.Namespace) -> None:
    checker = LinkChecker(args.knowledge_dir)
    include_all = getattr(args, "all", False)
    result = checker.check_all(
        include_archived=include_all,
        include_threads=include_all,
    )

    if args.json:
        print(json.dumps(result, indent=2))
        return

    print(f"Total backlinks scanned: {result['total_links']}")
    if result.get("placeholder_count", 0) > 0:
        print(f"Placeholder backlinks skipped: {result['placeholder_count']}")
    skipped_archived = result.get("skipped_archived_files", 0)
    skipped_threads = result.get("skipped_thread_files", 0)
    if skipped_archived or skipped_threads:
        parts = []
        if skipped_archived:
            parts.append(f"{skipped_archived} archived")
        if skipped_threads:
            parts.append(f"{skipped_threads} thread")
        print(f"Files skipped: {', '.join(parts)} (use --all to include)")
    print(f"Broken links: {result['broken_count']}")
    print(f"Archived references: {result['archived_count']}")

    if result["broken_links"]:
        print("\nBroken:")
        for bl in result["broken_links"]:
            print(f"  {bl['source_file']}: {bl['backlink']}")
            print(f"    {bl['error']}")

    if result["archived_links"]:
        print("\nArchived (resolved but work item is archived):")
        for al in result["archived_links"]:
            print(f"  {al['source_file']}: {al['backlink']}")


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="pk-search",
        description="SQLite FTS5 search for lore knowledge stores",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # index
    p_index = subparsers.add_parser("index", help="Build or rebuild the search index")
    p_index.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_index.add_argument("--force", action="store_true", help="Force full re-index")
    p_index.add_argument("--repo-root", default=None, help="Path to repo root for source file indexing")
    p_index.set_defaults(func=cmd_index)

    # incremental-index
    p_incr = subparsers.add_parser("incremental-index", help="Re-index only changed files")
    p_incr.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_incr.add_argument("--repo-root", default=None, help="Path to repo root for source file indexing")
    p_incr.set_defaults(func=cmd_incremental_index)

    # search
    p_search = subparsers.add_parser("search", help="Search indexed entries")
    p_search.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_search.add_argument("query", help="Search query (FTS5 syntax)")
    p_search.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="Max results")
    p_search.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD, help="Min relevance score (e.g. -5.0 = only strong matches; 0 = all)")
    p_search.add_argument("--type", choices=SOURCE_TYPES, default=None, help="Filter by source type")
    p_search.add_argument("--category", nargs="+", default=None, help="Filter by category (e.g. architecture conventions)")
    p_search.add_argument("--exclude-category", nargs="+", default=None, help="Exclude entries in these categories (e.g. domains)")
    p_search.add_argument("--json", action="store_true", help="Output as JSON")
    p_search.add_argument("--composite", action="store_true", help="Re-rank with composite scoring: BM25 + recency + TF-IDF similarity")
    p_search.add_argument("--semantic", action="store_true", help="Use vector similarity search (requires sentence-transformers)")
    p_search.add_argument("--hybrid", action="store_true", help="Combine BM25 + vector similarity (requires sentence-transformers)")
    p_search.add_argument("--bm25-weight", type=float, default=0.3, help="BM25 weight for hybrid search (default: 0.3)")
    p_search.add_argument("--vector-weight", type=float, default=0.7, help="Vector weight for hybrid search (default: 0.7)")
    p_search.add_argument("--caller", default=None, help="Caller identifier logged to retrieval log (e.g. 'lead', 'worker', 'prefetch')")
    p_search.add_argument("--include-archived", action="store_true", help="Include archived work items in results (excluded by default)")
    p_search.add_argument("--expand", action="store_true", help="Expand results with similar entries from TF-IDF concordance (See also)")
    p_search.add_argument("--budget", type=int, default=None, help="Budget in chars: return two-tier JSON (full + titles_only) within budget")
    p_search.set_defaults(func=cmd_search)

    # resolve
    p_resolve = subparsers.add_parser("resolve", help="Resolve [[backlink]] references to content")
    p_resolve.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_resolve.add_argument("backlinks", nargs="+", help="One or more backlinks (e.g. '[[knowledge:architecture#Section]]')")
    p_resolve.add_argument("--json", action="store_true", help="Output as JSON")
    p_resolve.set_defaults(func=cmd_resolve)

    # read
    p_read = subparsers.add_parser("read", help="Read a knowledge file, optionally filtered by query")
    p_read.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_read.add_argument("file", help="File to read (e.g. 'conventions', 'domains/topic', 'memory-system-design')")
    p_read.add_argument("--query", "-q", default=None, help="Filter sections by relevance to query")
    p_read.add_argument("--type", choices=SOURCE_TYPES, default=None, help="Source type hint (e.g. 'thread')")
    p_read.set_defaults(func=cmd_read)

    # check-links
    p_check = subparsers.add_parser("check-links", help="Scan for broken [[backlink]] references")
    p_check.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_check.add_argument("--json", action="store_true", help="Output as JSON")
    p_check.add_argument("--all", action="store_true", help="Include archived work items and thread files (excluded by default)")
    p_check.set_defaults(func=cmd_check_links)

    # analyze-concordance
    p_conc = subparsers.add_parser("analyze-concordance", help="Run TF-IDF concordance analysis (see-also + related files)")
    p_conc.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_conc.add_argument("--json", action="store_true", help="Output as JSON")
    p_conc.add_argument("--see-also-limit", type=int, default=3, help="Max see-also entries per knowledge entry (default: 3)")
    p_conc.add_argument("--related-files-threshold", type=float, default=0.05, help="Min similarity for related files (default: 0.05)")
    p_conc.set_defaults(func=cmd_analyze_concordance)

    # analyze-merge-candidates
    p_merge = subparsers.add_parser("analyze-merge-candidates", help="Find knowledge entries that may be duplicates (high similarity)")
    p_merge.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_merge.add_argument("--json", action="store_true", help="Output as JSON")
    p_merge.add_argument("--threshold", type=float, default=0.5, help="Min similarity for merge candidates (default: 0.5)")
    p_merge.set_defaults(func=cmd_analyze_merge_candidates)

    # stats
    p_stats = subparsers.add_parser("stats", help="Show index statistics")
    p_stats.add_argument("knowledge_dir", help="Path to knowledge directory")
    p_stats.set_defaults(func=cmd_stats)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
