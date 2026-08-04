#!/usr/bin/env bash
# test_coordinate_report.sh — Acceptance for the report-landing verb.
#
# Covers `lore coordinate report`: schema-v1 identity header validation, the
# write-once rule (an existing path is refused even for a byte-identical body),
# the split between a header refusal (3) and a destination refusal (4), and the
# guarantee that a refused landing writes nothing at all.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$REPO_ROOT/scripts/coordinate-report.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_work/demo-item"
  echo "$kdir"
}

# A well-formed schema-v1 report. Callers override single header fields by
# piping the result through sed.
report_body() {
  local report_id="${1:-task-1-r1}" work_item="${2:-demo-item}"
  cat <<EOF
Report-schema: 1
Report-id: $report_id
Work-item: $work_item
Task: #1 implement the thing
Producer-role: worker
Dispatch-path: harness-subagent
Harness: claude-code
Status: completed
Template-version: 122ad5df53d8
**Artifacts:**
  - path: /tmp/nothing
**Changes:**
- did the thing
EOF
}

echo "== a well-formed report lands at its assigned path =="
KDIR=$(new_store)
OUT=$(report_body | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "landing exits 0" "0" "$RC"
DEST="$KDIR/_work/demo-item/worker-reports/task-1-r1.md"
[[ -f "$DEST" ]] && pass "report file exists at the assigned path" || fail "report file exists at the assigned path"
assert_contains "landing names the path" "$OUT" "$DEST"
assert_eq "body landed verbatim" "$(report_body)" "$(cat "$DEST")"
[[ -z "$(find "$KDIR/_work/demo-item/worker-reports" -name '.tmp.*')" ]] && pass "no temp file left behind" || fail "no temp file left behind"

echo "== the assigned path is written once, then refused =="
OUT=$(report_body | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "byte-identical replay exits 4" "4" "$RC"
assert_contains "refusal names the existing file" "$OUT" "$DEST"
assert_contains "refusal explains immutability" "$OUT" "immutable"
assert_eq "the first landing is untouched" "$(report_body)" "$(cat "$DEST")"
# A different body under the same id is refused the same way, and does not land.
OUT=$(printf 'Report-schema: 1\nReport-id: task-1-r1\nWork-item: demo-item\nTask: #1\nProducer-role: worker\nDispatch-path: harness-subagent\nHarness: claude-code\nStatus: completed\nTemplate-version: x\n\nDIFFERENT\n' \
  | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "differing replay also exits 4" "4" "$RC"
assert_eq "differing replay did not overwrite" "$(report_body)" "$(cat "$DEST")"
# A fresh id is the sanctioned path for a second attempt.
report_body task-1-r2 | bash "$REPORT" demo-item --report-id task-1-r2 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "a fresh id lands beside the first" "0" "$?"

echo "== identity header validation refuses with 3 and writes nothing =="
KDIR=$(new_store)
REPORTS_DIR="$KDIR/_work/demo-item/worker-reports"

OUT=$(printf 'just some prose, no header at all\n' | bash "$REPORT" demo-item --report-id task-2-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a headerless body exits 3" "3" "$RC"
assert_contains "headerless refusal names the schema" "$OUT" "Report-schema"

OUT=$(report_body | grep -v '^Harness:' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a missing header field exits 3" "3" "$RC"
assert_contains "refusal names the missing field" "$OUT" "Harness"

OUT=$(report_body | sed 's/^Report-schema: 1$/Report-schema: 2/' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a foreign schema version exits 3" "3" "$RC"
assert_contains "refusal names the version" "$OUT" "schema-v1"

OUT=$(report_body | sed 's/^Status: completed$/Status:/' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "an empty header field exits 3" "3" "$RC"

OUT=$(report_body task-1-r1 | bash "$REPORT" demo-item --report-id task-1-r9 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a header id that disagrees with --report-id exits 3" "3" "$RC"
assert_contains "refusal shows both ids" "$OUT" "task-1-r9"

OUT=$(report_body task-1-r1 other-item | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a header work-item pointing elsewhere exits 3" "3" "$RC"
assert_contains "refusal names the mismatch" "$OUT" "other-item"

[[ ! -d "$REPORTS_DIR" ]] && pass "no refusal created worker-reports/" || fail "no refusal created worker-reports/" "$(ls "$REPORTS_DIR")"

echo "== usage and environment errors stay at 1 =="
KDIR=$(new_store)
OUT=$(report_body | bash "$REPORT" demo-item --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a missing --report-id exits 1" "1" "$RC"
assert_contains "the message names the flag" "$OUT" "--report-id"

OUT=$(report_body | bash "$REPORT" demo-item --report-id "sub/dir" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a path-bearing id exits 1" "1" "$RC"
OUT=$(report_body | bash "$REPORT" demo-item --report-id ".hidden" --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a dotfile id exits 1" "1" "$RC"

OUT=$(report_body | bash "$REPORT" no-such-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "an unknown work item exits 1" "1" "$RC"
assert_contains "the message names the directory" "$OUT" "no-such-item"

OUT=$(printf '' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "an empty body exits 1" "1" "$RC"
OUT=$(printf '   \n\n' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a whitespace-only body exits 1" "1" "$RC"

echo "== --json carries the same verdicts =="
KDIR=$(new_store)
OUT=$(report_body | bash "$REPORT" demo-item --report-id task-1-r1 --json --kdir "$KDIR" 2>/dev/null)
assert_contains "landing json says ok" "$OUT" '"ok": true'
assert_contains "landing json carries the path" "$OUT" "task-1-r1.md"
OUT=$(report_body | bash "$REPORT" demo-item --report-id task-1-r1 --json --kdir "$KDIR" 2>/dev/null); RC=$?
assert_eq "refusal json still exits 4" "4" "$RC"
assert_contains "refusal json carries the code" "$OUT" '"exit_code": 4'

echo "== the help text explains what each refusal code means =="
OUT=$(bash "$REPORT" --help 2>&1)
assert_contains "help documents exit 3" "$OUT" "3  the identity header failed validation"
assert_contains "help documents exit 4" "$OUT" "4  the report path already exists"
assert_contains "help explains the replay refusal" "$OUT" "byte-identical"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
