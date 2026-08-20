#!/usr/bin/env bash
# lib.sh — Shared utility functions for lore scripts and skills
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Or from skills: source ~/.lore/scripts/lib.sh
#
# NOTE: This is a library file. Do NOT add set -euo pipefail here.
# Callers set their own shell options.
#
# Shell support: bash 3.2+ and zsh 5+. The Claude Code Bash tool on macOS
# inherits the user's login shell (typically zsh), and skill setup blocks
# routinely `source` this file directly — so the path-detection and the
# few helpers using indirect expansion below MUST work in both shells.
# See gotchas/scripts-lib-sh-assumes-bash-is-routinely-sourced.md.

# Resolve this library's own path in a shell-portable way.
#   - bash: ${BASH_SOURCE[0]} is the sourced file path.
#   - zsh:  ${(%):-%x} prompt-expands to the file currently being sourced.
#   - other shells: best-effort fallback to $0 (will trip the sanity
#     check below if it lands somewhere bogus).
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _lore_lib_self="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  _lore_lib_self="${(%):-%x}"
else
  _lore_lib_self="${0}"
fi
LORE_LIB_DIR="$(cd "$(dirname "$_lore_lib_self")" && pwd)"
unset _lore_lib_self

# Sanity check: a correct $LORE_LIB_DIR contains lib.sh itself. If the
# detection fell through to the cwd (e.g. an unsupported shell where
# neither BASH_SOURCE nor ZSH_VERSION is populated), every downstream
# `$LORE_LIB_DIR/../adapters/...` lookup would silently target the wrong
# directory. Refuse loudly here instead.
if [[ ! -f "$LORE_LIB_DIR/lib.sh" ]]; then
  echo "Error: scripts/lib.sh self-detection failed (LORE_LIB_DIR='$LORE_LIB_DIR' has no lib.sh)." >&2
  echo "       lib.sh supports bash and zsh; if you're sourcing it from a different shell," >&2
  echo "       wrap the invocation in 'bash -c \"...\"' or report a bug." >&2
  return 1 2>/dev/null || exit 1
fi

# LORE_REPO_DIR is the physical lore-repo root (one level up from scripts/),
# resolved through any symlinks. Skills and scripts that build adapter paths
# via string concatenation (e.g. "$LORE_REPO_DIR/adapters/agents/...") need
# the realpath — stripping "/scripts" from LORE_LIB_DIR fails on the typical
# install where ~/.lore/scripts is a symlink to the actual repo's scripts/.
# `cd -P ..` resolves the symlink physically before going up, which a plain
# `cd "$LIB/.."; pwd -P` does not (bash collapses ".." logically in the path
# argument before chdir, landing at ~/.lore which has no adapters/ dir).
LORE_REPO_DIR="$(cd "$LORE_LIB_DIR" && cd -P .. && pwd)"

# --- Path-derivation convention ---
# When a helper here needs the lore-repo root, use "$LORE_REPO_DIR"
# (already physically resolved above), NEVER "$LORE_LIB_DIR/.." chained
# into a `cd`. Both bash and zsh logically collapse ".." against the
# string before chdir, so on the typical symlinked install
# (~/.lore/scripts -> <repo>/scripts) the resulting path lands at ~/.lore
# instead of <repo>/. Filesystem syscalls (`[[ -f ... ]]`, `cat`, `jq`)
# resolve ".." physically and tolerate the legacy form, but anything
# routed through `cd` does not. tests/frameworks/lib_shell_portability.bats
# guards this convention with a grep-based lint so future helpers can't
# silently re-introduce the trap.

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

# --- derive_entry_title ---
# Derive a knowledge-entry H1 from an insight/claim: first ~8 words, each
# title-cased (macOS-compatible via awk). Shared by capture.sh (titling new
# entries) and apply-correction.sh (regenerating a derived H1 after a body
# correction) — both must produce identical titles for identical input.
# Usage: title=$(derive_entry_title "some insight text")
derive_entry_title() {
  local text="$1"
  # An H1 is one line. awk below is line-oriented, so a multi-line insight used
  # to yield a multi-line "title" — every line's first eight words, title-cased,
  # stacked above the entry body (which capture.sh then wrote again in full).
  # Flatten first so later lines are normalized into the title instead of
  # promoted alongside it. Single-line input is unaffected.
  text=$(printf '%s' "$text" | tr '\n\t' '  ' | tr -s ' ')
  # LC_ALL=C: BSD awk's substr() is byte-oriented under a UTF-8 locale and
  # errors ("illegal byte sequence") when a word starts with a multibyte
  # character (e.g. a standalone em-dash in the first 8 words). Under the C
  # locale bytes pass through untouched — non-ASCII first letters are left
  # as-is instead of title-cased, and the output stays valid UTF-8.
  echo "$text" | LC_ALL=C awk '{for(i=1;i<=NF && i<=8;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; NF=(NF>8?8:NF); print}'
}

# --- sanitize_footer_value ---
# Make a value safe for the single-line HTML metadata footer of a knowledge
# entry. Three characters cannot survive there: "|" separates footer fields, ">"
# ends the comment (and terminates the value class the primary parser uses), and
# a newline or tab breaks the one-line shape the positional parsers assume. Each
# is replaced with a space, runs of spaces are collapsed, and the result is
# trimmed — so a value that contains none of them comes back unchanged.
#
# Short values belong in the footer; long-form prose does not. Put that in the
# entry body under a heading instead.
# Usage: safe=$(sanitize_footer_value "$raw")
sanitize_footer_value() {
  printf '%s' "$1" \
    | tr '|>\n\t' '    ' \
    | tr -s ' ' \
    | sed 's/^ *//;s/ *$//'
}

# --- resolve_knowledge_dir ---
# Resolve the knowledge store directory for the current project.
# Usage: KDIR=$(resolve_knowledge_dir)
resolve_knowledge_dir() {
  "$LORE_LIB_DIR/resolve-repo.sh"
}

