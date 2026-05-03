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

# Seed default activity-vocab.yaml — only when it does not already exist, so
# a hand-authored project file is never overwritten on re-run.
if [[ ! -f "$KNOWLEDGE_DIR/_meta/activity-vocab.yaml" ]]; then
  cat > "$KNOWLEDGE_DIR/_meta/activity-vocab.yaml" << 'ACTIVITYVOCABEOF'
# Activity vocabulary config — path-glob -> activity-token list mapping
# consumed by /spec retrieval-directive activity-pass lookups (see
# `skills/spec/SKILL.md` §Per-topic decomposition / activity_vocab).
#
# Per-project map: file-path glob -> list of BM25 query tokens that name a
# recurring practice on files matching that glob (e.g. writing tests, emitting
# telemetry, mocking, capturing). Loader semantics:
#
#   - Caller (resolve-manifest.sh / pk_search.py) supplies the phase's owned
#     file set.
#   - Loader returns the union of token lists whose glob matches at least one
#     file in that set, deduplicated.
#   - Patterns matching zero files contribute nothing.
#   - Missing config (this file absent), an unmatched path, or an empty token
#     list is a no-op, not an error.
#   - Activity vocab is *attached to a topic* in a v2 retrieval directive; the
#     topic fires one extra BM25 OR query at the topic's declared scale_set
#     using these tokens (logged as `query_kind=activity`).
#
# Project-overridable: a downstream knowledge store may replace this file in
# its own `$KDIR/_meta/activity-vocab.yaml` to encode that project's testing
# stack, telemetry conventions, etc. The seed below is the lore default;
# `lore init` only writes this file when it does not already exist.

tests/*: [pytest, fixture, assertion, mock]
ACTIVITYVOCABEOF
fi

# Create category directories
for category in principles architecture conventions abstractions workflows gotchas domains team; do
  mkdir -p "$KNOWLEDGE_DIR/$category"
done

# Seed _scorecards/ sidecar with README documenting the sole-writer invariant.
# scorecard-append.sh is the only sanctioned writer of rows.jsonl — see
# $KDIR/_scorecards/README.md for the full reader contract.
"$SCRIPT_DIR/seed-scorecards-readme.sh" "$KNOWLEDGE_DIR/_scorecards"

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
