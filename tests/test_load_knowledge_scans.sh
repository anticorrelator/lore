#!/usr/bin/env bash
# test_load_knowledge_scans.sh — Pin the session-start loader's two store scans
# and the elapsed time on its retrieval-log row.
#
#   1. extract_context_signal (scripts/lib.sh) — on main the signal comes from
#      the active work item whose _meta.json changed last; on a branch, from the
#      first item in glob order whose _meta.json names the branch.
#   2. The stale scan (scripts/load-knowledge.sh) — which entries the [Stale]
#      line lists, with which labels, in which order, and the count.
#   3. elapsed_ms on the loader's retrieval-log row.
#
# Everything runs from a scratch git repo, so the branch under test is the one
# the fixture checks out rather than whichever branch this checkout is on.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_DIR/scripts"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

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

# set_age <days> <file>... — mtime <days> days and one hour before now
set_age() {
  python3 - "$@" <<'PYEOF'
import os, sys, time
days, paths = int(sys.argv[1]), sys.argv[2:]
t = time.time() - days * 86400 - 3600
for p in paths:
    os.utime(p, (t, t))
PYEOF
}

GIT_REPO="$TEST_DIR/repo"
mkdir -p "$GIT_REPO"
git -C "$GIT_REPO" init -q
git -C "$GIT_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$GIT_REPO" branch -M main
git -C "$GIT_REPO" branch feat/shared
git -C "$GIT_REPO" branch feat/nomatch
cd "$GIT_REPO"

source "$SCRIPT_DIR/lib.sh"

echo "=== Session-start loader scan tests ==="

# =============================================
# Test 1: extract_context_signal on main
# =============================================
echo ""
echo "Test 1: on main, the active work item changed last supplies the signal"

KDIR="$TEST_DIR/signal"
write_item() {
  local slug="$1" title="$2" status="$3" branch="$4"
  mkdir -p "$KDIR/_work/$slug"
  cat > "$KDIR/_work/$slug/_meta.json" << EOF
{
  "title": "$title",
  "status": "$status",
  "branches": ["$branch"]
}
EOF
}
write_item m1-older "Older Active" active main
write_item m2-completed "Completed Item" completed main
write_item m3-archived "Archived Item" archived main
write_item m4-newest "Newest Active" active main
write_item m5-tied "Tied Active" active main
write_item _underscored "Underscored Dir" active main
printf 'Newest notes see [[knowledge:conventions/newest]]\n' > "$KDIR/_work/m4-newest/notes.md"

set_age 3 "$KDIR/_work/m1-older/_meta.json"
set_age 1 "$KDIR/_work/m4-newest/_meta.json" "$KDIR/_work/m5-tied/_meta.json"
set_age 0 "$KDIR/_work/m2-completed/_meta.json" "$KDIR/_work/m3-archived/_meta.json" \
  "$KDIR/_work/_underscored/_meta.json"

git checkout -q main
# The notes text keeps the space its newline became.
assert_eq "completed, archived and _-prefixed items are passed over; a tie goes to the earlier item" \
  "$(extract_context_signal "$KDIR")" \
  "$(printf '%s\n' "Newest Active Newest notes see [[knowledge:conventions/newest]] " \
    ---BACKLINKS--- conventions/newest ---SIGNAL_SOURCES--- title notes backlinks)"

rm -rf "$KDIR/_work/m4-newest" "$KDIR/_work/m5-tied"
assert_eq "the older active item is next" \
  "$(extract_context_signal "$KDIR" | head -1)" "Older Active"

# =============================================
# Test 2: extract_context_signal on a branch
# =============================================
echo ""
echo "Test 2: on a branch, the first item in glob order naming it supplies the signal"

write_item b1-first "First Branch Item" completed feat/shared
write_item b2-second "Second Branch Item" active feat/shared

git checkout -q feat/shared
assert_eq "the first match wins whatever its status" \
  "$(extract_context_signal "$KDIR")" \
  "feat shared First Branch Item
---BACKLINKS---
---SIGNAL_SOURCES---
branch
title"

git checkout -q feat/nomatch
assert_eq "an unmatched branch contributes only its name" \
  "$(extract_context_signal "$KDIR")" \
  "feat nomatch
---BACKLINKS---
---SIGNAL_SOURCES---
branch"
git checkout -q main

# =============================================
# Test 3: the stale scan
# =============================================
echo ""
echo "Test 3: the stale scan's labels, order, retired exclusion and count"

# No _work directory: no context signal, so the scan covers the rubric
# categories only and the loader issues no search.
KDIR="$TEST_DIR/stale"
mkdir -p "$KDIR/principles" "$KDIR/workflows" "$KDIR/conventions/nested" "$KDIR/preferences"
echo '{"format_version": 2}' > "$KDIR/_manifest.json"
write_entry() {
  printf '# %s\n\nBody.\n<!-- learned: 2026-01-01 | confidence: %s | source: interactive | status: %s -->\n' \
    "$1" "$2" "$3" > "$KDIR/$1"
}
write_entry principles/old-live.md high current
write_entry principles/old-retired.md high retired
write_entry conventions/nested/old-lowconf.md low current
write_entry conventions/nested/lowconf-retired.md low retired
write_entry preferences/lowconf-live.md low current
write_entry preferences/fresh.md high current
set_age 120 "$KDIR/principles/old-live.md"
set_age 200 "$KDIR/principles/old-retired.md" "$KDIR/conventions/nested/lowconf-retired.md"
set_age 100 "$KDIR/conventions/nested/old-lowconf.md"

run_loader() { LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/load-knowledge.sh" </dev/null 2>&1; }

STALE_LINE=$(run_loader | grep '^\[Stale\]' || true)
assert_eq "age labels first, then low-confidence; an old low-confidence entry is listed once" \
  "$STALE_LINE" \
  "[Stale] Entries needing review: principles/old-live.md (120d) conventions/nested/old-lowconf.md (100d) preferences/lowconf-live.md (low-confidence)"

for i in 01 02 03 04 05 06 07 08 09 10 11; do
  write_entry "workflows/old-$i.md" high current
  set_age 95 "$KDIR/workflows/old-$i.md"
done
STALE_LINE=$(run_loader | grep '^\[Stale\]' || true)
assert_contains "the count covers every listed entry" "$STALE_LINE" \
  "[Stale] 14 entries needing review (showing 10): principles/old-live.md (120d) workflows/old-"
assert_contains "the listing stops at ten" "$STALE_LINE" " … +4 more"

# =============================================
# Test 4: elapsed_ms on the retrieval-log row
# =============================================
echo ""
echo "Test 4: the loader's retrieval-log row carries its elapsed time"

ROW_CHECK=$(tail -1 "$KDIR/_meta/retrieval-log.jsonl" | python3 -c '
import json, sys
row = json.load(sys.stdin)
ms = row.get("elapsed_ms")
print("budget_used" in row, isinstance(ms, int) and 0 <= ms < 60000)')
assert_eq "elapsed_ms is a whole number of milliseconds on the budget row" "$ROW_CHECK" "True True"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
