#!/usr/bin/env bash
# test_work_source_checkout.sh — Regression tests for declaring a work item's
# source checkout from a named live instance outside a hosted session.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"
LORE="$REPO_DIR/cli/lore"

PASS=0
FAIL=0
KDIR=$(mktemp -d)
TEST_HOME=$(mktemp -d)

cleanup() {
  rm -rf "$KDIR" "$TEST_HOME"
}
trap cleanup EXIT

mkdir -p "$KDIR/_work" "$KDIR/_sessions/instances" "$TEST_HOME/.lore"
ln -s "$SCRIPTS_DIR" "$TEST_HOME/.lore/scripts"

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to find: $needle"
    echo "    Actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

write_work_item() {
  local slug="$1"
  mkdir -p "$KDIR/_work/$slug"
  printf '{"slug":"%s","title":"%s","status":"active"}\n' "$slug" "$slug" \
    > "$KDIR/_work/$slug/_meta.json"
}

write_instance() {
  local name="$1" project_dir="${2:-}"
  if [[ -n "$project_dir" ]]; then
    printf '{"name":"%s","pid":4242,"project_dir":"%s","sessions":[]}\n' \
      "$name" "$project_dir" > "$KDIR/_sessions/instances/$name.json"
  else
    printf '{"name":"%s","pid":4242,"sessions":[]}\n' "$name" \
      > "$KDIR/_sessions/instances/$name.json"
  fi
}

run_lore() {
  env -u LORE_SESSION_INSTANCE -u LORE_SESSION_SLUG -u LORE_SESSION_TYPE \
    HOME="$TEST_HOME" LORE_KNOWLEDGE_DIR="$KDIR" "$LORE" "$@"
}

meta_checkout() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("source_checkout", ""))' \
    "$KDIR/_work/$1/_meta.json"
}

capture_failure() {
  set +e
  CAPTURED_OUTPUT=$(run_lore "$@" 2>&1)
  CAPTURED_STATUS=$?
  set -e
}

mkdir -p "$KDIR/checkouts/live"
LIVE_CHECKOUT="$(cd "$KDIR/checkouts/live" && pwd -P)"
write_instance live-seat "$LIVE_CHECKOUT"

# --- Happy path: no hosted-session environment is required ------------------

write_work_item happy
HAPPY_OUTPUT=$(run_lore work source-checkout happy --from-instance live-seat 2>&1)
assert_contains "happy: command reports the source_checkout write" \
  "$HAPPY_OUTPUT" "source_checkout=$LIVE_CHECKOUT"
assert_eq "happy: stores the named live instance's physical checkout" \
  "$(meta_checkout happy)" "$LIVE_CHECKOUT"

REQUEST_OUTPUT=$(run_lore session request --type worker --slug happy--w9 \
  --framework codex --prefer-dir "$LIVE_CHECKOUT" --context probe --initiator agent 2>&1)
assert_contains "happy: declared item permits the worker request" "$REQUEST_OUTPUT" \
  "[session] Enqueued worker request"

# --- Explicit instance takes precedence over session provenance -------------

write_work_item precedence
PRECEDENCE_OUTPUT=$(
  LORE_SESSION_INSTANCE=missing LORE_SESSION_SLUG=wrong LORE_SESSION_TYPE=chat \
    HOME="$TEST_HOME" LORE_KNOWLEDGE_DIR="$KDIR" "$LORE" work source-checkout \
    precedence --from-instance live-seat 2>&1
)
assert_contains "precedence: explicit instance wins over unusable session provenance" \
  "$PRECEDENCE_OUTPUT" "source_checkout=$LIVE_CHECKOUT"

# --- Calling-session provenance remains supported ---------------------------

write_work_item session-provenance
printf '%s\n' \
  "{\"name\":\"session-seat\",\"pid\":4242,\"project_dir\":\"$LIVE_CHECKOUT\",\"sessions\":[{\"slug\":\"session-provenance\",\"type\":\"chat\",\"worktree\":{\"captured\":{\"canonical_path\":\"$LIVE_CHECKOUT\"}}}]}" \
  > "$KDIR/_sessions/instances/session-seat.json"
SESSION_OUTPUT=$(
  LORE_SESSION_INSTANCE=session-seat LORE_SESSION_SLUG=session-provenance \
    LORE_SESSION_TYPE=chat HOME="$TEST_HOME" LORE_KNOWLEDGE_DIR="$KDIR" \
    "$LORE" work source-checkout session-provenance 2>&1
)
assert_contains "session provenance: existing invocation still succeeds" \
  "$SESSION_OUTPUT" "source_checkout=$LIVE_CHECKOUT"

# --- Unknown instance --------------------------------------------------------

write_work_item unknown
capture_failure work source-checkout unknown --from-instance absent-seat
assert_eq "unknown: exits non-zero" "$CAPTURED_STATUS" "1"
assert_contains "unknown: names the missing instance" "$CAPTURED_OUTPUT" \
  "unknown instance 'absent-seat'"
assert_contains "unknown: names session list as the repair" "$CAPTURED_OUTPUT" \
  "lore session list"
assert_eq "unknown: does not mutate the item" "$(meta_checkout unknown)" ""

# --- Stale registry row ------------------------------------------------------

write_work_item stale
write_instance stale-seat "$LIVE_CHECKOUT"
touch -t 202601010000 "$KDIR/_sessions/instances/stale-seat.json"
capture_failure work source-checkout stale --from-instance stale-seat
assert_eq "stale: exits non-zero" "$CAPTURED_STATUS" "1"
assert_contains "stale: identifies the row as stale" "$CAPTURED_OUTPUT" \
  "instance 'stale-seat' is stale"
assert_contains "stale: names restart as a repair" "$CAPTURED_OUTPUT" \
  "Restart that instance"
assert_eq "stale: does not mutate the item" "$(meta_checkout stale)" ""

# --- Live row without checkout provenance -----------------------------------

write_work_item no-checkout
write_instance bare-seat
capture_failure work source-checkout no-checkout --from-instance bare-seat
assert_eq "no checkout: exits non-zero" "$CAPTURED_STATUS" "1"
assert_contains "no checkout: identifies the missing project_dir" "$CAPTURED_OUTPUT" \
  "records no checkout path (project_dir)"
assert_contains "no checkout: names restart as a repair" "$CAPTURED_OUTPUT" \
  "Restart that instance"

# --- Help and caller repairs -------------------------------------------------

HELP_OUTPUT=$(run_lore work source-checkout --help 2>&1)
assert_contains "help: usage names --from-instance" "$HELP_OUTPUT" \
  "Usage: lore work source-checkout <slug> [--from-instance <name>] [--json]"
assert_contains "help: explains the live registry source" "$HELP_OUTPUT" \
  "with --from-instance it is read from that live"

write_work_item no-provenance
capture_failure work source-checkout no-provenance
assert_contains "no provenance: existing refusal names the new repair" "$CAPTURED_OUTPUT" \
  "pass '--from-instance <name>'"

write_work_item request-repair
capture_failure session request --type worker --slug request-repair--w9 \
  --framework codex --prefer-dir "$LIVE_CHECKOUT" --context probe --initiator agent
assert_contains "request refusal: seed command names --from-instance" "$CAPTURED_OUTPUT" \
  "lore work source-checkout request-repair --from-instance <live-instance-name>"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
