#!/usr/bin/env bash
# auto-reindex.sh — Incrementally reindex knowledge store before session load
# Called as first SessionStart hook. Silent on success, prints on error.
# Must complete within 5 seconds (hook timeout).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the knowledge directory for the current project
KNOWLEDGE_DIR="$("${SCRIPT_DIR}/resolve-repo.sh" 2>/dev/null)"

# If the knowledge directory doesn't exist yet, nothing to index
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  exit 0
fi

# Run incremental index, suppress stdout on success, show stderr on error
if ! python3 "${SCRIPT_DIR}/pk_cli.py" incremental-index "$KNOWLEDGE_DIR" >/dev/null 2>&1; then
  echo "[auto-reindex] Failed to reindex: $KNOWLEDGE_DIR" >&2
  # Non-fatal: exit 0 so the hook chain continues
  exit 0
fi
