#!/usr/bin/env bash
# doctor.sh — Detect installation drift between repo source and installed state
#
# Checks all lore-managed artifacts and reports missing/wrong_target/stale issues.
#
# Usage:
#   bash doctor.sh           # Verbose output, always runs
#   bash doctor.sh --json    # Structured JSON output (D5 schema)
#   bash doctor.sh --quiet   # Silent when clean, one-line summary when drifted;
#                            # skips checks if ~/.lore/.doctor-last-run is <24h old
#   bash doctor.sh --digest  # Only the numbered next steps (install.sh ends with it)
#
# Prerequisites (python3, jq, git, PATH, and the optional TUI/PR tooling) come
# from prereqs.sh. Every issue carries the command that fixes it. Optional
# prerequisites are listed but never count as drift: --quiet stays silent and
# the exit status stays 0 when only optional tools are missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=scripts/prereqs.sh
source "$SCRIPT_DIR/prereqs.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE_JSON=0
MODE_QUIET=0
MODE_DIGEST=0

for arg in "$@"; do
  case "$arg" in
    --json)    MODE_JSON=1 ;;
    --quiet)   MODE_QUIET=1 ;;
    --digest)  MODE_DIGEST=1 ;;
    --help|-h)
      echo "Usage: lore doctor [--json] [--quiet] [--digest]" >&2
      echo "  Check installation for drift between repo source and installed state." >&2
      echo "  --json    Output structured JSON (D5 schema)" >&2
      echo "  --quiet   Silent when clean; one-line summary when drifted" >&2
      echo "            Throttled: skips checks if last run was <24h ago" >&2
      echo "  --digest  Print only the numbered next steps that clear the issues" >&2
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# D6: Once-per-day throttle (--quiet mode only)
# ---------------------------------------------------------------------------
TIMESTAMP_FILE="$HOME/.lore/.doctor-last-run"
THROTTLE_WINDOW=86400  # 24 hours in seconds

if [[ "$MODE_QUIET" -eq 1 ]]; then
  if [[ -f "$TIMESTAMP_FILE" ]]; then
    now=$(date +%s)
    last_run=$(get_mtime "$TIMESTAMP_FILE")
    age=$(( now - last_run ))
    if [[ "$age" -lt "$THROTTLE_WINDOW" ]]; then
      exit 0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Snapshot caller's LORE_DATA_DIR before the installation-layout block below
# clobbers it. The role-config check (Check 8) must mirror lib.sh::resolve_role,
# which honors ${LORE_DATA_DIR:-$HOME/.lore}; using the post-clobber value would
# diverge from resolve_role's actual lookup path.
# ---------------------------------------------------------------------------
ROLE_CONFIG_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"

# ---------------------------------------------------------------------------
# Resolve repo directory from the ~/.lore/scripts symlink
# ---------------------------------------------------------------------------
LORE_SCRIPTS_LINK="$HOME/.lore/scripts"
LORE_DATA_DIR="$HOME/.lore"

if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
else
  # Fallback: assume we're running from within the repo
  LORE_REPO_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
fi

# ---------------------------------------------------------------------------
# Resolve harness install paths for the active framework via T71's
# harness_path_or_empty helper. The helper returns the absolute path on
# supported kinds and an empty string on either unsupported or lookup failure
# (missing config, missing jq, missing capabilities.json) — both states are
# equivalent for doctor: emit "n/a" rather than "missing" because emitting
# claude-shaped warnings on a non-claude harness would be a false alarm.
# ---------------------------------------------------------------------------
HARNESS_SKILLS_DIR=$(harness_path_or_empty skills)
HARNESS_AGENTS_DIR=$(harness_path_or_empty agents)
HARNESS_INSTRUCTIONS_FILE=$(harness_path_or_empty instructions)
HARNESS_SETTINGS_FILE=$(harness_path_or_empty settings)

# ---------------------------------------------------------------------------
# Issue collection
# ---------------------------------------------------------------------------
# Each issue is one string of five fields joined by the ASCII unit separator:
# component, type, artifact, detail, fix. Details can hold '|' and newlines
# (schema messages), so neither can separate fields. An empty fix falls back
# to _default_fix at render time.
US=$'\x1f'
ISSUES=()
CHECKED=()
PREREQ_RECORDS=""

add_issue() {
  local component="$1"
  local type="$2"
  local artifact="$3"
  local detail="$4"
  local fix="${5:-}"
  ISSUES+=("${component}${US}${type}${US}${artifact}${US}${detail}${US}${fix}")
}