# --- knowledge_store_containing ---
# Find the knowledge store a directory sits inside, by walking up to
# $LORE_DATA_DIR/repos. A store is a directory beneath repos/ that holds a
# _manifest.json; the search is anchored there so an unrelated project with its
# own _manifest.json can never be mistaken for one.
#
# This answers a different question from resolve_knowledge_dir(): that one maps
# a *project checkout* to its store via git remote, this one names the store you
# are physically standing in. They usually agree. When they disagree — cwd
# inside store A while resolution names store B — a caller writing to the
# resolved store files into the wrong one silently, which is why capture.sh
# compares the two and refuses rather than picking.
#
# Echoes the store root (symlink-resolved) and returns 0 when found; returns 1
# when the directory is outside every store.
# Usage: store=$(knowledge_store_containing "$PWD") || store=""
knowledge_store_containing() {
  local dir="${1:-$(pwd)}"
  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local repos_root
  repos_root="$(cd "$data_dir/repos" 2>/dev/null && pwd -P)" || return 1
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  while [[ "$dir" == "$repos_root/"* ]]; do
    if [[ -f "$dir/_manifest.json" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
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

# --- resolve_work_item_dir ---
# Resolve the owning directory for a per-item write against the live
# filesystem. Call it immediately before writing — a work item can be archived
# between an earlier resolution and the write, and a stale path recreates an
# active dir for an archived item.
#
# Precedence when both _work/<slug>/ and _work/_archive/<slug>/ exist (each
# rung probes active then archive):
#   1. the dir holding <artifact-filename> at its root, when given — an active
#      residue stub loses to the archive copy that holds the real artifacts
#   2. the dir holding _meta.json — a real item beats a bare stub
#   3. bare directory presence
#
# Never creates directories. Probes match the dir root only: verdicts/ subdirs
# reuse artifact filenames for envelope storage and must never satisfy a probe,
# so <artifact-filename> must be a bare basename.
#
# Echoes the absolute path on stdout; returns non-zero when neither dir exists.
# Usage: dir=$(resolve_work_item_dir "$KDIR" "$slug" [artifact-filename]) || ...
resolve_work_item_dir() {
  local kdir="$1" slug="$2" artifact="${3:-}"
  if [[ -z "$kdir" || -z "$slug" ]]; then
    echo "[work] Error: resolve_work_item_dir requires <kdir> and <slug>" >&2
    return 1
  fi
  if [[ "$slug" == "_archive" || "$slug" != "$(basename "$slug")" ]]; then
    echo "[work] Error: resolve_work_item_dir: invalid work-item slug '$slug'" >&2
    return 1
  fi
  if [[ "$artifact" == */* ]]; then
    echo "[work] Error: resolve_work_item_dir: artifact filename must be a bare basename (got '$artifact')" >&2
    return 1
  fi
  local candidates=("$kdir/_work/$slug" "$kdir/_work/_archive/$slug")
  local dir
  if [[ -n "$artifact" ]]; then
    for dir in "${candidates[@]}"; do
      if [[ -f "$dir/$artifact" ]]; then
        echo "$dir"
        return 0
      fi
    done
  fi
  for dir in "${candidates[@]}"; do
    if [[ -f "$dir/_meta.json" ]]; then
      echo "$dir"
      return 0
    fi
  done
  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  done
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

# --- Session substrate timing contracts ---
# Keep the shell enqueue/preflight paths on the same registry liveness window as
# tui/internal/session/registry.go's session.LivenessTTL.  Callers ask this
# shared helper instead of growing another mtime interpretation beside the pin
# preflight.
SESSION_INSTANCE_LIVENESS_TTL_SECONDS=30

# session_instance_age_seconds <instances-dir> <instance>
# Prints the registry row age in whole seconds. Missing rows return 1; future
# mtimes clamp to zero so a small clock adjustment cannot make a row immortal.
session_instance_age_seconds() {
  local instances_dir="$1" instance="$2" path mtime now age
  [[ -n "$instance" && "$instance" != */* ]] || return 1
  path="$instances_dir/$instance.json"
  [[ -f "$path" ]] || return 1
  mtime=$(get_mtime "$path") || return 1
  now=$(date -u +%s)
  age=$((now - mtime))
  (( age < 0 )) && age=0
  printf '%s\n' "$age"
}

# session_instance_live <instances-dir> <instance>
# A registry row is live exactly when its age is inside the shared TTL.
session_instance_live() {
  local age
  age=$(session_instance_age_seconds "$1" "$2") || return 1
  (( age <= SESSION_INSTANCE_LIVENESS_TTL_SECONDS ))
}

# resolve_physical_dir <path>
# Echo <path> with symlinks collapsed, or return 1 when it is not an existing
# directory. `cd -P --` rather than a bare `cd`: with CDPATH set, cd to a
# relative path echoes its destination on stdout, so the captured value would
# carry a stray extra line. `--` keeps a leading-dash path from being read as
# options.
resolve_physical_dir() {
  local dir="$1"
  [[ -n "$dir" ]] || return 1
  (cd -P -- "$dir" >/dev/null 2>&1 && pwd -P) || return 1
}

# live_instance_project_dirs <instances-dir> [ttl-seconds]
# Print the project directory of every live registry row, one per line, sorted
# and deduplicated — the checkouts a placement declaration can currently be
# served from. The stored value is already physically resolved by its writer, so
# it is emitted verbatim: byte equality against a resolve_physical_dir result is
# the match the claiming side performs. Rows written before the field existed
# carry no project_dir and are skipped rather than printed empty.
live_instance_project_dirs() {
  local instances_dir="$1"
  local ttl="${2:-$SESSION_INSTANCE_LIVENESS_TTL_SECONDS}"
  python3 - "$instances_dir" "$ttl" <<'PYEOF'
import json, os, sys, time

instances_dir, ttl = sys.argv[1], float(sys.argv[2])
now = time.time()
dirs = set()
if os.path.isdir(instances_dir):
    for name in sorted(os.listdir(instances_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(instances_dir, name)
        try:
            if (now - os.path.getmtime(path)) > ttl:
                continue
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError):
            continue
        project_dir = (row.get("project_dir") or "").strip()
        if project_dir:
            dirs.add(project_dir)
for d in sorted(dirs):
    print(d)
PYEOF
}

# session_request_ttl_seconds
# The schema-declared setting is bounded to one second through seven days and
# defaults to one hour. Runtime readers fail closed to the shipped default when
# an old, missing, or hand-edited settings document supplies anything else.
SESSION_REQUEST_TTL_DEFAULT_SECONDS=3600
SESSION_REQUEST_TTL_MAX_SECONDS=604800
session_request_ttl_seconds() {
  local raw
  raw=$(bash "$LORE_LIB_DIR/settings.sh" get coordination.session_request_ttl_seconds 2>/dev/null || true)
  if [[ "$raw" =~ ^[0-9]+$ ]] \
      && (( raw >= 1 && raw <= SESSION_REQUEST_TTL_MAX_SECONDS )); then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$SESSION_REQUEST_TTL_DEFAULT_SECONDS"
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

# --- lore_harness_enabled ---
# Returns 0 (success) if lore integration is enabled for the named harness,
# non-zero if disabled. The framework arg is REQUIRED — callers know which
# harness they're acting on (toggle scripts pass the loop variable; the TUI
# passes the focused panel's framework). No implicit default — passing the
# wrong harness would silently pick a different toggle, which is the bug
# class this function exists to prevent.
#
# Resolution order:
#   1. LORE_AGENT_DISABLED=1 env var → disabled (returns 1). Session-wide
#      kill switch, applies to every harness. Name kept for back-compat with
#      shell rc files; semantically still "lore disabled this session".
#   2. Unified ~/.lore/config/settings.json `.harnesses.<fw>.enabled`. When
#      the key is explicitly `false`, return 1; any other present value is
#      enabled.
#   3. Key absent everywhere → enabled (returns 0). Default-on semantic
#      preserves the pre-rename contract where missing config = enabled.
#
# Usage:
#   lore_harness_enabled claude-code || exit 0
lore_harness_enabled() {
  local framework="${1:-}"
  if [[ -z "$framework" ]]; then
    echo "lore_harness_enabled: framework arg is required" >&2
    return 2
  fi

  if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
    return 1
  fi

  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"

  # Unified file (primary)
  if [[ -x "$settings_sh" || -r "$settings_sh" ]] && command -v jq &>/dev/null; then
    local unified_value
    unified_value=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.${framework}.enabled" 2>/dev/null || true)
    if [[ -n "$unified_value" ]]; then
      [[ "$unified_value" == "false" ]] && return 1
      return 0
    fi
  fi

  return 0
}

# --- lore_agent_enabled ---
# Returns 0 if lore integration is enabled for ANY registered harness, non-zero
# only when every harness is explicitly disabled (or LORE_AGENT_DISABLED=1 is
# in the env). This is the gate hooks call to decide whether to do any work
# at all — the per-harness disabled state is enforced by uninstalling that
# harness's symlinks and clearing its instruction file, so a disabled
# harness shouldn't fire its hooks at all. This gate is belt-and-suspenders
# against partial disable states.
#
# Resolution order:
#   1. LORE_AGENT_DISABLED=1 env var → disabled (returns 1).
#   2. For each registered framework, check `harnesses.<fw>.enabled`. If at
#      least one is true (or absent — default-on), return 0.
#   3. Nothing on disk → enabled (returns 0).
#
# Usage: lore_agent_enabled || exit 0
lore_agent_enabled() {
  if [[ "${LORE_AGENT_DISABLED:-}" == "1" ]]; then
    return 1
  fi

  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"

  # Per-harness check: if ANY registered framework is enabled (or absent →
  # default-on), the gate passes. We enumerate via list_supported_frameworks
  # so newly-added harnesses are picked up automatically.
  if [[ -x "$settings_sh" || -r "$settings_sh" ]] && command -v jq &>/dev/null; then
    local _fw_list
    _fw_list=$(list_supported_frameworks 2>/dev/null || true)
    if [[ -n "$_fw_list" ]]; then
      local fw any_present=0
      while IFS= read -r fw; do
        [[ -z "$fw" ]] && continue
        local v
        v=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.${fw}.enabled" 2>/dev/null || true)
        if [[ -n "$v" ]]; then
          any_present=1
          [[ "$v" == "true" ]] && return 0
        else
          # Absent → default-on. Lore is enabled.
          return 0
        fi
      done <<<"$_fw_list"
      # Every registered framework had an explicit value and none were true.
      [[ "$any_present" -eq 1 ]] && return 1
    fi
  fi

  return 0
}

# --- migrate_claude_args_to_harness_args ---
# Compatibility no-op. Runtime settings no longer migrate or read legacy
# claude.json / harness-args.json files; harness args come from
# settings.json or LORE_HARNESS_ARGS only.
migrate_claude_args_to_harness_args() {
  return 0
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
#      whichever harness the caller is reading.
#   2. Unified settings.json `harnesses.<harness>.args`.
#   3. built-in default: `--dangerously-skip-permissions` for
#      `claude-code`; nothing (no args) for any other harness, since the
#      flag is Anthropic-specific.
# Mirrors config.LoadHarnessArgs() in tui/internal/config/config.go (T10).
load_harness_args() {
  local harness="${1:-}"
  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"

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

    # Unified file (primary): harnesses.<harness>.args
    local unified_args_raw
    unified_args_raw=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$harness.args" 2>/dev/null || true)
    if [[ -n "$unified_args_raw" ]]; then
      if printf '%s' "$unified_args_raw" | jq -e 'type == "array"' &>/dev/null; then
        printf '%s' "$unified_args_raw" | jq -r '.[]'
        return
      fi
    fi

  fi

  if [[ "$harness" == "claude-code" ]]; then
    echo "--dangerously-skip-permissions"
  fi
}

# --- filter_harness_args_for_headless ---
# Print the subset of a harness argument list that the harness's
# non-interactive surface accepts, one arg per line, preserving order and
# repetition. Every dropped argument group is announced on stderr as a
# `[lore] degraded:` line.
#
# Args: $1 = framework id; $2.. = the argument list (typically the output of
#       load_harness_args, which this helper never calls — the caller decides
#       which list it is filtering).
#
# The contract is read from adapters/capabilities.json
# `.frameworks.<fw>.capabilities.headless_runner.argument_contract`:
#   mode=shared_parser  the harness parses interactive and non-interactive
#                       invocations with one option list; pass everything
#                       through, no notice.
#   mode=filtered       `source_grammar` maps each exact flag spelling to
#                       {arity, headless}. A flag is grouped with the number
#                       of following tokens its arity declares, then kept or
#                       dropped as a whole. Dropping the flag without its
#                       values is what this arity exists to prevent: a
#                       stranded value binds as the subcommand's positional
#                       prompt, turning a crash into a silently wrong run.
#   absent/empty        the surface has not been probed; pass everything
#                       through with a one-shot notice. Never synthesize a
#                       grammar.
#
# Exit codes:
#   0   filtered list printed (possibly empty).
#   64  setup error, raised before the caller spawns anything: an argument
#       whose flag is not in the grammar (its value boundary cannot be
#       inferred, so neither keeping nor dropping it is safe), an argument
#       list that ends mid-group, a structurally invalid declaration, or an
#       unreadable capabilities.json.
#
# Deliberately bash-only — see adapters/README.md § Why the headless argument
# filter is bash-only.
filter_harness_args_for_headless() {
  local framework="${1:-}"
  if [[ -z "$framework" ]]; then
    echo "Error: filter_harness_args_for_headless requires a framework id" >&2
    return 64
  fi
  shift

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    echo "Error: filter_harness_args_for_headless cannot read the argument contract (needs jq and $capabilities_file)" >&2
    return 64
  fi

  local mode
  mode=$(jq -r --arg fw "$framework" \
    '(.frameworks[$fw].capabilities.headless_runner.argument_contract // {}) | .mode // ""' \
    "$capabilities_file" 2>/dev/null) || mode=""

  if [[ -z "$mode" ]]; then
    _lore_warn_headless_arg_contract_once "$framework"
    if (( $# > 0 )); then printf '%s\n' "$@"; fi
    return 0
  fi

  case "$mode" in
    shared_parser)
      if (( $# > 0 )); then printf '%s\n' "$@"; fi
      return 0
      ;;
    filtered) ;;
    *)
      echo "Error: framework '$framework' declares headless argument-contract mode '$mode', which is not one of: filtered, shared_parser" >&2
      return 64
      ;;
  esac

  # Flatten the grammar to `flag<TAB>arity<TAB>policy` rows. jq errors out on
  # any malformed entry so a half-written declaration fails here rather than
  # silently narrowing the accepted surface.
  local grammar
  grammar=$(jq -er --arg fw "$framework" '
    (.frameworks[$fw].capabilities.headless_runner.argument_contract.source_grammar) as $g
    | if ($g | type) != "object" or ($g | length) == 0 then
        error("mode=filtered with a missing or empty source_grammar")
      else
        $g | to_entries | map(
          if (.key | startswith("-")) != true then
            error("source_grammar key \(.key) is not a flag spelling")
          elif (.value | type) != "object" then
            error("source_grammar entry \(.key) is not an object")
          elif (.value.arity | type) != "number" or .value.arity < 0 then
            error("source_grammar entry \(.key) has no non-negative numeric arity")
          elif (.value.headless != "accepted" and .value.headless != "rejected") then
            error("source_grammar entry \(.key) has no accepted/rejected headless policy")
          else
            "\(.key)\t\(.value.arity)\t\(.value.headless)"
          end
        ) | .[]
      end
  ' "$capabilities_file" 2>&1) || {
    echo "Error: framework '$framework' has a structurally invalid headless argument contract in $capabilities_file" >&2
    printf '%s\n' "$grammar" >&2
    return 64
  }

  local out=()
  local group=()
  local tok flag row arity policy inline n
  while (( $# > 0 )); do
    tok="$1"
    if [[ "$tok" != -?* ]]; then
      echo "Error: '$tok' in the '$framework' harness argument list is not a flag; the headless argument contract can only group tokens by a declared flag's arity" >&2
      return 64
    fi
    flag="$tok"
    inline=0
    if [[ "$tok" == --*=* ]]; then
      flag="${tok%%=*}"
      inline=1
    fi
    row=$(printf '%s\n' "$grammar" | awk -F'\t' -v f="$flag" '$1 == f { print $2 "\t" $3; exit }')
    if [[ -z "$row" ]]; then
      echo "Error: '$flag' is not declared in the '$framework' headless argument contract, so its value boundary is unknown — add it to source_grammar in adapters/capabilities.json (with the CLI version it was probed against) before this harness can run headless." >&2
      return 64
    fi
    arity="${row%%$'\t'*}"
    policy="${row##*$'\t'}"

    group=("$tok")
    shift
    if (( inline == 0 )); then
      n=0
      while (( n < arity )); do
        if (( $# == 0 )); then
          echo "Error: '$flag' takes $arity value(s) on the '$framework' surface but the harness argument list ends early" >&2
          return 64
        fi
        group+=("$1")
        shift
        n=$((n + 1))
      done
    fi

    if [[ "$policy" == "accepted" ]]; then
      out+=("${group[@]}")
    else
      echo "[lore] degraded: headless argument filter via headless_runner.argument_contract=partial (framework '$framework' dropped ${group[*]} — $flag is not accepted by the non-interactive surface)" >&2
    fi
  done

  if (( ${#out[@]} > 0 )); then printf '%s\n' "${out[@]}"; fi
}

# --- _lore_warn_headless_arg_contract_once ---
# Announce an unprobed non-interactive argument surface at most once per
# framework per shell. The latch is exported so subshells inherit it and a
# batch of judge invocations produces a single line.
_lore_warn_headless_arg_contract_once() {
  local framework="$1"
  case " ${_LORE_HEADLESS_ARG_CONTRACT_WARNED:-} " in
    *" $framework "*) return 0 ;;
  esac
  export _LORE_HEADLESS_ARG_CONTRACT_WARNED="${_LORE_HEADLESS_ARG_CONTRACT_WARNED:-}${_LORE_HEADLESS_ARG_CONTRACT_WARNED:+ }$framework"
  echo "[lore] degraded: headless argument filter via headless_runner.argument_contract=no-evidence (framework '$framework' has no probed non-interactive argument surface; passing harness args through unfiltered)" >&2
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
# Emit the historical LORE_CLAUDE_ARGS deprecation notice at most once per
# shell. The variable is no longer read by load_harness_args.
_lore_warn_load_claude_env_once() {
  if [[ -z "${_LORE_LOAD_CLAUDE_ENV_WARNED:-}" ]]; then
    echo "lib.sh: LORE_CLAUDE_ARGS is deprecated; set LORE_HARNESS_ARGS instead (T9)." >&2
    export _LORE_LOAD_CLAUDE_ENV_WARNED=1
  fi
}

# --- _lore_runtime_framework_hint ---
# Print the harness implied by the process environment, when a harness exposes
# a stable shell marker. This catches multi-harness installs where a stored
# TUI launch preference reflects a different harness than the tool that spawned
# this shell.
#
# Keep this deliberately narrow:
#   - LORE_FRAMEWORK remains the explicit override and is handled by
#     resolve_active_framework before this helper.
#   - A caller-provided LORE_DATA_DIR usually means a hermetic test or scripted
#     config inspection; in that case do not infer from the parent app's
#     environment. The resolver will fall through to the built-in default
#     unless LORE_FRAMEWORK is explicit.
#   - OpenCode exposes OPENCODE_CLIENT as the CLI/client identity knob; treat it
#     as a runtime hint only when the caller has not redirected LORE_DATA_DIR.
_lore_runtime_framework_hint() {
  if [[ -n "${LORE_DATA_DIR:-}" ]]; then
    return 0
  fi

  if [[ "${CLAUDECODE:-}" == "1" || -n "${CLAUDE_CODE_SESSION_ID:-}" || -n "${CLAUDE_CODE_TEAM_NAME:-}" ]]; then
    echo "claude-code"
    return 0
  fi

  if [[ "${CODEX_SHELL:-}" == "1" || -n "${CODEX_THREAD_ID:-}" ]]; then
    echo "codex"
    return 0
  fi

  if [[ -n "${OPENCODE_CLIENT:-}" || -n "${OPENCODE_SESSION_ID:-}" ]]; then
    echo "opencode"
    return 0
  fi
}

# --- resolve_active_framework ---
# Print the active harness framework name on stdout.
# Resolution order:
#   1. LORE_FRAMEWORK env var (any non-empty value, validated against the
#      shipped capabilities.json frameworks set).
#   2. Runtime harness environment markers (Claude Code / Codex shell
#      subprocesses) when LORE_DATA_DIR is not explicitly redirected.
#   3. Built-in default: "claude-code".
#
# Deliberately does NOT read settings.json. The stored TUI launch preference
# lives at `tui_launch_framework` and is consumed by the TUI when it spawns chat
# / spec sessions; shell helpers resolve the *current process* harness from
# process-local evidence only.
# Unknown framework names are rejected with a non-zero exit and stderr message;
# resolution never silently routes to a default for an explicit-but-bogus value.
# Mirrors config.ResolveActiveFramework() in tui/internal/config/config.go (T10).
resolve_active_framework() {
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local candidate=""
  local source=""

  if [[ -n "${LORE_FRAMEWORK:-}" ]]; then
    candidate="$LORE_FRAMEWORK"
    source="env LORE_FRAMEWORK"
  else
    local runtime_hint
    runtime_hint=$(_lore_runtime_framework_hint 2>/dev/null || true)
    if [[ -n "$runtime_hint" ]]; then
      candidate="$runtime_hint"
      source="runtime harness environment"
    fi
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
# Print the support level for a capability on the active framework, or on an
# explicitly supplied framework.
# Output is one of: full | partial | fallback | none.
# Resolution order (first match wins):
#   1. Unified settings.json `capability_overrides.<cap>`.
#   2. adapters/capabilities.json `.frameworks.<framework>.capabilities.<cap>.support`
#      (static profile shipped with the repo). The framework is the optional
#      second arg, or resolve_active_framework when omitted.
#   3. Fallback: "none".
# Usage: level=$(framework_capability stop_hook [framework])
#        if [[ "$(framework_capability mcp)" == "full" ]]; then ...
# Mirrors config.FrameworkCapability() in tui/internal/config/config.go (T10).
framework_capability() {
  local cap="$1"
  [[ -z "$cap" ]] && { echo "Error: framework_capability requires a capability name" >&2; return 1; }
  local explicit_framework="${2:-}"

  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local active level

  if ! command -v jq &>/dev/null; then
    echo "none"
    return 0
  fi

  # 1a. User override — unified file (primary)
  local unified_raw
  unified_raw=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "capability_overrides.$cap" 2>/dev/null || true)
  if [[ -n "$unified_raw" ]]; then
    level=$(printf '%s' "$unified_raw" | jq -r '. // empty' 2>/dev/null)
    if [[ -n "$level" ]]; then
      echo "$level"
      return 0
    fi
  fi

  # 2. Static profile lookup, keyed by active framework.
  active="$explicit_framework"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework) || return 1
  fi
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
# `.frameworks.<framework>.capabilities.<cap>.evidence`. The framework is the
# optional second arg, or resolve_active_framework when omitted.
# Used by install.sh and assemble-instructions.sh to compose operator log
# lines that read the capability triple
# (install_paths.<kind>, capabilities.<kind>.support, capabilities.<kind>.evidence)
# in the shared `degraded:partial|fallback|none|no-evidence|unverified-support(<level>)`
# vocabulary defined in conventions/capability-cells-in-adapters-capabilities-json-sho.md.
framework_capability_evidence() {
  local cap="$1"
  [[ -z "$cap" ]] && { echo "Error: framework_capability_evidence requires a capability name" >&2; return 1; }
  local explicit_framework="${2:-}"

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    echo ""
    return 0
  fi

  local active
  active="$explicit_framework"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework) || return 1
  fi
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

# --- framework_interaction_field ---
# Print one field of a probed interaction-contract row from
# adapters/capabilities.json `.frameworks.<fw>.interaction.<row>.<field>`.
# Go counterpart: the interactionProfile rows in
# tui/internal/config/framework.go (HarnessGracefulExitSequence reads the
# graceful_exit_sequence row's `sequence`).
#
# Args: $1 = row, one of the closed interaction row set:
#         composer_signature | permission_prompt_signature | submit_sequence |
#         newline_sequence | honors_bracketed_paste | paste_multiline_semantics |
#         mid_generation_semantics | graceful_exit_sequence
#       $2 = field, e.g. sequence | matcher | value | support | evidence
#       $3 = framework id (optional; defaults to the active framework)
#
# Output: a single line on stdout, exit 0:
#   - The field value when the row+field resolve to a non-null JSON scalar.
#     `sequence` rows print the literal PTY bytes the caller writes verbatim
#     (\r=CR, \n=LF, 0x03=Ctrl-C, 0x1b=ESC); a legitimately-false boolean
#     (honors_bracketed_paste=false) prints `false`, not the degraded token.
#   - The literal `unsupported` when the framework has no interaction block, the
#     row is absent, or the field is null — with a `[lore] degraded:` notice on
#     stderr. Unlike framework_tui_launch_flag, an unknown/absent framework
#     degrades to `unsupported` rather than erroring: a harness without a probed
#     interaction row is the expected state for a newly-added harness, so the
#     send/close paths skip-with-notice instead of crashing. Callers MUST skip
#     rather than substitute a value from another harness.
#
# Exit codes:
#   0  value or `unsupported` printed.
#   1  unknown row (the row set is closed — an unknown row is a caller bug, not a
#      data gap), missing capabilities.json, or jq unavailable.
framework_interaction_field() {
  local row="$1"
  local field="$2"
  local framework="${3:-}"
  [[ -z "$row" ]] && { echo "Error: framework_interaction_field requires a row" >&2; return 1; }
  [[ -z "$field" ]] && { echo "Error: framework_interaction_field requires a field" >&2; return 1; }
  case "$row" in
    composer_signature|permission_prompt_signature|submit_sequence|newline_sequence|\
    honors_bracketed_paste|paste_multiline_semantics|mid_generation_semantics|graceful_exit_sequence) ;;
    *) echo "Error: unknown interaction row '$row' (allowed: composer_signature, permission_prompt_signature, submit_sequence, newline_sequence, honors_bracketed_paste, paste_multiline_semantics, mid_generation_semantics, graceful_exit_sequence)" >&2; return 1 ;;
  esac

  if ! command -v jq &>/dev/null; then
    echo "Error: framework_interaction_field requires jq" >&2
    return 1
  fi

  if [[ -z "$framework" ]]; then
    framework=$(resolve_active_framework) || return 1
  fi

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]]; then
    echo "Error: framework_interaction_field cannot read $capabilities_file" >&2
    return 1
  fi

  # `has_value` distinguishes an absent/null field (degrade) from a present
  # scalar (including a legitimate `false`), which a `// default` cannot.
  local present
  present=$(jq -r --arg fw "$framework" --arg r "$row" --arg f "$field" \
    '(.frameworks[$fw].interaction[$r][$f]) != null' "$capabilities_file" 2>/dev/null)
  if [[ "$present" != "true" ]]; then
    echo "[lore] degraded: interaction.$row.$field unavailable for framework '$framework' (no probed row); skipping" >&2
    echo "unsupported"
    return 0
  fi
  jq -r --arg fw "$framework" --arg r "$row" --arg f "$field" \
    '.frameworks[$fw].interaction[$r][$f]' "$capabilities_file" 2>/dev/null
}

# --- Session journal reading ---
# Shared by every verb that reads _sessions/events.jsonl through the reference
# reader (session-events.sh) rather than opening the file itself: session-wait.sh
# and coordinate-watch.sh today. Keeping the vocabulary mirror, the retry policy,
# and the cursor-alignment check here means a new watcher inherits them instead
# of re-deriving them slightly differently.

# Mirror of the sole writer's event vocabulary (session-event-append.sh's
# validation case-arm). tests/session-verbs.bats cross-checks this list against
# the writer and names any drift; if that test fails, reconcile this line with
# the writer rather than silencing the test.
SESSION_EVENT_VOCAB="requested claimed spawned needs_input resumed recovered closed orphaned step_completed terminus_reached spawn_failed request_reclaimed request_abandoned request_cancelled request_expired close_requested close_failed restore_refused worktree_quarantined worktree_published worktree_write_refused send_requested sent send_refused answer_requested answered answer_refused modal_blocked"

# The events a coordinator can actually do something about, and therefore the
# default stop set for anything that waits on the journal. It covers both ends of
# a session's life: the terminal outcomes teardown can reach (closed,
# close_failed, orphaned, worktree_quarantined) and the mid-stream edges where a
# session has parked and is waiting on somebody (needs_input, modal_blocked,
# restore_refused) or has finished its protocol without closing
# (terminus_reached). A stop set of terminal outcomes alone means an autonomous
# session parked at a prompt wakes nobody — the watcher sits there while the work
# does too. Narrow it with an explicit --until when you want exactly one edge.
SESSION_ACTIONABLE_EVENTS="closed close_failed orphaned request_expired terminus_reached needs_input modal_blocked restore_refused worktree_quarantined"

# session_event_in_vocab <name> — 0 when the writer would accept <name> as an
# event. Validating an event-name argument up front turns a typo into a usage
# error instead of a wait that can never end.
session_event_in_vocab() {
  local candidate="$1" known
  for known in $SESSION_EVENT_VOCAB; do
    [[ "$candidate" == "$known" ]] && return 0
  done
  return 1
}

# session_events_run <events_sh> [args...]
# Run the reference reader at most three times with a fixed 1s/2s backoff,
# echoing its stdout on the first success. The bound is deliberate: a caller
# waiting on the journal is a reader, not a supervisor, so a reader that stays
# broken becomes the caller's internal-error terminal rather than an endless
# retry. Returns 1 when all three attempts fail.
session_events_run() {
  local events_sh="$1"; shift
  local delays=(1 2) output attempt
  for attempt in 0 1 2; do
    if output="$(bash "$events_sh" "$@")"; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ $attempt -lt 2 ]]; then
      sleep "${delays[$attempt]}"
    fi
  done
  return 1
}

# session_events_read <events_sh> <kdir> <cursor>
# One incremental journal read from <cursor>, echoing the reference reader's
# {events, records, next_cursor} object. Composing the reader means torn-row and
# interior-malformed tolerance — and the refusal of a cursor the journal cannot
# honour — are inherited, not re-derived per caller.
session_events_read() {
  local events_sh="$1" kdir="$2" cursor="$3"
  session_events_run "$events_sh" --json --since "$cursor" --kdir "$kdir"
}

# session_events_cursor <events_sh> <kdir>
# The journal's current end offset — the baseline for "wake on what happens
# next". An O(1) stat through the reader, not a row replay.
session_events_cursor() {
  local events_sh="$1" kdir="$2"
  session_events_run "$events_sh" --cursor-only --kdir "$kdir"
}

# session_cursor_row_aligned <events_file> <cursor>
# 0 when <cursor> sits on a row boundary, 2 when it points into the middle of a
# row, 1 when the check itself could not run. A cursor is a row boundary, not an
# arbitrary byte offset: rejecting an interior offset here stops the tolerant
# reference reader from reading a valid row's suffix as corrupt JSON and
# reporting the caller's own bad input as journal damage. Past-EOF is the other
# way to miss a boundary and this check does not cover it: a cursor beyond the
# journal's end passes here and is refused by the reader itself, which holds the
# file length the refusal has to name.
session_cursor_row_aligned() {
  local events_file="$1" cursor="$2" status=0
  python3 - "$events_file" "$cursor" <<'PYEOF' || status=$?
import os, sys

path, cursor = sys.argv[1], int(sys.argv[2])
try:
    size = os.path.getsize(path)
except FileNotFoundError:
    size = 0
if cursor <= size:
    with open(path, "rb") as f:
        f.seek(cursor - 1)
        if f.read(1) != b"\n":
            raise SystemExit(2)
PYEOF
  return "$status"
}

# --- Scoping a journal reader to a set of work items ---

# SESSION_SCOPE_JQ_PREDICATE — jq program text defining `scope_state`, the shared
# two-key scope test. Apply it to one journal row (not to a `.records` entry) with
# the scope's slug array and a 0/1 flag for whether a scope was requested at all;
# it evaluates to {matched, unattributed}.
#
# Two keys, because the journal has two disjoint identity keys and neither covers
# every row: `.slug` identifies spec and implement sessions (whose slug is the
# work-item slug), `links.work_item` identifies worker sessions (the sole writer
# derives it from the `<work-item>--w<n>` slug shape). Matching only `.slug`
# silently drops every worker row.
#
# A row carrying neither key matches unconditionally and is reported
# `unattributed`. Such a row cannot be scoped in or out on the evidence it
# carries, and a scoping filter that dropped it would turn an actionable event
# into silence; the caller labels the wake instead.
SESSION_SCOPE_JQ_PREDICATE='
def scope_state($scoped; $slugs):
  (.slug // "") as $s
  | (.links.work_item // "") as $w
  | if ($s == "" and $w == "") then {matched: true, unattributed: true}
    elif $scoped == 0 then {matched: true, unattributed: false}
    elif ($s != "" and ($slugs | index($s)) != null) then {matched: true, unattributed: false}
    elif ($w != "" and ($slugs | index($w)) != null) then {matched: true, unattributed: false}
    else {matched: false, unattributed: false}
    end;
'

# session_arc_member_slugs <kdir> <arc-slug>
# Print an arc's declared member slugs, one per line, for expansion into a scope.
#
# Membership is whatever the record's `members[]` lists. A work item carrying the
# arc's project label is NOT a member: labels and membership are separate, and
# records with an empty `members[]` alongside several labeled items are a live
# case, so a label join would silently widen the scope.
#
# A watcher may expand only an active arc. Closed is terminal for watcher
# firings: accepting it here lets a stale installed entry keep opening windows
# after the arc has ended. The record omits keys it has no value for rather than
# storing null, so every field is read defensively.
#
# Exit: 0 listed (possibly nothing), 1 no such record, 2 record unparseable,
#       3 record status is not active.
session_arc_member_slugs() {
  local kdir="$1" arc="$2"
  python3 - "$kdir" "$arc" <<'PYEOF'
import json, os, sys

kdir, arc = sys.argv[1], sys.argv[2]
path = os.path.join(kdir, "_work", "_arcs", arc, "_meta.json")
if not os.path.isfile(path):
    raise SystemExit(1)
try:
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(2)
if not isinstance(record, dict):
    raise SystemExit(2)
if record.get("status") != "active":
    raise SystemExit(3)
for member in record.get("members") or []:
    if isinstance(member, str) and member:
        print(member)
PYEOF
}

# --- Canonical watcher identity ---------------------------------------------

# canonical_existing_dir <path>
# Resolve one existing directory to an absolute physical path. This is the
# store-path rule carried by installed watcher commands: symlink spellings and
# relative spellings collapse before they become identity.
canonical_existing_dir() {
  local path="$1"
  [[ -d "$path" ]] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

# shell_quote_arg <value>
# Quote one runtime value for round-tripping through the command string stored
# in a harness settings file. shlex.quote and shlex.split are the paired writer
# and reader for watcher identity.
shell_quote_arg() {
  python3 - "$1" <<'PYEOF'
import shlex, sys
print(shlex.quote(sys.argv[1]), end="")
PYEOF
}

# watcher_identity_hash <kdir> <owner-kind> <owner-value> <tmux-server> [arc...]
# The arcs are normalized again here so every sidecar caller gets an
# order-insensitive, duplicate-insensitive identity even if its argument parser
# forgot to normalize first. The JSON tuple is the canonical hash encoding.
watcher_identity_hash() {
  python3 - "$@" <<'PYEOF'
import hashlib, json, sys

kdir, owner_kind, owner_value, tmux_server, *arcs = sys.argv[1:]
identity = ["watcher-identity-v1", kdir, owner_kind, owner_value,
            tmux_server if owner_kind == "tmux" else "", sorted(set(arcs))]
encoded = json.dumps(identity, ensure_ascii=False, separators=(",", ":"))
print(hashlib.sha256(encoded.encode("utf-8")).hexdigest()[:16])
PYEOF
}

# --- Owner liveness for a watcher ---

# session_owner_alive <pid> <tmux_name> [tmux_server]
# 0 when at least one handle PROVES the owner process is still there, 1 otherwise.
# Either handle may be empty; with both empty the answer is 1.
#
# This is the stop-biased reading of the same two handles the coordination seat
# lease records. The lease treats an unknowable answer (EPERM, no tmux binary) as
# alive, because reclaiming a live seat's checkout destroys work. A watcher's
# false positive is the opposite failure — it keeps running with nothing left to
# report to — so here unknowable does not count as alive. `kill -0` gives that
# for free: it fails on EPERM as well as on a reaped pid.
#
# Callers must still treat this as a hint, not a verdict: prove-death paths lag
# the journal during teardown, so pair a not-alive answer with a grace period and
# one final authoritative read before acting on it.
session_owner_alive() {
  local pid="${1:-}" tmux_name="${2:-}" tmux_server="${3:-lore-tui}"
  if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
    kill -0 "$pid" 2>/dev/null && return 0
  fi
  if [[ -n "$tmux_name" ]] && command -v tmux >/dev/null 2>&1; then
    tmux -L "${tmux_server:-lore-tui}" has-session -t "$tmux_name" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# --- Classifying a parked session from its rendered screen ---

# The events after which a session has stopped and is waiting on somebody, and
# the row alone cannot say whether it is still waiting now. Every other actionable
# event states its own outcome, so the row is the authority and no screen read is
# warranted.
SESSION_PARK_SHAPED_EVENTS="needs_input modal_blocked"

# Version of the signature set session_park_classify accepts. It travels in the
# consumer's output so a matcher-contract change surfaces there instead of
# silently reclassifying parks. Bump it whenever the accepted set below changes.
SESSION_PARK_SIGNATURE_VERSION=3

# session_park_classify <trigger> <ready> <blocked_reason>
# Compare one peek result against the strict signature set for <trigger> and print
# "<verdict><TAB><label>" (exit 0 either way).
#
#   verdict  `confirmed` when the screen strictly agrees the session is still
#            parked; `unconfirmed` otherwise.
#   label    which signature fired, or the reason none did. An unconfirmed park
#            is a labeled result, never a dropped one — the label is what the
#            caller reports.
#
# <trigger> is the journal event that put the question: "this row says the session
# parked; is it still parked?"
#
# <ready> is a peek response's `.ready` (`true`/`false`) and <blocked_reason> its
# `.blocked_reason`, whose vocabulary is the send/peek readiness gate's:
# generating, modal, no-signature, no-contract, error.
#
# The strict sets are deliberately narrow. A session that emitted modal_blocked
# but renders as generating is not parked now — on some harnesses that row fires
# at turn cadence on healthy sessions — so it does not confirm.
session_park_classify() {
  local trigger="$1" ready="$2" reason="$3"
  case "$trigger" in
    modal_blocked)
      if [[ "$ready" == "false" && "$reason" == "modal" ]]; then
        printf 'confirmed\tmodal-signature\n'
        return 0
      fi
      ;;
    needs_input)
      if [[ "$ready" == "true" ]]; then
        printf 'confirmed\tcomposer-awaiting-input\n'
        return 0
      fi
      if [[ "$reason" == "modal" ]]; then
        printf 'confirmed\tmodal-signature\n'
        return 0
      fi
      ;;
  esac
  case "$reason" in
    generating)   printf 'unconfirmed\tscreen-reports-generating\n' ;;
    no-signature) printf 'unconfirmed\tmatcher-found-no-known-signature\n' ;;
    no-contract)  printf 'unconfirmed\tharness-has-no-gate-contract\n' ;;
    error)        printf 'unconfirmed\tscreen-read-failed\n' ;;
    '')           printf 'unconfirmed\tpeek-returned-no-reason\n' ;;
    *)            printf 'unconfirmed\tunrecognized-blocked-reason\n' ;;
  esac
}

# --- How long a session has been running, from its own start row ---

# The strict park signatures read the screen, and between a pane being spawned
# and its first prompt being submitted a session renders a genuinely ready
# composer. The signature is truthful about the screen and wrong about the
# session: "not started yet" and "stopped, waiting on somebody" look identical
# there. Nothing else on the screen separates them, so the discriminator has to
# come from the journal — how old the session is.
#
# session_events_start_age <events_sh> <kdir> <slug> <ref_ts> <lookback>
# Echo whole seconds from <slug>'s most recent `spawned`/`claimed` row to
# <ref_ts>, when such a row lies within the <lookback>-second window ending at
# <ref_ts>.
#
# Exit: 0 age printed; 1 no start row inside the window (the session started
#       before it, or its start predates the journal); 2 the age could not be
#       determined at all (unparseable <ref_ts>, or the reference reader failed).
#       Callers must tell 1 and 2 apart: 1 is evidence the session is old, 2 is
#       the absence of evidence either way.
#
# The window is what keeps this bounded. A confirmed park only needs to know
# whether the session is younger than <lookback>, so the read is capped at that
# span of journal rather than replaying history back to the store's first row.
session_events_start_age() {
  local events_sh="$1" kdir="$2" slug="$3" ref_ts="$4" lookback="$5"
  local bounds window_start window_end payload age

  bounds="$(python3 - "$ref_ts" "$lookback" <<'PYEOF'
import sys
from datetime import datetime, timedelta, timezone

raw, lookback = sys.argv[1], float(sys.argv[2])
text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
try:
    ref = datetime.fromisoformat(text)
except ValueError:
    raise SystemExit(1)
if ref.tzinfo is None:
    ref = ref.replace(tzinfo=timezone.utc)
ref = ref.astimezone(timezone.utc)
# The reader's window is half-open, so the end is nudged one second past the
# reference row: a start row sharing that row's second belongs inside it.
fmt = "%Y-%m-%dT%H:%M:%SZ"
print((ref - timedelta(seconds=lookback)).strftime(fmt))
print((ref + timedelta(seconds=1)).strftime(fmt))
PYEOF
)" || return 2
  { IFS= read -r window_start; IFS= read -r window_end; } <<< "$bounds"
  [[ -n "$window_start" && -n "$window_end" ]] || return 2

  payload="$(session_events_run "$events_sh" --json \
    --window-start "$window_start" --window-end "$window_end" --kdir "$kdir")" || return 2

  # The payload rides an environment variable because the script itself owns
  # this python's stdin.
  age="$(SESSION_START_AGE_PAYLOAD="$payload" python3 - "$slug" "$ref_ts" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

slug, raw_ref = sys.argv[1], sys.argv[2]
START_EVENTS = ("spawned", "claimed")


def parse(value):
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    stamp = datetime.fromisoformat(text)
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


try:
    payload = json.loads(os.environ.get("SESSION_START_AGE_PAYLOAD") or "")
    ref = parse(raw_ref)
except ValueError:
    raise SystemExit(2)
if not isinstance(payload, dict):
    raise SystemExit(2)

latest = None
for row in payload.get("events") or []:
    if not isinstance(row, dict):
        continue
    if row.get("event") not in START_EVENTS or row.get("slug") != slug:
        continue
    stamp = row.get("ts")
    if not isinstance(stamp, str):
        continue
    try:
        parsed = parse(stamp)
    except ValueError:
        continue
    # The nudged window end can admit rows after the reference row; a start that
    # has not happened yet cannot be the start of the run being measured.
    if parsed > ref:
        continue
    if latest is None or parsed > latest:
        latest = parsed

if latest is None:
    raise SystemExit(1)
print(int((ref - latest).total_seconds()))
PYEOF
)" || return $?
  [[ -n "$age" ]] || return 2
  printf '%s\n' "$age"
}

# --- canonical_session_slug ---
# Convert the human-rendered generated-chat handle chat:<suffix> back to the
# durable registry slug chat-<suffix>. Every other slug is returned byte-for-byte,
# so spec/implement/worker addressing semantics are unchanged.
canonical_session_slug() {
  local slug="$1"
  case "$slug" in
    chat:*) printf 'chat-%s\n' "${slug#chat:}" ;;
    *) printf '%s\n' "$slug" ;;
  esac
}

