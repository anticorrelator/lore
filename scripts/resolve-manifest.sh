#!/usr/bin/env bash
# resolve-manifest.sh — Resolve a phase's retrieval_directive into a ## Prior Knowledge bundle
# Usage: bash resolve-manifest.sh <slug> <phase_number>
#
# <slug>          Work item slug (must have a tasks.json in $KDIR/_work/<slug>/)
# <phase_number>  1-based phase index (must correspond to a phase in tasks.json)
#
# Stdout: A ## Prior Knowledge markdown block (--format prompt output from lore query),
#         or empty string when retrieval_directive is null or resolves no entries.
#
# Stderr: Diagnostic messages on error conditions.
# Exit 0: success (including null directive or zero results — those are not errors).
# Exit non-zero: missing tasks.json, invalid JSON, bad phase number, lore query failure.
#
# On each successful resolve (non-null directive, non-empty seeds), appends a manifest_load
# event to $KDIR/_meta/retrieval-log.jsonl. Fail-open: log write errors do not block stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Validate arguments ---
if [[ $# -lt 2 ]]; then
  echo "Usage: resolve-manifest.sh <slug> <phase_number>" >&2
  exit 1
fi

SLUG="$1"
PHASE_NUMBER="$2"

if ! [[ "$PHASE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$PHASE_NUMBER" -lt 1 ]]; then
  echo "Error: phase_number must be a positive integer, got: '$PHASE_NUMBER'" >&2
  exit 1
fi

# --- Resolve knowledge dir and tasks.json path ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
TASKS_FILE="$KNOWLEDGE_DIR/_work/$SLUG/tasks.json"

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: tasks.json not found for slug '$SLUG' (expected: $TASKS_FILE)" >&2
  exit 1
fi

# --- Extract retrieval_directive for the requested phase (0-based index) ---
PHASE_INDEX=$(( PHASE_NUMBER - 1 ))

DIRECTIVE_JSON=$(python3 - "$TASKS_FILE" "$PHASE_INDEX" <<'EXTRACT_PY'
import json, sys

tasks_file = sys.argv[1]
phase_index = int(sys.argv[2])

try:
    with open(tasks_file) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"Error: tasks.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

phases = data.get("phases", [])
if phase_index >= len(phases):
    print(f"Error: phase_number {phase_index + 1} out of range (tasks.json has {len(phases)} phases)", file=sys.stderr)
    sys.exit(1)

phase = phases[phase_index]
directive = phase.get("retrieval_directive")

# Output null as literal "null" (sentinel for bash)
if directive is None:
    print("null")
else:
    print(json.dumps(directive))
EXTRACT_PY
) || exit 1

# --- Null directive: clean exit with empty stdout ---
if [[ "$DIRECTIVE_JSON" == "null" ]]; then
  exit 0
fi

# --- Parse directive fields ---
SEEDS=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
seeds = d.get('seeds', [])
print(','.join(seeds))
" "$DIRECTIVE_JSON" 2>/dev/null || true)

HOP_BUDGET=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('hop_budget', 1))
" "$DIRECTIVE_JSON" 2>/dev/null || echo "1")

SCALE_SET=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
ss = d.get('scale_set', [])
print(','.join(ss) if ss else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

FILTER_TYPE=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
f = d.get('filters', {})
print(f.get('type', '') if isinstance(f, dict) else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

FILTER_EXCLUDE_CATEGORY=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
f = d.get('filters', {})
print(f.get('exclude_category', '') if isinstance(f, dict) else '')
" "$DIRECTIVE_JSON" 2>/dev/null || true)

# --- Empty seeds after parsing: treat as null directive ---
if [[ -z "$SEEDS" ]]; then
  exit 0
fi

# --- Build lore query args ---
QUERY_ARGS=("query" "--seeds" "$SEEDS" "--hop-budget" "$HOP_BUDGET")

if [[ -n "$SCALE_SET" ]]; then
  QUERY_ARGS+=("--scale-set" "$SCALE_SET")
fi
if [[ -n "$FILTER_TYPE" ]]; then
  QUERY_ARGS+=("--type" "$FILTER_TYPE")
fi
if [[ -n "$FILTER_EXCLUDE_CATEGORY" ]]; then
  QUERY_ARGS+=("--exclude-category" "$FILTER_EXCLUDE_CATEGORY")
fi

# --- Resolve to path list (for Phase 5 telemetry) ---
# Run with --format json to capture loaded_paths; suppress errors (telemetry is best-effort)
JSON_RESULT=$(lore "${QUERY_ARGS[@]}" --format json 2>/dev/null || true)

# Export loaded_paths for Phase 5 use when this script is sourced
if [[ -n "$JSON_RESULT" && "$JSON_RESULT" != "[]" ]]; then
  RESOLVE_MANIFEST_PATHS=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
if isinstance(data, dict) and 'full' in data:
    entries = data['full']
else:
    entries = data if isinstance(data, list) else []
paths = [e.get('path', e.get('file_path', '')) for e in entries if e.get('path') or e.get('file_path')]
print(','.join(p for p in paths if p))
" "$JSON_RESULT" 2>/dev/null || true)
  export RESOLVE_MANIFEST_PATHS
else
  export RESOLVE_MANIFEST_PATHS=""
fi

# --- Emit ## Prior Knowledge markdown bundle to stdout ---
PROMPT_OUTPUT=$(lore "${QUERY_ARGS[@]}" --format prompt 2>/dev/null || true)
if [[ -n "$PROMPT_OUTPUT" ]]; then
  printf '%s\n' "$PROMPT_OUTPUT"
fi

# --- Emit manifest_load telemetry event (fail-open) ---
python3 - "$KNOWLEDGE_DIR" "$SLUG" "$PHASE_NUMBER" "$RESOLVE_MANIFEST_PATHS" <<'LOG_PY'
import json, os, sys, datetime

knowledge_dir = sys.argv[1]
slug = sys.argv[2]
phase = int(sys.argv[3])
paths_csv = sys.argv[4]

log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
loaded_paths = [p for p in paths_csv.split(",") if p] if paths_csv else []

record = json.dumps({
    "timestamp": ts,
    "event": "manifest_load",
    "slug": slug,
    "phase": phase,
    "task_id": None,
    "loaded_paths": loaded_paths,
})

try:
    with open(log_path, "a") as lf:
        lf.write(record + "\n")
except OSError:
    pass
LOG_PY
