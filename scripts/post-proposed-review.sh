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
      die "Unknown option: $1. Usage: post-proposed-review.sh <followup-id> [--dry-run] [--force (post lost-anchor comments at original line)]"
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
  die "Usage: post-proposed-review.sh <followup-id> [--dry-run] [--force (post lost-anchor comments at original line)]"
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

# --- Pre-flight: verify HEAD_SHA reachability ---
if git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
  HEAD_SHA_REACHABLE=1
elif gh api "repos/${OWNER}/${REPO}/commits/${HEAD_SHA}" --jq '.sha' >/dev/null 2>&1; then
  HEAD_SHA_REACHABLE=1
else
  die "original review SHA $HEAD_SHA is no longer reachable; re-review against the current head"
fi

if [[ "$HEAD_SHA" == "$CURRENT_HEAD" ]]; then
  NEEDS_REMAP=0
else
  # Ensure CURRENT_HEAD is available for local git diff
  if ! git cat-file -e "${CURRENT_HEAD}^{commit}" 2>/dev/null; then
    echo "[post-proposed-review] Fetching current PR head locally..."
    if ! git fetch origin "$CURRENT_HEAD" 2>/dev/null; then
      die "cannot diff current PR head locally; fetch the PR head and retry"
    fi
    if ! git cat-file -e "${CURRENT_HEAD}^{commit}" 2>/dev/null; then
      die "cannot diff current PR head locally; fetch the PR head and retry"
    fi
  fi
  NEEDS_REMAP=1
  echo "[post-proposed-review] PR head has changed since review."
  echo "  Sidecar head_sha:  $HEAD_SHA"
  echo "  Current PR head:   $CURRENT_HEAD"
fi

# --- Read review event from sidecar ---
review_event=$(jq -r '.review_event // "COMMENT"' "$SIDECAR")
case "$review_event" in
  COMMENT|APPROVE|REQUEST_CHANGES) ;;
  "") review_event="COMMENT" ;;
  *) die "Invalid review_event: $review_event" ;;
esac

# --- Build review payload ---
REVIEW_BODY_CUSTOM=$(jq -r '.review_body // empty' "$SIDECAR")
REVIEW_BODY_SELECTED=$(jq -r '.review_body_selected // false' "$SIDECAR")

if [[ "$REVIEW_BODY_SELECTED" == "true" && -n "$REVIEW_BODY_CUSTOM" ]]; then
  REVIEW_BODY="$REVIEW_BODY_CUSTOM"
  REVIEW_BODY_SOURCE="custom"
else
  REVIEW_BODY=""
  REVIEW_BODY_SOURCE="default"
fi

# --- Remap comments when PR head has changed ---
# OUTCOMES_JSON: array of per-comment post_outcome objects (keyed by sidecar index)
OUTCOMES_JSON='[]'
# INLINE_COMMENTS: array of GitHub API comment objects (path/line/body)
INLINE_COMMENTS='[]'

POSTED_COUNT=0
DROPPED_COUNT=0
SHIFTED_COUNT=0
RENAMED_COUNT=0

# Collect report lines for stdout (printed below)
REPORT_LINES=()

COMMENT_COUNT=$(echo "$SELECTED_JSON" | jq 'length')

