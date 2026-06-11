#!/usr/bin/env bash
# test_audit.sh — Tests for scripts/audit-artifact.sh
#
# Covers the three live source streams (task-claims, omission, consumption-
# contradiction) and the per-kind --kind/--id dispatch flag pair introduced
# alongside the kind-aware substrate. Each stream gets:
#   - happy-path resolution via positional artifact-id
#   - happy-path resolution via --kind/--id
#   - error path on absent/duplicate/malformed/kind-mismatched rows
# Plus general gate-contract and pipeline-skip tests that apply to every kind.

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

setup_task_claims_fixture() {
  # setup_task_claims_fixture <kdir> <slug>
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
  cat > "$kdir/_work/$slug/task-claims.jsonl" <<'JSONLEOF'
{"claim_id":"task-claim-a","tier":"task-evidence","claim":"task claim A is auditable directly from task-claims.jsonl","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"scripts/audit-artifact.sh","line_range":"1-20"},"falsifier":"Run lore audit against task-claims.jsonl with a matching priority claim"}
{"claim_id":"task-claim-b","tier":"task-evidence","claim":"task claim B remains available for priority filtering","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"scripts/audit-artifact.sh","line_range":"21-40"},"falsifier":"Run lore audit against task-claims.jsonl without a matching priority claim"}
JSONLEOF
}

setup_archived_task_claims_fixture() {
  # setup_archived_task_claims_fixture <kdir> <slug> — same rows as the active
  # fixture, but under _work/_archive/<slug>/ for artifact-presence fallback tests.
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/_archive/$slug"
  cat > "$kdir/_work/_archive/$slug/task-claims.jsonl" <<'JSONLEOF'
{"claim_id":"task-claim-a","tier":"task-evidence","claim":"task claim A is auditable directly from task-claims.jsonl","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"scripts/audit-artifact.sh","line_range":"1-20"},"falsifier":"Run lore audit against task-claims.jsonl with a matching priority claim"}
{"claim_id":"task-claim-b","tier":"task-evidence","claim":"task claim B remains available for priority filtering","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"scripts/audit-artifact.sh","line_range":"21-40"},"falsifier":"Run lore audit against task-claims.jsonl without a matching priority claim"}
JSONLEOF
}

setup_audit_candidates_fixture() {
  # setup_audit_candidates_fixture <kdir> <slug>
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
  cat > "$kdir/_work/$slug/audit-candidates.jsonl" <<'JSONLEOF'
{"candidate_id":"cand-aaaaaaaaaaaa","verdict_source":"reverse-auditor","work_item":"omission-fixture-slug","file":"scripts/audit-artifact.sh","line_range":"10-12","falsifier":"Confirm caller does not pass --foo when --bar is set","rationale":"Untested branch on flag combination","status":"pending_correctness_gate","created_at":"2026-05-16T00:00:00Z"}
JSONLEOF
}

setup_consumption_contradictions_fixture() {
  # setup_consumption_contradictions_fixture <kdir> <slug>
  local kdir="$1" slug="$2"
  mkdir -p "$kdir/_work/$slug"
  cat > "$kdir/_work/$slug/consumption-contradictions.jsonl" <<'JSONLEOF'
{"contradiction_id":"ctr-aaaaaaaaaaaa","verdict_source":"consumer-contradiction-channel","work_item":"cc-fixture-slug","source":"worker","producer_role":"worker","protocol_slot":"implementation","cycle_id":"cycle-1","prefetched_commons_entry":{"knowledge_path":"conventions/foo.md","heading":""},"contradiction_rationale":"The code at this line falsifies the commons claim","claim_payload":{"claim_id":"contradict-1","claim_text":"The function never returns null","file":"scripts/audit-artifact.sh","line_range":"50-50","exact_snippet":"return None","falsifier":"Trace the return paths and confirm None can be returned"},"status":"pending","created_at":"2026-05-16T00:00:00Z","dedupe_key":"d","captured_at_branch":null,"captured_at_sha":null,"captured_at_merge_base_sha":null}
JSONLEOF
}

gate_fixture() {
  # gate_fixture <path> <json-body>
  local path="$1" body="$2"
  printf '%s\n' "$body" > "$path"
}

echo "=== Audit-artifact.sh Tests ==="
echo ""

# =============================================
# Test 1: Task-claims happy path — positional artifact-id resolves the dir,
# --priority-claims narrows to one row, gate verdict landed correctly.
# =============================================
echo "Test 1: task-claims via directory positional + --priority-claims"
KDIR1="$TEST_DIR/kdir1"
setup_task_claims_fixture "$KDIR1" "wi-task-claims"
gate_fixture "$TEST_DIR/gate1.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"taskclaims111",
  "verdicts":[
    {"claim_id":"task-claim-a","verdict":"unverified","evidence":"fixture leaves claim unresolved"}
  ]
}'
printf '%s\n' '["task-claim-a"]' > "$TEST_DIR/priority1.json"

OUT1=$(bash "$AUDIT" "$KDIR1/_work/wi-task-claims/task-claims.jsonl" --kdir "$KDIR1" \
  --gate-output-file "$TEST_DIR/gate1.json" \
  --priority-claims "$TEST_DIR/priority1.json" 2>&1)
assert_contains "task-claims: priority narrowed to one row" "$OUT1" "priority-claims: narrowed claim_payload to 1 claim(s)"
assert_contains "task-claims: assertion gate completes" "$OUT1" "correctness-gate-assertion complete"
assert_contains "task-claims: verdict totals reflect one unverified claim" "$OUT1" "total=1 verified=0 unverified=1 contradicted=0"
assert_file_exists "task-claims verdict file landed under work item" "$KDIR1/_work/wi-task-claims/verdicts/task-claims.jsonl"

# =============================================
# Test 2: Task-claims via --kind task-claim --id <claim_id> --work-item <slug>
# Resolves exactly one row and routes only that row through the pipeline.
# =============================================
echo ""
echo "Test 2: task-claims via --kind/--id"
KDIR2="$TEST_DIR/kdir2"
setup_task_claims_fixture "$KDIR2" "wi-kind"
gate_fixture "$TEST_DIR/gate2.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"kind222",
  "verdicts":[
    {"claim_id":"task-claim-b","verdict":"verified","evidence":"matches"}
  ]
}'

OUT2=$(bash "$AUDIT" --kdir "$KDIR2" --work-item "wi-kind" \
  --kind task-claim --id task-claim-b \
  --gate-output-file "$TEST_DIR/gate2.json" 2>&1)
assert_contains "kind/id: narrowing message present" "$OUT2" "priority-claims: narrowed claim_payload to 1 claim(s)"
assert_contains "kind/id: assertion gate completes" "$OUT2" "correctness-gate-assertion complete"
assert_contains "kind/id: verdict totals reflect one verified claim" "$OUT2" "total=1 verified=1 unverified=0 contradicted=0"

# =============================================
# Test 3: Omission via --kind omission --id <candidate_id>
# =============================================
echo ""
echo "Test 3: omission via --kind/--id"
KDIR3="$TEST_DIR/kdir3"
setup_audit_candidates_fixture "$KDIR3" "wi-omission"
gate_fixture "$TEST_DIR/gate3.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"omiss333",
  "verdicts":[
    {"claim_id":"cand-aaaaaaaaaaaa","verdict":"verified","evidence":"branch confirmed missing"}
  ]
}'

OUT3=$(bash "$AUDIT" --kdir "$KDIR3" --work-item "wi-omission" \
  --kind omission --id cand-aaaaaaaaaaaa \
  --gate-output-file "$TEST_DIR/gate3.json" 2>&1)
assert_contains "omission: gate completes" "$OUT3" "correctness-gate-omission complete"
assert_contains "omission: verdict totals reflect one verified claim" "$OUT3" "total=1 verified=1 unverified=0 contradicted=0"

# =============================================
# Test 4: Consumption-contradiction via --kind consumption-contradiction --id <contradiction_id>
# =============================================
echo ""
echo "Test 4: consumption-contradiction via --kind/--id"
KDIR4="$TEST_DIR/kdir4"
setup_consumption_contradictions_fixture "$KDIR4" "wi-cc"
gate_fixture "$TEST_DIR/gate4.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"cc444",
  "verdicts":[
    {"claim_id":"contradict-1","verdict":"contradicted","evidence":"the claim is wrong","correction":"the function can return None"}
  ]
}'

