#!/usr/bin/env bats
# session-verbs.bats — Shell-level tests for the `lore session` verb family.
#
# Coverage per task #1 verification:
#   - request: happy path (pending row + `requested` event), validation refusals,
#     extra_context shaping (wrapped prose / verbatim object / file), --json.
#   - list: live-only instance filtering (mtime TTL), all three queues, malformed
#     rows excluded-with-warning.
#   - events: the cursor contract as PROPERTIES — reading from any row-boundary
#     cursor yields the remaining rows and advances to EOF; a torn trailing row
#     never disturbs the complete-row read; any past-EOF cursor resets to a full
#     re-read; interior malformed rows are excluded-with-warning.
#   - close: slug / --self enqueue (`close_requested`), --request cancel
#     (`request_cancelled`), and every refusal path.
#   - dispatcher: no-args usage+exit 1, unknown verb names the failure.
#
# Style: pure bats with an isolated $TEST_KDIR per test (test_packet_append.bats).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"
REQUEST="$REPO_DIR/scripts/session-request.sh"
LIST="$REPO_DIR/scripts/session-list.sh"
EVENTS="$REPO_DIR/scripts/session-events.sh"
CLOSE="$REPO_DIR/scripts/session-close.sh"
SEND="$REPO_DIR/scripts/session-send.sh"
PEEK="$REPO_DIR/scripts/session-peek.sh"
APPEND="$REPO_DIR/scripts/session-event-append.sh"

setup() {
  [ -f "$REQUEST" ] || skip "session-request.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  TEST_KDIR="$(mktemp -d)"
  mkdir -p "$TEST_KDIR/_sessions"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
}

# --- Fixtures --------------------------------------------------------------

# Wait (up to ~10s) for the first request file under _sessions/<subdir> and echo
# its request_id. Used by the send/peek --wait tests to seed an outcome/response
# concurrently, standing in for the owning TUI instance.
wait_request_id() {
  local subdir="$1" f=""
  local _i
  for _i in $(seq 1 100); do
    f="$(ls "$TEST_KDIR/_sessions/$subdir"/*.json 2>/dev/null | head -1)"
    [ -n "$f" ] && { jq -r .request_id "$f"; return 0; }
    sleep 0.1
  done
  return 1
}

# Write a live registry instance hosting one slug.
write_instance() {
  local name="$1" slug="$2"
  mkdir -p "$TEST_KDIR/_sessions/instances"
  cat > "$TEST_KDIR/_sessions/instances/$name.json" <<EOF
{"name":"$name","pid":4242,"repo":"lore","started":"2026-07-05T00:00:00Z","initiator_default":"human","sessions":[{"slug":"$slug","type":"implement","initiator":"human","started":"2026-07-05T00:00:00Z"}]}
EOF
}

# Build events.jsonl directly from explicit compact rows so byte offsets are
# fully controlled by the test (the reader validates JSON only, not schema).
JOURNAL_ROWS=(
  '{"event":"requested","request_id":"r1"}'
  '{"event":"claimed","request_id":"r1"}'
  '{"event":"spawned","request_id":"r1"}'
  '{"event":"closed","request_id":"r1"}'
)

write_journal() {
  local f="$TEST_KDIR/_sessions/events.jsonl"
  : > "$f"
  local line
  for line in "${JOURNAL_ROWS[@]}"; do
    printf '%s\n' "$line" >> "$f"
  done
  echo "$f"
}

