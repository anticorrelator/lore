#!/usr/bin/env bash
# work-ai.sh — Run Claude headlessly to create work items from a natural-language prompt.
# Usage: work-ai.sh "<prompt>" [--model <model>] [--max-budget <usd>] [--dry-run]
#
# Augments the prompt with guardrails that restrict Claude to only creating work items.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODEL="sonnet"
MAX_BUDGET="2.0"
DRY_RUN=false
PROMPT=""

usage() {
  cat >&2 <<'EOF'
Usage: lore work ai "<prompt>" [options]

Run Claude headlessly to create work items from a natural-language prompt.
Claude is restricted to read-only information gathering and work item creation only.

Options:
  --model <model>        Model to use (default: sonnet)
  --max-budget <usd>     Cost cap in USD (default: 2.0)
  --dry-run              Show what would run without executing
  -h, --help             Show this help

Examples:
  lore work ai "read all open issues assigned to me and make work items for them"
  lore work ai "create a work item for the auth refactor we discussed" --model opus
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -lt 2 ]] && { echo "Error: --model requires a value" >&2; exit 1; }
      MODEL="$2"; shift 2 ;;
    --max-budget)
      [[ $# -lt 2 ]] && { echo "Error: --max-budget requires a value" >&2; exit 1; }
      MAX_BUDGET="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --help|-h)
      usage; exit 0 ;;
    -*)
      echo "Error: unknown flag '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ -z "$PROMPT" ]]; then
        PROMPT="$1"
      else
        echo "Error: unexpected argument '$1'" >&2; usage; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo "Error: prompt is required" >&2
  usage
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "[work-ai] Error: claude CLI not found" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
CREATE_SCRIPT="$SCRIPT_DIR/create-work.sh"

# Pre-fetch existing work items for deduplication context.
EXISTING_WORK=$(bash "$SCRIPT_DIR/list-work.sh" 2>/dev/null || echo "  (none)")

# Write guardrails to a temp file to avoid bash quoting issues with heredoc inside $().
GUARDRAIL_FILE=$(mktemp)
trap 'rm -f "$GUARDRAIL_FILE"' EXIT

# Static section (single-quoted heredoc — no variable substitution needed).
cat >> "$GUARDRAIL_FILE" <<'STATIC'
WORK ITEM CREATION MODE — RESTRICTED SESSION

You are operating in a headless, restricted session. Your sole purpose is to
create work items based on the user request. Gather information as needed, then
create work items. Do nothing else.

PERMITTED ACTIONS:
  1. Read-only information gathering:
       gh issue list, gh issue view <number>, gh pr list, gh api <endpoint>
       lore work list, lore work search "<query>", lore search "<query>"
       curl <url> (read-only fetches only)

  2. Create work items — the ONLY write action permitted:
       bash <CREATE_SCRIPT> --title "<title>" \
         [--description "<description>"] \
         [--issue "<full github issue url>"] \
         [--pr "<full github pr url>"] \
         [--tags "<tag1,tag2>"]

  3. Print a plain-text summary of what you created.

PROHIBITED — do not attempt under any circumstances:
  - Edit, Write, or NotebookEdit tool use (no direct file creation or editing)
  - Any bash command not listed above
  - Modifying existing work items, knowledge entries, or any other system state
  - Invoking skills or spawning sub-agents

DEDUPLICATION — mandatory before creating any work item:
  Run: lore work search "<keywords>" to check for close matches.
  Do not create a work item if one already exists for the same issue or topic.

  Current work items:
STATIC

# Dynamic section — variable substitution for paths and existing work.
cat >> "$GUARDRAIL_FILE" <<DYNAMIC
$EXISTING_WORK

  (create-work.sh path: $CREATE_SCRIPT)

OUTPUT FORMAT — print after all work items are created:
  Created: "<title>" (slug: <slug>) [issue: #N] [pr: #N]
  If nothing was created, explain why briefly.
DYNAMIC

# Substitute the placeholder so Claude sees the real script path in the static section.
if [[ "$(uname)" == "Darwin" ]]; then
  sed -i '' "s|<CREATE_SCRIPT>|$CREATE_SCRIPT|g" "$GUARDRAIL_FILE"
else
  sed -i "s|<CREATE_SCRIPT>|$CREATE_SCRIPT|g" "$GUARDRAIL_FILE"
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[work-ai] DRY RUN"
  echo "[work-ai] Prompt  : $PROMPT"
  echo "[work-ai] Model   : $MODEL"
  echo "[work-ai] Budget  : \$$MAX_BUDGET"
  echo "[work-ai] Guardrails ($(wc -l < "$GUARDRAIL_FILE") lines):"
  echo "---"
  cat "$GUARDRAIL_FILE"
  echo "---"
  exit 0
fi

echo "[work-ai] Model: $MODEL | Budget cap: \$$MAX_BUDGET"
echo "[work-ai] Request: $PROMPT"
echo ""

mapfile -t CLAUDE_ARGS < <(load_claude_args)
claude -p "$PROMPT" \
  "${CLAUDE_ARGS[@]}" \
  --model "$MODEL" \
  --append-system-prompt "$(cat "$GUARDRAIL_FILE")" \
  --max-budget-usd "$MAX_BUDGET" \
  --output-format text
