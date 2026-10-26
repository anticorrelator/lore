#!/usr/bin/env bats
# lore-active.bats — Shell-level tests for `lore active`, the check a harness
# makes at session start to decide whether lore is loaded in this directory.
#
# Coverage:
#   - each reason: ok, disabled-env, harness-disabled, store-uninitialized
#     (missing manifest, missing work index), lore-unresolved.
#   - the JSON shape and the exit status that carries the answer.
#   - arc: the active arc listing the session's work item, read through a
#     managed manifest or the session slug; null for a non-member, outside a
#     session, for a closed or archived arc, and when lore is inactive.
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
# switch and session slug explicitly set so the caller's environment cannot leak
# in.
run_active() {
  run env LORE_DATA_DIR="$TEST_DATA" LORE_KNOWLEDGE_DIR="$TEST_STORE" \
    LORE_AGENT_DISABLED="${DISABLED:-}" LORE_SESSION_SLUG="${SESSION:-}" bash "$ACTIVE" "$@"
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

# make_arc <slug> <status> <opened> <member>...
make_arc() {
  local slug="$1" status="$2" opened="$3"
  shift 3
  mkdir -p "$TEST_STORE/_work/_arcs/$slug"
  jq -n --arg slug "$slug" --arg status "$status" --arg opened "$opened" \
    '{schema_version: 1, slug: $slug, status: $status, opened: $opened, members: $ARGS.positional}' \
    --args "$@" > "$TEST_STORE/_work/_arcs/$slug/_meta.json"
}

# make_managed_session <handle> <work item>
make_managed_session() {
  mkdir -p "$TEST_STORE/_sessions/managed"
  jq -n --arg handle "$1" --arg item "$2" '{schema_version: 1, handle: $handle, work_item: $item}' \
    > "$TEST_STORE/_sessions/managed/$1.json"
}

@test "an initialized store with lore enabled is active" {
  run_active --json
  [ "$status" -eq 0 ]
  assert_json "{\"active\": true, \"harness\": \"claude-code\", \"store\": \"$TEST_STORE\", \"reason\": \"ok\", \"arc\": null}"
}

@test "text mode names the harness and store and exits 0 when active" {
  run_active
  [ "$status" -eq 0 ]
  [ "$output" = "active (claude-code): $TEST_STORE" ]
}

@test "LORE_AGENT_DISABLED=1 is inactive with reason disabled-env and no store" {
  DISABLED=1 run_active --json
  [ "$status" -eq 1 ]
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "disabled-env", "arc": null}'
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
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "harness-disabled", "arc": null}'
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
  assert_json "{\"active\": false, \"harness\": \"claude-code\", \"store\": \"$TEST_STORE\", \"reason\": \"store-uninitialized\", \"arc\": null}"
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
  assert_json "{\"active\": false, \"harness\": \"claude-code\", \"store\": \"$TEST_DATA/repos/local/plain\", \"reason\": \"store-uninitialized\", \"arc\": null}"
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
  assert_json '{"active": false, "harness": "claude-code", "store": null, "reason": "lore-unresolved", "arc": null}'
}

@test "a session whose work item an active arc lists reports that arc" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-b item-a
  make_managed_session item-a--w8 item-a
  SESSION=item-a--w8 run_active --json
  [ "$status" -eq 0 ]
  assert_json "{\"active\": true, \"harness\": \"claude-code\", \"store\": \"$TEST_STORE\", \"reason\": \"ok\", \"arc\": \"arc-one\"}"
}

@test "a managed session's item comes from its manifest, not its handle" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-a
  make_arc arc-two active 2026-10-02T00:00:00Z renamed
  make_managed_session renamed--w2 item-a
  SESSION=renamed--w2 run_active --json
  printf '%s' "$output" | jq -e '.arc == "arc-one"'
}

@test "a session with no manifest is read by its slug: a worker's base item, else the slug" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-a
  SESSION=item-a--w3 run_active --json
  printf '%s' "$output" | jq -e '.arc == "arc-one"'
  SESSION=item-a run_active --json
  printf '%s' "$output" | jq -e '.arc == "arc-one"'
}

@test "a session whose work item no active arc lists reports a null arc" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-b
  make_managed_session item-a--w8 item-a
  SESSION=item-a--w8 run_active --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("arc") and .arc == null'
}

@test "outside a lore session the arc is null" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-a
  run_active --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'has("arc") and .arc == null'
}

@test "a closed or archived arc listing the item is not reported" {
  make_arc arc-one archived 2026-10-01T00:00:00Z item-a
  make_arc arc-two closed 2026-10-02T00:00:00Z item-a
  SESSION=item-a run_active --json
  printf '%s' "$output" | jq -e '.arc == null'
}

@test "of two active arcs listing the item the later opened is reported, past a record that will not parse" {
  make_arc arc-one active 2026-10-02T00:00:00Z item-a
  make_arc arc-two active 2026-10-01T00:00:00Z item-a
  mkdir -p "$TEST_STORE/_work/_arcs/broken"
  printf '{"status": "active", "members": ["item-a"' > "$TEST_STORE/_work/_arcs/broken/_meta.json"
  SESSION=item-a run_active --json
  printf '%s' "$output" | jq -e '.arc == "arc-one"'
}

@test "inside an arc member's session the text output and exit status are unchanged" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-a
  SESSION=item-a run_active
  [ "$status" -eq 0 ]
  [ "$output" = "active (claude-code): $TEST_STORE" ]
}

@test "an inactive answer reports a null arc inside an arc member's session" {
  make_arc arc-one active 2026-10-01T00:00:00Z item-a
  DISABLED=1 SESSION=item-a run_active --json
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.arc == null'
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
