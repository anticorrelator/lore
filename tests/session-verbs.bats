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
ANSWER="$REPO_DIR/scripts/session-answer.sh"
PEEK="$REPO_DIR/scripts/session-peek.sh"
WAIT="$REPO_DIR/scripts/session-wait.sh"
APPEND="$REPO_DIR/scripts/session-event-append.sh"
STEP="$REPO_DIR/scripts/session-step.sh"
TERMINUS="$REPO_DIR/scripts/session-terminus.sh"
COORDINATE="$REPO_DIR/scripts/coordinate-status.sh"

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

# Write a live registry instance hosting one session that carries a harness
# session_id. Pass an empty slug ("") to model a slugless session — the case
# only session_id can address across instances.
write_instance_session() {
  local name="$1" slug="$2" sid="$3"
  mkdir -p "$TEST_KDIR/_sessions/instances"
  cat > "$TEST_KDIR/_sessions/instances/$name.json" <<EOF
{"name":"$name","pid":4242,"repo":"lore","started":"2026-07-05T00:00:00Z","initiator_default":"human","sessions":[{"slug":"$slug","type":"chat","initiator":"human","started":"2026-07-05T00:00:00Z","session_id":"$sid"}]}
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

@test "request --type worker with a derived slug writes a pending row" {
  run bash "$REQUEST" --type worker --slug "impl-foo--w1" --initiator agent --context "brief body" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.type=="worker" and .slug=="impl-foo--w1"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --type worker without --slug refuses" {
  run bash "$REQUEST" --type worker --initiator agent --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--slug is required for --type worker"* ]]
}

@test "request --type worker with --track refuses (track is spec-only)" {
  run bash "$REQUEST" --type worker --slug "impl-foo--w1" --track short --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--track is valid only for --type spec"* ]]
}

@test "requested event for a worker derives links.work_item from the derived slug" {
  bash "$REQUEST" --type worker --slug "impl-foo--w1" --initiator agent --kdir "$TEST_KDIR"
  run jq -e 'select(.event=="requested") | .links.work_item == "impl-foo"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "request omits auto_close when the flag is not passed" {
  bash "$REQUEST" --type spec --slug wi --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e 'has("auto_close") | not' "$pending"
  [ "$status" -eq 0 ]
}

@test "request omits framework when the flag is not passed" {
  bash "$REQUEST" --type spec --slug wi --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e 'has("framework") | not' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --framework writes the framework field" {
  bash "$REQUEST" --type implement --slug wi --framework codex --min-vintage 2026-07-05T12:00:00Z --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.framework == "codex"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request with invalid --framework refuses before enqueue" {
  run bash "$REQUEST" --type spec --slug wi --framework bogus --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--framework"* ]]
  [ ! -e "$TEST_KDIR/_sessions/requests" ]
}

@test "request --framework without --min-vintage emits an advisory but enqueues" {
  local err="$TEST_KDIR/framework.err"
  local out
  out="$(bash "$REQUEST" --type implement --slug wi --framework codex --kdir "$TEST_KDIR" 2>"$err")"
  [[ "$out" == *"Enqueued implement request"* ]]
  [ "$(wc -l < "$err" | tr -d ' ')" -eq 1 ]
  grep -q -- "--min-vintage" "$err"

  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.framework == "codex"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request omits prefer_project_dir when neither prefer flag is passed" {
  bash "$REQUEST" --type spec --slug wi --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e 'has("prefer_project_dir") | not' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --prefer-dir stores the physically-resolved directory" {
  local target; target="$(mkdir -p "$TEST_KDIR/checkout" && cd "$TEST_KDIR/checkout" && pwd -P)"
  bash "$REQUEST" --type implement --slug wi --prefer-dir "$TEST_KDIR/checkout" --min-vintage 2026-07-05T12:00:00Z --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e --arg d "$target" '.prefer_project_dir == $d' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --prefer-dir collapses a symlink to its physical target" {
  mkdir -p "$TEST_KDIR/realdir"
  ln -s "$TEST_KDIR/realdir" "$TEST_KDIR/linkdir"
  local physical; physical="$(cd "$TEST_KDIR/realdir" && pwd -P)"
  bash "$REQUEST" --type implement --slug wi --prefer-dir "$TEST_KDIR/linkdir" --min-vintage 2026-07-05T12:00:00Z --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e --arg d "$physical" '.prefer_project_dir == $d' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --prefer-cwd captures the physically-resolved working directory" {
  mkdir -p "$TEST_KDIR/here"
  local physical; physical="$(cd "$TEST_KDIR/here" && pwd -P)"
  ( cd "$TEST_KDIR/here" && bash "$REQUEST" --type chat --prefer-cwd --min-vintage 2026-07-05T12:00:00Z --kdir "$TEST_KDIR" )
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e --arg d "$physical" '.prefer_project_dir == $d' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --prefer-dir naming a nonexistent path refuses before enqueue" {
  run bash "$REQUEST" --type spec --slug wi --prefer-dir /nonexistent/path/xyzzy --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"prefer_project_dir"* ]]
  [ ! -e "$TEST_KDIR/_sessions/requests" ]
}

@test "request refuses --prefer-dir and --prefer-cwd together" {
  run bash "$REQUEST" --type spec --slug wi --prefer-dir "$TEST_KDIR" --prefer-cwd --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [ ! -e "$TEST_KDIR/_sessions/requests" ]
}

@test "request --prefer-cwd without --min-vintage emits an advisory but enqueues" {
  local err="$TEST_KDIR/prefer.err"
  local out
  out="$(bash "$REQUEST" --type implement --slug wi --prefer-cwd --kdir "$TEST_KDIR" 2>"$err")"
  [[ "$out" == *"Enqueued implement request"* ]]
  grep -q -- "--min-vintage" "$err"

  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e 'has("prefer_project_dir")' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --auto-close true writes a JSON boolean" {
  bash "$REQUEST" --type spec --slug wi --auto-close true --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.auto_close == true and (.auto_close | type == "boolean")' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --auto-close false holds an agent session open" {
  bash "$REQUEST" --type implement --slug wi --initiator agent --auto-close false --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.auto_close == false and (.auto_close | type == "boolean")' "$pending"
  [ "$status" -eq 0 ]
}

