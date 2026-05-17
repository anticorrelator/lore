#!/usr/bin/env bash
# test_evidence_backfill_snippets.sh — Fixture-driven test for
# scripts/evidence-backfill-snippets.py, the one-time Tier 2 snippet+hash
# migration driver.
#
# Covers:
#   1. Recovery success: source bytes reachable via git → snippet+hash
#      populated; hash matches snippet_normalize.hash_normalized() over the
#      sliced source.
#   2. Recovery failure: unreachable sha → row marked legacy-no-snippet with
#      snippet/hash absent (null) and producer_role preserved.
#   3. State-2 → state-1 transition: row seeded with the legacy marker and a
#      recoverable file/sha — migration strips the marker and populates
#      snippet/hash (D2 transition).
#   4. Idempotency: re-running the migration on a fully-migrated store is a
#      no-op (0 backfilled, 0 marked legacy this run).
#   5. Terminal-state count: every row ends in exactly one of the two valid
#      states; INVALID-* count is zero.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
BACKFILL="$SCRIPTS_DIR/evidence-backfill-snippets.py"
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

# --- Pick a recoverable (sha, repo-relative-path, line-range, expected-snippet) ---
# Use HEAD of the lore repo and a file we know exists in tree at HEAD: the
# evidence-append.sh script. The snippet is its shebang line, which is
# stable across commits.
REPO_ROOT="$REPO_DIR"
RECOVERABLE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
RECOVERABLE_FILE_REL="scripts/evidence-append.sh"
RECOVERABLE_FILE_ABS="$REPO_ROOT/$RECOVERABLE_FILE_REL"
RECOVERABLE_LINE_RANGE="1-1"
RECOVERABLE_SOURCE=$(git -C "$REPO_ROOT" show "$RECOVERABLE_SHA:$RECOVERABLE_FILE_REL")
RECOVERABLE_SNIPPET=$(printf '%s' "$RECOVERABLE_SOURCE" | sed -n '1,1p')
EXPECTED_HASH=$(printf '%s' "$RECOVERABLE_SNIPPET" | python3 "$NORMALIZE_PY" --hash)

UNREACHABLE_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# --- Build a fresh KDIR with a seed _work/test-slug/task-claims.jsonl ---
KDIR="$TEST_DIR/kdir"
mkdir -p "$KDIR/_work/active-slug" "$KDIR/_work/_archive/archived-slug"

