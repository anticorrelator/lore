#!/usr/bin/env bash
# test_settlement_queue.sh - deterministic settlement queue lease/status tests

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$ROOT_DIR/scripts"
ENQUEUE="$SCRIPTS_DIR/background-queue-enqueue.sh"
PROCESS="$SCRIPTS_DIR/settlement-queue-process.sh"

PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; echo "    $2"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$label"
  else
    fail "$label" "missing $path"
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$label"
  else
    fail "$label" "unexpected file $path"
  fi
}

wait_until() {
  local label="$1" max="$2" cmd="$3"
  local waited=0
  while [[ "$waited" -lt "$max" ]]; do
    if bash -c "$cmd" >/dev/null 2>&1; then
      pass "$label"
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  fail "$label" "condition did not become true"
  return 1
}

enqueue_job() {
  local kdir="$1" job="$2" triggered="$3"
  bash "$ENQUEUE" --kdir "$kdir" --role settlement-audit --triggered-at "$triggered" --job "$job" --json >/dev/null
}

job_file() {
  local kdir="$1"
  find "$kdir/_work-queue/settlement-audit" -maxdepth 1 -name '*.json' ! -name '_leases.json' | sort | head -1
}

echo "=== Settlement queue tests ==="

echo ""
echo "Test 1: status initializes an empty queue"
KDIR="$TEST_DIR/kdir1"
mkdir -p "$KDIR"
OUT=$(bash "$PROCESS" status --kdir "$KDIR" --json)
assert_eq "empty queue pending count" "$(jq -r '.counts.pending' <<<"$OUT")" "0"
assert_eq "empty queue capacity is global limit" "$(jq -r '.capacity' <<<"$OUT")" "1"
assert_file_exists "lease file initialized" "$KDIR/_work-queue/settlement-audit/_leases.json"

echo ""
echo "Test 2: successful fake audit completes exactly one item"
KDIR="$TEST_DIR/kdir2"
mkdir -p "$KDIR"
MARKER="$TEST_DIR/success-marker"
enqueue_job "$KDIR" "printf done > '$MARKER'" "2026-01-01T00:00:00Z"
OUT=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-success --once --json)
assert_eq "one item processed" "$(jq -r '.processed' <<<"$OUT")" "1"
assert_eq "successful item marked completed" "$(jq -r '.results[0].status' <<<"$OUT")" "completed"
assert_file_exists "fake audit marker written" "$MARKER"
JOB=$(job_file "$KDIR")
assert_eq "job file status completed" "$(jq -r '.status' "$JOB")" "completed"

echo ""
echo "Test 3: failing fake audit leaves item retryable"
KDIR="$TEST_DIR/kdir3"
mkdir -p "$KDIR"
FAIL_MARKER="$TEST_DIR/fail-marker"
enqueue_job "$KDIR" "printf fail > '$FAIL_MARKER'; exit 7" "2026-01-01T00:00:01Z"
OUT=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-fail --once --json)
assert_eq "failed command reports retryable" "$(jq -r '.results[0].status' <<<"$OUT")" "retryable"
JOB=$(job_file "$KDIR")
assert_eq "failed job remains pending" "$(jq -r '.status' "$JOB")" "pending"
assert_eq "failure count increments" "$(jq -r '.failure_count' "$JOB")" "1"
assert_eq "last exit code retained" "$(jq -r '.last_exit_code' "$JOB")" "7"

