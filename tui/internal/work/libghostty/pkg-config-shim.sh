#!/bin/sh
# pkg-config replacement for the vendored libghostty-vt.
#
# go.mitchellh.com/libghostty resolves its C headers through
# `#cgo pkg-config: --static libghostty-vt-static`, which expects a
# pkg-config binary plus a .pc file produced by ghostty's zig build. Lore
# vendors the headers and static archive in this directory instead (see
# MANIFEST.json), so TUI builds export PKG_CONFIG pointing here and need
# no pkg-config install:
#
#   PKG_CONFIG=tui/internal/work/libghostty/pkg-config-shim.sh \
#     go build ./...
#
# install.sh and `lore rebuild` set this automatically.
#
# --cflags answers with the vendored include dir. --libs is intentionally
# empty: the link inputs (-L/-lghostty-vt against the per-platform archive)
# are owned by the `#cgo LDFLAGS` directives in
# tui/internal/work/ghostty_link.go, keeping a single source of link truth.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

mode=""
for arg in "$@"; do
  case "$arg" in
    --cflags) mode="cflags" ;;
    --libs) mode="libs" ;;
    --version) printf '1.0.0\n'; exit 0 ;;
    --static|--) ;;
    --*) ;;
    libghostty-vt-static|libghostty-vt) ;;
    *)
      printf 'pkg-config-shim: unknown package %s (only libghostty-vt[-static] is vendored)\n' "$arg" >&2
      exit 1
      ;;
  esac
done

case "$mode" in
  cflags) printf -- '-I%s/include\n' "$dir" ;;
  libs) printf '\n' ;;
  *)
    printf 'pkg-config-shim: expected --cflags or --libs\n' >&2
    exit 1
    ;;
esac
