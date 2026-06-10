#!/usr/bin/env bash
# test_settlement_commons_loop.sh — end-to-end acceptance test for the commons
# audit loop: promotion enqueues a commons audit, and verdicts flow back in both
# directions through the single settlement terminus.
#
# User-visible capabilities proven here:
#   1. Promoting a Tier-3 row enqueues a `commons` queue item AND the promotion
#      still succeeds when settlement is unavailable (fail-open enqueue).
#   2. A `verified` verdict advances the promoted entry's persisted confidence
#      from `unaudited` to `high`.
#   3. A `contradicted` verdict mutates the entry text.
#   4. `--advance-confidence` is idempotent (no-op on already-high; no duplicate
#      confidence_advances[] item).
#
# No real LLM judge runs — a fake executor returns the verdict envelope.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"
PROMOTE="$SCRIPTS_DIR/lore-promote.sh"
APPLY="$SCRIPTS_DIR/apply-correction.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"

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

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected to contain: $needle"; echo "    Got: $(printf '%s' "$haystack" | head -3)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected NOT to contain: $needle"; FAIL=$((FAIL + 1))
  fi
}

setup_kdir() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/conventions" "$KDIR/_work/$1"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
  printf '{"slug":"%s"}\n' "$1" > "$KDIR/_work/$1/_meta.json"
}

write_settings_file() {
  cat > "$1" <<'EOF'
{
  "version": 1,
  "tui_launch_framework": "claude-code",
  "harnesses": {"claude-code": {"args": []}},
  "settlement": {
    "enabled": true,
    "max_concurrency": 1,
    "batch_size": 4,
    "batch_recompute_min_interval_seconds": 0,
    "harness_selection": {"mode": "first_eligible", "eligible_frameworks": ["claude-code"]}
  }
}
EOF
}

# Fake executor returning a fixed verdict envelope. The verdict label and the
# correction text are passed via env so embedded quotes don't break the heredoc.
build_fake_executor() {
  local script="$1"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
python3 -c '
import json, os
print(json.dumps({
    "verdict_envelope_version": 1,
    "verdict": os.environ.get("FAKE_VERDICT", "verified"),
    "evidence": os.environ.get("FAKE_EVIDENCE", "test evidence"),
    "correction": (os.environ.get("FAKE_CORRECTION") or None),
    "executor": {"name": "fake-commons", "framework": "test", "exit_code": 0},
    "audit": None,
}))
'
EOF
  chmod +x "$script"
}

# Promote a Tier-3 row with the given claim text; echoes the absolute entry path.
promote_row() {
  local work_item="$1" claim_id="$2" claim_text="$3"
  local row
  row=$(jq -nc --arg cid "$claim_id" --arg claim "$claim_text" --arg wi "$work_item" '{
    claim_id: $cid, tier: "reusable", claim: $claim,
    producer_role: "worker", protocol_slot: "implement-step-5",
    scale: "implementation", why_future_agent_cares: "commons-loop acceptance fixture",
    falsifier: ("If the asserted behavior differs in the cited file for " + $cid),
    related_files: ["scripts/fixture.py"], source_artifact_ids: [$cid],
    work_item: $wi, confidence: "unaudited", captured_at_sha: "fixture-sha"
  }')
  printf '%s' "$row" | LORE_KNOWLEDGE_DIR="$KDIR" bash "$PROMOTE" --work-item "$work_item" --category conventions >/dev/null 2>&1
  # The producer row records the entry_path the audit flows back to.
  python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if line:
            print(json.loads(line)["entry_path"])
            break
' "$KDIR/_work/$work_item/promoted-commons.jsonl"
}

export LORE_KNOWLEDGE_DIR="$KDIR"
SETTINGS="$TEST_DIR/settings.json"
write_settings_file "$SETTINGS"
FAKE_EXEC="$TEST_DIR/fake-exec.sh"
build_fake_executor "$FAKE_EXEC"

