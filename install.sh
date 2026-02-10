#!/usr/bin/env bash
# install.sh — Set up lore for Claude Code
# Usage: bash install.sh [--uninstall] [--dry-run]
set -euo pipefail

# --- Resolve paths ---
LORE_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LORE_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
CLAUDE_DIR="$HOME/.claude"

# --- Parse flags ---
UNINSTALL=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --uninstall) UNINSTALL=true ;;
    --dry-run)   DRY_RUN=true ;;
    *)           echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# --- Helpers ---
info()  { echo "  [lore] $*"; }
dry()   { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }

# =========================================================================
#  UNINSTALL
# =========================================================================
if $UNINSTALL; then
  echo "Uninstalling lore..."

  # Remove skill symlinks
  if [ -d "$CLAUDE_DIR/skills" ]; then
    for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
      skill_name="$(basename "$skill_dir")"
      target="$CLAUDE_DIR/skills/$skill_name"
      if [ -L "$target" ] || [ -e "$target" ]; then
        info "Removing skill symlink: $target"
        dry rm -rf "$target"
      fi
    done
  fi

  # Remove CLI symlink
  if [ -L "$HOME/.local/bin/lore" ]; then
    info "Removing CLI symlink: $HOME/.local/bin/lore"
    dry rm -f "$HOME/.local/bin/lore"
  fi

  # Remove scripts symlink
  if [ -L "$LORE_DATA_DIR/scripts" ]; then
    info "Removing scripts symlink: $LORE_DATA_DIR/scripts"
    dry rm -f "$LORE_DATA_DIR/scripts"
  fi

  # Remove lore hooks from settings.json
  if [ -f "$CLAUDE_DIR/settings.json" ]; then
    info "Removing lore hooks from settings.json"
    if ! $DRY_RUN; then
      python3 - "$CLAUDE_DIR/settings.json" <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for hook_type in list(hooks.keys()):
    entries = hooks[hook_type]
    filtered = []
    for entry in entries:
        inner_hooks = entry.get("hooks", [])
        is_lore = any(
            "lore/scripts/" in h.get("command", "") or "project-knowledge/scripts/" in h.get("command", "")
            or "lore-capture-evaluator" in h.get("prompt", "")
            for h in inner_hooks
        )
        if not is_lore:
            filtered.append(entry)
    if filtered:
        hooks[hook_type] = filtered
    else:
        del hooks[hook_type]

if hooks:
    settings["hooks"] = hooks
elif "hooks" in settings:
    del settings["hooks"]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
    fi
  fi

  echo ""
  echo "Lore hooks and symlinks removed."
  echo "Data directory preserved at: $LORE_DATA_DIR"
  echo "To remove data: rm -rf $LORE_DATA_DIR"
  exit 0
fi

# =========================================================================
#  INSTALL
# =========================================================================
echo "Installing lore..."
echo "  Repo:  $LORE_REPO_DIR"
echo "  Data:  $LORE_DATA_DIR"
echo "  Claude: $CLAUDE_DIR"
echo ""

# --- 1. Create data directory ---
info "Creating data directory"
dry mkdir -p "$LORE_DATA_DIR/repos"

# --- 2. Create/update stable scripts symlink ---
info "Linking scripts -> $LORE_REPO_DIR/scripts"
dry ln -sfn "$LORE_REPO_DIR/scripts" "$LORE_DATA_DIR/scripts"

# --- 3. Install CLI to PATH ---
info "Installing CLI to ~/.local/bin/lore"
dry mkdir -p "$HOME/.local/bin"
dry ln -sf "$LORE_REPO_DIR/cli/lore" "$HOME/.local/bin/lore"

# Check if ~/.local/bin is on PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
  echo ""
  echo "  [warning] ~/.local/bin is not on your PATH."
  echo "  Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

# --- 4. Symlink skills ---
dry mkdir -p "$CLAUDE_DIR/skills"
for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
  skill_name="$(basename "$skill_dir")"
  target="$CLAUDE_DIR/skills/$skill_name"
  # Remove existing target (symlink, file, or directory)
  if [ -L "$target" ] || [ -e "$target" ]; then
    dry rm -rf "$target"
  fi
  info "Linking skill: $skill_name"
  dry ln -s "$skill_dir" "$target"
done

# --- 5. Inject hooks into settings.json ---
info "Configuring hooks in settings.json"
if ! $DRY_RUN; then
  dry mkdir -p "$CLAUDE_DIR"
  python3 - "$CLAUDE_DIR/settings.json" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]

# Read existing settings or start fresh
if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

# Resolve the lore repo dir from the ~/.lore/scripts symlink
scripts_link = os.path.expanduser("~/.lore/scripts")
if os.path.islink(scripts_link):
    repo_dir = os.path.dirname(os.path.realpath(scripts_link))
else:
    repo_dir = os.getcwd()

# Define lore hooks
# Each tuple: (hook_type, matcher_or_none, hook_kind, payload, timeout)
#   hook_kind: "command" or "agent"
#   payload: command string for "command" hooks, prompt string for "agent" hooks
lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-knowledge.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-threads.sh", 5),
    ("SessionStart", None, "command", "python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/stop-novelty-check.py", 10),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
    ("TaskCompleted", None, "command", "bash ~/.lore/scripts/task-completed-capture-check.sh", 10),
    ("SessionEnd",   "clear", "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
]

def is_lore_hook(entry):
    """Check if a hook entry belongs to lore (current or legacy path)."""
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        # Agent hooks from lore contain the lore-capture-evaluator marker
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    """Build a hook entry in the Claude settings format."""
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

# Group lore hooks by hook_type
from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

# For each hook type that has lore hooks: remove old lore entries, append new ones
all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    # Keep non-lore hooks
    preserved = [e for e in existing if not is_lore_hook(e)]
    # Add new lore hooks for this type
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

# Clean up empty hook types
hooks = {k: v for k, v in hooks.items() if v}

settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
fi

# --- 6. Assemble CLAUDE.md ---
info "Assembling CLAUDE.md"
if ! $DRY_RUN; then
  bash "$LORE_REPO_DIR/scripts/assemble-claude-md.sh"
fi

# --- 7. Migrate old data ---
OLD_DATA_DIR="$HOME/.project-knowledge/repos"
if [ -d "$OLD_DATA_DIR" ] && [ -d "$LORE_DATA_DIR/repos" ]; then
  # Check if new repos dir is empty (no entries besides . and ..)
  if [ -z "$(ls -A "$LORE_DATA_DIR/repos" 2>/dev/null)" ]; then
    info "Migrating data from $OLD_DATA_DIR"
    dry cp -a "$OLD_DATA_DIR/." "$LORE_DATA_DIR/repos/"
  fi
fi

# --- 8. Summary ---
echo ""
echo "Lore installed successfully."
echo ""
echo "  Data dir:    $LORE_DATA_DIR"
echo "  Scripts:     $LORE_DATA_DIR/scripts -> $LORE_REPO_DIR/scripts"
echo "  CLI:         ~/.local/bin/lore -> $LORE_REPO_DIR/cli/lore"
echo "  Skills:      $CLAUDE_DIR/skills/ ($(ls -d "$LORE_REPO_DIR"/skills/*/ 2>/dev/null | wc -l | tr -d ' ') linked)"
echo "  Hooks:       $CLAUDE_DIR/settings.json (updated)"
echo "  CLAUDE.md:   $CLAUDE_DIR/CLAUDE.md (assembled)"
echo ""
echo "To uninstall: bash $LORE_REPO_DIR/install.sh --uninstall"
