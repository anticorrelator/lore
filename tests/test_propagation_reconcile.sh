#!/usr/bin/env bash
# test_propagation_reconcile.sh — Tests for propagation-reconcile.sh.
#
# Builds a synthetic knowledge store with hand-rolled _settlement/runs/*.json
# records and pre-populated sidecars under _work/<slug>/, then drives the
# reconcile script and asserts both observable outputs and on-disk state.
#
# Covers:
#   T1: contradicted run with matching correction-candidate row → satisfied,
#       no miss appended.
#   T2: contradicted run with matching post-verdict filtered-claim row →
#       satisfied, no miss appended.
#   T3: contradicted run with no matching artifact and hook env unset →
#       miss appended with reason=hook_disabled.
#   T4: contradicted run with no matching artifact and hook env set but
#       claim_id absent from task-claims.jsonl → reason=rehydration_failed.
#   T5: contradicted run with no matching artifact, hook env set, claim in
#       task-claims.jsonl → reason=emit_failed (default).
#   T6: idempotency — running reconcile twice produces exactly one miss
#       row per missing run.
#   T7: load-bearing D2 boundary — a pre-enqueue filtered-claim with a
#       forged matching settlement_run_id does NOT satisfy the invariant;
#       a miss row is still appended.
#   T8: verified verdicts are skipped entirely (no satisfaction check, no
#       miss append).
#   T9: dry-run prints the summary but does not append.
#
# The test sets `LORE_SETTLEMENT_POST_HOOK` per-invocation via inline `env`
# so each scenario controls the observable signal cleanly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SCRIPT="$SCRIPT_DIR/propagation-reconcile.sh"

TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="recon-slug"
WORK_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
RUNS_DIR="$KNOWLEDGE_DIR/_settlement/runs"
MISSES="$WORK_DIR/propagation-misses.jsonl"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_miss_for_run() {
  local label="$1" run_id="$2"
  if [[ ! -f "$MISSES" ]]; then
    echo "  PASS: $label (sidecar absent)"
    PASS=$((PASS + 1))
    return
  fi
  local count
  count=$(jq -r --arg r "$run_id" 'select(.settlement_run_id == $r) | .settlement_run_id' "$MISSES" | wc -l | tr -d ' ')
  assert_eq "$label" "$count" "0"
}

assert_miss_for_run() {
  local label="$1" run_id="$2" expected_reason="$3"
  local row
  row=$(jq -c --arg r "$run_id" 'select(.settlement_run_id == $r)' "$MISSES")
  if [[ -z "$row" ]]; then
    echo "  FAIL: $label — no miss row found for $run_id"
    FAIL=$((FAIL + 1))
    return
  fi
  local actual_reason
  actual_reason=$(echo "$row" | jq -r '.reason')
  assert_eq "$label" "$actual_reason" "$expected_reason"
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$WORK_DIR"
  mkdir -p "$RUNS_DIR"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
}

# Write a synthetic run record. Args:
#   $1 = run_id, $2 = claim_id, $3 = verdict label (contradicted|verified|unverified)
write_run() {
  local run_id="$1" claim_id="$2" verdict="$3"
  cat > "$RUNS_DIR/$run_id.json" <<EOF
{
  "version": 1,
  "run_id": "$run_id",
  "item_id": "item-$run_id",
  "work_item": "$SLUG",
  "claim_id": "$claim_id",
  "status": "completed",
  "verdict": {
    "claim_id": "$claim_id",
    "verdict": "$verdict",
    "evidence": "test fixture",
    "correction": null,
    "verdict_format": "envelope"
  }
}
EOF
}

# Write a correction-candidates row for a run.
write_correction_candidate() {
  local run_id="$1" claim_id="$2"
  echo "{\"settlement_run_id\": \"$run_id\", \"claim_id\": \"$claim_id\", \"candidate_for_verdict_id\": \"$run_id\"}" \
    >> "$WORK_DIR/correction-candidates.jsonl"
}

# Write a filtered-claims row. Args:
#   $1=run_id (or "" to omit), $2=stage, $3=claim_id
write_filtered_claim() {
  local run_id="$1" stage="$2" claim_id="$3"
  if [[ -n "$run_id" ]]; then
    echo "{\"settlement_run_id\": \"$run_id\", \"stage\": \"$stage\", \"claim_id\": \"$claim_id\", \"reason\": \"no-discoverable-target\"}" \
      >> "$WORK_DIR/filtered-claims.jsonl"
  else
    echo "{\"stage\": \"$stage\", \"claim_id\": \"$claim_id\", \"reason\": \"templated-claim\"}" \
      >> "$WORK_DIR/filtered-claims.jsonl"
  fi
}

