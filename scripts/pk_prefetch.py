"""pk_prefetch: prefetch pipeline — search the knowledge store and render a
## Prior Knowledge block for agent prompts.

Library for `pk_cli.py prefetch`; the shell adapter prefetch-knowledge.sh
parses flags, enforces the --scale-set declaration, and dispatches here.

Scale and status filtering happen inside Searcher.search / search_preferences
(the single authority, including the preferences-category and abstract-scale
bypasses); this pipeline only dedupes, budgets, and renders what the
primitives return.
"""

import datetime
import importlib.util
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_search import Searcher, render_trust_stamp, _CORRECTIONS_FIELD_RE  # noqa: E402
from pk_resolve import Resolver, build_backlink_from_result  # noqa: E402
import pk_retrieval  # noqa: E402

PREFETCH_BUDGET = pk_retrieval.DEFAULT_PROMPT_BUDGET
SNIPPET_LIMIT = pk_retrieval.SNIPPET_CHAR_LIMIT


def _log_prefetch(
    knowledge_dir: str,
    served_results: list[dict],
    caller: str | None = None,
    scale_set: list[str] | None = None,
) -> None:
    """Append a prefetch event to retrieval-log.jsonl.

    `caller` and `scale_declared` are additive attribution fields (null/absent
    on old rows) so assessment-time joins can attribute prefetch delivery;
    `scale_declared` uses the same CSV form as search records.
    """
    log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    loaded_paths = [r["file_path"] for r in served_results if r.get("file_path")]
    record = {
        "timestamp": ts,
        "event": "prefetch",
        "loaded_paths": loaded_paths,
        "caller": caller,
        "scale_declared": ",".join(scale_set) if scale_set else None,
    }
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a") as lf:
            lf.write(json.dumps(record) + "\n")
    except OSError:
        pass


def _last_corrected_line(knowledge_dir: str, file_path_rel: str) -> str:
    """Return 'Last corrected: <date> — <evidence>' for most recent correction, or ''."""
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    try:
        text = open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return ""
    m = _CORRECTIONS_FIELD_RE.search(text)
    if not m:
        return ""
    try:
        items = json.loads(m.group(1))
        if not items:
            return ""
        latest = max(
            (it for it in items if isinstance(it, dict) and it.get("date")),
            key=lambda it: it["date"],
            default=None,
        )
        if not latest:
            return ""
        date = latest.get("date", "")
        evidence = latest.get("evidence", "").strip()
        if evidence:
            return f"Last corrected: {date} — {evidence}"
        return f"Last corrected: {date}"
    except (json.JSONDecodeError, TypeError):
        return ""


def _load_see_also_map(knowledge_dir: str) -> dict:
    """(abs_file_path, heading) -> [backlink, ...] from concordance see_also pairs."""
    see_also_map: dict = {}
    db_path = os.path.join(knowledge_dir, ".pk_search.db")
    if not os.path.exists(db_path):
        return see_also_map
    try:
        conn = sqlite3.connect(db_path)
        rows = conn.execute(
            "SELECT file_path, heading, similar_entry_path, similar_entry_heading, similarity_score "
            "FROM concordance_results WHERE result_type = 'see_also' "
            "ORDER BY similarity_score DESC"
        ).fetchall()
        conn.close()
    except (sqlite3.OperationalError, sqlite3.DatabaseError):
        return see_also_map
    for fp, heading, sim_fp, sim_heading, _score in rows:
        try:
            sim_rel = os.path.relpath(sim_fp, knowledge_dir)
        except ValueError:
            sim_rel = sim_fp
        see_also_map.setdefault((fp, heading), []).append(
            f"[[knowledge:{pk_retrieval.strip_md_suffix(sim_rel)}#{sim_heading}]]"
        )
    return see_also_map


# --- Staleness scoring (optional — graceful fallback if unavailable) ---

_staleness_mod = None
_repo_root = None


