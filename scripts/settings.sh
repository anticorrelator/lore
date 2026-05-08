#!/usr/bin/env bash
# settings.sh — jq-backed loader/writer for the unified user settings file
# (~/.lore/config/settings.json).
#
# The unified file is the single source of truth for user preferences during
# Phase 1 of the consolidate-user-config-unified-settings-file work item; the
# eight legacy fragmented files in ~/.lore/config/ remain on-disk during the
# deprecation window and are read as fallback by `lib.sh` helpers when a key
# is absent from the unified file. This loader is the canonical entry point
# from bash; `lib.sh` helpers route through it. Mirrors the Python loader at
# scripts/lore_settings.py and the Go loader at tui/internal/config/settings.go
# (D5 parity surface).
#
# Subcommands:
#   get <path>        Print JSON-decoded value at the dot-separated path.
#                     Empty stdout when the key is absent (loaders distinguish
#                     absence from JSON `null` based on whether the key exists
#                     in the document; absent → empty stdout, null → 'null').
#                     Path syntax is dot-separated (`roles.lead`,
#                     `harnesses.claude-code.args`); the script translates to
#                     a jq getpath internally — callers MUST NOT pass jq path
#                     syntax directly. Returns exit 0 even on absence so
#                     `set -e` callers don't trip on missing keys.
#   section <name>    Print JSON for the named top-level section, or `{}` when
#                     the section is missing.
#   path              Print the resolved settings.json absolute path.
#   patch <path> <val>  Section-scoped read-modify-write under flock per the
#                     D5a write contract: acquire exclusive lock on
#                     `~/.lore/config/.settings.lock`, read whole document,
#                     mutate only the targeted path, atomically replace. The
#                     <val> argument is JSON-encoded — strings MUST be passed
#                     quoted (`'"opus"'`), numbers/bools as bare JSON
#                     (`true`, `42`), arrays/objects as JSON literals
#                     (`'[]'`, `'{"a":1}'`). Unrelated keys are preserved.
#                     Creates the file from `{}` if absent.
#   delete <path>     Section-scoped read-modify-write under flock per the
#                     D5a write contract: removes the leaf at the
#                     dot-separated path. Implements the D9 Delete boundary
#                     contract — idempotent on absent paths (no-op, file
#                     byte-identical), no parent pruning (emptied parent
#                     objects stay), no whole-doc validation. Uses jq's
#                     `delpaths([$path])` with a path-array form so
#                     kebab-case keys like `claude-code` are not parsed as
#                     subtraction. On lock/parse/rename failure leaves the
#                     prior settings.json intact.
#   fallbacks         Deterministic snapshot of `<file>::<key>` pairs whose
#                     unified key is absent and whose legacy fragmented file
#                     exists on disk (i.e., the keys lib.sh helpers would
#                     fall back to read). Empty output means every legacy
#                     reader has been migrated. Consumed by `lore doctor`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LORE_DATA_DIR="${LORE_DATA_DIR:-$HOME/.lore}"
SETTINGS_FILE="$LORE_DATA_DIR/config/settings.json"
SETTINGS_LOCK="$LORE_DATA_DIR/config/.settings.lock"

usage() {
  cat >&2 <<EOF
settings.sh — read/write the unified ~/.lore/config/settings.json

Usage: settings.sh <subcommand> [args...]

Subcommands:
  get <path>            Print JSON value at dot-separated path (empty if absent).
  section <name>        Print JSON for the named top-level section, '{}' if absent.
  path                  Print the resolved settings.json absolute path.
  patch <path> <value>  Section-scoped read-modify-write under flock; <value> is JSON-encoded.
  delete <path>         Remove the leaf at <path> under flock (idempotent on absent paths; no parent pruning).
  fallbacks             List <file>::<key> pairs whose unified key is absent and would fall back.

Path syntax is dot-separated (roles.lead, harnesses.claude-code.args).
patch values are JSON-encoded (strings quoted: '"opus"', arrays: '[]', booleans: true).
EOF
}

