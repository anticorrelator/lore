#!/usr/bin/env bash
# test_cli_role_gate.sh — Tests for cli/lore role gating (task-54)
#
# Covers:
#   - Contributor role rejected from maintainer verbs (retro import/aggregate)
#     with exit code 2 (distinct from usage=1 / script-error≥3)
#   - Error message names the escape hatches (env var, per-repo, user-level)
#   - Contributor-facing 'retro export' passes through the gate
#   - Contributor 'retro --help' OMITS maintainer verbs
#   - Maintainer 'retro --help' includes them
#   - LORE_ROLE=maintainer env override lets the call through
#
# This test does not exercise the actual retro-import/aggregate scripts —
# we only verify the CLI layer's role gate. Success for the gate-passed
# path is that we reach retro-{import,aggregate}.sh's own argument parsing
# (which exits non-2 with its own error).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LORE_CLI="$SCRIPT_DIR/cli/lore"

PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# Fixture env: give resolve_role() a knowable default path by routing
# LORE_DATA_DIR + LORE_KNOWLEDGE_DIR to the temp dir. Neither config file
# exists, so resolve_role() returns the baseline default "contributor".
export LORE_DATA_DIR="$TEST_DIR/fakelore"
export LORE_KNOWLEDGE_DIR="$TEST_DIR/kdir"
mkdir -p "$LORE_DATA_DIR/config" "$LORE_KNOWLEDGE_DIR"

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected=$expected, actual=$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — did not find: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label — unexpected: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== cli/lore role-gate tests ==="

# --- Test 1: Contributor rejected from retro import ---
echo ""
echo "Test 1: Contributor 'retro import' rejected with exit 2"
EXIT=0
ERR=$("$LORE_CLI" retro import 2>&1 >/dev/null) || EXIT=$?
assert_eq "retro import exit code" "$EXIT" "2"
assert_contains "error names verb" "$ERR" "lore retro import"
assert_contains "error cites current role" "$ERR" "(current role: contributor)"
assert_contains "error names per-repo config path" "$ERR" "repos/<repo>/config.json"
assert_contains "error names env override" "$ERR" "LORE_ROLE=maintainer"

# --- Test 2: Contributor rejected from retro aggregate ---
echo ""
echo "Test 2: Contributor 'retro aggregate' rejected with exit 2"
EXIT=0
ERR=$("$LORE_CLI" retro aggregate 2>&1 >/dev/null) || EXIT=$?
assert_eq "retro aggregate exit code" "$EXIT" "2"
assert_contains "error names verb" "$ERR" "lore retro aggregate"

# --- Test 3: Contributor 'retro export' is NOT gated ---
echo ""
echo "Test 3: Contributor 'retro export' is not gated"
# Call with --help so the script exits cleanly; verify no exit-2 gate.
EXIT=0
OUT=$("$LORE_CLI" retro export --help 2>&1) || EXIT=$?
# The subcommand may produce its own help or error; we only assert that
# the exit code is NOT 2 (gate did not fire).
if [[ "$EXIT" == "2" ]]; then
  echo "  FAIL: retro export exited 2 (role gate fired — should not have)"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: retro export did not trigger role gate (exit=$EXIT)"
  PASS=$((PASS + 1))
fi

# --- Test 4: Contributor retro --help omits maintainer verbs ---
echo ""
echo "Test 4: Contributor 'retro --help' omits import/aggregate"
HELP=$("$LORE_CLI" retro --help 2>&1 || true)
assert_contains "export listed for contributors" "$HELP" "export"
assert_not_contains "import NOT listed for contributors" "$HELP" "import      Ingest"
assert_not_contains "aggregate NOT listed for contributors" "$HELP" "aggregate   Compute"
assert_contains "help surfaces current role for visibility" "$HELP" "Current role: contributor"

# --- Test 5: Maintainer retro --help includes maintainer verbs ---
echo ""
echo "Test 5: Maintainer 'retro --help' includes import/aggregate"
HELP=$(LORE_ROLE=maintainer "$LORE_CLI" retro --help 2>&1 || true)
assert_contains "export still listed" "$HELP" "export"
assert_contains "import shown to maintainer" "$HELP" "import      Ingest"
assert_contains "aggregate shown to maintainer" "$HELP" "aggregate   Compute"
assert_contains "help surfaces maintainer role" "$HELP" "Current role: maintainer"

# --- Test 6: Env-override lets maintainer verbs through the gate ---
echo ""
echo "Test 6: LORE_ROLE=maintainer passes the gate (script-level error is non-2)"
EXIT=0
OUT=$(LORE_ROLE=maintainer "$LORE_CLI" retro import 2>&1) || EXIT=$?
# The gate is passed; retro-import.sh will exit 1 for missing arg.
# Critically, it should NOT be 2.
if [[ "$EXIT" == "2" ]]; then
  echo "  FAIL: env-override failed — still exited 2"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: env-override bypassed the gate (exit=$EXIT from underlying script)"
  PASS=$((PASS + 1))
fi

# --- Test 7: Per-repo config.json=maintainer lets the gate pass ---
echo ""
echo "Test 7: Per-repo config.json with role=maintainer passes the gate"
echo '{"role":"maintainer"}' > "$LORE_KNOWLEDGE_DIR/config.json"
EXIT=0
"$LORE_CLI" retro aggregate >/dev/null 2>&1 || EXIT=$?
if [[ "$EXIT" == "2" ]]; then
  echo "  FAIL: per-repo maintainer config did not pass the gate"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: per-repo maintainer config passed the gate (exit=$EXIT from underlying script)"
  PASS=$((PASS + 1))
fi
rm -f "$LORE_KNOWLEDGE_DIR/config.json"

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
