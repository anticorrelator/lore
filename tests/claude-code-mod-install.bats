#!/usr/bin/env bats
# claude-code-mod-install.bats — the settings edit that loads lore's Claude Code
# mod: scripts/claude-code-mod-install.sh, and the harness toggle that calls it.
#
# Coverage:
#   - enable on a missing file, an empty file, and a file with an existing
#     CLAUDE_CODE_PLUGIN_DIRS value and unrelated settings.
#   - a repeat enable changes nothing.
#   - disable removes only the mod's entry, drops an emptied key and env block,
#     and is a no-op when the entry is absent.
#   - `lore harness disable claude-code` removes the entry; enable restores it.
#
# Style: pure bats; every test owns a temp HOME and LORE_DATA_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/.." && pwd -P)"
SCRIPT="$REPO_DIR/scripts/claude-code-mod-install.sh"
MOD_DIR="$REPO_DIR/adapters/claude-code-mod"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  TEST_HOME="$(mktemp -d)"
  TEST_DATA="$(mktemp -d)"
  mkdir -p "$TEST_HOME/.claude" "$TEST_DATA/config"
  ln -s "$REPO_DIR/scripts" "$TEST_DATA/scripts"
  export HOME="$TEST_HOME"
  export LORE_DATA_DIR="$TEST_DATA"
  unset LORE_FRAMEWORK
  SETTINGS="$TEST_HOME/.claude/settings.json"
}

teardown() {
  rm -rf "$TEST_HOME" "$TEST_DATA"
}

dirs() {
  jq -r '.env.CLAUDE_CODE_PLUGIN_DIRS // "<unset>"' "$SETTINGS"
}

@test "enable creates the settings file when it is missing" {
  run bash "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "$MOD_DIR" ]
}

@test "enable fills an empty settings file" {
  : > "$SETTINGS"
  run bash "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "$MOD_DIR" ]
  [ "$(jq -c 'keys' "$SETTINGS")" = '["env"]' ]
}

@test "enable appends to an existing value and keeps every other setting" {
  cat > "$SETTINGS" <<'EOF'
{"tui": "fullscreen", "env": {"OTHER": "1", "CLAUDE_CODE_PLUGIN_DIRS": "/a:/b"}, "hooks": {"Stop": []}}
EOF
  run bash "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "/a:/b:$MOD_DIR" ]
  [ "$(jq -r '.env.OTHER' "$SETTINGS")" = "1" ]
  [ "$(jq -r '.tui' "$SETTINGS")" = "fullscreen" ]
  [ "$(jq -c '.hooks' "$SETTINGS")" = '{"Stop":[]}' ]
}

@test "a repeat enable leaves the file as it was" {
  printf '{"env": {"CLAUDE_CODE_PLUGIN_DIRS": "/a"}}\n' > "$SETTINGS"
  bash "$SCRIPT" enable
  before="$(cat "$SETTINGS")"
  run bash "$SCRIPT" enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"already lists"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
  [ "$(dirs)" = "/a:$MOD_DIR" ]
}

@test "enable keeps the file's permissions" {
  printf '{}\n' > "$SETTINGS"
  chmod 600 "$SETTINGS"
  bash "$SCRIPT" enable
  [ "$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS")" = "600" ]
}

@test "disable removes only the mod's entry" {
  printf '{"env": {"CLAUDE_CODE_PLUGIN_DIRS": "/a:%s:/b"}}\n' "$MOD_DIR" > "$SETTINGS"
  run bash "$SCRIPT" disable
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "/a:/b" ]
}

@test "disable of the only entry drops the key, and the env block once it is empty" {
  bash "$SCRIPT" enable
  run bash "$SCRIPT" disable
  [ "$status" -eq 0 ]
  [ "$(jq -c '.' "$SETTINGS")" = '{}' ]

  printf '{"env": {"OTHER": "1", "CLAUDE_CODE_PLUGIN_DIRS": "%s"}}\n' "$MOD_DIR" > "$SETTINGS"
  bash "$SCRIPT" disable
  [ "$(jq -c '.env' "$SETTINGS")" = '{"OTHER":"1"}' ]
}

@test "disable when the entry is absent changes nothing" {
  printf '{"env": {"CLAUDE_CODE_PLUGIN_DIRS": "/a"}}\n' > "$SETTINGS"
  before="$(cat "$SETTINGS")"
  run bash "$SCRIPT" disable
  [ "$status" -eq 0 ]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "a settings file that is not JSON is refused and left alone" {
  printf 'not json' > "$SETTINGS"
  run bash "$SCRIPT" enable
  [ "$status" -ne 0 ]
  [ "$(cat "$SETTINGS")" = "not json" ]
}

@test "lore harness disable claude-code removes the entry and enable restores it" {
  printf '{"env": {"CLAUDE_CODE_PLUGIN_DIRS": "/a"}}\n' > "$SETTINGS"
  bash "$SCRIPT" enable
  run bash "$REPO_DIR/scripts/harness-toggle/disable.sh" claude-code
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "/a" ]
  run bash "$REPO_DIR/scripts/harness-toggle/enable.sh" claude-code
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "/a:$MOD_DIR" ]
}

@test "toggling another harness leaves the entry alone" {
  bash "$SCRIPT" enable
  run bash "$REPO_DIR/scripts/harness-toggle/disable.sh" codex
  [ "$status" -eq 0 ]
  [ "$(dirs)" = "$MOD_DIR" ]
}
