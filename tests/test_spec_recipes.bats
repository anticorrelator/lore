#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

setup() {
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$CASE_ROOT"
}

spec_scenario() {
  python3 -c 'import yaml'
  local recipe_root="$CASE_ROOT/case"
  if [ -n "${SPEC_RECIPE_OUTPUT_ROOT:-}" ]; then
    recipe_root="$SPEC_RECIPE_OUTPUT_ROOT/$1"
  fi
  local args=(--scenario "$1" --root "$recipe_root")
  if [ -n "${SPEC_RECIPE_PROSE_REF:-}" ]; then
    args+=(--prose-ref "$SPEC_RECIPE_PROSE_REF")
  fi
  python3 "$REPO_DIR/tests/helpers/spec_recipes.py" "${args[@]}"
}

@test "spec recipe inventory rejects malformed, missing, stale and empty selection coverage" {
  run spec_scenario inventory
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" == *"All three namespaces"* ]]
}
