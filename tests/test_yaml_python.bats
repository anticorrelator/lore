#!/usr/bin/env bats
REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
@test "impl interpreter discovery bypasses a Python missing yaml and propagates selection" {
  root=$(mktemp -d)
  mkdir "$root/missing" "$root/capable"
  printf '#!/bin/sh\nexit 1\n' > "$root/missing/python3"
  printf '#!/bin/sh\nexit 0\n' > "$root/capable/python3"
  chmod +x "$root"/*/python3
  run env -u LORE_PYTHON PATH="$root/missing:$root/capable:$PATH" bash -c 'source "$1/scripts/lib.sh"; ensure_yaml_python; test "$(command -v python3)" = "$2/capable/python3"; test "$LORE_PYTHON" = "$2/capable/python3"' bash "$REPO_DIR" "$root"
  rm -rf "$root"
  [ "$status" -eq 0 ]
}
