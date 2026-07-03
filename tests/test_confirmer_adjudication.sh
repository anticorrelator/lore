#!/usr/bin/env bash
# test_confirmer_adjudication.sh — acceptance for Phase 5 task-9:
# adjudication ledger emission from audit-artifact.sh and the confirmer
# sampler (confirmer-sample.sh).
#
# Capabilities proven:
#   1. Sampler eligibility: held reports on active-commons entries whose last
#      non-invalidated run predates the held observation are eligible; queued
#      items, entries adjudicated since the held report, and entries with no
#      active commons row (unroutable) are skipped with counts.
#   2. Budget cap: --budget N enqueues at most N items.
#   3. Enqueued items are kind=commons, stamped selection_reason=
#      "confirmer_sample", and placed at head-of-pending.
#   4. Re-running the sampler is idempotent; --dry-run writes nothing.
#   5. A commons audit run appends one adjudication ledger event per real
#      judge verdict: verified→confirmed, contradicted→rejected,
#      unverified→nothing; (template_id, template_version) matches both the
#      registry and template-version.sh of the resolved gate template.
#   6. A non-commons audit appends no adjudication events.
#   7. The sampled item is consumed by the correctness-gate-assertion wrapper
#      path (--kind commons) without wrapper changes.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
SAMPLER="$SCRIPTS_DIR/confirmer-sample.sh"
AUDIT="$SCRIPTS_DIR/audit-artifact.sh"
PROMOTE="$SCRIPTS_DIR/lore-promote.sh"
VERIFY="$SCRIPTS_DIR/verify-append.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d -t lore-confirmer.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

adjudication_rows() {
  # adjudication_rows <kdir> — TSV of entry_path/claim_id/verdict/template_id/template_version.
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
    if r.get("event") != "adjudication":
        continue
    pl = r["payload"]
    print("\t".join([r["entry_path"], pl["claim_id"], pl["verdict"], pl["template_id"], pl["template_version"]]))
PYEOF
}

promote_claim() {
  # promote_claim <kdir> <slug> <claim_id> <claim-text>
  local kdir="$1" slug="$2" claim_id="$3" claim="$4"
  jq -nc --arg cid "$claim_id" --arg claim "$claim" --arg wi "$slug" '{
    claim_id: $cid, tier: "reusable", claim: $claim,
    producer_role: "worker", protocol_slot: "s", scale: "implementation",
    why_future_agent_cares: "y", falsifier: "inspect the cited code",
    related_files: ["scripts/snippet_normalize.py"], source_artifact_ids: [$cid],
    work_item: $wi, confidence: "unaudited", captured_at_sha: "fixture-sha"
  }' | LORE_KNOWLEDGE_DIR="$kdir" bash "$PROMOTE" --work-item "$slug" --category conventions >/dev/null 2>&1
}

entry_for_claim() {
  # entry_for_claim <kdir> <slug> <claim_id> — entry_path of the promoted row.
  python3 - "$1/_work/$2/promoted-commons.jsonl" "$3" <<'PYEOF'
import json, sys
path, want = sys.argv[1:3]
for line in open(path):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("claim_id") == want:
        print(row["entry_path"])
PYEOF
}

hold_entry() {
  # hold_entry <kdir> <entry_rel>
  bash "$VERIFY" "$2" held --source worker \
    --file "$REPO_DIR/scripts/snippet_normalize.py" --line-range "36-41" \
    --exact-snippet "def normalize" --kdir "$1" >/dev/null
}

# =============================================
# Store 1: three promoted entries + one unroutable entry
# =============================================
KDIR="$TEST_DIR/knowledge"
SLUG="wi-conf"
mkdir -p "$KDIR/conventions" "$KDIR/_work/$SLUG"
echo '{"format_version": 2}' > "$KDIR/_manifest.json"
printf '{"slug":"%s"}\n' "$SLUG" > "$KDIR/_work/$SLUG/_meta.json"

promote_claim "$KDIR" "$SLUG" "cf-c1" "The normalizer strips whitespace runs to one space."
promote_claim "$KDIR" "$SLUG" "cf-c2" "The hash covers the UTF-8 bytes of the normalized string."
promote_claim "$KDIR" "$SLUG" "cf-c3" "The hash output is lowercase hex."
E1=$(entry_for_claim "$KDIR" "$SLUG" cf-c1)
E2=$(entry_for_claim "$KDIR" "$SLUG" cf-c2)
E3=$(entry_for_claim "$KDIR" "$SLUG" cf-c3)

