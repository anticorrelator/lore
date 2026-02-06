#!/usr/bin/env bash
# resolve-repo.sh — Resolves CWD to a knowledge directory path
# Usage: bash resolve-repo.sh [directory]
# Output: absolute path to the knowledge directory for this repo

set -euo pipefail

BASE_DIR="${HOME}/.project-knowledge/repos"
TARGET_DIR="${1:-$(pwd)}"

# Try to get git remote URL
if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
  REMOTE_URL=$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || echo "")

  if [[ -n "$REMOTE_URL" ]]; then
    # Normalize the remote URL
    NORMALIZED="$REMOTE_URL"

    # Strip protocol (https://, http://, git://)
    NORMALIZED="${NORMALIZED#https://}"
    NORMALIZED="${NORMALIZED#http://}"
    NORMALIZED="${NORMALIZED#git://}"

    # Strip SSH user prefix (git@)
    NORMALIZED="${NORMALIZED#*@}"

    # Convert SSH colon to slash (github.com:user/repo -> github.com/user/repo)
    NORMALIZED=$(echo "$NORMALIZED" | sed 's|:|/|')

    # Strip .git suffix
    NORMALIZED="${NORMALIZED%.git}"

    # Strip trailing slash
    NORMALIZED="${NORMALIZED%/}"

    # Strip auth credentials (user:pass@host -> host)
    if [[ "$NORMALIZED" == *"@"* ]]; then
      NORMALIZED="${NORMALIZED#*@}"
    fi

    # Lowercase
    NORMALIZED=$(echo "$NORMALIZED" | tr '[:upper:]' '[:lower:]')

    # Compute paths
    REMOTE_PATH="${BASE_DIR}/${NORMALIZED}"
    REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
    REPO_NAME=$(basename "$REPO_ROOT")
    LOCAL_PATH="${BASE_DIR}/local/${REPO_NAME}"

    # Check for existing knowledge stores
    # Prefer local path if it has data but remote path doesn't (migration case)
    if [[ ! -f "${REMOTE_PATH}/_index.md" ]] && [[ -f "${LOCAL_PATH}/_index.md" ]]; then
      # Knowledge found at local path, not remote path — use local
      echo "[resolve-repo] Warning: Knowledge found at local path, not remote path." >&2
      echo "  Local: repos/local/${REPO_NAME}" >&2
      echo "  Remote: repos/${NORMALIZED}" >&2
      echo "  Using local path. Run migration to consolidate." >&2
      echo "${LOCAL_PATH}"
    else
      # Default: use remote path (either has data or is new repo)
      echo "${REMOTE_PATH}"
    fi
    exit 0
  fi

  # Fallback: git repo without remote
  REPO_ROOT=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null)
  REPO_NAME=$(basename "$REPO_ROOT")
  echo "${BASE_DIR}/local/${REPO_NAME}"
  exit 0
fi

# Fallback: not a git repo
DIR_NAME=$(basename "$TARGET_DIR")
echo "${BASE_DIR}/local/${DIR_NAME}"
