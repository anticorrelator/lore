#!/usr/bin/env bash
# scale-registry.sh — thin reader CLI for scripts/scale-registry.json
#
# Usage:
#   scale-registry.sh get-version
#   scale-registry.sh get-label [--version N] <id>
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
  get-version              Print registry version integer
  get-label [--version N] <id>
                           Print current label for id, or historical label at version N
  get-ids                  Print ordered scale ids (one per line)
  get-adjacency <id>       Print id-below and id-above (empty line when no neighbor)
  relabel <id> --new-label <label>
                           Rename a scale's label; bumps version and appends to label_history
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
    VERSION=""
    ID=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) ID="$1"; shift ;;
      esac
    done
    if [[ -z "$ID" ]]; then
      echo "Error: get-label requires <id>" >&2
      usage
      exit 1
    fi
    python3 - "$REGISTRY" "$ID" "$VERSION" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
id_arg = sys.argv[2]
ver_arg = sys.argv[3]  # empty string if not provided

if ver_arg:
    target_ver = int(ver_arg)
    current_ver = reg["version"]
    # If asking for current version, fall through to labels map
    if target_ver == current_ver:
        labels = reg["labels"]
    else:
        # label_history entries record labels that were active *before* that version bump.
        # Entry with version=N holds labels that were active at version N-1 only.
        # To answer "what were the labels at target_ver?", look for the entry with
        # version == target_ver + 1 (the relabel that superseded target_ver).
        history = {e["version"]: e["labels"] for e in reg.get("label_history", [])}
        labels = history.get(target_ver + 1)
        if labels is None:
            # Only fall back to current labels when target_ver >= current version.
            # For target_ver < current version with no covering label_history entry,
            # the version is not represented in registry history — error out rather
            # than silently masking the gap with current labels.
            if target_ver >= current_ver:
                labels = reg["labels"]
            else:
                print(f"Error: version {target_ver} not represented in registry history", file=sys.stderr)
                sys.exit(1)
    if id_arg not in labels:
        print(f"Error: id '{id_arg}' not found in registry at version {target_ver}", file=sys.stderr)
        sys.exit(1)
    print(labels[id_arg])
else:
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
from datetime import datetime, timezone

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

history_entry = {
    "version": new_version,
    "relabeled_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "labels": dict(labels)
}
reg.setdefault("label_history", []).append(history_entry)

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
