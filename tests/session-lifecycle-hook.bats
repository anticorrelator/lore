#!/usr/bin/env bats
# session-lifecycle-hook.bats — the shared lifecycle hook and the hook-row form
# the journal writer admits.
#
# Coverage:
#   - each Claude Code event the session_lifecycle_hooks cell declares journals
#     the row D1 assigns it, as a hook row through the sole writer;
#   - each Codex event the codex cell declares does the same from a payload of
#     the shape Codex 0.162.1's hook input schemas give;
#   - each OpenCode client event the opencode cell declares does the same from
#     the payload lore's OpenCode plugin builds, and, because that cell's channel
#     is the pane environment, a row from any process below the session's first
#     process (a nested harness, one started from a tool shell, the hook run
#     through a shell) is refused while the first process still reports;
#   - hooks the cell does not declare write nothing;
#   - actor_instance names the live owner listing this launch after adoption;
#   - every path prints nothing and exits 0, including a refused write, a hung
#     writer, and stdin that never closes, and the hook returns within 5 s;
#   - the writer refuses malformed hook rows by field;
#   - the hooks-only Claude settings fixture accepts a payload built from the
#     declared events and rejects the shapes the docs do not allow.
#
# Style: pure bats with an isolated store per test.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
HOOK="$REPO_DIR/scripts/session-lifecycle-hook.sh"
APPEND="$REPO_DIR/scripts/session-event-append.sh"
CAPS="$REPO_DIR/adapters/capabilities.json"
SCHEMA="$REPO_DIR/tests/fixtures/claude-code-hooks-settings.schema.json"

# session_target.generation() of LAUNCH below: session id, request id, start second.
GENERATION="5f0c2a3e-0000-4000-8000-00000000c0de/req-hook-1/1792317600"
LAUNCH='{"slug":"hook-slug","type":"chat","session_id":"5f0c2a3e-0000-4000-8000-00000000c0de","request_id":"req-hook-1","tmux":"lore-hook","started":"2026-10-18T10:00:00Z"}'
OTHER_LAUNCH='{"slug":"hook-slug","type":"chat","session_id":"0b6f1d2a-0000-4000-8000-0000000000aa","request_id":"req-hook-0","tmux":"lore-hook","started":"2026-10-18T09:00:00Z"}'

setup() {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  TEST_KDIR="$(mktemp -d)"
  TEST_KDIR="$(cd "$TEST_KDIR" && pwd -P)"
  mkdir -p "$TEST_KDIR/_sessions/instances"
  export LORE_SESSION_SLUG=hook-slug LORE_SESSION_TYPE=chat LORE_SESSION_GENERATION="$GENERATION" \
    LORE_SESSION_STORE_ROOT="$TEST_KDIR" LORE_SESSION_INSTANCE=spawn-host
  unset LORE_AGENT_DISABLED
  LIVE_PIDS=()
}

teardown() {
  local pid
  for pid in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_KDIR"
}

# --- helpers ---

fire() {
  # fire <framework> <payload> — run the hook as a harness does, payload on
  # stdin, capturing everything it prints on either stream.
  run bash -c 'printf "%s" "$2" | bash "$1" "$3"' _ "$HOOK" "$2" "$1"
}

hook_rows() {
  [ -f "$TEST_KDIR/_sessions/events.jsonl" ] || return 0
  jq -c 'select(.links.authority == "hook-row")' "$TEST_KDIR/_sessions/events.jsonl"
}

row_count() {
  [ -f "$TEST_KDIR/_sessions/events.jsonl" ] || { echo 0; return; }
  wc -l < "$TEST_KDIR/_sessions/events.jsonl" | tr -d ' '
}

hooks_log() {
  cat "$TEST_KDIR/_sessions/hooks.log" 2>/dev/null || true
}

now() {
  python3 -c 'import time; print(time.time())'
}

elapsed_below() {
  # elapsed_below <start> <end> <seconds>
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < float(sys.argv[3]) else 1)' "$1" "$2" "$3"
}

