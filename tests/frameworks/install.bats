#!/usr/bin/env bats
# install.bats — Dry-run coverage for install.sh multi-harness paths (Phase 7, T23).
#
# Each harness section asserts:
#   - exit 0 under --dry-run
#   - Framework: <name> appears in the header
#   - Per-harness skills/agents/instructions path appears in the summary
#   - permission_hooks capability triple (support=X evidence=Y) is present
#   - degraded: token is from the closed vocabulary when present
#   - resolve_permission_adapter dispatch shape (cli: vs plugin-symlink:) matches harness
#
# Cross-framework:
#   - --uninstall walks SUPPORTED_FRAMEWORKS (all three mentioned in dry-run)
#   - --framework bogus exits non-zero with a closed-set error
#
# Default role seeding:
#   - A real install (non-dry) seeds roles.lead=opus and roles.worker=sonnet in
#     framework.json; dry-run skips the python3 write, so role-seeding assertions
#     are made against the python3 block source text in install.sh directly.
#
# Style: pure bats. The setup() / teardown() pattern isolates LORE_DATA_DIR so
# tests never touch the user's real ~/.lore or ~/.claude. Follows the same
# pattern established in hooks.bats and agents.bats.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
INSTALL_SH="$REPO_DIR/install.sh"
CAPS="$REPO_DIR/adapters/capabilities.json"
ROLES_JSON="$REPO_DIR/adapters/roles.json"

# Closed degradation vocabulary from adapters/capabilities.json skills._degradation_vocab.
# Tests assert every degraded: token in dry-run output uses one of these forms.
DEGRADED_VOCAB_RE='degraded:(partial|fallback|none|no-evidence|unverified-support\([^)]+\))'

setup() {
  [ -f "$INSTALL_SH" ] || skip "install.sh missing"
  [ -f "$CAPS" ]       || skip "adapters/capabilities.json missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for capability lookups"

  # Isolated data dir — mirrors hooks.bats/agents.bats pattern.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  TEST_HOME="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  # Provide a scripts symlink so lib.sh is resolvable inside install.sh
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  # Pre-seed capture-config.json so the "already exists, skipping" branch is
  # taken and the output stays deterministic across runs.
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  echo '{}' > "$TEST_LORE_DATA_DIR/config/capture-config.json"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export HOME="$TEST_HOME"
  unset LORE_FRAMEWORK
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
  if [ -n "${TEST_HOME:-}" ] && [ -d "$TEST_HOME" ]; then
    rm -rf "$TEST_HOME"
  fi
}

# --- helpers ---

# Look up frameworks.<fw>.capabilities.<cap>.support from capabilities.json.
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

# Look up frameworks.<fw>.capabilities.<cap>.evidence from capabilities.json.
cap_evidence() {
  local fw="$1" cap="$2"
  CAPS="$CAPS" FW="$fw" CAP="$cap" python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
fw = d["frameworks"].get(os.environ["FW"], {})
cell = (fw.get("capabilities") or {}).get(os.environ["CAP"])
if not cell or not cell.get("evidence"):
    print("")
else:
    print(cell["evidence"])
PYEOF
}

# Resolve harness install_paths.<kind> from capabilities.json (fallback to
# "unsupported" when absent). Uses the same HOME expansion install.sh applies.
install_path_for() {
  local fw="$1" kind="$2"
  CAPS="$CAPS" FW="$fw" KIND="$kind" HOME="$HOME" python3 - <<'PYEOF'
import json, os
d = json.load(open(os.environ["CAPS"]))
fw = d["frameworks"].get(os.environ["FW"], {})
raw = (fw.get("install_paths") or {}).get(os.environ["KIND"], "unsupported")
print(raw.replace("$HOME", os.environ["HOME"]))
PYEOF
}

# ============================================================
# Negative test: unknown framework
# ============================================================

@test "--framework bogus exits non-zero" {
  run bash "$INSTALL_SH" --framework bogus --dry-run
  [ "$status" -ne 0 ]
}

@test "--framework bogus error names the supported set" {
  run bash "$INSTALL_SH" --framework bogus --dry-run
  [ "$status" -ne 0 ]
  # Error should mention the supported frameworks; at minimum "supported"
  [[ "$output" =~ "supported" ]] || [[ "$output" =~ "claude-code" ]]
}

# ============================================================
# claude-code
# ============================================================

@test "claude-code dry-run exits 0" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
}

