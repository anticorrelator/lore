#!/usr/bin/env bash
# test_capture_similar.sh — the similar-entry notice capture.sh prints after
# filing: a near-verbatim re-capture names its source, an unrelated insight
# names nothing, entries filed since the last index run still count, and every
# way the check can fail to run says so instead of reading as "no matches".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
CAPTURE_SH="$SCRIPT_DIR/capture.sh"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; shift; for line in "$@"; do echo "    $line"; done; FAIL=$((FAIL + 1)); }

assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "Expected: $3" "Actual:   $2"; fi
}

assert_line() {
  if printf '%s\n' "$2" | grep -qxF -- "$3"; then pass "$1"; else fail "$1" "Expected line: $3" "Got: $2"; fi
}

assert_no_match() {
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail "$1" "Should not contain: $3" "Got: $2"; else pass "$1"; fi
}

count_lines() {
  printf '%s\n' "$1" | grep -cF -- "$2" || true
}

json_field() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get(sys.argv[1])))' "$2"
}

capture() {
  bash "$CAPTURE_SH" --kdir "$KNOWLEDGE_DIR" --scale implementation --category gotchas \
    --producer-role worker --protocol-slot test "$@" 2>/dev/null
}

index_store() {
  python3 "$SCRIPT_DIR/pk_cli.py" index "$KNOWLEDGE_DIR" >/dev/null 2>&1
}

RATE_LIMIT="The API rate limiter counts requests in a sliding sixty-second window keyed by tenant, so a burst from one tenant never throttles another tenant sharing the gateway."
UNRELATED="Watercolor paper buckles when the wash is applied before the sizing has fully cured, so stretch the sheet on a board overnight first."

seed_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR/conventions" "$KNOWLEDGE_DIR/gotchas"
  echo '{}' > "$KNOWLEDGE_DIR/_manifest.json"
  cat > "$KNOWLEDGE_DIR/gotchas/api-rate-limiter-counts-requests.md" <<EOF
# The API Rate Limiter Counts Requests
$RATE_LIMIT
<!-- learned: 2026-01-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->
EOF
  cat > "$KNOWLEDGE_DIR/conventions/database-columns-use-snake-case.md" <<'EOF'
# Database Columns Use Snake Case
Database column names use snake_case and every table carries created_at and updated_at timestamps maintained by triggers.
<!-- learned: 2026-01-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->
EOF
  cat > "$KNOWLEDGE_DIR/conventions/deploys-need-vpn.md" <<'EOF'
# Deploys Need The VPN
Production deploys run from the bastion host and need the corporate VPN; the deploy script refuses to start without it.
<!-- learned: 2026-01-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->
EOF
  cat > "$KNOWLEDGE_DIR/gotchas/flaky-browser-tests-share-fixtures.md" <<'EOF'
# Flaky Browser Tests Share Fixtures
Browser tests flake when two specs mutate the shared seed fixture; each spec must clone the fixture before writing to it.
<!-- learned: 2026-01-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->
EOF
}

export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

echo "=== capture.sh similar-entry notice ==="

echo "Test 1: a near-verbatim re-capture names its source"
seed_store
index_store
OUT=$(capture --insight "$RATE_LIMIT (Seen again during the gateway rewrite.)")
assert_line "source reported as similar" "$(printf '%s\n' "$OUT" | sed 's/ (similarity 0\.[0-9][0-9])$//')" \
  "[capture] similar entry: gotchas/api-rate-limiter-counts-requests.md"
assert_eq "notice follows the filing line" "$(printf '%s\n' "$OUT" | head -1 | cut -c1-20)" "[capture] Filed to g"
assert_no_match "no skip line" "$OUT" "similarity check skipped"

echo "Test 2: an unrelated insight names nothing"
seed_store
index_store
OUT=$(capture --insight "$UNRELATED")
assert_no_match "no similar entry" "$OUT" "[capture] similar entry:"
assert_no_match "no skip line" "$OUT" "similarity check skipped"

echo "Test 3: --json carries the matches, and an empty list when nothing matched"
seed_store
index_store
JSON_OUT=$(capture --insight "$RATE_LIMIT" --json)
assert_eq "similar lists the source" \
  "$(printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; print([s["path"] for s in json.load(sys.stdin)["similar"]])')" \
  "['gotchas/api-rate-limiter-counts-requests.md']"
JSON_OUT=$(capture --insight "$UNRELATED" --json)
assert_eq "similar is an empty list" "$(json_field "$JSON_OUT" similar)" "[]"

echo "Test 4: an entry filed since the last index run still counts"
seed_store
index_store
capture --insight "$UNRELATED" >/dev/null
OUT=$(capture --insight "$UNRELATED Tape the edges down as well.")
assert_eq "the unindexed entry is reported" \
  "$(count_lines "$OUT" "[capture] similar entry: gotchas/watercolor-paper-buckles-when-wash-is-applied.md")" "1"

echo "Test 5: a store with no search index prints the skip line and still files"
seed_store
OUT=$(capture --insight "$RATE_LIMIT")
STATUS=$?
assert_eq "exit status" "$STATUS" "0"
assert_eq "exactly one skip line" "$(count_lines "$OUT" "[capture] similarity check skipped: ")" "1"
assert_no_match "no similar entry" "$OUT" "[capture] similar entry:"
assert_eq "entry filed" "$(find "$KNOWLEDGE_DIR/gotchas" -name 'api-rate-limiter-counts-requests-*.md' | wc -l | tr -d ' ')" "1"

echo "Test 6: with --json and no index, similar is null with a reason, and stdout stays JSON"
seed_store
JSON_OUT=$(capture --insight "$RATE_LIMIT" --json)
assert_eq "similar is null" "$(json_field "$JSON_OUT" similar)" "null"
if [[ "$(json_field "$JSON_OUT" similar_skipped)" =~ ^\".+\"$ ]]; then pass "skip reason present"; else fail "skip reason present" "Got: $JSON_OUT"; fi
ERR_OUT=$(bash "$CAPTURE_SH" --kdir "$KNOWLEDGE_DIR" --scale implementation --category gotchas \
  --producer-role worker --protocol-slot test --insight "$UNRELATED" --json 2>&1 >/dev/null)
assert_eq "skip line on stderr" "$(count_lines "$ERR_OUT" "[capture] similarity check skipped: ")" "1"

echo "Test 7: a similarity helper that dies still surfaces as a skip"
seed_store
index_store
BROKEN_SCRIPTS="$TEST_DIR/scripts"
cp -R "$SCRIPT_DIR" "$BROKEN_SCRIPTS"
printf 'import sys\nsys.exit(3)\n' > "$BROKEN_SCRIPTS/capture-similar.py"
OUT=$(bash "$BROKEN_SCRIPTS/capture.sh" --kdir "$KNOWLEDGE_DIR" --scale implementation --category gotchas \
  --producer-role worker --protocol-slot test --insight "$RATE_LIMIT" 2>/dev/null)
STATUS=$?
assert_eq "exit status" "$STATUS" "0"
assert_eq "exactly one skip line" "$(count_lines "$OUT" "[capture] similarity check skipped: ")" "1"
JSON_OUT=$(bash "$BROKEN_SCRIPTS/capture.sh" --kdir "$KNOWLEDGE_DIR" --scale implementation --category gotchas \
  --producer-role worker --protocol-slot test --insight "$RATE_LIMIT" --json 2>/dev/null)
assert_eq "json similar is null" "$(json_field "$JSON_OUT" similar)" "null"

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
