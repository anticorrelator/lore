#!/usr/bin/env bash
# generate-review-summary.sh — LLM-powered thematic summary of selected PR review comments
# Usage: generate-review-summary.sh <followup-id> [--dry-run]
#
# Reads proposed-comments.json from the followup sidecar, filters to selected comments,
# and calls `claude -p` to emit a thematic markdown summary on stdout.
# All diagnostics go to stderr — callers can pipe stdout directly.
#
# Requires: jq, claude CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
FOLLOWUP_ID=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo "[generate-review-summary] Unknown option: $1" >&2
      echo "Usage: generate-review-summary.sh <followup-id> [--dry-run]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$FOLLOWUP_ID" ]]; then
        FOLLOWUP_ID="$1"
      else
        echo "[generate-review-summary] Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$FOLLOWUP_ID" ]]; then
  echo "[generate-review-summary] Error: followup-id is required" >&2
  echo "Usage: generate-review-summary.sh <followup-id> [--dry-run]" >&2
  exit 1
fi

# --- Check dependencies ---
if ! command -v jq &>/dev/null; then
  echo "[generate-review-summary] Error: jq not found. Install it: brew install jq" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false ]] && ! command -v claude &>/dev/null; then
  echo "[generate-review-summary] Error: claude CLI not found" >&2
  exit 1
fi

# --- Resolve followup directory ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir) || {
  echo "[generate-review-summary] Error: Could not resolve knowledge directory" >&2
  exit 1
}

# resolve_followup_dir requires FOLLOWUPS_DIR to be set
FOLLOWUPS_DIR="$KNOWLEDGE_DIR/_followups"

FOLLOWUP_DIR=$(resolve_followup_dir "$FOLLOWUP_ID") || exit 1

SIDECAR="$FOLLOWUP_DIR/proposed-comments.json"

if [[ ! -f "$SIDECAR" ]]; then
  echo "[generate-review-summary] Error: No proposed-comments.json sidecar found in: $FOLLOWUP_DIR" >&2
  exit 1
fi

# --- Validate sidecar JSON ---
if ! jq empty "$SIDECAR" 2>/dev/null; then
  echo "[generate-review-summary] Error: Invalid JSON in sidecar: $SIDECAR" >&2
  exit 1
fi

# --- Extract comments — ProposedReview wrapper first, fall back to bare array ---
# Wrapper format: {pr, owner, repo, head_sha, comments: [...]}
# Bare format: [{path, line, body}, ...]
if jq -e 'type == "object" and has("comments")' "$SIDECAR" >/dev/null 2>&1; then
  ALL_COMMENTS=$(jq '.comments' "$SIDECAR")
else
  ALL_COMMENTS=$(jq '.' "$SIDECAR")
fi

# --- Filter to selected comments only (prompt-injection hygiene: unselected bodies never reach the model) ---
SELECTED_JSON=$(echo "$ALL_COMMENTS" | jq '[.[] | select(.selected == true)]')
SELECTED_COUNT=$(echo "$SELECTED_JSON" | jq 'length')

if [[ "$SELECTED_COUNT" -eq 0 ]]; then
  echo "[generate-review-summary] No comments selected — nothing to summarize." >&2
  exit 1
fi

# --- Build user prompt ---
# Only include path, line, severity, lenses, body — never selected, id, head_sha, or
# post_outcome, which would leak curation context into the model.
USER_PROMPT=$(echo "$SELECTED_JSON" | jq '[.[] | {path, line, severity, lenses, body}]')

# --- Build system prompt ---
SYS_FILE=$(mktemp /tmp/review-summary-sys-XXXXXX.txt)
trap 'rm -f "$SYS_FILE"' EXIT

cat > "$SYS_FILE" <<'SYSTEM_EOF'
You are summarizing a set of code review comments into a thematic markdown summary.

Your output is a structured markdown document that groups findings by theme. Each theme
should have an H3 heading (###) that captures the concern category (e.g., "Auth Boundary",
"Test Quality", "Error Handling", "Regressions", "Performance", "Interface Clarity").

For each theme:
- Write 1-2 sentences summarizing the pattern across the comments in that theme
- List each comment as a bullet with a `path:line` backlink (e.g., `src/auth.go:42`)
- Include the severity if present (e.g., [critical], [warning], [info])

Rules:
- Output ONLY the markdown — no preamble, no explanation, no trailing remarks
- Group related findings together even if they span different files
- Use the `lenses` field to inform theme assignment, but name themes by concern not lens
- Omit themes that would have only one bullet if it naturally fits another theme
- If a comment body is very short, expand it into a full sentence in context

Output format example:
### Auth Boundary

Session token handling is inconsistent across the auth layer.

- [critical] `src/auth/session.go:88` — token validated but not rotated on privilege escalation
- [warning] `src/middleware/auth.go:34` — missing expiry check on OAuth tokens

### Test Quality

Unit tests lack coverage of error paths.

- [warning] `tests/auth_test.go:12` — no test for expired token rejection
SYSTEM_EOF

# --- Dry-run: print assembled prompts, never call claude ---
if [[ "$DRY_RUN" == true ]]; then
  echo "=== SYSTEM PROMPT ==="
  cat "$SYS_FILE"
  echo ""
  echo "=== USER PROMPT ==="
  echo "$USER_PROMPT"
  exit 0
fi

# --- Invoke claude -p ---
if ! claude -p "$USER_PROMPT" \
  --append-system-prompt "$(cat "$SYS_FILE")" \
  --model sonnet \
  --permission-mode bypassPermissions \
  --max-budget-usd 0.5 \
  --output-format text \
  --disallowed-tools "Bash,Edit,Write,Read,Grep,Glob,Agent,Task"; then
  echo "[generate-review-summary] Error: claude invocation failed" >&2
  exit 1
fi
