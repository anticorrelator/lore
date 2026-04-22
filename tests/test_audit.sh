#!/usr/bin/env bash
# test_audit.sh — Tests for scripts/audit-artifact.sh correctness-gate wiring
#
# Covers:
#   - End-to-end: lens-findings.json + --gate-output-file produces verdicts
#     file + 3 scorecard rows with correct metric values
#   - Contract validation: rejects bad shape (wrong judge, missing fields,
#     missing correction on contradicted, correction-on-verified)
#   - --skip-scorecard persists verdicts but does not append rows
#   - User-supplied --gate-output-file is preserved (not deleted by trap)
#   - Multi-run on same artifact appends to verdicts file and scorecard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
AUDIT="$SCRIPT_DIR/audit-artifact.sh"

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
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — missing: $path"
    FAIL=$((FAIL + 1))
  fi
}

setup_fixture() {
  # setup_fixture <kdir> <slug> [findings-json]
  local kdir="$1" slug="$2" findings="${3:-}"
  mkdir -p "$kdir/_followups/$slug"
  if [[ -z "$findings" ]]; then
    findings='{"pr":42,"findings":[{"title":"off-by-one","file":"app.py","line":10,"severity":"blocking","grounding":"loop bound","selected":true},{"title":"nit","severity":"info","selected":false}]}'
  fi
  printf '%s\n' "$findings" > "$kdir/_followups/$slug/lens-findings.json"
}

gate_fixture() {
  # gate_fixture <path> <json-body>
  local path="$1" body="$2"
  printf '%s\n' "$body" > "$path"
}

echo "=== Audit-artifact.sh Tests ==="
echo ""

# =============================================
# Test 1: End-to-end happy path
# =============================================
echo "Test 1: End-to-end — 1 verified, 1 contradicted"
KDIR="$TEST_DIR/kdir1"
setup_fixture "$KDIR" "pr-42"
gate_fixture "$TEST_DIR/gate1.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc123def456",
  "verdicts":[
    {"claim_id":"finding-0","verdict":"verified","evidence":"app.py:10 matches"},
    {"claim_id":"finding-1","verdict":"contradicted","evidence":"no match found","correction":"nit claim was about a different file"}
  ]
}'

OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-42" --kdir "$KDIR" --gate-output-file "$TEST_DIR/gate1.json")
assert_contains "reports correctness-gate complete" "$OUT" "correctness-gate complete"
assert_contains "reports verdict counts" "$OUT" "total=2 verified=1 unverified=0 contradicted=1"
assert_contains "reports scorecard rows appended" "$OUT" "scorecard rows appended: 3"

assert_file_exists "verdicts file landed under _followups" "$KDIR/_followups/pr-42/verdicts/pr-42.jsonl"
assert_file_exists "scorecard rows.jsonl landed" "$KDIR/_scorecards/rows.jsonl"

# Verify scorecard row values
METRICS=$(jq -c '{metric,value,verdict_source,kind}' < "$KDIR/_scorecards/rows.jsonl")
assert_contains "factual_precision metric row present" "$METRICS" '"metric":"factual_precision","value":0.5'
assert_contains "audit_contradiction_rate metric row present" "$METRICS" '"metric":"audit_contradiction_rate","value":0.5'
assert_contains "falsifier_quality reflects all contradictions have corrections" "$METRICS" '"metric":"falsifier_quality","value":1'
assert_contains "rows attribute verdict_source=correctness-gate" "$METRICS" '"verdict_source":"correctness-gate"'
assert_contains "rows are kind=scored" "$METRICS" '"kind":"scored"'

# =============================================
# Test 2: User-supplied --gate-output-file is preserved across runs
# =============================================
echo ""
echo "Test 2: --gate-output-file is not deleted, multi-run appends"
KDIR="$TEST_DIR/kdir2"
setup_fixture "$KDIR" "pr-1" '{"pr":1,"findings":[{"title":"x","severity":"blocking","grounding":"g"}]}'
gate_fixture "$TEST_DIR/gate2.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"zzz",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'

