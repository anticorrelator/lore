#!/usr/bin/env bash
# test_resolve_role.sh — Tests for resolve_role() in scripts/lib.sh
#
# Covers:
#   - Default when no config exists → "contributor"
#   - LORE_ROLE env var override (both values + invalid fall-through)
#   - Per-repo config.json → .role (maintainer and contributor)
#   - Per-repo config malformed / bogus role → fall through
#   - User-level ~/.lore/config/settings.json fallback
#   - Per-repo beats user-level; env beats per-repo

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"

PASS=0
FAIL=0

TEST_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: run resolve_role with a clean environment + fixture paths.
# Args: <kdir-path> <lore-data-dir-path> [env-role]
run_resolve() {
  local kdir="$1"
  local data_dir="$2"
  local env_role="${3:-}"
  local env_prefix=""
  if [[ -n "$env_role" ]]; then
    env_prefix="export LORE_ROLE='$env_role';"
  fi
  bash -c "
    $env_prefix
    export LORE_KNOWLEDGE_DIR='$kdir'
    export LORE_DATA_DIR='$data_dir'
    source '$SCRIPTS_DIR/lib.sh'
    resolve_role
  "
}

echo "=== resolve_role() tests ==="

# Build fixtures.
KDIR="$TEST_DIR/kdir"
DATA_DIR="$TEST_DIR/fakelore"
mkdir -p "$KDIR" "$DATA_DIR/config"

# Test 1: Default — no config files anywhere.
echo ""
echo "Test 1: Default (no configs) → contributor"
OUT=$(run_resolve "$KDIR" "$DATA_DIR")
assert_eq "default=contributor" "$OUT" "contributor"

# Test 2: LORE_ROLE env var overrides (both valid values).
echo ""
echo "Test 2: LORE_ROLE env var"
assert_eq "env=maintainer" "$(run_resolve "$KDIR" "$DATA_DIR" maintainer)" "maintainer"
assert_eq "env=contributor" "$(run_resolve "$KDIR" "$DATA_DIR" contributor)" "contributor"

# Test 3: LORE_ROLE invalid value falls through to default.
echo ""
echo "Test 3: LORE_ROLE invalid → fall-through"
assert_eq "env=bogus → contributor (default)" \
  "$(run_resolve "$KDIR" "$DATA_DIR" bogus-role)" "contributor"

# Test 4: Per-repo config.json wins.
echo ""
echo "Test 4: Per-repo config.json"
echo '{"role":"maintainer"}' > "$KDIR/config.json"
assert_eq "repo=maintainer" "$(run_resolve "$KDIR" "$DATA_DIR")" "maintainer"
echo '{"role":"contributor"}' > "$KDIR/config.json"
assert_eq "repo=contributor" "$(run_resolve "$KDIR" "$DATA_DIR")" "contributor"

# Test 5: Per-repo malformed JSON → fall through.
echo ""
echo "Test 5: Per-repo malformed/bogus → fall through"
printf 'not json at all\n' > "$KDIR/config.json"
assert_eq "repo=malformed → contributor" "$(run_resolve "$KDIR" "$DATA_DIR")" "contributor"
echo '{"role":"archangel"}' > "$KDIR/config.json"
assert_eq "repo=invalid-role → contributor" "$(run_resolve "$KDIR" "$DATA_DIR")" "contributor"

# Test 6: User-level settings.json fallback.
echo ""
echo "Test 6: User-level settings.json fallback"
rm "$KDIR/config.json"
echo '{"role":"maintainer"}' > "$DATA_DIR/config/settings.json"
assert_eq "user=maintainer" "$(run_resolve "$KDIR" "$DATA_DIR")" "maintainer"

# Test 7: Per-repo beats user-level.
echo ""
echo "Test 7: Precedence — per-repo beats user-level"
echo '{"role":"contributor"}' > "$KDIR/config.json"
# user is still maintainer from Test 6
assert_eq "repo=contributor beats user=maintainer" \
  "$(run_resolve "$KDIR" "$DATA_DIR")" "contributor"

# Test 8: Env var beats per-repo.
echo ""
echo "Test 8: Precedence — env beats per-repo"
# repo is contributor, user is maintainer; env forces maintainer
assert_eq "env=maintainer beats repo=contributor" \
  "$(run_resolve "$KDIR" "$DATA_DIR" maintainer)" "maintainer"

# Test 9: User-level malformed also falls through.
echo ""
echo "Test 9: User-level malformed → default"
rm "$KDIR/config.json"
printf 'broken json\n' > "$DATA_DIR/config/settings.json"
assert_eq "repo=absent, user=malformed → contributor" \
  "$(run_resolve "$KDIR" "$DATA_DIR")" "contributor"

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
