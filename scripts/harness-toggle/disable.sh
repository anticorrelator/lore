#!/usr/bin/env bash
# harness-toggle/disable.sh — Disable lore integration for one or all harnesses
#
# Usage: bash disable.sh [<framework>]
#
# With no argument: disables every registered framework. With a framework
# argument: disables only that one harness.
#
# For each disabled framework:
#   - Removes skill/agent symlinks under the harness's install paths (only
#     symlinks pointing into the lore repo; non-lore entries are left alone).
#   - Clears the framework's instruction file lore region via
#     scripts/assemble-instructions.sh --framework <fw> --disable.
#   - Sets harnesses.<fw>.enabled = false in unified settings.json.
#
# Settings writes are scoped per-framework — unrelated harnesses' state is
# preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../lib.sh"

SETTINGS_SH="$SCRIPT_DIR/../settings.sh"

# D6: symlink_manifest lives in install-state. Co-owned with install.sh
# (install reads-and-merges; harness-toggle disables overwrite the manifest
# with the snapshot of removed links so a later enable can restore).
SYMLINKS_STATE="${LORE_DATA_DIR}/.install-state/symlinks.json"
SYMLINKS_STATE_TMP="${SYMLINKS_STATE}.tmp.$$"

ASSEMBLE="${LORE_DATA_DIR}/scripts/assemble-instructions.sh"

# Detect lore repo path from ~/.lore/scripts symlink
LORE_SCRIPTS_LINK="${LORE_DATA_DIR}/scripts"
LORE_REPO_DIR_TOGGLE=""
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR_TOGGLE="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi

# --- Argument handling (mirrors enable.sh) ---
TARGET_FRAMEWORK=""
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<EOF
Usage: lore harness disable [<framework>]
  Disable lore integration for one harness (or all registered harnesses if no arg).
EOF
      exit 0
      ;;
    -*) echo "Error: unknown flag '$arg'" >&2; exit 2 ;;
    *)
      if [[ -n "$TARGET_FRAMEWORK" ]]; then
        echo "Error: only one framework may be specified ($TARGET_FRAMEWORK then $arg)" >&2
        exit 2
      fi
      TARGET_FRAMEWORK="$arg"
      ;;
  esac
done

_fw_list=$(list_supported_frameworks) || exit 1
ALL_FRAMEWORKS=()
while IFS= read -r fw; do ALL_FRAMEWORKS+=("$fw"); done <<<"$_fw_list"
unset _fw_list

FRAMEWORKS=()
if [[ -n "$TARGET_FRAMEWORK" ]]; then
  found=0
  for fw in "${ALL_FRAMEWORKS[@]}"; do
    if [[ "$fw" == "$TARGET_FRAMEWORK" ]]; then
      found=1
      break
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "Error: '$TARGET_FRAMEWORK' is not a registered framework" >&2
    echo "       Registered: ${ALL_FRAMEWORKS[*]}" >&2
    exit 2
  fi
  FRAMEWORKS=("$TARGET_FRAMEWORK")
else
  FRAMEWORKS=("${ALL_FRAMEWORKS[@]}")
fi

# --- Phase 3: remove symlinks for each affected framework, capturing manifest ---
# Appends entries into the global REMOVED_MANIFEST_ENTRIES bash array.
REMOVED_MANIFEST_ENTRIES=()
remove_symlinks_for() {
  local target_fw="$1"
  if [[ -z "$LORE_REPO_DIR_TOGGLE" ]]; then
    echo "  [warn] [$target_fw] Cannot detect lore repo path — skipping symlink removal" >&2
    return 0
  fi

  for kind in skills agents; do
    local resolved
    if ! resolved=$(LORE_FRAMEWORK="$target_fw" resolve_harness_install_path "$kind" 2>/dev/null); then
      echo "  [warn] [$target_fw] resolve $kind path failed — skipping" >&2
      continue
    fi
    [[ "$resolved" == "unsupported" || -z "$resolved" ]] && continue
    [[ -d "$resolved" ]] || continue

    for link in "$resolved"/*; do
      [[ -L "$link" ]] || continue
      local target
      if ! target="$(readlink "$link" 2>/dev/null)"; then
        echo "  [warn] [$target_fw] readlink failed for $link — skipping" >&2
        continue
      fi
      # Resolve to absolute path for comparison
      if [[ "$target" != /* ]]; then
        target="$(cd "$(dirname "$link")" && pwd)/$(basename "$target")"
      fi
      # Only remove symlinks targeting paths under the lore repo
      if [[ "$target" == "$LORE_REPO_DIR_TOGGLE"/* || "$target" == "$LORE_REPO_DIR_TOGGLE" ]]; then
        REMOVED_MANIFEST_ENTRIES+=("{\"name\":\"$(basename "$link")\",\"link_path\":\"$link\",\"target_path\":\"$target\"}")
        rm "$link" || echo "  [warn] [$target_fw] failed to remove $link" >&2
      fi
    done
  done
}

# --- Phase 4: clear instruction file region for each affected framework ---
clear_claude_md_for() {
  local target_fw="$1"
  if [[ ! -x "$ASSEMBLE" ]]; then
    echo "  [warn] assemble-instructions.sh not found — instruction file not updated" >&2
    return 0
  fi

  LORE_FRAMEWORK="$target_fw" bash "$ASSEMBLE" --framework "$target_fw" --disable \
    || echo "  [warn] [$target_fw] assemble-instructions.sh --disable failed (non-fatal)" >&2
}

mkdir -p "${LORE_DATA_DIR}/config"
mkdir -p "$(dirname "$SYMLINKS_STATE")"

# Read the prior manifest so a single-harness disable doesn't lose the other
# harnesses' previously-recorded entries.
PRIOR_MANIFEST="[]"
if [[ -f "$SYMLINKS_STATE" ]]; then
  PRIOR_MANIFEST=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(json.dumps(d.get('symlink_manifest', [])))
" "$SYMLINKS_STATE" 2>/dev/null || echo "[]")
fi

for fw in "${FRAMEWORKS[@]}"; do
  remove_symlinks_for "$fw"
  clear_claude_md_for "$fw"

  # Mirror to settings.json::harnesses.<fw>.enabled
  LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" patch "harnesses.${fw}.enabled" 'false'

  echo "Lore harness '$fw': disabled"
done

# Compose the new manifest: prior manifest + newly-removed entries, deduped
# by link_path so re-runs are idempotent.
NEW_ADDITIONS="[]"
if [[ ${#REMOVED_MANIFEST_ENTRIES[@]} -gt 0 ]]; then
  joined=$(printf ',%s' "${REMOVED_MANIFEST_ENTRIES[@]}")
  NEW_ADDITIONS="[${joined:1}]"
fi

python3 -c "
import json, sys
prior = json.loads(sys.argv[1])
new = json.loads(sys.argv[2])
seen = set()
out = []
for entry in prior + new:
    key = entry.get('link_path')
    if key in seen:
        continue
    seen.add(key)
    out.append(entry)
data = {'schema_version': 1, 'symlink_manifest': out}
print(json.dumps(data, indent=2))
" "$PRIOR_MANIFEST" "$NEW_ADDITIONS" > "$SYMLINKS_STATE_TMP"
mv "$SYMLINKS_STATE_TMP" "$SYMLINKS_STATE"
