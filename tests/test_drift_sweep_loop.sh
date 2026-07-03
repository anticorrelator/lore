#!/usr/bin/env bash
# test_drift_sweep_loop.sh — end-to-end acceptance for drift-sweep's re-enqueue
# loop against a synthetic knowledge store + source git repo.
#
# Capabilities proven:
#   1. A drifted entry (related_file modified after captured_at_sha) is
#      synthesized into a producer row AND enqueued as exactly one commons item.
#   2. Re-running the sweep enqueues zero additional items (queue-dedupe
#      idempotence via the deterministic claim_id).
#   3. An entry whose related_file is unchanged since captured_at_sha is
#      classified unchanged: no producer row, no enqueue.
#   4. --dry-run performs no writes and reports would_synthesize/would_queue.
#   5. --include-unaudited plans unchanged confidence:unaudited entries with
#      enqueue_reason=unaudited; --unaudited-only enqueues only that cohort.
#   6. A completed settlement run with a real verdict suppresses the unaudited
#      arm (reported already_settled), while the drift arm is unaffected.
#   7. After the work item is archived, producer rows append under
#      _work/_archive/<slug>/ (promote-commons-append.sh fallback).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
SWEEP="$SCRIPTS_DIR/drift-sweep.sh"
WORK_ITEM="proactive-drift-sweep-re-hash-commons-snippets-vs"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
KDIR="$TEST_DIR/knowledge"
SRC="$TEST_DIR/src"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; echo "    Expected: $expected"; echo "    Actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

git_src() { git -C "$SRC" "$@"; }

queue_commons_count() {
  python3 -c '
import json, os, sys
p = os.path.join(sys.argv[1], "_settlement", "queue.json")
items = json.load(open(p)).get("items", []) if os.path.exists(p) else []
print(sum(1 for i in items if i.get("kind") == "commons"))
' "$KDIR"
}

producer_row_count() {
  local f="$KDIR/_work/$WORK_ITEM/promoted-commons.jsonl"
  [[ -f "$f" ]] || f="$KDIR/_work/_archive/$WORK_ITEM/promoted-commons.jsonl"
  if [[ -f "$f" ]]; then grep -c . "$f" | tr -d ' '; else echo 0; fi
}

entry_state() {
  # entry_state <report-json> <entry_path> <field>...
  local report="$1" entry="$2"; shift 2
  printf '%s' "$report" | python3 -c '
import json, sys
entry = sys.argv[1]
fields = sys.argv[2:]
for e in json.load(sys.stdin)["entries"]:
    if e["entry_path"] == entry:
        print(" ".join(str(e.get(f)) for f in fields)); break
' "$entry" "$@"
}

# --- Build the source repo with a baseline commit ---
mkdir -p "$SRC"
git_src init -q
printf 'def stable():\n    return 1\n' > "$SRC/stable.py"
printf 'def churny():\n    return 1\n' > "$SRC/churny.py"
git_src add -A
git_src -c user.email=t@t -c user.name=t commit -q -m baseline --no-gpg-sign
BASE_SHA=$(git_src rev-parse HEAD)

# --- Build the knowledge store ---
mkdir -p "$KDIR/conventions" "$KDIR/_work/$WORK_ITEM" "$KDIR/_settlement"
echo '{"format_version": 2}' > "$KDIR/_manifest.json"
printf '{"slug":"%s"}\n' "$WORK_ITEM" > "$KDIR/_work/$WORK_ITEM/_meta.json"

write_entry() {
  # write_entry <rel> <h1> <body> <related> <sha> <status> [confidence]
  local rel="$1" h1="$2" body="$3" related="$4" sha="$5" status="$6" confidence="${7:-high}"
  cat > "$KDIR/$rel" <<EOF
# $h1
$body Falsifier: if the cited code reverts.
<!-- learned: 2026-01-01 | confidence: $confidence | source: manual | related_files: $related | scale: subsystem | captured_at_branch: main | captured_at_sha: $sha | status: $status -->
EOF
}

# Drifted entry: churny.py will be modified after BASE_SHA.
write_entry "conventions/drifted-entry.md" "Drifted Entry" \
  "The churny module returns a constant." "churny.py" "$BASE_SHA" "current"
# Clean entry: stable.py never changes.
write_entry "conventions/clean-entry.md" "Clean Entry" \
  "The stable module returns one." "stable.py" "$BASE_SHA" "current"
# Unaudited entry: unchanged code, never audited — only the unaudited arm can
# reach it.
write_entry "conventions/unaudited-entry.md" "Unaudited Entry" \
  "The stable module is stable." "stable.py" "$BASE_SHA" "current" "unaudited"

# --- Drift the source: modify churny.py and commit ---
printf 'def churny():\n    return 2\n' > "$SRC/churny.py"
git_src add -A
git_src -c user.email=t@t -c user.name=t commit -q -m churn --no-gpg-sign

