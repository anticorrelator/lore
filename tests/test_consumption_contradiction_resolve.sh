#!/usr/bin/env bash
# test_consumption_contradiction_resolve.sh — resolver/correction/retrieval tests.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
APPEND="$SCRIPTS_DIR/consumption-contradiction-append.sh"
RESOLVE="$SCRIPTS_DIR/consumption-contradiction-resolve.sh"
APPLY="$SCRIPTS_DIR/apply-correction.sh"
FIND="$SCRIPTS_DIR/find-correction-targets.sh"
PK="$SCRIPTS_DIR/pk_cli.py"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/kdir"
SLUG="resolver-fixture"
ENTRY="$KDIR/architecture/resolver-contract.md"
SIDECAR="$KDIR/_work/$SLUG/consumption-contradictions.jsonl"
VERDICT_ID="verdict-cal-1"
CONTRADICTION_ID="ctr-test000001"

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

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/_work/$SLUG" "$KDIR/_scorecards" "$KDIR/architecture" "$KDIR/_meta"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
  cat > "$ENTRY" <<'EOF'
# Resolver Contract

The resolver has no remediated state.

<!-- learned: 2026-05-09 | confidence: high | source: test | related_files: scripts/consumption-contradiction-resolve.sh | scale: subsystem | status: current -->
EOF
  "$APPEND" \
    --work-item "$SLUG" \
    --source worker \
    --producer-role worker \
    --protocol-slot implement-step-3 \
    --cycle-id cycle-test \
    --knowledge-path "architecture/resolver-contract.md" \
    --heading "Resolver Contract" \
    --contradiction-rationale "The code now supports remediated." \
    --claim-id "claim-resolver-state" \
    --claim-text "The resolver has no remediated state." \
    --file "$REPO_ROOT/scripts/consumption-contradiction-resolve.sh" \
    --line-range "1-10" \
    --exact-snippet "remediated" \
    --falsifier "No remediated transition exists." \
    --contradiction-id "$CONTRADICTION_ID" \
    --kdir "$KDIR" >/dev/null
}

seed_calibrated_verdict() {
  "$SCRIPTS_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$(jq -nc \
    --arg vid "$VERDICT_ID" \
    '{schema_version:"1",kind:"telemetry",tier:"telemetry",calibration_state:"calibrated",metric:"correction_authorization",value:1,sample_size:1,verdict_source:"correctness-gate",verdict_id:$vid}')" >/dev/null
}

echo "=== consumption-contradiction resolver Tests ==="

