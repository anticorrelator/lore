#!/usr/bin/env bash
# regen-tasks.sh — Regenerate tasks.json from plan.md for a work item
# Usage: bash regen-tasks.sh <slug>
# Calls generate-tasks.py, writes tasks.json, then heals the work index.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "[work] Error: Missing work item slug." >&2
  echo "Usage: regen-tasks.sh <slug>" >&2
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
  echo "[work] Error: Work item not found: $SLUG" >&2
  exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[work] Error: No plan.md found for: $SLUG" >&2
  echo "Run /spec first to create a plan." >&2
  exit 1
fi

# Generate tasks.json from plan.md
OUTPUT=$(python3 "$SCRIPT_DIR/generate-tasks.py" "$PLAN_FILE" \
  --knowledge-dir "$KNOWLEDGE_DIR" \
  --slug "$SLUG")

echo "$OUTPUT" > "$TASKS_FILE"

# Count tasks and phases from the generated JSON
TASK_COUNT=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(sum(len(p['tasks']) for p in d['phases']))")
PHASE_COUNT=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['phases']))")
CHECKSUM=$(echo "$OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['plan_checksum'][:8])")

echo "[work] Regenerated $TASK_COUNT tasks across $PHASE_COUNT phases. New checksum: $CHECKSUM"

# Update work index
bash "$SCRIPT_DIR/heal-work.sh"
