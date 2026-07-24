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

# A seat allocation must carry a liveness handle, so the default handle here is
# a tmux session on a server that does not exist: `has-session` fails, the owner
# is provably dead, and the row is sweepable. That is what these lifecycle tests
# need, and it exercises the real dead-man's-switch path (handle present, owner
# gone) rather than the handle-less case the manager now refuses. Callers that
# want a LIVE owner pass --owner-pid explicitly.
DEAD_TMUX_SERVER="lore-test-dead-$$"
allocate() {
  local attempt="$1" owner_id="$2"; shift 2
  local handle=(--owner-tmux "dead-$owner_id" --tmux-server "$DEAD_TMUX_SERVER")
  for arg in "$@"; do
    [[ "$arg" == "--owner-pid" || "$arg" == "--owner-tmux" ]] && handle=()
  done
  bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
    --attempt "$attempt" --owner-kind seat --owner-id "$owner_id" \
    --source-dir "$SOURCE" --json ${handle[@]+"${handle[@]}"} "$@"
}

expire_manifest() {
  python3 - "$1" <<'PY'
import json, os, sys, tempfile
path = sys.argv[1]
row = json.load(open(path))
row["lease"]["expires_at"] = "2000-01-01T00:00:00Z"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as handle:
    json.dump(row, handle)
os.replace(tmp, path)
PY
}

drive_cleanup_due() {
  local id="$1" owner="$2"
  bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$id" --owner-id "$owner" --json >/dev/null
  # A repeated bind is the post-spawn owner-probe attachment path.
  bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$id" --owner-id "$owner" --owner-pid "$$" --json >/dev/null
  for state in active quiescent reconciling cleanup_due; do
    bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$id" --to "$state" --json >/dev/null
  done
}

echo "=== test_coordinate_worktree.sh ==="

ALLOC="$(allocate normal seat-normal)"
WT_ID="$(jq -r '.worktree_id' <<<"$ALLOC")"
WT_PATH="$(jq -r '.execution_dir' <<<"$ALLOC")"
BRANCH="$(jq -r '.temporary_branch' <<<"$ALLOC")"
assert_eq "allocation starts reserved" "reserved" "$(jq -r '.state' <<<"$ALLOC")"
assert_eq "allocation lease is exactly fifteen minutes" "900" "$(jq -r '.lease.duration_seconds' <<<"$ALLOC")"
assert_eq "execution path uses manager namespace" "$KDIR_CANON/_coordination/worktrees/trees/$WT_ID" "$WT_PATH"
assert_eq "temporary branch is checked out" "$BRANCH" "$(git -C "$WT_PATH" branch --show-current)"
assert_eq "guard identity validates after manager branch creation" "$WT_PATH" \
  "$(jq -r '.guard_identity.canonical_path' <<<"$ALLOC")"

drive_cleanup_due "$WT_ID" seat-normal
printf 'unstaged\n' >> "$WT_PATH/tracked.txt"
printf 'staged\n' > "$WT_PATH/staged.txt"
git -C "$WT_PATH" add staged.txt
printf 'untracked\n' > "$WT_PATH/untracked.txt"
REMOVED="$(bash "$MANAGER" cleanup --kdir "$KDIR" --worktree-id "$WT_ID" --json)"
ARCHIVE="$KDIR/_coordination/worktrees/archive/$WT_ID.json"
assert_eq "normal cleanup reaches removed" "removed" "$(jq -r '.state' <<<"$REMOVED")"
assert_eq "cleanup proves all three terminal conditions" "true" \
  "$(jq -r '.cleanup_proof.path_absent and .cleanup_proof.git_registry_absent and (.cleanup_proof.branch_disposition=="deleted") and .cleanup_proof.verified' <<<"$REMOVED")"
assert_absent "normal cleanup removes physical path" "$WT_PATH"
assert_file "terminal record is archived" "$ARCHIVE"
BUNDLE="$(jq -r '.recovery.bundle_path' <<<"$REMOVED")"
assert_file "tracked recovery patch precedes removal" "$BUNDLE/tracked.patch"
assert_file "staged recovery patch precedes removal" "$BUNDLE/staged.patch"
assert_file "untracked recovery archive precedes removal" "$BUNDLE/untracked.tar"
assert_eq "recovery manifest hash validates" "$(jq -r '.recovery.manifest_sha256' <<<"$REMOVED")" \
  "$(shasum -a 256 "$BUNDLE/manifest.json" | awk '{print $1}')"