echo ""
echo "Test 1: accepted requires calibrated verdict evidence"
setup_store
EXIT_CODE=0
ERR=$("$RESOLVE" "$CONTRADICTION_ID" --status accepted --resolved-by test --verdict-id "$VERDICT_ID" --kdir "$KDIR" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "uncalibrated accept exits 4" "$EXIT_CODE" "4"
assert_contains "error names calibrated verdict evidence" "$ERR" "calibrated verdict evidence not found"
assert_eq "row remains pending" "$(jq -r '.status' < "$SIDECAR")" "pending"

echo ""
echo "Test 2: accepted emits calibrated correction evidence and is idempotent"
setup_store
seed_calibrated_verdict
OUT=$("$RESOLVE" "$CONTRADICTION_ID" --status accepted --resolved-by test --verdict-id "$VERDICT_ID" --kdir "$KDIR" --json 2>/dev/null)
assert_eq "json current_status accepted" "$(echo "$OUT" | jq -r '.current_status')" "accepted"
assert_eq "sidecar status accepted" "$(jq -r '.status' < "$SIDECAR")" "accepted"
assert_eq "sidecar accepted_by_verdict_id set" "$(jq -r '.accepted_by_verdict_id' < "$SIDECAR")" "$VERDICT_ID"
CORR_ROWS=$(jq -s --arg cid "$CONTRADICTION_ID" '[.[] | select(.kind=="consumption-contradiction" and .tier=="correction" and .contradiction_id==$cid)] | length' "$KDIR/_scorecards/rows.jsonl")
assert_eq "one correction evidence row emitted" "$CORR_ROWS" "1"
OUT2=$("$RESOLVE" "$CONTRADICTION_ID" --status accepted --resolved-by test --verdict-id "$VERDICT_ID" --kdir "$KDIR" --json 2>/dev/null)
assert_eq "idempotent accepted reports true" "$(echo "$OUT2" | jq -r '.idempotent')" "true"
CORR_ROWS2=$(jq -s --arg cid "$CONTRADICTION_ID" '[.[] | select(.kind=="consumption-contradiction" and .tier=="correction" and .contradiction_id==$cid)] | length' "$KDIR/_scorecards/rows.jsonl")
assert_eq "idempotent accepted does not duplicate evidence" "$CORR_ROWS2" "1"

echo ""
echo "Test 3: remediated applies commons correction before sidecar transition"
setup_store
seed_calibrated_verdict
OUT=$("$RESOLVE" "$CONTRADICTION_ID" \
  --status remediated \
  --resolved-by test \
  --verdict-id "$VERDICT_ID" \
  --entry "$ENTRY" \
  --evidence "scripts/consumption-contradiction-resolve.sh:1" \
  --superseded-text "The resolver has no remediated state." \
  --replacement-text "The resolver supports accepted, declined, and remediated states." \
  --date "2026-05-09" \
  --kdir "$KDIR" \
  --json 2>/dev/null)
assert_eq "json current_status remediated" "$(echo "$OUT" | jq -r '.current_status')" "remediated"
assert_eq "sidecar status remediated" "$(jq -r '.status' < "$SIDECAR")" "remediated"
assert_contains "entry body updated" "$(cat "$ENTRY")" "supports accepted, declined, and remediated"
assert_contains "entry metadata has corrections" "$(cat "$ENTRY")" "corrections:"
assert_contains "entry metadata has verdict id" "$(cat "$ENTRY")" "$VERDICT_ID"

echo ""
echo "Test 4: apply-correction --kdir accepts calibrated_by_verdict_id evidence"
setup_store
"$SCRIPTS_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$(jq -nc \
  --arg vid "$VERDICT_ID" \
  '{schema_version:"1",kind:"consumption-contradiction",tier:"correction",calibration_state:"calibrated",corrected_entry_path:"architecture/resolver-contract.md",correction_target:"claim",calibrated_by_verdict_id:$vid,verdict_id:$vid}')" >/dev/null
"$APPLY" \
  --entry "$ENTRY" \
  --verdict-id "$VERDICT_ID" \
  --verdict-source correctness-gate \
  --evidence "scripts/x.sh:1" \
  --superseded-text "The resolver has no remediated state." \
  --replacement-text "The resolver supports remediated." \
  --date "2026-05-09" \
  --kdir "$KDIR" >/dev/null
assert_contains "apply-correction updated fixture KDIR" "$(cat "$ENTRY")" "supports remediated"

echo ""
echo "Test 5: retrieval surfaces correction recency"
LORE_KNOWLEDGE_DIR="$KDIR" python3 "$PK" index "$KDIR" --force >/dev/null
SEARCH_JSON=$(LORE_KNOWLEDGE_DIR="$KDIR" python3 "$PK" search "$KDIR" "resolver remediated" --type knowledge --scale-set subsystem --json)
assert_eq "search json correction_recency" "$(echo "$SEARCH_JSON" | jq -r '.[0].correction_recency')" "2026-05-09"
PREFETCH_SUMMARY=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPTS_DIR/prefetch-knowledge.sh" "resolver remediated" --format summary --type knowledge --scale-set subsystem)
assert_contains "prefetch summary shows Last corrected" "$PREFETCH_SUMMARY" "Last corrected: 2026-05-09"

echo ""
echo "Test 6: find-correction-targets honors --kdir and --json"
FIND_JSON=$("$FIND" --claim-text "resolver supports remediated" --file-line "scripts/consumption-contradiction-resolve.sh:1" --kdir "$KDIR" --json)
assert_eq "find json first path is fixture" "$(echo "$FIND_JSON" | jq -r '.[0].path')" "$ENTRY"

echo ""
echo "Tests complete: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
