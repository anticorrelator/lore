#!/usr/bin/env bash
# test_implement_closure_report.sh — Tests for scripts/implement-closure-report.sh
#
# The structural proof: the Done success summary exists ONLY on the exit-0
# branch. Each case asserts both the exit code AND the presence/absence of the
# success text, so a divergence (or a corrupted location/verdict state) cannot
# carry "Done"/"archived"/"complete" prose.
#
# Covers:
#   - full (archived location)  -> Done summary, exit 0
#   - legacy/no-anchor          -> Done summary, exit 0
#   - partial (active location) -> banner only (no Done), exit 3
#   - none (active location)    -> banner only (no Done), exit 3
#   - mismatch (archived + capability_incomplete) -> fails without Done
#   - mismatch (active + verdict full)            -> fails without Done

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
REPORT="$SCRIPT_DIR/implement-closure-report.sh"

PASS=0
FAIL=0

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Run the script against a slug, capturing stdout+stderr and the exit code.
# Extra args after the slug pass through (e.g. the run-context count flags).
RUN_OUT=""
RUN_RC=0
run_report() {
  local slug="$1"; shift
  set +e
  RUN_OUT=$("$REPORT" --slug "$slug" --kdir "$TMP" "$@" 2>&1)
  RUN_RC=$?
  set -e
}

assert_rc() {
  local label="$1" expected="$2"
  if [[ "$RUN_RC" == "$expected" ]]; then
    echo "  PASS: $label (exit=$RUN_RC)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected exit=$expected, got $RUN_RC"
    echo "    Output: $RUN_OUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_has_done() {
  local label="$1"
  if echo "$RUN_OUT" | grep -qF "[implement] Done."; then
    echo "  PASS: $label (Done summary present)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected the Done summary, not found"
    echo "    Output: $RUN_OUT"
    FAIL=$((FAIL + 1))
  fi
}

# No success text at all: not "Done", not "archived." / "Work item archived."
# (the banner says "NOT archived", so match the success phrasing precisely).
assert_no_success_text() {
  local label="$1"
  if echo "$RUN_OUT" | grep -qF "[implement] Done." \
    || echo "$RUN_OUT" | grep -qF "Work item archived."; then
    echo "  FAIL: $label — success text leaked onto the non-completion path"
    echo "    Output: $RUN_OUT"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label (no Done/archived success text)"
    PASS=$((PASS + 1))
  fi
}

assert_contains() {
  local label="$1" expected="$2"
  if echo "$RUN_OUT" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected to contain: $expected"
    echo "    Output: $RUN_OUT"
    FAIL=$((FAIL + 1))
  fi
}

assert_absent() {
  local label="$1" unexpected="$2"
  if echo "$RUN_OUT" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label — should NOT contain: $unexpected"
    echo "    Output: $RUN_OUT"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label (absent: $unexpected)"
    PASS=$((PASS + 1))
  fi
}

write_meta() {
  # write_meta <location-dir> <slug> <json>
  local dir="$TMP/$1/$2"
  mkdir -p "$dir"
  printf '%s\n' "$3" > "$dir/_meta.json"
}

echo "=== implement-closure-report.sh tests ==="

# --- full (archived), counts passed -> Done with the full run-context block ---
write_meta "_work/_archive" "wi-full" \
  '{"intent_anchor":"deliver the widget loop","closure":{"verdict":"full","capability_incomplete":false,"capability_loop_summary":"widget loop operable end to end","divergence_summary":null,"residue_followup":null,"verdict_at":"2026-06-09T00:00:00Z","intent_anchor_at_close":"deliver the widget loop"}}'
run_report "wi-full" \
  --tasks-completed 4 --tasks-total 4 --tier2-count 7 \
  --tier3-accepted 2 --tier3-rejected 1 --followup "Deferred: widget polish"
assert_rc "full close exits 0" 0
assert_has_done "full close prints Done summary"
assert_contains "full close reports Closure: full" "Closure: full"
# D4: the full close's observable run-context lines match the historical report.
assert_contains "full close renders Completed N/M" "Completed: 4/4 tasks"
assert_contains "full close renders Tier 2 count" "Tier 2 claims written: 7"
assert_contains "full close renders Tier 3 promoted/rejected" "Tier 3 promoted: 2 (rejected: 1)"
assert_contains "full close renders Remaining archived line" "Remaining: none — work item archived"
assert_contains "full close renders Followup when passed" "Followup: Deferred: widget polish"
assert_contains "full close keeps retro pointer last" "Consider \`/retro wi-full\`"

