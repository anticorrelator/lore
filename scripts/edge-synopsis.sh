#!/usr/bin/env bash
# edge-synopsis.sh — Read/write/invalidate edge-keyed synopsis sidecars
#
# Usage:
#   edge-synopsis.sh get <entry_id> <requesting_scale>
#     → outputs synopsis content (stdout), exit 0 on cache hit
#     → exit 1 if not found
#     → exit 2 if stale (parent hash or template_version changed); stale file is deleted
#
#   edge-synopsis.sh put <entry_id> <requesting_scale> \
#     --content-file <path> \
#     --parent-hash <hex> \
#     --parent-template-version <ver> \
#     --status <cached|generated|fallback>
#     → writes sidecar file, prints path on stdout
#
#   edge-synopsis.sh invalidate <entry_id>
#     → deletes all synopsis files for entry_id (all scales); prints count on stdout
#
# Storage: $KDIR/_edge_synopses/<sanitized_entry_id>__<requesting_scale>.md
# The sanitized_entry_id is the entry's relative path with '/' → '__'.
#
# File format:
#   <!-- entry_id: <id> | requesting_scale: <scale> | synthesized_at: <ISO-8601> | parent_content_hash: <sha256> | parent_template_version: <ver> | synopsis_status: cached|generated|fallback -->
#   <synopsis content>
#
# Staleness detection (get):
#   Reads parent_content_hash from the cached header. Computes sha256 of the current
#   parent entry file. If mismatched, deletes the sidecar and exits 2.
#   template_version staleness: if the cached parent_template_version differs from
#   the current parent's template_version field (read from its HTML comment metadata),
#   also exits 2. "unknown" on either side skips the template_version check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Helpers ---

sanitize_entry_id() {
  local entry_id="$1"
  echo "$entry_id" | sed 's|/|__|g'
}

synopsis_path() {
  local kdir="$1"
  local entry_id="$2"
  local scale="$3"
  local sanitized
  sanitized=$(sanitize_entry_id "$entry_id")
  echo "$kdir/_edge_synopses/${sanitized}__${scale}.md"
}

usage() {
  sed -n '2,20p' "$0" >&2
  exit 1
}

# --- Subcommand dispatch ---

