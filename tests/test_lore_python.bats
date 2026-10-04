#!/usr/bin/env bats
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "impl interpreter discovery bypasses a python3 below the floor and propagates selection" {
  root=$(mktemp -d)
  mkdir "$root/old" "$root/capable"
  printf '#!/bin/sh\nexit 1\n' > "$root/old/python3"
  printf '#!/bin/sh\nexit 0\n' > "$root/capable/python3"
  chmod +x "$root"/*/python3
  run env -u LORE_PYTHON PATH="$root/old:$root/capable:$PATH" bash -c 'source "$1/scripts/lib.sh"; ensure_lore_python; test "$(command -v python3)" = "$2/capable/python3"; test "$LORE_PYTHON" = "$2/capable/python3"' bash "$REPO_DIR" "$root"
  rm -rf "$root"
  [ "$status" -eq 0 ]
}

@test "impl interpreter discovery fails with a pointer to lore doctor when no python3 qualifies" {
  root=$(mktemp -d)
  mkdir "$root/old"
  printf '#!/bin/sh\nexit 1\n' > "$root/old/python3"
  chmod +x "$root/old/python3"
  run env -u LORE_PYTHON PATH="$root/old:/usr/bin:/bin" bash -c 'source "$1/scripts/lib.sh"; PATH="$2/old:/bin"; ensure_lore_python' bash "$REPO_DIR" "$root"
  rm -rf "$root"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lore doctor"* ]]
}
