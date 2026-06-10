#!/usr/bin/env bash
# test_settlement_auto_correction.sh — end-to-end acceptance test for the
# autonomous settlement → commons correction loop.
#
# This test proves the user-visible capability:
#   contradicted settlement verdict  →  commons entry mutated on disk
#
# without any user invocation between enqueue and mutation. The loop must:
#   1. Settlement processor leases the Tier 2 row.
#   2. Configured executor (fake here) returns a contradicted verdict envelope
#      with a per-claim evidence + correction.
#   3. Processor writes the run record.
#   4. Processor's _apply_correction_from_verdict invokes find-correction-targets
#      to resolve the commons target, then apply-correction with
#      --allow-settlement-verdict to bypass the (vacuous) calibration gate.
#   5. apply-correction does the exact-match body substitution, appends a
#      corrections[] item to the entry's META block, and writes the entry.
#
# Accountability layer: in-entry corrections[] trail + git history. NO supersedes
# archive file is created (--check-escalation is NOT passed from the autonomous
# path — git is the version trail).
#
# Skip semantics: if the claim text is not present verbatim in the resolved
# target entry, apply-correction exits 2 and the loop logs a terminal skip
# ("not_mechanically_applicable" per codex). This test covers the SUCCESS path;
# a SKIP path is asserted by altering the entry body to not contain the claim.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
QUEUE="$SCRIPTS_DIR/settlement-queue.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"

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
    echo "    Got: $(printf '%s' "$haystack" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected NOT to contain: $needle"
    echo "    Got: $(printf '%s' "$haystack" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

setup_kdir_with_indexed_entry() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/conventions"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"

  # The entry body contains the EXACT sentence that the contradicted Tier-2 claim
  # asserts; the fake executor's correction text will replace it. Body-replacement
  # in apply-correction.sh requires a unique exact-match substring.
  cat > "$KDIR/conventions/example-routing-rule.md" <<'EOF'
# Example routing rule

Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest.

This is a fixture used by settlement auto-correction acceptance testing.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: scripts/router.py -->
EOF

  # A second decoy entry — TF-IDF needs N>=2 documents for IDF to be non-zero
  # (single-document corpus produces log(1/1)=0 vectors).
  cat > "$KDIR/conventions/decoy-database-naming.md" <<'EOF'
# Database naming

Tables use snake_case plural nouns. Columns use snake_case singular. Foreign
keys follow the pattern referenced_table_id.

<!-- learned: 2026-01-01 | confidence: high | source: worker | related_files: db/schema.sql -->
EOF

  PYTHONPATH="$SCRIPTS_DIR" python3 - "$KDIR" <<'PYEOF'
import os, sys
from pk_search import Indexer
from pk_concordance import Concordance
kdir = sys.argv[1]
Indexer(kdir).index_all()
Concordance(os.path.join(kdir, ".pk_search.db")).build_vectors()
PYEOF
}

