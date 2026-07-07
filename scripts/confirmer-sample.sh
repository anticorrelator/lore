#!/usr/bin/env bash
# confirmer-sample.sh — Budget-bounded confirmer sampler for held reports.
#
# The confirmer is a sampler, not a judge: it selects up to --budget held
# consumption-verification reports from the trust ledger and enqueues each
# as an assertion-shaped settlement audit item (kind=commons) for the
# existing correctness-gate-assertion judge. No new judge template, verdict
# state, or calibration surface — the gate re-verifies the commons entry the
# held report vouched for, and the audit wrapper's adjudication mirror lands
# the outcome back in the trust ledger against that entry.
#
# Routing: a held report is sampleable only when its entry has a
# promoted-commons row in an ACTIVE work item (`_work/*/promoted-commons.jsonl`)
# — that row is the source row the settlement dispatch re-resolves, and
# archived-source items are dropped by queue recompute. Held reports on
# entries without an active commons row are counted and reported as
# unroutable, never silently dropped.
#
# Idempotency (two layers): the call-site excludes candidates whose
# deterministic item id is already in queue.json, or whose latest
# non-invalidated settlement run completed at-or-after the held report was
# observed (the confirmation is already re-verified; an OLDER run does not
# exclude — re-verifying such entries is the confirmer's purpose). Enqueue
# itself goes through the settlement-queue intake, whose writer-level dedupe
# makes replays no-ops.
#
# Enqueued items are stamped selection_reason="confirmer_sample" and placed
# at head-of-pending (mirroring retry-errors' native stamping) — unstamped
# pending items are legacy-normalized into a queue recompute that keeps only
# the top batch_size scored candidates, which would strand the sample.
#
# Usage:
#   confirmer-sample.sh [--budget N] [--seed N] [--dry-run] [--kdir <path>] [--json]
#
# --budget defaults to 12, matching the settlement memo's throttled-census
# posture (12 sampled audits/week); ratchet down as peer-verification volume
# proves out.
#
# Exit codes:
#   0 — sampled and enqueued (or nothing eligible / --dry-run)
#   1 — usage error or knowledge store not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: confirmer-sample.sh [--budget N] [--seed N] [--dry-run] [--kdir <path>] [--json]

Select up to N held consumption-verification reports from the trust ledger
and enqueue each as a kind=commons settlement audit item for the existing
correctness-gate-assertion judge. Re-running is idempotent; --dry-run prints
the selection without enqueueing.
EOF
}

BUDGET=12
SEED=""
DRY_RUN=0
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget)   BUDGET="$2";         shift 2 ;;
    --seed)     SEED="$2";           shift 2 ;;
    --dry-run)  DRY_RUN=1;           shift ;;
    --kdir)     KDIR_OVERRIDE="$2";  shift 2 ;;
    --json)     JSON_MODE=1;         shift ;;
    --help|-h)  usage; exit 0 ;;
    *)
      echo "[confirmer-sample] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

if ! printf '%s' "$BUDGET" | grep -Eq '^[0-9]+$' || [[ "$BUDGET" -lt 1 ]]; then
  echo "[confirmer-sample] Error: --budget must be a positive integer (got '$BUDGET')" >&2
  exit 1
fi
if [[ -n "$SEED" ]] && ! printf '%s' "$SEED" | grep -Eq '^[0-9]+$'; then
  echo "[confirmer-sample] Error: --seed must be an integer (got '$SEED')" >&2
  exit 1
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KDIR" ]]; then
  echo "[confirmer-sample] Error: knowledge store not found at: $KDIR" >&2
  exit 1
fi