# _split_issue <issue> — set I_COMPONENT, I_TYPE, I_ARTIFACT, I_DETAIL, I_FIX.
_split_issue() {
  local rest="$1"
  I_COMPONENT="${rest%%"$US"*}"; rest="${rest#*"$US"}"
  I_TYPE="${rest%%"$US"*}"; rest="${rest#*"$US"}"
  I_ARTIFACT="${rest%%"$US"*}"; rest="${rest#*"$US"}"
  I_DETAIL="${rest%%"$US"*}"; I_FIX="${rest#*"$US"}"
  if [[ -z "$I_FIX" ]]; then
    I_FIX=$(_default_fix "$I_COMPONENT" "$I_TYPE")
  fi
}

# _default_fix <component> <type> — the repair for drift that names no fix.
_default_fix() {
  case "$1:$2" in
    *:n/a) echo "" ;;
    claude_md:stale) echo "lore assemble" ;;
    *) echo "bash $LORE_REPO_DIR/install.sh" ;;
  esac
}

# ---------------------------------------------------------------------------
# Check 0: Prerequisites (prereqs.sh). Required ones are drift; optional ones
# are reported with type "optional" and never change status or exit code.
# Later checks that need python3 skip themselves when it is unusable, so a
# missing interpreter surfaces once, here, instead of as false config errors.
# ---------------------------------------------------------------------------
CHECKED+=("prerequisites")
PREREQ_RECORDS=$(lore_prereq_records)
while IFS= read -r _record; do
  [[ -z "$_record" ]] && continue
  _rest="$_record"
  _level="${_rest%%"$US"*}"; _rest="${_rest#*"$US"}"
  _name="${_rest%%"$US"*}"; _rest="${_rest#*"$US"}"
  _detail="${_rest%%"$US"*}"; _rest="${_rest#*"$US"}"
  _fix="${_rest#*"$US"}"
  if [[ "$_level" == required ]]; then
    add_issue "prerequisites" "missing" "$_name" "$_detail" "$_fix"
  else
    add_issue "prerequisites" "optional" "$_name" "$_detail" "$_fix"
  fi
done <<< "$PREREQ_RECORDS"
unset _record _rest _level _name _detail _fix
PYTHON_OK=0
if command -v python3 >/dev/null 2>&1 && lore_python_ok python3; then
  PYTHON_OK=1
fi

# ---------------------------------------------------------------------------
# Check 0b: TUI binary (optional, like the toolchain that builds it). Only
# reported when go and a C compiler are present — otherwise Check 0 already
# names what is missing — so a build that failed or was never run, or a
# platform with no vendored terminal library, still shows up.
# ---------------------------------------------------------------------------
CHECKED+=("tui")
if [[ ! -x "$HOME/.local/bin/lore-tui" ]] && command -v go >/dev/null 2>&1 \
  && { command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1; }; then
  if _tui_blocker=$(tui_ghostty_preflight "$LORE_REPO_DIR/tui"); then
    add_issue "tui" "optional" "lore-tui" \
      "the TUI (run \`lore\`, needed by /coordinate) is not built" \
      "bash $LORE_REPO_DIR/install.sh   (rebuilds it; a failed build prints its error)"
  else
    add_issue "tui" "optional" "lore-tui" "the TUI cannot be built here: $_tui_blocker" \
      "none on this platform yet"
  fi
  unset _tui_blocker
fi

# ---------------------------------------------------------------------------
# Check 1: scripts symlink
# ---------------------------------------------------------------------------
CHECKED+=("symlinks")
# Resolve a path (file or directory) to its canonical absolute path.
_resolve_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    cd "$p" && pwd
  elif [[ -f "$p" ]]; then
    echo "$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  else
    echo "$p"
  fi
}

_check_symlink() {
  local link="$1"
  local expected_target="$2"
  local component="$3"
  local artifact_label="$4"

  if [[ ! -e "$link" && ! -L "$link" ]]; then
    add_issue "$component" "missing" "$artifact_label" "symlink does not exist: $link"
  elif [[ ! -L "$link" ]]; then
    add_issue "$component" "wrong_target" "$artifact_label" "exists but is not a symlink: $link"
  else
    actual_target="$(readlink "$link")"
    expected_resolved="$(_resolve_path "$expected_target")"
    if [[ -e "$actual_target" ]]; then
      actual_resolved="$(_resolve_path "$actual_target")"
    else
      actual_resolved="$actual_target"
    fi
    if [[ "$actual_resolved" != "$expected_resolved" ]]; then
      add_issue "$component" "wrong_target" "$artifact_label" \
        "points to $actual_target, expected $expected_target"
    fi
  fi
}

