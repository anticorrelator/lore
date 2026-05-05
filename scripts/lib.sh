#!/usr/bin/env bash
# lib.sh — Shared utility functions for lore scripts and skills
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Or from skills: source ~/.lore/scripts/lib.sh
#
# NOTE: This is a library file. Do NOT add set -euo pipefail here.
# Callers set their own shell options.

LORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- die ---
# Print an error message to stderr and exit with status 1.
# Usage: die "something went wrong"
die() {
  echo "Error: $*" >&2
  exit 1
}

# --- json_error ---
# Print a JSON error object to stdout and exit with status 1.
# The message is properly escaped for JSON (handles quotes, backslashes, newlines).
# Usage: json_error "something went wrong"
# Output: {"error": "something went wrong"}
json_error() {
  local msg="$1"
  local escaped
  escaped=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")')
  printf '{"error": %s}\n' "$escaped"
  exit 1
}

# --- json_output ---
# Print a JSON string to stdout and exit with status 0.
# The caller is responsible for providing valid JSON.
# Usage: json_output '{"key": "value"}'
json_output() {
  printf '%s\n' "$1"
  exit 0
}

# --- json_field ---
# Extract a JSON string field value using grep/sed.
# Usage: value=$(json_field "title" "$file")
# Returns the first match of "key": "value" from the given file.
json_field() {
  local key="$1"
  local file="$2"
  grep "\"$key\"" "$file" | sed 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/' | head -1
}

# --- slugify ---
# Convert a string to a URL-friendly kebab-case slug.
# Strips common stopwords to produce more compact slugs.
# Usage: slug=$(slugify "My Work Item Name")
# Output: "my-work-item-name"
MAX_SLUG_LENGTH=50
slugify() {
  local input="$1"
  # Flatten newlines/tabs to spaces before the line-oriented sed pipeline below;
  # otherwise embedded newlines survive into the slug and produce invalid filenames.
  input=$(printf '%s' "$input" | tr '\n\t' '  ' | tr -s ' ')
  local lower
  lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  local stripped
  stripped=$(echo "$lower" \
    | sed -E 's/(^| )(the|a|an|and|or|but|with|for|via|from|into|after|before|between|through|about|during|using|based)( |$)/ /g' \
    | sed -E 's/(^| )(the|a|an|and|or|but|with|for|via|from|into|after|before|between|through|about|during|using|based)( |$)/ /g')
  # Fall back to original if stopword removal left only whitespace
  local check
  check=$(echo "$stripped" | tr -d '[:space:]')
  if [[ -z "$check" ]]; then
    stripped="$lower"
  fi
  echo "$stripped" \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-$MAX_SLUG_LENGTH \
    | sed 's/-*$//'
}

# --- resolve_knowledge_dir ---
# Resolve the knowledge store directory for the current project.
# Usage: KDIR=$(resolve_knowledge_dir)
resolve_knowledge_dir() {
  "$LORE_LIB_DIR/resolve-repo.sh"
}

# --- resolve_followup_dir ---
# Resolve the on-disk directory for a followup id, checking active then archive.
# Requires FOLLOWUPS_DIR to be set by the caller (typically "$KNOWLEDGE_DIR/_followups").
# Echoes the absolute path on stdout; on miss, writes a diagnostic to stderr and returns non-zero.
# Usage: dir=$(resolve_followup_dir "$id") || exit 1
resolve_followup_dir() {
  local id="$1"
  if [[ -z "$id" ]]; then
    echo "[followup] Error: resolve_followup_dir requires an id" >&2
    return 1
  fi
  if [[ -z "${FOLLOWUPS_DIR:-}" ]]; then
    echo "[followup] Error: FOLLOWUPS_DIR is not set" >&2
    return 1
  fi
  if [[ -d "$FOLLOWUPS_DIR/$id" ]]; then
    echo "$FOLLOWUPS_DIR/$id"
    return 0
  fi
  if [[ -d "$FOLLOWUPS_DIR/_archive/$id" ]]; then
    echo "$FOLLOWUPS_DIR/_archive/$id"
    return 0
  fi
  echo "[followup] Error: followup '$id' not found in $FOLLOWUPS_DIR or $FOLLOWUPS_DIR/_archive" >&2
  return 1
}

# --- resolve_role ---
# Resolve the operator role for the current repo: "maintainer" or "contributor".
# Precedence (first match wins):
#   1. $LORE_ROLE env var (session override — accepts "maintainer" or "contributor")
#   2. Per-repo config: $KDIR/config.json → .role
#      (where $KDIR = resolve_knowledge_dir(), i.e.
#       ${LORE_DATA_DIR:-$HOME/.lore}/repos/<normalized-repo>/config.json)
#   3. User-level fallback: ${LORE_DATA_DIR:-$HOME/.lore}/config/settings.json → .role
#   4. Default: "contributor"
#
# Why contributor-default: Phase 9 role gating (task-54) restricts /evolve mutation,
# pool import/aggregate, and other maintainer verbs to the maintainer role. Any
# operator whose environment is not explicitly configured should see the safer
# contributor path — the one that produces exportable retro bundles but never
# mutates shared templates. Opting in to maintainer is an explicit act (task-59
# bootstrap writes {role: maintainer} into the repo's config.json when the
# operator is indeed the maintainer of this checkout).
#
# Malformed config: if a config file exists but cannot be parsed or contains a
# role value outside {"maintainer","contributor"}, the function falls through
# to the next precedence level rather than failing. Rationale: role resolution
# is called on every /evolve and /retro invocation; a single malformed config
# should not lock the operator out of their workflow. Surfacing the bad config
# is the responsibility of a dedicated `lore doctor` check, not this hot-path
# resolver.
#
# Usage: role=$(resolve_role)
# Output: "maintainer" | "contributor" on stdout (always exactly one of the two).
# Returns: 0 always.
resolve_role() {
  # 1. Env var override.
  if [[ "${LORE_ROLE:-}" == "maintainer" || "${LORE_ROLE:-}" == "contributor" ]]; then
    echo "$LORE_ROLE"
    return 0
  fi

  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"

  # 2. Per-repo config.json. Use resolve_knowledge_dir for the path so the
  #    per-repo config sits alongside _work/, _scorecards/, etc. — same
  #    normalization (including the local/ fallback for unpublished repos).
  local kdir role
  if kdir=$("$LORE_LIB_DIR/resolve-repo.sh" 2>/dev/null) && [[ -n "$kdir" ]]; then
    local repo_config="$kdir/config.json"
    if [[ -f "$repo_config" ]]; then
      role=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    r = d.get("role")
    if r in ("maintainer", "contributor"):
        print(r)
except Exception:
    pass
' "$repo_config" 2>/dev/null)
      if [[ -n "$role" ]]; then
        echo "$role"
        return 0
      fi
    fi
  fi

  # 3. User-level fallback: ~/.lore/config/settings.json.
  local settings="$data_dir/config/settings.json"
  if [[ -f "$settings" ]]; then
    role=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    r = d.get("role")
    if r in ("maintainer", "contributor"):
        print(r)
except Exception:
    pass
' "$settings" 2>/dev/null)
    if [[ -n "$role" ]]; then
      echo "$role"
      return 0
    fi
  fi

  # 4. Default.
  echo "contributor"
  return 0
}

# --- get_git_branch ---
# Get the current git branch name, or empty string if not in a git repo.
# Usage: branch=$(get_git_branch)
get_git_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo ""
}

# --- captured_at_branch ---
# Resolve the current branch name for capture-provenance. Returns the literal
# string "null" when outside a git repo or on detached HEAD — capture must
# always succeed regardless of repo state.
# Usage: branch=$(captured_at_branch)
captured_at_branch() {
  local b
  b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [[ -z "$b" || "$b" == "HEAD" ]]; then
    echo "null"
  else
    echo "$b"
  fi
}

# --- captured_at_sha ---
# Resolve the current HEAD commit SHA for capture-provenance. Returns "null"
# when outside a git repo.
# Usage: sha=$(captured_at_sha)
captured_at_sha() {
  local s
  s=$(git rev-parse HEAD 2>/dev/null || true)
  if [[ -z "$s" ]]; then
    echo "null"
  else
    echo "$s"
  fi
}

# --- captured_at_merge_base_sha ---
# Resolve the merge-base of HEAD against origin/main for capture-provenance.
# Returns "null" when outside a repo, when origin/main doesn't exist, or when
# the merge-base cannot be computed. No network access.
# Usage: mb=$(captured_at_merge_base_sha)
captured_at_merge_base_sha() {
  local mb
  mb=$(git merge-base origin/main HEAD 2>/dev/null || true)
  if [[ -z "$mb" ]]; then
    echo "null"
  else
    echo "$mb"
  fi
}

