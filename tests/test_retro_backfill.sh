#!/usr/bin/env bash
# test_retro_backfill.sh — Tests for `lore retro backfill` (retro-backfill.sh).
#
# Covers:
#   1. stdout mode prints clusters with size >= K
#   2. journal-emit mode appends new rows tagged with cluster_id + journal_row_refs
#   3. cluster_id dedupe — re-running journal-emit appends nothing new
#   4. --include-backfill-rows opt-in composes over prior backfill output
#   5. --min-cluster K threshold edge case (cluster of size 2 below default K=3)
#   6. Existing rows are NOT mutated by journal-emit mode

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/retro-backfill.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    pass "$label"
  else
    fail "$label" "needle not found: $needle"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    fail "$label" "unexpected: $needle"
  else
    pass "$label"
  fi
}

assert_exit_zero() {
  local label="$1" code="$2"
  if [[ "$code" -eq 0 ]]; then pass "$label"; else fail "$label" "exit=$code"; fi
}

assert_exit_nonzero() {
  local label="$1" code="$2"
  if [[ "$code" -ne 0 ]]; then pass "$label"; else fail "$label" "exit=0"; fi
}

# --- Fixture: synthetic kdir with controlled journal ---
KDIR=$(mktemp -d)
mkdir -p "$KDIR/_meta"
JOURNAL="$KDIR/_meta/effectiveness-journal.jsonl"

cleanup() { rm -rf "$KDIR"; }
trap cleanup EXIT

# Build a journal with:
#   - 3 distinct work_items hitting (skills/retro/SKILL.md, evidence-gap)  → cluster of 3
#   - 4 distinct work_items hitting (skills/evolve/SKILL.md, new-failure-mode) → cluster of 4
#   - 2 distinct work_items hitting (cli/lore, refactor) → below K=3, must NOT cluster
#   - 1 row with role=worker (must be ignored)
#   - 1 row out of window (must be ignored)
cat > "$JOURNAL" <<'EOF'
{"timestamp": "2026-04-01T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: foo", "context": "retro-evolution: w1", "role": "retro-evolution", "work_item": "wi-alpha", "git_branch": "main"}
{"timestamp": "2026-04-02T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: bar", "context": "retro-evolution: w2", "role": "retro-evolution", "work_item": "wi-beta", "git_branch": "main"}
{"timestamp": "2026-04-03T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: baz", "context": "retro-evolution: w3", "role": "retro-evolution", "work_item": "wi-gamma", "git_branch": "main"}
{"timestamp": "2026-04-04T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q1", "context": "retro-evolution: w4", "role": "retro-evolution", "work_item": "wi-delta", "git_branch": "main"}
{"timestamp": "2026-04-05T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q2", "context": "retro-evolution: w5", "role": "retro-evolution", "work_item": "wi-epsilon", "git_branch": "main"}
{"timestamp": "2026-04-06T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q3", "context": "retro-evolution: w6", "role": "retro-evolution", "work_item": "wi-zeta", "git_branch": "main"}
{"timestamp": "2026-04-07T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q4", "context": "retro-evolution: w7", "role": "retro-evolution", "work_item": "wi-eta", "git_branch": "main"}
{"timestamp": "2026-04-08T10:00:00Z", "observation": "Target: cli/lore | Change type: refactor | Section: dispatch | Suggestion: split", "context": "retro-evolution: w8", "role": "retro-evolution", "work_item": "wi-theta", "git_branch": "main"}
{"timestamp": "2026-04-09T10:00:00Z", "observation": "Target: cli/lore | Change type: refactor | Section: dispatch | Suggestion: split2", "context": "retro-evolution: w9", "role": "retro-evolution", "work_item": "wi-iota", "git_branch": "main"}
{"timestamp": "2026-04-10T10:00:00Z", "observation": "Worker note unrelated", "context": "implement: foo", "role": "worker", "work_item": "wi-kappa", "git_branch": "main"}
{"timestamp": "2025-12-01T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: out-of-window", "context": "retro-evolution: w-old", "role": "retro-evolution", "work_item": "wi-old", "git_branch": "main"}
EOF

EXPECTED_LINES_BEFORE=$(wc -l < "$JOURNAL" | tr -d '[:space:]')

echo "=== test_retro_backfill.sh ==="
echo ""

# --- Test 1: script exists and is executable ---
echo "Test 1: retro-backfill.sh exists"
if [[ -x "$SCRIPT" ]]; then
  pass "script is executable"
