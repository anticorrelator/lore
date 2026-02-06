#!/usr/bin/env bash
# init-plans.sh — Create _plans/ scaffold for a repo
# Usage: bash init-plans.sh [directory]
# Creates _plans/ directory with _index.json and _archive/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "No knowledge store found at: $KNOWLEDGE_DIR"
  echo "Run \`/knowledge init\` first."
  exit 1
fi

PLANS_DIR="$KNOWLEDGE_DIR/_plans"

if [[ -f "$PLANS_DIR/_index.json" ]]; then
  echo "Plans already initialized at: $PLANS_DIR"
  exit 0
fi

REPO_NAME=$(basename "$KNOWLEDGE_DIR")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

mkdir -p "$PLANS_DIR/_archive"

cat > "$PLANS_DIR/_index.json" << INDEXEOF
{
  "version": 1,
  "repo": "$REPO_NAME",
  "last_updated": "$TIMESTAMP",
  "plans": []
}
INDEXEOF

echo "Initialized plans at: $PLANS_DIR"
