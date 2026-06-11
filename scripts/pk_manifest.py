"""pk_manifest: resolve a v2 retrieval_directive into a ## Prior Knowledge bundle.

Library for `pk_cli.py resolve-manifest`; the shell adapter
resolve-manifest.sh validates arguments, extracts the phase directive from
tasks.json, and dispatches v2 directives here (the legacy flat path stays in
the shell, composing `lore query`).

Manifest-specific orchestration (topic fan-out, activity reserved slots,
per-section budgets, telemetry) lives here; scale filtering happens inside
Searcher.search (single authority) and dedupe/degradation come from
pk_retrieval.
"""

import datetime
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_search import Searcher  # noqa: E402
import pk_retrieval  # noqa: E402

GLOBAL_CHAR_CEILING = pk_retrieval.DEFAULT_PROMPT_BUDGET
FOCAL_FLOOR_K = 5
ACTIVITY_RESERVED_FOCAL = 2
ACTIVITY_RESERVED_ADJACENT = 1
MANIFEST_VERSION = 2
SNIPPET_CHAR_LIMIT = pk_retrieval.SNIPPET_CHAR_LIMIT

_KNOWLEDGE_BL_RE = re.compile(r"\[\[knowledge:([^\]#]+)(#[^\]]+)?\]\]")
_WORK_BL_RE = re.compile(r"\[\[work:([^\]#]+)(#[^\]]+)?\]\]")


def _backlink_to_vocab(seed: str) -> str:
    """Resolve a backlink seed to its title/path-vocabulary tokens.

    Raw `[[knowledge:foo/bar/baz]]` would tokenize as a single literal and
    miss the index. Strip brackets and split path components into tokens.
    """
    for pattern in (_KNOWLEDGE_BL_RE, _WORK_BL_RE):
        m = pattern.match(seed.strip())
        if m:
            tokens = re.split(r"[\s/\-_]+", m.group(1))
            return " ".join(t for t in tokens if t)
    return seed.strip()


def _build_query(topic: dict) -> str:
    """Build the BM25 OR query from a topic. Honor literal `query:` if set."""
    if topic.get("query"):
        return topic["query"]
    parts: list[str] = []
    if topic.get("topic"):
        parts.append(topic["topic"])
    for seed in topic.get("seeds", []):
        resolved = _backlink_to_vocab(seed)
        if resolved:
            parts.append(resolved)
    return " ".join(parts).strip()


def _entry_full_block(entry: dict) -> str:
    heading = pk_retrieval.entry_heading(entry)
    path = pk_retrieval.entry_path(entry)
    content = entry.get("content") or entry.get("body") or entry.get("snippet") or ""
    return f"\n#### {heading} (from {path})\n{content}\n"


def _entry_snippet_block(entry: dict) -> str:
    heading = pk_retrieval.entry_heading(entry)
    path = pk_retrieval.entry_path(entry)
    snippet = (entry.get("snippet") or entry.get("content") or "")[:SNIPPET_CHAR_LIMIT]
    return f"\n#### {heading} (from {path})\n{snippet}\n"


def _entry_backlink_block(entry: dict) -> str:
    heading = pk_retrieval.entry_heading(entry)
    path = pk_retrieval.entry_path(entry)
    return f"\n- {pk_retrieval.backlink_for(path, heading)}\n"