bash "$AUDIT" "$KDIR/_followups/pr-1" --kdir "$KDIR" --gate-output-file "$TEST_DIR/gate2.json" >/dev/null
assert_file_exists "gate output file preserved after run 1" "$TEST_DIR/gate2.json"

bash "$AUDIT" "$KDIR/_followups/pr-1" --kdir "$KDIR" --gate-output-file "$TEST_DIR/gate2.json" >/dev/null
assert_file_exists "gate output file preserved after run 2" "$TEST_DIR/gate2.json"

VERDICT_LINES=$(wc -l < "$KDIR/_followups/pr-1/verdicts/pr-1.jsonl" | tr -d ' ')
assert_eq "2 runs → 2 verdict lines" "$VERDICT_LINES" "2"

ROW_LINES=$(wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' ')
assert_eq "2 runs → 6 scorecard rows" "$ROW_LINES" "6"

# =============================================
# Test 3: Contract violation — wrong judge name
# =============================================
echo ""
echo "Test 3: Contract violation — wrong judge name"
KDIR="$TEST_DIR/kdir3"
setup_fixture "$KDIR" "pr-bad"
gate_fixture "$TEST_DIR/gate-bad-judge.json" '{"judge":"wrong-gate","verdicts":[]}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-bad" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate-bad-judge.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "wrong judge name exits 2 (contract violation)" "$EXIT_CODE" "2"
assert_contains "error cites contract violation" "$ERR_OUT" "contract violation"

# =============================================
# Test 4: Contract violation — contradicted without correction
# =============================================
echo ""
echo "Test 4: Contract violation — contradicted verdict missing correction"
KDIR="$TEST_DIR/kdir4"
setup_fixture "$KDIR" "pr-bad2"
gate_fixture "$TEST_DIR/gate-bad-correction.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"a",
  "verdicts":[{"claim_id":"finding-0","verdict":"contradicted","evidence":"x"}]
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-bad2" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate-bad-correction.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "missing correction on contradicted exits 2" "$EXIT_CODE" "2"
assert_contains "error names the correction field" "$ERR_OUT" "correction missing on contradicted"

# =============================================
# Test 5: Contract violation — correction on verified verdict
# =============================================
echo ""
echo "Test 5: Contract violation — correction on verified verdict"
KDIR="$TEST_DIR/kdir5"
setup_fixture "$KDIR" "pr-bad3"
gate_fixture "$TEST_DIR/gate-correction-on-verified.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"a",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok","correction":"should not be here"}]
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-bad3" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate-correction-on-verified.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "correction on verified exits 2" "$EXIT_CODE" "2"
assert_contains "error names correction-must-be-absent" "$ERR_OUT" "correction must be absent"

# =============================================
# Test 6: --skip-scorecard persists verdicts but no scorecard rows
# =============================================
echo ""
echo "Test 6: --skip-scorecard"
KDIR="$TEST_DIR/kdir6"
setup_fixture "$KDIR" "pr-skip"
gate_fixture "$TEST_DIR/gate-skip.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"a",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'

bash "$AUDIT" "$KDIR/_followups/pr-skip" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate-skip.json" --skip-scorecard >/dev/null

assert_file_exists "verdicts persisted" "$KDIR/_followups/pr-skip/verdicts/pr-skip.jsonl"
if [[ -f "$KDIR/_scorecards/rows.jsonl" ]]; then
  echo "  FAIL: --skip-scorecard did not prevent rows.jsonl creation"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: --skip-scorecard prevented rows.jsonl creation"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 7: Missing --gate-output-file and no claude CLI → clean error
# =============================================
echo ""
echo "Test 7: No claude CLI and no --gate-output-file → clean error"
KDIR="$TEST_DIR/kdir7"
setup_fixture "$KDIR" "pr-nogate"

