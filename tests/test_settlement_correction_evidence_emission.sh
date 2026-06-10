#!/usr/bin/env bash
# test_settlement_correction_evidence_emission.sh — Phase 1 emission-side
# acceptance tests for the settlement → scorecard bridge.
#
# Covers _emit_correction_evidence inside settlement-processor.py:
#   Test 1 (first emit)       — applied outcome → exactly one row appears in
#                               $KDIR/_scorecards/rows.jsonl with
#                               tier=correction, kind=scored,
#                               calibrated_by_verdict_id=<run_id>.
#   Test 2 (idempotent retry) — re-emit same run_id → row count stays at 1.
#   Test 3 (skipped outcome)  — status=skipped → no row written.
#   Test 4 (failed outcome)   — status=failed  → no row written.
#   Test 5 (commons kind)     — status=applied + kind=commons → no row
#                               (evidence-class gate; task-claim still emits).
#
# Drives the emission helper directly via python -c (instead of routing
# through the full settlement-queue loop) so the test is hermetic, fast, and
# independent of executor / find-correction-targets / apply-correction
# wiring — those branches are already covered by
# tests/test_settlement_auto_correction.sh and
# tests/test_settlement_correction_outcome_branches.py.
#
# Sole-writer invariant: this test exercises the bridge through the
# `scorecard-append.sh` writer (no direct rows.jsonl writes), matching the
# Phase 1 design decision (D2).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
SETTLEMENT_PY="$SCRIPTS_DIR/settlement-processor.py"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"

cleanup() { rm -rf "$TEST_DIR"; }
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

# Idempotent KDIR setup — wipes any prior state under the test directory.
setup_kdir() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR"
  # _manifest.json mirrors the auto-correction test fixture; scorecard-append.sh
  # only requires the directory to exist and creates _scorecards/ on demand.
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
}