write_settings_file() {
  local path="$1"
  cat > "$path" <<'EOF'
{
  "version": 1,
  "tui_launch_framework": "claude-code",
  "harnesses": {
    "claude-code": {"args": []},
    "opencode": {"args": []},
    "codex": {"args": []}
  },
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

# Fake executor that emits a contradicted verdict envelope. Used in lieu of
# settlement-audit-executor.sh so the test doesn't depend on running a real
# LLM judge. The envelope shape matches what Settlement.parse_verdict_envelope
# expects (verdict_envelope_version: 1). Replacement + evidence are passed in
# via env vars (not heredoc interpolation) so embedded quotes don't break the
# generated python.
build_fake_executor() {
  local script="$1" replacement="$2" evidence="$3"
  cat > "$script" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
python3 -c '
import json, os
print(json.dumps({
    "verdict_envelope_version": 1,
    "verdict": "contradicted",
    "evidence": os.environ.get("FAKE_EVIDENCE", ""),
    "correction": os.environ.get("FAKE_REPLACEMENT", ""),
    "executor": {"name": "fake-contradicted", "framework": "test", "exit_code": 0},
    "audit": None,
}))
'
EOF
  chmod +x "$script"
  export FAKE_REPLACEMENT="$replacement"
  export FAKE_EVIDENCE="$evidence"
}

emit_tier2_row() {
  local claim_id="$1" claim_text="$2"
  jq -nc --arg cid "$claim_id" --arg claim "$claim_text" '{
    claim_id: $cid,
    tier: "task-evidence",
    claim: $claim,
    producer_role: "worker",
    protocol_slot: "implementation",
    task_id: "auto-correction-fixture",
    phase_id: "1",
    scale: "implementation",
    file: "scripts/router.py",
    line_range: "10-12",
    falsifier: "If the routing matcher iterates in a different order than declared in router.py",
    why_this_work_needs_it: "Auto-correction acceptance test fixture proving the autonomous settlement->commons mutation loop",
    captured_at_sha: "fixture-sha",
    change_context: {
      diff_ref: null,
      changed_files: ["scripts/router.py"],
      summary: "Acceptance test fixture for autonomous correction loop"
    }
  }'
}

export LORE_KNOWLEDGE_DIR="$KDIR"

echo "=== Settlement Auto-Correction Acceptance Tests ==="

# =============================================
# Test 1: Successful autonomous correction (the user-visible capability)
# =============================================
echo ""
echo "Test 1: contradicted verdict mutates the commons entry on disk"
setup_kdir_with_indexed_entry

# The Tier-2 claim text must EXACTLY match the substring in the entry body.
ORIGINAL_TEXT="Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest."
REPLACEMENT_TEXT="Routes are matched in dependency-graph topological order; tied weights resolve via declaration order as a stable secondary sort."

SETTINGS="$TEST_DIR/settings.json"
write_settings_file "$SETTINGS"

FAKE_EXEC="$TEST_DIR/fake-contradicted-exec.sh"
build_fake_executor "$FAKE_EXEC" "$REPLACEMENT_TEXT" "scripts/router.py:10 — \"matcher.dispatch(events, by_priority=True)\""

# Build a Tier-2 row whose claim is the exact original sentence.
ROW=$(emit_tier2_row "claim-auto-correct-1" "$ORIGINAL_TEXT")
printf '%s' "$ROW" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  bash "$QUEUE" enqueue --work-item auto-correction-test --kdir "$KDIR" --json >/dev/null

# Drive the loop.
PROC_OUT=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr.txt")

# Verdict landed in run record
RUN_FILES=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
assert_eq "run record file exists" "$([[ -f "$RUN_FILES" ]] && echo yes || echo no)" "yes"

RUN_VERDICT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("verdict",{}).get("verdict",""))' "$RUN_FILES")
assert_eq "run record verdict is contradicted" "$RUN_VERDICT" "contradicted"

# Commons entry was mutated on disk (the user-visible outcome).
# Body = everything above the trailing META HTML comment block. The original
# sentence MUST be gone from the body but is intentionally preserved inside
# the corrections[] item in META as the accountability trail.
ENTRY_AFTER=$(cat "$KDIR/conventions/example-routing-rule.md")
ENTRY_BODY=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
# Strip the last <!-- ... --> comment block (the META block)
m = list(re.finditer(r"<!--.*?-->", text, re.DOTALL))
if m:
    text = text[:m[-1].start()]
print(text)
' "$KDIR/conventions/example-routing-rule.md")
assert_not_contains "body no longer contains original sentence" "$ENTRY_BODY" "$ORIGINAL_TEXT"
assert_contains "body now contains replacement sentence" "$ENTRY_BODY" "$REPLACEMENT_TEXT"

# Corrections trail is visible in the entry's META block
assert_contains "META block has corrections[] item" "$ENTRY_AFTER" "corrections:"
assert_contains "corrections item names verdict-source" "$ENTRY_AFTER" "correctness-gate"
assert_contains "META preserves original as superseded_text" "$ENTRY_AFTER" "superseded_text"

# No L3 supersedes archive (we explicitly do NOT pass --check-escalation)
SUPERSEDED_FILES=$(find "$KDIR/conventions" -name 'example-routing-rule-superseded-*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no supersedes archive created" "$SUPERSEDED_FILES" "0"

# Stderr confirms the autonomous path fired
PROC_STDERR=$(cat "$TEST_DIR/proc-stderr.txt")
assert_contains "stderr logs auto-correction APPLIED" "$PROC_STDERR" "auto-correction APPLIED"

# correction_outcome durable field landed on the run record (applied path)
RUN_OUTCOME_STATUS=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("status",""))
' "$RUN_FILES")
assert_eq "applied: correction_outcome.status" "$RUN_OUTCOME_STATUS" "applied"
RUN_OUTCOME_REASON=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("reason",""))
' "$RUN_FILES")
assert_eq "applied: correction_outcome.reason" "$RUN_OUTCOME_REASON" "applied"
RUN_OUTCOME_TARGET=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("target_entry",""))
' "$RUN_FILES")
assert_contains "applied: correction_outcome.target_entry names mutated entry" "$RUN_OUTCOME_TARGET" "conventions/example-routing-rule.md"