for i in $(seq 0 $((COMMENT_COUNT - 1))); do
  comment=$(echo "$SELECTED_JSON" | jq ".[$i]")
  orig_path=$(echo "$comment" | jq -r '.path')
  orig_line=$(echo "$comment" | jq -r '.line')
  body=$(echo "$comment" | jq -r '.body')

  # Find index in the full sidecar (match by path+line+body for uniqueness)
  sidecar_idx=$(jq --arg path "$orig_path" --arg line "$orig_line" --arg body "$body" \
    '[.comments | to_entries[] | select(.value.path == $path and (.value.line | tostring) == $line and .value.body == $body) | .key] | first // -1' \
    "$SIDECAR")

  if [[ "$NEEDS_REMAP" -eq 0 ]]; then
    # Fast path: SHAs match, no remap needed
    remap_result="anchored"
  else
    remap_result=$(remap_line_through_diff "$orig_path" "$orig_line" "$HEAD_SHA" "$CURRENT_HEAD") || {
      # diff could not be computed — treat as lost
      remap_result="lost"
    }
  fi

  # Parse remap_result
  final_path="$orig_path"
  final_line="$orig_line"
  remap_status="$remap_result"

  case "$remap_result" in
    anchored)
      final_status="post"
      report_icon="✓"
      report_anchor="${orig_path}:${orig_line} (unchanged)"
      ;;
    shifted:*)
      new_line="${remap_result#shifted:}"
      final_line="$new_line"
      final_status="post"
      remap_status="shifted"
      SHIFTED_COUNT=$((SHIFTED_COUNT + 1))
      delta=$((new_line - orig_line))
      if [[ "$delta" -gt 0 ]]; then
        report_anchor="${orig_path}:${orig_line} → ${new_line} (shifted +${delta})"
      else
        report_anchor="${orig_path}:${orig_line} → ${new_line} (shifted ${delta})"
      fi
      report_icon="✓"
      ;;
    renamed:*)
      remainder="${remap_result#renamed:}"
      new_path="${remainder%:*}"
      new_line="${remainder##*:}"
      final_path="$new_path"
      final_line="$new_line"
      final_status="post"
      remap_status="renamed"
      RENAMED_COUNT=$((RENAMED_COUNT + 1))
      report_anchor="${orig_path} (renamed → ${new_path}):${orig_line} → ${new_line}"
      report_icon="✓"
      ;;
    lost)
      final_status="lost"
      report_icon="✗"
      report_anchor="${orig_path}:${orig_line} — original hunk deleted in commit ${HEAD_SHA:0:7}"
      ;;
    *)
      final_status="lost"
      report_icon="✗"
      report_anchor="${orig_path}:${orig_line} — unknown remap result: ${remap_result}"
      ;;
  esac

  # Determine actual post disposition (may upgrade lost→posted under --force)
  outcome_message=""
  if [[ "$final_status" == "post" ]]; then
    INLINE_COMMENTS=$(echo "$INLINE_COMMENTS" | jq \
      --arg path "$final_path" \
      --argjson line "$final_line" \
      --arg body "$body" \
      '. + [{path: $path, line: $line, body: $body}]')
    POSTED_COUNT=$((POSTED_COUNT + 1))
    REPORT_LINES+=("  ${report_icon} ${report_anchor}")
  elif [[ "$FORCE" -eq 1 ]]; then
    # --force: post lost-anchor comments at original line
    final_path="$orig_path"
    final_line="$orig_line"
    final_status="posted"
    outcome_message="force-posted at original line"
    INLINE_COMMENTS=$(echo "$INLINE_COMMENTS" | jq \
      --arg path "$orig_path" \
      --argjson line "$orig_line" \
      --arg body "$body" \
      '. + [{path: $path, line: $line, body: $body}]')
    POSTED_COUNT=$((POSTED_COUNT + 1))
    REPORT_LINES+=("  ${report_icon} ${report_anchor} [force-posted at original line]")
  else
    final_status="dropped"
    DROPPED_COUNT=$((DROPPED_COUNT + 1))
    REPORT_LINES+=("  ${report_icon} ${report_anchor}")
  fi

  # Build post_outcome object after final disposition is resolved
  outcome_obj=$(jq -n \
    --arg remap_status "$remap_status" \
    --arg final_status "$final_status" \
    --argjson original_line "$orig_line" \
    --argjson posted_line "$final_line" \
    --arg posted_path "$final_path" \
    --arg message "$outcome_message" \
    '{remap_status: $remap_status, final_status: $final_status, original_line: $original_line, posted_line: $posted_line, posted_path: $posted_path, message: $message}')

  OUTCOMES_JSON=$(echo "$OUTCOMES_JSON" | jq \
    --argjson idx "$sidecar_idx" \
    --argjson outcome "$outcome_obj" \
    '. + [{"idx": $idx, "outcome": $outcome}]')
done

# Print per-comment disposition report
echo ""
if [[ "$DROPPED_COUNT" -gt 0 ]]; then
  echo "[post-proposed-review] Posting ${POSTED_COUNT} of ${SELECTED_COUNT} selected comments (${DROPPED_COUNT} dropped — see report)"
else
  echo "[post-proposed-review] Posting ${POSTED_COUNT} of ${SELECTED_COUNT} selected comments"
fi
for line in "${REPORT_LINES[@]}"; do
  echo "$line"
done
echo ""

PAYLOAD=$(jq -n \
  --arg commit_id "$CURRENT_HEAD" \
  --arg body "$REVIEW_BODY" \
  --arg event "$review_event" \
  --argjson comments "$INLINE_COMMENTS" \
  '{commit_id: $commit_id, body: $body, event: $event, comments: $comments}')

# --- Dry run output ---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[post-proposed-review] DRY RUN — would post the following review:"
  echo ""
  echo "Commit: ${CURRENT_HEAD}"
  echo "Event: ${review_event}"
  echo ""
  echo "Body [${REVIEW_BODY_SOURCE}]: ${REVIEW_BODY}"
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

# --- Write outcomes back to sidecar (atomic via temp-file + mv) ---
POSTED_AT=$(timestamp_iso)

# Build last_post summary
LAST_POST=$(jq -n \
  --arg at "$POSTED_AT" \
  --arg current_head "$CURRENT_HEAD" \
  --argjson posted "$POSTED_COUNT" \
  --argjson dropped "$DROPPED_COUNT" \
  --argjson shifted "$SHIFTED_COUNT" \
  --argjson renamed "$RENAMED_COUNT" \
  '{at: $at, current_head: $current_head, posted: $posted, dropped: $dropped, shifted: $shifted, renamed: $renamed}')

# Merge post_outcome into each comment by sidecar index, and add last_post top-level
SIDECAR_TMP="${SIDECAR}.tmp.$$"
if ! jq \
  --argjson outcomes "$OUTCOMES_JSON" \
  --argjson last_post "$LAST_POST" \
  '
  . + {last_post: $last_post} |
  .comments = [
    .comments | to_entries[] |
    . as $entry |
    ($outcomes[] | select(.idx == $entry.key) | .outcome) as $outcome |
    if $outcome then
      $entry.value + {post_outcome: ($outcome + {posted_at: $last_post.at})}
    else
      $entry.value
    end
  ]
  ' "$SIDECAR" > "$SIDECAR_TMP" 2>/dev/null; then
  rm -f "$SIDECAR_TMP"
  echo "[post-proposed-review] ERROR: review posted, but failed to persist outcomes locally" >&2
  exit 1
fi

if ! mv "$SIDECAR_TMP" "$SIDECAR" 2>/dev/null; then
  rm -f "$SIDECAR_TMP"
  echo "[post-proposed-review] ERROR: review posted, but failed to persist outcomes locally (mv failed)" >&2
  exit 1
fi

echo "[post-proposed-review] Outcomes persisted to sidecar"