start_live_process() {
  # Leaves the pid of a process that outlives the test body in LIVE_PID.
  sleep 300 3>&- &
  LIVE_PID=$!
  LIVE_PIDS+=("$LIVE_PID")
}

dead_pid() {
  sleep 0 &
  local pid=$!
  wait "$pid"
  echo "$pid"
}

write_registry() {
  # write_registry <file stem> <name> <pid> <revision> <role or ""> <session json>
  jq -n --arg name "$2" --argjson pid "$3" --argjson revision "$4" --arg role "$5" --argjson session "$6" \
    '{name: $name, pid: $pid, revision: $revision, repo: "github.com/example/repo",
      started: "2026-10-18T09:00:00Z", sessions: [$session]}
     + (if $role == "" then {} else {role: $role} end)' \
    > "$TEST_KDIR/_sessions/instances/$1.json"
}

contains() {
  # contains <haystack> <needle>. A failing [[ ]] does not fail a test under
  # bash 3.2, so substring checks go through a function that returns 1.
  case "$1" in *"$2"*) return 0 ;; esac
  printf 'expected to find: %s\nin: %s\n' "$2" "$1"
  return 1
}

assert_silent_exit() {
  [ "$status" -eq 0 ] || { echo "hook exited $status"; return 1; }
  [ -z "$output" ] || { echo "hook printed: $output"; return 1; }
}

assert_hook_row() {
  # assert_hook_row <row> <event> <activity> <hook_event>
  # assert_hook_row <row> <event> <activity> <hook_event> [framework, default claude-code]
  local row="$1"
  [ -n "$row" ] || { echo "no hook row was written"; return 1; }
  jq -e --arg event "$2" --arg activity "$3" --arg hook "$4" --arg gen "$GENERATION" \
    --arg framework "${5:-claude-code}" '
    .event == $event and .slug == "hook-slug" and .session_type == "chat"
    and (has("request_id") | not)
    and .links.authority == "hook-row" and .links.hook_event == $hook
    and .links.activity == $activity and .links.generation == $gen
    and .links.framework == $framework and .links.spawn_instance == "spawn-host"
    and (.links | has("observation") | not)
    and (.links.fired_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{6}Z$"))
  ' <<<"$row" >/dev/null || { echo "unexpected row: $row"; return 1; }
}

hook_layout_with_writer() {
  # hook_layout_with_writer <writer body> — a copy of the scripts the hook uses,
  # with the journal writer replaced, so a test can control what the writer does.
  # Prints the copied hook's path.
  local dir="$BATS_TEST_TMPDIR/layout"
  mkdir -p "$dir/scripts" "$dir/adapters"
  cp "$HOOK" "$REPO_DIR/scripts/session_target.py" "$dir/scripts/"
  cp "$CAPS" "$dir/adapters/capabilities.json"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$dir/scripts/session-event-append.sh"
  echo "$dir/scripts/session-lifecycle-hook.sh"
}

valid_hook_row() {
  jq -nc --arg gen "$GENERATION" '{
    event: "needs_input", slug: "hook-slug", session_type: "chat", actor_instance: "adopter",
    links: {authority: "hook-row", hook_event: "Stop", activity: "idle", generation: $gen,
            fired_at: "2026-10-18T10:00:01.123456Z", framework: "claude-code",
            spawn_instance: "spawn-host"}}'
}

# --- each declared Claude Code event journals the row D1 assigns it ---

@test "claude-code UserPromptSubmit journals resumed with activity working" {
  fire claude-code '{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"hello"}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" resumed working UserPromptSubmit
  [ "$(jq -r '.actor_instance' <<<"$row")" = "spawn-host" ]
}

@test "claude-code Stop journals needs_input with activity idle" {
  fire claude-code '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}'
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle Stop
}

@test "claude-code StopFailure journals needs_input blocked and carries the error type" {
  fire claude-code '{"hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests","last_assistant_message":"API Error: Rate limit reached"}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked StopFailure
  [ "$(jq -r '.links.error' <<<"$row")" = "rate_limit" ]
  [ "$(jq -r '.links | has("error_details")' <<<"$row")" = "false" ]
}