@test "request with invalid --auto-close refuses" {
  run bash "$REQUEST" --type spec --auto-close maybe --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --auto-close"* ]]
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

@test "request --route writes a routing_overrides map" {
  bash "$REQUEST" --type implement --slug wi --route worker=opus --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.routing_overrides.worker == "opus" and (.routing_overrides | type == "object")' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --route is repeatable across roles" {
  bash "$REQUEST" --type implement --slug wi --route worker=opus --route reviewer=haiku --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.routing_overrides.worker == "opus" and .routing_overrides.reviewer == "haiku"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request --route accepts a hyphenated class-qualified role" {
  bash "$REQUEST" --type implement --slug wi --route worker-mechanical=haiku --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e '.routing_overrides."worker-mechanical" == "haiku"' "$pending"
  [ "$status" -eq 0 ]
}

@test "request with an unknown --route role refuses naming the registry" {
  run bash "$REQUEST" --type implement --slug wi --route bogus=opus --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown role 'bogus'"* ]]
  [[ "$output" == *"roles.json"* ]]
}

@test "request with a malformed --route spec refuses" {
  run bash "$REQUEST" --type implement --slug wi --route worker --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --route"* ]]
}

@test "request omits routing_overrides when no --route is passed" {
  bash "$REQUEST" --type spec --slug wi --kdir "$TEST_KDIR"
  local pending; pending="$(ls "$TEST_KDIR"/_sessions/requests/pending/*.json)"
  run jq -e 'has("routing_overrides") | not' "$pending"
  [ "$status" -eq 0 ]
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

@test "list JSON declares its fold and vocabulary versions" {
  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fold_version=="1" and .vocabulary_version=="1"'
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

@test "list renders a slugless session as chat:<short-id> instead of a blank slug" {
  write_instance_session inst-b "" deadbeef-0000-0000-0000-000000000000
  run bash "$LIST" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  # The slugless session is visible, keyed by the same short id close --session accepts.
  [[ "$output" == *"chat:deadbeef"* ]]
  # And never as an empty "sessions: " tail.
  [[ "$output" != *"sessions: "$'\n'* ]]
}

@test "list renders a slugless session with no session_id as chat:?" {
  write_instance inst-b ""   # empty slug, no session_id field
  run bash "$LIST" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"chat:?"* ]]
}

@test "list still renders a slugged session by its slug" {
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$LIST" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sessions: feature-x"* ]]
  [[ "$output" != *"chat:"* ]]
}

@test "list renders framework @ project_dir on the instance line" {
  mkdir -p "$TEST_KDIR/_sessions/instances"
  cat > "$TEST_KDIR/_sessions/instances/inst-a.json" <<EOF
{"name":"inst-a","pid":4242,"repo":"lore","framework":"codex","project_dir":"/work/checkout-a","started":"2026-07-05T00:00:00Z","initiator_default":"human","sessions":[]}
EOF
  run bash "$LIST" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex @ /work/checkout-a"* ]]
}

@test "list renders unknown for an instance row lacking framework and project_dir" {
  # write_instance emits a pre-feature row (no framework/project_dir fields).
  write_instance inst-a feature-x
  run bash "$LIST" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown @ unknown"* ]]
}

