#!/usr/bin/env bash
# test_trust_mechanical_checks.sh — acceptance for the orchestrator-level
# mechanical-check mirror into the trust ledger (_trust/trust-events.jsonl).
#
# Capabilities proven:
#   1. A drift-sweep run appends one mechanical-check event per classified
#      entry: result=fail for a drifted entry, pass for an unchanged one,
#      with run_id = the sweep's HEAD sha.
#   2. Re-running the sweep at the same HEAD appends nothing (event_id dedupe).
#   3. --dry-run appends nothing.
#   4. A failed ledger append warns and does NOT fail the sweep; enqueue
#      behavior is unaffected.
#   5. A commons-kind audit (injected judges) appends reanchor-omission-claim
#      and grounding-preflight events attributed to the audited entry, without
#      changing the audit's verdict behavior.
#   6. A non-commons audit appends no trust events (the ledger keys on
#      knowledge-entry identity; task-claim artifacts have none).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
SWEEP="$SCRIPTS_DIR/drift-sweep.sh"
AUDIT="$SCRIPTS_DIR/audit-artifact.sh"
PROMOTE="$SCRIPTS_DIR/lore-promote.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d -t lore-trust-mc.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

ledger_rows() {
  # ledger_rows <kdir> [<jq-ish python filter args...>] — prints TSV of
  # entry_path/check_name/result for every mechanical-check row.
  python3 - "$1" <<'PYEOF'
import json, os, sys
p = os.path.join(sys.argv[1], "_trust", "trust-events.jsonl")
if not os.path.exists(p):
    sys.exit(0)
for line in open(p):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if r.get("event") != "mechanical-check":
        continue
    pl = r["payload"]
    print("\t".join([r["entry_path"], pl["check_name"], pl["result"], pl["run_id"]]))
PYEOF
}

# =============================================
# Drift-sweep sandbox: one drifted entry, one unchanged entry
# =============================================
KDIR="$TEST_DIR/knowledge"
SRC="$TEST_DIR/src"
mkdir -p "$KDIR/conventions" "$KDIR/_work/proactive-drift-sweep-re-hash-commons-snippets-vs" "$SRC"
git -C "$SRC" init -q
git -C "$SRC" config user.email t@t
git -C "$SRC" config user.name t
echo "line one" > "$SRC/tracked.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm base
BASE_SHA=$(git -C "$SRC" rev-parse HEAD)
echo "line two" >> "$SRC/tracked.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm drift
HEAD_SHA=$(git -C "$SRC" rev-parse HEAD)

cat > "$KDIR/conventions/drifted-entry.md" <<EOF
# Drifted Entry Claim
Drifted entry claim about tracked file behavior.
<!-- learned: 2026-07-01 | confidence: high | related_files: tracked.txt | scale: subsystem | captured_at_sha: $BASE_SHA | status: current -->
EOF
cat > "$KDIR/conventions/steady-entry.md" <<EOF
# Steady Entry Claim
Steady entry claim.
<!-- learned: 2026-07-01 | confidence: high | related_files: tracked.txt | scale: subsystem | captured_at_sha: $HEAD_SHA | status: current -->
EOF

export LORE_KNOWLEDGE_DIR="$KDIR"
LEDGER="$KDIR/_trust/trust-events.jsonl"

echo "=== Trust-ledger mechanical-check emission tests ==="
echo ""
echo "Test 1: drift-sweep mirrors per-entry classifications"
bash "$SWEEP" --json --repo-root "$SRC" >/dev/null 2>&1
assert_eq "drifted entry emits result=fail" \
  "$(ledger_rows "$KDIR" | grep -c $'conventions/drifted-entry.md\tdrift-sweep\tfail')" "1"
assert_eq "unchanged entry emits result=pass" \
  "$(ledger_rows "$KDIR" | grep -c $'conventions/steady-entry.md\tdrift-sweep\tpass')" "1"