@test "claude-code PermissionRequest journals needs_input blocked and names the tool" {
  fire claude-code '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked PermissionRequest
  [ "$(jq -r '.links.tool_name' <<<"$row")" = "Bash" ]
}

@test "claude-code PreToolUse on a question or plan tool journals needs_input blocked" {
  fire claude-code '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}'
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input blocked PreToolUse
  fire claude-code '{"hook_event_name":"PreToolUse","tool_name":"ExitPlanMode","tool_input":{}}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked PreToolUse
  [ "$(jq -r '.links.tool_name' <<<"$row")" = "ExitPlanMode" ]
}

@test "claude-code PostToolUse on a question tool journals resumed working" {
  fire claude-code '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_input":{},"tool_response":{"answers":{}}}'
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working PostToolUse
}

@test "claude-code PostToolUseFailure on a question tool ends the park with resumed working" {
  fire claude-code '{"hook_event_name":"PostToolUseFailure","tool_name":"ExitPlanMode","tool_input":{},"error":"failed","is_interrupt":false}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" resumed working PostToolUseFailure
  [ "$(jq -r '.links | has("error")' <<<"$row")" = "false" ]
}

@test "the mapping tests above cover every event the claude-code cell declares" {
  run jq -r '[.frameworks["claude-code"].session_lifecycle_hooks.events[].hook_event] | unique | join(",")' "$CAPS"
  [ "$status" -eq 0 ]
  [ "$output" = "PermissionRequest,PostToolUse,PostToolUseFailure,PreToolUse,Stop,StopFailure,UserPromptSubmit" ]
}

@test "a hook the cell does not declare, or a tool outside its matcher, writes no row" {
  fire claude-code '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'
  assert_silent_exit
  fire claude-code '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
  assert_silent_exit
  fire claude-code '{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{}}'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "declares no event for Notification"
  contains "$(hooks_log)" "declares no event for PreToolUse with tool_name Bash"
}

# --- each declared Codex event journals the row its cell assigns it ---
# Payload fields follow the hook input schemas embedded in Codex 0.162.1: every
# event carries session_id, turn_id, transcript_path, cwd, hook_event_name,
# model and permission_mode; PermissionRequest adds tool_name and tool_input,
# Stop adds stop_hook_active and last_assistant_message.

codex_payload() {
  # codex_payload <hook_event_name> [extra JSON object merged in]
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg name "$1" --argjson extra "$extra" '{
    session_id: "019a0000-0000-7000-8000-00000000c0de", turn_id: "turn-1",
    transcript_path: null, cwd: "/tmp/codex-work", hook_event_name: $name,
    model: "gpt-5.6-sol", permission_mode: "bypassPermissions"} + $extra'
}

@test "codex UserPromptSubmit journals resumed with activity working" {
  fire codex "$(codex_payload UserPromptSubmit '{"prompt":"Reply with the single word: ok"}')"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working UserPromptSubmit codex
}

@test "codex Stop journals needs_input with activity idle" {
  fire codex "$(codex_payload Stop '{"stop_hook_active":false,"last_assistant_message":"ok"}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input idle Stop codex
  [ "$(jq -r '.links | has("last_assistant_message")' <<<"$row")" = "false" ]
}

@test "codex Interrupt journals needs_input with activity idle" {
  fire codex "$(codex_payload Interrupt)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle Interrupt codex
}

@test "codex PermissionRequest journals needs_input blocked and names the tool" {
  fire codex "$(codex_payload PermissionRequest '{"tool_name":"exec_command","tool_input":{"cmd":"rm -rf build"}}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked PermissionRequest codex
  [ "$(jq -r '.links.tool_name' <<<"$row")" = "exec_command" ]
}

