#!/usr/bin/env bats
# harness_args.bats — Go↔bash dual-implementation parity coverage
# (Phase 1, T12).
#
# For every helper named in adapters/README.md's dual-implementation
# table, this suite drives identical config inputs through both:
#   - the bash side: scripts/lib.sh::<helper>
#   - the Go side: tui/internal/config/cmd/parity-harness, which dispatches
#     to the matching exported config.<Helper> symbol.
# and asserts the outputs are byte-equal.
#
# Helpers tested today (live on both sides):
#   - resolve_active_framework
#   - resolve_harness_install_path
#   - resolve_agent_template
#
# Helpers gated behind T10 (`LoadHarnessArgs`, `MigrateClaudeArgsToHarnessArgs`,
# `FrameworkCapability`, `FrameworkModelRoutingShape`, `ResolveModelForRole`):
# the Go harness emits the literal "T10-pending" until T10 wires the Go
# implementations and the case branches in cmd/parity-harness/main.go are
# updated. The corresponding `@test` blocks here check for that sentinel
# and skip cleanly until T10 lands. Once T10 lands, the parity-harness
# main.go switch arm should call the real `config.<Helper>` and the
# `skip` lines below should be removed.
#
# The bash-only smoke tests at the bottom (LOAD_HARNESS_ARGS_BASH_*) cover
# the bash side directly so the legacy/migration/env paths are exercised
# even before Go parity is wired.
#
# Style: pure bats. No fallback bash driver — the suite skips cleanly
# when bats or the Go toolchain is missing.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LIB_SH="$REPO_DIR/scripts/lib.sh"

setup() {
  [ -f "$LIB_SH" ] || skip "scripts/lib.sh missing"
  [ -f "$REPO_DIR/adapters/capabilities.json" ] || skip "adapters/capabilities.json missing"
  [ -f "$REPO_DIR/adapters/roles.json" ] || skip "adapters/roles.json missing"

  # Stage an isolated LORE_DATA_DIR so tests never touch the user's config.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  # The Go side resolves adapters/ via a "scripts" symlink under
  # LORE_DATA_DIR (loreRepoDir() in framework.go); mirror that staging.
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  # Default framework.json — individual tests rewrite as needed.
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"claude-code","capability_overrides":{},"roles":{}}
EOF
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
  unset LORE_HARNESS_ARGS
  unset LORE_CLAUDE_ARGS

  # Build the Go parity harness once per test. `go build` on a small
  # main.go is fast and avoids the cost of a shared cache between bats
  # processes. If go is missing, parity tests skip; bash-only tests
  # still run.
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

bash_helper() {
  # Run a lib.sh helper and print its stdout. Stderr is dropped so the
  # one-shot deprecation notices from load_claude_args do not pollute
  # the equality comparison.
  bash -c "source '$LIB_SH' && $*" 2>/dev/null
}

go_helper() {
  # Run the Go parity harness and print its stdout. Skips the test if
  # the harness binary failed to build during setup.
  if [ -z "${HARNESS_BIN:-}" ]; then
    skip "Go parity harness not available (go missing or build failed)"
  fi
  "$HARNESS_BIN" "$@" 2>/dev/null
}

# ============================================================
# Live dual-impl helpers — assert bash ↔ Go byte-equality
# ============================================================

@test "parity: resolve_active_framework — claude-code default" {
  go_out=$(go_helper resolve_active_framework)
  bash_out=$(bash_helper "resolve_active_framework")
  [ "$go_out" = "claude-code" ]
  [ "$bash_out" = "claude-code" ]
}

@test "parity: resolve_active_framework — env override (LORE_FRAMEWORK=opencode)" {
  export LORE_FRAMEWORK=opencode
  go_out=$(go_helper resolve_active_framework)
  bash_out=$(bash_helper "resolve_active_framework")
  [ "$go_out" = "opencode" ]
  [ "$bash_out" = "opencode" ]
}

@test "parity: resolve_active_framework — file-side override (framework.json codex)" {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"codex","capability_overrides":{},"roles":{}}
EOF
  go_out=$(go_helper resolve_active_framework)
  bash_out=$(bash_helper "resolve_active_framework")
  [ "$go_out" = "codex" ]
  [ "$bash_out" = "codex" ]
}

@test "parity: resolve_active_framework — unknown framework rejected on both sides" {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"bogus-harness","capability_overrides":{},"roles":{}}
EOF
  go_status=0
  go_out=$(go_helper resolve_active_framework) || go_status=$?
  bash_status=0
  bash_out=$(bash_helper "resolve_active_framework") || bash_status=$?
  [ "$go_status" -ne 0 ]
  [ "$bash_status" -ne 0 ]
}