else
  fail "script not executable: $SCRIPT"
  echo "=== Results: $PASS passed, $FAIL failed ==="
  exit 1
fi

# --- Test 2: --since required ---
echo ""
echo "Test 2: --since is required"
ERR_OUT=$(bash "$SCRIPT" --kdir "$KDIR" 2>&1)
RC=$?
assert_exit_nonzero "missing --since exits non-zero" "$RC"
assert_contains "error mentions --since" "$ERR_OUT" "--since"

# --- Test 3: stdout mode lists clusters of size >= K (default 3) ---
echo ""
echo "Test 3: stdout mode lists clusters of size >= 3"
OUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" 2>&1)
RC=$?
assert_exit_zero "exit 0 in stdout mode" "$RC"
assert_contains "header has CLUSTER_ID column" "$OUT" "CLUSTER_ID"
assert_contains "evolve cluster present (count=4)" "$OUT" "skills/evolve/SKILL.md"
assert_contains "retro cluster present (count=3)" "$OUT" "skills/retro/SKILL.md"
assert_not_contains "cli/lore cluster (size=2) NOT present" "$OUT" "cli/lore"

# --- Test 4: --json stdout mode emits structured JSON ---
echo ""
echo "Test 4: --json stdout mode emits structured JSON"
JSON_OUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --json 2>&1)
RC=$?
assert_exit_zero "exit 0 in --json mode" "$RC"
COUNT=$(echo "$JSON_OUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))' 2>/dev/null)
assert_eq "JSON has 2 clusters" "2" "$COUNT"

# --- Test 5: cluster_id is stable sha256 of canonical input ---
echo ""
echo "Test 5: cluster_id matches sha256 contract"
EXPECTED_ID=$(python3 -c '
import hashlib
work_items = sorted(["wi-delta", "wi-epsilon", "wi-zeta", "wi-eta"])
s = "retro-backfill" + "|" + "skills/evolve/SKILL.md" + "|" + "new-failure-mode" + "|" + ",".join(work_items)
print(hashlib.sha256(s.encode("utf-8")).hexdigest())
')
ACTUAL_ID=$(echo "$JSON_OUT" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for c in data["clusters"]:
    if c["target"] == "skills/evolve/SKILL.md":
        print(c["cluster_id"])
        break
')
assert_eq "evolve cluster_id matches sha256" "$EXPECTED_ID" "$ACTUAL_ID"

# --- Test 6: journal-emit mode appends rows with role=retro-evolution + cluster_id ---
echo ""
echo "Test 6: journal-emit mode appends new rows"
JOURNAL_OUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --emit-mode journal 2>&1)
RC=$?
assert_exit_zero "exit 0 in journal-emit mode" "$RC"
LINES_AFTER=$(wc -l < "$JOURNAL" | tr -d '[:space:]')
assert_eq "journal grew by 2 rows" "$((EXPECTED_LINES_BEFORE + 2))" "$LINES_AFTER"

# Check the appended rows
NEW_ROWS=$(tail -n 2 "$JOURNAL")
assert_contains "appended row has role=retro-evolution" "$NEW_ROWS" '"role": "retro-evolution"'
assert_contains "appended row has retro-backfill context" "$NEW_ROWS" '"context": "retro-backfill:'
assert_contains "appended row has cluster_id" "$NEW_ROWS" '"cluster_id":'
assert_contains "appended row has journal_row_refs" "$NEW_ROWS" '"journal_row_refs":'
assert_contains "appended row has work_item=(backfill)" "$NEW_ROWS" '"work_item": "(backfill)"'
assert_contains "appended row observation has Source: retro-backfill" "$NEW_ROWS" 'Source: retro-backfill'
assert_contains "appended row observation has cluster_id field" "$NEW_ROWS" 'cluster_id:'

# --- Test 7: existing journal rows are NOT mutated ---
echo ""
echo "Test 7: existing rows are unchanged"
ORIG_HEAD=$(head -n "$EXPECTED_LINES_BEFORE" "$JOURNAL" | python3 -c 'import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
EXPECTED_ORIG=$(cat <<'EOF' | python3 -c 'import sys, hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
{"timestamp": "2026-04-01T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: foo", "context": "retro-evolution: w1", "role": "retro-evolution", "work_item": "wi-alpha", "git_branch": "main"}
{"timestamp": "2026-04-02T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: bar", "context": "retro-evolution: w2", "role": "retro-evolution", "work_item": "wi-beta", "git_branch": "main"}
{"timestamp": "2026-04-03T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: baz", "context": "retro-evolution: w3", "role": "retro-evolution", "work_item": "wi-gamma", "git_branch": "main"}
{"timestamp": "2026-04-04T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q1", "context": "retro-evolution: w4", "role": "retro-evolution", "work_item": "wi-delta", "git_branch": "main"}
{"timestamp": "2026-04-05T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q2", "context": "retro-evolution: w5", "role": "retro-evolution", "work_item": "wi-epsilon", "git_branch": "main"}
{"timestamp": "2026-04-06T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q3", "context": "retro-evolution: w6", "role": "retro-evolution", "work_item": "wi-zeta", "git_branch": "main"}
{"timestamp": "2026-04-07T10:00:00Z", "observation": "Target: skills/evolve/SKILL.md | Change type: new-failure-mode | Section: 5 | Suggestion: q4", "context": "retro-evolution: w7", "role": "retro-evolution", "work_item": "wi-eta", "git_branch": "main"}
{"timestamp": "2026-04-08T10:00:00Z", "observation": "Target: cli/lore | Change type: refactor | Section: dispatch | Suggestion: split", "context": "retro-evolution: w8", "role": "retro-evolution", "work_item": "wi-theta", "git_branch": "main"}
{"timestamp": "2026-04-09T10:00:00Z", "observation": "Target: cli/lore | Change type: refactor | Section: dispatch | Suggestion: split2", "context": "retro-evolution: w9", "role": "retro-evolution", "work_item": "wi-iota", "git_branch": "main"}
{"timestamp": "2026-04-10T10:00:00Z", "observation": "Worker note unrelated", "context": "implement: foo", "role": "worker", "work_item": "wi-kappa", "git_branch": "main"}
{"timestamp": "2025-12-01T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Section: 2a | Suggestion: out-of-window", "context": "retro-evolution: w-old", "role": "retro-evolution", "work_item": "wi-old", "git_branch": "main"}
EOF
)
assert_eq "first 11 rows unchanged (sha256)" "$EXPECTED_ORIG" "$ORIG_HEAD"

# --- Test 8: cluster_id dedupe — re-run appends nothing ---
echo ""
echo "Test 8: re-running journal-emit dedupes by cluster_id"
LINES_BEFORE_RERUN=$(wc -l < "$JOURNAL" | tr -d '[:space:]')
RERUN_OUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --emit-mode journal 2>&1)
RC=$?
assert_exit_zero "rerun exit 0" "$RC"
LINES_AFTER_RERUN=$(wc -l < "$JOURNAL" | tr -d '[:space:]')
assert_eq "no new rows appended on rerun" "$LINES_BEFORE_RERUN" "$LINES_AFTER_RERUN"
assert_contains "rerun reports skipped(dedupe)=2" "$RERUN_OUT" "skipped(dedupe)=2"
assert_contains "rerun reports appended=0" "$RERUN_OUT" "appended=0"

# --- Test 9: --include-backfill-rows opts back in ---
echo ""
echo "Test 9: --include-backfill-rows allows composition over prior backfill rows"
# Without --include-backfill-rows, the backfill rows we just wrote are excluded;
# stdout mode without it returns 2 clusters (the originals).
OUT_WITHOUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --json 2>&1)
COUNT_WITHOUT=$(echo "$OUT_WITHOUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))')
assert_eq "without --include-backfill-rows: 2 clusters" "2" "$COUNT_WITHOUT"

# Add a few extra retro-evolution rows tagged retro-backfill: that share keys with originals
cat >> "$JOURNAL" <<'EOF'
{"timestamp": "2026-04-15T10:00:00Z", "observation": "Target: skills/retro/SKILL.md | Change type: evidence-gap | Cluster size: 3 distinct work_items | Source: retro-backfill", "context": "retro-backfill: 2026-01-01..2026-04-30", "role": "retro-evolution", "work_item": "wi-fresh", "git_branch": "main", "cluster_id": "fakecluster123"}
EOF
# With --include-backfill-rows, this fresh row joins the retro cluster as a 4th distinct work_item (still 3 originals + wi-fresh).
OUT_WITH=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --include-backfill-rows --json 2>&1)
RETRO_COUNT_WITH=$(echo "$OUT_WITH" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for c in data["clusters"]:
    if c["target"] == "skills/retro/SKILL.md" and c["change_type"] == "evidence-gap":
        print(c["count"])
        break
')
# With --include-backfill-rows, all retro-backfill-tagged rows get re-parsed.
# Retro cluster gains: wi-fresh (manually appended above) + "(backfill)" (the
# synthetic work_item Test 6 wrote when journal-emitting the retro cluster).
# So the retro cluster grows from 3 distinct work_items to 5.
assert_eq "with --include-backfill-rows: retro cluster grows to 5" "5" "$RETRO_COUNT_WITH"

# --- Test 10: --min-cluster threshold ---
echo ""
echo "Test 10: --min-cluster K threshold"
OUT_K2=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --min-cluster 2 --json 2>&1)
COUNT_K2=$(echo "$OUT_K2" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))')
# With K=2: retro (3), evolve (4), and cli/lore (2) all qualify → 3 clusters.
# (--include-backfill-rows is OFF here, so the retro-backfill rows we wrote earlier
# are excluded from the count — retro stays at 3 distinct work_items.)
assert_eq "K=2: 3 clusters (retro, evolve, cli/lore)" "3" "$COUNT_K2"

