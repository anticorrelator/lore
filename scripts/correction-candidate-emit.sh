#!/usr/bin/env bash
# correction-candidate-emit.sh — Settlement post-verdict hook: emit
# correction-candidate rows (or report-only filtered-claim rows) for a
# `contradicted` verdict by resolving the originating Tier-2 task_claim
# against the knowledge commons via find-correction-targets.sh --json.
#
# Hook contract (D2):
#   * Settlement invokes this script via $LORE_SETTLEMENT_POST_HOOK after
#     write_run_record_once when verdict == "contradicted".
#   * Stdin is a single JSON object `{run, item, task_claim}` where:
#       - run         — the run record just written
#       - item        — the dequeued settlement item that produced the run
#       - task_claim  — the rehydrated Tier-2 row keyed by claim_id; the run
#                       record alone is never the payload.
#   * Settlement guarantees verdict == "contradicted" before invoking the
#     hook (verified/unverified/skipped/error verdicts bypass the hook
#     entirely). This script does not re-check the verdict.
#
# Dispatch:
#   1. Call find-correction-targets.sh --json with the task_claim's
#      claim/file/line_range.
#   2. If targets is non-empty: emit one correction-candidate row per
#      target via correction-candidate-append.sh.
#   3. If targets is empty and index_state == "ready": emit ONE
#      filtered-claim row (stage=post-verdict, reason=no-discoverable-target,
#      mode=report-only) via filtered-claim-append.sh. The sole-writer
#      enforces mode=report-only ⇒ enqueued_anyway=true; a row that
#      produced a verdict was, by definition, enqueued.
#   4. If index_state == "missing": emit ONE filtered-claim row with
#      reason=concordance-stale (treat missing index as unknown rather than
#      dropping the signal).
#
# Exit codes:
#   0 — dispatched without subprocess failure (all sub-script calls returned 0)
#   1 — usage error, malformed payload, or any sub-script failure (fail-loud
#       so settlement's fail-open wrapper surfaces a warning on stderr).
#
# This hook is FAIL-OPEN at the caller: settlement-processor catches any
# non-zero exit and continues the loop. Surfacing errors via exit 1 (rather
# than silent exit 0) is the load-bearing contract — silent success would
# leave settlement believing propagation succeeded.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FIND_TARGETS="$SCRIPT_DIR/find-correction-targets.sh"
CANDIDATE_APPEND="$SCRIPT_DIR/correction-candidate-append.sh"
FILTERED_APPEND="$SCRIPT_DIR/filtered-claim-append.sh"

fail() {
  echo "[correction-candidate-emit] Error: $1" >&2
  exit 1
}

PAYLOAD=$(cat)
if [[ -z "$PAYLOAD" ]]; then
  fail "empty stdin (expected JSON {run, item, task_claim})"
fi

if ! printf '%s' "$PAYLOAD" | jq -e 'type == "object" and has("run") and has("item") and has("task_claim")' >/dev/null 2>&1; then
  fail "stdin must be a JSON object with keys: run, item, task_claim"
fi

WORK_ITEM=$(printf '%s' "$PAYLOAD" | jq -r '.item.work_item // .task_claim.work_item // empty')
if [[ -z "$WORK_ITEM" ]]; then
  fail "could not derive work_item from payload (.item.work_item or .task_claim.work_item)"
fi

RUN_ID=$(printf '%s' "$PAYLOAD" | jq -r '.run.run_id // empty')
if [[ -z "$RUN_ID" ]]; then
  fail "payload missing .run.run_id"
fi

CLAIM_ID=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.claim_id // .item.claim_id // empty')
if [[ -z "$CLAIM_ID" ]]; then
  fail "payload missing claim_id (.task_claim.claim_id or .item.claim_id)"
fi

CLAIM_TEXT=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.claim // .task_claim.claim_text // empty')
if [[ -z "$CLAIM_TEXT" ]]; then
  fail "payload .task_claim missing claim text"
fi

ANCHOR_FILE=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.file // (.task_claim.source.file // empty)')
ANCHOR_LINE_RANGE=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.line_range // (.task_claim.source.line_range // empty)')
if [[ -z "$ANCHOR_FILE" || -z "$ANCHOR_LINE_RANGE" ]]; then
  fail "payload .task_claim missing file/line_range anchor"
fi

ANCHOR_SCALE=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.scale // empty')
if [[ -z "$ANCHOR_SCALE" ]]; then
  fail "payload .task_claim missing scale"
fi

ANCHOR_PRODUCER_ROLE=$(printf '%s' "$PAYLOAD" | jq -r '.task_claim.producer_role // empty')
if [[ -z "$ANCHOR_PRODUCER_ROLE" ]]; then
  fail "payload .task_claim missing producer_role"
fi

ANCHOR_CHANGE_CONTEXT=$(printf '%s' "$PAYLOAD" | jq -c '.task_claim.change_context // empty')
if [[ -z "$ANCHOR_CHANGE_CONTEXT" || "$ANCHOR_CHANGE_CONTEXT" == "null" ]]; then
  fail "payload .task_claim missing change_context"
fi

VERDICT_EVIDENCE=$(printf '%s' "$PAYLOAD" | jq -r '.run.verdict.evidence // empty')
if [[ -z "$VERDICT_EVIDENCE" ]]; then
  fail "payload .run.verdict.evidence is required for a contradicted verdict"
fi