# Write a task-claims row so rehydration succeeds.
write_task_claim() {
  local claim_id="$1"
  echo "{\"claim_id\": \"$claim_id\", \"tier\": \"task-evidence\"}" \
    >> "$WORK_DIR/task-claims.jsonl"
}

# run_reconcile_unset: run with LORE_SETTLEMENT_POST_HOOK explicitly unset.
# Shell functions can't be invoked under `env -u`, so we inline the unset
# in a subshell — same observable effect, but the function call works.
run_reconcile_unset() {
  (
    unset LORE_SETTLEMENT_POST_HOOK
    "$SCRIPT" --work-item "$SLUG" --kdir "$KNOWLEDGE_DIR" "$@"
  )
}

# run_reconcile_with_hook: run with LORE_SETTLEMENT_POST_HOOK set so the
# reason-derivation skips the hook_disabled branch.
run_reconcile_with_hook() {
  (
    export LORE_SETTLEMENT_POST_HOOK="/tmp/test-hook.sh"
    "$SCRIPT" --work-item "$SLUG" --kdir "$KNOWLEDGE_DIR" "$@"
  )
}

echo "=== propagation-reconcile Tests ==="

# =============================================
# Test 1: correction-candidate match → satisfied
# =============================================
echo ""
echo "Test 1: contradicted run matched by correction-candidates row → satisfied"
setup_store
write_run "run-1" "claim-1" "contradicted"
write_correction_candidate "run-1" "claim-1"
OUTPUT=$(run_reconcile_unset 2>/dev/null)
assert_contains "human summary names work item" "$OUTPUT" "$SLUG"
assert_contains "human summary reports satisfied=1" "$OUTPUT" "satisfied=1"
assert_contains "human summary reports missing=0" "$OUTPUT" "missing=0"
assert_no_miss_for_run "no miss row for satisfied run-1" "run-1"

# =============================================
# Test 2: post-verdict filtered-claim match → satisfied
# =============================================
echo ""
echo "Test 2: contradicted run matched by post-verdict filtered-claims row → satisfied"
setup_store
write_run "run-2" "claim-2" "contradicted"
write_filtered_claim "run-2" "post-verdict" "claim-2"
OUTPUT=$(run_reconcile_unset 2>/dev/null)
assert_contains "satisfied=1 in summary" "$OUTPUT" "satisfied=1"
assert_no_miss_for_run "no miss row for satisfied run-2" "run-2"

# =============================================
# Test 3: no match, hook unset → reason=hook_disabled
# =============================================
echo ""
echo "Test 3: no match, LORE_SETTLEMENT_POST_HOOK unset → reason=hook_disabled"
setup_store
write_run "run-3" "claim-3" "contradicted"
write_task_claim "claim-3"
OUTPUT=$(run_reconcile_unset 2>/dev/null)
assert_contains "missing=1 in summary" "$OUTPUT" "missing=1"
assert_contains "hook_disabled:1 in summary" "$OUTPUT" "hook_disabled:1"
assert_miss_for_run "miss row reason=hook_disabled" "run-3" "hook_disabled"

# =============================================
# Test 4: no match, hook set, claim missing from task-claims → rehydration_failed
# =============================================
echo ""
echo "Test 4: hook set + claim absent from task-claims.jsonl → reason=rehydration_failed"
setup_store
write_run "run-4" "claim-4" "contradicted"
# Deliberately do NOT write a task-claim row for claim-4.
OUTPUT=$(run_reconcile_with_hook 2>/dev/null)
assert_contains "rehydration_failed:1 in summary" "$OUTPUT" "rehydration_failed:1"
assert_miss_for_run "miss row reason=rehydration_failed" "run-4" "rehydration_failed"

# =============================================
# Test 5: no match, hook set, claim present in task-claims → emit_failed
# =============================================
echo ""
echo "Test 5: hook set + claim present + no artifact → reason=emit_failed (default)"
setup_store
write_run "run-5" "claim-5" "contradicted"
write_task_claim "claim-5"
OUTPUT=$(run_reconcile_with_hook 2>/dev/null)
assert_contains "emit_failed:1 in summary" "$OUTPUT" "emit_failed:1"
assert_miss_for_run "miss row reason=emit_failed" "run-5" "emit_failed"

