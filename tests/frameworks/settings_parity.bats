#!/usr/bin/env bats
# settings_parity.bats — bash ↔ Go round-trip parity for the unified
# settings loader (Phase 1, T4 of consolidate-user-config-unified-settings-file).
#
# T1 ships the schema; T2 ships scripts/settings.sh + lib.sh integration;
# T3 ships scripts/lore_settings.py (Python parity covered there);
# T4 (this suite) asserts the Go-side mirror at tui/internal/config/settings.go
# produces byte-equivalent output to scripts/settings.sh against the same
# on-disk state, and that harness-local role/ceremony settings are wired
# identically across both stacks.
#
# Parity surface (D5 table — the four bash↔Go rows lifted from plan.md):
#   1. active_framework         — top-level scalar
#   2. harnesses.<n>.args       — per-harness array
#   3. harnesses.<n>.roles.<id> — per-harness role scalar
#   4. capability_overrides.<k> — top-level scalar (read-only on the Go side; bash
#                                  framework_capability composes against this)
#
# Harness-local role coverage:
#   - With harnesses.<active>.roles.lead set, resolve_model_for_role("lead")
#     returns that binding.
#   - With harnesses.<active>.roles.default set and the requested role absent,
#     resolve_model_for_role falls through to that harness-local default.
#
# Closed-set rejection at BOTH layers:
#   - Query:     unknown role id → reject.
#   - Overlay:   harnesses.<n>.roles."unknown_role" → reject when overlay block
#     names an unknown role id.
#
# Write contract (D5a):
#   - Go SettingsPatch and bash settings.sh patch land in the same file via the
#     same .settings.lock; either stack can write and the other can read.
#
# Style: pure bats. The setup() pattern stages an isolated LORE_DATA_DIR with
# a scripts/ symlink so the Go side's loreRepoDir() resolves correctly. Skips
# cleanly when go is missing (Go-side parity rows skip; bash-side smoke still
# runs).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LIB_SH="$REPO_DIR/scripts/lib.sh"
SETTINGS_SH="$REPO_DIR/scripts/settings.sh"

setup() {
  [ -f "$LIB_SH" ] || skip "scripts/lib.sh missing"
  [ -f "$SETTINGS_SH" ] || skip "scripts/settings.sh missing"
  [ -f "$REPO_DIR/adapters/capabilities.json" ] || skip "adapters/capabilities.json missing"
  [ -f "$REPO_DIR/adapters/roles.json" ] || skip "adapters/roles.json missing"
  command -v jq >/dev/null 2>&1 || skip "jq required for settings.sh"

  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
  unset LORE_HARNESS_ARGS
  unset LORE_CLAUDE_ARGS
  unset LORE_MODEL_LEAD
  unset LORE_MODEL_WORKER
  unset LORE_MODEL_DEFAULT
  unset LORE_TUI_LAYOUT

  if command -v go >/dev/null 2>&1; then
    HARNESS_BIN="$TEST_LORE_DATA_DIR/parity-harness"
    if (cd "$REPO_DIR/tui" && go build -o "$HARNESS_BIN" ./internal/config/cmd/parity-harness) >/dev/null 2>&1; then
      export HARNESS_BIN
    else
      unset HARNESS_BIN
    fi
  fi
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

# --- Helpers ---

write_settings() {
  local body="$1"
  printf '%s' "$body" > "$TEST_LORE_DATA_DIR/config/settings.json"
}

bash_get() {
  bash "$SETTINGS_SH" get "$1" 2>/dev/null
}

go_helper() {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available (go missing or build failed)"
  fi
  "$HARNESS_BIN" "$@" 2>/dev/null
}

# ============================================================
# D5 row 1: active_framework
# ============================================================

@test "parity: settings get active_framework — value present" {
  write_settings '{"version":1,"active_framework":"opencode"}'
  bash_out=$(bash_get active_framework)
  go_out=$(go_helper settings_get active_framework)
  [ "$bash_out" = '"opencode"' ]
  [ "$go_out" = '"opencode"' ]
}

@test "parity: settings get active_framework — absent key" {
  write_settings '{"version":1}'
  bash_out=$(bash_get active_framework)
  go_out=$(go_helper settings_get active_framework)
  # Both sides emit empty stdout on absence.
  [ -z "$bash_out" ]
  [ -z "$go_out" ]
}

@test "parity: settings get active_framework — explicit null" {
  write_settings '{"version":1,"active_framework":null}'
  bash_out=$(bash_get active_framework)
  go_out=$(go_helper settings_get active_framework)
  # Both sides emit literal "null" (distinguishes from absence).
  [ "$bash_out" = "null" ]
  [ "$go_out" = "null" ]
}

# ============================================================
# D5 row 2: harnesses.<n>.args (dot-path with dashes)
# ============================================================

@test "parity: settings get harnesses.claude-code.args — round-trips through dashed path" {
  write_settings '{
    "version": 1,
    "harnesses": {
      "claude-code": {"args": ["--dangerously-skip-permissions"]},
      "opencode": {"args": []},
      "codex": {"args": ["--ask-for-approval", "never"]}
    }
  }'
  bash_out=$(bash_get harnesses.claude-code.args)
  go_out=$(go_helper settings_get harnesses.claude-code.args)
  [ "$bash_out" = '["--dangerously-skip-permissions"]' ]
  [ "$go_out" = '["--dangerously-skip-permissions"]' ]
}