@test "the codex mapping tests above cover every event the codex cell declares" {
  run jq -r '[.frameworks.codex.session_lifecycle_hooks.events[].hook_event] | unique | join(",")' "$CAPS"
  [ "$status" -eq 0 ]
  [ "$output" = "Interrupt,PermissionRequest,Stop,UserPromptSubmit" ]
}

@test "a codex hook the cell does not declare writes no row" {
  fire codex "$(codex_payload SessionStart '{"source":"startup"}')"
  assert_silent_exit
  fire codex "$(codex_payload PreToolUse '{"tool_name":"exec_command","tool_input":{}}')"
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "frameworks.codex.session_lifecycle_hooks"
  contains "$(hooks_log)" "declares no event for SessionStart"
}

# --- OpenCode: a plugin selected through the pane environment ---
# The plugin (adapters/opencode/lore-session-lifecycle/tui.ts) runs in the
# OpenCode TUI process and spawns the hook directly with a payload naming the
# client event. Its channel is plugin-env, so the hook accepts a row only from
# the outermost process whose environment carries the session's generation.
# A python process stands in for the harness: the hook has to read the
# caller's environment, and macOS hides the environment of its own shells.

harness() {
  # harness <framework> <payload> [step...] — run the hook from a stand-in
  # harness process. Each step starts one more process below the previous one,
  # with the same environment: "python" a python process, "shell" a /bin/sh
  # that runs the next python process, "late" a python process started without
  # LORE_SESSION_GENERATION that sets it before going on, and "via-shell" runs
  # the hook itself through /bin/sh rather than directly. The hook's output is
  # relayed, so assert_silent_exit still checks it.
  local script="$BATS_TEST_TMPDIR/harness.py"
  cat > "$script" <<'PY'
import os
import shlex
import subprocess
import sys

hook, framework, payload, steps = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
if os.environ.get('HARNESS_RESTORE_GENERATION'):
    os.environ['LORE_SESSION_GENERATION'] = os.environ.pop('HARNESS_RESTORE_GENERATION')
if steps and steps[0] != 'via-shell':
    step, below = steps[0], [sys.executable, __file__, hook, framework, payload, *steps[1:]]
    if step == 'python':
        sys.exit(subprocess.run(below).returncode)
    if step == 'shell':
        sys.exit(subprocess.run(['/bin/sh', '-c', ' '.join(map(shlex.quote, below)) + '; exit $?']).returncode)
    if step == 'late':
        env = dict(os.environ)
        env['HARNESS_RESTORE_GENERATION'] = env.pop('LORE_SESSION_GENERATION')
        sys.exit(subprocess.run(below, env=env).returncode)
    sys.exit(f'unknown step {step}')
command = ['bash', hook, framework]
if steps:
    command = ['/bin/sh', '-c', ' '.join(map(shlex.quote, command)) + '; exit $?']
done = subprocess.run(command, input=payload.encode(), capture_output=True)
sys.stdout.buffer.write(done.stdout)
sys.stderr.buffer.write(done.stderr)
sys.exit(done.returncode)
PY
  local framework="$1" payload="$2"
  shift 2
  run python3 "$script" "$HOOK" "$framework" "$payload" "$@"
}

opencode_payload() {
  # opencode_payload <client event> [extra JSON object merged in] — the payload
  # the plugin hands the hook.
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg name "$1" --argjson extra "$extra" \
    '{hook_event_name: $name, session_id: "ses_eae16fdf8ffe22XSV2A8jvGrf5"} + $extra'
}

@test "opencode session.execution.started journals resumed with activity working" {
  harness opencode "$(opencode_payload session.execution.started)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working session.execution.started opencode
}

@test "opencode session.execution.succeeded journals needs_input with activity idle" {
  harness opencode "$(opencode_payload session.execution.succeeded)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle session.execution.succeeded opencode
}

@test "opencode session.execution.interrupted journals needs_input idle and carries the reason" {
  harness opencode "$(opencode_payload session.execution.interrupted '{"reason":"user"}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input idle session.execution.interrupted opencode
  [ "$(jq -r '.links.reason' <<<"$row")" = "user" ]
}

