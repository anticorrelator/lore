#!/usr/bin/env bash
# test_evolve_recurring_failure_gate.sh — /evolve recurring-failure gate (Phase 3)
#
# Validates the SKILL.md spec change introduced in Phase 3 of work item
# restore-evolve-gates-add-recurring-failure-path-se. Two layers:
#
# 1. Documentation contract — the SKILL.md text contains the required
#    structures (4-row matrix, Step 5.x sub-section, CLUSTER REVIEW block,
#    two-run lifecycle, K=3 threshold, accepted-cluster artifact format).
#
# 2. Behavioral simulation — fixture journal rows + accepted-cluster JSONL
#    are walked by the same candidate-cluster algorithm the spec describes
#    (raw clustering pass over retro-evolution rows, K boundary, two-run
#    lifecycle): K=2 → no candidate; K=3 → candidate; maintainer accepts in
#    "run N" → row persisted; gate in "run N+1" reads the row and clears
#    the staged suggestion.
#
# The persistence helper (accepted-cluster-append.sh) is a Phase 5
# dependency that does not yet exist; the test simulates its behavior
# directly via JSONL writes against a temp KDIR. When that helper lands,
# this test should be re-pointed to invoke it instead of the inline writer.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$REPO_DIR/skills/evolve/SKILL.md"

TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
JOURNAL="$KDIR/_meta/effectiveness-journal.jsonl"
ACCEPTED="$KDIR/_evolve/accepted-clusters.jsonl"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  [[ -n "${2:-}" ]] && echo "    $2"
  FAIL=$((FAIL + 1))
}

assert_grep() {
  local label="$1" pattern="$2" file="$3"
  if grep -qE -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label" "Pattern not found in $file: $pattern"
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "Expected: $expected | Actual: $actual"
  fi
}

# Read a top-level field from a JSON object on stdin. Avoids in-line
# `python3 -c "import json,sys;..."` quoting traps inside `$(...)`.
json_field() {
  local field="$1"
  python3 -c 'import json, sys; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$field"
}

# Read len(top-level list) from JSON-on-stdin.
json_len() {
  python3 -c 'import json, sys; print(len(json.load(sys.stdin)))'
}

# Read a path through a JSON object on stdin via python expression.
# Usage: echo '{"a":[1,2,3]}' | json_eval 'len(d["a"])'
json_eval() {
  local expr="$1"
  python3 -c 'import json, sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$expr"
}

setup_store() {
  rm -rf "$KDIR"
  mkdir -p "$KDIR/_meta" "$KDIR/_evolve"
  echo '{"format_version": 2}' > "$KDIR/_manifest.json"
  : > "$JOURNAL"
  : > "$ACCEPTED"
}

# Append a retro-evolution journal row with the structured Target/Change-type
# observation. Matches the format documented in skills/retro/SKILL.md:1368-1373
# and parsed by scripts/retro-export-collect-retros.py:97.
write_retro_evolution_row() {
  local timestamp="$1" work_item="$2" target="$3" change_type="$4" suggestion="$5"
  local context="${6-}"
  [[ -z "$context" ]] && context="retro-evolution: $work_item"
  python3 - "$JOURNAL" "$timestamp" "$work_item" "$target" "$change_type" "$suggestion" "$context" <<'PY'
import json, sys
journal, ts, wi, tgt, ct, sug, ctx = sys.argv[1:8]
obs = f"Target: {tgt} | Change type: {ct} | Section: anywhere | Suggestion: {sug} | Evidence: fixture"
row = {
    "timestamp": ts,
    "observation": obs,
    "context": ctx,
    "role": "retro-evolution",
    "git_branch": "main",
    "work_item": wi,
}
with open(journal, "a") as f:
    f.write(json.dumps(row) + "\n")
PY
}

