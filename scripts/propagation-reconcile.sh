#!/usr/bin/env bash
# propagation-reconcile.sh — Backstop for the settlement → commons
# propagation-completeness invariant (D2).
#
# Scans `$KDIR/_settlement/runs/*.json` for contradicted runs scoped to a
# work item, joins each run by `settlement_run_id` against the three
# downstream sidecars, and — for any contradicted run that produced no
# downstream artifact — appends a propagation-miss row via the sole-writer
# `propagation-miss-append.sh`. Misses are EXPECTED OUTPUT, not an error.
#
# Invariant locked: every contradicted run record must eventually resolve
# to exactly one of:
#   - correction-candidates.jsonl (matching settlement_run_id), or
#   - filtered-claims.jsonl with stage=post-verdict (matching
#     settlement_run_id; pre-enqueue rows do NOT satisfy the invariant), or
#   - propagation-misses.jsonl (matching settlement_run_id).
#
# Idempotency: the sole-writer dedupes on sha256(settlement_run_id|reason).
# Running this script twice produces no duplicate miss rows.
#
# Usage:
#   propagation-reconcile.sh
#       --work-item <slug>
#       [--kdir <path>]
#       [--detector <name>]      # default: propagation-reconcile.sh
#       [--dry-run]
#       [-v|--verbose]
#
# Exit codes:
#   0 — scan completed (including when misses were appended).
#   1 — fatal IO error (missing work-item dir, missing runs dir,
#       unresolvable $KDIR, sole-writer failure).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: propagation-reconcile.sh \
           --work-item <slug> \
           [--kdir <path>] \
           [--detector <name>] \
           [--dry-run] \
           [-v|--verbose]

Scan contradicted settlement runs for a work item and append a
propagation-miss row for any run that produced no downstream artifact.
Sole-writer (propagation-miss-append.sh) handles dedupe.
EOF
}

WORK_ITEM=""
KDIR_OVERRIDE=""
DETECTOR="propagation-reconcile.sh"
DRY_RUN=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item) WORK_ITEM="$2";     shift 2 ;;
    --kdir)      KDIR_OVERRIDE="$2"; shift 2 ;;
    --detector)  DETECTOR="$2";      shift 2 ;;
    --dry-run)   DRY_RUN=1;          shift ;;
    -v|--verbose) VERBOSE=1;         shift ;;
    --help|-h)   usage; exit 0 ;;
    *)
      echo "[reconcile] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  echo "[reconcile] Error: $1" >&2
  exit 1
}

if [[ -z "$WORK_ITEM" ]]; then
  fail "--work-item is required"
fi

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"
if [[ ! -d "$WORK_DIR" ]]; then
  fail "work item not found: $WORK_ITEM (expected $WORK_DIR)"
fi

RUNS_DIR="$KNOWLEDGE_DIR/_settlement/runs"
if [[ ! -d "$RUNS_DIR" ]]; then
  fail "settlement runs directory not found: $RUNS_DIR"
fi

CORRECTION_CANDIDATES="$WORK_DIR/correction-candidates.jsonl"
FILTERED_CLAIMS="$WORK_DIR/filtered-claims.jsonl"
PROPAGATION_MISSES="$WORK_DIR/propagation-misses.jsonl"
TASK_CLAIMS="$WORK_DIR/task-claims.jsonl"

# Pass observable inputs through the env so the python join can read them.
export RUNS_DIR WORK_ITEM CORRECTION_CANDIDATES FILTERED_CLAIMS \
       PROPAGATION_MISSES TASK_CLAIMS
# LORE_SETTLEMENT_POST_HOOK is read inside python to derive hook_disabled.

