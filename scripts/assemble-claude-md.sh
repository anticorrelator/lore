#!/usr/bin/env bash
# assemble-claude-md.sh — Assemble CLAUDE.md from fragments
#
# Concatenates all .md files in claude-md/ (sorted by filename)
# into ~/.claude/CLAUDE.md with a generated-file header.
#
# Usage: bash assemble-claude-md.sh [--check]
#   --check  Diff only, exit 1 if out of date (useful for CI/hooks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
FRAGMENTS_DIR="$AGENT_DIR/claude-md"
TARGET="$HOME/.claude/CLAUDE.md"

if [[ ! -d "$FRAGMENTS_DIR" ]]; then
  echo "Error: fragments directory not found: $FRAGMENTS_DIR" >&2
  exit 1
fi

# Ensure target directory exists
mkdir -p "$(dirname "$TARGET")"

# Assemble: sorted fragments separated by blank lines, trailing separator
assembled=""

first=true
for fragment in "$FRAGMENTS_DIR"/*.md; do
  [[ -f "$fragment" ]] || continue
  if [[ "$first" == true ]]; then
    first=false
  else
    assembled+="
"
  fi
  assembled+="$(cat "$fragment")"
  assembled+="
"
done

# Trailing separator to delineate from other CLAUDE.md content
assembled+="
---
"

if [[ "${1:-}" == "--check" ]]; then
  if [[ -f "$TARGET" ]]; then
    if diff <(echo "$assembled") "$TARGET" > /dev/null 2>&1; then
      echo "CLAUDE.md is up to date."
      exit 0
    else
      echo "CLAUDE.md is out of date. Run: bash ~/.project-knowledge/scripts/assemble-claude-md.sh" >&2
      diff <(echo "$assembled") "$TARGET" >&2 || true
      exit 1
    fi
  else
    echo "CLAUDE.md does not exist yet. Run: bash ~/.project-knowledge/scripts/assemble-claude-md.sh" >&2
    exit 1
  fi
fi

echo "$assembled" > "$TARGET"
echo "Assembled $(ls "$FRAGMENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ') fragments → $TARGET"
