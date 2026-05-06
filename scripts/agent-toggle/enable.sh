#!/usr/bin/env bash
# agent-toggle/enable.sh — Enable lore agent integration globally
# Atomically writes agent.json enabled=true (write-temp-then-rename).
# Restores per-harness skill/agent symlinks and re-assembles every registered
# framework's instruction file (CLAUDE.md / AGENTS.md) via
# scripts/assemble-instructions.sh --framework <fw>.
# Usage: bash enable.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../lib.sh"

AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
AGENT_JSON_TMP="${AGENT_JSON}.tmp.$$"

ASSEMBLE="${LORE_DATA_DIR}/scripts/assemble-instructions.sh"

# Detect lore repo path from ~/.lore/scripts symlink (for install.sh fallback)
LORE_SCRIPTS_LINK="${LORE_DATA_DIR}/scripts"
LORE_REPO_DIR_TOGGLE=""
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR_TOGGLE="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi

# Enumerate registered frameworks early — abort before any state mutation if this fails.
# Capture output explicitly so a die() inside list_supported_frameworks propagates to the
# outer shell (process substitution <(...) swallows exit codes in bash 3.2+).
_fw_list=$(list_supported_frameworks) || exit 1
FRAMEWORKS=()
while IFS= read -r fw; do FRAMEWORKS+=("$fw"); done <<<"$_fw_list"
unset _fw_list

# --- Phase 3: restore skill/agent symlinks from manifest; fallback to per-framework install logic ---
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
    # Fallback: reconstruct from per-framework install logic for every registered harness
    if [[ -z "$LORE_REPO_DIR_TOGGLE" ]]; then
      echo "  [warn] No symlink manifest and cannot detect lore repo — run install.sh to restore skills" >&2
      return 0
    fi

    for fw in "${FRAMEWORKS[@]}"; do
      local skills_dir agents_dir
      if skills_dir=$(LORE_FRAMEWORK="$fw" resolve_harness_install_path skills 2>/dev/null); then
        if [[ "$skills_dir" != "unsupported" && -n "$skills_dir" ]]; then
          mkdir -p "$skills_dir" || { echo "  [warn] [$fw] mkdir failed: $skills_dir" >&2; skills_dir=""; }
          if [[ -n "$skills_dir" ]]; then
            for skill_dir in "$LORE_REPO_DIR_TOGGLE"/skills/*/; do
              [[ -d "$skill_dir" ]] || continue
              skill_name="$(basename "$skill_dir")"
              link="${skills_dir}/${skill_name}"
              [[ -L "$link" ]] || ln -sfn "$skill_dir" "$link" \
                || echo "  [warn] [$fw] failed to link skill $skill_name" >&2
            done
          fi
        fi
      else
        echo "  [warn] [$fw] resolve skills path failed — skipping skills for this framework" >&2
      fi

      if agents_dir=$(LORE_FRAMEWORK="$fw" resolve_harness_install_path agents 2>/dev/null); then
        if [[ "$agents_dir" != "unsupported" && -n "$agents_dir" ]]; then
          mkdir -p "$agents_dir" || { echo "  [warn] [$fw] mkdir failed: $agents_dir" >&2; agents_dir=""; }
          if [[ -n "$agents_dir" ]]; then
            for agent_file in "$LORE_REPO_DIR_TOGGLE"/agents/*.md; do
              [[ -f "$agent_file" ]] || continue
              agent_name="$(basename "$agent_file")"
              link="${agents_dir}/${agent_name}"
              [[ -L "$link" ]] || ln -sf "$agent_file" "$link" \
                || echo "  [warn] [$fw] failed to link agent $agent_name" >&2
            done
          fi
        fi
      else
        echo "  [warn] [$fw] resolve agents path failed — skipping agents for this framework" >&2
      fi
    done

    return 0
  fi

  # Restore from manifest — per-entry try/except so one failed link does not skip later entries
  python3 -c "
import json, os, sys

manifest = json.loads(sys.argv[1])
for entry in manifest:
    link_path = entry['link_path']
    target_path = entry['target_path']
    try:
        if os.path.lexists(link_path):
            continue  # conflict: non-lore entry exists, leave it alone
        os.makedirs(os.path.dirname(link_path), exist_ok=True)
        os.symlink(target_path, link_path)
    except Exception as e:
        print(f'  [warn] manifest replay failed for {link_path}: {e}', file=sys.stderr)
" "$manifest"
}

# --- Phase 4: re-assemble every registered framework's instruction file ---
restore_claude_md() {
  if [[ ! -x "$ASSEMBLE" ]]; then
    echo "  [warn] assemble-instructions.sh not found — instruction file not updated" >&2
    return 0
  fi

  for fw in "${FRAMEWORKS[@]}"; do
    LORE_FRAMEWORK="$fw" bash "$ASSEMBLE" --framework "$fw" \
      || echo "  [warn] [$fw] assemble-instructions.sh failed (non-fatal)" >&2
  done
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
