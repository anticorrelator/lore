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
#   rewake-entry
#              Render the Stop-hook entry that re-invokes a session at
#              every turn boundary (`lore coordinate arm` composes the
#              command; this subcommand owns the Claude Code shape).
#   rewake-install / rewake-uninstall
#              Write or remove that entry in a caller-named settings
#              file. The file is never defaulted: it decides which
#              sessions get armed.
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

TARGET_FRAMEWORK=""

parse_adapter_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --framework)
        [[ $# -lt 2 ]] && { echo "Error: --framework requires a value" >&2; return 1; }
        TARGET_FRAMEWORK="$2"
        shift 2
        ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1
        ;;
    esac
  done
}

# --- Resolve settings.json target ---
# Active framework MUST be claude-code for this adapter; install callers pass
# --framework and runtime callers resolve from Claude Code markers or
# LORE_FRAMEWORK.
require_claude_code() {
  local active
  active="${TARGET_FRAMEWORK:-}"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework 2>/dev/null) || active=""
  fi
  if [[ "$active" != "claude-code" ]]; then
    echo "Error: adapters/hooks/claude-code.sh requires active framework=claude-code (got '$active')" >&2
    echo "       pass --framework claude-code or set LORE_FRAMEWORK=claude-code for this process" >&2
    return 1
  fi
}

