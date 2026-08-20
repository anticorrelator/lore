#!/usr/bin/env python3
"""generate-tasks: Parse plan.md and produce a tasks.json-compatible dict.

Standalone CLI and importable module. Zero external dependencies (stdlib only).

CLI usage:
    python3 generate-tasks.py <plan-md-path> [--knowledge-dir <path>]

Outputs JSON to stdout matching the tasks.json schema. Which unit array is
emitted follows the plan's own grammar, and only one is ever present:

    # plan authored with `### Task N:` headings
    { "plan_checksum": ..., "generated_at": ...,
      "tasks": [{ "id": "task-1", "name": "...", "deliverable": "...",
                  "file_targets": [...], "description": "<inline brief>", ... }] }

    # plan authored with `### Phase N:` headings
    { "plan_checksum": ..., "generated_at": ...,
      "phases": [{ "phase_number": 1, "phase_name": "...", "objective": "...",
                   "files": [...], "tasks": [{ "id": "task-1", ... }] }] }
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RESOLVE_CHAR_LIMIT = 4000

VERB_MAP = {
    "Write": "Writing", "Create": "Creating", "Update": "Updating",
    "Add": "Adding", "Remove": "Removing", "Delete": "Deleting",
    "Fix": "Fixing", "Move": "Moving", "Replace": "Replacing",
    "Test": "Testing", "Run": "Running", "Set": "Setting",
    "Implement": "Implementing", "Extract": "Extracting",
    "Refactor": "Refactoring", "Measure": "Measuring",
    "Capture": "Capturing", "Decide": "Deciding",
    "Configure": "Configuring", "Merge": "Merging",
    "Split": "Splitting", "Verify": "Verifying",
    "Check": "Checking", "Ensure": "Ensuring",
    "Enable": "Enabling", "Disable": "Disabling",
    "Install": "Installing", "Build": "Building",
    "Deploy": "Deploying", "Parse": "Parsing",
    "Generate": "Generating", "Validate": "Validating",
    "Rename": "Renaming", "Consolidate": "Consolidating",
    "Document": "Documenting", "Audit": "Auditing",
}

# Regex for CVC short verbs that double final consonant (Run->Running)
SHORT_CVC_RE = re.compile(r"^[A-Z][a-z]*[^aeiou]$")

# Context cost estimation constants.
# FIXED_OVERHEAD_CHARS: base per-task overhead (CLAUDE.md + MEMORY.md + worker.md +
# advisory mixin — approximately 22 KB for a typical worker session).
FIXED_OVERHEAD_CHARS = 22000

# Verb complexity multiplier: fraction of file read size to reserve for edit space.
# "high" verbs (write/create/refactor) require more output space; "low" verbs (check/verify) less.
VERB_COMPLEXITY: dict[str, float] = {
    # high — substantial rewrites
    "Write": 0.5, "Create": 0.5, "Implement": 0.5, "Refactor": 0.5,
    "Replace": 0.5, "Merge": 0.5, "Split": 0.5, "Generate": 0.5,
    # medium — targeted edits
    "Update": 0.3, "Add": 0.3, "Remove": 0.3, "Delete": 0.3,
    "Fix": 0.3, "Move": 0.3, "Extract": 0.3, "Configure": 0.3,
    "Install": 0.3, "Enable": 0.3, "Disable": 0.3, "Rename": 0.3,
    "Consolidate": 0.3, "Parse": 0.3, "Validate": 0.3, "Build": 0.3,
    "Deploy": 0.3, "Document": 0.3,
    # low — read-mostly or investigative
    "Test": 0.1, "Run": 0.1, "Set": 0.1, "Measure": 0.1,
    "Capture": 0.1, "Decide": 0.1, "Verify": 0.1, "Check": 0.1,
    "Ensure": 0.1, "Audit": 0.1,
}
_DEFAULT_VERB_MULTIPLIER = 1.0
_ADVISORY_OVERHEAD_CHARS = 500  # extra chars allocated when has_advisory=True


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def to_active_form(subject: str) -> str:
    """Convert an imperative subject to present-continuous activeForm."""
    words = subject.split()
    if not words:
        return subject
    verb = words[0]
    rest = " ".join(words[1:])

    if verb in VERB_MAP:
        ing = VERB_MAP[verb]
    elif verb.lower().endswith("e") and not verb.lower().endswith("ee"):
        ing = verb[:-1] + "ing"
    elif SHORT_CVC_RE.match(verb) and len(verb) <= 4:
        ing = verb + verb[-1] + "ing"
    elif verb.lower().endswith("ing"):
        ing = verb
    else:
        ing = verb + "ing"

    return (ing + " " + rest).strip()


def parse_design_decisions(plan_content: str) -> list[dict]:
    """Parse structured design decisions from the ## Design Decisions section.

    Returns list of dicts with keys:
        id: e.g. "D1"
        title: decision title
        decision: the decision text
        rationale: the rationale text
        applies_to: raw Applies-to text
        phase_numbers: list of int phase numbers (empty list means all phases)
    """
    # Find the ## Design Decisions section
    section_re = re.compile(r"^## Design Decisions\s*$", re.MULTILINE)
    section_match = section_re.search(plan_content)
    if not section_match:
        return []

    start = section_match.end()
    # Find next ## heading or end of content
    next_h2 = re.search(r"^## ", plan_content[start:], re.MULTILINE)
    end = start + next_h2.start() if next_h2 else len(plan_content)
    section_text = plan_content[start:end]

    # Parse individual ### DN: Title blocks
    decision_re = re.compile(r"^### (D\d+):\s*(.*)", re.MULTILINE)
    decision_matches = list(decision_re.finditer(section_text))
    if not decision_matches:
        return []

    decisions = []
    for i, dm in enumerate(decision_matches):
        d_id = dm.group(1)
        d_title = dm.group(2).strip()

        # Get decision block content
        block_start = dm.end()
        if i + 1 < len(decision_matches):
            block_end = decision_matches[i + 1].start()
        else:
            block_end = len(section_text)
        block = section_text[block_start:block_end]

        # Extract fields — use ^ with MULTILINE to match field markers at
        # line start only, avoiding false matches within backtick content
        decision_match = re.search(
            r"^\*\*Decision:\*\*\s*(.*?)(?=\n\*\*[A-Z]|\Z)",
            block, re.DOTALL | re.MULTILINE,
        )
        rationale_match = re.search(
            r"^\*\*Rationale:\*\*\s*(.*?)(?=\n\*\*[A-Z]|\Z)",
            block, re.DOTALL | re.MULTILINE,
        )
        applies_match = re.search(
            r"^\*\*Applies to:\*\*\s*(.*?)(?=\n\*\*[A-Z]|\n###|\Z)",
            block, re.DOTALL | re.MULTILINE,
        )

        decision_text = decision_match.group(1).strip() if decision_match else ""
        rationale_text = rationale_match.group(1).strip() if rationale_match else ""
        applies_text = applies_match.group(1).strip() if applies_match else ""

        # Parse phase numbers from Applies-to
        phase_numbers = _parse_applies_to(applies_text)

        decisions.append({
            "id": d_id,
            "title": d_title,
            "decision": decision_text,
            "rationale": rationale_text,
            "applies_to": applies_text,
            "phase_numbers": phase_numbers,
        })

    return decisions


def _parse_applies_to(applies_text: str) -> list[int]:
    """Parse phase numbers from an Applies-to field.

    Handles:
        "Phase 1 (name)" -> [1]
        "Phase 1 (name), Phase 3 (name)" -> [1, 3]
        "All phases (reason)" -> [] (empty = all phases)
    """
    if not applies_text:
        return []
    if re.match(r"(?i)\ball\b", applies_text):
        return []  # empty list signals "all phases"
    return [int(m.group(1)) for m in re.finditer(r"Phase\s+(\d+)", applies_text)]


def decisions_for_phase(
    decisions: list[dict], phase_num: int
) -> list[dict]:
    """Filter design decisions relevant to a given phase number.

    Decisions with empty phase_numbers apply to all phases.
    """
    return [
        d for d in decisions
        if not d["phase_numbers"] or phase_num in d["phase_numbers"]
    ]


def extract_backlinks(plan_content: str, section_name: str) -> list[str]:
    """Extract [[...]] backlink targets from a named ## section."""
    pattern = re.compile(
        rf"^##\s+{re.escape(section_name)}\s*$", re.MULTILINE
    )
    match = pattern.search(plan_content)
    if not match:
        return []

    start = match.end()
    # Find next ## heading or end of content
    next_h2 = re.search(r"^## ", plan_content[start:], re.MULTILINE)
    end = start + next_h2.start() if next_h2 else len(plan_content)
    section_text = plan_content[start:end]

    backlinks = []
    for bl_match in re.finditer(r"\[\[([^\]]+)\]\]", section_text):
        target = bl_match.group(1).strip()
        if target and target not in backlinks:
            backlinks.append(target)
    return backlinks


def extract_strategy(plan_content: str) -> str:
    """Extract the ## Strategy section content from plan_content.

    Returns the trimmed text between ## Strategy and the next ## heading,
    or an empty string if the section is absent, empty, or contains only
    HTML comments (e.g., template placeholder text).
    """
    pattern = re.compile(r"^##\s+Strategy\s*$", re.MULTILINE)
    match = pattern.search(plan_content)
    if not match:
        return ""

    start = match.end()
    next_h2 = re.search(r"^## ", plan_content[start:], re.MULTILINE)
    end = start + next_h2.start() if next_h2 else len(plan_content)
    section_text = plan_content[start:end]

    # Strip HTML comments (template placeholders) before checking content
    section_text = re.sub(r"<!--.*?-->", "", section_text, flags=re.DOTALL).strip()
    return section_text


