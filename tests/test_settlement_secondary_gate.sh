#!/usr/bin/env bash
# test_settlement_secondary_gate.sh — Phase 1 end-to-end falsification of the
# settlement → scorecard secondary-gate bridge.
#
# Proves the bridge fires through the REAL dispatch gate, not just when
# _emit_correction_evidence is called directly. A contradicted Tier-2 claim is
# driven through the full settlement queue (enqueue → process --once →
# execute_item), so the row only lands if execute_item's
# `correction_outcome.status == "applied"` guard actually reaches the bridge.
#
#   Test 1 — one applied correction end-to-end → exactly one
#            tier=correction + kind=scored row in _scorecards/rows.jsonl with
#            calibrated_by_verdict_id == run_id.
#   Test 2 — re-processing the same run does not double-emit (idempotency
#            holds across a real dispatch retry, not just a direct re-call).
#
# Complements two existing tests rather than duplicating them:
#   - test_settlement_correction_evidence_emission.sh exercises the emission
#     helper in isolation (direct python call, stubbed upstream).
#   - test_settlement_auto_correction.sh drives the contradicted run end-to-end
#     but asserts only on the mutated entry + run record, never on the
#     scorecard row.
# This file is the only one that asserts the row appears via the live
# execute_item gate — the seam the secondary gate depends on.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"

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

# Build an indexed knowledge store with one entry whose body contains the exact
# sentence the contradicted Tier-2 claim asserts. apply-correction.sh requires a
# unique exact-match substring; the concordance index lets find-correction-
# targets resolve the entry from the claim text.
setup_kdir_with_indexed_entry() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/conventions"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"

  cat > "$KDIR/conventions/example-routing-rule.md" <<'EOF'
# Example routing rule

Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest.

This is a fixture used by settlement secondary-gate acceptance testing.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/router.py -->
EOF

  # Decoy second entry — TF-IDF needs N>=2 documents for non-zero IDF.
  cat > "$KDIR/conventions/decoy-database-naming.md" <<'EOF'
# Database naming

Tables use snake_case plural nouns. Columns use snake_case singular. Foreign
keys follow the pattern referenced_table_id.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: db/schema.sql -->
EOF

  PYTHONPATH="$SCRIPTS_DIR" python3 - "$KDIR" <<'PYEOF'
import os, sys
from pk_search import Indexer
from pk_concordance import Concordance
kdir = sys.argv[1]
Indexer(kdir).index_all()
Concordance(os.path.join(kdir, ".pk_search.db")).build_vectors()
PYEOF
}

write_settings_file() {
  local path="$1"
  cat > "$path" <<'EOF'
{
  "version": 1,
  "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": []},
    "opencode": {"args": []},
    "codex": {"args": []}
  },
  "settlement": {
    "enabled": true,
    "max_concurrency": 1,
    "batch_size": 4,
    "batch_recompute_min_interval_seconds": 0,
    "harness_selection": {"mode": "first_eligible", "eligible_frameworks": ["claude-code"]}
  }
}
EOF
}

# Fake executor emitting a contradicted verdict envelope (verdict_envelope_version
# 1). Replacement + evidence arrive via env vars so embedded quotes survive.
build_fake_executor() {
  local script="$1" replacement="$2" evidence="$3"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
python3 -c '
import json, os
print(json.dumps({
    "verdict_envelope_version": 1,
    "verdict": "contradicted",
    "evidence": os.environ.get("FAKE_EVIDENCE", ""),
    "correction": os.environ.get("FAKE_REPLACEMENT", ""),
    "executor": {"name": "fake-contradicted", "framework": "test", "exit_code": 0},
    "audit": None,
}))
'
EOF
  chmod +x "$script"
  export FAKE_REPLACEMENT="$replacement"
  export FAKE_EVIDENCE="$evidence"
}

emit_tier2_row() {
  local claim_id="$1" claim_text="$2"
  jq -nc --arg cid "$claim_id" --arg claim "$claim_text" '{
    claim_id: $cid,
    tier: "task-evidence",
    claim: $claim,
    producer_role: "worker",
    protocol_slot: "implementation",
    task_id: "secondary-gate-fixture",
    phase_id: "1",
    scale: "implementation",
    file: "scripts/router.py",
    line_range: "10-12",
    falsifier: "If the routing matcher iterates in a different order than declared in router.py",
    why_this_work_needs_it: "Secondary-gate acceptance test fixture proving the bridge fires through the live dispatch gate",
    captured_at_sha: "fixture-sha",
    change_context: {
      diff_ref: null,
      changed_files: ["scripts/router.py"],
      summary: "Acceptance test fixture for the secondary-gate bridge"
    }
  }'
}

