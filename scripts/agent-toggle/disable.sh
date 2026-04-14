#!/usr/bin/env bash
# agent-toggle/disable.sh — Disable lore agent integration globally
# Atomically writes agent.json enabled=false (write-temp-then-rename).
# Surface removal (symlinks, CLAUDE.md) delegated to helpers — stubs for Phases 3-4.
# Usage: bash disable.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
AGENT_JSON_TMP="${AGENT_JSON}.tmp.$$"
CLAUDE_DIR="${HOME}/.claude"

# Detect lore repo path from ~/.lore/scripts symlink
LORE_SCRIPTS_LINK="${LORE_DATA_DIR}/scripts"
LORE_REPO_DIR=""
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi

# --- Phase 3: remove skill/agent symlinks pointing into lore repo; record manifest ---
remove_symlinks() {
  if [[ -z "$LORE_REPO_DIR" ]]; then
    echo "  [warn] Cannot detect lore repo path — skipping symlink removal" >&2
    return 0
  fi

  local manifest_entries=()

  for dir in "$CLAUDE_DIR/skills" "$CLAUDE_DIR/agents"; do
    [[ -d "$dir" ]] || continue
    for link in "$dir"/*; do
      [[ -L "$link" ]] || continue
      local target
      target="$(readlink "$link")"
      # Resolve to absolute path for comparison
      if [[ "$target" != /* ]]; then
        target="$(cd "$(dirname "$link")" && pwd)/$(basename "$target")"
      fi
      # Only remove symlinks targeting paths under the lore repo
      if [[ "$target" == "$LORE_REPO_DIR"/* || "$target" == "$LORE_REPO_DIR" ]]; then
        manifest_entries+=("{\"name\":\"$(basename "$link")\",\"link_path\":\"$link\",\"target_path\":\"$target\"}")
        rm "$link"
      fi
    done
  done

  # Output manifest JSON array for caller to embed in agent.json
  if [[ ${#manifest_entries[@]} -eq 0 ]]; then
    MANIFEST="[]"
  else
    local joined
    joined=$(printf ',%s' "${manifest_entries[@]}")
    MANIFEST="[${joined:1}]"
  fi
}

# --- Phase 4: clear lore content from CLAUDE.md via sentinel ---
clear_claude_md() {
  local assembler="${LORE_DATA_DIR}/scripts/assemble-claude-md.sh"
  if [[ -x "$assembler" ]]; then
    "$assembler" --disable
  else
    echo "  [warn] assemble-claude-md.sh not found — CLAUDE.md not updated" >&2
  fi
}

# Read existing manifest so we don't lose it when flipping disabled
MANIFEST="[]"
if [[ -f "$AGENT_JSON" ]]; then
  MANIFEST=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(json.dumps(d.get('symlink_manifest', [])))
" "$AGENT_JSON" 2>/dev/null || echo "[]")
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$AGENT_JSON")"

# Remove symlinks first — they populate the manifest before we write the JSON
remove_symlinks

python3 -c "
import json, sys
data = {
    'enabled': False,
    'last_changed': sys.argv[1],
    'symlink_manifest': json.loads(sys.argv[2]),
}
print(json.dumps(data, indent=2))
" "$TIMESTAMP" "$MANIFEST" > "$AGENT_JSON_TMP"

mv "$AGENT_JSON_TMP" "$AGENT_JSON"

clear_claude_md

echo "Lore agent integration: disabled"
echo "  Config: $AGENT_JSON"
echo "  Changed: $TIMESTAMP"
