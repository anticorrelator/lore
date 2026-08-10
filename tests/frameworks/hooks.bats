#!/usr/bin/env bats
# hooks.bats — Smoke coverage for the per-harness hook adapters
# (Phase 3, T30).
#
# Verifies the two assertions named in adapters/hooks/README.md
# "Adapter implementor's checklist":
#   item 5: each adapter exposes a smoke subcommand that prints, for the
#           active framework, every Lore lifecycle event paired with its
#           support level (and, where applicable, the native harness hook
#           it routes through).
#   item 6: every hook command string emitted by the adapter uses the
#           stable `~/.lore/scripts/<name>` form, never `$(pwd)`-relative
#           or repo-absolute paths.
#
# What gets exercised:
#   - The closed Lore lifecycle event set declared in adapters/hooks/README.md
#     matches the keys each adapter's smoke output advertises (drift detector
#     for the closed-set invariant).
#   - Every adapter prints exactly the nine Lore events + their support
#     levels + a description of what the cell binds to.
#   - For each adapter, each event's support level matches the
#     capabilities.json cell (no adapter-side drift from the registry).
#   - Adapter source files use stable `~/.lore/scripts/<name>` paths in
#     every emitted hook command (grep-based; covers the install path and
#     the smoke summary).
#
# Coverage matrix:
#   - claude-code adapter: required (T25 ships the reference impl).
#   - opencode adapter:    required (T26 ships in the same phase).
#   - codex adapter:       optional — skips with a clear reason if
#                          adapters/codex/hooks.sh has not landed yet.
#
# Style: pure bats. Skips cleanly when prerequisites (python3, bats, the
# adapter binary itself) are missing.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
HOOKS_README="$REPO_DIR/adapters/hooks/README.md"
CC_ADAPTER="$REPO_DIR/adapters/hooks/claude-code.sh"
OC_ADAPTER="$REPO_DIR/adapters/opencode/lore-hooks.ts"
CODEX_ADAPTER="$REPO_DIR/adapters/codex/hooks.sh"

# Closed Lore event set per adapters/hooks/README.md "Lifecycle Events".
# Tests assert each adapter advertises exactly these tokens.
LORE_EVENTS=(
  session_start
  user_prompt
  pre_tool
  post_tool
  permission_request
  pre_compact
  stop
  session_end
  task_completed
)

setup() {
  [ -f "$CAPS" ] || skip "adapters/capabilities.json missing"
  [ -f "$HOOKS_README" ] || skip "adapters/hooks/README.md missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for capability cell lookup"

  # Stage an isolated LORE_DATA_DIR so adapter smoke commands resolve
  # settings.json without touching the user's real config. The Go and bash
  # sides both walk the LORE_DATA_DIR/scripts symlink to find the repo, so we
  # replicate that here.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

# --- Helpers ---

set_framework() {
  export LORE_FRAMEWORK="$1"
  cat > "$TEST_LORE_DATA_DIR/config/settings.json" <<EOF
{"version":1,"tui_launch_framework":"$1","capability_overrides":{},"harnesses":{"claude-code":{"args":[]},"opencode":{"args":[]},"codex":{"args":[]}}}
EOF
}

# Look up frameworks.<fw>.capabilities.<cap>.support from capabilities.json.
# Prints the support level (full|partial|fallback|none) on stdout, exits 0;
# exits non-zero if the cell is missing.
cap_support() {
  local fw="$1" cap="$2"
  CAPS="$CAPS" FW="$fw" CAP="$cap" python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
fw = d["frameworks"].get(os.environ["FW"], {})
cell = (fw.get("capabilities") or {}).get(os.environ["CAP"])
if not cell or "support" not in cell:
    sys.exit(2)
print(cell["support"])
PYEOF
}

# Closed map — Lore event -> capabilities.json key — must mirror the
# table in adapters/hooks/README.md "Lifecycle Events" + the adapter
# CAPABILITY_KEY constants. Drift here means drift in the contract; the
# closed-set assertion test (below) catches it.
event_to_capability() {
  case "$1" in
    session_start)      echo session_start_hook ;;
    user_prompt)        echo tool_hooks ;;
    pre_tool)           echo tool_hooks ;;
    post_tool)          echo tool_hooks ;;
    permission_request) echo permission_hooks ;;
    pre_compact)        echo pre_compact_hook ;;
    stop)               echo stop_hook ;;
    session_end)        echo stop_hook ;;
    task_completed)     echo task_completed_hook ;;
    *) return 1 ;;
  esac
}

