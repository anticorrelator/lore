#!/usr/bin/env bash
# Coverage for the stream lifecycle record: pre-freeze phases, the declared
# transition graph, attempt lookup, and schema-3 migration.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/coordinate-reconcile.py"
TEST_ROOT="$(mktemp -d)"
KDIR="$TEST_ROOT/store"
REGISTRY="$KDIR/_coordination/worktrees/registry"
STATE="$KDIR/_coordination/reconciliation/demo/streams.json"
trap 'rm -rf "$TEST_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}

mkdir -p "$KDIR/_work/demo" "$REGISTRY" "$KDIR/_coordination/worktrees/archive"

REPO="$TEST_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit -q --allow-empty -m base
BASE_SHA="$(git -C "$REPO" rev-parse HEAD)"

write_identity() {
  local id="$1" stream="$2" attempt="$3"
  cat >"$REGISTRY/$id.json" <<JSON
{"schema_version":1,"worktree_id":"$id","execution_dir":"$TEST_ROOT/$id","temporary_branch":"lore/streams/demo/$stream/$attempt","git_common_dir":"$REPO/.git","allocation_base_sha":"$BASE_SHA","owner_item":"demo","stream_id":"$stream","attempt_id":"$attempt","owner":{"kind":"seat","id":"seat-1"},"lease":{"duration_seconds":900,"renewed_at":"2026-07-21T00:00:00Z","expires_at":"2099-07-21T00:15:00Z"},"guard_identity":{},"state":"reserved","cleanup_proof":null,"history":[]}
JSON
}

recon() { python3 "$RECONCILE" "$@" --kdir "$KDIR" --slug demo --json; }
state_hash() { [[ -f "$STATE" ]] && shasum -a 256 "$STATE" | awk '{print $1}' || echo absent; }

echo "=== test_coordinate_stream_lifecycle.sh ==="

# --- lookup answers before the record exists ---------------------------------
# "no record yet" must be a named answer, not an empty payload or an error.
MISSING="$(recon lookup-attempt --stream stream-a --attempt attempt-1)"
assert_eq "lookup before any record exits zero" "0" "$?"
assert_eq "lookup before any record names the absence" "coord_lookup_record_absent" \
  "$(jq -r '.outcome' <<<"$MISSING")"

# --- register-attempt: birth at allocate -------------------------------------
write_identity wt-a stream-a attempt-1
REG="$(recon register-attempt --stream stream-a --attempt attempt-1 --tree writer --worktree-id wt-a)"
assert_eq "writer attempt is born allocated" "coord_allocated" "$(jq -r '.status' <<<"$REG")"
assert_eq "first registration writes" "coord_registered" "$(jq -r '.outcome' <<<"$REG")"
assert_eq "registration declares schema 3" "3" "$(jq -r '.schema_version' "$STATE")"

BEFORE="$(state_hash)"
REPLAY="$(recon register-attempt --stream stream-a --attempt attempt-1 --tree writer --worktree-id wt-a)"
assert_eq "identical registration replays" "coord_register_replayed" "$(jq -r '.outcome' <<<"$REPLAY")"
assert_eq "replayed registration does not rewrite" "$BEFORE" "$(state_hash)"

write_identity wt-other stream-a attempt-1
CONFLICT="$(recon register-attempt --stream stream-a --attempt attempt-1 --tree writer --worktree-id wt-other 2>&1)"
assert_eq "a second tree for the same attempt is refused" "1" "$?"
assert_eq "refused registration leaves the record untouched" "$BEFORE" "$(state_hash)"
case "$CONFLICT" in
  *"already registered"*) pass "conflict names the registered tree" ;;
  *) fail "conflict names the registered tree" "$CONFLICT" ;;
esac

# --- lookup removes the caller's worktree-id transcription --------------------
FOUND="$(recon lookup-attempt --stream stream-a --attempt attempt-1)"
assert_eq "lookup resolves the pointer" "coord_lookup_resolved" "$(jq -r '.outcome' <<<"$FOUND")"
assert_eq "lookup answers with the tree identity" "wt-a" "$(jq -r '.worktree_id' <<<"$FOUND")"
assert_eq "lookup projects the manager's branch" "lore/streams/demo/stream-a/attempt-1" \
  "$(jq -r '.worktree.temporary_branch' <<<"$FOUND")"
assert_eq "lookup projects the allocation base" "$BASE_SHA" \
  "$(jq -r '.worktree.allocation_base_sha' <<<"$FOUND")"

# --- a read-only stream owns no tree -----------------------------------------
RO="$(recon register-attempt --stream stream-ro --attempt attempt-1 --tree read-only)"
assert_eq "read-only attempt is born dispatched" "coord_dispatched" "$(jq -r '.status' <<<"$RO")"
assert_eq "read-only attempt carries no pointer" "null" "$(jq -r '.worktree_id' <<<"$RO")"
RO_FOUND="$(recon lookup-attempt --stream stream-ro --attempt attempt-1)"
assert_eq "lookup names the tree-less outcome" "coord_lookup_tree_absent" \
  "$(jq -r '.outcome' <<<"$RO_FOUND")"
