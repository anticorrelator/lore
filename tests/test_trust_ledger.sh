#!/usr/bin/env bash
# test_trust_ledger.sh — Tests for the trust-ledger write surface:
# trust-event-append.sh, trust-event-migrate.sh, verify-append.sh.
#
# Covers:
#   - Valid append per event kind → one line in _trust/trust-events.jsonl
#   - event_id dedupe: identical invocation is a silent no-op (both writers)
#   - Grounded-or-nothing on BOTH dispositions (held and contradicted)
#   - Enum rejection: event, source, disposition, result, verdict, reason
#   - Entry-path shape rejection (absolute, traversal)
#   - normalized_snippet_hash recompute-and-reject on mismatch
#   - verify-append contradicted → CC bridge row lands, re-run does not dup
#   - contradicted without CC-bridge fields rejects before any disk write
#   - migrate wrapper delegates and rejects unsanctioned source/reason
#   - Rejections leave no ledger file behind (validate-before-disk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
APPEND="$SCRIPT_DIR/trust-event-append.sh"
MIGRATE="$SCRIPT_DIR/trust-event-migrate.sh"
VERIFY="$SCRIPT_DIR/verify-append.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
LEDGER="$KNOWLEDGE_DIR/_trust/trust-events.jsonl"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/consumption-contradictions.jsonl"
ENTRY="conventions/test-entry.md"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

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

