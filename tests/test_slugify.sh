#!/usr/bin/env bash
# test_slugify.sh — Tests for slugify() in scripts/lib.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: [$expected]"
    echo "    actual:   [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_newline() {
  local label="$1" actual="$2"
  if [[ "$actual" != *$'\n'* ]]; then
    echo "  PASS: $label (no embedded newline)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — embedded newline in [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

echo "Test: slugify"

assert_eq "basic kebab" "$(slugify 'My Work Item Name')" "my-work-item-name"
assert_eq "stopwords stripped" "$(slugify 'The Quick Brown Fox')" "quick-brown-fox"
assert_eq "punctuation collapsed" "$(slugify 'foo: bar/baz!!!')" "foo-bar-baz"

# Multi-line input — the bug this test guards against:
# generate_title() in capture.sh feeds awk-output (with embedded newlines) into
# slugify; the line-oriented sed pipeline used to leave those newlines intact,
# producing invalid filenames.
multi=$(printf 'line1 with words\nline2 with more words')
assert_no_newline "multi-line input produces single-line slug" "$(slugify "$multi")"
assert_eq "multi-line content joined" "$(slugify "$multi")" "line1-words-line2-more-words"

# Tabs and runs of whitespace.
assert_eq "tabs flattened" "$(slugify "$(printf 'one\ttwo\tthree')")" "one-two-three"
assert_eq "runs of spaces collapsed" "$(slugify 'foo   bar   baz')" "foo-bar-baz"

# Trailing-dash from truncation or stopword tails:
# When a slug got truncated mid-token at MAX_SLUG_LENGTH, or when the final
# token was a stopword-shaped fragment surrounded by punctuation (e.g. "d2 "
# emitted "-d2-" then truncation could leave a dangling dash), the result
# previously ended in "-".
long="a really really really really really really really long title here"
result=$(slugify "$long")
if [[ "$result" != *- ]]; then
  echo "  PASS: long input has no trailing dash"
  PASS=$((PASS + 1))
else
  echo "  FAIL: long input has trailing dash: [$result]"
  FAIL=$((FAIL + 1))
fi

# Reproduces the exact form that produced "lore-advertising-...-d2-governance-.md"
assert_eq "no trailing dash on real-world capture" \
  "$(slugify 'lore advertising surfaces inventory d2 governance')" \
  "lore-advertising-surfaces-inventory-d2-governance"

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