# --- timestamp_iso ---
# Generate an ISO 8601 UTC timestamp.
# Usage: ts=$(timestamp_iso)
# Output: "2026-02-07T04:30:00Z"
timestamp_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- get_mtime ---
# Get the modification time of a file as Unix epoch seconds.
# Cross-platform: works on both Darwin (macOS) and Linux.
# Usage: mtime=$(get_mtime "$file")
# Output: Unix epoch seconds (e.g., "1707300000"), or "0" on error.
get_mtime() {
  local file="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    stat -f %m "$file" 2>/dev/null || echo "0"
  else
    stat -c %Y "$file" 2>/dev/null || echo "0"
  fi
}

# --- find_lore_config ---
# Walk from a starting directory up to / looking for a .lore.config file.
# Echoes the absolute path to the file and returns 0 if found, returns 1 if not.
# Usage: config_path=$(find_lore_config) && echo "found at $config_path"
#        find_lore_config "/some/start/dir"
find_lore_config() {
  local dir="${1:-$(pwd)}"
  dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
  while true; do
    if [[ -f "$dir/.lore.config" ]]; then
      echo "$dir/.lore.config"
      return 0
    fi
    [[ "$dir" == "/" ]] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

# --- parse_lore_config ---
# Extract a value by key from a .lore.config file.
# Ignores blank lines and lines starting with #.
# Usage: repo=$(parse_lore_config "repo" "/path/to/.lore.config")
# Output: The value after the = sign, with leading/trailing whitespace stripped.
# Returns 0 if key found, 1 if not found or file missing.
parse_lore_config() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 1
  local line value
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Match key= at start of line
    if [[ "$line" == "${key}="* ]]; then
      value="${line#"${key}="}"
      # Strip leading and trailing whitespace
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      echo "$value"
      return 0
    fi
  done < "$file"
  return 1
}

# --- json_array_field ---
# Extract a JSON array field's inner content from a file using awk.
# Handles both single-line ["a","b"] and multi-line arrays.
# Usage: values=$(json_array_field "branches" "$file")
# Output: Inner content of the array with whitespace stripped (e.g., "a","b")
# For display formatting, pipe through: sed 's/"//g; s/,/, /g'
json_array_field() {
  local key="$1"
  local file="$2"
  awk -v key="\"$key\"" '
    $0 ~ key {
      match($0, /\[.*\]/)
      if (RSTART > 0) {
        arr = substr($0, RSTART+1, RLENGTH-2)
        gsub(/[[:space:]]/, "", arr)
        print arr
        next
      }
      collecting = 1
      buf = ""
      next
    }
    collecting && /\]/ {
      buf = buf $0
      gsub(/[[:space:]\]\[]/, "", buf)
      sub(/,$/, "", buf)
      print buf
      collecting = 0
      next
    }
    collecting { buf = buf $0 }
  ' "$file"
}

# --- lore_agent_enabled ---
# Returns 0 (success) if lore agent integration is enabled, non-zero if disabled.
# Checks in priority order:
#   1. LORE_AGENT_DISABLED=1 env var → disabled (returns 1)
#   2. ~/.lore/config/agent.json enabled field → false means disabled (returns 1)
#   3. File absent or enabled=true → enabled (returns 0)
# Usage: lore_agent_enabled || exit 0
lore_agent_enabled() {
  if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
    return 1
  fi
  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/agent.json"
  if [[ -f "$config_file" ]]; then
    if grep -q '"enabled"[[:space:]]*:[[:space:]]*false' "$config_file"; then
      return 1
    fi
  fi
  return 0
}

# --- migrate_claude_args_to_harness_args ---
# One-shot migration helper: if $LORE_DATA_DIR/config/harness-args.json is
# absent and the legacy $LORE_DATA_DIR/config/claude.json exists with a
# valid `.args` array, write a new harness-args.json with the legacy args
# under the `claude-code` key. Records the migration source in the new
# file's `_deprecated_legacy_source` field so callers can detect that the
# legacy file is the upstream and surface the deprecation in `lore status`.
# The legacy claude.json is left in place untouched per Phase 1's
# "deprecation note for one release" contract.
# Idempotent: returns early if harness-args.json already exists or jq is
# unavailable. Silent on missing legacy file (no migration needed).
# Mirrors config.MigrateClaudeArgsToHarnessArgs() in
# tui/internal/config/config.go (T10).
migrate_claude_args_to_harness_args() {
  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local legacy_file="$data_dir/config/claude.json"
  local new_file="$data_dir/config/harness-args.json"

  [[ -f "$new_file" ]] && return 0
  [[ -f "$legacy_file" ]] || return 0
  command -v jq &>/dev/null || return 0
  jq -e '.args | type == "array"' "$legacy_file" &>/dev/null || return 0

  mkdir -p "$(dirname "$new_file")"
  jq --arg src "$legacy_file" \
     '{
        "version": 1,
        "_deprecated_legacy_source": $src,
        "claude-code": { "args": .args }
      }' "$legacy_file" > "$new_file.tmp" && mv "$new_file.tmp" "$new_file"
}

# --- load_harness_args ---
# Print the args to prepend to every harness CLI invocation, one per line.
# Callers: mapfile -t HARNESS_ARGS < <(load_harness_args)
# Optional positional arg: explicit harness key (e.g. `claude-code`,
# `opencode`, `codex`). If omitted, the active framework is resolved via
# resolve_active_framework so the same call site picks up whichever
# harness install.sh persisted.
# Resolution order:
#   1. LORE_HARNESS_ARGS env var (JSON array, requires jq) — applies to
#      whichever harness the caller is reading; preferred for new code.
#   2. LORE_CLAUDE_ARGS env var (legacy alias, only honored when the
#      resolved harness is `claude-code`; logs a one-shot deprecation
#      notice to stderr).
#   3. $LORE_DATA_DIR/config/harness-args.json `[<harness>].args`
#      (canonical multi-harness shape, T8).
#   4. $LORE_DATA_DIR/config/claude.json `.args` (legacy, only honored
#      when the resolved harness is `claude-code`. On-the-fly migration
#      runs via migrate_claude_args_to_harness_args before step 3.)
#   5. built-in default: `--dangerously-skip-permissions` for
#      `claude-code`; nothing (no args) for any other harness, since the
#      flag is Anthropic-specific.
# Mirrors config.LoadHarnessArgs() in tui/internal/config/config.go (T10).
load_harness_args() {
  local harness="${1:-}"
  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local new_file="$data_dir/config/harness-args.json"
  local legacy_file="$data_dir/config/claude.json"

  if [[ -z "$harness" ]]; then
    harness=$(resolve_active_framework) || return 1
  fi

  if command -v jq &>/dev/null; then
    if [[ -n "${LORE_HARNESS_ARGS:-}" ]]; then
      if printf '%s' "$LORE_HARNESS_ARGS" | jq -e 'type == "array"' &>/dev/null; then
        printf '%s' "$LORE_HARNESS_ARGS" | jq -r '.[]'
        return
      fi
    fi

    if [[ "$harness" == "claude-code" && -n "${LORE_CLAUDE_ARGS:-}" ]]; then
      if printf '%s' "$LORE_CLAUDE_ARGS" | jq -e 'type == "array"' &>/dev/null; then
        _lore_warn_load_claude_env_once
        printf '%s' "$LORE_CLAUDE_ARGS" | jq -r '.[]'
        return
      fi
    fi

    # Migrate legacy file to new shape on first read (idempotent).
    migrate_claude_args_to_harness_args

    if [[ -f "$new_file" ]]; then
      if jq -e --arg fw "$harness" '.[$fw].args | type == "array"' "$new_file" &>/dev/null; then
        jq -r --arg fw "$harness" '.[$fw].args[]' "$new_file"
        return
      fi
    fi

    if [[ "$harness" == "claude-code" && -f "$legacy_file" ]]; then
      if jq -e '.args | type == "array"' "$legacy_file" &>/dev/null; then
        jq -r '.args[]' "$legacy_file"
        return
      fi
    fi
  fi

  if [[ "$harness" == "claude-code" ]]; then
    echo "--dangerously-skip-permissions"
  fi
}

# --- load_claude_args (deprecated alias) ---
# Backwards-compatible shim for callers not yet migrated to
# load_harness_args. Always reads the `claude-code` slot regardless of
# the active framework, matching the pre-T9 behavior. Emits a one-shot
# deprecation notice to stderr per shell so noisy migrations stay quiet.
# Remove one release after every caller has been migrated.
load_claude_args() {
  _lore_warn_load_claude_args_once
  load_harness_args "claude-code"
}

# --- _lore_warn_load_claude_args_once ---
# Emit the load_claude_args deprecation notice to stderr at most once per
# shell. The guard variable is exported so subshells inherit the latched
# state and a single shell session produces a single line.
_lore_warn_load_claude_args_once() {
  if [[ -z "${_LORE_LOAD_CLAUDE_ARGS_WARNED:-}" ]]; then
    echo "lib.sh: load_claude_args is deprecated; call load_harness_args instead (T9)." >&2
    export _LORE_LOAD_CLAUDE_ARGS_WARNED=1
  fi
}

