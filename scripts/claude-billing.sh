#!/usr/bin/env bash
# claude-billing.sh — Lease-based billing mode wrapper for Claude Code.
#
# This script keeps Claude.ai subscription auth as the default and only injects
# ANTHROPIC_API_KEY into Claude Code when an API billing lease is active.
#
# Typical setup:
#   1. Log in to Claude Code with your Pro/Max account: claude auth login
#   2. Store your fallback API key in one of:
#        - CLAUDE_FALLBACK_API_KEY
#        - CLAUDE_FALLBACK_API_KEY_FILE
#        - macOS Keychain item named "claude-api-fallback"
#   3. Alias Claude through this wrapper:
#        alias claude="$HOME/path/to/lore/scripts/claude-billing.sh run"
#
# Usage:
#   claude-billing.sh status
#   claude-billing.sh doctor
#   claude-billing.sh api 6h
#   claude-billing.sh max
#   claude-billing.sh run [claude args...]

set -euo pipefail

LEASE_FILE="${CLAUDE_BILLING_LEASE_FILE:-$HOME/.claude/api-billing-lease}"
KEYCHAIN_SERVICE="${CLAUDE_FALLBACK_API_KEY_KEYCHAIN_SERVICE:-claude-api-fallback}"

usage() {
  cat >&2 <<'EOF'
Usage:
  claude-billing.sh status
  claude-billing.sh doctor
  claude-billing.sh api <duration>
  claude-billing.sh max
  claude-billing.sh run [claude args...]

Commands:
  status           Show whether API billing is currently leased.
  doctor           Validate config and show how the API key would be resolved.
  api <duration>   Enable API billing for a fixed lease (examples: 90m, 6h, 1d).
  max              Clear the lease so new Claude launches use subscription auth.
  run ...          Launch Claude using the active billing mode.

Configuration:
  CLAUDE_BILLING_LEASE_FILE                 Override the lease file location.
  CLAUDE_FALLBACK_API_KEY                   API key used during API billing.
  CLAUDE_FALLBACK_API_KEY_FILE              File containing the API key.
  CLAUDE_FALLBACK_API_KEY_KEYCHAIN_SERVICE  macOS Keychain service name.

Key resolution priority:
  1. CLAUDE_FALLBACK_API_KEY
  2. CLAUDE_FALLBACK_API_KEY_FILE
  3. macOS Keychain service (default: claude-api-fallback)
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

ensure_claude_installed() {
  command -v claude >/dev/null 2>&1 || die "claude CLI not found on PATH"
}

now_epoch() {
  date +%s
}

parse_duration() {
  local raw="${1:-}"
  [[ -n "$raw" ]] || die "duration is required"

  if [[ "$raw" =~ ^([0-9]+)([smhd])$ ]]; then
    local value="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      s) echo "$value" ;;
      m) echo $((value * 60)) ;;
      h) echo $((value * 3600)) ;;
      d) echo $((value * 86400)) ;;
      *) die "unsupported duration unit: $unit" ;;
    esac
    return 0
  fi

  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
    return 0
  fi

  die "invalid duration '$raw' (use 90m, 6h, 1d, or seconds)"
}

format_duration() {
  local seconds="$1"
  if (( seconds < 60 )); then
    printf '%ss' "$seconds"
  elif (( seconds < 3600 )); then
    printf '%sm' $((seconds / 60))
  elif (( seconds < 86400 )); then
    printf '%sh %sm' $((seconds / 3600)) $(((seconds % 3600) / 60))
  else
    printf '%sd %sh' $((seconds / 86400)) $(((seconds % 86400) / 3600))
  fi
}

format_timestamp_local() {
  local epoch="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    date -r "$epoch" "+%Y-%m-%d %H:%M:%S %Z"
  else
    date -d "@$epoch" "+%Y-%m-%d %H:%M:%S %Z"
  fi
}