# --- Phase 1: plan (read-only selection) ---
PLAN=$(KDIR="$KDIR" BUDGET="$BUDGET" SEED="$SEED" SCRIPT_DIR="$SCRIPT_DIR" python3 <<'PY_EOF'
import glob
import importlib.util
import json
import os
import random
import sys

kdir = os.environ["KDIR"]
budget = int(os.environ["BUDGET"])
seed = os.environ.get("SEED") or None
script_dir = os.environ["SCRIPT_DIR"]

spec = importlib.util.spec_from_file_location(
    "settlement_processor", os.path.join(script_dir, "settlement-processor.py"))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
settlement = sp.Settlement(sp.Path(kdir))

def read_jsonl(path):
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
    except OSError:
        return

# Held reports, newest observation per entry.
held_by_entry = {}
held_total = 0
for row in read_jsonl(os.path.join(kdir, "_trust", "trust-events.jsonl")):
    if row.get("event") != "consumption-verification":
        continue
    payload = row.get("payload") or {}
    if payload.get("disposition") != "held":
        continue
    entry_path = row.get("entry_path") or ""
    if not entry_path:
        continue
    held_total += 1
    prev = held_by_entry.get(entry_path)
    if prev is None or str(row.get("observed_at") or "") > str(prev.get("observed_at") or ""):
        held_by_entry[entry_path] = row

# entry_path -> (work_item, commons row). Active work items only; sorted
# order with first-found-wins keeps the mapping deterministic; within a
# file the last row for an entry wins (later promotions supersede).
commons_by_entry = {}
for pc in sorted(glob.glob(os.path.join(kdir, "_work", "*", "promoted-commons.jsonl"))):
    work_item = os.path.basename(os.path.dirname(pc))
    per_file = {}
    for row in read_jsonl(pc):
        entry_path = row.get("entry_path") or ""
        claim_id = row.get("claim_id") or ""
        if entry_path and claim_id:
            per_file[entry_path] = row
    for entry_path, row in per_file.items():
        commons_by_entry.setdefault(entry_path, (work_item, row))

queued_ids = set()
try:
    with open(os.path.join(kdir, "_settlement", "queue.json"), encoding="utf-8") as fh:
        queue = json.load(fh)
    queued_ids = {str(it.get("id") or "") for it in queue.get("items", [])}
except (OSError, json.JSONDecodeError):
    pass

last_run_at = {}
# Span hot and archived runs: a settled run may have been compacted into
# archive/runs/, and its adjudication timestamp still decides whether a held
# report has been re-audited since. The two dirs never share a run_id.
run_globs = (
    glob.glob(os.path.join(kdir, "_settlement", "runs", "*.json"))
    + glob.glob(os.path.join(kdir, "_settlement", "archive", "runs", "*.json"))
)
for run_path in run_globs:
    try:
        with open(run_path, encoding="utf-8") as fh:
            run = json.load(fh)
    except (OSError, json.JSONDecodeError):
        continue
    if run.get("invalidated_at"):
        continue
    item_id = str(run.get("item_id") or "")
    if not item_id:
        continue
    run_at = str(run.get("completed_at") or run.get("started_at") or "")
    if run_at > last_run_at.get(item_id, ""):
        last_run_at[item_id] = run_at

candidates = []
skipped = {"unroutable": 0, "already_queued": 0, "adjudicated_since_held": 0}
seen_item_ids = set()
for entry_path in sorted(held_by_entry):
    mapping = commons_by_entry.get(entry_path)
    if mapping is None:
        skipped["unroutable"] += 1
        continue
    work_item, row = mapping
    item_id = settlement.item_id(work_item, str(row.get("claim_id")), "commons")
    if item_id in seen_item_ids:
        continue
    seen_item_ids.add(item_id)
    if item_id in queued_ids:
        skipped["already_queued"] += 1
        continue
    held_at = str(held_by_entry[entry_path].get("observed_at") or "")
    if last_run_at.get(item_id, "") >= held_at and item_id in last_run_at:
        skipped["adjudicated_since_held"] += 1
        continue
    candidates.append({
        "entry_path": entry_path,
        "work_item": work_item,
        "claim_id": str(row.get("claim_id")),
        "item_id": item_id,
        "row": row,
    })

rng = random.Random(int(seed)) if seed is not None else random.Random()
rng.shuffle(candidates)
selected = candidates[:budget]

print(json.dumps({
    "held_reports": held_total,
    "held_entries": len(held_by_entry),
    "eligible": len(candidates),
    "selected": selected,
    "skipped": skipped,
}))
PY_EOF
)

SELECTED_COUNT=$(printf '%s' "$PLAN" | jq '.selected | length')

if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(printf '%s' "$PLAN" | jq --argjson budget "$BUDGET" \
      '{ok: true, dry_run: true, budget: $budget, held_reports, held_entries, eligible, skipped,
        selected: [.selected[] | {entry_path, work_item, claim_id, item_id}]}')"
  fi
  echo "[confirmer-sample] dry-run: would enqueue $SELECTED_COUNT of $(printf '%s' "$PLAN" | jq '.eligible') eligible held reports (budget $BUDGET)"
  printf '%s' "$PLAN" | jq -r '.selected[] | "[confirmer-sample]   \(.entry_path) -> \(.work_item)/\(.claim_id)"'
  exit 0
fi

# --- Phase 2: enqueue each selected item through the stable intake ---
ENQUEUED_IDS=()
ENQUEUED=0
DUPLICATES=0
FAILED=0
ROW_TMP=$(mktemp "${TMPDIR:-/tmp}/confirmer-row.XXXXXX")
trap 'rm -f "$ROW_TMP"' EXIT

