#!/usr/bin/env bash
# adapters/hooks/claude-code.sh — Claude Code hook adapter (T25).
#
# Implements the hook adapter contract documented in
# adapters/hooks/README.md (T24) for Claude Code: SessionStart,
# PreCompact, Stop, TaskCompleted, PreToolUse, SessionEnd. Every Lore
# lifecycle event maps to a native Claude Code hook (this is the
# reference implementation; opencode/codex adapters with degraded
# coverage land in T26/T27).
#
# Subcommands:
#   install    Inject the lore hook entries into ~/.claude/settings.json,
#              preserving any non-lore hook entries the user has there.
#   uninstall  Remove every lore-installed hook entry from settings.json,
#              preserving non-lore entries. Empty hook-types are deleted.
#   smoke      Print the per-event support level + the native hook
#              each Lore lifecycle event maps to. Honors the smoke
#              contract documented in adapters/hooks/README.md.
#
# Refactored from install.sh's inline python block (formerly
# install.sh:389-481 install + install.sh:147-184 uninstall). Behavior
# is preserved bit-for-bit: identical hook list, identical settings.json
# edits, identical legacy-path detection (`lore/scripts/` and
# `project-knowledge/scripts/`).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LORE_REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

# Source lib.sh from the lore repo so resolve_harness_install_path is
# available. The repo path is sibling-up-twice from this file.
# shellcheck source=/dev/null
source "$LORE_REPO_DIR/scripts/lib.sh"

# --- Resolve settings.json target ---
# Active framework MUST be claude-code for this adapter; the caller
# (install.sh, smoke harnesses) is responsible for setting LORE_FRAMEWORK
# correctly. We honor the active framework so a future caller can install
# claude-code's settings.json without flipping framework.json globally.
require_claude_code() {
  local active
  active=$(resolve_active_framework 2>/dev/null) || active=""
  if [[ "$active" != "claude-code" ]]; then
    echo "Error: adapters/hooks/claude-code.sh requires active framework=claude-code (got '$active')" >&2
    echo "       set LORE_FRAMEWORK=claude-code or run install.sh --framework claude-code" >&2
    return 1
  fi
}

resolve_settings_path() {
  local settings_path
  if ! settings_path=$(resolve_harness_install_path settings 2>/dev/null); then
    echo "Error: resolve_harness_install_path settings failed for claude-code" >&2
    return 1
  fi
  if [[ "$settings_path" == "unsupported" ]]; then
    echo "Error: install_paths.settings is 'unsupported' for claude-code (capabilities.json contract violation)" >&2
    return 1
  fi
  echo "$settings_path"
}

# --- Subcommand: install ---
# Inject the lore hook list into settings.json. Preserves any non-lore
# entries the user has placed under .hooks. Replaces existing lore
# entries (same legacy-path detection as install.sh).
cmd_install() {
  require_claude_code
  local settings_path
  settings_path=$(resolve_settings_path)
  mkdir -p "$(dirname "$settings_path")"

  python3 - "$settings_path" <<'PYEOF'
import json, sys, os
from collections import defaultdict

settings_path = sys.argv[1]

# Read existing settings or start fresh.
if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

# Define lore hooks. Tuple shape:
#   (hook_type, matcher_or_none, hook_kind, payload, timeout_seconds)
# hook_kind is "command" or "agent"; payload is the shell command or
# the agent prompt text. Identical to the list that previously lived
# in install.sh:416-429.
lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/doctor.sh --quiet", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-knowledge.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-threads.sh", 5),
    ("SessionStart", None, "command", "python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/stop-novelty-check.py", 10),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
    ("TaskCompleted", None, "command", "bash ~/.lore/scripts/task-completed-capture-check.sh", 10),
    ("PreToolUse",   "Write", "command", "bash ~/.lore/scripts/guard-work-writes.sh", 5),
    ("SessionEnd",   "clear", "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
]

