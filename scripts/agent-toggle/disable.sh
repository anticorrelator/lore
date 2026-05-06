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

SETTINGS_SH="$SCRIPT_DIR/../settings.sh"
AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
AGENT_JSON_TMP="${AGENT_JSON}.tmp.$$"

# D6: symlink_manifest lives in install-state, separate from user-editable
# config. Co-owned with install.sh (install reads-and-merges; agent-toggle
# overwrites with the disable snapshot).
SYMLINKS_STATE="${LORE_DATA_DIR}/.install-state/symlinks.json"
SYMLINKS_STATE_TMP="${SYMLINKS_STATE}.tmp.$$"

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
mkdir -p "$(dirname "$SYMLINKS_STATE")"

# Remove symlinks first — they populate MANIFEST before we write the JSON
MANIFEST="[]"
remove_symlinks

# Write the disable-state symlink manifest to install-state/symlinks.json
# (D6 owns this path; install.sh reads-and-merges, never clobbers).
python3 -c "
import json, sys
data = {
    'schema_version': 1,
    'symlink_manifest': json.loads(sys.argv[1]),
}
print(json.dumps(data, indent=2))
" "$MANIFEST" > "$SYMLINKS_STATE_TMP"
mv "$SYMLINKS_STATE_TMP" "$SYMLINKS_STATE"

# Write the user-facing enable/disable state to agent.json (legacy path
# during the deprecation window) AND to the unified settings.json so the
# new loader sees the change immediately.
python3 -c "
import json, sys
data = {
    'enabled': False,
    'last_changed': sys.argv[1],
}
print(json.dumps(data, indent=2))
" "$TIMESTAMP" > "$AGENT_JSON_TMP"

mv "$AGENT_JSON_TMP" "$AGENT_JSON"

# Mirror to settings.json::agent.{enabled,last_changed} via the locked
# patch helper so concurrent writers (e.g., a TUI SavePrefs in parallel)
# don't lose the disable mutation. Section-scoped: unrelated sections of
# settings.json are preserved by the patch contract.
LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" patch agent.enabled 'false'
LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" patch agent.last_changed "$(printf '%s' "$TIMESTAMP" | jq -R .)"

clear_claude_md

echo "Lore agent integration: disabled"
echo "  Config: $AGENT_JSON"
echo "  Changed: $TIMESTAMP"