def resolve_v2(knowledge_dir: str, directive: dict, slug: str, phase_number: int) -> int:
    """Resolve a v2 directive: per-topic fan-out, sectioned render, telemetry."""
    knowledge_dir = os.path.abspath(knowledge_dir)
    topics = directive.get("topics", [])
    if not topics:
        print(f"Error: v2 directive in phase {phase_number} of '{slug}' has empty topics list.", file=sys.stderr)
        return 1

    searcher = Searcher(knowledge_dir)
    call_log: list[dict] = []

    def _run_query(query: str, scale_set: list[str], limit: int, query_kind: str) -> list[dict]:
        if not query.strip() or not scale_set:
            return []
        try:
            results = searcher.search(
                query=query,
                limit=limit,
                scale_set=scale_set,
                caller="resolve-manifest",
                query_kind=query_kind,
            )
        except (Exception, SystemExit):
            # A failed query (including Searcher's sys.exit on an unusable
            # index) degrades this topic to an empty section; the manifest,
            # _RM_PATHS marker, and telemetry must still be emitted.
            return []
        return [e for e in results if isinstance(e, dict)]

    def _log_call(topic_label: str, scale_set: list[str], query_kind: str, query: str, raw_count: int):
        call_log.append({
            "topic": topic_label,
            "scale_set": scale_set,
            "query_kind": query_kind,
            "query": query,
            "raw_count": raw_count,
        })

    # --- Step 1: Per-topic fan-out + activity-pass merging ---

    def _resolve_topic(topic: dict) -> dict:
        """Run topic + (optional) activity queries; merge with reserved-slot policy."""
        role = topic.get("role", "adjacent")
        label = topic.get("topic", "")
        scale_set = topic.get("scale_set", [])
        requested_k = int(topic.get("limit") or (8 if role == "focal" else 4))
        activity_vocab = topic.get("activity_vocab") or []

        query = _build_query(topic)
        raw_topical = _run_query(query, scale_set, max(requested_k * 2, requested_k + 4), "topic")
        _log_call(label, scale_set, "topic", query, len(raw_topical))

        raw_activity: list[dict] = []
        if activity_vocab:
            activity_query = " ".join(activity_vocab)
            raw_activity = _run_query(activity_query, scale_set, max(requested_k, 4), "activity")
            _log_call(label, scale_set, "activity", activity_query, len(raw_activity))

        seen_paths: set[str] = set()
        selected_topical = [
            {"entry": e, "query_kind": "topic"}
            for e in pk_retrieval.dedupe_entries(raw_topical, key_fn=pk_retrieval.entry_path, seen=seen_paths)
        ]
        activity_unique = [
            {"entry": e, "query_kind": "activity"}
            for e in pk_retrieval.dedupe_entries(raw_activity, key_fn=pk_retrieval.entry_path, seen=seen_paths)
        ]

        # Selection: take up to (requested_k - reserved) topical, then up to
        # `reserved` activity, then roll unused reserved slots back to topical.
        reserved = ACTIVITY_RESERVED_FOCAL if role == "focal" else ACTIVITY_RESERVED_ADJACENT
        base_topical_slots = max(requested_k - reserved, 0)
        chosen: list[dict] = []
        chosen.extend(selected_topical[:base_topical_slots])
        activity_to_take = min(reserved, len(activity_unique))
        chosen.extend(activity_unique[:activity_to_take])
        rollback = reserved - activity_to_take
        extras = selected_topical[base_topical_slots:base_topical_slots + rollback]
        chosen.extend(extras)
        while len(chosen) < requested_k:
            consumed_topical = base_topical_slots + len(extras)
            if consumed_topical < len(selected_topical):
                chosen.append(selected_topical[consumed_topical])
                base_topical_slots += 1
                continue
            if activity_to_take < len(activity_unique):
                chosen.append(activity_unique[activity_to_take])
                activity_to_take += 1
                continue
            break

        return {
            "role": role,
            "topic": label,
            "requested_k": requested_k,
            "raw_count": len(raw_topical) + len(raw_activity),
            "deduped_count": len(selected_topical) + len(activity_unique),
            "candidates": chosen[:requested_k],
        }

    resolved_topics = [_resolve_topic(t) for t in topics]

    # Cross-section dedupe: an entry in both focal and adjacent stays in focal.
    seen_global: set[str] = set()
    for sec in resolved_topics:
        if sec["role"] == "focal":
            for c in sec["candidates"]:
                p = pk_retrieval.entry_path(c["entry"])
                if p:
                    seen_global.add(p)
    for sec in resolved_topics:
        if sec["role"] != "focal":
            sec["candidates"] = pk_retrieval.dedupe_entries(
                sec["candidates"],
                key_fn=lambda c: pk_retrieval.entry_path(c["entry"]),
                seen=seen_global,
            )

    # --- Step 2: Per-section budget allocation ---
    # Focal gets ~40% of the global ceiling; adjacent sections split the rest.
    focal_sections = [s for s in resolved_topics if s["role"] == "focal"]
    adjacent_sections = [s for s in resolved_topics if s["role"] == "adjacent"]

    focal_budget = int(GLOBAL_CHAR_CEILING * 0.40) if focal_sections else 0
    adjacent_per = (GLOBAL_CHAR_CEILING - focal_budget) // len(adjacent_sections) if adjacent_sections else 0

    for sec in resolved_topics:
        sec["chars_budget"] = focal_budget if sec["role"] == "focal" else adjacent_per

    # --- Step 3: Render with full -> snippet -> backlink degradation per section ---

    def _render_section(sec: dict) -> dict:
        candidates = sec["candidates"]
        floor = FOCAL_FLOOR_K if sec["role"] == "focal" else 1
        header_line = f"\n### {sec['role'].capitalize()}: {sec['topic']}\n"

        degraded = pk_retrieval.degrade_section(
            candidates,
            budget=sec["chars_budget"],
            floor=floor,
            header_chars=len(header_line),
            render_full=lambda c: _entry_full_block(c["entry"]),
            render_snippet=lambda c: _entry_snippet_block(c["entry"]),
            render_backlink=lambda c: _entry_backlink_block(c["entry"]),
        )
        rendered_blocks = degraded["rendered_blocks"]

        render_mode_counts = {"full": 0, "snippet": 0, "backlink": 0}
        for _, m, _ in rendered_blocks:
            render_mode_counts[m] += 1
        served_paths = [
            pk_retrieval.entry_path(c["entry"])
            for c, _, _ in rendered_blocks
            if pk_retrieval.entry_path(c["entry"])
        ]

        return {
            "rendered": header_line + "".join(b for _, _, b in rendered_blocks),
            "served_count": len(rendered_blocks),
            "chars_used": len(header_line) + sum(len(b) for _, _, b in rendered_blocks),
            "render_mode_counts": render_mode_counts,
            "content_degraded": degraded["content_degraded"],
            "shrunk_for_budget": degraded["shrunk_for_budget"],
            "entry_count_before_budget": len(candidates),
            "served_paths": served_paths,
        }

    output_parts: list[str] = ["## Prior Knowledge\n"]
    total_chars = len(output_parts[0])
    section_records: list[dict] = []

    for sec in resolved_topics:
        sec["render_result"] = _render_section(sec)

    # If combined output exceeds the global ceiling, shrink adjacent sections
    # first, then focal — but focal never drops below its floor.
    combined_chars = total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics)
    if combined_chars > GLOBAL_CHAR_CEILING:
        overflow = combined_chars - GLOBAL_CHAR_CEILING
        for sec in resolved_topics:
            if sec["role"] != "adjacent":
                continue
            sec["chars_budget"] = max(sec["chars_budget"] - overflow, 200)
            sec["render_result"] = _render_section(sec)
            combined_chars = total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics)
            if combined_chars <= GLOBAL_CHAR_CEILING:
                break

    if total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics) > GLOBAL_CHAR_CEILING:
        for sec in resolved_topics:
            if sec["role"] != "focal":
                continue
            sec["chars_budget"] = int(sec["chars_budget"] * 0.7)
            sec["render_result"] = _render_section(sec)
            if total_chars + sum(s["render_result"]["chars_used"] for s in resolved_topics) <= GLOBAL_CHAR_CEILING:
                break

    for sec in resolved_topics:
        output_parts.append(sec["render_result"]["rendered"])
        section_records.append({
            "manifest_version": MANIFEST_VERSION,
            "topic": sec["topic"],
            "section_role": sec["role"],
            "requested_k": sec["requested_k"],
            "raw_count": sec["raw_count"],
            "served_count": sec["render_result"]["served_count"],
            "deduped_count": sec["deduped_count"],
            "served_paths": sec["render_result"]["served_paths"],
            "chars_used": sec["render_result"]["chars_used"],
            "chars_budget": sec["chars_budget"],
            "render_mode_counts": sec["render_result"]["render_mode_counts"],
            "content_degraded": sec["render_result"]["content_degraded"],
            "shrunk_for_budget": sec["render_result"]["shrunk_for_budget"],
            "entry_count_before_budget": sec["render_result"]["entry_count_before_budget"],
        })

    print("".join(output_parts), end="")

    # Stdout side-channel contract: a single trailing line of the exact form
    # `<!-- _RM_PATHS=<csv> -->` where <csv> is the unquoted comma-separated
    # list of served paths (paths may not contain commas). Callers that
    # capture this script's stdout may extract the CSV and export it as
    # RESOLVE_MANIFEST_PATHS, mirroring the legacy flat path. Edits MUST
    # preserve the literal `<!-- _RM_PATHS=` prefix and ` -->` suffix; do not
    # migrate this side channel to a sidecar file.
    all_paths: list[str] = []
    for sec in section_records:
        all_paths.extend(sec["served_paths"])
    print(f"\n<!-- _RM_PATHS={','.join(all_paths)} -->")

    # Telemetry: manifest_load event with per-section + per-call records (fail-open)
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        record = {
            "timestamp": ts,
            "event": "manifest_load",
            "slug": slug,
            "phase": phase_number,
            "task_id": None,
            "manifest_version": MANIFEST_VERSION,
            "loaded_paths": all_paths,
            "sections": section_records,
            "calls": call_log,
        }
        with open(log_path, "a") as lf:
            lf.write(json.dumps(record) + "\n")
    except OSError:
        pass

    return 0
