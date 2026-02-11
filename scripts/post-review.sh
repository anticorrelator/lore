#!/usr/bin/env bash
# post-review.sh — Post review findings to a GitHub PR as a batched review submission
# Usage: post-review.sh <FINDINGS_JSON_FILE> [--pr PR_NUMBER] [--repo OWNER/REPO] [--dry-run]
#
# Accepts a findings JSON file, determines review state from severities,
# and posts via `gh api` as a single batched review submission.
#
# Findings JSON format (one or more lens outputs concatenated in a JSON array):
# [
#   {
#     "lens": "correctness",
#     "pr": 42,
#     "findings": [
#       {"severity": "blocking|suggestion|question", "title": "...", "file": "path", "line": 42, "body": "...", "knowledge_context": ["entry — relevance"]}
#     ]
#   }
# ]
#
# Also accepts a single lens object (not wrapped in array) — the script normalizes it.
#
# Review state logic:
#   - Any blocking finding → REQUEST_CHANGES
#   - Only suggestions/questions → COMMENT
#   - No findings → APPROVE
#
# Requires: gh CLI (authenticated), jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FINDINGS_FILE=""
PR_NUMBER=""
REPO_OVERRIDE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    --repo)
      REPO_OVERRIDE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -*)
      die "Unknown option: $1. Usage: post-review.sh <FINDINGS_JSON_FILE> [--pr PR_NUMBER] [--repo OWNER/REPO] [--dry-run]"
      ;;
    *)
      if [[ -z "$FINDINGS_FILE" ]]; then
        FINDINGS_FILE="$1"
        shift
      else
        die "Unexpected argument: $1"
      fi
      ;;
  esac
done

if [[ -z "$FINDINGS_FILE" ]]; then
  die "Usage: post-review.sh <FINDINGS_JSON_FILE> [--pr PR_NUMBER] [--repo OWNER/REPO] [--dry-run]"
fi

if [[ ! -f "$FINDINGS_FILE" ]]; then
  die "Findings file not found: $FINDINGS_FILE"
fi

# --- Check dependencies ---
if ! command -v jq &>/dev/null; then
  die "jq not found. Install it: brew install jq (macOS) or apt-get install jq (Linux)"
fi

if ! command -v gh &>/dev/null; then
  die "gh CLI not found. Install it: https://cli.github.com/"
fi

if ! gh auth status &>/dev/null; then
  die "gh CLI not authenticated. Run: gh auth login"
fi

# --- Validate and normalize JSON ---
if ! jq empty "$FINDINGS_FILE" 2>/dev/null; then
  die "Invalid JSON in findings file: $FINDINGS_FILE"
fi

# Normalize: if the root is a single object with "lens" key, wrap it in an array
FINDINGS_JSON=$(jq '
  if type == "array" then .
  elif type == "object" and has("lens") then [.]
  else error("Expected a findings object or array of findings objects")
  end
' "$FINDINGS_FILE") || die "Findings JSON does not match expected format. Expected object with 'lens' key or array of such objects."

# --- Extract PR number ---
# Use --pr flag if provided, otherwise extract from the findings JSON
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER=$(echo "$FINDINGS_JSON" | jq -r '.[0].pr // empty')
fi

if [[ -z "$PR_NUMBER" ]]; then
  die "No PR number found. Provide --pr flag or include 'pr' field in findings JSON."
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  die "PR number must be numeric, got: $PR_NUMBER"
fi

# --- Resolve owner/repo ---
if [[ -n "$REPO_OVERRIDE" ]]; then
  OWNER="${REPO_OVERRIDE%%/*}"
  REPO="${REPO_OVERRIDE##*/}"
else
  REMOTE_URL=$(git remote get-url origin 2>/dev/null) || die "Not in a git repo or no 'origin' remote. Use --repo OWNER/REPO."
  if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
  else
    die "Could not parse owner/repo from remote URL: $REMOTE_URL. Use --repo OWNER/REPO."
  fi
fi

# --- Collect all findings across lenses ---
ALL_FINDINGS=$(echo "$FINDINGS_JSON" | jq '[.[] | .lens as $lens | .findings[] | . + {lens: $lens}]')
FINDING_COUNT=$(echo "$ALL_FINDINGS" | jq 'length')

# --- Determine review state ---
BLOCKING_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "blocking")] | length')
SUGGESTION_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "suggestion")] | length')
QUESTION_COUNT=$(echo "$ALL_FINDINGS" | jq '[.[] | select(.severity == "question")] | length')

