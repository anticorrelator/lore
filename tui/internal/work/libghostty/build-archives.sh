#!/usr/bin/env bash
# Reproduce the vendored SIMD-off libghostty-vt static archives.
#
# This is a developer tool, run only when bumping the ghostty/binding pins in
# MANIFEST.json — NOT part of install. End-user machines link the prebuilt
# archives with only a C compiler.
#
# Why this is more than `zig build -Demit-lib-vt`:
#   1. ghostty pins EXACTLY Zig 0.15.x. The official ziglang.org zig-0.15.2
#      binary cannot link on a macOS 26 host (its self-hosted MachO linker
#      fails to resolve libSystem for native targets). The Homebrew `zig@0.15`
#      bottle links via Homebrew LLVM/LLD and works. Use it on macOS 26.
#   2. `zig build -Demit-lib-vt` emits an archive whose members are not 8-byte
#      aligned; Apple `ld` rejects that. Re-archiving the objects with Apple
#      `libtool` fixes alignment (macho only).
#   3. The emitted archive does NOT bundle the f128 quad-float compiler-rt
#      builtins (__extenddftf2 / __extendxftf2 / __multf3 / __trunctfdf2) that
#      Zig's std formatting (Io.Writer.printValue) references. On Linux libgcc
#      provides them; on macOS clang's libclang_rt.osx.a does NOT. So for the
#      darwin archives we build Zig's compiler_rt standalone and merge its
#      object in, yielding a self-contained archive.
#
# Usage:
#   GHOSTTY_DIR=/path/to/ghostty-checkout-at-pinned-commit \
#   ZIG=/opt/homebrew/opt/zig@0.15/bin/zig \
#     ./build-archives.sh
#
# Prereqs: a ghostty checkout at the MANIFEST `ghostty.commit`; Homebrew
# `zig@0.15` (brew install zig@0.15); macOS with Xcode CLT (libtool, ar).
# Cross-targets are produced from a single macOS host via Zig's -Dtarget.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBDIR="$HERE/lib"
ZIG="${ZIG:-/opt/homebrew/opt/zig@0.15/bin/zig}"
GHOSTTY_DIR="${GHOSTTY_DIR:?set GHOSTTY_DIR to a ghostty checkout at the pinned commit}"
LLVM_AR="${LLVM_AR:-/opt/homebrew/opt/llvm@21/bin/llvm-ar}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$ZIG" version | grep -q '^0\.15\.' || { echo "ZIG must be 0.15.x (got $($ZIG version))"; exit 1; }

# goos_goarch -> zig target triple
targets=( "darwin_arm64:aarch64-macos" "darwin_amd64:x86_64-macos" "linux_amd64:x86_64-linux-gnu" )

for entry in "${targets[@]}"; do
  goname="${entry%%:*}"; triple="${entry##*:}"
  echo "=== $goname ($triple) ==="
  out="$LIBDIR/$goname"; mkdir -p "$out"

  # 1. Build the SIMD-off vt static archive.
  ( cd "$GHOSTTY_DIR" && rm -rf zig-out && "$ZIG" build -Demit-lib-vt -Dsimd=false -Doptimize=ReleaseFast -Dtarget="$triple" )
  vt="$GHOSTTY_DIR/zig-out/lib/libghostty-vt.a"

  # 2. Build Zig's full compiler_rt standalone (provides f128 builtins).
  crt="$WORK/${goname}_crt.a"
  "$ZIG" build-lib "$(dirname "$(dirname "$ZIG")")/lib/zig/compiler_rt.zig" \
    -target "$triple" -OReleaseFast --name compiler_rt -femit-bin="$crt"

  # 3. Extract the main vt object (drop the archive's incomplete compiler_rt.o)
  #    and the full compiler_rt object, then re-archive together.
  ex="$WORK/${goname}_ex"; rm -rf "$ex"; mkdir -p "$ex"; ( cd "$ex" && "$LLVM_AR" x "$vt" && chmod u+rw ./*.o && rm -f compiler_rt.o )
  crtex="$WORK/${goname}_crtex"; rm -rf "$crtex"; mkdir -p "$crtex"; ( cd "$crtex" && "$LLVM_AR" x "$crt" && chmod u+rw ./*.o )

  case "$goname" in
    darwin_*)
      # Apple libtool: 8-byte aligns members (required by Apple ld).
      /usr/bin/libtool -static -o "$out/libghostty-vt.a" "$ex"/*.o "$crtex"/*.o
      ;;
    linux_*)
      # ELF: GNU/LLVM ld has no 8-byte member requirement; libgcc would also
      # provide the f128 builtins, but bundle compiler_rt for self-containment.
      rm -f "$out/libghostty-vt.a"
      "$LLVM_AR" rcs "$out/libghostty-vt.a" "$ex"/*.o "$crtex"/*.o
      ;;
  esac

  sha="$(shasum -a 256 "$out/libghostty-vt.a" | awk '{print $1}')"
  echo "  -> $out/libghostty-vt.a  ($(wc -c < "$out/libghostty-vt.a") bytes)  sha256=$sha"
done

echo "Done. Update MANIFEST.json target sha256 cells with the values above."
