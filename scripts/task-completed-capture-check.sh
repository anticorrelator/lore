#!/usr/bin/env bash
# task-completed-capture-check.sh — TaskCompleted hook
# Ensures workers in impl-*/spec-* teams include architectural findings in
# their completion reports before marking tasks done.
#
# Input: JSON on stdin (TaskCompleted hook format)
# Output: exit 0 to allow, exit 2 + stderr to block

set -euo pipefail

INPUT=$(cat)

# Extract team_name (may be null/absent)
TEAM_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('team_name') or '')")

# Fast exit: not a team task, or not an impl-/spec- team
if [[ -z "$TEAM_NAME" ]]; then
  exit 0
fi
case "$TEAM_NAME" in
  impl-*|spec-*) ;;
  *) exit 0 ;;
esac

# Check task_description for the required section
TASK_DESC=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('task_description') or '')")

if echo "$TASK_DESC" | grep -qF '**Architectural patterns:**'; then
  exit 0
fi

echo "Update the task description with your full completion report (including **Architectural patterns:** section) before marking complete." >&2
exit 2
