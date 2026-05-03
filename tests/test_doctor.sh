#!/usr/bin/env bash
# test_doctor.sh — Tests for the role-config malformed check in scripts/doctor.sh
#
# Covers (Phase 1, D1):
#   - Per-repo config.json: invalid role value, unparseable JSON, clean, absent
#   - User-level settings.json: invalid role value, unparseable JSON, clean, absent
#   - Both layers absent: no role_config issues
#   - Caller-set LORE_DATA_DIR is honored (snapshot taken before doctor.sh
#     clobbers LORE_DATA_DIR to $HOME/.lore for installation-layout checks)
#
# Strategy: invoke doctor.sh directly with --json and filter the output for
# role_config issues only — ignoring drift in other components (symlinks,
# hooks, etc.) that the sandbox doesn't reproduce.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO_DIR/scripts/doctor.sh"

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

# Run doctor.sh --json with fixture paths and emit a newline-separated list
# of "<artifact>|<type>" for issues with component=="role_config" only.
# Other-component drift (symlinks, hooks, etc.) is filtered out.
role_issues() {
  local kdir="$1"
  local data_dir="$2"
  local out
  # set +e so a non-zero doctor exit (drift in any component) does not abort the test
  set +e
  out=$(LORE_KNOWLEDGE_DIR="$kdir" LORE_DATA_DIR="$data_dir" \
    bash "$DOCTOR" --json 2>/dev/null)
  set -e
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for i in d.get('issues', []):
    if i.get('component') == 'role_config':
        print(i.get('artifact', '') + '|' + i.get('type', ''))
" "$out"
}

# Helper: count of role_config issues (newline-separated; empty == 0).
role_issue_count() {
  local lines="$1"
  if [[ -z "$lines" ]]; then
    echo "0"
  else
    echo "$lines" | wc -l | tr -d ' '
  fi
}

echo "=== doctor role-config check tests ==="

# Build fixtures.
KDIR="$TEST_DIR/kdir"
DATA_DIR="$TEST_DIR/fakelore"
mkdir -p "$KDIR" "$DATA_DIR/config"

# Test 1: both layers absent → no role_config issues.
echo ""
echo "Test 1: Both layers absent → clean"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "absent both → 0 issues" "$(role_issue_count "$OUT")" "0"

# Test 2: per-repo clean (valid role) → no role_config issues.
echo ""
echo "Test 2: Per-repo config clean"
echo '{"role":"maintainer"}' > "$KDIR/config.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "repo=maintainer → 0 issues" "$(role_issue_count "$OUT")" "0"

echo '{"role":"contributor"}' > "$KDIR/config.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "repo=contributor → 0 issues" "$(role_issue_count "$OUT")" "0"

# Test 3: per-repo invalid role value → 1 malformed issue.
echo ""
echo "Test 3: Per-repo invalid role value"
echo '{"role":"bogus"}' > "$KDIR/config.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "repo=bogus → 1 issue" "$(role_issue_count "$OUT")" "1"
assert_eq "repo=bogus → type=malformed" \
  "$(echo "$OUT" | head -1 | cut -d'|' -f2)" "malformed"

# Test 4: per-repo unparseable JSON → 1 malformed issue.
echo ""
echo "Test 4: Per-repo unparseable JSON"
printf 'this is not json\n' > "$KDIR/config.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "repo=garbage → 1 issue" "$(role_issue_count "$OUT")" "1"
assert_eq "repo=garbage → type=malformed" \
  "$(echo "$OUT" | head -1 | cut -d'|' -f2)" "malformed"

# Test 5: per-repo with .role missing entirely → not malformed (treated like absent).
echo ""
echo "Test 5: Per-repo with .role key missing → clean"
echo '{"unrelated":"value"}' > "$KDIR/config.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "repo=missing-role → 0 issues" "$(role_issue_count "$OUT")" "0"

# Reset per-repo config for user-level tests.
rm -f "$KDIR/config.json"

# Test 6: user-level clean → no role_config issues.
echo ""
echo "Test 6: User-level settings.json clean"
echo '{"role":"maintainer"}' > "$DATA_DIR/config/settings.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "user=maintainer → 0 issues" "$(role_issue_count "$OUT")" "0"

# Test 7: user-level invalid role → 1 malformed issue.
echo ""
echo "Test 7: User-level invalid role"
echo '{"role":"archangel"}' > "$DATA_DIR/config/settings.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "user=archangel → 1 issue" "$(role_issue_count "$OUT")" "1"
assert_eq "user=archangel → type=malformed" \
  "$(echo "$OUT" | head -1 | cut -d'|' -f2)" "malformed"

# Test 8: user-level unparseable → 1 malformed issue.
echo ""
echo "Test 8: User-level unparseable JSON"
printf '{ broken json\n' > "$DATA_DIR/config/settings.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "user=garbage → 1 issue" "$(role_issue_count "$OUT")" "1"
assert_eq "user=garbage → type=malformed" \
  "$(echo "$OUT" | head -1 | cut -d'|' -f2)" "malformed"

# Test 9: both layers malformed → 2 malformed issues.
echo ""
echo "Test 9: Both layers malformed → 2 issues"
echo '{"role":"bogus"}' > "$KDIR/config.json"
printf 'not json\n' > "$DATA_DIR/config/settings.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
assert_eq "both malformed → 2 issues" "$(role_issue_count "$OUT")" "2"

# Test 10: caller-set LORE_DATA_DIR honored — user-level malformed at the
# caller's path, not at $HOME/.lore. Verifies the snapshot in doctor.sh
# captured the caller's LORE_DATA_DIR before the script clobbered it.
echo ""
echo "Test 10: Caller-set LORE_DATA_DIR is honored"
rm -f "$KDIR/config.json"
# malformed at the caller-supplied DATA_DIR
printf 'broken\n' > "$DATA_DIR/config/settings.json"
OUT=$(role_issues "$KDIR" "$DATA_DIR")
# Look for the caller-supplied path in the issue artifact (not $HOME/.lore)
got_path=$(echo "$OUT" | head -1 | cut -d'|' -f1)
case "$got_path" in
  "$DATA_DIR/config/settings.json")
    echo "  PASS: artifact references caller LORE_DATA_DIR"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL: artifact references caller LORE_DATA_DIR"
    echo "    expected: $DATA_DIR/config/settings.json"
    echo "    actual:   $got_path"
    FAIL=$((FAIL + 1))
    ;;
esac

# Test 11: doctor --json exit code is non-zero when role_config malformed
# (and other components are clean enough that role_config is the only signal).
# We assert exit code only reflects "non-zero on any drift" — not strictly tied
# to role_config — by checking doctor exits non-zero with malformed role config
# (the ambient install state may also drift, which is fine; we just confirm the
# exit-non-zero path fires when role_config is dirty).
echo ""
echo "Test 11: doctor --json exits non-zero when role_config malformed"
echo '{"role":"bogus"}' > "$KDIR/config.json"
rm -f "$DATA_DIR/config/settings.json"
set +e
LORE_KNOWLEDGE_DIR="$KDIR" LORE_DATA_DIR="$DATA_DIR" \
  bash "$DOCTOR" --json >/dev/null 2>&1
exit_code=$?
set -e
if [[ "$exit_code" -ne 0 ]]; then
  echo "  PASS: doctor exits non-zero with malformed role config"
  PASS=$((PASS + 1))
else
  echo "  FAIL: doctor exits non-zero with malformed role config"
  echo "    expected: non-zero exit"
  echo "    actual:   $exit_code"
  FAIL=$((FAIL + 1))
fi

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