if [[ $# -eq 0 ]]; then
  usage
fi

subcmd="$1"
shift

case "$subcmd" in
  --help|-h)
    usage
    ;;

  get)
    if [[ $# -lt 2 ]]; then
      echo "Error: get requires <entry_id> <requesting_scale>" >&2
      exit 1
    fi
    ENTRY_ID="$1"
    SCALE="$2"

    KDIR=$(resolve_knowledge_dir)
    SFILE=$(synopsis_path "$KDIR" "$ENTRY_ID" "$SCALE")

    if [[ ! -f "$SFILE" ]]; then
      exit 1
    fi

    # --- Staleness check ---
    # Extract cached header fields via Python (portable, no awk regex dependency)
    HEADER=$(head -1 "$SFILE")
    CACHED_HASH=$(printf '%s' "$HEADER" | python3 -c "
import re, sys
m = re.search(r'parent_content_hash:\s*([^\s|>]+)', sys.stdin.read())
print(m.group(1).strip() if m else '')
" 2>/dev/null || echo "")
    CACHED_TMPL=$(printf '%s' "$HEADER" | python3 -c "
import re, sys
m = re.search(r'parent_template_version:\s*([^\s|>]+)', sys.stdin.read())
print(m.group(1).strip() if m else '')
" 2>/dev/null || echo "")

    PARENT_PATH="$KDIR/${ENTRY_ID}.md"
    STALE=0

    if [[ -f "$PARENT_PATH" && -n "$CACHED_HASH" && "$CACHED_HASH" != "unknown" ]]; then
      CURRENT_HASH=$(sha256sum "$PARENT_PATH" 2>/dev/null | awk '{print $1}' \
        || shasum -a 256 "$PARENT_PATH" 2>/dev/null | awk '{print $1}' \
        || echo "unknown")
      if [[ -n "$CURRENT_HASH" && "$CURRENT_HASH" != "unknown" && "$CURRENT_HASH" != "$CACHED_HASH" ]]; then
        STALE=1
      fi
    fi

    # Template version check (skip when either side is "unknown")
    if [[ $STALE -eq 0 && -f "$PARENT_PATH" && -n "$CACHED_TMPL" && "$CACHED_TMPL" != "unknown" ]]; then
      CURRENT_TMPL=$(python3 -c "
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'\|\s*template_version:\s*([^\s|>]+)', text)
print(m.group(1).strip() if m else 'unknown')
" "$PARENT_PATH" 2>/dev/null || echo "unknown")
      if [[ "$CURRENT_TMPL" != "unknown" && "$CURRENT_TMPL" != "$CACHED_TMPL" ]]; then
        STALE=1
      fi
    fi

    if [[ $STALE -eq 1 ]]; then
      rm -f "$SFILE"
      exit 2
    fi

    # Cache hit — strip the metadata comment header line, output body
    tail -n +2 "$SFILE"
    ;;

  put)
    if [[ $# -lt 2 ]]; then
      echo "Error: put requires <entry_id> <requesting_scale> [options]" >&2
      exit 1
    fi
    ENTRY_ID="$1"
    SCALE="$2"
    shift 2

    CONTENT_FILE=""
    PARENT_HASH=""
    PARENT_TEMPLATE_VERSION=""
    STATUS=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --content-file)
          CONTENT_FILE="$2"
          shift 2
          ;;
        --parent-hash)
          PARENT_HASH="$2"
          shift 2
          ;;
        --parent-template-version)
          PARENT_TEMPLATE_VERSION="$2"
          shift 2
          ;;
        --status)
          STATUS="$2"
          shift 2
          ;;
        *)
          echo "Error: unknown option '$1'" >&2
          exit 1
          ;;
      esac
    done

    # Validate required flags
    if [[ -z "$CONTENT_FILE" ]]; then
      echo "Error: --content-file is required" >&2
      exit 1
    fi
    if [[ ! -f "$CONTENT_FILE" ]]; then
      echo "Error: content file not found: $CONTENT_FILE" >&2
      exit 1
    fi
    if [[ -z "$PARENT_HASH" ]]; then
      echo "Error: --parent-hash is required" >&2
      exit 1
    fi
    if [[ -z "$PARENT_TEMPLATE_VERSION" ]]; then
      echo "Error: --parent-template-version is required" >&2
      exit 1
    fi
    if [[ -z "$STATUS" ]]; then
      echo "Error: --status is required (cached|generated|fallback)" >&2
      exit 1
    fi
    case "$STATUS" in
      cached|generated|fallback) ;;
      *)
        echo "Error: --status must be one of: cached, generated, fallback" >&2
        exit 1
        ;;
    esac

    KDIR=$(resolve_knowledge_dir)
    SYNOPSES_DIR="$KDIR/_edge_synopses"
    mkdir -p "$SYNOPSES_DIR"

    SFILE=$(synopsis_path "$KDIR" "$ENTRY_ID" "$SCALE")
    TS=$(timestamp_iso)

    {
      printf '<!-- entry_id: %s | requesting_scale: %s | synthesized_at: %s | parent_content_hash: %s | parent_template_version: %s | synopsis_status: %s -->\n' \
        "$ENTRY_ID" "$SCALE" "$TS" "$PARENT_HASH" "$PARENT_TEMPLATE_VERSION" "$STATUS"
      cat "$CONTENT_FILE"
    } > "$SFILE"

    echo "$SFILE"
    ;;

  invalidate)
    if [[ $# -lt 1 ]]; then
      echo "Error: invalidate requires <entry_id>" >&2
      exit 1
    fi
    ENTRY_ID="$1"

    KDIR=$(resolve_knowledge_dir)
    SYNOPSES_DIR="$KDIR/_edge_synopses"

    if [[ ! -d "$SYNOPSES_DIR" ]]; then
      echo "0"
      exit 0
    fi

    # Match all files for this entry_id (any scale): <sanitized>__*.md
    SANITIZED=$(sanitize_entry_id "$ENTRY_ID")
    COUNT=0
    for f in "$SYNOPSES_DIR/${SANITIZED}__"*.md; do
      [[ -f "$f" ]] || continue
      rm -f "$f"
      COUNT=$((COUNT + 1))
    done

    echo "$COUNT"
    ;;

  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    echo "" >&2
    usage
    ;;
esac
