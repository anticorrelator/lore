#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"

setup() {
  CASE_ROOT="$(mktemp -d)"
}

teardown() {
  rm -rf "$CASE_ROOT"
}

spec_scenario() {
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

@test "spec recipe inventory spans both prose files and rejects malformed, missing, stale and empty selection coverage" {
  run spec_scenario inventory
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
  [[ "$output" == *"spans both prose files"* ]]
}

@test "spec synthesis recipes curate rendered delivery before open binds and project one latest packet" {
  run spec_scenario synthesis
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec entry recipes preserve standalone ordering, seat packets and resume states" {
  run spec_scenario entry
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec full recipes open a seat-authored wave, prepare ordinary sessions and collect independent reports" {
  run spec_scenario full
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec native recipes retain prepared bytes and refuse unavailable readiness" {
  run spec_scenario native
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec documented-report recipes check committed example coordinates and normalization" {
  run spec_scenario documented-report
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec design recipes ground the seat's reading and publish anchored revisions" {
  run spec_scenario design
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec finalize recipes preserve revisions, anchor refusal and hosted milestones" {
  run spec_scenario finalize
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec stewardship recipes retain theory capture and claim lifecycle" {
  run spec_scenario stewardship
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}

@test "spec recipe coverage accounts for every exact authored command" {
  local output_root="${SPEC_RECIPE_OUTPUT_ROOT:-$BATS_SUITE_TMPDIR/spec-recipes}"
  local inventories=()
  local scenario
  for scenario in synthesis entry full native documented-report design finalize stewardship; do
    inventories+=("$output_root/$scenario/case/inventory.json")
  done
  local sources=("$REPO_DIR/skills/spec/SKILL.md" "$REPO_DIR/skills/spec/commissioning.md")
  if [ -n "${SPEC_RECIPE_PROSE_REF:-}" ]; then
    sources=("$CASE_ROOT/SKILL.md" "$CASE_ROOT/commissioning.md")
    git -C "$REPO_DIR" show "$SPEC_RECIPE_PROSE_REF:skills/spec/SKILL.md" > "${sources[0]}"
    git -C "$REPO_DIR" show "$SPEC_RECIPE_PROSE_REF:skills/spec/commissioning.md" > "${sources[1]}"
  fi
  run python3 "$REPO_DIR/tests/helpers/spec_recipes.py" --scenario coverage \
    --root "$output_root/coverage" --source "${sources[@]}" \
    --inventories "${inventories[@]}"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
}
