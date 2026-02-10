#!/usr/bin/env bash
# generate-tasks-from-plan.sh — Parse plan.md and output TaskCreate-compatible JSON
# Usage: bash generate-tasks-from-plan.sh <work-slug>
# Output: JSON array of task objects to stdout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Validate arguments ---
if [[ $# -lt 1 ]]; then
  echo "Usage: generate-tasks-from-plan.sh <work-slug>" >&2
  exit 1
fi

SLUG="$1"

# --- Resolve knowledge directory ---
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh")
PLAN_FILE="$KNOWLEDGE_DIR/_work/$SLUG/plan.md"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "Error: No plan.md found at: $PLAN_FILE" >&2
  exit 1
fi

PLAN_CONTENT=$(<"$PLAN_FILE")

# --- Extract cross-cutting backlinks from ## Related and ## Design Decisions ---
extract_backlinks() {
  local section_name="$1"
  local in_section=false
  local backlinks=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]+"$section_name" ]]; then
      in_section=true
      continue
    fi
    if $in_section && [[ "$line" =~ ^##[[:space:]] ]]; then
      break
    fi
    if $in_section; then
      # Extract [[...]] patterns from the line
      while [[ "$line" =~ \[\[([^\]]+)\]\] ]]; do
        local match="${BASH_REMATCH[1]}"
        if [[ -n "$backlinks" ]]; then
          backlinks="$backlinks"$'\n'"$match"
        else
          backlinks="$match"
        fi
        line="${line#*"${BASH_REMATCH[0]}"}"
      done
    fi
  done <<< "$PLAN_CONTENT"

  echo "$backlinks"
}

RELATED_BACKLINKS=$(extract_backlinks "Related")
DESIGN_BACKLINKS=$(extract_backlinks "Design Decisions")

# Combine cross-cutting backlinks (deduplicated)
CROSS_CUTTING_BACKLINKS=""
if [[ -n "$RELATED_BACKLINKS" ]] || [[ -n "$DESIGN_BACKLINKS" ]]; then
  CROSS_CUTTING_BACKLINKS=$(printf '%s\n%s' "$RELATED_BACKLINKS" "$DESIGN_BACKLINKS" | sort -u | sed '/^$/d')
fi

# --- Parse phases ---
# We'll use Python for robust JSON generation since jq can handle it but
# the parsing logic is complex enough to warrant a helper.

python3 - "$PLAN_FILE" "$KNOWLEDGE_DIR" "$SLUG" "$CROSS_CUTTING_BACKLINKS" "$SCRIPT_DIR" << 'PYTHON_SCRIPT'
import sys
import os
import re
import json
import subprocess

plan_file = sys.argv[1]
knowledge_dir = sys.argv[2]
slug = sys.argv[3]
cross_cutting_raw = sys.argv[4] if len(sys.argv) > 4 else ""
script_dir = sys.argv[5] if len(sys.argv) > 5 else ""
pk_search_path = os.path.join(script_dir, "pk_search.py") if script_dir else ""

RESOLVE_CHAR_LIMIT = 2000