CRASH="$(allocate crash-before-enqueue seat-crashed)"
CRASH_ID="$(jq -r '.worktree_id' <<<"$CRASH")"
CRASH_PATH="$(jq -r '.execution_dir' <<<"$CRASH")"
printf 'abandoned\n' > "$CRASH_PATH/untracked-crash.txt"
expire_manifest "$KDIR/_coordination/worktrees/registry/$CRASH_ID.json"
SWEEP="$(bash "$MANAGER" sweep --kdir "$KDIR" --json)"
assert_eq "expired reserved allocation is swept" "$CRASH_ID" "$(jq -r '.swept[0]' <<<"$SWEEP")"
assert_eq "abnormal terminal is swept" "swept" \
  "$(jq -r '.state' "$KDIR/_coordination/worktrees/archive/$CRASH_ID.json")"
CRASH_BUNDLE="$(jq -r '.recovery.bundle_path' "$KDIR/_coordination/worktrees/archive/$CRASH_ID.json")"
assert_file "crash sweep stores untracked recovery" "$CRASH_BUNDLE/untracked.tar"
assert_absent "crash sweep removes path" "$CRASH_PATH"

CLAIMED="$(allocate interrupted-claim claimed-seat)"
CLAIMED_ID="$(jq -r '.worktree_id' <<<"$CLAIMED")"
CLAIMED_PATH="$(jq -r '.execution_dir' <<<"$CLAIMED")"
mv "$KDIR/_coordination/worktrees/registry/$CLAIMED_ID.json" \
  "$KDIR/_coordination/worktrees/claims/$CLAIMED_ID.json"
CLAIM_SWEEP="$(bash "$MANAGER" sweep --kdir "$KDIR" --json)"
assert_eq "next sweep resumes an interrupted atomic claim" "$CLAIMED_ID" \
  "$(jq -r '.swept[0]' <<<"$CLAIM_SWEEP")"
assert_absent "resumed cleanup removes claimed path" "$CLAIMED_PATH"

LIVE="$(allocate live-owner live-seat --owner-pid "$$")"
LIVE_ID="$(jq -r '.worktree_id' <<<"$LIVE")"
LIVE_PATH="$(jq -r '.execution_dir' <<<"$LIVE")"
expire_manifest "$KDIR/_coordination/worktrees/registry/$LIVE_ID.json"
LIVE_SWEEP="$(bash "$MANAGER" sweep --kdir "$KDIR" --json)"
assert_eq "live owner protects expired worktree" "$LIVE_ID" "$(jq -r '.protected[0]' <<<"$LIVE_SWEEP")"
assert_dir "protected owner path survives" "$LIVE_PATH"
drive_cleanup_due "$LIVE_ID" live-seat
bash "$MANAGER" cleanup --kdir "$KDIR" --worktree-id "$LIVE_ID" --json >/dev/null

BLOCKED="$(allocate cleanup-failure blocked-seat)"
BLOCKED_ID="$(jq -r '.worktree_id' <<<"$BLOCKED")"
BLOCKED_PATH="$(jq -r '.execution_dir' <<<"$BLOCKED")"
drive_cleanup_due "$BLOCKED_ID" blocked-seat
LORE_WORKTREE_FAIL_REMOVE=1 bash "$MANAGER" cleanup --kdir "$KDIR" --worktree-id "$BLOCKED_ID" --json >/dev/null 2>&1
assert_eq "injected removal failure is non-zero" "1" "$?"
BLOCKED_MANIFEST="$KDIR/_coordination/worktrees/registry/$BLOCKED_ID.json"
assert_eq "cleanup failure remains retry-only" "cleanup_blocked" "$(jq -r '.state' "$BLOCKED_MANIFEST")"
assert_eq "cleanup failure captures evidence before removal" "true" "$(jq -r '.recovery.captured_before_removal' "$BLOCKED_MANIFEST")"
assert_dir "failed removal leaves path retryable" "$BLOCKED_PATH"
bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$BLOCKED_ID" --to cleanup_due --json >/dev/null
bash "$MANAGER" cleanup --kdir "$KDIR" --worktree-id "$BLOCKED_ID" --json >/dev/null
assert_absent "cleanup retry removes path" "$BLOCKED_PATH"

# Acceptance refs pinned at reconciliation survive the sweep that deletes the
# temporary branch, keeping the accepted stream tip reachable afterward.
ACCEPT="$(allocate accept-anchor accept-seat --owner-pid "$$")"
ACCEPT_ID="$(jq -r '.worktree_id' <<<"$ACCEPT")"
ACCEPT_PATH="$(jq -r '.execution_dir' <<<"$ACCEPT")"
ACCEPT_BRANCH="$(jq -r '.temporary_branch' <<<"$ACCEPT")"
ACCEPT_COMMON="$(jq -r '.git_common_dir' "$KDIR/_coordination/worktrees/registry/$ACCEPT_ID.json")"
# Commit on the temporary branch so the stream tip is reachable only through it.
printf 'accepted\n' > "$ACCEPT_PATH/accepted.txt"
git -C "$ACCEPT_PATH" add accepted.txt
git -C "$ACCEPT_PATH" commit -qm accepted-tip
TIP="$(git -C "$ACCEPT_PATH" rev-parse HEAD)"
bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$ACCEPT_ID" --owner-id accept-seat --owner-pid "$$" --json >/dev/null
for state in active quiescent reconciling; do
  bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$ACCEPT_ID" --to "$state" --json >/dev/null
