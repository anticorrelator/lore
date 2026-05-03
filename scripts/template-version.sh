#!/usr/bin/env bash
# template-version.sh — content-hash a template file for the scorecard/retro registry
#
# Usage:
#   template-version.sh <template-path>
#
# Output: 12-char prefix of sha256(template-path contents), printed to stdout.
# Consumed inline, e.g. `TV=$(template-version.sh "$template")`.
#
# Exit codes:
#   0 — success
#   1 — missing argument, unreadable file, or no available hasher

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  echo "Usage: template-version.sh <template-path>" >&2
  echo "  Emit 12-char sha256 prefix of the file's contents." >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

case "$1" in
  --help|-h)
    usage
    exit 0
    ;;
esac

TEMPLATE_PATH="$1"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Error: template file not found: $TEMPLATE_PATH" >&2
  exit 1
fi

if [[ ! -r "$TEMPLATE_PATH" ]]; then
  echo "Error: template file not readable: $TEMPLATE_PATH" >&2
  exit 1
fi

# Prefer sha256sum (GNU coreutils, present on most Linux + newer macOS); fall back
# to `shasum -a 256` (always present on macOS) so the script is portable.
if command -v sha256sum >/dev/null 2>&1; then
  HASH=$(sha256sum "$TEMPLATE_PATH" | cut -c1-12)
elif command -v shasum >/dev/null 2>&1; then
  HASH=$(shasum -a 256 "$TEMPLATE_PATH" | cut -c1-12)
else
  echo "Error: neither sha256sum nor shasum found on PATH" >&2
  exit 1
fi

# Trailing newline — matches `$(...)` capture semantics (stripped by the shell).
printf '%s\n' "$HASH"