# ============================================================
# Closed-set invariant — README is the source of truth
# ============================================================

@test "README declares exactly the nine Lore lifecycle events" {
  # Pull the event names from the README's "Lifecycle Events (Closed Set)"
  # table, then compare to the LORE_EVENTS array. Any drift is a contract
  # violation (the README is the source of truth per T24).
  EXPECTED_EVENTS="${LORE_EVENTS[*]}" \
  README_PATH="$HOOKS_README" \
  run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["README_PATH"]).read()
m = re.search(r"## Lifecycle Events \(Closed Set\)(.*?)## Dispatch Contract", text, re.S)
if not m:
    print("could not locate Lifecycle Events section in README"); sys.exit(2)
section = m.group(1)
events = re.findall(r"^\| `([a-z_]+)`\s*\|", section, re.M)
expected = sorted(os.environ["EXPECTED_EVENTS"].split())
got = sorted(set(events))
if got != expected:
    print("README events:", got)
    print("expected:    ", expected)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# claude-code adapter (T25 reference impl)
# ============================================================

@test "claude-code adapter exposes a smoke subcommand" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  # Header line + at least one event row should be present.
  [[ "$output" =~ "claude-code" ]]
}

@test "claude-code smoke advertises every Lore lifecycle event" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "claude-code smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "claude-code smoke support levels match capabilities.json" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    cap=$(event_to_capability "$event")
    expected=$(cap_support claude-code "$cap")
    # Each smoke row begins with two leading spaces, the event name padded
    # to 20, then the support level. Match the (event, level) pair via a
    # whitespace-tolerant regex so we don't pin column counts.
    if ! grep -qE "(^|[[:space:]])${event}[[:space:]]+${expected}([[:space:]]|$)" <<<"$output"; then
      echo "claude-code smoke event=$event expected support=$expected"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "claude-code adapter source uses ~/.lore/scripts/ for every hook command" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  # Every line in claude-code.sh that mentions a script under .lore/scripts/
  # MUST use the stable `~/.lore/scripts/<name>` form (T24 checklist item
  # 6). Any reference to a different lore script root (e.g. the literal
  # repo path, $LORE_DATA_DIR/scripts hard-coded into a hook command, or
  # a `lore/scripts/` legacy path *outside* the is_lore_hook detector) is
  # a regression. Allow the legacy-detection literals because they only
  # match user-installed entries during uninstall scrubbing.
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|\$LORE_DATA_DIR/scripts/[a-z_-]+\.(sh|py)|/work/.*/scripts/[a-z_-]+\.(sh|py))' "$CC_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "claude-code adapter contains hook command paths that are not ~/.lore/scripts/:"
    echo "$bad_lines"
    return 1
  fi

  # Positive assertion — at least one ~/.lore/scripts/ reference exists.
  run grep -cE '~/\.lore/scripts/[a-z_-]+\.(sh|py)' "$CC_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "claude-code smoke fails fast when active framework is not claude-code" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework opencode
  run bash "$CC_ADAPTER" smoke
  # Adapter MUST refuse to smoke when active framework != claude-code,
  # per the require_claude_code() guard. Either non-zero exit OR an
  # explicit error message is acceptable; we assert both for clarity.
  [ "$status" -ne 0 ]
  [[ "$output" =~ claude-code ]]
}

