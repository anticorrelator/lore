#!/usr/bin/env bash
# End-to-end lifecycle tests for the sole stream-worktree manager.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGER="$REPO_ROOT/scripts/coordinate-worktree.sh"
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
