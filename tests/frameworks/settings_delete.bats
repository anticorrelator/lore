#!/usr/bin/env bats
# settings_delete.bats — bash side of the D9 explicit-unset gesture.
#
# settings.sh delete <path> implements the Delete boundary contract from
# the TUI settings configurator work item:
#   - idempotent on absent paths (success / no-op, file byte-identical)
#   - no parent pruning (emptied parent objects stay)
#   - no whole-doc validation (structural delete only)
#   - error semantics on parse / lock / rename failure leave the prior
#     settings.json intact
#
# The kebab-case key `claude-code` is the canonical sharp edge: a
# string-interpolated jq expression like `del(.harnesses.claude-code)`
# parses `claude-code` as `claude` minus `code`. settings.sh delete must
# use the path-array form (`delpaths([$p])` with `_path_to_array`) to
# round-trip dashed segments correctly.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
SETTINGS_SH="$REPO_DIR/scripts/settings.sh"

setup() {
  [ -f "$SETTINGS_SH" ] || skip "scripts/settings.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required for settings.sh"

  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  SETTINGS_FILE="$TEST_LORE_DATA_DIR/config/settings.json"
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

write_settings() {
  printf '%s' "$1" > "$SETTINGS_FILE"
}

bash_get() {
  bash "$SETTINGS_SH" get "$1" 2>/dev/null
}

bash_delete() {
  bash "$SETTINGS_SH" delete "$1"
}

# ============================================================
# Round-trip: patch → delete → absent
# ============================================================

@test "settings.sh delete: round-trip patch → delete → absent" {
  bash "$SETTINGS_SH" patch "roles.lead" '"opus"'
  [ "$(bash_get roles.lead)" = '"opus"' ]
  bash_delete "roles.lead"
  [ -z "$(bash_get roles.lead)" ]
}

# ============================================================
# Kebab-case path: claude-code parses as a single key segment, not
# subtraction. This is the load-bearing reason settings.sh delete uses
# `delpaths([$p])` rather than string-interpolated `del(.harnesses.claude-code)`.
# ============================================================

@test "settings.sh delete: kebab-case key (claude-code) round-trips" {
  bash "$SETTINGS_SH" patch "harnesses.claude-code.roles.lead" '"opus"'
  [ "$(bash_get harnesses.claude-code.roles.lead)" = '"opus"' ]
  bash_delete "harnesses.claude-code.roles.lead"
  [ -z "$(bash_get harnesses.claude-code.roles.lead)" ]
}

# ============================================================
# No parent pruning: emptied parent objects stay so the configurator
# can distinguish absent from explicit-empty per D9.
# ============================================================

@test "settings.sh delete: no parent pruning (emptied parent stays present)" {
  bash "$SETTINGS_SH" patch "harnesses.claude-code.roles.lead" '"opus"'
  bash_delete "harnesses.claude-code.roles.lead"

  # roles is now empty {} but still present; harnesses.claude-code is
  # still present with at least the empty roles object inside it.
  roles_section=$(bash "$SETTINGS_SH" get "harnesses.claude-code.roles")
  [ "$roles_section" = '{}' ]

  cc_present=$(jq -r 'has("harnesses") and (.harnesses | has("claude-code"))' "$SETTINGS_FILE")
  [ "$cc_present" = "true" ]
}

# Three-pronged version of the no-parent-pruning contract: sibling
# preservation, grandparent's peer key untouched, second-delete is a
# strict no-op (mtime preserved). Mirrors TestSettingsDelete_NoParentPruning
# on the Go side.
@test "settings.sh delete: preserves siblings, grandparent peer, and second delete is mtime-stable" {
  bash "$SETTINGS_SH" patch "harnesses.claude-code.args" '["--flag"]'
  bash "$SETTINGS_SH" patch "harnesses.claude-code.roles.lead" '"opus"'
  bash "$SETTINGS_SH" patch "harnesses.claude-code.roles.worker" '"sonnet"'

  bash_delete "harnesses.claude-code.roles.lead"

  # Sibling under same parent survives.
  [ "$(bash_get harnesses.claude-code.roles.worker)" = '"sonnet"' ]
  # The deleted leaf is absent.
  [ -z "$(bash_get harnesses.claude-code.roles.lead)" ]
  # Grandparent's peer key (.args) unchanged in value.
  [ "$(bash_get harnesses.claude-code.args)" = '["--flag"]' ]

  # Second delete on the now-absent path must be byte-identical (no mv).
  before_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}' \
    || md5 -q "$SETTINGS_FILE")
  bash_delete "harnesses.claude-code.roles.lead"
  after_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}' \
    || md5 -q "$SETTINGS_FILE")
  [ "$before_md5" = "$after_md5" ]
}

