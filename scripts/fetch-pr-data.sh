#!/usr/bin/env bash
# fetch-pr-data.sh — Fetch PR data (comments, reviews, review threads) via GitHub GraphQL API
# Usage: fetch-pr-data.sh <PR_NUMBER> [--repo OWNER/REPO]
#
# Outputs structured JSON with comments grouped by review submission.
# Output fields: title, body, state, author, baseRefName, headRefName,
#   grouped_reviews (reviews with inline_comments attached),
#   unmatched_threads (review threads not matched to any review),
#   orphan_comments (general PR comments not part of a review).
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
RAW_JSON=$(gh api graphql -f query='
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
}' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER")

# --- Post-process: group comments by review submission ---
# Groups review thread comments under their parent review (matched by author + timing).
# Unmatched threads (no parent review) and orphan comments (general PR comments) are separate.
echo "$RAW_JSON" | jq '
.data.repository.pullRequest as $pr |

# Build list of reviews with empty inline_comments arrays
[$pr.reviews.nodes[] | {
  reviewer: .author.login,
  state: .state,
  submittedAt: .createdAt,
  body: .body,
  url: .url,
  inline_comments: []
}] |

# For each review thread, find the best matching review and attach it.
# Match criteria: same author as thread opener, review submitted at or after thread comment.
# Among matches, pick the review with the earliest submittedAt (closest in time).
reduce ($pr.reviewThreads.nodes[] | select(.comments.nodes | length > 0)) as $thread (
  .;

  . as $revs |
  $thread.comments.nodes[0].author.login as $thread_author |
  $thread.comments.nodes[0].createdAt as $thread_created |

  {
    path: $thread.path,
    line: $thread.line,
    startLine: $thread.startLine,
    diffSide: $thread.diffSide,
    isResolved: $thread.isResolved,
    isOutdated: $thread.isOutdated,
    comments: $thread.comments.nodes
  } as $thread_obj |

  # Find index of best matching review
  (reduce range($revs | length) as $i (
    null;
    if $revs[$i].reviewer == $thread_author
       and $revs[$i].submittedAt >= $thread_created
    then
      if . == null then $i
      elif $revs[$i].submittedAt < $revs[.].submittedAt then $i
      else .
      end
    else .
    end
  )) as $match_idx |

  if $match_idx != null then
    .[$match_idx].inline_comments += [$thread_obj]
  else .
  end
) |

. as $grouped |

# Collect thread first-comment keys that were matched to a review
[$grouped[] | .inline_comments[] | .comments[0] | (.author.login + "|" + .createdAt)] |
  unique as $matched_keys |

# Unmatched threads: review threads not assigned to any review
[
  $pr.reviewThreads.nodes[]
  | select(.comments.nodes | length > 0)
  | .comments.nodes[0] as $first
  | select(
      ($first.author.login + "|" + $first.createdAt) as $k |
      ($matched_keys | index($k)) == null
    )
  | {
      path: .path,
      line: .line,
      startLine: .startLine,
      diffSide: .diffSide,
      isResolved: .isResolved,
      isOutdated: .isOutdated,
      comments: .comments.nodes
    }
] as $unmatched_threads |

{
  title: $pr.title,
  body: $pr.body,
  state: $pr.state,
  author: $pr.author.login,
  baseRefName: $pr.baseRefName,
  headRefName: $pr.headRefName,
  grouped_reviews: $grouped,
  unmatched_threads: $unmatched_threads,
  orphan_comments: [$pr.comments.nodes[] | {
    author: .author.login,
    body: .body,
    createdAt: .createdAt,
    url: .url
  }]
}'
