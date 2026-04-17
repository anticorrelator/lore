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
Group the given code review comments into thematic markdown sections.

Format:
- H3 (###) per theme, naming the concern (e.g., "Error Handling", "Test Coverage", "Interface Clarity").
- Under each heading, bullets only — no prose intro, no closing remarks.
- Each bullet: `[severity] path:line — <impact statement> (≤20 words)`. Drop `[severity]` when absent.

Bullet content — impact framing (this is the hard rule):
- Lead with the *observable consequence*, not the code description. A reader should be able to judge severity from the bullet alone.
- Name what breaks, who is affected, or what invariant is violated — e.g., "users see stale data after refresh", "panics on empty input", "silent data loss when N > 1000", "future callers will misuse X because Y is not enforced".
- Ground the impact in the comment body. Do not speculate beyond what the comment states. If the comment only flags a style issue with no stated impact, say so briefly ("minor: naming inconsistency, no runtime effect") rather than inventing one.
- Avoid vague verbs ("improve", "clean up", "refactor", "consider"). Avoid restating what the code does. Avoid starting with "the code" / "this function".

Rules:
- Output only the markdown. No preamble, no summary at the end.
- Prefer fewer, broader themes; merge singletons into a related theme.
- Use `lenses` to inform grouping but name themes by concern, not by lens.

Example:
### Error Handling
- [critical] src/auth/session.go:88 — privilege-escalation path keeps old session token, letting a demoted user act as admin
- [warning] src/middleware/auth.go:34 — expired OAuth tokens are accepted, extending sessions past their grant window

### Test Coverage
- [warning] tests/auth_test.go:12 — expired-token rejection untested, regressions in that branch will ship unnoticed
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
