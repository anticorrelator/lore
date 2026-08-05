#!/usr/bin/env bash
# test_trust_ledger.sh — Tests for the trust-ledger write surface:
# trust-event-append.sh, trust-event-migrate.sh, verify-append.sh, trust-confirm.sh.
#
# Covers:
#   - Valid append per event kind → one line in _trust/trust-events.jsonl
#   - event_id dedupe: identical invocation is a silent no-op (both writers)
#   - Grounded-or-nothing on BOTH dispositions (held and contradicted)
#   - Enum rejection: event, source, disposition, result, verdict, reason
#   - Entry-path shape rejection (absolute, traversal)
#   - normalized_snippet_hash recompute-and-reject on mismatch
#   - verify-append contradicted requires exactly one resolution; the legacy
#     bare form writes nothing anywhere
#   - corrected branch: entry rewritten, status corrected, linked negative
#     event, zero-weight correction event, no CC row, retries converge
#   - disputed branch: dated marker on the entry, linked negative event
#     carrying resolution=disputed, no CC row
#   - disputed-required: low confidence or single-callsite evidence against a
#     scope-exceeding claim exits 3 and writes nothing
#   - migrate wrapper delegates and rejects unsanctioned source/reason
#   - trust confirm front: holds→held mapping, source default, dedupe by sha,
#     new-sha-new-row, usage errors leave nothing appended
#   - trust-confirmation source-enum extension (interactive, coordinator)
#   - Rejections leave no ledger file behind (validate-before-disk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
APPEND="$SCRIPT_DIR/trust-event-append.sh"
MIGRATE="$SCRIPT_DIR/trust-event-migrate.sh"
VERIFY="$SCRIPT_DIR/verify-append.sh"
CONFIRM="$SCRIPT_DIR/trust-confirm.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="test-slug"
LEDGER="$KNOWLEDGE_DIR/_trust/trust-events.jsonl"
SIDECAR="$KNOWLEDGE_DIR/_work/$SLUG/consumption-contradictions.jsonl"
ENTRY="conventions/test-entry.md"
# Two well-formed sha256 digests, used wherever the writer demands the shape
# rather than a particular value.
SHA_A=$(printf 'a' | shasum -a 256 | cut -d' ' -f1)
SHA_B=$(printf 'b' | shasum -a 256 | cut -d' ' -f1)

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

verify_corrected() {
  verify_contradicted \
    --resolution corrected \
    --superseded-text "A claim." \
    --replacement-text "A repaired claim." \
    --confidence high \
    --evidence-scope multi-callsite \
    --claim-scale implementation \
    "$@"
}

