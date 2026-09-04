#!/usr/bin/env bats
REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  mkdir -p "$TEST_KDIR/conventions" "$TEST_KDIR/_sessions/instances"
  printf '# Entry\n\nA claim.\n' > "$TEST_KDIR/conventions/entry.md"
  printf '%s\n' '{"name":"position-test","sessions":[{"slug":"fixture","type":"implement","request_id":"spawn-1"}]}' > "$TEST_KDIR/_sessions/instances/position-test.json"
  export LORE_SESSION_INSTANCE=position-test LORE_SESSION_SLUG=fixture LORE_SESSION_TYPE=implement
}

teardown() {
  rm -rf "$TEST_KDIR"
  unset LORE_KNOWLEDGE_DIR LORE_SESSION_INSTANCE LORE_SESSION_SLUG LORE_SESSION_TYPE
}

@test "position and legacy verification sources survive trust reader round trips" {
  for source in investigator designer worker reviewer researcher spec-lead implement-lead; do
    run bash "$REPO_DIR/scripts/verify-append.sh" conventions/entry.md held \
      --source "$source" --file /fixture/code.py --line-range 1-1 --exact-snippet 'a = 1' --kdir "$TEST_KDIR"
    [ "$status" -eq 0 ]
  done
  run bash "$REPO_DIR/scripts/verify-report.sh" --entry conventions/entry.md --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | sed -n '/{/,$p' | jq -e '[.. | objects | .source? // empty] | unique | sort == (["investigator","designer","worker","reviewer","researcher","spec-lead","implement-lead"] | sort)'
  [ ! -e "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "position and legacy terminus reasons preserve deterministic duplicate handling" {
  for reason in investigator designer worker reviewer spec-finalize impl-close; do
    for repeat in 1 2; do
      run bash "$REPO_DIR/scripts/session-terminus.sh" --reason "$reason" --kdir "$TEST_KDIR" --json
      [ "$status" -eq 0 ]
    done
  done
  run bash "$REPO_DIR/scripts/session-events.sh" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.vocabulary_version == "2" and (.events | length) == 6 and ([.events[].reason] | sort) == (["investigator","designer","worker","reviewer","spec-finalize","impl-close"] | sort) and all(.events[]; .event == "terminus_reached" and (has("request_id") | not))'
}

@test "unknown position labels are rejected by every writer without appending" {
  run bash "$REPO_DIR/scripts/verify-append.sh" conventions/entry.md held --source unknown-position --file /fixture/code.py --line-range 1-1 --exact-snippet 'a = 1' --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/trust-event-append.sh" --event consumption-verification --entry-path conventions/entry.md --source unknown-position --disposition held --file /fixture/code.py --line-range 1-1 --exact-snippet 'a = 1' --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/session-terminus.sh" --reason unknown-position --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  run bash "$REPO_DIR/scripts/session-event-append.sh" --row '{"event":"terminus_reached","reason":"unknown-position","actor_instance":"position-test","slug":"fixture","session_type":"implement"}' --kdir "$TEST_KDIR"
  [ "$status" -ne 0 ]
  for reason in '[]' '{}' '1' 'null'; do
    row="$(jq -cn --argjson reason "$reason" '{event:"terminus_reached",reason:$reason,actor_instance:"position-test",slug:"fixture",session_type:"implement"}')"
    run bash "$REPO_DIR/scripts/session-event-append.sh" --row "$row" --kdir "$TEST_KDIR"
    [ "$status" -ne 0 ]
  done
  [ ! -e "$TEST_KDIR/_trust/trust-events.jsonl" ]
  [ ! -e "$TEST_KDIR/_sessions/events.jsonl" ]
}