@test "opencode session.execution.failed journals needs_input blocked and carries the error" {
  harness opencode "$(opencode_payload session.execution.failed '{"error":"Rate limit exceeded"}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked session.execution.failed opencode
  [ "$(jq -r '.links.error' <<<"$row")" = "Rate limit exceeded" ]
}

@test "opencode permission.asked journals needs_input blocked and names the tool; permission.replied resumes" {
  harness opencode "$(opencode_payload permission.asked '{"tool_name":"shell"}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  assert_hook_row "$row" needs_input blocked permission.asked opencode
  [ "$(jq -r '.links.tool_name' <<<"$row")" = "shell" ]
  harness opencode "$(opencode_payload permission.replied)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working permission.replied opencode
}

@test "opencode form.created journals needs_input blocked; form.replied and form.cancelled resume" {
  harness opencode "$(opencode_payload form.created)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input blocked form.created opencode
  harness opencode "$(opencode_payload form.replied)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working form.replied opencode
  harness opencode "$(opencode_payload form.cancelled)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" resumed working form.cancelled opencode
}

@test "the opencode mapping tests above cover every event the opencode cell declares" {
  run jq -r '[.frameworks.opencode.session_lifecycle_hooks.events[].hook_event] | unique | join(",")' "$CAPS"
  [ "$status" -eq 0 ]
  [ "$output" = "form.cancelled,form.created,form.replied,permission.asked,permission.replied,session.execution.failed,session.execution.interrupted,session.execution.started,session.execution.succeeded" ]
}

@test "an opencode event the cell does not declare writes no row" {
  harness opencode "$(opencode_payload session.idle)"
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "declares no event for session.idle"
}

@test "opencode: a nested process with the session's environment is refused, and the first process still reports" {
  harness opencode "$(opencode_payload session.execution.succeeded)" python
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "is a child process of the hosted session, whose first process is pid"
  harness opencode "$(opencode_payload session.execution.succeeded)"
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle session.execution.succeeded opencode
  [ "$(row_count)" = "1" ]
}

@test "opencode: a harness started from a tool shell inside the session is refused" {
  # root -> /bin/sh -> python, which runs the hook: the walk has to step over
  # the shell, whose environment macOS does not show, to find the root.
  harness opencode "$(opencode_payload session.execution.succeeded)" shell
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "is a child process of the hosted session"
}

@test "opencode: the hook run through a shell, not by the harness itself, is refused" {
  harness opencode "$(opencode_payload session.execution.succeeded)" via-shell
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "no row written: "
}

@test "opencode: a caller started without the generation is refused even when it sets it later" {
  harness opencode "$(opencode_payload session.execution.succeeded)" late
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "does not carry this session's generation"
}

@test "only a plugin-env channel is checked: a claude-code hook run through a shell still journals" {
  harness claude-code '{"hook_event_name":"Stop"}' python via-shell
  assert_silent_exit
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle Stop
}

@test "payload fields copied into links are single-line and bounded" {
  long=$(python3 -c 'print("x" * 400)')
  fire claude-code "$(jq -nc --arg e "rate
limit $long" '{hook_event_name: "StopFailure", error: $e}')"
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  [ -n "$row" ]
  error=$(jq -r '.links.error' <<<"$row")
  contains "|$error" "|rate limit xxx"
  [ "${#error}" -le 200 ]
}

# --- actor_instance names the current owner of this launch ---

@test "after adoption the row names the live owner listing this launch, not the spawn instance" {
  start_live_process
  live=$LIVE_PID
  write_registry spawn-host spawn-host "$(dead_pid)" 9 "" "$LAUNCH"
  write_registry adopter adopter "$live" 5 "" "$LAUNCH"
  write_registry spawn-0123abcd spawn-0123abcd "$live" 99 session-host-spawn "$LAUNCH"
  write_registry other-host other-host "$live" 50 "" "$OTHER_LAUNCH"
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  row=$(hook_rows | tail -n 1)
  [ "$(jq -r '.actor_instance' <<<"$row")" = "adopter" ]
  [ "$(jq -r '.links.spawn_instance' <<<"$row")" = "spawn-host" ]
}

