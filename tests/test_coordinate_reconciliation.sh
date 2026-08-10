#!/usr/bin/env bash
# End-to-end coverage for the attempt record and the board join that reads it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/coordinate-reconcile.py"
STATUS="$REPO_ROOT/scripts/coordinate-status.sh"
TEST_ROOT=$(mktemp -d)
KDIR="$TEST_ROOT/knowledge"
DATA_DIR="$TEST_ROOT/data"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$KDIR/_work/coordinated" "$KDIR/_coordination/worktrees/registry" \
  "$KDIR/_coordination/worktrees/archive" "$KDIR/_sessions/instances" \
  "$KDIR/_scorecards" "$KDIR/_evolve" "$DATA_DIR/config"

# The settlement ceiling is a decoy: it is the key the board used to read, and
# it disagrees with the coordination key on purpose. A board that reports 9
# seats below is still reading the retired path.
cat >"$DATA_DIR/config/settings.json" <<'JSON'
{"version":1,"tui_launch_framework":"codex","harnesses":{"codex":{"args":[]}},"coordination":{"max_concurrency":2},"settlement":{"max_concurrency":9}}
JSON
cat >"$KDIR/_work/_index.json" <<'JSON'
{"version":1,"plans":[{"slug":"coordinated","title":"Coordinated","status":"active","blocked_by":[],"has_plan_doc":true,"has_execution_log":false}],"archived":[]}
JSON
cat >"$KDIR/_work/coordinated/_meta.json" <<'JSON'
{"slug":"coordinated","title":"Coordinated","status":"active","blocked_by":[],"intent_anchor":"Ship coordinated streams"}
JSON
cat >"$KDIR/_work/coordinated/plan.md" <<'EOF'
## Phases
- [ ] Ship coordinated streams
EOF
cat >"$KDIR/_work/coordinated/tasks.json" <<'JSON'
{"phases":[{"tasks":[{"id":"task-1","subject":"Ship coordinated streams","blockedBy":[],"tree":"writer"}]}]}
JSON
# The board reads the ledger from the arc record; the attempt store is keyed by
# the same identity.
mkdir -p "$KDIR/_work/_arcs/coordinated"
cat >"$KDIR/_work/_arcs/coordinated/_meta.json" <<'JSON'
{"schema_version":1,"slug":"coordinated","title":"Coordinated","status":"active","members":["coordinated"]}
JSON
cat >"$KDIR/_work/_arcs/coordinated/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict | Evidence |
|---|---|---|---|---|---|---|
| stream-a | Produce A | — | writer | done | full | 9f2c1ab, 104/104 |
| stream-b | Integrate B | stream-a | writer | pending | — | — |
| stream-c | Unrelated writer | — | writer | in-flight | — | live-c |
EOF

REPO="$TEST_ROOT/repo"
COMMON="$REPO/.git"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit -q --allow-empty -m base

write_identity() {
  local id="$1" stream="$2" attempt="$3" item="${4:-coordinated}"
  cat >"$KDIR/_coordination/worktrees/registry/$id.json" <<JSON
{"schema_version":1,"worktree_id":"$id","execution_dir":"$TEST_ROOT/$id","temporary_branch":"refs/heads/$id","git_common_dir":"$COMMON","allocation_base_sha":"base-$id","owner_item":"$item","stream_id":"$stream","attempt_id":"$attempt","owner":{"kind":"seat","id":"seat-1"},"lease":{"duration_seconds":900,"renewed_at":"2026-07-21T00:00:00Z","expires_at":"2099-07-21T00:15:00Z"},"guard_identity":{},"state":"quiescent","lifecycle":[]}
JSON
}

# stream-a is finished: its attempt has been carried to report acceptance, which
# is what releases the stream. The account of what it shipped lives in the
# ledger's Evidence column, not here.
write_identity wt-a stream-a attempt-1
python3 "$RECONCILE" register-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --tree writer --worktree-id wt-a --json >/dev/null
python3 "$RECONCILE" advance-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --expected-status coord_allocated \
  --to coord_dispatched --json >/dev/null
python3 "$RECONCILE" advance-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --expected-status coord_dispatched \
  --to coord_report_accepted --json >/dev/null