echo ""
echo "Test 4: two workers contend through one global lease file"
KDIR="$TEST_DIR/kdir4"
mkdir -p "$KDIR"
STARTED="$TEST_DIR/started"
RELEASE="$TEST_DIR/release"
DONE1="$TEST_DIR/done1"
DONE2="$TEST_DIR/done2"
enqueue_job "$KDIR" "printf start > '$STARTED'; while [ ! -f '$RELEASE' ]; do sleep 0.05; done; printf done > '$DONE1'" "2026-01-01T00:00:02Z"
enqueue_job "$KDIR" "printf done > '$DONE2'" "2026-01-01T00:00:03Z"
bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-a --heartbeat-interval 0.1 --stale-after 5 --once --json > "$TEST_DIR/p1.out" &
P1=$!
wait_until "first worker acquired lease" 80 "[ -f '$STARTED' ] && [ \"\$(bash '$PROCESS' status --kdir '$KDIR' --json | jq -r '.active_leases')\" = 1 ]"
LEASE_WORKER=$(jq -r '.leases[0].processor_id' "$KDIR/_work-queue/settlement-audit/_leases.json")
assert_eq "lease records injected worker id" "$LEASE_WORKER" "worker-a"
HB1=$(jq -r '.leases[0].heartbeat_at' "$KDIR/_work-queue/settlement-audit/_leases.json")
wait_until "heartbeat refreshes while command is running" 80 "[ \"\$(jq -r '.leases[0].heartbeat_at' '$KDIR/_work-queue/settlement-audit/_leases.json')\" != '$HB1' ]"
OUT2=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-b --concurrency 1 --once --json)
assert_eq "second worker cannot exceed global limit" "$(jq -r '.processed' <<<"$OUT2")" "0"
assert_eq "second worker sees capacity reason" "$(jq -r '.results[0].reason' <<<"$OUT2")" "capacity"
assert_eq "one item remains pending while lease is active" "$(jq -r '.status.counts.pending' <<<"$OUT2")" "1"
touch "$RELEASE"
wait "$P1"
OUT3=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-c --once --json)
assert_eq "second item completes after capacity frees" "$(jq -r '.processed' <<<"$OUT3")" "1"
assert_file_exists "first marker completed" "$DONE1"
assert_file_exists "second marker completed" "$DONE2"

echo ""
echo "Test 5: expired lease is recovered before replacement"
KDIR="$TEST_DIR/kdir5"
mkdir -p "$KDIR"
STALE_MARKER="$TEST_DIR/stale-marker"
enqueue_job "$KDIR" "printf recovered > '$STALE_MARKER'" "2026-01-01T00:00:04Z"
JOB=$(job_file "$KDIR")
jq '.status="running" | .lease_id="lease-old"' "$JOB" > "$JOB.tmp" && mv "$JOB.tmp" "$JOB"
cat > "$KDIR/_work-queue/settlement-audit/_leases.json" <<JSON
{"version":1,"leases":[{"lease_id":"lease-old","request_id":"old","job_file":"$JOB","heartbeat_at":"2000-01-01T00:00:00Z","expires_at":"2000-01-01T00:00:01Z"}]}
JSON
OUT=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-recover --stale-after 1 --once --json)
assert_eq "stale lease recovery recorded on job" "$(jq -r '.previous_lease_id' "$JOB")" "lease-old"
assert_file_exists "recovered item eventually completed" "$STALE_MARKER"
assert_eq "stale job completed after replacement lease" "$(jq -r '.status' "$JOB")" "completed"

echo ""
echo "Test 6: malformed leases file is repaired without starting audit"
KDIR="$TEST_DIR/kdir6"
mkdir -p "$KDIR/_work-queue/settlement-audit"
MALFORMED_MARKER="$TEST_DIR/malformed-marker"
enqueue_job "$KDIR" "printf should-not-run > '$MALFORMED_MARKER'" "2026-01-01T00:00:05Z"
printf '{not-json\n' > "$KDIR/_work-queue/settlement-audit/_leases.json"
OUT=$(bash "$PROCESS" process --kdir "$KDIR" --worker-id worker-malformed --once --json)
assert_eq "malformed leases invocation does not process" "$(jq -r '.processed' <<<"$OUT")" "0"
assert_eq "malformed leases reason is explicit" "$(jq -r '.results[0].reason' <<<"$OUT")" "leases-corrupt-repaired"
assert_file_absent "fake audit not started for malformed leases" "$MALFORMED_MARKER"
jq -e '.leases == []' "$KDIR/_work-queue/settlement-audit/_leases.json" >/dev/null && pass "leases file repaired to valid empty set" || fail "leases file repaired to valid empty set" "invalid repaired leases file"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
