#!/usr/bin/env bash
# agent-toggle/enable.sh — Enable lore agent integration globally
# Atomically writes agent.json enabled=true (write-temp-then-rename).
# Surface restoration (symlinks, CLAUDE.md) delegated to helpers — stubs for Phases 3-4.
# Usage: bash enable.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"

AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
AGENT_JSON_TMP="${AGENT_JSON}.tmp.$$"

# Detect lore repo path from ~/.lore/scripts symlink (for install.sh fallback)
LORE_SCRIPTS_LINK="${LORE_DATA_DIR}/scripts"
LORE_REPO_DIR=""
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi

# --- Phase 3: restore skill/agent symlinks from manifest; fallback to install.sh logic ---
restore_symlinks() {
  local manifest
  manifest=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(json.dumps(d.get('symlink_manifest', [])))
" "$AGENT_JSON" 2>/dev/null || echo "[]")

  local count
  count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$manifest")

  if [[ "$count" -eq 0 ]]; then
    # Fallback: reconstruct from install.sh symlink logic
    if [[ -z "$LORE_REPO_DIR" ]]; then
      echo "  [warn] No symlink manifest and cannot detect lore repo — run install.sh to restore skills" >&2
      return 0
    fi
    for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
      [[ -d "$skill_dir" ]] || continue
      skill_name="$(basename "$skill_dir")"
      link="${HOME}/.claude/skills/${skill_name}"
      [[ -L "$link" ]] || ln -sfn "$skill_dir" "$link"
    done
    for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
      [[ -f "$agent_file" ]] || continue
      agent_name="$(basename "$agent_file")"
      link="${HOME}/.claude/agents/${agent_name}"
      [[ -L "$link" ]] || ln -sf "$agent_file" "$link"
    done
    return 0
  fi

  # Restore from manifest with conflict safety
  python3 -c "
import json, os, sys
manifest = json.loads(sys.argv[1])
for entry in manifest:
    link_path = entry['link_path']
    target_path = entry['target_path']
    if os.path.lexists(link_path):
        continue  # conflict: non-lore entry exists, leave it alone
    os.makedirs(os.path.dirname(link_path), exist_ok=True)
    os.symlink(target_path, link_path)
" "$manifest"
}

# --- Phase 4: re-assemble CLAUDE.md with lore content ---
restore_claude_md() {
  local assembler="${LORE_DATA_DIR}/scripts/assemble-claude-md.sh"
  if [[ -x "$assembler" ]]; then
    "$assembler"
  else
    echo "  [warn] assemble-claude-md.sh not found — CLAUDE.md not updated" >&2
  fi
}

# Read existing manifest so we don't lose it when flipping enabled
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

python3 -c "
import json, sys
data = {
    'enabled': True,
    'last_changed': sys.argv[1],
    'symlink_manifest': json.loads(sys.argv[2]),
}
print(json.dumps(data, indent=2))
" "$TIMESTAMP" "$MANIFEST" > "$AGENT_JSON_TMP"

mv "$AGENT_JSON_TMP" "$AGENT_JSON"

restore_symlinks
restore_claude_md

echo "Lore agent integration: enabled"
echo "  Config: $AGENT_JSON"
echo "  Changed: $TIMESTAMP"