if [[ "$FINDING_COUNT" -eq 0 ]]; then
  EVENT="APPROVE"
elif [[ "$BLOCKING_COUNT" -gt 0 ]]; then
  EVENT="REQUEST_CHANGES"
else
  EVENT="COMMENT"
fi

# --- Build review body ---
LENS_LIST=$(echo "$FINDINGS_JSON" | jq -r '[.[].lens] | unique | join(", ")')

REVIEW_BODY="**Multi-lens review** (${LENS_LIST})"
REVIEW_BODY="${REVIEW_BODY}"$'\n\n'
if [[ "$FINDING_COUNT" -eq 0 ]]; then
  REVIEW_BODY="${REVIEW_BODY}No findings — code looks good."
else
  REVIEW_BODY="${REVIEW_BODY}**Findings:** ${FINDING_COUNT} total"
  [[ "$BLOCKING_COUNT" -gt 0 ]] && REVIEW_BODY="${REVIEW_BODY} (${BLOCKING_COUNT} blocking)"
  [[ "$SUGGESTION_COUNT" -gt 0 ]] && REVIEW_BODY="${REVIEW_BODY} (${SUGGESTION_COUNT} suggestion)"
  [[ "$QUESTION_COUNT" -gt 0 ]] && REVIEW_BODY="${REVIEW_BODY} (${QUESTION_COUNT} question)"
fi

# --- Build inline comments array ---
# Only include findings that have both file and line (inline-eligible)
INLINE_COMMENTS=$(echo "$ALL_FINDINGS" | jq '
  [.[] | select(.file != null and .file != "" and .line != null and .line > 0) |
    {
      path: .file,
      line: .line,
      body: (
        "**[\(.severity | ascii_upcase)]** \(.title)\n\n\(.body)" +
        if (.knowledge_context // [] | length) > 0 then
          "\n\n---\n**Knowledge context:**\n" + ([.knowledge_context[] | "- \(.)"] | join("\n"))
        else ""
        end +
        "\n\n*— \(.lens) lens*"
      )
    }
  ]
')
INLINE_COUNT=$(echo "$INLINE_COMMENTS" | jq 'length')

# Findings without file/line go into the review body as general comments
GENERAL_FINDINGS=$(echo "$ALL_FINDINGS" | jq '
  [.[] | select(.file == null or .file == "" or .line == null or .line <= 0)]
')
GENERAL_COUNT=$(echo "$GENERAL_FINDINGS" | jq 'length')

if [[ "$GENERAL_COUNT" -gt 0 ]]; then
  GENERAL_TEXT=$(echo "$GENERAL_FINDINGS" | jq -r '
    .[] |
    "### [\(.severity | ascii_upcase)] \(.title) (\(.lens) lens)\n\(.body)\n"
  ')
  REVIEW_BODY="${REVIEW_BODY}"$'\n\n---\n\n'"${GENERAL_TEXT}"
fi

# --- Output summary ---
echo "[post-review] PR #${PR_NUMBER} (${OWNER}/${REPO})"
echo "[post-review] Event: ${EVENT}"
echo "[post-review] Findings: ${FINDING_COUNT} total (${BLOCKING_COUNT} blocking, ${SUGGESTION_COUNT} suggestion, ${QUESTION_COUNT} question)"
echo "[post-review] Inline comments: ${INLINE_COUNT}, general comments: ${GENERAL_COUNT}"
echo "[post-review] Lenses: ${LENS_LIST}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "[post-review] DRY RUN — would post the following review:"
  echo ""
  echo "Event: ${EVENT}"
  echo ""
  echo "Body:"
  echo "$REVIEW_BODY"
  echo ""
  echo "Inline comments:"
  echo "$INLINE_COMMENTS" | jq '.'
  exit 0
fi

# --- Post review via gh api ---
# Build the request payload as JSON to handle escaping correctly
PAYLOAD=$(jq -n \
  --arg body "$REVIEW_BODY" \
  --arg event "$EVENT" \
  --argjson comments "$INLINE_COMMENTS" \
  '{body: $body, event: $event, comments: $comments}')

RESPONSE=$(echo "$PAYLOAD" | gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" \
  --method POST \
  --input - 2>&1) || die "Failed to post review: ${RESPONSE}"

REVIEW_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
if [[ -n "$REVIEW_URL" ]]; then
  echo "[post-review] Posted: ${REVIEW_URL}"
else
  echo "[post-review] Review posted successfully"
fi
