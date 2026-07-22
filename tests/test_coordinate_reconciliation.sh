#!/usr/bin/env bash
# End-to-end coverage for immutable stream reconciliation and the eager board join.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/coordinate-reconcile.py"
STATUS="$REPO_ROOT/scripts/coordinate-status.sh"
CONFORMANCE="$REPO_ROOT/scripts/conformance-render.sh"
CLOSE="$REPO_ROOT/scripts/impl-close.sh"
TEST_ROOT=$(mktemp -d)
KDIR="$TEST_ROOT/knowledge"
DATA_DIR="$TEST_ROOT/data"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$KDIR/_work/coordinated" "$KDIR/_coordination/worktrees/registry" \
  "$KDIR/_coordination/worktrees/archive" "$KDIR/_sessions/instances" \
  "$KDIR/_scorecards" "$KDIR/_evolve" "$DATA_DIR/config"

cat >"$DATA_DIR/config/settings.json" <<'JSON'
{"version":1,"tui_launch_framework":"codex","harnesses":{"codex":{"args":[]}},"settlement":{"max_concurrency":2}}
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
cat >"$KDIR/_work/coordinated/coordination.md" <<'EOF'
| # | Step | Depends on | Tree | Status | Verdict | Evidence |
|---|---|---|---|---|---|---|
| stream-a | Produce A | — | writer | done | full | source-a |
| stream-b | Integrate B | stream-a | writer | pending | — | — |
| stream-c | Unrelated writer | — | writer | in-flight | — | live-c |
EOF

# A real repository backs the reconciler's git_common_dir. Acceptance refs are
# pinned into it at freeze-integrated, so their targets must be real commits.
REPO="$TEST_ROOT/repo"
COMMON="$REPO/.git"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit -q --allow-empty -m base
mkcommit() { git -C "$REPO" commit -q --allow-empty -m "$1" && git -C "$REPO" rev-parse HEAD; }

SRC_A=$(mkcommit src-a)
INT_A=$(mkcommit int-a)
SRC_D=$(mkcommit src-d)
INT_D=$(mkcommit int-d)

write_identity() {
  local id="$1" stream="$2" attempt="$3" item="${4:-coordinated}"
  cat >"$KDIR/_coordination/worktrees/registry/$id.json" <<JSON
{"schema_version":1,"worktree_id":"$id","execution_dir":"$TEST_ROOT/$id","temporary_branch":"refs/heads/$id","git_common_dir":"$COMMON","allocation_base_sha":"base-$id","owner_item":"$item","stream_id":"$stream","attempt_id":"$attempt","owner":{"kind":"seat","id":"seat-1"},"lease":{"duration_seconds":900,"renewed_at":"2026-07-21T00:00:00Z","expires_at":"2099-07-21T00:15:00Z"},"guard_identity":{},"state":"quiescent","lifecycle":[]}
JSON
}

write_identity wt-a stream-a attempt-1
printf 'diff --git a/a.txt b/a.txt\n' >"$TEST_ROOT/source-a.patch"
printf 'diff --git a/a.txt b/a.txt\n+integrated\n' >"$TEST_ROOT/integrated-a.patch"

python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --worktree-id wt-a --tree writer \
  --patch "$TEST_ROOT/source-a.patch" --head-sha "$SRC_A" --changed-path a.txt --json >/dev/null
python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug coordinated \
  --stream stream-a --attempt attempt-1 --patch "$TEST_ROOT/integrated-a.patch" \
  --integrated-sha "$INT_A" --changed-path a.txt --verdict full --json >/dev/null

# Acceptance refs are pinned at freeze-integrated, resolving to the recorded SHAs.
A_INT_REF="refs/lore/accepted/coordinated/stream-a/attempt-1/integrated"
A_SRC_REF="refs/lore/accepted/coordinated/stream-a/attempt-1/source"
[[ "$(git --git-dir="$COMMON" rev-parse "$A_INT_REF")" == "$INT_A" ]]
[[ "$(git --git-dir="$COMMON" rev-parse "$A_SRC_REF")" == "$SRC_A" ]]

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
    "verified_at": "2026-07-21T00:10:00Z",
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(row, handle)
os.unlink(source)
PY