# Echo the cumulative byte offset of each row boundary (0 .. file size).
journal_boundaries() {
  local acc=0 line
  echo 0
  for line in "${JOURNAL_ROWS[@]}"; do
    acc=$(( acc + ${#line} + 1 ))
    echo "$acc"
  done
}

# =====================================================================
# Dispatcher
# =====================================================================

@test "session with no args prints usage and exits 1" {
  run bash "$LORE" session
  [ "$status" -eq 1 ]
  [[ "$output" == *"lore session"* ]]
}

@test "session unknown verb names the failure and exits 1" {
  run bash "$LORE" session bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown session verb 'bogus'"* ]]
}

# =====================================================================
# session request
# =====================================================================

@test "request happy path writes a pending row and emits a requested event" {
  run bash "$REQUEST" --type implement --slug wi --target inst-a --initiator agent --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]

  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  [ -f "$pending" ]
  run jq -e '.type=="implement" and .slug=="wi" and .target_instance=="inst-a" and .initiator=="agent" and .attempts==0 and .last_error==null' "$pending"
  [ "$status" -eq 0 ]

  # attempts is a JSON number, not a quoted string (type discipline).
  run jq -e '.attempts | type == "number"' "$pending"
  [ "$status" -eq 0 ]

  run grep -c '"event":"requested"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "request without --type refuses and creates no pending dir" {
  run bash "$REQUEST" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: --type"* ]]
  [ ! -e "$TEST_KDIR/_sessions/requests" ]
}

@test "request with invalid --type refuses" {
  run bash "$REQUEST" --type bogus --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --type"* ]]
}

@test "request with invalid --initiator refuses" {
  run bash "$REQUEST" --type chat --initiator robot --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --initiator"* ]]
}

@test "request wraps plain --context text as a dispatch_guidance object" {
  bash "$REQUEST" --type spec --context "Run /spec and report the plan slug." --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.extra_context.dispatch_guidance == "Run /spec and report the plan slug."' "$pending"
  [ "$status" -eq 0 ]
}

@test "request stores a JSON-object --context verbatim" {
  bash "$REQUEST" --type spec --context '{"priority":"high","asks":["A","B"]}' --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.extra_context.priority == "high" and (.extra_context.asks | length) == 2' "$pending"
  [ "$status" -eq 0 ]
}

@test "request reads --context from a file when the value names one" {
  local cf="$TEST_KDIR/ctx.txt"
  printf 'guidance from a file' > "$cf"
  bash "$REQUEST" --type chat --context "$cf" --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.extra_context.dispatch_guidance == "guidance from a file"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --json emits a structured result" {
  run bash "$REQUEST" --type spec --slug demo --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued == true and .type == "spec" and .slug == "demo" and (.request_id | length > 0)'
}

# =====================================================================
# session list
# =====================================================================

@test "list renders only live instances (mtime TTL drops stale files)" {
  write_instance live-inst alpha
  write_instance stale-inst beta
  # Age the stale instance well past the default 30s TTL.
  touch -t 202601010000 "$TEST_KDIR/_sessions/instances/stale-inst.json"

  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.instances | length) == 1 and .instances[0].name == "live-inst"'
}

@test "list surfaces pending, claimed, and close-request queues" {
  mkdir -p "$TEST_KDIR"/_sessions/requests/pending \
           "$TEST_KDIR"/_sessions/requests/claimed \
           "$TEST_KDIR"/_sessions/close-requests
  echo '{"request_id":"p1","type":"spec","slug":null,"target_instance":null}' > "$TEST_KDIR/_sessions/requests/pending/p1.json"
  echo '{"request_id":"c1","type":"chat","claimed_by":"inst-a"}' > "$TEST_KDIR/_sessions/requests/claimed/c1.json"
  echo '{"request_id":"x1","slug":"wi","target_instance":"inst-a","reason":"human"}' > "$TEST_KDIR/_sessions/close-requests/x1.json"

  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.pending|length)==1 and (.claimed|length)==1 and (.close_requests|length)==1'
}

@test "list excludes a malformed row with a stderr warning, never rewriting it" {
  mkdir -p "$TEST_KDIR/_sessions/requests/pending"
  local good="$TEST_KDIR/_sessions/requests/pending/good.json"
  local bad="$TEST_KDIR/_sessions/requests/pending/bad.json"
  echo '{"request_id":"good","type":"spec"}' > "$good"
  printf 'NOT JSON{' > "$bad"
  local before; before="$(cat "$bad")"

  # Capture stdout and stderr separately so the warning does not pollute the JSON.
  local err="$TEST_KDIR/err"
  local out; out="$(bash "$LIST" --kdir "$TEST_KDIR" --json 2>"$err")"
  echo "$out" | jq -e '(.pending|length)==1 and .pending[0].request_id=="good"'
  grep -q "corrupt" "$err"                 # warning surfaced on stderr
  [ "$(cat "$bad")" = "$before" ]          # malformed row untouched
}

# =====================================================================
# session events — cursor contract as properties
# =====================================================================

@test "events: reading from any row-boundary cursor yields the remaining rows and advances to EOF" {
  write_journal >/dev/null
  local -a bounds=(); local _b
  while IFS= read -r _b; do bounds+=("$_b"); done < <(journal_boundaries)
  local size="${bounds[${#bounds[@]}-1]}"
  local total="${#JOURNAL_ROWS[@]}"

  local idx
  for idx in "${!bounds[@]}"; do
    local cursor="${bounds[$idx]}"
    local out; out="$(bash "$EVENTS" --kdir "$TEST_KDIR" --since "$cursor" --json 2>/dev/null)"
    local n; n="$(echo "$out" | jq -r '.events | length')"
    local nc; nc="$(echo "$out" | jq -r '.next_cursor')"
    # Property: rows returned == rows whose boundary is at/after the cursor.
    [ "$n" -eq $(( total - idx )) ] || { echo "cursor=$cursor n=$n expected=$(( total - idx ))"; false; }
    # Property: next_cursor always lands at EOF once all remaining rows are read.
    [ "$nc" -eq "$size" ] || { echo "cursor=$cursor next_cursor=$nc size=$size"; false; }
  done
}

