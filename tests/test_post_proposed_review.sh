#!/usr/bin/env bash
# test_post_proposed_review.sh — Tests for remap_line_through_diff in scripts/lib.sh
# Creates a temporary git repo per test case and asserts helper stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Source lib.sh to get remap_line_through_diff
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

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

# Create a tiny git repo with two commits and return old_sha and new_sha via globals
# Usage: setup_repo <repo_dir>
# Then set OLD_SHA and NEW_SHA as locals before calling
make_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "test@test.com"
  git -C "$repo_dir" config user.name "Test"
}

commit_file() {
  local repo_dir="$1" filename="$2" content="$3" msg="$4"
  printf '%s' "$content" > "$repo_dir/$filename"
  git -C "$repo_dir" add "$filename"
  git -C "$repo_dir" commit -q -m "$msg"
  git -C "$repo_dir" rev-parse HEAD
}

echo "=== remap_line_through_diff Tests ==="
echo ""

# =============================================
# Case (a): unmodified line returns "anchored"
# A file is unchanged between two commits.
# =============================================
echo "Case (a): unmodified line → anchored"
REPO="$TEST_DIR/repo_a"
make_repo "$REPO"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$(printf 'line1\nline2\nline3\n')" "initial")
NEW_SHA=$(commit_file "$REPO" "other.txt" "$(printf 'hello\n')" "add other file")

