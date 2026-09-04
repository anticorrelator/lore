#!/usr/bin/env bash
# guard-work-writes.sh — PreToolUse hook
# Blocks Write tool calls targeting _meta.json under _work/ directories.
# Agents must use `lore work create --title <name>` instead.
#
# Input:  JSON on stdin (PreToolUse hook format: tool_name, tool_input, ...)
# Output: {"decision":"block","reason":"..."} to block, {"decision":"approve"} to allow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
lore_agent_enabled || exit 0

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name') or '')" 2>/dev/null || true)

# Fast exit: not a Write call
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" && "$TOOL_NAME" != "MultiEdit" ]]; then
  printf '{"decision":"approve"}\n'
  exit 0
fi

FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input', {}).get('file_path') or '')" 2>/dev/null || true)

# Block if path contains /_work/ and ends with /_meta.json
if [[ "$FILE_PATH" == */_work/* && "$FILE_PATH" == */_meta.json ]]; then
  printf '{"decision":"block","reason":"Use '\''lore work create --title <name>'\'' instead of writing _meta.json directly. See /work skill for details."}\n'
  exit 0
fi

if [[ "$FILE_PATH" == */_work/*/revisions.jsonl || "$FILE_PATH" == */_work/*/revisions/* ]]; then
  printf '{"decision":"block","reason":"Use lore plan revise for revision history, snapshots, and publication staging."}\n'
  exit 0
fi

if [[ "$FILE_PATH" == */_work/*/reviews/* ]]; then
  printf '{"decision":"block","reason":"Use lore plan review prepare or seal for immutable review evidence."}\n'
  exit 0
fi

if [[ "$FILE_PATH" == */_work/*/results.jsonl || "$FILE_PATH" == */_work/*/results/* ]]; then
  printf '{"decision":"block","reason":"Use lore criteria run for executed results, output, and publication recovery."}\n'
  exit 0
fi

printf '{"decision":"approve"}\n'
