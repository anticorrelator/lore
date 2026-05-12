#!/usr/bin/env bash
# test_correction_candidate_emit.sh — Tests for correction-candidate-emit.sh,
# the settlement post-verdict hook (D2 emit script).
#
# Covers:
#   - Hook payload validation (missing keys → exit 1)
#   - Dispatch on non-empty targets → one correction-candidate row per target
#   - Dispatch on zero-target + index_state=ready → filtered-claim row
#     with stage=post-verdict, reason=no-discoverable-target, mode=report-only
#   - Dispatch on index_state=missing → filtered-claim row with
#     reason=concordance-stale, stage=post-verdict
#   - Sub-script failure surfaces as non-zero exit (fail-loud contract)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
EMIT_SCRIPT="$SCRIPT_DIR/correction-candidate-emit.sh"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
SLUG="emit-test"
WORK_DIR="$KNOWLEDGE_DIR/_work/$SLUG"

PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $expected"
    echo "    got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

setup_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$WORK_DIR"
  printf '{}\n' > "$KNOWLEDGE_DIR/_manifest.json"
}

# --- Fake find-correction-targets.sh stub ---
# The emit script shells out to find-correction-targets.sh. We stand up a
# fake on PATH that produces canned --json output keyed on env vars.
STUB_DIR="$TEST_DIR/stub-scripts"
mkdir -p "$STUB_DIR"
# We override by editing the emit script's resolved path — copy emit to a
# location where the sibling 'find-correction-targets.sh' is our stub.
WORK_SCRIPTS="$TEST_DIR/work-scripts"
mkdir -p "$WORK_SCRIPTS"