verify_disputed() {
  verify_contradicted \
    --resolution disputed \
    --dispute-note "The code disagrees but I could not tell which of two paths the entry means." \
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
assert_contains "verify usage names --resolution" "$OUTPUT" "--resolution"
assert_contains "append usage names the correction kind" "$("$APPEND" --help 2>&1)" "correction"
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
# Test 4: corrected branch — owner on the entry, two linked events, no CC row
# =============================================
echo ""
echo "Test 4: contradicted --resolution corrected"
OUTPUT=$(verify_corrected --json)
assert_eq "resolution reported" "$(echo "$OUTPUT" | jq -r '.resolution')" "corrected"
assert_eq "entry was mutated" "$(echo "$OUTPUT" | jq -r '.entry_action')" "applied"
assert_eq "correction event appended" "$(echo "$OUTPUT" | jq -r '.correction_event_appended')" "true"
CORR_REF=$(echo "$OUTPUT" | jq -r '.resolution_ref')
VER_EVENT=$(echo "$OUTPUT" | jq -r '.event_id')
assert_contains "resolution_ref is a correction id" "$CORR_REF" "corr-"
assert_eq "three ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "3"
assert_not_exist "corrected writes no CC row" "$SIDECAR"

NEG_ROW=$(grep '"disposition":"contradicted"' "$LEDGER" | head -1)
assert_eq "negative event carries the resolution" \
  "$(echo "$NEG_ROW" | jq -r '.payload.resolution')" "corrected"
assert_eq "negative event points at the correction" \
  "$(echo "$NEG_ROW" | jq -r '.payload.resolution_ref')" "$CORR_REF"

CORR_ROW=$(grep '"event":"correction"' "$LEDGER" | head -1)
assert_eq "correction links back to the verification" \
  "$(echo "$CORR_ROW" | jq -r '.payload.verification_event_id')" "$VER_EVENT"
assert_eq "correction id matches the entry record" \
  "$(echo "$CORR_ROW" | jq -r '.payload.correction_id')" "$CORR_REF"
assert_eq "result_status is corrected" \
  "$(echo "$CORR_ROW" | jq -r '.payload.result_status')" "corrected"
assert_eq "before/after hashes differ" \
  "$(echo "$CORR_ROW" | jq -r '.payload.before_sha256 == .payload.after_sha256')" "false"

ENTRY_BODY=$(cat "$KNOWLEDGE_DIR/$ENTRY")
assert_contains "entry body rewritten" "$ENTRY_BODY" "A repaired claim."
assert_contains "entry marked corrected" "$ENTRY_BODY" "status: corrected"
assert_contains "entry records the correction id" "$ENTRY_BODY" "$CORR_REF"

# =============================================
# Test 4b: re-running the corrected transaction converges
# =============================================
echo ""
echo "Test 4b: corrected retry convergence"
OUTPUT=$(verify_corrected --json)
assert_eq "entry mutation is a no-op" "$(echo "$OUTPUT" | jq -r '.entry_action')" "noop"
assert_contains "ledger dedupe on re-run" "$OUTPUT" '"appended": false'
assert_eq "correction event not re-appended" \
  "$(echo "$OUTPUT" | jq -r '.correction_event_appended')" "false"
assert_eq "still three ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "3"
assert_eq "one corrections record on the entry" \
  "$(grep -c "$CORR_REF" "$KNOWLEDGE_DIR/$ENTRY")" "1"
assert_not_exist "still no CC row" "$SIDECAR"

# =============================================
# Test 4c: disputed branch — dated marker, linked event, no CC row
# =============================================
echo ""
echo "Test 4c: contradicted --resolution disputed"
setup_store
OUTPUT=$(verify_disputed --json)
assert_eq "resolution reported" "$(echo "$OUTPUT" | jq -r '.resolution')" "disputed"
assert_eq "marker applied" "$(echo "$OUTPUT" | jq -r '.entry_action')" "applied"
assert_eq "no correction event on the disputed branch" \
  "$(echo "$OUTPUT" | jq -r 'has("correction_event_appended")')" "false"
DISP_REF=$(echo "$OUTPUT" | jq -r '.resolution_ref')
assert_contains "resolution_ref is a dispute id" "$DISP_REF" "disp-"
assert_eq "one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
assert_not_exist "disputed writes no CC row" "$SIDECAR"
assert_eq "negative event carries resolution=disputed" \
  "$(head -1 "$LEDGER" | jq -r '.payload.resolution')" "disputed"

ENTRY_BODY=$(cat "$KNOWLEDGE_DIR/$ENTRY")
assert_contains "marker is dated and in the body" "$ENTRY_BODY" "**Disputed $(date +%Y-%m-%d).**"
assert_contains "marker carries the reason" "$ENTRY_BODY" "could not tell which of two paths"
assert_contains "marker records provenance" "$ENTRY_BODY" "Reported by worker"
assert_contains "entry records the dispute id" "$ENTRY_BODY" "$DISP_REF"
assert_eq "disputed leaves the entry status alone" \
  "$(grep -c 'status: disputed' "$KNOWLEDGE_DIR/$ENTRY" || true)" "0"

OUTPUT=$(verify_disputed --json)
assert_eq "marker re-run is a no-op" "$(echo "$OUTPUT" | jq -r '.entry_action')" "noop"
assert_eq "one dispute record on the entry" \
  "$(grep -c "$DISP_REF" "$KNOWLEDGE_DIR/$ENTRY")" "1"

# =============================================
# Test 4d: disputed-required — nothing is written either way
# =============================================
echo ""
echo "Test 4d: disputed-required fork"
setup_store
set +e
OUT=$(verify_corrected --confidence low 2>&1)
RC=$?
set -e
assert_eq "low confidence exits 3" "$RC" "3"
assert_contains "names the outcome" "$OUT" "disputed-required"
assert_not_exist "low confidence writes no ledger" "$LEDGER"

set +e
OUT=$("$VERIFY" "$ENTRY" contradicted --source worker --file /f --line-range 1-2 \
  --exact-snippet s --work-item "$SLUG" --rationale r --claim-text c --falsifier f \
  --resolution corrected --superseded-text "A claim." --replacement-text "New." \
  --confidence high --evidence-scope single-callsite --claim-scale architecture \
  --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "altitude test exits 3" "$RC" "3"
assert_contains "names the scale that failed" "$OUT" "architecture scale"
assert_not_exist "altitude failure writes no ledger" "$LEDGER"
assert_eq "entry untouched by either fork" \
  "$(grep -c 'Disputed\|corrections:' "$KNOWLEDGE_DIR/$ENTRY" || true)" "0"

# Correcting an implementation-scale claim from one callsite is fine.
OUTPUT=$(verify_corrected --evidence-scope single-callsite --claim-scale implementation --json)
assert_eq "single callsite settles an implementation claim" \
  "$(echo "$OUTPUT" | jq -r '.resolution')" "corrected"

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
        --falsifier f --resolution disputed --dispute-note n \
        --kdir "$KNOWLEDGE_DIR" 2>&1) ;;
  esac
  RC=$?
  set -e
  assert_eq "missing $missing exits 1" "$RC" "1"
  assert_contains "missing $missing names the invariant" "$OUT" "grounded-or-nothing"
done
assert_not_exist "no ledger created by rejections" "$LEDGER"
assert_not_exist "no CC sidecar created by rejections" "$SIDECAR"

# =============================================
# Test 6: contradicted branch-field validation, all before any disk write
# =============================================
echo ""
echo "Test 6: contradicted branch-field validation"
set +e
OUT=$("$VERIFY" "$ENTRY" contradicted --source worker --file /f --line-range 1-2 \
  --exact-snippet s --kdir "$KNOWLEDGE_DIR" 2>&1)
RC=$?
set -e
assert_eq "missing observation fields exits 1" "$RC" "1"
assert_contains "names the missing flag" "$OUT" "--work-item is required"
assert_not_exist "no ledger row from rejected contradicted" "$LEDGER"

# The legacy form — a contradiction with no resolution — must write nothing at
# all: no ledger row, no sidecar row, no entry change.
set +e
OUT=$(verify_contradicted 2>&1)
RC=$?
set -e
assert_eq "no resolution exits 1" "$RC" "1"
assert_contains "asks what was done about it" "$OUT" "--resolution is required"
assert_not_exist "legacy form writes no ledger" "$LEDGER"
assert_not_exist "legacy form writes no CC row" "$SIDECAR"
assert_eq "legacy form leaves the entry alone" \
  "$(grep -c 'Disputed\|corrections:' "$KNOWLEDGE_DIR/$ENTRY" || true)" "0"

set +e
OUT=$(verify_contradicted --resolution bogus 2>&1); RC=$?
set -e
assert_eq "unknown resolution exits 1" "$RC" "1"
assert_contains "names the resolution enum" "$OUT" "must be 'corrected' or 'disputed'"

set +e
OUT=$(verify_contradicted --resolution corrected --confidence high \
  --evidence-scope multi-callsite --claim-scale implementation 2>&1); RC=$?
set -e
assert_eq "corrected without replacement text exits 1" "$RC" "1"
assert_contains "names the missing text flag" "$OUT" "--superseded-text is required"

set +e
OUT=$(verify_contradicted --resolution disputed 2>&1); RC=$?
set -e
assert_eq "disputed without a note exits 1" "$RC" "1"
assert_contains "asks for the note" "$OUT" "--dispute-note is required"

set +e
OUT=$(verify_held --resolution corrected 2>&1); RC=$?
set -e
assert_eq "resolution on held exits 1" "$RC" "1"
assert_contains "held rejects a resolution" "$OUT" "applies only to disposition 'contradicted'"
assert_not_exist "no ledger from any branch rejection" "$LEDGER"

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
# Resolution-or-nothing is enforced at the physical writer too, so a bare
# decrement is not expressible even by a caller that skips the verify front.
run_expect_fail "contradicted without resolution" "--resolution is required" \
  --event consumption-verification --entry-path "$ENTRY" --source worker \
  --disposition contradicted --file /f --line-range 1-2 --exact-snippet s \
  --kdir "$KNOWLEDGE_DIR"
run_expect_fail "contradicted without resolution-ref" "--resolution-ref is required" \
  --event consumption-verification --entry-path "$ENTRY" --source worker \
  --disposition contradicted --file /f --line-range 1-2 --exact-snippet s \
  --resolution corrected --kdir "$KNOWLEDGE_DIR"
run_expect_fail "bad resolution value" "--resolution must be" \
  --event consumption-verification --entry-path "$ENTRY" --source worker \
  --disposition contradicted --file /f --line-range 1-2 --exact-snippet s \
  --resolution settled --resolution-ref x --kdir "$KNOWLEDGE_DIR"
run_expect_fail "resolution on held" "apply only to --disposition contradicted" \
  --event consumption-verification --entry-path "$ENTRY" --source worker \
  --disposition held --file /f --line-range 1-2 --exact-snippet s \
  --resolution corrected --resolution-ref x --kdir "$KNOWLEDGE_DIR"
run_expect_fail "correction without verification link" "--verification-event-id is required" \
  --event correction --entry-path "$ENTRY" --source worker \
  --correction-id corr-1 --claim-id c --correction-date 2026-08-05 \
  --before-sha256 "$SHA_A" --after-sha256 "$SHA_B" \
  --prior-status current --result-status corrected --kdir "$KNOWLEDGE_DIR"
run_expect_fail "correction with a short verification id" "64-char sha256" \
  --event correction --entry-path "$ENTRY" --source worker \
  --correction-id corr-1 --verification-event-id abc123 --claim-id c \
  --correction-date 2026-08-05 --before-sha256 "$SHA_A" --after-sha256 "$SHA_B" \
  --prior-status current --result-status corrected --kdir "$KNOWLEDGE_DIR"
run_expect_fail "correction with a malformed date" "YYYY-MM-DD" \
  --event correction --entry-path "$ENTRY" --source worker \
  --correction-id corr-1 --verification-event-id "$SHA_A" --claim-id c \
  --correction-date "Aug 5" --before-sha256 "$SHA_A" --after-sha256 "$SHA_B" \
  --prior-status current --result-status corrected --kdir "$KNOWLEDGE_DIR"
run_expect_fail "correction with a non-corrected result" "--result-status must be" \
  --event correction --entry-path "$ENTRY" --source worker \
  --correction-id corr-1 --verification-event-id "$SHA_A" --claim-id c \
  --correction-date 2026-08-05 --before-sha256 "$SHA_A" --after-sha256 "$SHA_B" \
  --prior-status current --result-status disputed --kdir "$KNOWLEDGE_DIR"
assert_not_exist "no ledger created by rejections" "$LEDGER"

# =============================================
# Test 7b: correction appends once per verification event
# =============================================
echo ""
echo "Test 7b: correction event dedupe"
setup_store
append_correction() {
  "$APPEND" --event correction --entry-path "$ENTRY" --source worker \
    --correction-id corr-abc123456789 --verification-event-id "$1" \
    --claim-id ver-1 --correction-date 2026-08-05 \
    --before-sha256 "$SHA_A" --after-sha256 "$SHA_B" \
    --before-text "A claim." --after-text "A repaired claim." \
    --prior-status current --result-status corrected --work-item "$SLUG" \
    --kdir "$KNOWLEDGE_DIR" --json
}
OUTPUT=$(append_correction "$SHA_A")
assert_contains "correction appended" "$OUTPUT" '"appended": true'
ROW=$(head -1 "$LEDGER")
assert_eq "event kind" "$(echo "$ROW" | jq -r '.event')" "correction"
assert_eq "carries the verification link" \
  "$(echo "$ROW" | jq -r '.payload.verification_event_id')" "$SHA_A"
assert_eq "carries before/after text" \
  "$(echo "$ROW" | jq -r '.payload.after_text')" "A repaired claim."
OUTPUT=$(append_correction "$SHA_A")
assert_contains "same verification event dedupes" "$OUTPUT" '"appended": false'
assert_eq "still one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
OUTPUT=$(append_correction "$SHA_B")
assert_contains "a different verification event is a new row" "$OUTPUT" '"appended": true'
assert_eq "two ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"

# =============================================
# Test 8: mechanical-check and adjudication appends; run_id forks dedupe
# =============================================
echo ""
echo "Test 8: mechanical-check + adjudication"
setup_store
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
# Test 11: trust confirm front — append, dedupe by sha, new-sha-new-row
# =============================================
echo ""
echo "Test 11: trust confirm front"
setup_store
OUTPUT=$("$CONFIRM" "$ENTRY" --sha abc1234 --verdict holds --kdir "$KNOWLEDGE_DIR" --json)
assert_contains "confirm reports appended" "$OUTPUT" '"appended": true'
assert_eq "one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
ROW=$(head -1 "$LEDGER")
assert_eq "event kind" "$(echo "$ROW" | jq -r '.event')" "trust-confirmation"
assert_eq "verdict mapped holds->held" "$(echo "$ROW" | jq -r '.payload.verdict')" "held"
assert_eq "sha recorded verbatim" "$(echo "$ROW" | jq -r '.payload.sha')" "abc1234"
assert_eq "source defaults to interactive" "$(echo "$ROW" | jq -r '.source')" "interactive"
assert_eq "note omitted when empty" "$(echo "$ROW" | jq -r '.payload | has("note")')" "false"
# Identical re-run (same entry+verdict+source+sha) heals to a no-op.
OUTPUT=$("$CONFIRM" "$ENTRY" --sha abc1234 --verdict holds --kdir "$KNOWLEDGE_DIR" --json)
assert_contains "identical re-run dedupes" "$OUTPUT" '"appended": false'
assert_eq "still one ledger line" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
# A new sha is a new observation → a new row.
OUTPUT=$("$CONFIRM" "$ENTRY" --sha def5678 --verdict contradicted \
  --note "cheap dispute" --source coordinator --kdir "$KNOWLEDGE_DIR" --json)
assert_contains "new sha appends" "$OUTPUT" '"appended": true'
assert_eq "two ledger lines" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
ROW=$(tail -1 "$LEDGER")
assert_eq "contradicted verdict recorded" "$(echo "$ROW" | jq -r '.payload.verdict')" "contradicted"
assert_eq "note carried" "$(echo "$ROW" | jq -r '.payload.note')" "cheap dispute"
assert_eq "coordinator source accepted" "$(echo "$ROW" | jq -r '.source')" "coordinator"

# =============================================
# Test 12: trust confirm front — usage errors leave nothing appended
# =============================================
echo ""
echo "Test 12: trust confirm usage errors"
setup_store
confirm_expect_fail() {
  local label="$1" expected="$2"
  shift 2
  set +e
  local out
  out=$("$CONFIRM" "$@" 2>&1)
  local rc=$?
  set -e
  assert_eq "$label exits 1" "$rc" "1"
  assert_contains "$label message" "$out" "$expected"
}
confirm_expect_fail "missing --sha" "--sha is required" \
  "$ENTRY" --verdict holds --kdir "$KNOWLEDGE_DIR"
confirm_expect_fail "bad verdict" "--verdict must be 'holds' or 'contradicted'" \
  "$ENTRY" --sha abc1234 --verdict maybe --kdir "$KNOWLEDGE_DIR"
confirm_expect_fail "malformed sha" "hex string of at least 7" \
  "$ENTRY" --sha xyz --verdict holds --kdir "$KNOWLEDGE_DIR"
confirm_expect_fail "unknown flag" "unknown flag" \
  "$ENTRY" --sha abc1234 --verdict holds --bogus x --kdir "$KNOWLEDGE_DIR"
confirm_expect_fail "missing entry" "knowledge entry not found" \
  "conventions/no-such-entry.md" --sha abc1234 --verdict holds --kdir "$KNOWLEDGE_DIR"
assert_not_exist "no ledger created by rejections" "$LEDGER"

# =============================================
# Test 13: appender trust-confirmation validation + source-enum extension
# =============================================
echo ""
echo "Test 13: appender trust-confirmation"
setup_store
"$APPEND" --event trust-confirmation --entry-path "$ENTRY" --source interactive \
  --verdict held --sha abc1234 --kdir "$KNOWLEDGE_DIR" >/dev/null
assert_eq "interactive source accepted" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
"$APPEND" --event trust-confirmation --entry-path "$ENTRY" --source coordinator \
  --verdict contradicted --sha def5678 --kdir "$KNOWLEDGE_DIR" >/dev/null
assert_eq "coordinator source accepted" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
# The appender owns the schema: unmapped surface vocab and a missing/bad sha reject.
run_expect_fail "confirm unmapped verdict" "--verdict must be 'held' or 'contradicted'" \
  --event trust-confirmation --entry-path "$ENTRY" --source interactive \
  --verdict holds --sha abc1234 --kdir "$KNOWLEDGE_DIR"
run_expect_fail "confirm missing sha" "--sha is required" \
  --event trust-confirmation --entry-path "$ENTRY" --source interactive \
  --verdict held --kdir "$KNOWLEDGE_DIR"
run_expect_fail "confirm malformed sha" "hex string of at least 7" \
  --event trust-confirmation --entry-path "$ENTRY" --source interactive \
  --verdict held --sha nothex --kdir "$KNOWLEDGE_DIR"

# =============================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
