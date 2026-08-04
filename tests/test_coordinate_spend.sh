#!/usr/bin/env bash
# test_coordinate_spend.sh — Acceptance for the session-spend roll-up verb.
#
# Covers `lore coordinate spend`: the two-key work-item attribution (a worker
# row's derived slug must roll up under links.work_item), arc and work-item
# scoping, window bounding through the reference journal reader, and the rule
# that orphaned spend is reported but never folded into the total.
#
# It also cross-checks the two event names the verb mirrors — `closed` and
# `orphaned` — against session-event-append.sh, the vocabulary's sole writer.
# That mirror is the reason this check exists: the vocabulary has several
# read-only copies and they drift silently when nothing ties them back.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEND="$REPO_ROOT/scripts/coordinate-spend.sh"
APPEND="$REPO_ROOT/scripts/session-event-append.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then pass "$label"; else fail "$label" "expected '$expected', got '$actual'"; fi
}
assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label" "missing '$needle'"; fi
}
assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "unexpected '$needle'"; fi
}

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# The verb's own mirror of the vocabulary, read out of the script rather than
# retyped here — a test that hardcodes both sides cross-checks nothing.
CLOSED_LITERAL=$(sed -n 's/^CLOSED_EVENT="\(.*\)"$/\1/p' "$SPEND")
ORPHANED_LITERAL=$(sed -n 's/^ORPHANED_EVENT="\(.*\)"$/\1/p' "$SPEND")

# A store whose journal carries: one lead session and one worker session for
# item-a (the worker under a derived slug, linked back), one closed session for
# item-b, and one orphaned worker session for item-a.
new_store() {
  local kdir="$TEST_DIR/store.$RANDOM.$RANDOM"
  mkdir -p "$kdir/_sessions" "$kdir/_work/_arcs/demo-arc"
  cat > "$kdir/_sessions/events.jsonl" <<EOF
{"event":"$CLOSED_LITERAL","slug":"item-a","session_type":"implement","ts":"2026-08-01T00:00:00Z","event_id":"ev-1","spend":{"basis":"transcript","duration_seconds":600,"total_tokens":1000,"cost_usd":1.5},"links":{}}
{"event":"$CLOSED_LITERAL","slug":"item-a--w1","session_type":"worker","ts":"2026-08-01T01:00:00Z","event_id":"ev-2","spend":{"basis":"rollout","duration_seconds":300,"total_tokens":500},"links":{"work_item":"item-a"}}
{"event":"$CLOSED_LITERAL","slug":"item-b","session_type":"spec","ts":"2026-08-02T00:00:00Z","event_id":"ev-3","spend":{"basis":"duration-only","duration_seconds":900},"links":{}}
{"event":"$ORPHANED_LITERAL","slug":"item-a--w2","session_type":"worker","ts":"2026-08-02T05:00:00Z","event_id":"ev-4","spend":{"basis":"duration-only","duration_seconds":7200},"links":{"work_item":"item-a"}}
{"event":"spawned","slug":"item-a","ts":"2026-08-02T06:00:00Z","event_id":"ev-5","links":{}}
EOF
  echo '{"schema_version":1,"slug":"demo-arc","members":["item-a"]}' > "$kdir/_work/_arcs/demo-arc/_meta.json"
  echo "$kdir"
}

field() {
  local json="$1" path="$2"
  python3 - "$json" "$path" <<'PYEOF'
import json, sys
node = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    if not isinstance(node, dict) or key not in node:
        print("<absent>")
        raise SystemExit(0)
    node = node[key]
print(node)
PYEOF
}

echo "== the mirrored event names still exist in the vocabulary's sole writer =="
# Behavioral, not textual: the appender accepts a row carrying each mirrored
# name, and rejects one that is not in the vocabulary at all. If a rename lands
# in session-event-append.sh, the accept assertions fail here.
VOCAB_KDIR="$TEST_DIR/vocab"
mkdir -p "$VOCAB_KDIR/_sessions"
for name in "$CLOSED_LITERAL" "$ORPHANED_LITERAL"; do
  ROW=$(printf '{"event":"%s","slug":"vocab-probe","actor_instance":"probe","target_instance":"probe","reason":"instance-death"}' "$name")
  if bash "$APPEND" --row "$ROW" --kdir "$VOCAB_KDIR" >/dev/null 2>&1; then
    pass "session-event-append.sh still accepts event '$name'"
  else
    fail "session-event-append.sh still accepts event '$name'" "the roll-up mirrors a name the writer no longer knows"
  fi
done
if bash "$APPEND" --row '{"event":"not_a_real_event","slug":"vocab-probe"}' --kdir "$VOCAB_KDIR" >/dev/null 2>&1; then
  fail "the vocabulary probe is meaningful" "the appender accepts anything, so the accept assertions prove nothing"
else
  pass "the vocabulary probe is meaningful"
fi

echo "== a worker row rolls up under its work item, not its derived slug =="
KDIR=$(new_store)
OUT=$(bash "$SPEND" --json --kdir "$KDIR" 2>/dev/null)
assert_contains "the base work item is a group" "$OUT" '"item-a"'
assert_not_contains "the derived worker slug is not a group" "$OUT" '"item-a--w1"'
assert_eq "the worker's session counts toward its item" "2" "$(field "$OUT" by_work_item.item-a.sessions)"
assert_eq "the worker's tokens count toward its item" "1500" "$(field "$OUT" by_work_item.item-a.total_tokens)"
assert_eq "the worker's duration counts toward its item" "900" "$(field "$OUT" by_work_item.item-a.duration_seconds)"

