#!/usr/bin/env bash
# End-to-end lifecycle tests for the sole stream-worktree manager.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$REPO_ROOT/scripts/coordinate-worktree.sh"
RECONCILE="$REPO_ROOT/scripts/coordinate-reconcile.py"
CLI="$REPO_ROOT/cli/lore"
TEST_ROOT="$(mktemp -d)"
KDIR="$TEST_ROOT/store"
SOURCE="$TEST_ROOT/source"
GUARD="$TEST_ROOT/lore-worktree-guard"
export GOCACHE="$TEST_ROOT/go-cache"
export LORE_WORKTREE_GUARD="$GUARD"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_file() { if [[ -f "$2" ]]; then pass "$1"; else fail "$1" "missing $2"; fi; }
assert_dir() { if [[ -d "$2" ]]; then pass "$1"; else fail "$1" "missing $2"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1" "still exists: $2"; fi; }

cleanup() {
  git -C "$SOURCE" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / {print substr($0,10)}' \
    | while IFS= read -r path; do
        [[ "$path" == "$SOURCE" ]] || git -C "$SOURCE" worktree remove --force "$path" >/dev/null 2>&1 || true
      done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

mkdir -p "$KDIR/_work/demo" "$SOURCE"
KDIR_CANON="$(cd "$KDIR" && pwd -P)"
git -C "$SOURCE" init -b main >/dev/null
git -C "$SOURCE" config user.name Test
git -C "$SOURCE" config user.email test@example.com
printf 'base\n' > "$SOURCE/tracked.txt"
git -C "$SOURCE" add tracked.txt
git -C "$SOURCE" commit -m base >/dev/null

(cd "$REPO_ROOT/tui" && go build -o "$GUARD" ./cmd/lore-worktree-guard)
if [[ $? -ne 0 ]]; then
  echo "FAIL: could not build guard bridge"
  exit 1
fi

allocate() {
  local attempt="$1" owner_id="$2"; shift 2
  bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
    --attempt "$attempt" --owner-kind seat --owner-id "$owner_id" \
    --source-dir "$SOURCE" --json "$@"
}

# Everything up to the release, which is the last call a seat makes: entering
# cleanup_due is what takes the tree down.
drive_to_release() {
  local id="$1" owner="$2"
  bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$id" --owner-id "$owner" --json >/dev/null
  # A repeated bind is the post-spawn owner-probe attachment path.
  bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$id" --owner-id "$owner" --json >/dev/null
  for state in active quiescent reconciling; do
    bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$id" --to "$state" --json >/dev/null
  done
}

echo "=== test_coordinate_worktree.sh ==="

ALLOC="$(allocate normal seat-normal)"
WT_ID="$(jq -r '.worktree_id' <<<"$ALLOC")"
WT_PATH="$(jq -r '.execution_dir' <<<"$ALLOC")"
BRANCH="$(jq -r '.temporary_branch' <<<"$ALLOC")"
assert_eq "allocation starts reserved" "reserved" "$(jq -r '.state' <<<"$ALLOC")"
assert_eq "execution path uses manager namespace" "$KDIR_CANON/_coordination/worktrees/trees/$WT_ID" "$WT_PATH"
assert_eq "temporary branch is checked out" "$BRANCH" "$(git -C "$WT_PATH" branch --show-current)"
assert_eq "guard identity validates after manager branch creation" "$WT_PATH" \
  "$(jq -r '.guard_identity.canonical_path' <<<"$ALLOC")"

# Allocation is the stream's birth, so the seat never has to hand a worktree id
# back to the reconciler — it asks for the tree by stream and attempt instead.
STREAMS="$KDIR/_coordination/reconciliation/demo/streams.json"
assert_eq "allocation registers the stream lifecycle record" "true" \
  "$(jq -r '.lifecycle.registered' <<<"$ALLOC")"
LOOKUP="$(python3 "$RECONCILE" lookup-attempt --kdir "$KDIR" --slug demo \
  --stream stream-a --attempt normal --json)"
assert_eq "the record answers by stream and attempt" "coord_lookup_resolved" \
  "$(jq -r '.outcome' <<<"$LOOKUP")"
assert_eq "the answer carries the allocated tree" "$WT_ID" "$(jq -r '.worktree_id' <<<"$LOOKUP")"
assert_eq "the attempt is born allocated" "coord_allocated" "$(jq -r '.status' <<<"$LOOKUP")"

# --- The release is the teardown ---------------------------------------------
# Releasing a tree and removing it were two calls, and the second was the one
# that went missing: eleven of fifteen reclaims were finishing a teardown whose
# owner had already asked for it. One call now does both.
drive_to_release "$WT_ID" seat-normal
printf 'unstaged\n' >> "$WT_PATH/tracked.txt"
RELEASED="$(bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$WT_ID" --to cleanup_due --json)"
ARCHIVE="$KDIR/_coordination/worktrees/archive/$WT_ID.json"
assert_eq "the release reaches removed in one call" "removed" "$(jq -r '.state' <<<"$RELEASED")"
assert_eq "release proves all three terminal conditions" "true" \
  "$(jq -r '.cleanup_proof.path_absent and .cleanup_proof.git_registry_absent and (.cleanup_proof.branch_disposition=="deleted") and .cleanup_proof.verified' <<<"$RELEASED")"
assert_absent "the release removes the physical path" "$WT_PATH"
assert_file "terminal record is archived" "$ARCHIVE"
assert_eq "no registry row survives the release" "0" \
  "$(find "$KDIR/_coordination/worktrees/registry" -name "$WT_ID.json" | wc -l | tr -d ' ')"
assert_eq "no claim row survives the release" "0" \
  "$(find "$KDIR/_coordination/worktrees/claims" -name "$WT_ID.json" | wc -l | tr -d ' ')"
# This owner committed nothing, so there is no tip to preserve and the proof
# says so rather than naming a ref that does not exist.
assert_eq "an uncommitted tree records no quarantine ref" "null" \
  "$(jq -r '.cleanup_proof.quarantine_ref' <<<"$RELEASED")"

# --- Committed work outlives the branch that held it -------------------------
# The temporary branch is deleted at teardown, which is the only thing making
# its commits unreachable. A ref pinned at the tip beforehand keeps them, for
# the cost of one Git command.
ACCEPT="$(allocate accept-anchor accept-seat)"
ACCEPT_ID="$(jq -r '.worktree_id' <<<"$ACCEPT")"
ACCEPT_PATH="$(jq -r '.execution_dir' <<<"$ACCEPT")"
ACCEPT_BRANCH="$(jq -r '.temporary_branch' <<<"$ACCEPT")"
ACCEPT_COMMON="$(jq -r '.git_common_dir' "$KDIR/_coordination/worktrees/registry/$ACCEPT_ID.json")"
printf 'accepted\n' > "$ACCEPT_PATH/accepted.txt"
git -C "$ACCEPT_PATH" add accepted.txt
git -C "$ACCEPT_PATH" commit -qm accepted-tip
TIP="$(git -C "$ACCEPT_PATH" rev-parse HEAD)"
drive_to_release "$ACCEPT_ID" accept-seat
TORN="$(bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$ACCEPT_ID" --to cleanup_due --json)"
assert_eq "a committed tree's teardown proof verifies" "true" "$(jq -r '.cleanup_proof.verified' <<<"$TORN")"
assert_eq "the proof names the quarantine ref" "refs/lore/quarantine/$ACCEPT_ID" \
  "$(jq -r '.cleanup_proof.quarantine_ref' <<<"$TORN")"
