#!/usr/bin/env bash
# init-repo.sh — Initialize knowledge structure for a repo
# Usage: bash init-repo.sh [directory]
# Creates _inbox.md, _index.md, _manifest.json, domains/ for the resolved repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$(pwd)}"

KNOWLEDGE_DIR=$("$SCRIPT_DIR/resolve-repo.sh" "$TARGET_DIR")

if [[ -f "$KNOWLEDGE_DIR/_index.md" ]]; then
  echo "Knowledge store already initialized at: $KNOWLEDGE_DIR"
  exit 0
fi

# Derive repo name from path
REPO_NAME=$(basename "$KNOWLEDGE_DIR")

mkdir -p "$KNOWLEDGE_DIR/domains"

# Create inbox
cat > "$KNOWLEDGE_DIR/_inbox.md" << 'EOF'
# Knowledge Inbox

<!-- Append new entries below this line. Each entry is processed during /knowledge organize. -->
EOF

# Create index
cat > "$KNOWLEDGE_DIR/_index.md" << INDEXEOF
# Knowledge Index: ${REPO_NAME}

## Core Files
- [[architecture]] - System design, component boundaries, tech stack
- [[conventions]] - Standards beyond linters, naming patterns
- [[abstractions]] - Core patterns, base classes, type hierarchies
- [[workflows]] - Build, test, deploy commands and patterns
- [[gotchas]] - Non-obvious pitfalls and debugging tips
- [[team]] - Inferred team conventions from PR feedback

## Domain Files
<!-- Domain files are created on-demand as deep subsystem knowledge accumulates -->
INDEXEOF

# Create manifest
cat > "$KNOWLEDGE_DIR/_manifest.json" << 'EOF'
{
  "version": 1,
  "repo": "",
  "files": [],
  "last_updated": ""
}
EOF

# Create empty category files with headers
for category in architecture conventions abstractions workflows gotchas team; do
  TITLE=$(echo "$category" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  cat > "$KNOWLEDGE_DIR/${category}.md" << CATEOF
# ${TITLE}

<!-- Entries are filed here by /knowledge organize. Use ### headings for individual entries. -->
CATEOF
done

echo "Initialized knowledge store at: $KNOWLEDGE_DIR"
