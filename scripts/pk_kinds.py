"""pk_kinds: kind-section policy for the retrieval surfaces.

Library for the surfaces that append labeled non-fact sections after their own
ranked output (session start, the search CLI, and the two agent-prompt
injectors). This module owns the section list and its order, the per-section
caps, the kind_status selection rules, the theory one-per-subsystem bound, the
non-fact presence probe, dedupe against entries the caller already served, and
the reserve-then-rollback char arithmetic. It composes existing primitives:
Searcher.search supplies candidates, pk_retrieval.degrade_section renders them.
No surface carries a copy of the policy.

Two lifecycles are in play and this module only reads one of them. Entry status
(current / corrected / expired / retired) stays with Searcher.search's default
status filter, untouched. kind_status (open / answered / untested / supported /
refuted) is selected on here and nowhere else: an entry this module declines to
deliver is still returned by a direct kind-filtered Searcher.search.

Sections are only as good as the slice of the ranking they get to choose from.
Because the kind filter runs after SQL has cut to the top rows, a section asking
for a small multiple of its cap sees a window that same-topic facts can fill
entirely, and then it renders nothing — the starvation the sections exist to
prevent, reappearing one level down. The candidate window is therefore sized
from the row count (see candidate_limit) so that it spans the whole ranked list
on any store up to SEARCH_OVERFETCH * MAX_CANDIDATE_LIMIT rows. Past that size
it is a bounded window again and a dense enough single-topic fact corpus can
still bury a section's candidates.
"""

import os
import sqlite3
import sys
from typing import NamedTuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_search import DEFAULT_KIND, DEGRADED_UNAVAILABLE, SOURCE_TYPES, Searcher  # noqa: E402
from pk_resolve import Resolver, build_backlink_from_result  # noqa: E402
import pk_retrieval  # noqa: E402

SNIPPET_LIMIT = pk_retrieval.SNIPPET_CHAR_LIMIT


class SectionSpec(NamedTuple):
    """One kind's delivery rule: what to ask for and what to keep."""

    kind: str
    title: str
    cap: int
    # None applies no kind_status rule; a set admits only those values.
    admit_kind_status: frozenset | None
    exclude_kind_status: frozenset
    one_per_subsystem: bool


# Order is claim strength: a theory orients everything after it, a hypothesis is
# the weakest claim in the store and comes last. The caps are constants — they
# do not scale with the caller's limit or with the store, which is what keeps
# section cost flat as the store grows.
SECTION_SPECS: tuple[SectionSpec, ...] = (
    SectionSpec("theory", "Theory", 2, None, frozenset(), True),
    SectionSpec("question", "Open questions", 3, frozenset({"open"}), frozenset(), False),
    SectionSpec("hypothesis", "Hypotheses", 3, None, frozenset({"refuted"}), False),
)

# Searcher.search applies the kind filter in Python, over rows SQL has already
# cut to the top of the ranked list, and widens its own limit by this factor to
# do it. A section query therefore only ever sees the top
# (limit * SEARCH_OVERFETCH) of the ranking, and a non-fact entry is reachable
# only when it ranks inside that window.
SEARCH_OVERFETCH = 3

# Ceiling on the per-section candidate limit. Below SEARCH_OVERFETCH times this
# many indexed rows the window spans the entire ranked list, so no entry can be
# crowded out of its section by facts that outrank it; past that size the window
# is a window again and dense same-topic facts can bury a section's candidates.
# Sized against a real store: the `entries` table counts work items and threads
# alongside knowledge (roughly 6900 rows for 1300 knowledge entries), and a
# caller that declares no source_type ranks against all of them. Raising the
# limit past the matching-row count costs nothing measurable — ~70ms per section
# query on a 6000-row index either way — because the cost tracks rows the query
# actually matches, not the limit.
MAX_CANDIDATE_LIMIT = 4000

# Floor for small stores: enough over-fetch to absorb kind_status gating, path
# dedupe, and the theory one-per-subsystem bound before the caps apply.
MIN_CANDIDATE_LIMIT = 10


