#!/usr/bin/env bash
# test_entry_retirement.sh — Tests for the entry-retirement write path:
# retire-append.sh, apply-correction.sh --retire/--restore, the `retirement`
# ledger kind, its zero weight in the fold, and its verify-report section.
#
# Covers:
#   - Retire writes a dated marker naming the reason and the falsifier, sets
#     status: retired, and records the prior status in retirements[]
#   - One retirement ledger row per act, with the reason, falsifier, and the
#     reported inbound-backlink count in its payload
#   - Inbound backlinks are reported, never gating: an entry others link to
#     retires anyway
#   - Missing --falsifier (or --reason) refuses before the first write: entry
#     and ledger both byte-identical afterwards
#   - Repeating either invocation converges: no second marker, no second row
#   - Interrupted transaction (entry mutated, event missing) converges on a
#     repeat — the same event id lands, the entry is untouched
#   - Restore returns the recorded prior status, not a hardcoded 'current'
#   - Restore takes --note and nothing else: no confidence, evidence-scope, or
#     claim-scale flag exists, and no check on who retired the entry
#   - Restoring an entry that is not retired refuses and writes nothing
#   - retire -> restore -> retire appends three distinct rows
#   - Retirement rows are counted and weightless in the trust fold
#   - `lore verify --report` lists both directions with their reasons
#   - `lore retire` reaches the front through the CLI dispatch arm

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
RETIRE="$SCRIPT_DIR/retire-append.sh"
MUTATE="$SCRIPT_DIR/apply-correction.sh"
APPEND="$SCRIPT_DIR/trust-event-append.sh"
REPORT="$SCRIPT_DIR/verify-report.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
FAKE_HOME="$TEST_DIR/home"
LEDGER="$KNOWLEDGE_DIR/_trust/trust-events.jsonl"
ENTRY="conventions/queue-entry.md"
CITING_ENTRY="conventions/citing-entry.md"
REASON="The dispute queue this describes was removed; nothing in the tree reads it."
FALSIFIER="A live caller of the queue drain script still exists."
NOTE="Needed while auditing what the removal commit took with it."

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

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Expected NOT to contain: $unexpected"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
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

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions"
  printf '# Queue Entry\n\nThe dispute queue drains oldest-first.\n\n<!-- learned: 2026-07-03 | scale: implementation | status: corrected -->\n' \
    > "$KNOWLEDGE_DIR/$ENTRY"
  printf '# Citing Entry\n\nSee [[knowledge:conventions/queue-entry]] for the drain order.\n\n<!-- learned: 2026-07-03 | scale: implementation -->\n' \
    > "$KNOWLEDGE_DIR/$CITING_ENTRY"
  python3 - "$KNOWLEDGE_DIR" <<'MANIFEST_PY'