echo "=== Settlement Commons Loop Acceptance Tests ==="

# =============================================
# Test 1: promotion enqueues a commons item AND succeeds fail-open
# =============================================
echo ""
echo "Test 1: promotion enqueues a commons queue item (push, fail-open)"
setup_kdir enqueue-test
ENTRY_REL=$(promote_row enqueue-test claim-enq-1 "The dispatcher routes events by priority weight.")
assert_eq "promotion produced an entry path" "$([[ -n "$ENTRY_REL" ]] && echo yes || echo no)" "yes"
assert_eq "producer row written (fail-closed append)" \
  "$([[ -s "$KDIR/_work/enqueue-test/promoted-commons.jsonl" ]] && echo yes || echo no)" "yes"
QUEUE_KIND=$(python3 -c '
import json, os, sys
p = os.path.join(sys.argv[1], "_settlement", "queue.json")
items = json.load(open(p)).get("items", []) if os.path.exists(p) else []
print(next((i["kind"] for i in items if i.get("kind") == "commons"), "none"))
' "$KDIR")
assert_eq "commons queue item enqueued at promotion" "$QUEUE_KIND" "commons"

# Fail-open: a promotion whose enqueue fails still succeeds and leaves the
# durable producer row for scan() to recover. Force the enqueue to fail by
# occupying the _settlement path with a regular file so the queue write cannot
# create its directory — the producer append (under _work/) is unaffected.
echo ""
echo "Test 1b: promotion succeeds when the enqueue step fails (fail-open)"
setup_kdir failopen-test
: > "$KDIR/_settlement"   # a FILE where the queue expects a directory
PROMOTE_EXIT=0
jq -nc '{
  claim_id: "claim-fo-1", tier: "reusable", claim: "Cache invalidates on write.",
  producer_role: "worker", protocol_slot: "s", scale: "implementation",
  why_future_agent_cares: "y", falsifier: "If cache holds stale entries",
  related_files: ["scripts/fixture.py"], source_artifact_ids: ["claim-fo-1"],
  work_item: "failopen-test", confidence: "unaudited", captured_at_sha: "sha"
}' | LORE_KNOWLEDGE_DIR="$KDIR" bash "$PROMOTE" \
     --work-item failopen-test --category conventions >"$TEST_DIR/fo.out" 2>&1 || PROMOTE_EXIT=$?
# The promotion must SUCCEED (exit 0) despite the broken queue path.
assert_eq "fail-open: promotion still exits 0 when enqueue fails" "$PROMOTE_EXIT" "0"
assert_contains "fail-open: warns about the enqueue failure" "$(cat "$TEST_DIR/fo.out")" "settlement enqueue failed"
# The queue write could not happen (no queue.json under the file-blocked path).
assert_eq "fail-open: enqueue genuinely failed (no queue.json)" \
  "$([[ -f "$KDIR/_settlement/queue.json" ]] && echo present || echo absent)" "absent"
# Regardless, the durable producer row + entry exist.
assert_eq "fail-open: producer row durable even if enqueue fails" \
  "$([[ -s "$KDIR/_work/failopen-test/promoted-commons.jsonl" ]] && echo yes || echo no)" "yes"
rm -f "$KDIR/_settlement"

# =============================================
# Test 2: verified verdict advances confidence unaudited -> high
# =============================================
echo ""
echo "Test 2: verified verdict advances the entry's confidence to high"
setup_kdir verified-test
ENTRY_REL=$(promote_row verified-test claim-ver-1 "Sessions expire after thirty idle minutes.")
ENTRY_ABS="$KDIR/$ENTRY_REL"
CONF_BEFORE=$(grep -o 'confidence: [a-z]*' "$ENTRY_ABS" | head -1)
assert_eq "entry starts at confidence: unaudited" "$CONF_BEFORE" "confidence: unaudited"