# =============================================
# Test 6: idempotency — two runs → exactly one miss row per missing run
# =============================================
echo ""
echo "Test 6: idempotent re-run produces no duplicate miss rows"
setup_store
write_run "run-6" "claim-6" "contradicted"
write_run "run-7" "claim-7" "contradicted"
run_reconcile_unset > /dev/null 2>&1
run_reconcile_unset > /dev/null 2>&1
COUNT=$(wc -l < "$MISSES" | tr -d ' ')
assert_eq "two missing runs → two miss rows after two reconcile passes" "$COUNT" "2"
# And: exactly one row per (run_id) — dedupe key is (run_id, reason).
COUNT_R6=$(jq -r 'select(.settlement_run_id == "run-6") | .settlement_run_id' "$MISSES" | wc -l | tr -d ' ')
COUNT_R7=$(jq -r 'select(.settlement_run_id == "run-7") | .settlement_run_id' "$MISSES" | wc -l | tr -d ' ')
assert_eq "exactly one miss row for run-6" "$COUNT_R6" "1"
assert_eq "exactly one miss row for run-7" "$COUNT_R7" "1"

# =============================================
# Test 7: D2 boundary — pre-enqueue filtered-claim with matching run_id
# does NOT satisfy the invariant; miss row still appended.
# =============================================
echo ""
echo "Test 7: pre-enqueue filtered-claim does NOT satisfy (load-bearing D2 boundary)"
setup_store
write_run "run-8" "claim-8" "contradicted"
write_task_claim "claim-8"
# Forge a pre-enqueue row carrying a settlement_run_id (normally absent for
# pre-enqueue per filtered-claim schema, but we test the reader's filter:
# even a forged match must be ignored because stage != post-verdict).
write_filtered_claim "run-8" "pre-enqueue" "claim-8"
OUTPUT=$(run_reconcile_with_hook 2>/dev/null)
assert_contains "missing=1 — pre-enqueue did not satisfy" "$OUTPUT" "missing=1"
assert_miss_for_run "pre-enqueue forgery did not satisfy; miss appended" "run-8" "emit_failed"

# =============================================
# Test 8: verified verdicts are skipped entirely
# =============================================
echo ""
echo "Test 8: verified-verdict runs are skipped entirely"
setup_store
write_run "run-9" "claim-9" "verified"
write_run "run-10" "claim-10" "unverified"
OUTPUT=$(run_reconcile_unset 2>/dev/null)
assert_contains "satisfied=0 — verified runs ignored" "$OUTPUT" "satisfied=0"
assert_contains "missing=0 — verified runs ignored" "$OUTPUT" "missing=0"
if [[ -f "$MISSES" ]]; then
  COUNT=$(wc -l < "$MISSES" | tr -d ' ')
  assert_eq "no miss rows written for non-contradicted runs" "$COUNT" "0"
else
  echo "  PASS: misses sidecar not created for non-contradicted runs"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 9: --dry-run prints summary but does not append
# =============================================
echo ""
echo "Test 9: --dry-run prints summary but appends nothing"
setup_store
write_run "run-11" "claim-11" "contradicted"
OUTPUT=$(run_reconcile_unset --dry-run 2>/dev/null)
assert_contains "dry-run still prints summary" "$OUTPUT" "missing=1"
if [[ -f "$MISSES" ]]; then
  COUNT=$(wc -l < "$MISSES" | tr -d ' ')
  assert_eq "no miss rows in dry-run mode" "$COUNT" "0"
else
  echo "  PASS: dry-run did not create misses sidecar"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 10: structured stderr summary line is parseable JSON
# =============================================
echo ""
echo "Test 10: RECONCILE_SUMMARY on stderr is parseable JSON"
setup_store
write_run "run-12" "claim-12" "contradicted"
write_correction_candidate "run-12" "claim-12"
STDERR=$(run_reconcile_unset 2>&1 >/dev/null)
SUMMARY_LINE=$(echo "$STDERR" | grep '^RECONCILE_SUMMARY=' | sed 's/^RECONCILE_SUMMARY=//')
assert_eq "structured summary satisfied=1" "$(echo "$SUMMARY_LINE" | jq -r '.satisfied')" "1"
assert_eq "structured summary missing=0" "$(echo "$SUMMARY_LINE" | jq -r '.missing')" "0"
assert_eq "structured summary by_reason has hook_disabled key" \
  "$(echo "$SUMMARY_LINE" | jq -r '.by_reason | has("hook_disabled")')" "true"

# =============================================
# Test 11: --work-item required
# =============================================
echo ""
echo "Test 11: missing --work-item is a fatal error"
EXIT_CODE=0
STDERR=$("$SCRIPT" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "missing --work-item exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names --work-item" "$STDERR" "--work-item"

# =============================================
# Test 12: unknown work item is a fatal error
# =============================================
echo ""
echo "Test 12: nonexistent work item is a fatal error"
setup_store
EXIT_CODE=0
STDERR=$("$SCRIPT" --work-item "does-not-exist" --kdir "$KNOWLEDGE_DIR" 2>&1) || EXIT_CODE=$?
assert_eq "nonexistent work item exits 1" "$EXIT_CODE" "1"
assert_contains "stderr names work item not found" "$STDERR" "work item not found"

# =============================================
# Summary
# =============================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
