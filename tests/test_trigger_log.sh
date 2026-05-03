#!/usr/bin/env bash
# test_trigger_log.sh — Tests for scripts/trigger-log-append.sh
#
# Covers:
#   - Flag-form append round-trips a fired trigger
#   - Flag-form append round-trips a not-fired trigger (fired=false)
#   - --row JSON form appends
#   - stdin JSON form appends
#   - Rejects invalid ceremony
#   - Rejects configured_p out of [0.0, 1.0]
#   - Rejects non-boolean fired
#   - Rejects malformed triggered_at
#   - Rejects missing schema_version (via --row)
#   - Rejects invalid role
#   - Rejects invalid rolled (out of [0.0, 1.0])
#   - Creates _scorecards/ directory on first use
#   - Appends (does not overwrite) across calls
#   - JSONL format: one line per row, no trailing commas

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
APPEND="$SCRIPT_DIR/trigger-log-append.sh"

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
    echo "    Got: $output"
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

echo "=== trigger-log-append.sh tests ==="

# Flag-form fired trigger.
"$APPEND" append --kdir "$TMP" --ceremony implement --configured-p 0.3 --fired true --artifact-id slug-42 --role correctness-gate >/dev/null
LOG="$TMP/_scorecards/trigger-log.jsonl"
assert_contains "flag-form fired: ceremony recorded" "$(cat "$LOG")" '"ceremony":"implement"'
assert_contains "flag-form fired: fired=true recorded" "$(cat "$LOG")" '"fired":true'
assert_contains "flag-form fired: artifact_id recorded" "$(cat "$LOG")" '"artifact_id":"slug-42"'
assert_contains "flag-form fired: role recorded" "$(cat "$LOG")" '"role":"correctness-gate"'

# Flag-form not-fired trigger.
"$APPEND" append --kdir "$TMP" --ceremony spec --configured-p 0.2 --fired false --rolled 0.87 >/dev/null
LINE2=$(tail -1 "$LOG")
assert_contains "flag-form not-fired: fired=false" "$LINE2" '"fired":false'
assert_contains "flag-form not-fired: rolled preserved" "$LINE2" '"rolled":0.87'

# Append semantics — now 2 lines.
LINES=$(wc -l < "$LOG" | tr -d ' ')
if [[ "$LINES" == "2" ]]; then
  echo "  PASS: appended (does not overwrite)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: appended — expected 2 lines, got $LINES"
  FAIL=$((FAIL + 1))
fi

# --row JSON form.
"$APPEND" append --kdir "$TMP" --row '{"schema_version":"1","ceremony":"pr-review","configured_p":0.2,"fired":true,"artifact_id":"pr-42","role":"batch","triggered_at":"2026-04-22T15:30:00Z"}' >/dev/null
LINE3=$(tail -1 "$LOG")
assert_contains "--row form: ceremony recorded" "$LINE3" '"ceremony":"pr-review"'
assert_contains "--row form: timestamp preserved" "$LINE3" '"triggered_at":"2026-04-22T15:30:00Z"'

# stdin JSON form.
echo '{"schema_version":"1","ceremony":"pr-self-review","configured_p":0.3,"fired":false,"triggered_at":"2026-04-22T16:00:00Z"}' | "$APPEND" append --kdir "$TMP" >/dev/null
LINE4=$(tail -1 "$LOG")
assert_contains "stdin form: ceremony recorded" "$LINE4" '"ceremony":"pr-self-review"'

# Validation errors.
assert_exit "rejects invalid ceremony" 1 "$APPEND" append --kdir "$TMP" --ceremony bogus --configured-p 0.3 --fired true
assert_exit "rejects configured_p > 1.0" 1 "$APPEND" append --kdir "$TMP" --ceremony implement --configured-p 1.5 --fired true
assert_exit "rejects configured_p < 0" 1 "$APPEND" append --kdir "$TMP" --ceremony implement --configured-p -0.1 --fired true
assert_exit "rejects non-boolean fired" 1 "$APPEND" append --kdir "$TMP" --ceremony implement --configured-p 0.3 --fired maybe
assert_exit "rejects missing schema_version via --row" 1 "$APPEND" append --kdir "$TMP" --row '{"ceremony":"implement","configured_p":0.3,"fired":true,"triggered_at":"2026-04-22T00:00:00Z"}'
assert_exit "rejects malformed timestamp" 1 "$APPEND" append --kdir "$TMP" --row '{"schema_version":"1","ceremony":"implement","configured_p":0.3,"fired":true,"triggered_at":"not-a-date"}'
assert_exit "rejects invalid role" 1 "$APPEND" append --kdir "$TMP" --row '{"schema_version":"1","ceremony":"implement","configured_p":0.3,"fired":true,"role":"bogus","triggered_at":"2026-04-22T00:00:00Z"}'
assert_exit "rejects rolled > 1.0" 1 "$APPEND" append --kdir "$TMP" --row '{"schema_version":"1","ceremony":"implement","configured_p":0.3,"fired":true,"rolled":1.5,"triggered_at":"2026-04-22T00:00:00Z"}'

# JSONL format: each line is a valid JSON object, no trailing commas.
VALID_LINES=0
TOTAL_LINES=0
while IFS= read -r line; do
  TOTAL_LINES=$((TOTAL_LINES + 1))
  if echo "$line" | python3 -c "import json, sys; json.loads(sys.stdin.read())" >/dev/null 2>&1; then
    VALID_LINES=$((VALID_LINES + 1))
  fi
done < "$LOG"
if [[ "$VALID_LINES" == "$TOTAL_LINES" && "$TOTAL_LINES" -gt 0 ]]; then
  echo "  PASS: all $TOTAL_LINES lines are valid JSON (JSONL format)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: JSONL format — $VALID_LINES/$TOTAL_LINES lines parse"
  FAIL=$((FAIL + 1))
fi

# Creates _scorecards/ dir on first use: verify by pointing at a fresh dir.
TMP2=$(mktemp -d)
"$APPEND" append --kdir "$TMP2" --ceremony implement --configured-p 0.3 --fired true >/dev/null
if [[ -f "$TMP2/_scorecards/trigger-log.jsonl" ]]; then
  echo "  PASS: creates _scorecards/ directory on first use"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _scorecards/ directory not created"
  FAIL=$((FAIL + 1))
fi
rm -rf "$TMP2"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
