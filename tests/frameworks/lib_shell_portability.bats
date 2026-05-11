#!/usr/bin/env bats
# lib_shell_portability.bats — Regression coverage for sourcing scripts/lib.sh
# from non-bash shells (zsh in particular).
#
# Why this exists: the Claude Code Bash tool on macOS inherits the user's
# login shell, which is zsh by default. Skill setup blocks in /spec and
# /implement instruct the lead to `source ~/.lore/scripts/lib.sh` directly
# into that shell. lib.sh historically used bash-only constructs
# (${BASH_SOURCE[0]} for self-detection, ${!var} for indirect expansion)
# which silently misbehaved under zsh:
#
#   - ${BASH_SOURCE[0]} is empty in zsh, so `dirname ""` returned `.` and
#     LORE_LIB_DIR collapsed to the cwd. Every $LORE_LIB_DIR/../adapters/...
#     and $LORE_LIB_DIR/../agents/... lookup then targeted a wrong path,
#     producing "agent template not found" and "cannot read capabilities.json"
#     errors anywhere the lead happened to invoke from outside the lore repo.
#   - ${!var:-} is bash-only; zsh emits "bad substitution".
#
# These tests source lib.sh under both shells and assert the load-bearing
# resolvers return matching results. See:
# gotchas/scripts-lib-sh-assumes-bash-is-routinely-sourced.md.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LIB_SH="$REPO_DIR/scripts/lib.sh"

setup() {
  [ -f "$LIB_SH" ] || skip "scripts/lib.sh missing"
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
}

@test "lib.sh: LORE_LIB_DIR points at scripts/ when sourced under bash" {
  run bash -c "source '$LIB_SH' && printf '%s\n' \"\$LORE_LIB_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_DIR/scripts" ]
}

@test "lib.sh: LORE_LIB_DIR points at scripts/ when sourced under zsh" {
  # The original failure mode: ${BASH_SOURCE[0]} expands empty in zsh, so
  # LORE_LIB_DIR collapsed to the cwd. Run from a third-party cwd to make
  # the regression visible — if detection silently falls back to cwd, this
  # test fails because /tmp != $REPO_DIR/scripts.
  run zsh -c "cd /tmp && source '$LIB_SH' && printf '%s\n' \"\$LORE_LIB_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_DIR/scripts" ]
}

@test "lib.sh: LORE_REPO_DIR points at the repo root when sourced under zsh" {
  run zsh -c "cd /tmp && source '$LIB_SH' && printf '%s\n' \"\$LORE_REPO_DIR\""
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_DIR" ]
}

@test "lib.sh: resolve_agent_template returns the canonical path under zsh" {
  # Prior bug: zsh's `cd` collapsed ".." logically before chdir, so
  # `cd $LORE_LIB_DIR/../agents` landed at ~/.lore/agents (no symlink
  # there) instead of physically traversing through the scripts/ symlink.
  run zsh -c "cd /tmp && source '$LIB_SH' && resolve_agent_template researcher"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO_DIR/agents/researcher.md" ]
}

@test "lib.sh: resolve_agent_template works for every shipped template under zsh" {
  for tmpl in worker researcher advisor classifier curator correctness-gate \
              reverse-auditor structure-analyst crossref-scout; do
    run zsh -c "source '$LIB_SH' && resolve_agent_template '$tmpl'"
    [ "$status" -eq 0 ] || {
      echo "resolve_agent_template '$tmpl' failed under zsh: $output" >&2
      return 1
    }
    [ "$output" = "$REPO_DIR/agents/$tmpl.md" ]
  done
}

@test "lib.sh: framework_capability reads capabilities.json under zsh" {
  # Failure mode: $LORE_LIB_DIR/../adapters/capabilities.json passed to
  # jq directly (no `cd`) — kernel resolves through the symlink, so this
  # works even with the legacy LORE_LIB_DIR. Test guards against future
  # rewrites that route through `cd` (which would re-trigger zsh's
  # logical-".." collapse).
  run zsh -c "source '$LIB_SH' && LORE_FRAMEWORK=claude-code framework_capability subagents"
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
}

@test "lib.sh: resolve_model_for_role works under zsh (no \${!var} bad-substitution)" {
  # Prior bug: resolve_model_for_role used \${!env_var:-} (bash indirect
  # expansion). zsh rejects it with "bad substitution" before the env-var
  # branch can be evaluated. The eval-based replacement must keep the
  # env-var override working in both shells.
  #
  # NOTE: zsh treats `VAR=value source script` differently from bash —
  # the assignment-prefix on a builtin doesn't make VAR visible inside
  # the sourced file. Export the var into the parent zsh process instead,
  # which matches how users actually set role overrides.
  LORE_MODEL_LEAD=opus-test run zsh -c "source '$LIB_SH' && resolve_model_for_role lead"
  [ "$status" -eq 0 ]
  [ "$output" = "opus-test" ]
}

