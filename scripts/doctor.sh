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
# Resolve repo directory from the ~/.lore/scripts symlink
# ---------------------------------------------------------------------------
LORE_SCRIPTS_LINK="$HOME/.lore/scripts"
LORE_DATA_DIR="$HOME/.lore"
CLAUDE_DIR="$HOME/.claude"

if [[ -L "$LORE_SCRIPTS_LINK" ]]; then
  LORE_REPO_DIR="$(cd "$(dirname "$(readlink "$LORE_SCRIPTS_LINK")")" && pwd)"
else
  # Fallback: assume we're running from within the repo
  LORE_REPO_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
fi

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
# Check 4: Skills symlinks
# ---------------------------------------------------------------------------
CHECKED+=("skills")
if [[ -d "$LORE_REPO_DIR/skills" ]]; then
  for skill_dir in "$LORE_REPO_DIR"/skills/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    link="$CLAUDE_DIR/skills/$skill_name"
    if [[ ! -e "$link" && ! -L "$link" ]]; then
      add_issue "skills" "missing" "$skill_name" "symlink missing: $link"
    elif [[ ! -L "$link" ]]; then
      add_issue "skills" "wrong_target" "$skill_name" "exists but is not a symlink: $link"
    else
      actual_target="$(readlink "$link")"
      expected_target="$skill_dir"
      # Resolve to canonical for comparison
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

# ---------------------------------------------------------------------------
# Check 5: Agents symlinks (only lore-managed repo agents/*.md)
# ---------------------------------------------------------------------------
CHECKED+=("agents")
if [[ -d "$LORE_REPO_DIR/agents" ]]; then
  for agent_file in "$LORE_REPO_DIR"/agents/*.md; do
    [[ -f "$agent_file" ]] || continue
    agent_name="$(basename "$agent_file")"
    link="$CLAUDE_DIR/agents/$agent_name"
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

# ---------------------------------------------------------------------------
# Check 6: CLAUDE.md freshness via assemble-claude-md.sh --check
# ---------------------------------------------------------------------------
CHECKED+=("claude_md")
if [[ -f "$LORE_REPO_DIR/scripts/assemble-claude-md.sh" ]]; then
  if ! bash "$LORE_REPO_DIR/scripts/assemble-claude-md.sh" --check > /dev/null 2>&1; then
    add_issue "claude_md" "stale" "~/.claude/CLAUDE.md" \
      "assembled CLAUDE.md is out of date; run: lore assemble"
  fi
fi

# ---------------------------------------------------------------------------
# Check 7: Expected lore hook commands in settings.json (D4)
# ---------------------------------------------------------------------------
CHECKED+=("hooks")
SETTINGS_JSON="$CLAUDE_DIR/settings.json"

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

if [[ ! -f "$SETTINGS_JSON" ]]; then
  # If settings.json doesn't exist, all hooks are missing
  for cmd in "${EXPECTED_HOOK_COMMANDS[@]}"; do
    add_issue "hooks" "missing" "$cmd" "settings.json not found"
  done
else
  # Extract all command values from settings.json hooks
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
" "$SETTINGS_JSON" 2>/dev/null || echo "")"

  for cmd in "${EXPECTED_HOOK_COMMANDS[@]}"; do
    if ! echo "$installed_commands" | grep -qxF "$cmd"; then
      add_issue "hooks" "missing" "$cmd" "hook command not found in settings.json"
    fi
  done
fi

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
    'issues': issues,
    'checked': checked_deduped,
}
print(json.dumps(output, indent=2))
" "$STATUS" "$(printf '%s\n' "${ISSUES[@]+"${ISSUES[@]}"}")" "$(IFS=','; echo "${CHECKED[*]}")"
  exit $(( ISSUE_COUNT > 0 ? 1 : 0 ))
fi

if [[ "$MODE_QUIET" -eq 1 ]]; then
  if [[ "$STATUS" == "clean" ]]; then
    exit 0
  else
    echo "lore doctor: $ISSUE_COUNT issue(s) detected — run 'lore doctor' for details"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Verbose (default) output
# ---------------------------------------------------------------------------
draw_separator "lore doctor"
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