assert_eq "tree-less lookup projects nothing manager-owned" "null" \
  "$(jq -r '.worktree' <<<"$RO_FOUND")"
recon register-attempt --stream stream-ro2 --attempt attempt-1 --tree read-only --worktree-id wt-a >/dev/null 2>&1
assert_eq "a read-only registration refuses a worktree id" "1" "$?"

# --- the declared transition graph -------------------------------------------
ADV="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_allocated --to coord_dispatched)"
assert_eq "declared forward edge is accepted" "coord_dispatched" "$(jq -r '.status' <<<"$ADV")"
assert_eq "accepted advance writes" "coord_advanced" "$(jq -r '.outcome' <<<"$ADV")"

BEFORE="$(state_hash)"
ADV_REPLAY="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_allocated --to coord_dispatched)"
assert_eq "identical advance replays as success" "coord_advance_replayed" "$(jq -r '.outcome' <<<"$ADV_REPLAY")"
assert_eq "replayed advance does not rewrite" "$BEFORE" "$(state_hash)"

SKIP="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_allocated --to coord_report_accepted 2>&1)"
assert_eq "a skipped edge is refused" "1" "$?"
assert_eq "refused skip leaves the record untouched" "$BEFORE" "$(state_hash)"
case "$SKIP" in
  *"declared edges are"*) pass "refusal names the declared edges" ;;
  *) fail "refusal names the declared edges" "$SKIP" ;;
esac

recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_dispatched --to coord_allocated >/dev/null 2>&1
assert_eq "a backward edge is refused" "1" "$?"

FORGE="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_dispatched --to source_frozen 2>&1)"
assert_eq "advance cannot manufacture a status the machine does not declare" "1" "$?"
case "$FORGE" in
  *coord_report_accepted*) pass "refusal names where an attempt rests" ;;
  *) fail "refusal names where an attempt rests" "$FORGE" ;;
esac
assert_eq "refused advance leaves the record untouched" "$BEFORE" "$(state_hash)"

STALE="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_allocated --to source_frozen 2>&1)"
assert_eq "a stale expected status conflicts" "1" "$?"

# Report acceptance is where a writer attempt rests: what it shipped is the
# integration commit and the suite counts in the ledger, not a status here.
REST="$(recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_dispatched --to coord_report_accepted)"
assert_eq "a writer attempt rests at report acceptance" "coord_report_accepted" \
  "$(jq -r '.status' <<<"$REST")"
recon advance-attempt --stream stream-a --attempt attempt-1 \
  --expected-status coord_report_accepted --to coord_dispatched >/dev/null 2>&1
assert_eq "there is no edge out of report acceptance" "1" "$?"

# A read-only attempt rests at the same place.
recon advance-attempt --stream stream-ro --attempt attempt-1 \
  --expected-status coord_dispatched --to coord_report_accepted >/dev/null
assert_eq "read-only attempt reaches report acceptance" "coord_report_accepted" \
  "$(jq -r '[.streams[] | select(.stream_id=="stream-ro") | .attempts[0].status][0]' "$STATE")"

# --- conflicting concurrent advances -----------------------------------------
# Two callers holding the same expected status: exactly one may win.
write_identity wt-race stream-race attempt-1
recon register-attempt --stream stream-race --attempt attempt-1 --tree writer --worktree-id wt-race >/dev/null
RACE_A="$TEST_ROOT/race-a.txt"; RACE_B="$TEST_ROOT/race-b.txt"
recon advance-attempt --stream stream-race --attempt attempt-1 \
  --expected-status coord_allocated --to coord_dispatched >"$RACE_A" 2>&1 &
PID_A=$!
recon advance-attempt --stream stream-race --attempt attempt-1 \
  --expected-status coord_allocated --to coord_report_accepted >"$RACE_B" 2>&1 &
PID_B=$!
wait $PID_A; RC_A=$?
wait $PID_B; RC_B=$?
assert_eq "conflicting advances produce exactly one success" "1" "$((( RC_A == 0 ? 1 : 0 ) + ( RC_B == 0 ? 1 : 0 )))"
jq -e . "$STATE" >/dev/null 2>&1
assert_eq "concurrent advances leave valid JSON" "0" "$?"

# Non-conflicting concurrent operations must both survive.
write_identity wt-par1 stream-par1 attempt-1
write_identity wt-par2 stream-par2 attempt-1
recon register-attempt --stream stream-par1 --attempt attempt-1 --tree writer --worktree-id wt-par1 >/dev/null 2>&1 &
PID_1=$!
recon register-attempt --stream stream-par2 --attempt attempt-1 --tree writer --worktree-id wt-par2 >/dev/null 2>&1 &
PID_2=$!
wait $PID_1; wait $PID_2
assert_eq "both non-conflicting registrations survive" "2" \
  "$(jq '[.streams[] | select(.stream_id=="stream-par1" or .stream_id=="stream-par2")] | length' "$STATE")"

