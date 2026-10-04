#!/usr/bin/env bash
# claude-code-mod-install.sh — add or remove lore's Claude Code mod in the
# CLAUDE_CODE_PLUGIN_DIRS value of Claude Code's user settings env block.
#
# Usage: bash claude-code-mod-install.sh <enable|disable> [--settings <path>] [--plugin-dir <path>]
#
# That env block is where both the Claude Code CLI and the desktop app read
# plugin folders from. The value is a ':'-separated list; enable appends the
# mod's folder unless it is already listed, disable removes it, and every other
# entry is kept in order. A run that changes nothing leaves the file untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  claude-code-mod-install.sh <enable|disable> [--settings <path>] [--plugin-dir <path>]

Adds (enable) or removes (disable) lore's Claude Code mod folder in the
env.CLAUDE_CODE_PLUGIN_DIRS value of Claude Code's user settings.

Options:
  --settings <path>    Settings file (default: Claude Code's user settings.json).
  --plugin-dir <path>  Mod folder (default: adapters/claude-code-mod in this checkout).
  --help, -h           Show this help.
EOF
}

ACTION=""
SETTINGS_PATH=""
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)/adapters/claude-code-mod"

while [[ $# -gt 0 ]]; do
  case "$1" in
    enable|disable)
      [[ -z "$ACTION" ]] || { echo "Error: one action only" >&2; usage; exit 2; }
      ACTION="$1"; shift ;;
    --settings)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --settings needs a path" >&2; exit 2; }
      SETTINGS_PATH="$2"; shift 2 ;;
    --plugin-dir)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Error: --plugin-dir needs a path" >&2; exit 2; }
      PLUGIN_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unexpected argument '$1'" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 2; }

if [[ -z "$SETTINGS_PATH" ]]; then
  SETTINGS_PATH="$(resolve_harness_install_path settings claude-code)"
  if [[ "$SETTINGS_PATH" == "unsupported" ]]; then
    echo "Error: install_paths.settings is 'unsupported' for claude-code" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$SETTINGS_PATH")"

python3 - "$SETTINGS_PATH" "$ACTION" "$PLUGIN_DIR" <<'PYEOF'
import fcntl, json, os, sys, tempfile

settings_path = os.path.realpath(sys.argv[1])
action = sys.argv[2]
plugin_dir = sys.argv[3]
key = "CLAUDE_CODE_PLUGIN_DIRS"

# The same lock adapters/hooks/claude-code.sh takes, so the two writers of this
# file never interleave a read and a replace.
lock = open(settings_path + ".lore.lock", "a+")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        raw = f.read()
    if raw.strip():
        settings = json.loads(raw)

env = settings.get("env")
if env is None:
    env = {}
if not isinstance(env, dict):
    sys.exit(f"Error: {settings_path}: env is not an object")
current = env.get(key, "")
if not isinstance(current, str):
    sys.exit(f"Error: {settings_path}: env.{key} is not a string")

entries = [entry for entry in current.split(":") if entry]
if action == "enable":
    wanted = entries if plugin_dir in entries else entries + [plugin_dir]
else:
    wanted = [entry for entry in entries if entry != plugin_dir]

if wanted == entries:
    print(f"[claude-code-mod] {action}: {settings_path} already {'lists' if action == 'enable' else 'omits'} {plugin_dir}")
    sys.exit(0)

if wanted:
    env[key] = ":".join(wanted)
else:
    env.pop(key, None)
if env:
    settings["env"] = env
else:
    settings.pop("env", None)

existing_mode = os.stat(settings_path).st_mode & 0o777 if os.path.exists(settings_path) else None
fd, temporary = tempfile.mkstemp(prefix=".tmp.settings.", dir=os.path.dirname(settings_path))
try:
    if existing_mode is not None:
        os.fchmod(fd, existing_mode)
    with os.fdopen(fd, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(temporary, settings_path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
print(f"[claude-code-mod] {action}: {plugin_dir} in {settings_path} env.{key}")
PYEOF