OUTPUT=$(remap_line_through_diff "file.txt" 2 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "unmodified file line 2 is anchored" "$OUTPUT" "anchored"

echo ""

# =============================================
# Case (b): line below a pure-add hunk returns "shifted:<line+added>"
# Add 3 lines before the target line.
# =============================================
echo "Case (b): line below pure-add hunk → shifted:<new_line>"
REPO="$TEST_DIR/repo_b"
make_repo "$REPO"
# Old file: 5 lines, target line is line 4 ("target_line")
OLD_CONTENT="$(printf 'a\nb\nc\ntarget_line\ne\n')"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$OLD_CONTENT" "initial")
# New file: 3 lines added before target, target is now at line 7
NEW_CONTENT="$(printf 'a\nb\nc\nadd1\nadd2\nadd3\ntarget_line\ne\n')"
NEW_SHA=$(commit_file "$REPO" "file.txt" "$NEW_CONTENT" "add lines before target")

OUTPUT=$(remap_line_through_diff "file.txt" 4 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "line shifted down by 3 additions" "$OUTPUT" "shifted:7"

echo ""

# =============================================
# Case (c): line above any hunk returns "anchored"
# Modify lines below the target line only.
# =============================================
echo "Case (c): line above all hunks → anchored"
REPO="$TEST_DIR/repo_c"
make_repo "$REPO"
OLD_CONTENT="$(printf 'alpha\nbeta\ngamma\ndelta\neps\n')"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$OLD_CONTENT" "initial")
# Only change lines 4-5 (below line 2, our target)
NEW_CONTENT="$(printf 'alpha\nbeta\ngamma\nchanged_delta\nchanged_eps\n')"
NEW_SHA=$(commit_file "$REPO" "file.txt" "$NEW_CONTENT" "modify lines below target")

OUTPUT=$(remap_line_through_diff "file.txt" 2 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "line above hunks is anchored" "$OUTPUT" "anchored"

echo ""

# =============================================
# Case (d): line inside a deleted hunk returns "lost"
# Delete the target line.
# =============================================
echo "Case (d): line inside deleted hunk → lost"
REPO="$TEST_DIR/repo_d"
make_repo "$REPO"
OLD_CONTENT="$(printf 'first\nsecond\nthird\nfourth\nfifth\n')"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$OLD_CONTENT" "initial")
# Delete line 3 ("third")
NEW_CONTENT="$(printf 'first\nsecond\nfourth\nfifth\n')"
NEW_SHA=$(commit_file "$REPO" "file.txt" "$NEW_CONTENT" "delete line 3")

OUTPUT=$(remap_line_through_diff "file.txt" 3 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "deleted line is lost" "$OUTPUT" "lost"

echo ""

# =============================================
# Case (e): line inside modified hunk, content identical → shifted:<new>
# Replace a different line in same hunk, target content unchanged.
# =============================================
echo "Case (e): modified hunk, target content identical → shifted:<new_line>"
REPO="$TEST_DIR/repo_e"
make_repo "$REPO"
# 6 lines; target is line 3 ("keep_me"), line 4 will change
OLD_CONTENT="$(printf 'a\nb\nkeep_me\nold_line\ne\nf\n')"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$OLD_CONTENT" "initial")
# Change line 4, keep line 3 intact — they're in the same hunk
NEW_CONTENT="$(printf 'a\nb\nkeep_me\nnew_line\ne\nf\n')"
NEW_SHA=$(commit_file "$REPO" "file.txt" "$NEW_CONTENT" "change line 4 only")

OUTPUT=$(remap_line_through_diff "file.txt" 3 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "context line in modified hunk is anchored or shifted" "$OUTPUT" "anchored"

echo ""

# =============================================
# Case (f): line inside modified hunk, content changed → lost
# The target line itself is rewritten.
# =============================================
echo "Case (f): modified hunk, target content changed → lost"
REPO="$TEST_DIR/repo_f"
make_repo "$REPO"
OLD_CONTENT="$(printf 'a\nb\noriginal_content\nd\ne\n')"
OLD_SHA=$(commit_file "$REPO" "file.txt" "$OLD_CONTENT" "initial")
# Rewrite line 3 entirely
NEW_CONTENT="$(printf 'a\nb\ncompletely_different\nd\ne\n')"
NEW_SHA=$(commit_file "$REPO" "file.txt" "$NEW_CONTENT" "rewrite line 3")

OUTPUT=$(remap_line_through_diff "file.txt" 3 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "rewritten line is lost" "$OUTPUT" "lost"

echo ""

# =============================================
# Case (g): file renamed, line outside hunks → renamed:<new_path>:<same_line>
# Rename file with no content changes to the target area.
# =============================================
echo "Case (g): file renamed, line outside hunks → renamed:<new_path>:<line>"
REPO="$TEST_DIR/repo_g"
make_repo "$REPO"
OLD_CONTENT="$(printf 'line1\nline2\nline3\nline4\nline5\n')"
OLD_SHA=$(commit_file "$REPO" "old_name.txt" "$OLD_CONTENT" "initial")
# Rename by moving the file (git mv)
cp "$REPO/old_name.txt" "$REPO/new_name.txt"
git -C "$REPO" add new_name.txt
git -C "$REPO" rm -q old_name.txt
git -C "$REPO" commit -q -m "rename file"
NEW_SHA=$(git -C "$REPO" rev-parse HEAD)

OUTPUT=$(remap_line_through_diff "old_name.txt" 2 "$OLD_SHA" "$NEW_SHA" "$REPO")
assert_contains "renamed file result starts with 'renamed:'" "$OUTPUT" "renamed:"
assert_contains "renamed file result contains new path" "$OUTPUT" "new_name.txt"
assert_contains "renamed file result contains line number" "$OUTPUT" ":2"

echo ""

# =============================================
# Phase 2: post-proposed-review.sh sidecar write
# These tests exercise the full script with a mock gh and a synthetic sidecar.
# =============================================
POST_SCRIPT="$SCRIPT_DIR/post-proposed-review.sh"

# Setup: create a mock gh binary in TEST_DIR/bin that returns controlled responses.
# The mock reads GH_MOCK_PR_HEAD, GH_MOCK_POST_RESPONSE, GH_MOCK_COMMITS_STATUS.
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
# Mock gh — controlled by env vars
case "$*" in
  *"auth status"*)
    exit 0
    ;;
  *"commits/"*)
    # Simulate reachability check for HEAD_SHA
    if [[ "${GH_MOCK_COMMITS_STATUS:-0}" == "404" ]]; then
      exit 1
    fi
    echo "${GH_MOCK_HEAD_SHA:-abc123}"
    exit 0
    ;;
  *"/pulls/"*" --jq .head.sha"*)
    echo "${GH_MOCK_PR_HEAD:-newhead123}"
    exit 0
    ;;
  *"POST"*|*"--method POST"*)
    echo "${GH_MOCK_POST_RESPONSE:-{\"html_url\":\"https://github.com/test/repo/pull/1#pullrequestreview-99\"}}"
    exit 0
    ;;
  *)
    echo "mock gh: unhandled: $*" >&2
    exit 1
    ;;
esac
GHEOF
chmod +x "$MOCK_BIN/gh"

# Also stub lore resolve via LORE_KNOWLEDGE_DIR
PHASE2_KNOWLEDGE="$TEST_DIR/knowledge_p2"
mkdir -p "$PHASE2_KNOWLEDGE/_followups"

make_sidecar() {
  local followup_id="$1" head_sha="$2"
  local fdir="$PHASE2_KNOWLEDGE/_followups/$followup_id"
  mkdir -p "$fdir"
  cat > "$fdir/proposed-comments.json" <<EOF
{
  "owner": "testowner",
  "repo": "testrepo",
  "pr": 1,
  "head_sha": "${head_sha}",
  "comments": [
    {"path": "src/a.go", "line": 5, "body": "comment on shifted line", "selected": true},
    {"path": "src/b.go", "line": 10, "body": "comment on deleted line", "selected": true}
  ]
}
EOF
  echo "$fdir/proposed-comments.json"
}

run_script() {
  local followup_id="$1"
  shift
  PATH="$MOCK_BIN:$PATH" LORE_KNOWLEDGE_DIR="$PHASE2_KNOWLEDGE" \
    bash "$POST_SCRIPT" "$followup_id" "$@" 2>&1
}

# Build a git repo where src/a.go line 5 shifts to line 8, and src/b.go line 10 is deleted
PHASE2_REPO="$TEST_DIR/repo_p2"
make_repo "$PHASE2_REPO"
mkdir -p "$PHASE2_REPO/src"
# src/a.go: 10 lines; will add 3 lines before line 5
printf 'a1\na2\na3\na4\na5\na6\na7\na8\na9\na10\n' > "$PHASE2_REPO/src/a.go"
# src/b.go: 12 lines; will delete line 10
printf 'b1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\nb9\nb10\nb11\nb12\n' > "$PHASE2_REPO/src/b.go"
git -C "$PHASE2_REPO" add .
git -C "$PHASE2_REPO" commit -q -m "initial"
P2_OLD_SHA=$(git -C "$PHASE2_REPO" rev-parse HEAD)

# New commit: add 3 lines before a5 (shifts a5 → a8), delete b10
printf 'a1\na2\na3\na4\nnew1\nnew2\nnew3\na5\na6\na7\na8\na9\na10\n' > "$PHASE2_REPO/src/a.go"
printf 'b1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\nb9\nb11\nb12\n' > "$PHASE2_REPO/src/b.go"
git -C "$PHASE2_REPO" add .
git -C "$PHASE2_REPO" commit -q -m "shift a5, delete b10"
P2_NEW_SHA=$(git -C "$PHASE2_REPO" rev-parse HEAD)

# =============================================
# Phase 2 Case (a): fast path — head_sha == current_head
# sidecar gets last_post with posted=2 dropped=0
# =============================================
echo "Phase 2 Case (a): fast path (SHA match) → last_post written, posted=2 dropped=0"
SIDECAR_A=$(make_sidecar "p2a" "$P2_OLD_SHA")
# Mock gh returns same SHA as sidecar head_sha
export GH_MOCK_PR_HEAD="$P2_OLD_SHA"
export GH_MOCK_HEAD_SHA="$P2_OLD_SHA"
export GH_MOCK_COMMITS_STATUS="200"
OUTPUT_A=$(run_script "p2a")
assert_contains "fast path posts successfully" "$OUTPUT_A" "Outcomes persisted to sidecar"
LAST_POST_DROPPED=$(jq '.last_post.dropped' "$SIDECAR_A")
assert_contains "fast path: dropped == 0" "$LAST_POST_DROPPED" "0"
LAST_POST_POSTED=$(jq '.last_post.posted' "$SIDECAR_A")
assert_contains "fast path: posted == 2" "$LAST_POST_POSTED" "2"
# Original line fields preserved
ORIG_LINE_A=$(jq '.comments[0].line' "$SIDECAR_A")
assert_contains "fast path: original line preserved" "$ORIG_LINE_A" "5"

echo ""

# =============================================
# Phase 2 Case (b): unreachable HEAD_SHA → bails with non-zero, no POST
# =============================================
echo "Phase 2 Case (b): unreachable HEAD_SHA → bails non-zero, no sidecar write"
SIDECAR_B=$(make_sidecar "p2b" "deadbeef000000000000000000000000deadbeef")
export GH_MOCK_PR_HEAD="$P2_NEW_SHA"
export GH_MOCK_COMMITS_STATUS="404"
OUTPUT_B=$(run_script "p2b" 2>&1 || true)
assert_contains "unreachable SHA: error message" "$OUTPUT_B" "no longer reachable"
# Sidecar should NOT have last_post
HAS_LAST_POST=$(jq 'has("last_post")' "$SIDECAR_B")
assert_contains "unreachable SHA: no last_post written" "$HAS_LAST_POST" "false"

echo ""

# =============================================
# Phase 2 Case (c): shifted + lost, no --force
# → payload has only shifted comment, sidecar last_post.dropped==1
# =============================================
echo "Phase 2 Case (c): shifted + lost (no --force) → dropped==1 in sidecar"
SIDECAR_C=$(make_sidecar "p2c" "$P2_OLD_SHA")
export GH_MOCK_PR_HEAD="$P2_NEW_SHA"
export GH_MOCK_HEAD_SHA="$P2_OLD_SHA"
export GH_MOCK_COMMITS_STATUS="200"
# Need the test repo to be the git repo context for remap — use LORE_KNOWLEDGE_DIR in same parent
# The script calls remap_line_through_diff which needs the git repo. We need to run from P2_REPO.
OUTPUT_C=$(cd "$PHASE2_REPO" && PATH="$MOCK_BIN:$PATH" LORE_KNOWLEDGE_DIR="$PHASE2_KNOWLEDGE" \
  bash "$POST_SCRIPT" "p2c" 2>&1)
assert_contains "shifted+lost: report shows shifted" "$OUTPUT_C" "shifted"
DROPPED_C=$(jq '.last_post.dropped' "$SIDECAR_C")
assert_contains "shifted+lost: dropped==1" "$DROPPED_C" "1"
POSTED_C=$(jq '.last_post.posted' "$SIDECAR_C")
assert_contains "shifted+lost: posted==1" "$POSTED_C" "1"
# Dropped comment has remap_status==lost and final_status==dropped
DROPPED_FINAL=$(jq -r '.comments[1].post_outcome.final_status' "$SIDECAR_C")
assert_contains "shifted+lost: dropped final_status==dropped" "$DROPPED_FINAL" "dropped"
DROPPED_REMAP=$(jq -r '.comments[1].post_outcome.remap_status' "$SIDECAR_C")
assert_contains "shifted+lost: dropped remap_status==lost" "$DROPPED_REMAP" "lost"
# Original line field preserved
ORIG_LINE_C=$(jq '.comments[1].line' "$SIDECAR_C")
assert_contains "original line preserved after partial post" "$ORIG_LINE_C" "10"

echo ""

# =============================================
# Phase 2 Case (d): shifted + lost with --force
# → both posted; lost comment final_status==posted with message
# =============================================
echo "Phase 2 Case (d): shifted + lost with --force → both posted, final_status==posted"
SIDECAR_D=$(make_sidecar "p2d" "$P2_OLD_SHA")
export GH_MOCK_PR_HEAD="$P2_NEW_SHA"
OUTPUT_D=$(cd "$PHASE2_REPO" && PATH="$MOCK_BIN:$PATH" LORE_KNOWLEDGE_DIR="$PHASE2_KNOWLEDGE" \
  bash "$POST_SCRIPT" "p2d" --force 2>&1)
assert_contains "--force: posts both comments" "$OUTPUT_D" "force-posted"
DROPPED_D=$(jq '.last_post.dropped' "$SIDECAR_D")
assert_contains "--force: dropped==0" "$DROPPED_D" "0"
POSTED_D=$(jq '.last_post.posted' "$SIDECAR_D")
assert_contains "--force: posted==2" "$POSTED_D" "2"
FORCE_FINAL=$(jq -r '.comments[1].post_outcome.final_status' "$SIDECAR_D")
assert_contains "--force: lost comment final_status==posted" "$FORCE_FINAL" "posted"
FORCE_MSG=$(jq -r '.comments[1].post_outcome.message' "$SIDECAR_D")
assert_contains "--force: message notes force-post" "$FORCE_MSG" "force"

echo ""

# =============================================
# Phase 2 Case (e): --dry-run → prints report, no POST, no sidecar write
# =============================================
echo "Phase 2 Case (e): --dry-run → no sidecar write"
SIDECAR_E=$(make_sidecar "p2e" "$P2_OLD_SHA")
export GH_MOCK_PR_HEAD="$P2_NEW_SHA"
OUTPUT_E=$(cd "$PHASE2_REPO" && PATH="$MOCK_BIN:$PATH" LORE_KNOWLEDGE_DIR="$PHASE2_KNOWLEDGE" \
  bash "$POST_SCRIPT" "p2e" --dry-run 2>&1)
assert_contains "--dry-run: shows DRY RUN label" "$OUTPUT_E" "DRY RUN"
HAS_LAST_POST_E=$(jq 'has("last_post")' "$SIDECAR_E")
assert_contains "--dry-run: no last_post written to sidecar" "$HAS_LAST_POST_E" "false"

echo ""

# =============================================
# Phase 2 Case (f): archived followup → resolve_followup_dir finds it in _archive
# Verifies the script can retry on a followup that has already been archived.
# =============================================
echo "Phase 2 Case (f): archived followup → resolves in _archive and posts"
# Create sidecar in active dir first, then move to _archive
SIDECAR_F=$(make_sidecar "p2f" "$P2_OLD_SHA")
mkdir -p "$PHASE2_KNOWLEDGE/_followups/_archive"
mv "$PHASE2_KNOWLEDGE/_followups/p2f" "$PHASE2_KNOWLEDGE/_followups/_archive/p2f"
export GH_MOCK_PR_HEAD="$P2_OLD_SHA"
export GH_MOCK_HEAD_SHA="$P2_OLD_SHA"
export GH_MOCK_COMMITS_STATUS="200"
OUTPUT_F=$(run_script "p2f")
assert_contains "archived followup: posts successfully" "$OUTPUT_F" "Outcomes persisted to sidecar"
# Sidecar should now live at archive path and have last_post written
ARCHIVED_SIDECAR="$PHASE2_KNOWLEDGE/_followups/_archive/p2f/proposed-comments.json"
HAS_LAST_POST_F=$(jq 'has("last_post")' "$ARCHIVED_SIDECAR")
assert_contains "archived followup: last_post written in archive path" "$HAS_LAST_POST_F" "true"

echo ""

# =============================================
# Summary
# =============================================
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
