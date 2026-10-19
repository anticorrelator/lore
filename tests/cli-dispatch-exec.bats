#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd)"
LORE="$REPO_DIR/cli/lore"

setup() {
  TEST_ROOT="$(mktemp -d)"
  TEST_HOME="$TEST_ROOT/home"
  TEST_SCRIPTS="$TEST_ROOT/scripts"
  TEST_ROUTER="$TEST_ROOT/lore"
  PID_FILE="$TEST_ROOT/leaf.pid"
  RELEASE_FILE="$TEST_ROOT/release"

  mkdir -p "$TEST_HOME/.lore" "$TEST_SCRIPTS"
  ln -s "$TEST_SCRIPTS" "$TEST_HOME/.lore/scripts"
  cp "$LORE" "$TEST_ROUTER"
  : > "$TEST_SCRIPTS/lib.sh"

  cat > "$TEST_SCRIPTS/session-wait.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$PID_FILE"
while [[ ! -e "$RELEASE_FILE" ]]; do
  sleep 0.01
done
exit 37
EOF
  chmod +x "$TEST_SCRIPTS/session-wait.sh"

  for leaf in spec-start spec-discover spec-open; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
  done
  for leaf in retro-prepare retro-file; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
  done
  for leaf in evolve-prepare evolve-file; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
  done
  for leaf in coordinate-arm coordinate-report coordinate-spend; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
  done
}

