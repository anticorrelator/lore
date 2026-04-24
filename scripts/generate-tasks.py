#!/usr/bin/env python3
"""generate-tasks: Parse plan.md and produce a tasks.json-compatible dict.

Standalone CLI and importable module. Zero external dependencies (stdlib only).

CLI usage:
    python3 generate-tasks.py <plan-md-path> [--knowledge-dir <path>]

Outputs JSON to stdout matching the tasks.json schema:
{
  "plan_checksum": "sha256-of-plan.md",
  "generated_at": "ISO-8601-UTC",
  "phases": [{ "phase_number": 1, "phase_name": "...", "objective": "...",
                "files": [...], "tasks": [{ "id": "task-1", ... }] }]
}
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


def extract_file_targets(task_text: str, phase_files: list[str]) -> list[str]:
    """Extract file targets from a task's text, falling back to phase files.

    Looks for backtick-quoted paths (containing '/' or '.') in the task text.
    If none found, returns the phase-level files list as fallback.
    Returns deduplicated list preserving first-occurrence order.
    """
    targets: list[str] = []
    seen: set[str] = set()
    for m in re.finditer(r"`([^`]+)`", task_text):
        candidate = m.group(1).strip()
        if _is_file_path(candidate) and candidate not in seen:
            targets.append(candidate)
            seen.add(candidate)
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
    """Build the context section for a task description.

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

    # Parse phases
    phase_re = re.compile(r"^### Phase (\d+):\s*(.*)", re.MULTILINE)
    phase_matches = list(phase_re.finditer(plan_content))

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

        # Extract phase-level knowledge context backlinks with annotations
        kc_match = re.search(
            r"\*\*Knowledge context:\*\*\s*\n((?:- .*\n?)*)", phase_content
        )
        phase_backlinks: list[tuple[str, str]] = []
        if kc_match:
            kc_block = kc_match.group(1)
            seen_targets: set[str] = set()
            for line in kc_block.splitlines():
                bl_match = re.search(r"\[\[([^\]]+)\]\]", line)
                if not bl_match:
                    continue
                target = bl_match.group(1).strip()
                if target in seen_targets:
                    continue
                seen_targets.add(target)
                # Extract annotation text after the backlink: " — <annotation>"
                annotation = ""
                after_bl = line[bl_match.end():]
                ann_match = re.match(r"\s*—\s*(.*)", after_bl)
                if ann_match:
                    annotation = ann_match.group(1).strip()
                phase_backlinks.append((target, annotation))

        # Detect whether this phase declares advisors
        has_advisory = bool(re.search(r"^\*\*Advisors:\*\*", phase_content, re.MULTILINE))

        # Detect task format: prescriptive vs intent+constraints (default)
        tf_match = re.search(r"\*\*Task format:\*\*\s*(.*)", phase_content)
        is_prescriptive = (
            tf_match is not None
            and tf_match.group(1).strip().lower() == "prescriptive"
        )

        # Extract Scope block (plain bullet lines after **Scope:**)
        scope_match = re.search(
            r"^\*\*Scope:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
            phase_content, re.MULTILINE
        )
        scope_lines: list[str] = []
        if scope_match:
            for line in scope_match.group(1).splitlines():
                stripped = line.strip()
                if stripped.startswith("- ") and not stripped.startswith("- [ ]") and not stripped.startswith("- [x]"):
                    text = stripped[2:].strip()
                    # Skip template placeholder lines
                    if not text.startswith("Do not modify:") and not text.startswith("Output contract:"):
                        scope_lines.append(stripped)
                    elif "path/to/file" not in text and "<what" not in text:
                        scope_lines.append(stripped)

        # Extract Verification block (plain bullet lines after **Verification:**)
        verif_match = re.search(
            r"^\*\*Verification:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
            phase_content, re.MULTILINE
        )
        verif_lines: list[str] = []
        if verif_match:
            for line in verif_match.group(1).splitlines():
                stripped = line.strip()
                if stripped.startswith("- ") and not stripped.startswith("- [ ]") and not stripped.startswith("- [x]"):
                    text = stripped[2:].strip()
                    # Skip template placeholder lines (angle-bracket content)
                    if not (text.startswith("<") and text.endswith(">")):
                        verif_lines.append(stripped)

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
            parsed_items.append({
                "task_id": task_id,
                "subject": subject,
                "active_form": active_form,
                "file_targets": file_targets,
                "task_backlinks": task_backlinks,
            })

        # Filter design decisions relevant to this phase
        phase_decisions = decisions_for_phase(
            all_design_decisions, phase_num
        )

        # Second pass: build context and descriptions with per-task reference files
        for item in parsed_items:
            task_id = item["task_id"]
            subject = item["subject"]
            active_form = item["active_form"]
            file_targets = item["file_targets"]
            task_backlinks = item["task_backlinks"]

            # Per-task reference files: phase files minus this task's targets
            reference_files = detect_reference_files(files, file_targets)

            context = build_context_section(
                phase_backlinks, cross_cutting_backlinks,
                knowledge_dir, script_dir,
                task_backlinks=task_backlinks,
                reference_files=reference_files,
                design_decisions=phase_decisions,
                resolve_full_content=resolve_full_content,
                strategy=strategy or None,
            )

            # Build description
            desc_parts = []
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
            desc_parts.append(f"**Task:** {subject}")
            if scope_lines:
                desc_parts.append("")
                desc_parts.append("**Scope:**")
                desc_parts.extend(scope_lines)
            if verif_lines:
                desc_parts.append("")
                desc_parts.append("**Verification:**")
                desc_parts.extend(verif_lines)
            if annotation_warning:
                desc_parts.append("")
                desc_parts.append(
                    "> **Note:** This phase uses intent+constraints task format with annotation-only "
                    "knowledge delivery. Workers interpret design patterns from knowledge context — "
                    "consider using `**Knowledge delivery:** full` so workers receive resolved content, "
                    "not just backlink labels."
                )
            desc_parts.append("")
            desc_parts.append(context)
            if slug:
                desc_parts.append(f"**Plan reference:** [[work:{slug}]]")
            description = "\n".join(desc_parts)

            context_cost_estimate = estimate_context_cost(
                description=description,
                file_targets=file_targets,
                subject=subject,
                has_advisory=has_advisory,
            )

            phase_tasks.append({
                "id": task_id,
                "subject": subject,
                "description": description,
                "activeForm": active_form,
                "blockedBy": [],
                "file_targets": file_targets,
                "context_cost_estimate": context_cost_estimate,
            })

        # Chain tasks that share a file target (within and across phases)
        for task in phase_tasks:
            for ft in task.get("file_targets", []):
                if ft in file_last_task:
                    prev_id = file_last_task[ft]
                    if prev_id not in task["blockedBy"]:
                        task["blockedBy"].append(prev_id)
                file_last_task[ft] = task["id"]

        # Compute phase-level cost summary from per-task estimates
        task_totals = [
            t["context_cost_estimate"]["total_chars"]
            for t in phase_tasks
            if "context_cost_estimate" in t
        ]
        if task_totals:
            phase_cost_summary = {
                "total_chars": sum(task_totals),
                "avg_per_task": int(sum(task_totals) / len(task_totals)),
                "max_task": max(task_totals),
                "min_task": min(task_totals),
            }
        else:
            phase_cost_summary = {
                "total_chars": 0,
                "avg_per_task": 0,
                "max_task": 0,
                "min_task": 0,
            }

        phases.append({
            "phase_number": phase_num,
            "phase_name": phase_name,
            "objective": objective,
            "files": files,
            "tasks": phase_tasks,
            "phase_cost_summary": phase_cost_summary,
        })

    # Compute recommended worker count from the assembled DAG
    all_tasks = [task for phase in phases for task in phase["tasks"]]
    recommended_workers = compute_recommended_workers(all_tasks)

    return {
        "plan_checksum": plan_checksum,
        "generated_at": generated_at,
        "recommended_workers": recommended_workers,
        "design_decisions_present": design_decisions_present,
        "phases": phases,
    }


# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

def print_sizing_diagnostics(result: dict) -> None:
    """Print per-phase sizing summary and outlier warnings to stderr.

    Outputs:
        - A summary table: phase name, task count, avg cost (chars), max cost (chars)
        - Warnings for tasks whose total_chars exceeds 2x the phase avg_per_task

    Args:
        result: The dict returned by generate_tasks_from_plan().
    """
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
