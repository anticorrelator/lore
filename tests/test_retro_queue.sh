#!/usr/bin/env bash
# test_retro_queue.sh — Durable DUE queue fold and monotonic disposition tests.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPEND="$REPO_ROOT/scripts/retro-deferred-append.sh"
QUEUE_FRONT="$REPO_ROOT/scripts/retro-queue.sh"
CLI="$REPO_ROOT/cli/lore"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_zero() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "exit=$2"; fi; }
assert_nonzero() { if [[ "$2" -ne 0 ]]; then pass "$1"; else fail "$1" "exit=0"; fi; }

KDIR=$(mktemp -d)
trap 'rm -rf "$KDIR"' EXIT
mkdir -p "$KDIR/_scorecards"
QUEUE="$KDIR/_scorecards/retro-deferred-queue.jsonl"

echo "=== test_retro_queue.sh ==="

# Legacy grammar remains accepted and readable.
for outcome in "done" "deferred" "skipped"; do
  bash "$APPEND" --cycle-id "legacy-$outcome" --event-type spec-finalize \
    --outcome "$outcome" --rate 0 --stratum routine --kdir "$KDIR" >/dev/null
  assert_zero "legacy outcome '$outcome' remains accepted" "$?"
done

# Two DUE decisions for the same cycle are distinct point events.
for reason in always-stratum coin; do
  bash "$APPEND" --cycle-id cycle-a --event-type impl-close --outcome due \
    --disposition unhandled --reason "$reason" --rate 0.5 --stratum routine \
    --coin 0.1 --kdir "$KDIR" >/dev/null
  assert_zero "DUE outcome '$reason' appended" "$?"
done

STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
RC=$?
assert_zero "queue fold exits zero" "$RC"
assert_eq "two repeated DUE decisions retain distinct identities" "2" \
  "$(printf '%s' "$STATUS" | jq -r '[.unhandled_due[].outcome_id] | unique | length')"
assert_eq "legacy deferred row remains visible" "1" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.deferred')"
assert_eq "default fold reports both DUE identities unhandled" "2" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.unhandled_due')"

CLI_STATUS=$(bash "$CLI" retro queue --kdir "$KDIR" --json)
assert_eq "lore retro queue exposes the same unhandled fold" "2" \
  "$(printf '%s' "$CLI_STATUS" | jq -r '.counts.unhandled_due')"

OID=$(printf '%s' "$STATUS" | jq -r '.unhandled_due[0].outcome_id')
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "handle by outcome identity appends transition" "$?"

LINES_AFTER_FIRST=$(wc -l < "$QUEUE" | tr -d '[:space:]')
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "identical handling retry is an idempotent success" "$?"
assert_eq "idempotent retry appends no row" "$LINES_AFTER_FIRST" \
  "$(wc -l < "$QUEUE" | tr -d '[:space:]')"

bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action skipped \
  --handled-by coordinator --kdir "$KDIR" >/dev/null 2>&1
assert_nonzero "conflicting second action fails loudly" "$?"

# Cycle handling claims every remaining unhandled identity and ignores the
# already-adjudicated identity rather than trying to transition it again.
bash "$QUEUE_FRONT" handle --cycle-id cycle-a --action dispatched \
  --handled-by coordinator --kdir "$KDIR" >/dev/null
assert_zero "cycle-wide handling claims only remaining unhandled identities" "$?"

STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
assert_eq "handled identities leave the unhandled fold" "0" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.unhandled_due')"
assert_eq "handled fold retains both identities" "2" \
  "$(printf '%s' "$STATUS" | jq -r '.counts.handled_due')"
printf '%s' "$STATUS" | jq -e '
  all(.handled_due[];
      .handling.disposition == "handled" and
      .handling.action == "dispatched" and
      .handling.handled_by == "coordinator" and
      (.handling.handled_at | length) > 0)
' >/dev/null
assert_zero "handled rows carry action, actor, and writer-stamped time" "$?"

LINES_BEFORE_CYCLE_RETRY=$(wc -l < "$QUEUE" | tr -d '[:space:]')
bash "$QUEUE_FRONT" handle --cycle-id cycle-a --action skipped \
  --handled-by retro-lead --kdir "$KDIR" >/dev/null
assert_zero "cycle-wide claim is a no-op after prior coordinator handling" "$?"
assert_eq "cycle-wide no-op does not append a conflicting transition" "$LINES_BEFORE_CYCLE_RETRY" \
  "$(wc -l < "$QUEUE" | tr -d '[:space:]')"

# Exercise every authoritative handled-action token through the writer and read
# it back through the fold so the reader's mirrored vocabulary cannot drift.
for action in deferred skipped; do
  bash "$APPEND" --cycle-id "action-$action" --event-type spec-finalize --outcome due \
    --disposition unhandled --reason coin --rate 1 --stratum routine --coin 0.1 \
    --kdir "$KDIR" >/dev/null
  action_oid=$(jq -r --arg cycle "action-$action" \
    'select(.record_type == "outcome" and .cycle_id == $cycle) | .outcome_id' "$QUEUE")
  bash "$QUEUE_FRONT" handle --outcome-id "$action_oid" --action "$action" \
    --handled-by coordinator --kdir "$KDIR" >/dev/null
  assert_zero "handled action '$action' round-trips through the appender" "$?"
done
ACTION_STATUS=$(bash "$QUEUE_FRONT" queue --kdir "$KDIR" --json)
assert_eq "queue fold mirrors dispatched|deferred|skipped action vocabulary" \
  "deferred,dispatched,skipped" \
  "$(printf '%s' "$ACTION_STATUS" | jq -r '[.handled_due[].handling.action] | unique | sort | join(",")')"
bash "$QUEUE_FRONT" handle --outcome-id "$OID" --action maybe \
  --handled-by coordinator --kdir "$KDIR" >/dev/null 2>&1
assert_nonzero "appender rejects action tokens outside the closed vocabulary" "$?"

# No DUE for a cycle is a successful no-op, which keeps direct /retro claiming fail-open.
bash "$CLI" retro handle --cycle-id absent --action dispatched \
  --handled-by retro-lead --kdir "$KDIR" >/dev/null
assert_zero "lore retro handle treats a cycle with no DUE as a no-op" "$?"

echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