# Convert a dot-separated path into a JSON array suitable for jq's
# getpath/setpath. JSON-encoding via `jq -R` handles segments containing
# dashes (claude-code), spaces, or other jq-significant characters.
# Input:  harnesses.claude-code.args → ["harnesses","claude-code","args"]
_path_to_array() {
  local path="$1"
  local IFS=.
  local -a segments
  read -ra segments <<<"$path"
  printf '%s\n' "${segments[@]}" | jq -R . | jq -sc .
}

# Validate that the unified file parses as JSON. Returns 0 if absent (callers
# treat absence as "all keys missing"); returns 1 with an actionable error
# when the file exists but is malformed (D5 read contract).
_validate_settings_file() {
  [[ -f "$SETTINGS_FILE" ]] || return 0
  if ! jq -e . "$SETTINGS_FILE" &>/dev/null; then
    echo "Error: invalid JSON in $SETTINGS_FILE — run \`lore doctor\` to diagnose" >&2
    return 1
  fi
  return 0
}

cmd_get() {
  local path="${1:-}"
  [[ -z "$path" ]] && { echo "Error: settings.sh get requires a path" >&2; return 2; }
  command -v jq &>/dev/null || { echo "Error: settings.sh requires jq" >&2; return 2; }

  _validate_settings_file || return 1
  [[ -f "$SETTINGS_FILE" ]] || return 0

  local path_array
  path_array=$(_path_to_array "$path")

  # Three-state distinction:
  #   1. key absent → exit 0 with empty stdout (fallback trigger for lib.sh)
  #   2. key present, value null → exit 0 with stdout 'null'
  #   3. key present, value non-null → exit 0 with compact JSON stdout
  # Recursive `has` walk preserves the absent-vs-null distinction that
  # `// empty` and `// null` would collapse.
  local exists
  exists=$(jq -r --argjson p "$path_array" '
    def has_path(p):
      if (p | length) == 0 then true
      elif type != "object" then false
      elif has(p[0]) | not then false
      else (.[p[0]] | has_path(p[1:]))
      end;
    has_path($p)
  ' "$SETTINGS_FILE")

  if [[ "$exists" != "true" ]]; then
    return 0
  fi

  jq -c --argjson p "$path_array" 'getpath($p)' "$SETTINGS_FILE"
}

cmd_section() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "Error: settings.sh section requires a section name" >&2; return 2; }
  command -v jq &>/dev/null || { echo "Error: settings.sh requires jq" >&2; return 2; }

  _validate_settings_file || return 1
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "{}"
    return 0
  fi

  jq -c --arg n "$name" '.[$n] // {}' "$SETTINGS_FILE"
}

cmd_path() {
  printf '%s\n' "$SETTINGS_FILE"
}

# Internal: read-modify-write body. Caller holds the flock when concurrent
# safety is required.
_patch_unlocked() {
  local path="$1"
  local value="$2"

  local path_array
  path_array=$(_path_to_array "$path")

  local current="{}"
  if [[ -f "$SETTINGS_FILE" ]]; then
    if ! jq -e . "$SETTINGS_FILE" &>/dev/null; then
      echo "Error: invalid JSON in $SETTINGS_FILE — refusing to patch (run \`lore doctor\`)" >&2
      return 1
    fi
    current=$(cat "$SETTINGS_FILE")
  fi

  local tmp="$SETTINGS_FILE.tmp.$$"
  printf '%s' "$current" \
    | jq --argjson p "$path_array" --argjson v "$value" 'setpath($p; $v)' \
    > "$tmp" \
    || { rm -f "$tmp"; echo "Error: settings.sh patch failed for $path" >&2; return 1; }

  mv "$tmp" "$SETTINGS_FILE"
}

# Acquire the unified settings lock. flock is preferred where available;
# mkdir-based locking is the portable fallback (mkdir is atomic on POSIX
# and macOS ships without flock by default). The lock dir is removed on
# release. Returns 0 once acquired; spins with a 50ms sleep until then,
# bounded at ~10s to surface deadlock-like states rather than block forever.
_acquire_settings_lock_mkdir() {
  local lockdir="$SETTINGS_LOCK.d"
  local waited=0
  local max_wait_ms=10000
  while ! mkdir "$lockdir" 2>/dev/null; do
    if [[ "$waited" -ge "$max_wait_ms" ]]; then
      echo "Error: settings.sh patch could not acquire $lockdir after ${max_wait_ms}ms" >&2
      echo "Hint: stale lock — remove $lockdir if no settings.sh patch is in flight" >&2
      return 1
    fi
    sleep 0.05
    waited=$((waited + 50))
  done
}