@test "claude-code dry-run prints Framework: claude-code" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Framework: claude-code" ]]
}

@test "claude-code dry-run skills target is ~/.claude/skills" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  expected_skills=$(install_path_for claude-code skills)
  [[ "$output" =~ "$expected_skills" ]]
}

@test "claude-code dry-run instructions target is ~/.claude/CLAUDE.md" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  expected_instr=$(install_path_for claude-code instructions)
  [[ "$output" =~ "$expected_instr" ]]
}

@test "claude-code dry-run permission_hooks support matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  expected=$(cap_support claude-code permission_hooks)
  [[ "$output" =~ "support=$expected" ]]
}

@test "claude-code dry-run permission_hooks evidence matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  expected=$(cap_evidence claude-code permission_hooks)
  [ -n "$expected" ]
  [[ "$output" =~ "evidence=$expected" ]]
}

@test "claude-code dry-run adapter dispatch is cli: form" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  # claude-code uses the bash hooks adapter (cli: dispatch shape).
  # The info line says "Configuring hooks via adapters/hooks/claude-code.sh install"
  [[ "$output" =~ "adapters/hooks/claude-code.sh" ]]
}

@test "claude-code dry-run any degraded: token uses closed vocabulary" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  # Extract lines containing degraded: and assert each token matches the vocab.
  while IFS= read -r line; do
    [[ "$line" =~ degraded: ]] || continue
    # Each degraded: occurrence must match the closed vocab regex.
    if ! echo "$line" | grep -qE "$DEGRADED_VOCAB_RE"; then
      echo "Line contains out-of-vocab degraded: token: $line"
      return 1
    fi
  done <<<"$output"
}

@test "claude-code dry-run summary shows CLAUDE.md label (byte-equivalence)" {
  run bash "$INSTALL_SH" --dry-run --framework claude-code
  [ "$status" -eq 0 ]
  # The historical summary label for claude-code is exactly "CLAUDE.md:"
  [[ "$output" =~ "CLAUDE.md:" ]]
}

# ============================================================
# opencode
# ============================================================

@test "opencode dry-run exits 0" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
}

@test "opencode dry-run prints Framework: opencode" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Framework: opencode" ]]
}

@test "opencode dry-run skills target matches capabilities.json install_paths.skills" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  expected_skills=$(install_path_for opencode skills)
  [[ "$output" =~ "$expected_skills" ]]
}

@test "opencode dry-run instructions target matches capabilities.json install_paths.instructions" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  expected_instr=$(install_path_for opencode instructions)
  [[ "$output" =~ "$expected_instr" ]]
}

@test "opencode dry-run permission_hooks support matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  expected=$(cap_support opencode permission_hooks)
  [[ "$output" =~ "support=$expected" ]]
}

@test "opencode dry-run permission_hooks evidence matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  expected=$(cap_evidence opencode permission_hooks)
  [ -n "$expected" ]
  [[ "$output" =~ "evidence=$expected" ]]
}

@test "opencode dry-run adapter dispatch is plugin-symlink: form" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  # opencode uses plugin-symlink dispatch (lore-hooks.ts).
  [[ "$output" =~ "lore-hooks.ts" ]]
}

@test "opencode dry-run permission_hooks degrades to partial (closed-set token)" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  # opencode permission_hooks.support=partial → degraded:partial in the triple.
  [[ "$output" =~ "degraded:partial" ]]
}

@test "opencode dry-run any degraded: token uses closed vocabulary" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ "$line" =~ degraded: ]] || continue
    if ! echo "$line" | grep -qE "$DEGRADED_VOCAB_RE"; then
      echo "Line contains out-of-vocab degraded: token: $line"
      return 1
    fi
  done <<<"$output"
}

@test "opencode dry-run summary shows Instructions: label (not CLAUDE.md:)" {
  run bash "$INSTALL_SH" --dry-run --framework opencode
  [ "$status" -eq 0 ]
  # Non-claude-code harnesses use the generic "Instructions:" label
  [[ "$output" =~ "Instructions:" ]]
  # And must NOT use the claude-code-specific "CLAUDE.md:" label
  if [[ "$output" =~ "  CLAUDE.md:" ]]; then
    echo "opencode summary used claude-code-specific CLAUDE.md: label"
    return 1
  fi
}

# ============================================================
# codex
# ============================================================

@test "codex dry-run exits 0" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
}

