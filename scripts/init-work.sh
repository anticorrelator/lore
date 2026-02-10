#!/usr/bin/env bash
# init-work.sh — Create _work/ scaffold for a repo
# Usage: bash init-work.sh [directory]
# Creates _work/ directory with _index.json and _archive/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR"
  echo "Run \`/memory init\` first."
  exit 1
fi

WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ -f "$WORK_DIR/_index.json" ]]; then
  echo "Work directory already initialized at: $WORK_DIR"
  exit 0
fi

REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$WORK_DIR/_archive"

cat > "$WORK_DIR/_index.json" << INDEXEOF
{
  "version": 1,
  "repo": "$REPO_NAME",
  "last_updated": "$TIMESTAMP",
  "plans": []
}
INDEXEOF

echo "Initialized work directory at: $WORK_DIR"
