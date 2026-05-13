#!/usr/bin/env bash
# test_retro_vocab_invariant.sh — Phase 4 invariant block tests for /retro Step 2b.7
# Verifies the defensive vocabulary guard at skills/retro/SKILL.md Step 2b.7.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/retro/SKILL.md"

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  if [[ -n "${2:-}" ]]; then
    echo "    $2"
  fi
  FAIL=$((FAIL + 1))
}

assert_file_exists() {
  if [[ -f "$SKILL" ]]; then
    pass "skills/retro/SKILL.md exists"
  else
    fail "skills/retro/SKILL.md exists" "missing: $SKILL"
    exit 1
  fi
}

# Extract Step 2b.7 body: from "### 2b.7" up to (but not including) the next "### " heading.
extract_2b7() {
  awk '
    /^### 2b\.7:/ { capturing=1; next }
    capturing && /^### / { exit }
    capturing { print }
  ' "$SKILL"
}

echo "=== /retro Step 2b.7 invariant block tests ==="
echo ""

# ---------------------------------------------------------------
# Test 1: SKILL.md exists
# ---------------------------------------------------------------
echo "Test 1: skills/retro/SKILL.md is present"
assert_file_exists

# ---------------------------------------------------------------
# Test 2: Step 2b.7 is present and starts with the Invariant block
# ---------------------------------------------------------------
echo ""
echo "Test 2: Step 2b.7 leads with **Invariant — canonical contradiction vocabulary.**"
BODY=$(extract_2b7)
if [[ -z "$BODY" ]]; then
  fail "Step 2b.7 section was located" "no body extracted between '### 2b.7:' and the next '### ' heading"
else
  pass "Step 2b.7 section was located"
fi

# First non-blank line of the section must be the invariant lead.
FIRST_LINE=$(printf '%s\n' "$BODY" | awk 'NF { print; exit }')
EXPECTED_LEAD='**Invariant — canonical contradiction vocabulary.**'
case "$FIRST_LINE" in
  "$EXPECTED_LEAD"*)
    pass "Step 2b.7 first non-blank line begins with the invariant lead"
    ;;
  *)
    fail "Step 2b.7 first non-blank line begins with the invariant lead" \
      "got: $FIRST_LINE"
    ;;
esac

# ---------------------------------------------------------------
# Test 3: Canonical trio appears verbatim ≥ 5 times across the whole file
# (matches phase Verification rule: grep -c "routed | verified | rejected" >= 5)
# ---------------------------------------------------------------
echo ""
echo "Test 3: Canonical trio 'routed | verified | rejected' appears on ≥ 5 lines in SKILL.md"
TRIO_COUNT=$(grep -c "routed | verified | rejected" "$SKILL" || true)
if [[ "$TRIO_COUNT" -ge 5 ]]; then
  pass "canonical trio appears on $TRIO_COUNT lines (≥ 5 required)"
else
  fail "canonical trio appears on $TRIO_COUNT lines (≥ 5 required)" \
    "phase Verification requires preserving existing references plus the new invariant block"
fi

# ---------------------------------------------------------------
# Test 4: Invariant block names the orthogonal dispatch_status field
# ---------------------------------------------------------------
echo ""
echo "Test 4: Invariant block names the orthogonal dispatch_status field"
if printf '%s\n' "$BODY" | grep -qF 'dispatch_status'; then
  pass "Step 2b.7 mentions dispatch_status"
else
  fail "Step 2b.7 mentions dispatch_status" "orthogonal field must be named in the invariant block"
fi

if printf '%s\n' "$BODY" | grep -qE 'dispatch_status.*routed|dispatch_status: routed'; then
  pass "Step 2b.7 ties dispatch_status to the literal value 'routed'"
else
  fail "Step 2b.7 ties dispatch_status to the literal value 'routed'" \
    "invariant block must specify that dispatch_status takes the literal 'routed'"
fi

# ---------------------------------------------------------------
# Test 5: Invariant block carries a drift-detection guard
# (must name what drift looks like AND how to detect it)
# ---------------------------------------------------------------
echo ""
echo "Test 5: Invariant block names what drift looks like and how to detect it"
if printf '%s\n' "$BODY" | grep -qiE 'drift'; then
  pass "Step 2b.7 names 'drift' explicitly"
else
  fail "Step 2b.7 names 'drift' explicitly" "drift-detection guard must label the failure mode"
fi

# Detection mechanism: the guard recommends an inspection over consumption-contradictions.jsonl.
if printf '%s\n' "$BODY" | grep -qF 'consumption-contradictions.jsonl'; then
  pass "Step 2b.7 points to consumption-contradictions.jsonl as the detection substrate"
else
  fail "Step 2b.7 points to consumption-contradictions.jsonl as the detection substrate" \
    "drift-detection guard must direct readers to the JSONL where status values live"
fi

# ---------------------------------------------------------------
# Test 6: Original canonical anchors elsewhere in the file are preserved
# (regression guard against accidental edits to the read-side gate inputs)
# ---------------------------------------------------------------
echo ""
echo "Test 6: Read-side anchors used by Step 3.0 / Step 3.8 are preserved verbatim"

assert_anchor_present() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL"; then
    pass "$label"
  else
    fail "$label" "missing line: $needle"
  fi
}

assert_anchor_present \
  "Step 3.8 routing-health reads dispatch_status: routed" \
  'dispatch_status: routed'

assert_anchor_present \
  "row schema lists status — routed | verified | rejected" \
  '`status` — `routed | verified | rejected`'

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
