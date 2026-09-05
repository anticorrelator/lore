#!/usr/bin/env bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ -z "${POSITION_SESSION_FIXTURES:-}" ]]; then
  POSITION_SESSION_FIXTURES="$(mktemp -d)"
  trap 'rm -rf "$POSITION_SESSION_FIXTURES"' EXIT
fi
export POSITION_SESSION_FIXTURES
export POSITION_DISPATCH_FIXTURES="$POSITION_SESSION_FIXTURES"
bats --filter 'ordinary position queue preparation' "$REPO/tests/test_position_dispatch.bats"
export PKG_CONFIG="$REPO/tui/internal/work/libghostty/pkg-config-shim.sh"
export GOCACHE=/private/tmp/position-go-cache
cd "$REPO/tui"
go test ./internal/session ./internal/config ./internal/work . -run 'TestPosition|TestBuildInitialPrompt|TestStartTerminalCmd|TestDescriptorFromRequest' -count=1