@test "when two live owners list this launch, the newest revision names the owner" {
  start_live_process
  write_registry older-host older-host "$LIVE_PID" 3 "" "$LAUNCH"
  write_registry newer-host newer-host "$LIVE_PID" 9 "" "$LAUNCH"
  fire claude-code '{"hook_event_name":"UserPromptSubmit","prompt":"go"}'
  assert_silent_exit
  [ "$(hook_rows | tail -n 1 | jq -r '.actor_instance')" = "newer-host" ]
}

@test "a registry row past its 30 second heartbeat window is not an owner" {
  start_live_process
  write_registry stale-host stale-host "$LIVE_PID" 9 "" "$LAUNCH"
  touch -t 202601010000 "$TEST_KDIR/_sessions/instances/stale-host.json"
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  [ "$(hook_rows | tail -n 1 | jq -r '.actor_instance')" = "spawn-host" ]
}

# --- every failure is silent, exits 0, leaves no row, and logs one line ---

@test "a refused write leaves no row, prints nothing, exits 0, and logs the refusal" {
  unset LORE_SESSION_TYPE
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  log=$(hooks_log)
  [ "$(printf '%s\n' "$log" | grep -c .)" = "1" ]
  contains "$log" "the journal writer refused the row (exit 1)"
  contains "$log" "session_type"
  contains "$log" "slug=hook-slug"
  contains "$log" "hook_event=Stop"
}

@test "a payload that is not a JSON object leaves no row and logs why" {
  fire claude-code 'not json'
  assert_silent_exit
  fire claude-code '["Stop"]'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "payload on stdin was not a JSON object"
}

@test "a framework without a session_lifecycle_hooks cell leaves no row and logs why" {
  fire no-such-harness '{"hook_event_name":"Stop"}'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "cannot read frameworks.no-such-harness.session_lifecycle_hooks.events"
}

@test "LORE_AGENT_DISABLED=1 makes the hook a no-op" {
  export LORE_AGENT_DISABLED=1
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  [ ! -e "$TEST_KDIR/_sessions/hooks.log" ]
}

@test "without a generation or a slug the hook does nothing" {
  unset LORE_SESSION_GENERATION
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  export LORE_SESSION_GENERATION="$GENERATION"
  unset LORE_SESSION_SLUG
  fire claude-code '{"hook_event_name":"Stop"}'
  assert_silent_exit
  [ "$(row_count)" = "0" ]
  [ ! -e "$TEST_KDIR/_sessions/hooks.log" ]
}

@test "a journal writer that hangs is stopped and the hook returns within 5 seconds" {
  export HANG_PID_FILE="$BATS_TEST_TMPDIR/writer.pid"
  hook=$(hook_layout_with_writer 'echo $$ > "$HANG_PID_FILE"; exec sleep 60')
  start=$(now)
  run bash -c 'printf "%s" "$2" | bash "$1" claude-code' _ "$hook" '{"hook_event_name":"Stop"}'
  end=$(now)
  assert_silent_exit
  elapsed_below "$start" "$end" 5
  [ -s "$HANG_PID_FILE" ]
  if kill -0 "$(cat "$HANG_PID_FILE")" 2>/dev/null; then
    echo "the hung writer is still running"
    return 1
  fi
  contains "$(hooks_log)" "the journal writer had not finished after 4s and was stopped"
  [ "$(row_count)" = "0" ]
}

@test "stdin that never closes: a complete payload still journals, promptly" {
  fifo="$BATS_TEST_TMPDIR/stdin.fifo"
  mkfifo "$fifo"
  ( printf '%s' '{"hook_event_name":"Stop"}'; exec sleep 60 ) > "$fifo" 3>&- &
  LIVE_PIDS+=("$!")
  start=$(now)
  run bash -c 'bash "$1" claude-code < "$2"' _ "$HOOK" "$fifo"
  end=$(now)
  assert_silent_exit
  elapsed_below "$start" "$end" 5
  assert_hook_row "$(hook_rows | tail -n 1)" needs_input idle Stop
}