OUT4=$(bash "$AUDIT" --kdir "$KDIR4" --work-item "wi-cc" \
  --kind consumption-contradiction --id ctr-aaaaaaaaaaaa \
  --gate-output-file "$TEST_DIR/gate4.json" 2>&1)
assert_contains "cc: contradiction gate completes" "$OUT4" "correctness-gate-contradiction complete"
assert_contains "cc: verdict totals reflect one contradicted claim" "$OUT4" "total=1 verified=0 unverified=0 contradicted=1"

# =============================================
# Test 5: --kind/--id error: missing source file
# =============================================
echo ""
echo "Test 5: --kind/--id error — missing source file"
KDIR5="$TEST_DIR/kdir5"
mkdir -p "$KDIR5/_work/wi-empty"

EXIT5=0
ERR5=$(bash "$AUDIT" --kdir "$KDIR5" --work-item "wi-empty" \
  --kind task-claim --id task-claim-x 2>&1 >/dev/null) || EXIT5=$?
assert_eq "missing source file exits 1" "$EXIT5" "1"
assert_contains "missing source: stderr names the missing file" "$ERR5" "source file not found"

# =============================================
# Test 6: --kind/--id error: absent id (file exists but no matching row)
# =============================================
echo ""
echo "Test 6: --kind/--id error — id not present in source file"
KDIR6="$TEST_DIR/kdir6"
setup_task_claims_fixture "$KDIR6" "wi-no-match"