@test "parity: resolve_harness_install_path — skills on claude-code" {
  go_out=$(go_helper resolve_harness_install_path skills)
  bash_out=$(bash_helper "resolve_harness_install_path skills")
  [ "$go_out" = "$bash_out" ]
  [ -n "$go_out" ]
}

@test "parity: resolve_harness_install_path — agents on claude-code" {
  go_out=$(go_helper resolve_harness_install_path agents)
  bash_out=$(bash_helper "resolve_harness_install_path agents")
  [ "$go_out" = "$bash_out" ]
}

@test "parity: resolve_harness_install_path — unsupported sentinel matches" {
  # codex teams is the canonical 'unsupported' cell per capabilities.json.
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"codex","capability_overrides":{},"roles":{}}
EOF
  go_out=$(go_helper resolve_harness_install_path teams)
  bash_out=$(bash_helper "resolve_harness_install_path teams")
  [ "$go_out" = "$bash_out" ]
  [ "$go_out" = "unsupported" ]
}

@test "parity: resolve_harness_install_path — unknown kind rejected on both sides" {
  go_status=0
  go_out=$(go_helper resolve_harness_install_path bogus-kind) || go_status=$?
  bash_status=0
  bash_out=$(bash_helper "resolve_harness_install_path bogus-kind") || bash_status=$?
  [ "$go_status" -ne 0 ]
  [ "$bash_status" -ne 0 ]
}

# --- T71 harness_path_or_empty: convenience wrapper around resolve_harness_install_path ---
# The wrapper collapses (path | unsupported | error) into (path | empty); both
# sides must agree on every cell of that mapping. The four parity rows below
# cover supported (path), unsupported sentinel, lookup error (unknown kind),
# and missing config (no framework.json — falls through to default claude-code).

@test "parity: harness_path_or_empty — supported path on claude-code" {
  go_out=$(go_helper harness_path_or_empty agents)
  bash_out=$(bash_helper "harness_path_or_empty agents")
  [ "$go_out" = "$bash_out" ]
  [ -n "$go_out" ]
  [[ "$go_out" == */agents ]]
}

@test "parity: harness_path_or_empty — unsupported sentinel collapses to empty" {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"codex","capability_overrides":{},"roles":{}}
EOF
  go_out=$(go_helper harness_path_or_empty teams)
  bash_out=$(bash_helper "harness_path_or_empty teams")
  [ "$go_out" = "$bash_out" ]
  [ -z "$go_out" ]
}

@test "parity: harness_path_or_empty — unknown kind collapses to empty (exit 0)" {
  # Unlike resolve_harness_install_path, harness_path_or_empty never errors —
  # an unknown kind is just "no path here". Both sides must agree.
  go_status=0
  go_out=$(go_helper harness_path_or_empty bogus-kind) || go_status=$?
  bash_status=0
  bash_out=$(bash_helper "harness_path_or_empty bogus-kind") || bash_status=$?
  [ "$go_status" -eq 0 ]
  [ "$bash_status" -eq 0 ]
  [ "$go_out" = "$bash_out" ]
  [ -z "$go_out" ]
}

@test "parity: resolve_agent_template — worker.md" {
  go_out=$(go_helper resolve_agent_template worker)
  bash_out=$(bash_helper "resolve_agent_template worker")
  [ "$go_out" = "$bash_out" ]
  [ -f "$go_out" ]
}

@test "parity: resolve_agent_template — unknown name rejected on both sides" {
  go_status=0
  go_out=$(go_helper resolve_agent_template no-such-agent-template-12345) || go_status=$?
  bash_status=0
  bash_out=$(bash_helper "resolve_agent_template no-such-agent-template-12345") || bash_status=$?
  [ "$go_status" -ne 0 ]
  [ "$bash_status" -ne 0 ]
}

# ============================================================
# T10-gated dual-impl helpers — skip until T10 wires the Go side
# ============================================================

@test "parity: load_harness_args — claude-code default args" {
  go_out=$(go_helper load_harness_args claude-code)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side LoadHarnessArgs pending T10 (parity-harness emits T10-pending sentinel)"
  fi
  bash_out=$(bash_helper "load_harness_args claude-code")
  [ "$go_out" = "$bash_out" ]
  # Default for claude-code with no config = single arg.
  [ "$go_out" = "--dangerously-skip-permissions" ]
}

@test "parity: load_harness_args — opencode empty default" {
  go_out=$(go_helper load_harness_args opencode)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side LoadHarnessArgs pending T10"
  fi
  bash_out=$(bash_helper "load_harness_args opencode")
  # Both sides MUST return empty for non-Claude harnesses (no
  # --dangerously-skip-permissions leak per T9 design).
  [ -z "$go_out" ]
  [ -z "$bash_out" ]
}