resolve_settings_path() {
  local settings_path
  if ! settings_path=$(resolve_harness_install_path settings "${TARGET_FRAMEWORK:-}" 2>/dev/null); then
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
# Every command carries the LORE_FRAMEWORK=claude-code prefix. framework.json
# holds a single framework string (last install wins), so on a multi-harness
# install every hook that resolved through it would route to whichever harness
# installed last. lib.sh::resolve_active_framework reads LORE_FRAMEWORK ahead of
# framework.json, so the prefix is what pins these hooks to claude-code's own
# capability profile. TUI launch preference is not process truth either, so a
# later install for another harness cannot redirect these commands.
lore_hooks = [
    # doctor.sh moved to TUI startup (tui/update.go::Model.Init via runDoctor) —
    # keeps drift checks attached to the lore surface that can act on them
    # instead of every claude-code session, including non-lore ones.
    # Timeouts: store-scaling SessionStart hooks get 15s, not 5s. Their
    # runtime grows with store size, and a hook timeout kills the payload
    # SILENTLY — at ~1,600 indexed files load-knowledge.sh (7.8s pre-
    # optimization) and auto-reindex.sh (5.6s) both exceeded 5s, so sessions
    # started with no knowledge context and no error anywhere. load-knowledge
    # also self-limits via LORE_LOAD_KNOWLEDGE_TIME_BUDGET (graceful
    # degradation before the cliff).
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/auto-reindex.sh", 15),
    # mine-retrieval-misses and packet-assess run before load-knowledge so
    # candidates they write (directly, or via the assessor's missing[]
    # hand-off to the miner) are counted by load-knowledge.sh's [capture]
    # trigger in the same session start.
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code python3 ~/.lore/scripts/mine-retrieval-misses.py", 10),
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code python3 ~/.lore/scripts/packet-assess.py", 10),
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/load-knowledge.sh", 15),
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/load-threads.sh", 15),
    ("SessionStart", None, "command", "LORE_FRAMEWORK=claude-code python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/pre-compact.sh", 5),
    ("TaskCompleted", None, "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/task-completed-capture-check.sh", 10),
    ("PreToolUse",   "Write", "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/guard-work-writes.sh", 5),
    ("PreToolUse",   "Agent", "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook claude-code", 5),
    ("SessionEnd",   "clear", "command", "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/pre-compact.sh", 5),
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

# --- Subcommands: rewake-entry / rewake-install / rewake-uninstall ---
#
# Claude Code's Stop hook can carry `asyncRewake: true`, which runs the command
# in the background while the session sits idle and, on exit 2, enqueues the
# command's stderr as a notification that starts the next turn. Ending that turn
# fires Stop again, so one installed entry keeps re-arming whatever the command
# is — that is the whole arm-once primitive, and its shape lives here rather
# than in the caller because it is Claude Code's, not lore's.
#
# `timeout` is seconds and is not optional for this entry: the harness SIGTERMs
# the command at it, a signalled command exits 143, and 143 is not the exit code
# that enqueues anything. So a hook that outlives its timeout ends the chain and
# reports nothing. The caller is responsible for a command that finishes first;
# this subcommand refuses an entry with no timeout at all.

REWAKE_COMMAND=""
REWAKE_TIMEOUT=""
REWAKE_MESSAGE=""
REWAKE_SETTINGS=""

parse_rewake_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --framework)
        [[ $# -lt 2 ]] && { echo "Error: --framework requires a value" >&2; return 1; }
        TARGET_FRAMEWORK="$2"; shift 2 ;;
      --command)
        [[ $# -lt 2 ]] && { echo "Error: --command requires a value" >&2; return 1; }
        REWAKE_COMMAND="$2"; shift 2 ;;
      --timeout)
        [[ $# -lt 2 ]] && { echo "Error: --timeout requires a value" >&2; return 1; }
        REWAKE_TIMEOUT="$2"; shift 2 ;;
      --message)
        [[ $# -lt 2 ]] && { echo "Error: --message requires a value" >&2; return 1; }
        REWAKE_MESSAGE="$2"; shift 2 ;;
      --settings)
        [[ $# -lt 2 ]] && { echo "Error: --settings requires a value" >&2; return 1; }
        REWAKE_SETTINGS="$2"; shift 2 ;;
      *)
        echo "Error: unexpected argument '$1'" >&2
        return 1 ;;
    esac
  done
}

require_rewake_payload() {
  [[ -n "$REWAKE_COMMAND" ]] || { echo "Error: rewake entry requires --command" >&2; return 1; }
  [[ "$REWAKE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "Error: rewake entry requires --timeout <seconds> as a positive integer; the harness kills the hook at it and a killed hook cannot re-arm" >&2
    return 1
  }
}

render_rewake_entry() {
  python3 - "$REWAKE_COMMAND" "$REWAKE_TIMEOUT" "$REWAKE_MESSAGE" <<'PYEOF'
import json, sys

command, timeout, message = sys.argv[1], int(sys.argv[2]), sys.argv[3]
hook = {
    "type": "command",
    "command": command,
    "timeout": timeout,
    "asyncRewake": True,
}
if message:
    hook["rewakeMessage"] = message
print(json.dumps({"hooks": [hook]}, indent=2, ensure_ascii=False))
PYEOF
}

cmd_rewake_entry() {
  require_claude_code
  require_rewake_payload
  render_rewake_entry
}

# The marker is the command's own script path: `lore coordinate arm` is the only
# writer of a Stop entry pointing at coordinate-arm.sh, so replacing on that
# substring re-arms in place instead of stacking a second watcher per call.
#
# The marker matches on the script and not on the seat, so the replace drops an
# entry another seat armed into this file just as readily as it drops a stale one
# of the caller's own. Install therefore prints what it removed — one line per
# displaced entry, on stdout, for the arming surface to pass on. A settings file
# holds one watcher entry; whoever arms into a shared one is switching off
# somebody's eye and should hear about it.
REWAKE_MARKER="coordinate-arm.sh"

cmd_rewake_install() {
  require_claude_code
  require_rewake_payload
  [[ -n "$REWAKE_SETTINGS" ]] || {
    echo "Error: rewake-install requires --settings <path>; the settings file decides which sessions get armed, so it is never defaulted" >&2
    return 1
  }
  mkdir -p "$(dirname "$REWAKE_SETTINGS")"
  local entry
  entry="$(render_rewake_entry)"
  python3 - "$REWAKE_SETTINGS" "$REWAKE_MARKER" "$entry" <<'PYEOF'
import json, os, shlex, sys

settings_path, marker, entry_json = sys.argv[1], sys.argv[2], sys.argv[3]
entry = json.loads(entry_json)

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})


def watcher_commands(hook_entry):
    return [
        h.get("command", "") for h in hook_entry.get("hooks", [])
        if marker in h.get("command", "")
    ]


def describe(command):
    """Who a displaced entry was watching for, read off its own command line."""
    argv = shlex.split(command)
    owner, arcs = "", []
    for i, token in enumerate(argv):
        if i + 1 >= len(argv):
            break
        if token in ("--owner-pid", "--owner-tmux"):
            owner = "%s %s" % (token[len("--owner-"):], argv[i + 1])
        elif token == "--arc":
            arcs.append(argv[i + 1])
    scope = "arc " + ", ".join(arcs) if arcs else "the whole board"
    return "owner %s, scope %s" % (owner or "unnamed", scope)


displaced = [c for e in hooks.get("Stop", []) for c in watcher_commands(e)]
stop = [e for e in hooks.get("Stop", []) if not watcher_commands(e)]
stop.append(entry)
hooks["Stop"] = stop
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

for command in displaced:
    print("replaced a watcher entry already in %s (%s)" % (settings_path, describe(command)))
PYEOF
}

cmd_rewake_uninstall() {
  require_claude_code
  [[ -n "$REWAKE_SETTINGS" ]] || {
    echo "Error: rewake-uninstall requires --settings <path>" >&2
    return 1
  }
  [[ -f "$REWAKE_SETTINGS" ]] || return 0
  python3 - "$REWAKE_SETTINGS" "$REWAKE_MARKER" <<'PYEOF'
import json, sys

settings_path, marker = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
stop = [
    e for e in hooks.get("Stop", [])
    if not any(marker in h.get("command", "") for h in e.get("hooks", []))
]
if stop:
    hooks["Stop"] = stop
else:
    hooks.pop("Stop", None)
if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

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
  printf '  %-20s %-9s %s\n' session_start      full      "SessionStart hook (~/.lore/scripts/{auto-reindex,mine-retrieval-misses,packet-assess,load-knowledge,load-work,load-threads,extract-session-digest}); doctor.sh runs from TUI startup instead"
  printf '  %-20s %-9s %s\n' user_prompt        full      "(no native UserPromptSubmit hook today; PreToolUse Write matcher covers lore writes)"
  printf '  %-20s %-9s %s\n' pre_tool           full      "PreToolUse hooks (Write guard; Agent -> validate-dispatch-guidance.sh)"
  printf '  %-20s %-9s %s\n' post_tool          full      "(currently unused by lore; PostToolUse hook surface available)"
  printf '  %-20s %-9s %s\n' permission_request full      "PreToolUse JSON-stdout decision protocol (no separate lore handler)"
  printf '  %-20s %-9s %s\n' pre_compact        full      "PreCompact hook (~/.lore/scripts/pre-compact.sh)"
  printf '  %-20s %-9s %s\n' stop               full      "(no Stop hook in the standard install; \`lore coordinate arm\` installs an asyncRewake entry into a settings file the caller names)"
  printf '  %-20s %-9s %s\n' session_end        full      "SessionEnd hook (matcher=clear -> pre-compact.sh)"
  printf '  %-20s %-9s %s\n' task_completed     full      "TaskCompleted hook (task-completed-capture-check.sh, exit-2 blocking)"
}

# --- Dispatch ---
cmd="${1:-}"
case "$cmd" in
  install)   shift; parse_adapter_args "$@"; cmd_install ;;
  uninstall) shift; parse_adapter_args "$@"; cmd_uninstall ;;
  smoke)     shift; parse_adapter_args "$@"; cmd_smoke ;;
  rewake-entry)     shift; parse_rewake_args "$@"; cmd_rewake_entry ;;
  rewake-install)   shift; parse_rewake_args "$@"; cmd_rewake_install ;;
  rewake-uninstall) shift; parse_rewake_args "$@"; cmd_rewake_uninstall ;;
  -h|--help|"")
    cat <<EOF >&2
Usage: $(basename "$0") <subcommand> [--framework claude-code]

Subcommands:
  install    Inject lore hooks into the active framework's settings file.
  uninstall  Remove every lore-installed hook entry, preserving non-lore.
  smoke      Print Lore lifecycle event -> native hook mapping for
             the active framework (claude-code only).
  rewake-entry --command <cmd> --timeout <sec> [--message <text>]
             Print the asyncRewake Stop entry for that command.
  rewake-install --settings <path> --command <cmd> --timeout <sec> [--message <text>]
             Write that entry into the named settings file, replacing any
             entry already armed there. A later 'install' rewrites the
             lore-managed hooks in that file and drops the armed entry, so
             re-arm after installing.
  rewake-uninstall --settings <path>
             Remove the armed entry from that settings file.

Refer to adapters/hooks/README.md for the full hook adapter contract.
EOF
    [[ -z "$cmd" ]] && exit 1 || exit 0
    ;;
  *)
    echo "Error: unknown subcommand '$cmd' (allowed: install, uninstall, smoke, rewake-entry, rewake-install, rewake-uninstall)" >&2
    exit 1
    ;;
esac