# --- legacy / no-anchor (archived), no count flags -> Done, lines gracefully omitted ---
write_meta "_work/_archive" "wi-legacy" '{"intent_anchor":""}'
run_report "wi-legacy"
assert_rc "legacy close exits 0" 0
assert_has_done "legacy close prints Done summary"
assert_contains "legacy close reports Closure: legacy" "Closure: legacy"
assert_contains "legacy close still archives" "Remaining: none — work item archived"
# Graceful omission: a count flag not passed -> that line is absent, not blank.
assert_absent "legacy close omits Completed when no flag" "Completed:"
assert_absent "legacy close omits Tier 2 line when no flag" "Tier 2 claims written:"
assert_absent "legacy close omits Followup when no flag" "Followup:"

# --- partial (active), counts passed -> banner only, no count lines, exit 3 ---
# Pass the success-only flags to prove they are structurally inert on the
# divergence branch — the banner stays isolated regardless.
write_meta "_work" "wi-partial" \
  '{"intent_anchor":"deliver the widget loop","closure":{"verdict":"partial","capability_incomplete":true,"capability_loop_summary":"shipped the read path","divergence_summary":"write path deferred to residue child","residue_followup":"widget-write-path","verdict_at":"2026-06-09T00:00:00Z","intent_anchor_at_close":"deliver the widget loop"}}'
run_report "wi-partial" \
  --tasks-completed 4 --tasks-total 4 --tier2-count 7 \
  --tier3-accepted 2 --tier3-rejected 1 --followup "Deferred: widget polish"
assert_rc "partial close exits 3" 3
assert_no_success_text "partial close emits no success text"
assert_contains "partial banner names divergence" "DIVERGED FROM ANCHOR"
assert_contains "partial banner uses closure-laundering vocabulary" "mocked or deferred"
assert_contains "partial banner names the residue follow-up" "widget-write-path"
assert_contains "partial banner states NOT archived" "NOT archived"
# Count flags must not leak onto the banner.
assert_absent "partial banner omits Completed line" "Completed:"
assert_absent "partial banner omits Tier 2 line" "Tier 2 claims written:"
assert_absent "partial banner omits Tier 3 line" "Tier 3 promoted:"
assert_absent "partial banner omits Followup line" "Followup:"

# --- none (active), counts passed -> banner only, no count lines, exit 3 ---
write_meta "_work" "wi-none" \
  '{"intent_anchor":"deliver the widget loop","closure":{"verdict":"none","capability_incomplete":true,"capability_loop_summary":"attempted the read path","divergence_summary":"no load-bearing capability delivered","residue_followup":null,"verdict_at":"2026-06-09T00:00:00Z","intent_anchor_at_close":"deliver the widget loop"}}'
run_report "wi-none" \
  --tasks-completed 4 --tasks-total 4 --tier2-count 7 \
  --tier3-accepted 2 --tier3-rejected 1
assert_rc "none close exits 3" 3
assert_no_success_text "none close emits no success text"
assert_contains "none banner names divergence" "DIVERGED FROM ANCHOR"
assert_absent "none banner omits Completed line" "Completed:"
assert_absent "none banner omits Tier 2 line" "Tier 2 claims written:"

# --- mismatch: archived location carrying capability_incomplete=true -> fail, no Done ---
write_meta "_work/_archive" "wi-mismatch-arch" \
  '{"intent_anchor":"deliver the widget loop","closure":{"verdict":"partial","capability_incomplete":true,"capability_loop_summary":"x","divergence_summary":"y","residue_followup":"z","verdict_at":"2026-06-09T00:00:00Z","intent_anchor_at_close":"deliver the widget loop"}}'
run_report "wi-mismatch-arch"
if [[ "$RUN_RC" != "0" ]]; then
  echo "  PASS: archived+capability_incomplete mismatch exits non-zero (exit=$RUN_RC)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: archived+capability_incomplete mismatch should exit non-zero, got 0"
  FAIL=$((FAIL + 1))
fi
assert_no_success_text "archived mismatch emits no success text"
assert_contains "archived mismatch names the contradiction" "location/verdict mismatch"

# --- mismatch: active location claiming verdict full -> fail, no Done ---
write_meta "_work" "wi-mismatch-active" \
  '{"intent_anchor":"deliver the widget loop","closure":{"verdict":"full","capability_incomplete":false,"capability_loop_summary":"x","divergence_summary":null,"residue_followup":null,"verdict_at":"2026-06-09T00:00:00Z","intent_anchor_at_close":"deliver the widget loop"}}'
run_report "wi-mismatch-active"
if [[ "$RUN_RC" != "0" ]]; then
  echo "  PASS: active+verdict-full mismatch exits non-zero (exit=$RUN_RC)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: active+verdict-full mismatch should exit non-zero, got 0"
  FAIL=$((FAIL + 1))
fi
assert_no_success_text "active mismatch emits no success text"

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
