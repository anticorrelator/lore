"""pk_query: seeds-keyed compositional retrieval for `lore query`.

Library for `pk_cli.py query`; the `cli/lore` cmd_query wrapper validates
flags (seed presence, required --scale-set, --budget/--hop-budget exclusion)
and dispatches here. Seeds may be backlink references (knowledge:<path> or
work:<slug>, with or without [[...]]) or query text.

Scale filtering is delegated to Searcher (single authority — including the
preferences-category and abstract-scale bypass rules); no post-filter is
applied here.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_search import Searcher, SOURCE_TYPES, attach_similar_entries  # noqa: E402
from pk_resolve import Resolver  # noqa: E402
import pk_retrieval  # noqa: E402


def _partition_seeds(seeds_csv: str) -> tuple[list[str], list[str]]:
    """Split a comma-separated seed list into (backlink_seeds, query_parts)."""
    backlink_seeds: list[str] = []
    query_parts: list[str] = []
    for raw_seed in seeds_csv.split(","):
        seed = raw_seed.strip()
        if not seed:
            continue
        inner = seed.removeprefix("[[").removesuffix("]]")
        if inner.startswith("knowledge:") or inner.startswith("work:"):
            backlink_seeds.append(inner)
        else:
            query_parts.append(seed)
    return backlink_seeds, query_parts


def _warn_unresolved(knowledge_dir: str, backlink_seeds: list[str]) -> None:
    """Resolve backlink seeds and emit stderr warnings for unresolved ones."""
    resolver = Resolver(knowledge_dir)
    try:
        results = resolver.resolve_batch([f"[[{bs}]]" for bs in backlink_seeds])
    except Exception:
        return
    for r in results:
        if not r.get("resolved"):
            print(
                f"Warning: unresolved backlink '{r.get('backlink', '')}': {r.get('error', 'not found')}",
                file=sys.stderr,
            )


def _build_query(backlink_seeds: list[str], query_parts: list[str]) -> str:
    if query_parts:
        return " ".join(query_parts)
    if backlink_seeds:
        # Use the first backlink target's last path component as a query fallback
        query = backlink_seeds[0].removeprefix("knowledge:").removeprefix("work:")
        query = query.rsplit("/", 1)[-1]
        return query.split("#", 1)[0]
    return ""


def _inject_path(entries: list[dict]) -> list[dict]:
    out = []
    for r in entries:
        entry = dict(r)
        if "path" not in entry:
            entry["path"] = entry.get("file_path", "")
        for s in entry.get("similar_entries", []):
            if "path" not in s:
                s["path"] = s.get("file_path", "")
        out.append(entry)
    return out


def _render_prompt(data) -> None:
    """Emit a compact ## Prior Knowledge backlink list from results."""
    entries = data["full"] if isinstance(data, dict) and "full" in data else data
    if not entries:
        return

    lines = ["## Prior Knowledge"]
    for r in entries:
        heading = r.get("heading", "")
        fp = pk_retrieval.strip_md_suffix(r.get("file_path", r.get("path", "")))
        snippet = r.get("snippet", r.get("content", ""))
        if len(snippet) > 300:
            snippet = snippet[:300].rsplit(" ", 1)[0] + "..."
        lines.append(f"- {pk_retrieval.backlink_for(fp, heading)}")
        if snippet:
            lines.append(f"  {snippet.splitlines()[0][:200]}")
        for s in r.get("similar_entries", []):
            sfp = pk_retrieval.strip_md_suffix(s.get("file_path", s.get("path", "")))
            lines.append(f"  - See also: {pk_retrieval.backlink_for(sfp, s.get('heading', ''))}")

    print("\n".join(lines))


def run_query(
    knowledge_dir: str,
    seeds: str,
    scale_set: list[str],
    hop_budget: int = 0,
    budget: int | None = None,
    type_filter: str = "knowledge",
    exclude_category: str = "",
    fmt: str = "json",
) -> int:
    """Run the seeds-keyed query pipeline and print results to stdout."""
    knowledge_dir = os.path.abspath(knowledge_dir)
    backlink_seeds, query_parts = _partition_seeds(seeds)

    if backlink_seeds:
        _warn_unresolved(knowledge_dir, backlink_seeds)

    query = _build_query(backlink_seeds, query_parts)
    if not query:
        if fmt != "prompt":
            print("[]")
        return 0

    source_type = None if type_filter == "all" else type_filter
    if source_type is not None and source_type not in SOURCE_TYPES:
        # Unknown source types yield an empty result, not an unfiltered search.
        if fmt != "prompt":
            print("[]")
        return 0

    searcher = Searcher(knowledge_dir)
    data = None
    try:
        if budget is not None:
            result = searcher.budget_search(
                query=query,
                budget_chars=budget,
                scale_set=scale_set,
                source_type=source_type,
                exclude_category=exclude_category or None,
                caller="lore-query",
            )
            data = pk_retrieval.budget_json_payload(result)
        else:
            data = searcher.search(
                query=query,
                scale_set=scale_set,
                source_type=source_type,
                exclude_category=exclude_category or None,
                caller="lore-query",
            )
            if hop_budget >= 1:
                attach_similar_entries(searcher, data)
    except (Exception, SystemExit):
        # Searcher exits via sys.exit on an unusable index (e.g. knowledge dir
        # missing); the query surface stays fail-open: empty results, exit 0.
        data = []

    if isinstance(data, dict) and "full" in data:
        data["full"] = _inject_path(data["full"])
        data["titles_only"] = _inject_path(data["titles_only"])
    else:
        data = _inject_path(data)

    if fmt == "prompt":
        _render_prompt(data)
    else:
        print(json.dumps(data, indent=2))
    return 0