# Hide `claude` if present by running with a sanitized PATH
EXIT_CODE=0
ERR_OUT=$(PATH="/usr/bin:/bin" bash "$AUDIT" "$KDIR/_followups/pr-nogate" --kdir "$KDIR" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "no-claude, no-gate-file exits 1" "$EXIT_CODE" "1"
assert_contains "error names both integration modes" "$ERR_OUT" "claude"

# =============================================
# Test 8: Curator stage end-to-end via injection
# =============================================
echo ""
echo "Test 8: Curator stage — 2 verified → 1 selected + 1 dropped"
KDIR="$TEST_DIR/kdir8"
setup_fixture "$KDIR" "pr-8" '{"pr":8,"findings":[
  {"title":"a","file":"a.py","line":1,"severity":"blocking","grounding":"g"},
  {"title":"b","file":"b.py","line":2,"severity":"blocking","grounding":"g"},
  {"title":"c","severity":"info"}
]}'
gate_fixture "$TEST_DIR/gate8.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc",
  "verdicts":[
    {"claim_id":"finding-0","verdict":"verified","evidence":"a.py:1 ok"},
    {"claim_id":"finding-1","verdict":"verified","evidence":"b.py:2 ok"},
    {"claim_id":"finding-2","verdict":"unverified","evidence":"no ref"}
  ]
}'
gate_fixture "$TEST_DIR/curator8.json" '{
  "judge":"curator",
  "judge_template_version":"def",
  "selected":[
    {"claim_id":"finding-0","selection_rationale":"non-recoverable rationale"}
  ],
  "dropped":[
    {"claim_id":"finding-1","trivial_reason":"duplicate-of-survivor","drop_rationale":"dup of finding-0"}
  ]
}'

OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-8" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate8.json" \
  --curator-output-file "$TEST_DIR/curator8.json")
assert_contains "reports curator complete" "$OUT" "curator complete"
assert_contains "reports selected=1 dropped=1" "$OUT" "selected=1 dropped=1"
assert_contains "total rows = 5 (3 gate + 2 curator)" "$OUT" "total scorecard rows appended: 5"

# Verify curator scorecard rows landed with correct attribution
METRICS=$(jq -c '{metric,value,verdict_source,granularity,sample_size}' < "$KDIR/_scorecards/rows.jsonl")
assert_contains "curated_rate row present (0.5 = 1 selected / 2 verified)" "$METRICS" '"metric":"curated_rate","value":0.5,"verdict_source":"curator","granularity":"set-level","sample_size":2'
assert_contains "triviality_rate row present (0.5 = 1 dropped / 2 verified)" "$METRICS" '"metric":"triviality_rate","value":0.5,"verdict_source":"curator","granularity":"set-level","sample_size":2'

# Verify verdict file has 2 lines (gate + curator)
VERDICT_LINES=$(wc -l < "$KDIR/_followups/pr-8/verdicts/pr-8.jsonl" | tr -d ' ')
assert_eq "verdict file has 2 lines (gate + curator)" "$VERDICT_LINES" "2"

# =============================================
# Test 9: Curator skipped when 0 verified
# =============================================
echo ""
echo "Test 9: Curator skipped — 0 verified survivors"
KDIR="$TEST_DIR/kdir9"
setup_fixture "$KDIR" "pr-9"
gate_fixture "$TEST_DIR/gate9.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc",
  "verdicts":[
    {"claim_id":"finding-0","verdict":"contradicted","evidence":"no","correction":"actual"}
  ]
}'

OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-9" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate9.json" \
  --curator-output-file "$TEST_DIR/curator8.json")
# With 0 verified, curator never runs even if --curator-output-file is supplied.
# The "no curator runs" is inferred from the absence of "curator complete" output.
if echo "$OUT" | grep -qF "curator complete"; then
  echo "  FAIL: curator ran despite 0 verified survivors"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: curator skipped when 0 verified"
  PASS=$((PASS + 1))
fi
assert_contains "next-step says curator skipped" "$OUT" "curator skipped (no verified survivors)"

# =============================================
# Test 10: Curator auto-skip when gate injected but no curator file
# =============================================
echo ""
echo "Test 10: Curator auto-skip when gate is injected but no curator file"
KDIR="$TEST_DIR/kdir10"
setup_fixture "$KDIR" "pr-10"
gate_fixture "$TEST_DIR/gate10.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'

ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-10" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate10.json" 2>&1 >/dev/null)
assert_contains "auto-skip explanation cites gate-injected-but-no-curator-file" "$ERR_OUT" "gate was injected but no --curator-output-file supplied"

