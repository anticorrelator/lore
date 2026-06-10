#!/usr/bin/env bash
# drift-sweep.sh — orchestrate proactive commons drift re-enqueue.
#
# Runs drift-sweep.py to detect committed-entry drift against each entry's
# captured_at_sha, then for each drifted+parseable entry:
#   (1) ensures a promoted-commons.jsonl producer row exists (synthesizing one
#       via promote-commons-append.sh when absent — never hand-writing the file),
#   (2) enqueues a commons settlement item via settlement-queue.sh enqueue
#       --kind commons (the same call lore-promote.sh makes at promotion time).
#
# drift-sweep builds no terminus and no correction path — it is a *producer* for
# the existing commons settlement chain. It writes nothing directly: the only
# side effects are the two writer-script calls above.
#
# Synthesized producer rows are filed under this work item's own
# promoted-commons.jsonl; the entry_path on each row carries flowback authority
# back to the drifted entry.
#
# Usage:
#   drift-sweep.sh [--dry-run] [--json] [--category NAME]... [--repo-root PATH]
#
# Exit codes:
#   0  a report was produced (including all-skipped / all-unparseable runs)
#   1  operational failure (git error, or a writer-script non-zero exit)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Work item that owns synthesized producer rows + their queue items.
WORK_ITEM="proactive-drift-sweep-re-hash-commons-snippets-vs"

DRY_RUN=0
JSON=0
REPO_ROOT=""
CATEGORY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --json)    JSON=1; shift ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --category) CATEGORY_ARGS+=(--category "$2"); shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "[drift-sweep] Unknown argument: $1" >&2
      echo "Usage: drift-sweep.sh [--dry-run] [--json] [--category NAME]... [--repo-root PATH]" >&2
      exit 1
      ;;
  esac
done

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "[drift-sweep] knowledge store not found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

# Default the git baseline repo to cwd (the source checkout) when not given.
REPO_ROOT="${REPO_ROOT:-$(pwd)}"

PLANNER="$SCRIPT_DIR/drift-sweep.py"
APPEND="$SCRIPT_DIR/promote-commons-append.sh"
QUEUE="$SCRIPT_DIR/settlement-queue.sh"

# --- Run the planner (JSON report; no side effects) ---
# Empty-array expansion is unbound under `set -u`, so expand only when populated.
set +e
PLAN_JSON=$(python3 "$PLANNER" "$KNOWLEDGE_DIR" --repo-root "$REPO_ROOT" "${CATEGORY_ARGS[@]+"${CATEGORY_ARGS[@]}"}" --json)
PLAN_EXIT=$?
set -e
if [[ $PLAN_EXIT -ne 0 ]]; then
  # Planner already emitted its diagnostic to stderr.
  exit 1
fi

PRODUCER_FILE="$KNOWLEDGE_DIR/_work/$WORK_ITEM/promoted-commons.jsonl"

# Realize side effects for each drifted+parseable entry. Per-entry, the planner
# decided drift; here we resolve producer_row + enqueue states (and perform the
# writes unless --dry-run). The augmented per-entry states are emitted as JSONL
# on fd 3 and re-collected into the final report.
exec 3>/tmp/drift-sweep-states.$$.jsonl

cleanup() {
  rm -f "/tmp/drift-sweep-states.$$.jsonl" \
        "/tmp/drift-append.$$.err" \
        "/tmp/drift-enqueue.$$.err"
}
trap cleanup EXIT