def resolve_backlinks(
    backlinks: list[str], knowledge_dir: str, script_dir: str
) -> list[dict]:
    """Resolve backlinks via pk_search.py resolve. Returns list of result dicts."""
    if not backlinks or not knowledge_dir:
        return []
    pk_search = os.path.join(script_dir, "pk_search.py")
    if not os.path.isfile(pk_search):
        return []

    formatted = [
        f"[[{bl}]]" if not bl.startswith("[[") else bl for bl in backlinks
    ]
    try:
        result = subprocess.run(
            [sys.executable, pk_search, "resolve", knowledge_dir]
            + formatted
            + ["--json"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            results = json.loads(result.stdout)
            for r in results:
                if not r.get("resolved", True):
                    print(
                        f"Warning: unresolved backlink: {r['backlink']}"
                        f" — {r.get('error', 'unknown')}",
                        file=sys.stderr,
                    )
            return results
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return []


def extract_task_backlinks(item_text: str) -> list[str]:
    """Extract [[...]] backlink targets from an individual task item line."""
    backlinks: list[str] = []
    for bl_match in re.finditer(r"\[\[([^\]]+)\]\]", item_text):
        target = bl_match.group(1).strip()
        if target and target not in backlinks:
            backlinks.append(target)
    return backlinks


_WOVEN_NORM_RE = re.compile(
    r"\bhonor\s+`?([A-Za-z0-9][A-Za-z0-9._-]*)`?"
)


def extract_woven_norms(item_text: str) -> list[str]:
    """Return honor-clause labels backed by same-line knowledge backlinks."""
    backlink_slugs: set[str] = set()
    for target in extract_task_backlinks(item_text):
        if not target.startswith("knowledge:"):
            continue
        path = target.removeprefix("knowledge:").split("#", 1)[0].rstrip("/")
        slug = path.rsplit("/", 1)[-1]
        if slug.endswith(".md"):
            slug = slug[:-3]
        if slug:
            backlink_slugs.add(slug)

    woven: list[str] = []
    for match in _WOVEN_NORM_RE.finditer(item_text):
        label = match.group(1)
        if label in backlink_slugs and label not in woven:
            woven.append(label)
    return woven


# Closed judgment-class vocabulary. A spec author writes a trailing
# [class: <value>] marker on each task line; /implement routes each value to a
# worker-tier binding. The three values are a closed set — anything else is not
# a marker and yields no class.
_JUDGMENT_CLASS_RE = re.compile(
    r"\[class:\s*(mechanical|standard|judgment-dense)\s*\]"
)


def extract_judgment_class(item_text: str) -> "str | None":
    """Extract the trailing [class: <value>] marker from a task line.

    Returns ``mechanical`` | ``standard`` | ``judgment-dense``, or ``None`` when
    the line carries no marker. The marker is left in place in the task subject —
    this extraction is additive and never rewrites the subject. An absent marker
    (``None``) routes the task as plain ``worker`` downstream.
    """
    match = _JUDGMENT_CLASS_RE.search(item_text)
    return match.group(1) if match else None


# Closed route vocabulary. A spec author may append a trailing [route: session]
# marker to a task line to request the task be dispatched as a PTY-hosted worker
# session rather than an in-harness Task-tool worker. ``session`` is the only
# recognized value; anything else is not a marker and yields no route. Unlike
# [class: …], the route marker is a pure dispatch signal — it is stripped from
# the rendered task description and its value travels only in the task's
# ``route`` field.
_ROUTE_RE = re.compile(r"\[route:\s*(session)\s*\]")
# Same marker plus any leading whitespace, so stripping it from rendered text
# leaves no orphaned space.
_ROUTE_STRIP_RE = re.compile(r"\s*" + _ROUTE_RE.pattern)

# Coordination annotations are additive task projections. The subject remains
# byte-identical to the plan checklist line so checkbox reconciliation keeps its
# existing identity; consumers read the structured fields instead of reparsing
# prose. Explicit dependencies compose with collision-derived blockedBy edges.
_DEPENDS_ON_RE = re.compile(r"\[depends-on:\s*([^\]]*)\]", re.IGNORECASE)
_TREE_RE = re.compile(r"\[tree:\s*(writer|read-only)\s*\]", re.IGNORECASE)
# The run of `[[backlink]]` and `[marker: value]` brackets that closes a
# checklist line. Everything before it is prose.
_TRAILING_MARKERS_RE = re.compile(
    r"(?:\s*(?:\[\[[^\]]*\]\]|\[[^\]\[]*\]))+\s*$"
)


def extract_route(item_text: str) -> "str | None":
    """Extract the trailing [route: <value>] marker from a task line.

    Returns ``session``, or ``None`` when the line carries no marker. Mirrors
    ``extract_judgment_class``'s trailing-marker pattern and placement. An
    absent marker (``None``) leaves the task on the default in-harness route,
    and the ``route`` field is omitted rather than emitted null.
    """
    match = _ROUTE_RE.search(item_text)
    return match.group(1) if match else None


def strip_route_marker(text: str) -> str:
    """Remove the [route: session] marker (with any leading space) from text.

    Applied when rendering a task's description so the dispatch marker does not
    surface as task content; the parsed value lives in the task's ``route``
    field instead.
    """
    return _ROUTE_STRIP_RE.sub("", text).strip()


def extract_explicit_dependencies(
    item_text: str, trailing_only: bool = False
) -> list[str]:
    """Extract ordered task ids from an optional [depends-on: ...] marker.

    With ``trailing_only``, only the run of bracketed markers and backlinks that
    closes the line is searched, so a ``[depends-on: …]`` written inside the
    prose of a checklist line cannot shadow the authored edge.
    """
    haystack = item_text
    if trailing_only:
        suffix = _TRAILING_MARKERS_RE.search(item_text)
        haystack = suffix.group(0) if suffix else ""
    match = _DEPENDS_ON_RE.search(haystack)
    if not match:
        return []
    values: list[str] = []
    for raw in match.group(1).split(","):
        value = raw.strip()
        if not value:
            continue
        if not re.fullmatch(r"task-[1-9][0-9]*", value):
            raise ValueError(f"invalid dependency id {value!r}; expected task-N")
        if value not in values:
            values.append(value)
    return values


def extract_tree(item_text: str) -> str:
    """Return the declared coordination tree class, defaulting conservatively."""
    match = _TREE_RE.search(item_text)
    return match.group(1).lower() if match else "writer"


def _is_file_path(candidate: str) -> bool:
    """Return True if a backtick-quoted string looks like a real file path."""
    # Must contain '/' or '.' to look like a path
    if "/" not in candidate and "." not in candidate:
        return False
    # Exclude backlinks inside backticks: [[knowledge:...]]
    if candidate.startswith("[["):
        return False
    # Exclude bash variables: $WORK_DIR, $KNOWLEDGE_DIR
    if candidate.startswith("$"):
        return False
    # Exclude bracketed expressions: phases[], tasks[], build_context_section()
    if "[]" in candidate or "()" in candidate:
        return False
    # Exclude bare skill/command names with leading slash but no extension
    # e.g. /implement, /spec, /work — these have a single slash and no '.'
    if re.match(r"^/[a-z-]+$", candidate):
        return False
    return True


def backtick_file_paths(text: str) -> list[str]:
    """Return backtick-quoted paths in ``text``, deduplicated in first-seen order."""
    targets: list[str] = []
    seen: set[str] = set()
    for m in re.finditer(r"`([^`]+)`", text):
        candidate = m.group(1).strip()
        if _is_file_path(candidate) and candidate not in seen:
            targets.append(candidate)
            seen.add(candidate)
    return targets


def extract_file_targets(task_text: str, phase_files: list[str]) -> list[str]:
    """Extract file targets from a task's text, falling back to phase files.

    Looks for backtick-quoted paths (containing '/' or '.') in the task text.
    If none found, returns the phase-level files list as fallback.
    Returns deduplicated list preserving first-occurrence order.
    """
    targets = backtick_file_paths(task_text)
    if targets:
        return targets
    # Fallback: use phase-level files
    return list(phase_files)


def detect_reference_files(
    phase_files: list[str], task_targets: list[str]
) -> list[str]:
    """Detect phase files that this task does not target.

    These are "reference files" — phase-level files that the task should
    read for context but is not expected to modify.

    Args:
        phase_files: The phase-level ``**Files:**`` list.
        task_targets: This task's ``file_targets``.

    Returns:
        Phase files not in this task's targets, preserving original order.
        Empty list when every phase file is also a target of this task.
    """
    targeted = set(task_targets)
    return [f for f in phase_files if f not in targeted]


def _unpack_backlink(item: "str | tuple[str, str]") -> tuple[str, str]:
    """Normalize a backlink item to (target, annotation).

    Accepts either a plain string ``"knowledge:foo"`` or a tuple
    ``("knowledge:foo", "why this matters")``.  Returns ``(target, "")``
    for plain strings.
    """
    if isinstance(item, tuple):
        return (item[0], item[1] if len(item) > 1 else "")
    return (item, "")


def _format_backlink_line(item: "str | tuple[str, str]") -> str:
    """Format a backlink item as a markdown list entry.

    With annotation:  ``- [[knowledge:foo]] — why this matters``
    Without:          ``- [[knowledge:foo]]``
    """
    target, annotation = _unpack_backlink(item)
    if annotation:
        return f"- [[{target}]] — {annotation}"
    return f"- [[{target}]]"


def estimate_context_cost(
    description: str,
    file_targets: list[str],
    subject: str,
    has_advisory: bool = False,
) -> dict:
    """Estimate the context window cost (in chars) for a single task.

    Returns a dict with:
        fixed_overhead_chars  — base per-task overhead (system framing, etc.)
        description_chars     — len(description)
        file_read_chars       — sum of os.path.getsize() for each file_target;
                                missing files contribute 0
        edit_space_chars      — file_read_chars * verb_multiplier, where the
                                multiplier is derived from the first word of
                                subject via VERB_COMPLEXITY
        advisory_chars        — extra overhead when has_advisory=True
        total_chars           — sum of all components above
    """
    fixed = FIXED_OVERHEAD_CHARS
    description_chars = len(description)

    file_read_chars = 0
    for path in file_targets:
        try:
            file_read_chars += os.path.getsize(path)
        except OSError:
            pass  # missing or inaccessible file → 0

    # Derive verb multiplier from subject's first word
    first_word = subject.split()[0] if subject.split() else ""
    multiplier = VERB_COMPLEXITY.get(first_word, _DEFAULT_VERB_MULTIPLIER)
    edit_space_chars = int(file_read_chars * multiplier)

    advisory_chars = _ADVISORY_OVERHEAD_CHARS if has_advisory else 0

    total_chars = fixed + description_chars + file_read_chars + edit_space_chars + advisory_chars

    return {
        "fixed_overhead_chars": fixed,
        "description_chars": description_chars,
        "file_read_chars": file_read_chars,
        "edit_space_chars": edit_space_chars,
        "advisory_chars": advisory_chars,
        "total_chars": total_chars,
    }


def build_context_section(
    phase_backlinks: list,
    cross_cutting_backlinks: list,
    knowledge_dir: str,
    script_dir: str,
    task_backlinks: list | None = None,
    reference_files: list[str] | None = None,
    design_decisions: list[dict] | None = None,
    resolve_full_content: bool = False,
    strategy: str | None = None,
) -> str:
    """Build the context section for a task description or phase brief.

    Backlink lists accept either plain strings (``"knowledge:foo"``) or
    tuples (``("knowledge:foo", "annotation text")``).  Annotations are
    rendered inline: ``- [[target]] — annotation``.

    Task-level backlinks (from the individual checklist item) are resolved
    first and given priority within the char budget. Phase-level and
    cross-cutting backlinks fill remaining budget.

    When strategy is non-empty, a **Strategy:** block is prepended before
    the ## Design Decisions block.

    When design_decisions is non-empty, a ## Design Decisions block is
    rendered before the ## Context heading, showing Decision + Rationale
    for each relevant decision.

    When reference_files is non-empty, a **Reference files:** block is
    prepended before the ## Context heading.
    """
    lines = []

    if strategy:
        lines.append("**Strategy:**")
        lines.append(strategy)
        lines.append("")

    if design_decisions:
        lines.append("## Design Decisions")
        lines.append("")
        for d in design_decisions:
            lines.append(f"### {d['id']}: {d['title']}")
            if d.get("decision"):
                lines.append(f"**Decision:** {d['decision']}")
            if d.get("rationale"):
                lines.append(f"**Rationale:** {d['rationale']}")
            lines.append("")
        lines.append("")

    if reference_files:
        lines.append("**Reference files:**")
        for rf in sorted(reference_files):
            lines.append(f"- `{rf}` — read this first for patterns and conventions")
        lines.append("")

    lines.extend([
        "## Context (resolve before starting)",
        'Resolve these with: lore resolve "<backlink>"',
        "",
    ])

    # Build per-tier filtered display lists: lower-priority tiers exclude targets
    # already shown in a higher-priority tier. Original lists are kept intact for
    # the all_backlinks resolution path below.
    seen_display: set[str] = set()
    display_task: list = []
    for bl in (task_backlinks or []):
        target, _ = _unpack_backlink(bl)
        if target not in seen_display:
            display_task.append(bl)
            seen_display.add(target)

    display_phase: list = []
    for bl in phase_backlinks:
        target, _ = _unpack_backlink(bl)
        if target not in seen_display:
            display_phase.append(bl)
            seen_display.add(target)

    display_cross: list = []
    for bl in cross_cutting_backlinks:
        target, _ = _unpack_backlink(bl)
        if target not in seen_display:
            display_cross.append(bl)
            seen_display.add(target)

    if display_task:
        lines.append("Task-level:")
        for bl in display_task:
            lines.append(_format_backlink_line(bl))
        lines.append("")

    if display_phase:
        lines.append("Phase-level:")
        for bl in display_phase:
            lines.append(_format_backlink_line(bl))
        lines.append("")

    if display_cross:
        lines.append("Cross-cutting:")
        for bl in display_cross:
            lines.append(_format_backlink_line(bl))
        lines.append("")

    has_any = task_backlinks or phase_backlinks or cross_cutting_backlinks
    if not has_any:
        lines.append("No backlinks found in plan.")
        lines.append("")

    # Build prioritized resolution order: task-level first, then phase, then cross-cutting
    # Deduplicate while preserving priority order (annotations not needed for resolution)
    all_backlinks: list[str] = []
    seen: set[str] = set()
    for bl_list in (task_backlinks or [], phase_backlinks, cross_cutting_backlinks):
        for bl in bl_list:
            target, _ = _unpack_backlink(bl)
            if target not in seen:
                all_backlinks.append(target)
                seen.add(target)

    if all_backlinks and resolve_full_content and knowledge_dir:
        resolved = resolve_backlinks(all_backlinks, knowledge_dir, script_dir)
        if resolved:
            lines.append("## Prior Knowledge")
            lines.append("")
            total_chars = 0
            included = 0
            for r in resolved:
                bl_label = r.get("backlink", "")
                if r.get("resolved"):
                    content = r.get("content", "")
                    entry = f"**{bl_label}:**\n{content}"
                    if total_chars + len(entry) > RESOLVE_CHAR_LIMIT:
                        remaining = len(resolved) - included
                        lines.append(
                            f"[... truncated, {remaining} more entries]"
                        )
                        lines.append("")
                        break
                    lines.append(entry)
                    lines.append("")
                    total_chars += len(entry)
                else:
                    error = r.get("error", "not found in knowledge store")
                    lines.append(f"**{bl_label}:** [unresolved — {error}]")
                    lines.append("")
                included += 1
    elif all_backlinks and not resolve_full_content:
        # Annotation-only mode: emit backlink labels with annotations, no resolution
        # Build annotation lookup from all backlink lists
        annotation_map: dict[str, str] = {}
        for bl_list in (task_backlinks or [], phase_backlinks, cross_cutting_backlinks):
            for bl in bl_list:
                target, annotation = _unpack_backlink(bl)
                if target not in annotation_map and annotation:
                    annotation_map[target] = annotation

        lines.append("## Prior Knowledge")
        lines.append("")
        for target in all_backlinks:
            annotation = annotation_map.get(target, "")
            if annotation:
                lines.append(f"- **[[{target}]]** — {annotation}")
            else:
                lines.append(f"- **[[{target}]]**")
        lines.append("")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Advisor + consultation parsing
#
# Both plan grammars declare these blocks on the unit that owns the brief — the
# phase in a phase-shaped plan, the task in a flat one — so these parsers take
# whichever block is declaring.
# ---------------------------------------------------------------------------

def _has_persistent_advisor(block: str) -> bool:
    """Return True if the block declares at least one ``mode: persistent`` advisor.

    Only advisors tagged
    ``mode: persistent`` opt into the advisor-agent pipeline that
    concatenates ``advisory-consultation.md`` onto worker prompts.
    Legacy advisor declarations (``[must-consult]``, ``[on-demand]``)
    without a ``mode: persistent`` suffix route through the lead inline
    and add no advisory-mixin overhead to per-task cost estimates.

    Scans the ``**Advisors:**`` block (if present) for any line carrying
    a ``mode: persistent`` token. The token may appear inline on the same
    line as the advisor name, or as a continuation bullet under the advisor
    entry.
    """
    adv_match = re.search(
        r"^\*\*Advisors:\*\*\s*\n((?:(?!^\*\*|\n##).*\n?)*)",
        block,
        re.MULTILINE,
    )
    if not adv_match:
        return False
    block = adv_match.group(1)
    return bool(re.search(r"\bmode\s*:\s*persistent\b", block))


def _parse_consultations_required(block: str) -> list[str]:
    """Parse a unit's ``**Consultations required:**`` domain labels.

    The block format mirrors ``**Files:**`` — a ``-`` bulleted list of
    domain labels a worker MUST consult before starting implementation.
    Each bullet contributes one label; trailing annotation after ``—`` is
    preserved as part of the rendered brief but the parsed list contains only
    the label text up to the optional dash.

    Returns an empty list when the unit declares no
    ``**Consultations required:**`` block. Template placeholder bullets
    (e.g. ``<domain-label>``) are skipped.
    """
    cr_match = re.search(
        r"^\*\*Consultations required:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
        block,
        re.MULTILINE,
    )
    if not cr_match:
        return []
    domains: list[str] = []
    for line in cr_match.group(1).splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            continue
        if stripped.startswith("- [ ]") or stripped.startswith("- [x]"):
            continue
        text = stripped[2:].strip()
        # Skip template placeholder bullets like "<domain-label>"
        if text.startswith("<") and text.endswith(">"):
            continue
        if not text:
            continue
        domains.append(text)
    return domains


def _parse_knowledge_context(block: str) -> list[tuple[str, str]]:
    """Parse a ``**Knowledge context:**`` block into (backlink, annotation) pairs."""
    kc_match = re.search(
        r"\*\*Knowledge context:\*\*\s*\n((?:- .*\n?)*)", block
    )
    if not kc_match:
        return []
    backlinks: list[tuple[str, str]] = []
    seen_targets: set[str] = set()
    for line in kc_match.group(1).splitlines():
        bl_match = re.search(r"\[\[([^\]]+)\]\]", line)
        if not bl_match:
            continue
        target = bl_match.group(1).strip()
        if target in seen_targets:
            continue
        seen_targets.add(target)
        # Annotation text after the backlink: " — <annotation>"
        annotation = ""
        ann_match = re.match(r"\s*—\s*(.*)", line[bl_match.end():])
        if ann_match:
            annotation = ann_match.group(1).strip()
        backlinks.append((target, annotation))
    return backlinks


def _parse_retrieval_directive(block: str, unit_label: str) -> "dict | None":
    """Parse a ``**Retrieval directive:**`` block. Two shapes are recognized:

    (legacy/flat) bullets:  "- seeds: ...", "- scale_set: ...", ...
    (v2 grouped)  bullets:  "- version: 2" plus a "- topics:" tree of
                            role/topic/seeds/scale_set/limit/activity_vocab/query.

    ``unit_label`` names the declaring unit in v2 validation errors.
    """
    match = re.search(
        r"^\*\*Retrieval directive:\*\*\s*\n((?:(?!^\*\*|\n##).*\n?)*)",
        block, re.MULTILINE,
    )
    if not match:
        return None
    body = match.group(1)
    if _is_v2_directive(body):
        return _parse_v2_directive(body, unit_label)
    return _parse_legacy_directive(body)


def _parse_files_declaration(block: str) -> list[str]:
    """Parse a task's ``**Files:**`` block into its declared owned surface.

    Accepts the inline comma-separated form, a following ``- `` bullet list, or
    both. Entries carrying whitespace are template prose rather than paths and
    are dropped, so an unfilled placeholder yields no surface (and a refusal)
    instead of a bogus target.
    """
    match = re.search(r"^\*\*Files:\*\*[ \t]*(.*)$", block, re.MULTILINE)
    if not match:
        return []
    entries: list[str] = []
    seen: set[str] = set()

    def add(raw: str) -> None:
        value = raw.strip().strip("`").strip()
        if not value or " " in value or "\t" in value:
            return
        if value.startswith("<") and value.endswith(">"):
            return
        if value in seen:
            return
        entries.append(value)
        seen.add(value)

    for raw in match.group(1).split(","):
        add(raw)
    rest = block[match.end():]
    if rest.startswith("\n"):
        rest = rest[1:]
    for line in rest.splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            break
        if stripped.startswith("- [ ]") or stripped.startswith("- [x]"):
            break
        add(stripped[2:])
    return entries


def _bullet_lines(block: str, label: str) -> list[str]:
    """Return the plain ``- `` bullet lines of a ``**<label>:**`` block.

    Checkbox bullets are excluded so a checklist line that follows the block
    never reads as one of its entries.
    """
    match = re.search(
        rf"^\*\*{re.escape(label)}:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
        block, re.MULTILINE,
    )
    if not match:
        return []
    out: list[str] = []
    for line in match.group(1).splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            continue
        if stripped.startswith("- [ ]") or stripped.startswith("- [x]"):
            continue
        out.append(stripped)
    return out


def _parse_scope_lines(block: str) -> list[str]:
    """Parse a ``**Scope:**`` block, dropping the template's placeholder bullets."""
    scope_lines: list[str] = []
    for stripped in _bullet_lines(block, "Scope"):
        text = stripped[2:].strip()
        if not text.startswith("Do not modify:") and not text.startswith("Output contract:"):
            scope_lines.append(stripped)
        elif "path/to/file" not in text and "<what" not in text:
            scope_lines.append(stripped)
    return scope_lines


def _parse_verification_lines(block: str) -> list[str]:
    """Parse a ``**Verification:**`` block, dropping angle-bracket placeholders."""
    verif_lines: list[str] = []
    for stripped in _bullet_lines(block, "Verification"):
        text = stripped[2:].strip()
        if not (text.startswith("<") and text.endswith(">")):
            verif_lines.append(stripped)
    return verif_lines


# ---------------------------------------------------------------------------
# Phase context builder
# ---------------------------------------------------------------------------

def _build_phase_context(
    phase_num: int,
    objective: str,
    files: list[str],
    phase_backlinks: list,
    cross_cutting_backlinks: list,
    phase_decisions: list[dict],
    verif_lines: list[str],
    resolve_full_content: bool,
    strategy: str | None,
    knowledge_dir: str,
    script_dir: str,
    annotation_warning: bool = False,
    consultations_required: list[str] | None = None,
) -> str:
    """Render the phase-level brief for `phases[N].phase_context`.

    Contains all phase-shared content that is lifted out of per-task descriptions:
    Strategy, Design Decisions, Verification, Reference files (full phase **Files:** list),
    phase Knowledge context backlinks, the resolved ## Prior Knowledge block, and
    (when present) the phase's ``**Consultations required:**`` domain list.

    Returns an empty string if the phase has no shareable context.
    """
    parts: list[str] = []

    if objective:
        parts.append(f"**Phase {phase_num} objective:** {objective}")
        parts.append("")

    if files:
        parts.append("**Files:**")
        for f in files:
            parts.append(f"- `{f}`")
        parts.append("")

    if consultations_required:
        parts.append("**Consultations required:**")
        for domain in consultations_required:
            parts.append(f"- {domain}")
        parts.append("")

    if verif_lines:
        parts.append("**Verification:**")
        parts.extend(verif_lines)
        parts.append("")

    if annotation_warning:
        parts.append(
            "> **Note:** This phase uses intent+constraints task format with annotation-only "
            "knowledge delivery. Workers interpret design patterns from knowledge context — "
            "consider using `**Knowledge delivery:** full` so workers receive resolved content, "
            "not just backlink labels."
        )
        parts.append("")

    # Build the context section (Strategy + Design Decisions + backlinks + Prior Knowledge)
    # for phase-level use: no task_backlinks, no per-task reference files.
    context = build_context_section(
        phase_backlinks=phase_backlinks,
        cross_cutting_backlinks=cross_cutting_backlinks,
        knowledge_dir=knowledge_dir,
        script_dir=script_dir,
        task_backlinks=None,
        reference_files=None,
        design_decisions=phase_decisions,
        resolve_full_content=resolve_full_content,
        strategy=strategy,
    )
    if context.strip():
        parts.append(context)

    return "\n".join(parts).strip()


# ---------------------------------------------------------------------------
# DAG width: compute_recommended_workers
# ---------------------------------------------------------------------------

def compute_recommended_workers(all_tasks: list[dict]) -> int:
    """Compute recommended worker count from the task dependency DAG.

    Takes a flat list of task dicts (each with ``id`` and ``blockedBy``),
    assigns topological levels via BFS from roots (tasks with no blockers),
    and returns the maximum number of tasks at any single level.

    This equals the maximum number of workers that can be usefully active
    simultaneously. Fully-sequential plans (width=1) and fully-parallel
    plans (width=N) are handled correctly.

    Args:
        all_tasks: Flat list of task dicts with ``id`` and ``blockedBy`` keys.

    Returns:
        Maximum level width (>= 1), or 0 if all_tasks is empty.
    """
    if not all_tasks:
        return 0

    # Build id -> task lookup and in-degree count
    task_by_id: dict[str, dict] = {t["id"]: t for t in all_tasks}
    level: dict[str, int] = {}

    # Memoized recursive level assignment
    def get_level(task_id: str, visiting: set[str]) -> int:
        if task_id in level:
            return level[task_id]
        task = task_by_id.get(task_id)
        if task is None:
            return 0
        blocked_by = task.get("blockedBy", [])
        if not blocked_by:
            level[task_id] = 0
            return 0
        # Guard against cycles (treat cycle members as level 0)
        if task_id in visiting:
            return 0
        visiting = visiting | {task_id}
        max_pred_level = max(get_level(pred, visiting) for pred in blocked_by)
        level[task_id] = max_pred_level + 1
        return level[task_id]

    for t in all_tasks:
        get_level(t["id"], set())

    # Count tasks per level and return max
    level_counts: dict[int, int] = {}
    for lvl in level.values():
        level_counts[lvl] = level_counts.get(lvl, 0) + 1

    return max(level_counts.values()) if level_counts else 0


# ---------------------------------------------------------------------------
# Core: generate_tasks_from_plan
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Retrieval directive parsing (legacy flat + v2 grouped)
# ---------------------------------------------------------------------------

_V2_VERSION_RE = re.compile(r"^\s*(?:-\s*)?version\s*:\s*2\s*$", re.MULTILINE)


def _is_v2_directive(block: str) -> bool:
    """Return True if the directive block declares ``version: 2``.

    Matches both the bullet form (``- version: 2``) and the plain-key form
    (``version: 2``) that fenced YAML blocks use, including when nested under
    a ``retrieval_directive:`` top key.
    """
    return bool(_V2_VERSION_RE.search(block))


def _split_csv_list(val) -> list[str]:
    """Parse a value as either YAML inline list ``[a, b, c]``, ``a, b, c``, or ``a``.

    Also accepts an actual list (from a real-YAML parse of a fenced block),
    returning its items stringified. For string input, strips a *single* outer
    ``[...]`` pair only when the contents don't themselves begin with another
    ``[`` — this preserves lists of ``[[knowledge:...]]`` backlinks.
    """
    if isinstance(val, list):
        return [str(tok).strip() for tok in val if str(tok).strip()]
    s = str(val).strip()
    if s.startswith("[") and s.endswith("]") and not s.startswith("[["):
        s = s[1:-1]
    return [tok.strip().strip('"').strip("'") for tok in s.split(",") if tok.strip()]


def _parse_legacy_directive(block: str) -> dict:
    """Parse a flat ``key: value`` bullet directive."""
    seeds: list[str] = []
    scale_set: list[str] = []
    hop_budget: int = 1
    filters: dict = {}
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            continue
        text = stripped[2:].strip()
        if ":" not in text:
            continue
        raw_key, _, raw_val = text.partition(":")
        key = raw_key.strip().lower().replace("-", "_")
        val = raw_val.strip()
        if key == "seeds":
            seeds = _split_csv_list(val)
        elif key == "scale_set":
            scale_set = _split_csv_list(val)
        elif key == "hop_budget":
            try:
                hop_budget = int(val)
            except ValueError:
                hop_budget = 1
        elif key == "type":
            filters["type"] = val
        elif key == "exclude_category":
            filters["exclude_category"] = val
    return {
        "seeds": seeds,
        "scale_set": scale_set,
        "hop_budget": hop_budget,
        "filters": filters,
    }


def _parse_v2_directive_yaml(body: str, unit_label: str) -> dict | None:
    """Parse a fenced directive body with a real YAML parser when available.

    Returns the normalized v2 directive dict, or ``None`` when PyYAML is not
    installed or the body is not parseable YAML (caller falls back to the
    yaml-ish line parser). Tolerates the body being wrapped under a top-level
    ``retrieval_directive:`` key. Structurally-invalid v2 content (no topics,
    wrong focal count) raises ``ValueError`` with the same messages as the
    yaml-ish path — invalid is loud, not a silent legacy downgrade.
    """
    try:
        import yaml
    except ImportError:
        return None
    try:
        data = yaml.safe_load(body)
    except yaml.YAMLError:
        return None
    if not isinstance(data, dict):
        return None
    if isinstance(data.get("retrieval_directive"), dict):
        data = data["retrieval_directive"]
    if data.get("version") != 2:
        return None
    topics_raw = data.get("topics")
    if not isinstance(topics_raw, list) or not topics_raw:
        raise ValueError(
            f"[generate-tasks] {unit_label}: retrieval_directive declares "
            f"version: 2 but no topics were parsed; v2 requires a non-empty topics list."
        )
    topics: list[dict] = []
    focal_count = 0
    for raw_topic in topics_raw:
        if not isinstance(raw_topic, dict):
            raise ValueError(
                f"[generate-tasks] {unit_label}: v2 retrieval_directive "
                f"topics must be mappings, got: {type(raw_topic).__name__}"
            )
        topic = _normalize_v2_topic(raw_topic)
        if topic["role"] == "focal":
            focal_count += 1
        topics.append(topic)
    if focal_count != 1:
        raise ValueError(
            f"[generate-tasks] {unit_label}: v2 retrieval_directive must "
            f"declare exactly one role: focal topic (found {focal_count}). "
            f"If no focal candidate exists, emit a legacy flat directive instead."
        )
    return {
        "version": 2,
        "topics": topics,
    }


def _parse_v2_directive(block: str, unit_label: str) -> dict:
    """Parse a ``version: 2`` grouped directive block.

    Recognized shape::

        - version: 2
        - topics:
            - role: focal
              topic: <label>
              seeds: [a, b]              (or comma-separated)
              query: "<literal query>"   (optional; overrides topic+seeds at search)
              scale_set: [subsystem, implementation]
              activity_vocab: [pytest, fixture]
              limit: 8
            - role: adjacent
              ...

    Enforces exactly one ``role: focal``; zero/multi-focal v2 is a hard error
    that names ``unit_label``. Also tolerates a literal YAML code-fenced
    ``retrieval_directive:`` block embedded in the directive text.
    """
    # Strip a fenced YAML block if the lead pasted one verbatim.
    fence_match = re.search(
        r"```(?:yaml|yml)?\s*\n(.*?)\n```", block, re.DOTALL
    )
    if fence_match:
        body = fence_match.group(1)
        # A fenced block is real YAML (nested keys, multi-line seed lists) that
        # the line-oriented yaml-ish extractor mis-parses — each nested seed
        # bullet reads as a new topic. Prefer a real-YAML parse when available.
        yaml_parsed = _parse_v2_directive_yaml(body, unit_label)
        if yaml_parsed is not None:
            return yaml_parsed
    else:
        body = block
        # Strip leading "- " on bullet lines so YAML-ish indentation stands alone.
        cleaned: list[str] = []
        for raw in body.splitlines():
            line = raw.rstrip()
            if not line.strip():
                cleaned.append("")
                continue
            stripped = line.lstrip()
            indent = line[: len(line) - len(stripped)]
            if stripped.startswith("- "):
                inner = stripped[2:]
                if ":" in inner and not inner.startswith("role:"):
                    cleaned.append(f"{indent}{inner}")
                    continue
            cleaned.append(line)
        body = "\n".join(cleaned)

    topics_raw = _extract_topics_from_yaml_ish(body)
    if not topics_raw:
        raise ValueError(
            f"[generate-tasks] {unit_label}: retrieval_directive declares "
            f"version: 2 but no topics were parsed; v2 requires a non-empty topics list."
        )

    topics: list[dict] = []
    focal_count = 0
    for raw_topic in topics_raw:
        topic = _normalize_v2_topic(raw_topic)
        if topic["role"] == "focal":
            focal_count += 1
        topics.append(topic)

    if focal_count != 1:
        raise ValueError(
            f"[generate-tasks] {unit_label}: v2 retrieval_directive must "
            f"declare exactly one role: focal topic (found {focal_count}). "
            f"If no focal candidate exists, emit a legacy flat directive instead."
        )

    return {
        "version": 2,
        "topics": topics,
    }


def _extract_topics_from_yaml_ish(body: str) -> list[dict]:
    """Extract topics list entries from a minimally-YAML directive body.

    Returns a list of raw-key dicts (string keys, string-or-list values) one
    per ``- role: ...`` block under a top-level ``topics:`` key.
    """
    lines = body.splitlines()
    in_topics = False
    topics_indent = -1
    topic_blocks: list[list[str]] = []
    current: list[str] = []

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            if in_topics and current:
                current.append("")
            continue
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not in_topics:
            m = re.match(r"topics\s*:\s*$", stripped)
            if m:
                in_topics = True
                topics_indent = indent
            continue

        # End-of-topics: a key at <= topics_indent that isn't a list item.
        if indent <= topics_indent and not stripped.startswith("- "):
            in_topics = False
            if current:
                topic_blocks.append(current)
                current = []
            continue

        if stripped.startswith("- "):
            if current:
                topic_blocks.append(current)
            current = [line]
        else:
            if current:
                current.append(line)

    if current:
        topic_blocks.append(current)

    parsed: list[dict] = []
    for blk in topic_blocks:
        topic_dict = _parse_topic_block(blk)
        if topic_dict:
            parsed.append(topic_dict)
    return parsed


def _parse_topic_block(block_lines: list[str]) -> dict:
    """Parse one ``- key: value`` topic entry into a raw dict."""
    out: dict = {}
    if not block_lines:
        return out
    # First line: "- key: value"
    first = block_lines[0].lstrip()
    if first.startswith("- "):
        first = first[2:].strip()
    # Track base indent (continuation keys live at +2 of "- ")
    len(block_lines[0]) - len(block_lines[0].lstrip())
    # Parse first key
    if ":" in first:
        k, _, v = first.partition(":")
        out[k.strip()] = v.strip()
    for raw in block_lines[1:]:
        if not raw.strip():
            continue
        stripped = raw.lstrip()
        if ":" not in stripped:
            continue
        k, _, v = stripped.partition(":")
        out[k.strip()] = v.strip()
    return out


def _normalize_v2_topic(raw: dict) -> dict:
    """Coerce a raw-string topic dict into typed v2 fields with defaults."""
    role = (raw.get("role") or "").strip().lower()
    if role not in ("focal", "adjacent"):
        raise ValueError(
            f"v2 topic role must be 'focal' or 'adjacent', got: {role!r}"
        )
    topic = str(raw.get("topic") or "").strip().strip('"').strip("'")
    seeds = _split_csv_list(raw.get("seeds", ""))
    scale_set = _split_csv_list(raw.get("scale_set", ""))
    activity_vocab = _split_csv_list(raw.get("activity_vocab", ""))
    query_raw = str(raw.get("query") or "").strip()
    if query_raw.startswith('"') and query_raw.endswith('"'):
        query_raw = query_raw[1:-1]
    elif query_raw.startswith("'") and query_raw.endswith("'"):
        query_raw = query_raw[1:-1]
    limit_raw = str(raw.get("limit") or "").strip()
    try:
        limit = int(limit_raw) if limit_raw else (8 if role == "focal" else 4)
    except ValueError:
        limit = 8 if role == "focal" else 4
    return {
        "role": role,
        "topic": topic,
        "seeds": seeds,
        "scale_set": scale_set,
        "activity_vocab": activity_vocab,
        "query": query_raw,
        "limit": limit,
    }


# The two unit headings a plan may use. A plan declares its units one way or
# the other: `### Task N:` blocks carry their own brief, `### Phase N:` blocks
# group tasks under a shared one. A document using both is refused.
_PHASE_HEADING_RE = re.compile(r"^### Phase (\d+):\s*(.*)", re.MULTILINE)
_TASK_HEADING_RE = re.compile(r"^### Task (\d+):\s*(.*)", re.MULTILINE)

# Labels the plan-level acceptance bar where it is rendered into a task brief.
# The criteria belong to the plan and are honored once at plan close, so a
# worker reading its own brief does not mistake them for its own checklist.
PLAN_VERIFICATION_HEADING = "**Plan verification (plan-owned close criteria):**"


def generate_tasks_from_plan(
    plan_content: str,
    knowledge_dir: str = "",
    slug: str = "",
    script_dir: str = "",
) -> dict:
    """Parse plan.md content and return a tasks.json-compatible dict.

    Args:
        plan_content: Raw markdown content of plan.md.
        knowledge_dir: Path to the knowledge store (for backlink resolution).
        slug: Work item slug (for plan references in descriptions).
        script_dir: Path to the scripts directory (for pk_search.py).

    Returns:
        Dict matching the tasks.json schema with plan_checksum, generated_at,
        and phases containing tasks with flat IDs and blockedBy dependencies.
    """
    if not script_dir:
        script_dir = os.path.dirname(os.path.abspath(__file__))

    plan_checksum = hashlib.sha256(plan_content.encode("utf-8")).hexdigest()
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # Extract cross-cutting backlinks
    related_backlinks = extract_backlinks(plan_content, "Related")
    design_backlinks = extract_backlinks(plan_content, "Design Decisions")
    cross_cutting_backlinks = sorted(
        set(related_backlinks + design_backlinks)
    )

    # Extract strategy for propagation to workers
    strategy = extract_strategy(plan_content)

    # Parse design decisions for propagation to workers
    _dd_section_re = re.compile(r"^## Design Decisions\s*$", re.MULTILINE)
    design_decisions_present = bool(_dd_section_re.search(plan_content))
    if not design_decisions_present:
        print(
            "[generate-tasks] warning: plan.md missing ## Design Decisions"
            " — worker tasks will not receive design-decision context",
            file=sys.stderr,
        )
    all_design_decisions = parse_design_decisions(plan_content)

    phase_matches = list(_PHASE_HEADING_RE.finditer(plan_content))
    task_matches = list(_TASK_HEADING_RE.finditer(plan_content))
    if phase_matches and task_matches:
        raise ValueError(
            "[generate-tasks] plan mixes '### Phase "
            f"{phase_matches[0].group(1)}:' and '### Task "
            f"{task_matches[0].group(1)}:' headings; a plan declares its units "
            "one way or the other. No output was written."
        )

    result = {
        "plan_checksum": plan_checksum,
        "generated_at": generated_at,
        "recommended_workers": 0,
        "design_decisions_present": design_decisions_present,
    }

    if task_matches:
        tasks = _tasks_from_plan(
            plan_content=plan_content,
            task_matches=task_matches,
            cross_cutting_backlinks=cross_cutting_backlinks,
            strategy=strategy,
            all_design_decisions=all_design_decisions,
            knowledge_dir=knowledge_dir,
            slug=slug,
            script_dir=script_dir,
        )
        all_tasks = tasks
        result["tasks"] = tasks
    else:
        phases = _phases_from_plan(
            plan_content=plan_content,
            phase_matches=phase_matches,
            cross_cutting_backlinks=cross_cutting_backlinks,
            strategy=strategy,
            all_design_decisions=all_design_decisions,
            knowledge_dir=knowledge_dir,
            slug=slug,
            script_dir=script_dir,
        )
        all_tasks = [task for phase in phases for task in phase["tasks"]]
        result["phases"] = phases

    _validate_dependency_graph(all_tasks)
    result["recommended_workers"] = compute_recommended_workers(all_tasks)
    return result


def _validate_dependency_graph(all_tasks: list[dict]) -> None:
    """Refuse a task list whose blockedBy edges name absent or self ids."""
    task_ids = {task["id"] for task in all_tasks}
    for task in all_tasks:
        unknown = [
            dependency for dependency in task["blockedBy"]
            if dependency not in task_ids
        ]
        if unknown:
            raise ValueError(
                f"{task['id']} declares unknown dependencies: {', '.join(unknown)}"
            )
        if task["id"] in task["blockedBy"]:
            raise ValueError(f"{task['id']} cannot depend on itself")


def _phases_from_plan(
    plan_content: str,
    phase_matches: list,
    cross_cutting_backlinks: list,
    strategy: str,
    all_design_decisions: list[dict],
    knowledge_dir: str,
    slug: str,
    script_dir: str,
) -> list[dict]:
    """Build ``phases[]`` from a plan authored with ``### Phase N:`` headings.

    Each phase's shared brief lands in ``phase_context``; per-task descriptions
    carry only what is unique to the task.
    """
    phases = []
    task_counter = 0
    file_last_task: dict[str, str] = {}  # file -> last task id targeting it (across all phases)

    for i, match in enumerate(phase_matches):
        phase_num = int(match.group(1))
        phase_name = match.group(2).strip()

        # Get phase content boundaries
        start = match.end()
        if i + 1 < len(phase_matches):
            end = phase_matches[i + 1].start()
        else:
            next_h2 = re.search(r"^## ", plan_content[start:], re.MULTILINE)
            end = start + next_h2.start() if next_h2 else len(plan_content)
        phase_content = plan_content[start:end]

        # Extract objective (same-line only — don't cross newlines)
        obj_match = re.search(
            r"^\*\*Objective:\*\*[ \t]*(.*)", phase_content, re.MULTILINE
        )
        objective = obj_match.group(1).strip() if obj_match else ""

        # Extract files
        files_match = re.search(r"\*\*Files:\*\*\s*(.*)", phase_content)
        files_raw = files_match.group(1).strip() if files_match else ""
        files = [f.strip().strip("`") for f in files_raw.split(",") if f.strip()] if files_raw else []

        # Extract optional knowledge delivery mode (default: annotation-only)
        kd_match = re.search(
            r"\*\*Knowledge delivery:\*\*\s*(.*)", phase_content
        )
        resolve_full_content = (
            kd_match is not None
            and kd_match.group(1).strip().lower() == "full"
        )

        phase_backlinks = _parse_knowledge_context(phase_content)

        # Detect whether this phase declares persistent-mode advisors.
        # Only phase advisors tagged ``mode: persistent`` add advisory prompt
        # overhead to cost estimates — the opt-in advisor-agent route is the
        # only path that concatenates ``advisory-consultation.md`` onto worker
        # prompts. Default lead-handled consultations and non-persistent
        # advisor declarations (e.g. ``[must-consult]``, ``[on-demand]``
        # without a ``mode: persistent`` suffix) route through the lead
        # inline and do NOT inflate per-task context estimates.
        has_advisory = _has_persistent_advisor(phase_content)

        # Parse phase-level ``**Consultations required:**`` block — a
        # ``-`` bulleted list of consultation domain labels a worker on
        # this phase MUST request before starting implementation. The
        # block is lifted into ``phase_context`` so workers receive it
        # via ``lore work phase-context``; it is NOT duplicated into
        # per-task descriptions (per-task descriptions stay lean).
        # Required consultations are runtime SendMessage traffic, not
        # pre-loaded prompt content, so the presence of this block does
        # NOT add advisory-mixin overhead to cost estimates.
        consultations_required = _parse_consultations_required(phase_content)

        # Detect task format: prescriptive vs intent+constraints (default)
        tf_match = re.search(r"\*\*Task format:\*\*\s*(.*)", phase_content)
        is_prescriptive = (
            tf_match is not None
            and tf_match.group(1).strip().lower() == "prescriptive"
        )

        scope_lines = _parse_scope_lines(phase_content)
        verif_lines = _parse_verification_lines(phase_content)

        retrieval_directive = _parse_retrieval_directive(
            phase_content, f"phase {phase_num}"
        )

        # Annotation quality warning: intent-based + annotation-only delivery
        annotation_warning = (
            not is_prescriptive
            and not resolve_full_content
            and bool(phase_backlinks)
        )

        # Extract unchecked task items
        unchecked = re.findall(r"^- \[ \]\s+(.*)", phase_content, re.MULTILINE)
        if not unchecked:
            continue

        phase_tasks = []

        # First pass: parse tasks, extract file_targets and backlinks
        parsed_items: list[dict] = []
        for item_text in unchecked:
            task_counter += 1
            task_id = f"task-{task_counter}"
            subject = item_text.strip()
            active_form = to_active_form(subject)
            file_targets = extract_file_targets(item_text, files)
            task_backlinks = extract_task_backlinks(item_text)
            woven_norms = extract_woven_norms(item_text)
            judgment_class = extract_judgment_class(item_text)
            route = extract_route(item_text)
            explicit_dependencies = extract_explicit_dependencies(item_text)
            tree = extract_tree(item_text)
            parsed_items.append({
                "task_id": task_id,
                "subject": subject,
                "active_form": active_form,
                "file_targets": file_targets,
                "task_backlinks": task_backlinks,
                "woven_norms": woven_norms,
                "judgment_class": judgment_class,
                "route": route,
                "explicit_dependencies": explicit_dependencies,
                "tree": tree,
            })

        # Filter design decisions relevant to this phase
        phase_decisions = decisions_for_phase(
            all_design_decisions, phase_num
        )

        # Build phase_context once — carries all phase-shared content lifted out of task descriptions:
        # Strategy, Design Decisions, Verification, Reference files (full phase files list),
        # phase Knowledge context backlinks, the resolved ## Prior Knowledge block, and
        # (when declared) the **Consultations required:** domain list (D4/D6a).
        phase_context = _build_phase_context(
            phase_num=phase_num,
            objective=objective,
            files=files,
            phase_backlinks=phase_backlinks,
            cross_cutting_backlinks=cross_cutting_backlinks,
            phase_decisions=phase_decisions,
            verif_lines=verif_lines,
            resolve_full_content=resolve_full_content,
            strategy=strategy or None,
            knowledge_dir=knowledge_dir,
            script_dir=script_dir,
            annotation_warning=annotation_warning,
            consultations_required=consultations_required,
        )

        # D5 invariant: if the plan had any phase-level context to lift, phase_context must be non-empty.
        _has_phase_level_context = bool(
            phase_decisions
            or verif_lines
            or files
            or phase_backlinks
            or strategy
            or consultations_required
        )
        if _has_phase_level_context and not phase_context.strip():
            raise RuntimeError(
                f"[generate-tasks] D5 violation: phase {phase_num} had phase-level context "
                f"(design decisions, verification, files, knowledge context, or strategy) "
                f"but phase_context is empty — this is a generator bug."
            )

        # Second pass: build per-task descriptions (unique assignment only — no phase-shared blocks)
        for item in parsed_items:
            task_id = item["task_id"]
            subject = item["subject"]
            active_form = item["active_form"]
            file_targets = item["file_targets"]
            task_backlinks = item["task_backlinks"]
            woven_norms = item["woven_norms"]
            judgment_class = item["judgment_class"]
            route = item["route"]
            explicit_dependencies = item["explicit_dependencies"]
            tree = item["tree"]

            # Build stripped description: Phase line (D6), objective hint, target files,
            # task line, task-specific Scope, task-specific backlinks (annotation-only), plan reference.
            desc_parts = []
            # D6: stable first line for worker phase-number extraction
            desc_parts.append(f"**Phase:** {phase_num}")
            if objective:
                desc_parts.append(
                    f"**Phase {phase_num} objective:** {objective}"
                )
            if file_targets:
                formatted_targets = ", ".join(f"`{f}`" for f in file_targets)
                desc_parts.append(
                    f"**Target files:** {formatted_targets}"
                    " — files this task is expected to modify"
                )
            elif files_raw:
                desc_parts.append(f"**Files:** {files_raw}")
            desc_parts.append(f"**Task:** {strip_route_marker(subject)}")
            if scope_lines:
                desc_parts.append("")
                desc_parts.append("**Scope:**")
                desc_parts.extend(scope_lines)
            # Task-specific backlinks: annotation-only compact list (no resolution)
            if task_backlinks:
                desc_parts.append("")
                desc_parts.append("**Task context:**")
                for bl in task_backlinks:
                    target, annotation = _unpack_backlink(bl)
                    if annotation:
                        desc_parts.append(f"- [[{target}]] — {annotation}")
                    else:
                        desc_parts.append(f"- [[{target}]]")
            if slug:
                desc_parts.append("")
                desc_parts.append(f"**Plan reference:** [[work:{slug}]]")
            description = "\n".join(desc_parts)

            context_cost_estimate = estimate_context_cost(
                description=description,
                file_targets=file_targets,
                subject=subject,
                has_advisory=has_advisory,
            )

            task_payload = {
                "id": task_id,
                "subject": subject,
                "description": description,
                "activeForm": active_form,
                "blockedBy": list(explicit_dependencies),
                "tree": tree,
                "file_targets": file_targets,
                "judgment_class": judgment_class,
                "context_cost_estimate": context_cost_estimate,
            }
            # Omit-when-empty: the route field is present only when the task
            # line carried a [route: …] marker — no default synthesis.
            if route is not None:
                task_payload["route"] = route
            if woven_norms:
                task_payload["woven_norms"] = woven_norms
            phase_tasks.append(task_payload)

        # Chain tasks that share a file target (within and across phases)
        for task in phase_tasks:
            for ft in task.get("file_targets", []):
                if ft in file_last_task:
                    prev_id = file_last_task[ft]
                    if prev_id not in task["blockedBy"]:
                        task["blockedBy"].append(prev_id)
                file_last_task[ft] = task["id"]

        # Compute phase-level cost summary from per-task estimates.
        # phase_context_chars is included for attribution but not added to per-task totals
        # (phase_context is fetched once per task claim, not per task execution).
        task_totals = [
            t["context_cost_estimate"]["total_chars"]
            for t in phase_tasks
            if "context_cost_estimate" in t
        ]
        phase_context_chars = len(phase_context)
        if task_totals:
            phase_cost_summary = {
                "total_chars": sum(task_totals),
                "avg_per_task": int(sum(task_totals) / len(task_totals)),
                "max_task": max(task_totals),
                "min_task": min(task_totals),
                "phase_context_chars": phase_context_chars,
            }
        else:
            phase_cost_summary = {
                "total_chars": 0,
                "avg_per_task": 0,
                "max_task": 0,
                "min_task": 0,
                "phase_context_chars": phase_context_chars,
            }

        phases.append({
            "phase_number": phase_num,
            "phase_name": phase_name,
            "objective": objective,
            "files": files,
            "tasks": phase_tasks,
            "phase_context": phase_context,
            "phase_cost_summary": phase_cost_summary,
            "retrieval_directive": retrieval_directive,
        })

    return phases


def _plan_verification_lines(plan_level_text: str) -> list[str]:
    """Parse the plan's acceptance bar from either shape an author may write it.

    The bar is a ``**Verification:**`` block; when it heads its own
    ``## Verification`` section the bold marker may be omitted, so the section's
    bullets are read directly.
    """
    lines = _parse_verification_lines(plan_level_text)
    if lines:
        return lines
    section = re.search(r"^##\s+Verification\s*$", plan_level_text, re.MULTILINE)
    if not section:
        return []
    start = section.end()
    next_h2 = re.search(r"^## ", plan_level_text[start:], re.MULTILINE)
    body = plan_level_text[start:start + next_h2.start()] if next_h2 else plan_level_text[start:]
    out: list[str] = []
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped.startswith("- "):
            continue
        if stripped.startswith("- [ ]") or stripped.startswith("- [x]"):
            continue
        text = stripped[2:].strip()
        if text.startswith("<") and text.endswith(">"):
            continue
        out.append(stripped)
    return out


def _flat_task_blocks(plan_content: str, task_matches: list) -> list[dict]:
    """Slice a plan into one block per ``### Task N:`` heading."""
    blocks: list[dict] = []
    for i, match in enumerate(task_matches):
        body_start = match.end()
        if i + 1 < len(task_matches):
            end = task_matches[i + 1].start()
        else:
            next_h2 = re.search(r"^## ", plan_content[body_start:], re.MULTILINE)
            end = body_start + next_h2.start() if next_h2 else len(plan_content)
        blocks.append({
            "number": int(match.group(1)),
            "name": match.group(2).strip(),
            "heading_start": match.start(),
            "end": end,
            "body": plan_content[body_start:end],
        })
    return blocks


def _plan_level_text(plan_content: str, blocks: list[dict]) -> str:
    """Return the plan with its task blocks cut out.

    Blocks under `**Verification:**` are parsed from this text, so a task's own
    block can never be read as the plan's acceptance bar.
    """
    parts: list[str] = []
    cursor = 0
    for block in blocks:
        parts.append(plan_content[cursor:block["heading_start"]])
        cursor = block["end"]
    parts.append(plan_content[cursor:])
    return "".join(parts)


def _flat_checklist_line(block: dict) -> "str | None":
    """Return a task block's single unchecked checklist line.

    ``None`` means the line is checked — completed work, which the generator
    drops from the emitted list. Any count other than one is a refusal: the
    heading number is the task's id, so two lines under one heading have no
    distinct identity to take.
    """
    unchecked = re.findall(r"^- \[ \]\s+(.*)", block["body"], re.MULTILINE)
    checked = re.findall(r"^- \[[xX]\]\s+(.*)", block["body"], re.MULTILINE)
    total = len(unchecked) + len(checked)
    if total != 1:
        raise ValueError(
            f"[generate-tasks] task {block['number']} ({block['name']!r}) carries "
            f"{total} checklist lines; each '### Task N:' block carries exactly one."
        )
    return unchecked[0] if unchecked else None


def _flat_file_targets(block: dict, item_text: str) -> list[str]:
    """Resolve a task's owned file surface from **Files:** plus its task line.

    ``**Files:**`` is authoritative: a backticked path on the task line that the
    block does not declare is a contradiction, not an addition. With no
    ``**Files:**`` block the task line's paths stand alone as the surface.
    """
    declared = _parse_files_declaration(block["body"])
    line_paths = backtick_file_paths(item_text)
    undeclared = [path for path in line_paths if path not in declared]
    if declared and undeclared:
        raise ValueError(
            f"[generate-tasks] task {block['number']} targets "
            f"{', '.join(undeclared)} on its task line but does not declare "
            f"{'it' if len(undeclared) == 1 else 'them'} in **Files:**, which is "
            f"the task's owned surface: {item_text.strip()}"
        )
    targets = declared + undeclared
    if not targets:
        raise ValueError(
            f"[generate-tasks] task {block['number']} names no file target; declare "
            f"the owned surface in **Files:** or in backticks on the task line: "
            f"{item_text.strip()}"
        )
    return targets


def _merge_task_backlinks(
    line_backlinks: list[str], knowledge_context: list[tuple[str, str]]
) -> list[tuple[str, str]]:
    """Merge a task's two backlink sources into one task-level tier.

    Task-line order wins, and an entry named in both keeps the annotation the
    ``**Knowledge context:**`` block gave it.
    """
    annotations = dict(knowledge_context)
    merged: list[tuple[str, str]] = []
    seen: set[str] = set()
    for target in line_backlinks:
        merged.append((target, annotations.get(target, "")))
        seen.add(target)
    for target, annotation in knowledge_context:
        if target not in seen:
            merged.append((target, annotation))
            seen.add(target)
    return merged


def _tasks_from_plan(
    plan_content: str,
    task_matches: list,
    cross_cutting_backlinks: list,
    strategy: str,
    all_design_decisions: list[dict],
    knowledge_dir: str,
    slug: str,
    script_dir: str,
) -> list[dict]:
    """Build ``tasks[]`` from a plan authored with ``### Task N:`` headings.

    Each task's brief is composed into its own description, so a consumer reads
    the whole assignment off the task record with no second fetch and no index
    into a containing unit. Task ids come from the heading number rather than a
    running count, which keeps ``[depends-on: task-N]`` pointing at the same
    task after earlier work is checked off.
    """
    blocks = _flat_task_blocks(plan_content, task_matches)
    plan_verification = _plan_verification_lines(
        _plan_level_text(plan_content, blocks)
    )

    tasks: list[dict] = []
    completed_ids: set[str] = set()
    seen_numbers: set[int] = set()

    for block in blocks:
        number = block["number"]
        if number in seen_numbers:
            raise ValueError(
                f"[generate-tasks] duplicate heading '### Task {number}: "
                f"{block['name']}'; the heading number is the task's id and must "
                f"be unique."
            )
        seen_numbers.add(number)
        task_id = f"task-{number}"

        item_text = _flat_checklist_line(block)
        if item_text is None:
            completed_ids.add(task_id)
            continue

        body = block["body"]
        subject = item_text.strip()
        file_targets = _flat_file_targets(block, item_text)

        deliverable_match = re.search(
            r"^\*\*Deliverable:\*\*[ \t]*(.*)", body, re.MULTILINE
        )
        deliverable = deliverable_match.group(1).strip() if deliverable_match else ""

        kd_match = re.search(r"\*\*Knowledge delivery:\*\*\s*(.*)", body)
        resolve_full_content = (
            kd_match is not None and kd_match.group(1).strip().lower() == "full"
        )
        tf_match = re.search(r"\*\*Task format:\*\*\s*(.*)", body)
        is_prescriptive = (
            tf_match is not None and tf_match.group(1).strip().lower() == "prescriptive"
        )

        knowledge_context = _parse_knowledge_context(body)
        scope_lines = _parse_scope_lines(body)
        consultations_required = _parse_consultations_required(body)
        has_advisory = _has_persistent_advisor(body)
        retrieval_directive = _parse_retrieval_directive(body, f"task {number}")

        # A [depends-on: …] written inside the prose of a task line is a
        # mention, not an edge — only the marker run closing the line declares.
        explicit_dependencies = extract_explicit_dependencies(
            item_text, trailing_only=True
        )

        annotation_warning = (
            not is_prescriptive
            and not resolve_full_content
            and bool(knowledge_context)
        )

        desc_parts: list[str] = []
        if deliverable:
            desc_parts.append(f"**Deliverable:** {deliverable}")
        formatted_targets = ", ".join(f"`{f}`" for f in file_targets)
        desc_parts.append(
            f"**Target files:** {formatted_targets}"
            " — files this task is expected to modify"
        )
        desc_parts.append(f"**Task:** {strip_route_marker(subject)}")

        if scope_lines:
            desc_parts.append("")
            desc_parts.append("**Scope:**")
            desc_parts.extend(scope_lines)

        if consultations_required:
            desc_parts.append("")
            desc_parts.append("**Consultations required:**")
            desc_parts.extend(f"- {domain}" for domain in consultations_required)

        if plan_verification:
            desc_parts.append("")
            desc_parts.append(PLAN_VERIFICATION_HEADING)
            desc_parts.extend(plan_verification)

        if annotation_warning:
            desc_parts.append("")
            desc_parts.append(
                "> **Note:** This task uses intent+constraints task format with "
                "annotation-only knowledge delivery. Workers interpret design patterns "
                "from knowledge context — consider using `**Knowledge delivery:** full` "
                "so workers receive resolved content, not just backlink labels."
            )

        context = build_context_section(
            phase_backlinks=[],
            cross_cutting_backlinks=cross_cutting_backlinks,
            knowledge_dir=knowledge_dir,
            script_dir=script_dir,
            task_backlinks=_merge_task_backlinks(
                extract_task_backlinks(item_text), knowledge_context
            ),
            reference_files=None,
            design_decisions=all_design_decisions,
            resolve_full_content=resolve_full_content,
            strategy=strategy or None,
        )
        if context.strip():
            desc_parts.append("")
            desc_parts.append(context.strip())

        if slug:
            desc_parts.append("")
            desc_parts.append(f"**Plan reference:** [[work:{slug}]]")

        description = "\n".join(desc_parts)

        task_payload = {
            "id": task_id,
            "name": block["name"],
            "subject": subject,
            "deliverable": deliverable,
            "description": description,
            "activeForm": to_active_form(subject),
            "blockedBy": list(explicit_dependencies),
            "tree": extract_tree(item_text),
            "file_targets": file_targets,
            "judgment_class": extract_judgment_class(item_text),
            "consultations_required": consultations_required,
            "retrieval_directive": retrieval_directive,
            "context_cost_estimate": estimate_context_cost(
                description=description,
                file_targets=file_targets,
                subject=subject,
                has_advisory=has_advisory,
            ),
        }
        route = extract_route(item_text)
        if route is not None:
            task_payload["route"] = route
        woven_norms = extract_woven_norms(item_text)
        if woven_norms:
            task_payload["woven_norms"] = woven_norms
        tasks.append(task_payload)

    # A dependency on work already checked off is satisfied, so its edge is
    # dropped; a dependency on a task the plan never declares still fails
    # validation downstream.
    for task in tasks:
        task["blockedBy"] = [
            dependency for dependency in task["blockedBy"]
            if dependency not in completed_ids
        ]

    # Chain tasks that share a file target, in plan order.
    file_last_task: dict[str, str] = {}
    for task in tasks:
        for target in task["file_targets"]:
            if target in file_last_task:
                previous = file_last_task[target]
                if previous not in task["blockedBy"]:
                    task["blockedBy"].append(previous)
            file_last_task[target] = task["id"]

    return tasks


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

def _print_flat_sizing_diagnostics(tasks: list[dict]) -> None:
    """Print the per-task sizing summary for a flat plan, and outlier warnings."""
    totals = [
        t.get("context_cost_estimate", {}).get("total_chars", 0) for t in tasks
    ]
    avg = int(sum(totals) / len(totals)) if totals else 0

    print("", file=sys.stderr)
    print("Context cost summary:", file=sys.stderr)
    print(
        f"  {'Task':<40}  {'Files':>5}  {'Cost (chars)':>12}",
        file=sys.stderr,
    )
    print("  " + "-" * 61, file=sys.stderr)

    warnings: list[str] = []
    for task in tasks:
        label = task.get("name") or task.get("subject", "")
        display_name = label[:38] + ".." if len(label) > 40 else label
        total = task.get("context_cost_estimate", {}).get("total_chars", 0)
        print(
            f"  {display_name:<40}  {len(task.get('file_targets', [])):>5}"
            f"  {total:>12,}",
            file=sys.stderr,
        )
        if avg > 0 and total > 2 * avg:
            warnings.append(
                f"  WARNING: task '{task.get('subject', '')}' is {total:,} chars"
                f" ({total / avg:.1f}x plan avg {avg:,}) — consider splitting"
            )

    if warnings:
        print("", file=sys.stderr)
        print("Oversized tasks (>2x plan avg):", file=sys.stderr)
        for w in warnings:
            print(w, file=sys.stderr)

    print("", file=sys.stderr)


def print_sizing_diagnostics(result: dict) -> None:
    """Print per-phase sizing summary and outlier warnings to stderr.

    Outputs:
        - A summary table: phase name, task count, avg cost (chars), max cost (chars)
        - Warnings for tasks whose total_chars exceeds 2x the phase avg_per_task

    Args:
        result: The dict returned by generate_tasks_from_plan().
    """
    tasks = result.get("tasks")
    if tasks:
        _print_flat_sizing_diagnostics(tasks)
        return

    phases = result.get("phases", [])
    if not phases:
        return

    # Header
    print("", file=sys.stderr)
    print("Context cost summary:", file=sys.stderr)
    print(
        f"  {'Phase':<30}  {'Tasks':>5}  {'Avg (chars)':>12}  {'Max (chars)':>12}",
        file=sys.stderr,
    )
    print("  " + "-" * 65, file=sys.stderr)

    warnings: list[str] = []

    for phase in phases:
        phase_name = phase.get("phase_name", "")
        tasks = phase.get("tasks", [])
        summary = phase.get("phase_cost_summary", {})
        avg = summary.get("avg_per_task", 0)
        max_cost = summary.get("max_task", 0)
        task_count = len(tasks)

        # Truncate phase name for table formatting
        display_name = phase_name[:28] + ".." if len(phase_name) > 30 else phase_name
        print(
            f"  {display_name:<30}  {task_count:>5}  {avg:>12,}  {max_cost:>12,}",
            file=sys.stderr,
        )

        # Collect outlier warnings
        for task in tasks:
            estimate = task.get("context_cost_estimate", {})
            total = estimate.get("total_chars", 0)
            if avg > 0 and total > 2 * avg:
                warnings.append(
                    f"  WARNING: Phase '{phase_name}' — task '{task.get('subject', '')}'"
                    f" is {total:,} chars ({total / avg:.1f}x phase avg {avg:,})"
                    f" — consider splitting"
                )

    if warnings:
        print("", file=sys.stderr)
        print("Oversized tasks (>2x phase avg):", file=sys.stderr)
        for w in warnings:
            print(w, file=sys.stderr)

    print("", file=sys.stderr)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate tasks.json from a plan.md file."
    )
    parser.add_argument("plan_path", help="Path to plan.md")
    parser.add_argument(
        "--knowledge-dir", default="", help="Knowledge store directory"
    )
    parser.add_argument(
        "--slug", default="", help="Work item slug"
    )
    parser.add_argument(
        "--diagnostics", action="store_true",
        help="Print per-phase context cost summary and warnings to stderr"
    )
    parser.add_argument(
        "--quiet", action="store_true",
        help="Suppress diagnostics output (overrides --diagnostics)"
    )
    args = parser.parse_args()

    if not os.path.isfile(args.plan_path):
        print(f"Error: plan.md not found at: {args.plan_path}", file=sys.stderr)
        sys.exit(1)

    with open(args.plan_path, "r", encoding="utf-8") as f:
        plan_content = f.read()

    # Infer slug from directory name if not provided
    slug = args.slug
    if not slug:
        slug = os.path.basename(os.path.dirname(os.path.abspath(args.plan_path)))

    result = generate_tasks_from_plan(
        plan_content=plan_content,
        knowledge_dir=args.knowledge_dir,
        slug=slug,
        script_dir=os.path.dirname(os.path.abspath(__file__)),
    )

    if args.diagnostics and not args.quiet:
        print_sizing_diagnostics(result)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
