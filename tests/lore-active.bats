#!/usr/bin/env bats
# lore-active.bats — Shell-level tests for `lore active`, the check a harness
# makes at session start to decide whether lore is loaded in this directory.
#
# Coverage:
#   - each reason: ok, disabled-env, harness-disabled, store-uninitialized
#     (missing manifest, missing work index), lore-unresolved.
#   - the JSON shape and the exit status that carries the answer.
#   - the harness toggle is per-harness: disabling one leaves the others active.
#   - an unregistered harness is a usage error, not a default-on answer.
#   - dispatcher: `lore active` reaches the script and is listed in usage.
#
# Style: pure bats; every test owns its LORE_DATA_DIR, settings file and store.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"
ACTIVE="$REPO_DIR/scripts/active.sh"

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_ROOT="$(mktemp -d)"
  TEST_DATA="$TEST_ROOT/data"
  TEST_STORE="$TEST_ROOT/store"
  mkdir -p "$TEST_DATA/config" "$TEST_STORE/_work"
  printf '{}\n' > "$TEST_STORE/_manifest.json"
  printf '{}\n' > "$TEST_STORE/_work/_index.json"
  printf '{}\n' > "$TEST_DATA/config/settings.json"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# Run the verb against the test's own data dir and store, with the session kill
# switch explicitly off so the caller's environment cannot leak in.
run_active() {
  run env LORE_DATA_DIR="$TEST_DATA" LORE_KNOWLEDGE_DIR="$TEST_STORE" \
    LORE_AGENT_DISABLED="${DISABLED:-}" bash "$ACTIVE" "$@"
}

disable_harness() {
  printf '{"harnesses": {"%s": {"enabled": false}}}\n' "$1" > "$TEST_DATA/config/settings.json"
}

assert_json() {
  printf '%s' "$output" | python3 -c '
import json, sys
got = json.loads(sys.stdin.read())
want = json.loads(sys.argv[1])
assert got == want, (got, want)
' "$1"
}

@test "an initialized store with lore enabled is active" {
  run_active --json
  [ "$status" -eq 0 ]
  assert_json "{\"active\": true, \"harness\": \"claude-code\", \"store\": \"$TEST_STORE\", \"reason\": \"ok\"}"
}

@test "text mode names the harness and store and exits 0 when active" {
  run_active
  [ "$status" -eq 0 ]
  [ "$output" = "active (claude-code): $TEST_STORE" ]
}

@test "LORE_AGENT_DISABLED=1 is inactive with reason disabled-env and no store" {
  DISABLED=1 run_active --json
  [ "$status" -eq 1 ]
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "disabled-env"}'
}

@test "the env kill switch wins over a harness that settings disable too" {
  disable_harness claude-code
  DISABLED=1 run_active --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.reason == "disabled-env"'
}

@test "a harness disabled in settings is inactive with reason harness-disabled" {
  disable_harness claude-code
  run_active --json
  [ "$status" -eq 1 ]
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "harness-disabled"}'
}

@test "disabling one harness leaves another active" {
  disable_harness claude-code
  run_active --harness codex --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.active == true and .harness == "codex" and .reason == "ok"'
}

@test "a store without _manifest.json is inactive with reason store-uninitialized" {
  rm "$TEST_STORE/_manifest.json"
  run_active --json
  [ "$status" -eq 1 ]
  assert_json "{\"active\": false, \"harness\": \"claude-code\", \"store\": \"$TEST_STORE\", \"reason\": \"store-uninitialized\"}"
}

@test "a store without _work/_index.json is inactive with reason store-uninitialized" {
  rm "$TEST_STORE/_work/_index.json"
  run_active --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.reason == "store-uninitialized"'
}

@test "a directory that resolves to a store nobody initialized is inactive" {
  mkdir -p "$TEST_ROOT/plain"
  run bash -c 'cd "$1" && env -u LORE_KNOWLEDGE_DIR LORE_DATA_DIR="$2" LORE_AGENT_DISABLED= bash "$3" --json' \
    _ "$TEST_ROOT/plain" "$TEST_DATA" "$ACTIVE"
  [ "$status" -eq 1 ]
  assert_json "{\"active\": false, \"harness\": \"claude-code\", \"store\": \"$TEST_DATA/repos/local/plain\", \"reason\": \"store-uninitialized\"}"
}

@test "a resolver that names no store is inactive with reason lore-unresolved" {
  # A scripts tree identical to the real one except for its resolver; lib.sh
  # finds its siblings by the directory it was sourced from.
  TREE="$TEST_ROOT/tree"
  mkdir -p "$TREE/scripts"
  ln -s "$REPO_DIR/adapters" "$TREE/adapters"
  for f in "$REPO_DIR"/scripts/*; do ln -s "$f" "$TREE/scripts/"; done
  rm "$TREE/scripts/resolve-repo.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TREE/scripts/resolve-repo.sh"
  chmod +x "$TREE/scripts/resolve-repo.sh"
  run env -u LORE_KNOWLEDGE_DIR LORE_DATA_DIR="$TEST_DATA" LORE_AGENT_DISABLED= \
    bash "$TREE/scripts/active.sh" --json
  [ "$status" -eq 1 ]
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "lore-unresolved"}'
}

@test "text mode names the reason and exits 1 when inactive" {
  disable_harness claude-code
  run_active
  [ "$status" -eq 1 ]
  [ "$output" = "inactive (claude-code): harness-disabled" ]
}

@test "an unregistered harness is a usage error, not an active answer" {
  run_active --harness claud-code --json
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "unknown harness 'claud-code'"
}

@test "--harness without a value is a usage error" {
  run_active --harness
  [ "$status" -eq 2 ]
}

@test "--harness=<fw> is accepted" {
  run_active --harness=opencode --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.harness == "opencode"'
}

@test "lore active dispatches to the script and appears in top-level usage" {
  run env LORE_DATA_DIR="$TEST_DATA" LORE_KNOWLEDGE_DIR="$TEST_STORE" LORE_AGENT_DISABLED= \
    bash "$LORE" active --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.reason == "ok"'
  run bash "$LORE" --help
  echo "$output" | grep -qE '^  active +Say whether lore is loaded'
  grep -qF 'exec "$SCRIPTS_DIR/active.sh" "$@"' "$LORE"
}
