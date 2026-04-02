#!/usr/bin/env bash
# post-proposed-review.sh — Post selected proposed comments from a followup sidecar to a GitHub PR
# Usage: post-proposed-review.sh <followup-id> [--dry-run] [--force]
#
# Reads proposed-comments.json from the followup directory, filters to selected
# comments, checks staleness against the current PR head, and posts as a batched
# review via gh api.
#
# Requires: gh CLI (authenticated), jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FOLLOWUP_ID=""
DRY_RUN=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -*)
      die "Unknown option: $1. Usage: post-proposed-review.sh <followup-id> [--dry-run] [--force]"
      ;;
    *)
      if [[ -z "$FOLLOWUP_ID" ]]; then
        FOLLOWUP_ID="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

if [[ -z "$FOLLOWUP_ID" ]]; then
  die "Usage: post-proposed-review.sh <followup-id> [--dry-run]"
fi

# --- Check dependencies ---
if ! command -v jq &>/dev/null; then
  die "jq not found. Install it: brew install jq (macOS) or apt-get install jq (Linux)"
fi

if ! command -v gh &>/dev/null; then
  die "gh CLI not found. Install it: https://cli.github.com/"
fi

# --- Resolve followup directory ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir) || die "Could not resolve knowledge directory"
FOLLOWUP_DIR="$KNOWLEDGE_DIR/_followups/$FOLLOWUP_ID"

if [[ ! -d "$FOLLOWUP_DIR" ]]; then
  die "Follow-up not found: $FOLLOWUP_ID"
fi

SIDECAR="$FOLLOWUP_DIR/proposed-comments.json"

if [[ ! -f "$SIDECAR" ]]; then
  die "No proposed-comments.json sidecar found in: $FOLLOWUP_DIR"
fi

# --- Validate sidecar JSON ---
if ! jq empty "$SIDECAR" 2>/dev/null; then
  die "Invalid JSON in sidecar: $SIDECAR"
fi

# --- Extract PR metadata ---
OWNER=$(jq -r '.owner // empty' "$SIDECAR")
REPO=$(jq -r '.repo // empty' "$SIDECAR")
PR_NUMBER=$(jq -r '.pr // empty' "$SIDECAR")
HEAD_SHA=$(jq -r '.head_sha // empty' "$SIDECAR")

if [[ -z "$OWNER" || -z "$REPO" || -z "$PR_NUMBER" ]]; then
  die "Sidecar missing required PR metadata (owner, repo, pr)"
fi

if [[ -z "$HEAD_SHA" ]]; then
  die "Sidecar missing head_sha — cannot verify comment staleness"
fi

# --- Filter to selected comments ---
TOTAL_COUNT=$(jq '.comments | length' "$SIDECAR")
SELECTED_JSON=$(jq '.comments | [.[] | select(.selected == true)]' "$SIDECAR")
SELECTED_COUNT=$(echo "$SELECTED_JSON" | jq 'length')

echo "[post-proposed-review] PR #${PR_NUMBER} (${OWNER}/${REPO})"
echo "[post-proposed-review] Comments: ${SELECTED_COUNT} selected / ${TOTAL_COUNT} total"

if [[ "$SELECTED_COUNT" -eq 0 ]]; then
  echo "[post-proposed-review] No comments selected — nothing to post."
  exit 0
fi

# --- Staleness check: compare sidecar head_sha to current PR head ---
CURRENT_HEAD=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null) || \
  die "Failed to fetch current PR head SHA via gh api"

if [[ "$HEAD_SHA" != "$CURRENT_HEAD" ]]; then
  echo "[post-proposed-review] WARNING: PR head has changed since review."
  echo "  Sidecar head_sha:  $HEAD_SHA"
  echo "  Current PR head:   $CURRENT_HEAD"
  echo "  Comments may reference outdated line numbers."
  if [[ "$FORCE" -eq 1 ]]; then
    echo "[post-proposed-review] --force passed, proceeding despite staleness."
  else
    printf "[post-proposed-review] Continue anyway? [y/N] "
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "[post-proposed-review] Aborted."
      exit 1
    fi
  fi
fi

# --- Build review payload ---
REVIEW_BODY="Review from lore (${SELECTED_COUNT} comments)"

# Transform selected comments into the GitHub API inline comments format
INLINE_COMMENTS=$(echo "$SELECTED_JSON" | jq '
  [.[] | {
    path: .path,
    line: .line,
    body: .body
  }]
')

PAYLOAD=$(jq -n \
  --arg commit_id "$HEAD_SHA" \
  --arg body "$REVIEW_BODY" \
  --arg event "COMMENT" \
  --argjson comments "$INLINE_COMMENTS" \
  '{commit_id: $commit_id, body: $body, event: $event, comments: $comments}')

# --- Dry run output ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "[post-proposed-review] DRY RUN — would post the following review:"
  echo ""
  echo "Commit: ${HEAD_SHA}"
  echo "Event: COMMENT"
  echo ""
  echo "Body: ${REVIEW_BODY}"
  echo ""
  echo "Inline comments:"
  echo "$INLINE_COMMENTS" | jq '.'
  exit 0
fi

# --- Post review via gh api ---
if ! gh auth status &>/dev/null; then
  die "gh CLI not authenticated. Run: gh auth login"
fi

RESPONSE=$(echo "$PAYLOAD" | gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --method POST \
  --input - 2>&1) || die "Failed to post review: ${RESPONSE}"

REVIEW_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
if [[ -n "$REVIEW_URL" ]]; then
  echo "[post-proposed-review] Posted: ${REVIEW_URL}"
else
  echo "[post-proposed-review] Review posted successfully"
fi