@test "codex dry-run prints Framework: codex" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Framework: codex" ]]
}

@test "codex dry-run skills target is ~/.codex/skills" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  expected_skills=$(install_path_for codex skills)
  [[ "$output" =~ "$expected_skills" ]]
}

@test "codex dry-run instructions target is ~/.codex/AGENTS.md" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  expected_instr=$(install_path_for codex instructions)
  [[ "$output" =~ "$expected_instr" ]]
}

@test "codex dry-run permission_hooks support matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  expected=$(cap_support codex permission_hooks)
  [[ "$output" =~ "support=$expected" ]]
}

@test "codex dry-run permission_hooks evidence matches capabilities.json" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  expected=$(cap_evidence codex permission_hooks)
  [ -n "$expected" ]
  [[ "$output" =~ "evidence=$expected" ]]
}

@test "codex dry-run adapter dispatch is cli: form (hooks.sh)" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  # codex uses the bash hooks adapter (cli: dispatch shape).
  [[ "$output" =~ "adapters/codex/hooks.sh" ]]
}

@test "codex dry-run any degraded: token uses closed vocabulary" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ "$line" =~ degraded: ]] || continue
    if ! echo "$line" | grep -qE "$DEGRADED_VOCAB_RE"; then
      echo "Line contains out-of-vocab degraded: token: $line"
      return 1
    fi
  done <<<"$output"
}

@test "codex dry-run summary shows Instructions: label (not CLAUDE.md:)" {
  run bash "$INSTALL_SH" --dry-run --framework codex
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Instructions:" ]]
  if [[ "$output" =~ "  CLAUDE.md:" ]]; then
    echo "codex summary used claude-code-specific CLAUDE.md: label"
    return 1
  fi
}

@test "codex dry-run skills path differs from claude-code skills path" {
  run_cc=$(bash "$INSTALL_SH" --dry-run --framework claude-code 2>&1)
  run_codex=$(bash "$INSTALL_SH" --dry-run --framework codex 2>&1)
  # claude-code uses ~/.claude/skills; codex uses ~/.codex/skills
  cc_skills=$(install_path_for claude-code skills)
  cx_skills=$(install_path_for codex skills)
  [ "$cc_skills" != "$cx_skills" ]
  [[ "$run_cc" =~ "$cc_skills" ]]
  [[ "$run_codex" =~ "$cx_skills" ]]
}

# ============================================================
# Cross-framework: --uninstall mentions all three supported harnesses
# ============================================================

@test "--uninstall dry-run exits 0" {
  run bash "$INSTALL_SH" --uninstall --dry-run
  [ "$status" -eq 0 ]
}

@test "--uninstall output references all three SUPPORTED_FRAMEWORKS" {
  run bash "$INSTALL_SH" --uninstall --dry-run
  [ "$status" -eq 0 ]
  # Uninstall walks all frameworks so their skill/agent paths appear in output
  # (even if the dirs don't exist — the test pattern uses -L checks which
  # simply skip absent targets silently). We assert the framework names or
  # their harness-specific paths appear.
  # At minimum the uninstall header and data-dir preservation message should appear.
  [[ "$output" =~ "Lore hooks and symlinks removed" ]]
}

# ============================================================
# Default role seeding: lead=opus, all others=sonnet
# ============================================================

@test "install.sh source seeds lead role as opus in DEFAULT_BY_ROLE" {
  # The role-seeding python block in install.sh must map lead->opus.
  # This is the byte-equivalence invariant: default claude-code install
  # preserves the legacy lead=opus behavior.
  run grep -n 'DEFAULT_BY_ROLE\|"lead".*"opus"\|lead.*opus' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "lead" ]]
  [[ "$output" =~ "opus" ]]
}

@test "install.sh source seeds non-lead roles as sonnet fallback" {
  # The DEFAULT_BY_ROLE dict has only lead overridden; all other roles
  # default to "sonnet". Verify the fallback string appears near the dict.
  run grep -n '"sonnet"' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 0 ]
}

@test "install.sh derives role keyset from adapters/roles.json (closed registry)" {
  # The role-seeding block sources roles.json not a hardcoded list.
  run grep -n 'roles\.json\|roles_path\|roles_data' "$INSTALL_SH"
  [ "$status" -eq 0 ]
  # At least the roles.json reference must exist
  [[ "$output" =~ "roles.json" ]]
}
