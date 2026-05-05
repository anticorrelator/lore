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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE_JSON=0
MODE_QUIET=0

for arg in "$@"; do
  case "$arg" in
    --json)    MODE_JSON=1 ;;
    --quiet)   MODE_QUIET=1 ;;
    --help|-h)
      echo "Usage: lore doctor [--json] [--quiet]" >&2
      echo "  Check installation for drift between repo source and installed state." >&2
      echo "  --json    Output structured JSON (D5 schema)" >&2
      echo "  --quiet   Silent when clean; one-line summary when drifted" >&2
      echo "            Throttled: skips checks if last run was <24h ago" >&2
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
# Each issue is stored as a pipe-delimited string: component|type|artifact|detail
ISSUES=()
CHECKED=()

add_issue() {
  local component="$1"
  local type="$2"
  local artifact="$3"
  local detail="$4"
  ISSUES+=("${component}|${type}|${artifact}|${detail}")
}

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

# The canonical list of expected lore hook commands (mirrors install.sh)
EXPECTED_HOOK_COMMANDS=(
  "bash ~/.lore/scripts/auto-reindex.sh"
  "bash ~/.lore/scripts/load-knowledge.sh"
  "bash ~/.lore/scripts/load-work.sh"
  "bash ~/.lore/scripts/load-threads.sh"
  "python3 ~/.lore/scripts/extract-session-digest.py"
  "bash ~/.lore/scripts/pre-compact.sh"
  "python3 ~/.lore/scripts/stop-novelty-check.py"
  "python3 ~/.lore/scripts/check-plan-persistence.py"
  "bash ~/.lore/scripts/task-completed-capture-check.sh"
  "bash ~/.lore/scripts/guard-work-writes.sh"
)

# Harnesses without a settings surface (or with a non-JSON settings file
# that the JSON parser cannot read) yield a single n/a issue. Operators on
# those harnesses should consult `lore framework status` / `lore framework
# doctor` for the per-harness installer's verdict.
if [[ -z "$HARNESS_SETTINGS_FILE" || "$HARNESS_SETTINGS_FILE" != *.json ]]; then
  add_issue "hooks" "n/a" "settings" \
    "active harness has no JSON settings file (was: ${HARNESS_SETTINGS_FILE:-unsupported})"
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
        "config file is not valid JSON: $config_file" ;;
    invalid:*)
      local bad_role="${result#invalid:}"
      add_issue "role_config" "malformed" "$artifact_label" \
        "role value '$bad_role' not in {maintainer, contributor}: $config_file" ;;
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
# Determine overall status
# ---------------------------------------------------------------------------
ISSUE_COUNT="${#ISSUES[@]}"
if [[ "$ISSUE_COUNT" -eq 0 ]]; then
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
# Output
# ---------------------------------------------------------------------------

if [[ "$MODE_JSON" -eq 1 ]]; then
  # Build JSON output (D5 schema)
  python3 -c "
import json, sys

status = sys.argv[1]
issues_raw = sys.argv[2]
checked_raw = sys.argv[3]

issues = []
if issues_raw:
    for line in issues_raw.strip().split('\n'):
        parts = line.split('|', 3)
        if len(parts) == 4:
            issues.append({
                'component': parts[0],
                'type': parts[1],
                'artifact': parts[2],
                'detail': parts[3],
            })

checked = [c for c in checked_raw.split(',') if c]
# Deduplicate while preserving order
seen = set()
checked_deduped = []
for c in checked:
    if c not in seen:
        seen.add(c)
        checked_deduped.append(c)

output = {
    'status': status,
    'agent_state': sys.argv[4],
    'issues': issues,
    'checked': checked_deduped,
}
print(json.dumps(output, indent=2))
" "$STATUS" "$(printf '%s\n' "${ISSUES[@]+"${ISSUES[@]}"}")" "$(IFS=','; echo "${CHECKED[*]}")" "$AGENT_STATE"
  exit $(( ISSUE_COUNT > 0 ? 1 : 0 ))
fi

if [[ "$MODE_QUIET" -eq 1 ]]; then
  if [[ "$STATUS" == "clean" ]]; then
    exit 0
  else
    echo "lore doctor: $ISSUE_COUNT issue(s) detected — run 'lore doctor' for details"
    echo "  agent: $AGENT_STATE"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Verbose (default) output
# ---------------------------------------------------------------------------
draw_separator "lore doctor"
echo ""
echo "  agent: $AGENT_STATE"
echo ""

if [[ "$STATUS" == "clean" ]]; then
  echo "  All checks passed. Installation is up to date."
  echo ""
  draw_separator
  exit 0
fi

echo "  Found $ISSUE_COUNT issue(s):"
echo ""

for issue_str in "${ISSUES[@]}"; do
  IFS='|' read -r component type artifact detail <<< "$issue_str"
  case "$type" in
    missing)      marker="[missing]" ;;
    wrong_target) marker="[wrong_target]" ;;
    stale)        marker="[stale]" ;;
    *)            marker="[$type]" ;;
  esac
  echo "  $marker [$component] $artifact"
  echo "    $detail"
done

echo ""
echo "  Run 'bash install.sh' to repair installation."
echo ""
draw_separator
exit 1