@test "evolve prepare and file exec at their deepest external dispatch arms" {
  local verb
  for verb in prepare file; do
    : > "$PID_FILE"
    rm -f "$RELEASE_FILE"
    HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
      bash "$TEST_ROUTER" evolve "$verb" &
    ROUTER_PID=$!

    for _ in $(seq 1 200); do
      [[ -s "$PID_FILE" ]] && break
      sleep 0.01
    done
    [[ -s "$PID_FILE" ]]
    [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

    touch "$RELEASE_FILE"
    local leaf_status=0
    wait "$ROUTER_PID" || leaf_status=$?
    ROUTER_PID=""
    [[ "$leaf_status" -eq 37 ]]
  done
}

@test "retro prepare and file exec at their deepest external dispatch arms" {
  local verb
  for verb in prepare file; do
    : > "$PID_FILE"
    rm -f "$RELEASE_FILE"
    HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
      bash "$TEST_ROUTER" retro "$verb" &
    ROUTER_PID=$!

    for _ in $(seq 1 200); do
      [[ -s "$PID_FILE" ]] && break
      sleep 0.01
    done
    [[ -s "$PID_FILE" ]]
    [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

    touch "$RELEASE_FILE"
    local leaf_status=0
    wait "$ROUTER_PID" || leaf_status=$?
    ROUTER_PID=""
    [[ "$leaf_status" -eq 37 ]]
  done
}

@test "all new spec leaves exec at the deepest external dispatch arm" {
  local verb
  for verb in start discover open; do
    : > "$PID_FILE"
    rm -f "$RELEASE_FILE"
    HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
      bash "$TEST_ROUTER" spec "$verb" &
    ROUTER_PID=$!

    for _ in $(seq 1 200); do
      [[ -s "$PID_FILE" ]] && break
      sleep 0.01
    done
    [[ -s "$PID_FILE" ]]
    [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

    touch "$RELEASE_FILE"
    local leaf_status=0
    wait "$ROUTER_PID" || leaf_status=$?
    ROUTER_PID=""
    [[ "$leaf_status" -eq 37 ]]
  done
}

teardown() {
  if [[ -n "${ROUTER_PID:-}" ]]; then
    kill "$ROUTER_PID" 2>/dev/null || true
    wait "$ROUTER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}

@test "coordinate arm execs its leaf and does not fall through to unknown-verb" {
  # The armed watcher window is a long-lived leaf: the router must hand the
  # process over rather than stay alive as its parent, so the pid the harness
  # signals at the hook timeout is the one running the window.
  : > "$PID_FILE"
  rm -f "$RELEASE_FILE"
  HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
    bash "$TEST_ROUTER" coordinate arm --owner-pid 1 &
  ROUTER_PID=$!

  for _ in $(seq 1 200); do
    [[ -s "$PID_FILE" ]] && break
    sleep 0.01
  done
  [[ -s "$PID_FILE" ]]
  [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

  touch "$RELEASE_FILE"
  local leaf_status=0
  wait "$ROUTER_PID" || leaf_status=$?
  ROUTER_PID=""
  [[ "$leaf_status" -eq 37 ]]
}

@test "the new coordinate verbs exec their leaves and do not fall through to unknown-verb" {
  # disarm routes to the arm script with a leading positional; report and spend
  # each have their own leaf. All three must hand the process over rather than
  # stay alive as a wrapper.
  local verb
  for verb in disarm report spend; do
    : > "$PID_FILE"
    rm -f "$RELEASE_FILE"
    HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
      bash "$TEST_ROUTER" coordinate "$verb" &
    ROUTER_PID=$!

    for _ in $(seq 1 200); do
      [[ -s "$PID_FILE" ]] && break
      sleep 0.01
    done
    [[ -s "$PID_FILE" ]]
    [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

    touch "$RELEASE_FILE"
    local leaf_status=0
    wait "$ROUTER_PID" || leaf_status=$?
    ROUTER_PID=""
    [[ "$leaf_status" -eq 37 ]]
  done
}

@test "coordinate board execs lore-tui's board renderer with its arguments" {
  local bin="$TEST_ROOT/bin" args_file="$TEST_ROOT/board.args"
  mkdir -p "$bin"
  # The router runs only a binary that carries the render flag's bytes.
  cat > "$bin/lore-tui" <<'EOF'
#!/usr/bin/env bash
# --render-board
printf '%s\n' "$*" > "$ARGS_FILE"
printf '%s\n' "$$" > "$PID_FILE"
while [[ ! -e "$RELEASE_FILE" ]]; do
  sleep 0.01
done
exit 37
EOF
  chmod +x "$bin/lore-tui"
  : > "$PID_FILE"
  rm -f "$RELEASE_FILE"
  HOME="$TEST_HOME" PATH="$bin:$PATH" ARGS_FILE="$args_file" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
    bash "$TEST_ROUTER" coordinate board --arc some-arc --width 80 --json &
  ROUTER_PID=$!

  for _ in $(seq 1 200); do
    [[ -s "$PID_FILE" ]] && break
    sleep 0.01
  done
  [[ -s "$PID_FILE" ]]
  [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]
  [[ "$(<"$args_file")" == "--render-board --arc some-arc --width 80 --json" ]]

  touch "$RELEASE_FILE"
  local leaf_status=0
  wait "$ROUTER_PID" || leaf_status=$?
  ROUTER_PID=""
  [[ "$leaf_status" -eq 37 ]]
}

# Runs the router against a lore-tui that would hang if it were ever started,
# as an older binary does when it opens the full-screen TUI, and requires a
# prompt exit 3 naming the remedy without running it.
board_refuses_without_running() {
  local path="$1" want="$2" out="$TEST_ROOT/board.out" ran="$TEST_ROOT/board.ran"
  HOME="$TEST_HOME" PATH="$path" RAN_FILE="$ran" \
    bash "$TEST_ROUTER" coordinate board --arc some-arc --width 80 > "$out" 2>&1 &
  ROUTER_PID=$!
  local waited=0
  while kill -0 "$ROUTER_PID" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 100 ]] || break
  done
  if kill -0 "$ROUTER_PID" 2>/dev/null; then
    kill "$ROUTER_PID" 2>/dev/null || true
    ROUTER_PID=""
    false
  fi
  local status=0
  wait "$ROUTER_PID" || status=$?
  ROUTER_PID=""
  [[ "$status" -eq 3 ]]
  [[ ! -e "$ran" ]]
  [[ "$(<"$out")" == "lore coordinate board: $want" ]]
}

@test "coordinate board refuses a lore-tui older than the render mode without running it" {
  local bin="$TEST_ROOT/old-bin"
  mkdir -p "$bin"
  cat > "$bin/lore-tui" <<'EOF'
#!/usr/bin/env bash
: > "$RAN_FILE"
sleep 30
EOF
  chmod +x "$bin/lore-tui"
  board_refuses_without_running "$bin:$PATH" "lore-tui is older than this command — run lore rebuild"
}

@test "coordinate board names the remedy when lore-tui is not installed" {
  local bin="$TEST_ROOT/empty-bin"
  mkdir -p "$bin"
  ln -s "$(command -v bash)" "$bin/bash"
  for tool in realpath dirname readlink; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  board_refuses_without_running "$bin" "lore-tui is not installed — run lore rebuild"
}

@test "rebuild stamps the build identity install.sh stamps" {
  local bin="$TEST_ROOT/go-bin" args_file="$TEST_ROOT/go.args"
  mkdir -p "$bin"
  cat > "$bin/go" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  env) [[ "$2" == GOOS ]] && echo darwin || echo arm64 ;;
  build)
    printf '%s\n' "$@" > "$GO_ARGS"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then mkdir -p "$(dirname "$2")"; : > "$2"; fi
      shift
    done
    ;;
esac
EOF
  chmod +x "$bin/go"
  HOME="$TEST_HOME" PATH="$bin:$PATH" GO_ARGS="$args_file" run bash "$LORE" rebuild
  [ "$status" -eq 0 ]
  local sha when
  sha="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  when="$(TZ=UTC git -C "$REPO_DIR" show -s --date=format-local:'%Y-%m-%dT%H:%M:%SZ' --format='%cd' HEAD)"
  [[ -n "$sha" && -n "$when" ]]
  grep -qxF -- "-ldflags" "$args_file"
  grep -qxF -- "-X main.buildSHA=$sha -X main.buildTime=$when" "$args_file"
  [[ -e "$TEST_HOME/.local/bin/lore-tui" ]]
}

@test "rebuild --help prints usage and an unknown flag refuses, neither building" {
  # A go stub that records every call: a build that slipped past the argument
  # guard would show up here, and its -o would land under the scratch HOME.
  # Each [[ ]] ends in '|| return 1' because macOS bash 3.2 does not fail a
  # bats test on a mid-test [[ ]] that is false.
  local bin="$TEST_ROOT/go-bin" calls="$TEST_ROOT/go.calls"
  mkdir -p "$bin"
  cat > "$bin/go" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GO_CALLS"
case "$1" in
  env) [[ "$2" == GOOS ]] && echo darwin || echo arm64 ;;
  build)
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == -o ]]; then mkdir -p "$(dirname "$2")"; : > "$2"; fi
      shift
    done
    ;;
