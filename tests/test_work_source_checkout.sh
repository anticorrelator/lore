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
CHECKOUTS=$(mktemp -d)
RUNTIME_NAME="wsc-$$"

cleanup() {
  rm -rf "$KDIR" "$TEST_HOME" "$CHECKOUTS"
}
trap cleanup EXIT

mkdir -p "$KDIR/_work" "$KDIR/_sessions/instances" "$TEST_HOME/.lore/config"
ln -s "$SCRIPTS_DIR" "$TEST_HOME/.lore/scripts"
cp "$REPO_DIR/adapters/settings.template.json" "$TEST_HOME/.lore/config/settings.json"

# Every lore call runs in its own session runtime with a host binary that refuses
# the store-host arguments, recorded as such, so ensure() fails at once instead of
# starting a supervisor, as it does before 'bash install.sh' has rebuilt lore-tui.
STUB_HOST="$TEST_HOME/bin/lore-tui-old"
mkdir -p "$TEST_HOME/bin"
printf '#!/bin/sh\nexit 2\n' > "$STUB_HOST"
chmod +x "$STUB_HOST"
export LORE_SESSION_RUNTIME="$RUNTIME_NAME" LORE_SESSION_HOST_BINARY="$STUB_HOST" \
  LORE_SESSION_SUPERVISOR_QUIET_SECONDS=1 LORE_DATA_DIR="$TEST_HOME/.lore"
unset LORE_SESSION_HOST_KEY LORE_SESSION_SOURCE_DIR

session_runtime() {
  HOME="$TEST_HOME" python3 - "$SCRIPTS_DIR" "$@" <<'PYEOF'
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("managed", sys.argv[1] + "/session-managed.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
op, kdir = sys.argv[2], Path(sys.argv[3]).resolve()
key = m.RUNTIME.store_host_key(kdir)
if op == "key":
    print(key)
elif op == "refuse":
    stub = Path(sys.argv[4]).resolve()
    m.atomic(m.host_dir(kdir, key) / "supervisor-error.json", dict(
        schema_version=1, at=m.now(), store=str(kdir), host_key=key, exit_code=2, binary=str(stub),
        binary_identity=m.file_identity(stub), error="test host binary refuses the store-host arguments"))
elif op == "pin":
    m.atomic(m.RUNTIME.login_dir() / "served.json",
             {"schema_version": 1, "stores": {str(kdir): {"wanted_at": m.now(), "pin_knowledge_dir": True}}})
PYEOF
}
session_runtime refuse "$KDIR" "$STUB_HOST"
STORE_KEY="$(session_runtime key "$KDIR")"
# The store is pinned, as a host started with LORE_KNOWLEDGE_DIR naming a scratch
# store is, so a git checkout outside it belongs to it without resolution.
session_runtime pin "$KDIR"

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

mkdir -p "$CHECKOUTS/live"
git -C "$CHECKOUTS/live" init -q
LIVE_CHECKOUT="$(cd "$CHECKOUTS/live" && pwd -P)"
write_instance live-seat "$LIVE_CHECKOUT"

# --- Happy path: no hosted-session environment is required ------------------

write_work_item happy
HAPPY_OUTPUT=$(run_lore work source-checkout happy --from-instance live-seat 2>&1)
assert_contains "happy: command reports the source_checkout write" \
  "$HAPPY_OUTPUT" "source_checkout=$LIVE_CHECKOUT"
assert_eq "happy: stores the named live instance's physical checkout" \
  "$(meta_checkout happy)" "$LIVE_CHECKOUT"

capture_failure session request --type worker --slug happy--w9 \
  --prefer-dir "$LIVE_CHECKOUT" --context probe --initiator agent
assert_eq "happy: a store host that cannot start refuses the request" "$CAPTURED_STATUS" "1"
assert_contains "happy: the refusal leads with its repair" "$CAPTURED_OUTPUT" \
  "Error: store host did not start; fix the error below, retry"
assert_contains "happy: the refusal names the rebuild" "$CAPTURED_OUTPUT" "lore rebuild"
assert_eq "happy: a live lore-tui no longer takes the row instead" \
  "$(find "$KDIR/_sessions/requests/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"

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
  --prefer-dir "$LIVE_CHECKOUT" --context probe --initiator agent
assert_contains "request refusal: seed command names --from-instance" "$CAPTURED_OUTPUT" \
  "lore work source-checkout request-repair --from-instance <live-instance-name>"

# --- The store's session host serves every checkout of the store -------------

STORE_CHECKOUT="$CHECKOUTS/store-checkout"
mkdir -p "$STORE_CHECKOUT"
git -C "$STORE_CHECKOUT" init -q
STORE_CHECKOUT="$(cd "$STORE_CHECKOUT" && pwd -P)"
write_store_host() {
  printf '%s\n' "{\"name\":\"store-host\",\"pid\":$$,\"role\":\"session-host\",\"scope\":\"store\",\"host_key\":\"$STORE_KEY\",\"runtime\":\"$RUNTIME_NAME\",\"sessions\":$1}" \
    > "$KDIR/_sessions/instances/store-host.json"
}
write_store_host '[]'

write_work_item from-store-host
STORE_OUTPUT=$(cd "$STORE_CHECKOUT" && run_lore work source-checkout from-store-host --from-instance store-host 2>&1)
assert_contains "store host: seeds the checkout the command runs in" "$STORE_OUTPUT" \
  "source_checkout=$STORE_CHECKOUT"
assert_eq "store host: stores that checkout" "$(meta_checkout from-store-host)" "$STORE_CHECKOUT"

write_work_item store-host-outside
set +e
OUTSIDE_OUTPUT=$(cd "$CHECKOUTS" && run_lore work source-checkout store-host-outside --from-instance store-host 2>&1)
OUTSIDE_STATUS=$?
set -e
assert_eq "store host outside a checkout: exits non-zero" "$OUTSIDE_STATUS" "1"
assert_contains "store host outside a checkout: says why" "$OUTSIDE_OUTPUT" "is not inside a git checkout"
assert_eq "store host outside a checkout: does not mutate the item" "$(meta_checkout store-host-outside)" ""

INSIDE_STORE="$KDIR/_sessions/worktrees/inner"
mkdir -p "$INSIDE_STORE"
git -C "$INSIDE_STORE" init -q
write_work_item store-host-inside
set +e
INSIDE_OUTPUT=$(cd "$INSIDE_STORE" && run_lore work source-checkout store-host-inside --from-instance store-host 2>&1)
INSIDE_STATUS=$?
set -e
assert_eq "store host inside the store: exits non-zero" "$INSIDE_STATUS" "1"
assert_contains "store host inside the store: names the store" "$INSIDE_OUTPUT" "lies inside the knowledge store"

write_work_item hosted
write_store_host "[{\"slug\":\"hosted--w1\",\"type\":\"worker\",\"source_dir\":\"$STORE_CHECKOUT\"}]"
HOSTED_OUTPUT=$(
  LORE_SESSION_INSTANCE=gone-generation LORE_SESSION_SLUG=hosted--w1 LORE_SESSION_TYPE=worker \
    LORE_SESSION_HOST_KEY="$STORE_KEY" HOME="$TEST_HOME" LORE_KNOWLEDGE_DIR="$KDIR" \
    "$LORE" work source-checkout hosted 2>&1
)
assert_contains "store-hosted session: seeds the session row's source_dir" "$HOSTED_OUTPUT" \
  "source_checkout=$STORE_CHECKOUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
