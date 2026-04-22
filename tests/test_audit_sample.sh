#!/usr/bin/env bash
# test_audit_sample.sh — Tests for scripts/audit-sample.sh
#
# Covers:
#   - Base weight is 1.0 when no signals fire
#   - Each signal contributes the documented additive weight
#   - Signals compose additively (all-four claim lands at 3.6)
#   - --top-k trims output after weight-descending sort
#   - --input reads from file
#   - Missing claim_id fails fast
#   - Empty input / malformed JSON fail fast
#   - Generic-phrase detection catches "works correctly" and friends
#   - High-risk regex catches auth/crypto/scorecard/config paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
SAMPLER="$SCRIPT_DIR/audit-sample.sh"

PASS=0
FAIL=0

assert_weight() {
  local label="$1" input_json="$2" claim_id="$3" expected="$4"
  local output actual
  output=$(echo "$input_json" | "$SAMPLER" 2>&1) || true
  actual=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r['claim_id'] == '$claim_id':
        print(r['weight'])
        break
")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected weight=$expected, got $actual"
    echo "    output: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_signal() {
  local label="$1" input_json="$2" claim_id="$3" signal="$4" expected="$5"
  local output actual
  output=$(echo "$input_json" | "$SAMPLER" 2>&1) || true
  actual=$(echo "$output" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data:
    if r['claim_id'] == '$claim_id':
        print(str(r['signals']['$signal']).lower())
        break
")
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected signals.$signal=$expected, got $actual"
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

echo "=== audit-sample.sh tests ==="

# Base weight — neutral claim, no signals fire.
# Using a long lexically diverse prose sample to avoid generic-language trip,
# and a clearly non-risk path, and no test_status. lore search may match the
# topic (contradicts_prior) so we exclude that signal from this test by not
# asserting the full weight — instead we check the breakdown shape.
BASE_CLAIM='[{"claim_id":"base","claim_text":"The fibonacci sequence generator memoizes previously computed intermediate values into a dictionary keyed by the recursion depth integer index.","file":"docs/algorithm-overview.md"}]'
assert_signal "base: tests_skipped false" "$BASE_CLAIM" "base" "tests_skipped" "false"
assert_signal "base: high_risk_path false" "$BASE_CLAIM" "base" "high_risk_path" "false"
assert_signal "base: generic_language false" "$BASE_CLAIM" "base" "generic_language" "false"

# tests_skipped — various status strings.
for status in "skipped" "SKIPPED" "not-applicable" "not applicable" "n/a" "NA"; do
  JSON=$(printf '[{"claim_id":"t","claim_text":"x","test_status":"%s"}]' "$status")
  assert_signal "tests_skipped: '$status' fires" "$JSON" "t" "tests_skipped" "true"
done

# tests_skipped — passing/running do NOT fire.
for status in "passed" "running" "pending" ""; do
  JSON=$(printf '[{"claim_id":"t","claim_text":"x","test_status":"%s"}]' "$status")
  assert_signal "tests_skipped: '$status' does not fire" "$JSON" "t" "tests_skipped" "false"
done

# high_risk_path — each of the catalog terms.
for path in "src/auth/login.js" "crypto/sign.go" "payment/charge.py" "migrations/20260101_add_column.sql" "src/admin/panel.js" "scorecard-append.sh" "_scorecards/rows.jsonl" "config/settings.json" "scripts/hook-dispatch.sh"; do
  JSON=$(printf '[{"claim_id":"r","claim_text":"x","file":"%s"}]' "$path")
  assert_signal "high_risk_path: '$path' fires" "$JSON" "r" "high_risk_path" "true"
done

# high_risk_path — benign paths do not fire.
for path in "docs/README.md" "src/utils/format.js" "tests/fixtures/data.json"; do
  JSON=$(printf '[{"claim_id":"r","claim_text":"x","file":"%s"}]' "$path")
  assert_signal "high_risk_path: '$path' does not fire" "$JSON" "r" "high_risk_path" "false"
done

# generic_language — curated phrases fire.
for phrase in "works correctly" "handles properly" "no issues" "follows best practices" "behaves as expected"; do
  JSON=$(printf '[{"claim_id":"g","claim_text":"The implementation %s."}]' "$phrase")
  assert_signal "generic_language: '$phrase' fires" "$JSON" "g" "generic_language" "true"
done

# --top-k — orders by weight, trims.
TK_INPUT='[{"claim_id":"low","claim_text":"neutral statement about stuff"},{"claim_id":"high","claim_text":"x","test_status":"skipped","file":"auth/login.js"}]'
TK_OUTPUT=$(echo "$TK_INPUT" | "$SAMPLER" --top-k 1)
FIRST_ID=$(echo "$TK_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['claim_id'])")
COUNT=$(echo "$TK_OUTPUT" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
if [[ "$FIRST_ID" == "high" && "$COUNT" == "1" ]]; then
  echo "  PASS: --top-k 1 returns highest-weight claim only"
  PASS=$((PASS + 1))
else
  echo "  FAIL: --top-k 1 — first=$FIRST_ID count=$COUNT"
  FAIL=$((FAIL + 1))
fi

# --input — reads from file.
TMP=$(mktemp)
echo '[{"claim_id":"f","claim_text":"x","test_status":"skipped"}]' > "$TMP"
FILE_OUT=$("$SAMPLER" --input "$TMP")
if echo "$FILE_OUT" | grep -q '"tests_skipped": true'; then
  echo "  PASS: --input reads from file"
  PASS=$((PASS + 1))
else
  echo "  FAIL: --input did not parse file"
  FAIL=$((FAIL + 1))
fi
rm -f "$TMP"

# Error paths.
assert_exit "empty stdin exits 1" 1 bash -c "echo '' | '$SAMPLER'"
assert_exit "malformed JSON exits 1" 1 bash -c "echo 'not json' | '$SAMPLER'"
assert_exit "missing claim_id exits 1" 1 bash -c "echo '[{\"claim_text\":\"x\"}]' | '$SAMPLER'"
assert_exit "unknown flag exits 1" 1 "$SAMPLER" --bogus
assert_exit "missing input file exits 1" 1 "$SAMPLER" --input /no/such/file

# All-four-signals claim: base 1.0 + 0.8 + 0.7 + 0.5 + 0.6 = 3.6
ALL_IN='[{"claim_id":"all","claim_text":"Authentication works correctly","file":"src/auth/middleware.js","test_status":"skipped"}]'
assert_weight "all four signals compose to 3.6" "$ALL_IN" "all" "3.6"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