@test "list --json passes instance framework and project_dir through untouched" {
  mkdir -p "$TEST_KDIR/_sessions/instances"
  cat > "$TEST_KDIR/_sessions/instances/inst-a.json" <<EOF
{"name":"inst-a","pid":4242,"repo":"lore","framework":"claude-code","project_dir":"/work/checkout-a","started":"2026-07-05T00:00:00Z","initiator_default":"human","sessions":[]}
EOF
  run bash "$LIST" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.instances[0].framework == "claude-code" and .instances[0].project_dir == "/work/checkout-a"'
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

@test "events JSON declares its fold and vocabulary versions" {
  : > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$EVENTS" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.fold_version=="1" and .vocabulary_version=="1"'
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

@test "events: plain mode emits the cursor as a final stdout row and nothing on stderr" {
  write_journal >/dev/null
  local -a bounds=(); local _b
  while IFS= read -r _b; do bounds+=("$_b"); done < <(journal_boundaries)
  local size="${bounds[${#bounds[@]}-1]}"
  local total="${#JOURNAL_ROWS[@]}"

  local err="$TEST_KDIR/err"
  local out; out="$(bash "$EVENTS" --kdir "$TEST_KDIR" 2>"$err")"
  # Every line is one JSON value; the last is the cursor row, the rest are events.
  local lines; lines="$(printf '%s\n' "$out" | grep -c .)"
  [ "$lines" -eq $(( total + 1 )) ] || { echo "lines=$lines expected=$(( total + 1 ))"; false; }
  local last; last="$(printf '%s\n' "$out" | tail -n1)"
  [ "$(printf '%s' "$last" | jq -r '.next_cursor')" -eq "$size" ]
  # Event rows carry .event; the cursor row does not.
  [ "$(printf '%s\n' "$out" | head -n"$total" | jq -rs 'map(has("event")) | all')" = "true" ]
  # A clean read writes nothing to stderr — the cursor is data and rides stdout.
  [ ! -s "$err" ]
}

@test "events: --cursor-only prints the bare journal byte size without replaying rows" {
  write_journal >/dev/null
  local size; size="$(wc -c < "$TEST_KDIR/_sessions/events.jsonl" | tr -d ' ')"
  run bash "$EVENTS" --cursor-only --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "$size" ]                       # bare integer, equal to EOF offset
  [[ "$output" != *'{'* ]]                      # no row replayed
}

@test "events: --cursor-only on an absent journal prints 0" {
  run bash "$EVENTS" --cursor-only --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "events: --tail N emits the last N event rows plus the cursor row" {
  write_journal >/dev/null
  local size; size="$(wc -c < "$TEST_KDIR/_sessions/events.jsonl" | tr -d ' ')"
  local out; out="$(bash "$EVENTS" --tail 2 --kdir "$TEST_KDIR" 2>/dev/null)"
  # 2 event rows + 1 cursor row.
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 3 ]
  # Last two events of the fixture are spawned then closed.
  [ "$(printf '%s\n' "$out" | jq -rs '[.[] | select(has("event")) | .event] | join(",")')" = "spawned,closed" ]
  [ "$(printf '%s\n' "$out" | tail -n1 | jq -r '.next_cursor')" -eq "$size" ]
}

@test "events: --tail rejects a non-positive count" {
  write_journal >/dev/null
  run bash "$EVENTS" --tail 0 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --tail"* ]]
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

@test "close --retire-close-request appends the exact deterministic terminal before deleting" {
  local rid="close-legacy-1" target="dead-inst"
  mkdir -p "$TEST_KDIR/_sessions/close-requests"
  printf '%s\n' '{"request_id":"close-legacy-1","slug":"feature-x","target_instance":"dead-inst","reason":"human","requested_by":"operator","requested_at":"2026-07-11T00:00:00Z"}' \
    > "$TEST_KDIR/_sessions/close-requests/$rid.json"

  run bash "$CLOSE" --retire-close-request "$rid" --requested-by coordinator-a --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_KDIR/_sessions/close-requests/$rid.json" ]

  local expected_id
  expected_id="close-failed-dead-target-$(python3 - "$target" "$rid" <<'PYEOF'
import hashlib, sys
print(hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:32])
PYEOF
)"
  run jq -e --arg id "$expected_id" \
    'select(.event == "close_failed")
     | .event_id == $id and .request_id == "close-legacy-1"
       and .target_instance == "dead-inst" and .actor_instance == "coordinator-a"
       and .slug == "feature-x" and .reason == "target-instance-dead"' \
    "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "close --retire-close-request keeps the queue row when the terminal append fails" {
  local rid="close-legacy-2" target="dead-inst" event_id
  mkdir -p "$TEST_KDIR/_sessions/close-requests"
  printf '%s\n' '{"request_id":"close-legacy-2","slug":"feature-x","target_instance":"dead-inst","reason":"human"}' \
    > "$TEST_KDIR/_sessions/close-requests/$rid.json"
  event_id="close-failed-dead-target-$(python3 - "$target" "$rid" <<'PYEOF'
import hashlib, sys
print(hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:32])
PYEOF
)"
  bash "$APPEND" --row "{\"event_id\":\"$event_id\",\"event\":\"close_failed\",\"request_id\":\"different\",\"reason\":\"error\"}" --kdir "$TEST_KDIR" >/dev/null

  run bash "$CLOSE" --retire-close-request "$rid" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"request was not deleted"* ]]
  [ -f "$TEST_KDIR/_sessions/close-requests/$rid.json" ]
}

@test "close --retire-close-request refuses a currently live target" {
  local rid="close-live-1"
  write_instance inst-a feature-x
  mkdir -p "$TEST_KDIR/_sessions/close-requests"
  printf '%s\n' '{"request_id":"close-live-1","slug":"feature-x","target_instance":"inst-a","reason":"human"}' \
    > "$TEST_KDIR/_sessions/close-requests/$rid.json"

  run bash "$CLOSE" --retire-close-request "$rid" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"target instance 'inst-a' is currently live"* ]]
  [ -f "$TEST_KDIR/_sessions/close-requests/$rid.json" ]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "close --retire-close-request replays idempotently after append-before-delete interruption" {
  local rid="close-replay-1" row
  mkdir -p "$TEST_KDIR/_sessions/close-requests"
  row='{"request_id":"close-replay-1","slug":"feature-x","target_instance":"dead-inst","reason":"human"}'
  printf '%s\n' "$row" > "$TEST_KDIR/_sessions/close-requests/$rid.json"
  run bash "$CLOSE" --retire-close-request "$rid" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]

  # Model a crash after append but before delete by restoring the exact queue row.
  printf '%s\n' "$row" > "$TEST_KDIR/_sessions/close-requests/$rid.json"
  run bash "$CLOSE" --retire-close-request "$rid" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_KDIR/_sessions/close-requests/$rid.json" ]
  [ "$(jq -r 'select(.request_id == "close-replay-1") | .event' "$TEST_KDIR/_sessions/events.jsonl" | wc -l | tr -d ' ')" -eq 1 ]
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

# --- close --session (address by harness session_id) ---

@test "close --session <full-id> resolves the owning instance and enqueues" {
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session 11111111-1111-1111-1111-111111111111 --reason coordinator --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .slug=="feature-x" and .target_instance=="inst-a"'
  run grep -c '"event":"close_requested"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "close --session <prefix> resolves by an unambiguous leading prefix" {
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session 1111 --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.target_instance=="inst-a" and .slug=="feature-x"'
}

@test "close --session addresses a slugless session; the row carries a null slug" {
  # The slugless session's own slug is empty, so the close-request row's slug is
  # JSON null (which the Go consumer reads as "" and matches on its empty-slug key).
  write_instance_session inst-b "" 22222222-2222-2222-2222-222222222222
  run bash "$CLOSE" --session 2222 --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .slug==null and .target_instance=="inst-b"'

  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '.slug==null and .target_instance=="inst-b"' "$cr"
  [ "$status" -eq 0 ]

  # Human line names it as a slugless session, never "close of ''".
  run bash "$CLOSE" --session 2222 --kdir "$TEST_KDIR"
  [[ "$output" == *"slugless session on instance inst-b"* ]]
}

