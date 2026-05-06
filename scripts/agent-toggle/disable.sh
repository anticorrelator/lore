#!/usr/bin/env bash
# agent-toggle/disable.sh — Disable lore agent integration globally
# Atomically writes agent.json enabled=false (write-temp-then-rename).
# Removes per-harness skill/agent symlinks across all registered frameworks
# (resolve_harness_install_path {skills,agents}) and clears every framework's
# instruction file via scripts/assemble-instructions.sh --framework <fw> --disable.
# Usage: bash disable.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../lib.sh"

AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
AGENT_JSON_TMP="${AGENT_JSON}.tmp.$$"

ASSEMBLE="${LORE_DATA_DIR}/scripts/assemble-instructions.sh"

# Detect lore repo path from ~/.lore/scripts symlink
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

# --- Phase 3: remove skill/agent symlinks pointing into lore repo; record manifest ---
remove_symlinks() {
  if [[ -z "$LORE_REPO_DIR_TOGGLE" ]]; then
    echo "  [warn] Cannot detect lore repo path — skipping symlink removal" >&2
    MANIFEST="[]"
    return 0
  fi

  local manifest_entries=()

  for fw in "${FRAMEWORKS[@]}"; do
    for kind in skills agents; do
      local resolved
      if ! resolved=$(LORE_FRAMEWORK="$fw" resolve_harness_install_path "$kind" 2>/dev/null); then
        echo "  [warn] [$fw] resolve $kind path failed — skipping" >&2
        continue
      fi
      [[ "$resolved" == "unsupported" || -z "$resolved" ]] && continue
      [[ -d "$resolved" ]] || continue

      for link in "$resolved"/*; do
        [[ -L "$link" ]] || continue
        local target
        if ! target="$(readlink "$link" 2>/dev/null)"; then
          echo "  [warn] [$fw] readlink failed for $link — skipping" >&2
          continue
        fi
        # Resolve to absolute path for comparison
        if [[ "$target" != /* ]]; then
          target="$(cd "$(dirname "$link")" && pwd)/$(basename "$target")"
        fi
        # Only remove symlinks targeting paths under the lore repo
        if [[ "$target" == "$LORE_REPO_DIR_TOGGLE"/* || "$target" == "$LORE_REPO_DIR_TOGGLE" ]]; then
          manifest_entries+=("{\"name\":\"$(basename "$link")\",\"link_path\":\"$link\",\"target_path\":\"$target\"}")
          rm "$link" || echo "  [warn] [$fw] failed to remove $link" >&2
        fi
      done
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

# --- Phase 4: clear lore content from every registered framework's instruction file ---
clear_claude_md() {
  if [[ ! -x "$ASSEMBLE" ]]; then
    echo "  [warn] assemble-instructions.sh not found — instruction file not updated" >&2
    return 0
  fi

  for fw in "${FRAMEWORKS[@]}"; do
    LORE_FRAMEWORK="$fw" bash "$ASSEMBLE" --framework "$fw" --disable \
      || echo "  [warn] [$fw] assemble-instructions.sh --disable failed (non-fatal)" >&2
  done
}

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$(dirname "$AGENT_JSON")"

# Remove symlinks first — they populate MANIFEST before we write the JSON
MANIFEST="[]"
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
