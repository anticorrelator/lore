#!/usr/bin/env bash
# test_review_body_flags.sh — Tests for create-followup.sh review-body channel flags.
#
# Verifies the additive --review-body / --review-body-selected / --review-event flags
# on create-followup.sh:
#   1. A populated wrapper carries review_body, review_body_selected, review_event.
#   2. Legacy parity — omitting all three flags yields a wrapper with the original five
#      keys and no review_body keys (byte-identical to pre-change output).
#   3. --review-event defaults to COMMENT when --review-body is set without it.
#   4. --review-body-selected without --review-body is rejected.
#   5. --review-event without --review-body is rejected.
#   6. --review-body outside the ProposedReview wrapper path is rejected.
#   7. An invalid --review-event value is rejected.
#   8. --review-event APPROVE / REQUEST_CHANGES round-trip when paired with --review-body.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

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

assert_exit_nonzero() {
  local label="$1" rc="$2"
  if [[ "$rc" -ne 0 ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected non-zero exit"
    FAIL=$((FAIL + 1))
  fi
}

setup_knowledge_store() {
  rm -rf "$KNOWLEDGE_DIR"
  mkdir -p "$KNOWLEDGE_DIR"
  echo '{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}' > "$KNOWLEDGE_DIR/_manifest.json"
}

setup_knowledge_store
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

# Bare comments array (the real producer shape — a JSON list of comment objects).
COMMENTS='[{"path":"a.py","line":1,"body":"x","selected":true}]'

wrapper_json() {
  # Echo the wrapper file for the given followup slug.
  cat "$KNOWLEDGE_DIR/_followups/$1/proposed-comments.json"
}

py_field() {
  # py_field <slug> <python-expr-on-`d`> — load wrapper as d, print the expression.
  python3 -c "import json,sys; d=json.load(open('$KNOWLEDGE_DIR/_followups/$1/proposed-comments.json')); print($2)"
}

echo "=== create-followup.sh review-body flag tests ==="
echo ""

# =============================================
# Test 1: populated wrapper carries all three review_body keys
# =============================================
echo "Test 1: populated wrapper — review_body / review_body_selected / review_event present"
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Body followup" --source "pr-review" \
  --proposed-comments "$COMMENTS" \
  --pr 7 --owner me --repo r --head-sha abc \
  --review-body "Whole-PR structural note" --review-body-selected --review-event COMMENT > /dev/null 2>&1

assert_eq "review_body populated" "$(py_field body-followup "d['review_body']")" "Whole-PR structural note"
assert_eq "review_body_selected true" "$(py_field body-followup "d['review_body_selected']")" "True"
assert_eq "review_event COMMENT" "$(py_field body-followup "d['review_event']")" "COMMENT"

# =============================================
# Test 2: legacy parity — no flags => original five keys, no review keys
# =============================================
echo ""
echo "Test 2: legacy parity — wrapper free of review_body keys when flags omitted"
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Legacy wrapper" --source "pr-review" \
  --proposed-comments "$COMMENTS" \
  --pr 7 --owner me --repo r --head-sha abc > /dev/null 2>&1

KEYS=$(py_field legacy-wrapper "','.join(d.keys())")
assert_eq "wrapper keys are exactly the original five" "$KEYS" "pr,owner,repo,head_sha,comments"
HAS_REVIEW=$(py_field legacy-wrapper "any(k.startswith('review_') for k in d)")
assert_eq "no review_ keys present" "$HAS_REVIEW" "False"

# =============================================
# Test 3: --review-event defaults to COMMENT when omitted alongside --review-body
# =============================================
echo ""
echo "Test 3: --review-event defaults to COMMENT; --review-body-selected absent => false"
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Default event" --source "pr-review" \
  --proposed-comments "$COMMENTS" \
  --pr 7 --owner me --repo r --head-sha abc \
  --review-body "Body only" > /dev/null 2>&1

assert_eq "review_event defaults to COMMENT" "$(py_field default-event "d['review_event']")" "COMMENT"
assert_eq "review_body_selected defaults to false" "$(py_field default-event "d['review_body_selected']")" "False"
assert_eq "review_body populated without selection" "$(py_field default-event "d['review_body']")" "Body only"

# =============================================
# Test 4: --review-body-selected without --review-body is rejected
# =============================================
echo ""
echo "Test 4: --review-body-selected requires --review-body"
setup_knowledge_store

set +e
bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Selected no body" --source "pr-review" \
  --proposed-comments "$COMMENTS" --pr 7 --owner me --repo r --head-sha abc \
  --review-body-selected > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "rejects --review-body-selected without --review-body" "$RC"

# =============================================
# Test 5: --review-event without --review-body is rejected
# =============================================
echo ""
echo "Test 5: --review-event requires --review-body"
setup_knowledge_store

set +e
bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Event no body" --source "pr-review" \
  --proposed-comments "$COMMENTS" --pr 7 --owner me --repo r --head-sha abc \
  --review-event APPROVE > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "rejects --review-event without --review-body" "$RC"

# =============================================
# Test 6: --review-body outside the ProposedReview wrapper path is rejected
# =============================================
echo ""
echo "Test 6: --review-body requires the ProposedReview wrapper path"
setup_knowledge_store

set +e
bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Body no wrapper" --source "pr-review" \
  --review-body "orphan body" > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "rejects --review-body without --proposed-comments + PR flags" "$RC"

# =============================================
# Test 7: invalid --review-event value is rejected
# =============================================
echo ""
echo "Test 7: invalid --review-event value is rejected"
setup_knowledge_store

set +e
bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Bad event" --source "pr-review" \
  --proposed-comments "$COMMENTS" --pr 7 --owner me --repo r --head-sha abc \
  --review-body "x" --review-event BOGUS > /dev/null 2>&1
RC=$?
set -e
assert_exit_nonzero "rejects --review-event BOGUS" "$RC"

# =============================================
# Test 8: APPROVE / REQUEST_CHANGES round-trip with --review-body
# =============================================
echo ""
echo "Test 8: APPROVE / REQUEST_CHANGES events round-trip"
setup_knowledge_store

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Approve event" --source "pr-review" \
  --proposed-comments "$COMMENTS" --pr 7 --owner me --repo r --head-sha abc \
  --review-body "lgtm" --review-body-selected --review-event APPROVE > /dev/null 2>&1
assert_eq "review_event APPROVE round-trips" "$(py_field approve-event "d['review_event']")" "APPROVE"

bash "$SCRIPT_DIR/create-followup.sh" \
  --title "Changes event" --source "pr-review" \
  --proposed-comments "$COMMENTS" --pr 7 --owner me --repo r --head-sha abc \
  --review-body "please fix" --review-body-selected --review-event REQUEST_CHANGES > /dev/null 2>&1
assert_eq "review_event REQUEST_CHANGES round-trips" "$(py_field changes-event "d['review_event']")" "REQUEST_CHANGES"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All review-body flag tests passed!"
  exit 0
fi