def _empty_result(reserve_chars: int) -> dict:
    """The shape every short-circuit returns: nothing rendered, nothing spent."""
    return {
        "has_non_fact": False,
        "searches": 0,
        "text": "",
        "sections": [],
        "chars_reserved": max(reserve_chars, 0),
        "chars_used": 0,
        "chars_unspent": max(reserve_chars, 0),
        "degraded": None,
    }


# ---------------------------------------------------------------------------
# Presence probe
# ---------------------------------------------------------------------------

def has_non_fact_entries(searcher: Searcher) -> bool:
    """True when any indexed entry declares a kind other than `fact`.

    One lookup against the index, no BM25 query and no retrieval-log record.
    Callers gate the whole section path on this: on a store where it answers
    False there is nothing any section could deliver, so the surface returns to
    its existing code path having spent exactly this one query.
    """
    if searcher._ensure_index() == DEGRADED_UNAVAILABLE:
        return False
    try:
        conn = sqlite3.connect(searcher.db_path)
        try:
            row = conn.execute(
                "SELECT 1 FROM entries "
                "WHERE kind IS NOT NULL AND trim(lower(kind)) NOT IN ('', ?) "
                "LIMIT 1",
                (DEFAULT_KIND,),
            ).fetchone()
        finally:
            conn.close()
    except sqlite3.Error:
        return False
    return row is not None


def indexed_row_count(searcher: Searcher, source_type: str | None = None) -> int:
    """Rows a query can rank against — the upper bound on what it can match.

    Counts under the same source_type restriction Searcher.search will apply, so
    a caller that asks only for knowledge is sized against knowledge rather than
    against the whole index. The distinction is not academic: work items and
    threads share the `entries` table and outnumber knowledge entries several
    times over, so counting them in when they cannot appear would size the
    window far past what it needs to be, and counting them out when they can
    would size it short.

    Returns 0 when there is no index yet or it cannot be read, which sizes the
    window to its floor rather than failing the section path. Does not create
    the index — connecting to a missing database file would leave an empty one
    behind, and _ensure_index treats any existing file as an index it can serve
    from. build_sections calls this only after the presence probe, which is
    what builds the index.
    """
    if not os.path.exists(searcher.db_path):
        return 0
    try:
        conn = sqlite3.connect(searcher.db_path)
        try:
            if source_type and source_type in SOURCE_TYPES:
                return conn.execute(
                    "SELECT count(*) FROM entries WHERE source_type = ?",
                    (source_type,),
                ).fetchone()[0]
            return conn.execute("SELECT count(*) FROM entries").fetchone()[0]
        finally:
            conn.close()
    except sqlite3.Error:
        return 0