done
printf 'diff --git a/accepted.txt b/accepted.txt\n' > "$TEST_ROOT/accept-src.patch"
printf 'diff --git a/accepted.txt b/accepted.txt\n+accepted\n' > "$TEST_ROOT/accept-int.patch"
python3 "$RECONCILE" freeze-source --kdir "$KDIR" --slug demo \
  --stream stream-a --attempt accept-anchor --worktree-id "$ACCEPT_ID" --tree writer \
  --patch "$TEST_ROOT/accept-src.patch" --head-sha "$TIP" --changed-path accepted.txt --json >/dev/null
python3 "$RECONCILE" freeze-integrated --kdir "$KDIR" --slug demo \
  --stream stream-a --attempt accept-anchor --patch "$TEST_ROOT/accept-int.patch" \
  --integrated-sha "$TIP" --changed-path accepted.txt --verdict full --json >/dev/null
INT_REF="refs/lore/accepted/demo/stream-a/accept-anchor/integrated"
SRC_REF="refs/lore/accepted/demo/stream-a/accept-anchor/source"
assert_eq "acceptance integrated ref pinned before sweep" "$TIP" \
  "$(git --git-dir="$ACCEPT_COMMON" rev-parse "$INT_REF")"

bash "$MANAGER" transition --kdir "$KDIR" --worktree-id "$ACCEPT_ID" --to cleanup_due --json >/dev/null
SWEEP_ACCEPT="$(bash "$MANAGER" cleanup --kdir "$KDIR" --worktree-id "$ACCEPT_ID" --json)"
assert_eq "accepted stream cleanup proof verifies" "true" "$(jq -r '.cleanup_proof.verified' <<<"$SWEEP_ACCEPT")"
assert_eq "accepted stream branch is deleted" "deleted" "$(jq -r '.cleanup_proof.branch_disposition' <<<"$SWEEP_ACCEPT")"
assert_absent "accepted stream worktree path removed" "$ACCEPT_PATH"
git --git-dir="$ACCEPT_COMMON" show-ref --verify --quiet "refs/heads/$ACCEPT_BRANCH"
assert_eq "temporary branch gone after sweep" "1" "$?"
assert_eq "acceptance integrated ref survives sweep" "$TIP" \
  "$(git --git-dir="$ACCEPT_COMMON" rev-parse "$INT_REF")"
assert_eq "acceptance source ref survives sweep" "$TIP" \
  "$(git --git-dir="$ACCEPT_COMMON" rev-parse "$SRC_REF")"
git --git-dir="$ACCEPT_COMMON" merge-base --is-ancestor "$TIP" "$SRC_REF"
assert_eq "stream tip reachable from acceptance ref after sweep" "0" "$?"
git --git-dir="$ACCEPT_COMMON" merge-base --is-ancestor "$TIP" main
assert_eq "stream tip is not reachable from main" "1" "$?"

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
     --owner-tmux dead-hint-plain --tmux-server "$DEAD_TMUX_SERVER" \
     --source-dir "$SOURCE" 2>/dev/null | jq -r 'if (.next // "") | test("bind") then 1 else 0 end')"
# A session lease is driven by the TUI, which follows its own path; the hint is
# for the seat that has to drive the lifecycle by hand.
SESSION_HINT="$(bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
  --attempt session-hint --owner-kind session --owner-id session-hint-owner \
  --owner-pid "$$" --source-dir "$SOURCE" --json 2>/dev/null)"
assert_eq "session allocation carries no seat lifecycle hint" "null" \
  "$(jq -r '.next // "null"' <<<"$SESSION_HINT")"

# --- Liveness handle is mandatory for a seat lease ---------------------------
# The lease is a dead-man's switch: sweep_all reclaims an expired tree only when
# owner_live() cannot prove the owner is there, and it knows exactly two proofs
# (owner.pid, owner.tmux_name). A seat carrying neither is unprotectable by
# construction and was reclaimed mid-flight from a live worker.
NOHANDLE="$(bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
  --attempt no-handle --owner-kind seat --owner-id bare-seat \
  --source-dir "$SOURCE" --json 2>&1)"