esac
EOF
  chmod +x "$bin/go"

  local flag
  for flag in --help -h; do
    HOME="$TEST_HOME" PATH="$bin:$PATH" GO_CALLS="$calls" run bash "$LORE" rebuild "$flag"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: lore rebuild"* ]] || return 1
    [[ "$output" != *"Building lore-tui"* ]] || return 1
  done

  HOME="$TEST_HOME" PATH="$bin:$PATH" GO_CALLS="$calls" run bash "$LORE" rebuild --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument '--force' for lore rebuild"* ]] || return 1
  [[ "$output" == *"Usage: lore rebuild"* ]] || return 1
  [[ "$output" != *"Building lore-tui"* ]] || return 1

  [[ ! -e "$calls" ]] || return 1
  [[ ! -e "$TEST_HOME/.local/bin/lore-tui" ]] || return 1
}

@test "coordinate --help lists every verb and returns promptly" {
  # The usage heredoc cites sibling verbs in backticks. Were it unquoted, those
  # would be command substitutions and printing the help would run a watcher —
  # which does not fail, it hangs. So this is bounded rather than a plain run.
  local help_out="$TEST_ROOT/coordinate-help.txt"
  HOME="$TEST_HOME" bash "$TEST_ROUTER" coordinate --help > "$help_out" 2>&1 &
  ROUTER_PID=$!

  local waited=0
  while kill -0 "$ROUTER_PID" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    [[ "$waited" -lt 200 ]] || break
  done
  if kill -0 "$ROUTER_PID" 2>/dev/null; then
    kill "$ROUTER_PID" 2>/dev/null || true
    ROUTER_PID=""
    false
  fi
  wait "$ROUTER_PID" || true
  ROUTER_PID=""

  local output verb
  output="$(<"$help_out")"
  for verb in read board status reconcile watch arm disarm worktree report spend; do
    [[ "$output" == *"  $verb "* ]]
  done
  [[ "$output" != *"  pin "* ]]
}