# Drive Settlement._emit_correction_evidence directly for a given outcome.
# args: run_id, status, target_entry (may be empty for non-applied),
#       kind (optional; defaults to task-claim — the only kind the call-site
#       gate emits for, per the decide-commons-correction-feed-evolve-secondary-ga
#       decision record)
emit() {
  local run_id="$1" status="$2" target_entry="$3" kind="${4:-task-claim}"
  KDIR_ABS="$KDIR" RUN_ID="$run_id" STATUS="$status" TARGET_ENTRY="$target_entry" \
    ITEM_KIND="$kind" \
    SETTLEMENT_PY="$SETTLEMENT_PY" \
  python3 - <<'PYEOF'
import importlib.util
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("settlement_processor", os.environ["SETTLEMENT_PY"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

settlement = mod.Settlement(Path(os.environ["KDIR_ABS"]))
outcome = {
    "status": os.environ["STATUS"],
    "reason": os.environ["STATUS"],
}
target_entry = os.environ.get("TARGET_ENTRY") or ""
if target_entry:
    outcome["target_entry"] = target_entry

# Mirror the execute_item gate: only emit for status=="applied" AND
# kind=="task-claim" (commons corrections are knowledge-drift signal, not
# doctrine signal — they must never reach the /evolve secondary gate).
if outcome.get("status") == "applied" and os.environ.get("ITEM_KIND", "task-claim") == "task-claim":
    settlement._emit_correction_evidence(os.environ["RUN_ID"], outcome)
PYEOF
}

# Count rows in $KDIR/_scorecards/rows.jsonl matching tier:correction,
# kind:scored, and the given run_id.
count_rows_for_run() {
  local run_id="$1"
  local rows="$KDIR/_scorecards/rows.jsonl"
  if [[ ! -f "$rows" ]]; then
    echo "0"
    return
  fi
  jq -s --arg rid "$run_id" '
    map(select(.tier == "correction" and .kind == "scored" and .calibrated_by_verdict_id == $rid))
    | length
  ' "$rows"
}

# Count total rows in the file (or 0 if absent).
count_rows_total() {
  local rows="$KDIR/_scorecards/rows.jsonl"
  if [[ ! -f "$rows" ]]; then
    echo "0"
    return
  fi
  wc -l < "$rows" | tr -d ' '
}

echo "=== Settlement → Scorecard Bridge Emission Tests ==="

# =============================================
# Test 1: First emit — applied outcome creates exactly one row
# =============================================
echo ""
echo "Test 1: applied outcome → exactly one tier:correction + kind:scored row"
setup_kdir

emit "run-emit-001" "applied" "conventions/example-routing-rule.md"

ROWS_FILE="$KDIR/_scorecards/rows.jsonl"
assert_eq "rows.jsonl exists after applied emit" "$([[ -f "$ROWS_FILE" ]] && echo yes || echo no)" "yes"
assert_eq "exactly 1 matching row for run_id" "$(count_rows_for_run "run-emit-001")" "1"
assert_eq "total row count is 1" "$(count_rows_total)" "1"

# Schema fields on the emitted row
EMITTED_ROW=$(grep -F '"run-emit-001"' "$ROWS_FILE" | head -1)
assert_eq "row tier == correction" "$(echo "$EMITTED_ROW" | jq -r '.tier')" "correction"
assert_eq "row kind == scored" "$(echo "$EMITTED_ROW" | jq -r '.kind')" "scored"
assert_eq "row calibration_state == pre-calibration" "$(echo "$EMITTED_ROW" | jq -r '.calibration_state')" "pre-calibration"
assert_eq "row calibrated_by_verdict_id == run-emit-001" "$(echo "$EMITTED_ROW" | jq -r '.calibrated_by_verdict_id')" "run-emit-001"
assert_eq "row correction_target == claim" "$(echo "$EMITTED_ROW" | jq -r '.correction_target')" "claim"
assert_eq "row corrected_entry_path names the entry" "$(echo "$EMITTED_ROW" | jq -r '.corrected_entry_path')" "conventions/example-routing-rule.md"
assert_eq "row schema_version is 1" "$(echo "$EMITTED_ROW" | jq -r '.schema_version')" "1"

# =============================================
# Test 2: Idempotent retry — re-emit same run_id, row count stays at 1
# =============================================
echo ""
echo "Test 2: idempotent retry → row count stays at 1"
# Do NOT reset $KDIR — we want to retry against the row from Test 1.

emit "run-emit-001" "applied" "conventions/example-routing-rule.md"
assert_eq "still exactly 1 matching row for run-emit-001 after retry" "$(count_rows_for_run "run-emit-001")" "1"
assert_eq "total row count still 1 after retry" "$(count_rows_total)" "1"

# A different run_id still emits — idempotency is keyed by calibrated_by_verdict_id.
emit "run-emit-002" "applied" "conventions/another-entry.md"
assert_eq "second distinct run_id emits a second row" "$(count_rows_for_run "run-emit-002")" "1"
assert_eq "total row count after distinct second emit" "$(count_rows_total)" "2"

# Re-emit the second one too — still 1 row for it.
emit "run-emit-002" "applied" "conventions/another-entry.md"
assert_eq "second run_id retry stays at 1 row" "$(count_rows_for_run "run-emit-002")" "1"
assert_eq "total row count holds at 2 after second retry" "$(count_rows_total)" "2"

# =============================================
# Test 3: Skipped outcome → no row written
# =============================================
echo ""
echo "Test 3: skipped outcome → no row written"
setup_kdir

emit "run-skip-001" "skipped" "conventions/example-routing-rule.md"
assert_eq "no rows.jsonl after skipped (file absent or empty)" "$(count_rows_total)" "0"
assert_eq "no matching row for skipped run_id" "$(count_rows_for_run "run-skip-001")" "0"

# =============================================
# Test 4: Failed outcome → no row written
# =============================================
echo ""
echo "Test 4: failed outcome → no row written"
setup_kdir

emit "run-fail-001" "failed" "conventions/example-routing-rule.md"
assert_eq "no rows.jsonl after failed outcome" "$(count_rows_total)" "0"
assert_eq "no matching row for failed run_id" "$(count_rows_for_run "run-fail-001")" "0"

# =============================================
# Test 5: Commons kind, applied outcome → no row (kind gate)
# Decision record: _work/decide-commons-correction-feed-evolve-secondary-ga —
# contradicted-commons corrections flow back to the entry (corrections[] trail)
# but must NOT emit tier:correction rows into /evolve's secondary-gate pool.
# =============================================
echo ""
echo "Test 5: commons kind + applied outcome → no row (evidence-class gate)"
setup_kdir

emit "run-commons-001" "applied" "conventions/drifted-entry.md" "commons"
assert_eq "no rows.jsonl after commons applied outcome" "$(count_rows_total)" "0"
assert_eq "no matching row for commons run_id" "$(count_rows_for_run "run-commons-001")" "0"

# task-claim applied in the same KDIR still emits (gate is kind-specific, not global)
emit "run-commons-002" "applied" "conventions/real-doctrine-fix.md" "task-claim"
assert_eq "task-claim applied still emits exactly 1 row" "$(count_rows_for_run "run-commons-002")" "1"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]] || exit 1