# Drive one entry at a time through Python (to read its synthesized_payload) +
# the writer scripts (bash). We iterate entry_paths the planner marked drifted
# with a synthesized_payload; everything else keeps the planner's states.
DRIFTED_PARSEABLE=$(printf '%s' "$PLAN_JSON" | python3 -c '
import json, sys
report = json.load(sys.stdin)
for row in report["entries"]:
    if row.get("drifted") and row.get("synthesized_payload"):
        print(row["entry_path"])
')

OP_FAILURE=0
while IFS= read -r ENTRY_PATH; do
  [[ -n "$ENTRY_PATH" ]] || continue

  # Pull this entry's synthesized payload and its deterministic claim_id.
  PAYLOAD=$(printf '%s' "$PLAN_JSON" | python3 -c '
import json, sys
target = sys.argv[1]
report = json.load(sys.stdin)
for row in report["entries"]:
    if row.get("entry_path") == target:
        print(json.dumps(row["synthesized_payload"]))
        break
' "$ENTRY_PATH")

  # Existing-row lookup: a producer row counts as `existing` when its entry_path
  # matches this entry, regardless of claim_id. If one exists we skip synthesis
  # but still enqueue (the queue dedupes on the row's own claim_id identity).
  ROW_FOR_ENQUEUE="$PAYLOAD"
  PRODUCER_STATE="synthesized"
  if [[ -f "$PRODUCER_FILE" ]]; then
    EXISTING_ROW=$(python3 -c '
import json, sys
target, path = sys.argv[1], sys.argv[2]
match = None
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(row, dict) and row.get("entry_path") == target:
            match = row  # latest wins
print(json.dumps(match) if match is not None else "")
' "$ENTRY_PATH" "$PRODUCER_FILE")
    if [[ -n "$EXISTING_ROW" ]]; then
      PRODUCER_STATE="existing"
      ROW_FOR_ENQUEUE="$EXISTING_ROW"
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    [[ "$PRODUCER_STATE" == "existing" ]] && PSTATE="existing" || PSTATE="would_synthesize"
    printf '%s\n' "$(python3 -c '
import json, sys
print(json.dumps({"entry_path": sys.argv[1], "producer_row": sys.argv[2], "enqueue": "would_queue"}))
' "$ENTRY_PATH" "$PSTATE")" >&3
    continue
  fi

  # (a) Synthesize the producer row when none exists. FAIL-CLOSED: the row
  # carries the falsifier, so a rejected append aborts this entry's enqueue.
  if [[ "$PRODUCER_STATE" == "synthesized" ]]; then
    if ! printf '%s' "$PAYLOAD" \
      | "$APPEND" --work-item "$WORK_ITEM" --entry-path "$ENTRY_PATH" --kdir "$KNOWLEDGE_DIR" >/dev/null 2>"/tmp/drift-append.$$.err"; then
      echo "[drift-sweep] producer-row append failed for $ENTRY_PATH:" >&2
      cat "/tmp/drift-append.$$.err" >&2
      rm -f "/tmp/drift-append.$$.err"
      OP_FAILURE=1
      printf '%s\n' "$(python3 -c '
import json, sys
print(json.dumps({"entry_path": sys.argv[1], "producer_row": "error", "enqueue": "skipped"}))
' "$ENTRY_PATH")" >&3
      continue
    fi
    rm -f "/tmp/drift-append.$$.err"
  fi

  # (b) Enqueue a commons settlement item. The queue dedupes on
  # commons:{work_item}:{claim_id}, so a re-run with the same deterministic
  # claim_id reports action=duplicate and adds nothing.
  set +e
  ENQUEUE_OUT=$(printf '%s' "$ROW_FOR_ENQUEUE" \
    | "$QUEUE" enqueue --work-item "$WORK_ITEM" --kind commons --kdir "$KNOWLEDGE_DIR" --json 2>"/tmp/drift-enqueue.$$.err")
  ENQUEUE_EXIT=$?
  set -e
  if [[ $ENQUEUE_EXIT -ne 0 ]]; then
    echo "[drift-sweep] enqueue failed for $ENTRY_PATH:" >&2
    cat "/tmp/drift-enqueue.$$.err" >&2
    rm -f "/tmp/drift-enqueue.$$.err"
    OP_FAILURE=1
    printf '%s\n' "$(python3 -c '
import json, sys
print(json.dumps({"entry_path": sys.argv[1], "producer_row": sys.argv[2], "enqueue": "error"}))
' "$ENTRY_PATH" "$PRODUCER_STATE")" >&3
    continue
  fi
  rm -f "/tmp/drift-enqueue.$$.err"

  ACTION=$(printf '%s' "$ENQUEUE_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("action",""))')
  case "$ACTION" in
    enqueued) ENQ_STATE="queued" ;;
    duplicate) ENQ_STATE="deduped" ;;
    *) ENQ_STATE="skipped" ;;
  esac
  printf '%s\n' "$(python3 -c '
import json, sys
print(json.dumps({"entry_path": sys.argv[1], "producer_row": sys.argv[2], "enqueue": sys.argv[3]}))
' "$ENTRY_PATH" "$PRODUCER_STATE" "$ENQ_STATE")" >&3

done <<< "$DRIFTED_PARSEABLE"

exec 3>&-

# --- Merge realized states back into the report and render ---
STATES_FILE="/tmp/drift-sweep-states.$$.jsonl"
[[ -f "$STATES_FILE" ]] || : > "$STATES_FILE"

FINAL_REPORT=$(printf '%s' "$PLAN_JSON" | python3 -c '
import json, sys
report = json.load(sys.stdin)
states = {}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        s = json.loads(line)
        states[s["entry_path"]] = s
for row in report["entries"]:
    s = states.get(row["entry_path"])
    if s:
        row["producer_row"] = s["producer_row"]
        row["enqueue"] = s["enqueue"]
report["dry_run"] = bool(int(sys.argv[2]))
print(json.dumps(report, sort_keys=True))
' "$STATES_FILE" "$DRY_RUN")

if [[ $JSON -eq 1 ]]; then
  printf '%s\n' "$FINAL_REPORT"
else
  printf '%s' "$FINAL_REPORT" | python3 -c '
import json, sys
report = json.load(sys.stdin)
dry_tag = " (dry-run)" if report.get("dry_run") else ""
head = report.get("head", "")[:12]
print("drift-sweep: scanned {} entries in {} @ {}{}".format(
    report["scanned"], report["repo_root"], head, dry_tag))
print("  drifted: {}".format(report["drifted_count"]))
for row in report["entries"]:
    if not row.get("drifted"):
        continue
    files = ", ".join("{}={}".format(f["path"], f["drift_class"]) for f in row.get("files", []))
    sha = (row.get("captured_at_sha") or "")[:12]
    print("  - {}".format(row["entry_path"]))
    print("      sha={} files=[{}]".format(sha, files))
    claim_tag = " claim_id={}".format(row["claim_id"]) if row.get("claim_id") else ""
    print("      producer_row={} enqueue={}{}".format(
        row.get("producer_row"), row.get("enqueue"), claim_tag))
    if row.get("unparseable"):
        print("      unparseable: {}".format(row.get("skip_reason", "")))
'
fi

if [[ $OP_FAILURE -ne 0 ]]; then
  exit 1
fi
exit 0