# --- _lore_warn_load_claude_env_once ---
# Emit the LORE_CLAUDE_ARGS deprecation notice to stderr at most once per
# shell. LORE_HARNESS_ARGS is the supported replacement.
_lore_warn_load_claude_env_once() {
  if [[ -z "${_LORE_LOAD_CLAUDE_ENV_WARNED:-}" ]]; then
    echo "lib.sh: LORE_CLAUDE_ARGS is deprecated; set LORE_HARNESS_ARGS instead (T9)." >&2
    export _LORE_LOAD_CLAUDE_ENV_WARNED=1
  fi
}

# --- resolve_active_framework ---
# Print the active harness framework name on stdout.
# Resolution order:
#   1. LORE_FRAMEWORK env var (any non-empty value, validated against the
#      shipped capabilities.json frameworks set).
#   2. $LORE_DATA_DIR/config/framework.json `.framework` (written by install.sh).
#   3. Built-in default: "claude-code".
# Unknown framework names are rejected with a non-zero exit and stderr message;
# resolution never silently routes to a default for an explicit-but-bogus value.
# Mirrors config.ResolveActiveFramework() in tui/internal/config/config.go (T10).
resolve_active_framework() {
  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/framework.json"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local candidate=""
  local source=""

  if [[ -n "${LORE_FRAMEWORK:-}" ]]; then
    candidate="$LORE_FRAMEWORK"
    source="env LORE_FRAMEWORK"
  elif [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
    candidate=$(jq -r '.framework // empty' "$config_file" 2>/dev/null)
    source="$config_file"
  fi

  if [[ -z "$candidate" ]]; then
    candidate="claude-code"
    source="built-in default"
  fi

  if [[ -f "$capabilities_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg fw "$candidate" '.frameworks | has($fw)' "$capabilities_file" &>/dev/null; then
      echo "Error: unknown framework '$candidate' (from $source); not present in $capabilities_file" >&2
      return 1
    fi
  fi

  echo "$candidate"
}

# --- framework_capability ---
# Print the support level for a capability on the active framework.
# Output is one of: full | partial | fallback | none.
# Resolution order (first match wins):
#   1. $LORE_DATA_DIR/config/framework.json `.capability_overrides.<cap>`
#      (user/admin override seeded by install.sh).
#   2. adapters/capabilities.json `.frameworks.<active>.capabilities.<cap>.support`
#      (static profile shipped with the repo).
#   3. Fallback: "none".
# Usage: level=$(framework_capability stop_hook)
#        if [[ "$(framework_capability mcp)" == "full" ]]; then ...
# Mirrors config.FrameworkCapability() in tui/internal/config/config.go (T10).
framework_capability() {
  local cap="$1"
  [[ -z "$cap" ]] && { echo "Error: framework_capability requires a capability name" >&2; return 1; }

  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/framework.json"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local active level

  if ! command -v jq &>/dev/null; then
    echo "none"
    return 0
  fi

  # 1. User override
  if [[ -f "$config_file" ]]; then
    level=$(jq -r --arg c "$cap" '.capability_overrides[$c] // empty' "$config_file" 2>/dev/null)
    if [[ -n "$level" ]]; then
      echo "$level"
      return 0
    fi
  fi

  # 2. Static profile lookup, keyed by active framework.
  active=$(resolve_active_framework) || return 1
  if [[ -f "$capabilities_file" ]]; then
    level=$(jq -r --arg fw "$active" --arg c "$cap" \
      '.frameworks[$fw].capabilities[$c].support // empty' "$capabilities_file" 2>/dev/null)
    if [[ -n "$level" ]]; then
      echo "$level"
      return 0
    fi
  fi

  # 3. Fallback.
  echo "none"
}

# --- framework_capability_evidence ---
# Print the evidence id for a capability on the active framework, or empty
# string if the cell has no evidence pointer (D8 evidence-gating: a non-`none`
# cell missing this field SHOULD be reported as `degraded:no-evidence` by
# the caller). Reads adapters/capabilities.json
# `.frameworks.<active>.capabilities.<cap>.evidence`.
# Used by install.sh and assemble-instructions.sh to compose operator log
# lines that read the capability triple
# (install_paths.<kind>, capabilities.<kind>.support, capabilities.<kind>.evidence)
# in the shared `degraded:partial|fallback|none|no-evidence|unverified-support(<level>)`
# vocabulary defined in conventions/capability-cells-in-adapters-capabilities-json-sho.md.
framework_capability_evidence() {
  local cap="$1"
  [[ -z "$cap" ]] && { echo "Error: framework_capability_evidence requires a capability name" >&2; return 1; }

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    echo ""
    return 0
  fi

  local active
  active=$(resolve_active_framework) || return 1
  jq -r --arg fw "$active" --arg c "$cap" \
    '.frameworks[$fw].capabilities[$c].evidence // ""' "$capabilities_file" 2>/dev/null
}

# --- framework_tui_launch_flag ---
# Print the harness-native CLI flag spelling for one of the TUI-injected
# concerns (T11). Mirrors the Go helpers
# config.HarnessSystemPromptFlag / config.HarnessSettingsOverrideFlag in
# tui/internal/config/framework.go.
#
# Args: $1 = kind, one of: append_system_prompt | inline_settings_override
#       $2 = framework id (optional; defaults to active framework)
#
# Output: a single line on stdout, exit 0:
#   - The flag spelling (e.g., `--append-system-prompt`) when the active
#     framework's tui_launch_flags.<kind> names a flag.
#   - The literal `unsupported` when the cell is the install_paths-style
#     sentinel. Callers MUST skip the injection rather than substitute a
#     different flag — opencode/codex error on an unknown CLI flag.
#
# Exit codes:
#   0  flag spelling or `unsupported` printed.
#   1  unknown kind, unknown framework, missing capabilities.json, or
#      jq unavailable. Callers MUST handle the error rather than fall back
#      to a Claude Code default — both concerns are load-bearing
#      (settings: would inject wrong flag; system prompt: would crash
#      followup-mode on non-claude-code harnesses).
framework_tui_launch_flag() {
  local kind="$1"
  local framework="${2:-}"
  [[ -z "$kind" ]] && { echo "Error: framework_tui_launch_flag requires a kind" >&2; return 1; }
  case "$kind" in
    append_system_prompt|inline_settings_override) ;;
    *) echo "Error: unknown tui_launch_flag kind '$kind' (allowed: append_system_prompt, inline_settings_override)" >&2; return 1 ;;
  esac

  if ! command -v jq &>/dev/null; then
    echo "Error: framework_tui_launch_flag requires jq" >&2
    return 1
  fi

  if [[ -z "$framework" ]]; then
    framework=$(resolve_active_framework) || return 1
  fi

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]]; then
    echo "Error: framework_tui_launch_flag cannot read $capabilities_file" >&2
    return 1
  fi

  if ! jq -e --arg fw "$framework" '.frameworks | has($fw)' "$capabilities_file" &>/dev/null; then
    echo "Error: unknown framework '$framework' (not present in $capabilities_file)" >&2
    return 1
  fi

  local raw
  raw=$(jq -r --arg fw "$framework" --arg k "$kind" \
    '.frameworks[$fw].tui_launch_flags[$k] // ""' "$capabilities_file" 2>/dev/null)
  if [[ -z "$raw" ]]; then
    echo "Error: no tui_launch_flags.$kind defined for framework '$framework'" >&2
    return 1
  fi
  echo "$raw"
}

