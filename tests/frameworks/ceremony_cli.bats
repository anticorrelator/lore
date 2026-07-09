#!/usr/bin/env bats
# ceremony_cli.bats — CLI regression coverage for harness-local ceremony config.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
bats_require_minimum_version 1.5.0

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  command -v jq >/dev/null 2>&1 || skip "jq required for ceremony config"

  TEST_HOME="$(mktemp -d)"
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_HOME/.lore" "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_HOME/.lore/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export LORE_FRAMEWORK=codex

  TEST_KDIR=$(env HOME="$TEST_HOME" LORE_DATA_DIR="$TEST_LORE_DATA_DIR" \
    bash "$REPO_DIR/scripts/resolve-repo.sh")
  mkdir -p "$TEST_KDIR/_work/ceremony-test"
  printf '{"title":"Ceremony test"}\n' > "$TEST_KDIR/_work/ceremony-test/_meta.json"

  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":1,"tui_launch_framework":"codex","harnesses":{"codex":{"args":[],"ceremonies":{"spec-design":["pr-review"]}}}}
EOF
}

teardown() {
  rm -rf "${TEST_HOME:-}" "${TEST_LORE_DATA_DIR:-}"
}

@test "lore ceremony get without --harness handles empty harness args under nounset" {
  run --separate-stderr env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony get spec-design
  [ "$status" -eq 0 ]
  [ "$output" = '["pr-review"]' ]
  [ -z "$stderr" ]
  [ ! -e "$TEST_KDIR/_scorecards/rows.jsonl" ]
}

@test "lore ceremony get leaves an empty registration silent and outcome-free" {
  run --separate-stderr env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony get implement
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ -z "$stderr" ]
  [ ! -e "$TEST_KDIR/_scorecards/rows.jsonl" ]
}

@test "lore ceremony add rejects an advisor missing from the target harness before mutation" {
  before=$(jq -c '.harnesses.codex.ceremonies["spec-design"]' \
    "$TEST_LORE_DATA_DIR/config/settings.json")

  run --separate-stderr env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony \
    --harness codex add spec-design target-only-missing-review

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"unknown ceremony advisor 'target-only-missing-review'"* ]]
  after=$(jq -c '.harnesses.codex.ceremonies["spec-design"]' \
    "$TEST_LORE_DATA_DIR/config/settings.json")
  [ "$after" = "$before" ]
}

@test "a binding made stale after add records a divergence and resolves fail-open" {
  mkdir -p "$TEST_HOME/.codex/skills/transient-ceremony-review"
  run --separate-stderr env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony \
    --harness codex add spec-design transient-ceremony-review
  [ "$status" -eq 0 ]
  [ "$output" = '["pr-review","transient-ceremony-review"]' ]
  [ -z "$stderr" ]

  rm -rf "$TEST_HOME/.codex/skills/transient-ceremony-review"
  run --separate-stderr env HOME="$TEST_HOME" bash "$LORE_CLI" ceremony get \
    spec-design --work-item ceremony-test

  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [[ "$stderr" == *"[ceremony] Divergence:"* ]]
  [[ "$stderr" == *"ceremony='spec-design'"* ]]
  [[ "$stderr" == *"advisor='transient-ceremony-review'"* ]]
  [[ "$stderr" == *"harness='codex'"* ]]
  [[ "$stderr" == *"work_item='ceremony-test'"* ]]
  [[ "$stderr" == *"Corrective action:"* ]]

  [ "$(wc -l < "$TEST_KDIR/_scorecards/rows.jsonl" | tr -d ' ')" -eq 1 ]
  jq -e '
    .kind == "telemetry"
    and .tier == "telemetry"
    and .event_type == "ceremony-resolution"
    and .outcome == "needs-decision"
    and .disposition == "unhandled"
    and .ceremony == "spec-design"
    and .advisor == "transient-ceremony-review"
    and .harness == "codex"
    and .work_item == "ceremony-test"
  ' "$TEST_KDIR/_scorecards/rows.jsonl" >/dev/null
  grep -q 'source: ceremony' "$TEST_KDIR/_work/ceremony-test/execution-log.md"
}