@test "coordinate pin is no longer a verb" {
  run bash "$LORE" coordinate pin myproject --preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown coordinate verb 'pin'"* ]]
}

@test "session wait execs the leaf before a mid-wait router edit" {
  HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
    bash "$TEST_ROUTER" session wait &
  ROUTER_PID=$!

  for _ in $(seq 1 200); do
    [[ -s "$PID_FILE" ]] && break
    sleep 0.01
  done
  [[ -s "$PID_FILE" ]]

  # exec preserves the launched router PID as the leaf PID. A plain dispatch
  # would leave the router alive as the leaf's parent and fail this assertion.
  [[ "$(<"$PID_FILE")" == "$ROUTER_PID" ]]

  # Shift the router's byte offsets while the leaf is blocked. The running
  # process must no longer have a wrapper interpreter that can resume reading it.
  python3 - "$TEST_ROUTER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
path.write_bytes(b"# mid-dispatch byte shift\n" + path.read_bytes())
PY

  touch "$RELEASE_FILE"
  local status=0
  wait "$ROUTER_PID" || status=$?
  ROUTER_PID=""

  [[ "$status" -eq 37 ]]
}

@test "session request execs the ensuring entry in session-managed.py" {
  cat > "$TEST_SCRIPTS/session-managed.py" <<'EOF'
import os, sys, time
with open(os.environ["PID_FILE"], "w") as stream:
    stream.write(f"{os.getpid()} {' '.join(sys.argv[1:])}\n")
while not os.path.exists(os.environ["RELEASE_FILE"]):
    time.sleep(0.01)
sys.exit(37)
EOF
  : > "$PID_FILE"
  rm -f "$RELEASE_FILE"
  HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
    bash "$TEST_ROUTER" session request --type chat --anywhere &
  ROUTER_PID=$!
  for _ in $(seq 1 200); do
    [[ -s "$PID_FILE" ]] && break
    sleep 0.01
  done
  [[ "$(<"$PID_FILE")" == "$ROUTER_PID request --type chat --anywhere" ]]
  touch "$RELEASE_FILE"
  local leaf_status=0
  wait "$ROUTER_PID" || leaf_status=$?
  [[ "$leaf_status" -eq 37 ]]
}

@test "session ensure execs the ensuring entry in session-managed.py" {
  cat > "$TEST_SCRIPTS/session-managed.py" <<'EOF'
import os, sys, time
with open(os.environ["PID_FILE"], "w") as stream:
    stream.write(f"{os.getpid()} {' '.join(sys.argv[1:])}\n")
while not os.path.exists(os.environ["RELEASE_FILE"]):
    time.sleep(0.01)
sys.exit(37)
EOF
  : > "$PID_FILE"
  rm -f "$RELEASE_FILE"
  HOME="$TEST_HOME" PID_FILE="$PID_FILE" RELEASE_FILE="$RELEASE_FILE" \
    bash "$TEST_ROUTER" session ensure --if-work --json &
  ROUTER_PID=$!
  for _ in $(seq 1 200); do
    [[ -s "$PID_FILE" ]] && break
    sleep 0.01
  done
  [[ "$(<"$PID_FILE")" == "$ROUTER_PID ensure --if-work --json" ]]
  touch "$RELEASE_FILE"
  local leaf_status=0
  wait "$ROUTER_PID" || leaf_status=$?
  [[ "$leaf_status" -eq 37 ]]
}
