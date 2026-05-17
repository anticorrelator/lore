#!/usr/bin/env bash
# test_evidence_update.sh — Round-trip tests for evidence-update.sh, the
# sibling sole-writer for the *update* operation on task-claims.jsonl.
#
# Covers the verification objectives for Phase 2:
#   1. Round-trip: a snippet+hash mutation lands and validates.
#   2. Atomic rewrite: only the target line changes; sibling lines are untouched.
#   3. producer_role is preserved across mutation (origin-preserving migration).
#   4. D2 exclusive-terminal-state enforcement: post-mutation rows in mixed
#      state (legacy flag + snippet/hash present) are rejected; file untouched.
#   5. Writer-path divergence: evidence-update.sh ACCEPTS the legacy marker
#      (snippet/hash cleared); evidence-append.sh REJECTS the same row at its
#      writer-path gate.
#   6. Idempotency: re-running an already-applied mutation is a no-op.
#   7. Missing claim_id exits non-zero with a diagnostic.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
UPDATE="$SCRIPTS_DIR/evidence-update.sh"
APPEND="$SCRIPTS_DIR/evidence-append.sh"
VALIDATE="$SCRIPTS_DIR/validate-tier2.sh"
NORMALIZE_PY="$SCRIPTS_DIR/snippet_normalize.py"

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

hash_of() {
  printf '%s' "$1" | python3 "$NORMALIZE_PY" --hash
}

