#!/usr/bin/env bash
# init-threads.sh — Create _threads/ scaffold for a repo
# Usage: bash init-threads.sh [directory]
# Creates _threads/ directory with _index.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR"
  echo "Run \`/memory init\` first."
  exit 1
fi

THREADS_DIR="$KNOWLEDGE_DIR/_threads"

if [[ -f "$THREADS_DIR/_index.json" ]]; then
  echo "Threads already initialized at: $THREADS_DIR"
  exit 0
fi

REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$THREADS_DIR"

cat > "$THREADS_DIR/_index.json" << INDEXEOF
{
  "version": 1,
  "repo": "$REPO_NAME",
  "last_updated": "$TIMESTAMP",
  "threads": []
}
INDEXEOF

echo "Initialized threads at: $THREADS_DIR"