RECON_STATUS=$(python3 "$RECONCILE" status --kdir "$KDIR" --slug coordinated --json)
jq -e '.valid and .streams[0].attempts[0].terminal_full_cleaned' <<<"$RECON_STATUS" >/dev/null

BOARD=$(LORE_DATA_DIR="$DATA_DIR" bash "$STATUS" --kdir "$KDIR" --json)
jq -e '.coordination_dispatch.concurrency_ceiling == 2 and .coordination_dispatch.active_attempts == 1' <<<"$BOARD" >/dev/null
jq -e '[.buckets.act_now[] | select(.kind=="ready-stream" and .observed_facts.stream_id=="stream-b")] | length == 1' <<<"$BOARD" >/dev/null
jq -e '[.buckets.act_now[] | select(.observed_facts.stream_id=="stream-c")] | length == 0' <<<"$BOARD" >/dev/null

# The coordinator's merge verb leaves clean composition staged for audit, but
# records and aborts conflicts so source edits remain a worker responsibility.
CONTROL="$TEST_ROOT/control"
git init -q "$CONTROL"
git -C "$CONTROL" config user.email test@example.com
git -C "$CONTROL" config user.name Test
printf 'base\n' >"$CONTROL/shared.txt"
git -C "$CONTROL" add shared.txt
git -C "$CONTROL" commit -qm base
git -C "$CONTROL" checkout -qb source-e
printf 'source\n' >"$CONTROL/shared.txt"
git -C "$CONTROL" commit -qam source
git -C "$CONTROL" checkout -q master 2>/dev/null || git -C "$CONTROL" checkout -q main
printf 'control\n' >"$CONTROL/shared.txt"
git -C "$CONTROL" commit -qam control
write_identity wt-e stream-e attempt-1
python3 - "$KDIR/_coordination/worktrees/registry/wt-e.json" <<'PY'
import json, sys
path = sys.argv[1]
row = json.load(open(path, encoding="utf-8"))
row["temporary_branch"] = "source-e"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(row, handle)
PY
printf 'source e\n' >"$TEST_ROOT/source-e.patch"
python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug coordinated \
  --stream stream-e --attempt attempt-1 --worktree-id wt-e --tree writer \
  --patch "$TEST_ROOT/source-e.patch" --head-sha source-e --changed-path shared.txt --json >/dev/null
CONFLICT=$(python3 "$RECONCILE" merge --kdir "$KDIR" --slug coordinated \
  --stream stream-e --attempt attempt-1 --repo "$CONTROL" --json)
jq -e '.status == "needs_judgment" and .merge_aborted and (.conflicts == ["shared.txt"])' <<<"$CONFLICT" >/dev/null
[[ ! -f "$CONTROL/.git/MERGE_HEAD" ]]
[[ -z "$(git -C "$CONTROL" status --porcelain)" ]]

git -C "$CONTROL" checkout -qb source-f
printf 'clean\n' >"$CONTROL/clean.txt"
git -C "$CONTROL" add clean.txt
git -C "$CONTROL" commit -qm clean-source
git -C "$CONTROL" checkout -q master 2>/dev/null || git -C "$CONTROL" checkout -q main
write_identity wt-f stream-f attempt-1
python3 - "$KDIR/_coordination/worktrees/registry/wt-f.json" <<'PY'
import json, sys
path = sys.argv[1]
row = json.load(open(path, encoding="utf-8"))
row["temporary_branch"] = "source-f"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(row, handle)
PY
printf 'source f\n' >"$TEST_ROOT/source-f.patch"
python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug coordinated \
  --stream stream-f --attempt attempt-1 --worktree-id wt-f --tree writer \
  --patch "$TEST_ROOT/source-f.patch" --head-sha source-f --changed-path clean.txt --json >/dev/null
MERGE_READY=$(python3 "$RECONCILE" merge --kdir "$KDIR" --slug coordinated \
  --stream stream-f --attempt attempt-1 --repo "$CONTROL" --json)
jq -e '.status == "merge_ready" and .source_ref == "source-f"' <<<"$MERGE_READY" >/dev/null
[[ -f "$CONTROL/.git/MERGE_HEAD" ]]
git -C "$CONTROL" merge --abort

