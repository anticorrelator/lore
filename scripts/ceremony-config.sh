#!/usr/bin/env bash
# ceremony-config.sh — Manage ceremony advisor overrides
# Usage: ceremony-config.sh <subcommand> [args...]
#
# Subcommands:
#   get <ceremony>                Get advisor list for a ceremony (JSON array, [] if absent)
#   add <ceremony> <skill>        Add an advisor to a ceremony (idempotent)
#   remove <ceremony> <skill>     Remove an advisor from a ceremony (no-op if absent)
#   list                          List all configured ceremonies (JSON object)
#
# All mutation commands return the updated entity state as JSON.
# Config is stored at $LORE_DATA_DIR/ceremonies.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CONFIG_PATH=$(resolve_ceremony_config_path)

usage() {
  cat >&2 <<EOF
ceremony-config.sh — manage ceremony advisor overrides

Usage: ceremony-config.sh <subcommand> [args...]

Subcommands:
  get <ceremony>                    Get advisor list (JSON array)
  add <ceremony> <skill>            Add an advisor (idempotent)
  remove <ceremony> <skill>         Remove an advisor (no-op if absent)
  list                              List all configured ceremonies (JSON)

Options:
  --help, -h    Show this help
EOF
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
  get)
    shift
    if [[ $# -lt 1 ]]; then
      echo "Usage: ceremony-config.sh get <ceremony>" >&2
      exit 1
    fi
    CEREMONY="$1"
    python3 -c "
import json, sys, os

config_path = sys.argv[1]
ceremony = sys.argv[2]

if not os.path.exists(config_path):
    print('[]')
    sys.exit(0)

with open(config_path) as f:
    data = json.load(f)

print(json.dumps(data.get(ceremony, [])))
" "$CONFIG_PATH" "$CEREMONY"
    ;;
  add)
    shift
    if [[ $# -lt 2 ]]; then
      echo "Usage: ceremony-config.sh add <ceremony> <skill>" >&2
      exit 1
    fi
    CEREMONY="$1"
    SKILL="$2"
    python3 -c "
import json, sys, os

config_path = sys.argv[1]
ceremony = sys.argv[2]
skill = sys.argv[3]

data = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        data = json.load(f)

advisors = data.get(ceremony, [])
if skill not in advisors:
    advisors.append(skill)
data[ceremony] = advisors

tmp_path = config_path + '.tmp'
with open(tmp_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
os.rename(tmp_path, config_path)

print(json.dumps(data[ceremony]))
" "$CONFIG_PATH" "$CEREMONY" "$SKILL"
    ;;
  remove)
    shift
    if [[ $# -lt 2 ]]; then
      echo "Usage: ceremony-config.sh remove <ceremony> <skill>" >&2
      exit 1
    fi
    CEREMONY="$1"
    SKILL="$2"
    python3 -c "
import json, sys, os

config_path = sys.argv[1]
ceremony = sys.argv[2]
skill = sys.argv[3]

data = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        data = json.load(f)

advisors = data.get(ceremony, [])
if skill in advisors:
    advisors.remove(skill)
data[ceremony] = advisors

# Remove ceremony key if empty
if not data[ceremony]:
    del data[ceremony]

tmp_path = config_path + '.tmp'
with open(tmp_path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
os.rename(tmp_path, config_path)

print(json.dumps(advisors))
" "$CONFIG_PATH" "$CEREMONY" "$SKILL"
    ;;
  list)
    shift
    python3 -c "
import json, sys, os

config_path = sys.argv[1]

if not os.path.exists(config_path):
    print('{}')
    sys.exit(0)

with open(config_path) as f:
    data = json.load(f)

print(json.dumps(data, indent=2))
" "$CONFIG_PATH"
    ;;
  *)
    echo "Error: unknown subcommand '$1'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