# --- recorded facts, attached without moving the status ----------------------
FACTS="$(recon advance-attempt --stream stream-par1 --attempt attempt-1 \
  --expected-status coord_allocated \
  --branch-relevance coord_branch_advanced --branch-base-sha "$BASE_SHA" \
  --branch-tip-sha deadbeef --recovery-bundle /tmp/bundle --quarantine-patch /tmp/q.patch)"
assert_eq "recording facts leaves the status alone" "coord_allocated" "$(jq -r '.status' <<<"$FACTS")"
assert_eq "sweep facts name the quarantine patch" "/tmp/q.patch" \
  "$(jq -r '[.streams[] | select(.stream_id=="stream-par1") | .attempts[0].coord_sweep_recovery.quarantine_patch_path][0]' "$STATE")"
assert_eq "sweep facts name the recovery bundle" "/tmp/bundle" \
  "$(jq -r '[.streams[] | select(.stream_id=="stream-par1") | .attempts[0].coord_sweep_recovery.recovery_bundle_path][0]' "$STATE")"
BEFORE="$(state_hash)"
recon advance-attempt --stream stream-par1 --attempt attempt-1 \
  --expected-status coord_allocated \
  --branch-relevance coord_branch_advanced --branch-base-sha "$BASE_SHA" \
  --branch-tip-sha deadbeef --recovery-bundle /tmp/bundle --quarantine-patch /tmp/q.patch >/dev/null
assert_eq "re-recording identical facts does not rewrite" "$BEFORE" "$(state_hash)"

# --- delivery classification is supplied, never inferred ---------------------
NOEV="$(recon advance-attempt --stream stream-par1 --attempt attempt-1 \
  --expected-status coord_allocated \
  --delivery-classification coord_quarantine_routine_residue 2>&1)"
assert_eq "a classification without evidence is refused" "1" "$?"
case "$NOEV" in
  *"--delivery-evidence"*) pass "refusal names the evidence flag" ;;
  *) fail "refusal names the evidence flag" "$NOEV" ;;
esac
assert_eq "no classification appears until a caller supplies one" "null" \
  "$(jq -r '[.streams[] | select(.stream_id=="stream-par2") | .attempts[0].coord_delivery // "null"][0]' "$STATE")"
recon advance-attempt --stream stream-par1 --attempt attempt-1 \
  --expected-status coord_allocated \
  --delivery-classification coord_quarantine_routine_residue \
  --delivery-evidence refs/lore/quarantine/wt-par1 --delivery-evidence report-7 >/dev/null
assert_eq "classification records the evidence behind it" "2" \
  "$(jq '[.streams[] | select(.stream_id=="stream-par1") | .attempts[0].coord_delivery.evidence][0] | length' "$STATE")"

# --- a stale pointer is not an absent one ------------------------------------
rm "$REGISTRY/wt-par2.json"
assert_eq "a pointer into nothing reads as stale" "coord_lookup_stale_pointer" \
  "$(recon lookup-attempt --stream stream-par2 --attempt attempt-1 | jq -r '.outcome')"
assert_eq "an unknown stream is distinguishable" "coord_lookup_stream_absent" \
  "$(recon lookup-attempt --stream stream-nope --attempt attempt-1 | jq -r '.outcome')"
assert_eq "an unknown attempt is distinguishable" "coord_lookup_attempt_absent" \
  "$(recon lookup-attempt --stream stream-a --attempt attempt-99 | jq -r '.outcome')"

# --- a record written before this change stays readable, then upgrades --------
python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path, encoding="utf-8"))
state["schema_version"] = 2
json.dump(state, open(path, "w", encoding="utf-8"), indent=2, sort_keys=True)
PY
V2_STATUS="$(recon lookup-attempt --stream stream-a --attempt attempt-1)"
assert_eq "a version 2 record is read unchanged" "2" "$(jq -r '.schema_version' <<<"$V2_STATUS")"
assert_eq "a version 2 read reports its own version" "2" "$(jq -r '.schema_version' "$STATE")"
V2_ATTEMPTS="$(jq '[.streams[].attempts[]] | length' "$STATE")"
V2_DELIVERY="$(jq -r '[.streams[] | select(.stream_id=="stream-par1") | .attempts[0].coord_delivery.classification][0]' "$STATE")"
assert_eq "a read leaves a version 2 record at version 2" "2" "$(jq -r '.schema_version' "$STATE")"

write_identity wt-up stream-upgrade attempt-1
recon register-attempt --stream stream-upgrade --attempt attempt-1 --tree writer --worktree-id wt-up >/dev/null
assert_eq "the first mutation upgrades the record" "3" "$(jq -r '.schema_version' "$STATE")"
assert_eq "the upgrade keeps every pre-existing attempt" "$((V2_ATTEMPTS + 1))" \
  "$(jq '[.streams[].attempts[]] | length' "$STATE")"
assert_eq "the upgrade keeps recorded classifications" "$V2_DELIVERY" \
  "$(jq -r '[.streams[] | select(.stream_id=="stream-par1") | .attempts[0].coord_delivery.classification][0]' "$STATE")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