# --- resolve_permission_adapter ---
# Resolve the per-harness permission/settings policy installer for a
# framework. The single source of truth for which adapter owns each
# harness's settings file (and which merge strategy the adapter applies)
# lives here, so install.sh and uninstall paths consult one helper rather
# than re-deriving the dispatch via case "$FRAMEWORK" branches scattered
# across callers.
#
# Args: $1 = framework id (closed set per resolve_active_framework). When
#       omitted, the active framework is used.
#
# Output: a single line on stdout, exit 0. The line is a
# colon-delimited record describing the adapter's shape:
#
#   cli:<absolute-adapter-path>
#       Adapter is a bash CLI exposing `install`/`uninstall`/`smoke`
#       subcommands per the contract in adapters/hooks/README.md.
#       Today: claude-code -> adapters/hooks/claude-code.sh,
#       codex      -> adapters/codex/hooks.sh.
#
#   plugin-symlink:<src-path>:<dst-path>
#       Adapter is install-time file placement (no CLI). Caller links
#       <src-path> at <dst-path>; uninstall removes <dst-path>. Today:
#       opencode -> adapters/opencode/lore-hooks.ts symlinked into
#       $HOME/.config/opencode/plugins/lore-hooks.ts.
#
#   unsupported
#       Framework has no permission-adapter wired. Caller MUST emit a
#       documented `degraded:none` notice and skip; this is the explicit
#       degradation path required by D6 (degradation is explicit and
#       testable) and the capability triple convention.
#
# Closed framework set; an unknown framework id is an error (exit 1)
# rather than a routed-to-`unsupported` case, mirroring the closed-set
# rejection pattern already used by resolve_model_for_role (T6) and the
# `case` validation in install.sh.
resolve_permission_adapter() {
  local fw="${1:-}"
  if [[ -z "$fw" ]]; then
    fw=$(resolve_active_framework) || return 1
  fi

  # LORE_LIB_DIR resolves to scripts/; repo_root is one level up. Strip
  # the trailing /scripts segment so adapter paths render as
  # "<repo>/adapters/..." rather than "<repo>/scripts/../adapters/...".
  local repo_root="${LORE_LIB_DIR%/scripts}"
  case "$fw" in
    claude-code)
      printf 'cli:%s\n' "$repo_root/adapters/hooks/claude-code.sh"
      ;;
    codex)
      printf 'cli:%s\n' "$repo_root/adapters/codex/hooks.sh"
      ;;
    opencode)
      printf 'plugin-symlink:%s:%s\n' \
        "$repo_root/adapters/opencode/lore-hooks.ts" \
        "$HOME/.config/opencode/plugins/lore-hooks.ts"
      ;;
    *)
      echo "Error: unknown framework '$fw' (allowed: claude-code, codex, opencode)" >&2
      return 1
      ;;
  esac
}

# --- framework_model_routing_shape ---
# Print the model_routing shape for the active framework: "single" or "multi".
# Reads adapters/capabilities.json `.frameworks.<active>.model_routing.shape`.
# Single-provider harnesses (claude-code, codex) collapse the role->model map
# to one binding; multi-provider harnesses (opencode) honor per-role bindings.
# Returns "single" as a safe degraded fallback when capabilities.json is
# unreadable, since the role map under "single" still produces a working
# (collapsed) routing.
# Mirrors config.FrameworkModelRoutingShape() in tui/internal/config/config.go.
framework_model_routing_shape() {
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local active shape

  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    echo "single"
    return 0
  fi
  active=$(resolve_active_framework) || return 1
  shape=$(jq -r --arg fw "$active" '.frameworks[$fw].model_routing.shape // "single"' "$capabilities_file" 2>/dev/null)
  echo "${shape:-single}"
}

# --- resolve_model_for_role ---
# Print the resolved model id for a role on stdout.
# Role MUST be one of the closed set in adapters/roles.json (see T3); unknown
# roles are rejected with a non-zero exit. The "default" role is the
# resolution fallback consumed internally by this helper and is also a valid
# explicit role id.
# Resolution order (first match wins):
#   1. Env var LORE_MODEL_<ROLE_UPPER> (e.g., LORE_MODEL_LEAD=opus).
#   2. Per-repo .lore.config `model_for_<role>=<model>` (walk-up search from
#      cwd; same lookup mechanism as resolve_knowledge_dir).
#   3. User config $LORE_DATA_DIR/config/framework.json `.roles.<role>`.
#   4. Fallback: same file's `.roles.default` (seeded to "sonnet" by install.sh).
# Documented and tested per Phase 1 verification (plan.md line 231):
# precedence is env -> per-repo -> user -> harness default.
# Mirrors config.ResolveModelForRole() in tui/internal/config/config.go (T10).
resolve_model_for_role() {
  local role="$1"
  [[ -z "$role" ]] && { echo "Error: resolve_model_for_role requires a role name" >&2; return 1; }

  local roles_file="$LORE_LIB_DIR/../adapters/roles.json"
  local config_file="${LORE_DATA_DIR:-$HOME/.lore}/config/framework.json"

  # Validate role against the closed registry.
  if [[ -f "$roles_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg r "$role" '.roles[] | select(.id == $r)' "$roles_file" &>/dev/null; then
      echo "Error: unknown role '$role' (not in $roles_file)" >&2
      return 1
    fi
  fi

  # 1. Env var override: LORE_MODEL_<ROLE_UPPER>
  local env_var="LORE_MODEL_$(echo "$role" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!env_var:-}" ]]; then
    echo "${!env_var}"
    return 0
  fi

  # 2. Per-repo .lore.config (walk-up from cwd)
  local lore_config
  if lore_config=$(find_lore_config 2>/dev/null) && [[ -n "$lore_config" ]]; then
    local repo_value
    if repo_value=$(parse_lore_config "model_for_$role" "$lore_config") && [[ -n "$repo_value" ]]; then
      echo "$repo_value"
      return 0
    fi
  fi

  # 3 + 4. User config (.roles.<role>, then .roles.default).
  if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
    local user_value
    user_value=$(jq -r --arg r "$role" '.roles[$r] // empty' "$config_file" 2>/dev/null)
    if [[ -n "$user_value" ]]; then
      echo "$user_value"
      return 0
    fi
    # Fallback to .roles.default
    user_value=$(jq -r '.roles.default // empty' "$config_file" 2>/dev/null)
    if [[ -n "$user_value" ]]; then
      echo "$user_value"
      return 0
    fi
  fi

  echo "Error: no model binding for role '$role' (no env var, no per-repo .lore.config entry, no $config_file roles.<role> or roles.default)" >&2
  return 1
}

# --- resolve_harness_install_path ---
# Print the install path for a kind on the active framework, with $HOME and
# similar shell-style references expanded.
# Closed kind set: instructions | skills | agents | settings | teams |
#                  ephemeral_plans | mcp_servers
# Output:
#   - On supported kinds: an absolute path on stdout, exit 0.
#   - On the literal string "unsupported" stored in install_paths (e.g., codex
#     teams): the literal "unsupported" on stdout, exit 0. Callers branch on
#     this sentinel rather than treating it as a path.
#   - On unknown kinds (not in the closed set) or when the active framework
#     has no install_paths block: an Error on stderr, exit 1.
# Used by audit-artifact.sh, agent-toggle/{enable,disable}.sh, doctor.sh,
# status.sh, load-work.sh, task-completed-capture-check.sh after T19/T29/T53/
# T68/T69 migrate them off hardcoded ~/.claude/* paths. mcp_servers added
# by T20 names the per-harness MCP-server config file (claude-code/opencode
# JSON, codex TOML); the value identifies the file lore writes into when
# packaging a Lore-shipped MCP server.
# Mirrors config.ResolveHarnessInstallPath() in tui/internal/config/config.go.
resolve_harness_install_path() {
  local kind="$1"
  [[ -z "$kind" ]] && { echo "Error: resolve_harness_install_path requires a kind" >&2; return 1; }

  case "$kind" in
    instructions|skills|agents|settings|teams|ephemeral_plans|mcp_servers) ;;
    *)
      echo "Error: unknown kind '$kind' (allowed: instructions, skills, agents, settings, teams, ephemeral_plans, mcp_servers)" >&2
      return 1
      ;;
  esac

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]] || ! command -v jq &>/dev/null; then
    echo "Error: cannot read $capabilities_file (or jq unavailable)" >&2
    return 1
  fi

  local active raw
  active=$(resolve_active_framework) || return 1
  raw=$(jq -r --arg fw "$active" --arg k "$kind" '.frameworks[$fw].install_paths[$k] // empty' "$capabilities_file" 2>/dev/null)

  if [[ -z "$raw" ]]; then
    echo "Error: no install_paths.$kind defined for framework '$active' in $capabilities_file" >&2
    return 1
  fi

  if [[ "$raw" == "unsupported" ]]; then
    echo "unsupported"
    return 0
  fi

  # Expand $HOME / ${HOME}; install paths are restricted to absolute paths
  # rooted in known env vars to keep substitution explainable.
  local expanded="$raw"
  expanded="${expanded//\$HOME/$HOME}"
  expanded="${expanded//\$\{HOME\}/$HOME}"
  echo "$expanded"
}

# --- harness_path_or_empty ---
# Convenience wrapper around resolve_harness_install_path that collapses the
# dominant call shape — "give me the path, or an empty string if this harness
# has no surface for X" — into a single command-substitution-friendly form.
# Args: $1 = kind (same closed set as resolve_harness_install_path)
# Output:
#   - On supported kinds with a real path: the absolute path on stdout, exit 0.
#   - On the "unsupported" sentinel (codex teams, codex ephemeral_plans, etc.):
#     empty string on stdout, exit 0.
#   - On any error from resolve_harness_install_path (unknown kind, missing
#     capabilities.json, missing install_paths block): empty string on stdout,
#     exit 0. Errors are silenced because callers of this form treat both
#     "unsupported" and "config not yet present" as the same "no path here"
#     signal — and the helper is designed to be safe inside `set -e` shells
#     used by SessionStart hooks (load-work.sh, status.sh) where a non-zero
#     exit would abort the whole hook on a transient config issue.
# Usage:
#   VAR=$(harness_path_or_empty <kind>)
#   if [[ -n "$VAR" ]]; then ... fi
# Callers that need to distinguish "unsupported" from "config error" must use
# resolve_harness_install_path directly and inspect its exit code; this helper
# deliberately conflates them. T29/T68/T69 surfaced the pattern in 4 callers
# (load-work.sh, status.sh, doctor.sh, agent-toggle/{enable,disable}.sh)
# before this helper was introduced.
# Mirrors config.HarnessPathOrEmpty() in tui/internal/config/framework.go.
harness_path_or_empty() {
  local kind="$1"
  local res
  if res=$(resolve_harness_install_path "$kind" 2>/dev/null); then
    if [[ "$res" == "unsupported" ]]; then
      return 0
    fi
    echo "$res"
  fi
  return 0
}

