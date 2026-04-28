#!/usr/bin/env bash
# test_scale_registry.sh — Smoke tests for scale-registry.sh relabel and get-adjacency
# Covers the 4-bucket configuration: implementation, subsystem, architectural, application

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
REGISTRY_SH="$SCRIPT_DIR/scale-registry.sh"

PASS=0
FAIL=0

assert_equal() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $(echo "$expected" | head -5)"
    echo "    Got:      $(echo "$actual" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_zero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -eq 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected exit 0, got $exit_code)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit_nonzero() {
  local label="$1" exit_code="$2"
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected non-zero exit, got 0)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup: save/restore the real registry around relabel tests ---
TMP_DIR=$(mktemp -d)
REAL_REGISTRY="$SCRIPT_DIR/scale-registry.json"
REGISTRY_BACKUP="$TMP_DIR/scale-registry.json.bak"
cp "$REAL_REGISTRY" "$REGISTRY_BACKUP"

cleanup() {
  cp "$REGISTRY_BACKUP" "$REAL_REGISTRY"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "=== get-ids: 4-bucket set ==="
IDS_OUTPUT=$("$REGISTRY_SH" get-ids)
assert_equal "get-ids returns 4 entries" "$(echo "$IDS_OUTPUT" | wc -l | tr -d ' ')" "4"
assert_equal "get-ids[1] = implementation" "$(echo "$IDS_OUTPUT" | sed -n '1p')" "implementation"
assert_equal "get-ids[2] = subsystem"      "$(echo "$IDS_OUTPUT" | sed -n '2p')" "subsystem"
assert_equal "get-ids[3] = architectural"  "$(echo "$IDS_OUTPUT" | sed -n '3p')" "architectural"
assert_equal "get-ids[4] = application"    "$(echo "$IDS_OUTPUT" | sed -n '4p')" "application"

echo ""
echo "=== get-adjacency: boundary tests ==="

# implementation (ordinal 1): no below, subsystem above
ADJ_IMPL=$("$REGISTRY_SH" get-adjacency implementation)
assert_equal "implementation: no below (empty first line)" "$(echo "$ADJ_IMPL" | sed -n '1p')" ""
assert_equal "implementation: subsystem above"             "$(echo "$ADJ_IMPL" | sed -n '2p')" "subsystem"

# subsystem (ordinal 2): implementation below, architectural above
ADJ_SUB=$("$REGISTRY_SH" get-adjacency subsystem)
assert_equal "subsystem: implementation below"  "$(echo "$ADJ_SUB" | sed -n '1p')" "implementation"
assert_equal "subsystem: architectural above"   "$(echo "$ADJ_SUB" | sed -n '2p')" "architectural"

# architectural (ordinal 3): subsystem below, application above
ADJ_ARCH=$("$REGISTRY_SH" get-adjacency architectural)
assert_equal "architectural: subsystem below"   "$(echo "$ADJ_ARCH" | sed -n '1p')" "subsystem"
assert_equal "architectural: application above" "$(echo "$ADJ_ARCH" | sed -n '2p')" "application"

# application (ordinal 4): architectural below, no above
ADJ_APP=$("$REGISTRY_SH" get-adjacency application)
assert_equal "application: architectural below" "$(echo "$ADJ_APP" | sed -n '1p')" "architectural"
assert_equal "application: no above (empty second line)" "$(echo "$ADJ_APP" | sed -n '2p')" ""

# invalid id
ADJ_ERR=$("$REGISTRY_SH" get-adjacency unknown 2>&1 || true)
assert_contains "get-adjacency unknown: error message" "$ADJ_ERR" "not found"

echo ""
echo "=== relabel: round-trip (modifies real registry, restored by trap) ==="

RELABEL_OUT=$("$REGISTRY_SH" relabel application --new-label system 2>&1)
assert_contains "relabel application->system: success message" "$RELABEL_OUT" "Relabeled"
assert_contains "relabel application->system: shows old label"  "$RELABEL_OUT" "application"
assert_contains "relabel application->system: shows new label"  "$RELABEL_OUT" "system"

# Version should have bumped
NEW_VERSION=$("$REGISTRY_SH" get-version)
assert_equal "relabel bumps version to 2" "$NEW_VERSION" "2"

# get-label at current version returns new label
NEW_LABEL=$("$REGISTRY_SH" get-label application)
assert_equal "get-label application = system after relabel" "$NEW_LABEL" "system"

# get-label at version 1 returns old label (historical)
OLD_LABEL=$("$REGISTRY_SH" get-label --version 1 application)
assert_equal "get-label --version 1 application = application (historical)" "$OLD_LABEL" "application"

# Relabeling to same name is a no-op (exit 0, message says no-op)
NOOP_OUT=$("$REGISTRY_SH" relabel application --new-label system 2>&1)
assert_contains "relabel no-op message" "$NOOP_OUT" "No-op"

# Restore for error-case tests (cleanup trap also restores on exit)
cp "$REGISTRY_BACKUP" "$REAL_REGISTRY"

echo ""
echo "=== relabel: error cases ==="
RELABEL_ERR=$("$REGISTRY_SH" relabel unknown --new-label foo 2>&1 || true)
assert_contains "relabel unknown id: error message" "$RELABEL_ERR" "not found"

RELABEL_NOARGS=$("$REGISTRY_SH" relabel 2>&1 || true)
assert_contains "relabel no args: usage error" "$RELABEL_NOARGS" "requires"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
