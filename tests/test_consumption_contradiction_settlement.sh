#!/usr/bin/env bash
# End-to-end fixture coverage for settlement landing and historical replay.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROCESSOR="$REPO_DIR/scripts/settlement-processor.py"
MIGRATION="$REPO_DIR/scripts/migrations/consumption-contradiction-backfill-status.sh"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected=$expected actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

write_row() {
  local path="$1" slug="$2" cid="$3" status="$4"
  mkdir -p "$(dirname "$path")"
  jq -nc --arg slug "$slug" --arg cid "$cid" --arg status "$status" \
    '{schema_version:1,work_item:$slug,contradiction_id:$cid,status:$status,dedupe_key:"keep-me",claim_payload:{claim_id:"claim",file:"x.py",line_range:"1",exact_snippet:"x",falsifier:"y"}}' > "$path"
}

land_run() {
  local kdir="$1" slug="$2" cid="$3" verdict="$4" run_id="$5" completed_at="$6"
  python3 - "$PROCESSOR" "$kdir" "$slug" "$cid" "$verdict" "$run_id" "$completed_at" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

processor, kdir, slug, cid, verdict, run_id, completed_at = sys.argv[1:]
spec = importlib.util.spec_from_file_location("settlement_processor", processor)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

settlement = module.Settlement(Path(kdir))
run = {
    "version": 1,
    "run_id": run_id,
    "item_id": "item-" + cid,
    "kind": "consumption-contradiction",
    "source_id": cid,
    "work_item": slug,
    "status": "completed",
    "completed_at": completed_at,
    "verdict": {"verdict": verdict},
}
written = settlement.write_run_record_once(run)
item = {"kind": "consumption-contradiction", "source_id": cid, "work_item": slug}
outcome = settlement._apply_consumption_contradiction_outcome(written, item)
if isinstance(outcome, dict):
    persisted = settlement.write_run_consumption_contradiction_outcome_once(run_id, outcome)
    written["consumption_contradiction_outcome"] = persisted
print(json.dumps(outcome, sort_keys=True))
PY
}

echo "=== consumption-contradiction settlement landing ==="

KDIR="$TEST_DIR/landing"
mkdir -p "$KDIR/_settlement/runs" "$KDIR/_scorecards"
touch "$KDIR/_scorecards/rows.jsonl"
write_row "$KDIR/_work/active-item/consumption-contradictions.jsonl" active-item ctr-active pending
OUT=$(land_run "$KDIR" active-item ctr-active verified run-active 2026-06-01T01:02:03Z)
assert_eq "verified settlement reports applied" "$(jq -r .status <<<"$OUT")" "applied"
assert_eq "verified settlement updates active row" "$(jq -r .status "$KDIR/_work/active-item/consumption-contradictions.jsonl")" "verified"
assert_eq "settlement preserves run completion time" "$(jq -r .settled_at "$KDIR/_work/active-item/consumption-contradictions.jsonl")" "2026-06-01T01:02:03Z"
assert_eq "settlement outcome is persisted on run" "$(jq -r .consumption_contradiction_outcome.status "$KDIR/_settlement/runs/run-active.json")" "applied"
assert_eq "settlement run remains completed" "$(jq -r .status "$KDIR/_settlement/runs/run-active.json")" "completed"

write_row "$KDIR/_work/_archive/archive-item/consumption-contradictions.jsonl" archive-item ctr-archive pending
OUT=$(land_run "$KDIR" archive-item ctr-archive contradicted run-archive 2026-05-02T03:04:05Z)
assert_eq "contradicted settlement reports applied" "$(jq -r .status <<<"$OUT")" "applied"
assert_eq "contradicted verdict lands unchanged in archive" "$(jq -r .status "$KDIR/_work/_archive/archive-item/consumption-contradictions.jsonl")" "contradicted"
assert_eq "archive location is recorded on run outcome" "$(jq -r .consumption_contradiction_outcome.sidecar_location "$KDIR/_settlement/runs/run-archive.json")" "archive"

write_row "$KDIR/_work/idempotent-item/consumption-contradictions.jsonl" idempotent-item ctr-idem verified
OUT=$(land_run "$KDIR" idempotent-item ctr-idem verified run-idem 2026-06-03T00:00:00Z)
assert_eq "same-terminal settlement reports idempotent" "$(jq -r .status <<<"$OUT")" "idempotent"

write_row "$KDIR/_work/unverified-item/consumption-contradictions.jsonl" unverified-item ctr-unverified pending
OUT=$(land_run "$KDIR" unverified-item ctr-unverified unverified run-unverified 2026-06-04T00:00:00Z)
assert_eq "unverified settlement has no projection outcome" "$OUT" "null"
assert_eq "unverified row remains pending" "$(jq -r .status "$KDIR/_work/unverified-item/consumption-contradictions.jsonl")" "pending"
assert_eq "unverified run has no projection field" "$(jq -r 'has("consumption_contradiction_outcome")' "$KDIR/_settlement/runs/run-unverified.json")" "false"