assert_eq "run_id is the sweep HEAD sha" \
  "$(ledger_rows "$KDIR" | head -1 | cut -f4)" "$HEAD_SHA"

echo ""
echo "Test 2: re-run at the same HEAD dedupes to a no-op"
BEFORE=$(ledger_rows "$KDIR" | wc -l | tr -d ' ')
bash "$SWEEP" --json --repo-root "$SRC" >/dev/null 2>&1
assert_eq "row count unchanged after same-HEAD re-run" \
  "$(ledger_rows "$KDIR" | wc -l | tr -d ' ')" "$BEFORE"

echo ""
echo "Test 3: --dry-run appends nothing"
bash "$SWEEP" --dry-run --json --repo-root "$SRC" >/dev/null 2>&1
assert_eq "row count unchanged after dry-run" \
  "$(ledger_rows "$KDIR" | wc -l | tr -d ' ')" "$BEFORE"

echo ""
echo "Test 4: a failed ledger append warns and never fails the sweep"
echo "line three" >> "$SRC/tracked.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm more
chmod 444 "$LEDGER"
SWEEP_ERR=$(bash "$SWEEP" --json --repo-root "$SRC" 2>&1 >/dev/null)
SWEEP_RC=$?
chmod 644 "$LEDGER"
assert_eq "sweep exits 0 despite append failures" "$SWEEP_RC" "0"
assert_eq "each failed append warned (2 classified entries)" \
  "$(printf '%s' "$SWEEP_ERR" | grep -c 'trust-event append failed')" "2"
assert_eq "no rows appended through the read-only ledger" \
  "$(ledger_rows "$KDIR" | wc -l | tr -d ' ')" "$BEFORE"

# =============================================
# Audit sandbox: commons-kind audit with injected judges
# =============================================
echo ""
echo "Test 5: commons audit mirrors reanchor + grounding-preflight results"
AKDIR="$TEST_DIR/audit-kdir"
SLUG="wi-mc-commons"
mkdir -p "$AKDIR/conventions" "$AKDIR/_work/$SLUG"
echo '{"format_version": 2}' > "$AKDIR/_manifest.json"
printf '{"slug":"%s"}\n' "$SLUG" > "$AKDIR/_work/$SLUG/_meta.json"

jq -nc '{
  claim_id: "mc-claim-1", tier: "reusable",
  claim: "The normalizer applies the v1 recipe before hashing.",
  producer_role: "worker", protocol_slot: "s", scale: "implementation",
  why_future_agent_cares: "y", falsifier: "If normalize() skips the v1 recipe",
  related_files: ["scripts/snippet_normalize.py"], source_artifact_ids: ["mc-claim-1"],
  work_item: "wi-mc-commons", confidence: "unaudited", captured_at_sha: "fixture-sha"
}' | LORE_KNOWLEDGE_DIR="$AKDIR" bash "$PROMOTE" --work-item "$SLUG" --category conventions >/dev/null 2>&1

ENTRY_REL=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["entry_path"])' \
  "$AKDIR/_work/$SLUG/promoted-commons.jsonl")

RA_TV=$(bash "$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/reverse-auditor.md")
OMISSION_FILE="$REPO_DIR/scripts/snippet_normalize.py"
OMISSION_RANGE="36-41"
cat > "$TEST_DIR/gate.json" <<JSON
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"mc-claim-1","verdict":"verified","evidence":"present on disk"}]}
JSON
cat > "$TEST_DIR/curator.json" <<JSON
{"judge":"curator","judge_template_version":"curatorversion","selected":[{"claim_id":"mc-claim-1","selection_rationale":"the load-bearing claim"}],"dropped":[]}
JSON
python3 - "$TEST_DIR/ra.json" "$RA_TV" "$SLUG" "$OMISSION_FILE" "$OMISSION_RANGE" "$SCRIPTS_DIR" <<'PYEOF'
import json, subprocess, sys
out, ra_tv, slug, ofile, orange, sdir = sys.argv[1:7]
lines = open(ofile).read().splitlines()
start, end = (int(x) for x in orange.split("-"))
snippet = "\n".join(lines[start - 1:end])
ohash = subprocess.run(
    ["python3", sdir + "/snippet_normalize.py", "--hash"],
    input=snippet, capture_output=True, text=True).stdout.strip()