VERDICT_CORRECTION=$(printf '%s' "$PAYLOAD" | jq -r '.run.verdict.correction // empty')

# Optional --kdir passthrough — Phase 1 sole-writers accept --kdir to
# override the project-resolved knowledge directory. Settlement invokes
# this hook with LORE_KNOWLEDGE_DIR set; surface that to the appenders so
# tests and KDIR-overrides flow through.
KDIR_FLAGS=()
if [[ -n "${LORE_KNOWLEDGE_DIR:-}" ]]; then
  KDIR_FLAGS=(--kdir "$LORE_KNOWLEDGE_DIR")
fi

FILE_LINE="${ANCHOR_FILE}:${ANCHOR_LINE_RANGE}"

emit_filtered_claim() {
  # emit_filtered_claim <reason> <resolver_version>
  local reason="$1" resolver_version="$2"
  bash "$FILTERED_APPEND" \
    "${KDIR_FLAGS[@]}" \
    --work-item "$WORK_ITEM" \
    --claim-id "$CLAIM_ID" \
    --reason "$reason" \
    --mode "report-only" \
    --stage "post-verdict" \
    --settlement-run-id "$RUN_ID" \
    --file "$ANCHOR_FILE" \
    --line-range "$ANCHOR_LINE_RANGE" \
    --change-context "$ANCHOR_CHANGE_CONTEXT" \
    --enqueued-anyway "true" \
    --resolver-version "$resolver_version"
}

if [[ -z "$VERDICT_CORRECTION" ]]; then
  # Downstream appender requires non-empty correction text; route to
  # filtered-claims instead of emitting a malformed candidate.
  RESOLVER_VERSION=$(bash "$FIND_TARGETS" --json --claim-text "$CLAIM_TEXT" --file-line "$FILE_LINE" 2>/dev/null \
    | jq -r '.resolver_version // "v1"')
  emit_filtered_claim "no-discoverable-target" "$RESOLVER_VERSION" >/dev/null \
    || fail "filtered-claim-append.sh failed for missing-correction-text fallback"
  exit 0
fi

# Query the resolver. The --json mode folds missing-index into
# index_state="missing" with exit 0, so any non-zero here is a real error.
RESOLVE_OUT=$(bash "$FIND_TARGETS" --json --claim-text "$CLAIM_TEXT" --file-line "$FILE_LINE") || \
  fail "find-correction-targets.sh --json failed"

if ! printf '%s' "$RESOLVE_OUT" | jq -e 'type == "object" and has("targets") and has("index_state") and has("resolver_version")' >/dev/null 2>&1; then
  fail "find-correction-targets.sh --json returned malformed JSON"
fi

INDEX_STATE=$(printf '%s' "$RESOLVE_OUT" | jq -r '.index_state')
RESOLVER_VERSION=$(printf '%s' "$RESOLVE_OUT" | jq -r '.resolver_version')
TARGET_COUNT=$(printf '%s' "$RESOLVE_OUT" | jq -r '.targets | length')

# Dispatch branch: targets non-empty → correction-candidate per target;
# zero targets + ready → filtered-claim (no-discoverable-target);
# missing/stale index → filtered-claim (concordance-stale).
if [[ "$TARGET_COUNT" -gt 0 ]]; then
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    T_PATH=$(printf '%s' "$target" | jq -r '.path')
    T_RANK=$(printf '%s' "$target" | jq -r '.rank')
    T_OVERLAP=$(printf '%s' "$target" | jq -r '.overlap')
    T_SIM=$(printf '%s' "$target" | jq -r '.sim')
    bash "$CANDIDATE_APPEND" \
      "${KDIR_FLAGS[@]}" \
      --work-item "$WORK_ITEM" \
      --candidate-for-verdict-id "$RUN_ID" \
      --settlement-run-id "$RUN_ID" \
      --claim-id "$CLAIM_ID" \
      --target-entry-path "$T_PATH" \
      --target-rank "$T_RANK" \
      --target-overlap "$T_OVERLAP" \
      --target-sim "$T_SIM" \
      --verdict-evidence "$VERDICT_EVIDENCE" \
      --verdict-correction-text "$VERDICT_CORRECTION" \
      --task-claim-anchor-file "$ANCHOR_FILE" \
      --task-claim-anchor-line-range "$ANCHOR_LINE_RANGE" \
      --task-claim-anchor-scale "$ANCHOR_SCALE" \
      --task-claim-anchor-producer-role "$ANCHOR_PRODUCER_ROLE" \
      --task-claim-anchor-change-context "$ANCHOR_CHANGE_CONTEXT" \
      --resolver-version "$RESOLVER_VERSION" \
      >/dev/null || fail "correction-candidate-append.sh failed for target $T_PATH"
  done < <(printf '%s' "$RESOLVE_OUT" | jq -c '.targets[]')
  exit 0
fi

case "$INDEX_STATE" in
  ready)
    FILTERED_REASON="no-discoverable-target"
    ;;
  missing|stale)
    FILTERED_REASON="concordance-stale"
    ;;
  *)
    fail "find-correction-targets.sh --json returned unknown index_state='$INDEX_STATE'"
    ;;
esac

emit_filtered_claim "$FILTERED_REASON" "$RESOLVER_VERSION" >/dev/null \
  || fail "filtered-claim-append.sh failed (stage=post-verdict, reason=$FILTERED_REASON)"