@test "parity: load_harness_args — harness-args.json claude-code slot" {
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<EOF
{"version":1,"claude-code":{"args":["--foo","--bar"]},"opencode":{"args":["--qux"]}}
EOF
  go_out=$(go_helper load_harness_args claude-code)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side LoadHarnessArgs pending T10"
  fi
  bash_out=$(bash_helper "load_harness_args claude-code")
  [ "$go_out" = "$bash_out" ]
  printf '%s\n' "$go_out" | grep -q -- "--foo"
  printf '%s\n' "$go_out" | grep -q -- "--bar"
}

@test "parity: load_harness_args — harness-args.json opencode slot reads opencode args (not claude-code's)" {
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<EOF
{"version":1,"claude-code":{"args":["--CC"]},"opencode":{"args":["--OC"]}}
EOF
  go_out=$(go_helper load_harness_args opencode)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side LoadHarnessArgs pending T10"
  fi
  bash_out=$(bash_helper "load_harness_args opencode")
  [ "$go_out" = "$bash_out" ]
  printf '%s\n' "$go_out" | grep -q -- "--OC"
  ! printf '%s\n' "$go_out" | grep -q -- "--CC"
}

@test "parity: load_harness_args — LORE_HARNESS_ARGS env wins" {
  export LORE_HARNESS_ARGS='["--from-env","--also"]'
  go_out=$(go_helper load_harness_args claude-code)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side LoadHarnessArgs pending T10"
  fi
  bash_out=$(bash_helper "load_harness_args claude-code")
  [ "$go_out" = "$bash_out" ]
  printf '%s\n' "$go_out" | grep -q -- "--from-env"
}

@test "parity: migrate_claude_args_to_harness_args — produces semantically identical harness-args.json" {
  # Stage a legacy claude.json only.
  cat > "$TEST_LORE_DATA_DIR/config/claude.json" <<EOF
{"args":["--legacy-flag"]}
EOF

  # Bash side runs first and writes its harness-args.json.
  bash_helper "migrate_claude_args_to_harness_args"
  if [ ! -f "$TEST_LORE_DATA_DIR/config/harness-args.json" ]; then
    skip "Bash migration helper produced no file (no-op gate fired)"
  fi
  bash_canon=$(python3 -c "import json,sys; print(json.dumps(json.load(open('$TEST_LORE_DATA_DIR/config/harness-args.json')),sort_keys=True))")

  # Reset and run the Go side.
  rm -f "$TEST_LORE_DATA_DIR/config/harness-args.json"
  go_out=$(go_helper migrate_claude_args_to_harness_args 2>&1)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side MigrateClaudeArgsToHarnessArgs pending T10"
  fi
  go_canon=$(python3 -c "import json,sys; print(json.dumps(json.load(open('$TEST_LORE_DATA_DIR/config/harness-args.json')),sort_keys=True))")

  # Semantic equality: both sides must produce JSON that parses to the
  # same object after sort_keys canonicalization. Byte equality is NOT
  # asserted because jq (bash) preserves filter order while Go's
  # json.MarshalIndent sorts keys alphabetically — a noisy difference
  # without semantic consequence. T10 follow-up: align Go-side
  # serialization with jq's key order to support a strict byte-equal
  # invariant if future migrations need it (see adapters/README.md note).
  [ "$bash_canon" = "$go_canon" ]
}

@test "parity: framework_capability — Go-side TODO" {
  # framework_capability was added on the bash side in T6 but is NOT in
  # T10's stated scope. The parity-harness emits the literal "T10-pending"
  # sentinel until a follow-up wires config.FrameworkCapability. Skip
  # cleanly here so the suite passes; remove the skip when the Go side
  # exposes the helper.
  go_out=$(go_helper framework_capability skills)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side FrameworkCapability not yet exported (T10 follow-up)"
  fi
  bash_out=$(bash_helper "framework_capability skills")
  [ "$go_out" = "$bash_out" ]
}

@test "parity: framework_model_routing_shape — Go-side TODO" {
  # Same gating as framework_capability: bash-only until the Go side
  # exports config.FrameworkModelRoutingShape. parity-harness emits
  # "T10-pending" until then.
  go_out=$(go_helper framework_model_routing_shape)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side FrameworkModelRoutingShape not yet exported (T10 follow-up)"
  fi
  bash_out=$(bash_helper "framework_model_routing_shape")
  [ "$go_out" = "$bash_out" ]
}