# --- resolve_session_owner ---
# Echo the name of the single live TUI instance whose registry row hosts <slug>,
# or nothing when none is live within <ttl_seconds>. The owning instance is the
# one that must act on a close/send/peek request for that slug — the ptmx is
# process-local, so exactly one instance is ever eligible. Requires python3.
#
# Args: $1 = instances dir ($SESSIONS_DIR/instances), $2 = slug, $3 = ttl seconds.
resolve_session_owner() {
  local instances_dir="$1"
  local slug="$2"
  local ttl="$3"
  python3 - "$instances_dir" "$slug" "$ttl" <<'PYEOF'
import json, os, sys, time

instances_dir, slug, ttl = sys.argv[1], sys.argv[2], float(sys.argv[3])
now = time.time()
if os.path.isdir(instances_dir):
    for name in sorted(os.listdir(instances_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(instances_dir, name)
        try:
            if (now - os.path.getmtime(path)) > ttl:
                continue
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError):
            continue
        for sess in row.get("sessions") or []:
            if sess.get("slug") == slug:
                print(row.get("name", ""))
                sys.exit(0)
PYEOF
}

# --- resolve_session_by_id ---
# Address a live session by its harness session_id — the only stable handle a
# slugless session carries — where resolve_session_owner keys on slug. A slugless
# session has an empty slug, so slug is unusable as a target; session_id is not.
# Matches the given id as a full value OR an unambiguous leading prefix across the
# live registry, so a coordinator can paste the short form `lore session list`
# renders (chat:<8-hex-of-id>) without the full UUID.
#
# The result is a single status line on stdout (exit 0 in every case — the caller
# branches on the token, never on exit status). A richer contract than
# resolve_session_owner's empty-means-none because this resolver must also express
# refusal on an ambiguous prefix, which the slug resolver never had to:
#   MATCH<TAB><instance><TAB><slug>   one live session matched; slug is the
#                                     matched session's own slug, empty for a
#                                     slugless session. The caller writes it
#                                     verbatim into the close-request row so the
#                                     TUI consumer (which keys teardown off slug)
#                                     acts on it — session_id is resolution input,
#                                     not a row field.
#   NONE                              no live session matched.
#   AMBIGUOUS<TAB><id>,<id>,...       the prefix matched more than one live
#                                     session; the caller refuses and names the
#                                     colliding ids. An exact full-id match is
#                                     never ambiguous even if it is also a prefix
#                                     of another id.
# Requires python3.
#
# Args: $1 = instances dir, $2 = session_id (full or leading prefix), $3 = ttl.
resolve_session_by_id() {
  local instances_dir="$1"
  local session_id="$2"
  local ttl="$3"
  python3 - "$instances_dir" "$session_id" "$ttl" <<'PYEOF'
import json, os, sys, time

instances_dir, sid, ttl = sys.argv[1], sys.argv[2], float(sys.argv[3])
now = time.time()
matches = []  # (instance_name, slug, full_session_id)
if sid and os.path.isdir(instances_dir):
    for name in sorted(os.listdir(instances_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(instances_dir, name)
        try:
            if (now - os.path.getmtime(path)) > ttl:
                continue
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError):
            continue
        for sess in row.get("sessions") or []:
            row_sid = sess.get("session_id") or ""
            if row_sid and (row_sid == sid or row_sid.startswith(sid)):
                matches.append((row.get("name", ""), sess.get("slug") or "", row_sid))

# A complete id the caller typed in full is an unambiguous target even if it is a
# leading prefix of some other id (impossible for equal-length UUIDs, guarded
# anyway so pasting a whole id always resolves).
exact = [m for m in matches if m[2] == sid]
if len(exact) == 1:
    matches = exact

if not matches:
    print("NONE")
elif len(matches) > 1:
    print("AMBIGUOUS\t" + ",".join(sorted(m[2] for m in matches)))
else:
    inst, slug, _ = matches[0]
    print("MATCH\t" + inst + "\t" + slug)
PYEOF
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

  # LORE_REPO_DIR is the physical lore-repo root (resolved through symlinks
  # at lib.sh source time). Renders adapter paths as "<repo>/adapters/..."
  # without the "<repo>/scripts/../adapters/..." round-trip and without
  # tripping on symlinked installs (e.g. ~/.lore/scripts -> /path/to/repo/scripts).
  local repo_root="$LORE_REPO_DIR"
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

# --- dispatch guidance -----------------------------------------------------
# These are the shared prompt-assembly seams for repository-owned dispatch
# producers. Keep callers out of the renderer/validator filenames so the
# schema can evolve behind one stable shell contract.
render_dispatch_guidance() {
  bash "$LORE_LIB_DIR/render-dispatch-guidance.sh" "$@"
}

validate_dispatch_guidance() {
  bash "$LORE_LIB_DIR/validate-dispatch-guidance.sh" "$@"
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
  local explicit_framework="${1:-}"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local active shape

  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    echo "single"
    return 0
  fi
  active="$explicit_framework"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework) || return 1
  fi
  shape=$(jq -r --arg fw "$active" '.frameworks[$fw].model_routing.shape // "single"' "$capabilities_file" 2>/dev/null)
  echo "${shape:-single}"
}

# --- framework_model_routing_tiers ---
# Print the framework's ordered model-tier aliases, one per line, in
# ascending capability order. Reads adapters/capabilities.json
# `.frameworks.<fw>.model_routing.tiers`. Optional $1 selects an explicit
# framework; default is the active framework. A missing or empty tiers
# array prints nothing — no default ladder is guessed, because the alias
# strings are consumed verbatim by harness spawns and a wrong guess fails
# only at audit time. Go counterpart: the capabilities profile's
# ModelRouting.Tiers in tui/internal/config.
framework_model_routing_tiers() {
  local explicit_framework="${1:-}"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  local active

  if ! command -v jq &>/dev/null || [[ ! -f "$capabilities_file" ]]; then
    return 0
  fi
  active="$explicit_framework"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework) || return 1
  fi
  jq -r --arg fw "$active" '(.frameworks[$fw].model_routing.tiers // [])[] | select(type == "string")' "$capabilities_file" 2>/dev/null
}

# --- framework_spend_telemetry_field ---
# Print one scalar field of the per-framework spend_telemetry sibling block from
# adapters/capabilities.json `.frameworks.<fw>.spend_telemetry.<field>`.
# spend_telemetry is a framework-root sibling of model_routing and interaction
# describing how a harness exposes token spend: `support` (closed level set),
# `evidence` (id resolving in capabilities-evidence.md), `artifact`
# (transcript | rollout | store — the source kind), and `binding`
# (session-id-flag | none — the spawn-time join mechanism). Go counterpart:
# the spendTelemetry struct in tui/internal/config/framework.go.
#
# Args: $1 = field, one of: support | evidence | artifact | binding | notes
#       $2 = framework id (optional; defaults to the active framework)
#
# Output: a single line on stdout, exit 0:
#   - The field value when it resolves to a non-null JSON scalar.
#   - The literal `unsupported` when the framework has no spend_telemetry block
#     or the field is absent/null — with a `[lore] degraded:` notice on stderr.
#     A harness without a probed spend row is the expected state for a newly
#     added harness, so callers (session-spend.sh) fall back to duration-only
#     rather than crashing.
#
# Exit codes:
#   0  value or `unsupported` printed.
#   1  unknown field (the field set is closed), missing capabilities.json, or jq
#      unavailable.
framework_spend_telemetry_field() {
  local field="$1"
  local framework="${2:-}"
  [[ -z "$field" ]] && { echo "Error: framework_spend_telemetry_field requires a field" >&2; return 1; }
  case "$field" in
    support|evidence|artifact|binding|notes) ;;
    *) echo "Error: unknown spend_telemetry field '$field' (allowed: support, evidence, artifact, binding, notes)" >&2; return 1 ;;
  esac

  if ! command -v jq &>/dev/null; then
    echo "Error: framework_spend_telemetry_field requires jq" >&2
    return 1
  fi

  if [[ -z "$framework" ]]; then
    framework=$(resolve_active_framework) || return 1
  fi

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]]; then
    echo "Error: framework_spend_telemetry_field cannot read $capabilities_file" >&2
    return 1
  fi

  local present
  present=$(jq -r --arg fw "$framework" --arg f "$field" \
    '(.frameworks[$fw].spend_telemetry[$f]) != null' "$capabilities_file" 2>/dev/null)
  if [[ "$present" != "true" ]]; then
    echo "[lore] degraded: spend_telemetry.$field unavailable for framework '$framework' (no probed row); skipping" >&2
    echo "unsupported"
    return 0
  fi
  jq -r --arg fw "$framework" --arg f "$field" \
    '.frameworks[$fw].spend_telemetry[$f]' "$capabilities_file" 2>/dev/null
}

