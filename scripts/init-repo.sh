#!/usr/bin/env bash
# init-repo.sh — Initialize knowledge structure for a repo (format v2)
# Usage: bash init-repo.sh [--force] [directory]
# Creates _inbox/, _meta/, category directories, _manifest.json for the resolved repo
#
# Options:
#   --force   Allow initialization in non-git directories

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Parse arguments
FORCE=false
TARGET_DIR=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) TARGET_DIR="$arg" ;;
  esac
done
TARGET_DIR="${TARGET_DIR:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  echo "Knowledge store already initialized at: $KNOWLEDGE_DIR"
  exit 0
fi

# Gate: require --force for non-git directories
if ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
  if [[ "$FORCE" != true ]]; then
    echo "Error: Not inside a git repository." >&2
    echo "Use \`/memory init --force\` to create a knowledge store anyway." >&2
    exit 1
  fi
fi

# Create directory structure
mkdir -p "$KNOWLEDGE_DIR/_inbox"
mkdir -p "$KNOWLEDGE_DIR/_meta"
touch "$KNOWLEDGE_DIR/_meta/.gitkeep"

# Create category directories
for category in principles architecture conventions abstractions workflows gotchas domains team; do
  mkdir -p "$KNOWLEDGE_DIR/$category"
done

# Create manifest (format v2)
TIMESTAMP=$(timestamp_iso)
cat > "$KNOWLEDGE_DIR/_manifest.json" << MANIFESTEOF
{
  "format_version": 2,
  "repo": "$(basename "$KNOWLEDGE_DIR")",
  "last_updated": "$TIMESTAMP",
  "categories": {},
  "entries": []
}
MANIFESTEOF

echo "Initialized knowledge store at: $KNOWLEDGE_DIR"