export LORE_KNOWLEDGE_DIR="$KDIR"

echo "=== drift-sweep loop acceptance ==="

# =============================================
# Test 0: dry-run performs no writes
# =============================================
echo ""
echo "Test 0: --dry-run reports would_synthesize/would_queue and writes nothing"
DRY=$(bash "$SWEEP" --dry-run --json --repo-root "$SRC")
DRY_DRIFT=$(printf '%s' "$DRY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["drifted_count"])')
assert_eq "dry-run sees exactly one drifted entry" "$DRY_DRIFT" "1"
DRY_STATE=$(printf '%s' "$DRY" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["entries"]:
    if e.get("drifted"):
        print(e["producer_row"], e["enqueue"]); break
')
assert_eq "dry-run reports would_synthesize would_queue" "$DRY_STATE" "would_synthesize would_queue"
assert_eq "dry-run wrote no producer rows" "$(producer_row_count)" "0"
assert_eq "dry-run enqueued no commons items" "$(queue_commons_count)" "0"

# =============================================
# Test 1: first real sweep synthesizes + enqueues exactly one
# =============================================
echo ""
echo "Test 1: first sweep synthesizes a producer row and enqueues one commons item"
OUT1=$(bash "$SWEEP" --json --repo-root "$SRC")
SWEEP1_EXIT=$?
assert_eq "first sweep exits 0" "$SWEEP1_EXIT" "0"
assert_eq "first sweep enqueued exactly one commons item" "$(queue_commons_count)" "1"
assert_eq "first sweep wrote exactly one producer row" "$(producer_row_count)" "1"
STATE1=$(printf '%s' "$OUT1" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["entries"]:
    if e.get("drifted"):
        print(e["producer_row"], e["enqueue"]); break
')
assert_eq "first sweep reports synthesized queued" "$STATE1" "synthesized queued"
# The producer row carries the deterministic drift- claim_id and entry_path.
CLAIM_ID=$(python3 -c 'import json; print(json.loads(open("'"$KDIR"'/_work/'"$WORK_ITEM"'/promoted-commons.jsonl").readline())["claim_id"])')
assert_eq "producer row claim_id is deterministic drift-<slug>" "$CLAIM_ID" "drift-conventions-drifted-entry"

# =============================================
# Test 2: re-running the sweep enqueues zero additional items (idempotence)
# =============================================
echo ""
echo "Test 2: re-running the sweep is idempotent (dedupe, no new queue items)"
OUT2=$(bash "$SWEEP" --json --repo-root "$SRC")
assert_eq "re-run still has exactly one commons item" "$(queue_commons_count)" "1"
STATE2=$(printf '%s' "$OUT2" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["entries"]:
    if e.get("drifted"):
        print(e["enqueue"]); break
')
assert_eq "re-run reports enqueue=deduped" "$STATE2" "deduped"
# An existing producer row matched on entry_path → no second synthesis.
assert_eq "re-run produced no second producer row" "$(producer_row_count)" "1"
STATE2P=$(printf '%s' "$OUT2" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["entries"]:
    if e.get("drifted"):
        print(e["producer_row"]); break
')
assert_eq "re-run reports producer_row=existing" "$STATE2P" "existing"

# =============================================
# Test 3: the clean entry never enqueues and never synthesizes
# =============================================
echo ""
echo "Test 3: an unchanged entry is classified unchanged with no side effects"
CLEAN=$(printf '%s' "$OUT2" | python3 -c '
import json,sys
for e in json.load(sys.stdin)["entries"]:
    if e["entry_path"] == "conventions/clean-entry.md":
        cls = e["files"][0]["drift_class"] if e.get("files") else "none"
        print(e["drifted"], cls, e["producer_row"], e["enqueue"]); break
')
assert_eq "clean entry: not drifted, unchanged, no writes" "$CLEAN" "False unchanged skipped skipped"

# =============================================
# Test 4: --include-unaudited plans the unaudited cohort; dry-run writes nothing
# =============================================
echo ""
echo "Test 4: --include-unaudited --dry-run plans the unaudited entry, no writes"
OUT4=$(bash "$SWEEP" --include-unaudited --dry-run --json --repo-root "$SRC")
assert_eq "unaudited entry planned with reason=unaudited" \
  "$(entry_state "$OUT4" conventions/unaudited-entry.md drifted enqueue_reason enqueue)" \
  "False unaudited would_queue"
assert_eq "unaudited entry would synthesize a fresh producer row" \
  "$(entry_state "$OUT4" conventions/unaudited-entry.md producer_row)" "would_synthesize"
UNAUD_COUNT=$(printf '%s' "$OUT4" | python3 -c 'import json,sys; print(json.load(sys.stdin)["unaudited_enqueue_count"])')
assert_eq "report counts one planned unaudited enqueue" "$UNAUD_COUNT" "1"
assert_eq "dry-run wrote no new producer rows" "$(producer_row_count)" "1"
assert_eq "dry-run enqueued nothing new" "$(queue_commons_count)" "1"
# Without the flag the same entry stays invisible to the sweep.
OUT4B=$(bash "$SWEEP" --dry-run --json --repo-root "$SRC")
assert_eq "without flag the unaudited entry is not planned" \
  "$(entry_state "$OUT4B" conventions/unaudited-entry.md drifted enqueue)" "False skipped"

# =============================================
# Test 5: --unaudited-only enqueues the cohort and skips purely-drifted entries
# =============================================
echo ""
echo "Test 5: --unaudited-only enqueues only the unaudited entry"
OUT5=$(bash "$SWEEP" --unaudited-only --json --repo-root "$SRC")
assert_eq "unaudited entry synthesized and queued" \
  "$(entry_state "$OUT5" conventions/unaudited-entry.md producer_row enqueue enqueue_reason)" \
  "synthesized queued unaudited"
assert_eq "drifted entry not enqueued under --unaudited-only" \
  "$(entry_state "$OUT5" conventions/drifted-entry.md drifted enqueue)" "True skipped"
assert_eq "queue now holds exactly two commons items" "$(queue_commons_count)" "2"
assert_eq "producer log now holds exactly two rows" "$(producer_row_count)" "2"

# =============================================
# Test 6: a completed run with a real verdict suppresses the unaudited arm
# =============================================
echo ""
echo "Test 6: already-settled unaudited entry is suppressed and reported"
mkdir -p "$KDIR/_settlement/runs"
python3 -c '
import hashlib, json, sys
kdir, work_item = sys.argv[1], sys.argv[2]
claim_id = "drift-conventions-unaudited-entry"
digest = hashlib.sha256(f"commons:{work_item}:{claim_id}".encode()).hexdigest()[:20]
item_id = f"commons-{digest}"
run = {"run_id": f"run-{digest}", "item_id": item_id, "status": "completed",
       "verdict": {"verdict": "verified", "claim_id": claim_id}}
with open(f"{kdir}/_settlement/runs/run-{digest}.json", "w") as fh:
    json.dump(run, fh)
' "$KDIR" "$WORK_ITEM"
OUT6=$(bash "$SWEEP" --include-unaudited --dry-run --json --repo-root "$SRC")
assert_eq "settled unaudited entry reports already_settled, no enqueue" \
  "$(entry_state "$OUT6" conventions/unaudited-entry.md already_settled enqueue)" \
  "True skipped"
SETTLED_COUNT=$(printf '%s' "$OUT6" | python3 -c 'import json,sys; print(json.load(sys.stdin)["already_settled_count"])')
assert_eq "report counts one already-settled suppression" "$SETTLED_COUNT" "1"
assert_eq "drift arm unaffected: drifted entry still planned" \
  "$(entry_state "$OUT6" conventions/drifted-entry.md enqueue_reason enqueue)" \
  "drift would_queue"

# =============================================
# Test 7: archived work item — producer rows append under _work/_archive/<slug>/
# =============================================
echo ""
echo "Test 7: append falls back to _work/_archive/<slug>/ after archival"
mkdir -p "$KDIR/_work/_archive"
mv "$KDIR/_work/$WORK_ITEM" "$KDIR/_work/_archive/$WORK_ITEM"
# A fresh never-audited entry arrives after the work item was archived.
write_entry "conventions/late-unaudited.md" "Late Unaudited Entry" \
  "The stable module is still stable." "stable.py" "$BASE_SHA" "current" "unaudited"
OUT7=$(bash "$SWEEP" --unaudited-only --json --repo-root "$SRC")
SWEEP7_EXIT=$?
assert_eq "archived-item sweep exits 0" "$SWEEP7_EXIT" "0"
assert_eq "late entry synthesized and queued" \
  "$(entry_state "$OUT7" conventions/late-unaudited.md producer_row enqueue enqueue_reason)" \
  "synthesized queued unaudited"
ARCHIVE_LOG="$KDIR/_work/_archive/$WORK_ITEM/promoted-commons.jsonl"
ARCHIVE_ROWS=$(grep -c . "$ARCHIVE_LOG" 2>/dev/null | tr -d ' ' || echo 0)
assert_eq "producer row appended in the archived location" "$ARCHIVE_ROWS" "3"
assert_eq "no active work-item dir was recreated" \
  "$([[ -d "$KDIR/_work/$WORK_ITEM" ]] && echo present || echo absent)" "absent"
assert_eq "queue now holds exactly three commons items" "$(queue_commons_count)" "3"

echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"
[[ "$FAIL" -eq 0 ]]