@test "stdin that never closes and carries nothing returns within 5 seconds and logs" {
  fifo="$BATS_TEST_TMPDIR/stdin.fifo"
  mkfifo "$fifo"
  ( exec sleep 60 ) > "$fifo" 3>&- &
  LIVE_PIDS+=("$!")
  start=$(now)
  run bash -c 'bash "$1" claude-code < "$2"' _ "$HOOK" "$fifo"
  end=$(now)
  assert_silent_exit
  elapsed_below "$start" "$end" 5
  [ "$(row_count)" = "0" ]
  contains "$(hooks_log)" "not a JSON object (0 bytes"
}

# --- the writer admits exactly one hook-row shape ---

@test "the writer accepts a well-formed hook row and a screen row with no authority link" {
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row)"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$APPEND" --kdir "$TEST_KDIR" --row '{"event":"needs_input","slug":"hook-slug","links":{"activity":"stalled","generation":"g","observed_at":"2026-10-18T10:00:00Z","observation":"{}"}}'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(row_count)" = "2" ]
}

@test "the writer refuses links.authority outside needs_input and resumed, or other than hook-row" {
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c '.event = "modal_blocked" | .reason = "modal"')"
  [ "$status" -eq 1 ]
  contains "$output" "invalid field: links.authority (allowed only on needs_input and resumed"
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c '.links.authority = "screen-signature"')"
  [ "$status" -eq 1 ]
  contains "$output" "invalid field: links.authority (must be hook-row"
  [ "$(row_count)" = "0" ]
}

@test "the writer refuses a hook row missing any required field" {
  for path in slug session_type actor_instance links.hook_event links.activity links.generation \
              links.fired_at links.framework links.spawn_instance; do
    run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c "del(.$path)")"
    [ "$status" -eq 1 ] || { echo "accepted a row without $path"; return 1; }
    contains "$output" "missing required field: $path (required on a hook row)" || { echo "$output"; return 1; }
  done
  [ "$(row_count)" = "0" ]
}

@test "the writer refuses a hook row whose activity does not fit its event" {
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c '.links.activity = "working"')"
  [ "$status" -eq 1 ]
  contains "$output" "invalid field: links.activity (a hook needs_input row reports idle or blocked)"
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c '.event = "resumed"')"
  [ "$status" -eq 1 ]
  contains "$output" "invalid field: links.activity (a hook resumed row reports working)"
  run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c '.event = "resumed" | .links.activity = "working"')"
  [ "$status" -eq 0 ]
}

@test "the writer refuses a hook row with queue or screen fields, a non-string link, or a malformed fired_at" {
  for mutation in '.request_id = "req-1"' '.links.observation = "{}"' '.links.tool_name = 3' \
                  '.links.error = "two\nlines"' '.links.tool_name = ""' \
                  '.links.fired_at = "2026-10-18 10:00:01"' '.links.fired_at = "2026-10-18T10:00:01+02:00"'; do
    run bash "$APPEND" --kdir "$TEST_KDIR" --row "$(valid_hook_row | jq -c "$mutation")"
    [ "$status" -eq 1 ] || { echo "accepted a row after $mutation"; return 1; }
    contains "$output" "invalid field: " || { echo "$output"; return 1; }
  done
  [ "$(row_count)" = "0" ]
}

# --- the hooks-only Claude settings fixture ---