# Inline candidate-cluster formation: bucket retro-evolution rows by
# (target, change_type), counting distinct work_items. Excludes rows whose
# context starts with "retro-backfill:" (those are handled by the
# pre-clustered consumption pass per Step 5.x).
compute_candidate_clusters() {
  local k_threshold="$1"
  python3 - "$JOURNAL" "$k_threshold" <<'PY'
import json, re, sys
from collections import defaultdict

path, k = sys.argv[1], int(sys.argv[2])
buckets = defaultdict(set)  # (target, change_type) -> {work_item, ...}
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("role") != "retro-evolution":
            continue
        if (e.get("context") or "").startswith("retro-backfill:"):
            continue
        obs = e.get("observation", "")
        tgt_m = re.search(r"Target:\s*([^|]+)", obs)
        ct_m = re.search(r"Change type:\s*([^|]+)", obs)
        wi = e.get("work_item")
        if not (tgt_m and ct_m and wi):
            continue
        key = (tgt_m.group(1).strip(), ct_m.group(1).strip())
        buckets[key].add(wi)

candidates = [
    {"target": t, "change_type": ct, "work_items": sorted(wis), "K": len(wis)}
    for (t, ct), wis in buckets.items()
    if len(wis) >= k
]
print(json.dumps(candidates))
PY
}

# Simulate the maintainer-accept side of Step 6 CLUSTER REVIEW: append an
# accepted_cluster row to _evolve/accepted-clusters.jsonl. This is the shape
# the SKILL.md Step 5.x section documents; the production sole-writer
# (accepted-cluster-append.sh) lands with Phase 5.
write_accepted_cluster() {
  local target="$1" change_type="$2" work_items_csv="$3" accepted_at_run_id="$4" decision="${5:-merge}"
  python3 - "$ACCEPTED" "$target" "$change_type" "$work_items_csv" "$accepted_at_run_id" "$decision" <<'PY'
import hashlib, json, sys
from datetime import datetime, timezone

path, target, ct, wis_csv, run_id, decision = sys.argv[1:7]
wis = sorted([w.strip() for w in wis_csv.split(",") if w.strip()])
key = target + "|" + "|".join(sorted([ct])) + "|" + "|".join(wis)
cluster_id = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
row = {
    "cluster_id": cluster_id,
    "target": target,
    "change_types": [ct],
    "work_items": wis,
    "journal_row_refs": [{"timestamp": "fixture", "work_item": w} for w in wis],
    "accepted_at": datetime.now(timezone.utc).isoformat(),
    "accepted_at_run_id": run_id,
    "accepted_by_maintainer_decision": decision,
    "consumed_at_run_id": None,
}
with open(path, "a") as f:
    f.write(json.dumps(row) + "\n")
print(cluster_id)
PY
}

# Simulate the Step 5 recurring-failure gate evaluation: scan
# _evolve/accepted-clusters.jsonl for an unconsumed row matching
# (target, change_type), mark it consumed, return clear|no_op + reason.
evaluate_recurring_failure_gate() {
  local target="$1" change_type="$2" current_run_id="$3"
  python3 - "$ACCEPTED" "$target" "$change_type" "$current_run_id" <<'PY'
import json, sys

path, target, ct, current_run = sys.argv[1:5]
rows = []
hit_index = -1
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            rows.append(r)
except FileNotFoundError:
    print(json.dumps({"verdict": "no_op", "reason": "no_accepted_cluster"}))
    sys.exit(0)

for i, r in enumerate(rows):
    if r.get("target") != target:
        continue
    if ct not in (r.get("change_types") or []):
        continue
    if r.get("consumed_at_run_id") is not None:
        continue
    if r.get("accepted_at_run_id") == current_run:
        # same-run re-entry forbidden
        continue
    hit_index = i
    break

if hit_index < 0:
    print(json.dumps({"verdict": "no_op", "reason": "no_accepted_cluster"}))
    sys.exit(0)

rows[hit_index]["consumed_at_run_id"] = current_run
with open(path, "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")

print(json.dumps({
    "verdict": "clear",
    "cluster_id": rows[hit_index]["cluster_id"],
    "K": len(rows[hit_index]["work_items"]),
}))
PY
}

