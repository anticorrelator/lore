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
# Staleness integration
# ---------------------------------------------------------------------------

# Staleness threshold for generating fix tasks (matches STALE_THRESHOLD in staleness-scan.py)
STALE_DRIFT_THRESHOLD = 0.6


def _find_repo_root() -> str:
    """Find the git repo root from cwd, or return cwd if not in a repo."""
    cwd = os.getcwd()
    d = cwd
    while True:
        if os.path.isdir(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return cwd
        d = parent


def _backlink_to_entry_path(backlink: str, knowledge_dir: str) -> str | None:
    """Map a knowledge backlink target to its absolute entry file path.

    Handles both category-file and category-dir/entry-file layouts.
    Returns None if no matching file found or if not a knowledge backlink.
    """
    # Only process knowledge-type backlinks
    if not backlink.startswith("knowledge:"):
        return None
    target = backlink.split(":", 1)[1]
    # Strip heading fragment
    if "#" in target:
        target = target.split("#", 1)[0]
    target = target.strip()
    if not target:
        return None

    # Try as a direct file: knowledge_dir/<target>.md
    candidate = os.path.join(knowledge_dir, target + ".md")
    if os.path.isfile(candidate):
        return candidate

    # Try as category dir: target may be "category/subcategory/entry-slug"
    # The file might be at knowledge_dir/category/subcategory/entry-slug.md
    candidate = os.path.join(knowledge_dir, target.replace("/", os.sep) + ".md")
    if os.path.isfile(candidate):
        return candidate

    return None


def scan_phase_knowledge_staleness(
    phase_backlinks: list[str],
    cross_cutting_backlinks: list[str],
    knowledge_dir: str,
    script_dir: str,
) -> list[dict]:
    """Scan knowledge entries referenced by phase backlinks for staleness.

    Returns list of dicts for stale entries: {path, rel_path, drift_score, status, signals, related_files}
    Only returns entries where file_drift is available (not confidence-only).
    """
    if not knowledge_dir:
        return []

    # Collect unique knowledge backlink targets
    all_bl = []
    seen = set()
    for bl in phase_backlinks + cross_cutting_backlinks:
        if bl not in seen and bl.startswith("knowledge:"):
            all_bl.append(bl)
            seen.add(bl)

    if not all_bl:
        return []

    # Import staleness functions (co-located in scripts/)
    # Module name has a hyphen, so use spec_from_file_location
    ss_path = os.path.join(script_dir, "staleness-scan.py")
    if not os.path.isfile(ss_path):
        return []
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("staleness_scan", ss_path)
        if spec is None or spec.loader is None:
            return []
        ss = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ss)
        parse_metadata = ss.parse_metadata
        compute_file_drift = ss.compute_file_drift
        compute_backlink_drift = ss.compute_backlink_drift
        score_entry = ss.score_entry
    except (ImportError, AttributeError, OSError):
        return []

    repo_root = _find_repo_root()
    stale_entries = []

    for bl in all_bl:
        entry_path = _backlink_to_entry_path(bl, knowledge_dir)
        if not entry_path or not os.path.isfile(entry_path):
            continue

        meta = parse_metadata(entry_path)
        file_drift = compute_file_drift(repo_root, meta["learned"], meta["related_files"])

        # Gate: only score entries where file_drift is available
        if not file_drift.get("available", False):
            continue

        backlink_drift = compute_backlink_drift(entry_path, knowledge_dir)
        drift_score, status, signals = score_entry(file_drift, backlink_drift, meta["confidence"])

        if drift_score >= STALE_DRIFT_THRESHOLD:
            try:
                rel_path = os.path.relpath(entry_path, knowledge_dir)
            except ValueError:
                rel_path = entry_path
            stale_entries.append({
                "path": rel_path,
                "abs_path": entry_path,
                "drift_score": drift_score,
                "status": status,
                "signals": signals,
                "related_files": meta["related_files"],
            })

    return stale_entries


def _build_fix_task_description(
    stale_entry: dict,
    phase_num: int,
    objective: str,
    slug: str,
) -> str:
    """Build a task description for fixing a stale knowledge entry."""
    path = stale_entry["path"]
    drift = stale_entry["drift_score"]
    signals = stale_entry["signals"]
    related = stale_entry["related_files"]

    # Build drift reason string
    reasons = []
    fd = signals.get("file_drift", {})
    if fd.get("available"):
        reasons.append(f"file drift: {fd['commit_count']} commits since learned date")
    bd = signals.get("backlink_drift", {})
    if bd.get("available") and bd.get("broken", 0) > 0:
        reasons.append(f"backlinks: {bd['broken']}/{bd['total']} broken")
    drift_reason = "; ".join(reasons) if reasons else "drift threshold exceeded"

    lines = []
    if objective:
        lines.append(f"**Phase {phase_num} objective:** {objective}")
    lines.append(f"**Task:** Update stale knowledge entry: `{path}`")
    lines.append(f"**Drift score:** {drift:.2f} ({drift_reason})")
    lines.append("")
    lines.append("**Instructions:**")
    lines.append(f"1. Read the knowledge entry at `{path}`")
    if related:
        lines.append("2. Read each related file listed below and compare claims to current code")
        lines.append("3. Rewrite the entry to match current behavior, preserving format (H1 title, prose, See also backlinks, HTML metadata comment)")
        lines.append("4. Update `learned` date to today and set `source: worker-fix` in the HTML metadata comment")
    else:
        lines.append("2. Verify claims against the codebase")
        lines.append("3. Rewrite stale content, preserving format")
        lines.append("4. Update `learned` date to today and set `source: worker-fix`")
    lines.append("")
    if related:
        lines.append("**Related files to check:**")
        for rf in related:
            lines.append(f"- `{rf}`")
        lines.append("")
    if slug:
        lines.append(f"**Plan reference:** [[work:{slug}]]")

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

        # Staleness scan: check knowledge entries referenced by this phase
        stale_entries = scan_phase_knowledge_staleness(
            phase_backlinks, cross_cutting_backlinks,
            knowledge_dir, script_dir,
        )
        for se in stale_entries:
            task_counter += 1
            fix_task_id = f"task-{task_counter}"
            fix_subject = f"Update stale knowledge entry: `{se['path']}`"
            fix_active = f"Updating stale knowledge entry: {se['path']}"
            fix_desc = _build_fix_task_description(
                se, phase_num, objective, slug,
            )
            phase_tasks.append({
                "id": fix_task_id,
                "subject": fix_subject,
                "description": fix_desc,
                "activeForm": fix_active,
                "blockedBy": list(prev_phase_task_ids),
                "file_targets": [se["path"]],
            })
            current_phase_task_ids.append(fix_task_id)

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