json.dump({
    "judge": "reverse-auditor", "judge_template_version": ra_tv,
    "work_item": slug, "artifact_id": slug, "coverage_state": "covered",
    "abstention_reason": None, "insufficient_evidence_refs": None,
    "omission_claim": {
        "file": ofile, "line_range": orange, "exact_snippet": snippet,
        "normalized_snippet_hash": ohash,
        "falsifier": "a surviving curated claim already covering the v1 recipe",
        "why_it_matters": "unclaimed recipe lets regressions slip",
    },
    "created_at": "2026-07-03T00:00:00Z",
}, open(out, "w"))
PYEOF

( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    --kind commons --id mc-claim-1 --work-item "$SLUG" --kdir "$AKDIR" --json \
    --gate-output-file "$TEST_DIR/gate.json" \
    --curator-output-file "$TEST_DIR/curator.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    > "$TEST_DIR/report.json" 2>"$TEST_DIR/audit-stderr.log" )
AUDIT_RC=$?
assert_eq "commons audit exits 0" "$AUDIT_RC" "0"
assert_eq "audit verdict behavior unchanged (RA verdict=omission-claim)" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reverse_auditor"]["verdict"])' "$TEST_DIR/report.json")" \
  "omission-claim"
assert_eq "reanchor result mirrored for the audited entry" \
  "$(ledger_rows "$AKDIR" | grep -c $"$ENTRY_REL\treanchor-omission-claim\tpass")" "1"
assert_eq "grounding-preflight result mirrored for the audited entry" \
  "$(ledger_rows "$AKDIR" | grep -c $"$ENTRY_REL\tgrounding-preflight\tpass")" "1"

echo ""
echo "Test 6: non-commons audit appends no trust events"
NSLUG="wi-mc-taskclaims"
mkdir -p "$AKDIR/_work/$NSLUG"
printf '{"slug":"%s"}\n' "$NSLUG" > "$AKDIR/_work/$NSLUG/_meta.json"
SNIP=$(sed -n '36,41p' "$OMISSION_FILE")
jq -nc --arg s "$SNIP" '{
  claim_id: "ra-c1", tier: "task-evidence", claim: "normalize() applies the v1 recipe",
  producer_role: "worker", protocol_slot: "implementation", task_id: "t1", phase_id: "1",
  scale: "implementation", file: "scripts/snippet_normalize.py", line_range: "36-41",
  exact_snippet: $s, falsifier: "inspect normalize()"
}' > "$AKDIR/_work/$NSLUG/task-claims.jsonl"
cat > "$TEST_DIR/gate2.json" <<JSON
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"ra-c1","verdict":"verified","evidence":"present on disk"}]}
JSON
cat > "$TEST_DIR/curator2.json" <<JSON
{"judge":"curator","judge_template_version":"curatorversion","selected":[{"claim_id":"ra-c1","selection_rationale":"r"}],"dropped":[]}
JSON
ROWS_BEFORE=$(ledger_rows "$AKDIR" | wc -l | tr -d ' ')
( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    "$AKDIR/_work/$NSLUG/task-claims.jsonl" --kdir "$AKDIR" --json \
    --gate-output-file "$TEST_DIR/gate2.json" \
    --curator-output-file "$TEST_DIR/curator2.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    > "$TEST_DIR/report2.json" 2>>"$TEST_DIR/audit-stderr.log" )
assert_eq "non-commons audit exits 0" "$?" "0"
assert_eq "no trust events for an artifact without a knowledge entry" \
  "$(ledger_rows "$AKDIR" | wc -l | tr -d ' ')" "$ROWS_BEFORE"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]]