import json, os, sys
kdir = sys.argv[1]
manifest = {
    "format_version": 2,
    "entries": [
        {"path": "conventions/queue-entry.md", "backlinks": []},
        {"path": "conventions/citing-entry.md",
         "backlinks": ["knowledge:conventions/queue-entry"]},
    ],
}
with open(os.path.join(kdir, "_manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f)
MANIFEST_PY
}

retire_entry() {
  "$RETIRE" "$ENTRY" \
    --reason "$REASON" \
    --falsifier "$FALSIFIER" \
    --source worker \
    --work-item retirement-test \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

restore_entry() {
  "$RETIRE" "$ENTRY" --restore \
    --note "$NOTE" \
    --source interactive \
    --kdir "$KNOWLEDGE_DIR" \
    "$@"
}

ledger_lines() {
  if [[ -f "$LEDGER" ]]; then
    wc -l < "$LEDGER" | tr -d ' '
  else
    echo 0
  fi
}

file_sha() {
  if [[ -f "$1" ]]; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "absent"
  fi
}

echo "=== entry-retirement Tests ==="

# =============================================
# Test 1: --help names what each direction costs
# =============================================
echo ""
echo "Test 1: --help usage"
OUTPUT=$("$RETIRE" --help 2>&1)
assert_contains "front usage names --reason" "$OUTPUT" "--reason"
assert_contains "front usage names --falsifier" "$OUTPUT" "--falsifier"
assert_contains "front usage names --restore" "$OUTPUT" "--restore"
assert_contains "front usage names --note" "$OUTPUT" "--note"
assert_contains "front usage names the opt-in status flag" "$OUTPUT" "--include-status retired"
OUTPUT=$("$MUTATE" --help 2>&1)
assert_contains "mutator usage names retire mode" "$OUTPUT" "Retire mode:"
assert_contains "mutator usage names restore mode" "$OUTPUT" "Restore mode:"

# =============================================
# Test 2: retire — marker, status, prior status, one ledger row
# =============================================
echo ""
echo "Test 2: retire"
setup_store
OUTPUT=$(retire_entry --date 2026-08-06 2>&1)
BODY=$(cat "$KNOWLEDGE_DIR/$ENTRY")
assert_contains "dated marker in the body" "$BODY" "**Retired 2026-08-06.**"
assert_contains "marker names the reason" "$BODY" "$REASON"
assert_contains "marker names the falsifier" "$BODY" "Overturned if: $FALSIFIER"
assert_contains "marker names the way back" "$BODY" "--restore --note"
assert_contains "META status is retired" "$BODY" "status: retired"
assert_contains "retirements[] records the prior status" "$BODY" '"prior_status": "corrected"'
assert_contains "the entry file is still on disk" "$BODY" "The dispute queue drains oldest-first."
assert_eq "one ledger row" "$(ledger_lines)" "1"
ROW=$(head -1 "$LEDGER")
assert_eq "event kind" "$(echo "$ROW" | jq -r '.event')" "retirement"
assert_eq "action" "$(echo "$ROW" | jq -r '.payload.action')" "retired"
assert_eq "prior_status in the payload" "$(echo "$ROW" | jq -r '.payload.prior_status')" "corrected"
assert_eq "result_status in the payload" "$(echo "$ROW" | jq -r '.payload.result_status')" "retired"
assert_eq "reason in the payload" "$(echo "$ROW" | jq -r '.payload.reason')" "$REASON"
assert_eq "falsifier in the payload" "$(echo "$ROW" | jq -r '.payload.falsifier')" "$FALSIFIER"
assert_eq "work item in the payload" "$(echo "$ROW" | jq -r '.payload.work_item')" "retirement-test"
RET_ID=$(echo "$ROW" | jq -r '.payload.retirement_id')
assert_contains "retirement id is a ret- id" "$RET_ID" "ret-"
assert_eq "event_id is 64 hex" "$(echo "$ROW" | jq -r '.event_id | length')" "64"

# =============================================
# Test 3: inbound backlinks are reported, never gating
# =============================================
echo ""
echo "Test 3: inbound backlinks reported, not gating"
assert_contains "count reported to the retiring agent" "$OUTPUT" "1 other entry links here"
assert_eq "count carried on the ledger row" \
  "$(echo "$ROW" | jq -r '.payload.inbound_backlinks')" "1"
assert_contains "retirement was not refused" "$OUTPUT" "retired ($RET_ID)"

# =============================================
# Test 4: repeating the retirement converges
# =============================================
echo ""
echo "Test 4: retire is idempotent"
BEFORE=$(file_sha "$KNOWLEDGE_DIR/$ENTRY")
OUTPUT=$(retire_entry --date 2026-08-06 2>&1)
assert_contains "reports a no-op" "$OUTPUT" "was already retired"
assert_eq "entry untouched" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$BEFORE"
assert_eq "still one ledger row" "$(ledger_lines)" "1"
assert_eq "exactly one Retired marker" \
  "$(grep -c '\*\*Retired' "$KNOWLEDGE_DIR/$ENTRY" || true)" "1"

# =============================================
# Test 5: interrupted transaction converges on a repeat
# =============================================
# The entry is mutated before the event is appended, so an interruption between
# the two leaves a marker with no event. Repeating the same invocation must
# append the missing event under the same id without touching the entry again.
echo ""
echo "Test 5: interrupted transaction"
EVENT_ID=$(head -1 "$LEDGER" | jq -r '.event_id')
: > "$LEDGER"
BEFORE=$(file_sha "$KNOWLEDGE_DIR/$ENTRY")
OUTPUT=$(retire_entry --date 2026-08-06 --json 2>&1)
assert_eq "entry still untouched" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$BEFORE"
assert_eq "the missing event landed" "$(ledger_lines)" "1"
assert_eq "under the same event id" "$(head -1 "$LEDGER" | jq -r '.event_id')" "$EVENT_ID"
assert_eq "and the same retirement id" \
  "$(head -1 "$LEDGER" | jq -r '.payload.retirement_id')" "$RET_ID"

# =============================================
# Test 6: restore returns the recorded prior status
# =============================================
echo ""
echo "Test 6: restore"
OUTPUT=$(restore_entry --date 2026-08-07 2>&1)
BODY=$(cat "$KNOWLEDGE_DIR/$ENTRY")
assert_contains "dated restore marker" "$BODY" "**Restored 2026-08-07.**"
assert_contains "restore marker names the note" "$BODY" "$NOTE"
assert_contains "restore marker names the retirement it reverses" "$BODY" "$RET_ID"
assert_contains "status returns to the recorded prior status" "$BODY" "status: corrected"
assert_contains "the retirement record is kept" "$BODY" '"retirement_id": "'"$RET_ID"'"'
assert_eq "second ledger row" "$(ledger_lines)" "2"
ROW=$(tail -1 "$LEDGER")
assert_eq "action" "$(echo "$ROW" | jq -r '.payload.action')" "restored"
assert_eq "result_status is the prior status, not 'current'" \
  "$(echo "$ROW" | jq -r '.payload.result_status')" "corrected"
assert_eq "note in the payload" "$(echo "$ROW" | jq -r '.payload.note')" "$NOTE"
assert_eq "restores_retirement_id points back" \
  "$(echo "$ROW" | jq -r '.payload.restores_retirement_id')" "$RET_ID"
RES_ID=$(echo "$ROW" | jq -r '.payload.retirement_id')
assert_contains "restoration id is a res- id" "$RES_ID" "res-"
# A different --source than the one that retired it restores without complaint.
assert_contains "no check on who retired the entry" "$OUTPUT" "restored to status corrected"

# =============================================
# Test 7: restore takes a note and nothing else
# =============================================
echo ""
echo "Test 7: restore has no second gate"
for flag in --confidence --evidence-scope --claim-scale; do
  set +e
  OUT=$("$RETIRE" "$ENTRY" --restore --note "$NOTE" --source worker \
    "$flag" high --kdir "$KNOWLEDGE_DIR" 2>&1)
  STATUS=$?
  set -e
  assert_eq "$flag is not a flag of this verb (exit 1)" "$STATUS" "1"
  assert_contains "$flag rejected as unknown" "$OUT" "unknown flag '$flag'"
done

# =============================================
# Test 8: repeating the restore converges
# =============================================
echo ""
echo "Test 8: restore is idempotent"
BEFORE=$(file_sha "$KNOWLEDGE_DIR/$ENTRY")
OUTPUT=$(restore_entry --date 2026-08-07 2>&1)
assert_contains "reports a no-op" "$OUTPUT" "was already restored"
assert_eq "entry untouched" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$BEFORE"
assert_eq "still two ledger rows" "$(ledger_lines)" "2"

# =============================================
# Test 9: retire -> restore -> retire appends three distinct rows
# =============================================
echo ""
echo "Test 9: a second retirement is its own act"
OUTPUT=$("$RETIRE" "$ENTRY" \
  --reason "Second look: still describes a subsystem that is gone." \
  --falsifier "Someone cites this entry from a new work item." \
  --source worker --kdir "$KNOWLEDGE_DIR" --date 2026-08-08 2>&1)
assert_eq "third ledger row" "$(ledger_lines)" "3"
SECOND_RET_ID=$(tail -1 "$LEDGER" | jq -r '.payload.retirement_id')
if [[ "$SECOND_RET_ID" != "$RET_ID" ]]; then
  echo "  PASS: the second retirement carries a fresh id"
  PASS=$((PASS + 1))
else
  echo "  FAIL: the second retirement reused $RET_ID"
  FAIL=$((FAIL + 1))
fi
assert_eq "three distinct event ids" \
  "$(jq -r '.event_id' "$LEDGER" | sort -u | wc -l | tr -d ' ')" "3"

# =============================================
# Test 10: retirement rows are counted and weightless
# =============================================
echo ""
echo "Test 10: zero weight in the fold"
OUTPUT=$(python3 "$SCRIPT_DIR/trust-compute.py" "$KNOWLEDGE_DIR" --entry "$ENTRY" --json)
assert_eq "signal unmoved by two retirements and a restoration" \
  "$(echo "$OUTPUT" | jq -r ".entries[\"$ENTRY\"].signal == 0")" "true"
assert_eq "retired counted" \
  "$(echo "$OUTPUT" | jq -r ".entries[\"$ENTRY\"].counts.retired")" "2"
assert_eq "restored counted" \
  "$(echo "$OUTPUT" | jq -r ".entries[\"$ENTRY\"].counts.restored")" "1"
assert_eq "no fold warnings" "$(echo "$OUTPUT" | jq -r '.warnings | length')" "0"

# =============================================
# Test 11: verify --report projects both directions
# =============================================
echo ""
echo "Test 11: verify-report retirement section"
OUTPUT=$("$REPORT" --entry "$ENTRY" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)
assert_contains "section header with both counts" "$OUTPUT" "retirements: 2 retired, 1 restored"
assert_contains "the reason is in the report" "$OUTPUT" "reason: $REASON"
assert_contains "the falsifier is in the report" "$OUTPUT" "overturned if: $FALSIFIER"
assert_contains "the restore note is in the report" "$OUTPUT" "note: $NOTE"
assert_contains "the reversal is legible" "$OUTPUT" "reverses: $RET_ID"
JSON=$("$REPORT" --entry "$ENTRY" --kdir "$KNOWLEDGE_DIR" --json 2>/dev/null)
assert_eq "json carries the retirement events" \
  "$(echo "$JSON" | jq -r '.entries[0].retirements.events | length')" "3"

# =============================================
# Test 12: a retirement with no falsifier is refused before any write
# =============================================
echo ""
echo "Test 12: missing falsifier writes nothing"
setup_store
ENTRY_BEFORE=$(file_sha "$KNOWLEDGE_DIR/$ENTRY")
LEDGER_BEFORE=$(file_sha "$LEDGER")
set +e
OUTPUT=$("$RETIRE" "$ENTRY" --reason "$REASON" --source worker \
  --kdir "$KNOWLEDGE_DIR" 2>&1)
STATUS=$?
set -e
assert_eq "exits non-zero" "$STATUS" "1"
assert_contains "the error says what is missing" "$OUTPUT" "--falsifier is required"
assert_eq "entry byte-identical" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$ENTRY_BEFORE"
assert_eq "ledger byte-identical" "$(file_sha "$LEDGER")" "$LEDGER_BEFORE"
# Whitespace is not a falsifier.
set +e
OUTPUT=$("$RETIRE" "$ENTRY" --reason "$REASON" --falsifier "   " --source worker \
  --kdir "$KNOWLEDGE_DIR" 2>&1)
STATUS=$?
set -e
assert_eq "blank falsifier also refused" "$STATUS" "1"
assert_eq "entry still byte-identical" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$ENTRY_BEFORE"
assert_eq "ledger still byte-identical" "$(file_sha "$LEDGER")" "$LEDGER_BEFORE"

# =============================================
# Test 13: a retirement with no reason is refused the same way
# =============================================
echo ""
echo "Test 13: missing reason writes nothing"
set +e
OUTPUT=$("$RETIRE" "$ENTRY" --falsifier "$FALSIFIER" --source worker \
  --kdir "$KNOWLEDGE_DIR" 2>&1)
STATUS=$?
set -e
assert_eq "exits non-zero" "$STATUS" "1"
assert_contains "the error says what is missing" "$OUTPUT" "--reason is required"
assert_eq "entry byte-identical" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$ENTRY_BEFORE"
assert_eq "ledger byte-identical" "$(file_sha "$LEDGER")" "$LEDGER_BEFORE"

# =============================================
# Test 14: restoring an entry that is not retired
# =============================================
echo ""
echo "Test 14: nothing to restore"
set +e
OUTPUT=$(restore_entry 2>&1)
STATUS=$?
set -e
assert_eq "exits non-zero" "$STATUS" "2"
assert_contains "the error says why" "$OUTPUT" "is not retired"
assert_eq "entry byte-identical" "$(file_sha "$KNOWLEDGE_DIR/$ENTRY")" "$ENTRY_BEFORE"
assert_eq "ledger byte-identical" "$(file_sha "$LEDGER")" "$LEDGER_BEFORE"
set +e
OUTPUT=$("$RETIRE" "$ENTRY" --restore --source worker --kdir "$KNOWLEDGE_DIR" 2>&1)
STATUS=$?
set -e
assert_eq "restore without a note is refused" "$STATUS" "1"
assert_contains "the error asks for the note" "$OUTPUT" "--note is required"

# =============================================
# Test 15: the ledger writer owns the retirement schema
# =============================================
echo ""
echo "Test 15: ledger-level validation"
run_expect_fail() {
  local label="$1" expected="$2"
  shift 2
  set +e
  local out
  out=$("$APPEND" "$@" 2>&1)
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    echo "  FAIL: $label — expected non-zero exit"
    FAIL=$((FAIL + 1))
    return
  fi
  assert_contains "$label" "$out" "$expected"
}
run_expect_fail "retirement without a falsifier" "--falsifier is required" \
  --event retirement --entry-path "$ENTRY" --source worker \
  --action retired --retirement-id ret-000000000000 \
  --prior-status current --result-status retired --reason "r" \
  --kdir "$KNOWLEDGE_DIR"
run_expect_fail "unknown action" "--action must be 'retired' or 'restored'" \
  --event retirement --entry-path "$ENTRY" --source worker \
  --action archived --retirement-id ret-000000000000 \
  --prior-status current --result-status retired \
  --reason "r" --falsifier "f" --kdir "$KNOWLEDGE_DIR"
run_expect_fail "restore carrying a retirement's flags" "applies only to --action retired" \
  --event retirement --entry-path "$ENTRY" --source worker \
  --action restored --retirement-id res-000000000000 \
  --restores-retirement-id ret-000000000000 --note "n" --reason "r" \
  --prior-status retired --result-status current --kdir "$KNOWLEDGE_DIR"
assert_eq "no rejected row reached disk" "$(ledger_lines)" "0"

# =============================================
# Test 16: `lore retire` reaches the front
# =============================================
echo ""
echo "Test 16: CLI dispatch"
setup_store
mkdir -p "$FAKE_HOME/.lore"
ln -sfn "$SCRIPT_DIR" "$FAKE_HOME/.lore/scripts"
OUTPUT=$(HOME="$FAKE_HOME" bash "$REPO_DIR/cli/lore" retire "$ENTRY" \
  --reason "$REASON" --falsifier "$FALSIFIER" --source interactive \
  --kdir "$KNOWLEDGE_DIR" --date 2026-08-06 2>&1)
assert_contains "the verb dispatches to the front" "$OUTPUT" "retired"
assert_eq "and the transaction completed" "$(ledger_lines)" "1"
assert_contains "the entry carries the marker" \
  "$(cat "$KNOWLEDGE_DIR/$ENTRY")" "**Retired 2026-08-06.**"
HELP=$(HOME="$FAKE_HOME" bash "$REPO_DIR/cli/lore" --help 2>&1)
assert_contains "the verb is listed in lore --help" "$HELP" "retire"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