# --- resolve_agent_template ---
# Print the absolute path to an agent template (.md file) shipped with the
# lore repo. Templates live under <lore-repo>/agents/<name>.md and are
# framework-independent — install.sh symlinks them into per-harness install
# dirs (resolve_harness_install_path agents) but the canonical content
# always reads from the repo path so version drift between repo and
# harness-side symlink cannot mask itself.
# Args: $1 = template name (e.g., "worker", "researcher", "correctness-gate")
# Output:
#   - Absolute path on stdout, exit 0 when the template file exists.
#   - Error on stderr, exit 1 when the file is missing or the name is empty.
# Used by audit-artifact.sh (correctness-gate, curator, reverse-auditor) and
# any future caller that previously hardcoded $HOME/.claude/agents/<name>.md.
# Mirrors config.ResolveAgentTemplate() in tui/internal/config/config.go.
resolve_agent_template() {
  local name="$1"
  [[ -z "$name" ]] && { echo "Error: resolve_agent_template requires a template name" >&2; return 1; }

  local repo_root="$LORE_LIB_DIR/.."
  local template_path="$repo_root/agents/$name.md"

  if [[ ! -f "$template_path" ]]; then
    echo "Error: agent template '$name' not found at $template_path" >&2
    return 1
  fi

  # Print canonical absolute path (resolve any symlinks in the prefix).
  ( cd "$(dirname "$template_path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$template_path")" )
}