assert_not_exist() {
  local label="$1" filepath="$2"
  if [[ ! -f "$filepath" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — file exists: $filepath"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/_work/$SLUG" "$KNOWLEDGE_DIR/conventions"
  echo '{"format_version": 2}' > "$KNOWLEDGE_DIR/_manifest.json"
  printf '# Test Entry\n\nA claim.\n\n<!-- learned: 2026-07-03 | scale: implementation -->\n' \
    > "$KNOWLEDGE_DIR/$ENTRY"
}

verify_held() {
  "$VERIFY" "$ENTRY" held \
    --source worker \
    --file "/abs/path/to/code.sh" \
    --line-range "10-20" \
    --exact-snippet "foo bar" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

verify_contradicted() {
  "$VERIFY" "$ENTRY" contradicted \
    --source worker \
    --file "/abs/path/to/code.sh" \
    --line-range "30-40" \
    --exact-snippet "baz qux" \
    --work-item "$SLUG" \
    --rationale "code disagrees" \
    --claim-text "the entry claim" \
    --falsifier "evidence X" \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

echo "=== trust-ledger Tests ==="

# =============================================
# Test 1: --help prints usage naming key flags
# =============================================
echo ""
echo "Test 1: --help usage"
OUTPUT=$("$APPEND" --help 2>&1)
assert_contains "append usage names --event" "$OUTPUT" "--event"
assert_contains "append usage names --entry-path" "$OUTPUT" "--entry-path"
assert_contains "append usage names --disposition" "$OUTPUT" "--disposition"
OUTPUT=$("$VERIFY" --help 2>&1)
assert_contains "verify usage names held|contradicted" "$OUTPUT" "held|contradicted"
assert_contains "verify usage names --exact-snippet" "$OUTPUT" "--exact-snippet"
OUTPUT=$("$MIGRATE" --help 2>&1)
assert_contains "migrate usage names --from-entry-path" "$OUTPUT" "--from-entry-path"

# =============================================
# Test 2: held append → one validated ledger row
# =============================================
echo ""
echo "Test 2: held append"
setup_store
OUTPUT=$(verify_held --json)
assert_contains "json reports appended" "$OUTPUT" '"appended": true'
assert_eq "one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
ROW=$(head -1 "$LEDGER")
assert_eq "schema_version 1" "$(echo "$ROW" | jq -r '.schema_version')" "1"
assert_eq "event kind" "$(echo "$ROW" | jq -r '.event')" "consumption-verification"
assert_eq "entry_path" "$(echo "$ROW" | jq -r '.entry_path')" "$ENTRY"
assert_eq "disposition" "$(echo "$ROW" | jq -r '.payload.disposition')" "held"
assert_eq "event_id is 64 hex" "$(echo "$ROW" | jq -r '.event_id | length')" "64"
assert_eq "snippet hash auto-computed" \
  "$(echo "$ROW" | jq -r '.payload.normalized_snippet_hash')" \
  "$(printf '%s' "foo bar" | python3 "$SCRIPT_DIR/snippet_normalize.py" --hash)"
assert_eq "provenance trio present" \
  "$(echo "$ROW" | jq 'has("captured_at_branch") and has("captured_at_sha") and has("captured_at_merge_base_sha")')" "true"

# =============================================
# Test 3: identical held re-run is a dedupe no-op
# =============================================
echo ""
echo "Test 3: held dedupe"
OUTPUT=$(verify_held --json)
assert_contains "json reports duplicate" "$OUTPUT" '"appended": false'
assert_eq "still one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"

# =============================================
# Test 4: contradicted bridges one CC row; re-run no dup on either file
# =============================================
echo ""
echo "Test 4: contradicted bridge + dedupe"
OUTPUT=$(verify_contradicted --json)
assert_contains "bridge status appended" "$OUTPUT" '"status": "appended"'
assert_eq "two ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
assert_eq "one CC row" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"
assert_eq "CC row pending" "$(head -1 "$SIDECAR" | jq -r '.status')" "pending"
assert_eq "CC knowledge_path matches" \
  "$(head -1 "$SIDECAR" | jq -r '.prefetched_commons_entry.knowledge_path')" "$ENTRY"
OUTPUT=$(verify_contradicted --json)
assert_contains "ledger dedupe on re-run" "$OUTPUT" '"appended": false'
assert_eq "still two ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
assert_eq "still one CC row" "$(wc -l < "$SIDECAR" | tr -d ' ')" "1"

# =============================================
# Test 5: grounded-or-nothing on BOTH dispositions; nothing reaches disk
# =============================================
echo ""
echo "Test 5: grounded-or-nothing"
setup_store
for missing in file line-range exact-snippet; do
  set +e
  case "$missing" in
    file)
      OUT=$("$VERIFY" "$ENTRY" held --source worker --line-range 1-2 \
        --exact-snippet s --kdir "$KNOWLEDGE_DIR" 2>&1) ;;
    line-range)
      OUT=$("$VERIFY" "$ENTRY" held --source worker --file /f \
        --exact-snippet s --kdir "$KNOWLEDGE_DIR" 2>&1) ;;
    exact-snippet)
      OUT=$("$VERIFY" "$ENTRY" contradicted --source worker --file /f \
        --line-range 1-2 --work-item "$SLUG" --rationale r --claim-text c \
        --falsifier f --kdir "$KNOWLEDGE_DIR" 2>&1) ;;
  esac
  RC=$?
  set -e
  assert_eq "missing $missing exits 1" "$RC" "1"
  assert_contains "missing $missing names the invariant" "$OUT" "grounded-or-nothing"
done
assert_not_exist "no ledger created by rejections" "$LEDGER"
assert_not_exist "no CC sidecar created by rejections" "$SIDECAR"

# =============================================
# Test 6: contradicted without CC-bridge fields rejects before disk
# =============================================
echo ""
echo "Test 6: contradicted bridge-field validation"
set +e
OUT=$("$VERIFY" "$ENTRY" contradicted --source worker --file /f --line-range 1-2 \
  --exact-snippet s --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "missing bridge fields exits 1" "$RC" "1"
assert_contains "names the missing flag" "$OUT" "--work-item is required"
assert_not_exist "no ledger row from rejected contradicted" "$LEDGER"

# =============================================
# Test 7: enum + shape rejections at the ledger writer
# =============================================
echo ""
echo "Test 7: ledger writer rejections"
setup_store
run_expect_fail() {
  local label="$1" expected="$2"
  shift 2
  set +e
  local out
  out=$("$APPEND" "$@" 2>&1)
  local rc=$?
  set -e
  assert_eq "$label exits 1" "$rc" "1"
  assert_contains "$label message" "$out" "$expected"
}
run_expect_fail "bad event" "--event must be" \
  --event bogus --entry-path "$ENTRY" --source worker --kdir "$KNOWLEDGE_DIR"
run_expect_fail "bad source" "--source must be" \
  --event mechanical-check --entry-path "$ENTRY" --source stranger \
  --check-name n --target t --result pass --run-id r --kdir "$KNOWLEDGE_DIR"
run_expect_fail "bad result" "--result must be" \
  --event mechanical-check --entry-path "$ENTRY" --source drift-sweep \
  --check-name n --target t --result maybe --run-id r --kdir "$KNOWLEDGE_DIR"
run_expect_fail "bad verdict" "--verdict must be" \
  --event adjudication --entry-path "$ENTRY" --source settlement \
  --claim-id c --verdict verified --template-id t --template-version v \
  --run-id r --kdir "$KNOWLEDGE_DIR"
run_expect_fail "absolute entry-path" "must be KDIR-relative" \
  --event mechanical-check --entry-path /abs/x.md --source drift-sweep \
  --check-name n --target t --result pass --run-id r --kdir "$KNOWLEDGE_DIR"
run_expect_fail "traversal entry-path" "must not contain" \
  --event mechanical-check --entry-path "../x.md" --source drift-sweep \
  --check-name n --target t --result pass --run-id r --kdir "$KNOWLEDGE_DIR"
run_expect_fail "snippet hash mismatch" "does not match" \
  --event consumption-verification --entry-path "$ENTRY" --source worker \
  --disposition held --file /f --line-range 1-2 --exact-snippet s \
  --normalized-snippet-hash deadbeef --kdir "$KNOWLEDGE_DIR"
assert_not_exist "no ledger created by rejections" "$LEDGER"

# =============================================
# Test 8: mechanical-check and adjudication appends; run_id forks dedupe
# =============================================
echo ""
echo "Test 8: mechanical-check + adjudication"
"$APPEND" --event mechanical-check --entry-path "$ENTRY" --source drift-sweep \
  --check-name anchor-drift --target 'scripts/foo.sh:10' --result fail \
  --run-id run-1 --kdir "$KNOWLEDGE_DIR" >/dev/null
"$APPEND" --event mechanical-check --entry-path "$ENTRY" --source drift-sweep \
  --check-name anchor-drift --target 'scripts/foo.sh:10' --result fail \
  --run-id run-1 --kdir "$KNOWLEDGE_DIR" >/dev/null
"$APPEND" --event mechanical-check --entry-path "$ENTRY" --source drift-sweep \
  --check-name anchor-drift --target 'scripts/foo.sh:10' --result fail \
  --run-id run-2 --kdir "$KNOWLEDGE_DIR" >/dev/null
assert_eq "same run deduped, new run appended" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
"$APPEND" --event adjudication --entry-path "$ENTRY" --source settlement \
  --claim-id c1 --verdict confirmed --template-id gate --template-version v1 \
  --run-id run-3 --kdir "$KNOWLEDGE_DIR" >/dev/null
assert_eq "adjudication appended" "$(wc -l < "$LEDGER" | tr -d ' ')" "3"
assert_eq "adjudication payload verdict" \
  "$(tail -1 "$LEDGER" | jq -r '.payload.verdict')" "confirmed"

# =============================================
# Test 9: provenance-migration via the migrate wrapper
# =============================================
echo ""
echo "Test 9: provenance-migration"
setup_store
OUTPUT=$("$MIGRATE" --from-entry-path "$ENTRY" \
  --to-entry-path "conventions/test-entry-superseded-2026-07-03.md" \
  --reason l3-supersede --source apply-correction --verdict-id v9 \
  --kdir "$KNOWLEDGE_DIR" --json)
assert_contains "migration appended" "$OUTPUT" '"appended": true'
ROW=$(tail -1 "$LEDGER")
assert_eq "from path" "$(echo "$ROW" | jq -r '.payload.from_entry_path')" "$ENTRY"
assert_eq "entry_path equals to path" \
  "$(echo "$ROW" | jq -r '.entry_path')" \
  "$(echo "$ROW" | jq -r '.payload.to_entry_path')"
assert_eq "verdict_id carried" "$(echo "$ROW" | jq -r '.payload.verdict_id')" "v9"
OUTPUT=$("$MIGRATE" --from-entry-path "$ENTRY" \
  --to-entry-path "conventions/test-entry-superseded-2026-07-03.md" \
  --reason l3-supersede --source apply-correction --verdict-id v9 \
  --kdir "$KNOWLEDGE_DIR" --json)
assert_contains "migration dedupe" "$OUTPUT" '"appended": false'
set +e
OUT=$("$MIGRATE" --from-entry-path a.md --to-entry-path b.md \
  --reason manual-move --source renormalize --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "unsanctioned reason exits 1" "$RC" "1"
set +e
OUT=$("$MIGRATE" --from-entry-path a.md --to-entry-path b.md \
  --reason l3-supersede --source worker --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "unsanctioned source exits 1" "$RC" "1"
assert_contains "unsanctioned source message" "$OUT" "--source must be 'apply-correction' or 'renormalize'"

# =============================================
# Test 10: verify rejects unknown entry and unknown flag
# =============================================
echo ""
echo "Test 10: verify entry/flag validation"
set +e
OUT=$("$VERIFY" conventions/no-such-entry.md held --source worker --file /f \
  --line-range 1-2 --exact-snippet s --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "unknown entry exits 1" "$RC" "1"
assert_contains "unknown entry message" "$OUT" "knowledge entry not found"
set +e
OUT=$("$VERIFY" "$ENTRY" held --source worker --file /f --line-range 1-2 \
  --exact-snippet s --bogus-flag x --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "unknown flag exits 1" "$RC" "1"
assert_contains "unknown flag message" "$OUT" "unknown flag"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