OUT_K10=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --min-cluster 10 --json 2>&1)
COUNT_K10=$(echo "$OUT_K10" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))')
assert_eq "K=10: 0 clusters (none meet threshold)" "0" "$COUNT_K10"

# --- Test 11: out-of-window rows excluded ---
echo ""
echo "Test 11: --until upper bound excludes later rows"
OUT_NARROW=$(bash "$SCRIPT" --since 2026-01-01 --until 2026-04-04T00:00:00Z --kdir "$KDIR" --json 2>&1)
COUNT_NARROW=$(echo "$OUT_NARROW" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))')
# Window contains only 3 retro evidence-gap rows; evolve cluster (starts 2026-04-04T10) is outside.
assert_eq "narrow window: 1 cluster (retro only)" "1" "$COUNT_NARROW"

# --- Test 12: invalid --emit-mode rejected ---
echo ""
echo "Test 12: invalid --emit-mode rejected"
ERR_OUT=$(bash "$SCRIPT" --since 2026-01-01 --kdir "$KDIR" --emit-mode invalid 2>&1)
RC=$?
assert_exit_nonzero "invalid emit-mode exits non-zero" "$RC"
assert_contains "error mentions emit-mode" "$ERR_OUT" "emit-mode"

# --- Test 13: cli/lore registers backfill subcommand ---
echo ""
echo "Test 13: cli/lore wires backfill into retro dispatch"
CLI="$REPO_ROOT/cli/lore"
assert_contains "cli/lore has backfill case" "$(cat "$CLI")" 'backfill)'
assert_contains "cli/lore routes to retro-backfill.sh" "$(cat "$CLI")" 'retro-backfill.sh'