_check_symlink "$LORE_SCRIPTS_LINK" "$LORE_REPO_DIR/scripts" "symlinks" "~/.lore/scripts"

# Check 2: claude-md symlink
LORE_CLAUDE_MD_LINK="$LORE_DATA_DIR/claude-md"
_check_symlink "$LORE_CLAUDE_MD_LINK" "$LORE_REPO_DIR/claude-md" "symlinks" "~/.lore/claude-md"

# ---------------------------------------------------------------------------
# Check 3: CLI symlink
# ---------------------------------------------------------------------------
_check_symlink "$HOME/.local/bin/lore" "$LORE_REPO_DIR/cli/lore" "cli" "~/.local/bin/lore"

# ---------------------------------------------------------------------------
# Determine agent state
# AGENT_CONFIG_DISABLED=1 only when config explicitly disables (not env override);
# this gates whether missing symlinks and empty CLAUDE.md are drift or healthy.
# ---------------------------------------------------------------------------
AGENT_STATE="enabled"
AGENT_CONFIG_DISABLED=0
if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
  AGENT_STATE="disabled (env override)"
else
  _AGENT_JSON="${LORE_DATA_DIR}/config/agent.json"
  if [[ -f "$_AGENT_JSON" ]]; then
    _ENABLED=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('enabled', True))" "$_AGENT_JSON" 2>/dev/null || echo "True")
    if [[ "$_ENABLED" == "False" ]]; then
      AGENT_STATE="disabled (config)"
      AGENT_CONFIG_DISABLED=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Check 4: Skills symlinks (skipped when config-disabled — absence is healthy)
# Skipped on harnesses with no skills surface; surfaces n/a so JSON
# consumers can distinguish "not applicable here" from "missing".
# ---------------------------------------------------------------------------
CHECKED+=("skills")
if [[ "$AGENT_CONFIG_DISABLED" -eq 0 && -d "$LORE_REPO_DIR/skills" ]]; then
  if [[ -z "$HARNESS_SKILLS_DIR" ]]; then
    add_issue "skills" "n/a" "skills" "active harness exposes no skills install path"
  else
    for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
      [[ -d "$skill_dir" ]] || continue
      skill_name="$(basename "$skill_dir")"
      link="$HARNESS_SKILLS_DIR/$skill_name"
      if [[ ! -e "$link" && ! -L "$link" ]]; then
        add_issue "skills" "missing" "$skill_name" "symlink missing: $link"
      elif [[ ! -L "$link" ]]; then
        add_issue "skills" "wrong_target" "$skill_name" "exists but is not a symlink: $link"
      else
        actual_target="$(readlink "$link")"
        expected_target="$skill_dir"
        if [[ -e "$actual_target" ]]; then
          actual_resolved="$(_resolve_path "$actual_target")"
        else
          actual_resolved="$actual_target"
        fi
        expected_resolved="$(_resolve_path "$expected_target")"
        if [[ "$actual_resolved" != "$expected_resolved" ]]; then
          add_issue "skills" "wrong_target" "$skill_name" \
            "points to $actual_target, expected $expected_target"
        fi
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check 5: Agents symlinks (skipped when config-disabled — absence is healthy)
# Skipped on harnesses with no agents surface; surfaces n/a so JSON
# consumers can distinguish "not applicable here" from "missing".
# ---------------------------------------------------------------------------
CHECKED+=("agents")
if [[ "$AGENT_CONFIG_DISABLED" -eq 0 && -d "$LORE_REPO_DIR/agents" ]]; then
  if [[ -z "$HARNESS_AGENTS_DIR" ]]; then
    add_issue "agents" "n/a" "agents" "active harness exposes no agents install path"
  else
    for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
      [[ -f "$agent_file" ]] || continue
      agent_name="$(basename "$agent_file")"
      link="$HARNESS_AGENTS_DIR/$agent_name"
      if [[ ! -e "$link" && ! -L "$link" ]]; then
        add_issue "agents" "missing" "$agent_name" "symlink missing: $link"
      elif [[ ! -L "$link" ]]; then
        add_issue "agents" "wrong_target" "$agent_name" "exists but is not a symlink: $link"
      else
        actual_target="$(readlink "$link")"
        expected_target="$agent_file"
        if [[ -e "$actual_target" ]]; then
          actual_resolved="$(_resolve_path "$actual_target")"
        else
          actual_resolved="$actual_target"
        fi
        expected_resolved="$(_resolve_path "$expected_target")"
        if [[ "$actual_resolved" != "$expected_resolved" ]]; then
          add_issue "agents" "wrong_target" "$agent_name" \
            "points to $actual_target, expected $expected_target"
        fi
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Check 6: Instructions file freshness (CLAUDE.md/AGENTS.md, harness-specific)
# Skipped when agent config-disabled (empty region is healthy) and on
# harnesses with no instructions surface (n/a). The component name
# remains "claude_md" for backward compatibility with JSON consumers; the
# artifact label echoes the resolved instructions path so opencode/codex
# operators see the right file name.
# ---------------------------------------------------------------------------
CHECKED+=("claude_md")
if [[ "$AGENT_CONFIG_DISABLED" -eq 0 && -f "$LORE_REPO_DIR/scripts/assemble-claude-md.sh" ]]; then
  if [[ -z "$HARNESS_INSTRUCTIONS_FILE" ]]; then
    add_issue "claude_md" "n/a" "instructions" "active harness exposes no instructions file"
  elif ! bash "$LORE_REPO_DIR/scripts/assemble-claude-md.sh" --check > /dev/null 2>&1; then
    add_issue "claude_md" "stale" "$HARNESS_INSTRUCTIONS_FILE" \
      "assembled instructions file is out of date; run: lore assemble"
  fi
