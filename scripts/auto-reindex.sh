#!/usr/bin/env bash
# auto-reindex.sh — Incrementally reindex knowledge store before session load
# Called as first SessionStart hook. Silent on success, prints on error.
# Must complete within 5 seconds (hook timeout).

set -euo pipefail

SCRIPT_NAME="auto-reindex"

# Hook failure diagnostic trap
trap 'echo "[hook] $SCRIPT_NAME: Failed at line $LINENO with exit code $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the knowledge directory for the current project
KNOWLEDGE_DIR="$("${SCRIPT_DIR}/resolve-repo.sh" 2>/dev/null)"

# If the knowledge directory doesn't exist yet, nothing to index
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  exit 0
fi

# Auto-discover repo root for source file indexing
REPO_ROOT_ARGS=()
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  REPO_ROOT_ARGS=(--repo-root "$REPO_ROOT")
fi

# Run incremental index, suppress stdout on success, show stderr on error
if ! python3 "${SCRIPT_DIR}/pk_cli.py" incremental-index "$KNOWLEDGE_DIR" "${REPO_ROOT_ARGS[@]}" >/dev/null 2>&1; then
  echo "[auto-reindex] Failed to reindex: $KNOWLEDGE_DIR" >&2
  # Non-fatal: exit 0 so the hook chain continues
  exit 0
fi

# Keep the assembled instructions file fresh (same charter as the index: a
# derived artifact rebuilt at session start, never left to a manual step).
# --check compares the sentinel region against the fragments byte-for-byte;
# the rebuild is deterministic, atomic, and sentinel-scoped, so running it
# unattended cannot touch content outside the lore region. The current
# session already loaded the old file — freshness lands next session, which
# bounds drift at one session instead of "until someone runs lore assemble".
ASSEMBLE="${SCRIPT_DIR}/assemble-instructions.sh"
if [[ -f "$ASSEMBLE" ]]; then
  if ! bash "$ASSEMBLE" --check >/dev/null 2>&1; then
    if bash "$ASSEMBLE" >/dev/null 2>&1; then
      echo "[auto-reindex] Assembled instructions were stale — rebuilt from fragments (takes effect next session)"
    else
      echo "[auto-reindex] Assembled instructions are stale and rebuild failed; run: lore assemble" >&2
    fi
  fi
fi