@test "claude-code install preserves user hooks and adds the exact Agent guidance gate" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  export HOME="$TEST_LORE_DATA_DIR/home"
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"user-owned-hook"}]}]}}
JSON
  run bash "$CC_ADAPTER" install --framework claude-code
  [ "$status" -eq 0 ]
  run python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d["hooks"]["PreToolUse"]
assert any(r.get("matcher") == "Bash" and r["hooks"][0]["command"] == "user-owned-hook" for r in rows)
agent = [r for r in rows if r.get("matcher") == "Agent"]
assert len(agent) == 1
assert agent[0]["hooks"][0]["command"] == "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook claude-code"
PY
  [ "$status" -eq 0 ]
}

@test "every claude-code hook command is pinned to LORE_FRAMEWORK=claude-code" {
  # framework.json holds one framework string (last install wins), so on a
  # multi-harness install any hook command that resolves through it routes to
  # the wrong harness's capability profile. The env prefix is the only thing
  # that pins a hook to its own adapter, so the assertion quantifies over every
  # command the adapter writes — a hook added later without the prefix fails
  # here rather than misrouting silently in a mixed install.
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  export HOME="$TEST_LORE_DATA_DIR/home"
  mkdir -p "$HOME/.claude"
  run bash "$CC_ADAPTER" install --framework claude-code
  [ "$status" -eq 0 ]
  run python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
commands = [
    h["command"]
    for entries in d["hooks"].values()
    for entry in entries
    for h in entry.get("hooks", [])
    if h.get("type") == "command"
]
# Lower bound guards against a parse that finds nothing and passes vacuously.
assert len(commands) >= 8, commands
unpinned = [c for c in commands if not c.startswith("LORE_FRAMEWORK=claude-code ")]
assert not unpinned, unpinned
PY
  [ "$status" -eq 0 ]
}

# ============================================================
# Arm-once: the Stop entry, and the command it runs
# ============================================================
#
# `lore coordinate arm` composes a watcher command; the claude-code adapter
# owns the Stop-entry shape that carries it. The two are tested together
# because neither is correct alone: an entry with no explicit timeout is
# killed silently mid-window, and a command that does not exit 2 is never
# delivered even when the entry is perfect.

ARM_SH="$REPO_DIR/scripts/coordinate-arm.sh"

# Stage a scripts/ directory holding the real arm script and lib.sh next to a
# stub watcher, so wrapper behavior is exercised without a live journal. The
# stub's exit code is the watch terminal under test.
stage_arm_harness() {
  ARM_ROOT="$(mktemp -d)"
  mkdir -p "$ARM_ROOT/scripts" "$ARM_ROOT/kdir/_coordination"
  cp "$REPO_DIR/scripts/lib.sh" "$REPO_DIR/scripts/coordinate-arm.sh" "$ARM_ROOT/scripts/"
  cat > "$ARM_ROOT/scripts/coordinate-watch.sh" <<'EOF'
#!/usr/bin/env bash
echo "watch-args: $*"
echo "watch-diagnostic" >&2
exit "${STUB_WATCH_EXIT:-0}"
EOF
  chmod +x "$ARM_ROOT/scripts/coordinate-watch.sh"
}

teardown_arm_harness() {
  [ -n "${ARM_ROOT:-}" ] && rm -rf "$ARM_ROOT"
  ARM_ROOT=""
}

@test "coordinate arm refuses a handle-less arm and names both flags" {
  set_framework claude-code
  run bash "$ARM_SH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--owner-pid"* ]]
  [[ "$output" == *"--owner-tmux"* ]]
}

@test "coordinate arm refuses a hook timeout that does not outlast the window" {
  set_framework claude-code
  run bash "$ARM_SH" --owner-pid 1 --window 3600 --hook-timeout 3600
  [ "$status" -eq 1 ]
  [[ "$output" == *"strictly greater"* ]]
}

