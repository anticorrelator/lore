#!/usr/bin/env bats
# claude-code-mod.bats — every check on lore's Claude Code mod
# (adapters/claude-code-mod) in one suite: Claude Code's own validator, a strict
# TypeScript check, and the mod's plugin tests (adapters/claude-code-mod/tests).
#
# Each needs the `claude` CLI and skips without it. The type-check also needs
# TypeScript 5 (npx fetches it, or tsc on PATH).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd -P)"
MOD="$REPO_DIR/adapters/claude-code-mod"

setup() {
  command -v claude >/dev/null 2>&1 || skip "claude CLI not installed"
}

@test "claude plugin validate accepts the mod" {
  run claude plugin validate "$MOD"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Validation passed"* ]]
}

@test "the mod type-checks under strict TypeScript" {
  # The declarations are the engine's own, written into .claude-plugin/types
  # whenever Claude Code loads the mod. A headless run of the local /cost
  # command loads it without a model call; leaving out user settings and
  # setting LORE_AGENT_DISABLED keeps the owner's hooks and the mod idle.
  (cd "$MOD" && LORE_AGENT_DISABLED=1 claude -p --setting-sources project --plugin-dir "$MOD" "/cost" </dev/null >/dev/null 2>&1) \
    || skip "claude could not load the mod headless"
  [ -f "$MOD/.claude-plugin/types/claude-code/index.d.ts" ] || skip "claude did not write the mod's type declarations"
  if command -v npx >/dev/null 2>&1; then
    run npx --yes -p typescript@5 tsc -p "$MOD/tests/tsconfig.json"
  elif command -v tsc >/dev/null 2>&1; then
    run tsc -p "$MOD/tests/tsconfig.json"
  else
    skip "TypeScript not available (npx or tsc)"
  fi
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "claude plugin test passes" {
  run claude plugin test "$MOD"
  echo "$output"
  [ "$status" -eq 0 ]
}
