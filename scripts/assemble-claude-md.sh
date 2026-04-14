#!/usr/bin/env bash
# assemble-claude-md.sh — Assemble CLAUDE.md from fragments
#
# Concatenates all .md files in claude-md/ (sorted by filename)
# into ~/.claude/CLAUDE.md wrapped in <!-- LORE:BEGIN --> / <!-- LORE:END --> sentinels.
# Non-lore content outside the sentinels is preserved on subsequent runs.
#
# Usage: bash assemble-claude-md.sh [--check | --disable]
#   --check    Diff only, exit 1 if out of date (useful for CI/hooks)
#   --disable  Write an empty lore region (preserves surrounding content)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
FRAGMENTS_DIR="$AGENT_DIR/claude-md"
TARGET="$HOME/.claude/CLAUDE.md"

source "$SCRIPT_DIR/lib.sh"

LORE_BEGIN="<!-- LORE:BEGIN -->"
LORE_END="<!-- LORE:END -->"

# Fragments to exclude from assembly (loaded on-demand by skills instead)
EXCLUDE=()

if [[ ! -d "$FRAGMENTS_DIR" ]]; then
  echo "Error: fragments directory not found: $FRAGMENTS_DIR" >&2
  exit 1
fi

# Ensure target directory exists
mkdir -p "$(dirname "$TARGET")"

# Build sorted fragments into a single string (trailing --- separator inside sentinels)
build_lore_block() {
  local block="" first=true
  for fragment in "$FRAGMENTS_DIR"/*.md; do
    [[ -f "$fragment" ]] || continue
    [[ ${#EXCLUDE[@]} -gt 0 && " ${EXCLUDE[*]} " == *" $(basename "$fragment") "* ]] && continue
    if [[ "$first" == true ]]; then
      first=false
    else
      block+="
"
    fi
    block+="$(cat "$fragment")"
    block+="
"
  done
  block+="
---
"
  printf '%s' "$block"
}

# Write lore_content into TARGET, bounded by sentinels.
# If sentinels exist: replace only the sentinel-bounded region (sentinel-scoped).
# If no sentinels: prepend the wrapped block, preserving any existing content.
# Writes atomically via a temp file.
splice_lore_block() {
  local lore_content="$1"
  local wrapped="${LORE_BEGIN}
${lore_content}${LORE_END}"

  local tmp
  tmp=$(mktemp)

  if [[ -f "$TARGET" ]] && grep -qF "$LORE_BEGIN" "$TARGET"; then
    python3 -c "
import sys, re
begin, end = sys.argv[1], sys.argv[2]
replacement = sys.argv[3]
with open(sys.argv[4]) as f:
    content = f.read()
pattern = re.escape(begin) + r'.*?' + re.escape(end)
new_content, n = re.subn(pattern, replacement, content, count=1, flags=re.DOTALL)
if n == 0:
    new_content = replacement + '\n' + content
sys.stdout.write(new_content)
" "$LORE_BEGIN" "$LORE_END" "$wrapped" "$TARGET" > "$tmp"
  else
    {
      printf '%s\n' "$wrapped"
      [[ -f "$TARGET" ]] && cat "$TARGET" || true
    } > "$tmp"
  fi

  mv "$tmp" "$TARGET"
}

# Handle --disable: write empty lore region, preserve surrounding content
if [[ "${1:-}" == "--disable" ]]; then
  splice_lore_block ""
  echo "Lore region cleared in $TARGET (disabled)"
  exit 0
fi

# Build expected content based on effective agent state
if lore_agent_enabled; then
  lore_block="$(build_lore_block)"
else
  lore_block=""
fi
wrapped_block="${LORE_BEGIN}
${lore_block}${LORE_END}"

if [[ "${1:-}" == "--check" ]]; then
  if [[ -f "$TARGET" ]] && grep -qF "$LORE_BEGIN" "$TARGET"; then
    current_region=$(python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    content = f.read()
m = re.search(re.escape(sys.argv[2]) + r'(.*?)' + re.escape(sys.argv[3]), content, re.DOTALL)
print(m.group(0) if m else '', end='')
" "$TARGET" "$LORE_BEGIN" "$LORE_END")
    if [[ "$current_region" == "$wrapped_block" ]]; then
      echo "CLAUDE.md is up to date."
      exit 0
    else
      echo "CLAUDE.md is out of date. Run: lore assemble" >&2
      diff <(printf '%s' "$wrapped_block") <(printf '%s' "$current_region") >&2 || true
      exit 1
    fi
  else
    echo "CLAUDE.md does not exist or has no lore sentinels. Run: lore assemble" >&2
    exit 1
  fi
fi

# First-time migration: if CLAUDE.md exists but has no sentinels, back it up and replace
# entirely with the sentinel-wrapped block. The backup preserves any pre-existing content;
# splice_lore_block is then skipped since we write the file directly here.
migrate_if_needed() {
  [[ -f "$TARGET" ]] || return 0
  grep -qF "$LORE_BEGIN" "$TARGET" && return 0  # already has sentinels, nothing to do

  local backup="${TARGET}.pre-lore-backup"
  if [[ ! -f "$backup" ]]; then
    cp "$TARGET" "$backup"
    echo "  [migrate] Backed up pre-sentinel CLAUDE.md to ${backup}"
  fi

  # Replace entire file with sentinel-wrapped lore block (no duplication risk)
  local tmp
  tmp=$(mktemp)
  printf '%s\n%s%s\n' "$LORE_BEGIN" "$lore_block" "$LORE_END" > "$tmp"
  mv "$tmp" "$TARGET"
  echo "  [migrate] Rewrote CLAUDE.md with sentinel markers"
  MIGRATION_DONE=1
}

MIGRATION_DONE=0
migrate_if_needed

if [[ "$MIGRATION_DONE" -eq 0 ]]; then
  splice_lore_block "$lore_block"
fi

total=$(ls "$FRAGMENTS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
excluded=${#EXCLUDE[@]}
if [[ $excluded -gt 0 ]]; then
  echo "Assembled $((total - excluded)) of $total fragments → $TARGET (excluded: ${EXCLUDE[*]})"
else
  echo "Assembled $total fragments → $TARGET"
fi
