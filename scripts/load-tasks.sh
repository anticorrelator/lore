#!/usr/bin/env bash
# load-tasks.sh — Validate tasks.json checksum and output tasks as structured text
# Usage: bash load-tasks.sh <slug>
#
# Output format (one block per task, delimited by === task-N ===):
#   [tasks] N tasks across M phases | checksum: <short> MATCH
#
#   === task-1 ===
#   subject: ...
#   activeForm: ...
#   blockedBy: none | task-2, task-3
#   ---
#   <description>
#
# On checksum mismatch, exits with status 1 after printing a warning.
# The model reads this output once and fires TaskCreate calls without further probing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "[load-tasks] Error: Missing work item slug." >&2
  echo "Usage: load-tasks.sh <slug>" >&2
  exit 1
fi

SLUG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
PLAN_FILE="$WORK_ITEM_DIR/plan.md"
TASKS_FILE="$WORK_ITEM_DIR/tasks.json"

if [[ ! -d "$WORK_ITEM_DIR" ]]; then
  echo "[load-tasks] Error: Work item not found: $SLUG" >&2
  exit 1
fi

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "[load-tasks] Error: No tasks.json found for: $SLUG" >&2
  echo "Run: lore work tasks $SLUG" >&2
  exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[load-tasks] Error: No plan.md found for: $SLUG" >&2
  exit 1
fi

python3 - "$TASKS_FILE" "$PLAN_FILE" "$SLUG" << 'PYTHON'
import json
import sys
import hashlib

tasks_file = sys.argv[1]
plan_file = sys.argv[2]
slug = sys.argv[3]

with open(tasks_file) as f:
    data = json.load(f)

with open(plan_file, 'rb') as f:
    plan_checksum = hashlib.sha256(f.read()).hexdigest()

stored_checksum = data.get("plan_checksum", "")
checksum_short = stored_checksum[:8] if stored_checksum else "none"
match_label = "MATCH" if plan_checksum == stored_checksum else "MISMATCH"

phases = data.get("phases", [])
total_tasks = sum(len(p.get("tasks", [])) for p in phases)
phase_count = len(phases)

if match_label == "MISMATCH":
    print(f"[load-tasks] WARNING: Checksum mismatch — plan.md was edited after tasks.json was generated.")
    print(f"  Stored:  {stored_checksum[:16]}...")
    print(f"  Current: {plan_checksum[:16]}...")
    print(f"  Run: lore work regen-tasks {slug}")
    sys.exit(1)

print(f"[tasks] {total_tasks} tasks across {phase_count} phases | checksum: {checksum_short} {match_label}")
print()

for phase in phases:
    phase_num = phase.get("phase_number", "?")
    phase_name = phase.get("phase_name", "")
    tasks = phase.get("tasks", [])
    if not tasks:
        continue
    print(f"=== Phase {phase_num}: {phase_name} ===")
    print()
    for task in tasks:
        tid = task.get("id", "")
        subject = task.get("subject", "")
        active_form = task.get("activeForm", "")
        blocked_by = task.get("blockedBy", [])
        description = task.get("description", "")

        blocked_str = ", ".join(blocked_by) if blocked_by else "none"

        print(f"=== {tid} ===")
        print(f"subject: {subject}")
        print(f"activeForm: {active_form}")
        print(f"blockedBy: {blocked_str}")
        print("---")
        print(description)
        print()
PYTHON