@test "events: a torn trailing row never disturbs the complete-row read; cursor stops before it" {
  local f; f="$(write_journal)"
  local -a bounds=(); local _b
  while IFS= read -r _b; do bounds+=("$_b"); done < <(journal_boundaries)
  local size="${bounds[${#bounds[@]}-1]}"
  local total="${#JOURNAL_ROWS[@]}"

  local fragment
  for fragment in '{' '{"event":"spawned"' '{"event":"spawned","request_id":"r2"'; do
    # Restore the clean journal, then append an unterminated fragment.
    write_journal >/dev/null
    printf '%s' "$fragment" >> "$f"

    local out; out="$(bash "$EVENTS" --kdir "$TEST_KDIR" --json 2>/dev/null)"
    local n; n="$(echo "$out" | jq -r '.events | length')"
    local nc; nc="$(echo "$out" | jq -r '.next_cursor')"
    [ "$n" -eq "$total" ] || { echo "fragment='$fragment' n=$n expected=$total"; false; }
    [ "$nc" -eq "$size" ] || { echo "fragment='$fragment' next_cursor=$nc size=$size"; false; }
  done
}

@test "events: any past-EOF cursor resets to a full re-read with a warning" {
  write_journal >/dev/null
  local -a bounds=(); local _b
  while IFS= read -r _b; do bounds+=("$_b"); done < <(journal_boundaries)
  local size="${bounds[${#bounds[@]}-1]}"
  local total="${#JOURNAL_ROWS[@]}"

  local delta
  for delta in 1 50 9999; do
    local cursor=$(( size + delta ))
    local err="$TEST_KDIR/err.$delta"
    local out; out="$(bash "$EVENTS" --kdir "$TEST_KDIR" --since "$cursor" --json 2>"$err")"
    local n; n="$(echo "$out" | jq -r '.events | length')"
    local nc; nc="$(echo "$out" | jq -r '.next_cursor')"
    [ "$n" -eq "$total" ] || { echo "delta=$delta n=$n expected=$total"; false; }
    [ "$nc" -eq "$size" ] || { echo "delta=$delta next_cursor=$nc size=$size"; false; }
    grep -q "resetting to full re-read" "$err" || { echo "delta=$delta: missing reset warning"; false; }
  done
}

@test "events: an interior malformed row is excluded-with-warning and the read continues" {
  local f="$TEST_KDIR/_sessions/events.jsonl"
  {
    printf '%s\n' '{"event":"requested","request_id":"a"}'
    printf '%s\n' 'THIS IS NOT JSON'
    printf '%s\n' '{"event":"closed","request_id":"a"}'
  } > "$f"
  local size; size="$(wc -c < "$f" | tr -d ' ')"

  local err="$TEST_KDIR/err"
  local out; out="$(bash "$EVENTS" --kdir "$TEST_KDIR" --json 2>"$err")"
  echo "$out" | jq -e '(.events|length)==2 and .events[0].event=="requested" and .events[1].event=="closed"'
  # Cursor advances to EOF because a valid row follows the malformed one.
  [ "$(echo "$out" | jq -r '.next_cursor')" -eq "$size" ]
  grep -q "corrupt" "$err"
}

@test "events: an empty journal returns no rows at cursor 0" {
  run bash "$EVENTS" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.events|length)==0 and .next_cursor==0'
}

# =====================================================================
# session close
# =====================================================================

@test "close <slug> writes a close-request file and emits close_requested" {
  write_instance inst-a feature-x
  run bash "$CLOSE" feature-x --reason coordinator --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .slug=="feature-x" and .target_instance=="inst-a" and .reason=="coordinator"'

  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '.reason=="coordinator" and .target_instance=="inst-a" and (.requested_at|length>0)' "$cr"
  [ "$status" -eq 0 ]

  run grep -c '"event":"close_requested"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "close <slug> refuses when no live instance runs the slug" {
  run bash "$CLOSE" ghost --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live instance is running session 'ghost'"* ]]
}

