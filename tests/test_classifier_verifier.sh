#!/usr/bin/env bash
# test_classifier_verifier.sh — Tests for verifier-only classifier behavior.
# Covers: verifier-only spec (no entry-file modification claim), output schema shape,
# backfill proposal emission shape, and absence of hybrid/primary_assignments references.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$REPO_ROOT/agents/classifier.md"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (not found: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label (unexpected: $needle)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== test_classifier_verifier.sh ==="
echo ""

CONTENT=$(cat "$CLASSIFIER")

# --- Test 1: Classifier file exists ---
echo "Test 1: agents/classifier.md exists"
if [[ -f "$CLASSIFIER" ]]; then
  echo "  PASS: classifier.md exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: classifier.md not found at $CLASSIFIER"
  FAIL=$((FAIL + 1))
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

# --- Test 2: Verifier-only invariant — classifier does NOT modify entry files ---
echo ""
echo "Test 2: Verifier-only invariant — no entry-file modification claim"
assert_not_contains "no 'lore capture' call" "$CONTENT" "lore capture"
assert_not_contains "no 'write.*entry' instruction" "$CONTENT" "write the entry"
assert_contains "advisory output declared" "$CONTENT" "do NOT modify knowledge files"

# --- Test 3: Output is written to _meta/classification-report.json ---
echo ""
echo "Test 3: Output path is _meta/classification-report.json"
assert_contains "output path declared" "$CONTENT" "_meta/classification-report.json"

# --- Test 4: Required top-level output schema fields present ---
echo ""
echo "Test 4: Required top-level schema fields in output"
assert_contains "disagreements array" "$CONTENT" '"disagreements"'
assert_contains "demotions array" "$CONTENT" '"demotions"'
assert_contains "relabels array" "$CONTENT" '"relabels"'
assert_contains "backfill_proposals array" "$CONTENT" '"backfill_proposals"'
assert_contains "skipped_entries array" "$CONTENT" '"skipped_entries"'
assert_contains "summary object" "$CONTENT" '"summary"'

# --- Test 5: Backfill proposal shape — entry, proposed_scale, evidence ---
echo ""
echo "Test 5: Backfill proposal items carry required fields"
assert_contains "backfill proposal has entry field" "$CONTENT" '"entry":'
assert_contains "backfill proposal has proposed_scale field" "$CONTENT" '"proposed_scale":'
assert_contains "backfill proposal has evidence field" "$CONTENT" '"evidence":'

# --- Test 6: Summary counter for backfill proposals present ---
echo ""
echo "Test 6: Summary includes backfill_proposals_made counter"
assert_contains "backfill_proposals_made in summary" "$CONTENT" '"backfill_proposals_made"'

# --- Test 7: No hybrid mode or primary_assignments references ---
echo ""
echo "Test 7: No hybrid mode or primary_assignments references"
assert_not_contains "no classifier_mode" "$CONTENT" "classifier_mode"
assert_not_contains "no hybrid mode text" "$CONTENT" "hybrid mode"
assert_not_contains "no primary_assignments" "$CONTENT" "primary_assignments"
assert_not_contains "no unscaled_entries template var" "$CONTENT" "{{unscaled_entries}}"

# --- Test 8: Task 4 is Legacy Backfill Proposal (not Primary Scale Assignment) ---
echo ""
echo "Test 8: Task 4 is Legacy Backfill Proposal"
assert_contains "Task 4 exists" "$CONTENT" "## Task 4:"
assert_contains "Task 4 is backfill" "$CONTENT" "Legacy Backfill Proposal"
assert_not_contains "Task 4 is not primary assignment" "$CONTENT" "Primary Scale Assignment"

# --- Test 9: Backfill task is coverage-gated (runs only below threshold) ---
echo ""
echo "Test 9: Backfill task is gated by declaration coverage threshold"
assert_contains "coverage threshold gate" "$CONTENT" "declaration coverage"

# --- Test 10: Classifier output is advisory — proposals not automatic mutations ---
echo ""
echo "Test 10: Backfill proposals are advisory (human-confirmable), not automatic mutations"
assert_contains "proposals for human review" "$CONTENT" "proposals for human review"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