# The tree is torn down and archived. The attempt record keeps pointing at it,
# and the lookup answers with the manager's own cleanup proof rather than a
# second opinion rebuilt from its parts.
python3 - "$KDIR/_coordination/worktrees/registry/wt-a.json" \
  "$KDIR/_coordination/worktrees/archive/wt-a.json" <<'PY'
import json, os, sys
source, target = sys.argv[1:]
row = json.load(open(source, encoding="utf-8"))
row["state"] = "removed"
row["cleanup_proof"] = {
    "path_absent": True,
    "git_registry_absent": True,
    "branch_disposition": "deleted",
    "verified": True,
    "verified_at": "2026-07-21T00:10:00Z",
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(row, handle)
os.unlink(source)
PY

LOOKUP=$(python3 "$RECONCILE" lookup-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --json)
jq -e '.outcome == "coord_lookup_resolved"' <<<"$LOOKUP" >/dev/null
jq -e '.status == "coord_report_accepted"' <<<"$LOOKUP" >/dev/null
jq -e '.worktree.record_source == "archive"' <<<"$LOOKUP" >/dev/null
jq -e '.worktree.cleanup_proof.verified == true' <<<"$LOOKUP" >/dev/null

# stream-c holds its stream: its attempt has been dispatched and not accepted,
# so the board must not offer it for redispatch.
write_identity wt-c stream-c attempt-1
python3 "$RECONCILE" register-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-c --attempt attempt-1 --tree writer --worktree-id wt-c --json >/dev/null
python3 "$RECONCILE" advance-attempt --kdir "$KDIR" --slug coordinated \
  --stream stream-c --attempt attempt-1 --expected-status coord_allocated \
  --to coord_dispatched --json >/dev/null

BOARD=$(LORE_DATA_DIR="$DATA_DIR" bash "$STATUS" --kdir "$KDIR" --json)
jq -e '.coordination_dispatch.concurrency_ceiling == 2 and .coordination_dispatch.active_attempts == 1' <<<"$BOARD" >/dev/null
# stream-b's predecessor is recorded done/full, so it is ready.
jq -e '[.buckets.act_now[] | select(.kind=="ready-stream" and .observed_facts.stream_id=="stream-b")] | length == 1' <<<"$BOARD" >/dev/null
jq -e '[.buckets.act_now[] | select(.observed_facts.stream_id=="stream-c")] | length == 0' <<<"$BOARD" >/dev/null
jq -e '[.buckets.waiting[] | select(.kind=="active-stream-attempt" and .observed_facts.stream_id=="stream-c")] | length == 1' <<<"$BOARD" >/dev/null

# A predecessor the ledger has not called full holds its dependants back, and
# says which of the two ways it is unfinished.
python3 - "$KDIR/_work/_arcs/coordinated/coordination.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read().replace(
    "| stream-a | Produce A | — | writer | done | full | 9f2c1ab, 104/104 |",
    "| stream-a | Produce A | — | writer | done | partial | 9f2c1ab, 101/104 |")
open(path, "w", encoding="utf-8").write(text)
PY
PARTIAL_BOARD=$(LORE_DATA_DIR="$DATA_DIR" bash "$STATUS" --kdir "$KDIR" --json)
jq -e '[.buckets.needs_judgment[] | select(.kind=="predecessor-not-full")] | length == 1' <<<"$PARTIAL_BOARD" >/dev/null
jq -e '[.buckets.act_now[] | select(.observed_facts.stream_id=="stream-b")] | length == 0' <<<"$PARTIAL_BOARD" >/dev/null

# An unreadable attempt record is reported as one reconcile row, not as an
# absence that would silently free every stream for redispatch.
printf 'not json\n' >"$KDIR/_coordination/reconciliation/coordinated/streams.json"
BROKEN_BOARD=$(LORE_DATA_DIR="$DATA_DIR" bash "$STATUS" --kdir "$KDIR" --json)
jq -e '[.buckets.reconcile[] | select(.kind=="coordination-reconciliation-invalid")] | length == 1' <<<"$BROKEN_BOARD" >/dev/null

echo "coordinate reconciliation tests passed"
