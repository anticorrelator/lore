#!/usr/bin/env bash
# kind-registry.sh — thin reader CLI for scripts/kind-registry.json
#
# The epistemic kind of a knowledge entry says what sort of claim it makes:
#   fact        A settled claim about how the system behaves. The default, and
#               what every entry written before this field existed is.
#   hypothesis  A belief nobody has settled yet. Carries a kind_status of
#               untested, supported, or refuted.
#   question    A recorded unknown. Carries a kind_status of open, answered, or
#               dissolved, and optionally where someone already looked and what
#               answered it.
#   theory      What a subsystem is, named by the subsystem field. Unlike the
#               other three, a theory is authored rather than observed during
#               exploration — the one deliberate exception to entries
#               originating from work rather than from documentation.
#
# Each kind declares its own footer fields and, where it has one, its own
# lifecycle vocabulary. Writers read those declarations from here instead of
# repeating them, so the vocabulary cannot fork between the writer and a
# later validator.
#
# Usage:
#   kind-registry.sh get-version
#   kind-registry.sh get-label <id>
#   kind-registry.sh get-ids
#   kind-registry.sh get-statuses <id>
#   kind-registry.sh get-fields <id>
#   kind-registry.sh get-required-fields <id>
#
# Exit codes:
#   0 — success
#   1 — usage/lookup error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$SCRIPT_DIR/kind-registry.json"

usage() {
  cat >&2 <<EOF
Usage: kind-registry.sh <subcommand> [args...]

Subcommands:
  get-version                 Print registry revision counter (integer)
  get-label <id>              Print current label for id
  get-ids                     Print ordered kind ids (one per line)
  get-statuses <id>           Print the kind's kind_status vocabulary (one per
                              line; empty when the kind has no lifecycle)
  get-fields <id>             Print every footer field the kind accepts
                              (required first, then optional; one per line)
  get-required-fields <id>    Print only the kind's required footer fields
EOF
}

if [[ ! -f "$REGISTRY" ]]; then
  echo "Error: kind registry not found at $REGISTRY" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

subcmd="$1"
shift

# Print a per-kind list field, one element per line. Shared by the three
# list-returning subcommands below; an unknown id is an error, an empty list
# is not.
emit_kind_list() {
  local id="$1"
  shift
  python3 - "$REGISTRY" "$id" "$@" <<'EOF'
import json, sys
reg = json.load(open(sys.argv[1]))
id_arg = sys.argv[2]
keys = sys.argv[3:]
by_id = {k["id"]: k for k in reg["kinds"]}
if id_arg not in by_id:
    print(f"Error: id '{id_arg}' not found in registry", file=sys.stderr)
    sys.exit(1)
for key in keys:
    for value in by_id[id_arg].get(key, []):
        print(value)
EOF
}

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
for entry in sorted(reg["kinds"], key=lambda e: e["ordinal"]):
    print(entry["id"])
EOF
    ;;

  get-statuses)
    if [[ $# -eq 0 ]]; then
      echo "Error: get-statuses requires <id>" >&2
      usage
      exit 1
    fi
    emit_kind_list "$1" kind_statuses
    ;;

  get-fields)
    if [[ $# -eq 0 ]]; then
      echo "Error: get-fields requires <id>" >&2
      usage
      exit 1
    fi
    emit_kind_list "$1" required_fields optional_fields
    ;;

  get-required-fields)
    if [[ $# -eq 0 ]]; then
      echo "Error: get-required-fields requires <id>" >&2
      usage
      exit 1
    fi
    emit_kind_list "$1" required_fields
    ;;

  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    exit 1
    ;;
esac