# =============================================
# Test 11: Contract violation — curator missing drop_rationale
# =============================================
echo ""
echo "Test 11: Contract violation — curator drop without drop_rationale"
KDIR="$TEST_DIR/kdir11"
setup_fixture "$KDIR" "pr-11" '{"pr":11,"findings":[
  {"title":"a","severity":"blocking","grounding":"g"},
  {"title":"b","severity":"blocking","grounding":"g"}
]}'
gate_fixture "$TEST_DIR/gate11.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc",
  "verdicts":[
    {"claim_id":"finding-0","verdict":"verified","evidence":"ok"},
    {"claim_id":"finding-1","verdict":"verified","evidence":"ok"}
  ]
}'
gate_fixture "$TEST_DIR/curator-bad.json" '{
  "judge":"curator","judge_template_version":"d",
  "selected":[{"claim_id":"finding-0","selection_rationale":"ok"}],
  "dropped":[{"claim_id":"finding-1"}]
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-11" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate11.json" \
  --curator-output-file "$TEST_DIR/curator-bad.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "curator drop without drop_rationale exits 2" "$EXIT_CODE" "2"
assert_contains "error names drop_rationale" "$ERR_OUT" "drop_rationale missing"

# =============================================
# Test 12: Contract violation — curator selected empty despite verified set
# =============================================
echo ""
echo "Test 12: Contract violation — curator selected empty with non-empty verified"
KDIR="$TEST_DIR/kdir12"
setup_fixture "$KDIR" "pr-12"
gate_fixture "$TEST_DIR/gate12.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"abc",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'
gate_fixture "$TEST_DIR/curator-empty-sel.json" '{
  "judge":"curator","judge_template_version":"d",
  "selected":[],
  "dropped":[{"claim_id":"finding-0","drop_rationale":"trivial"}]
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-12" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate12.json" \
  --curator-output-file "$TEST_DIR/curator-empty-sel.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "curator empty selected with verified exits 2" "$EXIT_CODE" "2"
assert_contains "error names empty-selected-vs-verified" "$ERR_OUT" "selected is empty but verified_candidate_set was non-empty"

# =============================================
# Test 13: Contract violation — curator selected > 3
# =============================================
echo ""
echo "Test 13: Contract violation — curator selected > 3"
KDIR="$TEST_DIR/kdir13"
setup_fixture "$KDIR" "pr-13" '{"pr":13,"findings":[
  {"title":"a","severity":"blocking","grounding":"g"},
  {"title":"b","severity":"blocking","grounding":"g"},
  {"title":"c","severity":"blocking","grounding":"g"},
  {"title":"d","severity":"blocking","grounding":"g"}
]}'
gate_fixture "$TEST_DIR/gate13.json" '{
  "judge":"correctness-gate","judge_template_version":"abc",
  "verdicts":[
    {"claim_id":"finding-0","verdict":"verified","evidence":"ok"},
    {"claim_id":"finding-1","verdict":"verified","evidence":"ok"},
    {"claim_id":"finding-2","verdict":"verified","evidence":"ok"},
    {"claim_id":"finding-3","verdict":"verified","evidence":"ok"}
  ]
}'
gate_fixture "$TEST_DIR/curator-too-many.json" '{
  "judge":"curator","judge_template_version":"d",
  "selected":[
    {"claim_id":"finding-0","selection_rationale":"r"},
    {"claim_id":"finding-1","selection_rationale":"r"},
    {"claim_id":"finding-2","selection_rationale":"r"},
    {"claim_id":"finding-3","selection_rationale":"r"}
  ],
  "dropped":[]
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-13" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate13.json" \
  --curator-output-file "$TEST_DIR/curator-too-many.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "curator selected > 3 exits 2" "$EXIT_CODE" "2"
assert_contains "error names the k-bound violation" "$ERR_OUT" "curator contract caps at 3"

# =============================================
# Test 14: Reverse-auditor stage — silence (explicit no-omission)
# =============================================
echo ""
echo "Test 14: Reverse-auditor silence"
KDIR="$TEST_DIR/kdir14"
setup_fixture "$KDIR" "pr-14"
gate_fixture "$TEST_DIR/gate14.json" '{
  "judge":"correctness-gate","judge_template_version":"gtv",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'