PROC_ERR="$TEST_DIR/proc-verified.err"
FAKE_VERDICT="verified" FAKE_CORRECTION="" \
  FAKE_EVIDENCE="scripts/fixture.py:5 — thirty-minute idle expiry confirmed" \
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$PROC_ERR" >/dev/null

VER_STDERR=$(cat "$PROC_ERR")
assert_contains "stderr logs commons flowback ADVANCED" "$VER_STDERR" "commons flowback ADVANCED"
CONF_AFTER=$(grep -o 'confidence: [a-z]*' "$ENTRY_ABS" | head -1)
assert_eq "entry advanced to confidence: high" "$CONF_AFTER" "confidence: high"
assert_contains "META carries a confidence_advances[] item" "$(cat "$ENTRY_ABS")" "confidence_advances:"
assert_contains "advance item records from->to" "$(cat "$ENTRY_ABS")" '"to": "high"'

# correction_outcome durable field landed with status advanced (not applied)
RUN_FILE=$(find "$KDIR/_settlement/runs" -name '*.json' | head -1)
OUTCOME_STATUS=$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("correction_outcome") or {}).get("status",""))' "$RUN_FILE")
assert_eq "verified: correction_outcome.status is advanced" "$OUTCOME_STATUS" "advanced"

# =============================================
# Test 3: contradicted verdict mutates the entry body
# =============================================
echo ""
echo "Test 3: contradicted verdict mutates the commons entry on disk"
setup_kdir contra-test
CLAIM_TEXT="The token bucket refills at a constant rate regardless of load."
ENTRY_REL=$(promote_row contra-test claim-con-1 "$CLAIM_TEXT")
ENTRY_ABS="$KDIR/$ENTRY_REL"
# The claim text is the entry insight body, so it is present verbatim.
assert_contains "entry body contains the claim verbatim" "$(cat "$ENTRY_ABS")" "$CLAIM_TEXT"

REPLACEMENT="The token bucket refills proportionally to observed headroom, throttling under sustained load."
PROC_ERR="$TEST_DIR/proc-contra.err"
FAKE_VERDICT="contradicted" FAKE_CORRECTION="$REPLACEMENT" \
  FAKE_EVIDENCE="scripts/fixture.py:9 — refill rate is load-sensitive" \
  LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$PROC_ERR" >/dev/null

CON_STDERR=$(cat "$PROC_ERR")
assert_contains "stderr logs commons flowback APPLIED" "$CON_STDERR" "commons flowback APPLIED"
# Body = entry minus the trailing META block. The original claim must be gone
# from the body (it is preserved only inside the corrections[] META trail).
ENTRY_BODY=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
m = list(re.finditer(r"<!--.*?-->", text, re.DOTALL))
print(text[:m[-1].start()] if m else text)
' "$ENTRY_ABS")
assert_not_contains "body no longer contains original claim" "$ENTRY_BODY" "$CLAIM_TEXT"
assert_contains "body now contains the replacement" "$ENTRY_BODY" "$REPLACEMENT"
assert_contains "META carries a corrections[] trail" "$(cat "$ENTRY_ABS")" "corrections:"
# Evidence-class gate (decide-commons-correction-feed-evolve-secondary-ga):
# a commons-kind applied correction must NOT emit a tier:correction row into
# the /evolve secondary-gate pool — exercises the execute_item kind gate on
# the real dispatch path, not a test-harness mirror.
if [[ -f "$KDIR/_scorecards/rows.jsonl" ]]; then
  COMMONS_CORRECTION_ROWS=$(jq -s 'map(select(.tier == "correction" and .kind == "scored")) | length' "$KDIR/_scorecards/rows.jsonl")
else
  COMMONS_CORRECTION_ROWS=0
fi
assert_eq "commons applied correction emits NO tier:correction scorecard row" "$COMMONS_CORRECTION_ROWS" "0"