def resolve_backlinks(backlinks, knowledge_dir):
    """Resolve a list of backlink strings via pk_search.py resolve.

    Returns a list of dicts with keys: backlink, resolved, content, error.
    """
    if not backlinks or not pk_search_path or not os.path.isfile(pk_search_path):
        return []
    # Format as [[type:target#heading]]
    formatted = [f"[[{bl}]]" if not bl.startswith("[[") else bl for bl in backlinks]
    try:
        result = subprocess.run(
            ["python3", pk_search_path, "resolve", knowledge_dir] + formatted + ["--json"],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        pass
    return []

with open(plan_file, 'r') as f:
    plan_content = f.read()

# Parse cross-cutting backlinks
cross_cutting_backlinks = [b.strip() for b in cross_cutting_raw.split('\n') if b.strip()]

# Split into phases
phase_pattern = re.compile(r'^### Phase (\d+):\s*(.*)', re.MULTILINE)
phase_matches = list(phase_pattern.finditer(plan_content))

tasks = []

for i, match in enumerate(phase_matches):
    phase_num = int(match.group(1))
    phase_title = match.group(2).strip()

    # Get phase content (from this header to the next phase header or end)
    start = match.end()
    if i + 1 < len(phase_matches):
        end = phase_matches[i + 1].start()
    else:
        # End at next ## heading or end of file
        next_h2 = re.search(r'^## ', plan_content[start:], re.MULTILINE)
        end = start + next_h2.start() if next_h2 else len(plan_content)

    phase_content = plan_content[start:end]

    # Extract objective
    obj_match = re.search(r'\*\*Objective:\*\*\s*(.*)', phase_content)
    objective = obj_match.group(1).strip() if obj_match else ""

    # Extract files
    files_match = re.search(r'\*\*Files:\*\*\s*(.*)', phase_content)
    files = files_match.group(1).strip() if files_match else ""

    # Extract knowledge context block (multiline)
    kc_match = re.search(
        r'\*\*Knowledge context:\*\*\s*\n((?:- .*\n?)*)',
        phase_content
    )
    phase_backlinks = []
    if kc_match:
        kc_block = kc_match.group(1)
        for bl_match in re.finditer(r'\[\[([^\]]+)\]\]', kc_block):
            phase_backlinks.append(bl_match.group(1))

    # Extract unchecked items
    unchecked_pattern = re.compile(r'^- \[ \]\s+(.*)', re.MULTILINE)
    unchecked_items = unchecked_pattern.findall(phase_content)

    if not unchecked_items:
        continue

    for item_text in unchecked_items:
        # Build subject: imperative title from checkbox text
        subject = item_text.strip()
        subject_clean = subject

        # Build activeForm: convert imperative to present continuous
        active_form = subject_clean
        words = active_form.split()
        if words:
            verb = words[0]
            rest = ' '.join(words[1:])

            # Explicit mapping for common verbs
            verb_map = {
                'Write': 'Writing', 'Create': 'Creating', 'Update': 'Updating',
                'Add': 'Adding', 'Remove': 'Removing', 'Delete': 'Deleting',
                'Fix': 'Fixing', 'Move': 'Moving', 'Replace': 'Replacing',
                'Test': 'Testing', 'Run': 'Running', 'Set': 'Setting',
                'Implement': 'Implementing', 'Extract': 'Extracting',
                'Refactor': 'Refactoring', 'Measure': 'Measuring',
                'Capture': 'Capturing', 'Decide': 'Deciding',
                'Configure': 'Configuring', 'Merge': 'Merging',
                'Split': 'Splitting', 'Verify': 'Verifying',
                'Check': 'Checking', 'Ensure': 'Ensuring',
                'Enable': 'Enabling', 'Disable': 'Disabling',
                'Install': 'Installing', 'Build': 'Building',
                'Deploy': 'Deploying', 'Parse': 'Parsing',
                'Generate': 'Generating', 'Validate': 'Validating',
                'Rename': 'Renaming', 'Consolidate': 'Consolidating',
                'Document': 'Documenting', 'Audit': 'Auditing',
            }

            if verb in verb_map:
                ing_verb = verb_map[verb]
            elif verb.lower().endswith('e') and not verb.lower().endswith('ee'):
                ing_verb = verb[:-1] + 'ing'
            elif re.match(r'^[A-Z][a-z]*[^aeiou]$', verb) and len(verb) <= 4:
                # Short CVC words: double final consonant (Run->Running, Set->Setting)
                ing_verb = verb + verb[-1] + 'ing'
            elif verb.lower().endswith('ing'):
                ing_verb = verb
            else:
                ing_verb = verb + 'ing'

            active_form = (ing_verb + ' ' + rest).strip()

        # Build context section
        context_lines = []
        context_lines.append("## Context (resolve before starting)")
        context_lines.append(f"Resolve these with: lore resolve \"<backlink>\"")
        context_lines.append("")

        has_phase_backlinks = bool(phase_backlinks)
        has_cross_cutting = bool(cross_cutting_backlinks)

        if has_phase_backlinks:
            context_lines.append("Phase-level:")
            for bl in phase_backlinks:
                context_lines.append(f"- [[{bl}]]")
            context_lines.append("")

        if has_cross_cutting:
            context_lines.append("Cross-cutting:")
            for bl in cross_cutting_backlinks:
                context_lines.append(f"- [[{bl}]]")
            context_lines.append("")

        if not has_phase_backlinks and not has_cross_cutting:
            context_lines.append("No backlinks found in plan.")
            context_lines.append("")

        # Pre-resolve backlinks and append content
        all_backlinks = list(phase_backlinks) + [
            bl for bl in cross_cutting_backlinks if bl not in phase_backlinks
        ]
        if all_backlinks:
            resolved_results = resolve_backlinks(all_backlinks, knowledge_dir)
            if resolved_results:
                resolved_lines = []
                resolved_lines.append("--- Pre-resolved Knowledge ---")
                resolved_lines.append("")
                total_chars = 0
                included = 0
                remaining = 0
                for r in resolved_results:
                    bl_label = r.get("backlink", "")
                    if r.get("resolved"):
                        content = r.get("content", "")
                        entry = f"**{bl_label}:**\n{content}"
                        entry_len = len(entry)
                        if total_chars + entry_len > RESOLVE_CHAR_LIMIT:
                            remaining = len(resolved_results) - included
                            break
                        resolved_lines.append(entry)
                        resolved_lines.append("")
                        total_chars += entry_len
                        included += 1
                    else:
                        error = r.get("error", "not found in knowledge store")
                        resolved_lines.append(f"**{bl_label}:** [unresolved — {error}]")
                        resolved_lines.append("")
                        included += 1
                if remaining > 0:
                    resolved_lines.append(f"[... truncated, {remaining} more entries]")
                    resolved_lines.append("")
                context_lines.extend(resolved_lines)

        # Build description
        desc_parts = []
        if objective:
            desc_parts.append(f"**Phase {phase_num} objective:** {objective}")
        if files:
            desc_parts.append(f"**Files:** {files}")
        desc_parts.append(f"**Task:** {subject}")
        desc_parts.append("")
        desc_parts.append('\n'.join(context_lines))
        desc_parts.append(f"**Plan reference:** [[work:{slug}]]")

        description = '\n'.join(desc_parts)

        task = {
            "subject": subject_clean,
            "description": description,
            "activeForm": active_form,
            "phase": phase_num
        }
        tasks.append(task)

print(json.dumps(tasks, indent=2))
PYTHON_SCRIPT
