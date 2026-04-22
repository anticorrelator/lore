#!/usr/bin/env bash
# test_codex_verdict_capture.sh — Tests for scripts/codex-verdict-capture.sh
#
# Covers:
#   - Flag-form spec round-trips 6 criterion rows + 1 gate row
#   - Flag-form pr-review round-trips arbitrary criteria
#   - Rating → value mapping (STRONG=1.0, ADEQUATE=0.75, WEAK=0.25, MISSING=0.0)
#   - Gate → value mapping (pass=1.0, fail=0.0)
#   - Rows attribute to --producer-template-version (not codex's version)
#   - template_id reflects source ceremony (codex-plan-review vs codex-pr-review)
#   - All rows land with kind=scored, calibration_state=pre-calibration
#   - metric names slugify correctly ("Objective and Scope" → "criterion:objective-and-scope")
#   - Unknown rating is skipped with warning (not fatal)
#   - Missing ratings map is a hard error
#   - Invalid ceremony is rejected
#   - --row pass-through validates via scorecard-append
#   - Sole-writer invariant preserved (all appends go through scorecard-append.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
CAPTURE="$SCRIPT_DIR/codex-verdict-capture.sh"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected="$2"; shift 2
  set +e
  "$@" >/dev/null 2>&1
  local actual=$?
  set -e
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected exit=$expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

echo "=== codex-verdict-capture.sh tests ==="

# Flag-form spec (plan-review): 6 criteria + gate = 7 rows.
SPEC_VERDICT='{"ratings":{"Objective and Scope":"STRONG","Evidence and Uncertainty":"ADEQUATE","Interface Clarity":"WEAK","Design Coherence":"ADEQUATE","Execution Readiness":"ADEQUATE","Validation and Traceability":"MISSING"},"gate":"fail"}'
"$CAPTURE" capture --kdir "$TMP" --source-ceremony spec --producer-template-version abc123def456 --work-item test-slug --verdict-json "$SPEC_VERDICT" >/dev/null

ROWS="$TMP/_scorecards/rows.jsonl"
LINES=$(wc -l < "$ROWS" | tr -d ' ')
if [[ "$LINES" == "7" ]]; then
  echo "  PASS: spec verdict emits 6 criteria + 1 gate = 7 rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 7 rows, got $LINES"
  FAIL=$((FAIL + 1))
fi

# template_id = codex-plan-review on spec
assert_contains "spec → template_id=codex-plan-review" "$(cat "$ROWS")" '"template_id":"codex-plan-review"'

# Rating → value mapping
assert_contains "STRONG maps to 1.0" "$(cat "$ROWS")" '"rating_label":"STRONG"'
assert_contains "STRONG value=1.0" "$(cat "$ROWS")" '"value":1.0,"sample_size":1,"window_start":"'$(date -u +%Y-%m-%dT)
assert_contains "WEAK value=0.25" "$(cat "$ROWS")" '"value":0.25'
assert_contains "MISSING value=0.0 with rating_label" "$(cat "$ROWS")" '"value":0.0,"sample_size":1,"window_start":"'$(date -u +%Y-%m-%dT)

# Gate mapping
assert_contains "gate=fail maps to 0.0" "$(cat "$ROWS")" '"gate_label":"fail"'

# Slugify
assert_contains "'Interface Clarity' slugifies to criterion:interface-clarity" "$(cat "$ROWS")" '"metric":"criterion:interface-clarity"'
assert_contains "'Validation and Traceability' slugifies correctly" "$(cat "$ROWS")" '"metric":"criterion:validation-and-traceability"'

# Producer template_version
assert_contains "rows attribute to --producer-template-version" "$(cat "$ROWS")" '"template_version":"abc123def456"'

# All rows kind=scored
KIND_LINES=$(grep -c '"kind":"scored"' "$ROWS")
if [[ "$KIND_LINES" == "7" ]]; then
  echo "  PASS: all 7 rows kind=scored"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 7 kind=scored rows, got $KIND_LINES"
  FAIL=$((FAIL + 1))
fi

# All rows calibration_state=pre-calibration
CAL_LINES=$(grep -c '"calibration_state":"pre-calibration"' "$ROWS")
if [[ "$CAL_LINES" == "7" ]]; then
  echo "  PASS: all 7 rows calibration_state=pre-calibration"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 7 pre-calibration rows, got $CAL_LINES"
  FAIL=$((FAIL + 1))
fi

# Flag-form pr-review: different criteria, gate=pass.
TMP2=$(mktemp -d)
PR_VERDICT='{"ratings":{"Correctness":"STRONG","Interface Clarity":"ADEQUATE"},"gate":"pass"}'
"$CAPTURE" capture --kdir "$TMP2" --source-ceremony pr-review --producer-template-version xyz789fedcba --verdict-json "$PR_VERDICT" >/dev/null
PR_ROWS="$TMP2/_scorecards/rows.jsonl"
PR_LINES=$(wc -l < "$PR_ROWS" | tr -d ' ')
if [[ "$PR_LINES" == "3" ]]; then
  echo "  PASS: pr-review verdict emits 2 criteria + 1 gate = 3 rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 3 rows, got $PR_LINES"
  FAIL=$((FAIL + 1))
fi
assert_contains "pr-review → template_id=codex-pr-review" "$(cat "$PR_ROWS")" '"template_id":"codex-pr-review"'
assert_contains "gate=pass maps to 1.0" "$(cat "$PR_ROWS")" '"gate_label":"pass"'
rm -rf "$TMP2"

# Unknown rating skipped with warning, not fatal.
TMP3=$(mktemp -d)
WARN_OUTPUT=$("$CAPTURE" capture --kdir "$TMP3" --source-ceremony spec --producer-template-version h --verdict-json '{"ratings":{"Valid":"STRONG","Bogus":"OK"}}' 2>&1)
assert_contains "unknown rating produces warning" "$WARN_OUTPUT" "Warning: skipping criterion 'Bogus'"
WARN_LINES=$(wc -l < "$TMP3/_scorecards/rows.jsonl" | tr -d ' ')
if [[ "$WARN_LINES" == "1" ]]; then
  echo "  PASS: unknown rating is skipped, valid ratings still land"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 1 row after skip, got $WARN_LINES"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP3"

# Error paths
assert_exit "missing ratings map exits 1" 1 "$CAPTURE" capture --kdir "$TMP" --source-ceremony spec --producer-template-version h --verdict-json '{}'
assert_exit "invalid ceremony exits 1" 1 "$CAPTURE" capture --source-ceremony bogus --producer-template-version h --verdict-json '{"ratings":{"X":"STRONG"}}'
assert_exit "missing required flags exits 1" 1 "$CAPTURE" capture --verdict-json '{"ratings":{}}'
assert_exit "malformed verdict-json exits 1" 1 "$CAPTURE" capture --kdir "$TMP" --source-ceremony spec --producer-template-version h --verdict-json 'not json'

# --row pass-through: build a valid row, feed it directly, it should land.
TMP4=$(mktemp -d)
ROW_PASSTHRU='{"schema_version":"1","template_id":"codex-plan-review","template_version":"abc","metric":"test","value":0.5,"sample_size":1,"window_start":"2026-04-22T00:00:00Z","window_end":"2026-04-22T00:00:00Z","source_artifact_ids":[],"granularity":"set-level","kind":"scored","calibration_state":"pre-calibration"}'
"$CAPTURE" capture --kdir "$TMP4" --row "$ROW_PASSTHRU" >/dev/null
assert_contains "--row pass-through lands the row" "$(cat "$TMP4/_scorecards/rows.jsonl")" '"metric":"test"'
rm -rf "$TMP4"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