# Count rows in $KDIR/_scorecards/rows.jsonl matching tier:correction,
# kind:scored, and a given calibrated_by_verdict_id (the run_id).
count_correction_rows_for_run() {
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

# Count all tier:correction + kind:scored rows regardless of run_id.
count_correction_rows_total() {
  local rows="$KDIR/_scorecards/rows.jsonl"
  if [[ ! -f "$rows" ]]; then
    echo "0"
    return
  fi
  jq -s 'map(select(.tier == "correction" and .kind == "scored")) | length' "$rows"
}

# Resolve the run_id of the single run record produced by a process --once call.
run_id_from_record() {
  local run_file
  run_file=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
  [[ -f "$run_file" ]] || { echo ""; return; }
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run_id",""))' "$run_file"
}

export LORE_KNOWLEDGE_DIR="$KDIR"

echo "=== Settlement Secondary-Gate End-to-End Tests ==="

# =============================================
# Test 1: applied correction end-to-end → exactly one correction scorecard row
# =============================================
echo ""
echo "Test 1: contradicted run through dispatch → one tier:correction + kind:scored row"
setup_kdir_with_indexed_entry

ORIGINAL_TEXT="Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest."
REPLACEMENT_TEXT="Routes are matched in dependency-graph topological order; tied weights resolve via declaration order as a stable secondary sort."

SETTINGS="$TEST_DIR/settings.json"
write_settings_file "$SETTINGS"

FAKE_EXEC="$TEST_DIR/fake-contradicted-exec.sh"
build_fake_executor "$FAKE_EXEC" "$REPLACEMENT_TEXT" "scripts/router.py:10 — \"matcher.dispatch(events, by_priority=True)\""

ROW=$(emit_tier2_row "claim-secondary-gate-1" "$ORIGINAL_TEXT")
printf '%s' "$ROW" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  bash "$QUEUE" enqueue --work-item secondary-gate-test --kdir "$KDIR" --json >/dev/null

LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr.txt" >/dev/null

# Sanity: the run record records an applied correction (the gate's precondition).
RUN_FILE=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
RUN_OUTCOME_STATUS=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("correction_outcome") or {}).get("status",""))' "$RUN_FILE")
assert_eq "run record records correction_outcome.status == applied" "$RUN_OUTCOME_STATUS" "applied"

# The bridge fired through execute_item: exactly one scorecard row keyed to run_id.
RUN_ID=$(run_id_from_record)
assert_eq "run_id resolved from record" "$([[ -n "$RUN_ID" ]] && echo yes || echo no)" "yes"
assert_eq "exactly 1 correction row for run_id" "$(count_correction_rows_for_run "$RUN_ID")" "1"
assert_eq "total correction rows == 1" "$(count_correction_rows_total)" "1"

ROWS_FILE="$KDIR/_scorecards/rows.jsonl"
EMITTED_ROW=$(jq -c --arg rid "$RUN_ID" 'select(.tier == "correction" and .kind == "scored" and .calibrated_by_verdict_id == $rid)' "$ROWS_FILE" | head -1)
assert_eq "row tier == correction" "$(echo "$EMITTED_ROW" | jq -r '.tier')" "correction"
assert_eq "row kind == scored" "$(echo "$EMITTED_ROW" | jq -r '.kind')" "scored"
assert_eq "row calibrated_by_verdict_id == run_id" "$(echo "$EMITTED_ROW" | jq -r '.calibrated_by_verdict_id')" "$RUN_ID"
assert_eq "row calibration_state == pre-calibration" "$(echo "$EMITTED_ROW" | jq -r '.calibration_state')" "pre-calibration"
# find-correction-targets returns an absolute path, so the live bridge records
# corrected_entry_path absolute — unlike the direct-helper emission test, which
# feeds a relative target_entry. Assert the suffix rather than pinning the tmpdir.
CORRECTED_PATH=$(echo "$EMITTED_ROW" | jq -r '.corrected_entry_path')
assert_eq "row corrected_entry_path is absolute" "$([[ "$CORRECTED_PATH" == /* ]] && echo yes || echo no)" "yes"
assert_eq "row corrected_entry_path names mutated entry" "$([[ "$CORRECTED_PATH" == *"conventions/example-routing-rule.md" ]] && echo yes || echo no)" "yes"
assert_eq "row correction_target == claim" "$(echo "$EMITTED_ROW" | jq -r '.correction_target')" "claim"

# =============================================
# Test 2: re-processing the same run does not double-emit
# =============================================
echo ""
echo "Test 2: idempotent across a real dispatch retry"

# Re-running process --once with the already-terminal run replays
# write_run_correction_outcome_once → status==applied → _emit_correction_evidence.
# The bridge's rows.jsonl scan must suppress a second row for the same run_id.
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>>"$TEST_DIR/proc-stderr.txt" >/dev/null || true

# Directly re-invoke the bridge for the same run_id to assert the idempotency
# scan, independent of whether the queue re-leased the terminal item.
KDIR_ABS="$KDIR" RUN_ID="$RUN_ID" SETTLEMENT_PY="$SCRIPTS_DIR/settlement-processor.py" \
python3 - <<'PYEOF'
import importlib.util, os
from pathlib import Path
spec = importlib.util.spec_from_file_location("settlement_processor", os.environ["SETTLEMENT_PY"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
settlement = mod.Settlement(Path(os.environ["KDIR_ABS"]))
settlement._emit_correction_evidence(
    os.environ["RUN_ID"],
    {"status": "applied", "reason": "applied", "target_entry": "conventions/example-routing-rule.md"},
)
PYEOF

assert_eq "still exactly 1 correction row for run_id after retry" "$(count_correction_rows_for_run "$RUN_ID")" "1"
assert_eq "total correction rows still 1 after retry" "$(count_correction_rows_total)" "1"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]] || exit 1
