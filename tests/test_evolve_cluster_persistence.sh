#!/usr/bin/env bash
# test_evolve_cluster_persistence.sh — /evolve Step 6 cluster-confirmation
# persistence (Phase 2).
#
# Validates that the Step 6 CLUSTER REVIEW confirmation handler is wired to the
# real sole-writer (scripts/accepted-cluster-append.sh) introduced in Phase 1.
# Two layers:
#
# 1. Documentation contract — the SKILL.md text wires each accept decision
#    (y/edit/split/merge) to the writer and skips the write on `n`, no longer
#    describing the writer as a Phase 5 stub, and carries the canonical-
#    vocabulary invariant comment.
#
# 2. Behavioral end-to-end — drive the actual writer the way Step 6 would for
#    each decision branch and assert the resulting _evolve/accepted-clusters.jsonl:
#      - y confirmation        → exactly one row
#      - n rejection           → no row (writer never invoked)
#      - merge of 2 candidates → one row with the union member list
#      - rerun of same cycle   → no duplicate row (cluster_id idempotency)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$REPO_DIR/skills/evolve/SKILL.md"
WRITER="$REPO_DIR/scripts/accepted-cluster-append.sh"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
SIDECAR="$KDIR/_evolve/accepted-clusters.jsonl"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "Expected: $expected | Actual: $actual"
  fi
}

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label" "Pattern not found in $file: $pattern"
  fi
}

assert_not_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE -- "$pattern" "$file"; then
    fail "$label" "Pattern unexpectedly present in $file: $pattern"
  else
    pass "$label"
  fi
}

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
}

sidecar_lines() {
  [[ -f "$SIDECAR" ]] && wc -l < "$SIDECAR" | tr -d ' ' || echo 0
}

# Drive the writer exactly as a Step 6 accept branch does.
confirm_cluster() {
  local target="$1" change_types="$2" work_items="$3" decision="$4" run_id="$5"
  "$WRITER" \
    --target "$target" \
    --change-types "$change_types" \
    --work-items "$work_items" \
    --decision "$decision" \
    --accepted-at-run-id "$run_id" \
    --kdir "$KDIR"
}

echo "=== /evolve Step 6 cluster persistence (Phase 2) ==="

# =========================================================================
# Layer 1: Documentation contract
# =========================================================================
echo ""
echo "Test 1: Step 6 wires accept decisions to the writer; n skips it"
assert_grep "writer invoked from Step 6" "accepted-cluster-append.sh" "$SKILL_MD"
assert_grep "n branch skips the writer" "do not invoke the writer" "$SKILL_MD"
assert_grep "merge produces a union member row" "union of both candidates" "$SKILL_MD"
assert_grep "canonical-vocabulary invariant comment present" "Canonical vocabulary consumed by accepted-cluster-append" "$SKILL_MD"
# The Phase 5 "stub" caveat must be gone now that the writer exists.
assert_not_grep "no Phase 5 stub caveat remains" "the persistence step is a stub" "$SKILL_MD"
assert_not_grep "no 'Phase 5 dependency' caveat on the writer" "Phase 5 dependency" "$SKILL_MD"

# =========================================================================
# Layer 2: Behavioral end-to-end
# =========================================================================
echo ""
echo "Test 2: y confirmation → exactly one row"
setup_store
confirm_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-alpha,wi-beta,wi-gamma" "merge" "run-N" > /dev/null
assert_eq "one row after y confirmation" "$(sidecar_lines)" "1"
ROW=$(cat "$SIDECAR")
assert_eq "row target persisted" "$(echo "$ROW" | jq -r '.target')" "skills/foo/SKILL.md"
assert_eq "row work_items = 3 members" "$(echo "$ROW" | jq -r '.work_items | length')" "3"
assert_eq "row decision = merge" "$(echo "$ROW" | jq -r '.accepted_by_maintainer_decision')" "merge"

echo ""
echo "Test 3: n rejection → no row (writer never invoked)"
setup_store
# A Step 6 'n' branch does NOT call the writer at all; assert the sidecar stays absent.
assert_eq "no row after n rejection" "$(sidecar_lines)" "0"
assert_eq "sidecar file not created" "$([[ -f "$SIDECAR" ]] && echo present || echo absent)" "absent"

echo ""
echo "Test 4: merge of two candidates → one row with union member list"
setup_store
# Two candidate clusters on the same (target, change_type) carrying disjoint
# members. The maintainer 'merge' decision combines them into a single row
# whose --work-items is the union.
C1="wi-alpha,wi-beta"
C2="wi-gamma,wi-delta"
UNION="$C1,$C2"
confirm_cluster "skills/foo/SKILL.md" "ceiling-raise" "$UNION" "merge" "run-N" > /dev/null
assert_eq "one row after merge" "$(sidecar_lines)" "1"
ROW=$(cat "$SIDECAR")
assert_eq "merged row has 4 union members" "$(echo "$ROW" | jq -r '.work_items | length')" "4"
assert_eq "merged work_items sorted union" "$(echo "$ROW" | jq -c '.work_items')" '["wi-alpha","wi-beta","wi-delta","wi-gamma"]'