@test "parity: settings get harnesses.codex.args — multi-element array" {
  write_settings '{
    "version": 1,
    "harnesses": {
      "codex": {"args": ["--ask-for-approval", "never"]}
    }
  }'
  bash_out=$(bash_get harnesses.codex.args)
  go_out=$(go_helper settings_get harnesses.codex.args)
  [ "$bash_out" = '["--ask-for-approval","never"]' ]
  [ "$go_out" = '["--ask-for-approval","never"]' ]
}

# ============================================================
# D5 row 3: harnesses.<n>.roles.<id>
# ============================================================

@test "parity: settings get harnesses.claude-code.roles.lead — harness-local scalar" {
  write_settings '{"version":1,"harnesses":{"claude-code":{"args":[],"roles":{"lead":"opus","default":"sonnet"}}}}'
  bash_out=$(bash_get harnesses.claude-code.roles.lead)
  go_out=$(go_helper settings_get harnesses.claude-code.roles.lead)
  [ "$bash_out" = '"opus"' ]
  [ "$go_out" = '"opus"' ]
}

# ============================================================
# D5 row 4: capability_overrides.<key>
# ============================================================

@test "parity: settings get capability_overrides.stop_hook" {
  write_settings '{"version":1,"capability_overrides":{"stop_hook":"full"}}'
  bash_out=$(bash_get capability_overrides.stop_hook)
  go_out=$(go_helper settings_get capability_overrides.stop_hook)
  [ "$bash_out" = '"full"' ]
  [ "$go_out" = '"full"' ]
}

# ============================================================
# section parity
# ============================================================

@test "parity: settings section tui — present" {
  write_settings '{"version":1,"tui":{"layout":"top-bottom"}}'
  bash_out=$(bash "$SETTINGS_SH" section tui 2>/dev/null)
  go_out=$(go_helper settings_section tui)
  # Both sides emit a JSON object literal. Compare via jq normalization so
  # whitespace differences between formatters do not falsely diff.
  bash_norm=$(printf '%s' "$bash_out" | jq -cS .)
  go_norm=$(printf '%s' "$go_out" | jq -cS .)
  [ "$bash_norm" = "$go_norm" ]
}

@test "parity: settings section absent — both return {}" {
  write_settings '{"version":1}'
  bash_out=$(bash "$SETTINGS_SH" section nonexistent 2>/dev/null)
  go_out=$(go_helper settings_section nonexistent)
  bash_norm=$(printf '%s' "$bash_out" | jq -cS .)
  go_norm=$(printf '%s' "$go_out" | jq -cS .)
  [ "$bash_norm" = "{}" ]
  [ "$go_norm" = "{}" ]
}

# ============================================================
# Patch contract: shared lock file, atomic round-trip
# ============================================================

@test "parity: Go SettingsPatch is observable to bash settings.sh get" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  # Go writes; bash reads.
  "$HARNESS_BIN" settings_patch active_framework '"opencode"'
  bash_out=$(bash_get active_framework)
  [ "$bash_out" = '"opencode"' ]
}

