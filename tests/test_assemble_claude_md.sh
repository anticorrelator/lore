#!/usr/bin/env bash
# test_assemble_claude_md.sh — Tests for the CLAUDE.md assembly pipeline
# Covers: motivation block present in fragment, word count ≤200, check exits 0.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAGMENT="$REPO_ROOT/claude-md/20-retrieval-protocol.md"

PASS=0
FAIL=0

assert_exit_zero() {
  local label="$1"
  local exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (not found: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

assert_le() {
  local label="$1"
  local value="$2"
  local limit="$3"
  if [[ "$value" -le "$limit" ]]; then
    echo "  PASS: $label ($value ≤ $limit)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label ($value > $limit)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_assemble_claude_md.sh ==="
echo ""

# --- Test 1: fragment file exists ---
echo "Test 1: claude-md/20-retrieval-protocol.md exists"
if [[ -f "$FRAGMENT" ]]; then
  echo "  PASS: fragment exists"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fragment not found at $FRAGMENT"
  FAIL=$((FAIL + 1))
fi

FRAGMENT_CONTENT=$(cat "$FRAGMENT")

# --- Test 2: Scale Declaration section present ---
echo ""
echo "Test 2: Scale Declaration section present in fragment"
assert_contains "Scale Declaration heading" "$FRAGMENT_CONTENT" "### Scale Declaration"

# --- Test 3: All four motivation claims present ---
echo ""
echo "Test 3: All four motivation claims present"
assert_contains "Claim 1 — Trust your declaration" "$FRAGMENT_CONTENT" "Trust your declaration"
assert_contains "Claim 2 — Off-altitude harmful" "$FRAGMENT_CONTENT" "Off-altitude content is harmful"
assert_contains "Claim 3 — Re-declare with intent" "$FRAGMENT_CONTENT" "Re-declare with intent"
assert_contains "Claim 4 — Narrow results" "$FRAGMENT_CONTENT" "Narrow results aren"

# --- Test 4: Motivation block word count ≤200 ---
echo ""
echo "Test 4: Scale Declaration section word count ≤200"
# Extract just the Scale Declaration section (from heading to next ###)
SECTION=$(awk '/^### Scale Declaration/,/^### [^S]/' "$FRAGMENT" | grep -v "^### [^S]" || true)
if [[ -z "$SECTION" ]]; then
  # Fallback: extract to end of file if no next section
  SECTION=$(awk '/^### Scale Declaration/{found=1} found{print}' "$FRAGMENT")
fi
WORD_COUNT=$(echo "$SECTION" | wc -w | tr -d '[:space:]')
assert_le "Scale Declaration section ≤200 words" "$WORD_COUNT" 200

# --- Test 5: No rubric definitions in fragment (motivation only) ---
echo ""
echo "Test 5: Fragment does not contain full rubric definitions (motivation only per D3)"
# The rubric has specific phrases that should NOT appear in CLAUDE.md
if echo "$FRAGMENT_CONTENT" | grep -qF "implementation: a finding about"; then
  echo "  FAIL: rubric definitions leaked into fragment (found 'implementation: a finding about')"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: no rubric definitions in fragment"
  PASS=$((PASS + 1))
fi

# --- Test 6: assemble-claude-md.sh --check exits 0 ---
echo ""
echo "Test 6: assemble-claude-md.sh --check exits 0"
ASSEMBLE_SCRIPT="$HOME/.lore/scripts/assemble-claude-md.sh"
if [[ -f "$ASSEMBLE_SCRIPT" ]]; then
  bash "$ASSEMBLE_SCRIPT" --check > /dev/null 2>&1
  assert_exit_zero "assemble-claude-md.sh --check" "$?"
else
  echo "  SKIP: assemble-claude-md.sh not found at $ASSEMBLE_SCRIPT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