@test "close --session stamps the passed session_id onto the close-request row" {
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session 11111111-1111-1111-1111-111111111111 --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '.session_id=="11111111-1111-1111-1111-111111111111"' "$cr"
  [ "$status" -eq 0 ]
}

@test "close --session stamps the leading prefix the coordinator passed, not the full id" {
  # The producer stamps the passed value verbatim; the consumer matches it
  # against the full hosted id by leading prefix, so the short form still resolves.
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session 1111 --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '.session_id=="1111"' "$cr"
  [ "$status" -eq 0 ]
}

@test "close <slug> omits session_id from the close-request row (legacy shape)" {
  write_instance inst-a feature-x
  run bash "$CLOSE" feature-x --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '(has("session_id")|not)' "$cr"
  [ "$status" -eq 0 ]
}

@test "close --self omits session_id from the close-request row" {
  run env LORE_SESSION_INSTANCE=inst-a LORE_SESSION_SLUG=feature-x \
    bash "$CLOSE" --self --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  local cr; cr="$(ls "$TEST_KDIR"/_sessions/close-requests/*.json)"
  run jq -e '(has("session_id")|not)' "$cr"
  [ "$status" -eq 0 ]
}

@test "close --session refuses an ambiguous prefix and names the colliding ids" {
  write_instance_session inst-c early abcd0000-0000-0000-0000-000000000000
  write_instance_session inst-d late  abcd1111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session abcd --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous session id 'abcd'"* ]]
  [[ "$output" == *"abcd0000-0000-0000-0000-000000000000"* ]]
  [[ "$output" == *"abcd1111-1111-1111-1111-111111111111"* ]]
  [[ "$output" == *"longer prefix"* ]]
  # Refusal writes nothing.
  [ ! -d "$TEST_KDIR/_sessions/close-requests" ]
}

@test "close --session refuses when no live session matches" {
  write_instance_session inst-a feature-x 11111111-1111-1111-1111-111111111111
  run bash "$CLOSE" --session ffff --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live session matches session id 'ffff'"* ]]
}

@test "close with no target names --session in the refusal" {
  run bash "$CLOSE" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no target"* ]]
  [[ "$output" == *"--session <id>"* ]]
}

@test "close with an empty --session value is refused as no target (no sentinel)" {
  run bash "$CLOSE" --session "" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no target"* ]]
  [[ "$output" == *"--session <id>"* ]]
}

@test "close refuses an ambiguous form (slug plus --session)" {
  run bash "$CLOSE" feature-x --session 1111 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"--session <id>"* ]]
}

# =====================================================================
# session-event-append — close_failed terminal-outcome vocabulary
# =====================================================================

@test "append accepts close_failed with a non-empty request_id" {
  run bash "$APPEND" --row '{"event":"close_failed","request_id":"r1","reason":"rung-exhausted"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run grep -c '"event":"close_failed"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$output" = "1" ]
}

@test "append accepts orphaned and deterministic replay is idempotent" {
  local row='{"event_id":"orphan-fixed","event":"orphaned","request_id":"spawn-1","slug":"feature-x","reason":"instance-death"}'
  run bash "$APPEND" --row "$row" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$APPEND" --row "$row" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"event":"orphaned"' "$TEST_KDIR/_sessions/events.jsonl")" -eq 1 ]
}

@test "append rejects close_failed without a request_id, naming the field" {
  run bash "$APPEND" --row '{"event":"close_failed","reason":"error"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: request_id"* ]]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append accepts modal_blocked with slug and reason=modal" {
  run bash "$APPEND" --row '{"event":"modal_blocked","slug":"feature-x","reason":"modal"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run jq -e 'select(.event=="modal_blocked") | .slug=="feature-x" and .reason=="modal" and (has("request_id")|not)' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "append accepts answer lifecycle rows with numeric option and closed refusal reason" {
  run bash "$APPEND" --row '{"event":"answer_requested","request_id":"a1","slug":"feature-x","option":2}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$APPEND" --row '{"event":"answered","request_id":"a1","slug":"feature-x","option":2}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$APPEND" --row '{"event":"answer_refused","request_id":"a2","slug":"feature-x","option":3,"reason":"expect-mismatch"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run jq -s -e 'map(select(.event=="answer_requested" or .event=="answered" or .event=="answer_refused")) | map(.option) == [2,2,3] and all(.[]; (.option|type)=="number")' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "append rejects malformed answer lifecycle rows" {
  run bash "$APPEND" --row '{"event":"answered","request_id":"a1","slug":"feature-x"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"option"* ]]
  run bash "$APPEND" --row '{"event":"answer_refused","request_id":"a2","slug":"feature-x","option":2,"reason":"maybe"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"answer_refused requires"* ]]
}

@test "append accepts terminus_reached only with hosted identity and no queue request_id" {
  run bash "$APPEND" --row '{"event":"terminus_reached","actor_instance":"inst-a","slug":"feature-x","session_type":"implement","reason":"impl-close"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run jq -e 'select(.event=="terminus_reached") | .actor_instance=="inst-a" and .slug=="feature-x" and .session_type=="implement" and (has("request_id")|not)' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]

  run bash "$APPEND" --row '{"event":"terminus_reached","actor_instance":"inst-a","slug":"feature-x","session_type":"implement","reason":"impl-close","request_id":"queue-id"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a queue-lifecycle event"* ]]
}

