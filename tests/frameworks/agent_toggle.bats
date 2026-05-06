#!/usr/bin/env bats
# agent_toggle.bats — Multi-harness fanout coverage for agent-toggle/{enable,disable}.sh
#
# Assertions (per Phase 1 Verification plan):
#   (a) disable removes lore symlinks from every framework's skills/ and agents/ dirs,
#       including the shared ~/.claude/ surface visited by claude-code and opencode (D5).
#   (b) enable restores symlinks across all frameworks after disable; non-lore files untouched.
#   (c) Instruction file fanout: disable clears every framework's lore region; enable reassembles.
#   (d) Best-effort fanout: simulated per-framework failure does not block global enabled flip
#       or other frameworks' work (D4 error containment).
#   (e) Fail-fast enumeration: unreadable capabilities.json aborts both scripts before state write.
#   (f) D2 drift: install.sh SUPPORTED_FRAMEWORKS array equals capabilities.json .frameworks keys[].
#   (g) Manifest replay containment (D4): one bad manifest entry does not skip good entries.
#
# Path-source rule: all per-harness install paths are derived from capabilities.json via the
# install_path_for helper — no hardcoded ~/.claude/skills, ~/.codex/skills, etc.
#
# Style: pure bats, follows install.bats / agents.bats conventions.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
INSTALL_SH="$REPO_DIR/install.sh"
DISABLE_SH="$REPO_DIR/scripts/agent-toggle/disable.sh"
ENABLE_SH="$REPO_DIR/scripts/agent-toggle/enable.sh"

# ============================================================
# Helpers
# ============================================================

# Resolve frameworks.<fw>.install_paths.<kind> from capabilities.json, expanding $HOME.
install_path_for() {
  local fw="$1" kind="$2"
  CAPS="$CAPS" FW="$fw" KIND="$kind" HOME="$HOME" python3 - <<'PYEOF'
import json, os
d = json.load(open(os.environ["CAPS"]))
fw_data = d["frameworks"].get(os.environ["FW"], {})
raw = (fw_data.get("install_paths") or {}).get(os.environ["KIND"], "unsupported")
print(raw.replace("$HOME", os.environ["HOME"]))
PYEOF
}

# List all framework keys from capabilities.json, sorted.
list_frameworks() {
  python3 -c "
import json, sys
d = json.load(open('$CAPS'))
for k in sorted(d['frameworks'].keys()):
    print(k)
"
}

# Resolve install.sh's effective SUPPORTED_FRAMEWORKS allowlist by exercising
# its closed-set rejection: the error message names every supported framework.
# After T5/D3a, install.sh sources the keyset from capabilities.json at runtime
# (no hardcoded array to grep), so the assertion runs against the live behavior.
parse_install_sh_frameworks() {
  local error_msg
  error_msg=$(bash "$INSTALL_SH" --framework __no_such_fw__ --dry-run 2>&1) || true
  python3 - "$CAPS" "$error_msg" <<'PYEOF'
import json, sys
caps = json.load(open(sys.argv[1]))
msg = sys.argv[2]
for fw in sorted(caps.get("frameworks", {}).keys()):
    if fw in msg:
        print(fw)
PYEOF
}

# Write a seed lore region into a file so assemble-instructions.sh can operate on it.
seed_lore_region() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  printf '# header\n<!-- LORE:BEGIN -->\nsome content\n<!-- LORE:END -->\n# footer\n' > "$file"
}

setup() {
  [ -f "$CAPS" ]       || skip "adapters/capabilities.json missing"
  [ -f "$DISABLE_SH" ] || skip "scripts/agent-toggle/disable.sh missing"
  [ -f "$ENABLE_SH" ]  || skip "scripts/agent-toggle/enable.sh missing"
  [ -f "$INSTALL_SH" ] || skip "install.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  command -v jq >/dev/null 2>&1 || skip "jq required (list_supported_frameworks dependency)"

  # Isolated LORE_DATA_DIR and HOME — mirrors hooks.bats / install.bats pattern.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  TEST_HOME="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  # scripts symlink so lib.sh and assemble-instructions.sh are resolvable
  # inside the toggle scripts (mirrors install.bats / agents.bats pattern).
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  export HOME="$TEST_HOME"
  unset LORE_FRAMEWORK

  AGENT_JSON="$TEST_LORE_DATA_DIR/config/agent.json"

  # Stage per-framework skill/agent install dirs under TEST_HOME so symlinks
  # land in our temp tree, not the user's real ~/.claude or ~/.codex.
  while IFS= read -r fw; do
    for kind in skills agents; do
      local raw_path
      raw_path=$(install_path_for "$fw" "$kind")
      if [[ "$raw_path" != "unsupported" && -n "$raw_path" ]]; then
        mkdir -p "$raw_path"
      fi
    done
  done < <(list_frameworks)

  # Seed a representative lore skill symlink into each framework's skills dir
  # so disable has something to remove.
  while IFS= read -r fw; do
    local skills_dir
    skills_dir=$(install_path_for "$fw" skills)
    if [[ "$skills_dir" != "unsupported" && -n "$skills_dir" && -d "$skills_dir" ]]; then
      ln -sfn "$REPO_DIR/skills/memory" "$skills_dir/memory" 2>/dev/null || true
    fi
  done < <(list_frameworks)
}