cp "$SCRIPT_DIR/lib.sh" "$WORK_SCRIPTS/lib.sh"
cp "$SCRIPT_DIR/config.sh" "$WORK_SCRIPTS/config.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/resolve-repo.sh" "$WORK_SCRIPTS/resolve-repo.sh" 2>/dev/null || true
cp "$SCRIPT_DIR/correction-candidate-emit.sh" "$WORK_SCRIPTS/correction-candidate-emit.sh"
cp "$SCRIPT_DIR/correction-candidate-append.sh" "$WORK_SCRIPTS/correction-candidate-append.sh"
cp "$SCRIPT_DIR/filtered-claim-append.sh" "$WORK_SCRIPTS/filtered-claim-append.sh"
chmod +x "$WORK_SCRIPTS"/*.sh

# Fake find-correction-targets.sh — reads $EMIT_TEST_RESPONSE_FILE for JSON.
cat > "$WORK_SCRIPTS/find-correction-targets.sh" <<'STUB'
#!/usr/bin/env bash
# Stub: emit canned JSON loaded from $EMIT_TEST_RESPONSE_FILE.
if [[ -n "${EMIT_TEST_RESPONSE_FILE:-}" && -f "$EMIT_TEST_RESPONSE_FILE" ]]; then
  cat "$EMIT_TEST_RESPONSE_FILE"
  exit 0
fi
printf '{"targets":[],"index_state":"missing","resolver_version":"stub-v1"}\n'
STUB
chmod +x "$WORK_SCRIPTS/find-correction-targets.sh"

EMIT="$WORK_SCRIPTS/correction-candidate-emit.sh"

# --- Helpers to build payloads ---
build_payload() {
  local run_id="$1" verdict="$2" claim_id="$3" evidence="${4:-contradiction evidence}" correction="${5:-replacement text for the entry}"
  jq -nc \
    --arg run_id "$run_id" \
    --arg verdict "$verdict" \
    --arg cid "$claim_id" \
    --arg slug "$SLUG" \
    --arg ev "$evidence" \
    --arg cor "$correction" \
    '{
      run: {
        run_id: $run_id,
        work_item: $slug,
        claim_id: $cid,
        verdict: {verdict: $verdict, evidence: $ev, correction: $cor}
      },
      item: {
        id: "task-claim-stub",
        work_item: $slug,
        claim_id: $cid
      },
      task_claim: {
        claim_id: $cid,
        work_item: $slug,
        claim: "rehydrated tier-2 claim text long enough not to be templated",
        scale: "implementation",
        producer_role: "worker",
        file: "/abs/path/to/scripts/settlement-processor.py",
        line_range: "100-120",
        falsifier: "Run the settlement queue tests and inspect durable state",
        change_context: {diff_ref:"abc123",changed_files:["/abs/path/to/scripts/settlement-processor.py"],summary:"emit test fixture"}
      }
    }'
}

echo "=== correction-candidate-emit.sh tests ==="

echo ""
echo "Test 1: empty stdin → exit 1"
setup_store
PAYLOAD=""
OUT=$(printf '%s' "$PAYLOAD" | bash "$EMIT" 2>&1) && EXIT=0 || EXIT=$?
assert_eq "empty stdin exits 1" "$EXIT" "1"
assert_contains "empty stdin error names empty payload" "$OUT" "empty stdin"

echo ""
echo "Test 2: malformed payload (missing keys) → exit 1"
setup_store
OUT=$(printf '{"foo": 1}' | bash "$EMIT" 2>&1) && EXIT=0 || EXIT=$?
assert_eq "malformed payload exits 1" "$EXIT" "1"
assert_contains "malformed payload error names required keys" "$OUT" "must be a JSON object with keys"

echo ""
echo "Test 3: non-empty targets → one correction-candidate row per target"
setup_store
RESP="$TEST_DIR/resp-targets.json"
cat > "$RESP" <<'JSON'
{
  "targets": [
    {"path": "/abs/path/entry-one.md", "rank": 1, "overlap": true, "sim": 0.85},
    {"path": "/abs/path/entry-two.md", "rank": 2, "overlap": false, "sim": 0.62}
  ],
  "index_state": "ready",
  "resolver_version": "stub-sha"
}
JSON
PAYLOAD=$(build_payload "run-target-1" "contradicted" "claim-target-1")
EXIT=0
printf '%s' "$PAYLOAD" | LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" EMIT_TEST_RESPONSE_FILE="$RESP" bash "$EMIT" 2>&1 || EXIT=$?
assert_eq "emit succeeds on non-empty targets" "$EXIT" "0"
CC_FILE="$WORK_DIR/correction-candidates.jsonl"
if [[ -f "$CC_FILE" ]]; then
  COUNT=$(wc -l < "$CC_FILE" | tr -d ' ')
  assert_eq "two correction-candidate rows appended (one per target)" "$COUNT" "2"
  assert_eq "first target path captured" "$(jq -r 'select(.target_rank==1) | .target_entry_path' "$CC_FILE" | head -1)" "/abs/path/entry-one.md"
  assert_eq "first target overlap=true" "$(jq -r 'select(.target_rank==1) | .target_overlap' "$CC_FILE" | head -1)" "true"
  assert_eq "second target overlap=false" "$(jq -r 'select(.target_rank==2) | .target_overlap' "$CC_FILE" | head -1)" "false"
  assert_eq "verdict literal is contradicted" "$(jq -r '.verdict' "$CC_FILE" | head -1)" "contradicted"
  assert_eq "candidate_for_verdict_id matches run_id" "$(jq -r '.candidate_for_verdict_id' "$CC_FILE" | head -1)" "run-target-1"
else
  echo "  FAIL: correction-candidates.jsonl not created"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Test 4: zero targets + index_state=ready → filtered-claim row stage=post-verdict reason=no-discoverable-target"
setup_store
RESP="$TEST_DIR/resp-empty.json"
cat > "$RESP" <<'JSON'
{"targets": [], "index_state": "ready", "resolver_version": "stub-sha"}
JSON
PAYLOAD=$(build_payload "run-empty-1" "contradicted" "claim-empty-1")
EXIT=0
printf '%s' "$PAYLOAD" | LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" EMIT_TEST_RESPONSE_FILE="$RESP" bash "$EMIT" 2>&1 || EXIT=$?
assert_eq "emit succeeds on zero-target ready" "$EXIT" "0"
FC_FILE="$WORK_DIR/filtered-claims.jsonl"
if [[ -f "$FC_FILE" ]]; then
  ROW=$(grep "claim-empty-1" "$FC_FILE" | head -1)
  assert_eq "filtered-claim stage=post-verdict" "$(echo "$ROW" | jq -r '.stage')" "post-verdict"
  assert_eq "filtered-claim reason=no-discoverable-target" "$(echo "$ROW" | jq -r '.reason')" "no-discoverable-target"
  assert_eq "filtered-claim mode=report-only" "$(echo "$ROW" | jq -r '.mode')" "report-only"
  assert_eq "filtered-claim settlement_run_id=run-empty-1" "$(echo "$ROW" | jq -r '.settlement_run_id')" "run-empty-1"
  # Sole-writer enforces mode=report-only ⇒ enqueued_anyway=true (the row
  # produced a verdict, so it WAS enqueued).
  assert_eq "filtered-claim enqueued_anyway=true" "$(echo "$ROW" | jq -r '.enqueued_anyway')" "true"
else
  echo "  FAIL: filtered-claims.jsonl not created on zero-target path"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Test 5: index_state=missing → filtered-claim row reason=concordance-stale"
setup_store
RESP="$TEST_DIR/resp-missing.json"
cat > "$RESP" <<'JSON'
{"targets": [], "index_state": "missing", "resolver_version": "stub-sha"}
JSON
PAYLOAD=$(build_payload "run-missing-1" "contradicted" "claim-missing-1")
EXIT=0
printf '%s' "$PAYLOAD" | LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR" EMIT_TEST_RESPONSE_FILE="$RESP" bash "$EMIT" 2>&1 || EXIT=$?
assert_eq "emit succeeds on index_state=missing" "$EXIT" "0"
if [[ -f "$WORK_DIR/filtered-claims.jsonl" ]]; then
  ROW=$(grep "claim-missing-1" "$WORK_DIR/filtered-claims.jsonl" | head -1)
  assert_eq "missing-index filtered-claim reason=concordance-stale" "$(echo "$ROW" | jq -r '.reason')" "concordance-stale"
  assert_eq "missing-index filtered-claim stage=post-verdict" "$(echo "$ROW" | jq -r '.stage')" "post-verdict"
else
  echo "  FAIL: filtered-claims.jsonl not created on missing-index path"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Test 6: missing required payload key (.task_claim) → exit 1"
setup_store
BAD=$(jq -nc '{run: {run_id: "x"}, item: {work_item: "wi"}}')
EXIT=0
OUT=$(printf '%s' "$BAD" | bash "$EMIT" 2>&1) || EXIT=$?
assert_eq "missing task_claim exits 1" "$EXIT" "1"

echo ""
echo "Test 7: missing claim text in task_claim → exit 1"
setup_store
BAD=$(jq -nc --arg slug "$SLUG" '{
  run: {run_id: "x", work_item: $slug, claim_id: "c", verdict: {evidence: "e", correction: "c"}},
  item: {work_item: $slug, claim_id: "c"},
  task_claim: {claim_id: "c", scale: "implementation", producer_role: "worker", file: "/a", line_range: "1-1", change_context: {}}
}')
EXIT=0
OUT=$(printf '%s' "$BAD" | bash "$EMIT" 2>&1) || EXIT=$?
assert_eq "missing claim text exits 1" "$EXIT" "1"
assert_contains "missing-claim-text error names field" "$OUT" "missing claim text"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