@test "append accepts step_completed only with hosted step identity and no queue request_id" {
  local row='{"event":"step_completed","actor_instance":"inst-a","slug":"feature-x","session_type":"implement","step_id":"implement:task:task-1","step_label":"Task 1 accepted"}'
  run bash "$APPEND" --row "$row" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run jq -e 'select(.event=="step_completed") | .actor_instance=="inst-a" and .slug=="feature-x" and .session_type=="implement" and .step_id=="implement:task:task-1" and .step_label=="Task 1 accepted" and (has("request_id")|not)' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]

  local field incomplete
  for field in actor_instance slug session_type step_id step_label; do
    incomplete="$(printf '%s' "$row" | jq -c "del(.$field)")"
    run bash "$APPEND" --row "$incomplete" --kdir "$TEST_KDIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing required field: $field"* ]]
  done

  run bash "$APPEND" --row "$(printf '%s' "$row" | jq -c '. + {request_id:"queue-id"}')" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"request_id (step_completed is not a queue-lifecycle event)"* ]]
  [ "$(grep -c '"event":"step_completed"' "$TEST_KDIR/_sessions/events.jsonl")" -eq 1 ]
}

@test "step helper derives deterministic replay identity and refuses changed labels" {
  mkdir -p "$TEST_KDIR/_sessions/instances"
  printf '%s\n' '{"name":"inst-a","sessions":[{"slug":"feature-x","type":"implement","request_id":"spawn-1"}]}' > "$TEST_KDIR/_sessions/instances/inst-a.json"
  export LORE_SESSION_INSTANCE=inst-a LORE_SESSION_SLUG=feature-x LORE_SESSION_TYPE=implement

  run bash "$STEP" --step-id implement:task:task-1 --step-label "Task 1 accepted" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$STEP" --step-id implement:task:task-1 --step-label "Task 1 accepted" --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"event":"step_completed"' "$TEST_KDIR/_sessions/events.jsonl")" -eq 1 ]

  local expected
  expected="step-$(python3 - <<'PY'
import hashlib
print(hashlib.sha256("\0".join(["step_completed", "inst-a", "feature-x", "implement", "spawn-1", "implement:task:task-1"]).encode()).hexdigest())
PY
)"
  run jq -er --arg id "$expected" 'select(.event=="step_completed") | .event_id==$id and .step_id=="implement:task:task-1" and .step_label=="Task 1 accepted" and (has("request_id")|not)' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]

  run bash "$STEP" --step-id implement:task:task-1 --step-label "Different evidence" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"event_id collision"* ]]
  [ "$(grep -c '"event":"step_completed"' "$TEST_KDIR/_sessions/events.jsonl")" -eq 1 ]
}

@test "terminus helper derives deterministic replay identity from the persisted spawn request" {
  mkdir -p "$TEST_KDIR/_sessions/instances"
  printf '%s\n' '{"name":"inst-a","sessions":[{"slug":"feature-x","type":"implement","request_id":"spawn-1"}]}' > "$TEST_KDIR/_sessions/instances/inst-a.json"
  export LORE_SESSION_INSTANCE=inst-a LORE_SESSION_SLUG=feature-x LORE_SESSION_TYPE=implement

  run bash "$TERMINUS" --reason impl-close --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run bash "$TERMINUS" --reason impl-close --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"event":"terminus_reached"' "$TEST_KDIR/_sessions/events.jsonl")" -eq 1 ]
  local expected
  expected="terminus-$(python3 - <<'PY'
import hashlib
print(hashlib.sha256("\0".join(["terminus_reached", "inst-a", "feature-x", "implement", "spawn-1", "impl-close"]).encode()).hexdigest())
PY
)"
  run jq -er --arg id "$expected" 'select(.event=="terminus_reached") | .event_id==$id and (has("request_id")|not)' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "append rejects modal_blocked without a slug" {
  run bash "$APPEND" --row '{"event":"modal_blocked","reason":"modal"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: slug"* ]]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append rejects modal_blocked without reason" {
  run bash "$APPEND" --row '{"event":"modal_blocked","slug":"feature-x"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing required field: reason"* ]]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append rejects modal_blocked with a non-modal reason" {
  run bash "$APPEND" --row '{"event":"modal_blocked","slug":"feature-x","reason":"generating"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"modal_blocked requires reason=modal"* ]]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append accepts string-valued closed.links.close_requests" {
  run bash "$APPEND" --row '{"event":"closed","request_id":"spawn-1","links":{"close_requests":"[\"term-1\",\"explicit-2\"]"}}' --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  run jq -er 'select(.event=="closed") | .links.close_requests == "[\"term-1\",\"explicit-2\"]"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "append rejects closed.links.close_requests outside closed" {
  run bash "$APPEND" --row '{"event":"close_failed","request_id":"r1","links":{"close_requests":"[\"r1\"]"}}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"links.close_requests"* ]]
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append rejects malformed closed.links.close_requests declarations" {
  local row
  for row in \
    '{"event":"closed","links":{"close_requests":["r1"]}}' \
    '{"event":"closed","links":{"close_requests":"not-json"}}' \
    '{"event":"closed","links":{"close_requests":"[]"}}' \
    '{"event":"closed","links":{"close_requests":"[\"\"]"}}' \
    '{"event":"closed","links":{"close_requests":"[ \"r1\" ]"}}' \
    '{"event":"closed","links":{"close_requests":"[\"r1\",\"r1\"]"}}'; do
    run bash "$APPEND" --row "$row" --kdir "$TEST_KDIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"links.close_requests"* ]]
  done
  [ ! -f "$TEST_KDIR/_sessions/events.jsonl" ]
}