@test "parity: resolve_model_for_role — env-aware role binding" {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"claude-code","capability_overrides":{},"roles":{"lead":"opus","default":"sonnet"}}
EOF
  go_out=$(go_helper resolve_model_for_role lead)
  if [ "$go_out" = "T10-pending" ]; then
    skip "Go-side ResolveModelForRole not yet exported"
  fi
  bash_out=$(bash_helper "resolve_model_for_role lead")
  [ "$go_out" = "$bash_out" ]
  [ "$go_out" = "opus" ]
}

# ============================================================
# Bash-only smoke tests (don't depend on Go)
# Cover the bash side's load_harness_args resolution ladder so the
# legacy/migration/env paths are exercised even when go is missing.
# ============================================================

@test "bash: load_harness_args — claude-code default with no config" {
  out=$(bash_helper "load_harness_args claude-code")
  [ "$out" = "--dangerously-skip-permissions" ]
}

@test "bash: load_harness_args — opencode default with no config is empty" {
  out=$(bash_helper "load_harness_args opencode")
  [ -z "$out" ]
}

@test "bash: load_harness_args — codex default with no config is empty" {
  out=$(bash_helper "load_harness_args codex")
  [ -z "$out" ]
}

@test "bash: load_harness_args — reads claude-code slot from harness-args.json" {
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<EOF
{"version":1,"claude-code":{"args":["--alpha","--beta"]}}
EOF
  out=$(bash_helper "load_harness_args claude-code" | tr '\n' ' ')
  [ "$out" = "--alpha --beta " ]
}

@test "bash: load_harness_args — LORE_HARNESS_ARGS env wins over file" {
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<EOF
{"version":1,"claude-code":{"args":["--from-file"]}}
EOF
  export LORE_HARNESS_ARGS='["--from-env"]'
  out=$(bash_helper "load_harness_args claude-code")
  [ "$out" = "--from-env" ]
}

@test "bash: load_harness_args — LORE_CLAUDE_ARGS legacy env honored only for claude-code" {
  export LORE_CLAUDE_ARGS='["--legacy"]'
  cc_out=$(bash_helper "load_harness_args claude-code")
  [ "$cc_out" = "--legacy" ]
  oc_out=$(bash_helper "load_harness_args opencode")
  [ -z "$oc_out" ]  # opencode does NOT honor LORE_CLAUDE_ARGS
}

@test "bash: migrate_claude_args_to_harness_args — first read populates harness-args.json" {
  cat > "$TEST_LORE_DATA_DIR/config/claude.json" <<EOF
{"args":["--legacy-1","--legacy-2"]}
EOF
  out=$(bash_helper "load_harness_args claude-code" | tr '\n' ' ')
  [ "$out" = "--legacy-1 --legacy-2 " ]
  [ -f "$TEST_LORE_DATA_DIR/config/harness-args.json" ]
  # Migration must record the legacy source path for deprecation surfacing.
  grep -q "_deprecated_legacy_source" "$TEST_LORE_DATA_DIR/config/harness-args.json"
}

@test "bash: migrate_claude_args_to_harness_args — idempotent (second run is a no-op)" {
  cat > "$TEST_LORE_DATA_DIR/config/claude.json" <<EOF
{"args":["--once"]}
EOF
  bash_helper "load_harness_args claude-code" >/dev/null
  sha1=$(shasum -a 256 "$TEST_LORE_DATA_DIR/config/harness-args.json" | cut -d' ' -f1)
  bash_helper "load_harness_args claude-code" >/dev/null
  sha2=$(shasum -a 256 "$TEST_LORE_DATA_DIR/config/harness-args.json" | cut -d' ' -f1)
  [ "$sha1" = "$sha2" ]
}

@test "bash: load_claude_args (deprecated alias) emits one-shot stderr deprecation and delegates to claude-code slot" {
  cat > "$TEST_LORE_DATA_DIR/config/harness-args.json" <<EOF
{"version":1,"claude-code":{"args":["--deprecated-path"]},"opencode":{"args":["--should-not-leak"]}}
EOF
  combined=$(bash -c "source '$LIB_SH' && load_claude_args" 2>&1)
  printf '%s\n' "$combined" | grep -q "deprecated"
  printf '%s\n' "$combined" | grep -q -- "--deprecated-path"
  ! printf '%s\n' "$combined" | grep -q -- "--should-not-leak"
}

@test "bash: load_claude_args (deprecated alias) warns at most once per shell" {
  output=$(bash -c "source '$LIB_SH' && load_claude_args; load_claude_args" 2>&1)
  warn_count=$(printf '%s\n' "$output" | grep -c "deprecated" || true)
  [ "$warn_count" = "1" ]
}
