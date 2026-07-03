#!/usr/bin/env bash
# tui-capture.sh — canonical TUI capture pipeline: tmux 170x46, capture-pane -e, freeze
#
# Every visual artifact (HEAD baselines, design candidates, reference TUIs)
# must go through this same renderer path so captures stay pixel-comparable.
# The canonical geometry is 170x46; override only when a capture is
# deliberately out-of-corpus (it will not be comparable to the rest).
#
# Usage:
#   bash tui-capture.sh build [-o <path>]
#       Build the lore-tui binary (handles the libghostty cgo pkg-config shim).
#       Default output: /tmp/lore-tui-capture
#   bash tui-capture.sh start <session> [--binary <path>] [--cwd <dir>]
#                       [--width N] [--height N] [--env K=V]... [--settle <sec>]
#       Start a detached tmux session at the canonical geometry running the
#       TUI binary, then wait --settle seconds (default 2) for first paint.
#       The knowledge store is resolved from --cwd (default: current dir).
#   bash tui-capture.sh send <session> <key>... [--settle <sec>]
#       Send keys (tmux send-keys names: 'q', 'Escape', 'Tab', 'Enter', ...),
#       then wait --settle seconds (default 0.5) for the redraw.
#   bash tui-capture.sh capture <session> <out.ans>
#       Capture the pane with ANSI escapes preserved (capture-pane -e -p).
#   bash tui-capture.sh render <in.ans> [<out.png>]
#       Render an .ans capture to PNG via freeze (default: <in>.png).
#   bash tui-capture.sh kill <session>
#       Kill the tmux session (idempotent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CANONICAL_WIDTH=170
CANONICAL_HEIGHT=46

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH"
}

cmd_build() {
  local out="/tmp/lore-tui-capture"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      *) die "build: unknown argument '$1'" ;;
    esac
  done
  local tui_dir="$LORE_REPO_DIR/tui"
  [[ -d "$tui_dir" ]] || die "tui/ directory not found at $tui_dir"
  local missing
  if ! missing=$(tui_ghostty_preflight "$tui_dir"); then
    die "$missing"
  fi
  local build_tags="${LORE_TUI_BUILD_TAGS:-}"
  echo "Building lore-tui -> $out"
  (cd "$tui_dir" && \
    PKG_CONFIG="$(tui_ghostty_pkg_config_shim "$tui_dir")" \
    go build ${build_tags:+-tags "$build_tags"} -o "$out" .)
  echo "Built: $out"
}

cmd_start() {
  require_cmd tmux
  [[ $# -ge 1 ]] || usage
  local session="$1"; shift
  local binary="/tmp/lore-tui-capture"
  local cwd="$PWD"
  local width="$CANONICAL_WIDTH"
  local height="$CANONICAL_HEIGHT"
  local settle=2
  local envs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binary) binary="$2"; shift 2 ;;
      --cwd) cwd="$2"; shift 2 ;;
      --width) width="$2"; shift 2 ;;
      --height) height="$2"; shift 2 ;;
      --env) envs+=(-e "$2"); shift 2 ;;
      --settle) settle="$2"; shift 2 ;;
      *) die "start: unknown argument '$1'" ;;
    esac
  done
  [[ -x "$binary" ]] || die "TUI binary not found or not executable: $binary (run '$0 build -o $binary' first)"
  if tmux has-session -t "$session" 2>/dev/null; then
    die "tmux session '$session' already exists (kill it first)"
  fi
  if [[ "$width" != "$CANONICAL_WIDTH" || "$height" != "$CANONICAL_HEIGHT" ]]; then
    echo "Warning: ${width}x${height} is off the canonical ${CANONICAL_WIDTH}x${CANONICAL_HEIGHT} geometry; capture will not be corpus-comparable" >&2
  fi
  tmux new-session -d -s "$session" -x "$width" -y "$height" -c "$cwd" ${envs[@]+"${envs[@]}"} "$binary"
  sleep "$settle"
  echo "Session '$session' running $binary at ${width}x${height} (cwd: $cwd)"
}

cmd_send() {
  require_cmd tmux
  [[ $# -ge 2 ]] || usage
  local session="$1"; shift
  local settle=0.5
  local keys=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --settle) settle="$2"; shift 2 ;;
      *) keys+=("$1"); shift ;;
    esac
  done
  [[ ${#keys[@]} -ge 1 ]] || die "send: no keys given"
  local key
  for key in "${keys[@]}"; do
    tmux send-keys -t "$session" "$key"
    sleep 0.15
  done
  sleep "$settle"
}

cmd_capture() {
  require_cmd tmux
  [[ $# -eq 2 ]] || usage
  local session="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  tmux capture-pane -e -p -t "$session" > "$out"
  echo "Captured: $out"
}

cmd_render() {
  require_cmd freeze
  [[ $# -ge 1 && $# -le 2 ]] || usage
  local in="$1"
  local out="${2:-${1%.ans}.png}"
  [[ -f "$in" ]] || die "capture file not found: $in"
  freeze --language ansi "$in" -o "$out"
  echo "Rendered: $out"
}

cmd_kill() {
  require_cmd tmux
  [[ $# -eq 1 ]] || usage
  tmux kill-session -t "$1" 2>/dev/null || true
  echo "Session '$1' killed"
}

[[ $# -ge 1 ]] || usage
SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
  build)   cmd_build "$@" ;;
  start)   cmd_start "$@" ;;
  send)    cmd_send "$@" ;;
  capture) cmd_capture "$@" ;;
  render)  cmd_render "$@" ;;
  kill)    cmd_kill "$@" ;;
  *) usage ;;
esac