gate_fixture "$TEST_DIR/curator14.json" '{
  "judge":"curator","judge_template_version":"ctv",
  "selected":[{"claim_id":"finding-0","selection_rationale":"kept"}],
  "dropped":[]
}'
gate_fixture "$TEST_DIR/ra14.json" '{
  "judge":"reverse-auditor","judge_template_version":"rtv",
  "omission_claim":null,
  "silence_rationale":"coverage looks clean"
}'

OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-14" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate14.json" \
  --curator-output-file "$TEST_DIR/curator14.json" \
  --reverse-auditor-output-file "$TEST_DIR/ra14.json")
assert_contains "reports reverse-auditor complete" "$OUT" "reverse-auditor complete"
assert_contains "silence verdict reported" "$OUT" "verdict=silence"
assert_contains "queue destination is silence (no write)" "$OUT" "queue=silence"
# Silence emits exactly one telemetry row (grounding_failure_rate=0)
assert_contains "total rows = 6 (3 gate + 2 curator + 1 telemetry)" "$OUT" "total scorecard rows appended: 6"

# Verify no audit-candidates/attempts file was created (silence short-circuits queue)
if [[ -f "$KDIR/_followups/pr-14/audit-candidates.jsonl" ]]; then
  echo "  FAIL: silence created audit-candidates.jsonl"; FAIL=$((FAIL + 1))
else
  echo "  PASS: silence did not create audit-candidates.jsonl"; PASS=$((PASS + 1))
fi
if [[ -f "$KDIR/_followups/pr-14/audit-attempts.jsonl" ]]; then
  echo "  FAIL: silence created audit-attempts.jsonl"; FAIL=$((FAIL + 1))
else
  echo "  PASS: silence did not create audit-attempts.jsonl"; PASS=$((PASS + 1))
fi

# Verify telemetry row shape
RA_METRICS=$(jq -c 'select(.verdict_source=="reverse-auditor")' < "$KDIR/_scorecards/rows.jsonl")
assert_contains "grounding_failure_rate telemetry row=0" "$RA_METRICS" '"metric":"grounding_failure_rate"'
assert_contains "reverse-auditor rows are kind=telemetry on silence" "$RA_METRICS" '"kind":"telemetry"'

# Verdict file has 3 lines (gate + curator + reverse-auditor)
VERDICT_LINES=$(wc -l < "$KDIR/_followups/pr-14/verdicts/pr-14.jsonl" | tr -d ' ')
assert_eq "verdict file has 3 lines" "$VERDICT_LINES" "3"

# =============================================
# Test 15: Reverse-auditor stage — grounded omission claim (preflight pass)
# =============================================
echo ""
echo "Test 15: Reverse-auditor grounded omission (preflight pass)"
KDIR="$TEST_DIR/kdir15"
setup_fixture "$KDIR" "pr-15"

# Build a fixture repo with a file the omission claim anchors into.
FIXTURE_REPO="$TEST_DIR/repo15"
mkdir -p "$FIXTURE_REPO"
printf 'line-one\nline-two\nline-three\n' > "$FIXTURE_REPO/target.py"

# exact_snippet must be verbatim lines 2-2 ("line-two"); normalized hash
# follows v1 normalization (already clean ASCII, single-line).
HASH=$(printf '%s' "line-two" | python3 -c '
import hashlib,re,sys
s=sys.stdin.read()
s=s.replace("‘","\x27").replace("’","\x27")
s=s.replace("“","\x22").replace("”","\x22")
s=re.sub(r"\s+"," ",s).strip()
print(hashlib.sha256(s.encode("utf-8")).hexdigest())
')

gate_fixture "$TEST_DIR/gate15.json" '{
  "judge":"correctness-gate","judge_template_version":"gtv",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'
gate_fixture "$TEST_DIR/curator15.json" '{
  "judge":"curator","judge_template_version":"ctv",
  "selected":[{"claim_id":"finding-0","selection_rationale":"kept"}],
  "dropped":[]
}'
gate_fixture "$TEST_DIR/ra15.json" '{
  "judge":"reverse-auditor","judge_template_version":"rtv",
  "omission_claim":{
    "file":"target.py","line_range":"2-2",
    "exact_snippet":"line-two",
    "normalized_snippet_hash":"'"$HASH"'",
    "falsifier":"grep for callers of line-two",
    "why_it_matters":"documents an untested branch"
  }
}'

