#!/usr/bin/env bash
# resolve-manifest.sh — Resolve a retrieval_directive into a ## Prior Knowledge bundle
# Usage: bash resolve-manifest.sh <slug> --task-id <id> [--delivery-json <path>]
#        bash resolve-manifest.sh <slug> <phase_number> [--task-id <id>] [--delivery-json <path>]
#
# <slug>          Work item slug (must have a tasks.json in $KDIR/_work/<slug>/)
# <phase_number>  Phase number as declared in tasks.json, for a plan whose
#                 tasks.json carries phases[]
# --task-id       The task this resolve serves. Without a <phase_number> it also
#                 selects the directive: the task's own retrieval_directive when
#                 tasks.json carries a top-level tasks[], otherwise the directive
#                 of the phase holding that task. With a <phase_number> it only
#                 attributes the telemetry, for a directive several tasks share.
# --delivery-json Write a per-entry delivery snapshot (render mode + trust at
#                 delivery) as JSON to this path (v2 directives only) — input
#                 for packet emission; stdout is unchanged
#
# Stdout: A ## Prior Knowledge markdown block.
#   - Legacy flat directive: passes through `lore query --format prompt` (single section).
#   - v2 directive (version: 2): fans out one BM25 OR query per topic via `lore query --json`,
#     emits sectioned `### Focal: <topic>` / `### Adjacent: <topic>` blocks with per-section
#     budgeting, full→snippet→backlink degradation, and per-section telemetry.
#
# Stderr: Diagnostic messages on error conditions.
# Exit 0: success
# Exit non-zero: missing tasks.json, invalid JSON, unknown task id or phase number,
#                null directive, empty seeds (legacy), missing scale_set (legacy),
#                v2 invariants violated.
#
# On each successful resolve, appends a manifest_load event to $KDIR/_meta/retrieval-log.jsonl.
# Fail-open: log write errors do not block stdout. v2 records per-section fields (topic,
# section_role, requested_k, raw_count, served_count, deduped_count, served_paths, chars_used,
# chars_budget, render_mode_counts, content_degraded, shrunk_for_budget, entry_count_before_budget)
# and per-call records add query_kind (topic|activity).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Validate arguments ---
USAGE="Usage: resolve-manifest.sh <slug> --task-id <id> [--delivery-json <path>]
       resolve-manifest.sh <slug> <phase_number> [--task-id <id>] [--delivery-json <path>]"

if [[ $# -lt 2 ]]; then
  echo "Error: a work-item slug and either --task-id <id> or a phase number are required." >&2
  echo "$USAGE" >&2
  exit 1
fi

SLUG="$1"
shift

PHASE_NUMBER=""
TASK_ID=""
DELIVERY_JSON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      TASK_ID="${2:-}"
      shift 2
      ;;
    --task-id=*)
      TASK_ID="${1#--task-id=}"
      shift
      ;;
    --delivery-json)
      DELIVERY_JSON="${2:-}"
      shift 2
      ;;
    --delivery-json=*)
      DELIVERY_JSON="${1#--delivery-json=}"
      shift
      ;;
    -*)
      echo "Error: unknown flag '$1'. Accepted flags are --task-id and --delivery-json." >&2
      echo "$USAGE" >&2
      exit 1
      ;;
    *)
      if [[ -n "$PHASE_NUMBER" ]]; then
        echo "Error: unexpected extra argument '$1'; at most one phase number is accepted." >&2
        echo "$USAGE" >&2
        exit 1
      fi
      PHASE_NUMBER="$1"
      shift
      ;;
  esac
done

if [[ -n "$PHASE_NUMBER" ]]; then
  if ! [[ "$PHASE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$PHASE_NUMBER" -lt 1 ]]; then
    echo "Error: the phase number must be a positive integer, got '$PHASE_NUMBER'." >&2
    echo "$USAGE" >&2
    exit 1
  fi
elif [[ -z "$TASK_ID" ]]; then
  echo "Error: nothing to resolve — pass --task-id <id> to resolve the directive a task declares, or a phase number to resolve one a phase declares." >&2
  echo "$USAGE" >&2
  exit 1
fi

# Names the unit this resolve is addressed to, for every diagnostic below.
if [[ -n "$PHASE_NUMBER" ]]; then
  UNIT_LABEL="phase $PHASE_NUMBER"
else
  UNIT_LABEL="task $TASK_ID"
fi

# --- Resolve knowledge dir and tasks.json path ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
TASKS_FILE="$KNOWLEDGE_DIR/_work/$SLUG/tasks.json"

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "Error: tasks.json not found for slug '$SLUG' (expected: $TASKS_FILE)" >&2
  exit 1
fi

