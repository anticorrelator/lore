#!/usr/bin/env bash
# test_coordinate_report.sh — Acceptance for the report-landing verb.
#
# Covers `lore coordinate report`: landing a body at the path its report id
# names, the write-once rule (an existing path is refused even for a
# byte-identical body), and the guarantee that a refused landing writes nothing
# at all.

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

# A report body. The path it lands at is what identifies it, so the body is
# whatever the worker wrote.
report_body() {
  local marker="${1:-task-1-r1}"
  cat <<EOF
**Artifacts:**
  - path: /tmp/nothing
**Changes:**
- did the thing ($marker)
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
OUT=$(printf 'DIFFERENT\n' | bash "$REPORT" demo-item --report-id task-1-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "differing replay also exits 4" "4" "$RC"
assert_eq "differing replay did not overwrite" "$(report_body)" "$(cat "$DEST")"
# A fresh id is the sanctioned path for a second attempt.
report_body task-1-r2 | bash "$REPORT" demo-item --report-id task-1-r2 --kdir "$KDIR" >/dev/null 2>&1
assert_eq "a fresh id lands beside the first" "0" "$?"

echo "== a body with no header at all is still a report =="
KDIR=$(new_store)
OUT=$(printf 'just some prose, no header at all\n' | bash "$REPORT" demo-item --report-id task-2-r1 --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a headerless body lands" "0" "$RC"
assert_eq "the headerless body landed verbatim" "just some prose, no header at all" \
  "$(cat "$KDIR/_work/demo-item/worker-reports/task-2-r1.md")"

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

echo "== a real-sized multibyte body lands promptly =="
# Worker reports run to tens of KB and are full of em-dashes and arrows. A
# non-emptiness check that rewrites the whole body to test it costs seconds at
# 4KB and minutes at 40KB, so this case asserts a wall-clock bound, not just a
# landing. The watchdog is what keeps a regression a failure instead of a hang.
KDIR=$(new_store)
BIG_BODY="$TEST_DIR/big-body.md"
{
  report_body big-r1
  python3 -c 'print("A finding — with an arrow → and an ellipsis … in it.\n" * 800, end="")'
} > "$BIG_BODY"
BIG_BYTES=$(wc -c < "$BIG_BODY" | tr -d '[:space:]')

START=$SECONDS
bash "$REPORT" demo-item --report-id big-r1 --kdir "$KDIR" < "$BIG_BODY" >/dev/null 2>&1 &
BIG_PID=$!
(
  waited=0
  while [[ $waited -lt 30 ]]; do
    kill -0 "$BIG_PID" 2>/dev/null || exit 0
    sleep 1
    waited=$((waited + 1))
  done
  kill -9 "$BIG_PID" 2>/dev/null
) >/dev/null 2>&1 &
wait "$BIG_PID" 2>/dev/null; RC=$?
ELAPSED=$((SECONDS - START))
assert_eq "a ${BIG_BYTES}-byte body lands" "0" "$RC"
if [[ $ELAPSED -lt 10 ]]; then
  pass "it lands in under 10s (took ${ELAPSED}s)"
else
  fail "it lands in under 10s" "took ${ELAPSED}s"
fi
assert_eq "the landed body is byte-complete" "$BIG_BYTES" \
  "$({ wc -c < "$KDIR/_work/demo-item/worker-reports/big-r1.md"; } 2>/dev/null | tr -d '[:space:]')"

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
assert_contains "help documents exit 4" "$OUT" "4  the report path already exists"
assert_contains "help explains that the path is the identity" "$OUT" "The path is the identity"
assert_contains "help explains the replay refusal" "$OUT" "byte-identical"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
