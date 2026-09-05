#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
exec python3 "$SCRIPT_DIR/packet_builder.py" --kdir "$(resolve_knowledge_dir)" "$@"