fi

# ---------------------------------------------------------------------------
# Check 7: Expected lore hook commands in the harness's settings file (D4)
# Settings shape is harness-specific: claude-code uses ~/.claude/settings.json
# (JSON), codex uses ~/.codex/config.toml (TOML — different parser needed).
# Today the JSON path covers claude-code and opencode; codex (and any other
# harness whose settings file is non-JSON or unsupported) yields n/a until
# T28 wires the per-harness settings/permissions installer. Doctor surfaces
# n/a in that case rather than emitting "missing" against every expected hook.
# ---------------------------------------------------------------------------
CHECKED+=("hooks")

# The canonical list of expected lore hook commands, without the framework
# prefix the adapters emit (mirrors adapters/hooks/<framework>.sh).
EXPECTED_HOOK_SCRIPTS=(
  "bash ~/.lore/scripts/auto-reindex.sh"
  "bash ~/.lore/scripts/load-knowledge.sh"
  "bash ~/.lore/scripts/load-work.sh"
  "bash ~/.lore/scripts/load-threads.sh"
  "python3 ~/.lore/scripts/extract-session-digest.py"
  "bash ~/.lore/scripts/pre-compact.sh"
  "bash ~/.lore/scripts/task-completed-capture-check.sh"
  "bash ~/.lore/scripts/guard-work-writes.sh"
)

ACTIVE_FRAMEWORK=$(resolve_active_framework 2>/dev/null || true)

# Every adapter-emitted hook command carries `LORE_FRAMEWORK=<harness> ` so the
# handler resolves its own harness rather than whichever one wrote framework.json
# last. The expected strings must carry it too, or a correct install reads as
# drift. Comparison stays exact-match — a prefix-less command in the settings
# file is precisely the misrouting this check should surface.
EXPECTED_HOOK_COMMANDS=()
for _expected_script in "${EXPECTED_HOOK_SCRIPTS[@]}"; do
  if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
    EXPECTED_HOOK_COMMANDS+=("LORE_FRAMEWORK=$ACTIVE_FRAMEWORK $_expected_script")
  else
    EXPECTED_HOOK_COMMANDS+=("$_expected_script")
  fi
done
unset _expected_script
GUIDANCE_HOOK_SUPPORT="none"
if [[ -n "$ACTIVE_FRAMEWORK" ]]; then
  GUIDANCE_HOOK_SUPPORT=$(framework_capability native_dispatch_guidance_hook "$ACTIVE_FRAMEWORK" 2>/dev/null || echo "none")
fi

if [[ "$GUIDANCE_HOOK_SUPPORT" == "full" && "$ACTIVE_FRAMEWORK" == "claude-code" ]]; then
  EXPECTED_HOOK_COMMANDS+=(
    "LORE_FRAMEWORK=claude-code bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook claude-code"
  )
fi