# ============================================================
# Idempotence: absent-path delete is a no-op (byte-identical file).
# ============================================================

@test "settings.sh delete: absent path is a no-op (byte-identical file)" {
  # Stage a file with deliberately non-canonical formatting — a foreign
  # writer's whitespace. If `delete` re-marshalled via jq pretty-print
  # on the absent-key branch it would trample this layout.
  printf '%s' '{
"version": 1,
  "tui_launch_framework":"opencode"
}
' > "$SETTINGS_FILE"
  before_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}' \
    || md5 -q "$SETTINGS_FILE")

  bash_delete "nonexistent.path"

  after_md5=$(md5sum "$SETTINGS_FILE" 2>/dev/null | awk '{print $1}' \
    || md5 -q "$SETTINGS_FILE")
  [ "$before_md5" = "$after_md5" ]
}

@test "settings.sh delete: idempotent repeated delete" {
  bash "$SETTINGS_SH" patch "roles.lead" '"opus"'
  bash_delete "roles.lead"
  # Second delete must succeed (no-op) — exit 0, file unchanged.
  bash_delete "roles.lead"
  [ -z "$(bash_get roles.lead)" ]
}

@test "settings.sh delete: missing settings.json is a no-op (does not create file)" {
  [ ! -f "$SETTINGS_FILE" ]
  bash_delete "anything.at.all"
  [ ! -f "$SETTINGS_FILE" ]
}

# ============================================================
# Error semantics
# ============================================================

@test "settings.sh delete: rejects empty path with exit code != 0" {
  run bash "$SETTINGS_SH" delete ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a path"* ]]
}

@test "settings.sh delete: malformed JSON leaves file intact" {
  local malformed='not even close to JSON'
  printf '%s' "$malformed" > "$SETTINGS_FILE"

  run bash "$SETTINGS_SH" delete "roles.lead"
  [ "$status" -ne 0 ]

  # File untouched.
  local after
  after=$(cat "$SETTINGS_FILE")
  [ "$after" = "$malformed" ]
}

# ============================================================
# Preservation: delete on one path leaves unrelated keys verbatim.
# ============================================================

@test "settings.sh delete: preserves unrelated keys" {
  write_settings '{
    "version": 1,
    "tui_launch_framework": "claude-code",
    "capability_overrides": {"stop_hook": "full"},
    "roles": {"lead": "opus", "default": "sonnet"}
  }'

  bash_delete "roles.lead"

  [ "$(bash_get tui_launch_framework)" = '"claude-code"' ]
  [ "$(bash_get capability_overrides.stop_hook)" = '"full"' ]
  [ "$(bash_get roles.default)" = '"sonnet"' ]
  [ -z "$(bash_get roles.lead)" ]
}

# ============================================================
# Explicit JSON null: present-key with null value still gets removed.
# ============================================================

@test "settings.sh delete: explicit null value is removed" {
  write_settings '{"version":1,"roles":{"lead":null,"default":"sonnet"}}'

  # Sanity: pre-delete the key reads as 'null' (present, not absent).
  [ "$(bash_get roles.lead)" = "null" ]

  bash_delete "roles.lead"

  # Post-delete the key is absent (empty stdout, not 'null').
  [ -z "$(bash_get roles.lead)" ]
  # Sibling preserved.
  [ "$(bash_get roles.default)" = '"sonnet"' ]
}
