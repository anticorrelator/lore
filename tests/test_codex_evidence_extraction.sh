#!/usr/bin/env bash
# test_codex_evidence_extraction.sh — Tests for the chaperone-proxied Tier 2
# append contract in agents/codex-worker.md (§ "Append the Tier 2 rows").
#
# Codex workers run in a workspace-write sandbox that does NOT reach the shared
# knowledge store, so they cannot run evidence-append.sh directly. Instead they
# print their Tier 2 rows as raw compact JSON between the sentinels
#   ===LORE-TIER2-BEGIN===
#   ===LORE-TIER2-END===
# and the chaperone (a normal Claude subagent, outside the sandbox) extracts
# those rows and appends each via evidence-append.sh.
#
# This test exercises the two mechanical halves of that contract:
#   1. The awk sentinel extraction (mirrors the snippet in the doc's
#      "Append the Tier 2 rows" step).
#   2. The extract → evidence-append.sh append loop against a real KDIR,
#      including the relay-verbatim-or-degraded row path: a row the validator
#      refuses lands in REJECTED with its diagnostic, never silently dropped.
#
# Covers:
#   1. Extraction returns only the rows between the sentinels — surrounding
#      report prose is excluded.
#   2. A report with no sentinel block ("Tier 2 evidence: none") extracts to
#      nothing.
#   3. Valid rows append through the real evidence-append.sh and land in
#      task-claims.jsonl with their claim_ids.
#   4. A malformed row is rejected (captured in REJECTED with a diagnostic) and
#      does NOT land, while a valid sibling in the same block still lands.
#   5. A missing END sentinel degrades to capturing through EOF — the stray
#      trailing lines fail validation and are reported rejected, never silently
#      appended (documents the awk fall-through the doc warns about).
#   6. The delimiter tokens the test hard-codes still match the doc (anti-drift).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
APPEND="$SCRIPTS_DIR/evidence-append.sh"
NORMALIZE_PY="$SCRIPTS_DIR/snippet_normalize.py"
DOC="$REPO_DIR/agents/codex-worker.md"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
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
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $needle"
    echo "    Got: $(printf '%s' "$haystack" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

hash_of() {
  printf '%s' "$1" | python3 "$NORMALIZE_PY" --hash
}

build_row() {
  # Build a Tier 2 row, overrides via key=JSON-value args. key=__DELETE__ drops.
  python3 - "$@" <<'PYEOF'
import json, sys
base = {
    "claim_id": "t-1",
    "tier": "task-evidence",
    "claim": "claim text",
    "producer_role": "worker",
    "protocol_slot": "implement-phase-2",
    "task_id": "task-1",
    "phase_id": "phase-2",
    "scale": "implementation",
    "file": "/tmp/example.py",
    "line_range": "10-20",
    "falsifier": "falsifier text",
    "why_this_work_needs_it": "because reasons",
    "captured_at_sha": "deadbeef",
    "change_context": {
        "diff_ref": None,
        "changed_files": ["/tmp/example.py"],
        "summary": "summary",
    },
}
for arg in sys.argv[1:]:
    k, v = arg.split("=", 1)
    if v == "__DELETE__":
        base.pop(k, None)
    else:
        base[k] = json.loads(v)
print(json.dumps(base))
PYEOF
}

# --- extract_rows: mirrors the awk sentinel extraction in
#     agents/codex-worker.md's "Append the Tier 2 rows" step. Keep in sync with
#     the doc; Test 6 guards the sentinel tokens against drift.
extract_rows() {
  awk '
    /^===LORE-TIER2-BEGIN===$/ {f=1; next}
    /^===LORE-TIER2-END===$/   {f=0}
    f' "$1"
}

# --- append_extracted: mirrors the extract → append loop in the "Append the
#     Tier 2 rows" step. Populates the
#     global APPENDED (claim_ids that landed) and REJECTED ("row :: diagnostic").
append_extracted() {
  local codex_out="$1" kdir="$2" slug="$3" rows row cid append_out
  rows=$(extract_rows "$codex_out")
  APPENDED=()
  REJECTED=()
  while IFS= read -r row; do
    [[ -z "${row// }" ]] && continue
    if append_out=$(printf '%s' "$row" | bash "$APPEND" --work-item "$slug" --kdir "$kdir" 2>&1); then
      cid=$(printf '%s' "$row" | jq -r '.claim_id // "(unknown)"' 2>/dev/null || echo "(unknown)")
      APPENDED+=("$cid")
    else
      REJECTED+=("$row :: $append_out")
    fi
  done <<< "$rows"
}

seed_kdir() {
  local kdir="$1"
  rm -rf "$kdir"
  mkdir -p "$kdir/_work/wi"
  : > "$kdir/_work/wi/task-claims.jsonl"
}

GOOD_SNIPPET="print('hello')"
GOOD_HASH=$(hash_of "$GOOD_SNIPPET")

echo "=== codex evidence extraction / chaperone-proxied append tests ==="