LORE_DATA_DIR="$DATA_DIR" LORE_KNOWLEDGE_DIR="$KDIR" \
  bash "$CONFORMANCE" coordinated --diff-base HEAD --json >/dev/null
python3 - "$KDIR/_work/coordinated/closure-conformance.md" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r"## Machine Aggregate\n\n```json\n(.*?)\n```", text, re.S)
assert match
doc = json.loads(match.group(1))
assert doc["schema_version"] == 2
assert doc["stream_diffs"][0]["source_only_paths"] == []
assert doc["stream_diffs"][0]["terminal_full_cleaned"] is True
PY

# A second integrated writer without archive cleanup makes close fail before it
# writes a closure verdict or reconciles checkboxes.
write_identity wt-d stream-d attempt-1
printf 'diff --git a/d.txt b/d.txt\n' >"$TEST_ROOT/source-d.patch"
printf 'diff --git a/d.txt b/d.txt\n+integrated\n' >"$TEST_ROOT/integrated-d.patch"
python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug coordinated \
  --stream stream-d --attempt attempt-1 --worktree-id wt-d --tree writer \
  --patch "$TEST_ROOT/source-d.patch" --head-sha "$SRC_D" --changed-path d.txt --json >/dev/null
python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug coordinated \
  --stream stream-d --attempt attempt-1 --patch "$TEST_ROOT/integrated-d.patch" \
  --integrated-sha "$INT_D" --changed-path d.txt --verdict full --json >/dev/null
set +e
CLOSE_OUTPUT=$(LORE_DATA_DIR="$DATA_DIR" LORE_KNOWLEDGE_DIR="$KDIR" \
  bash "$CLOSE" coordinated --verdict full --summary "coordinated close" 2>&1)
CLOSE_RC=$?
set -e
[[ $CLOSE_RC -eq 1 ]]
[[ "$CLOSE_OUTPUT" == *"cleanup is unproven"* ]]
jq -e 'has("closure") | not' "$KDIR/_work/coordinated/_meta.json" >/dev/null

# Content-addressed objects are actively revalidated, not trusted by path.
OBJECT=$(jq -r '.streams[0].attempts[0].source_manifest.path' "$KDIR/_coordination/reconciliation/coordinated/streams.json")
printf 'tamper\n' >>"$KDIR/$OBJECT"
TAMPERED=$(python3 "$RECONCILE" status --kdir "$KDIR" --slug coordinated --json)
jq -e '.valid == false' <<<"$TAMPERED" >/dev/null

# Acceptance-ref behaviors on an isolated slug: verdict coverage, idempotency,
# immutability, status audit, and pre-feature backward compatibility.
freeze_accepted() {
  local stream="$1" verdict="$2" src="$3" integrated="$4"
  local wt="wt-$stream"
  write_identity "$wt" "$stream" attempt-1 accepted
  printf 'diff --git a/%s.txt b/%s.txt\n' "$stream" "$stream" >"$TEST_ROOT/$stream-src.patch"
  printf 'diff --git a/%s.txt b/%s.txt\n+x\n' "$stream" "$stream" >"$TEST_ROOT/$stream-int.patch"
  python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug accepted \
    --stream "$stream" --attempt attempt-1 --worktree-id "$wt" --tree writer \
    --patch "$TEST_ROOT/$stream-src.patch" --head-sha "$src" --changed-path "$stream.txt" --json >/dev/null
  python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug accepted \
    --stream "$stream" --attempt attempt-1 --patch "$TEST_ROOT/$stream-int.patch" \
    --integrated-sha "$integrated" --changed-path "$stream.txt" --verdict "$verdict" --json >/dev/null
}

assert_accepted_refs() {
  local stream="$1" src="$2" integrated="$3"
  local base="refs/lore/accepted/accepted/$stream/attempt-1"
  [[ "$(git --git-dir="$COMMON" rev-parse "$base/integrated")" == "$integrated" ]]
  [[ "$(git --git-dir="$COMMON" rev-parse "$base/source")" == "$src" ]]
}

