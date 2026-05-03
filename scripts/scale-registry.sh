#!/usr/bin/env bash
# scale-registry.sh — thin reader CLI for scripts/scale-registry.json
#
# Usage:
#   scale-registry.sh get-version
#   scale-registry.sh get-label <id>
#   scale-registry.sh get-ids
#   scale-registry.sh get-adjacency <id>
#
# Exit codes:
#   0 — success
#   1 — usage/lookup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/scale-registry.json"

usage() {
  cat >&2 <<EOF
Usage: scale-registry.sh <subcommand> [args...]

Subcommands:
  get-version              Print registry revision counter (integer)
  get-label <id>           Print current label for id
  get-ids                  Print ordered scale ids (one per line)
  get-adjacency <id>       Print id-below and id-above (empty line when no neighbor)
  relabel <id> --new-label <label>
                           Rename a scale's label; bumps the registry revision counter
EOF
}

if [[ ! -f "$REGISTRY" ]]; then
  echo "Error: scale registry not found at $REGISTRY" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

subcmd="$1"
shift

case "$subcmd" in
  --help|-h)
    usage
    exit 0
    ;;

  get-version)
    python3 - "$REGISTRY" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
print(reg["version"])
EOF
    ;;

  get-label)
    if [[ $# -eq 0 ]]; then
      echo "Error: get-label requires <id>" >&2
      usage
      exit 1
    fi
    ID="$1"
    python3 - "$REGISTRY" "$ID" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
id_arg = sys.argv[2]
labels = reg["labels"]
if id_arg not in labels:
    print(f"Error: id '{id_arg}' not found in registry", file=sys.stderr)
    sys.exit(1)
print(labels[id_arg])
EOF
    ;;

  get-ids)
    python3 - "$REGISTRY" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
for entry in sorted(reg["scales"], key=lambda e: e["ordinal"]):
    print(entry["id"])
EOF
    ;;

  get-adjacency)
    if [[ $# -eq 0 ]]; then
      echo "Error: get-adjacency requires <id>" >&2
      usage
      exit 1
    fi
    ID="$1"
    python3 - "$REGISTRY" "$ID" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
id_arg = sys.argv[2]
scales = sorted(reg["scales"], key=lambda e: e["ordinal"])
ids = [e["id"] for e in scales]
if id_arg not in ids:
    print(f"Error: id '{id_arg}' not found in registry", file=sys.stderr)
    sys.exit(1)
idx = ids.index(id_arg)
below = ids[idx - 1] if idx > 0 else ""
above = ids[idx + 1] if idx < len(ids) - 1 else ""
print(below)
print(above)
EOF
    ;;

  relabel)
    ID=""
    NEW_LABEL=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --new-label) NEW_LABEL="$2"; shift 2 ;;
        *) ID="$1"; shift ;;
      esac
    done
    if [[ -z "$ID" || -z "$NEW_LABEL" ]]; then
      echo "Error: relabel requires <id> --new-label <label>" >&2
      usage
      exit 1
    fi
    python3 - "$REGISTRY" "$ID" "$NEW_LABEL" <<'EOF'
import json, sys

reg_path = sys.argv[1]
id_arg   = sys.argv[2]
new_label = sys.argv[3]

with open(reg_path) as f:
    reg = json.load(f)

labels = reg.get("labels", {})
if id_arg not in labels:
    print(f"Error: id '{id_arg}' not found in registry", file=sys.stderr)
    sys.exit(1)

old_label = labels[id_arg]
if old_label == new_label:
    print(f"No-op: '{id_arg}' label is already '{new_label}'")
    sys.exit(0)

old_version = reg["version"]
new_version = old_version + 1

reg["labels"][id_arg] = new_label
reg["version"] = new_version

import os, tempfile
dir_ = os.path.dirname(reg_path)
with tempfile.NamedTemporaryFile("w", dir=dir_, delete=False, suffix=".tmp") as tf:
    json.dump(reg, tf, indent=2)
    tf.write("\n")
    tmp_path = tf.name
os.replace(tmp_path, reg_path)

print(f"Relabeled '{id_arg}': '{old_label}' -> '{new_label}' (version {old_version} -> {new_version})")
EOF
    ;;

  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