@test "parity: bash settings.sh patch is observable to Go SettingsGet" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  # Bash writes; Go reads.
  bash "$SETTINGS_SH" patch active_framework '"codex"' >/dev/null
  go_out=$(go_helper settings_get active_framework)
  [ "$go_out" = '"codex"' ]
}

@test "parity: same lock file path on both stacks" {
  # Both stacks lock against $LORE_DATA_DIR/config/.settings.lock — verified
  # indirectly by writing through both, then asserting the file exists.
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  "$HARNESS_BIN" settings_patch tui.layout '"top-bottom"'
  bash "$SETTINGS_SH" patch active_framework '"claude-code"' >/dev/null
  [ -f "$TEST_LORE_DATA_DIR/config/.settings.lock" ]
  # And both writes landed.
  bash_active=$(bash_get active_framework)
  bash_layout=$(bash_get tui.layout)
  [ "$bash_active" = '"claude-code"' ]
  [ "$bash_layout" = '"top-bottom"' ]
}

@test "parity: patch preserves unrelated keys on both stacks" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{"version":1,"active_framework":"claude-code","harnesses":{"claude-code":{"args":[],"roles":{"lead":"opus","default":"sonnet"}}},"capability_overrides":{"stop_hook":"full"}}'
  # Go-side patch.
  "$HARNESS_BIN" settings_patch harnesses.claude-code.roles.lead '"haiku"'
  # Unrelated keys must survive.
  default_after=$(bash_get harnesses.claude-code.roles.default)
  cap_after=$(bash_get capability_overrides.stop_hook)
  active_after=$(bash_get active_framework)
  [ "$default_after" = '"sonnet"' ]
  [ "$cap_after" = '"full"' ]
  [ "$active_after" = '"claude-code"' ]
}

# ============================================================
# resolve_active_framework parity (unified-file-driven)
# ============================================================

@test "parity: resolve_active_framework reads unified settings.json on both stacks" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{"version":1,"active_framework":"opencode","harnesses":{"opencode":{"args":[]}}}'
  bash_out=$(bash -c "source '$LIB_SH' && resolve_active_framework" 2>/dev/null)
  go_out=$("$HARNESS_BIN" resolve_active_framework 2>/dev/null)
  [ "$bash_out" = "opencode" ]
  [ "$go_out" = "opencode" ]
}

@test "parity: resolve_active_framework rejects unknown framework on both stacks" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{"version":1,"active_framework":"phantom-harness"}'
  run bash -c "source '$LIB_SH' && resolve_active_framework"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown framework"* ]] || [[ "$output" == *"phantom-harness"* ]]
  run "$HARNESS_BIN" resolve_active_framework
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown framework"* ]]
}

# ============================================================
# Harness-local resolve_model_for_role
# ============================================================

@test "parity: harness-local role binding wins for active harness" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{
    "version": 1,
    "active_framework": "claude-code",
    "harnesses": {
      "claude-code": {"args": [], "roles": {"lead": "opus", "default": "sonnet"}},
      "opencode": {"args": [], "roles": {"lead": "anthropic/opus", "default": "anthropic/opus"}}
    }
  }'
  bash_out=$(bash -c "source '$LIB_SH' && resolve_model_for_role lead" 2>/dev/null)
  go_out=$("$HARNESS_BIN" resolve_model_for_role lead 2>/dev/null)
  [ "$bash_out" = "opus" ]
  [ "$go_out" = "opus" ]
}

@test "parity: harness-local role default handles absent role binding" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{
    "version": 1,
    "active_framework": "opencode",
    "harnesses": {
      "claude-code": {"args": [], "roles": {"lead": "opus", "default": "sonnet"}},
      "opencode": {"args": [], "roles": {"default": "anthropic/opus"}}
    }
  }'
  bash_out=$(bash -c "source '$LIB_SH' && resolve_model_for_role lead" 2>/dev/null)
  go_out=$("$HARNESS_BIN" resolve_model_for_role lead 2>/dev/null)
  [ "$bash_out" = "anthropic/opus" ]
  [ "$go_out" = "anthropic/opus" ]
}