@test "coordinate arm emits an asyncRewake entry whose timeout outlasts the window" {
  set_framework claude-code
  run bash "$ARM_SH" --owner-pid 1 --window 600 --hook-timeout 900 --render --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["turn_boundary_rewake"] == "full", d["turn_boundary_rewake"]
hook = d["hook_entry"]["hooks"][0]
assert hook["asyncRewake"] is True, hook
assert hook["timeout"] == 900, hook
assert hook["timeout"] > d["window_seconds"], hook
assert hook["rewakeMessage"], "entry must carry a rewakeMessage"
cmd = hook["command"]
assert cmd.startswith("LORE_FRAMEWORK=claude-code "), cmd
assert "~/.lore/scripts/coordinate-arm.sh run" in cmd, cmd
assert "--owner-pid 1" in cmd, cmd
assert "--window 600" in cmd, cmd
'
}

@test "coordinate arm installs into the named settings file and re-arms in place" {
  set_framework claude-code
  settings="$TEST_LORE_DATA_DIR/seat-settings.json"
  cat > "$settings" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-owned-stop"}]}]}}
JSON
  run bash "$ARM_SH" --owner-pid 1 --window 600 --hook-timeout 900 --install "$settings"
  [ "$status" -eq 0 ]
  # pid 1 again rather than a second made-up number: arming now refuses a pid
  # that is not alive, and what this case is about is the second arm replacing
  # the first entry in place rather than stacking beside it.
  run bash "$ARM_SH" --owner-pid 1 --window 700 --hook-timeout 1000 --install "$settings"
  [ "$status" -eq 0 ]
  run python3 - "$settings" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["hooks"]["Stop"]
assert any(r["hooks"][0]["command"] == "user-owned-stop" for r in rows), rows
armed = [r for r in rows if "coordinate-arm.sh" in r["hooks"][0]["command"]]
assert len(armed) == 1, f"re-arming stacked {len(armed)} watchers"
assert armed[0]["hooks"][0]["timeout"] == 1000, armed
PY
  [ "$status" -eq 0 ]
}

@test "rewake-entry refuses to render an entry with no explicit timeout" {
  set_framework claude-code
  run bash "$CC_ADAPTER" rewake-entry --command "bash ~/.lore/scripts/coordinate-arm.sh run"
  [ "$status" -ne 0 ]
  [[ "$output" == *"timeout"* ]]
}

@test "coordinate arm degrades without installing where rewake is not full" {
  # codex has the continuation channel but not async execution; opencode has
  # neither. Both must still print a runnable watcher command on request — a
  # capability gap degrades the loop, it never aborts it — and both must refuse
  # --install, because an installed entry there would re-arm nothing. Printing
  # is a request in its own right (--render): a bare arm here would exit 0
  # having armed nothing, which is what a seat reads as an armed watcher.
  for fw in codex opencode; do
    set_framework "$fw"
    run bash "$ARM_SH" --owner-pid 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"--render"* ]]

    run bash "$ARM_SH" --owner-pid 1 --render
    [ "$status" -eq 0 ]
    [[ "$output" == *"degraded"* ]]
    [[ "$output" == *"coordinate-arm.sh run"* ]]
    [[ "$output" == *"LORE_FRAMEWORK=$fw"* ]]

    run bash "$ARM_SH" --owner-pid 1 --install "$TEST_LORE_DATA_DIR/$fw-settings.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing --install"* ]]
    [ ! -f "$TEST_LORE_DATA_DIR/$fw-settings.json" ]
  done
}