lease_expiry_epoch() {
  [[ -f "$LEASE_FILE" ]] || return 1
  local expiry
  expiry="$(tr -d '[:space:]' < "$LEASE_FILE")"
  [[ "$expiry" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$expiry"
}

lease_active() {
  local expiry
  expiry="$(lease_expiry_epoch)" || return 1
  (( expiry > $(now_epoch) ))
}

clear_expired_lease() {
  local expiry
  expiry="$(lease_expiry_epoch)" || return 0
  if (( expiry <= $(now_epoch) )); then
    rm -f "$LEASE_FILE"
  fi
}

resolve_api_key_source() {
  if [[ -n "${CLAUDE_FALLBACK_API_KEY:-}" ]]; then
    echo "env:CLAUDE_FALLBACK_API_KEY"
    return 0
  fi

  if [[ -n "${CLAUDE_FALLBACK_API_KEY_FILE:-}" ]]; then
    [[ -f "$CLAUDE_FALLBACK_API_KEY_FILE" ]] || die "CLAUDE_FALLBACK_API_KEY_FILE does not exist: $CLAUDE_FALLBACK_API_KEY_FILE"
    echo "file:$CLAUDE_FALLBACK_API_KEY_FILE"
    return 0
  fi

  if [[ "$(uname)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -w >/dev/null 2>&1; then
      echo "keychain:$KEYCHAIN_SERVICE"
      return 0
    fi
  fi

  return 1
}

read_api_key() {
  if [[ -n "${CLAUDE_FALLBACK_API_KEY:-}" ]]; then
    printf '%s' "$CLAUDE_FALLBACK_API_KEY"
    return 0
  fi

  if [[ -n "${CLAUDE_FALLBACK_API_KEY_FILE:-}" ]]; then
    [[ -f "$CLAUDE_FALLBACK_API_KEY_FILE" ]] || die "CLAUDE_FALLBACK_API_KEY_FILE does not exist: $CLAUDE_FALLBACK_API_KEY_FILE"
    head -n 1 "$CLAUDE_FALLBACK_API_KEY_FILE" | tr -d '\r\n'
    return 0
  fi

  if [[ "$(uname)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | tr -d '\r\n'
    return 0
  fi

  return 1
}

write_lease() {
  local expiry="$1"
  mkdir -p "$(dirname "$LEASE_FILE")"
  printf '%s\n' "$expiry" > "$LEASE_FILE"
}

cmd_status() {
  clear_expired_lease
  echo "Lease file: $LEASE_FILE"

  if lease_active; then
    local expiry remaining
    expiry="$(lease_expiry_epoch)"
    remaining=$((expiry - $(now_epoch)))
    echo "Mode: api"
    echo "Expires: $(format_timestamp_local "$expiry")"
    echo "Remaining: $(format_duration "$remaining")"
  else
    echo "Mode: max"
    echo "Lease: inactive"
  fi

  if source_label="$(resolve_api_key_source 2>/dev/null)"; then
    echo "Fallback key source: $source_label"
  else
    echo "Fallback key source: not configured"
  fi
}

cmd_doctor() {
  ensure_claude_installed
  echo "Claude version: $(claude --version)"
  if claude auth status >/dev/null 2>&1; then
    echo "Claude auth: configured"
  else
    echo "Claude auth: not configured"
  fi

  clear_expired_lease
  if source_label="$(resolve_api_key_source 2>/dev/null)"; then
    echo "Fallback key source: $source_label"
  else
    echo "Fallback key source: missing"
    echo "Hint: set CLAUDE_FALLBACK_API_KEY, CLAUDE_FALLBACK_API_KEY_FILE, or a macOS Keychain item named '$KEYCHAIN_SERVICE'."
  fi

  if lease_active; then
    local expiry remaining
    expiry="$(lease_expiry_epoch)"
    remaining=$((expiry - $(now_epoch)))
    echo "Current lease: active for $(format_duration "$remaining")"
  else
    echo "Current lease: inactive"
  fi
}

cmd_api() {
  local duration_raw="${1:-}"
  local seconds expiry source_label
  seconds="$(parse_duration "$duration_raw")"

  source_label="$(resolve_api_key_source 2>/dev/null)" \
    || die "no fallback API key configured"

  expiry=$(( $(now_epoch) + seconds ))
  write_lease "$expiry"

  echo "API billing enabled."
  echo "Source: $source_label"
  echo "Expires: $(format_timestamp_local "$expiry")"
}

cmd_max() {
  rm -f "$LEASE_FILE"
  echo "API billing lease cleared. New Claude launches will use subscription auth."
}

cmd_run() {
  clear_expired_lease
  ensure_claude_installed

  if lease_active; then
    local api_key expiry
    api_key="$(read_api_key)" || die "API lease is active, but no fallback API key is configured"
    [[ -n "$api_key" ]] || die "resolved fallback API key was empty"
    expiry="$(lease_expiry_epoch)"
    echo "[claude-billing] Using API billing until $(format_timestamp_local "$expiry")" >&2
    exec env ANTHROPIC_API_KEY="$api_key" claude "$@"
  fi

  echo "[claude-billing] Using Claude subscription auth" >&2
  exec env -u ANTHROPIC_API_KEY claude "$@"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    status)
      shift
      cmd_status "$@"
      ;;
    doctor)
      shift
      cmd_doctor "$@"
      ;;
    api)
      shift
      cmd_api "$@"
      ;;
    max)
      shift
      cmd_max "$@"
      ;;
    run)
      shift
      cmd_run "$@"
      ;;
    -h|--help|help|'')
      usage
      ;;
    *)
      die "unknown command: $cmd"
      ;;
  esac
}

main "$@"
