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
  local recipe_root="$BATS_SUITE_TMPDIR/spec-recipes/$1"
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

@test "spec synthesis recipes curate rendered delivery before binding and project one latest packet" {
  run spec_scenario synthesis
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec entry recipes preserve standalone ordering, seat packets and resume states" {
  run spec_scenario entry
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec inline recipes land typed investigator reports without a launch claim" {
  run spec_scenario inline
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec full recipes prepare ordinary sessions and collect independent reports" {
  run spec_scenario full
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec native recipes retain prepared bytes and refuse unavailable readiness" {
  run spec_scenario native
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec designer recipes preserve independent planning and accepted continuation inputs" {
  run spec_scenario designer
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec consultation recipes retain the implement task-domain handoff" {
  run spec_scenario consultation
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec gate-design recipes compose coordinator and multiple evaluator attempts" {
  run spec_scenario gate-design
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec gate-plan recipes review intervening edits and preserve historical attempts" {
  run spec_scenario gate-plan
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec review recipes retain both ceremonies, absence and commissioned gates" {
  run spec_scenario reviews
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec finalize recipes preserve revisions, anchor refusal and hosted milestones" {
  run spec_scenario finalize
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec stewardship recipes retain capture, trust repair and claim lifecycle" {
  run spec_scenario stewardship
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec recipe coverage accounts for every exact authored command" {
  local output_root="${SPEC_RECIPE_OUTPUT_ROOT:-$BATS_SUITE_TMPDIR/spec-recipes}"
  local inventories=()
  local scenario
  for scenario in synthesis entry inline full native designer consultation gate-design gate-plan reviews finalize stewardship; do
    inventories+=("$output_root/$scenario/case/inventory.json")
  done
  local current_source="$REPO_DIR/skills/spec/SKILL.md"
  if [ -n "${SPEC_RECIPE_PROSE_REF:-}" ]; then
    current_source="$CASE_ROOT/current-spec.md"
    git -C "$REPO_DIR" show "$SPEC_RECIPE_PROSE_REF:skills/spec/SKILL.md" > "$current_source"
  fi
  run python3 "$REPO_DIR/tests/helpers/spec_recipes.py" --scenario coverage \
    --root "$output_root/coverage" --source "$current_source" \
    --inventories "${inventories[@]}"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
