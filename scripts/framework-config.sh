#!/usr/bin/env bash
# framework-config.sh — Read the persisted lore framework configuration
# Usage: framework-config.sh <subcommand> [args...]
#
# Subcommands:
#   framework                    Print the active framework name (e.g. claude-code).
#   role <role>                  Print the model bound to <role>. Returns the
#                                explicit binding if present; otherwise the
#                                "default" role; otherwise exits non-zero.
#   roles                        Print the full role->model map as JSON.
#   capability-overrides         Print the capability_overrides object as JSON.
#   show                         Print the entire config as JSON (machine-readable).
#   path                         Print the absolute path to framework.json.
#
# Reads $LORE_DATA_DIR/config/framework.json. T6 owns the lib.sh-side
# resolve_model_for_role helper with full env/per-repo precedence; this script
# is the cli/lore-side reader and intentionally surfaces the persisted file
# directly without consulting env overrides — operators inspecting "what is
# configured?" should see the configured value, not whatever transient env
# vars are in effect.
#
# Exits non-zero with an actionable message when framework.json is missing
# (operator should run `bash install.sh`) or malformed (operator should
# inspect and re-run install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CONFIG_PATH="${LORE_DATA_DIR}/config/framework.json"

usage() {
  cat >&2 <<EOF
framework-config.sh — read persisted lore framework configuration

Usage: framework-config.sh <subcommand> [args...]

Subcommands:
  framework                  Print the active framework name
  role <role>                Print the model bound to <role>; falls back to "default"
  roles                      Print the role->model map as JSON
  capability-overrides       Print capability_overrides as JSON
  show                       Print the entire config as JSON
  path                       Print the absolute path to framework.json

Options:
  --help, -h    Show this help

Config path: \$LORE_DATA_DIR/config/framework.json
EOF
}

require_config() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    cat >&2 <<EOF
Error: framework config not found at $CONFIG_PATH

Run \`bash install.sh\` (optionally with --framework <name>) to create it.
EOF
    exit 1
  fi
  # Fail fast with a readable error if the file is unparseable, rather than
  # letting individual subcommand python heredocs each emit a traceback.
  python3 - "$CONFIG_PATH" <<'PYEOF' || exit 3
import json, sys
try:
    with open(sys.argv[1]) as f:
        json.load(f)
except json.JSONDecodeError as e:
    print(f"Error: framework config at {sys.argv[1]} is not valid JSON: {e}", file=sys.stderr)
    print(f"Inspect the file or re-run install.sh to overwrite the framework field.", file=sys.stderr)
    sys.exit(3)
PYEOF
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  --help|-h)
    usage
    exit 0
    ;;
  path)
    echo "$CONFIG_PATH"
    ;;
  framework)
    require_config
    python3 - "$CONFIG_PATH" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
fw = cfg.get("framework")
if not isinstance(fw, str) or not fw:
    print("Error: framework field missing or invalid in config", file=sys.stderr)
    sys.exit(2)
print(fw)
PYEOF
    ;;
  role)
    if [[ $# -lt 2 ]]; then
      echo "Usage: framework-config.sh role <role>" >&2
      exit 1
    fi
    require_config
    ROLE="$2" python3 - "$CONFIG_PATH" <<'PYEOF'
import json, os, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
roles = cfg.get("roles") or {}
role = os.environ["ROLE"]
# Explicit binding wins; otherwise fall back to "default"; otherwise no answer.
if role in roles:
    print(roles[role])
elif "default" in roles:
    print(roles["default"])
else:
    print(f"Error: role '{role}' has no binding and no default fallback in config", file=sys.stderr)
    sys.exit(2)
PYEOF
    ;;
  roles)
    require_config
    python3 - "$CONFIG_PATH" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
print(json.dumps(cfg.get("roles") or {}, indent=2))
PYEOF
    ;;
  capability-overrides)
    require_config
    python3 - "$CONFIG_PATH" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
print(json.dumps(cfg.get("capability_overrides") or {}, indent=2))
PYEOF
    ;;
  show)
    require_config
    python3 - "$CONFIG_PATH" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
print(json.dumps(cfg, indent=2))
PYEOF
    ;;
  *)
    echo "Error: unknown framework-config subcommand '$1'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
