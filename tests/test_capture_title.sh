#!/usr/bin/env bash
# test_capture_title.sh — capture.sh --title: an explicit headline becomes the
# entry's H1 and slug source; without it the title is derived from the insight
# exactly as before. Also covers the batch-capture.sh passthrough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
source "$SCRIPT_DIR/lib.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
CAPTURE_SH="$SCRIPT_DIR/capture.sh"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

reset_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
}

capture() {
  bash "$CAPTURE_SH" --kdir "$KNOWLEDGE_DIR" --scale implementation --category conventions \
    --producer-role worker --protocol-slot test "$@" 2>/dev/null
}

only_entry() {
  find "$KNOWLEDGE_DIR/conventions" -name '*.md' | head -1
}

export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

INSIGHT="The retry loop in the uploader backs off exponentially but never caps the delay, so a long outage parks uploads for hours"
HEADLINE="Uploader retry backoff has no ceiling"

echo "=== capture.sh --title ==="

echo "Test 1: --title sets the H1 and the slug"
reset_store
capture --title "$HEADLINE" --insight "$INSIGHT" >/dev/null
ENTRY=$(only_entry)
assert_eq "H1 is the given title" "$(head -1 "$ENTRY")" "# $HEADLINE"
assert_eq "slug comes from the title" "$(basename "$ENTRY" .md)" "$(slugify "$HEADLINE")"
assert_eq "insight is still the body" "$(sed -n 2p "$ENTRY")" "$INSIGHT"

echo "Test 2: without --title the title is derived from the insight as before"
reset_store
capture --insight "$INSIGHT" >/dev/null
ENTRY=$(only_entry)
DERIVED=$(derive_entry_title "$INSIGHT")
assert_eq "H1 is derived from the insight" "$(head -1 "$ENTRY")" "# $DERIVED"
assert_eq "slug comes from the derived title" "$(basename "$ENTRY" .md)" "$(slugify "$DERIVED")"

echo "Test 3: --title=<value> form"
reset_store
capture --title="$HEADLINE" --insight "$INSIGHT" >/dev/null
assert_eq "H1 is the given title" "$(head -1 "$(only_entry)")" "# $HEADLINE"

echo "Test 4: a multi-line title is flattened onto the H1 line"
reset_store
capture --title "$(printf 'Uploader retry backoff\n  has no ceiling ')" --insight "$INSIGHT" >/dev/null
ENTRY=$(only_entry)
assert_eq "H1 is one line" "$(head -1 "$ENTRY")" "# $HEADLINE"
assert_eq "body follows directly" "$(sed -n 2p "$ENTRY")" "$INSIGHT"

echo "Test 5: a blank title falls back to the derived title"
reset_store
capture --title "   " --insight "$INSIGHT" >/dev/null
assert_eq "H1 is derived from the insight" "$(head -1 "$(only_entry)")" "# $DERIVED"

echo "Test 6: a title with no sluggable characters keeps its H1 and takes the insight's slug"
reset_store
capture --title "—" --insight "$INSIGHT" >/dev/null
ENTRY=$(only_entry)
assert_eq "H1 is the given title" "$(head -1 "$ENTRY")" "# —"
assert_eq "slug comes from the insight" "$(basename "$ENTRY" .md)" "$(slugify "$DERIVED")"

echo "Test 7: an explicit title is kept verbatim for lifecycle kinds"
reset_store
capture --kind hypothesis --kind-status untested --title "Hypothesis: uploads stall on outages" \
  --insight "Hypothesis: $INSIGHT" >/dev/null
assert_eq "H1 is the given title" "$(head -1 "$(only_entry)")" "# Hypothesis: uploads stall on outages"

echo "Test 8: --json reports the given title"
reset_store
JSON_OUT=$(capture --title "$HEADLINE" --insight "$INSIGHT" --json)
assert_eq "json title" "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["title"])')" "$HEADLINE"

echo "Test 9: batch-capture.sh carries title through"
reset_store
BATCH_FILE="$TEST_DIR/batch.json"
python3 -c 'import json,sys; json.dump([{"insight": sys.argv[1], "title": sys.argv[2], "scale": "implementation", "category": "conventions"}], open(sys.argv[3], "w"))' \
  "$INSIGHT" "$HEADLINE" "$BATCH_FILE"
bash "$SCRIPT_DIR/batch-capture.sh" --file "$BATCH_FILE" >/dev/null 2>&1
assert_eq "H1 is the given title" "$(head -1 "$(only_entry)")" "# $HEADLINE"

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