EXIT6=0
ERR6=$(bash "$AUDIT" --kdir "$KDIR6" --work-item "wi-no-match" \
  --kind task-claim --id task-claim-zzzzz 2>&1 >/dev/null) || EXIT6=$?
assert_eq "absent id exits 1" "$EXIT6" "1"
assert_contains "absent id: stderr cites 'resolved 0 source rows'" "$ERR6" "resolved 0 source rows"

# =============================================
# Test 7: --kind/--id error: duplicate id (file has two matching rows)
# =============================================
echo ""
echo "Test 7: --kind/--id error — duplicate id resolves >1 row"
KDIR7="$TEST_DIR/kdir7"
mkdir -p "$KDIR7/_work/wi-dup"
cat > "$KDIR7/_work/wi-dup/task-claims.jsonl" <<'JSONLEOF'
{"claim_id":"dup-id","tier":"task-evidence","claim":"first occurrence","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"x","line_range":"1-1"},"falsifier":"x","change_context":{"diff_ref":null,"changed_files":["x"],"summary":"s"}}
{"claim_id":"dup-id","tier":"task-evidence","claim":"second occurrence","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"x","line_range":"2-2"},"falsifier":"x","change_context":{"diff_ref":null,"changed_files":["x"],"summary":"s"}}
JSONLEOF

EXIT7=0
ERR7=$(bash "$AUDIT" --kdir "$KDIR7" --work-item "wi-dup" \
  --kind task-claim --id dup-id 2>&1 >/dev/null) || EXIT7=$?
assert_eq "duplicate id exits 1" "$EXIT7" "1"
assert_contains "duplicate id: stderr cites 'resolved 2 source rows'" "$ERR7" "resolved 2 source rows"

# =============================================
# Test 8: --kind/--id error: malformed source file (invalid JSON line) is
# silently skipped — duplicate/zero-match detection is unaffected by it.
# Here the only valid row has the requested id; absent-id error fires only if
# malformed lines were the *only* lines. Use a tighter fixture: malformed
# row + zero valid rows ⇒ absent-id error after dedupe.
# =============================================
echo ""
echo "Test 8: --kind/--id error — malformed source file leaves zero matches"
KDIR8="$TEST_DIR/kdir8"
mkdir -p "$KDIR8/_work/wi-malformed"
printf '%s\n' '{this is not valid json' > "$KDIR8/_work/wi-malformed/task-claims.jsonl"

EXIT8=0
ERR8=$(bash "$AUDIT" --kdir "$KDIR8" --work-item "wi-malformed" \
  --kind task-claim --id task-claim-x 2>&1 >/dev/null) || EXIT8=$?
assert_eq "malformed-only file exits 1" "$EXIT8" "1"
assert_contains "malformed-only: stderr cites 'resolved 0 source rows'" "$ERR8" "resolved 0 source rows"

# =============================================
# Test 9: --kind/--id error: kind mismatch — id exists in a different stream
# than --kind names. The wrapper resolves only against the --kind file, so the
# error is "resolved 0 source rows" (the id lives elsewhere).
# =============================================
echo ""
echo "Test 9: --kind/--id error — kind mismatch (id lives in another stream)"
KDIR9="$TEST_DIR/kdir9"
mkdir -p "$KDIR9/_work/wi-mismatch"
# task-claim id, but we'll ask for kind=omission
cat > "$KDIR9/_work/wi-mismatch/task-claims.jsonl" <<'JSONLEOF'
{"claim_id":"wrong-stream-id","tier":"task-evidence","claim":"x","producer_role":"worker","protocol_slot":"implementation","task_id":"t","phase_id":"1","scale":"implementation","source":{"file":"x","line_range":"1-1"},"falsifier":"x","change_context":{"diff_ref":null,"changed_files":["x"],"summary":"s"}}
JSONLEOF
# Empty omission file (signals file presence, no rows)
: > "$KDIR9/_work/wi-mismatch/audit-candidates.jsonl"

EXIT9=0
ERR9=$(bash "$AUDIT" --kdir "$KDIR9" --work-item "wi-mismatch" \
  --kind omission --id wrong-stream-id 2>&1 >/dev/null) || EXIT9=$?
assert_eq "kind-mismatch exits 1" "$EXIT9" "1"
assert_contains "kind-mismatch: stderr cites 'resolved 0 source rows'" "$ERR9" "resolved 0 source rows"

# =============================================
# Test 10: --kind/--id flag pairing — --kind without --id rejected
# =============================================
echo ""
echo "Test 10: --kind without --id rejected"
EXIT10=0
ERR10=$(bash "$AUDIT" --kdir "$TEST_DIR" --work-item "wi-x" --kind task-claim 2>&1 >/dev/null) || EXIT10=$?
assert_eq "--kind without --id exits 1" "$EXIT10" "1"
assert_contains "stderr names flag pairing rule" "$ERR10" "--kind and --id must both be present"

# =============================================
# Test 11: --kind invalid value rejected
# =============================================
echo ""
echo "Test 11: --kind invalid value rejected"
EXIT11=0
ERR11=$(bash "$AUDIT" --kdir "$TEST_DIR" --work-item "wi-x" --kind nonsense --id foo 2>&1 >/dev/null) || EXIT11=$?
assert_eq "--kind invalid exits 1" "$EXIT11" "1"
assert_contains "stderr names valid kind enum" "$ERR11" "--kind must be"

# =============================================
# Test 12: Gate contract violation — wrong judge name
# =============================================
echo ""
echo "Test 12: Contract violation — wrong judge name"
KDIR12="$TEST_DIR/kdir12"
setup_task_claims_fixture "$KDIR12" "wi-bad"
gate_fixture "$TEST_DIR/gate-bad-judge.json" '{"judge":"wrong-gate","verdicts":[]}'

EXIT12=0
ERR12=$(bash "$AUDIT" --kdir "$KDIR12" --work-item "wi-bad" \
  --kind task-claim --id task-claim-a \
  --gate-output-file "$TEST_DIR/gate-bad-judge.json" --skip-scorecard 2>&1 >/dev/null) || EXIT12=$?
assert_eq "wrong judge name exits 2 (contract violation)" "$EXIT12" "2"
assert_contains "error cites contract violation" "$ERR12" "contract violation"

# =============================================
# Test 13: Gate contract violation — contradicted without correction
# =============================================
echo ""
echo "Test 13: Contract violation — contradicted verdict missing correction"
KDIR13="$TEST_DIR/kdir13"
setup_task_claims_fixture "$KDIR13" "wi-bad2"
gate_fixture "$TEST_DIR/gate-bad-correction.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"a",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"contradicted","evidence":"x"}]
}'

EXIT13=0
ERR13=$(bash "$AUDIT" --kdir "$KDIR13" --work-item "wi-bad2" \
  --kind task-claim --id task-claim-a \
  --gate-output-file "$TEST_DIR/gate-bad-correction.json" --skip-scorecard 2>&1 >/dev/null) || EXIT13=$?
assert_eq "missing correction on contradicted exits 2" "$EXIT13" "2"
assert_contains "error names the correction field" "$ERR13" "correction missing on contradicted"

# =============================================
# Test 14: --skip-scorecard persists verdicts but no scorecard rows
# =============================================
echo ""
echo "Test 14: --skip-scorecard"
KDIR14="$TEST_DIR/kdir14"
setup_task_claims_fixture "$KDIR14" "wi-skip"
gate_fixture "$TEST_DIR/gate-skip.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"a",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"}]
}'

