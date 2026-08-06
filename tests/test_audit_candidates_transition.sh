#!/usr/bin/env bash
# test_audit_candidates_transition.sh — Tests for the
# audit-candidates-backfill-transitions.sh one-shot backfill.
#
# Covered behavior:
#   - The backfill walks the recorded _settlement/runs, collapses to the latest
#     non-invalidated terminal run per (work_item, candidate_id), and maps
#     verdicts (verified → gate-passed, unverified|contradicted → gate-failed,
#     error|blocked → no-op). Idempotent on re-invocation; --dry-run is no-op.
#   - Scope guard: per-slug archive paths skipped + counted out-of-scope;
#     consolidated _archive rows are processed normally.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
BACKFILL="$SCRIPT_DIR/migrations/audit-candidates-backfill-transitions.sh"

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

candidate_status() {
  # candidate_status <cand-file> <candidate-id>
  local file="$1" cid="$2"
  python3 - "$file" "$cid" <<'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
for line in open(path):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("candidate_id") == cid:
        print(row.get("status",""))
        break
PYEOF
}

seed_candidate() {
  # seed_candidate <kdir> <slug> <candidate-id> [status]
  local kdir="$1" slug="$2" cid="$3" status="${4:-pending_correctness_gate}"
  mkdir -p "$kdir/_work/$slug"
  python3 - "$kdir/_work/$slug/audit-candidates.jsonl" "$cid" "$status" "$slug" <<'PYEOF'
import json, sys
path, cid, status, slug = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
row = {
    "candidate_id": cid,
    "work_item": slug,
    "file": "scripts/x.sh",
    "line_range": "1-2",
    "falsifier": "falsifier text",
    "rationale": "rationale text",
    "status": status,
    "created_at": "2026-05-01T00:00:00Z",
}
with open(path, "a") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
PYEOF
}

write_run() {
  # write_run <kdir> <run-id> <kind> <status> <work-item> <candidate-id> <verdict>
  #          [--invalidated] [--completed-at <iso>]
  local kdir="$1" run_id="$2" kind="$3" status="$4" wi="$5" cid="$6" verdict="$7"
  shift 7
  local invalidated="false"
  local completed_at="2026-05-10T00:00:00Z"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --invalidated) invalidated="true"; shift ;;
      --completed-at) completed_at="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  mkdir -p "$kdir/_settlement/runs"
  python3 - "$kdir/_settlement/runs/$run_id.json" "$run_id" "$kind" "$status" "$wi" "$cid" "$verdict" "$invalidated" "$completed_at" <<'PYEOF'
import json, sys
path, run_id, kind, status, wi, cid, verdict, invalidated, completed_at = sys.argv[1:]
run = {
    "version": 1,
    "run_id": run_id,
    "item_id": f"item-{run_id}",
    "kind": kind,
    "source_id": cid,
    "work_item": wi,
    "status": status,
    "completed_at": completed_at,
    "verdict": {
        "claim_id": cid,
        "verdict": verdict,
        "evidence": "test",
        "correction": None,
        "verdict_format": "envelope",
    },
}
if invalidated == "true":
    run["invalidated_at"] = "2026-05-11T00:00:00Z"
with open(path, "w") as fh:
    json.dump(run, fh)
PYEOF
}

echo "=== audit-candidates backfill ==="
echo ""

# -----------------------------------------------------------------------------
# Test 1: backfill collapses to the latest non-invalidated run and maps verdicts
# -----------------------------------------------------------------------------
echo "Test 1: backfill basic walk"
KDIR9="$TEST_DIR/kdir9"
seed_candidate "$KDIR9" "wi-9a" "cand-aa11aa11aa11"
seed_candidate "$KDIR9" "wi-9b" "cand-bb22bb22bb22"
seed_candidate "$KDIR9" "wi-9c" "cand-cc33cc33cc33"
# wi-9a: invalidated verified + later unverified — should land gate-failed
write_run "$KDIR9" "run-aa-1" "omission" "completed" "wi-9a" "cand-aa11aa11aa11" "verified"   --invalidated --completed-at "2026-05-10T00:00:00Z"
write_run "$KDIR9" "run-aa-2" "omission" "completed" "wi-9a" "cand-aa11aa11aa11" "unverified" --completed-at "2026-05-12T00:00:00Z"
# wi-9b: contradicted
write_run "$KDIR9" "run-bb-1" "omission" "completed" "wi-9b" "cand-bb22bb22bb22" "contradicted" --completed-at "2026-05-10T00:00:00Z"
# wi-9c: error → no transition
write_run "$KDIR9" "run-cc-1" "omission" "completed" "wi-9c" "cand-cc33cc33cc33" "error" --completed-at "2026-05-10T00:00:00Z"

