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
        # Find the label_history entry where the version transition covers target_ver.
        # label_history entries record labels that were active *before* that version bump.
        # Entry with version=N holds labels that were active at version N-1 (just before relabel).
        # We walk history in reverse to find the earliest entry whose version > target_ver.
        history = sorted(reg.get("label_history", []), key=lambda e: e["version"])
        labels = None
        for entry in history:
            if entry["version"] > target_ver:
                labels = entry["labels"]
                break
        if labels is None:
            # target_ver >= current version, use current labels
            labels = reg["labels"]
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

  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