# Unroutable: an entry with no promoted-commons row.
cat > "$KDIR/conventions/unrouted-entry.md" <<'EOF'
# Unrouted Entry
Claim with no commons row.
<!-- learned: 2026-07-01 | scale: implementation -->
EOF

# Promote auto-enqueues one commons item per claim. Simulate cf-c1/cf-c2's
# initial audits having completed BEFORE the held reports: drop their queue
# items and write old completed runs. cf-c3's item stays pending (the
# already_queued case).
python3 - "$KDIR" <<'PYEOF'
import json, os, sys
kdir = sys.argv[1]
qp = os.path.join(kdir, "_settlement", "queue.json")
q = json.load(open(qp))
kept, dropped = [], []
for it in q["items"]:
    (kept if it.get("claim_id") == "cf-c3" else dropped).append(it)
q["items"] = kept
json.dump(q, open(qp, "w"))
runs = os.path.join(kdir, "_settlement", "runs")
os.makedirs(runs, exist_ok=True)
for i, it in enumerate(dropped):
    json.dump({"run_id": f"run-old-{i}", "item_id": it["id"], "status": "completed",
               "completed_at": "2026-06-01T00:00:00Z"},
              open(os.path.join(runs, f"run-old-{i}.json"), "w"))
PYEOF

hold_entry "$KDIR" "$E1"
hold_entry "$KDIR" "$E2"
hold_entry "$KDIR" "$E3"
hold_entry "$KDIR" "conventions/unrouted-entry.md"

echo ""
echo "Test 1: dry-run selects without writing"
QUEUE_BEFORE=$(cat "$KDIR/_settlement/queue.json")
DRY=$(bash "$SAMPLER" --budget 5 --seed 3 --dry-run --kdir "$KDIR" --json)
assert_eq "dry-run eligible = 2" "$(printf '%s' "$DRY" | jq '.eligible')" "2"
assert_eq "dry-run unroutable = 1" "$(printf '%s' "$DRY" | jq '.skipped.unroutable')" "1"
assert_eq "dry-run already_queued = 1" "$(printf '%s' "$DRY" | jq '.skipped.already_queued')" "1"
assert_eq "dry-run leaves the queue untouched" "$(cat "$KDIR/_settlement/queue.json")" "$QUEUE_BEFORE"

echo ""
echo "Test 2: budget cap — budget 1 with 2 eligible enqueues exactly 1"
OUT=$(bash "$SAMPLER" --budget 1 --seed 3 --kdir "$KDIR" --json)
assert_eq "enqueued = 1" "$(printf '%s' "$OUT" | jq '.enqueued')" "1"
assert_eq "stamped = 1" "$(printf '%s' "$OUT" | jq '.stamped')" "1"
SAMPLED_ID=$(printf '%s' "$OUT" | jq -r '.selected[0].item_id')