@test "parity: closed-set rejection — unknown role query rejected on both stacks" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{
    "version": 1,
    "active_framework": "claude-code",
    "harnesses": {"claude-code": {"args": [], "roles": {"default": "sonnet"}}}
  }'
  run bash -c "source '$LIB_SH' && resolve_model_for_role unknown_role_xyz"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
  run "$HARNESS_BIN" resolve_model_for_role unknown_role_xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
}

@test "parity: closed-set rejection — unknown role in harness-local map rejected on both stacks" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  # An unknown role id stored in harnesses.<active>.roles must error on the
  # *query* of any role (the closed-set rejection fires at overlay-validation
  # time, before any specific role lookup). Bash D3b parity at
  # scripts/lib.sh:964-985.
  write_settings '{
    "version": 1,
    "active_framework": "claude-code",
    "harnesses": {
      "claude-code": {"args": [], "roles": {"unknown_role_xyz": "opus"}}
    }
  }'
  # Querying "lead" should still error because the overlay block contains
  # an unknown role id (misconfigured overlay must surface, not be silently
  # ignored).
  run bash -c "source '$LIB_SH' && resolve_model_for_role lead"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
  run "$HARNESS_BIN" resolve_model_for_role lead
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown role"* ]]
}

# ============================================================
# load_harness_args parity (read through unified file)
# ============================================================

@test "parity: load_harness_args reads harnesses.<n>.args from unified file" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  write_settings '{
    "version": 1,
    "active_framework": "claude-code",
    "harnesses": {
      "claude-code": {"args": ["--from-unified", "--second"]},
      "opencode": {"args": ["--opencode-only"]}
    }
  }'
  bash_out=$(bash -c "source '$LIB_SH' && load_harness_args claude-code" 2>/dev/null)
  go_out=$("$HARNESS_BIN" load_harness_args claude-code 2>/dev/null)
  [ "$bash_out" = "$(printf '%s\n%s' --from-unified --second)" ]
  [ "$go_out"   = "$(printf '%s\n%s' --from-unified --second)" ]
}

@test "parity: load_harness_args ignores legacy harness-args.json when unified absent" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  # No settings.json. Stage legacy harness-args.json.
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<'EOF'
{
  "version": 1,
  "claude-code": {"args": ["--from-legacy"]}
}
EOF
  bash_out=$(bash -c "source '$LIB_SH' && load_harness_args claude-code" 2>/dev/null)
  go_out=$("$HARNESS_BIN" load_harness_args claude-code 2>/dev/null)
  [ "$bash_out" = "--dangerously-skip-permissions" ]
  [ "$go_out"   = "--dangerously-skip-permissions" ]
}

# ============================================================
# Ceremony advisor resolution (harness-local only)
# ============================================================

@test "ceremony: resolve_ceremony_advisors reads active harness only" {
  write_settings '{
    "version": 1,
    "active_framework": "codex",
    "harnesses": {
      "claude-code": {"args": [], "ceremonies": {"spec-design": ["pr-review"]}},
      "codex": {"args": [], "ceremonies": {"spec-design": ["pr-self-review"]}}
    },
    "ceremonies": {"spec-design": ["pr-create"]}
  }'
  out=$(bash -c "source '$LIB_SH' && resolve_ceremony_advisors spec-design" 2>/dev/null)
  [ "$out" = '["pr-self-review"]' ]
}

@test "ceremony: top-level and ceremonies.json are ignored" {
  cat > "$TEST_LORE_DATA_DIR/ceremonies.json" <<'EOF'
{"spec-design":["pr-review"]}
EOF
  write_settings '{
    "version": 1,
    "active_framework": "codex",
    "harnesses": {
      "codex": {"args": []}
    },
    "ceremonies": {"spec-design": ["pr-create"]}
  }'
  out=$(bash -c "source '$LIB_SH' && resolve_ceremony_advisors spec-design" 2>/dev/null)
  [ "$out" = '[]' ]
}

# ============================================================
# settings.sh path subcommand and Go SettingsPath agreement
# ============================================================

@test "parity: settings_path agrees on file location" {
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available"
  fi
  bash_path=$(bash "$SETTINGS_SH" path)
  go_path=$("$HARNESS_BIN" settings_path)
  [ "$bash_path" = "$go_path" ]
  [ "$bash_path" = "$TEST_LORE_DATA_DIR/config/settings.json" ]
}