bash "$AUDIT" --kdir "$KDIR14" --work-item "wi-skip" \
  --kind task-claim --id task-claim-a \
  --gate-output-file "$TEST_DIR/gate-skip.json" --skip-scorecard >/dev/null

assert_file_exists "verdicts persisted" "$KDIR14/_work/wi-skip/verdicts/task-claims.jsonl"
if [[ -f "$KDIR14/_scorecards/rows.jsonl" ]]; then
  echo "  FAIL: --skip-scorecard did not prevent rows.jsonl creation"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: --skip-scorecard prevented rows.jsonl creation"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 15: --priority-claims absent → unchanged pipeline (regression)
# =============================================
echo ""
echo "Test 15: --priority-claims absent → pipeline unchanged"
KDIR15="$TEST_DIR/kdir15"
setup_task_claims_fixture "$KDIR15" "wi-noflag"
gate_fixture "$TEST_DIR/gate15.json" '{
  "judge":"correctness-gate",
  "judge_template_version":"ppp",
  "verdicts":[
    {"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"},
    {"claim_id":"task-claim-b","verdict":"verified","evidence":"ok"}
  ]
}'

OUT15=$(bash "$AUDIT" "$KDIR15/_work/wi-noflag/task-claims.jsonl" --kdir "$KDIR15" \
  --gate-output-file "$TEST_DIR/gate15.json" 2>&1)