# --- Extract the retrieval_directive the addressed unit declares -------------
DIRECTIVE_JSON=$(python3 - "$TASKS_FILE" "$SLUG" "$PHASE_NUMBER" "$TASK_ID" <<'EXTRACT_PY'
import json, sys

tasks_file, slug, phase_number, task_id = sys.argv[1:5]

try:
    with open(tasks_file) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f"Error: tasks.json is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

flat = data.get("tasks")
phases = data.get("phases")
have_flat = isinstance(flat, list)
have_phases = isinstance(phases, list)

if not have_flat and not have_phases:
    print(
        f"Error: tasks.json for '{slug}' declares neither a top-level tasks array "
        f"nor a phases array, so there is nothing to resolve. Regenerate it with: "
        f"lore work regen-tasks {slug}",
        file=sys.stderr,
    )
    sys.exit(1)

if phase_number:
    if not have_phases:
        print(
            f"Error: tasks.json for '{slug}' has no phases array, so phase "
            f"{phase_number} names nothing. Address the unit by its task instead: "
            f"--task-id <id>",
            file=sys.stderr,
        )
        sys.exit(1)
    wanted = int(phase_number)
    declared = [p.get("phase_number") for p in phases]
    matches = [p for p in phases if p.get("phase_number") == wanted]
    if matches:
        owner = matches[0]
    elif not any(n is not None for n in declared):
        # No phase names its own number, so position is the only identity the
        # document offers and the request is read as a 1-based index.
        if wanted > len(phases):
            print(
                f"Error: '{slug}' has {len(phases)} phase(s), so phase {wanted} "
                f"names nothing.",
                file=sys.stderr,
            )
            sys.exit(1)
        owner = phases[wanted - 1]
    else:
        present = ", ".join(str(n) for n in declared if n is not None)
        print(
            f"Error: '{slug}' declares no phase {wanted} (phases present: {present}).",
            file=sys.stderr,
        )
        sys.exit(1)
else:
    # tasks[] is authoritative when present; otherwise the task is located in
    # phases[] and the phase holding it owns the directive.
    owner = None
    if have_flat:
        owner = next((t for t in flat if t.get("id") == task_id), None)
    if owner is None and have_phases:
        for phase in phases:
            if any(t.get("id") == task_id for t in phase.get("tasks", [])):
                owner = phase
                break
    if owner is None:
        print(
            f"Error: '{slug}' has no task '{task_id}'. Check the task id against "
            f"tasks.json, or regenerate it with: lore work regen-tasks {slug}",
            file=sys.stderr,
        )
        sys.exit(1)

directive = owner.get("retrieval_directive")

if directive is None:
    print("null")
else:
    print(json.dumps(directive))
EXTRACT_PY
) || exit 1

if [[ "$DIRECTIVE_JSON" == "null" ]]; then
  echo "Error: $UNIT_LABEL of '$SLUG' has no retrieval_directive; a scale-declared directive is required." >&2
  exit 1
fi

# --- Branch on directive version ---
DIRECTIVE_VERSION=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('version', 1))
" "$DIRECTIVE_JSON" 2>/dev/null || echo "1")

if [[ "$DIRECTIVE_VERSION" == "2" ]]; then
  # v2 grouped path — per-topic fan-out, sectioned output, per-section
  # budgets/degradation/telemetry. All of it lives in pk_manifest.py
  # (dispatched via pk_cli.py), composing Searcher + pk_retrieval.
  V2_ARGS=(--directive "$DIRECTIVE_JSON" --slug "$SLUG")
  [[ -n "$PHASE_NUMBER" ]] && V2_ARGS+=(--phase "$PHASE_NUMBER")
  [[ -n "$TASK_ID" ]] && V2_ARGS+=(--task-id "$TASK_ID")
  [[ -n "$DELIVERY_JSON" ]] && V2_ARGS+=(--delivery-json "$DELIVERY_JSON")
  python3 "$SCRIPT_DIR/pk_cli.py" resolve-manifest "$KNOWLEDGE_DIR" "${V2_ARGS[@]}"
  exit $?
fi

# ============================================================
# Legacy flat path — single `lore query` call, single section
# ============================================================

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

if [[ -z "$SEEDS" ]]; then
  echo "Error: $UNIT_LABEL of '$SLUG' has a retrieval_directive with no seeds; seeds are required." >&2
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: $UNIT_LABEL of '$SLUG' has a retrieval_directive with no scale_set; declare a scale before fetching." >&2
  exit 1
fi

QUERY_ARGS=("query" "--seeds" "$SEEDS" "--hop-budget" "$HOP_BUDGET" "--scale-set" "$SCALE_SET")
if [[ -n "$FILTER_TYPE" ]]; then
  QUERY_ARGS+=("--type" "$FILTER_TYPE")
fi
if [[ -n "$FILTER_EXCLUDE_CATEGORY" ]]; then
  QUERY_ARGS+=("--exclude-category" "$FILTER_EXCLUDE_CATEGORY")
fi

JSON_RESULT=$(lore "${QUERY_ARGS[@]}" --format json 2>/dev/null || true)

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

PROMPT_OUTPUT=$(lore "${QUERY_ARGS[@]}" --format prompt 2>/dev/null || true)
if [[ -n "$PROMPT_OUTPUT" ]]; then
  printf '%s\n' "$PROMPT_OUTPUT"
fi

# Legacy telemetry: manifest_load event without per-section fields.
python3 - "$KNOWLEDGE_DIR" "$SLUG" "$PHASE_NUMBER" "$RESOLVE_MANIFEST_PATHS" "$TASK_ID" <<'LOG_PY'
import json, os, sys, datetime

knowledge_dir = sys.argv[1]
slug = sys.argv[2]
phase = int(sys.argv[3]) if sys.argv[3] else None
paths_csv = sys.argv[4]
task_id = sys.argv[5] or None

log_path = os.path.join(knowledge_dir, "_meta", "retrieval-log.jsonl")
os.makedirs(os.path.dirname(log_path), exist_ok=True)

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
loaded_paths = [p for p in paths_csv.split(",") if p] if paths_csv else []

record = json.dumps({
    "timestamp": ts,
    "event": "manifest_load",
    "slug": slug,
    "phase": phase,
    "task_id": task_id,
    "manifest_version": 1,
    "loaded_paths": loaded_paths,
})

try:
    with open(log_path, "a") as lf:
        lf.write(record + "\n")
except OSError:
    pass
LOG_PY