def is_lore_hook(entry):
    """Return True if the hook entry was installed by lore.

    Detects both the current path (`lore/scripts/`) and the legacy
    path (`project-knowledge/scripts/`); also detects agent hooks via
    the lore-capture-evaluator marker in the prompt.
    """
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

# Group lore hooks by hook_type so we can rewrite entries per type.
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

# For each hook type that has lore hooks: keep the user's non-lore
# entries, append the fresh lore entries.
all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    preserved = [e for e in existing if not is_lore_hook(e)]
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

# Drop any hook-type that ended up empty (e.g. if it only ever held
# lore entries and lore_by_type no longer touches it).
hooks = {k: v for k, v in hooks.items() if v}

settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
}

# --- Subcommand: uninstall ---
# Remove every lore-installed hook entry from settings.json. Preserves
# non-lore entries. Empty hook-types are deleted; if .hooks ends up
# empty entirely, the key itself is deleted.
cmd_uninstall() {
  require_claude_code
  local settings_path
  settings_path=$(resolve_settings_path)
  if [[ ! -f "$settings_path" ]]; then
    return 0
  fi

  python3 - "$settings_path" <<'PYEOF'
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
}

# --- Subcommand: smoke ---
# Print, for the active framework (must be claude-code here), every
# Lore lifecycle event paired with its support level and the native
# Claude Code hook it routes through. Mirrors the smoke contract in
# adapters/hooks/README.md "Adapter responsibilities" #4.
cmd_smoke() {
  require_claude_code
  local settings_path
  settings_path=$(resolve_settings_path 2>/dev/null) || settings_path="<unresolved>"

  echo "[claude-code hook adapter smoke]"
  echo "  active framework: claude-code"
  echo "  settings path:    $settings_path"
  echo
  echo "  Lore event           Support   Native hook (claude-code)"
  echo "  -------------------- --------- ----------------------------------------"
  printf '  %-20s %-9s %s\n' session_start      full      "SessionStart hook (~/.lore/scripts/{doctor,auto-reindex,load-knowledge,load-work,load-threads,extract-session-digest})"
  printf '  %-20s %-9s %s\n' user_prompt        full      "(no native UserPromptSubmit hook today; PreToolUse Write matcher covers lore writes)"
  printf '  %-20s %-9s %s\n' pre_tool           full      "PreToolUse hook (matcher=Write -> guard-work-writes.sh)"
  printf '  %-20s %-9s %s\n' post_tool          full      "(currently unused by lore; PostToolUse hook surface available)"
  printf '  %-20s %-9s %s\n' permission_request full      "PreToolUse JSON-stdout decision protocol (no separate lore handler)"
  printf '  %-20s %-9s %s\n' pre_compact        full      "PreCompact hook (~/.lore/scripts/pre-compact.sh)"
  printf '  %-20s %-9s %s\n' stop               full      "Stop hook (stop-novelty-check.py + check-plan-persistence.py)"
  printf '  %-20s %-9s %s\n' session_end        full      "SessionEnd hook (matcher=clear -> pre-compact.sh)"
  printf '  %-20s %-9s %s\n' task_completed     full      "TaskCompleted hook (task-completed-capture-check.sh, exit-2 blocking)"
}

# --- Dispatch ---
cmd="${1:-}"
case "$cmd" in
  install)   shift; cmd_install   "$@" ;;
  uninstall) shift; cmd_uninstall "$@" ;;
  smoke)     shift; cmd_smoke     "$@" ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand>

Subcommands:
  install    Inject lore hooks into the active framework's settings file.
  uninstall  Remove every lore-installed hook entry, preserving non-lore.
  smoke      Print Lore lifecycle event -> native hook mapping for
             the active framework (claude-code only).

Refer to adapters/hooks/README.md for the full hook adapter contract.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: install, uninstall, smoke)" >&2
    exit 1
    ;;
esac