assert_eq "the proof names the sha it preserved" "$TIP" "$(jq -r '.cleanup_proof.quarantine_sha' <<<"$TORN")"
assert_eq "temporary branch is deleted" "deleted" "$(jq -r '.cleanup_proof.branch_disposition' <<<"$TORN")"
assert_absent "the checkout is gone" "$ACCEPT_PATH"
git --git-dir="$ACCEPT_COMMON" show-ref --verify --quiet "refs/heads/$ACCEPT_BRANCH"
assert_eq "the branch ref is gone" "1" "$?"
assert_eq "the committed tip survives on the quarantine ref" "$TIP" \
  "$(git --git-dir="$ACCEPT_COMMON" rev-parse "refs/lore/quarantine/$ACCEPT_ID")"
git --git-dir="$ACCEPT_COMMON" merge-base --is-ancestor "$TIP" main
assert_eq "the tip is not reachable from main" "1" "$?"

# --- A teardown that cannot finish leaves the tree retryable -----------------
BLOCKED="$(allocate teardown-failure blocked-seat)"
BLOCKED_ID="$(jq -r '.worktree_id' <<<"$BLOCKED")"
BLOCKED_PATH="$(jq -r '.execution_dir' <<<"$BLOCKED")"
drive_to_release "$BLOCKED_ID" blocked-seat
LORE_WORKTREE_FAIL_REMOVE=1 bash "$MANAGER" transition --kdir "$KDIR" \
  --worktree-id "$BLOCKED_ID" --to cleanup_due --json >/dev/null 2>&1