build_row() {
  # Build a Tier 2 row, overrides via key=JSON-value args. Pass key=__DELETE__ to drop.
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

# Build a fresh KDIR with a seed task-claims.jsonl containing the given rows.
seed_kdir() {
  local kdir="$1"
  shift
  rm -rf "$kdir"
  mkdir -p "$kdir/_work/wi"
  : > "$kdir/_work/wi/task-claims.jsonl"
  for row in "$@"; do
    printf '%s\n' "$row" | jq -c '.' >> "$kdir/_work/wi/task-claims.jsonl"
  done
}

GOOD_SNIPPET="print('hello')"
GOOD_HASH=$(hash_of "$GOOD_SNIPPET")

ALT_SNIPPET="def foo(): return 1"
ALT_HASH=$(hash_of "$ALT_SNIPPET")

echo "Setup sanity:"
assert_eq "GOOD_HASH is 64-char lowercase hex" \
  "$(printf '%s' "$GOOD_HASH" | grep -cE '^[0-9a-f]{64}$')" "1"

echo ""
echo "Test 1: Round-trip snippet+hash mutation lands and validates"
ROW_LEGACY=$(build_row \
  "claim_id=\"c1\"" \
  "exact_snippet=__DELETE__" \
  "normalized_snippet_hash=__DELETE__" \
  "provenance=\"legacy-no-snippet\"")
KDIR="$TEST_DIR/kdir1"
seed_kdir "$KDIR" "$ROW_LEGACY"
# Strip the legacy marker AND set snippet+hash (state-2 → state-1 transition).
MERGE=$(jq -n --arg s "$GOOD_SNIPPET" --arg h "$GOOD_HASH" '{exact_snippet:$s, normalized_snippet_hash:$h, provenance:null}')
printf '%s' "$MERGE" | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id c1 --from-stdin --quiet
NEW_SNIPPET=$(jq -r '.exact_snippet' "$KDIR/_work/wi/task-claims.jsonl")
NEW_HASH=$(jq -r '.normalized_snippet_hash' "$KDIR/_work/wi/task-claims.jsonl")
NEW_PROV=$(jq -r '.provenance' "$KDIR/_work/wi/task-claims.jsonl")
assert_eq "snippet was written" "$NEW_SNIPPET" "$GOOD_SNIPPET"
assert_eq "hash was written" "$NEW_HASH" "$GOOD_HASH"
assert_eq "legacy marker was cleared (set to null)" "$NEW_PROV" "null"
# Validate the resulting row.
assert_eq "post-mutation row passes validate-tier2.sh" \
  "$(jq -c '.' "$KDIR/_work/wi/task-claims.jsonl" | bash "$VALIDATE" >/dev/null 2>&1 && echo ok || echo fail)" "ok"

echo ""
echo "Test 2: Atomic rewrite — only the target line changes; siblings untouched"
ROW_A=$(build_row "claim_id=\"a\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
ROW_B_LEGACY=$(build_row "claim_id=\"b\"" "exact_snippet=__DELETE__" "normalized_snippet_hash=__DELETE__" "provenance=\"legacy-no-snippet\"")
ROW_C=$(build_row "claim_id=\"c\"" "exact_snippet=\"$ALT_SNIPPET\"" "normalized_snippet_hash=\"$ALT_HASH\"")
KDIR="$TEST_DIR/kdir2"
seed_kdir "$KDIR" "$ROW_A" "$ROW_B_LEGACY" "$ROW_C"
ORIG_A=$(sed -n '1p' "$KDIR/_work/wi/task-claims.jsonl")
ORIG_C=$(sed -n '3p' "$KDIR/_work/wi/task-claims.jsonl")
# Mutate the middle row b: state-2 → state-1.
MERGE=$(jq -n --arg s "$GOOD_SNIPPET" --arg h "$GOOD_HASH" '{exact_snippet:$s, normalized_snippet_hash:$h, provenance:null}')
printf '%s' "$MERGE" | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id b --from-stdin --quiet
NEW_A=$(sed -n '1p' "$KDIR/_work/wi/task-claims.jsonl")
NEW_C=$(sed -n '3p' "$KDIR/_work/wi/task-claims.jsonl")
assert_eq "line 1 (a) unchanged" "$NEW_A" "$ORIG_A"
assert_eq "line 3 (c) unchanged" "$NEW_C" "$ORIG_C"
assert_eq "line 2 (b) snippet was written" "$(sed -n '2p' "$KDIR/_work/wi/task-claims.jsonl" | jq -r '.exact_snippet')" "$GOOD_SNIPPET"
assert_eq "file still has 3 lines" "$(wc -l < "$KDIR/_work/wi/task-claims.jsonl" | tr -d ' ')" "3"

echo ""
echo "Test 3: producer_role is preserved across mutation"
ROW_RESEARCHER=$(build_row "claim_id=\"r1\"" "producer_role=\"researcher\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
KDIR="$TEST_DIR/kdir3"
seed_kdir "$KDIR" "$ROW_RESEARCHER"
# Attempt to mutate producer_role; writer must silently preserve original.
MERGE=$(jq -n --arg s "$ALT_SNIPPET" --arg h "$ALT_HASH" '{producer_role:"advisor", exact_snippet:$s, normalized_snippet_hash:$h}')
printf '%s' "$MERGE" | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id r1 --from-stdin --quiet
assert_eq "producer_role preserved (researcher, not advisor)" \
  "$(jq -r '.producer_role' "$KDIR/_work/wi/task-claims.jsonl")" "researcher"
assert_eq "other fields still mutated (snippet swapped)" \
  "$(jq -r '.exact_snippet' "$KDIR/_work/wi/task-claims.jsonl")" "$ALT_SNIPPET"

echo ""
echo "Test 4: D2 exclusive-terminal-state — mixed-state mutation is rejected, file untouched"
ROW_FAST=$(build_row "claim_id=\"f1\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
KDIR="$TEST_DIR/kdir4"
seed_kdir "$KDIR" "$ROW_FAST"
ORIG=$(cat "$KDIR/_work/wi/task-claims.jsonl")
# Try to set legacy marker while leaving snippet/hash in place — must reject.
RC=0
echo '{"provenance":"legacy-no-snippet"}' \
  | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id f1 --from-stdin --quiet 2>/dev/null \
  || RC=$?
assert_eq "mixed-state mutation exits non-zero" "$RC" "1"
AFTER=$(cat "$KDIR/_work/wi/task-claims.jsonl")
assert_eq "file is unchanged after rejection" "$AFTER" "$ORIG"

echo ""
echo "Test 5: Writer-path divergence — update ACCEPTS legacy, append REJECTS"
# 5a: update accepts a row that ends up in the slow-path legacy terminal state.
ROW_FAST=$(build_row "claim_id=\"d1\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
KDIR="$TEST_DIR/kdir5"
seed_kdir "$KDIR" "$ROW_FAST"
echo '{"provenance":"legacy-no-snippet","exact_snippet":null,"normalized_snippet_hash":null}' \
  | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id d1 --from-stdin --quiet
assert_eq "update writer wrote legacy state" \
  "$(jq -r '.provenance' "$KDIR/_work/wi/task-claims.jsonl")" "legacy-no-snippet"
# 5b: append rejects the same row at its writer-path gate.
LEGACY_ROW=$(build_row "claim_id=\"d2\"" "exact_snippet=__DELETE__" "normalized_snippet_hash=__DELETE__" "provenance=\"legacy-no-snippet\"")
RC=0
printf '%s' "$LEGACY_ROW" | bash "$APPEND" --kdir "$KDIR" --work-item wi >/dev/null 2>&1 || RC=$?
assert_eq "append writer rejected the legacy row" "$RC" "1"

echo ""
echo "Test 6: Idempotency — re-applying the same mutation is a no-op"
ROW_FAST=$(build_row "claim_id=\"i1\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
KDIR="$TEST_DIR/kdir6"
seed_kdir "$KDIR" "$ROW_FAST"
# First mutation: change the falsifier.
echo '{"falsifier":"new-falsifier"}' \
  | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id i1 --from-stdin --quiet
FIRST=$(cat "$KDIR/_work/wi/task-claims.jsonl")
# Re-apply identical mutation.
OUT=$(echo '{"falsifier":"new-falsifier"}' \
  | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id i1 --from-stdin 2>&1)
SECOND=$(cat "$KDIR/_work/wi/task-claims.jsonl")
assert_eq "file is byte-identical after no-op" "$SECOND" "$FIRST"
assert_eq "no-op log line printed" \
  "$(printf '%s' "$OUT" | grep -c "no-op")" "1"

echo ""
echo "Test 7: Missing claim_id exits non-zero with a diagnostic"
ROW=$(build_row "claim_id=\"only\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
KDIR="$TEST_DIR/kdir7"
seed_kdir "$KDIR" "$ROW"
set +e
ERR=$(echo '{"falsifier":"x"}' \
  | bash "$UPDATE" --kdir "$KDIR" --work-item wi --claim-id missing --from-stdin 2>&1)
RC=$?
set -e
assert_eq "missing claim exits non-zero" "$RC" "1"
DIAG_MATCHES=$(printf '%s' "$ERR" | grep -cE 'missing|not found' || true)
if [[ "$DIAG_MATCHES" -gt 0 ]]; then
  assert_eq "diagnostic mentions the missing id" "found" "found"
else
  assert_eq "diagnostic mentions the missing id" "not-found" "found"
fi

echo ""
echo "Test 8: --task-claims-path mode bypasses --work-item resolution"
ROW=$(build_row "claim_id=\"p1\"" "exact_snippet=\"$GOOD_SNIPPET\"" "normalized_snippet_hash=\"$GOOD_HASH\"")
JSONL="$TEST_DIR/standalone-claims.jsonl"
printf '%s\n' "$ROW" | jq -c '.' > "$JSONL"
MERGE=$(jq -n --arg s "$ALT_SNIPPET" --arg h "$ALT_HASH" '{exact_snippet:$s, normalized_snippet_hash:$h}')
printf '%s' "$MERGE" | bash "$UPDATE" --task-claims-path "$JSONL" --claim-id p1 --from-stdin --quiet
assert_eq "--task-claims-path mutation lands" \
  "$(jq -r '.exact_snippet' "$JSONL")" "$ALT_SNIPPET"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