# =============================================
# Test 2: Skip path — claim text not present in entry body
# =============================================
echo ""
echo "Test 2: claim text absent from entry → terminal skip, no mutation"
setup_kdir_with_indexed_entry

# Read the original entry content for later comparison
ENTRY_BEFORE=$(cat "$KDIR/conventions/example-routing-rule.md")

# Claim is the original substring; we point the find-correction-targets at the
# entry that has the related_files match, but mutate the entry body so the
# substring is no longer present — then enqueue.
sed -i.bak 's/Routes are matched in declaration order;/Routes resolve dependency-graph order;/' "$KDIR/conventions/example-routing-rule.md"
rm -f "$KDIR/conventions/example-routing-rule.md.bak"
# Rebuild index so concordance reflects the new entry body
PYTHONPATH="$SCRIPTS_DIR" python3 - "$KDIR" <<'PYEOF'
import os, sys
from pk_search import Indexer
from pk_concordance import Concordance
kdir = sys.argv[1]
Indexer(kdir).index_all()
Concordance(os.path.join(kdir, ".pk_search.db")).build_vectors()
PYEOF

SETTINGS2="$TEST_DIR/settings2.json"
write_settings_file "$SETTINGS2"
KDIR2_SUBSTR=$(cat "$KDIR/conventions/example-routing-rule.md" | head -3 | tail -1)

# Enqueue a claim whose text is NOT present in the (mutated) entry body
SKIP_CLAIM="Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest."
ROW2=$(emit_tier2_row "claim-skip-1" "$SKIP_CLAIM")
printf '%s' "$ROW2" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" \
  bash "$QUEUE" enqueue --work-item auto-correction-test --kdir "$KDIR" --json >/dev/null

PROC_OUT2=$(LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS2" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr2.txt")

ENTRY_AFTER2=$(cat "$KDIR/conventions/example-routing-rule.md")
assert_eq "entry unchanged when claim text absent" "$ENTRY_AFTER2" "$(cat "$KDIR/conventions/example-routing-rule.md")"
# Verify the entry doesn't have a corrections[] block (skip didn't mutate META either)
PROC_STDERR2=$(cat "$TEST_DIR/proc-stderr2.txt")
assert_contains "stderr logs not_mechanically_applicable skip" "$PROC_STDERR2" "not_mechanically_applicable"

# correction_outcome durable field landed on the run record (skip path).
# setup_kdir_with_indexed_entry rm -rf $KDIR at the top of Test 2 so the runs dir
# is fresh — pick the only run file.
RUN_FILES2=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
RUN_OUTCOME2_STATUS=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("status",""))
' "$RUN_FILES2")
assert_eq "skipped: correction_outcome.status" "$RUN_OUTCOME2_STATUS" "skipped"
RUN_OUTCOME2_REASON=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("reason",""))
' "$RUN_FILES2")
assert_eq "skipped: correction_outcome.reason is not_mechanically_applicable" "$RUN_OUTCOME2_REASON" "not_mechanically_applicable"

# =============================================
# Test 3: Non-contradicted verdict → no correction attempted
# =============================================
echo ""
echo "Test 3: verified verdict does NOT trigger apply-correction"
setup_kdir_with_indexed_entry

VERIFIED_EXEC="$TEST_DIR/verified-exec.sh"
cat > "$VERIFIED_EXEC" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
python3 -c '
import json
print(json.dumps({
    "verdict_envelope_version": 1,
    "verdict": "verified",
    "evidence": "claim matches the current implementation",
    "correction": None,
    "executor": {"name": "fake-verified", "framework": "test", "exit_code": 0},
    "audit": None
}))
'
EOF
chmod +x "$VERIFIED_EXEC"

SETTINGS3="$TEST_DIR/settings3.json"
write_settings_file "$SETTINGS3"

VERIFIED_CLAIM="Routes are matched in declaration order; the first regex hit wins and shortcircuits the rest."
ROW3=$(emit_tier2_row "claim-verified-1" "$VERIFIED_CLAIM")
ENTRY_BEFORE3=$(cat "$KDIR/conventions/example-routing-rule.md")
printf '%s' "$ROW3" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" \
  bash "$QUEUE" enqueue --work-item auto-correction-test --kdir "$KDIR" --json >/dev/null
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS3" \
  LORE_SETTLEMENT_EXECUTOR="$VERIFIED_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr3.txt" >/dev/null
ENTRY_AFTER3=$(cat "$KDIR/conventions/example-routing-rule.md")
assert_eq "verified verdict does not mutate entry" "$ENTRY_AFTER3" "$ENTRY_BEFORE3"
PROC_STDERR3=$(cat "$TEST_DIR/proc-stderr3.txt")
assert_not_contains "no auto-correction log for verified" "$PROC_STDERR3" "auto-correction APPLIED"

