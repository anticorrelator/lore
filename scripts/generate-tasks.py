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
        # Must look like a file path: contains '/' or '.' (but not just a word)
        if ("/" in candidate or "." in candidate) and candidate not in seen:
            targets.append(candidate)
            seen.add(candidate)
    if targets:
        return targets
    # Fallback: use phase-level files
    return list(phase_files)


def detect_reference_files(
    phase_files: list[str], all_task_targets: list[list[str]]
) -> list[str]:
    """Detect phase files that are not targeted by any task in the phase.

    These are "reference files" — files listed at the phase level that no task
    directly modifies. Workers should read them for context before starting.

    Args:
        phase_files: The phase-level ``**Files:**`` list.
        all_task_targets: List of each task's ``file_targets`` within the phase.

    Returns:
        Phase files not present in any task's targets, preserving original order.
        Empty list when every phase file appears in at least one task's targets.
    """
    targeted: set[str] = set()
    for targets in all_task_targets:
        targeted.update(targets)
    return [f for f in phase_files if f not in targeted]


def build_context_section(
    phase_backlinks: list[str],
    cross_cutting_backlinks: list[str],
    knowledge_dir: str,
    script_dir: str,
    task_backlinks: list[str] | None = None,
    reference_files: list[str] | None = None,
    design_decisions: list[dict] | None = None,
) -> str:
    """Build the context section for a task description.

    Task-level backlinks (from the individual checklist item) are resolved
    first and given priority within the char budget. Phase-level and
    cross-cutting backlinks fill remaining budget.

    When design_decisions is non-empty, a ## Design Decisions block is
    rendered before the ## Context heading, showing Decision + Rationale
    for each relevant decision.

    When reference_files is non-empty, a **Reference files:** block is
    prepended before the ## Context heading.
    """
    lines = []

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

    if task_backlinks:
        lines.append("Task-level:")
        for bl in task_backlinks:
            lines.append(f"- [[{bl}]]")
        lines.append("")

    if phase_backlinks:
        lines.append("Phase-level:")
        for bl in phase_backlinks:
            lines.append(f"- [[{bl}]]")
        lines.append("")

    if cross_cutting_backlinks:
        lines.append("Cross-cutting:")
        for bl in cross_cutting_backlinks:
            lines.append(f"- [[{bl}]]")
        lines.append("")

    has_any = task_backlinks or phase_backlinks or cross_cutting_backlinks
    if not has_any:
        lines.append("No backlinks found in plan.")
        lines.append("")

    # Build prioritized resolution order: task-level first, then phase, then cross-cutting
    # Deduplicate while preserving priority order
    all_backlinks: list[str] = []
    seen: set[str] = set()
    for bl_list in (task_backlinks or [], phase_backlinks, cross_cutting_backlinks):
        for bl in bl_list:
            if bl not in seen:
                all_backlinks.append(bl)
                seen.add(bl)

    if all_backlinks and knowledge_dir:
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

    return "\n".join(lines)


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

    # Parse design decisions for propagation to workers
    all_design_decisions = parse_design_decisions(plan_content)

    # Parse phases
    phase_re = re.compile(r"^### Phase (\d+):\s*(.*)", re.MULTILINE)
    phase_matches = list(phase_re.finditer(plan_content))

    phases = []
    task_counter = 0
    prev_phase_task_ids: list[str] = []

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

        # Extract phase-level knowledge context backlinks
        kc_match = re.search(
            r"\*\*Knowledge context:\*\*\s*\n((?:- .*\n?)*)", phase_content
        )
        phase_backlinks = []
        if kc_match:
            kc_block = kc_match.group(1)
            for bl_match in re.finditer(r"\[\[([^\]]+)\]\]", kc_block):
                target = bl_match.group(1).strip()
                if target not in phase_backlinks:
                    phase_backlinks.append(target)

        # Extract unchecked task items
        unchecked = re.findall(r"^- \[ \]\s+(.*)", phase_content, re.MULTILINE)
        if not unchecked:
            continue

        current_phase_task_ids: list[str] = []
        phase_tasks = []

        # First pass: parse tasks, extract file_targets and backlinks
        parsed_items: list[dict] = []
        all_task_targets: list[list[str]] = []
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
            all_task_targets.append(file_targets)

        # Compute reference files: phase files not targeted by any task
        reference_files = detect_reference_files(files, all_task_targets)

        # Filter design decisions relevant to this phase
        phase_decisions = decisions_for_phase(
            all_design_decisions, phase_num
        )

        # Second pass: build context and descriptions with reference files
        for item in parsed_items:
            task_id = item["task_id"]
            subject = item["subject"]
            active_form = item["active_form"]
            file_targets = item["file_targets"]
            task_backlinks = item["task_backlinks"]

            context = build_context_section(
                phase_backlinks, cross_cutting_backlinks,
                knowledge_dir, script_dir,
                task_backlinks=task_backlinks,
                reference_files=reference_files,
                design_decisions=phase_decisions,
            )

            # Build description
            desc_parts = []
            if objective:
                desc_parts.append(
                    f"**Phase {phase_num} objective:** {objective}"
                )
            if files_raw:
                desc_parts.append(f"**Files:** {files_raw}")
            desc_parts.append(f"**Task:** {subject}")
            desc_parts.append("")
            desc_parts.append(context)
            if slug:
                desc_parts.append(f"**Plan reference:** [[work:{slug}]]")
            description = "\n".join(desc_parts)

            phase_tasks.append({
                "id": task_id,
                "subject": subject,
                "description": description,
                "activeForm": active_form,
                "blockedBy": list(prev_phase_task_ids),
                "file_targets": file_targets,
            })
            current_phase_task_ids.append(task_id)

        # Intra-phase ordering: chain tasks that share a file target
        file_last_task: dict[str, str] = {}  # file -> last task id targeting it
        for task in phase_tasks:
            for ft in task.get("file_targets", []):
                if ft in file_last_task:
                    prev_id = file_last_task[ft]
                    if prev_id not in task["blockedBy"]:
                        task["blockedBy"].append(prev_id)
                file_last_task[ft] = task["id"]

        phases.append({
            "phase_number": phase_num,
            "phase_name": phase_name,
            "objective": objective,
            "files": files,
            "tasks": phase_tasks,
        })
        prev_phase_task_ids = current_phase_task_ids

    return {
        "plan_checksum": plan_checksum,
        "generated_at": generated_at,
        "phases": phases,
    }


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

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
