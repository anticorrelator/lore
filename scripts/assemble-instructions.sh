#!/usr/bin/env bash
# assemble-instructions.sh — Framework-aware wrapper around assemble-claude-md.sh
#
# Dispatches instruction-file assembly to the right per-harness target based
# on --framework <name>. Today every supported framework's instruction target
# is the Claude-style ~/.claude/CLAUDE.md (Claude Code's canonical path,
# which OpenCode also reads natively per [[knowledge:architecture/
# infrastructure/opencode-reads-claude-skills-and-claude-md-natively-as-fallb]]).
# Codex's AGENTS.md target lands in T18 (which owns per-harness packaging
# targets); until then this wrapper reports a degraded-target notice for
# codex on --dry-run and delegates to the existing CLAUDE.md path on a
# real run.
#
# Resolution order for --framework value:
#   1. Explicit --framework <name> CLI flag.
#   2. resolve_active_framework (env LORE_FRAMEWORK or
#      $LORE_DATA_DIR/config/framework.json `.framework`).
#   3. Built-in default: claude-code.
#
# Usage:
#   bash assemble-instructions.sh [--framework <name>] [--check | --disable | --dry-run]
#     --framework <name>   One of claude-code|opencode|codex (default: active framework)
#     --check              Diff only, exit 1 if out of date
#     --disable            Write an empty lore region (preserves surrounding content)
#     --dry-run            Print the resolved framework + target file path; exit 0 without writing
#
# Back-compat: scripts/assemble-claude-md.sh remains as the bare CLAUDE.md
# entrypoint and is still callable directly. cli/lore's `assemble`
# subcommand routes through this wrapper instead (T17 responsibility);
# install.sh's call site is migrated by T18.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"

FRAMEWORK=""
DRY_RUN=0
PASSTHROUGH_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework)
      FRAMEWORK="$2"
      shift 2
      ;;
    --framework=*)
      FRAMEWORK="${1#--framework=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --check|--disable)
      PASSTHROUGH_FLAG="$1"
      shift
      ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" >&2
      exit 0
      ;;
    *)
      echo "Error: unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# 1. Resolve framework: --framework wins; else resolve_active_framework; else claude-code.
if [[ -z "$FRAMEWORK" ]]; then
  if FRAMEWORK=$(resolve_active_framework 2>/dev/null) && [[ -n "$FRAMEWORK" ]]; then
    :
  else
    FRAMEWORK="claude-code"
  fi
fi

# Validate framework against the closed set in adapters/capabilities.json.
CAPABILITIES_FILE="$SCRIPT_DIR/../adapters/capabilities.json"
if [[ -f "$CAPABILITIES_FILE" ]] && command -v jq &>/dev/null; then
  if ! jq -e --arg fw "$FRAMEWORK" '.frameworks[$fw] // empty | length > 0' "$CAPABILITIES_FILE" &>/dev/null; then
    echo "Error: unknown framework '$FRAMEWORK' (not present in $CAPABILITIES_FILE)" >&2
    exit 1
  fi
fi

# 2. Resolve the target instruction-file path via the framework's
#    install_paths.instructions cell (T18 wired this from the legacy
#    case statement to resolve_harness_install_path). claude-code and
#    opencode both resolve to ~/.claude/CLAUDE.md (OpenCode reads it
#    natively); codex resolves to ~/.codex/AGENTS.md. Frameworks whose
#    install_paths.instructions is "unsupported" (or unwired) report
#    degraded and exit without writing.
TARGET=""
DEGRADED=""
if TARGET=$(LORE_FRAMEWORK="$FRAMEWORK" resolve_harness_install_path instructions 2>&1); then
  if [[ "$TARGET" == "unsupported" ]]; then
    DEGRADED="framework=$FRAMEWORK has no instructions install path (install_paths.instructions=unsupported); skipping instruction-file assembly"
    TARGET=""
  fi
else
  DEGRADED="resolve_harness_install_path failed for framework=$FRAMEWORK: $TARGET"
  TARGET=""
fi

# 3. --dry-run: print resolved framework + instruction target + MCP target.
#    The MCP target line (T20) reports where Lore-shipped MCP servers WOULD
#    be packaged for the active harness even when the registry is empty,
#    so operators auditing the per-harness install can see the surface
#    without needing to run install.sh. Empty registry / unsupported
#    surface emits a "would package: N servers" or "mcp=none" notice.
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -n "$DEGRADED" ]]; then
    echo "[assemble-instructions] framework=$FRAMEWORK degraded: $DEGRADED" >&2
    # Still report MCP target on degraded instruction path — they're
    # independent surfaces.
  else
    echo "[assemble-instructions] framework=$FRAMEWORK target=$TARGET"
  fi
  MCP_TARGET=""
  MCP_REGISTRY="$SCRIPT_DIR/../adapters/mcp-servers.json"
  if mcp_raw=$(LORE_FRAMEWORK="$FRAMEWORK" resolve_harness_install_path mcp_servers 2>/dev/null); then
    if [[ "$mcp_raw" == "unsupported" ]]; then
      echo "[assemble-instructions] framework=$FRAMEWORK mcp=none (no MCP install path)"
    else
      MCP_TARGET="$mcp_raw"
      MCP_COUNT=0
      if [[ -f "$MCP_REGISTRY" ]] && command -v python3 &>/dev/null; then
        MCP_COUNT=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(len(d.get('servers') or {}))
except Exception:
    print(0)
" "$MCP_REGISTRY" 2>/dev/null || echo 0)
      fi
      echo "[assemble-instructions] framework=$FRAMEWORK mcp_target=$MCP_TARGET servers=$MCP_COUNT"
    fi
  else
    echo "[assemble-instructions] framework=$FRAMEWORK mcp_target=unresolvable" >&2
  fi
  exit 0
fi

# 4. Degraded path: announce and exit without writing.
if [[ -n "$DEGRADED" ]]; then
  echo "[assemble-instructions] framework=$FRAMEWORK degraded — $DEGRADED" >&2
  exit 0
fi

# 5. Delegate to assemble-claude-md.sh for the actual write. The
#    LORE_INSTRUCTIONS_TARGET env var overrides assemble-claude-md.sh's
#    default $HOME/.claude/CLAUDE.md so the same fragment-assembly +
#    sentinel-splice + pre-lore-backup logic handles every harness's
#    target without duplication. Codex's $HOME/.codex/AGENTS.md reuses
#    the LORE:BEGIN/END sentinels — Codex reads sentinel-bracketed
#    markdown as plain instruction prose.
if [[ -n "$PASSTHROUGH_FLAG" ]]; then
  LORE_INSTRUCTIONS_TARGET="$TARGET" exec bash "$SCRIPT_DIR/assemble-claude-md.sh" "$PASSTHROUGH_FLAG"
else
  LORE_INSTRUCTIONS_TARGET="$TARGET" exec bash "$SCRIPT_DIR/assemble-claude-md.sh"
fi