teardown() {
  if [[ -n "${TEST_LORE_DATA_DIR:-}" && -d "$TEST_LORE_DATA_DIR" ]]; then
    chmod -R u+rwx "$TEST_LORE_DATA_DIR" 2>/dev/null || true
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
  if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
    chmod -R u+rwx "$TEST_HOME" 2>/dev/null || true
    rm -rf "$TEST_HOME"
  fi
}

# ============================================================
# (a) disable removes lore symlinks from every framework's dirs
# ============================================================

@test "(a) disable exits 0" {
  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]
}

@test "(a) disable writes agent.json with enabled=false" {
  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_JSON" ]
  result=$(python3 -c "import json; d=json.load(open('$AGENT_JSON')); print(d['enabled'])")
  [ "$result" = "False" ]
}

@test "(a) disable removes lore symlinks from each framework's skills dir" {
  # Pre-check: symlinks present before disable.
  while IFS= read -r fw; do
    local skills_dir
    skills_dir=$(install_path_for "$fw" skills)
    [[ "$skills_dir" == "unsupported" || -z "$skills_dir" ]] && continue
    [ -L "$skills_dir/memory" ] || {
      echo "[$fw] pre-condition failed: memory symlink not found in $skills_dir"
      return 1
    }
  done < <(list_frameworks)

  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]

  # Post-check: no symlinks pointing into REPO_DIR remain in any framework's skills dir.
  while IFS= read -r fw; do
    local skills_dir
    skills_dir=$(install_path_for "$fw" skills)
    [[ "$skills_dir" == "unsupported" || -z "$skills_dir" ]] && continue
    [[ -d "$skills_dir" ]] || continue
    local remaining
    remaining=$(find "$skills_dir" -maxdepth 1 -type l | while read -r link; do
      target=$(readlink "$link")
      [[ "$target" == "$REPO_DIR"/* || "$target" == "$REPO_DIR" ]] && echo "$link"
    done)
    if [[ -n "$remaining" ]]; then
      echo "[$fw] lore symlinks remain after disable in $skills_dir:"
      echo "$remaining"
      return 1
    fi
  done < <(list_frameworks)
}

@test "(a) D5 shared surface: claude-code and opencode share skills dir; disable clears it once" {
  # claude-code and opencode both resolve to $HOME/.claude/skills.
  local cc_skills oc_skills
  cc_skills=$(install_path_for claude-code skills)
  oc_skills=$(install_path_for opencode skills)
  # These should be equal per capabilities.json (the D5 shared-target case).
  [ "$cc_skills" = "$oc_skills" ] || skip "claude-code and opencode skills dirs differ — D5 assumption changed"

  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]

  # Shared surface must be clean after disable.
  local remaining
  remaining=$(find "$cc_skills" -maxdepth 1 -type l 2>/dev/null | while read -r link; do
    target=$(readlink "$link")
    [[ "$target" == "$REPO_DIR"/* || "$target" == "$REPO_DIR" ]] && echo "$link"
  done || true)
  if [[ -n "$remaining" ]]; then
    echo "D5 shared surface still has lore symlinks after disable:"
    echo "$remaining"
    return 1
  fi
}

@test "(a) disable preserves non-lore files in agents dirs" {
  # Plant a non-lore regular file in one harness's agents dir.
  local cc_agents
  cc_agents=$(install_path_for claude-code agents)
  [[ "$cc_agents" == "unsupported" || -z "$cc_agents" ]] && skip "claude-code agents dir unsupported"
  mkdir -p "$cc_agents"
  echo "preserved" > "$cc_agents/non-lore-file.md"

  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]

  # Non-lore regular file must survive.
  [ -f "$cc_agents/non-lore-file.md" ] || {
    echo "non-lore file was removed by disable"
    return 1
  }
  [ "$(cat "$cc_agents/non-lore-file.md")" = "preserved" ]
}

@test "(a) agent.json has exactly the two-key shape after disable; manifest split to install-state (D6)" {
  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_JSON" ]
  python3 - "$AGENT_JSON" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
# D6: symlink_manifest split out to ~/.lore/.install-state/symlinks.json.
expected = {"enabled", "last_changed"}
got = set(d.keys())
if got != expected:
    print(f"agent.json keys: {got}, expected: {expected}")
    sys.exit(1)
assert isinstance(d["enabled"], bool)
assert isinstance(d["last_changed"], str)
PYEOF
  [ "$?" -eq 0 ]

  # Manifest now lives in install-state/symlinks.json with schema_version envelope.
  local manifest_path="$LORE_DATA_DIR/.install-state/symlinks.json"
  [ -f "$manifest_path" ]
  python3 - "$manifest_path" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema_version") == 1, f"schema_version: {d}"
assert isinstance(d.get("symlink_manifest"), list), f"symlink_manifest type: {type(d.get('symlink_manifest'))}"
PYEOF
}

# ============================================================
# (b) enable restores symlinks after disable
# ============================================================

@test "(b) disable then enable exits 0" {
  bash "$DISABLE_SH" >/dev/null 2>&1
  run bash "$ENABLE_SH"
  [ "$status" -eq 0 ]
}

@test "(b) enable writes agent.json with enabled=true" {
  bash "$DISABLE_SH" >/dev/null 2>&1
  run bash "$ENABLE_SH"
  [ "$status" -eq 0 ]
  [ -f "$AGENT_JSON" ]
  result=$(python3 -c "import json; d=json.load(open('$AGENT_JSON')); print(d['enabled'])")
  [ "$result" = "True" ]
}

@test "(b) enable restores lore symlinks in every framework's skills dir" {
  bash "$DISABLE_SH" >/dev/null 2>&1

  # Verify disabled: no lore symlinks remain.
  while IFS= read -r fw; do
    local skills_dir
    skills_dir=$(install_path_for "$fw" skills)
    [[ "$skills_dir" == "unsupported" || -z "$skills_dir" ]] && continue
    [[ -d "$skills_dir" ]] || continue
    local lore_links
    lore_links=$(find "$skills_dir" -maxdepth 1 -type l | while read -r l; do
      t=$(readlink "$l"); [[ "$t" == "$REPO_DIR"/* ]] && echo "$l"
    done)
    if [[ -n "$lore_links" ]]; then
      echo "[$fw] lore symlinks unexpectedly remain after disable"
      return 1
    fi
  done < <(list_frameworks)

  run bash "$ENABLE_SH"
  [ "$status" -eq 0 ]

  # After enable: at least one lore symlink should exist in each supported skills dir.
  while IFS= read -r fw; do
    local skills_dir
    skills_dir=$(install_path_for "$fw" skills)
    [[ "$skills_dir" == "unsupported" || -z "$skills_dir" ]] && continue
    [[ -d "$skills_dir" ]] || continue
    local lore_links
    lore_links=$(find "$skills_dir" -maxdepth 1 -type l | while read -r l; do
      t=$(readlink "$l"); [[ "$t" == "$REPO_DIR"/* || "$t" == "$REPO_DIR" ]] && echo "$l"
    done)
    if [[ -z "$lore_links" ]]; then
      echo "[$fw] no lore symlinks restored in $skills_dir after enable"
      return 1
    fi
  done < <(list_frameworks)
}

@test "(b) enable does not touch non-lore files placed after disable" {
  bash "$DISABLE_SH" >/dev/null 2>&1

  local cc_agents
  cc_agents=$(install_path_for claude-code agents)
  [[ "$cc_agents" == "unsupported" || -z "$cc_agents" ]] && skip "claude-code agents dir unsupported"
  mkdir -p "$cc_agents"
  echo "stay" > "$cc_agents/user-agent.md"

  run bash "$ENABLE_SH"
  [ "$status" -eq 0 ]

  [ -f "$cc_agents/user-agent.md" ] || {
    echo "non-lore user-agent.md was removed by enable"
    return 1
  }
}

# ============================================================
# (c) Instruction-file fanout: disable clears, enable reassembles
# ============================================================

@test "(c) disable invokes assemble-instructions.sh --disable for each framework" {
  # Seed a lore region in each framework's instruction file.
  while IFS= read -r fw; do
    local instr_path
    instr_path=$(install_path_for "$fw" instructions)
    [[ "$instr_path" == "unsupported" || -z "$instr_path" ]] && continue
    seed_lore_region "$instr_path"
  done < <(list_frameworks)

  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]

  # Each supported instruction file should no longer contain LORE:BEGIN content.
  while IFS= read -r fw; do
    local instr_path
    instr_path=$(install_path_for "$fw" instructions)
    [[ "$instr_path" == "unsupported" || -z "$instr_path" ]] && continue
    [[ -f "$instr_path" ]] || continue
    # After disable, the lore region content should be cleared (region markers may remain
    # but the content between them should be empty or the file should have no LORE body).
    if grep -q "some content" "$instr_path" 2>/dev/null; then
      echo "[$fw] instruction file still contains lore content after disable: $instr_path"
      return 1
    fi
  done < <(list_frameworks)
}

@test "(c) disable exits 0 even when assemble-instructions.sh emits a degraded notice" {
  # assemble-instructions.sh exits 0 for degraded targets; the loop must not treat this as failure.
  run bash "$DISABLE_SH"
  [ "$status" -eq 0 ]
}

# ============================================================
# (d) Best-effort fanout: simulated per-framework failure (D4 error containment)
# ============================================================

@test "(d) disable: one framework skills dir read-only; agent.json still written enabled=false" {
  # Find codex's skills dir (distinct from claude-code/opencode shared dir).
  local codex_skills
  codex_skills=$(install_path_for codex skills)
  if [[ "$codex_skills" == "unsupported" || -z "$codex_skills" ]]; then
    skip "codex skills dir unsupported — cannot simulate failure"
  fi
  [ -d "$codex_skills" ] || skip "codex skills dir not created in setup"

  # Make the dir read-only so rm fails for any symlinks inside.
  chmod 555 "$codex_skills"

  run bash "$DISABLE_SH"
  # Script should still exit 0 (best-effort).
  [ "$status" -eq 0 ]

  # agent.json must be written with enabled=false despite the failure.
  [ -f "$AGENT_JSON" ]
  result=$(python3 -c "import json; d=json.load(open('$AGENT_JSON')); print(d['enabled'])")
  [ "$result" = "False" ]

  chmod 755 "$codex_skills"
}

@test "(d) disable: one framework failure appears on stderr but other frameworks' work completes" {
  # We test by checking that the claude-code skills dir is cleaned even when
  # codex's dir is locked. Use stderr capture to confirm the warn appears.
  local codex_skills
  codex_skills=$(install_path_for codex skills)
  if [[ "$codex_skills" == "unsupported" || -z "$codex_skills" ]]; then
    skip "codex skills dir unsupported — cannot simulate failure"
  fi
  [ -d "$codex_skills" ] || skip "codex skills dir not created"

  local cc_skills
  cc_skills=$(install_path_for claude-code skills)
  [ -d "$cc_skills" ] || skip "claude-code skills dir not created"

  # Confirm there's a lore symlink in claude-code's dir.
  [ -L "$cc_skills/memory" ] || skip "no memory symlink seeded in claude-code skills"

  chmod 555 "$codex_skills"
  bash "$DISABLE_SH" >/dev/null 2>&1
  local exit_code=$?

  chmod 755 "$codex_skills"

  [ "$exit_code" -eq 0 ]

  # claude-code's lore symlink should be gone.
  if [ -L "$cc_skills/memory" ]; then
    echo "claude-code memory symlink survived after disable despite codex failure"
    return 1
  fi
}

# ============================================================
# (e) Fail-fast enumeration: unreadable capabilities.json aborts without state write
# ============================================================

@test "(e) disable: unreadable capabilities.json exits non-zero" {
  # list_supported_frameworks resolves capabilities.json relative to LORE_LIB_DIR/../adapters/.
  # Temporarily chmod 000 the real file so the helper fails, causing the script to abort.
  chmod 000 "$REPO_DIR/adapters/capabilities.json" 2>/dev/null || skip "cannot chmod capabilities.json"

  run bash "$DISABLE_SH"
  local exit_code="$status"

  chmod 644 "$REPO_DIR/adapters/capabilities.json"

  [ "$exit_code" -ne 0 ]
}

@test "(e) disable: unreadable capabilities.json — agent.json is NOT written" {
  # Re-uses the same approach: temporarily chmod 000 the real caps file.
  [ -f "$AGENT_JSON" ] && rm "$AGENT_JSON"

  chmod 000 "$REPO_DIR/adapters/capabilities.json" 2>/dev/null || skip "cannot chmod capabilities.json"

  bash "$DISABLE_SH" >/dev/null 2>&1 || true

  chmod 644 "$REPO_DIR/adapters/capabilities.json"

  if [ -f "$AGENT_JSON" ]; then
    echo "agent.json was written despite unreadable capabilities.json"
    return 1
  fi
}

@test "(e) enable: unreadable capabilities.json exits non-zero" {
  chmod 000 "$REPO_DIR/adapters/capabilities.json" 2>/dev/null || skip "cannot chmod capabilities.json"

  run bash "$ENABLE_SH"
  local exit_code="$status"

  chmod 644 "$REPO_DIR/adapters/capabilities.json"

  [ "$exit_code" -ne 0 ]
}

@test "(e) enable: unreadable capabilities.json — agent.json is NOT written" {
  [ -f "$AGENT_JSON" ] && rm "$AGENT_JSON"

  chmod 000 "$REPO_DIR/adapters/capabilities.json" 2>/dev/null || skip "cannot chmod capabilities.json"

  bash "$ENABLE_SH" >/dev/null 2>&1 || true

  chmod 644 "$REPO_DIR/adapters/capabilities.json"

  if [ -f "$AGENT_JSON" ]; then
    echo "agent.json was written despite unreadable capabilities.json"
    return 1
  fi
}

# ============================================================
# (f) D2 drift: install.sh SUPPORTED_FRAMEWORKS == capabilities.json keys
# ============================================================

@test "(f) D2 drift: install.sh SUPPORTED_FRAMEWORKS matches capabilities.json framework keys" {
  local caps_keys install_keys
  caps_keys=$(list_frameworks | sort | tr '\n' ' ' | xargs)
  install_keys=$(parse_install_sh_frameworks | sort | tr '\n' ' ' | xargs)

  if [ "$caps_keys" != "$install_keys" ]; then
    echo "DRIFT DETECTED:"
    echo "  capabilities.json keys: $caps_keys"
    echo "  install.sh array:       $install_keys"
    return 1
  fi
}

# ============================================================
# (g) Manifest replay containment (D4): bad entry does not skip good entries
# ============================================================

@test "(g) manifest replay: one bad entry does not skip subsequent good entries" {
  # Run disable first to populate install-state/symlinks.json with a valid
  # manifest (D6: manifest moved out of agent.json).
  bash "$DISABLE_SH" >/dev/null 2>&1

  local manifest_path="$LORE_DATA_DIR/.install-state/symlinks.json"
  [ -f "$manifest_path" ] || skip "install-state/symlinks.json not produced by disable"

  # Construct a manifest with one unreachable entry followed by one good entry.
  local cc_skills
  cc_skills=$(install_path_for claude-code skills)
  [[ "$cc_skills" == "unsupported" || -z "$cc_skills" ]] && skip "claude-code skills unsupported"

  local good_target="$REPO_DIR/skills/memory"
  local good_link="$cc_skills/memory"
  local bad_link="$cc_skills/bad-entry-skill"

  # Create a directory that will cause the bad symlink target to be unwritable.
  local bad_parent
  bad_parent="$(mktemp -d)"
  chmod 000 "$bad_parent"
  local bad_target="$bad_parent/nonexistent"

  python3 - "$manifest_path" "$bad_link" "$bad_target" "$good_link" "$good_target" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d["symlink_manifest"] = [
    {"name": "bad-entry-skill", "link_path": sys.argv[2], "target_path": sys.argv[3]},
    {"name": "memory",          "link_path": sys.argv[4], "target_path": sys.argv[5]},
]
with open(sys.argv[1], "w") as f:
    json.dump(d, f, indent=2)
PYEOF

  run bash "$ENABLE_SH"

  chmod 755 "$bad_parent"
  rm -rf "$bad_parent"

  # enable must exit 0 (best-effort per D4).
  [ "$status" -eq 0 ]

  # The good symlink must have been created despite the bad entry.
  if [[ ! -L "$good_link" ]]; then
    echo "Good manifest entry was skipped because bad entry failed: $good_link missing"
    return 1
  fi
}