# --- resolve_model_for_role ---
# Print the resolved model id for a role on stdout.
# Role MUST be one of the closed set in adapters/roles.json (see T3); unknown
# roles are rejected with a non-zero exit at the top level AND the harness
# overlay layer (D3b closed-set rejection: an unknown id in
# `harnesses.<active>.roles` is the same error class as in `roles.<id>`).
# The "default" role is the resolution fallback consumed internally by this
# helper and is also a valid explicit role id.
# The optional second argument is a ceremony id from the closed set in
# adapters/ceremonies.json (`spec`, `implement`). When present it inserts a
# ceremony-scoped overlay between the per-repo config and the role overlay;
# when absent the ceremony layer is skipped entirely (role-only resolution is
# byte-identical to the pre-ceremony behavior). Same closed-set rejection
# applies at the ceremony layer to an unknown ceremony id (in the query or
# stored under `ceremony_roles`) and an unknown role id stored inside a
# ceremony map.
# Resolution order (first match wins):
#   1. Env var LORE_MODEL_<ROLE_UPPER> (e.g., LORE_MODEL_LEAD=opus).
#   2. Per-repo .lore.config `model_for_<role>=<model>` (walk-up search from
#      cwd; same lookup mechanism as resolve_knowledge_dir).
#   3. Unified settings.json `.harnesses.<active>.ceremony_roles.<ceremony>.<role>`
#      (only consulted when a ceremony argument is passed; absent binding
#      falls through).
#   4. Unified settings.json `.harnesses.<active>.roles.<role>` (D3b overlay
#      — applies to the active harness only; absent overlay falls through).
#   4b. Class-qualified role fallback: if the role declares a `fallback_role` in
#      roles.json and layers 1-4 all missed, re-resolve once with that role (so
#      an unbound worker-mechanical resolves exactly as plain worker). Runs
#      before layer 5 so the fallback role consults its own overlay binding
#      ahead of the shared default.
#   5. Unified `.harnesses.<active>.roles.default` (overlay's own default).
# Mirrors config.ResolveModelForRoleInCeremony() in tui/internal/config/framework.go.
resolve_model_for_role() {
  local role="$1"
  local ceremony="${2:-}"
  [[ -z "$role" ]] && { echo "Error: resolve_model_for_role requires a role name" >&2; return 1; }

  local roles_file="$LORE_LIB_DIR/../adapters/roles.json"
  local ceremonies_file="$LORE_LIB_DIR/../adapters/ceremonies.json"
  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"

  # Validate role against the closed registry, and read its optional
  # fallback_role in the same pass. A class-qualified role (worker-mechanical,
  # worker-judgment-dense) declares fallback_role: "worker"; when the role's own
  # layers all miss short of the overlay default, the resolver re-resolves once
  # with that role (see the fallback step below). Empty when the role has no
  # fallback or roles.json/jq is unavailable, matching the pre-class behavior.
  local fallback_role=""
  if [[ -f "$roles_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg r "$role" '.roles[] | select(.id == $r)' "$roles_file" &>/dev/null; then
      echo "Error: unknown role '$role' (not in $roles_file)" >&2
      return 1
    fi
    fallback_role=$(jq -r --arg r "$role" '.roles[] | select(.id == $r) | .fallback_role // empty' "$roles_file" 2>/dev/null)
  fi

  # Validate the ceremony query against the closed registry. Mirrors the role
  # query guard above — a malformed ceremony id is rejected upfront, before the
  # env/per-repo layers, so an unknown ceremony never resolves regardless of
  # env override.
  if [[ -n "$ceremony" && -f "$ceremonies_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg c "$ceremony" '.ceremonies[] | select(.id == $c)' "$ceremonies_file" &>/dev/null; then
      echo "Error: unknown ceremony '$ceremony' (not in $ceremonies_file)" >&2
      return 1
    fi
  fi

  # 1. Env var override: LORE_MODEL_<ROLE_UPPER>.
  # Indirect expansion via eval rather than ${!var} — the latter is bash-only
  # and trips zsh with "bad substitution" when this library is sourced from
  # the harness shell (see lib.sh top-of-file comment on shell support).
  # Hyphens in the role id (class-qualified roles like worker-mechanical) are
  # mapped to underscores in the env-var name so the name is a valid shell
  # identifier — without this, `${LORE_MODEL_WORKER-MECHANICAL:-}` triggers the
  # ${param-word} default operator on LORE_MODEL_WORKER instead of a lookup.
  local env_var="LORE_MODEL_$(echo "$role" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  local env_value=""
  eval "env_value=\${$env_var:-}"
  if [[ -n "$env_value" ]]; then
    echo "$env_value"
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

  command -v jq &>/dev/null || {
    echo "Error: resolve_model_for_role requires jq" >&2
    return 1
  }

  # Resolve active harness once for the overlay layer.
  local active=""
  active=$(resolve_active_framework 2>/dev/null) || active=""

  # 3. Ceremony overlay `.harnesses.<active>.ceremony_roles.<ceremony>.<role>`.
  # Consulted only when a ceremony argument is passed, so role-only resolution
  # is byte-identical to the pre-ceremony behavior. Closed-set rejection here
  # mirrors the role overlay guard below: any unknown ceremony key or unknown
  # role key stored under ceremony_roles is a misconfiguration the user should
  # see, not a silently-ignored block.
  if [[ -n "$ceremony" && -n "$active" && -f "$ceremonies_file" && -f "$roles_file" ]]; then
    local ceremony_block
    ceremony_block=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.ceremony_roles" 2>/dev/null || true)
    if [[ -n "$ceremony_block" ]]; then
      local valid_ceremony_ids
      valid_ceremony_ids=$(jq -c '[.ceremonies[].id]' "$ceremonies_file" 2>/dev/null)
      [[ -z "$valid_ceremony_ids" || "$valid_ceremony_ids" == "null" ]] && valid_ceremony_ids="[]"
      local bad_ceremony
      bad_ceremony=$(printf '%s' "$ceremony_block" | jq -r --argjson valid "$valid_ceremony_ids" \
        '(keys) - $valid | .[]' 2>/dev/null | head -1)
      if [[ -n "$bad_ceremony" ]]; then
        echo "Error: unknown ceremony '$bad_ceremony' in harnesses.$active.ceremony_roles (not in $ceremonies_file)" >&2
        return 1
      fi

      local valid_role_ids_c
      valid_role_ids_c=$(jq -c '[.roles[].id]' "$roles_file" 2>/dev/null)
      [[ -z "$valid_role_ids_c" || "$valid_role_ids_c" == "null" ]] && valid_role_ids_c="[]"
      local bad_ceremony_role
      bad_ceremony_role=$(printf '%s' "$ceremony_block" | jq -r --argjson valid "$valid_role_ids_c" \
        '[.[] | keys[]] - $valid | .[]' 2>/dev/null | head -1)
      if [[ -n "$bad_ceremony_role" ]]; then
        echo "Error: unknown role '$bad_ceremony_role' in harnesses.$active.ceremony_roles (not in $roles_file)" >&2
        return 1
      fi
    fi

    local ceremony_raw
    ceremony_raw=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.ceremony_roles.$ceremony.$role" 2>/dev/null || true)
    if [[ -n "$ceremony_raw" ]]; then
      local ceremony_value
      ceremony_value=$(printf '%s' "$ceremony_raw" | jq -r '. // empty' 2>/dev/null)
      if [[ -n "$ceremony_value" ]]; then
        echo "$ceremony_value"
        return 0
      fi
    fi
  fi

  # D3b closed-set rejection at the overlay layer: any unknown role id
  # (anything not in adapters/roles.json) found under
  # `harnesses.<active>.roles` is rejected immediately. The role validation
  # above already rejects an unknown role in the *query*; this guard rejects
  # an unknown id stored in the overlay block itself, which would otherwise
  # silently never be consulted (a misconfiguration the user should see).
  if [[ -n "$active" && -f "$roles_file" ]]; then
    local overlay_keys
    overlay_keys=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.roles" 2>/dev/null || true)
    if [[ -n "$overlay_keys" ]]; then
      local valid_role_ids
      valid_role_ids=$(jq -c '[.roles[].id]' "$roles_file" 2>/dev/null)
      [[ -z "$valid_role_ids" || "$valid_role_ids" == "null" ]] && valid_role_ids="[]"
      local bad
      bad=$(printf '%s' "$overlay_keys" | jq -r --argjson valid "$valid_role_ids" \
        '(keys) - $valid | .[]' 2>/dev/null | head -1)
      if [[ -n "$bad" ]]; then
        echo "Error: unknown role '$bad' in harnesses.$active.roles (not in $roles_file)" >&2
        return 1
      fi
    fi
  fi

  # 4. Unified settings.json `.harnesses.<active>.roles.<role>` (D3b overlay)
  local overlay_value=""
  if [[ -n "$active" ]]; then
    local raw
    raw=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.roles.$role" 2>/dev/null || true)
    if [[ -n "$raw" ]]; then
      overlay_value=$(printf '%s' "$raw" | jq -r '. // empty' 2>/dev/null)
      if [[ -n "$overlay_value" ]]; then
        echo "$overlay_value"
        return 0
      fi
    fi
  fi

  # Class-qualified role fallback: a role that declares fallback_role re-resolves
  # once with that role after all of its own layers (env, per-repo, ceremony
  # overlay, role overlay) miss short of the shared overlay default. This makes
  # an unbound class-qualified role resolve byte-identically to its fallback
  # (worker-mechanical == worker); a class role bound at any layer above still
  # wins. Placed before roles.default so the fallback role gets its own overlay
  # binding before the shared default is consulted. The fallback target declares
  # no fallback_role of its own, so this re-resolution runs at most once.
  if [[ -n "$fallback_role" ]]; then
    resolve_model_for_role "$fallback_role" "$ceremony"
    return $?
  fi

  # 5. Unified `.harnesses.<active>.roles.default` (overlay's own default)
  if [[ -n "$active" ]]; then
    local raw_default
    raw_default=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.roles.default" 2>/dev/null || true)
    if [[ -n "$raw_default" ]]; then
      local default_value
      default_value=$(printf '%s' "$raw_default" | jq -r '. // empty' 2>/dev/null)
      if [[ -n "$default_value" ]]; then
        echo "$default_value"
        return 0
      fi
    fi
  fi

  echo "Error: no model binding for role '$role' (no env var, no per-repo .lore.config entry, no harnesses.<active>.roles.$role or harnesses.<active>.roles.default in settings.json)" >&2
  return 1
}

# --- resolve_route_for_role ---
# Resolve the existing scalar role binding, then interpret an optional leading
# framework id from adapters/capabilities.json. The scalar resolver above is
# deliberately unchanged; this sibling returns the non-lossy route as compact
# JSON for orchestration callers.
#
# Output keys: binding, source_framework, target_framework, native_binding,
# qualified. Go counterpart: config.ResolveRouteForRoleInCeremony.
_model_route_json() {
  local role="$1"
  local binding="$2"
  [[ -z "$role" ]] && { echo "Error: resolve_route_for_role requires a role name" >&2; return 1; }
  [[ -z "$binding" ]] && { echo "Error: role '$role' has empty model binding" >&2; return 1; }

  if ! command -v jq &>/dev/null; then
    echo "Error: resolve_route_for_role requires jq" >&2
    return 1
  fi

  local roles_file="$LORE_LIB_DIR/../adapters/roles.json"
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]]; then
    echo "Error: resolve_route_for_role cannot read $capabilities_file" >&2
    return 1
  fi
  if [[ -f "$roles_file" ]] && ! jq -e --arg r "$role" '.roles[] | select(.id == $r)' "$roles_file" &>/dev/null; then
    echo "Error: unknown role '$role' (not in $roles_file)" >&2
    return 1
  fi

  local source target native prefix qualified shape
  source=$(resolve_active_framework) || return 1
  target="$source"
  native="$binding"
  qualified="false"

  if [[ "$binding" == */* ]]; then
    prefix="${binding%%/*}"
    if jq -e --arg fw "$prefix" '.frameworks[$fw] != null' "$capabilities_file" &>/dev/null; then
      target="$prefix"
      native="${binding#*/}"
      qualified="true"
      if [[ -z "$native" ]]; then
        echo "Error: role '$role' binding '$binding' has an empty native binding after framework qualifier '$target/'" >&2
        return 1
      fi
    fi
  fi

  shape=$(jq -r --arg fw "$target" '.frameworks[$fw].model_routing.shape // "single"' "$capabilities_file" 2>/dev/null)
  if [[ "$native" == */* && "$shape" != "multi" ]]; then
    if [[ "$qualified" == "true" ]]; then
      echo "Error: role '$role' binding '$binding' has native binding '$native' but target framework '$target' has model_routing.shape=$shape (single-provider harnesses require a bare model binding)" >&2
    else
      echo "Error: role '$role' binding '$binding' names a provider but the active harness '$source' has model_routing.shape=$shape (single-provider harnesses cannot serve cross-provider bindings)." >&2
    fi
    return 1
  fi

  # The only implemented foreign bridge is the Codex worker chaperone. Same-
  # framework qualification is always native; every other foreign pair fails
  # before a source adapter can mistake the framework id for a provider id.
  if [[ "$source" != "$target" && "$target" != "codex" ]]; then
    echo "Error: unsupported framework bridge '$source->$target' for role '$role' binding '$binding'" >&2
    return 1
  fi

  jq -cn \
    --arg binding "$binding" \
    --arg source_framework "$source" \
    --arg target_framework "$target" \
    --arg native_binding "$native" \
    --argjson qualified "$qualified" \
    '{binding: $binding, source_framework: $source_framework, target_framework: $target_framework, native_binding: $native_binding, qualified: $qualified}'
}

resolve_route_for_role() {
  local role="$1"
  local ceremony="${2:-}"
  local binding
  [[ -z "$role" ]] && { echo "Error: resolve_route_for_role requires a role name" >&2; return 1; }
  binding=$(resolve_model_for_role "$role" ${ceremony:+"$ceremony"}) || return 1
  _model_route_json "$role" "$binding"
}

# --- resolve_harness_install_path ---
# Print the install path for a kind on the active framework (or optional
# explicit framework), with $HOME and similar shell-style references expanded.
# Closed kind set: instructions | skills | agents | settings |
#                  watcher_settings | teams | ephemeral_plans | mcp_servers
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
  local explicit_framework="${2:-}"

  case "$kind" in
    instructions|skills|agents|settings|watcher_settings|teams|ephemeral_plans|mcp_servers) ;;
    *)
      echo "Error: unknown kind '$kind' (allowed: instructions, skills, agents, settings, watcher_settings, teams, ephemeral_plans, mcp_servers)" >&2
      return 1
      ;;
  esac

  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if [[ ! -f "$capabilities_file" ]] || ! command -v jq &>/dev/null; then
    echo "Error: cannot read $capabilities_file (or jq unavailable)" >&2
    return 1
  fi

  local active raw
  active="$explicit_framework"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework) || return 1
  fi
  raw=$(jq -r --arg fw "$active" --arg k "$kind" '.frameworks[$fw].install_paths[$k] // empty' "$capabilities_file" 2>/dev/null)

  if [[ -z "$raw" ]]; then
    echo "Error: no install_paths.$kind defined for framework '$active' in $capabilities_file" >&2
    return 1
  fi

  if [[ "$raw" == "unsupported" ]]; then
    echo "unsupported"
    return 0
  fi

  # Expand the two declared roots. $HOME is the user-global install surface;
  # $PROJECT_ROOT is the physical git worktree root at call time and exists for
  # project-local surfaces such as Claude's settings.local.json.
  local expanded="$raw"
  expanded="${expanded//\$HOME/$HOME}"
  expanded="${expanded//\$\{HOME\}/$HOME}"
  if [[ "$expanded" == *'$PROJECT_ROOT'* || "$expanded" == *'${PROJECT_ROOT}'* ]]; then
    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      echo "Error: install_paths.$kind requires a git project root" >&2
      return 1
    }
    project_root="$(canonical_existing_dir "$project_root")" || return 1
    expanded="${expanded//\$PROJECT_ROOT/$project_root}"
    expanded="${expanded//\$\{PROJECT_ROOT\}/$project_root}"
  fi
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

# --- list_supported_frameworks ---
# Print the registered framework keys from adapters/capabilities.json, one per
# line, sorted lexicographically. Fatal (die) if jq is unavailable or the file
# cannot be read. Both enable.sh and disable.sh use this as the authoritative
# source for multi-harness fanout.
list_supported_frameworks() {
  local capabilities_file="$LORE_LIB_DIR/../adapters/capabilities.json"
  if ! command -v jq &>/dev/null; then
    die "list_supported_frameworks: jq is required but not found on PATH"
  fi
  if [[ ! -f "$capabilities_file" ]]; then
    die "list_supported_frameworks: capabilities file not found: $capabilities_file"
  fi
  jq -r '.frameworks | keys[]' "$capabilities_file" 2>/dev/null | sort \
    || die "list_supported_frameworks: failed to read frameworks from $capabilities_file"
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

  # Use $LORE_REPO_DIR (already resolved through symlinks at lib.sh source
  # time) rather than $LORE_LIB_DIR/.. — zsh's cd collapses ".." logically
  # before chdir, which on the typical symlinked install
  # (~/.lore/scripts -> /path/to/repo/scripts) lands at ~/.lore (no agents/)
  # instead of physically traversing the symlink. See d29208b for the same
  # fix in resolve_permission_adapter().
  local repo_root="$LORE_REPO_DIR"
  local template_path="$repo_root/agents/$name.md"

  if [[ ! -f "$template_path" ]]; then
    echo "Error: agent template '$name' not found at $template_path" >&2
    return 1
  fi

  # Print canonical absolute path (resolve any symlinks in the prefix).
  ( cd "$(dirname "$template_path")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$template_path")" )
}

# --- validate_role_model_binding ---
# Validate a role->model binding against the closed role and framework
# registries and the selected target's model_routing shape. T14 ownership (the verification
# rule lives in tests/frameworks/roles.bats; this helper is what the test
# exercises and what install/doctor surfaces will call once T15+T60 wire
# them up).
#
# Usage: validate_role_model_binding <role> <model>
# Returns 0 on success; non-zero on rejection with a stderr explanation.
#
# Rules:
#   1. role MUST appear in adapters/roles.json's closed set.
#   2. A first slash segment that is a registered framework id qualifies the
#      route; otherwise slash syntax retains its existing provider/model meaning.
#   3. The native binding is validated against the target framework's shape.
#   4. Empty model strings and unsupported foreign bridges are rejected.
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

  # Preserve the legacy bare-binding path, including its degraded behavior when
  # jq or roles.json is unavailable. Registry parsing is needed only for slash
  # values, where the first segment may select a framework.
  local roles_file="$LORE_LIB_DIR/../adapters/roles.json"
  if [[ -f "$roles_file" ]] && command -v jq &>/dev/null; then
    if ! jq -e --arg r "$role" '.roles[] | select(.id == $r)' "$roles_file" &>/dev/null; then
      echo "Error: unknown role '$role' (not in $roles_file)" >&2
      return 1
    fi
  fi
  if [[ "$model" != */* ]]; then
    return 0
  fi

  _model_route_json "$role" "$model" >/dev/null
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

# --- validate_ceremony_advisors ---
# Validate a JSON array of advisor names against the skills resolvable by a
# specific harness. On failure, CEREMONY_UNRESOLVABLE_ADVISOR names the first
# unresolvable advisor so resolution callers can report the exact binding.
#
# Usage: validate_ceremony_advisors <harness> <layer-label> <json-array>
# Returns 0 when every advisor resolves; otherwise returns 1 with a diagnostic.
validate_ceremony_advisors() {
  local harness="$1"
  local layer="$2"
  local list_json="$3"
  CEREMONY_UNRESOLVABLE_ADVISOR=""

  if [[ -z "$harness" ]]; then
    echo "Error: validate_ceremony_advisors requires a harness name" >&2
    return 1
  fi
  if ! printf '%s' "$list_json" | jq -e 'type == "array"' &>/dev/null; then
    echo "Error: ceremony advisors in $layer must be a JSON array" >&2
    return 1
  fi

  local repo_root="$LORE_REPO_DIR"
  local installed_skills_dir=""
  installed_skills_dir=$(resolve_harness_install_path skills "$harness" 2>/dev/null || true)
  [[ "$installed_skills_dir" == "unsupported" ]] && installed_skills_dir=""

  local valid_set
  valid_set=$( {
    [[ -d "$repo_root/skills" ]] && find "$repo_root/skills" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
    [[ -d "$repo_root/scripts/agent-protocols" ]] && find "$repo_root/scripts/agent-protocols" -mindepth 1 -maxdepth 1 -type f -name '*.md' -exec basename {} .md \; 2>/dev/null
    [[ -n "$installed_skills_dir" && -d "$installed_skills_dir" ]] && find "$installed_skills_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec basename {} \; 2>/dev/null
  } | sort -u | jq -R . | jq -sc .)
  [[ -z "$valid_set" || "$valid_set" == "null" ]] && valid_set="[]"

  local bad
  bad=$(printf '%s' "$list_json" | jq -r --argjson valid "$valid_set" \
    '. - $valid | .[]' 2>/dev/null | head -1)
  if [[ -n "$bad" ]]; then
    CEREMONY_UNRESOLVABLE_ADVISOR="$bad"
    echo "Error: unknown ceremony advisor '$bad' in $layer for harness '$harness' (not a registered skill)" >&2
    return 1
  fi
  return 0
}

# --- resolve_ceremony_advisors ---
# Print the resolved advisor list for a ceremony as a JSON array on stdout.
# Ceremony advisors are harness-local: resolution reads only
# `.harnesses.<active>.ceremonies.<skill>` from settings.json. There is no
# top-level ceremonies fallback and no ceremonies.json fallback.
# Missing key resolves to `[]` (no advisors configured). Explicit empty `[]`
# remains meaningful as the stored value for "no advisors on this harness".
# A registered advisor that is no longer resolvable on the target harness is
# recorded as a needs-decision outcome, then resolves fail-open to `[]`.
# Closed advisor set: the union of skill names under scripts/agent-protocols/,
# repo-local skills/, and the target harness's installed skills directory.
# The set is resolved at call time, so no hardcoded list is maintained here.
# Optional arguments select a target harness and attach work-item context;
# callers that omit them retain active-harness, context-free behavior.
# Mirrors no Go counterpart in v1 (TUI does not read ceremonies — bash-only
# parity surface per D5).
resolve_ceremony_advisors() {
  local skill="$1"
  local target_harness="${2:-}"
  local work_item="${3:-}"
  [[ -z "$skill" ]] && { echo "Error: resolve_ceremony_advisors requires a skill name" >&2; return 1; }

  command -v jq &>/dev/null || { echo "Error: resolve_ceremony_advisors requires jq" >&2; return 1; }

  local data_dir="${LORE_DATA_DIR:-$HOME/.lore}"
  local settings_sh="$LORE_LIB_DIR/settings.sh"
  local active="$target_harness"
  if [[ -z "$active" ]]; then
    active=$(resolve_active_framework 2>/dev/null) || active=""
  fi

  if [[ -n "$active" ]]; then
    local raw
    raw=$(LORE_DATA_DIR="$data_dir" bash "$settings_sh" get "harnesses.$active.ceremonies.$skill" 2>/dev/null || true)
    if [[ -n "$raw" ]]; then
      if printf '%s' "$raw" | jq -e 'type == "array"' &>/dev/null; then
        if ! validate_ceremony_advisors "$active" "harnesses.$active.ceremonies.$skill" "$raw" 2>/dev/null; then
          local advisor="$CEREMONY_UNRESOLVABLE_ADVISOR"
          local work_label="none"
          [[ -n "$work_item" ]] && work_label="$work_item"
          local reason="registered ceremony advisor is not resolvable on the target harness"
          echo "[ceremony] Divergence: ceremony='$skill' advisor='$advisor' harness='$active' work_item='$work_label' reason='$reason'. Corrective action: run the advisor where it is registered before consuming the artifact, or update the harness-local ceremony binding." >&2

          local recorder="$LORE_LIB_DIR/ceremony-outcome-record.sh"
          if [[ ! -f "$recorder" ]]; then
            echo "[ceremony] Warning: outcome recorder is unavailable at $recorder; continuing with an empty advisor list" >&2
          else
            local recorder_args=(
              --ceremony "$skill"
              --advisor "$advisor"
              --harness "$active"
              --reason "$reason"
            )
            if [[ -n "$work_item" ]]; then
              recorder_args+=(--work-item "$work_item")
            fi
            if ! bash "$recorder" "${recorder_args[@]}"; then
              echo "[ceremony] Warning: failed to record unresolved advisor '$advisor'; continuing with an empty advisor list" >&2
            fi
          fi
          echo "[]"
          return 0
        fi
        printf '%s\n' "$raw"
        return 0
      fi
    fi
  fi

  echo "[]"
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

# --- seed_meta_activity_vocab ---
# Restore-if-absent seeder for $KNOWLEDGE_DIR/_meta/activity-vocab.yaml.
# Usage: seed_meta_activity_vocab "$KNOWLEDGE_DIR"
# Args: $1 = knowledge store root (the directory containing _meta/)
# Contract:
#   - mkdir -p the parent _meta/ directory (the helper owns this).
#   - If $KDIR/_meta/activity-vocab.yaml exists (any content, including empty),
#     return 0 silently — never overwrite a project-overridden file.
#   - Otherwise verify $LORE_REPO_DIR/defaults/_meta/activity-vocab.yaml exists;
#     if missing, print an error naming that canonical path and return non-zero.
#   - Copy the canonical default into place and return 0.
# Errors only on filesystem failures (canonical source missing, target unwritable).
seed_meta_activity_vocab() {
  local kdir="${1:-}"
  if [[ -z "$kdir" ]]; then
    echo "Error: seed_meta_activity_vocab requires a knowledge-store directory argument" >&2
    return 1
  fi
  local target="$kdir/_meta/activity-vocab.yaml"
  local source="$LORE_REPO_DIR/defaults/_meta/activity-vocab.yaml"
  mkdir -p "$kdir/_meta"
  if [[ -f "$target" ]]; then
    return 0
  fi
  if [[ ! -f "$source" ]]; then
    echo "Error: canonical activity-vocab default missing at $source" >&2
    return 1
  fi
  cp "$source" "$target"
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

# --- project_record_field ---
# Read a field from a project record. The directory home
# (_work/_projects/<slug>/_meta.json) is authoritative; a legacy flat record
# (_work/_projects/<slug>.md) is the fallback. The field name is the bold-field
# label ("Status", "Anchor", "Title"); for the home it maps to the lowercase
# _meta.json key. Prints the value or nothing when the record or field is
# absent. Always returns 0 so read-only surfaces (list, digest, show, archive)
# can call it unconditionally under set -e.
project_record_field() {
  local work_dir="$1" slug="$2" field="$3"
  local home_meta="$work_dir/_projects/$slug/_meta.json"
  if [[ -f "$home_meta" ]]; then
    local key
    key=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]')
    python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2])
if v is not None:
    print(v)' "$home_meta" "$key"
    return 0
  fi
  local record="$work_dir/_projects/$slug.md"
  [[ -f "$record" ]] || return 0
  sed -n "s/^\*\*${field}:\*\*[[:space:]]*//p" "$record" | head -1
}

# --- warn_near_project_label ---
# Label hygiene for project grouping: warn on stderr when a project label is
# edit-distance-close to (but not exactly) an existing one. Existing labels
# are the union of plans[].project and archived[].project from _index.json
# plus _projects/ record names (directory homes and legacy flat files).
# Warn-only — never normalizes, merges, rejects the label, or creates a
# record. Always returns 0.
# Usage: warn_near_project_label "$WORK_DIR" "$label"
warn_near_project_label() {
  local work_dir="$1" label="$2"
  [[ -n "$label" ]] || return 0
  local matches match
  matches=$(python3 - "$work_dir" "$label" 2>/dev/null <<'PYEOF' || true
import difflib, glob, json, os, sys

work_dir, label = sys.argv[1], sys.argv[2]
labels = set()
try:
    with open(os.path.join(work_dir, "_index.json"), encoding="utf-8") as f:
        data = json.load(f)
    for key in ("plans", "archived"):
        for item in data.get(key) or []:
            if isinstance(item, dict) and item.get("project"):
                labels.add(str(item["project"]))
except Exception:
    pass
for path in glob.glob(os.path.join(work_dir, "_projects", "*.md")):
    labels.add(os.path.splitext(os.path.basename(path))[0])
for path in glob.glob(os.path.join(work_dir, "_projects", "*", "_meta.json")):
    labels.add(os.path.basename(os.path.dirname(path)))
labels.discard(label)
for match in difflib.get_close_matches(label, sorted(labels), n=3, cutoff=0.8):
    print(match)
PYEOF
)
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    echo "[work] Warning: project '$label' is close to existing project '$match' — grouping matches exact labels only." >&2
  done <<<"$matches"
  return 0
}

# --- project_record_exists ---
# True when a project has a record, in either form: the directory home
# (_work/_projects/<slug>/_meta.json) or a legacy flat file (<slug>.md).
# Usage: if project_record_exists "$WORK_DIR" "$slug"; then ...
project_record_exists() {
  local work_dir="$1" slug="$2"
  [[ -f "$work_dir/_projects/$slug/_meta.json" || -f "$work_dir/_projects/$slug.md" ]]
}

# --- migrate_project_record ---
# Convert a legacy flat record (_work/_projects/<slug>.md) into the directory
# home form (_work/_projects/<slug>/ with _meta.json + overview.md). No-op when
# the home already exists or no flat file is present. Idempotent; always
# returns 0. Called by the mutating verbs (describe/archive) on first touch and
# by heal-work.sh for structural repair; read surfaces never call it.
migrate_project_record() {
  local work_dir="$1" slug="$2"
  local flat="$work_dir/_projects/$slug.md"
  local home="$work_dir/_projects/$slug"
  [[ -f "$flat" ]] || return 0
  [[ -d "$home" ]] && return 0
  local ts
  ts=$(timestamp_iso)
  python3 - "$flat" "$home" "$slug" "$ts" <<'PYEOF' || return 0
import json, os, re, sys

flat, home, slug, ts = sys.argv[1:5]
with open(flat, encoding="utf-8") as f:
    text = f.read()

title = " ".join(w.capitalize() for w in slug.split("-"))
m = re.search(r"^# (.+)$", text, re.MULTILINE)
if m:
    title = m.group(1).strip()
m = re.search(r"^\*\*Status:\*\*[ \t]*(.*)$", text, re.MULTILINE)
status = (m.group(1).strip() if m else "") or "active"
m = re.search(r"^\*\*Anchor:\*\*[ \t]*(.*)$", text, re.MULTILINE)
anchor = m.group(1).strip() if m else ""

lines = text.splitlines()
body_start = len(lines)
for i, line in enumerate(lines):
    s = line.strip()
    if not s or line.startswith("# ") or line.startswith("**Status:**") or line.startswith("**Anchor:**"):
        continue
    body_start = i
    break
body = "\n".join(lines[body_start:]).strip()

os.makedirs(home, exist_ok=True)
meta = {
    "slug": slug,
    "title": title,
    "status": status,
    "anchor": anchor,
    "created": ts,
    "updated": ts,
}
with open(os.path.join(home, "_meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
if body:
    with open(os.path.join(home, "overview.md"), "w", encoding="utf-8") as f:
        f.write(body + "\n")
PYEOF
  rm -f "$flat"
  return 0
}

# --- project_identity_state ---
# Classify a project name as active | archived | free. A project is:
#   - archived: its record _meta.json.status is "archived", OR no record exists
#     but the name has archived members and zero active members in _index.json;
#   - active: its record status is anything other than "archived", OR no record
#     exists but the name has at least one active member;
#   - free: no record and no members.
# The record read dual-reads (directory home first, flat-file fallback). The
# member read scopes to BOTH _index.json projections — plans[] alone misses the
# archived generation the gate exists to catch. Always returns 0; echoes the
# state. Usage: state=$(project_identity_state "$WORK_DIR" "$slug")
project_identity_state() {
  local work_dir="$1" slug="$2"
  local status
  status=$(project_record_field "$work_dir" "$slug" Status)
  if [[ -n "$status" ]]; then
    if [[ "$status" == "archived" ]]; then
      echo "archived"
    else
      echo "active"
    fi
    return 0
  fi
  python3 - "$work_dir/_index.json" "$slug" <<'PYEOF'
import json, sys

index_path, slug = sys.argv[1], sys.argv[2]
try:
    with open(index_path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {}
active = archived = 0
for item in data.get("plans") or []:
    if isinstance(item, dict) and str(item.get("project", "") or "") == slug:
        active += 1
for item in data.get("archived") or []:
    if isinstance(item, dict) and str(item.get("project", "") or "") == slug:
        archived += 1
if active > 0:
    print("active")
elif archived > 0:
    print("archived")
else:
    print("free")
PYEOF
}

# --- set_project_record_status ---
# Set a project home's _meta.json.status (and touch updated), migrating a
# legacy flat record to the directory home first. No-op when the project has no
# record (a label-only project — status lives only in its members). Used by
# archive-project.sh (archived) and the reuse-reactivation paths (active).
# Usage: set_project_record_status "$WORK_DIR" "$slug" active
set_project_record_status() {
  local work_dir="$1" slug="$2" status="$3"
  migrate_project_record "$work_dir" "$slug"
  local meta="$work_dir/_projects/$slug/_meta.json"
  [[ -f "$meta" ]] || return 0
  local ts
  ts=$(timestamp_iso)
  python3 - "$meta" "$status" "$ts" <<'PYEOF'
import json, sys

meta_path, status, ts = sys.argv[1:4]
with open(meta_path, encoding="utf-8") as f:
    data = json.load(f)
data["status"] = status
data["updated"] = ts
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

# --- project_record_statuses ---
# Emit one "slug<TAB>status" line per project record, dual-reading both the
# directory homes (_projects/<slug>/_meta.json) and any legacy flat records
# (_projects/<slug>.md) that have not yet migrated. A home supersedes a flat
# file of the same slug. Feeds the header status token in list-work.sh and the
# SessionStart digest (load-work.sh). Always returns 0.
project_record_statuses() {
  local work_dir="$1"
  local records_dir="$work_dir/_projects"
  [[ -d "$records_dir" ]] || return 0
  local home record pslug
  for home in "$records_dir"/*/; do
    [[ -d "$home" ]] || continue
    pslug=$(basename "$home")
    [[ -f "$home/_meta.json" ]] || continue
    printf '%s\t%s\n' "$pslug" "$(project_record_field "$work_dir" "$pslug" Status)"
  done
  for record in "$records_dir"/*.md; do
    [[ -f "$record" ]] || continue
    pslug=$(basename "$record" .md)
    [[ -d "$records_dir/$pslug" ]] && continue
    printf '%s\t%s\n' "$pslug" "$(project_record_field "$work_dir" "$pslug" Status)"
  done
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

# --- TUI ghostty-backend build helpers ---
# The TUI's libghostty terminal backend links a vendored SIMD-off static
# archive via cgo, so every TUI build needs a C compiler and the
# per-platform archive under tui/internal/work/libghostty/lib/ in addition
# to the go toolchain. install.sh and `lore rebuild` use these helpers to
# turn a missing requirement into an actionable skip/error instead of a
# raw cgo failure.

# tui_ghostty_vendor_dir <tui_dir>
# Root of the vendored libghostty-vt headers/archives/manifest.
tui_ghostty_vendor_dir() {
  printf '%s/internal/work/libghostty\n' "$1"
}

# tui_ghostty_pkg_config_shim <tui_dir>
# pkg-config replacement satisfying go.mitchellh.com/libghostty's
# `#cgo pkg-config: libghostty-vt-static` directive from the vendored
# headers. Export as PKG_CONFIG for TUI builds.
tui_ghostty_pkg_config_shim() {
  printf '%s/pkg-config-shim.sh\n' "$(tui_ghostty_vendor_dir "$1")"
}

# tui_ghostty_preflight <tui_dir>
# Verify a TUI build can compile and link: a C compiler on PATH and the
# vendored static archive for the native platform. Prints the first
# unmet requirement (with the action to fix it) and returns 1; silent
# success when the build can proceed.
tui_ghostty_preflight() {
  local tui_dir="$1"
  local vendor_dir
  vendor_dir=$(tui_ghostty_vendor_dir "$tui_dir")
  if ! command -v cc >/dev/null 2>&1 \
    && ! command -v clang >/dev/null 2>&1 \
    && ! command -v gcc >/dev/null 2>&1; then
    echo "the TUI's libghostty terminal backend needs a C compiler (cc/clang/gcc) and none was found on PATH. Install Xcode Command Line Tools (xcode-select --install) on macOS or gcc/clang via your package manager, then re-run."
    return 1
  fi
  local goos goarch
  goos=$(go env GOOS 2>/dev/null || true)
  goarch=$(go env GOARCH 2>/dev/null || true)
  local archive="$vendor_dir/lib/${goos}_${goarch}/libghostty-vt.a"
  if [[ ! -f "$archive" ]]; then
    echo "no vendored libghostty-vt static archive for ${goos}/${goarch} (expected at $archive). See $vendor_dir/MANIFEST.json for the pinned build recipe."
    return 1
  fi
  return 0
}
