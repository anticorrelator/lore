#!/usr/bin/env bats
# ceremony_cli.bats — CLI regression coverage for harness-local ceremony config.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  command -v jq >/dev/null 2>&1 || skip "jq required for ceremony config"

  TEST_HOME="$(mktemp -d)"
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_HOME/.lore" "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_HOME/.lore/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK

  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":1,"active_framework":"codex","harnesses":{"codex":{"args":[],"ceremonies":{"spec-design":["pr-review"]}}}}
EOF
}

teardown() {
  rm -rf "${TEST_HOME:-}" "${TEST_LORE_DATA_DIR:-}"
}

@test "lore ceremony get without --harness handles empty harness args under nounset" {
  run env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony get spec-design
  [ "$status" -eq 0 ]
  [ "$output" = '["pr-review"]' ]
}