# =============================================
# Test 4: --advance-confidence is idempotent
# =============================================
echo ""
echo "Test 4: --advance-confidence is a no-op on an already-high entry"
setup_kdir idem-test
ENTRY_REL=$(promote_row idem-test claim-idem-1 "Workers drain the queue in FIFO order.")
ENTRY_ABS="$KDIR/$ENTRY_REL"
# Fabricate a verified run record so --allow-settlement-verdict authorizes.
mkdir -p "$KDIR/_settlement/runs"
cat > "$KDIR/_settlement/runs/run-idem.json" <<'EOF'
{"run_id":"run-idem","kind":"commons","verdict":{"verdict":"verified","evidence":"x","correction":null}}
EOF
# First advance: unaudited -> high.
LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPLY" --advance-confidence --entry "$ENTRY_ABS" \
  --verdict-id run-idem --verdict-source correctness-gate \
  --evidence "scripts/fixture.py:1 — FIFO drain confirmed" --allow-settlement-verdict >/dev/null 2>&1
assert_eq "first advance sets confidence: high" "$(grep -o 'confidence: [a-z]*' "$ENTRY_ABS" | head -1)" "confidence: high"
COUNT1=$(grep -o '"to": "high"' "$ENTRY_ABS" | wc -l | tr -d ' ')
# Second advance on already-high: must be a no-op exit 0 with no new advance item.
IDEM_OUT=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPLY" --advance-confidence --entry "$ENTRY_ABS" \
  --verdict-id run-idem --verdict-source correctness-gate \
  --evidence "scripts/fixture.py:1 — FIFO drain confirmed" --allow-settlement-verdict 2>&1)
IDEM_EXIT=$?
assert_eq "idempotent re-run exits 0" "$IDEM_EXIT" "0"
assert_contains "idempotent re-run reports no-op" "$IDEM_OUT" "already high"
COUNT2=$(grep -o '"to": "high"' "$ENTRY_ABS" | wc -l | tr -d ' ')
assert_eq "no duplicate confidence_advances[] item" "$COUNT2" "$COUNT1"

# =============================================
# Test 5: producer-row writer rejects malformed rows (the fail-closed boundary)
# =============================================
echo ""
echo "Test 5: promote-commons-append.sh rejects rows that lack the audit payload"
setup_kdir writer-test
echo '# An entry' > "$KDIR/conventions/writer-entry.md"
APPEND="$SCRIPTS_DIR/promote-commons-append.sh"
# Missing falsifier — the audit payload is incomplete.
REJECT_OUT=$(echo '{"claim_id":"w1","claim":"x","scale":"implementation","related_files":["a"]}' \
  | LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPEND" --work-item writer-test \
    --entry-path conventions/writer-entry.md 2>&1 || true)
assert_contains "writer rejects row missing falsifier" "$REJECT_OUT" "falsifier"
# entry_path that does not resolve to an existing entry.
REJECT2=$(echo '{"claim_id":"w2","claim":"x","falsifier":"if not x","scale":"implementation","related_files":["a"]}' \
  | LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPEND" --work-item writer-test \
    --entry-path conventions/does-not-exist.md 2>&1 || true)
assert_contains "writer rejects nonexistent entry_path" "$REJECT2" "does not resolve"
# A valid row is accepted and stamped with entry_path.
echo '{"claim_id":"w3","claim":"x","falsifier":"if not x","scale":"implementation","related_files":["a"]}' \
  | LORE_KNOWLEDGE_DIR="$KDIR" bash "$APPEND" --work-item writer-test \
    --entry-path conventions/writer-entry.md >/dev/null 2>&1
STAMPED=$(python3 -c 'import json; print(json.loads(open("'"$KDIR"'/_work/writer-test/promoted-commons.jsonl").readline())["entry_path"])' 2>/dev/null)
assert_eq "valid row is appended with entry_path stamped" "$STAMPED" "conventions/writer-entry.md"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]]
