#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

setup() {
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$CASE_ROOT"
}

review_scenario() {
  python3 -c 'import yaml'
  python3 "$REPO_DIR/tests/helpers/spec_review_recipes.py" \
    --scenario "$1" --root "$CASE_ROOT/case" \
    --source-root "${LORE_REVIEW_SOURCE_ROOT:-$REPO_DIR}"
}

@test "review recipe inventory preserves namespaces and rejects absent or stale coverage" {
  run review_scenario inventory
  [ "$status" -eq 0 ]
  [[ "$output" == *"All three namespaces"* ]]
}

@test "design review recipes select immutable abstract context and preserve review history" {
  run review_scenario design
  [ "$status" -eq 0 ]
}

@test "plan review recipes retain full prepared tasks, judgments and seven attributed ratings" {
  run review_scenario plan
  [ "$status" -eq 0 ]
}

@test "review skills install from canonical sources into an isolated target" {
  run review_scenario installation
  [ "$status" -eq 0 ]
}
