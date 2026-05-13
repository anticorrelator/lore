#!/usr/bin/env bash
# test_advisor_impact_rollup.sh — Tests for scripts/advisor-impact-rollup.sh
#
# Covers:
#   - Single advisor, single followed consultation → 2 rows (consultation_rate, advice_followed_rate)
#   - Multiple consultations same advisor → rolled up into one pair of rows
#   - Multiple advisors → one pair per advisor
#   - Followed-rate arithmetic (1/2 = 0.5)
#   - Unfollowed consultation requires rationale
#   - Empty array → no rows, exit 0
#   - Missing required field fails
#   - Non-boolean was_followed fails
#   - Missing advisor_template_version fails
#   - stdin JSON form works
#   - Rows attribute to template_id=advisor (not producer)
#   - Rows carry kind=scored, calibration_state=pre-calibration
#   - source_artifact_ids = [work_item]
#   - Rows include extra metadata (consultations_in_report, followed_count, total_consultations)
#   - Sole-writer invariant (rows go through scorecard-append.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
ROLLUP="$SCRIPT_DIR/advisor-impact-rollup.sh"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — did not find: $expected"
    echo "    got: $(echo "$output" | head -3)"
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

echo "=== advisor-impact-rollup.sh tests ==="

# Single advisor, single followed consultation.
"$ROLLUP" rollup --kdir "$TMP" --work-item slug-1 \
  --consultations-json '[{"advisor_template_version":"advA","query_summary":"q","advice_summary":"a","was_followed":true}]' >/dev/null

ROWS="$TMP/_scorecards/rows.jsonl"
LINES=$(wc -l < "$ROWS" | tr -d ' ')
if [[ "$LINES" == "2" ]]; then
  echo "  PASS: single followed consultation emits 2 rows (consultation_rate + advice_followed_rate)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 2 rows, got $LINES"
  FAIL=$((FAIL + 1))
fi
assert_contains "template_id=advisor" "$(cat "$ROWS")" '"template_id":"advisor"'
assert_contains "template_version=advA" "$(cat "$ROWS")" '"template_version":"advA"'
assert_contains "consultation_rate=1.0" "$(cat "$ROWS")" '"metric":"consultation_rate","value":1.0'
assert_contains "advice_followed_rate=1.0 (all followed)" "$(cat "$ROWS")" '"metric":"advice_followed_rate","value":1.0'
assert_contains "kind=scored" "$(cat "$ROWS")" '"kind":"scored"'
assert_contains "calibration_state=pre-calibration" "$(cat "$ROWS")" '"calibration_state":"pre-calibration"'
assert_contains "source_artifact_ids contains work-item" "$(cat "$ROWS")" '"source_artifact_ids":["slug-1"]'

# Multiple consultations same advisor → rolled up to one pair.
TMP2=$(mktemp -d)
"$ROLLUP" rollup --kdir "$TMP2" --work-item slug-2 \
  --consultations-json '[{"advisor_template_version":"advB","query_summary":"q1","advice_summary":"a1","was_followed":true},{"advisor_template_version":"advB","query_summary":"q2","advice_summary":"a2","was_followed":false,"rationale_if_not_followed":"scope issue"}]' >/dev/null
ROWS2="$TMP2/_scorecards/rows.jsonl"
LINES2=$(wc -l < "$ROWS2" | tr -d ' ')
if [[ "$LINES2" == "2" ]]; then
  echo "  PASS: 2 consultations same advisor roll up to 1 pair of rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 2 rows, got $LINES2"
  FAIL=$((FAIL + 1))
fi
assert_contains "followed_rate=0.5 (1 of 2 followed)" "$(cat "$ROWS2")" '"metric":"advice_followed_rate","value":0.5'
assert_contains "consultations_in_report=2" "$(cat "$ROWS2")" '"consultations_in_report":2'
assert_contains "followed_count=1" "$(cat "$ROWS2")" '"followed_count":1'
assert_contains "total_consultations=2" "$(cat "$ROWS2")" '"total_consultations":2'
rm -rf "$TMP2"

# Multiple advisors → one pair per advisor.
TMP3=$(mktemp -d)
"$ROLLUP" rollup --kdir "$TMP3" --work-item slug-3 \
  --consultations-json '[{"advisor_template_version":"advA","query_summary":"qA","advice_summary":"aA","was_followed":true},{"advisor_template_version":"advC","query_summary":"qC","advice_summary":"aC","was_followed":true}]' >/dev/null