echo "== the total covers closed rows only; orphaned is reported beside it =="
assert_eq "closed sessions counted" "3" "$(field "$OUT" closed.sessions)"
assert_eq "closed duration excludes the orphan's 7200s" "1800" "$(field "$OUT" closed.duration_seconds)"
assert_eq "orphaned is reported" "1" "$(field "$OUT" orphaned.sessions)"
assert_eq "orphaned duration is on its own line" "7200" "$(field "$OUT" orphaned.duration_seconds)"
TEXT=$(bash "$SPEND" --kdir "$KDIR" 2>/dev/null)
assert_contains "text output labels the exclusion" "$TEXT" "NOT in the total"

echo "== spend is read in its normalized form, basis and all =="
assert_eq "duration-only tokens stay zero" "0" "$(field "$OUT" by_work_item.item-b.total_tokens)"
assert_eq "duration-only duration still counts" "900" "$(field "$OUT" by_work_item.item-b.duration_seconds)"
assert_eq "each basis is counted" "1" "$(field "$OUT" closed.basis.transcript)"
assert_eq "the rollout basis is counted" "1" "$(field "$OUT" closed.basis.rollout)"
assert_eq "the duration-only basis is counted" "1" "$(field "$OUT" closed.basis.duration-only)"
assert_contains "text output names the basis split" "$TEXT" "token basis:"
assert_contains "text output flags the unmeasured rows" "$TEXT" "reported no tokens"

echo "== arc scope expands to the arc's declared members =="
OUT=$(bash "$SPEND" --arc demo-arc --json --kdir "$KDIR" 2>/dev/null)
assert_eq "only member rows are in the total" "2" "$(field "$OUT" closed.sessions)"
assert_contains "the member is grouped" "$OUT" '"item-a"'
assert_not_contains "a non-member is excluded" "$OUT" '"item-b"'
assert_eq "the orphan is still reported inside the arc" "1" "$(field "$OUT" orphaned.sessions)"

echo "== work-item scope narrows to one item =="
OUT=$(bash "$SPEND" --work-item item-b --json --kdir "$KDIR" 2>/dev/null)
assert_eq "only that item is counted" "1" "$(field "$OUT" closed.sessions)"
assert_eq "its orphan count is zero" "0" "$(field "$OUT" orphaned.sessions)"

echo "== window bounds come from the reference journal reader =="
OUT=$(bash "$SPEND" --window-start 2026-08-02T00:00:00Z --window-end 2026-08-03T00:00:00Z --json --kdir "$KDIR" 2>/dev/null)
assert_eq "rows before the window drop out" "1" "$(field "$OUT" closed.sessions)"
assert_eq "the in-window orphan is still reported" "1" "$(field "$OUT" orphaned.sessions)"
OUT=$(bash "$SPEND" --window-start 2020-01-01T00:00:00Z --window-end 2020-01-02T00:00:00Z --json --kdir "$KDIR" 2>/dev/null)
assert_eq "an empty window totals zero" "0" "$(field "$OUT" closed.sessions)"

echo "== refusals are loud and coded =="
OUT=$(bash "$SPEND" --arc no-such-arc --kdir "$KDIR" 2>&1); RC=$?
assert_eq "an unknown arc exits 4" "4" "$RC"
assert_contains "the refusal names the arc" "$OUT" "no-such-arc"
OUT=$(bash "$SPEND" --arc demo-arc --work-item item-a --kdir "$KDIR" 2>&1); RC=$?
assert_eq "two scopes at once exits 1" "1" "$RC"
OUT=$(bash "$SPEND" --window-start 2026-08-01T00:00:00Z --kdir "$KDIR" 2>&1); RC=$?
assert_eq "a half window exits 1" "1" "$RC"
assert_contains "the half-window message explains the pairing" "$OUT" "supplied together"

echo "== an empty scope says so rather than reporting a cheap arc =="
OUT=$(bash "$SPEND" --work-item never-ran --kdir "$KDIR" 2>/dev/null)
assert_contains "zero is explained" "$OUT" "there were no rows, not because they were free"

echo "== the roll-up writes nothing =="
KDIR=$(new_store)
BEFORE=$(find "$KDIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
bash "$SPEND" --kdir "$KDIR" >/dev/null 2>&1
bash "$SPEND" --arc demo-arc --json --kdir "$KDIR" >/dev/null 2>&1
AFTER=$(find "$KDIR" -type f | sort | xargs shasum 2>/dev/null | shasum)
assert_eq "the store is byte-identical after two runs" "$BEFORE" "$AFTER"

echo "== the help text names the two-totals trap and the exit codes =="
OUT=$(bash "$SPEND" --help 2>&1)
assert_contains "help distinguishes this from retro's number" "$OUT" "not retro's session-spend number"
assert_contains "help documents exit 4" "$OUT" "4  --arc named an arc with no record"
assert_contains "help explains the orphaned exclusion" "$OUT" "never folded into the total"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