OUT9=$(bash "$BACKFILL" --kdir "$KDIR9" 2>&1)
assert_contains "summary line printed" "$OUT9" "scanned: 3"
assert_contains "transitioned count" "$OUT9" "transitioned: 2"
assert_contains "no-transition count" "$OUT9" "no-transition: 1"
assert_eq "wi-9a landed gate-failed (latest non-invalidated wins)" "$(candidate_status "$KDIR9/_work/wi-9a/audit-candidates.jsonl" "cand-aa11aa11aa11")" "gate-failed"
assert_eq "wi-9b landed gate-failed (contradicted)" "$(candidate_status "$KDIR9/_work/wi-9b/audit-candidates.jsonl" "cand-bb22bb22bb22")" "gate-failed"
assert_eq "wi-9c stays pending (error)" "$(candidate_status "$KDIR9/_work/wi-9c/audit-candidates.jsonl" "cand-cc33cc33cc33")" "pending_correctness_gate"

# -----------------------------------------------------------------------------
# Test 2: backfill is idempotent — second invocation produces no errors
# -----------------------------------------------------------------------------
echo "Test 2: backfill idempotent on re-run"
OUT10=$(bash "$BACKFILL" --kdir "$KDIR9" 2>&1)
assert_contains "second pass errors: 0" "$OUT10" "errors: 0"
# Already-terminal rows for wi-9a and wi-9b should be counted as already-terminal.
assert_contains "already-terminal counted on rerun" "$OUT10" "already-terminal: 2"

# -----------------------------------------------------------------------------
# Test 3: --dry-run prints intended transitions and exits 0 without mutating
# -----------------------------------------------------------------------------
echo "Test 3: --dry-run leaves rows untouched"
KDIR11="$TEST_DIR/kdir11"
seed_candidate "$KDIR11" "wi-11" "cand-dd44dd44dd44"
write_run "$KDIR11" "run-dd-1" "omission" "completed" "wi-11" "cand-dd44dd44dd44" "verified" --completed-at "2026-05-10T00:00:00Z"
OUT11=$(bash "$BACKFILL" --kdir "$KDIR11" --dry-run 2>&1)
assert_contains "dry-run prints dry-run marker" "$OUT11" "[backfill][dry-run] wi-11 cand-dd44dd44dd44 verdict=verified -> gate-passed"
assert_contains "dry-run summary errors: 0" "$OUT11" "errors: 0"
assert_eq "dry-run leaves status pending" "$(candidate_status "$KDIR11/_work/wi-11/audit-candidates.jsonl" "cand-dd44dd44dd44")" "pending_correctness_gate"

# -----------------------------------------------------------------------------
# Test 4: scope guard — per-slug archive paths SKIPPED + counted out-of-scope;
# consolidated _archive rows ARE processed.
# -----------------------------------------------------------------------------
echo "Test 4: scope guard (per-slug archive vs consolidated _archive)"
KDIR12="$TEST_DIR/kdir12"
# Per-slug archive (out of scope): _work/_archive/<slug>/audit-candidates.jsonl
mkdir -p "$KDIR12/_work/_archive/old-slug"
python3 - "$KDIR12/_work/_archive/old-slug/audit-candidates.jsonl" "cand-archived001" <<'PYEOF'
import json, sys
path, cid = sys.argv[1], sys.argv[2]
row = {
    "candidate_id": cid,
    "work_item": "old-slug",
    "file": "scripts/x.sh", "line_range":"1-2",
    "falsifier":"f","rationale":"r",
    "status": "pending_correctness_gate",
    "created_at": "2026-05-01T00:00:00Z",
}
with open(path, "a") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
PYEOF
write_run "$KDIR12" "run-arch-1" "omission" "completed" "_archive/old-slug" "cand-archived001" "verified" --completed-at "2026-05-10T00:00:00Z"
# Consolidated _archive row (in scope): _work/_archive/audit-candidates.jsonl
seed_candidate "$KDIR12" "_archive" "cand-consol00001"
write_run "$KDIR12" "run-arch-2" "omission" "completed" "_archive" "cand-consol00001" "verified" --completed-at "2026-05-10T00:00:00Z"

OUT12=$(bash "$BACKFILL" --kdir "$KDIR12" 2>&1)
assert_contains "out-of-scope counted for per-slug archive" "$OUT12" "out-of-scope: 1"
assert_contains "consolidated _archive transitioned" "$OUT12" "transitioned: 1"
# Per-slug archive row stays pending (not touched).
assert_eq "per-slug archive row untouched" "$(candidate_status "$KDIR12/_work/_archive/old-slug/audit-candidates.jsonl" "cand-archived001")" "pending_correctness_gate"
# Consolidated _archive row transitioned.
assert_eq "consolidated _archive row promoted" "$(candidate_status "$KDIR12/_work/_archive/audit-candidates.jsonl" "cand-consol00001")" "gate-passed"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"

[[ $FAIL -eq 0 ]]