def _load_staleness() -> None:
    global _staleness_mod, _repo_root
    if _staleness_mod is not None:
        return
    script_dir = os.path.dirname(os.path.abspath(__file__))
    ss_path = os.path.join(script_dir, "staleness-scan.py")
    if not os.path.isfile(ss_path):
        _staleness_mod = False
        return
    try:
        spec = importlib.util.spec_from_file_location("staleness_scan", ss_path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _staleness_mod = mod
    except Exception:
        _staleness_mod = False
        return
    d = os.getcwd()
    while True:
        if os.path.isdir(os.path.join(d, ".git")):
            _repo_root = d
            return
        parent = os.path.dirname(d)
        if parent == d:
            _repo_root = os.getcwd()
            return
        d = parent


def _staleness_annotation(knowledge_dir: str, file_path_rel: str) -> str:
    """Score a knowledge entry and return a [STALE] annotation or empty string."""
    _load_staleness()
    if not _staleness_mod or _staleness_mod is False:
        return ""
    abs_path = os.path.join(knowledge_dir, file_path_rel)
    if not os.path.isfile(abs_path):
        return ""
    try:
        meta = _staleness_mod.parse_metadata(abs_path)
        file_drift = _staleness_mod.compute_file_drift(
            _repo_root, meta["learned"], meta["related_files"]
        )
        if not file_drift.get("available", False):
            return ""
        backlink_drift = _staleness_mod.compute_backlink_drift(abs_path, knowledge_dir)
        drift_score, status, signals = _staleness_mod.score_entry(
            file_drift, backlink_drift, meta["confidence"]
        )
        if status == "stale":
            reason = _staleness_mod._top_signal(signals)
            return f" [STALE — drift: {drift_score:.2f}, {reason}]"
    except Exception:
        pass
    return ""


def _emit_scope_pointers(knowledge_dir: str, work_item: str, query: str) -> None:
    """Surface scope_pointers.jsonl rows whose scope hint/payload matches the query."""
    sp_path = os.path.join(knowledge_dir, "_work", work_item, "scope_pointers.jsonl")
    if not os.path.isfile(sp_path):
        return
    query_lower = query.lower()
    rows = []
    try:
        with open(sp_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        return
    matched = []
    for row in rows:
        hint = (row.get("target_scope_hint") or "").lower()
        payload = (row.get("payload") or "").lower()
        if not hint or query_lower in hint or query_lower in payload:
            matched.append(row)
    if not matched:
        return
    print()
    print("## Scope Pointers")
    print("Pending researcher/worker concerns routed from off-scale sidecar:")
    for row in matched:
        slot = row.get("protocol_slot", "")
        source = row.get("source", "")
        hint = row.get("target_scope_hint", "") or "(no scope hint)"
        payload = row.get("payload", "")
        route_id = row.get("route_id", "")
        print()
        print(f"- **[{slot}]** (source: {source}, scope: {hint}, route_id: {route_id})")
        print(f"  {payload}")


def run_prefetch(
    knowledge_dir: str,
    query: str,
    scale_set: list[str],
    fmt: str = "prompt",
    limit: int = 5,
    source_type: str = "knowledge",
    exclude_backlinks: str = "",
    work_item: str = "",
    no_preferences: bool = False,
    caller: str | None = None,
) -> int:
    """Run the prefetch pipeline and print the formatted block to stdout."""
    knowledge_dir = os.path.abspath(knowledge_dir)
    try:
        searcher = Searcher(knowledge_dir)
        resolver = Resolver(knowledge_dir)
    except (Exception, SystemExit):
        # Prefetch is fail-open for its hook callers: an unusable store
        # yields an empty block and exit 0, never a traceback.
        return 0

    # Preferences side-channel (always-on; --no-preferences opts out)
    pref_results: list[dict] = []
    if not no_preferences:
        try:
            pref_results = searcher.search_preferences(query=query, caller="prefetch")
        except (Exception, SystemExit):
            pref_results = []

    try:
        results = searcher.search(
            query=query,
            limit=limit,
            source_type=source_type if source_type != "all" else None,
            caller="prefetch",
            scale_set=scale_set,
        )
    except (Exception, SystemExit):
        results = []

    # Dedupe preferences out of the main pool by (file_path, heading)
    if pref_results:
        pref_keys = {pk_retrieval.entry_key(r) for r in pref_results}
        results = [r for r in results if pk_retrieval.entry_key(r) not in pref_keys]

    if not results and not pref_results:
        return 0

    # Filter out results matching excluded backlink paths. When this empties
    # the main pool, rendering is skipped but scope pointers still emit.
    main_pool_emptied = False
    if exclude_backlinks:
        exclude_set = set()
        for entry in exclude_backlinks.split(","):
            entry = entry.strip().strip("[]")
            if entry:
                exclude_set.add(entry)
        if exclude_set:
            filtered = []
            for r in results:
                bl = build_backlink_from_result(r).strip("[]")
                base = bl.split("#")[0]
                if bl not in exclude_set and base not in exclude_set:
                    filtered.append(r)
            results = filtered
        if not results:
            _log_prefetch(knowledge_dir, results, caller=caller, scale_set=scale_set)
            main_pool_emptied = True

    if main_pool_emptied:
        if work_item:
            _emit_scope_pointers(knowledge_dir, work_item, query)
        return 0

    see_also_map = _load_see_also_map(knowledge_dir)
    requested_label = ",".join(sorted({s.strip().lower() for s in scale_set if s.strip()}))

    def _resolve_content(backlink: str) -> str:
        """Return full resolved content for backlink, or '' on failure."""
        try:
            resolved = resolver.resolve_batch([backlink])
            if resolved and resolved[0].get("resolved"):
                return resolved[0]["content"]
        except Exception:
            pass
        return ""

    if fmt == "summary":
        if pref_results:
            print('## Preferences')
            print(f'Scoped working-style guidance matching: "{query}"')
            print()
            for r in pref_results:
                snippet = r.get("snippet", "")[:200]
                if len(r.get("snippet", "")) > 200:
                    snippet += "..."
                print(f'- **{r["heading"]}** ({r["file_path"]}, score: {r.get("score", 0)}): {snippet}')
            print()
        print('## Prior Knowledge')
        print(f'Results from knowledge store for: "{query}" (scale-set: {requested_label})')
        print()
        for r in results:
            snippet = r.get("snippet", "")[:200]
            if len(r.get("snippet", "")) > 200:
                snippet += "..."
            print(f'- **{r["heading"]}** ({r["file_path"]}, score: {r.get("score", 0)}): {snippet}')
        _log_prefetch(knowledge_dir, results, caller=caller, scale_set=scale_set)
        if work_item:
            _emit_scope_pointers(knowledge_dir, work_item, query)
        return 0

    # prompt format — resolve each result to full content
    if pref_results:
        print('## Preferences')
        print(f'Scoped working-style guidance matching: "{query}"')
        for r in pref_results:
            backlink = build_backlink_from_result(r)
            trust_line = render_trust_stamp(r, knowledge_dir)
            content = _resolve_content(backlink) or r.get("snippet", "")
            print(f'\n### {r["heading"]} (from {r["file_path"]})')
            print(trust_line)
            print(content)
        print()

    print('## Prior Knowledge')
    print(f'Results from knowledge store for: "{query}" (scale-set: {requested_label})')

    content_cache: dict[tuple[str, str], str] = {}

    def _entry_content(r):
        key = pk_retrieval.entry_key(r)
        if key not in content_cache:
            content_cache[key] = _resolve_content(build_backlink_from_result(r)) or r.get("snippet", "")
        return content_cache[key]

    def _stale_tag(r):
        if r.get("source_type") != "knowledge":
            return ""
        return _staleness_annotation(knowledge_dir, r["file_path"])

    def _full_block(r):
        is_knowledge = r.get("source_type") == "knowledge"
        abs_fp = os.path.join(knowledge_dir, r.get("file_path", ""))
        sa_entries = see_also_map.get((abs_fp, r["heading"]), [])
        sa_line = ("See also: " + ", ".join(sa_entries[:3])) if sa_entries else ""
        trust_line = render_trust_stamp(r, knowledge_dir)
        corrected_line = _last_corrected_line(knowledge_dir, r["file_path"]) if is_knowledge else ""
        block = f'\n### {r["heading"]} (from {r["file_path"]}){_stale_tag(r)}\n{trust_line}'
        if corrected_line:
            block += f'\n{corrected_line}'
        block += f'\n{_entry_content(r)}'
        if sa_line:
            block += f'\n{sa_line}'
        return block

    def _snippet_block(r):
        snippet = r.get("snippet", "") or _entry_content(r)
        return f'\n### {r["heading"]} (from {r["file_path"]}){_stale_tag(r)}\n{snippet[:SNIPPET_LIMIT]}'

    def _backlink_block(r):
        return f'\n- {pk_retrieval.backlink_for(r["file_path"], r["heading"])}'

    blocks, _ = pk_retrieval.emit_degrading(
        results, PREFETCH_BUDGET, _full_block, _snippet_block, _backlink_block
    )
    for block in blocks:
        print(block)

    _log_prefetch(knowledge_dir, results, caller=caller, scale_set=scale_set)

    if work_item:
        _emit_scope_pointers(knowledge_dir, work_item, query)

    return 0
