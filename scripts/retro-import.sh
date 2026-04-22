#!/usr/bin/env bash
# retro-import.sh — Ingest a contributor retro-export bundle into the maintainer's private pool
#
# Usage:
#   lore retro import <bundle.json> [--json]
#
# Validates the bundle's schema (retro-export.v1), then writes it to
# `~/.lore/_retro-pool/<contributor_id>/<timestamp>.json`. This pool is
# maintainer-private — **not committed** to any shared repo. Per
# multi-user-evolution-design.md §2, retros are introspective artifacts
# and committing them would cross a norm boundary.
#
# SCOPE: maintainer-only. This script requires `role: maintainer` in
# `~/.lore/config/settings.json` (or per-repo `~/.lore/repos/<repo>/config.json`).
# Role resolution is currently inline; task-53 will replace this block
# with a shared `resolve_role()` helper in lib.sh. Until then, the inline
# check is the enforcement point.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

BUNDLE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      if [[ -z "$BUNDLE" ]]; then
        BUNDLE="$1"
        shift
      else
        echo "Unknown argument: $1" >&2
        echo "Usage: lore retro import <bundle.json> [--json]" >&2
        exit 1
      fi
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

[[ -z "$BUNDLE" ]] && fail "bundle path required: lore retro import <bundle.json>"
[[ -f "$BUNDLE" ]] || fail "bundle not found: $BUNDLE"

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

# --- Role gate (inline; will be replaced by resolve_role() from task-53) ---
ROLE="contributor"
GLOBAL_CONFIG="$HOME/.lore/config/settings.json"
if [[ -f "$GLOBAL_CONFIG" ]]; then
  G_ROLE=$(jq -r '.role // ""' "$GLOBAL_CONFIG" 2>/dev/null || echo "")
  [[ -n "$G_ROLE" ]] && ROLE="$G_ROLE"
fi
# Per-repo override: walk up from cwd for .lore.config to find repo slug
if [[ -d "$HOME/.lore/repos" ]]; then
  REPO_CONFIG=""
  # Try current repo's config file if we're inside a lore-tracked repo
  KDIR=$(resolve_knowledge_dir 2>/dev/null || echo "")
  if [[ -n "$KDIR" && -f "$KDIR/config.json" ]]; then
    REPO_CONFIG="$KDIR/config.json"
    R_ROLE=$(jq -r '.role // ""' "$REPO_CONFIG" 2>/dev/null || echo "")
    [[ -n "$R_ROLE" ]] && ROLE="$R_ROLE"
  fi
fi

if [[ "$ROLE" != "maintainer" ]]; then
  fail "lore retro import requires role=maintainer (current: $ROLE). Set {\"role\":\"maintainer\"} in ~/.lore/config/settings.json or per-repo config.json."
fi

# --- Validate bundle schema ---
SCHEMA_VERSION=$(jq -r '.envelope.schema_version // ""' "$BUNDLE" 2>/dev/null || echo "")
if [[ "$SCHEMA_VERSION" != "retro-export.v1" ]]; then
  fail "bundle schema_version is '$SCHEMA_VERSION', expected 'retro-export.v1'"
fi

CONTRIBUTOR_ID=$(jq -r '.envelope.contributor_id // ""' "$BUNDLE")
[[ -z "$CONTRIBUTOR_ID" || "$CONTRIBUTOR_ID" == "null" ]] && fail "bundle missing envelope.contributor_id"

EXPORT_ID=$(jq -r '.envelope.export_id // ""' "$BUNDLE")
[[ -z "$EXPORT_ID" || "$EXPORT_ID" == "null" ]] && fail "bundle missing envelope.export_id"

# --- Check for duplicate import (same export_id already in pool) ---
POOL_DIR="$HOME/.lore/_retro-pool/$CONTRIBUTOR_ID"
if [[ -d "$POOL_DIR" ]]; then
  if grep -rl "\"export_id\": *\"$EXPORT_ID\"" "$POOL_DIR" 2>/dev/null | head -1 | grep -q .; then
    fail "bundle with export_id=$EXPORT_ID is already in the pool (duplicate import)"
  fi
fi

# --- Write to pool ---
mkdir -p "$POOL_DIR"
TIMESTAMP=$(timestamp_iso | tr ':' '-')
OUT_PATH="$POOL_DIR/$TIMESTAMP.json"
cp "$BUNDLE" "$OUT_PATH"

CELL_COUNT=$(jq '.scorecard_cells | length' "$OUT_PATH")
RETRO_COUNT=$(jq '.retros | length' "$OUT_PATH")

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n \
    --arg path "$OUT_PATH" \
    --arg contributor_id "$CONTRIBUTOR_ID" \
    --arg export_id "$EXPORT_ID" \
    --argjson cell_count "$CELL_COUNT" \
    --argjson retro_count "$RETRO_COUNT" \
    '{path: $path, contributor_id: $contributor_id, export_id: $export_id, cell_count: $cell_count, retro_count: $retro_count}'
  exit 0
fi

echo "[retro-import] Imported bundle to pool"
echo "  contributor_id: $CONTRIBUTOR_ID"
echo "  export_id:      $EXPORT_ID"
echo "  path:           $OUT_PATH"
echo "  cells:          $CELL_COUNT"
echo "  retros:         $RETRO_COUNT"
echo ""
echo "Run 'lore retro aggregate' to compute pooled convergence tags."
