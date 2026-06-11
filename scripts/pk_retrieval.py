"""pk_retrieval: shared retrieval-core primitives for lore knowledge pipelines.

Pure module — no imports from other pk_* modules. Owns the mechanics every
retrieval entry point shares: entry-field access, ordered dedupe, budget
partitioning, entry-block rendering, and full -> snippet -> backlink budget
degradation. Pipelines (pk_prefetch, pk_manifest, pk_query, Searcher's
budget_search) compose these instead of carrying private copies.

Scale and status filtering are NOT here: Searcher.search (pk_search.py) is
the single authority for those, including the preferences-category and
abstract-scale bypass rules.
"""

# Shared char ceiling for prompt-formatted ## Prior Knowledge bundles
# (prefetch single-pass budget and manifest v2 global ceiling).
DEFAULT_PROMPT_BUDGET = 12000

# Max chars rendered for an entry degraded to snippet mode.
SNIPPET_CHAR_LIMIT = 600


# ---------------------------------------------------------------------------
# Entry-field access
# ---------------------------------------------------------------------------

def entry_path(entry: dict) -> str:
    return entry.get("path") or entry.get("file_path") or ""


def entry_heading(entry: dict) -> str:
    return entry.get("heading") or entry.get("title") or ""


def entry_key(entry: dict) -> tuple[str, str]:
    """Canonical identity of a served entry: (file_path, heading)."""
    return (entry.get("file_path", ""), entry.get("heading", ""))


def strip_md_suffix(path: str) -> str:
    return path[:-3] if path.endswith(".md") else path


def backlink_for(path: str, heading: str | None = None) -> str:
    """Render a [[knowledge:...]] backlink for a store-relative entry path."""
    target = strip_md_suffix(path)
    if heading:
        return f"[[knowledge:{target}#{heading}]]"
    return f"[[knowledge:{target}]]"


# ---------------------------------------------------------------------------
# Dedupe
# ---------------------------------------------------------------------------

def dedupe_entries(entries: list[dict], key_fn=entry_key, seen: set | None = None) -> list[dict]:
    """Order-preserving dedupe. Entries with falsy keys are dropped only when
    key_fn is entry_path-like and returns ""; (..,"") tuples are kept.

    Pass a shared `seen` set to dedupe across multiple pools — the set is
    mutated so later calls see earlier pools' keys.
    """
    if seen is None:
        seen = set()
    out = []
    for e in entries:
        k = key_fn(e)
        if isinstance(k, str) and not k:
            continue
        if k in seen:
            continue
        seen.add(k)
        out.append(e)
    return out


def path_exclusion_set(paths: list[str]) -> set[str]:
    """Expand store-relative paths to also match their .md spellings."""
    out: set[str] = set()
    for p in paths:
        if not p:
            continue
        out.add(p)
        if not p.endswith(".md"):
            out.add(p + ".md")
    return out


def exclude_by_paths(entries: list[dict], exclude: set[str]) -> list[dict]:
    """Drop entries whose file_path (with or without .md) is in `exclude`."""
    if not exclude:
        return list(entries)
    out = []
    for e in entries:
        fp = e.get("file_path", "")
        fp_no_ext = fp.rsplit(".", 1)[0] if "." in fp else fp
        if fp in exclude or fp_no_ext in exclude:
            continue
        out.append(e)
    return out


# ---------------------------------------------------------------------------
# Budget partitioning (two-tier full/titles_only)
# ---------------------------------------------------------------------------

def partition_two_tier(results: list[dict], budget_chars: int) -> dict:
    """Partition ranked results into full entries that fit budget_chars and a
    titles-only tail. Content size is the only cost counted.
    """
    full: list[dict] = []
    titles_only: list[dict] = []
    budget_used = 0

    for r in results:
        content_size = len(r.get("content", ""))
        if budget_used + content_size <= budget_chars:
            full.append(r)
            budget_used += content_size
        else:
            titles_only.append({
                "heading": r.get("heading", ""),
                "file_path": r.get("file_path", ""),
                "source_type": r.get("source_type", ""),
                "category": r.get("category"),
                "composite_score": r.get("composite_score", 0),
            })

    return {
        "full": full,
        "titles_only": titles_only,
        "budget_used": budget_used,
        "budget_total": budget_chars,
    }


def budget_json_payload(result: dict) -> dict:
    """Normalize a budget_search result into the public two-tier JSON shape
    (`score` exposes the composite score; internal fields are dropped).
    """
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
    return {
        "full": full_out,
        "titles_only": titles_out,
        "budget_used": result["budget_used"],
        "budget_total": result["budget_total"],
    }


# ---------------------------------------------------------------------------
# Budget degradation strategies
# ---------------------------------------------------------------------------

def emit_degrading(items: list, budget: int, render_full, render_snippet, render_backlink):
    """Greedy per-item degradation: for each item in rank order emit the
    richest block that fits the remaining budget (full -> snippet ->
    backlink); stop entirely once even a backlink no longer fits.

    Returns (blocks, budget_remaining).
    """
    blocks: list[str] = []
    remaining = budget
    for item in items:
        block = render_full(item)
        if len(block) > remaining:
            block = render_snippet(item)
            if len(block) > remaining:
                block = render_backlink(item)
                if len(block) > remaining:
                    break
        blocks.append(block)
        remaining -= len(block)
    return blocks, remaining


def degrade_section(candidates: list, budget: int, floor: int, header_chars: int,
                    render_full, render_snippet, render_backlink) -> dict:
    """Section-wide degradation: render all candidates full, then step the
    last-ranked block down one mode at a time (full -> snippet -> backlink)
    until the section fits `budget`; once everything is backlinks, drop
    entries from the bottom but never below `floor`.

    Returns dict with: rendered_blocks (list of (candidate, mode, block)),
    content_degraded, shrunk_for_budget.
    """
    rendered_blocks: list[tuple] = [(c, "full", render_full(c)) for c in candidates]
    content_degraded = False
    shrunk_for_budget = False

    def _total(rb):
        return header_chars + sum(len(b) for _, _, b in rb)

    while _total(rendered_blocks) > budget and rendered_blocks:
        downgraded = False
        for i in range(len(rendered_blocks) - 1, -1, -1):
            cand, mode, _ = rendered_blocks[i]
            if mode == "full":
                rendered_blocks[i] = (cand, "snippet", render_snippet(cand))
                content_degraded = True
                downgraded = True
                break
            if mode == "snippet":
                rendered_blocks[i] = (cand, "backlink", render_backlink(cand))
                content_degraded = True
                downgraded = True
                break
        if downgraded:
            continue
        if len(rendered_blocks) > floor:
            rendered_blocks.pop()
            shrunk_for_budget = True
            continue
        break

    return {
        "rendered_blocks": rendered_blocks,
        "content_degraded": content_degraded,
        "shrunk_for_budget": shrunk_for_budget,
    }