# Harnesses without a settings surface (or with a non-JSON settings file
# that the JSON parser cannot read) yield a single n/a issue. Operators on
# those harnesses should consult `lore framework status` / `lore framework
# doctor` for the per-harness installer's verdict.
if [[ "$GUIDANCE_HOOK_SUPPORT" == "full" && "$ACTIVE_FRAMEWORK" == "codex" ]]; then
  expected_guidance_command="LORE_FRAMEWORK=codex bash ~/.lore/scripts/validate-dispatch-guidance.sh --hook codex"
  if [[ ! -f "$HARNESS_SETTINGS_FILE" ]]; then
    add_issue "hooks" "missing" "$expected_guidance_command" "$HARNESS_SETTINGS_FILE not found"
  else
    installed_guidance_commands="$(python3 - "$HARNESS_SETTINGS_FILE" <<'PYEOF' 2>/dev/null || true
import json, re, sys
try:
    import tomllib  # Python 3.11+
except ImportError:
    tomllib = None
if tomllib is not None:
    with open(sys.argv[1], "rb") as f:
        settings = tomllib.load(f)
    for entries in settings.get("hooks", {}).values():
        for entry in entries:
            command = entry.get("command")
            if command:
                print(command)
else:
    # Python 3.9 and 3.10 ship no TOML parser. The lore-managed block writes
    # each hook as a command key holding a TOML basic string (see
    # adapters/codex/hooks.sh); basic strings escape exactly as JSON strings
    # do, so reading those lines finds every lore command. Quote characters
    # are spelled as \x22 here because bash 3.2 miscounts quotes inside a
    # heredoc nested in command substitution.
    with open(sys.argv[1], encoding="utf-8") as f:
        for line in f:
            m = re.match(r"\s*command\s*=\s*(\x22(?:[^\x22\\]|\\.)*\x22)\s*(#.*)?$", line)
            if m:
                print(json.loads(m.group(1)))
PYEOF
)"
    if ! echo "$installed_guidance_commands" | grep -qxF "$expected_guidance_command"; then
      add_issue "hooks" "missing" "$expected_guidance_command" \
        "dispatch-guidance hook command not found in $HARNESS_SETTINGS_FILE"
    fi
  fi
elif [[ -z "$HARNESS_SETTINGS_FILE" || "$HARNESS_SETTINGS_FILE" != *.json ]]; then
  add_issue "hooks" "n/a" "settings" \
    "active harness has no JSON settings file (was: ${HARNESS_SETTINGS_FILE:-unsupported})"
elif [[ "$PYTHON_OK" -eq 0 ]]; then
  :  # cannot read the settings file without python3; Check 0 reports why
elif [[ ! -f "$HARNESS_SETTINGS_FILE" ]]; then
  for cmd in "${EXPECTED_HOOK_COMMANDS[@]}"; do
    add_issue "hooks" "missing" "$cmd" "$HARNESS_SETTINGS_FILE not found"
  done
else
  installed_commands="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
for hook_type, entries in hooks.items():
    for entry in entries:
        for h in entry.get('hooks', []):
            cmd = h.get('command', '')
            if cmd:
                print(cmd)
" "$HARNESS_SETTINGS_FILE" 2>/dev/null || echo "")"

  for cmd in "${EXPECTED_HOOK_COMMANDS[@]}"; do
    if ! echo "$installed_commands" | grep -qxF "$cmd"; then
      add_issue "hooks" "missing" "$cmd" "hook command not found in $HARNESS_SETTINGS_FILE"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Check 8: Role config files parse and contain a valid role value
# Mirrors lib.sh::resolve_role precedence (per-repo, then user-level), but
# surfaces malformed configs that resolve_role silently falls through on.
# Path resolution uses ROLE_CONFIG_DATA_DIR (snapshot of caller's
# LORE_DATA_DIR before this script's installation-layout block clobbered it).
# ---------------------------------------------------------------------------
CHECKED+=("role_config")

_check_role_config() {
  local config_file="$1"
  local artifact_label="$2"
  [[ -f "$config_file" ]] || return 0
  [[ "$PYTHON_OK" -eq 1 ]] || return 0
  local result
  result=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    print("unparseable")
    sys.exit(0)
r = d.get("role")
if r in ("maintainer", "contributor"):
    print("ok")
elif r is None:
    print("ok")
else:
    print("invalid:" + str(r))
' "$config_file" 2>/dev/null) || result="unparseable"
  case "$result" in
    ok) return 0 ;;
    unparseable)
      add_issue "role_config" "malformed" "$artifact_label" \
        "config file is not valid JSON: $config_file" \
        "repair the JSON syntax in $config_file" ;;
    invalid:*)
      local bad_role="${result#invalid:}"
      add_issue "role_config" "malformed" "$artifact_label" \
        "role value '$bad_role' not in {maintainer, contributor}: $config_file" \
        "set \"role\" to \"maintainer\" or \"contributor\" in $config_file" ;;
  esac
}