# The classification step is JSON-heavy; hand the join off to python3 and
# read back a single JSON document with the missing-run descriptors plus
# satisfied counts. Following the bash-python hybrid pattern referenced
# in shell-script-conventions for JSON-heavy joins.
JOIN_JSON=$(python3 <<'PY_EOF'
import json, os, sys
from pathlib import Path

runs_dir = Path(os.environ["RUNS_DIR"])
work_item = os.environ["WORK_ITEM"]
correction = Path(os.environ["CORRECTION_CANDIDATES"])
filtered = Path(os.environ["FILTERED_CLAIMS"])
misses = Path(os.environ["PROPAGATION_MISSES"])
task_claims_path = Path(os.environ["TASK_CLAIMS"])
hook_env = os.environ.get("LORE_SETTLEMENT_POST_HOOK", "")


def load_jsonl(path):
    if not path.is_file():
        return []
    out = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def contradicted_runs():
    out = []
    if not runs_dir.is_dir():
        return out
    for entry in sorted(runs_dir.iterdir()):
        if entry.suffix != ".json":
            continue
        try:
            run = json.loads(entry.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(run, dict):
            continue
        if str(run.get("work_item") or "") != work_item:
            continue
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        if str(verdict.get("verdict") or "") != "contradicted":
            continue
        out.append(run)
    return out


correction_run_ids = {
    str(row.get("settlement_run_id") or "")
    for row in load_jsonl(correction)
    if row.get("settlement_run_id")
}

# Stage discriminator is load-bearing: pre-enqueue rows are NOT a satisfying
# signal for the post-verdict propagation-completeness invariant (D2).
post_verdict_filtered_run_ids = {
    str(row.get("settlement_run_id") or "")
    for row in load_jsonl(filtered)
    if row.get("stage") == "post-verdict" and row.get("settlement_run_id")
}

miss_run_ids = {
    str(row.get("settlement_run_id") or "")
    for row in load_jsonl(misses)
    if row.get("settlement_run_id")
}

claim_ids_in_task_claims = {
    str(row.get("claim_id") or "")
    for row in load_jsonl(task_claims_path)
    if row.get("claim_id")
}


def derive_reason(run):
    # 1. Hook entirely disabled in the live environment.
    if not hook_env:
        return "hook_disabled"
    # 2. Run record may carry an explicit hook-invocation signal once
    #    Phase 2 lands. Today, settlement-processor does not stamp this
    #    field; future runs may set hook_invoked / hook_error.
    if run.get("hook_invoked") is False:
        return "hook_disabled"
    if run.get("hook_error"):
        return "emit_failed"
    # 3. Tier-2 rehydration check: if the run's claim_id is not in the
    #    work item's task-claims.jsonl at reconcile time, the emit script
    #    could not have rehydrated.
    claim_id = str(run.get("claim_id") or "")
    if claim_id and claim_id not in claim_ids_in_task_claims:
        return "rehydration_failed"
    # 4. Default: the hook ran (or appears to have) but produced no
    #    downstream artifact — emit_failed.
    return "emit_failed"


satisfied = 0
missing = []
for run in contradicted_runs():
    run_id = str(run.get("run_id") or "")
    claim_id = str(run.get("claim_id") or "")
    if not run_id:
        continue
    if (
        run_id in correction_run_ids
        or run_id in post_verdict_filtered_run_ids
        or run_id in miss_run_ids
    ):
        satisfied += 1
        continue
    reason = derive_reason(run)
    missing.append({"run_id": run_id, "claim_id": claim_id, "reason": reason})

print(json.dumps({"satisfied": satisfied, "missing": missing}))
PY_EOF
) || fail "join step failed"

# Parse python output and either append or print, then build the summary.
SATISFIED=$(printf '%s' "$JOIN_JSON" | jq -r '.satisfied')
MISSING_COUNT=$(printf '%s' "$JOIN_JSON" | jq -r '.missing | length')

declare -i count_hook_disabled=0
declare -i count_emit_failed=0
declare -i count_rehydration_failed=0
declare -i count_hook_crashed=0

if [[ "$MISSING_COUNT" -gt 0 ]]; then
  # Stream missing entries via jq -c so each row is a self-contained JSON
  # object — avoids fragile whitespace splitting.
  while IFS= read -r row; do
    run_id=$(printf '%s' "$row" | jq -r '.run_id')
    claim_id=$(printf '%s' "$row" | jq -r '.claim_id')
    reason=$(printf '%s' "$row" | jq -r '.reason')

    case "$reason" in
      hook_disabled)      count_hook_disabled=$((count_hook_disabled + 1)) ;;
      emit_failed)        count_emit_failed=$((count_emit_failed + 1)) ;;
      rehydration_failed) count_rehydration_failed=$((count_rehydration_failed + 1)) ;;
      hook_crashed)       count_hook_crashed=$((count_hook_crashed + 1)) ;;
      *)
        fail "internal error: unrecognized derived reason '$reason' for run '$run_id'"
        ;;
    esac

    if [[ $VERBOSE -eq 1 ]]; then
      echo "[reconcile] missing run_id=$run_id claim_id=$claim_id reason=$reason"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
      continue
    fi

    if ! bash "$SCRIPT_DIR/propagation-miss-append.sh" \
        --work-item "$WORK_ITEM" \
        --settlement-run-id "$run_id" \
        --claim-id "$claim_id" \
        --reason "$reason" \
        --detector "$DETECTOR" \
        --kdir "$KNOWLEDGE_DIR" \
        >/dev/null; then
      fail "propagation-miss-append failed for run $run_id (reason=$reason)"
    fi
  done < <(printf '%s' "$JOIN_JSON" | jq -c '.missing[]')
fi

# Build the structured stderr summary.
BY_REASON=$(jq -nc \
  --argjson hd "$count_hook_disabled" \
  --argjson ef "$count_emit_failed" \
  --argjson rf "$count_rehydration_failed" \
  --argjson hc "$count_hook_crashed" \
  '{hook_disabled: $hd, emit_failed: $ef, rehydration_failed: $rf, hook_crashed: $hc}')

SUMMARY_JSON=$(jq -nc \
  --argjson sat "$SATISFIED" \
  --argjson miss "$MISSING_COUNT" \
  --argjson by "$BY_REASON" \
  '{satisfied: $sat, missing: $miss, by_reason: $by}')

# Human stdout summary.
echo "[reconcile] $WORK_ITEM: satisfied=$SATISFIED missing=$MISSING_COUNT by_reason={hook_disabled:$count_hook_disabled, emit_failed:$count_emit_failed, rehydration_failed:$count_rehydration_failed, hook_crashed:$count_hook_crashed}"

# Structured stderr summary for monitoring.
echo "RECONCILE_SUMMARY=$SUMMARY_JSON" >&2