OUT=$(LORE_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT" "$KDIR/_followups/pr-15" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate15.json" \
  --curator-output-file "$TEST_DIR/curator15.json" \
  --reverse-auditor-output-file "$TEST_DIR/ra15.json")
assert_contains "omission-claim verdict reported" "$OUT" "verdict=omission-claim"
assert_contains "preflight ok" "$OUT" "preflight=ok"
assert_contains "queue destination is candidates" "$OUT" "queue=candidates"
# Grounded omission → 3 reverse-auditor scorecard rows (omission_rate scored +
# coverage_quality scored + grounding_failure_rate telemetry)
assert_contains "total rows = 8 (3 gate + 2 curator + 3 ra)" "$OUT" "total scorecard rows appended: 8"

# audit-candidates.jsonl landed in the followup dir (no _work/<slug>)
assert_file_exists "audit-candidates.jsonl written" "$KDIR/_followups/pr-15/audit-candidates.jsonl"
CAND_LINE=$(cat "$KDIR/_followups/pr-15/audit-candidates.jsonl")
assert_contains "candidate row carries file" "$CAND_LINE" '"file": "target.py"'
assert_contains "candidate row status=pending_correctness_gate" "$CAND_LINE" '"status": "pending_correctness_gate"'

# Verify claim_anchor landed on scored reverse-auditor rows
RA_SCORED=$(jq -c 'select(.verdict_source=="reverse-auditor" and .kind=="scored")' < "$KDIR/_scorecards/rows.jsonl")
assert_contains "scored reverse-auditor row has claim_anchor.file" "$RA_SCORED" '"file":"target.py"'
assert_contains "omission_rate=1.0 on grounded omission" "$RA_SCORED" '"metric":"omission_rate","value":1'

# =============================================
# Test 16: Reverse-auditor preflight fail → audit-attempts.jsonl + exit 3
# =============================================
echo ""
echo "Test 16: Reverse-auditor preflight fail — bad line-range"
KDIR="$TEST_DIR/kdir16"
setup_fixture "$KDIR" "pr-16"

FIXTURE_REPO="$TEST_DIR/repo16"
mkdir -p "$FIXTURE_REPO"
printf 'only-one-line\n' > "$FIXTURE_REPO/short.py"

gate_fixture "$TEST_DIR/gate16.json" '{
  "judge":"correctness-gate","judge_template_version":"gtv",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'
gate_fixture "$TEST_DIR/curator16.json" '{
  "judge":"curator","judge_template_version":"ctv",
  "selected":[{"claim_id":"finding-0","selection_rationale":"kept"}],
  "dropped":[]
}'
# Claim points at line 99 of a 1-line file → line-out-of-range
gate_fixture "$TEST_DIR/ra16.json" '{
  "judge":"reverse-auditor","judge_template_version":"rtv",
  "omission_claim":{
    "file":"short.py","line_range":"99-99",
    "exact_snippet":"phantom",
    "normalized_snippet_hash":"0000000000000000000000000000000000000000000000000000000000000000",
    "falsifier":"falsifier",
    "why_it_matters":"why"
  }
}'