# correction_outcome field MUST be absent on a verified (non-contradicted) run record.
# setup_kdir_with_indexed_entry rm -rf $KDIR at the top of Test 3 so the runs dir is fresh.
RUN_FILES3=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
RUN_OUTCOME3_PRESENT=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print("yes" if "correction_outcome" in d else "no")
' "$RUN_FILES3")
assert_eq "verified: correction_outcome field is absent" "$RUN_OUTCOME3_PRESENT" "no"

# =============================================
# Test 4: LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION kill-switch
# =============================================
echo ""
echo "Test 4: kill-switch env var disables auto-correction"
setup_kdir_with_indexed_entry

ROW4=$(emit_tier2_row "claim-killswitch-1" "$ORIGINAL_TEXT")
ENTRY_BEFORE4=$(cat "$KDIR/conventions/example-routing-rule.md")
printf '%s' "$ROW4" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  bash "$QUEUE" enqueue --work-item auto-correction-test --kdir "$KDIR" --json >/dev/null
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  LORE_SETTLEMENT_DISABLE_AUTO_CORRECTION=1 \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr4.txt" >/dev/null
ENTRY_AFTER4=$(cat "$KDIR/conventions/example-routing-rule.md")
assert_eq "kill-switch suppresses mutation" "$ENTRY_AFTER4" "$ENTRY_BEFORE4"

# correction_outcome captures the kill-switch path on the run record.
RUN_FILES4=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
RUN_OUTCOME4_STATUS=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("status",""))
' "$RUN_FILES4")
assert_eq "kill-switch: correction_outcome.status" "$RUN_OUTCOME4_STATUS" "skipped"
RUN_OUTCOME4_REASON=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("reason",""))
' "$RUN_FILES4")
assert_eq "kill-switch: correction_outcome.reason is auto_correction_disabled" "$RUN_OUTCOME4_REASON" "auto_correction_disabled"

# =============================================
# Test 5: Paraphrase claim (right topic, different wording) → terminal skip
# =============================================
# Regression for the secondary-gate audit: every historical
# not_mechanically_applicable rejection was a claim that paraphrased a fact the
# entry already states in different words — not a claim about a missing topic.
# apply-correction's match is exact-substring (claim text must appear verbatim
# in the entry body), so a paraphrase correctly rejects. This pins that the
# rejection is by-design conservatism, not a normalization gap.
echo ""
echo "Test 5: paraphrase claim that restates an entry fact in other words → skip"
setup_kdir_with_indexed_entry

# The entry body says "the first regex hit wins and shortcircuits the rest."
# This claim asserts the SAME fact in different words — no verbatim overlap.
PARAPHRASE_CLAIM="Routing dispatch resolves to whichever pattern matches earliest and ignores all later patterns."
ROW5=$(emit_tier2_row "claim-paraphrase-1" "$PARAPHRASE_CLAIM")
ENTRY_BEFORE5=$(cat "$KDIR/conventions/example-routing-rule.md")
printf '%s' "$ROW5" | LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  bash "$QUEUE" enqueue --work-item auto-correction-test --kdir "$KDIR" --json >/dev/null
LORE_SETTLEMENT_SETTINGS_FILE="$SETTINGS" \
  LORE_SETTLEMENT_EXECUTOR="$FAKE_EXEC" \
  bash "$QUEUE" process --kdir "$KDIR" --once --json 2>"$TEST_DIR/proc-stderr5.txt" >/dev/null
ENTRY_AFTER5=$(cat "$KDIR/conventions/example-routing-rule.md")
assert_eq "paraphrase claim does not mutate entry" "$ENTRY_AFTER5" "$ENTRY_BEFORE5"
PROC_STDERR5=$(cat "$TEST_DIR/proc-stderr5.txt")
assert_contains "stderr logs not_mechanically_applicable for paraphrase" "$PROC_STDERR5" "not_mechanically_applicable"

RUN_FILES5=$(find "$KDIR/_settlement/runs" -name '*.json' 2>/dev/null | head -1)
RUN_OUTCOME5_REASON=$(python3 -c '
import json,sys
d = json.load(open(sys.argv[1]))
print((d.get("correction_outcome") or {}).get("reason",""))
' "$RUN_FILES5")
assert_eq "paraphrase: correction_outcome.reason is not_mechanically_applicable" "$RUN_OUTCOME5_REASON" "not_mechanically_applicable"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]] || exit 1