# --- validate_role_model_binding ---
# Validate a role->model binding against the closed role registry and the
# active harness's model_routing shape. T14 ownership (the verification
# rule lives in tests/frameworks/roles.bats; this helper is what the test
# exercises and what install/doctor surfaces will call once T15+T60 wire
# them up).
#
# Usage: validate_role_model_binding <role> <model>
# Returns 0 on success; non-zero on rejection with a stderr explanation.
#
# Rules:
#   1. role MUST appear in adapters/roles.json's closed set.
#   2. If model contains a slash (provider/model syntax) — e.g.
#      "anthropic/sonnet" or "openai/gpt-4o" — the active harness's
#      model_routing.shape MUST be "multi". Single-shape harnesses
#      (claude-code, codex) cannot serve cross-provider bindings.
#   3. Empty model strings are rejected.
#
# Bare model names (no slash) are always accepted regardless of shape;
# single-provider harnesses interpret the bare name against their native
# provider, multi-provider harnesses interpret it against their default
# provider.
validate_role_model_binding() {
  local role="$1"
  local model="$2"

  if [[ -z "$role" ]]; then
    echo "Error: validate_role_model_binding requires a role name" >&2
    return 1
  fi
  if [[ -z "$model" ]]; then
    echo "Error: role '$role' has empty model binding" >&2
    return 1
  fi

  # Rule 1: role must be in the closed registry.
  local roles_file="$LORE_LIB_DIR/../adapters/roles.json"
  if [[ -f "$roles_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg r "$role" '.roles[] | select(.id == $r)' "$roles_file" &>/dev/null; then
      echo "Error: unknown role '$role' (not in $roles_file)" >&2
      return 1
    fi
  fi

  # Rule 2: provider/model syntax requires multi-shape harness.
  if [[ "$model" == */* ]]; then
    local shape
    shape=$(framework_model_routing_shape) || return 1
    if [[ "$shape" != "multi" ]]; then
      local active
      active=$(resolve_active_framework 2>/dev/null) || active="<unknown>"
      echo "Error: role '$role' binding '$model' names a provider but the active harness '$active' has model_routing.shape=$shape (single-provider harnesses cannot serve cross-provider bindings)." >&2
      return 1
    fi
  fi

  return 0
}

# --- resolve_completion_enforcement_mode ---
# Print the resolved completion-enforcement mode for the active framework
# on stdout. One of: native_blocking | lead_validator | self_attestation |
# unavailable. The orchestration adapter contract (adapters/agents/README.md
# §"Mode resolution rule") defines the closed table this helper implements.
#
# The function never fails — even when capability lookup degrades to "none",
# the result is a valid mode string ("unavailable"), so callers can branch
# on the mode value without an additional error path.
#
# Mirrors config.ResolveCompletionEnforcementMode() in
# tui/internal/config/framework.go (T42-T43 lands the Go mirror).
resolve_completion_enforcement_mode() {
  local hook subagents
  hook=$(framework_capability task_completed_hook 2>/dev/null) || hook="none"
  subagents=$(framework_capability subagents 2>/dev/null) || subagents="none"

  if [[ "$subagents" == "none" || "$hook" == "none" ]]; then
    echo "unavailable"
    return 0
  fi

  case "$hook" in
    full)
      # full hook + subagents in {full,partial} -> native_blocking;
      # subagents=fallback is not a documented combination but downgrades
      # safely to lead_validator since the hook still fires.
      if [[ "$subagents" == "fallback" ]]; then
        echo "lead_validator"
      else
        echo "native_blocking"
      fi
      ;;
    partial)
      echo "lead_validator"
      ;;
    fallback)
      if [[ "$subagents" == "fallback" ]]; then
        echo "self_attestation"
      else
        echo "lead_validator"
      fi
      ;;
    *)
      # Unknown level — treat as missing.
      echo "unavailable"
      ;;
  esac
}

# --- resolve_ceremony_config_path ---
# Resolve the path to the global ceremony config file (ceremonies.json)
# at $LORE_DATA_DIR/ceremonies.json (defaults to ~/.lore/ceremonies.json).
# Usage: config_path=$(resolve_ceremony_config_path)
# Output: Absolute path to ceremonies.json (file may not exist yet)
resolve_ceremony_config_path() {
  source "$LORE_LIB_DIR/config.sh"
  echo "${LORE_DATA_DIR}/ceremonies.json"
}

# --- check_fts_available ---
# Check if FTS5 search backend is available (python3 + sqlite3).
# Sets USE_FTS=1 if available, USE_FTS=0 otherwise.
# Usage: check_fts_available; if [[ $USE_FTS -eq 1 ]]; then ...
check_fts_available() {
  USE_FTS=0
  if command -v python3 &>/dev/null && python3 -c "import sqlite3" 2>/dev/null; then
    USE_FTS=1
  fi
}

# --- update_meta_timestamp ---
# Update the "updated" field in a work item's _meta.json to the current UTC time.
# Usage: update_meta_timestamp "$WORK_DIR/$slug"
# Args: $1 = work item directory (containing _meta.json)
# No-op if _meta.json doesn't exist.
update_meta_timestamp() {
  local work_item_dir="$1"
  local meta_file="$work_item_dir/_meta.json"
  [[ -f "$meta_file" ]] || return 0
  local ts
  ts=$(timestamp_iso)
  # Replace the "updated" field value in-place
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ts\"/" "$meta_file"
  else
    sed -i "s/\"updated\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"updated\": \"$ts\"/" "$meta_file"
  fi
}

# --- iso_to_epoch ---
# Convert an ISO 8601 timestamp to Unix epoch seconds.
# Handles "2026-02-07T04:30:00Z" and "2026-02-07T04:30:00" (with or without Z).
# Cross-platform: works on both Darwin (macOS) and Linux.
# Usage: epoch=$(iso_to_epoch "2026-02-07T04:30:00Z")
# Output: Unix epoch seconds (e.g., "1738903800"), or "0" on error.
iso_to_epoch() {
  local iso_date="$1"
  if [[ -z "$iso_date" ]]; then
    echo "0"
    return
  fi
  if [[ "$(uname)" == "Darwin" ]]; then
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_date" +%s 2>/dev/null \
      || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_date%Z}" +%s 2>/dev/null \
      || echo "0"
  else
    date -d "$iso_date" +%s 2>/dev/null || echo "0"
  fi
}

# --- extract_backlinks ---
# Extract [[knowledge:...]] backlinks from a file (notes.md or plan.md).
# Returns one backlink path per line (the part after "knowledge:").
# Usage: backlinks=$(extract_backlinks "$file")
# Output: Newline-separated knowledge paths (e.g., "conventions/skills/skill-composition-via-allowed-tools")
extract_backlinks() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local raw
  raw=$(grep -oE '\[\[knowledge:[^]]+\]\]' "$file" 2>/dev/null) || true
  if [[ -n "$raw" ]]; then
    echo "$raw" | sed 's/\[\[knowledge://;s/\]\]//' | sort -u
  fi
}

# --- _extract_work_item_backlinks ---
# Extract [[knowledge:...]] backlinks from a work item's notes.md and plan.md.
# Returns deduplicated backlink paths, one per line.
# Usage: backlinks=$(_extract_work_item_backlinks "$work_item_dir")
_extract_work_item_backlinks() {
  local work_item_dir="$1"
  local notes_backlinks plan_backlinks
  notes_backlinks=$(extract_backlinks "${work_item_dir}notes.md")
  plan_backlinks=$(extract_backlinks "${work_item_dir}plan.md")

  if [[ -n "$notes_backlinks" || -n "$plan_backlinks" ]]; then
    printf '%s\n%s' "$notes_backlinks" "$plan_backlinks" | grep -v '^$' | sort -u
  fi
}

# --- _extract_work_item_signal ---
# Extract signal terms from a single work item directory.
# Reads title, plan headings, tags from _meta.json, and first ~500 chars of notes.md.
# Usage: output=$(_extract_work_item_signal "$work_item_dir")
# Output format (multi-line):
#   Line 1: Space-separated signal terms (may be empty)
#   Line 2: "---ITEM_SOURCES---" delimiter
#   Lines 3+: One source name per line (title, tags, plan_headings, notes)
_extract_work_item_signal() {
  local work_item_dir="$1"
  local signal=""
  local sources=()
  local meta_file="${work_item_dir}_meta.json"

  # Title
  if [[ -f "$meta_file" ]]; then
    local work_title
    work_title=$(json_field "title" "$meta_file")
    if [[ -n "$work_title" ]]; then
      signal="${work_title}"
      sources+=("title")
    fi

    # Tags from _meta.json (JSON array → space-separated words)
    local tags_raw
    tags_raw=$(json_array_field "tags" "$meta_file")
    if [[ -n "$tags_raw" ]]; then
      local tags_clean
      tags_clean=$(echo "$tags_raw" | sed 's/"//g; s/,/ /g; s/-/ /g')
      if [[ -n "$tags_clean" ]]; then
        signal="${signal} ${tags_clean}"
        sources+=("tags")
      fi
    fi
  fi

  # Plan headings
  local plan_file="${work_item_dir}plan.md"
  if [[ -f "$plan_file" ]]; then
    local plan_headings
    plan_headings=$(grep '^### ' "$plan_file" 2>/dev/null | sed 's/^### //' | head -5 | tr '\n' ' ')
    if [[ -n "$plan_headings" ]]; then
      signal="${signal} ${plan_headings}"
      sources+=("plan_headings")
    fi
  fi

  # First ~500 chars of notes.md (strip markdown headings, comments, blank lines)
  local notes_file="${work_item_dir}notes.md"
  if [[ -f "$notes_file" ]]; then
    local notes_text
    notes_text=$(sed '/^#/d; /^$/d; /^<!--/d' "$notes_file" 2>/dev/null | tr '\n' ' ' | cut -c1-500)
    if [[ -n "$notes_text" ]]; then
      signal="${signal} ${notes_text}"
      sources+=("notes")
    fi
  fi

  echo "$signal"
  echo "---ITEM_SOURCES---"
  if [[ ${#sources[@]} -gt 0 ]]; then
    printf '%s\n' "${sources[@]}"
  fi
}

# --- extract_context_signal ---
# Extract context signal from git branch + matched work item for FTS5 ranking.
# Combines branch name, work item title, plan headings, tags, and notes into a text signal.
# Also extracts [[knowledge:...]] backlinks from notes.md and plan.md.
# On main/master, falls back to most recently updated active work item.
# Usage: OUTPUT=$(extract_context_signal "$KNOWLEDGE_DIR")
# Output format (multi-line):
#   Line 1: Space-separated signal terms (may be empty)
#   Line 2: "---BACKLINKS---" delimiter
#   Lines 3+: One knowledge backlink path per line (may be none)
#   "---SIGNAL_SOURCES---" delimiter
#   Remaining lines: One source name per line (branch, title, tags, plan_headings, notes, backlinks)
# Parsing:
#   CONTEXT_SIGNAL=$(echo "$OUTPUT" | head -1)
#   BACKLINKS=$(echo "$OUTPUT" | sed -n '/^---BACKLINKS---$/,/^---SIGNAL_SOURCES---$/{ /^---/d; p; }')
#   SIGNAL_SOURCES=$(echo "$OUTPUT" | sed '1,/^---SIGNAL_SOURCES---$/d')
extract_context_signal() {
  local knowledge_dir="$1"
  local signal=""
  local backlinks=""
  local signal_sources=()
  local branch
  branch=$(get_git_branch)

  # Helper: call _extract_work_item_signal and parse its multi-line output
  _parse_item_signal() {
    local item_output="$1"
    # Signal is line 1
    _PARSED_SIGNAL=$(echo "$item_output" | head -1)
    # Sources are after ---ITEM_SOURCES--- delimiter
    _PARSED_SOURCES=$(echo "$item_output" | sed '1,/^---ITEM_SOURCES---$/d')
  }

  if [[ -n "$branch" && "$branch" != "main" && "$branch" != "master" ]]; then
    # Branch name as initial signal (convert hyphens/underscores to spaces)
    signal=$(echo "$branch" | tr '_/-' ' ')
    signal_sources+=("branch")

    # Try to match branch to a work item for a stronger signal
    local work_dir="$knowledge_dir/_work"
    if [[ -d "$work_dir" ]]; then
      local work_item_dir meta_file
      for work_item_dir in "$work_dir"/*/; do
        [[ -d "$work_item_dir" ]] || continue
        meta_file="${work_item_dir}_meta.json"
        [[ -f "$meta_file" ]] || continue

        if grep -q "\"$branch\"" "$meta_file" 2>/dev/null; then
          local item_output
          item_output=$(_extract_work_item_signal "$work_item_dir")
          _parse_item_signal "$item_output"
          if [[ -n "$_PARSED_SIGNAL" ]]; then
            signal="${signal} ${_PARSED_SIGNAL}"
          fi
          # Collect item sources
          if [[ -n "$_PARSED_SOURCES" ]]; then
            while IFS= read -r src; do
              [[ -n "$src" ]] && signal_sources+=("$src")
            done <<< "$_PARSED_SOURCES"
          fi

          # Extract backlinks from notes.md and plan.md
          backlinks=$(_extract_work_item_backlinks "$work_item_dir")
          if [[ -n "$backlinks" ]]; then
            signal_sources+=("backlinks")
          fi
          break
        fi
      done
    fi
  else
    # On main/master: use most recently updated active work item
    local work_dir="$knowledge_dir/_work"
    if [[ -d "$work_dir" ]]; then
      local newest_mtime=0 newest_dir="" work_item_dir dirname meta_file item_status item_mtime
      for work_item_dir in "$work_dir"/*/; do
        [[ -d "$work_item_dir" ]] || continue
        dirname=$(basename "$work_item_dir")
        [[ "$dirname" == _* ]] && continue
        meta_file="${work_item_dir}_meta.json"
        [[ -f "$meta_file" ]] || continue

        item_status=$(json_field "status" "$meta_file")
        if [[ "$item_status" == "completed" || "$item_status" == "archived" ]]; then
          continue
        fi

        item_mtime=$(get_mtime "$meta_file")
        if [[ "$item_mtime" -gt "$newest_mtime" ]]; then
          newest_mtime="$item_mtime"
          newest_dir="$work_item_dir"
        fi
      done

      if [[ -n "$newest_dir" ]]; then
        local item_output
        item_output=$(_extract_work_item_signal "$newest_dir")
        _parse_item_signal "$item_output"
        signal="$_PARSED_SIGNAL"
        # Collect item sources
        if [[ -n "$_PARSED_SOURCES" ]]; then
          while IFS= read -r src; do
            [[ -n "$src" ]] && signal_sources+=("$src")
          done <<< "$_PARSED_SOURCES"
        fi

        backlinks=$(_extract_work_item_backlinks "$newest_dir")
        if [[ -n "$backlinks" ]]; then
          signal_sources+=("backlinks")
        fi
      fi
    fi
  fi

  # Output: signal on first line, delimiter, backlinks, delimiter, signal sources
  echo "$signal"
  echo "---BACKLINKS---"
  if [[ -n "$backlinks" ]]; then
    echo "$backlinks"
  fi
  echo "---SIGNAL_SOURCES---"
  if [[ ${#signal_sources[@]} -gt 0 ]]; then
    printf '%s\n' "${signal_sources[@]}"
  fi
}

# --- entry_filename_from_heading ---
# Convert a thread entry heading into a filename stem (without .md).
# Handles: "## 2026-02-06" → "2026-02-06"
#          "## 2026-02-06 (Session 6)" → "2026-02-06-s6"
#          "## 2026-02-07 (Session 14, continued)" → "2026-02-07-s14-continued"
#
# Usage: stem=$(entry_filename_from_heading "## 2026-02-06 (Session 6)")
# Output: "2026-02-06-s6"
entry_filename_from_heading() {
  local heading="$1"
  python3 -c "
import re, sys

heading = sys.argv[1]

# Strip leading ## and whitespace
text = heading.lstrip('#').strip()

# Extract date (YYYY-MM-DD)
date_match = re.match(r'(\d{4}-\d{2}-\d{2})', text)
if not date_match:
    # Fallback: slugify the whole heading
    slug = re.sub(r'[^a-z0-9]', '-', text.lower())
    slug = re.sub(r'-+', '-', slug).strip('-')
    print(slug[:60])
    sys.exit(0)

date = date_match.group(1)
rest = text[date_match.end():].strip()

if not rest:
    print(date)
    sys.exit(0)

# Parse parenthesized session info: (Session N) or (Session N, extra)
session_match = re.match(r'\(Session\s+(\d+)(?:,\s*(.+?))?\)', rest)
if session_match:
    session_num = session_match.group(1)
    extra = session_match.group(2)
    suffix = f'-s{session_num}'
    if extra:
        # Slugify the extra text (e.g., 'continued' → 'continued')
        extra_slug = re.sub(r'[^a-z0-9]', '-', extra.lower())
        extra_slug = re.sub(r'-+', '-', extra_slug).strip('-')
        if extra_slug:
            suffix += f'-{extra_slug}'
    print(f'{date}{suffix}')
else:
    # Non-session parenthetical — slugify the rest as suffix
    rest_slug = re.sub(r'[^a-z0-9]', '-', rest.lower())
    rest_slug = re.sub(r'-+', '-', rest_slug).strip('-')
    if rest_slug:
        print(f'{date}-{rest_slug}')
    else:
        print(date)
" "$heading"
}

# --- disambiguate_entry_filename ---
# Given a filename stem and a newline-separated list of already-used stems,
# append -2, -3, etc. if the stem is already taken.
#
# Usage:
#   USED_STEMS=""
#   stem=$(disambiguate_entry_filename "$stem" "$USED_STEMS")
#   USED_STEMS="${USED_STEMS}${stem}"$'\n'
#
# Output: the (possibly disambiguated) stem
disambiguate_entry_filename() {
  local stem="$1"
  local used="$2"
  local candidate="$stem"
  local counter=2

  while echo "$used" | grep -qxF "$candidate"; do
    candidate="${stem}-${counter}"
    counter=$((counter + 1))
  done

  echo "$candidate"
}

# --- heading_from_entry_filename ---
# Reconstruct a ## heading from an entry filename (or stem).
# Handles: "2026-02-06.md" or "2026-02-06" → "## 2026-02-06"
#          "2026-02-06-s6.md" → "## 2026-02-06 (Session 6)"
#          "2026-02-07-s14-continued.md" → "## 2026-02-07 (Session 14, continued)"
#
# Usage: heading=$(heading_from_entry_filename "2026-02-06-s6.md")
# Output: "## 2026-02-06 (Session 6)"
heading_from_entry_filename() {
  local filename="$1"
  python3 -c "
import re, sys

name = sys.argv[1]

# Strip .md extension if present
if name.endswith('.md'):
    name = name[:-3]

# Match date + optional session suffix
# Extra text must contain a letter (distinguishes from -N dedup suffix)
m = re.match(r'^(\d{4}-\d{2}-\d{2})(?:-s(\d+)(?:-((?=.*[a-z]).+))?)?(?:-\d+)?$', name)
if m:
    date = m.group(1)
    session = m.group(2)
    extra = m.group(3)
    if session:
        if extra:
            # Convert slug back to words (hyphens to spaces)
            extra_text = extra.replace('-', ' ')
            print(f'## {date} (Session {session}, {extra_text})')
        else:
            print(f'## {date} (Session {session})')
    else:
        print(f'## {date}')
else:
    # Fallback: use the filename as-is
    print(f'## {name}')
" "$filename"
}

# --- term_width ---
# Get the current terminal width in columns.
# Tries tput first, falls back to $COLUMNS or 100. Enforces a minimum of 100.
# Usage: width=$(term_width)
# Output: Integer column count (e.g., "120")
term_width() {
  local w
  w=$(tput cols 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$w" || "$w" -le 0 ]] 2>/dev/null; then
    w="${COLUMNS:-100}"
    w=$(echo "$w" | tr -d '[:space:]')
  fi
  if [[ "$w" -lt 100 ]] 2>/dev/null; then
    w=100
  fi
  echo "$w"
}

# --- draw_separator ---
# Draw a box-drawing separator line filling the terminal width.
# With a title:  "── Title ────────────...──"
# Without:       "──────────────────────...──"
# Usage: draw_separator "Section Title"
#        draw_separator   # no title
draw_separator() {
  local title="${1:-}"
  local width
  width=$(term_width)

  if [[ -z "$title" ]]; then
    # Full-width line
    printf '%*s\n' "$width" '' | tr ' ' '─'
  else
    local prefix="── "
    local suffix=" "
    local decorated="${prefix}${title}${suffix}"
    local decorated_len=${#decorated}
    local remaining=$((width - decorated_len))
    if [[ "$remaining" -lt 1 ]]; then
      remaining=1
    fi
    printf '%s' "$decorated"
    printf '%*s\n' "$remaining" '' | tr ' ' '─'
  fi
}

# --- render_table ---
# Render a formatted table to stdout with dynamic column widths.
# Reads pipe-delimited data rows from stdin and formats them according to a
# column specification string.
#
# Column spec format: "NAME:type:size:align|NAME:type:size:align|..."
#   type  — "flex" (proportional) or "fixed" (absolute)
#   size  — character width (fixed) or relative weight (flex)
#   align — "left" or "right"
#
# Flex columns share the remaining terminal width after fixed columns are
# allocated. Minimum flex column width is 10 characters. Values that exceed
# their column width are truncated with a ".." suffix.
#
# Usage: echo "val1|val2|val3" | render_table "COL1:flex:40:left|COL2:fixed:10:right|COL3:flex:60:left"
# Output:
#   COL1          COL2       COL3
#   ----------    ---------- ----------------
#   val1               val2 val3
render_table() {
  local spec="$1"
  local tw
  tw=$(term_width)

  # Parse column spec into parallel arrays
  local -a col_names col_types col_sizes col_aligns col_widths
  local IFS='|'
  local i=0
  for col_spec in $spec; do
    local saved_ifs="$IFS"
    IFS=':'
    local -a parts=($col_spec)
    IFS="$saved_ifs"
    col_names+=("${parts[0]}")
    col_types+=("${parts[1]}")
    col_sizes+=("${parts[2]}")
    col_aligns+=("${parts[3]}")
    i=$((i + 1))
  done
  local ncols=$i

  # Calculate fixed total and flex total weight
  local fixed_total=0
  local flex_weight_total=0
  for ((i = 0; i < ncols; i++)); do
    if [[ "${col_types[$i]}" == "fixed" ]]; then
      fixed_total=$((fixed_total + col_sizes[$i]))
    else
      flex_weight_total=$((flex_weight_total + col_sizes[$i]))
    fi
  done

  # Gaps between columns: (ncols - 1) single spaces
  local gaps=$((ncols - 1))
  # 2-char indent
  local indent=2
  local flex_space=$((tw - indent - fixed_total - gaps))
  if [[ "$flex_space" -lt 0 ]]; then
    flex_space=0
  fi

  # Assign widths
  for ((i = 0; i < ncols; i++)); do
    if [[ "${col_types[$i]}" == "fixed" ]]; then
      col_widths+=("${col_sizes[$i]}")
    else
      local w=10
      if [[ "$flex_weight_total" -gt 0 ]]; then
        w=$((flex_space * col_sizes[$i] / flex_weight_total))
      fi
      if [[ "$w" -lt 10 ]]; then
        w=10
      fi
      col_widths+=("$w")
    fi
  done

  # Build printf format string
  local fmt="  "  # 2-space indent
  for ((i = 0; i < ncols; i++)); do
    if [[ "$i" -gt 0 ]]; then
      fmt="${fmt} "
    fi
    if [[ "${col_aligns[$i]}" == "right" ]]; then
      fmt="${fmt}%${col_widths[$i]}s"
    else
      fmt="${fmt}%-${col_widths[$i]}s"
    fi
  done

  # Helper: truncate a value to a given width, appending ".." if needed
  _trunc() {
    local val="$1"
    local maxw="$2"
    if [[ "${#val}" -gt "$maxw" ]]; then
      if [[ "$maxw" -le 2 ]]; then
        echo "${val:0:$maxw}"
      else
        echo "${val:0:$((maxw - 2))}.."
      fi
    else
      echo "$val"
    fi
  }

  # Render header
  local -a hdr_vals
  for ((i = 0; i < ncols; i++)); do
    hdr_vals+=("$(_trunc "${col_names[$i]}" "${col_widths[$i]}")")
  done
  printf "${fmt}\n" "${hdr_vals[@]}"

  # Render separator
  local -a sep_vals
  for ((i = 0; i < ncols; i++)); do
    local dashes=""
    local w="${col_widths[$i]}"
    dashes=$(printf '%*s' "$w" '' | tr ' ' '-')
    sep_vals+=("$dashes")
  done
  printf "${fmt}\n" "${sep_vals[@]}"

  # Render data rows from stdin
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    local -a row_vals=()
    local saved_ifs="$IFS"
    IFS='|'
    local -a fields=($line)
    IFS="$saved_ifs"
    for ((i = 0; i < ncols; i++)); do
      local val="${fields[$i]:-}"
      row_vals+=("$(_trunc "$val" "${col_widths[$i]}")")
    done
    printf "${fmt}\n" "${row_vals[@]}"
  done
}

# --- remap_line_through_diff ---
# Map an old line number through a git diff to its new position.
# Usage: remap_line_through_diff <path> <line> <old_sha> <new_sha> [repo_dir]
# Output (stdout, single line):
#   anchored                  — line unchanged
#   shifted:<NEW_LINE>        — line moved, content semantically identical
#   renamed:<NEW_PATH>:<LINE> — file renamed, line tracked through rename
#   lost                      — line deleted or rewritten
# Exit 1 if diff cannot be computed (caller should bail).
remap_line_through_diff() {
  local file_path="$1"
  local target_line="$2"
  local old_sha="$3"
  local new_sha="$4"
  local repo_dir="${5:-.}"

  # Compute unified diff with rename detection
  local diff_output
  if ! diff_output=$(git -C "$repo_dir" diff -M "${old_sha}..${new_sha}" -- "$file_path" 2>/dev/null); then
    return 1
  fi

  # Empty diff: file is identical — line is anchored
  if [[ -z "$diff_output" ]]; then
    echo "anchored"
    return 0
  fi

  # Detect rename: path-filtered diff suppresses rename headers (git treats renamed-away file as
  # a pure deletion). Re-run without path filter when a rename from this path exists.
  local new_path=""
  local full_diff
  full_diff=$(git -C "$repo_dir" diff -M "${old_sha}..${new_sha}" 2>/dev/null) || true
  new_path=$(printf '%s\n' "$full_diff" | awk -v src="$file_path" '
    found_src { if (/^rename to /) { sub(/^rename to /, ""); print; exit } }
    /^rename from / { path = $0; sub(/^rename from /, "", path); if (path == src) found_src = 1 }
  ')

  # If renamed, use the rename-aware diff for hunk walking
  if [[ -n "$new_path" ]]; then
    diff_output=$(printf '%s\n' "$full_diff" | awk -v src="$file_path" -v dst="$new_path" '
      in_block { print }
      /^diff --git/ {
        in_block = 0
        # Check if this block is the rename of our file
        if ($0 ~ ("a/" src " b/" dst)) in_block = 1
      }
    ')
  fi

  # Walk the diff to determine outcome for target_line.
  #
  # Algorithm:
  #   - Track cumulative_delta = (new lines added) - (old lines deleted) across all hunks seen so far.
  #   - For each hunk header, if target_line < old_start → it's between/before hunks:
  #       new_line = target_line + cumulative_delta → anchored (or shifted if delta!=0, or renamed)
  #   - Inside a hunk body, walk line by line tracking old_pos / new_pos:
  #       ' ' context: advance both; if old_pos==target → anchored/renamed
  #       '-' deletion: if old_pos==target → save content for comparison; advance old_pos
  #       '+' addition: if we have a saved deletion at target → compare content:
  #                       same → shifted/renamed; different → lost
  #   - After processing all hunks, if not found → target is after last hunk:
  #       new_line = target_line + cumulative_delta → anchored/renamed
  local result
  result=$(printf '%s\n' "$diff_output" | awk \
    -v target="$target_line" \
    -v new_path="$new_path" \
    '
    BEGIN {
      found = 0
      outcome = ""
      in_hunk = 0
      old_pos = 0
      new_pos = 0
      cumulative_delta = 0
      # For deleted-line lookahead
      pending_delete = 0
      pending_delete_content = ""
      pending_new_pos = 0
    }

    /^@@ / {
      # Flush any pending delete that was not followed by "+"
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }

      # Parse: @@ -old_start[,old_count] +new_start[,new_count] @@
      # Portable BSD awk: extract numbers using sub/split on the header
      hdr = $0
      sub(/^@@ -/, "", hdr)
      split(hdr, a, " ")
      old_part = a[1]; sub(/,.*/, "", old_part); old_start = old_part + 0
      new_part = a[2]; sub(/^\+/, "", new_part); sub(/,.*/, "", new_part); new_start = new_part + 0

      # If target is before this hunk, it lives in the context between/before hunks
      if (target < old_start && !found) {
        # new_line = target + cumulative_delta (delta from all prior hunks)
        new_line = target + cumulative_delta
        if (new_path != "") {
          outcome = "renamed:" new_path ":" new_line
        } else if (new_line == target) {
          outcome = "anchored"
        } else {
          outcome = "shifted:" new_line
        }
        found = 1
      }

      # cumulative_delta from prior hunks: (new_start - old_start) reflects prior hunk edits
      # We update cumulative_delta AFTER we check the target relative to old_start,
      # but we need cumulative_delta to reflect all prior (already-finished) hunks.
      # Track it via old/new position advancement below; reset here to hunk start.
      old_pos = old_start
      new_pos = new_start
      in_hunk = 1
      next
    }

    in_hunk && /^([-+ ])/ {
      ch = substr($0, 1, 1)

      if (ch == "+") {
        # Addition line
        if (pending_delete && !found) {
          # Compare content of deleted line with this added line
          add_content = substr($0, 2)
          if (add_content == pending_delete_content) {
            # Same content — shifted (or renamed)
            if (new_path != "") {
              outcome = "renamed:" new_path ":" pending_new_pos
            } else {
              outcome = "shifted:" pending_new_pos
            }
          } else {
            outcome = "lost"
          }
          found = 1
          pending_delete = 0
        }
        cumulative_delta++
        new_pos++
        next
      }

      # For "-" or " " lines: flush any open pending_delete (deletion not followed by "+")
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }

      if (ch == " ") {
        # Context line: in both old and new
        if (old_pos == target && !found) {
          new_line = new_pos
          if (new_path != "") {
            outcome = "renamed:" new_path ":" new_line
          } else if (new_line == target) {
            outcome = "anchored"
          } else {
            outcome = "shifted:" new_line
          }
          found = 1
        }
        old_pos++
        new_pos++
      } else if (ch == "-") {
        # Deletion line: only in old
        if (old_pos == target && !found) {
          # Save for comparison with next "+" line
          pending_delete = 1
          pending_delete_content = substr($0, 2)
          pending_new_pos = new_pos
        }
        cumulative_delta--
        old_pos++
      }
      next
    }

    # Non-diff-body lines inside a hunk (e.g. "\ No newline at end of file")
    in_hunk && /^\\ / {
      next
    }

    # Any other line ends the hunk
    in_hunk {
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
        pending_delete = 0
      }
      in_hunk = 0
    }

    END {
      if (pending_delete && !found) {
        outcome = "lost"
        found = 1
      }
      if (!found) {
        # Target is after all hunks
        new_line = target + cumulative_delta
        if (new_path != "") {
          outcome = "renamed:" new_path ":" new_line
        } else if (new_line == target) {
          outcome = "anchored"
        } else {
          outcome = "shifted:" new_line
        }
      }
      print outcome
    }
  ')

  echo "$result"
}

# --- init_followups_dir ---
# Create $KNOWLEDGE_DIR/_followups/ if it does not already exist.
# Usage: init_followups_dir "$KNOWLEDGE_DIR"
# Args: $1 = knowledge directory path
# Returns 0 if created or already exists. Exits 1 if KNOWLEDGE_DIR does not exist.
init_followups_dir() {
  local knowledge_dir="$1"
  if [[ ! -d "$knowledge_dir" ]]; then
    echo "Error: knowledge store not found at: $knowledge_dir" >&2
    return 1
  fi
  local followups_dir="$knowledge_dir/_followups"
  if [[ ! -d "$followups_dir" ]]; then
    mkdir -p "$followups_dir"
  fi
}
