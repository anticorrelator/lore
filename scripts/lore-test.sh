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
  echo "  seams        Run retro seam-drift checker + reader contract tests (repo cwd)" >&2
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
  seams)
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
      echo "Usage: lore test seams [base-revision] [head-revision]" >&2
      echo "" >&2
      echo "Runs, from a lore repo checkout:" >&2
      echo "  1. check-retro-seam-drift.sh over the commit range (default origin/main..HEAD)" >&2
      echo "  2. the retro reader contract suite (tests/frameworks/retro_prepare.bats)" >&2
      echo "  3. the checker's own tests (tests/test_retro_seam_drift_check.sh)" >&2
      echo "  4. the evidence-pack protocol test (tests/test_retro_evidence_pack_protocol.sh)" >&2
      exit 0
    fi
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/scripts/check-retro-seam-drift.sh" ]]; then
      echo "Error: run from inside a lore repo checkout (needs scripts/check-retro-seam-drift.sh)" >&2
      exit 1
    fi
    cd "$REPO_ROOT"
    BASE_REV="${1:-origin/main}"
    HEAD_REV="${2:-HEAD}"
    rc=0
    echo "[test] seam-drift checker: $BASE_REV..$HEAD_REV"
    bash scripts/check-retro-seam-drift.sh "$BASE_REV" "$HEAD_REV" || rc=1
    if command -v bats &>/dev/null; then
      echo "[test] reader contract suite: tests/frameworks/retro_prepare.bats"
      bats tests/frameworks/retro_prepare.bats || rc=1
    else
      echo "Error: bats not found on PATH — reader contract suite NOT run" >&2
      rc=1
    fi
    for t in tests/test_retro_seam_drift_check.sh tests/test_retro_evidence_pack_protocol.sh; do
      if [[ -f "$t" ]]; then
        echo "[test] $t"
        bash "$t" || rc=1
      fi
    done
    if [[ $rc -eq 0 ]]; then
      echo "[test] seams: all green"
    else
      echo "[test] seams: FAILURES above" >&2
    fi
    exit $rc
    ;;
  *)
    echo "Error: unknown test subcommand '$SUBCMD'" >&2
    echo "" >&2
    echo "Usage: lore test <subcommand> [args...]" >&2
    echo "Subcommands: protocols, seams" >&2
    exit 1
    ;;
esac