echo ""
echo "Test 5: rerun of the same cycle → no duplicate row (idempotency)"
# Continuing from Test 4's state: re-confirm the identical merged cluster as if
# a second /evolve run over an unchanged journal re-presented it. cluster_id is
# re-derived identically, so the writer no-ops.
confirm_cluster "skills/foo/SKILL.md" "ceiling-raise" "$UNION" "merge" "run-N+1" > /dev/null
assert_eq "still one row after rerun" "$(sidecar_lines)" "1"
# Member order should not matter either — the same set in a different order.
confirm_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-delta,wi-gamma,wi-beta,wi-alpha" "merge" "run-N+2" > /dev/null
assert_eq "still one row after reordered rerun" "$(sidecar_lines)" "1"

echo ""
echo "Test 6: distinct confirmations accumulate (append-only across decisions)"
setup_store
confirm_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-a,wi-b,wi-c" "merge" "run-N" > /dev/null
confirm_cluster "skills/bar/SKILL.md" "guardrail-add" "wi-d,wi-e,wi-f" "edit" "run-N" > /dev/null
assert_eq "two distinct confirmations → two rows" "$(sidecar_lines)" "2"
assert_eq "first row decision merge" "$(head -1 "$SIDECAR" | jq -r '.accepted_by_maintainer_decision')" "merge"
assert_eq "second row decision edit" "$(tail -1 "$SIDECAR" | jq -r '.accepted_by_maintainer_decision')" "edit"

# =========================================================================
# Layer 3: Batch-confirmation mode for backfill input (Phase 4)
# =========================================================================
# `lore retro backfill` candidates carry a SINGULAR change_type plus a
# work_items[] list; the Step 6 batch flow maps that change_type to a
# one-element --change-types list and confirms one candidate per prompt.
# Simulate accept of two backfill candidates and one rejection.

echo ""
echo "Test 7: backfill candidate (singular change_type) maps to a one-element change_types list"
setup_store
# A backfill candidate: target, change_type=new-failure-mode, work_items list.
confirm_cluster "skills/spec/SKILL.md" "new-failure-mode" "wi-1,wi-2,wi-3,wi-4" "merge" "backfill-run" > /dev/null
assert_eq "one row after backfill confirm" "$(sidecar_lines)" "1"
ROW=$(cat "$SIDECAR")
assert_eq "change_types is a one-element list" "$(echo "$ROW" | jq -c '.change_types')" '["new-failure-mode"]'
assert_eq "all 4 backfill members persisted" "$(echo "$ROW" | jq -r '.work_items | length')" "4"

echo ""
echo "Test 8: batch flow — two accepts + one reject yields exactly two rows"
setup_store
# Candidate A: accepted (y/merge)
confirm_cluster "skills/spec/SKILL.md" "new-failure-mode" "wi-1,wi-2,wi-3" "merge" "backfill-run" > /dev/null
# Candidate B: rejected (n) — the batch flow does NOT call the writer; nothing to run.
# Candidate C: accepted (edit)
confirm_cluster "skills/retro/SKILL.md" "evidence-gap" "wi-4,wi-5,wi-6" "edit" "backfill-run" > /dev/null
assert_eq "two accepts → two rows; reject wrote nothing" "$(sidecar_lines)" "2"

echo ""
echo "Test 9: batch re-run is idempotent (same candidates → no duplicate rows)"
# Re-confirming both accepted candidates (as a second backfill pass would) adds nothing.
confirm_cluster "skills/spec/SKILL.md" "new-failure-mode" "wi-3,wi-2,wi-1" "merge" "backfill-run-2" > /dev/null
confirm_cluster "skills/retro/SKILL.md" "evidence-gap" "wi-6,wi-5,wi-4" "edit" "backfill-run-2" > /dev/null
assert_eq "still two rows after re-running the batch" "$(sidecar_lines)" "2"

echo ""
echo "Test 10: Step 6 documentation contract — batch-confirmation mode (D5) present"
assert_grep "names batch-confirmation mode" "Batch-confirmation mode \(backfill input\)" "$SKILL_MD"
assert_grep "candidate source is lore retro backfill" "lore retro backfill" "$SKILL_MD"
assert_grep "one prompt per candidate" "one CLUSTER REVIEW prompt per candidate" "$SKILL_MD"
assert_grep "singular change_type → one-element list" "one-element .--change-types. list" "$SKILL_MD"
assert_grep "tallies proposed/confirmed/merged/rejected" "proposed / confirmed / merged / rejected" "$SKILL_MD"
assert_grep "no auto-confirm of operator decisions" "Do not auto-confirm" "$SKILL_MD"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -gt 0 ]] && exit 1
exit 0