@test "append rejects an out-of-vocabulary event and enumerates close_failed" {
  run bash "$APPEND" --row '{"event":"close_bogus","request_id":"r1"}' --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid event"* ]]
  [[ "$output" == *"close_failed"* ]]
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
# session answer
# =====================================================================

@test "answer enqueues numeric option and expectation and emits answer_requested" {
  write_instance inst-a feature-x
  run bash "$ANSWER" feature-x --option 2 --expect "Would you like to run" --requested-by coordinator --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .slug=="feature-x" and .target_instance=="inst-a" and .option==2'

  local ar; ar="$(ls "$TEST_KDIR"/_sessions/answer-requests/*.json)"
  run jq -e '.option==2 and (.option|type)=="number" and .expect=="Would you like to run" and .requested_by=="coordinator"' "$ar"
  [ "$status" -eq 0 ]
  run jq -e 'select(.event=="answer_requested") | .request_id and .slug=="feature-x" and .option==2 and (.option|type)=="number"' "$TEST_KDIR/_sessions/events.jsonl"
  [ "$status" -eq 0 ]
}

@test "answer validates required expectation and positive option before enqueue" {
  write_instance inst-a feature-x
  run bash "$ANSWER" feature-x --expect modal --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--option"* ]]
  run bash "$ANSWER" feature-x --option 2 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--expect"* ]]
  run bash "$ANSWER" feature-x --option 0 --expect modal --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
  [ ! -d "$TEST_KDIR/_sessions/answer-requests" ]
}

@test "answer --wait maps answered to exit 0" {
  write_instance inst-a feature-x
  ( rid="$(wait_request_id answer-requests)"
    echo '{"event":"answered","request_id":"'"$rid"'","slug":"feature-x","option":2}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$ANSWER" feature-x --option 2 --expect modal --wait --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"Answered 'feature-x' with option 2"* ]]
}

@test "answer --wait maps answer_refused to exit 3" {
  write_instance inst-a feature-x
  ( rid="$(wait_request_id answer-requests)"
    echo '{"event":"answer_refused","request_id":"'"$rid"'","slug":"feature-x","option":2,"reason":"option-unavailable"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$ANSWER" feature-x --option 2 --expect modal --wait --timeout 10 --json --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 3 ]
  [[ "$output" == *'"refused": true'* ]]
  [[ "$output" == *'"option": 2'* ]]
  [[ "$output" == *'"reason": "option-unavailable"'* ]]
}

@test "answer --wait times out to exit 1" {
  write_instance inst-a feature-x
  run bash "$ANSWER" feature-x --option 1 --expect modal --wait --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
}

@test "session answer routes through the dispatcher" {
  write_instance inst-a feature-x
  run bash "$LORE" session answer feature-x --option 1 --expect modal --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.enqueued==true and .option==1'
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

# =====================================================================
# session wait
# =====================================================================

# The events wait verb keeps a static mirror of the sole writer's event
# vocabulary (to validate --until). These two extractors read the writer's
# accepting case-arm and the verb's mirror so the drift-guard test below can name
# the exact token that diverged.
writer_event_vocab() {
  python3 - "$APPEND" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# The writer validates .event against a case-arm whose accepting pattern ends in
# ") ;;". Grab that pattern run, drop line continuations, split on the alternation.
m = re.search(r'case "\$EVENT" in\n(.*?)\)\s*;;', src, re.S)
if not m:
    sys.exit("could not locate the writer's event case-arm")
block = m.group(1).replace('\\\n', '').replace('\n', '')
for tok in block.split('|'):
    tok = tok.strip()
    if tok:
        print(tok)
PY
}

mirror_event_vocab() {
  grep -E '^SESSION_EVENT_VOCAB=' "$WAIT" | head -n1 \
    | sed -E 's/^SESSION_EVENT_VOCAB="([^"]*)".*/\1/' \
    | tr ' ' '\n' | grep -v '^$'
}

coordinate_event_vocab() {
  grep -E '^SESSION_EVENT_VOCAB=' "$COORDINATE" | head -n1 \
    | sed -E 's/^SESSION_EVENT_VOCAB="([^"]*)".*/\1/' \
    | tr ' ' '\n' | grep -v '^$'
}

@test "wait: --until vocabulary mirror matches the sole writer's case-arm (drift guard)" {
  local w m
  w="$(writer_event_vocab | sort -u)"
  m="$(mirror_event_vocab | sort -u)"
  [ -n "$w" ] || { echo "writer vocabulary extraction returned nothing"; false; }
  [ -n "$m" ] || { echo "mirror vocabulary extraction returned nothing"; false; }
  local missing extra
  missing="$(comm -23 <(printf '%s\n' "$w") <(printf '%s\n' "$m") | tr '\n' ' ')"
  extra="$(comm -13 <(printf '%s\n' "$w") <(printf '%s\n' "$m") | tr '\n' ' ')"
  [ -z "${missing// }" ] || { echo "wait mirror is MISSING tokens the writer accepts: $missing"; false; }
  [ -z "${extra// }" ] || { echo "wait mirror has EXTRA tokens the writer rejects: $extra"; false; }
}

@test "coordinate: event vocabulary mirror matches the sole writer's case-arm" {
  local w m
  w="$(writer_event_vocab | sort -u)"
  m="$(coordinate_event_vocab | sort -u)"
  [ -n "$w" ]
  [ "$w" = "$m" ]
}

@test "coordinate: modal_blocked is accepted without projecting a modal bucket" {
  echo '{"event":"modal_blocked","slug":"feature-x","reason":"modal"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null
  run bash "$COORDINATE" --kdir "$TEST_KDIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    (.source_manifest[] | select(.source_id=="session-journal") | .read_status) == "ok"
    and ([.buckets[][] | select(.source_id=="session-journal")] | length) == 0
  '
}

@test "wait: an exact-slug close matches, emitting the matched row and the cursor row in one read" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"closed","request_id":"r1","slug":"feature-x"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 10 --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  wait
  [ "$code" -eq 0 ]
  [ "$(printf '%s\n' "$out" | jq -rs 'map(select(has("event")).event) | join(",")')" = "closed" ]
  local nc; nc="$(printf '%s\n' "$out" | jq -rs 'map(select(has("next_cursor")).next_cursor)[0]')"
  [ -n "$nc" ] && [ "$nc" != "null" ]
  # Re-arming from the emitted cursor does not re-match the consumed row.
  run bash "$WAIT" feature-x --since "$nc" --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 2 ]
}

@test "wait: the default until-set also wakes on close_failed" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"close_failed","request_id":"r1","slug":"feature-x","reason":"error"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$WAIT" feature-x --since 0 --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"close_failed"'* ]]
}

@test "wait: --until modal_blocked wakes on the entry row" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"modal_blocked","slug":"feature-x","reason":"modal"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$WAIT" feature-x --until modal_blocked --since 0 --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"modal_blocked"'* ]]
}