assert_eq "an injected removal failure is non-zero" "1" "$?"
BLOCKED_MANIFEST="$KDIR/_coordination/worktrees/registry/$BLOCKED_ID.json"
assert_file "a failed teardown returns the record to the registry" "$BLOCKED_MANIFEST"
assert_eq "a failed teardown is one state short of released" "reconciling" \
  "$(jq -r '.state' "$BLOCKED_MANIFEST")"
assert_eq "the failure is recorded on the row" "1" \
  "$(jq -r 'if .last_cleanup_error then 1 else 0 end' "$BLOCKED_MANIFEST")"
assert_dir "a failed removal leaves the path retryable" "$BLOCKED_PATH"
bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$BLOCKED_ID" --to cleanup_due --json >/dev/null
assert_absent "re-driving the release is the retry" "$BLOCKED_PATH"

# --- allocate names the next lifecycle step ----------------------------------
# A fresh allocation sits at `reserved` and nothing downstream complains: a seat
# can allocate, dispatch, and integrate without ever leaving that state, and only
# discovers it at teardown. The hint rides the output the caller already reads.
HINT_ALLOC="$(allocate lifecycle-hint hint-seat)"
HINT="$(jq -r '.next // ""' <<<"$HINT_ALLOC")"
HINT_ID="$(jq -r '.worktree_id' <<<"$HINT_ALLOC")"
case "$HINT" in
  *"bind"*) pass "seat allocation names bind as the next verb" ;;
  *) fail "seat allocation names bind as the next verb" "$HINT" ;;
esac
case "$HINT" in
  *quiescent*reconciling*cleanup_due*) pass "hint names the accept/integrate transitions" ;;
  *) fail "hint names the accept/integrate transitions" "$HINT" ;;
esac
case "$HINT" in
  *"$HINT_ID"*) pass "hint carries the worktree id the caller must pass back" ;;
  *) fail "hint carries the worktree id the caller must pass back" "$HINT" ;;
esac
# The hint is advice to the caller, not state the manager owns: it must not land
# in the durable manifest, where a later reader would mistake it for a record.
assert_eq "hint stays out of the persisted manifest" "null" \
  "$(jq -r '.next // "null"' "$KDIR/_coordination/worktrees/registry/$HINT_ID.json")"
# Plain (non---json) output carries it too — the manager has one output shape and
# --json only changes the indentation.
assert_eq "plain allocate output carries the hint" "1" \
  "$(bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
     --attempt lifecycle-hint-plain --owner-kind seat --owner-id hint-plain-seat \
     --source-dir "$SOURCE" 2>/dev/null | jq -r 'if (.next // "") | test("bind") then 1 else 0 end')"

# --- Refusals teach the lifecycle at the point it went wrong -----------------
TEACH="$(allocate lifecycle-teaching teaching-seat)"
TEACH_ID="$(jq -r '.worktree_id' <<<"$TEACH")"
RELEASE_REFUSAL="$(bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$TEACH_ID" \
  --to cleanup_due --json 2>&1)"