@test "the armed command turns every watch terminal into a wake on stderr" {
  # The polarity shim. `coordinate watch` says 0 for a match and 2 for a quiet
  # timeout; the rewake channel only reads exit 2 with something on stderr, and
  # treats everything else as silence. A quiet window that stayed silent would
  # end the chain, so it wakes too.
  stage_arm_harness
  for stub in 0 2; do
    run env STUB_WATCH_EXIT="$stub" bash "$ARM_ROOT/scripts/coordinate-arm.sh" run \
      --owner-pid $$ --window 5 --kdir "$ARM_ROOT/kdir"
    [ "$status" -eq 2 ]
    [[ "$output" == *"[coordinate wake]"* ]]
    [[ "$output" == *"watch-args: --wake-shaped --timeout 5"* ]]
  done
  # A reader failure is a wake too, labeled as one, rather than a chain that
  # ends without saying why.
  run env STUB_WATCH_EXIT=4 LORE_ARM_ERROR_BACKOFF_SECONDS=1 \
    bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 5 --kdir "$ARM_ROOT/kdir"
  [ "$status" -eq 2 ]
  [[ "$output" == *"watcher-failed"* ]]

  # A watcher that returns nothing at all still has to exit 2 with a header on
  # stderr. Anything else and the seat never wakes, so it never re-arms.
  cat > "$ARM_ROOT/scripts/coordinate-watch.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$ARM_ROOT/scripts/coordinate-watch.sh"
  run bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 3 --kdir "$ARM_ROOT/kdir"
  [ "$status" -eq 2 ]
  [[ "$output" == *"[coordinate wake] quiet"* ]]
  teardown_arm_harness
}

# A stub that keeps the alpha-scoped window open long enough to contend with,
# and returns immediately for every other scope. Used by the guard tests so a
# non-contending scope is proven by a fast, complete window rather than a
# timeout.
stage_slow_alpha_watcher() {
  cat > "$ARM_ROOT/scripts/coordinate-watch.sh" <<'EOF'
#!/usr/bin/env bash
echo "watch-args: $*"
case "$*" in *alpha*) sleep 8 ;; esac
exit 0
EOF
  chmod +x "$ARM_ROOT/scripts/coordinate-watch.sh"
}

# Block until the armed wrapper has actually entered its window — it forks the
# watcher only after taking the lock, so a child is proof the lock is held.
wait_for_window() {
  local arm_pid="$1"
  for _ in $(seq 1 200); do
    [ -n "$(pgrep -P "$arm_pid" 2>/dev/null)" ] && return 0
    sleep 0.05
  done
  echo "armed window never started for pid $arm_pid"
  return 1
}

@test "a second armed window on the same scope exits silently instead of stacking a watcher" {
  # Stop fires at every turn boundary and the harness deduplicates nothing, so
  # this is the ordinary case, not a race: a user message mid-window arms a
  # second watcher on the same scope and the same cursor.
  stage_arm_harness
  stage_slow_alpha_watcher

  bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug alpha >"$ARM_ROOT/first.out" 2>"$ARM_ROOT/first.err" &
  first_pid=$!
  wait_for_window "$first_pid"

  started="$(date +%s)"
  run bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug alpha
  elapsed=$(( $(date +%s) - started ))
  # Exit 0 is the only terminal a completed window cannot reach (it wakes with 2
  # or stops with 3), so this alone proves the second instance never ran one.
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # And it declined immediately rather than blocking on the held lock.
  [ "$elapsed" -lt 5 ]

  # Exactly one lock for the scope, and exactly one wake from the one window
  # that owned it.
  locks=("$ARM_ROOT"/kdir/_coordination/arm-window-*.lock)
  [ "${#locks[@]}" -eq 1 ]

  first_status=0
  wait "$first_pid" || first_status=$?
  [ "$first_status" -eq 2 ]
  [ "$(grep -c '\[coordinate wake\]' "$ARM_ROOT/first.err")" -eq 1 ]
  teardown_arm_harness
}

@test "the window lock is per scope, so unrelated scopes both run" {
  # The guard must not become a global mutex: two seats watching different work
  # have no reason to serialize, and a beta window that waited on alpha's would
  # be a wake the guard swallowed rather than deduplicated.
  stage_arm_harness
  stage_slow_alpha_watcher

  bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug alpha >/dev/null 2>&1 &
  first_pid=$!
  wait_for_window "$first_pid"

  run bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug beta
  [ "$status" -eq 2 ]
  [[ "$output" == *"[coordinate wake] actionable"* ]]
  [[ "$output" == *"--slug beta"* ]]

  # Two scopes, two distinct locks.
  locks=("$ARM_ROOT"/kdir/_coordination/arm-window-*.lock)
  [ "${#locks[@]}" -eq 2 ]

  # TERM the wrapper, not the watcher: the wrapper's own trap tears the window
  # down, where killing the watcher underneath it would look like a reader
  # failure and back off for a minute.
  kill -TERM "$first_pid" 2>/dev/null || true
  wait "$first_pid" || true
  teardown_arm_harness
}