echo ""
echo "Test 3: enqueued item is kind=commons, stamped, head-of-pending"
FIRST_PENDING=$(python3 -c '
import json, sys
q = json.load(open(sys.argv[1]))
for it in q["items"]:
    if it.get("status") == "pending":
        print(json.dumps([it["id"], it["kind"], it.get("selection_reason")]))
        break
' "$KDIR/_settlement/queue.json")
assert_eq "sampled item leads pending with stamp" "$FIRST_PENDING" "[\"$SAMPLED_ID\", \"commons\", \"confirmer_sample\"]"

echo ""
echo "Test 4: idempotent re-runs"
OUT=$(bash "$SAMPLER" --budget 5 --seed 3 --kdir "$KDIR" --json)
assert_eq "second run enqueues the remaining candidate" "$(printf '%s' "$OUT" | jq '.enqueued')" "1"
OUT=$(bash "$SAMPLER" --budget 5 --seed 3 --kdir "$KDIR" --json)
assert_eq "third run enqueues nothing" "$(printf '%s' "$OUT" | jq '.enqueued')" "0"
assert_eq "third run reports both already queued" "$(printf '%s' "$OUT" | jq '.skipped.already_queued')" "3"

# =============================================
# Store 2: adjudicated-since-held exclusion
# =============================================
echo ""
echo "Test 5: a run newer than the held report excludes the entry"
KDIR2="$TEST_DIR/knowledge2"
mkdir -p "$KDIR2/conventions" "$KDIR2/_work/$SLUG"
echo '{"format_version": 2}' > "$KDIR2/_manifest.json"
printf '{"slug":"%s"}\n' "$SLUG" > "$KDIR2/_work/$SLUG/_meta.json"
promote_claim "$KDIR2" "$SLUG" "cf-c9" "The normalizer replaces curly quotes with ASCII."
E9=$(entry_for_claim "$KDIR2" "$SLUG" cf-c9)
hold_entry "$KDIR2" "$E9"
python3 - "$KDIR2" <<'PYEOF'
import json, os, sys
kdir = sys.argv[1]
qp = os.path.join(kdir, "_settlement", "queue.json")
q = json.load(open(qp))
item_id = q["items"][0]["id"]
q["items"] = []
json.dump(q, open(qp, "w"))
runs = os.path.join(kdir, "_settlement", "runs")
os.makedirs(runs, exist_ok=True)
json.dump({"run_id": "run-new", "item_id": item_id, "status": "completed",
           "completed_at": "2027-01-01T00:00:00Z"},
          open(os.path.join(runs, "run-new.json"), "w"))
PYEOF
OUT=$(bash "$SAMPLER" --budget 5 --kdir "$KDIR2" --json)
assert_eq "eligible = 0" "$(printf '%s' "$OUT" | jq '.eligible')" "0"
assert_eq "adjudicated_since_held = 1" "$(printf '%s' "$OUT" | jq '.skipped.adjudicated_since_held')" "1"

# =============================================
# Adjudication emission: injected-judge commons audits in store 1
# =============================================
echo ""
echo "Test 6: verified verdict emits one confirmed adjudication with registry identity"
RA_TV=$(bash "$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/reverse-auditor.md")
python3 - "$TEST_DIR/ra.json" "$RA_TV" "$SLUG" "$REPO_DIR/scripts/snippet_normalize.py" "$SCRIPTS_DIR" <<'PYEOF'
import json, subprocess, sys
out, ra_tv, slug, ofile, sdir = sys.argv[1:6]
lines = open(ofile).read().splitlines()
snippet = "\n".join(lines[35:41])
ohash = subprocess.run(["python3", sdir + "/snippet_normalize.py", "--hash"],
                       input=snippet, capture_output=True, text=True).stdout.strip()
json.dump({"judge": "reverse-auditor", "judge_template_version": ra_tv, "work_item": slug,
           "artifact_id": slug, "coverage_state": "covered", "abstention_reason": None,
           "insufficient_evidence_refs": None,
           "omission_claim": {"file": ofile, "line_range": "36-41", "exact_snippet": snippet,
                              "normalized_snippet_hash": ohash,
                              "falsifier": "a surviving curated claim already covering the recipe",
                              "why_it_matters": "unclaimed recipe lets regressions slip"},
           "created_at": "2026-07-03T00:00:00Z"}, open(out, "w"))
PYEOF
cat > "$TEST_DIR/gate-verified.json" <<'JSON'
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"cf-c1","verdict":"verified","evidence":"present on disk"}]}
JSON
cat > "$TEST_DIR/curator.json" <<'JSON'
{"judge":"curator","judge_template_version":"curatorversion","selected":[{"claim_id":"cf-c1","selection_rationale":"r"}],"dropped":[]}
JSON
( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    --kind commons --id cf-c1 --work-item "$SLUG" --kdir "$KDIR" --json \
    --gate-output-file "$TEST_DIR/gate-verified.json" \
    --curator-output-file "$TEST_DIR/curator.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    >/dev/null 2>"$TEST_DIR/audit-stderr.log" )
assert_eq "commons audit exits 0" "$?" "0"
GATE_TV=$(bash "$SCRIPTS_DIR/template-version.sh" "$REPO_DIR/agents/correctness-gate-assertion.md")
assert_eq "one confirmed adjudication for the audited entry" \
  "$(adjudication_rows "$KDIR" | grep -c $"$E1\tcf-c1\tconfirmed\tcorrectness-gate-assertion\t$GATE_TV")" "1"
REG_MATCH=$(python3 -c '
import json, sys
reg = json.load(open(sys.argv[1]))
print(sum(1 for e in reg["entries"]
          if e["template_id"] == "correctness-gate-assertion" and e["template_version"] == sys.argv[2]))
' "$KDIR/_scorecards/template-registry.json" "$GATE_TV")
assert_eq "(template_id, template_version) registered" "$REG_MATCH" "1"

echo ""
echo "Test 7: contradicted maps to rejected; unverified emits nothing"
cat > "$TEST_DIR/gate-contradicted.json" <<'JSON'
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"cf-c2","verdict":"contradicted","evidence":"code disagrees","correction":"corrected text"}]}
JSON
( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    --kind commons --id cf-c2 --work-item "$SLUG" --kdir "$KDIR" --json --skip-scorecard \
    --gate-output-file "$TEST_DIR/gate-contradicted.json" \
    --curator-output-file "$TEST_DIR/curator.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    >/dev/null 2>>"$TEST_DIR/audit-stderr.log" )
assert_eq "one rejected adjudication for the contradicted claim" \
  "$(adjudication_rows "$KDIR" | grep -c $"cf-c2\trejected")" "1"
ROWS_BEFORE=$(adjudication_rows "$KDIR" | wc -l | tr -d ' ')
cat > "$TEST_DIR/gate-unverified.json" <<'JSON'
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"cf-c3","verdict":"unverified","evidence":"could not locate"}]}
JSON
( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    --kind commons --id cf-c3 --work-item "$SLUG" --kdir "$KDIR" --json --skip-scorecard \
    --gate-output-file "$TEST_DIR/gate-unverified.json" \
    --curator-output-file "$TEST_DIR/curator.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    >/dev/null 2>>"$TEST_DIR/audit-stderr.log" )
assert_eq "unverified verdict appends no adjudication" \
  "$(adjudication_rows "$KDIR" | wc -l | tr -d ' ')" "$ROWS_BEFORE"

echo ""
echo "Test 8: non-commons audit appends no adjudication events"
NSLUG="wi-taskclaims"
mkdir -p "$KDIR/_work/$NSLUG"
printf '{"slug":"%s"}\n' "$NSLUG" > "$KDIR/_work/$NSLUG/_meta.json"
SNIP=$(sed -n '36,41p' "$REPO_DIR/scripts/snippet_normalize.py")
jq -nc --arg s "$SNIP" '{
  claim_id: "tc-c1", tier: "task-evidence", claim: "normalize() applies the v1 recipe",
  producer_role: "worker", protocol_slot: "implementation", task_id: "t1", phase_id: "1",
  scale: "implementation", file: "scripts/snippet_normalize.py", line_range: "36-41",
  exact_snippet: $s, falsifier: "inspect normalize()"
}' > "$KDIR/_work/$NSLUG/task-claims.jsonl"
cat > "$TEST_DIR/gate-tc.json" <<'JSON'
{"judge":"correctness-gate","judge_template_version":"gateversion01","verdicts":[{"claim_id":"tc-c1","verdict":"verified","evidence":"present on disk"}]}
JSON
ROWS_BEFORE=$(adjudication_rows "$KDIR" | wc -l | tr -d ' ')
( cd "$REPO_DIR" && LORE_REPO_ROOT="$REPO_DIR" bash "$AUDIT" \
    "$KDIR/_work/$NSLUG/task-claims.jsonl" --kdir "$KDIR" --json --skip-scorecard \
    --gate-output-file "$TEST_DIR/gate-tc.json" \
    --curator-output-file "$TEST_DIR/curator.json" \
    --reverse-auditor-output-file "$TEST_DIR/ra.json" \
    >/dev/null 2>>"$TEST_DIR/audit-stderr.log" )
assert_eq "non-commons audit exits 0" "$?" "0"
assert_eq "no adjudication rows for an artifact without entry identity" \
  "$(adjudication_rows "$KDIR" | wc -l | tr -d ' ')" "$ROWS_BEFORE"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]]
