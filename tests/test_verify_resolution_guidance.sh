#!/usr/bin/env bash
# test_verify_resolution_guidance.sh — Pin the consumption-verification
# reaction point in the worker and researcher templates: a contradicted
# verification is documented as an owned resolution, never as a terminal
# report.
#
# Only the settled contract is pinned — the two resolution values, the
# gate error, the steward framing, and the held-path guidance the rewrite
# must preserve. Branch-specific flag names and surrounding prose may
# drift; the checks below must not.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_MD="$REPO_DIR/agents/worker.md"
RESEARCHER_MD="$REPO_DIR/agents/researcher.md"
VERIFY_APPEND="$REPO_DIR/scripts/verify-append.sh"

PASS=0
FAIL=0

assert_file_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

# Prose in these templates is hard-wrapped, so phrase checks match against a
# whitespace-flattened copy rather than individual lines.
assert_prose_contains() {
  local label="$1" file="$2" pattern="$3"
  if tr '\n' ' ' <"$file" | tr -s ' ' | grep -qF -- "$pattern"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_lacks() {
  local label="$1" file="$2" pattern="$3"
  if grep -qF -- "$pattern" "$file"; then
    echo "  FAIL: $label"
    echo "    File:      $file"
    echo "    Should not contain: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== Verify Resolution Guidance Tests ==="
echo ""

echo "Test 1: both resolution values appear as concrete invocations"
# The reader has to see both branches spelled out. A template naming only
# one of them teaches a fork with a single reachable arm.
for pair in "worker:$WORKER_MD" "researcher:$RESEARCHER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  assert_file_contains "$role template shows the corrected invocation" \
    "$file" "contradicted --resolution corrected"
  assert_file_contains "$role template shows the disputed invocation" \
    "$file" "contradicted --resolution disputed"
done

echo ""
echo "Test 2: no documented path files a contradiction without resolving it"
# `contradicted \` is the old terminal form: disposition, line continuation,
# grounding flags, done. If it reappears, a reader can follow an invocation
# that decrements trust and leaves the entry ownerless.
for pair in "worker:$WORKER_MD" "researcher:$RESEARCHER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  assert_file_lacks "$role template has no resolution-free contradicted call" \
    "$file" "contradicted \\"
  assert_file_lacks "$role template no longer routes contradictions to a judge" \
    "$file" "judge-facing"
  assert_file_lacks "$role template no longer writes the contradiction sidecar" \
    "$file" "consumption-contradictions.jsonl"
done

echo ""
echo "Test 3: the branch gate is named and the fork criteria stay at two"
# `disputed-required` is the front's answer when the evidence cannot carry
# the claim; a template that omits it leaves the altitude test unactionable.
for pair in "worker:$WORKER_MD" "researcher:$RESEARCHER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  assert_prose_contains "$role template names the altitude-test gate answer" \
    "$file" "disputed-required"
  assert_prose_contains "$role template keeps the fork at two criteria" \
    "$file" "Nothing else gates the fork."
  # Importance gates were removed by design; prose reintroducing them would
  # send agents looking for an escalation path that does not exist.
  assert_prose_contains "$role template states no entry is out of reach" \
    "$file" "too widely cited to be corrected"
done

echo ""
echo "Test 4: the steward stance is stated affirmatively"
for pair in "worker:$WORKER_MD" "researcher:$RESEARCHER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  assert_prose_contains "$role template frames a repair as a checkable claim" \
    "$file" "a claim the next agent will check"
  assert_prose_contains "$role template frames verification as in-band" \
    "$file" "mutual and in-band"
done

echo ""
echo "Test 5: the held path and grounding requirements survive the rewrite"
for pair in "worker:$WORKER_MD" "researcher:$RESEARCHER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  assert_file_contains "$role template keeps the held invocation" \
    "$file" "held \\"
  assert_prose_contains "$role template keeps grounded-or-nothing" \
    "$file" "Grounded-or-nothing applies to both dispositions"
  assert_prose_contains "$role template keeps the held-reports-matter framing" \
    "$file" "Held reports matter as much as contradictions"
  assert_prose_contains "$role template keeps the run-from-source-repo note" \
    "$file" "from the source repo's root"
done

echo ""
echo "Test 6: the templates name the branch flags the script requires"
# Prose and CLI must speak the same vocabulary: a flag renamed in
# verify-append.sh without the templates following leaves agents copying an
# invocation the front rejects. Each flag is asserted against the script and
# both templates, so either side drifting alone fails here.
BRANCH_FLAGS=(
  --resolution
  --superseded-text
  --replacement-text
  --confidence
  --evidence-scope
  --claim-scale
  --dispute-note
)
for flag in "${BRANCH_FLAGS[@]}"; do
  assert_file_contains "verify-append.sh accepts $flag" \
    "$VERIFY_APPEND" "$flag)"
  assert_file_contains "worker template names $flag" "$WORKER_MD" "$flag"
  assert_file_contains "researcher template names $flag" "$RESEARCHER_MD" "$flag"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
