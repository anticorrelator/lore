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


def build_context_section(
    phase_backlinks: list[str],
    cross_cutting_backlinks: list[str],
    knowledge_dir: str,
    script_dir: str,
    task_backlinks: list[str] | None = None,
) -> str:
    """Build the context section for a task description.

    Task-level backlinks (from the individual checklist item) are resolved
    first and given priority within the char budget. Phase-level and
    cross-cutting backlinks fill remaining budget.
    """
    lines = [
        "## Context (resolve before starting)",
        'Resolve these with: lore resolve "<backlink>"',
        "",
    ]

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
            lines.append("--- Pre-resolved Knowledge ---")
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

        for item_text in unchecked:
            task_counter += 1
            task_id = f"task-{task_counter}"
            subject = item_text.strip()
            active_form = to_active_form(subject)

            # Extract file targets for intra-phase ordering
            file_targets = extract_file_targets(item_text, files)

            # Extract task-level backlinks from the checklist item
            task_backlinks = extract_task_backlinks(item_text)

            # Build context (task-level backlinks get priority)
            context = build_context_section(
                phase_backlinks, cross_cutting_backlinks,
                knowledge_dir, script_dir,
                task_backlinks=task_backlinks,
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
