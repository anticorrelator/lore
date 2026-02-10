#!/usr/bin/env bash
# annotate.sh — Record a friction annotation to the knowledge store
# Usage: lore annotate --intent "..." --outcome found|found_but_unhelpful|not_found [--friction "..."]
#
# Appends a JSONL entry to _meta/friction-log.jsonl for later analysis
# by the renormalize pipeline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
INTENT=""
OUTCOME=""
FRICTION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --intent)
      INTENT="$2"
      shift 2
      ;;
    --outcome)
      OUTCOME="$2"
      shift 2
      ;;
    --friction)
      FRICTION="$2"
      shift 2
      ;;
    --help|-h)
      cat >&2 <<EOF
Usage: lore annotate --intent "..." --outcome found|found_but_unhelpful|not_found [--friction "..."]

Options:
  --intent     What the user/agent was looking for (required)
  --outcome    Retrieval outcome: found, found_but_unhelpful, not_found (required)
  --friction   Description of the friction encountered (optional)
  --help, -h   Show this help
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: lore annotate --intent \"...\" --outcome found|found_but_unhelpful|not_found [--friction \"...\"]" >&2
      exit 1
      ;;
  esac
done

# --- Validate required args ---
if [[ -z "$INTENT" ]]; then
  die "--intent is required"
fi

if [[ -z "$OUTCOME" ]]; then
  die "--outcome is required"
fi

# --- Validate outcome value ---
case "$OUTCOME" in
  found|found_but_unhelpful|not_found) ;;
  *)
    die "--outcome must be one of: found, found_but_unhelpful, not_found (got: $OUTCOME)"
    ;;
esac

# --- Resolve knowledge directory ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)

# --- Verify knowledge store exists ---
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  die "No knowledge store found at: $KNOWLEDGE_DIR. Run \`lore init\` to initialize one."
fi

# --- Ensure _meta/ directory exists ---
META_DIR="$KNOWLEDGE_DIR/_meta"
mkdir -p "$META_DIR"

# --- Build JSONL entry ---
TIMESTAMP=$(timestamp_iso)

# Use python3 for safe JSON serialization (avoids quoting issues with bash)
ENTRY=$(python3 -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'intent': sys.argv[2],
    'outcome': sys.argv[3],
}
if sys.argv[4]:
    entry['friction'] = sys.argv[4]
print(json.dumps(entry, ensure_ascii=False))
" "$TIMESTAMP" "$INTENT" "$OUTCOME" "$FRICTION")

# --- Append to friction log ---
LOGFILE="$META_DIR/friction-log.jsonl"
echo "$ENTRY" >> "$LOGFILE"

echo "[annotate] Recorded friction annotation: outcome=$OUTCOME"