assert_contains "no-flag: assertion gate completes" "$OUT15" "correctness-gate-assertion complete"
assert_contains "no-flag: both claims kept" "$OUT15" "total=2 verified=2"
if echo "$OUT15" | grep -qF "priority-claims: narrowed"; then
  echo "  FAIL: no-flag run emitted a priority-claims narrowing message"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: no-flag run emits no priority-claims narrowing message"
  PASS=$((PASS + 1))
fi

# =============================================
# Test 16: --priority-claims missing file → exit 1
# =============================================
echo ""
echo "Test 16: --priority-claims missing file → exit 1"
KDIR16="$TEST_DIR/kdir16"
setup_task_claims_fixture "$KDIR16" "wi-pcmiss"
gate_fixture "$TEST_DIR/gate16.json" '{
  "judge":"correctness-gate","judge_template_version":"x",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"}]
}'

EXIT16=0
ERR16=$(bash "$AUDIT" "$KDIR16/_work/wi-pcmiss/task-claims.jsonl" --kdir "$KDIR16" \
  --gate-output-file "$TEST_DIR/gate16.json" \
  --priority-claims "$TEST_DIR/does-not-exist-$RANDOM.json" 2>&1 >/dev/null) || EXIT16=$?
assert_eq "missing priority-claims file exits 1" "$EXIT16" "1"
assert_contains "missing file: stderr names 'priority-claims file not found'" "$ERR16" "priority-claims file not found"