@test "the hooks settings fixture uses only the keywords its validators read" {
  run python3 - "$SCHEMA" <<'PY'
import json, sys
allowed = {"$schema", "$id", "title", "description", "$comment", "type", "const", "enum",
           "required", "properties", "additionalProperties", "propertyNames", "items",
           "minItems", "minLength", "minProperties", "$ref", "$defs"}
def walk(node, where):
    if isinstance(node, dict):
        for key, value in node.items():
            if where.endswith(".properties") or where.endswith(".$defs"):
                walk(value, f"{where}.{key}")
                continue
            if key not in allowed:
                sys.exit(f"{where}: keyword {key!r} is outside the validated subset")
            walk(value, f"{where}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            walk(value, f"{where}[{i}]")
walk(json.load(open(sys.argv[1])), "$")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a hooks-only payload built from the declared claude-code events matches the fixture, and the shapes the docs rule out do not" {
  run python3 - "$SCHEMA" "$CAPS" "$HOOK" <<'PY'
import copy, json, sys
schema = json.load(open(sys.argv[1]))
events = json.load(open(sys.argv[2]))["frameworks"]["claude-code"]["session_lifecycle_hooks"]["events"]
command = f"{sys.argv[3]} claude-code"
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool}

def resolve(node):
    while "$ref" in node:
        node = schema["$defs"][node["$ref"].rsplit("/", 1)[1]]
    return node

def errors(node, value, where="$"):
    node, found = resolve(node), []
    expected = node.get("type")
    if expected and not isinstance(value, TYPES[expected]):
        return [f"{where}: expected {expected}"]
    if "const" in node and value != node["const"]:
        found.append(f"{where}: expected {node['const']!r}")
    if "enum" in node and value not in node["enum"]:
        found.append(f"{where}: {value!r} is not one of the documented values")
    if isinstance(value, str) and len(value) < node.get("minLength", 0):
        found.append(f"{where}: too short")
    if isinstance(value, dict):
        found += [f"{where}: missing {key}" for key in node.get("required", []) if key not in value]
        if len(value) < node.get("minProperties", 0):
            found.append(f"{where}: too few keys")
        for key, item in value.items():
            if "propertyNames" in node:
                found += errors(node["propertyNames"], key, f"{where}<{key}>")
            if key in node.get("properties", {}):
                found += errors(node["properties"][key], item, f"{where}.{key}")
            elif node.get("additionalProperties", True) is False:
                found.append(f"{where}: unexpected key {key}")
            elif isinstance(node.get("additionalProperties"), dict):
                found += errors(node["additionalProperties"], item, f"{where}.{key}")
    if isinstance(value, list):
        if len(value) < node.get("minItems", 0):
            found.append(f"{where}: too few items")
        for i, item in enumerate(value):
            found += errors(node.get("items", {}), item, f"{where}[{i}]")
    return found

hooks = {}
for event in events:
    group = {"hooks": [{"type": "command", "command": command, "async": True}]}
    if "matcher" in event:
        group = {"matcher": event["matcher"], **group}
    hooks.setdefault(event["hook_event"], []).append(group)
payload = {"hooks": hooks}
problems = errors(schema, payload)
if problems:
    sys.exit("declared events do not build a valid payload: " + "; ".join(problems))

def mutated(change):
    candidate = copy.deepcopy(payload)
    change(candidate)
    return candidate

ruled_out = {
    "a key beside hooks at the root": lambda p: p.update(env={"X": "1"}),
    "an undocumented event name": lambda p: p["hooks"].update(TurnEnded=p["hooks"]["Stop"]),
    "a matcher on the handler instead of the group": lambda p: p["hooks"]["PreToolUse"][0]["hooks"][0].update(matcher="Bash"),
    "a handler type other than command": lambda p: p["hooks"]["Stop"][0]["hooks"][0].update(type="http"),
    "a handler field outside type, command and async": lambda p: p["hooks"]["Stop"][0]["hooks"][0].update(asyncRewake=True),
    "a non-boolean async": lambda p: p["hooks"]["Stop"][0]["hooks"][0].update({"async": "true"}),
    "an empty handler list": lambda p: p["hooks"]["Stop"][0].update(hooks=[]),
    "an event mapped to a bare handler instead of matcher groups": lambda p: p["hooks"].update(Stop={"type": "command", "command": command}),
}
accepted = [name for name, change in ruled_out.items() if not errors(schema, mutated(change))]
if accepted:
    sys.exit("fixture accepted: " + ", ".join(accepted))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