@test "a dead window releases its lock without leaving a stale holder behind" {
  # The guard is an flock on a descriptor the wrapper holds, so the kernel drops
  # it on process death — including a SIGKILL that runs no trap. Nothing here
  # inspects or repairs a recorded pid, and nothing should need to.
  stage_arm_harness
  stage_slow_alpha_watcher

  bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug alpha >/dev/null 2>&1 &
  first_pid=$!
  wait_for_window "$first_pid"
  # SIGKILL the wrapper and reap the watcher it can no longer clean up. The
  # watcher never inherited the lock descriptor, so its survival must not keep
  # the scope locked either.
  watch_pids="$(pgrep -P "$first_pid" 2>/dev/null || true)"
  kill -KILL "$first_pid"
  wait "$first_pid" || true
  for p in $watch_pids; do kill -KILL "$p" 2>/dev/null || true; done

  # Same scope, lock file still on disk — but unheld, so the next turn boundary
  # re-arms normally instead of finding a corpse in the way.
  [ -f "$(echo "$ARM_ROOT"/kdir/_coordination/arm-window-*.lock)" ]
  cat > "$ARM_ROOT/scripts/coordinate-watch.sh" <<'EOF'
#!/usr/bin/env bash
echo "watch-args: $*"
exit 0
EOF
  chmod +x "$ARM_ROOT/scripts/coordinate-watch.sh"
  run bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 25 \
    --kdir "$ARM_ROOT/kdir" --slug alpha
  [ "$status" -eq 2 ]
  [[ "$output" == *"[coordinate wake] actionable"* ]]
  teardown_arm_harness
}

@test "the armed command relays scope flags to the watcher" {
  stage_arm_harness
  run env STUB_WATCH_EXIT=0 bash "$ARM_ROOT/scripts/coordinate-arm.sh" run \
    --owner-pid $$ --window 5 --kdir "$ARM_ROOT/kdir" --slug alpha --slug beta --arc gamma
  [ "$status" -eq 2 ]
  [[ "$output" == *"--slug alpha --slug beta --arc gamma"* ]]
  teardown_arm_harness
}

@test "the armed command exits without a wake when the owner is provably gone" {
  stage_arm_harness
  # A pid the probe can prove is not there. No wake body, and an exit code the
  # rewake channel ignores, so the chain stops instead of waking a dead seat.
  run env STUB_WATCH_EXIT=0 bash "$ARM_ROOT/scripts/coordinate-arm.sh" run \
    --owner-pid 2147483646 --window 5 --kdir "$ARM_ROOT/kdir"
  [ "$status" -eq 3 ]
  [[ "$output" != *"[coordinate wake]"* ]]
  [[ "$output" == *"owner is gone"* ]]
  teardown_arm_harness
}

@test "a SIGTERMed window leaves a marker distinguishing the kill from a wake" {
  stage_arm_harness
  cat > "$ARM_ROOT/scripts/coordinate-watch.sh" <<'EOF'
#!/usr/bin/env bash
sleep 60
EOF
  chmod +x "$ARM_ROOT/scripts/coordinate-watch.sh"
  bash "$ARM_ROOT/scripts/coordinate-arm.sh" run --owner-pid $$ --window 30 \
    --kdir "$ARM_ROOT/kdir" >/dev/null 2>&1 &
  arm_pid=$!
  # Let the window start before signalling it.
  for _ in $(seq 1 200); do
    [ -n "$(pgrep -P "$arm_pid" 2>/dev/null)" ] && break
    sleep 0.05
  done
  kill -TERM "$arm_pid"
  arm_status=0
  wait "$arm_pid" || arm_status=$?
  # 143 is what the harness sees, and it is exactly the code the rewake branch
  # does not read — hence the marker.
  [ "$arm_status" -eq 143 ]
  marker="$ARM_ROOT/kdir/_coordination/arm-window-killed.json"
  [ -f "$marker" ]
  run python3 - "$marker" <<'PY'
import json, sys
row = json.load(open(sys.argv[1]))
for field in ("killed_at", "owner", "window_seconds", "elapsed_seconds", "note"):
    assert row.get(field) not in (None, ""), field
PY
  [ "$status" -eq 0 ]
  teardown_arm_harness
}