ERR_FILE="$TEST_DIR/missing.err"
OUT=$(land_run "$KDIR" missing-item ctr-missing contradicted run-missing 2026-06-05T00:00:00Z 2>"$ERR_FILE")
assert_eq "missing-row settlement records failed outcome" "$(jq -r .status <<<"$OUT")" "failed"
assert_eq "failed outcome identifies work item" "$(jq -r .work_item <<<"$OUT")" "missing-item"
assert_eq "failed outcome identifies contradiction" "$(jq -r .contradiction_id <<<"$OUT")" "ctr-missing"
assert_eq "projection failure does not fail settlement run" "$(jq -r .status "$KDIR/_settlement/runs/run-missing.json")" "completed"
assert_eq "projection failure is persisted" "$(jq -r .consumption_contradiction_outcome.status "$KDIR/_settlement/runs/run-missing.json")" "failed"
assert_eq "projection failure is emitted to stderr" "$(grep -c 'landing failed.*run_id=run-missing.*contradiction_id=ctr-missing' "$ERR_FILE")" "1"
assert_eq "settlement landing appends no scorecard row" "$(wc -l < "$KDIR/_scorecards/rows.jsonl" | tr -d ' ')" "0"

# Static seam guard: the normal post-run terminus invokes projection after the
# run record is durable and before it returns.
ORDER=$(python3 - "$PROCESSOR" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("written = self.write_run_record_once(run)")
projection = text.index("self._apply_consumption_contradiction_outcome(written, item)", start)
ret = text.index("return written", projection)
print("ok" if start < projection < ret else "bad")
PY
)
assert_eq "normal settlement terminus contains durable-run then projection ordering" "$ORDER" "ok"

echo "=== consumption-contradiction replay migration ==="
MKDIR="$TEST_DIR/migration"
mkdir -p "$MKDIR/_settlement/runs" "$MKDIR/_settlement/archive/runs" "$MKDIR/_scorecards"
touch "$MKDIR/_scorecards/rows.jsonl"
write_row "$MKDIR/_work/mig-active/consumption-contradictions.jsonl" mig-active ctr-mig-active pending
write_row "$MKDIR/_work/_archive/mig-archive/consumption-contradictions.jsonl" mig-archive ctr-mig-archive pending
jq -nc '{run_id:"run-mig-active",kind:"consumption-contradiction",source_id:"ctr-mig-active",work_item:"mig-active",status:"completed",completed_at:"2026-04-01T00:00:00Z",verdict:{verdict:"verified"}}' > "$MKDIR/_settlement/runs/run-mig-active.json"
jq -nc '{run_id:"run-mig-archive",kind:"consumption-contradiction",source_id:"ctr-mig-archive",work_item:"mig-archive",status:"completed",completed_at:"2026-03-01T00:00:00Z",verdict:{verdict:"contradicted"}}' > "$MKDIR/_settlement/archive/runs/run-mig-archive.json"
# An invalidated newer run must not displace the live completed verdict.
jq -nc '{run_id:"run-mig-invalid",kind:"consumption-contradiction",source_id:"ctr-mig-active",work_item:"mig-active",status:"completed",completed_at:"2026-05-01T00:00:00Z",invalidated_at:"2026-05-02T00:00:00Z",verdict:{verdict:"contradicted"}}' > "$MKDIR/_settlement/runs/run-mig-invalid.json"

DRY=$("$MIGRATION" --kdir "$MKDIR" --dry-run --json)
assert_eq "dry-run census selects two latest valid identities" "$(jq -r .selected_runs <<<"$DRY")" "2"
assert_eq "dry-run census finds two pending matches" "$(jq -r .matched <<<"$DRY")" "2"
assert_eq "dry-run predicts two transitions" "$(jq -r .applied <<<"$DRY")" "2"
assert_eq "dry-run active/archive split is 1/1" "$(jq -r '[.split.active.matched,.split.archive.matched]|join("/")' <<<"$DRY")" "1/1"

SCORE_HASH_BEFORE=$(shasum -a 256 "$MKDIR/_scorecards/rows.jsonl" | awk '{print $1}')
APPLY=$("$MIGRATION" --kdir "$MKDIR" --json)
assert_eq "live replay applies both transitions" "$(jq -r .applied <<<"$APPLY")" "2"
assert_eq "live replay has no failures" "$(jq -r .failed <<<"$APPLY")" "0"
assert_eq "replay preserves active completion time" "$(jq -r .settled_at "$MKDIR/_work/mig-active/consumption-contradictions.jsonl")" "2026-04-01T00:00:00Z"
assert_eq "replay preserves archived completion time" "$(jq -r .settled_at "$MKDIR/_work/_archive/mig-archive/consumption-contradictions.jsonl")" "2026-03-01T00:00:00Z"
assert_eq "replay writes contradicted unchanged" "$(jq -r .status "$MKDIR/_work/_archive/mig-archive/consumption-contradictions.jsonl")" "contradicted"

SECOND=$("$MIGRATION" --kdir "$MKDIR" --json)
assert_eq "second replay reports zero transitions" "$(jq -r .applied <<<"$SECOND")" "0"
assert_eq "second replay reports both rows idempotent" "$(jq -r .idempotent <<<"$SECOND")" "2"
assert_eq "second replay has zero pending matches" "$(jq -r .matched <<<"$SECOND")" "0"
SCORE_HASH_AFTER=$(shasum -a 256 "$MKDIR/_scorecards/rows.jsonl" | awk '{print $1}')
assert_eq "replay never appends scorecard rows" "$SCORE_HASH_AFTER" "$SCORE_HASH_BEFORE"

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
