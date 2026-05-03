#!/usr/bin/env bash
# test_scale_registry.sh — Smoke tests for scale-registry.sh relabel and get-adjacency
# Covers the 4-bucket configuration: implementation, subsystem, architecture, abstract

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

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    echo "  FAIL: $label"
    echo "    Did not expect to find: $unexpected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
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
assert_equal "get-ids[3] = architecture"   "$(echo "$IDS_OUTPUT" | sed -n '3p')" "architecture"
assert_equal "get-ids[4] = abstract"       "$(echo "$IDS_OUTPUT" | sed -n '4p')" "abstract"

echo ""
echo "=== get-adjacency: boundary tests ==="

# implementation (ordinal 1): no below, subsystem above
ADJ_IMPL=$("$REGISTRY_SH" get-adjacency implementation)
assert_equal "implementation: no below (empty first line)" "$(echo "$ADJ_IMPL" | sed -n '1p')" ""
assert_equal "implementation: subsystem above"             "$(echo "$ADJ_IMPL" | sed -n '2p')" "subsystem"

# subsystem (ordinal 2): implementation below, architecture above
ADJ_SUB=$("$REGISTRY_SH" get-adjacency subsystem)
assert_equal "subsystem: implementation below"  "$(echo "$ADJ_SUB" | sed -n '1p')" "implementation"
assert_equal "subsystem: architecture above"    "$(echo "$ADJ_SUB" | sed -n '2p')" "architecture"

# architecture (ordinal 3): subsystem below, abstract above
ADJ_ARCH=$("$REGISTRY_SH" get-adjacency architecture)
assert_equal "architecture: subsystem below"   "$(echo "$ADJ_ARCH" | sed -n '1p')" "subsystem"
assert_equal "architecture: abstract above"    "$(echo "$ADJ_ARCH" | sed -n '2p')" "abstract"

# abstract (ordinal 4): architecture below, no above
ADJ_ABS=$("$REGISTRY_SH" get-adjacency abstract)
assert_equal "abstract: architecture below" "$(echo "$ADJ_ABS" | sed -n '1p')" "architecture"
assert_equal "abstract: no above (empty second line)" "$(echo "$ADJ_ABS" | sed -n '2p')" ""

# invalid id
ADJ_ERR=$("$REGISTRY_SH" get-adjacency unknown 2>&1 || true)
assert_contains "get-adjacency unknown: error message" "$ADJ_ERR" "not found"

echo ""
echo "=== relabel: round-trip (modifies real registry, restored by trap) ==="

OLD_VERSION=$("$REGISTRY_SH" get-version)

RELABEL_OUT=$("$REGISTRY_SH" relabel architecture --new-label architecture-renamed 2>&1)
assert_contains "relabel architecture->architecture-renamed: success message" "$RELABEL_OUT" "Relabeled"
assert_contains "relabel architecture->architecture-renamed: shows old label"  "$RELABEL_OUT" "architecture"
assert_contains "relabel architecture->architecture-renamed: shows new label"  "$RELABEL_OUT" "architecture-renamed"

# Version should have bumped by 1
NEW_VERSION=$("$REGISTRY_SH" get-version)
assert_equal "relabel bumps version by 1" "$NEW_VERSION" "$((OLD_VERSION + 1))"

# get-label returns new label after relabel
NEW_LABEL=$("$REGISTRY_SH" get-label architecture)
assert_equal "get-label architecture = architecture-renamed after relabel" "$NEW_LABEL" "architecture-renamed"

# 'labels' was updated in the registry JSON
REGISTRY_AFTER=$(cat "$REAL_REGISTRY")
assert_contains "registry.labels.architecture updated to new label" \
  "$REGISTRY_AFTER" "\"architecture\": \"architecture-renamed\""

# No label_history field is created by relabel
assert_not_contains "registry has no label_history field after relabel" \
  "$REGISTRY_AFTER" "label_history"

# Relabeling to same name is a no-op (exit 0, message says no-op)
NOOP_OUT=$("$REGISTRY_SH" relabel architecture --new-label architecture-renamed 2>&1)
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
