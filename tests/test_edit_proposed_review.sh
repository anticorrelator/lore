#!/usr/bin/env bash
# test_edit_proposed_review.sh — Tests for `lore followup edit-review`
# (scripts/edit-proposed-review.sh) and the lens_findings field of
# `lore followup view --json`.
#
#   1. --comment N --deselect / --select flips one comment's selection.
#   2. --comment N --body replaces its text; unknown fields survive.
#   3. --all-comments --select selects every comment.
#   4. --general --body / --deselect write review_body and review_body_selected.
#   5. --event sets review_event alone.
#   6. --finding N and --all-findings change lens-findings.json selection.
#   7. A position past the end, --body on a finding, and a bad event are refused.
#   8. --json prints the review as it now stands.
#   9. view --json carries lens_findings and author.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts"
TEST_DIR=$(mktemp -d)
KNOWLEDGE_DIR="$TEST_DIR/knowledge"
EDIT="$SCRIPT_DIR/edit-proposed-review.sh"

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

assert_refused() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: $label — expected a refusal"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

mkdir -p "$KNOWLEDGE_DIR/_followups/review-x"
echo '{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}' > "$KNOWLEDGE_DIR/_manifest.json"
export LORE_KNOWLEDGE_DIR="$KNOWLEDGE_DIR"

ITEM="$KNOWLEDGE_DIR/_followups/review-x"
cat > "$ITEM/_meta.json" <<'EOF'
{"id": "review-x", "title": "Review: x (#7)", "source": "pr-review", "author": "@me", "status": "open",
 "attachments": [{"type": "pr", "ref": "#7"}], "created": "2026-01-01T00:00:00Z", "updated": "2026-01-01T00:00:00Z"}
EOF
echo '# Review: x' > "$ITEM/finding.md"
cat > "$ITEM/proposed-comments.json" <<'EOF'
{"pr": 7, "owner": "o", "repo": "r", "head_sha": "abc",
 "comments": [
   {"path": "a.py", "line": 1, "body": "first", "title": "One", "finding_ordinal": 1, "custom": "kept"},
   {"path": "b.py", "line": 2, "body": "second", "selected": true}
 ],
 "review_body": "general", "review_body_selected": true, "review_event": "COMMENT", "extra": {"x": 1}}
EOF
cat > "$ITEM/lens-findings.json" <<'EOF'
{"pr": 7, "work_item": "", "findings": [
  {"severity": "blocking", "title": "F1", "file": "a.py", "line": 1, "body": "b1", "lens": "correctness", "grounding": "g", "selected": false, "id": "keep-me"},
  {"severity": "suggestion", "title": "F2", "file": "b.py", "line": 0, "body": "b2", "lens": "regressions", "grounding": "g", "selected": false}
]}
EOF

field() {
  python3 -c "import json; d=json.load(open('$ITEM/$1')); print($2)"
}

echo "=== edit-proposed-review.sh ==="

bash "$EDIT" review-x --comment 0 --select >/dev/null
assert_eq "comment 0 selected" "$(field proposed-comments.json "d['comments'][0]['selected']")" "True"
bash "$EDIT" review-x --comment 1 --deselect >/dev/null
assert_eq "comment 1 deselected" "$(field proposed-comments.json "d['comments'][1]['selected']")" "False"

bash "$EDIT" review-x --comment 0 --body $'line one\n\nline two' >/dev/null
assert_eq "comment 0 body replaced" "$(field proposed-comments.json "repr(d['comments'][0]['body'])")" "'line one\\n\\nline two'"
assert_eq "unknown comment field kept" "$(field proposed-comments.json "d['comments'][0]['custom']")" "kept"
assert_eq "unknown top-level field kept" "$(field proposed-comments.json "d['extra']['x']")" "1"

bash "$EDIT" review-x --all-comments --select >/dev/null
assert_eq "all comments selected" "$(field proposed-comments.json "[c['selected'] for c in d['comments']]")" "[True, True]"

printf 'from a file' > "$TEST_DIR/body.md"
bash "$EDIT" review-x --general --body-file "$TEST_DIR/body.md" --deselect >/dev/null
assert_eq "general body from file" "$(field proposed-comments.json "d['review_body']")" "from a file"
assert_eq "general deselected" "$(field proposed-comments.json "d['review_body_selected']")" "False"

bash "$EDIT" review-x --event REQUEST_CHANGES >/dev/null
assert_eq "event set" "$(field proposed-comments.json "d['review_event']")" "REQUEST_CHANGES"

bash "$EDIT" review-x --finding 1 --select >/dev/null
assert_eq "finding 1 selected" "$(field lens-findings.json "[f['selected'] for f in d['findings']]")" "[False, True]"
bash "$EDIT" review-x --all-findings --select >/dev/null
assert_eq "all findings selected" "$(field lens-findings.json "[f['selected'] for f in d['findings']]")" "[True, True]"
assert_eq "finding provenance kept" "$(field lens-findings.json "d['findings'][0]['id']")" "keep-me"

assert_refused "position past the end" bash "$EDIT" review-x --comment 9 --select
assert_refused "--body on a finding" bash "$EDIT" review-x --finding 0 --body nope
assert_refused "bad event" bash "$EDIT" review-x --event MERGE
assert_refused "target with no change" bash "$EDIT" review-x --comment 0
assert_refused "two targets" bash "$EDIT" review-x --comment 0 --general --select
assert_refused "unknown follow-up" bash "$EDIT" review-nope --comment 0 --select

out="$(bash "$EDIT" review-x --comment 1 --deselect --json)"
assert_eq "--json prints the review" "$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['id'], d['proposed_comments']['comments'][1]['selected'], len(d['lens_findings']['findings']))")" "review-x False 2"

legacy="$KNOWLEDGE_DIR/_followups/review-legacy"
mkdir -p "$legacy"
cp "$ITEM/_meta.json" "$legacy/_meta.json"
echo '[{"path": "a.py", "line": 1, "body": "x"}]' > "$legacy/proposed-comments.json"
bash "$EDIT" review-legacy --comment 0 --select >/dev/null
assert_eq "legacy list: comment selected" "$(python3 -c "import json; print(json.load(open('$legacy/proposed-comments.json'))[0]['selected'])")" "True"
assert_refused "legacy list: no event" bash "$EDIT" review-legacy --event APPROVE

echo "=== load-followup.sh --json ==="
view="$(bash "$SCRIPT_DIR/load-followup.sh" review-x --json)"
assert_eq "view carries lens_findings and author" "$(printf '%s' "$view" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['lens_findings']['findings']), d['author'])")" "2 @me"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
