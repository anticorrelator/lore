#!/usr/bin/env bash
# harness-toggle/enable.sh — Enable lore integration for one or all harnesses
#
# Usage: bash enable.sh [<framework>]
#
# With no argument: enables every registered framework (claude-code, opencode,
# codex, ...). With a framework argument: enables only that one harness.
#
# For each enabled framework:
#   - Restores skill/agent symlinks under the harness's install paths.
#   - Re-assembles the framework's instruction file (CLAUDE.md / AGENTS.md)
#     via scripts/assemble-instructions.sh --framework <fw>.
#   - Sets harnesses.<fw>.enabled = true in unified settings.json.
#
# Settings writes are scoped to the affected framework only — unrelated
# harnesses' state is preserved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/../lib.sh"

SETTINGS_SH="$SCRIPT_DIR/../settings.sh"

# D6: symlink_manifest lives in install-state, separate from user-editable
# config. Co-owned with install.sh (install reads-and-merges; harness-toggle
# overwrites with the disable snapshot).
SYMLINKS_STATE="${LORE_DATA_DIR}/.install-state/symlinks.json"
SYMLINKS_STATE_TMP="${SYMLINKS_STATE}.tmp.$$"

ASSEMBLE="${LORE_DATA_DIR}/scripts/assemble-instructions.sh"

# Detect lore repo path from ~/.lore/scripts symlink (for install.sh fallback)
LORE_SCRIPTS_LINK="${LORE_DATA_DIR}/scripts"
LORE_REPO_DIR_TOGGLE=""
if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR_TOGGLE="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
fi

# --- Argument handling ---
# Positional <framework> selects a single harness; absence = fan all.
TARGET_FRAMEWORK=""
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<EOF
Usage: lore harness enable [<framework>]
  Enable lore integration for one harness (or all registered harnesses if no arg).
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

# Enumerate registered frameworks early — abort before any state mutation if this fails.
_fw_list=$(list_supported_frameworks) || exit 1
ALL_FRAMEWORKS=()
while IFS= read -r fw; do ALL_FRAMEWORKS+=("$fw"); done <<<"$_fw_list"
unset _fw_list

# Build the operating set: either [TARGET_FRAMEWORK] or all registered.
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

# --- Phase 3: restore skill/agent symlinks for each affected framework ---
# We restore from the install-state manifest when present, but filter entries
# by framework so a single-harness enable doesn't touch siblings.
restore_symlinks_for() {
  local target_fw="$1"
  local manifest="[]"

  if [[ -f "$SYMLINKS_STATE" ]]; then
    manifest=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(json.dumps(d.get('symlink_manifest', [])))
" "$SYMLINKS_STATE" 2>/dev/null || echo "[]")
  fi

  # Filter manifest entries to those whose link_path is under one of the
  # target framework's install dirs. install.sh and disable.sh now record
  # entries scoped per-framework so this filter is precise.
  local skills_dir agents_dir filtered="[]"
  skills_dir=$(LORE_FRAMEWORK="$target_fw" resolve_harness_install_path skills 2>/dev/null || true)
  agents_dir=$(LORE_FRAMEWORK="$target_fw" resolve_harness_install_path agents 2>/dev/null || true)
  [[ "$skills_dir" == "unsupported" ]] && skills_dir=""
  [[ "$agents_dir" == "unsupported" ]] && agents_dir=""

  if [[ -n "$skills_dir" || -n "$agents_dir" ]]; then
    filtered=$(python3 -c "
import json, sys
manifest = json.loads(sys.argv[1])
prefixes = [p for p in (sys.argv[2], sys.argv[3]) if p]
out = [e for e in manifest if any(e.get('link_path','').startswith(p + '/') for p in prefixes)]
print(json.dumps(out))
" "$manifest" "$skills_dir" "$agents_dir")
  fi

  local count
  count=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$filtered")

  if [[ "$count" -eq 0 ]]; then
    # Fallback: reconstruct from per-framework install logic.
    if [[ -z "$LORE_REPO_DIR_TOGGLE" ]]; then
      echo "  [warn] [$target_fw] No symlink manifest and cannot detect lore repo — run install.sh to restore skills" >&2
      return 0
    fi

    if [[ -n "$skills_dir" ]]; then
      mkdir -p "$skills_dir" || { echo "  [warn] [$target_fw] mkdir failed: $skills_dir" >&2; skills_dir=""; }
      if [[ -n "$skills_dir" ]]; then
        for skill_dir in "$LORE_REPO_DIR_TOGGLE"/skills/*/; do
          [[ -d "$skill_dir" ]] || continue
          skill_name="$(basename "$skill_dir")"
          link="${skills_dir}/${skill_name}"
          [[ -L "$link" ]] || ln -sfn "$skill_dir" "$link" \
            || echo "  [warn] [$target_fw] failed to link skill $skill_name" >&2
        done
      fi
    fi

    if [[ -n "$agents_dir" ]]; then
      mkdir -p "$agents_dir" || { echo "  [warn] [$target_fw] mkdir failed: $agents_dir" >&2; agents_dir=""; }
      if [[ -n "$agents_dir" ]]; then
        for agent_file in "$LORE_REPO_DIR_TOGGLE"/agents/*.md; do
          [[ -f "$agent_file" ]] || continue
          agent_name="$(basename "$agent_file")"
          link="${agents_dir}/${agent_name}"
          [[ -L "$link" ]] || ln -sf "$agent_file" "$link" \
            || echo "  [warn] [$target_fw] failed to link agent $agent_name" >&2
        done
      fi
    fi

    return 0
  fi

  # Restore from filtered manifest.
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
" "$filtered"
}

# --- Phase 4: re-assemble each affected framework's instruction file ---
restore_claude_md_for() {
  local target_fw="$1"
  if [[ ! -x "$ASSEMBLE" ]]; then
    echo "  [warn] assemble-instructions.sh not found — instruction file not updated" >&2
    return 0
  fi

  LORE_FRAMEWORK="$target_fw" bash "$ASSEMBLE" --framework "$target_fw" \
    || echo "  [warn] [$target_fw] assemble-instructions.sh failed (non-fatal)" >&2
}

mkdir -p "${LORE_DATA_DIR}/config"
mkdir -p "$(dirname "$SYMLINKS_STATE")"

# Ensure the install-state symlinks file exists so install.sh's read-and-merge
# has something to read. Idempotent: if present, leave it alone.
if [[ ! -f "$SYMLINKS_STATE" ]]; then
  python3 -c "
import json
print(json.dumps({'schema_version': 1, 'symlink_manifest': []}, indent=2))
" > "$SYMLINKS_STATE_TMP"
  mv "$SYMLINKS_STATE_TMP" "$SYMLINKS_STATE"
fi

for fw in "${FRAMEWORKS[@]}"; do
  # Mirror to settings.json::harnesses.<fw>.enabled via the locked patch
  # helper. Section-scoped: unrelated sections of settings.json are preserved
  # byte-for-byte by the patch contract.
  LORE_DATA_DIR="$LORE_DATA_DIR" bash "$SETTINGS_SH" patch "harnesses.${fw}.enabled" 'true'

  restore_symlinks_for "$fw"
  restore_claude_md_for "$fw"

  echo "Lore harness '$fw': enabled"
done