# =============================================
# Test 17: --priority-claims empty array → exit 1
# =============================================
echo ""
echo "Test 17: --priority-claims empty array → exit 1"
KDIR17="$TEST_DIR/kdir17"
setup_task_claims_fixture "$KDIR17" "wi-pcempty"
gate_fixture "$TEST_DIR/gate17.json" '{
  "judge":"correctness-gate","judge_template_version":"x",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"}]
}'
printf '%s\n' '[]' > "$TEST_DIR/priority17.json"

EXIT17=0
ERR17=$(bash "$AUDIT" "$KDIR17/_work/wi-pcempty/task-claims.jsonl" --kdir "$KDIR17" \
  --gate-output-file "$TEST_DIR/gate17.json" \
  --priority-claims "$TEST_DIR/priority17.json" 2>&1 >/dev/null) || EXIT17=$?
assert_eq "empty array exits 1" "$EXIT17" "1"
assert_contains "empty array: stderr names 'priority-claims array is empty'" "$ERR17" "priority-claims array is empty"


# =============================================
# Test 18: '_archive' literal rejected as work-item slug
# Regression: a path-parsing bug at audit-artifact.sh:851 used to capture
# '_archive' as the slug for any artifact under /_work/_archive/<real-slug>/,
# producing phantom verdict stubs at $KDIR/_work/_archive/verdicts/. The
# defensive guard rejects '_archive' as an ARTIFACT_ID outright.
# =============================================
echo ""
echo "Test 18: '_archive' literal rejected as work-item slug"
KDIR18="$TEST_DIR/kdir18"
mkdir -p "$KDIR18/_work/_archive/real-slug"
cat > "$KDIR18/_work/_archive/real-slug/audit-candidates.jsonl" <<'JSONLEOF'
{"candidate_id":"cand-bbbbbbbbbbbb","verdict_source":"reverse-auditor","work_item":"real-slug","file":"scripts/audit-artifact.sh","line_range":"1-1","falsifier":"f","rationale":"r","status":"pending_correctness_gate","created_at":"2026-05-24T00:00:00Z"}
JSONLEOF

EXIT18=0
ERR18=$(bash "$AUDIT" --kdir "$KDIR18" --work-item "_archive" \
  --kind omission --id cand-bbbbbbbbbbbb 2>&1 >/dev/null) || EXIT18=$?
assert_eq "'_archive' as --work-item exits 1" "$EXIT18" "1"
assert_contains "stderr names archive root rule" "$ERR18" "_archive' is the archive root"

# Confirm no phantom stub was created
if [[ ! -d "$KDIR18/_work/_archive/verdicts" ]]; then
  echo "  PASS: no phantom verdicts/ stub created under _archive/"
  PASS=$((PASS + 1))
else
  echo "  FAIL: phantom stub created at $KDIR18/_work/_archive/verdicts/"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 19: Archived work item resolves to real slug, not '_archive'
# Regression: the resolved-input.json work_item extractor at audit-artifact.sh
# now correctly captures the slug under /_work/_archive/<slug>/ rather than
# greedily matching '_archive'.
# =============================================
echo ""
echo "Test 19: archived artifact resolves to real slug in resolved-input"
KDIR19="$TEST_DIR/kdir19"
mkdir -p "$KDIR19/_work/_archive/archived-slug"
cat > "$KDIR19/_work/_archive/archived-slug/task-claims.jsonl" <<'JSONLEOF'
{"claim_id":"task-claim-arc","tier":"task-evidence","claim":"archived claim","producer_role":"worker","protocol_slot":"implementation","task_id":"task-1","phase_id":"1","scale":"implementation","source":{"file":"scripts/audit-artifact.sh","line_range":"1-20"},"falsifier":"f"}
JSONLEOF
gate_fixture "$TEST_DIR/gate19.json" '{
  "judge":"correctness-gate","judge_template_version":"arc",
  "verdicts":[{"claim_id":"task-claim-arc","verdict":"verified","evidence":"ok"}]
}'

