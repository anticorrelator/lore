#!/usr/bin/env bash
set -euo pipefail
# Run from the source checkout root; no disposable checkout path is embedded.
python3 -m unittest discover -s tests -p test_steering_contract.py -q
python3 -m unittest discover -s tests -p test_coordinate_watch_delivery.py -q
cd tui
export GOTOOLCHAIN=local GOPROXY=off GOMAXPROCS=2
export GOCACHE=/private/tmp/lore-friction-go-cache
export PKG_CONFIG="$PWD/internal/work/libghostty/pkg-config-shim.sh"
STEERING_GO="${STEERING_GO:-/Users/dustinqngo/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.26.4.darwin-arm64/bin/go}"
"$STEERING_GO" test -p 1 . ./internal/session -count=1