NOHANDLE_RC=$?
assert_eq "handle-less seat allocation is refused" "1" "$NOHANDLE_RC"
case "$NOHANDLE" in
  *"--owner-pid"*"--owner-tmux"*) pass "refusal names both handle flags" ;;
  *) fail "refusal names both handle flags" "$NOHANDLE" ;;
esac
case "$NOHANDLE" in
  *'$$'*) pass "refusal warns against the \$\$ subshell trap" ;;
  *) fail "refusal warns against the \$\$ subshell trap" "$NOHANDLE" ;;
esac
assert_eq "refused allocation leaves no registry row" "0" \
  "$(find "$KDIR/_coordination/worktrees/registry" -name '*.json' -newer "$SOURCE/tracked.txt" \
     -exec grep -l '"attempt_id": "no-handle"' {} + 2>/dev/null | wc -l | tr -d ' ')"

# A session lease is deliberately still permitted — no automated caller
# allocates, so there is no call site that can be shown to already pass a
# handle. It warns rather than refusing, so the hole stays visible.
SESSION_ERR="$TEST_ROOT/session-warn.txt"
SESSION_ALLOC="$(bash "$MANAGER" allocate --kdir "$KDIR" --work-item demo --stream stream-a \
  --attempt session-no-handle --owner-kind session --owner-id bare-session \
  --source-dir "$SOURCE" --json 2>"$SESSION_ERR")"
assert_eq "handle-less session allocation still succeeds" "reserved" \
  "$(jq -r '.state' <<<"$SESSION_ALLOC")"
case "$(cat "$SESSION_ERR")" in
  *"no liveness handle"*) pass "handle-less session warns on stderr" ;;
  *) fail "handle-less session warns on stderr" "$(cat "$SESSION_ERR")" ;;
esac

# bind is the repair path for a lease that was allocated without a handle.
SESSION_ID="$(jq -r '.worktree_id' <<<"$SESSION_ALLOC")"
BOUND="$(bash "$MANAGER" bind --kdir "$KDIR" --worktree-id "$SESSION_ID" \
  --owner-id bare-session --owner-pid "$$" --json)"
assert_eq "bind attaches a liveness handle after allocation" "$$" \
  "$(jq -r '.owner.pid' <<<"$BOUND")"
expire_manifest "$KDIR/_coordination/worktrees/registry/$SESSION_ID.json"
REPAIRED_SWEEP="$(bash "$MANAGER" sweep --kdir "$KDIR" --json 2>/dev/null)"
assert_eq "a bound live pid protects a previously handle-less lease" "$SESSION_ID" \
  "$(jq -r --arg id "$SESSION_ID" '.protected[] | select(. == $id)' <<<"$REPAIRED_SWEEP")"

# --- Reclamation reports where the work went ---------------------------------
# cleanup_proof read as pure destruction and never mentioned the recovery
# bundle sitting in the same manifest; that cost forty minutes and a wrong
# data-loss report.
RECOV="$(allocate recovery-pointer recovery-seat)"
RECOV_ID="$(jq -r '.worktree_id' <<<"$RECOV")"
printf 'unsaved work\n' > "$(jq -r '.execution_dir' <<<"$RECOV")/scratch.txt"
expire_manifest "$KDIR/_coordination/worktrees/registry/$RECOV_ID.json"
RECOV_SWEEP="$(bash "$MANAGER" sweep --kdir "$KDIR" --json 2>/dev/null)"
RECOV_BUNDLE="$(jq -r --arg id "$RECOV_ID" '.recovery[$id] // ""' <<<"$RECOV_SWEEP")"
assert_dir "sweep result carries the recovery bundle path" "$RECOV_BUNDLE"
RECOV_ARCHIVE="$KDIR/_coordination/worktrees/archive/$RECOV_ID.json"
assert_eq "cleanup proof carries the recovery bundle path" "$RECOV_BUNDLE" \
  "$(jq -r '.cleanup_proof.recovery_bundle_path' "$RECOV_ARCHIVE")"
case "$(jq -r '.cleanup_proof.recovery_hint' "$RECOV_ARCHIVE")" in
  *"never"*"--3way"*) pass "cleanup proof warns against git apply --3way" ;;
  *) fail "cleanup proof warns against git apply --3way" ;;
esac

# --- allocate --help states the contract and the $$ trap ---------------------
ALLOC_HELP="$(bash "$MANAGER" allocate --help 2>&1)"
case "$ALLOC_HELP" in
  *'$$'*) pass "allocate help names the \$\$ trap" ;;
  *) fail "allocate help names the \$\$ trap" ;;
esac
case "$ALLOC_HELP" in
  *"--3way"*) pass "allocate help points at the recovery path" ;;
  *) fail "allocate help points at the recovery path" ;;
esac

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