# Per-repo config: $KDIR/config.json (resolve-repo.sh may exit non-zero when
# agent is disabled or outside a repo — both cases are silent skips).
_REPO_KDIR=$("$SCRIPT_DIR/resolve-repo.sh" 2>/dev/null) || _REPO_KDIR=""
if [[ -n "$_REPO_KDIR" ]]; then
  _check_role_config "$_REPO_KDIR/config.json" "$_REPO_KDIR/config.json"
fi

# User-level fallback: $ROLE_CONFIG_DATA_DIR/config/settings.json
_check_role_config "$ROLE_CONFIG_DATA_DIR/config/settings.json" \
  "$ROLE_CONFIG_DATA_DIR/config/settings.json"

# ---------------------------------------------------------------------------
# Check 9: Unified settings.json validates against adapters/settings.schema.json
# Strict full-document validation (D7) via scripts/lore_schema.py, a stdlib
# validator, so the check runs on any python3 without installing anything.
# ---------------------------------------------------------------------------
CHECKED+=("settings_schema")
doctor_validate_settings_schema() {
  local settings_file="$ROLE_CONFIG_DATA_DIR/config/settings.json"
  local schema_file="$LORE_REPO_DIR/adapters/settings.schema.json"

  if [[ ! -f "$settings_file" ]]; then
    return 0
  fi
  if [[ ! -f "$schema_file" ]]; then
    add_issue "settings_schema" "missing" "$schema_file" \
      "schema file not found: $schema_file"
    return 0
  fi

  [[ "$PYTHON_OK" -eq 1 ]] || return 0

  # Capture stdout under `set -e`: || rc=$? keeps the validator's non-zero
  # exit (1 = violation, 2 = unreadable input or unsupported schema) from
  # aborting the script.
  local validation_output rc=0
  validation_output=$(python3 "$LORE_REPO_DIR/scripts/lore_schema.py" "$schema_file" "$settings_file" 2>&1) || rc=$?
  if [[ $rc -eq 1 ]]; then
    add_issue "settings_schema" "schema_violation" "$settings_file" \
      "$validation_output" \
      "edit $settings_file at the path named above (bash $LORE_REPO_DIR/install.sh repairs keys it manages)"
  elif [[ $rc -ne 0 ]]; then
    add_issue "settings_schema" "malformed" "$settings_file" \
      "$validation_output" \
      "repair $settings_file, or move it aside and re-run bash $LORE_REPO_DIR/install.sh"
  fi
  return 0
}
doctor_validate_settings_schema

