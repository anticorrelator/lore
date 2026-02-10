#!/usr/bin/env bash
# update-plan-checkbox.sh — Check off a completed task in plan.md
# Usage: bash update-plan-checkbox.sh <work-slug> <task-subject>
# Output: Prints matched line before/after to stdout
#
# Matching strategy:
#   1. Exact substring match (case-insensitive)
#   2. Significant-word match (ignore articles/prepositions)
#   3. Error if ambiguous (multiple matches) or no match

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Validate arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: update-plan-checkbox.sh <work-slug> <task-subject>" >&2
  exit 1
fi

WORK_SLUG="$1"
shift
TASK_SUBJECT="$*"

# --- Resolve knowledge directory ---
KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh")
PLAN_FILE="$KNOWLEDGE_DIR/_work/$WORK_SLUG/plan.md"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "Error: plan.md not found at: $PLAN_FILE" >&2
  exit 1
fi

# --- Use Python for robust matching and update ---
python3 - "$PLAN_FILE" "$TASK_SUBJECT" << 'PYTHON_SCRIPT'
import sys
import re

plan_file = sys.argv[1]
task_subject = sys.argv[2]

with open(plan_file, 'r') as f:
    lines = f.readlines()

# Collect all checkbox lines with their indices
unchecked = []  # (line_index, line_text_after_checkbox)
checked = []    # (line_index, line_text_after_checkbox)

for i, line in enumerate(lines):
    m_unchecked = re.match(r'^(\s*- \[ \] )(.*)', line)
    m_checked = re.match(r'^(\s*- \[x\] )(.*)', line)
    if m_unchecked:
        unchecked.append((i, m_unchecked.group(2).strip()))
    elif m_checked:
        checked.append((i, m_checked.group(2).strip()))

# Check if already checked (idempotent)
for idx, text in checked:
    if task_subject.lower() in text.lower():
        print(f"Already checked: {text}")
        sys.exit(0)

# Strategy 1: exact substring match (case-insensitive)
matches = [(idx, text) for idx, text in unchecked if task_subject.lower() in text.lower()]

# Strategy 2: significant-word match if no exact substring match
if not matches:
    stop_words = {'a', 'an', 'the', 'in', 'on', 'at', 'to', 'for', 'of', 'with',
                  'by', 'from', 'and', 'or', 'but', 'is', 'are', 'was', 'were',
                  'be', 'been', 'being', 'have', 'has', 'had', 'do', 'does', 'did',
                  'it', 'its', 'that', 'this', 'these', 'those'}

    def significant_words(text):
        words = re.findall(r'[a-z0-9]+', text.lower())
        return set(w for w in words if w not in stop_words and len(w) > 1)

    subject_words = significant_words(task_subject)
    if subject_words:
        for idx, text in unchecked:
            line_words = significant_words(text)
            # Match if all significant words from subject appear in line
            if subject_words.issubset(line_words):
                matches.append((idx, text))

# Handle results
if not matches:
    print(f"Error: No matching unchecked item found for: {task_subject}", file=sys.stderr)
    if unchecked:
        print("\nAvailable unchecked items:", file=sys.stderr)
        for _, text in unchecked:
            print(f"  - [ ] {text}", file=sys.stderr)
    else:
        print("\nNo unchecked items remain in plan.md", file=sys.stderr)
    sys.exit(1)

if len(matches) > 1:
    print(f"Error: Ambiguous match for: {task_subject}", file=sys.stderr)
    print(f"\nMultiple matches found ({len(matches)}):", file=sys.stderr)
    for _, text in matches:
        print(f"  - [ ] {text}", file=sys.stderr)
    print("\nProvide a more specific subject to disambiguate.", file=sys.stderr)
    sys.exit(1)

# Single match — update the line
match_idx, match_text = matches[0]
old_line = lines[match_idx]
new_line = re.sub(r'^(\s*)- \[ \] ', r'\1- [x] ', old_line)
lines[match_idx] = new_line

with open(plan_file, 'w') as f:
    f.writelines(lines)

print(f"Before: {old_line.rstrip()}")
print(f"After:  {new_line.rstrip()}")
PYTHON_SCRIPT
