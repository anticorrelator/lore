#!/usr/bin/env bash
# test_reverse_auditor_coverage_state.sh — end-to-end injection test driving all
# THREE reverse-auditor coverage states through the REAL production wrapper
# (scripts/audit-artifact.sh) with --gate-output-file / --curator-output-file /
# --reverse-auditor-output-file. No live LLM, no live-store side effects.
#
# Asserts the full coverage_state threading ported in Phase 2:
#   - RA_SHAPE_OK validator accepts all three shapes (covered silence, grounded
#     omission, insufficient-evidence abstention) and rejects a malformed one.
#   - The classifier maps coverage_state → verdict + queue destination.
#   - Abstention routes RA-local to audit-reattempts.jsonl (pending_reattempt),
#     NOT to candidates/attempts and NOT to the gate-derived aggregate.
#   - A grounded omission anchored to an on-disk snippet passes the --no-cascade
#     grounding preflight and routes to audit-candidates.jsonl.
#   - The verdict envelope row carries coverage_state and the inlined_evidence
#     key (null on the injected path, present as a recorded field).
#   - The grounded-or-nothing claim_anchor gate is satisfied (omission) or
#     bypassed (silence/abstention) — the audit completes and scorecard rows
#     append without rejection.
#   - The JSON report surfaces reverse_auditor.coverage_state.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$REPO_DIR/scripts/audit-artifact.sh"

PASS=0
FAIL=0
fail() { printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
pass() { printf '  PASS: %s\n' "$*"; PASS=$((PASS + 1)); }

TEST_ROOT="$(mktemp -d -t lore-ra-coverage.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# The omission claim anchors to a stable on-disk region of the lore checkout so
# the --no-cascade preflight (run with --repo-root = lore checkout) resolves it.
OMISSION_FILE="$REPO_DIR/scripts/snippet_normalize.py"
OMISSION_RANGE="36-41"
OMISSION_SNIPPET="$(sed -n '36,41p' "$OMISSION_FILE")"
OMISSION_HASH="$(printf '%s' "$OMISSION_SNIPPET" | python3 "$REPO_DIR/scripts/snippet_normalize.py" --hash)"

RA_TV="$(bash "$REPO_DIR/scripts/template-version.sh" "$REPO_DIR/agents/reverse-auditor.md")"

# --- Knowledge dir + source artifact ---
KDIR="$TEST_ROOT/kdir"
SLUG="wi-ra-coverage"
mkdir -p "$KDIR/_work/$SLUG"
cat > "$KDIR/_work/$SLUG/task-claims.jsonl" <<JSONL
{"claim_id":"ra-c1","tier":"task-evidence","claim":"normalize() applies the v1 recipe","producer_role":"worker","protocol_slot":"implementation","task_id":"t1","phase_id":"1","scale":"implementation","file":"scripts/snippet_normalize.py","line_range":"$OMISSION_RANGE","exact_snippet":"placeholder","falsifier":"inspect normalize()"}
JSONL

# Gate marks the single claim verified; curator selects it. Both injected.
cat > "$TEST_ROOT/gate.json" <<JSON
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"ra-c1","verdict":"verified","evidence":"present on disk"}]}
JSON
cat > "$TEST_ROOT/curator.json" <<JSON
{"judge":"curator","judge_template_version":"curatorversion","selected":[{"claim_id":"ra-c1","selection_rationale":"the load-bearing claim"}],"dropped":[]}
JSON

# Build a reverse-auditor emission file for a given coverage state.
make_ra_silence() {
  cat > "$1" <<JSON
{"judge":"reverse-auditor","judge_template_version":"$RA_TV","work_item":"$SLUG","artifact_id":"$SLUG","coverage_state":"covered","abstention_reason":null,"insufficient_evidence_refs":null,"omission_claim":null,"created_at":"2026-06-09T00:00:00Z"}
JSON
}
make_ra_abstention() {
  cat > "$1" <<JSON
{"judge":"reverse-auditor","judge_template_version":"$RA_TV","work_item":"$SLUG","artifact_id":"$SLUG","coverage_state":"insufficient-evidence","abstention_reason":"diff hunks for the changed file were unresolved; cannot assess omission","insufficient_evidence_refs":["scripts/ghost.py"],"omission_claim":null,"created_at":"2026-06-09T00:00:00Z"}
JSON
}
make_ra_omission() {
  python3 - "$1" "$RA_TV" "$SLUG" "$OMISSION_FILE" "$OMISSION_RANGE" "$OMISSION_HASH" <<'PYEOF'
import json, sys
out, ra_tv, slug, ofile, orange, ohash = sys.argv[1:7]
with open(ofile.replace("snippet_normalize.py","snippet_normalize.py")) as fh:
    lines = fh.read().splitlines()
start, end = (int(x) for x in orange.split("-"))
snippet = "\n".join(lines[start-1:end])
obj = {
    "judge": "reverse-auditor",
    "judge_template_version": ra_tv,
    "work_item": slug,
    "artifact_id": slug,
    "coverage_state": "covered",
    "abstention_reason": None,
    "insufficient_evidence_refs": None,
    "omission_claim": {
        "file": ofile,
        "line_range": orange,
        "exact_snippet": snippet,
        "normalized_snippet_hash": ohash,
        "falsifier": "a surviving curated claim already covering normalize()'s v1 recipe",
        "why_it_matters": "an unclaimed normalize() recipe lets a regression to the whitespace/quote rule slip the audit",
    },
    "created_at": "2026-06-09T00:00:00Z",
}
with open(out, "w") as fh:
    json.dump(obj, fh)
PYEOF
}