# ---------------------------------------------------------------------------
# Check 10: Aggregate fallback snapshots across stacks (D7)
# Each stack reports its deterministic snapshot of "<file>::<key>" pairs the
# loader would currently fall back to read because the unified key is absent.
# Empty across all stacks means cleanup (D4 phase 3) is unblocked.
# ---------------------------------------------------------------------------
CHECKED+=("settings_fallbacks")
doctor_aggregate_fallbacks() {
  local settings_sh="$LORE_REPO_DIR/scripts/settings.sh"
  local pairs=""

  if [[ -x "$settings_sh" ]]; then
    local bash_pairs
    bash_pairs=$(LORE_DATA_DIR="$ROLE_CONFIG_DATA_DIR" bash "$settings_sh" fallbacks 2>/dev/null || true)
    if [[ -n "$bash_pairs" ]]; then
      pairs="$bash_pairs"
    fi
  fi

  if [[ "$PYTHON_OK" -eq 1 ]]; then
    local py_pairs
    py_pairs=$(LORE_DATA_DIR="$ROLE_CONFIG_DATA_DIR" \
      PYTHONPATH="$LORE_REPO_DIR/scripts" \
      python3 -c "
import lore_settings
for f, k in lore_settings.fallbacks():
    print(f'{f}::{k}')
" 2>/dev/null || true)
    if [[ -n "$py_pairs" ]]; then
      if [[ -n "$pairs" ]]; then
        pairs="$pairs
$py_pairs"
      else
        pairs="$py_pairs"
      fi
    fi
  fi

  # T4: Go fallback snapshot. When tui/internal/config/settings.go exposes a
  # `Fallbacks()` accessor wired through lore-tui or a sibling CLI, aggregate
  # it here. Until then, skip gracefully.
  # TODO(T4): plumb the Go snapshot once the loader lands.

  if [[ -n "$pairs" ]]; then
    while IFS= read -r pair; do
      [[ -z "$pair" ]] && continue
      local legacy_file="${pair%%::*}"
      local key="${pair#*::}"
      add_issue "settings_fallbacks" "fallback" "$pair" \
        "settings.json is missing key $key — re-run install or hand-merge from $legacy_file"
    done < <(printf '%s\n' "$pairs" | sort -u)
  fi
  return 0
}
doctor_aggregate_fallbacks

# ---------------------------------------------------------------------------
# Determine overall status
# ---------------------------------------------------------------------------
# Optional prerequisites are informational: they never make the install
# "drift", never wake --quiet, and never set a failing exit status.
ACTION_COUNT=0
OPTIONAL_COUNT=0
for _issue in ${ISSUES[@]+"${ISSUES[@]}"}; do
  _split_issue "$_issue"
  if [[ "$I_TYPE" == optional ]]; then
    OPTIONAL_COUNT=$((OPTIONAL_COUNT + 1))
  else
    ACTION_COUNT=$((ACTION_COUNT + 1))
  fi
done
unset _issue
if [[ "$ACTION_COUNT" -eq 0 ]]; then
  STATUS="clean"
else
  STATUS="drift"
fi

# ---------------------------------------------------------------------------
# Update throttle timestamp after a successful (clean) --quiet run
# ---------------------------------------------------------------------------
if [[ "$MODE_QUIET" -eq 1 && "$STATUS" == "clean" ]]; then
  touch "$TIMESTAMP_FILE"
fi

# ---------------------------------------------------------------------------
# Next steps: prerequisite records as prereqs.sh produced them (they carry the
# package name, so installs batch into one command), plus one record per
# distinct fix for everything else, so thirty missing symlinks read as one
# step. n/a issues have nothing to do and are left out.
# ---------------------------------------------------------------------------
build_digest_records() {
  local -a g_fix=() g_count=() g_components=() g_first=()
  local issue i found n
  for issue in ${ISSUES[@]+"${ISSUES[@]}"}; do
    _split_issue "$issue"
    [[ "$I_COMPONENT" == prerequisites || "$I_TYPE" == n/a || -z "$I_FIX" ]] && continue
    found=-1
    n=${#g_fix[@]}
    for (( i = 0; i < n; i++ )); do
      if [[ "${g_fix[$i]}" == "$I_FIX" ]]; then found=$i; break; fi
    done
    if [[ "$found" -lt 0 ]]; then
      g_fix+=("$I_FIX"); g_count+=(1); g_components+=("$I_COMPONENT")
      g_first+=("$I_COMPONENT: ${I_DETAIL//$'\n'/; }")
    else
      g_count[$found]=$(( ${g_count[$found]} + 1 ))
      case ", ${g_components[$found]}, " in
        *", $I_COMPONENT, "*) ;;
        *) g_components[$found]="${g_components[$found]}, $I_COMPONENT" ;;
      esac
    fi
  done
  [[ -n "$PREREQ_RECORDS" ]] && printf '%s\n' "$PREREQ_RECORDS"
  n=${#g_fix[@]}
  for (( i = 0; i < n; i++ )); do
    local detail="${g_first[$i]}"
    if [[ "${g_count[$i]}" -gt 1 ]]; then
      detail="${g_count[$i]} installation issues (${g_components[$i]}), e.g. ${g_first[$i]}"
    fi
    printf 'required%sinstall%s%s%s%s%s\n' "$US" "$US" "$detail" "$US" "$US" "${g_fix[$i]}"
  done
}

print_next_steps() {
  local records
  records=$(build_digest_records)
  lore_render_digest "$records" || true
  if [[ "$ACTION_COUNT" -eq 0 && "$OPTIONAL_COUNT" -gt 0 ]]; then
    echo "  Lore is ready. The optional items above unlock the features they name."
    echo ""
  fi
  echo "  Re-check any time with: lore doctor"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# _json_str <s> — a JSON string literal, for when python3 is unusable.
_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

if [[ "$MODE_JSON" -eq 1 ]]; then
  # Build JSON output (D5 schema). Each issue gains "fix": the command that
  # clears it (null for n/a).
  if [[ "$PYTHON_OK" -eq 1 ]]; then
    _resolved=()
    for _issue in ${ISSUES[@]+"${ISSUES[@]}"}; do
      _split_issue "$_issue"
      _resolved+=("${I_COMPONENT}${US}${I_TYPE}${US}${I_ARTIFACT}${US}${I_DETAIL}${US}${I_FIX}")
    done
    python3 -c "
import json, sys

status, checked_raw, agent_state = sys.argv[1], sys.argv[2], sys.argv[3]
issues = []
for raw in sys.argv[4:]:
    component, type_, artifact, detail, fix = raw.split('\x1f', 4)
    issues.append({
        'component': component,
        'type': type_,
        'artifact': artifact,
        'detail': detail,
        'fix': fix or None,
    })

# Deduplicate checked while preserving order
checked = list(dict.fromkeys(c for c in checked_raw.split(',') if c))

print(json.dumps({
    'status': status,
    'agent_state': agent_state,
    'issues': issues,
    'checked': checked,
}, indent=2))
" "$STATUS" "$(IFS=','; echo "${CHECKED[*]}")" "$AGENT_STATE" ${_resolved[@]+"${_resolved[@]}"}
  else
    # No usable python3 (Check 0 says why): emit the same shape from bash.
    printf '{\n  "status": %s,\n  "agent_state": %s,\n  "issues": [' "$(_json_str "$STATUS")" "$(_json_str "$AGENT_STATE")"
    _sep=""
    for _issue in ${ISSUES[@]+"${ISSUES[@]}"}; do
      _split_issue "$_issue"
      printf '%s\n    {"component": %s, "type": %s, "artifact": %s, "detail": %s, "fix": %s}' "$_sep" \
        "$(_json_str "$I_COMPONENT")" "$(_json_str "$I_TYPE")" "$(_json_str "$I_ARTIFACT")" \
        "$(_json_str "$I_DETAIL")" "$(if [[ -n "$I_FIX" ]]; then _json_str "$I_FIX"; else echo null; fi)"
      _sep=","
    done
    printf '\n  ],\n  "checked": ['
    _sep=""
    for _c in "${CHECKED[@]}"; do printf '%s%s' "$_sep" "$(_json_str "$_c")"; _sep=", "; done
    printf ']\n}\n'
  fi
  exit $(( ACTION_COUNT > 0 ? 1 : 0 ))
fi

if [[ "$MODE_QUIET" -eq 1 ]]; then
  if [[ "$STATUS" == "clean" ]]; then
    exit 0
  else
    echo "lore doctor: $ACTION_COUNT issue(s) detected — run 'lore doctor' for details"
    echo "  agent: $AGENT_STATE"
    exit 1
  fi
fi

if [[ "$MODE_DIGEST" -eq 1 ]]; then
  draw_separator "lore: next steps"
  echo ""
  if [[ "$ACTION_COUNT" -eq 0 && "$OPTIONAL_COUNT" -eq 0 ]]; then
    echo "  Everything checks out: prerequisites are met and the installation is verified."
    echo ""
  else
    print_next_steps
    echo ""
  fi
  draw_separator
  exit $(( ACTION_COUNT > 0 ? 1 : 0 ))
fi

# ---------------------------------------------------------------------------
# Verbose (default) output: every issue with its fix, then the deduplicated
# next steps.
# ---------------------------------------------------------------------------
draw_separator "lore doctor"
echo ""
echo "  agent: $AGENT_STATE"
echo ""

if [[ "$ACTION_COUNT" -eq 0 && "$OPTIONAL_COUNT" -eq 0 ]]; then
  echo "  All checks passed. Installation is up to date."
  echo ""
  draw_separator
  exit 0
fi

print_issue() {
  _split_issue "$1"
  echo "  [$I_TYPE] [$I_COMPONENT] $I_ARTIFACT"
  printf '%s\n' "$I_DETAIL" | sed 's/^/    /'
  if [[ -n "$I_FIX" ]]; then
    echo "    fix: $I_FIX"
  fi
}

if [[ "$ACTION_COUNT" -gt 0 ]]; then
  echo "  Found $ACTION_COUNT issue(s):"
  echo ""
  for issue_str in "${ISSUES[@]}"; do
    _split_issue "$issue_str"
    [[ "$I_TYPE" == optional ]] || print_issue "$issue_str"
  done
  echo ""
else
  echo "  All checks passed. Installation is up to date."
  echo ""
fi

if [[ "$OPTIONAL_COUNT" -gt 0 ]]; then
  echo "  Optional — lore works without these; the feature each names does not:"
  echo ""
  for issue_str in "${ISSUES[@]}"; do
    _split_issue "$issue_str"
    [[ "$I_TYPE" != optional ]] || print_issue "$issue_str"
  done
  echo ""
fi

echo "  Next steps:"
echo ""
print_next_steps
echo ""
draw_separator
exit $(( ACTION_COUNT > 0 ? 1 : 0 ))