_release_settings_lock_mkdir() {
  rmdir "$SETTINGS_LOCK.d" 2>/dev/null || true
}

cmd_patch() {
  local path="${1:-}"
  local value="${2:-}"
  [[ -z "$path" ]] && { echo "Error: settings.sh patch requires a path" >&2; return 2; }
  [[ $# -lt 2 ]] && { echo "Error: settings.sh patch requires a JSON-encoded value" >&2; return 2; }
  command -v jq &>/dev/null || { echo "Error: settings.sh requires jq" >&2; return 2; }

  # Validate value is parseable JSON. `jq -e` exits non-zero on null/false
  # even when the input is valid JSON; use `jq .` and check parse exit only.
  if ! printf '%s' "$value" | jq . &>/dev/null; then
    echo "Error: settings.sh patch value is not valid JSON: $value" >&2
    echo "Hint: strings must be quoted ('\"opus\"'), arrays as '[]', booleans as 'true'" >&2
    return 2
  fi

  mkdir -p "$(dirname "$SETTINGS_FILE")"

  # D5a write contract: lock-protected read-modify-write with atomic mv.
  # flock when present (Linux); mkdir-based locking otherwise (macOS).
  # Both ensure no two writers interleave their RMW windows; atomic mv
  # then guards against partial-write corruption.
  if command -v flock &>/dev/null; then
    : >>"$SETTINGS_LOCK"
    (
      flock -x 9 || { echo "Error: settings.sh patch could not acquire $SETTINGS_LOCK" >&2; exit 1; }
      _patch_unlocked "$path" "$value"
    ) 9>>"$SETTINGS_LOCK"
    return $?
  fi

  _acquire_settings_lock_mkdir || return 1
  trap _release_settings_lock_mkdir EXIT INT TERM
  _patch_unlocked "$path" "$value"
  local rc=$?
  _release_settings_lock_mkdir
  trap - EXIT INT TERM
  return "$rc"
}

# Internal: read-modify-delete body. Caller holds the flock when concurrent
# safety is required. Returns 0 on success (including absent-path no-op),
# non-zero on parse / mutation / rename failure. Mirrors the Go-side
# SettingsDelete idempotence contract: an absent path leaves the file
# byte-identical (no rename) so foreign-writer formatting is preserved.
_delete_unlocked() {
  local path="$1"

  local path_array
  path_array=$(_path_to_array "$path")

  # Missing file → nothing to delete; idempotent no-op.
  [[ -f "$SETTINGS_FILE" ]] || return 0

  if ! jq -e . "$SETTINGS_FILE" &>/dev/null; then
    echo "Error: invalid JSON in $SETTINGS_FILE — refusing to delete (run \`lore doctor\`)" >&2
    return 1
  fi

  # Recursive `has` walk preserves the absent-vs-null distinction the same
  # way cmd_get does. delpaths is silently a no-op on an absent path, but
  # we still want to skip the rename so the file is byte-identical when
  # nothing changed (D9 absent-delete contract).
  local exists
  exists=$(jq -r --argjson p "$path_array" '
    def has_path(p):
      if (p | length) == 0 then true
      elif type != "object" then false
      elif has(p[0]) | not then false
      else (.[p[0]] | has_path(p[1:]))
      end;
    has_path($p)
  ' "$SETTINGS_FILE")

  if [[ "$exists" != "true" ]]; then
    return 0
  fi

  local tmp="$SETTINGS_FILE.tmp.$$"
  # Path-array form is load-bearing: `delpaths` takes an array of paths,
  # each path being an array of segments. String-interpolated jq source
  # like `del(.harnesses.claude-code)` would parse `claude-code` as
  # subtraction (`claude` minus `code`).
  jq --argjson p "$path_array" 'delpaths([$p])' "$SETTINGS_FILE" \
    > "$tmp" \
    || { rm -f "$tmp"; echo "Error: settings.sh delete failed for $path" >&2; return 1; }

  mv "$tmp" "$SETTINGS_FILE"
}

cmd_delete() {
  local path="${1:-}"
  [[ -z "$path" ]] && { echo "Error: settings.sh delete requires a path" >&2; return 2; }
  command -v jq &>/dev/null || { echo "Error: settings.sh requires jq" >&2; return 2; }

  # Asymmetry with cmd_patch (load-bearing per D9, do not "fix"):
  # cmd_patch auto-creates intermediate objects via setpath; cmd_delete
  # deliberately does NOT — an absent intermediate is a no-op short-circuit
  # (see _delete_unlocked above). This is what makes tab-through
  # navigation safe in the configurator. harnesses.<fw>.enabled and
  # active_framework MUST NEVER reach this function — the widget layer
  # routes those through harness-toggle scripts and SettingsPatch
  # respectively.
  mkdir -p "$(dirname "$SETTINGS_FILE")"

  # D5a write contract: lock-protected read-modify-write with atomic mv.
  # flock when present (Linux); mkdir-based locking otherwise (macOS).
  if command -v flock &>/dev/null; then
    : >>"$SETTINGS_LOCK"
    (
      flock -x 9 || { echo "Error: settings.sh delete could not acquire $SETTINGS_LOCK" >&2; exit 1; }
      _delete_unlocked "$path"
    ) 9>>"$SETTINGS_LOCK"
    return $?
  fi

  _acquire_settings_lock_mkdir || return 1
  trap _release_settings_lock_mkdir EXIT INT TERM
  _delete_unlocked "$path"
  local rc=$?
  _release_settings_lock_mkdir
  trap - EXIT INT TERM
  return "$rc"
}

# fallbacks: deterministic snapshot of legacy file/key pairs whose unified
# key is absent and whose legacy fragmented file is present on disk (i.e.,
# what lib.sh helpers would actually fall back to read). Order is stable
# so `lore doctor` can diff against prior runs. Only legacy keys consulted
# from bash are listed; Python and Go loaders maintain their own snapshots
# when their fragmented-file readers diverge.
cmd_fallbacks() {
  command -v jq &>/dev/null || { echo "Error: settings.sh requires jq" >&2; return 2; }

  # "<unified-path>|<file>::<key>" — `<all>` marks files read whole rather
  # than by single key (e.g., ceremonies.json's whole map).
  local table=(
    "active_framework|framework.json::framework"
    "capability_overrides|framework.json::capability_overrides"
    "roles|framework.json::roles"
    "harnesses|harness-args.json::harnesses"
    "obsidian.vaults|obsidian.json::<all>"
    "ceremonies|ceremonies.json::<all>"
  )

  local entry unified_path locator legacy_file legacy_path unified_value
  for entry in "${table[@]}"; do
    unified_path="${entry%%|*}"
    locator="${entry#*|}"
    legacy_file="${locator%%::*}"

    if [[ -f "$SETTINGS_FILE" ]]; then
      unified_value=$(cmd_get "$unified_path" 2>/dev/null || true)
      [[ -n "$unified_value" ]] && continue
    fi

    # ceremonies.json lives at $LORE_DATA_DIR/ceremonies.json (no /config/
    # prefix per resolve_ceremony_config_path).
    if [[ "$legacy_file" == "ceremonies.json" ]]; then
      legacy_path="$LORE_DATA_DIR/ceremonies.json"
    else
      legacy_path="$LORE_DATA_DIR/config/$legacy_file"
    fi
    [[ -f "$legacy_path" ]] || continue

    printf '%s\n' "$locator"
  done
}

# ============================================================
# Entrypoint
# ============================================================

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

subcmd="$1"
shift

case "$subcmd" in
  --help|-h)
    usage
    exit 0
    ;;
  get)
    cmd_get "${1:-}"
    ;;
  section)
    cmd_section "${1:-}"
    ;;
  path)
    cmd_path
    ;;
  patch)
    cmd_patch "${1:-}" "${2:-}"
    ;;
  delete)
    cmd_delete "${1:-}"
    ;;
  fallbacks)
    cmd_fallbacks
    ;;
  *)
    echo "Error: unknown subcommand '$subcmd'" >&2
    usage
    exit 1
    ;;
esac
