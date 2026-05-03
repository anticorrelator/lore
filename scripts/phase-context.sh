#!/usr/bin/env bash
# phase-context.sh — Fetch the phase_context field for a given phase from tasks.json
# Usage: bash phase-context.sh <slug> <phase-number>
#
# <slug>          Work item slug (must have a tasks.json in $KDIR/_work/<slug>/)
# <phase-number>  1-based phase index (positive integer)
#
# Stdout: The rendered phase brief (phase_context string), or empty if the phase
#         exists and phase_context is absent/null/empty (legacy fallback, per D4).
#
# Stderr: Diagnostic messages on error conditions.
# Exit 0: success — brief returned, or legacy-empty fallback (phase exists, field absent/null/empty).
# Exit 1: any real failure — slug not found, tasks.json missing/unreadable/malformed,
#         non-integer phase-number, phase-number out of range.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Validate arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: phase-context.sh <slug> <phase-number>" >&2
  exit 1
fi

SLUG="$1"
PHASE_NUMBER="$2"

if ! [[ "$PHASE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$PHASE_NUMBER" -lt 1 ]]; then
  echo "Error: phase-number must be a positive integer, got: '$PHASE_NUMBER'" >&2
  exit 1
fi

# --- Resolve knowledge dir and tasks.json path ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
TASKS_FILE="$WORK_ITEM_DIR/tasks.json"

if [[ ! -d "$WORK_ITEM_DIR" ]]; then
  echo "Error: work item not found: '$SLUG' (expected: $WORK_ITEM_DIR)" >&2
  exit 1
fi

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: tasks.json not found for slug '$SLUG' (expected: $TASKS_FILE)" >&2
  exit 1
fi

# --- Extract phase_context for the requested phase (0-based index) ---
PHASE_INDEX=$(( PHASE_NUMBER - 1 ))

python3 -c "
import json, sys

tasks_file = sys.argv[1]
phase_index = int(sys.argv[2])
phase_number = int(sys.argv[3])

try:
    with open(tasks_file) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f'Error: tasks.json is not valid JSON: {e}', file=sys.stderr)
    sys.exit(1)

phases = data.get('phases', [])
if phase_index >= len(phases):
    print(
        f'Error: phase_number {phase_number} out of range (tasks.json has {len(phases)} phase(s))',
        file=sys.stderr,
    )
    sys.exit(1)

phase = phases[phase_index]
phase_context = phase.get('phase_context')

# D4: exit 0 with empty stdout when field is absent, null, or empty (legacy fallback)
if not phase_context:
    sys.exit(0)

print(phase_context, end='')
" "$TASKS_FILE" "$PHASE_INDEX" "$PHASE_NUMBER"