EXIT_CODE=0
OUT=$(LORE_REPO_ROOT="$FIXTURE_REPO" bash "$AUDIT" "$KDIR/_followups/pr-16" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate16.json" \
  --curator-output-file "$TEST_DIR/curator16.json" \
  --reverse-auditor-output-file "$TEST_DIR/ra16.json") || EXIT_CODE=$?
assert_eq "preflight-failed exits 3" "$EXIT_CODE" "3"
assert_contains "preflight reason is line-out-of-range" "$OUT" "preflight=line-out-of-range"
assert_contains "queue destination is attempts" "$OUT" "queue=attempts"

assert_file_exists "audit-attempts.jsonl written" "$KDIR/_followups/pr-16/audit-attempts.jsonl"
ATT_LINE=$(cat "$KDIR/_followups/pr-16/audit-attempts.jsonl")
assert_contains "attempt row cites line-out-of-range reason" "$ATT_LINE" '"reason": "line-out-of-range"'

# grounding_failure_rate telemetry row = 1.0 on preflight fail
RA_TELEMETRY=$(jq -c 'select(.verdict_source=="reverse-auditor" and .kind=="telemetry")' < "$KDIR/_scorecards/rows.jsonl")
assert_contains "grounding_failure_rate=1.0 on preflight fail" "$RA_TELEMETRY" '"metric":"grounding_failure_rate","value":1'
# omission_rate scored row must NOT be emitted on preflight fail (no grounded claim)
RA_OMISSION=$(jq -c 'select(.verdict_source=="reverse-auditor" and .metric=="omission_rate")' < "$KDIR/_scorecards/rows.jsonl")
if [[ -z "$RA_OMISSION" ]]; then
  echo "  PASS: no omission_rate scored row on preflight fail"; PASS=$((PASS + 1))
else
  echo "  FAIL: omission_rate scored row emitted on preflight fail: $RA_OMISSION"; FAIL=$((FAIL + 1))
fi

# =============================================
# Test 17: Reverse-auditor contract violation — malformed emission
# =============================================
echo ""
echo "Test 17: Reverse-auditor shape violation — omission_claim missing required field"
KDIR="$TEST_DIR/kdir17"
setup_fixture "$KDIR" "pr-17"
gate_fixture "$TEST_DIR/gate17.json" '{
  "judge":"correctness-gate","judge_template_version":"gtv",
  "verdicts":[{"claim_id":"finding-0","verdict":"verified","evidence":"ok"}]
}'
gate_fixture "$TEST_DIR/curator17.json" '{
  "judge":"curator","judge_template_version":"ctv",
  "selected":[{"claim_id":"finding-0","selection_rationale":"kept"}],
  "dropped":[]
}'
# Missing falsifier
gate_fixture "$TEST_DIR/ra-bad.json" '{
  "judge":"reverse-auditor","judge_template_version":"rtv",
  "omission_claim":{
    "file":"x.py","line_range":"1-1","exact_snippet":"x",
    "normalized_snippet_hash":"h","why_it_matters":"w"
  }
}'

EXIT_CODE=0
ERR_OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-17" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate17.json" \
  --curator-output-file "$TEST_DIR/curator17.json" \
  --reverse-auditor-output-file "$TEST_DIR/ra-bad.json" --skip-scorecard 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "reverse-auditor shape violation exits 2" "$EXIT_CODE" "2"
assert_contains "error names the missing field" "$ERR_OUT" "omission_claim.falsifier missing"

# =============================================
# Test 18: Reverse-auditor skipped when curator produced 0 selected
# =============================================
echo ""
echo "Test 18: Reverse-auditor skipped — 0 curator-selected survivors"
KDIR="$TEST_DIR/kdir18"
setup_fixture "$KDIR" "pr-18"
gate_fixture "$TEST_DIR/gate18.json" '{
  "judge":"correctness-gate","judge_template_version":"gtv",
  "verdicts":[{"claim_id":"finding-0","verdict":"contradicted","evidence":"no","correction":"actual"}]
}'

OUT=$(bash "$AUDIT" "$KDIR/_followups/pr-18" --kdir "$KDIR" \
  --gate-output-file "$TEST_DIR/gate18.json" \
  --curator-output-file "$TEST_DIR/curator14.json" \
  --reverse-auditor-output-file "$TEST_DIR/ra14.json")
# With 0 verified → no curator → no reverse-auditor. Confirm by absence of
# "reverse-auditor complete" output.
if echo "$OUT" | grep -qF "reverse-auditor complete"; then
  echo "  FAIL: reverse-auditor ran when curator had no survivors"; FAIL=$((FAIL + 1))
else
  echo "  PASS: reverse-auditor skipped when curator stage did not run"; PASS=$((PASS + 1))
fi

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
