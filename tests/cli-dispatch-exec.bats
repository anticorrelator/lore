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

  for leaf in spec-start spec-discover spec-open spec-outcome; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
  done
  for leaf in retro-prepare retro-file; do
    cp "$TEST_SCRIPTS/session-wait.sh" "$TEST_SCRIPTS/$leaf.sh"
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
  for verb in start discover open outcome; do
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