# --- Test 14: lore retro dispatcher preserves existing subcommands ---
echo ""
echo "Test 14: lore retro / export|import|aggregate dispatch unmodified"
# `lore retro` with no subcommand should print usage and exit non-zero (preserves prior behavior).
# Use set +e style: capture output, then read $? on the very next line.
RETRO_OUT=$(bash "$CLI" retro 2>&1)
RC=$?
assert_exit_nonzero "lore retro (no subcommand) exits non-zero" "$RC"
assert_contains "lore retro usage lists export" "$RETRO_OUT" "export"
assert_contains "lore retro usage lists backfill" "$RETRO_OUT" "backfill"
# `lore retro --help` should print usage and exit 0.
HELP_OUT=$(bash "$CLI" retro --help 2>&1)
RC=$?
assert_exit_zero "lore retro --help exits 0" "$RC"
assert_contains "lore retro --help lists export" "$HELP_OUT" "export"
# `lore retro export --help` should still dispatch to the export script (unchanged).
EXPORT_HELP=$(bash "$CLI" retro export --help 2>&1)
assert_contains "lore retro export --help still dispatches" "$EXPORT_HELP" "retro export"
# Unknown subcommand still rejected.
UNKNOWN=$(bash "$CLI" retro nosuchcmd 2>&1)
RC=$?
assert_exit_nonzero "lore retro nosuchcmd exits non-zero" "$RC"
assert_contains "unknown retro subcommand error" "$UNKNOWN" "unknown retro subcommand"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
