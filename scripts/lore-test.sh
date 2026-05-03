#!/usr/bin/env bash
# lore-test.sh — Run lore protocol test suites.
#
# Usage:
#   lore test protocols [pytest-args...]
#   lore test protocols --help
#   lore test protocols -k convention
#
# Subcommands:
#   protocols    Run pytest against ~/.lore/tests/protocols/

set -euo pipefail

PROTOCOLS_DIR="$HOME/.lore/tests/protocols"

if [[ $# -eq 0 ]]; then
  echo "Usage: lore test <subcommand> [args...]" >&2
  echo "" >&2
  echo "Subcommands:" >&2
  echo "  protocols    Run protocol tests (pytest ~/.lore/tests/protocols/)" >&2
  exit 1
fi

SUBCMD="$1"
shift

case "$SUBCMD" in
  --help|-h)
    echo "Usage: lore test <subcommand> [args...]" >&2
    echo "" >&2
    echo "Subcommands:" >&2
    echo "  protocols    Run protocol tests (pytest ~/.lore/tests/protocols/)" >&2
    exit 0
    ;;
  protocols)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
      echo "Usage: lore test protocols [pytest-args...]" >&2
      echo "" >&2
      echo "Runs pytest against $PROTOCOLS_DIR." >&2
      echo "Any additional arguments are forwarded to pytest." >&2
      echo "" >&2
      echo "Examples:" >&2
      echo "  lore test protocols                  # run all tests" >&2
      echo "  lore test protocols -k convention    # filter by name" >&2
      echo "  lore test protocols -v               # verbose output" >&2
      exit 0
    fi
    if [[ ! -d "$PROTOCOLS_DIR" ]]; then
      echo "Error: protocols test directory not found: $PROTOCOLS_DIR" >&2
      echo "Expected pytest test files at $PROTOCOLS_DIR/test_*.py" >&2
      exit 1
    fi
    echo "[test] Running lore protocol tests..."
    if ! command -v pytest &>/dev/null; then
      echo "Error: pytest not found on PATH" >&2
      exit 1
    fi
    pytest "$PROTOCOLS_DIR" "$@"
    ;;
  *)
    echo "Error: unknown test subcommand '$SUBCMD'" >&2
    echo "" >&2
    echo "Usage: lore test <subcommand> [args...]" >&2
    echo "Subcommands: protocols" >&2
    exit 1
    ;;
esac