build_row() {
  python3 - "$@" <<'PYEOF'
import json, sys
base = {
    "claim_id": "TO-OVERRIDE",
    "tier": "task-evidence",
    "claim": "claim text",
    "producer_role": "worker",
    "protocol_slot": "implement-phase-2",
    "task_id": "task-1",
    "phase_id": "phase-2",
    "scale": "implementation",
    "file": "TO-OVERRIDE",
    "line_range": "TO-OVERRIDE",
    "falsifier": "f",
    "why_this_work_needs_it": "w",
    "captured_at_sha": "TO-OVERRIDE",
    "change_context": {
        "diff_ref": None,
        "changed_files": ["TO-OVERRIDE"],
        "summary": "s",
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

# Row 1: recoverable (state-3 → state-1 backfill)
ROW_RECOVERABLE=$(build_row \
  "claim_id=\"recoverable\"" \
  "producer_role=\"worker\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"$RECOVERABLE_LINE_RANGE\"" \
  "captured_at_sha=\"$RECOVERABLE_SHA\"" \
  "change_context={\"diff_ref\":null,\"changed_files\":[\"$RECOVERABLE_FILE_ABS\"],\"summary\":\"s\"}")

# Row 2: unrecoverable (state-3 → state-2 mark-legacy). Use the unreachable SHA.
ROW_UNRECOVERABLE=$(build_row \
  "claim_id=\"unrecoverable\"" \
  "producer_role=\"researcher\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"1-1\"" \
  "captured_at_sha=\"$UNREACHABLE_SHA\"" \
  "change_context={\"diff_ref\":null,\"changed_files\":[\"$RECOVERABLE_FILE_ABS\"],\"summary\":\"s\"}")

# Row 3: already-compliant (state-1 — should be skipped)
ALREADY_SNIPPET="print('hello')"
ALREADY_HASH=$(printf '%s' "$ALREADY_SNIPPET" | python3 "$NORMALIZE_PY" --hash)
ROW_ALREADY=$(build_row \
  "claim_id=\"already\"" \
  "producer_role=\"advisor\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"1-1\"" \
  "captured_at_sha=\"$RECOVERABLE_SHA\"" \
  "exact_snippet=\"$ALREADY_SNIPPET\"" \
  "normalized_snippet_hash=\"$ALREADY_HASH\"" \
  "change_context={\"diff_ref\":null,\"changed_files\":[\"$RECOVERABLE_FILE_ABS\"],\"summary\":\"s\"}")

# Row 4 (in archive): state-2 → state-1 transition. Seed with the legacy
# marker and a *recoverable* sha; migration should strip the marker and
# populate snippet/hash.
ROW_TRANSITION=$(build_row \
  "claim_id=\"transition\"" \
  "producer_role=\"spec-lead\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"$RECOVERABLE_LINE_RANGE\"" \
  "captured_at_sha=\"$RECOVERABLE_SHA\"" \
  "provenance=\"legacy-no-snippet\"" \
  "change_context={\"diff_ref\":null,\"changed_files\":[\"$RECOVERABLE_FILE_ABS\"],\"summary\":\"s\"}")

printf '%s\n%s\n%s\n' "$ROW_RECOVERABLE" "$ROW_UNRECOVERABLE" "$ROW_ALREADY" \
  | jq -c '.' > "$KDIR/_work/active-slug/task-claims.jsonl"
printf '%s\n' "$ROW_TRANSITION" \
  | jq -c '.' > "$KDIR/_work/_archive/archived-slug/task-claims.jsonl"

echo "Setup: seeded $KDIR with 4 rows across active + archive"

echo ""
echo "Test 1: First-pass migration"
REPORT=$(python3 "$BACKFILL" --kdir "$KDIR" --repo-root "$REPO_ROOT" 2>/dev/null)
echo "$REPORT" | head -20
BACKFILLED=$(printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["backfilled"])')
MARKED=$(printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["marked_legacy"])')
COMPLIANT=$(printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["already_compliant"])')
TRANSITIONS=$(printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state2_to_state1_transitions"])')
FAILED=$(printf '%s' "$REPORT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["update_failed"])')

assert_eq "backfilled count = 1 (the recoverable row)" "$BACKFILLED" "1"
assert_eq "marked_legacy count = 1 (the unrecoverable row)" "$MARKED" "1"
assert_eq "already_compliant count = 1" "$COMPLIANT" "1"
assert_eq "state2_to_state1_transitions count = 1" "$TRANSITIONS" "1"
assert_eq "update_failed count = 0" "$FAILED" "0"

echo ""
echo "Test 2: Snippet+hash match snippet_normalize for the recoverable row"
RECOVERED_SNIPPET=$(jq -r 'select(.claim_id=="recoverable") | .exact_snippet' "$KDIR/_work/active-slug/task-claims.jsonl")
RECOVERED_HASH=$(jq -r 'select(.claim_id=="recoverable") | .normalized_snippet_hash' "$KDIR/_work/active-slug/task-claims.jsonl")
COMPUTED_HASH=$(printf '%s' "$RECOVERED_SNIPPET" | python3 "$NORMALIZE_PY" --hash)
assert_eq "recovered snippet matches expected source" "$RECOVERED_SNIPPET" "$RECOVERABLE_SNIPPET"
assert_eq "recovered hash matches snippet_normalize over the snippet" "$RECOVERED_HASH" "$COMPUTED_HASH"
assert_eq "recovered hash matches the precomputed expected hash" "$RECOVERED_HASH" "$EXPECTED_HASH"

echo ""
echo "Test 3: Unrecoverable row is marked legacy; producer_role preserved"
PROV=$(jq -r 'select(.claim_id=="unrecoverable") | .provenance' "$KDIR/_work/active-slug/task-claims.jsonl")
SNIPPET=$(jq -r 'select(.claim_id=="unrecoverable") | .exact_snippet' "$KDIR/_work/active-slug/task-claims.jsonl")
HASH=$(jq -r 'select(.claim_id=="unrecoverable") | .normalized_snippet_hash' "$KDIR/_work/active-slug/task-claims.jsonl")
ROLE=$(jq -r 'select(.claim_id=="unrecoverable") | .producer_role' "$KDIR/_work/active-slug/task-claims.jsonl")
assert_eq "provenance set to legacy-no-snippet" "$PROV" "legacy-no-snippet"
assert_eq "exact_snippet is null (absent)" "$SNIPPET" "null"
assert_eq "normalized_snippet_hash is null (absent)" "$HASH" "null"
assert_eq "producer_role preserved (researcher)" "$ROLE" "researcher"

echo ""
echo "Test 4: Already-compliant row is unchanged"
COMPLIANT_SNIPPET=$(jq -r 'select(.claim_id=="already") | .exact_snippet' "$KDIR/_work/active-slug/task-claims.jsonl")
COMPLIANT_HASH=$(jq -r 'select(.claim_id=="already") | .normalized_snippet_hash' "$KDIR/_work/active-slug/task-claims.jsonl")
COMPLIANT_ROLE=$(jq -r 'select(.claim_id=="already") | .producer_role' "$KDIR/_work/active-slug/task-claims.jsonl")
assert_eq "compliant row's snippet preserved" "$COMPLIANT_SNIPPET" "$ALREADY_SNIPPET"
assert_eq "compliant row's hash preserved" "$COMPLIANT_HASH" "$ALREADY_HASH"
assert_eq "compliant row's producer_role preserved (advisor)" "$COMPLIANT_ROLE" "advisor"

echo ""
echo "Test 5: State-2 → state-1 transition cleared the legacy marker"
T_PROV=$(jq -r '.provenance' "$KDIR/_work/_archive/archived-slug/task-claims.jsonl")
T_SNIPPET=$(jq -r '.exact_snippet' "$KDIR/_work/_archive/archived-slug/task-claims.jsonl")
T_HASH=$(jq -r '.normalized_snippet_hash' "$KDIR/_work/_archive/archived-slug/task-claims.jsonl")
T_ROLE=$(jq -r '.producer_role' "$KDIR/_work/_archive/archived-slug/task-claims.jsonl")
# null in JSONL appears as the JSON null literal.
assert_eq "transition row provenance is null (marker stripped)" "$T_PROV" "null"
assert_eq "transition row snippet populated" "$T_SNIPPET" "$RECOVERABLE_SNIPPET"
assert_eq "transition row hash populated" "$T_HASH" "$EXPECTED_HASH"
assert_eq "transition row producer_role preserved (spec-lead)" "$T_ROLE" "spec-lead"

echo ""
echo "Test 6: Idempotent re-run is a no-op"
REPORT2=$(python3 "$BACKFILL" --kdir "$KDIR" --repo-root "$REPO_ROOT" 2>/dev/null)
B2=$(printf '%s' "$REPORT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["backfilled"])')
M2=$(printf '%s' "$REPORT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["marked_legacy"])')
T2=$(printf '%s' "$REPORT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["state2_to_state1_transitions"])')
ALSL2=$(printf '%s' "$REPORT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["already_legacy_skipped"])')
C2=$(printf '%s' "$REPORT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["already_compliant"])')
assert_eq "re-run backfilled = 0" "$B2" "0"
assert_eq "re-run marked_legacy = 0" "$M2" "0"
assert_eq "re-run transitions = 0" "$T2" "0"
assert_eq "re-run already_legacy_skipped = 1 (the unrecoverable row)" "$ALSL2" "1"
assert_eq "re-run already_compliant = 3 (the 3 fast-path rows)" "$C2" "3"

echo ""
echo "Test 7: Terminal-state count check across the test KDIR"
INVALID_COUNT=$(find "$KDIR/_work" -name task-claims.jsonl -print0 \
  | xargs -0 cat \
  | python3 -c '
import json, sys, collections
c = collections.Counter()
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        r=json.loads(line)
    except json.JSONDecodeError:
        c["malformed"] += 1; continue
    has_snip = bool(r.get("exact_snippet"))
    has_hash = bool(r.get("normalized_snippet_hash"))
    prov = r.get("provenance") or ""
    if prov == "legacy-no-snippet" and not has_snip and not has_hash:
        c["state-2"] += 1
    elif has_snip and has_hash and not prov:
        c["state-1"] += 1
    elif has_snip and has_hash and prov == "legacy-no-snippet":
        c["INVALID-mixed"] += 1
    else:
        c["INVALID-incomplete"] += 1
print(c["INVALID-mixed"] + c["INVALID-incomplete"] + c["malformed"])
')
assert_eq "INVALID-* count is zero across the test KDIR" "$INVALID_COUNT" "0"

echo ""
echo "Test 8: Verdict-envelope quarantine — pre-mixed envelopes are split into a sidecar"
# Build a fresh KDIR with a producer row commingled with verdict envelopes.
QKDIR="$TEST_DIR/kdir-q"
mkdir -p "$QKDIR/_work/mixed-slug"
ROW_PRODUCER=$(build_row \
  "claim_id=\"producer-row-1\"" \
  "producer_role=\"worker\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"$RECOVERABLE_LINE_RANGE\"" \
  "captured_at_sha=\"$RECOVERABLE_SHA\"" \
  "change_context={\"diff_ref\":null,\"changed_files\":[\"$RECOVERABLE_FILE_ABS\"],\"summary\":\"s\"}")
ENVELOPE_1='{"artifact_id":"a1","judge":"correctness-gate","judge_run_at":"2026-05-11T07:18:28Z","judge_template_version":"73ed9a0559a4","verdicts":[{"claim_id":"x","verdict":"verified"}]}'
ENVELOPE_2='{"artifact_id":"a2","judge":"reverse-auditor","judge_run_at":"2026-05-12T08:00:00Z","judge_template_version":"abcdef012345"}'
printf '%s\n%s\n%s\n' "$ROW_PRODUCER" "$ENVELOPE_1" "$ENVELOPE_2" \
  | jq -c '.' > "$QKDIR/_work/mixed-slug/task-claims.jsonl"

# Run the migration on this fresh KDIR.
REPORT_Q=$(python3 "$BACKFILL" --kdir "$QKDIR" --repo-root "$REPO_ROOT" 2>/dev/null)
Q_COUNT=$(printf '%s' "$REPORT_Q" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantined_verdict_envelopes"])')
assert_eq "quarantined count = 2" "$Q_COUNT" "2"

# Verify the producer file no longer contains the envelopes.
PROD_LINES=$(wc -l < "$QKDIR/_work/mixed-slug/task-claims.jsonl" | tr -d ' ')
assert_eq "producer file has 1 remaining line (the producer row)" "$PROD_LINES" "1"
REMAINING_CLAIM_ID=$(jq -r '.claim_id' "$QKDIR/_work/mixed-slug/task-claims.jsonl")
assert_eq "remaining producer row is the one we seeded" "$REMAINING_CLAIM_ID" "producer-row-1"

# Verify the sidecar exists and contains both envelopes.
SIDECAR="$QKDIR/_work/mixed-slug/verdict-envelopes.jsonl"
[[ -f "$SIDECAR" ]] && SIDECAR_EXISTS=yes || SIDECAR_EXISTS=no
assert_eq "verdict-envelopes.jsonl sidecar was created" "$SIDECAR_EXISTS" "yes"
SIDECAR_LINES=$(wc -l < "$SIDECAR" | tr -d ' ')
assert_eq "sidecar contains 2 envelopes" "$SIDECAR_LINES" "2"

echo ""
echo "Test 9: Quarantine is idempotent — re-running on a cleaned file is a no-op for envelopes"
REPORT_Q2=$(python3 "$BACKFILL" --kdir "$QKDIR" --repo-root "$REPO_ROOT" 2>/dev/null)
Q_COUNT2=$(printf '%s' "$REPORT_Q2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["quarantined_verdict_envelopes"])')
assert_eq "re-run quarantined count = 0 (idempotent)" "$Q_COUNT2" "0"
SIDECAR_LINES2=$(wc -l < "$SIDECAR" | tr -d ' ')
assert_eq "sidecar unchanged on re-run (still 2 envelopes)" "$SIDECAR_LINES2" "2"

echo ""
echo "Test 11: Scale-alias remap — pre-Phase-1 row with deprecated scale='architectural' is renamed to 'architecture' at mark-legacy boundary"
SKDIR="$TEST_DIR/kdir-s"
mkdir -p "$SKDIR/_work/scale-slug"
ROW_ARCHITECTURAL=$(build_row \
  "claim_id=\"deprecated-scale\"" \
  "producer_role=\"worker\"" \
  "scale=\"architectural\"" \
  "file=\"$RECOVERABLE_FILE_ABS\"" \
  "line_range=\"1-1\"" \
  "captured_at_sha=\"$RECOVERABLE_SHA\"" \
  "change_context=__DELETE__")
printf '%s\n' "$ROW_ARCHITECTURAL" | jq -c '.' > "$SKDIR/_work/scale-slug/task-claims.jsonl"
python3 "$BACKFILL" --kdir "$SKDIR" --repo-root "$REPO_ROOT" >/dev/null 2>&1
NEW_SCALE=$(jq -r '.scale' "$SKDIR/_work/scale-slug/task-claims.jsonl")
NEW_PROV=$(jq -r '.provenance' "$SKDIR/_work/scale-slug/task-claims.jsonl")
assert_eq "scale was remapped to canonical 'architecture'" "$NEW_SCALE" "architecture"
assert_eq "row was marked legacy" "$NEW_PROV" "legacy-no-snippet"

echo ""
echo "Test 10: row_is_verdict_envelope shape detector"
# Module filename has dashes, so import via importlib spec directly.
DETECT_TEST=$(BACKFILL="$BACKFILL" python3 <<'PYEOF'
import os, importlib.util
spec = importlib.util.spec_from_file_location("ebs", os.environ["BACKFILL"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
producer = {"claim_id": "c1", "tier": "task-evidence", "judge": "value-not-trigger"}
envelope = {"artifact_id": "a1", "judge": "correctness-gate", "verdicts": []}
print("producer:", m.row_is_verdict_envelope(producer))
print("envelope:", m.row_is_verdict_envelope(envelope))
PYEOF
)
PRODUCER_RESULT=$(printf '%s' "$DETECT_TEST" | awk '/^producer:/ {print $2}')
ENVELOPE_RESULT=$(printf '%s' "$DETECT_TEST" | awk '/^envelope:/ {print $2}')
assert_eq "producer row (has claim_id) NOT detected as envelope even with judge field" "$PRODUCER_RESULT" "False"
assert_eq "verdict envelope IS detected" "$ENVELOPE_RESULT" "True"

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