echo ""
echo "Test 1: extraction returns only rows between the sentinels"
ROW_A=$(build_row "claim_id=\"a\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"" | jq -c '.')
ROW_B=$(build_row "claim_id=\"b\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"" | jq -c '.')
FIX1="$TEST_DIR/codex_out_1.txt"
{
  echo "Routed via codex exec — harness=codex model=x effort=none"
  echo "**Task:** do the thing"
  echo "**Changes:** foo.py: did the thing"
  echo "**Tests:** ran 3 / 0 failures"
  echo "**Observations:**"
  echo "- claim: \"a real observation, not a row\""
  echo "**Tier 2 evidence:** 2 rows below"
  echo "**Convention handling:** none in scope"
  echo "**Surfaced concerns:** None"
  echo "**Blockers:** none"
  echo "===LORE-TIER2-BEGIN==="
  echo "$ROW_A"
  echo "$ROW_B"
  echo "===LORE-TIER2-END==="
} > "$FIX1"
EXTRACTED=$(extract_rows "$FIX1")
assert_eq "extracts exactly the two rows" "$EXTRACTED" "$(printf '%s\n%s' "$ROW_A" "$ROW_B")"
assert_eq "report prose is not captured" \
  "$(printf '%s' "$EXTRACTED" | grep -c 'a real observation' || true)" "0"

echo ""
echo "Test 2: a report with no sentinel block extracts to nothing"
FIX2="$TEST_DIR/codex_out_2.txt"
{
  echo "**Task:** trivial change"
  echo "**Tier 2 evidence:** none"
  echo "**Blockers:** none"
} > "$FIX2"
assert_eq "no-block report extracts empty" "$(extract_rows "$FIX2")" ""

echo ""
echo "Test 3: valid extracted rows append through the real evidence-append.sh"
KDIR3="$TEST_DIR/kdir3"
seed_kdir "$KDIR3"
append_extracted "$FIX1" "$KDIR3" "wi"
assert_eq "both claim_ids reported appended" "${APPENDED[*]}" "a b"
assert_eq "no rejections" "${#REJECTED[@]}" "0"
assert_eq "two rows landed in task-claims.jsonl" \
  "$(wc -l < "$KDIR3/_work/wi/task-claims.jsonl" | tr -d ' ')" "2"
assert_eq "row a landed" \
  "$(grep -c '"claim_id":"a"' "$KDIR3/_work/wi/task-claims.jsonl" || true)" "1"

echo ""
echo "Test 4: a malformed row is rejected with a diagnostic and does not land;"
echo "        a valid sibling in the same block still lands"
ROW_BAD='{"claim_id":"bad","tier":"task-evidence"}'   # missing most required fields
FIX4="$TEST_DIR/codex_out_4.txt"
{
  echo "**Task:** mixed batch"
  echo "**Changes:** foo.py"
  echo "**Observations:**"
  echo "- claim: \"None\""
  echo "**Tier 2 evidence:** 2 rows below"
  echo "**Blockers:** none"
  echo "===LORE-TIER2-BEGIN==="
  echo "$ROW_A"
  echo "$ROW_BAD"
  echo "===LORE-TIER2-END==="
} > "$FIX4"
KDIR4="$TEST_DIR/kdir4"
seed_kdir "$KDIR4"
append_extracted "$FIX4" "$KDIR4" "wi"
assert_eq "only the valid row is reported appended" "${APPENDED[*]}" "a"
assert_eq "exactly one rejection captured" "${#REJECTED[@]}" "1"
assert_contains "rejection carries the offending row verbatim" "${REJECTED[0]}" '"claim_id":"bad"'
assert_contains "rejection carries a validator diagnostic" "${REJECTED[0]}" "rejected"
assert_eq "only the valid row landed on disk" \
  "$(wc -l < "$KDIR4/_work/wi/task-claims.jsonl" | tr -d ' ')" "1"
assert_eq "the malformed row did not land" \
  "$(grep -c '"claim_id":"bad"' "$KDIR4/_work/wi/task-claims.jsonl" || true)" "0"

echo ""
echo "Test 5: a missing END sentinel degrades to EOF-capture — stray trailing"
echo "        lines are rejected, never silently appended"
FIX5="$TEST_DIR/codex_out_5.txt"
{
  echo "**Task:** truncated block"
  echo "**Tier 2 evidence:** 1 row below"
  echo "**Blockers:** none"
  echo "===LORE-TIER2-BEGIN==="
  echo "$ROW_A"
  echo "some trailing prose codex printed after forgetting the END sentinel"
} > "$FIX5"
KDIR5="$TEST_DIR/kdir5"
seed_kdir "$KDIR5"
append_extracted "$FIX5" "$KDIR5" "wi"
assert_eq "valid row still landed" "${APPENDED[*]}" "a"
assert_eq "trailing prose captured and rejected (not dropped)" "${#REJECTED[@]}" "1"
assert_contains "rejected entry names the stray line" "${REJECTED[0]}" "trailing prose"

echo ""
echo "Test 6: the doc still defines the sentinel tokens this test depends on"
assert_eq "doc defines BEGIN sentinel" \
  "$(grep -cF '===LORE-TIER2-BEGIN===' "$DOC" > /dev/null && echo ok || echo missing)" "ok"
assert_eq "doc defines END sentinel" \
  "$(grep -cF '===LORE-TIER2-END===' "$DOC" > /dev/null && echo ok || echo missing)" "ok"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