while IFS= read -r sel; do
  [[ -n "$sel" ]] || continue
  printf '%s' "$sel" | jq -c '.row' > "$ROW_TMP"
  WI=$(printf '%s' "$sel" | jq -r '.work_item')
  ITEM_ID=$(printf '%s' "$sel" | jq -r '.item_id')
  if OUT=$(bash "$SCRIPT_DIR/settlement-queue.sh" enqueue \
        --work-item "$WI" --kind commons --row-file "$ROW_TMP" \
        --kdir "$KDIR" --json 2>&1); then
    ACTION=$(printf '%s' "$OUT" | jq -r '.action // "unknown"' 2>/dev/null || echo "unknown")
    case "$ACTION" in
      enqueued)  ENQUEUED=$((ENQUEUED + 1)); ENQUEUED_IDS+=("$ITEM_ID") ;;
      duplicate) DUPLICATES=$((DUPLICATES + 1)) ;;
      *)
        FAILED=$((FAILED + 1))
        echo "[confirmer-sample] warning: unexpected enqueue action '$ACTION' for $ITEM_ID" >&2
        ;;
    esac
  else
    FAILED=$((FAILED + 1))
    echo "[confirmer-sample] warning: enqueue failed for $ITEM_ID — skipped" >&2
  fi
done < <(printf '%s' "$PLAN" | jq -c '.selected[]')

# --- Phase 3: stamp selection_reason + head-of-pending placement ---
# Mirrors retry-errors' native intervention (selection_score=null,
# selection_reason, batch_id, leased + stamped + pending order, batch header)
# so the sampled cohort survives legacy-pending normalization instead of
# competing in a recompute window. Contained: a stamp failure leaves valid
# enqueued items behind and only warns.
STAMPED=0
if [[ $ENQUEUED -gt 0 ]]; then
  if STAMPED=$(KDIR="$KDIR" SCRIPT_DIR="$SCRIPT_DIR" \
      ITEM_IDS=$(printf '%s\n' "${ENQUEUED_IDS[@]}") python3 <<'PY_EOF'
import importlib.util
import hashlib
import json
import os

kdir = os.environ["KDIR"]
script_dir = os.environ["SCRIPT_DIR"]
item_ids = set(filter(None, os.environ["ITEM_IDS"].split("\n")))

spec = importlib.util.spec_from_file_location(
    "settlement_processor", os.path.join(script_dir, "settlement-processor.py"))
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)
settlement = sp.Settlement(sp.Path(kdir))

now = sp.utc_now()
batch_id = "confirmer-" + hashlib.sha256((now + str(len(item_ids))).encode()).hexdigest()[:16]

with sp.repo_lock(settlement.state):
    queue = settlement.load_queue()
    stamped = []
    leased, sampled, pending = [], [], []
    for item in queue.get("items", []):
        if item.get("id") in item_ids and item.get("status") == "pending":
            item["selection_score"] = None
            item["selection_reason"] = "confirmer_sample"
            item["batch_id"] = batch_id
            item["updated_at"] = now
            sampled.append(item)
            stamped.append(item["id"])
        elif item.get("status") == "leased":
            leased.append(item)
        else:
            pending.append(item)
    queue["items"] = leased + sampled + pending
    queue["batch"] = {
        "id": batch_id,
        "recomputed_at": now,
        "size": len([it for it in queue["items"] if it.get("status") == "pending"]),
        "backlog_size": len(sampled) + len([it for it in pending if it.get("status") == "pending"]),
        "recompute_reason": "confirmer_sample",
        "errors": [],
    }
    settlement.save_queue(queue)
print(len(stamped))
PY_EOF
  ); then
    :
  else
    STAMPED=0
    echo "[confirmer-sample] warning: selection_reason stamp failed — enqueued items remain but will compete in the next queue recompute" >&2
  fi
fi

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(printf '%s' "$PLAN" | jq --argjson budget "$BUDGET" \
    --argjson enqueued "$ENQUEUED" --argjson duplicates "$DUPLICATES" \
    --argjson failed "$FAILED" --argjson stamped "${STAMPED:-0}" \
    '{ok: true, dry_run: false, budget: $budget, held_reports, held_entries, eligible, skipped,
      enqueued: $enqueued, duplicates: $duplicates, failed: $failed, stamped: $stamped,
      selected: [.selected[] | {entry_path, work_item, claim_id, item_id}]}')"
fi

echo "[confirmer-sample] enqueued $ENQUEUED confirmer audit(s) (budget $BUDGET, eligible $(printf '%s' "$PLAN" | jq '.eligible'), duplicates $DUPLICATES, failed $FAILED, stamped ${STAMPED:-0})"