# ============================================================
# opencode adapter (T26)
# ============================================================

@test "opencode adapter exposes a --smoke entrypoint" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # Smoke is gated on a runtime that can execute the .ts file. Skip
  # cleanly if neither tsx nor bun nor node-with-loader is available.
  if command -v tsx >/dev/null 2>&1; then
    runtime=(tsx)
  elif command -v bun >/dev/null 2>&1; then
    runtime=(bun)
  else
    skip "no TypeScript runtime available (need tsx or bun) to run lore-hooks.ts --smoke"
  fi
  set_framework opencode
  run "${runtime[@]}" "$OC_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ opencode ]]
}

@test "opencode smoke advertises every Lore lifecycle event" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  if command -v tsx >/dev/null 2>&1; then
    runtime=(tsx)
  elif command -v bun >/dev/null 2>&1; then
    runtime=(bun)
  else
    skip "no TypeScript runtime available to run lore-hooks.ts --smoke"
  fi
  set_framework opencode
  run "${runtime[@]}" "$OC_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "opencode smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "opencode adapter source uses ~/.lore/scripts/ paths or LORE_DATA_DIR" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # OpenCode adapter spawns Lore handler scripts via path.join with
  # LORE_DATA_DIR fallback to ~/.lore. Any literal `/work/` or
  # `git rev-parse`-derived absolute path is a regression — the plugin
  # runtime resolves $LORE_DATA_DIR/scripts/<name> at spawn time.
  bad=$(grep -nE '(/work/[^"]*scripts/[a-z_-]+\.(sh|py)|\$\(pwd\)/scripts/)' "$OC_ADAPTER" || true)
  if [ -n "$bad" ]; then
    echo "opencode adapter contains absolute repo paths in script invocations:"
    echo "$bad"
    return 1
  fi

  # Positive assertion — adapter mentions LORE_DATA_DIR or ~/.lore/scripts
  # somewhere (script path resolution).
  run grep -cE '(LORE_DATA_DIR|\.lore[/"\047]scripts)' "$OC_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "opencode adapter pins spawned handler scripts to LORE_FRAMEWORK=opencode" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  run grep -q 'LORE_FRAMEWORK: "opencode"' "$OC_ADAPTER"
  [ "$status" -eq 0 ]
}

@test "opencode refuses only the definite native task route when prompt enforcement is unverified" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  OC_ADAPTER="$OC_ADAPTER" run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["OC_ADAPTER"]).read()
required = [
    'payload.tool === "task"',
    "Run 'lore dispatch guidance'",
    'return { allow: false, reason: NATIVE_TASK_GUIDANCE_REASON }',
]
missing = [needle for needle in required if needle not in text]
if missing:
    print("missing exact OpenCode task refusal fragments:", missing)
    sys.exit(1)
body = re.search(
    r"export function refuseUnverifiedNativeTask\(.*?\n\}", text, re.S
)
if not body:
    print("could not locate refusal helper")
    sys.exit(2)
for heuristic in ('toLowerCase(', 'includes(', 'prompt', 'message'):
    if heuristic in body.group(0):
        print("unverified heuristic/prompt normalization in refusal helper:", heuristic)
        sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