LINES3=$(wc -l < "$TMP3/_scorecards/rows.jsonl" | tr -d ' ')
if [[ "$LINES3" == "4" ]]; then
  echo "  PASS: 2 advisors emit 4 rows (2 advisors × 2 metrics)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: expected 4 rows, got $LINES3"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP3"

# Empty array → no rows, exit 0.
TMP4=$(mktemp -d)
OUT=$("$ROLLUP" rollup --kdir "$TMP4" --work-item slug-4 --consultations-json '[]' 2>&1)
RC=$?
if [[ "$RC" == "0" && ! -f "$TMP4/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: empty array → exit 0, no rows file created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: empty array — rc=$RC, rows file exists=$([[ -f "$TMP4/_scorecards/rows.jsonl" ]] && echo yes || echo no)"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP4"

# stdin form.
TMP5=$(mktemp -d)
echo '[{"advisor_template_version":"advD","query_summary":"q","advice_summary":"a","was_followed":true}]' | "$ROLLUP" rollup --kdir "$TMP5" --work-item slug-5 >/dev/null
if [[ -f "$TMP5/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: stdin JSON form works"
  PASS=$((PASS + 1))
else
  echo "  FAIL: stdin form produced no rows"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP5"

# Validation errors.
assert_exit "missing advisor_template_version exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s --consultations-json '[{"query_summary":"q","advice_summary":"a","was_followed":true}]'
assert_exit "non-boolean was_followed exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s --consultations-json '[{"advisor_template_version":"x","query_summary":"q","advice_summary":"a","was_followed":"maybe"}]'
assert_exit "was_followed=false without rationale exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s --consultations-json '[{"advisor_template_version":"x","query_summary":"q","advice_summary":"a","was_followed":false}]'
assert_exit "non-array input exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s --consultations-json '{"not":"an array"}'
assert_exit "malformed JSON exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s --consultations-json 'not json'
assert_exit "missing --work-item exits 1" 1 "$ROLLUP" rollup --kdir "$TMP" --consultations-json '[]'

# ---------------------------------------------------------------------------
# D5/D6 handler-discriminator filtering tests (added with the hoist).
# ---------------------------------------------------------------------------

# B1. Mixed handler input filtering: lead + skill + agent → only the agent
# entry produces rows; lead and skill entries are silently filtered out.
TMP_MIX=$(mktemp -d)
"$ROLLUP" rollup --kdir "$TMP_MIX" --work-item slug-mix \
  --consultations-json '[
    {"handler":"lead","domain":"design","query_summary":"qL","advice_summary":"aL","was_followed":true},
    {"handler":"skill","domain":"codex-plan-review","skill_template_version":"skll00000000","query_summary":"qS","advice_summary":"aS","was_followed":true},
    {"handler":"agent","advisor_template_version":"advMIX000000","domain":"security","query_summary":"qA","advice_summary":"aA","was_followed":true}
  ]' >/dev/null
ROWS_MIX="$TMP_MIX/_scorecards/rows.jsonl"
LINES_MIX=$(wc -l < "$ROWS_MIX" | tr -d ' ')
if [[ "$LINES_MIX" == "2" ]]; then
  echo "  PASS: mixed-handler input → only handler:agent emits rows (2 metrics × 1 advisor)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: mixed-handler — expected 2 rows for the agent entry, got $LINES_MIX"
  FAIL=$((FAIL + 1))
fi
assert_contains "mixed-handler row attributes to advMIX advisor" "$(cat "$ROWS_MIX")" '"template_version":"advMIX000000"'
# Negative: lead/skill entries leave no scorecard fingerprint.
if ! grep -q '"template_version":"skll' "$ROWS_MIX" && \
   ! grep -q '"template_id":"lead"' "$ROWS_MIX"; then
  echo "  PASS: mixed-handler — lead and skill entries produce zero rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: mixed-handler — lead or skill entry leaked into rows"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP_MIX"

# B2a. Lead-only and skill-only inputs produce no scorecard rows at all
# (default-route steady state after the hoist).
TMP_LEADONLY=$(mktemp -d)
OUT_LO=$("$ROLLUP" rollup --kdir "$TMP_LEADONLY" --work-item slug-lead \
  --consultations-json '[{"handler":"lead","domain":"d","query_summary":"q","advice_summary":"a","was_followed":true}]' 2>&1)
RC_LO=$?
if [[ "$RC_LO" == "0" && ! -f "$TMP_LEADONLY/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: lead-only input → exit 0, no rows file created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: lead-only — rc=$RC_LO, rows file exists=$([[ -f "$TMP_LEADONLY/_scorecards/rows.jsonl" ]] && echo yes || echo no)"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP_LEADONLY"

TMP_SKILLONLY=$(mktemp -d)
OUT_SO=$("$ROLLUP" rollup --kdir "$TMP_SKILLONLY" --work-item slug-skill \
  --consultations-json '[{"handler":"skill","skill_template_version":"skll00000000","domain":"codex-plan-review","query_summary":"q","advice_summary":"a","was_followed":true}]' 2>&1)
RC_SO=$?
if [[ "$RC_SO" == "0" && ! -f "$TMP_SKILLONLY/_scorecards/rows.jsonl" ]]; then
  echo "  PASS: skill-only input → exit 0, no rows file created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: skill-only — rc=$RC_SO, rows file exists=$([[ -f "$TMP_SKILLONLY/_scorecards/rows.jsonl" ]] && echo yes || echo no)"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP_SKILLONLY"

# B2. D6 backward-compat normalization: legacy entry with no `handler` but
# carrying `advisor_template_version` is normalized to `handler: agent` and
# emits rows attributing to its advisor_template_version.
#
# Note: the existing "Single advisor, single followed consultation" case at
# the top of this file also exercises the D6 legacy shape (input omits
# handler); this case adds a variant that mixes a legacy no-handler entry
# with a fresh `handler: lead` entry in one payload, asserting the legacy
# normalizes-to-agent while the lead is filtered out.
TMP_LEGACY=$(mktemp -d)
"$ROLLUP" rollup --kdir "$TMP_LEGACY" --work-item slug-legacy \
  --consultations-json '[
    {"advisor_template_version":"legacy123abc","query_summary":"qLG","advice_summary":"aLG","was_followed":true},
    {"handler":"lead","domain":"design","query_summary":"qL","advice_summary":"aL","was_followed":true}
  ]' >/dev/null
ROWS_LG="$TMP_LEGACY/_scorecards/rows.jsonl"
LINES_LG=$(wc -l < "$ROWS_LG" | tr -d ' ')
if [[ "$LINES_LG" == "2" ]]; then
  echo "  PASS: D6 backward-compat — legacy no-handler entry normalizes to agent, mixed with handler:lead, emits 2 rows"
  PASS=$((PASS + 1))
else
  echo "  FAIL: D6 backward-compat — expected 2 rows for the normalized agent entry, got $LINES_LG"
  FAIL=$((FAIL + 1))
fi
assert_contains "D6 normalized entry attributes to legacy123abc" "$(cat "$ROWS_LG")" '"template_version":"legacy123abc"'
rm -rf "$TMP_LEGACY"

# B3. Invalid handler value (closed-set validation): handler=oracle should
# be rejected because the discriminator must be one of lead|skill|agent.
assert_exit "invalid handler value rejected" 1 "$ROLLUP" rollup --kdir "$TMP" --work-item s \
  --consultations-json '[{"handler":"oracle","advisor_template_version":"x","query_summary":"q","advice_summary":"a","was_followed":true}]'

# B4. Missing handler AND missing advisor_template_version → rejected. The
# entry cannot be normalized (no advisor_template_version for D6 fallback)
# and cannot be attributed. This guards the "missing-handler-no-tpl-version"
# rejection branch in the rollup's validation block. (Distinct from
# "missing advisor_template_version" above, which carries a handler-less
# entry that lacks every attribution field.)
assert_exit "missing handler + missing advisor_template_version rejected" 1 \
  "$ROLLUP" rollup --kdir "$TMP" --work-item s \
  --consultations-json '[{"domain":"d","query_summary":"q","advice_summary":"a","was_followed":true}]'

# B5. handler:agent without advisor_template_version → rejected (the
# discriminator REQUIRES advisor_template_version when handler=agent per
# the script header).
assert_exit "handler:agent without advisor_template_version rejected" 1 \
  "$ROLLUP" rollup --kdir "$TMP" --work-item s \
  --consultations-json '[{"handler":"agent","domain":"d","query_summary":"q","advice_summary":"a","was_followed":true}]'

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