@test "wait: --until terminus_reached wakes without changing the teardown default" {
  write_instance inst-a feature-x
  echo '{"event":"terminus_reached","actor_instance":"inst-a","slug":"feature-x","session_type":"implement","reason":"impl-close"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null
  run bash "$WAIT" feature-x --until terminus_reached --since 0 --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"terminus_reached"'* ]]

  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 1 --json --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  [ "$code" -eq 2 ]
  echo "$out" | jq -e '.until==["closed","close_failed","orphaned"]'
}

@test "wait: --until step_completed wakes with exact step fields without changing the teardown default" {
  write_instance inst-a feature-x
  echo '{"event":"step_completed","actor_instance":"inst-a","slug":"feature-x","session_type":"implement","step_id":"implement:task:task-1","step_label":"Task 1 accepted"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null
  run bash "$WAIT" feature-x --until step_completed --since 0 --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"step_id":"implement:task:task-1"'* ]]
  [[ "$output" == *'"step_label":"Task 1 accepted"'* ]]

  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 1 --json --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  [ "$code" -eq 2 ]
  echo "$out" | jq -e '.until==["closed","close_failed","orphaned"]'
}

@test "wait: modal_blocked does not change the default close wake set" {
  write_instance inst-a feature-x
  echo '{"event":"modal_blocked","slug":"feature-x","reason":"modal"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null
  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 1 --json --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  [ "$code" -eq 2 ]
  echo "$out" | jq -e '.outcome=="timeout" and (.until==["closed","close_failed","orphaned"])'
}

@test "wait: the default until-set wakes on orphaned" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"orphaned","request_id":"spawn-1","slug":"feature-x","reason":"instance-death"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  run bash "$WAIT" feature-x --since 0 --timeout 10 --kdir "$TEST_KDIR"
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"orphaned"'* ]]
}

@test "wait: a derived <slug>--w1 close never wakes a parent-slug wait; it times out" {
  write_instance inst-a feature-x            # parent live, so session-gone stays quiet
  printf '%s\n' '{"event":"closed","request_id":"r1","slug":"feature-x--w1"}' > "$TEST_KDIR/_sessions/events.jsonl"
  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 2 --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  [ "$code" -eq 2 ]
  # Even on timeout the resume cursor rides stdout as a jq-parseable row.
  [ "$(printf '%s' "$out" | jq -r '.next_cursor' | grep -c '^[0-9]\+$')" -eq 1 ]
}

@test "wait: --request-id ignores a prior same-slug terminal and matches the declared session" {
  write_instance inst-a feature-x
  printf '%s\n' '{"event":"closed","request_id":"prior-rid","slug":"feature-x"}' > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"closed","request_id":"next-rid","slug":"feature-x"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  local out code
  out="$(bash "$WAIT" feature-x --request-id next-rid --since 0 --timeout 10 --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  wait
  [ "$code" -eq 0 ]
  [ "$(printf '%s\n' "$out" | jq -rs '[.[] | select(has("event")) | .request_id] | join(",")')" = "next-rid" ]
}

@test "wait: --request-id narrows closed only and preserves a close_failed sloppy wake" {
  write_instance inst-a feature-x
  printf '%s\n' \
    '{"event":"closed","request_id":"prior-spawn","slug":"feature-x"}' \
    '{"event":"close_failed","request_id":"close-request","slug":"feature-x","reason":"approval-required"}' \
    > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" feature-x --request-id current-spawn --since 0 --timeout 10 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -rs '[.[] | select(has("event")) | .event + ":" + .request_id] | join(",")')" = "close_failed:close-request" ]
}

@test "wait: --work-item matches exact-base and canonical workers only and is an alternate target" {
  printf '%s\n' '{"event":"closed","request_id":"base-rid","slug":"feature-x"}' > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" --work-item feature-x --since 0 --timeout 10 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"slug":"feature-x"'* ]]

  printf '%s\n' '{"event":"closed","request_id":"worker-rid","slug":"feature-x--w12"}' > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" --work-item feature-x --since 0 --timeout 10 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"slug":"feature-x--w12"'* ]]

  write_instance inst-a feature-x--w2
  printf '%s\n' '{"event":"closed","request_id":"lookalike","slug":"feature-x--w2-extra"}' > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" --work-item feature-x --since 0 --timeout 0 --kdir "$TEST_KDIR"
  [ "$status" -eq 2 ]                         # live canonical worker prevents session-gone

  run bash "$WAIT" feature-x --work-item feature-x --since 0 --timeout 0 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"either a positional <slug> or --work-item, not both"* ]]
}

@test "wait: reference-reader failures retry with 1s/2s backoff then exit internal_error 4" {
  local fixture="$TEST_KDIR/wait-fixture" stub_bin="$TEST_KDIR/stub-bin"
  mkdir -p "$fixture" "$stub_bin"
  cp "$WAIT" "$fixture/session-wait.sh"
  cp "$REPO_DIR/scripts/lib.sh" "$fixture/lib.sh"
  cat > "$fixture/session-events.sh" <<'EOF'
#!/usr/bin/env bash
count_file="$(dirname "$0")/attempt-count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${EVENTS_STUB_MODE:-}" = fail-twice ] && [ "$count" -ge 3 ]; then
  printf '%s\n' '{"events":[{"event":"closed","request_id":"spawn-rid","slug":"retry-slug"}],"next_cursor":77}'
  exit 0