assert_eq "releasing a tree still at reserved is refused" "1" "$?"
case "$RELEASE_REFUSAL" in
  *"'reserved' -> 'cleanup_due'"*) pass "the refusal names the edge it rejected" ;;
  *) fail "the refusal names the edge it rejected" "$RELEASE_REFUSAL" ;;
esac
assert_dir "the refused release left the tree standing" "$(jq -r '.execution_dir' <<<"$TEACH")"

# The prose taught `bound -> quiescent`, an edge that has never existed. The
# refusal now reads the legal set and the route out of the machine itself.
bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$TEACH_ID" --owner-id teaching-seat --json >/dev/null
SKIP_REFUSAL="$(bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$TEACH_ID" \
  --to quiescent --json 2>&1)"
assert_eq "a skipped transition is refused" "1" "$?"
case "$SKIP_REFUSAL" in
  *"legal next states are: active"*) pass "the transition refusal names the legal set" ;;
  *) fail "the transition refusal names the legal set" "$SKIP_REFUSAL" ;;
esac
case "$SKIP_REFUSAL" in
  *"active -> quiescent -> reconciling -> cleanup_due"*) pass "the transition refusal names the route out" ;;
  *) fail "the transition refusal names the route out" "$SKIP_REFUSAL" ;;
esac

# --- allocate --help states what teardown preserves --------------------------
ALLOC_HELP="$(bash "$MANAGER" allocate --help 2>&1)"
case "$ALLOC_HELP" in
  *"refs/lore/quarantine/"*) pass "allocate help names where committed work goes" ;;
  *) fail "allocate help names where committed work goes" "$ALLOC_HELP" ;;
esac

# --- A worker session cannot be pinned to a manager-allocated tree -----------
# That pin was the only thing that ever put a worker session into this
# registry, and nothing has used it since 2026-07-25. A worker session's
# checkout comes from the claiming TUI, which owns it end to end.
SESSION_REFUSAL="$(bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo \
  --stream stream-a --attempt session-pin --owner-kind session \
  --owner-id session-owner --source-dir "$SOURCE" --json 2>&1)"
assert_eq "a session-owned allocation is refused" "1" "$?"
case "$SESSION_REFUSAL" in
  *"owner kind must be seat"*) pass "the refusal names the only owner kind left" ;;
  *) fail "the refusal names the only owner kind left" "$SESSION_REFUSAL" ;;
esac
case "$SESSION_REFUSAL" in
  *"claiming TUI"*) pass "the refusal says where a worker session's checkout comes from" ;;
  *) fail "the refusal says where a worker session's checkout comes from" "$SESSION_REFUSAL" ;;
esac
assert_eq "the refused allocation wrote no registry row" "0" \
  "$(grep -l '"attempt_id": "session-pin"' "$KDIR"/_coordination/worktrees/registry/*.json 2>/dev/null | wc -l | tr -d ' ')"

REFUSE="$(allocate refuse-missing-identity refuse-seat)"
REFUSE_ID="$(jq -r '.worktree_id' <<<"$REFUSE")"
REFUSE_MANIFEST="$KDIR/_coordination/worktrees/registry/$REFUSE_ID.json"
python3 - "$REFUSE_MANIFEST" <<'PY'
import json, sys
path = sys.argv[1]
row = json.load(open(path))
del row["guard_identity"]
json.dump(row, open(path, "w"))
PY
BEFORE_HASH="$(shasum -a 256 "$REFUSE_MANIFEST" | awk '{print $1}')"
bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$REFUSE_ID" --to bound --json >/dev/null 2>&1
assert_eq "missing identity fails closed" "1" "$?"
assert_eq "failed identity gate has no manifest side effect" "$BEFORE_HASH" \
  "$(shasum -a 256 "$REFUSE_MANIFEST" | awk '{print $1}')"

HELP="$(bash "$CLI" coordinate --help 2>&1)"
case "$HELP" in
  *worktree*) pass "CLI advertises worktree manager" ;;
  *) fail "CLI advertises worktree manager" ;;
esac

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