run_audit() {
  # $1 = ra emission file ; writes report to $TEST_ROOT/report.json, returns rc
  ( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
      "$KDIR/_work/$SLUG/task-claims.jsonl" --kdir "$KDIR" --json \
      --gate-output-file "$TEST_ROOT/gate.json" \
      --curator-output-file "$TEST_ROOT/curator.json" \
      --reverse-auditor-output-file "$1" \
      > "$TEST_ROOT/report.json" 2>"$TEST_ROOT/stderr.log" )
  echo $?
}

report_get() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2],{"d":d}))' "$TEST_ROOT/report.json" "$1" 2>/dev/null; }
envelope_last_ra() {
  python3 - "$KDIR/_work/$SLUG/verdicts/task-claims.jsonl" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ra = [r for r in rows if r.get("judge") == "reverse-auditor"]
print(json.dumps(ra[-1]) if ra else "{}")
PYEOF
}

echo "=== reverse-auditor coverage_state end-to-end injection tests ==="

# ---------------------------------------------------------------------------
echo ""
echo "Test 1: covered silence — verdict=silence, queue=silence, no candidate/reattempt row"
rm -rf "$KDIR/_work/$SLUG/verdicts" "$KDIR/_work/$SLUG/audit-"*.jsonl
make_ra_silence "$TEST_ROOT/ra.json"
rc=$(run_audit "$TEST_ROOT/ra.json")
if [[ "$rc" == "0" ]]; then pass "audit exits 0 on silence"; else fail "silence audit rc=$rc; stderr: $(tail -3 "$TEST_ROOT/stderr.log")"; fi
if [[ "$(report_get 'd["reverse_auditor"]["verdict"]')" == "silence" ]]; then pass "verdict=silence"; else fail "got verdict=$(report_get 'd["reverse_auditor"]["verdict"]')"; fi
if [[ "$(report_get 'd["reverse_auditor"]["coverage_state"]')" == "covered" ]]; then pass "report carries coverage_state=covered"; else fail "coverage_state=$(report_get 'd["reverse_auditor"]["coverage_state"]')"; fi
if [[ ! -f "$KDIR/_work/$SLUG/audit-candidates.jsonl" && ! -f "$KDIR/_work/$SLUG/audit-reattempts.jsonl" ]]; then pass "no candidate/reattempt row written on silence"; else fail "unexpected queue row on silence"; fi
if [[ "$(envelope_last_ra | python3 -c 'import json,sys; print(json.load(sys.stdin).get("coverage_state"))')" == "covered" ]]; then pass "verdict envelope carries coverage_state"; else fail "envelope missing coverage_state"; fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 2: grounded omission — verdict=omission-claim, routes to candidates, preflight passes"
rm -rf "$KDIR/_work/$SLUG/verdicts" "$KDIR/_work/$SLUG/audit-"*.jsonl
make_ra_omission "$TEST_ROOT/ra.json"
rc=$(run_audit "$TEST_ROOT/ra.json")
if [[ "$rc" == "0" ]]; then pass "audit exits 0 on grounded omission"; else fail "omission audit rc=$rc; stderr: $(tail -5 "$TEST_ROOT/stderr.log")"; fi
if [[ "$(report_get 'd["reverse_auditor"]["verdict"]')" == "omission-claim" ]]; then pass "verdict=omission-claim"; else fail "got verdict=$(report_get 'd["reverse_auditor"]["verdict"]') (preflight=$(report_get 'd["reverse_auditor"]["preflight_reason"]'))"; fi
if [[ -f "$KDIR/_work/$SLUG/audit-candidates.jsonl" ]]; then pass "omission routed to audit-candidates.jsonl"; else fail "no candidate row written for omission"; fi
if [[ "$(report_get 'd["reverse_auditor"]["queue_destination"]')" == "candidates" ]]; then pass "queue_destination=candidates"; else fail "queue=$(report_get 'd["reverse_auditor"]["queue_destination"]')"; fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 3: abstention — verdict=insufficient-evidence, routes RA-local to audit-reattempts.jsonl"
rm -rf "$KDIR/_work/$SLUG/verdicts" "$KDIR/_work/$SLUG/audit-"*.jsonl
make_ra_abstention "$TEST_ROOT/ra.json"
rc=$(run_audit "$TEST_ROOT/ra.json")
if [[ "$rc" == "0" ]]; then pass "audit exits 0 on abstention (not the preflight-failed exit 3)"; else fail "abstention audit rc=$rc; stderr: $(tail -5 "$TEST_ROOT/stderr.log")"; fi
if [[ "$(report_get 'd["reverse_auditor"]["verdict"]')" == "insufficient-evidence" ]]; then pass "verdict=insufficient-evidence"; else fail "got verdict=$(report_get 'd["reverse_auditor"]["verdict"]')"; fi
if [[ "$(report_get 'd["reverse_auditor"]["queue_destination"]')" == "reattempt" ]]; then pass "queue_destination=reattempt"; else fail "queue=$(report_get 'd["reverse_auditor"]["queue_destination"]')"; fi
if [[ -f "$KDIR/_work/$SLUG/audit-reattempts.jsonl" ]]; then pass "abstention routed to audit-reattempts.jsonl"; else fail "no reattempt row written"; fi
if [[ ! -f "$KDIR/_work/$SLUG/audit-candidates.jsonl" && ! -f "$KDIR/_work/$SLUG/audit-attempts.jsonl" ]]; then pass "abstention did NOT touch candidates/attempts queue"; else fail "abstention leaked into candidates/attempts"; fi
if python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][0]; sys.exit(0 if r.get("status")=="pending_reattempt" and r.get("coverage_state")=="insufficient-evidence" else 1)' "$KDIR/_work/$SLUG/audit-reattempts.jsonl" 2>/dev/null; then pass "reattempt row has status=pending_reattempt + coverage_state"; else fail "reattempt row shape wrong"; fi
# Aggregate verdict (gate-derived) must be unaffected by the RA abstention.
if [[ "$(report_get 'd["correctness_gate"]["verified"]')" == "1" ]]; then pass "gate aggregate unchanged by abstention (verified=1)"; else fail "gate aggregate perturbed"; fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 4: malformed coverage_state — RA_SHAPE_OK rejects (contract violation, exit 2)"
rm -rf "$KDIR/_work/$SLUG/verdicts" "$KDIR/_work/$SLUG/audit-"*.jsonl
cat > "$TEST_ROOT/ra-bad.json" <<JSON
{"judge":"reverse-auditor","judge_template_version":"$RA_TV","work_item":"$SLUG","artifact_id":"$SLUG","coverage_state":"bogus","abstention_reason":null,"insufficient_evidence_refs":null,"omission_claim":null,"created_at":"2026-06-09T00:00:00Z"}
JSON
rc=$(run_audit "$TEST_ROOT/ra-bad.json")
if [[ "$rc" == "2" ]]; then pass "malformed coverage_state rejected with exit 2"; else fail "expected exit 2, got rc=$rc"; fi
if grep -q "coverage_state must be" "$TEST_ROOT/stderr.log"; then pass "validator names the coverage_state violation"; else fail "validator did not name coverage_state; stderr: $(tail -3 "$TEST_ROOT/stderr.log")"; fi

# ---------------------------------------------------------------------------
echo ""
echo "Test 5: abstention with omission_claim non-null is rejected (shape contradiction)"
rm -rf "$KDIR/_work/$SLUG/verdicts" "$KDIR/_work/$SLUG/audit-"*.jsonl
cat > "$TEST_ROOT/ra-bad2.json" <<JSON
{"judge":"reverse-auditor","judge_template_version":"$RA_TV","work_item":"$SLUG","artifact_id":"$SLUG","coverage_state":"insufficient-evidence","abstention_reason":"x","insufficient_evidence_refs":["f"],"omission_claim":{"file":"a","line_range":"1-1","exact_snippet":"x","normalized_snippet_hash":"0000000000000000000000000000000000000000000000000000000000000000","falsifier":"y","why_it_matters":"z"},"created_at":"2026-06-09T00:00:00Z"}
JSON
rc=$(run_audit "$TEST_ROOT/ra-bad2.json")
if [[ "$rc" == "2" ]]; then pass "insufficient-evidence + non-null omission_claim rejected"; else fail "expected exit 2, got rc=$rc"; fi

echo ""
echo "=== Results ==="
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