OUT19=$(bash "$AUDIT" "$KDIR19/_work/_archive/archived-slug/task-claims.jsonl" \
  --kdir "$KDIR19" --gate-output-file "$TEST_DIR/gate19.json" 2>&1)
assert_contains "archived artifact: assertion gate completes" "$OUT19" "correctness-gate-assertion complete"
assert_file_exists "archived artifact: verdicts land under real slug, not _archive" \
  "$KDIR19/_work/_archive/archived-slug/verdicts/task-claims.jsonl"

# Confirm phantom location was NOT created
if [[ ! -d "$KDIR19/_work/_archive/verdicts" ]]; then
  echo "  PASS: archived artifact did not create _archive/verdicts/ stub"
  PASS=$((PASS + 1))
else
  echo "  FAIL: phantom stub created at $KDIR19/_work/_archive/verdicts/"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 20: Active stub shadows archive copy — --kind task-claim falls back to
# the archive per-kind file and verdicts land beside it (under _archive/).
# Regression: an empty active stub dir used to win directory-presence
# resolution, then the dispatch hard-errored on the missing per-kind file.
# =============================================
echo ""
echo "Test 20: active stub + archive copy — --kind resolves archive, verdicts follow"
KDIR20="$TEST_DIR/kdir20"
mkdir -p "$KDIR20/_work/wi-stub"
setup_archived_task_claims_fixture "$KDIR20" "wi-stub"
gate_fixture "$TEST_DIR/gate20.json" '{
  "judge":"correctness-gate","judge_template_version":"stub20",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"}]
}'

OUT20=$(bash "$AUDIT" --kdir "$KDIR20" --work-item "wi-stub" \
  --kind task-claim --id task-claim-a \
  --gate-output-file "$TEST_DIR/gate20.json" 2>&1)
assert_contains "stub-shadow: assertion gate completes" "$OUT20" "correctness-gate-assertion complete"
assert_file_exists "stub-shadow: verdicts land under archive dir" \
  "$KDIR20/_work/_archive/wi-stub/verdicts/task-claims.jsonl"
if [[ ! -d "$KDIR20/_work/wi-stub/verdicts" ]]; then
  echo "  PASS: stub-shadow: no verdicts dir created under the active stub"
  PASS=$((PASS + 1))
else
  echo "  FAIL: stub-shadow: verdicts dir created under the active stub"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 21: Archive-only work item — no active dir at all; --kind resolves the
# archive copy via the slug resolver and completes.
# =============================================
echo ""
echo "Test 21: archive-only work item via --kind/--id"
KDIR21="$TEST_DIR/kdir21"
setup_archived_task_claims_fixture "$KDIR21" "wi-arch-only"
gate_fixture "$TEST_DIR/gate21.json" '{
  "judge":"correctness-gate","judge_template_version":"arch21",
  "verdicts":[{"claim_id":"task-claim-b","verdict":"verified","evidence":"ok"}]
}'

OUT21=$(bash "$AUDIT" --kdir "$KDIR21" --work-item "wi-arch-only" \
  --kind task-claim --id task-claim-b \
  --gate-output-file "$TEST_DIR/gate21.json" 2>&1)
assert_contains "archive-only: assertion gate completes" "$OUT21" "correctness-gate-assertion complete"
assert_file_exists "archive-only: verdicts land under archive dir" \
  "$KDIR21/_work/_archive/wi-arch-only/verdicts/task-claims.jsonl"

# =============================================
# Test 22: Per-kind file present in BOTH active and archive dirs — active wins;
# live-item behavior unchanged.
# =============================================
echo ""
echo "Test 22: both-present prefers active copy"
KDIR22="$TEST_DIR/kdir22"
setup_task_claims_fixture "$KDIR22" "wi-both"
setup_archived_task_claims_fixture "$KDIR22" "wi-both"
gate_fixture "$TEST_DIR/gate22.json" '{
  "judge":"correctness-gate","judge_template_version":"both22",
  "verdicts":[{"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"}]
}'

