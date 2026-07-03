#!/usr/bin/env bash
# test_verify_plan_backlinks_project.sh — Regression tests for [[project:...]]
# links in plan verification:
#
#   1. A project link with a record at _work/_projects/<slug>.md verifies.
#   2. A recordless project whose only member is archived verifies (member
#      list synthesized from the archived[] index projection).
#   3. A project link with no record and no members is reported unresolved —
#      and is never fuzzy-corrected to another entry.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"

PASS=0
FAIL=0
KDIR=$(mktemp -d)

cleanup() { rm -rf "$KDIR"; }
trap cleanup EXIT

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to find: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_absent() {
  local label="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $label"
    echo "    Did not expect to find: $needle"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# --- Fixtures ----------------------------------------------------------------

mkdir -p "$KDIR/_work/_projects"

cat > "$KDIR/_work/_projects/record-proj.md" <<'MD'
# Record Proj
**Status:** active
**Anchor:** A project with a record file.

Freeform description body.
MD

cat > "$KDIR/_work/_index.json" <<'JSON'
{
  "version": 1,
  "plans": [],
  "archived": [
    {
      "slug": "old-member",
      "title": "Old Member",
      "status": "archived",
      "project": "members-proj"
    }
  ]
}
JSON

PLAN_FILE="$KDIR/plan.md"
cat > "$PLAN_FILE" <<'MD'
# Test Plan

- [[project:record-proj]]
- [[project:members-proj]]
- [[project:ghost-proj]]
MD

# --- Run verifier ------------------------------------------------------------

echo "Test: verify-plan-backlinks.sh resolves [[project:...]] links"
OUTPUT=$(bash "$SCRIPTS_DIR/verify-plan-backlinks.sh" "$PLAN_FILE" "$KDIR")

assert_contains "record + archived-only-member links verify" "$OUTPUT" '"verified": 2'
assert_contains "no-record no-members link is unresolved" "$OUTPUT" '[[project:ghost-proj]]'
assert_absent "record link is not unresolved" "$OUTPUT" '"backlink": "[[project:record-proj]]"'
assert_absent "unresolved project link is never fuzzy-corrected" "$OUTPUT" '"from": "[[project:ghost-proj]]"'

# --- Summary -----------------------------------------------------------------

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