# Refs are pinned for every verdict, mirroring the object store.
SRC_FULL=$(mkcommit src-full); INT_FULL=$(mkcommit int-full)
SRC_PART=$(mkcommit src-part); INT_PART=$(mkcommit int-part)
SRC_NONE=$(mkcommit src-none); INT_NONE=$(mkcommit int-none)
freeze_accepted stream-full full "$SRC_FULL" "$INT_FULL"
freeze_accepted stream-partial partial "$SRC_PART" "$INT_PART"
freeze_accepted stream-none none "$SRC_NONE" "$INT_NONE"
assert_accepted_refs stream-full "$SRC_FULL" "$INT_FULL"
assert_accepted_refs stream-partial "$SRC_PART" "$INT_PART"
assert_accepted_refs stream-none "$SRC_NONE" "$INT_NONE"

# Re-running freeze-integrated with identical arguments is idempotent.
python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug accepted \
  --stream stream-full --attempt attempt-1 --patch "$TEST_ROOT/stream-full-int.patch" \
  --integrated-sha "$INT_FULL" --changed-path stream-full.txt --verdict full --json >/dev/null
assert_accepted_refs stream-full "$SRC_FULL" "$INT_FULL"

# A different integrated SHA for the same attempt fails on the immutability rule.
set +e
IMMUTABLE_OUT=$(python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug accepted \
  --stream stream-full --attempt attempt-1 --patch "$TEST_ROOT/stream-full-int.patch" \
  --integrated-sha "$INT_PART" --changed-path stream-full.txt --verdict full --json 2>&1)
IMMUTABLE_RC=$?
set -e
[[ $IMMUTABLE_RC -ne 0 ]]
[[ "$IMMUTABLE_OUT" == *immutable* ]]

# status marks an attempt invalid when an acceptance ref is deleted out from under it.
git --git-dir="$COMMON" update-ref -d "refs/lore/accepted/accepted/stream-full/attempt-1/integrated"
ACCEPTED_STATUS=$(python3 "$RECONCILE" status --kdir "$KDIR" --slug accepted --json)
jq -e '.valid == false' <<<"$ACCEPTED_STATUS" >/dev/null
jq -e '[.streams[] | select(.stream_id=="stream-full") | .attempts[0]][0] | .valid == false and (.validation_error | test("acceptance ref"))' <<<"$ACCEPTED_STATUS" >/dev/null
jq -e '[.streams[] | select(.stream_id=="stream-partial") | .attempts[0]][0] | .valid == true' <<<"$ACCEPTED_STATUS" >/dev/null

# A pre-feature integrated manifest (no acceptance_refs metadata) skips the audit
# and stays valid even when its refs are absent.
SRC_LEG=$(mkcommit src-legacy); INT_LEG=$(mkcommit int-legacy)
freeze_accepted stream-legacy full "$SRC_LEG" "$INT_LEG"
python3 - "$KDIR" accepted stream-legacy attempt-1 <<'PY'
import hashlib, json, sys
kdir, slug, stream, attempt = sys.argv[1:5]
streams_path = f"{kdir}/_coordination/reconciliation/{slug}/streams.json"
state = json.load(open(streams_path, encoding="utf-8"))
ref = next(a["integrated_manifest"] for s in state["streams"] if s["stream_id"] == stream
           for a in s["attempts"] if a["attempt_id"] == attempt)
manifest = json.load(open(f"{kdir}/{ref['path']}", encoding="utf-8"))
manifest.pop("acceptance_refs", None)
body = (json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
new_hash = hashlib.sha256(body).hexdigest()
rel = f"_coordination/reconciliation/{slug}/objects/sha256-{new_hash}.json"
open(f"{kdir}/{rel}", "wb").write(body)
ref["sha256"], ref["path"] = new_hash, rel
json.dump(state, open(streams_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
git --git-dir="$COMMON" update-ref -d "refs/lore/accepted/accepted/stream-legacy/attempt-1/integrated"
git --git-dir="$COMMON" update-ref -d "refs/lore/accepted/accepted/stream-legacy/attempt-1/source"
LEGACY_STATUS=$(python3 "$RECONCILE" status --kdir "$KDIR" --slug accepted --json)
jq -e '[.streams[] | select(.stream_id=="stream-legacy") | .attempts[0]][0] | .valid == true' <<<"$LEGACY_STATUS" >/dev/null

echo "coordinate reconciliation tests passed"