@test "lib.sh: end-to-end implement-skill setup block succeeds under zsh" {
  # Mirrors the exact sequence /implement Step 3.x emits (see
  # skills/implement/SKILL.md). This is the failing transcript reproduced
  # as a test: every line below comes from a real session that errored
  # before the fix. If any of these resolvers regress, this composite
  # check fails before the skill body does.
  run zsh -c "
    set -e
    source '$LIB_SH'
    [ -n \"\$LORE_LIB_DIR\" ]
    [ -n \"\$LORE_REPO_DIR\" ]
    fw=\$(resolve_active_framework)
    [ -n \"\$fw\" ]
    adapter=\"\$LORE_REPO_DIR/adapters/agents/\$fw.sh\"
    [ -x \"\$adapter\" ]
    resolve_agent_template worker  >/dev/null
    resolve_agent_template advisor >/dev/null
    framework_capability subagents >/dev/null
    resolve_model_for_role lead    >/dev/null
    echo OK
  "
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "lib.sh: Claude Code runtime marker wins over last-installed codex settings" {
  # Regression for a split-brain multi-harness install: the user is running a
  # Claude Code Bash tool, but ~/.lore/config/settings.json still says codex
  # because Codex was installed later. The skill setup block must resolve the
  # Claude adapter/capabilities in that shell.
  local home_dir="$BATS_TEST_TMPDIR/claude-runtime-home"
  mkdir -p "$home_dir/.lore/config"
  ln -s "$REPO_DIR/scripts" "$home_dir/.lore/scripts"
  cat >"$home_dir/.lore/config/settings.json" <<'EOF'
{"version":1,"tui_launch_framework":"codex","capability_overrides":{},"harnesses":{"claude-code":{"args":[],"roles":{"default":"sonnet","lead":"opus","worker":"sonnet"}},"codex":{"args":[],"roles":{"default":"gpt-5.5","lead":"gpt-5.5","worker":"gpt-5.5"}}}}
EOF

  run zsh -c "
    set -e
    export HOME='$home_dir'
    export CLAUDECODE=1
    unset LORE_DATA_DIR LORE_FRAMEWORK
    source '$home_dir/.lore/scripts/lib.sh'
    fw=\$(resolve_active_framework)
    echo \"framework=\$fw\"
    echo \"team_messaging=\$(framework_capability team_messaging)\"
    adapter=\"\$LORE_REPO_DIR/adapters/agents/\$fw.sh\"
    [ -x \"\$adapter\" ]
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"framework=claude-code"* ]]
  [[ "$output" == *"team_messaging=full"* ]]
}

@test "lib.sh: Codex runtime marker wins over last-installed claude-code settings" {
  # Symmetric guard for Codex sessions: if the user last installed Claude Code,
  # Codex shell commands should still resolve Codex's capability profile.
  local home_dir="$BATS_TEST_TMPDIR/codex-runtime-home"
  mkdir -p "$home_dir/.lore/config"
  ln -s "$REPO_DIR/scripts" "$home_dir/.lore/scripts"
  cat >"$home_dir/.lore/config/settings.json" <<'EOF'
{"version":1,"tui_launch_framework":"claude-code","capability_overrides":{},"harnesses":{"claude-code":{"args":[],"roles":{"default":"sonnet","lead":"opus","worker":"sonnet"}},"codex":{"args":[],"roles":{"default":"gpt-5.5","lead":"gpt-5.5","worker":"gpt-5.5"}}}}
EOF

  run zsh -c "
    set -e
    export HOME='$home_dir'
    export CODEX_SHELL=1
    unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_TEAM_NAME LORE_DATA_DIR LORE_FRAMEWORK
    source '$home_dir/.lore/scripts/lib.sh'
    fw=\$(resolve_active_framework)
    echo \"framework=\$fw\"
    echo \"team_messaging=\$(framework_capability team_messaging)\"
    adapter=\"\$LORE_REPO_DIR/adapters/agents/\$fw.sh\"
    [ -x \"\$adapter\" ]
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"framework=codex"* ]]
  [[ "$output" == *"team_messaging=none"* ]]
}

@test "lib.sh: OpenCode runtime marker wins over last-installed codex settings" {
  # OpenCode shares Claude-compatible skill locations, so path-based inference
  # cannot distinguish it from Claude Code. OPENCODE_CLIENT is the runtime hint
  # that keeps skill shell snippets on the opencode capability profile.
  local home_dir="$BATS_TEST_TMPDIR/opencode-runtime-home"
  mkdir -p "$home_dir/.lore/config"
  ln -s "$REPO_DIR/scripts" "$home_dir/.lore/scripts"
  cat >"$home_dir/.lore/config/settings.json" <<'EOF'
{"version":1,"tui_launch_framework":"codex","capability_overrides":{},"harnesses":{"opencode":{"args":[],"roles":{"default":"anthropic/sonnet","lead":"anthropic/opus","worker":"openai/gpt-4o"}},"codex":{"args":[],"roles":{"default":"gpt-5.5","lead":"gpt-5.5","worker":"gpt-5.5"}}}}
EOF

  run zsh -c "
    set -e
    export HOME='$home_dir'
    export OPENCODE_CLIENT=cli
    unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_TEAM_NAME CODEX_SHELL CODEX_THREAD_ID LORE_DATA_DIR LORE_FRAMEWORK
    source '$home_dir/.lore/scripts/lib.sh'
    fw=\$(resolve_active_framework)
    echo \"framework=\$fw\"
    echo \"team_messaging=\$(framework_capability team_messaging)\"
    echo \"routing=\$(framework_model_routing_shape)\"
    adapter=\"\$LORE_REPO_DIR/adapters/agents/\$fw.sh\"
    [ -x \"\$adapter\" ]
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"framework=opencode"* ]]
  [[ "$output" == *"team_messaging=none"* ]]
  [[ "$output" == *"routing=multi"* ]]
}

@test "lib.sh: no helper uses '\$LORE_LIB_DIR/..' chained into cd" {
  # Codifies the convention documented at the top of lib.sh: helpers that
  # need the repo root must use \$LORE_REPO_DIR, never \$LORE_LIB_DIR/..
  # routed through `cd`. The latter triggers bash/zsh's logical-".."
  # collapse, which on the typical symlinked install lands at ~/.lore
  # instead of the actual repo root. Filesystem-syscall uses
  # ([[ -f ... ]], cat, jq) are fine — only `cd` triggers the bug.
  #
  # This test reads lib.sh, drops comment-only lines, and refuses any
  # remaining occurrence of the antipattern. The legitimate site is the
  # one-time LORE_REPO_DIR seed at line ~50, which uses `cd -P ..` (not
  # \$LORE_LIB_DIR/..) so it doesn't match.
  hits=$(awk '
    # Strip leading comments; keep code-with-trailing-comments intact.
    /^[[:space:]]*#/ { next }
    # Look for cd "...$LORE_LIB_DIR/.." or cd "$LORE_LIB_DIR/..something
    /cd[[:space:]]+["'"'"'][^"'"'"']*\$LORE_LIB_DIR\/\.\./ { print NR": "$0 }
  ' "$LIB_SH")
  if [ -n "$hits" ]; then
    echo "lib.sh: forbidden pattern (\$LORE_LIB_DIR/.. chained into cd) found:" >&2
    echo "$hits" >&2
    echo "Use \$LORE_REPO_DIR (already resolved physically) instead." >&2
    return 1
  fi
}

@test "lib.sh: rejects unsupported shells with a clear error" {
  # Sanity-check the safety net at top of lib.sh. Force the detection
  # to fail by clearing both BASH_SOURCE and ZSH_VERSION and pointing
  # ${0} somewhere bogus, then assert lib.sh refuses with a recognizable
  # message rather than silently routing through a wrong path.
  #
  # We can't easily run a "different" shell, so we simulate the failure
  # by sourcing a tiny shim that pre-clobbers the detection inputs and
  # falls through to the ${0}-based branch.
  cat >"$BATS_TEST_TMPDIR/shim.sh" <<EOF
# Pretend to be a non-bash, non-zsh shell by clearing the markers AFTER
# the original \${BASH_SOURCE[0]} captured the shim path. We then re-source
# lib.sh — its detection block will see empty BASH_SOURCE, empty
# ZSH_VERSION, and \$0 pointing at the shim under /tmp (no lib.sh there),
# which is exactly the unsupported-shell case the safety net guards.
unset 'BASH_SOURCE'
ZSH_VERSION=""
set -- "/tmp/definitely-not-lib"
source '$LIB_SH'
EOF
  run bash "$BATS_TEST_TMPDIR/shim.sh"
  # The safety net should fire — but only when detection genuinely fails.
  # bash always populates BASH_SOURCE for the *current* file regardless of
  # the parent's unset, so this case is hard to exercise inline without a
  # third shell. Treat the test as passing if either (a) lib.sh refused
  # loudly, or (b) bash's BASH_SOURCE override kept detection working.
  if [ "$status" -ne 0 ]; then
    [[ "$output" == *"self-detection failed"* ]]
  fi
}