OUT22=$(bash "$AUDIT" --kdir "$KDIR22" --work-item "wi-both" \
  --kind task-claim --id task-claim-a \
  --gate-output-file "$TEST_DIR/gate22.json" 2>&1)
assert_contains "both-present: assertion gate completes" "$OUT22" "correctness-gate-assertion complete"
assert_file_exists "both-present: verdicts land under active dir" \
  "$KDIR22/_work/wi-both/verdicts/task-claims.jsonl"
if [[ ! -d "$KDIR22/_work/_archive/wi-both/verdicts" ]]; then
  echo "  PASS: both-present: archive copy untouched"
  PASS=$((PASS + 1))
else
  echo "  FAIL: both-present: verdicts dir created under archive copy"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 23: --kind commons resolves promoted-commons.jsonl from the archive
# behind an active stub. The dispatch is closed: promoted-commons.jsonl is
# reachable only via --kind commons, never via non-kind dir refinement.
# =============================================
echo ""
echo "Test 23: --kind commons resolves archive copy behind active stub"
KDIR23="$TEST_DIR/kdir23"
mkdir -p "$KDIR23/_work/wi-commons"
mkdir -p "$KDIR23/_work/_archive/wi-commons"
cat > "$KDIR23/_work/_archive/wi-commons/promoted-commons.jsonl" <<'JSONLEOF'
{"claim_id":"commons-claim-1","tier":"reusable","claim":"promoted commons claim is auditable via --kind commons","falsifier":"Run lore audit --kind commons and confirm the assertion gate adjudicates it"}
JSONLEOF
gate_fixture "$TEST_DIR/gate23.json" '{
  "judge":"correctness-gate","judge_template_version":"comm23",
  "verdicts":[{"claim_id":"commons-claim-1","verdict":"verified","evidence":"ok"}]
}'

OUT23=$(bash "$AUDIT" --kdir "$KDIR23" --work-item "wi-commons" \
  --kind commons --id commons-claim-1 \
  --gate-output-file "$TEST_DIR/gate23.json" 2>&1)
assert_contains "commons: assertion gate completes" "$OUT23" "correctness-gate-assertion complete"
assert_file_exists "commons: verdicts land under archive dir" \
  "$KDIR23/_work/_archive/wi-commons/verdicts/promoted-commons.jsonl"

# =============================================
# Test 24: Non-kind positional slug — empty active stub falls back to the
# archive copy during dir refinement; whole-file audit runs from the archive.
# =============================================
echo ""
echo "Test 24: non-kind positional slug falls back to archive copy"
KDIR24="$TEST_DIR/kdir24"
mkdir -p "$KDIR24/_work/wi-refine"
setup_archived_task_claims_fixture "$KDIR24" "wi-refine"
gate_fixture "$TEST_DIR/gate24.json" '{
  "judge":"correctness-gate","judge_template_version":"ref24",
  "verdicts":[
    {"claim_id":"task-claim-a","verdict":"verified","evidence":"ok"},
    {"claim_id":"task-claim-b","verdict":"verified","evidence":"ok"}
  ]
}'

OUT24=$(bash "$AUDIT" "wi-refine" --kdir "$KDIR24" \
  --gate-output-file "$TEST_DIR/gate24.json" 2>&1)
assert_contains "refine-fallback: assertion gate completes" "$OUT24" "correctness-gate-assertion complete"
assert_contains "refine-fallback: both claims audited" "$OUT24" "total=2 verified=2"
# Directory positionals name the verdict file after the resolved dir's
# basename (the slug), unlike per-kind dispatch which uses the source file's.
assert_file_exists "refine-fallback: verdicts land under archive dir" \
  "$KDIR24/_work/_archive/wi-refine/verdicts/wi-refine.jsonl"

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
