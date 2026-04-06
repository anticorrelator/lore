#!/usr/bin/env bash
# cache-branch.sh — Cache and retrieve branch-to-work-item slug associations
# Usage:
#   cache-branch.sh --write <slug>              Associate current branch with <slug>
#   cache-branch.sh --read [--branch <name>]    Print slug for current (or named) branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
MODE=""
SLUG=""
BRANCH_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write)
      MODE="write"
      SLUG="$2"
      shift 2
      ;;
    --read)
      MODE="read"
      shift
      ;;
    --branch)
      BRANCH_OVERRIDE="$2"
      shift 2
      ;;
    *)
      echo "[cache] Error: Unknown argument '$1'" >&2
      echo "Usage: cache-branch.sh --write <slug> | --read [--branch <name>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "[cache] Error: Must specify --write <slug> or --read" >&2
  echo "Usage: cache-branch.sh --write <slug> | --read [--branch <name>]" >&2
  exit 1
fi

# --- Resolve knowledge dir ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
CACHE_FILE="$KNOWLEDGE_DIR/_branch_cache.json"

# --- --read mode ---
if [[ "$MODE" == "read" ]]; then
  if [[ -n "$BRANCH_OVERRIDE" ]]; then
    TARGET_BRANCH="$BRANCH_OVERRIDE"
  else
    TARGET_BRANCH=$(get_git_branch)
    if [[ -z "$TARGET_BRANCH" ]]; then
      exit 1
    fi
  fi

  if [[ ! -f "$CACHE_FILE" ]]; then
    exit 1
  fi

  RESULT=$(python3 - "$CACHE_FILE" "$TARGET_BRANCH" <<'PYEOF'
import json, sys

cache_file = sys.argv[1]
branch = sys.argv[2]

try:
    with open(cache_file, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)

entry = data.get(branch)
if entry and isinstance(entry, dict) and entry.get("slug"):
    print(entry["slug"])
    sys.exit(0)

sys.exit(1)
PYEOF
) && echo "$RESULT" && exit 0 || exit 1
fi

# --- --write mode ---
if [[ -z "$SLUG" ]]; then
  echo "[cache] Error: --write requires a slug argument" >&2
  exit 1
fi

BRANCH=$(get_git_branch)

if [[ -z "$BRANCH" ]]; then
  echo "[cache] Error: not in a git repo" >&2
  exit 1
fi

# Skip silently on detached HEAD
if [[ "$BRANCH" == "HEAD" ]]; then
  exit 0
fi

TIMESTAMP=$(timestamp_iso)

# Get list of all branches from git
GIT_BRANCHES=$(git branch -a --format='%(refname:short)' 2>/dev/null | sed 's|^origin/||' | sort -u) || GIT_BRANCHES=""

python3 - "$CACHE_FILE" "$BRANCH" "$SLUG" "$TIMESTAMP" "$GIT_BRANCHES" <<'PYEOF'
import json, os, sys, tempfile

cache_file = sys.argv[1]
branch = sys.argv[2]
slug = sys.argv[3]
timestamp = sys.argv[4]
git_branches_raw = sys.argv[5]

# Parse the set of known branches
known_branches = set(b.strip() for b in git_branches_raw.splitlines() if b.strip())

# Load existing cache or start fresh
data = {}
if os.path.exists(cache_file):
    try:
        with open(cache_file, "r") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data = loaded
    except (json.JSONDecodeError, OSError):
        data = {}

# Upsert current entry
data[branch] = {"slug": slug, "timestamp": timestamp}

# Purge stale entries (branches not in git branch -a output)
if known_branches:
    stale = [b for b in list(data.keys()) if b not in known_branches]
    for b in stale:
        del data[b]

# Write atomically via temp file + rename
cache_dir = os.path.dirname(cache_file)
try:
    fd, tmp_path = tempfile.mkstemp(dir=cache_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
            f.write("\n")
    except Exception:
        os.unlink(tmp_path)
        raise
    os.replace(tmp_path, cache_file)
except Exception as e:
    print(f"[cache] Warning: failed to write cache: {e}", file=sys.stderr)
    sys.exit(1)

PYEOF

echo "[cache] Associated '$BRANCH' → '$SLUG'"