echo "=== /evolve recurring-failure gate (Phase 3) ==="

# =========================================================================
# Layer 1: Documentation contract — verify SKILL.md has the required shape
# =========================================================================
echo ""
echo "Test 1: Step 5 evidence-class matrix has four rows"
# Count rows starting with `| ` between matrix header and the trailing
# blank line that closes the table.
ROW_COUNT=$(awk '
  /^\| `change_type` \| Gate path \| Required evidence \|/ { in_table=1; next }
  in_table && /^\|---/ { next }
  in_table && /^\| / { count++ ; next }
  in_table && /^[^|]/ { exit }
  END { print count }
' "$SKILL_MD")
assert_eq "matrix has 4 rows" "$ROW_COUNT" "4"

assert_grep "matrix routes recurring-failure" "^\| \`recurring-failure\`" "$SKILL_MD"

echo ""
echo "Test 2: Step 5.x recurring-failure gate sub-section exists with routing-gate properties"
assert_grep "Step 5.x heading present" "\*\*Recurring-failure gate\*\*" "$SKILL_MD"
assert_grep "names Inputs"             "\*\*Inputs:\*\*"               "$SKILL_MD"
assert_grep "names Success route"      "\*\*Success route:\*\*"        "$SKILL_MD"
assert_grep "names Conservative fallback" "\*\*Conservative fallback:\*\*" "$SKILL_MD"
assert_grep "names Lifecycle constraints" "\*\*Lifecycle constraints:\*\*" "$SKILL_MD"
assert_grep "K threshold table mentions K == 3" "K == 3"     "$SKILL_MD"
assert_grep "two-run lifecycle table" "Run N\+1"             "$SKILL_MD"
assert_grep "accepted-cluster artifact path" "_evolve/accepted-clusters.jsonl" "$SKILL_MD"
assert_grep "no_accepted_cluster reason"     "no_accepted_cluster"     "$SKILL_MD"
assert_grep "raw-clustering pass excludes retro-backfill" "retro-backfill:" "$SKILL_MD"
assert_grep "consumption pass over retro-backfill: rows"   "consumption pass" "$SKILL_MD"

echo ""
echo "Test 3: Step 6 CLUSTER REVIEW block with member list and y/edit/split/n prompt"
assert_grep "CLUSTER REVIEW block heading"  "CLUSTER REVIEW"            "$SKILL_MD"
assert_grep "prompt grammar y/edit/split/n" "\[y/edit/split/n\]"        "$SKILL_MD"
assert_grep "member list shows timestamps"  "<timestamp>"               "$SKILL_MD"
assert_grep "member list shows work_item slugs" "<work_item slug>"      "$SKILL_MD"
assert_grep "representative Evidence line"  "Representative Evidence"   "$SKILL_MD"

echo ""
echo "Test 4: Step 5a sunset table unchanged (3 classification rows)"
SUNSET_ROWS=$(awk '
  /^\| Classification \| Definition \| Sunset required\?/ { in_table=1; next }
  in_table && /^\|---/ { next }
  in_table && /^\| / { count++; next }
  in_table && /^[^|]/ { exit }
  END { print count }
' "$SKILL_MD")
assert_eq "Step 5a sunset table has 3 rows" "$SUNSET_ROWS" "3"

# =========================================================================
# Layer 2: Behavioral simulation — fixture journal + accepted-cluster JSONL
# =========================================================================
echo ""
echo "Test 5: Candidate-cluster formation — K=2 sub-threshold (no candidate)"
setup_store
write_retro_evolution_row "2026-05-10T00:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T01:00:00Z" "wi-beta"  "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "K=2 → no candidate" "$(echo "$CANDIDATES" | json_len)" "0"

echo ""
echo "Test 6: Candidate-cluster formation — K=3 boundary (candidate)"
setup_store
write_retro_evolution_row "2026-05-10T00:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T01:00:00Z" "wi-beta"  "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T02:00:00Z" "wi-gamma" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "K=3 → exactly one candidate" "$(echo "$CANDIDATES" | json_len)" "1"
assert_eq "candidate target"    "$(echo "$CANDIDATES" | json_eval 'd[0]["target"]')" "skills/foo/SKILL.md"
assert_eq "candidate change_type" "$(echo "$CANDIDATES" | json_eval 'd[0]["change_type"]')" "ceiling-raise"
assert_eq "candidate K"         "$(echo "$CANDIDATES" | json_eval 'd[0]["K"]')" "3"

echo ""
echo "Test 6b: K counts distinct work_items, not raw rows"
setup_store
# wi-alpha generates 5 rows on the same target/change_type — still K=1
for i in 1 2 3 4 5; do
  write_retro_evolution_row "2026-05-10T0${i}:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
done
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "5 rows from same wi → no candidate (K=1)" "$(echo "$CANDIDATES" | json_len)" "0"

echo ""
echo "Test 6c: retro-backfill: rows are excluded from raw-clustering pass"
setup_store
write_retro_evolution_row "2026-05-10T00:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-1"
write_retro_evolution_row "2026-05-10T01:00:00Z" "wi-beta"  "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-1"
write_retro_evolution_row "2026-05-10T02:00:00Z" "wi-gamma" "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-1"
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "all-backfill rows → 0 raw candidates" "$(echo "$CANDIDATES" | json_len)" "0"

echo ""
echo "Test 7: Maintainer-acceptance persistence (run N writes accepted-clusters.jsonl)"
setup_store
write_retro_evolution_row "2026-05-10T00:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T01:00:00Z" "wi-beta"  "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T02:00:00Z" "wi-gamma" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
CLUSTER_ID=$(write_accepted_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-alpha,wi-beta,wi-gamma" "run-N" "merge")
assert_eq "accepted-clusters has one row" "$(wc -l < "$ACCEPTED" | tr -d ' ')" "1"
ROW=$(cat "$ACCEPTED")
assert_eq "cluster_id matches return value"          "$(echo "$ROW" | json_field cluster_id)" "$CLUSTER_ID"
assert_eq "target persisted"                         "$(echo "$ROW" | json_field target)" "skills/foo/SKILL.md"
assert_eq "decision persisted"                       "$(echo "$ROW" | json_field accepted_by_maintainer_decision)" "merge"
assert_eq "accepted_at_run_id persisted"             "$(echo "$ROW" | json_field accepted_at_run_id)" "run-N"
assert_eq "consumed_at_run_id starts null (empty)"   "$(echo "$ROW" | json_field consumed_at_run_id)" ""
assert_eq "work_items persisted (sorted)"            "$(echo "$ROW" | python3 -c 'import json, sys; print(",".join(json.load(sys.stdin)["work_items"]))')" "wi-alpha,wi-beta,wi-gamma"

echo ""
echo "Test 8: Run-N+1 consumption — gate clears suggestion and marks row consumed"
# Continuing from Test 7's state: row exists, consumed_at_run_id is null,
# accepted_at_run_id="run-N". Now invoke the gate as run-N+1.
RESULT=$(evaluate_recurring_failure_gate "skills/foo/SKILL.md" "ceiling-raise" "run-N+1")
assert_eq "gate clears in run N+1"     "$(echo "$RESULT" | json_field verdict)" "clear"
assert_eq "gate echoes K=3"            "$(echo "$RESULT" | json_field K)" "3"
ROW=$(cat "$ACCEPTED")
assert_eq "consumed_at_run_id populated" "$(echo "$ROW" | json_field consumed_at_run_id)" "run-N+1"

echo ""
echo "Test 9: Same-run re-entry forbidden (run-N cannot consume what run-N accepted)"
setup_store
write_accepted_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-alpha,wi-beta,wi-gamma" "run-N" "merge" >/dev/null
RESULT=$(evaluate_recurring_failure_gate "skills/foo/SKILL.md" "ceiling-raise" "run-N")
assert_eq "same-run gate → no_op"      "$(echo "$RESULT" | json_field verdict)" "no_op"
assert_eq "reason is no_accepted_cluster" "$(echo "$RESULT" | json_field reason)" "no_accepted_cluster"

echo ""
echo "Test 10: Already-consumed cluster does not re-fire"
# After Test 8, the row is consumed. A second run-N+2 invocation must no_op.
setup_store
write_accepted_cluster "skills/foo/SKILL.md" "ceiling-raise" "wi-alpha,wi-beta,wi-gamma" "run-N" "merge" >/dev/null
evaluate_recurring_failure_gate "skills/foo/SKILL.md" "ceiling-raise" "run-N+1" >/dev/null
RESULT=$(evaluate_recurring_failure_gate "skills/foo/SKILL.md" "ceiling-raise" "run-N+2")
assert_eq "consumed cluster does not re-fire" "$(echo "$RESULT" | json_field verdict)" "no_op"

echo ""
echo "Test 11: No matching accepted cluster → no_op (no silent fallback)"
setup_store
RESULT=$(evaluate_recurring_failure_gate "skills/bar/SKILL.md" "ceiling-raise" "run-N+1")
assert_eq "missing accepted cluster → no_op" "$(echo "$RESULT" | json_field verdict)" "no_op"
assert_eq "reason is no_accepted_cluster"    "$(echo "$RESULT" | json_field reason)" "no_accepted_cluster"

echo ""
echo "Test 12: Backfill double-count guard — mixed raw + retro-backfill rows"
# Per Phase 3 spec (worker brief deliverable d.5): pre-clustered
# retro-backfill rows must NOT be counted in the raw-clustering pass, even
# when they share (target, change_type) with raw rows. The raw and
# consumption passes produce disjoint candidate lists; their contributions
# to K do not stack.
setup_store
# Two raw rows (distinct work_items) — K=2, sub-threshold on raw pass alone.
write_retro_evolution_row "2026-05-10T00:00:00Z" "wi-alpha" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
write_retro_evolution_row "2026-05-10T01:00:00Z" "wi-beta"  "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
# Three retro-backfill rows on the same (target, change_type) carrying
# distinct work_items. If the guard fails, the raw pass would see K=5 and
# emit a candidate; with the guard intact, raw pass stays at K=2.
write_retro_evolution_row "2026-05-09T00:00:00Z" "wi-delta"   "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-2"
write_retro_evolution_row "2026-05-09T01:00:00Z" "wi-epsilon" "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-2"
write_retro_evolution_row "2026-05-09T02:00:00Z" "wi-zeta"    "skills/foo/SKILL.md" "ceiling-raise" "tighten X" "retro-backfill: pre-clustered-bundle-2"
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "raw pass excludes retro-backfill (K=2, sub-threshold)" "$(echo "$CANDIDATES" | json_len)" "0"

# Now adding one more distinct raw work_item should push raw pass to K=3.
# This proves the K=3 fire is on raw-pass-only counts, not raw+backfill mix.
write_retro_evolution_row "2026-05-10T02:00:00Z" "wi-gamma" "skills/foo/SKILL.md" "ceiling-raise" "tighten X"
CANDIDATES=$(compute_candidate_clusters 3)
assert_eq "raw pass fires at K=3 from raw-only count" "$(echo "$CANDIDATES" | json_len)" "1"
assert_eq "K reflects raw work_items only"            "$(echo "$CANDIDATES" | json_eval 'd[0]["K"]')" "3"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

[[ $FAIL -gt 0 ]] && exit 1
exit 0