@test "close --self self-addresses from LORE_SESSION_* env" {
  run env LORE_SESSION_INSTANCE=inst-a LORE_SESSION_SLUG=feature-x \
    bash "$CLOSE" --self --reason protocol_terminus --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.target_instance=="inst-a" and .slug=="feature-x" and .reason=="protocol_terminus"'
  run grep -c '"event":"close_requested"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "close --self refuses without LORE_SESSION_INSTANCE" {
  run env -u LORE_SESSION_INSTANCE bash "$CLOSE" --self --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--self requires LORE_SESSION_INSTANCE"* ]]
}

@test "close --request cancels a pending spawn row and emits request_cancelled" {
  local rid; rid="$(bash "$REQUEST" --type chat --slug wi --kdir "$TEST_KDIR" --json | jq -r .request_id)"
  [ -f "$TEST_KDIR/_sessions/requests/pending/$rid.json" ]

  run bash "$CLOSE" --request "$rid" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.cancelled==true'
  [ ! -f "$TEST_KDIR/_sessions/requests/pending/$rid.json" ]

  run grep -c '"event":"request_cancelled"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "close --request refuses a nonexistent id" {
  run bash "$CLOSE" --request no-such-id --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pending request 'no-such-id'"* ]]
}

@test "close refuses an ambiguous form (slug plus --self)" {
  run bash "$CLOSE" feature-x --self --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]]
}

@test "close refuses an invalid --reason" {
  write_instance inst-a feature-x
  run bash "$CLOSE" feature-x --reason nonsense --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --reason"* ]]
}

# =====================================================================
# session send
# =====================================================================

@test "send <slug> <message> enqueues a send-request and emits send_requested" {
  write_instance inst-a feature-x
  run bash "$SEND" feature-x "hello world" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .slug=="feature-x" and .target_instance=="inst-a"'

  local sr; sr="$(ls "$TEST_KDIR"/_sessions/send-requests/*.json)"
  run jq -e '.body=="hello world" and .target_instance=="inst-a" and (.requested_at|length>0)' "$sr"
  [ "$status" -eq 0 ]

  run grep -c '"event":"send_requested"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "send refuses when no live instance runs the slug" {
  run bash "$SEND" ghost "hi" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live instance is running session 'ghost'"* ]]
}

@test "send refuses a missing message" {
  write_instance inst-a feature-x
  run bash "$SEND" feature-x --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no message"* ]]
}

@test "send --wait maps a sent outcome to exit 0" {
  write_instance inst-a feature-x
  ( rid="$(wait_request_id send-requests)"
    echo '{"event":"sent","request_id":"'"$rid"'","slug":"feature-x"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$SEND" feature-x "hi" --wait --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sent to 'feature-x'"* ]]
}

@test "send --wait maps a send_refused outcome to exit 3" {
  write_instance inst-a feature-x
  ( rid="$(wait_request_id send-requests)"
    echo '{"event":"send_refused","request_id":"'"$rid"'","slug":"feature-x","reason":"modal"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$SEND" feature-x "hi" --wait --timeout 10 --json --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 3 ]
  # JSON on stdout, human line on stderr; bats run combines them, so match the
  # refusal fields as substrings rather than parsing the merged stream.
  [[ "$output" == *'"refused": true'* ]]
  [[ "$output" == *'"reason": "modal"'* ]]
}

@test "send --wait times out to exit 1 when no outcome lands" {
  write_instance inst-a feature-x
  run bash "$SEND" feature-x "hi" --wait --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

# =====================================================================
# session peek
# =====================================================================

@test "peek returns the seeded screen rows and deletes the response on read" {
  write_instance inst-a feature-x
  ( rid="$(wait_request_id peek-requests)"
    mkdir -p "$TEST_KDIR/_sessions/peek-responses"
    printf '%s\n' '{"request_id":"'"$rid"'","slug":"feature-x","captured_at":"t","ready":true,"blocked_reason":"","rows":["prompt line","second row"]}' \
      > "$TEST_KDIR/_sessions/peek-responses/$rid.json" ) &
  run bash "$PEEK" feature-x --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt line"* ]]
  [[ "$output" == *"ready=true"* ]]
  [ -z "$(ls "$TEST_KDIR"/_sessions/peek-responses/ 2>/dev/null)" ]
  # Peek is a read: it emits no journal events.
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "peek refuses when no live instance runs the slug" {
  run bash "$PEEK" ghost --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live instance is running session 'ghost'"* ]]
}

@test "peek times out to exit 1 and cleans up its request" {
  write_instance inst-a feature-x
  run bash "$PEEK" feature-x --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
  [ -z "$(ls "$TEST_KDIR"/_sessions/peek-requests/ 2>/dev/null)" ]
}