fi
exit 9
EOF
  chmod +x "$fixture/session-events.sh"
  cat > "$stub_bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SLEEP_LOG"
EOF
  chmod +x "$stub_bin/sleep"

  local sleep_log="$TEST_KDIR/sleeps" out err="$TEST_KDIR/retry.err" code
  out="$(PATH="$stub_bin:$PATH" SLEEP_LOG="$sleep_log" EVENTS_STUB_MODE=fail-twice \
    bash "$fixture/session-wait.sh" retry-slug --since 0 --timeout 0 --json --kdir "$TEST_KDIR" 2>"$err")" && code=0 || code=$?
  [ "$code" -eq 0 ]
  echo "$out" | jq -e '.outcome=="matched" and .matched.slug=="retry-slug" and .next_cursor==77'
  [ "$(paste -sd, "$sleep_log")" = "1,2" ]

  rm -f "$fixture/attempt-count" "$sleep_log"
  out="$(PATH="$stub_bin:$PATH" SLEEP_LOG="$sleep_log" EVENTS_STUB_MODE=always-fail \
    bash "$fixture/session-wait.sh" retry-slug --timeout 0 --json --kdir "$TEST_KDIR" 2>"$err")" && code=0 || code=$?
  [ "$code" -eq 4 ]
  echo "$out" | jq -e '.outcome=="internal_error" and .matched==null and .next_cursor==null'
  [ "$(paste -sd, "$sleep_log")" = "1,2" ]
  grep -q "session-events failed after 3 attempts" "$err"
}

@test "wait: a mid-row --since fails with the cursor-not-row-aligned remediation" {
  printf '%s\n' '{"event":"closed","request_id":"r1","slug":"feature-x"}' > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" feature-x --since 7 --timeout 0 --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --since cursor 7: cursor-not-row-aligned (preceding byte is not newline); reuse a next_cursor emitted by lore session events or lore session wait"* ]]
  [[ "$output" != *"corrupt"* ]]
}

@test "wait: no live instance and no matching row exits 3 (session gone) with a resume cursor" {
  : > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" ghost --since 0 --timeout 30 --kdir "$TEST_KDIR"
  [ "$status" -eq 3 ]
  [[ "$output" == *"session gone"* ]]        # stderr diagnostic (run merges streams)
  [[ "$output" == *'"next_cursor"'* ]]       # cursor row on stdout
}

@test "wait: a terminal landing after liveness-miss but within grace wins over session-gone" {
  : > "$TEST_KDIR/_sessions/events.jsonl"     # no live instance: grace starts immediately
  ( sleep 1
    echo '{"event":"closed","request_id":"r1","slug":"teardown-race"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  local out code
  out="$(bash "$WAIT" teardown-race --since 0 --timeout 30 --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  wait
  [ "$code" -eq 0 ]
  [ "$(printf '%s\n' "$out" | jq -rs 'map(select(has("event")).event) | join(",")')" = "closed" ]
  [ "$(printf '%s\n' "$out" | jq -rs 'map(select(has("next_cursor")).next_cursor) | length')" -eq 1 ]
}

@test "wait: a matching row already present with no live instance still matches (exit 0)" {
  printf '%s\n' '{"event":"closed","request_id":"r1","slug":"gone-but-closed"}' > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$WAIT" gone-but-closed --since 0 --timeout 30 --kdir "$TEST_KDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"event":"closed"'* ]]
}

@test "wait: a queue/pre-spawn --until suppresses session-gone; it times out instead of exit 3" {
  : > "$TEST_KDIR/_sessions/events.jsonl"     # no instance, no match
  run bash "$WAIT" ghost --until spawned --since 0 --timeout 2 --kdir "$TEST_KDIR"
  [ "$status" -eq 2 ]                          # timeout, not session-gone
}

@test "wait: an out-of-vocabulary --until event is a usage error, not a forever-wait" {
  run bash "$WAIT" feature-x --until closd --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid --until event: 'closd'"* ]]
}

@test "wait: --json surfaces an invalid --until as a JSON error" {
  run bash "$WAIT" feature-x --until bogus --json --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.error | test("invalid --until")'
}

@test "wait: refuses when no slug is given" {
  run bash "$WAIT" --kdir "$TEST_KDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no target"* ]]
}

@test "wait: --json emits a result object on the timeout terminal" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 1 --json --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  [ "$code" -eq 2 ]
  echo "$out" | jq -e '.outcome=="timeout" and .matched==null and (.next_cursor|type=="number") and .slug=="feature-x" and (.until==["closed","close_failed","orphaned"])'
}

@test "wait: --json emits the matched object on the match terminal" {
  write_instance inst-a feature-x
  : > "$TEST_KDIR/_sessions/events.jsonl"
  ( sleep 1
    echo '{"event":"closed","request_id":"r1","slug":"feature-x"}' | bash "$APPEND" --kdir "$TEST_KDIR" >/dev/null ) &
  local out code
  out="$(bash "$WAIT" feature-x --since 0 --timeout 10 --json --kdir "$TEST_KDIR" 2>/dev/null)" && code=0 || code=$?
  wait
  [ "$code" -eq 0 ]
  echo "$out" | jq -e '.outcome=="matched" and .matched.event=="closed" and (.next_cursor|type=="number")'
}

@test "session wait routes through the dispatcher" {
  : > "$TEST_KDIR/_sessions/events.jsonl"
  run bash "$LORE" session wait ghost --until spawned --since 0 --timeout 1 --kdir "$TEST_KDIR"
  [ "$status" -eq 2 ]                          # pre-spawn until suppresses gone; times out
}
