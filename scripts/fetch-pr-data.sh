#!/usr/bin/env bash
# fetch-pr-data.sh — Fetch PR data (comments, reviews, review threads) via GitHub GraphQL API
# Usage: fetch-pr-data.sh <PR_NUMBER> [--repo OWNER/REPO]
#
# Outputs structured JSON with all PR comment types.
# Requires: gh CLI authenticated (gh auth status)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
PR_NUMBER=""
REPO_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      if [[ -z "$PR_NUMBER" ]]; then
        # Accept PR number or full URL
        PR_NUMBER="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  die "Usage: fetch-pr-data.sh <PR_NUMBER> [--repo OWNER/REPO]"
fi

# Extract PR number from URL if needed (e.g., https://github.com/owner/repo/pull/123)
if [[ "$PR_NUMBER" =~ /pull/([0-9]+) ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi

# Validate PR number is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die "PR number must be numeric, got: $PR_NUMBER"
fi

# --- Resolve owner/repo ---
if [[ -n "$REPO_OVERRIDE" ]]; then
  OWNER="${REPO_OVERRIDE%%/*}"
  REPO="${REPO_OVERRIDE##*/}"
else
  REMOTE_URL=$(git remote get-url origin 2>/dev/null) || die "Not in a git repo or no 'origin' remote"
  if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
  else
    die "Could not parse owner/repo from remote URL: $REMOTE_URL"
  fi
fi

# --- Verify gh CLI ---
if ! command -v gh &>/dev/null; then
  die "gh CLI not found. Install it: https://cli.github.com/"
fi

if ! gh auth status &>/dev/null; then
  die "gh CLI not authenticated. Run: gh auth login"
fi

# --- Fetch PR data via GraphQL ---
# Single query fetches all comment types: reviewThreads, reviews, general comments
gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      title
      body
      state
      author { login }
      baseRefName
      headRefName
      reviewThreads(first: 100) {
        nodes {
          isResolved
          isOutdated
          path
          line
          startLine
          diffSide
          comments(first: 50) {
            nodes {
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
      reviews(first: 50) {
        nodes {
          author { login }
          body
          state
          createdAt
          url
        }
      }
      comments(first: 100) {
        nodes {
          author { login }
          body
          createdAt
          url
        }
      }
    }
  }
}' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER"