@test "doctor checks capability-backed Claude and Codex guidance hook commands" {
  doctor="$REPO_DIR/scripts/doctor.sh"
  run grep -qF 'framework_capability native_dispatch_guidance_hook' "$doctor"
  [ "$status" -eq 0 ]
  run grep -qF 'LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook claude-code' "$doctor"
  [ "$status" -eq 0 ]
  run grep -qF 'LORE_FRAMEWORK=codex bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook codex' "$doctor"
  [ "$status" -eq 0 ]
}

@test "opencode adapter declares the same closed event set as the README" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # The TS LoreEvent type literal union must list exactly the nine Lore
  # events. Drift between the union and the README closed set is a
  # contract violation regardless of whether a TS runtime is installed.
  EXPECTED_EVENTS="${LORE_EVENTS[*]}" \
  OC_ADAPTER="$OC_ADAPTER" \
  run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["OC_ADAPTER"]).read()
m = re.search(r"export type LoreEvent\s*=\s*([^;]+);", text)
if not m:
    print("could not locate LoreEvent type alias in opencode adapter"); sys.exit(2)
union = m.group(1)
got = sorted(set(re.findall(r'"([a-z_]+)"', union)))
expected = sorted(os.environ["EXPECTED_EVENTS"].split())
if got != expected:
    print("opencode LoreEvent union:", got)
    print("expected:                ", expected)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# codex adapter (T27 — optional until adapter lands)
# ============================================================

@test "codex adapter exposes a smoke subcommand" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ codex ]]
}

@test "codex smoke advertises every Lore lifecycle event" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "codex smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "codex smoke support levels match capabilities.json" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    cap=$(event_to_capability "$event")
    expected=$(cap_support codex "$cap")
    if ! grep -qE "(^|[[:space:]])${event}[[:space:]]+${expected}([[:space:]]|$)" <<<"$output"; then
      echo "codex smoke event=$event expected support=$expected"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "codex adapter source uses ~/.lore/scripts/ for every hook command" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|/work/.*/scripts/[a-z_-]+\.(sh|py))' "$CODEX_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "codex adapter contains hook command paths that are not ~/.lore/scripts/:"
    echo "$bad_lines"
    return 1
  fi
  run grep -cE '(~/\.lore/scripts/|LORE_DATA_DIR.*scripts)' "$CODEX_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "codex install preserves user TOML and adds the exact Agent guidance gate" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing"
  set_framework codex
  export HOME="$TEST_LORE_DATA_DIR/home"
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
model = "user-owned-model"
TOML
  run bash "$CODEX_ADAPTER" install --framework codex
  [ "$status" -eq 0 ]
  run grep -qF 'model = "user-owned-model"' "$HOME/.codex/config.toml"
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'matcher = "Agent"' "$HOME/.codex/config.toml")" -eq 1 ]
  [ "$(grep -cF 'LORE_FRAMEWORK=codex bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook codex' "$HOME/.codex/config.toml")" -eq 1 ]
}

@test "every codex hook command is pinned to LORE_FRAMEWORK=codex" {
  # Same invariant as the claude-code case: framework.json cannot distinguish
  # harnesses on a multi-harness install, so each adapter's commands carry
  # their own LORE_FRAMEWORK. Read the installed TOML rather than the heredoc
  # so the assertion covers what codex actually loads.
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing"
  set_framework codex
  export HOME="$TEST_LORE_DATA_DIR/home"
  mkdir -p "$HOME/.codex"
  run bash "$CODEX_ADAPTER" install --framework codex
  [ "$status" -eq 0 ]
  run python3 - "$HOME/.codex/config.toml" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    settings = tomllib.load(f)
commands = [
    entry["command"]
    for entries in settings.get("hooks", {}).values()
    for entry in entries
    if entry.get("command")
]
assert len(commands) >= 8, commands
unpinned = [c for c in commands if not c.startswith("LORE_FRAMEWORK=codex ")]
assert not unpinned, unpinned
PY
  [ "$status" -eq 0 ]
}