def candidate_limit(row_count: int) -> int:
    """Rows to request per section, sized so the kind filter sees the whole
    ranked list.

    Searcher.search scans `limit * SEARCH_OVERFETCH` rows before filtering by
    kind, so asking for ceil(row_count / SEARCH_OVERFETCH) puts every row a
    query can match inside the window — no non-fact entry can be crowded out by
    facts that outrank it. Above MAX_CANDIDATE_LIMIT the window stops growing
    and that property lapses; see the module docstring.
    """
    spanning = -(-row_count // SEARCH_OVERFETCH)
    return max(MIN_CANDIDATE_LIMIT, min(spanning, MAX_CANDIDATE_LIMIT))


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _entry_label(entry: dict) -> str:
    """Bracketed label carried by every rendered line: the entry's kind_status,
    plus the subsystem a theory names (theory declares no kind_status)."""
    parts = []
    kind_status = (entry.get("kind_status") or "").strip()
    if kind_status:
        parts.append(kind_status)
    if entry.get("kind") == "theory":
        subsystem = entry.get("subsystem")
        if subsystem:
            parts.append(f"subsystem: {subsystem}")
    return f" [{' | '.join(parts)}]" if parts else ""


class _Renderer:
    """The three render modes for one store.

    Search results carry a truncated `snippet` and no full body, so full mode
    resolves the entry through the store's Resolver and caches the result —
    without that step full and snippet render the same text and the middle rung
    of the degradation ladder does nothing.
    """

    def __init__(self, knowledge_dir: str):
        self._content: dict = {}
        try:
            self._resolver = Resolver(knowledge_dir)
        except (Exception, SystemExit):
            self._resolver = None

    def _entry_content(self, entry: dict) -> str:
        key = pk_retrieval.entry_key(entry)
        if key not in self._content:
            resolved = ""
            if self._resolver is not None:
                try:
                    batch = self._resolver.resolve_batch([build_backlink_from_result(entry)])
                    if batch and batch[0].get("resolved"):
                        resolved = batch[0]["content"]
                except Exception:
                    resolved = ""
            self._content[key] = resolved or entry.get("snippet", "")
        return self._content[key]

    def full(self, entry: dict) -> str:
        heading = pk_retrieval.entry_heading(entry)
        path = pk_retrieval.entry_path(entry)
        return f"\n#### {heading}{_entry_label(entry)} (from {path})\n{self._entry_content(entry)}\n"

    def snippet(self, entry: dict) -> str:
        heading = pk_retrieval.entry_heading(entry)
        path = pk_retrieval.entry_path(entry)
        body = (entry.get("snippet") or self._entry_content(entry))[:SNIPPET_LIMIT]
        return f"\n#### {heading}{_entry_label(entry)} (from {path})\n{body}\n"

    def backlink(self, entry: dict) -> str:
        heading = pk_retrieval.entry_heading(entry)
        path = pk_retrieval.entry_path(entry)
        return f"\n- {pk_retrieval.backlink_for(path, heading)}{_entry_label(entry)}\n"


def section_header(spec: SectionSpec) -> str:
    return f"\n### {spec.title}\n"


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

def _kind_status_admits(spec: SectionSpec, entry: dict) -> bool:
    """Apply the section's kind_status rule. Declining an entry here keeps it
    out of the delivered section only — it stays reachable by a kind-filtered
    search, which is why this rule never touches the entry-status filter."""
    kind_status = (entry.get("kind_status") or "").strip().lower()
    if spec.admit_kind_status is not None and kind_status not in spec.admit_kind_status:
        return False
    return kind_status not in spec.exclude_kind_status


def select_candidates(spec: SectionSpec, results: list[dict], exclude: set,
                      seen: set) -> list[dict]:
    """Rank-ordered survivors of the section's rules, capped. `seen` is mutated
    so a later section cannot re-serve an entry an earlier one took."""
    admitted = [r for r in results if _kind_status_admits(spec, r)]
    admitted = pk_retrieval.exclude_by_paths(admitted, exclude)
    admitted = pk_retrieval.dedupe_entries(
        admitted, key_fn=pk_retrieval.entry_path, seen=seen
    )

    chosen: list[dict] = []
    subsystems_taken: set = set()
    for entry in admitted:
        if len(chosen) >= spec.cap:
            break
        if spec.one_per_subsystem:
            subsystem = entry.get("subsystem")
            if subsystem in subsystems_taken:
                continue
            subsystems_taken.add(subsystem)
        chosen.append(entry)
    return chosen


def _render_section(spec: SectionSpec, candidates: list[dict], budget: int,
                    renderer: "_Renderer") -> dict:
    header = section_header(spec)
    degraded = pk_retrieval.degrade_section(
        candidates,
        budget=budget,
        # Floor 0: a section that cannot fit even one backlink in its slice
        # drops out entirely rather than overrunning the caller's reservation.
        floor=0,
        header_chars=len(header),
        render_full=renderer.full,
        render_snippet=renderer.snippet,
        render_backlink=renderer.backlink,
    )
    blocks = degraded["rendered_blocks"]
    if not blocks:
        return {}

    render_mode_counts = {"full": 0, "snippet": 0, "backlink": 0}
    for _, mode, _ in blocks:
        render_mode_counts[mode] += 1
    served_entries = [
        {
            "path": pk_retrieval.entry_path(entry),
            "render_mode": mode,
            "kind": entry.get("kind"),
            "kind_status": entry.get("kind_status"),
            "subsystem": entry.get("subsystem"),
            "entry": entry,
        }
        for entry, mode, _ in blocks
    ]
    rendered = header + "".join(block for _, _, block in blocks)
    return {
        "kind": spec.kind,
        "title": spec.title,
        "rendered": rendered,
        "served_count": len(blocks),
        "chars_used": len(rendered),
        "render_mode_counts": render_mode_counts,
        # Independent by design: content_degraded says entries rendered smaller,
        # shrunk_for_budget says the section lost entries it had selected.
        "content_degraded": degraded["content_degraded"],
        "shrunk_for_budget": degraded["shrunk_for_budget"],
        "entry_count_before_budget": len(candidates),
        "served_paths": [e["path"] for e in served_entries if e["path"]],
        "served_entries": served_entries,
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def build_sections(
    searcher: Searcher,
    query: str,
    reserve_chars: int,
    scale_set: list[str] | None = None,
    served_paths: list[str] | tuple[str, ...] = (),
    caller: str | None = None,
    source_type: str | None = None,
    include_archived: bool = False,
    include_status: tuple[str, ...] | list[str] | None = None,
    and_mode: bool = False,
) -> dict:
    """Render the kind sections for `query` within a `reserve_chars` slice.

    `served_paths` are the entries the caller already delivered; nothing here
    repeats one. `scale_set` and `include_status` pass straight through to
    Searcher.search, so sections inherit the caller's declared scale and the
    default entry-status filter rather than defining their own.

    Returns:
        has_non_fact: the probe's answer.
        searches: Searcher.search calls issued — 0 when the probe said no.
        text: the sections, ready to append after the caller's own output.
              Empty string when no section had anything to say; a section with
              no surviving candidate contributes no header and no blank line.
        sections: one record per rendered section, in delivery order.
        chars_reserved / chars_used / chars_unspent: the reservation, the size
              of `text`, and the remainder the caller takes back.
        degraded: Searcher.degraded after the last section query, so an empty
              `text` from a store with nothing to say stays distinguishable
              from an empty `text` from an index that could not answer.
    """
    reserve = max(int(reserve_chars), 0)
    # The probe runs first so `has_non_fact` in the returned record is always
    # the store's answer, never a side effect of an empty query or reservation.
    if not has_non_fact_entries(searcher):
        return _empty_result(reserve)
    if reserve <= 0 or not query or not query.strip():
        return dict(_empty_result(reserve), has_non_fact=True)

    exclude = pk_retrieval.path_exclusion_set(list(served_paths))
    seen: set = set()
    searches = 0
    degraded: str | None = None
    pending: list[tuple[SectionSpec, list[dict]]] = []

    # Sized once per call, not per section: the window has to span the ranked
    # list, which is a property of the store rather than of any one section's
    # cap. What each section delivers is still bounded by spec.cap below.
    limit = candidate_limit(indexed_row_count(searcher, source_type))

    for spec in SECTION_SPECS:
        results = searcher.search(
            query,
            limit=limit,
            source_type=source_type,
            caller=caller,
            include_archived=include_archived,
            include_status=include_status,
            scale_set=scale_set,
            kind=spec.kind,
            and_mode=and_mode,
        )
        searches += 1
        degraded = searcher.degraded
        candidates = select_candidates(spec, results, exclude, seen)
        if candidates:
            pending.append((spec, candidates))

    sections: list[dict] = []
    remaining = reserve
    renderer = _Renderer(searcher.knowledge_dir)
    for i, (spec, candidates) in enumerate(pending):
        # Each section gets an even share of what is left, so an early section
        # cannot consume the whole reservation; whatever it does not spend rolls
        # into the next one's share, and the last unspent chars go back to the
        # caller untouched.
        share = remaining // (len(pending) - i)
        record = _render_section(spec, candidates, share, renderer)
        if not record:
            continue
        sections.append(record)
        remaining -= record["chars_used"]

    text = "".join(s["rendered"] for s in sections)
    return {
        "has_non_fact": True,
        "searches": searches,
        "text": text,
        "sections": sections,
        "chars_reserved": reserve,
        "chars_used": len(text),
        "chars_unspent": reserve - len(text),
        "degraded": degraded,
    }


def served_paths_from(result: dict) -> list[str]:
    """Every entry path the sections delivered, in delivery order."""
    return [p for section in result["sections"] for p in section["served_paths"]]
