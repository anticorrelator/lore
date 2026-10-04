#!/usr/bin/env bash
# prereqs.sh — What lore needs from the machine, and the command that gets each
# missing piece through the machine's own package manager.
#
# Pure bash (3.2-compatible) and dependency-free: it runs before jq or python3
# are known to exist, so install.sh can stop early with a useful message.
#
# Usage:
#   bash prereqs.sh             Print a digest of unmet prerequisites.
#                               Exit 1 when a required one is unmet.
#   bash prereqs.sh --records   One record per unmet prerequisite (see below).
#   source prereqs.sh           Use the functions directly (doctor.sh does).
#
# Record format (fields separated by the ASCII unit separator, \x1f):
#   level  name  detail  pkg  fix
#   level   required | optional
#   name    short identifier (python3, jq, go, ...)
#   detail  what is wrong and what it costs
#   pkg     package name for the detected package manager, empty when the fix
#           is not a plain package install (used to batch installs)
#   fix     the command (or instruction) that resolves it
#
# Fix hints only name the system package manager. They never suggest pip,
# curl-to-shell, or tarball installs. Lore ships its Python libraries
# (scripts/vendor), so no Python package ever has to be installed.

# Minimum Python. 3.9 is what macOS's Command Line Tools ship (/usr/bin/python3),
# and what RHEL 9 and Debian 11 ship. lib.sh::ensure_lore_python enforces the
# same floor.
LORE_PYTHON_MIN_MAJOR=3
LORE_PYTHON_MIN_MINOR=9
# Go that can fetch the toolchain tui/go.mod pins on its own (GOTOOLCHAIN=auto).
LORE_GO_MIN_MINOR=21

_LORE_US=$'\x1f'

# lore_pkg_manager — print the package manager this machine uses:
# brew | port | apt | dnf | yum | pacman | zypper | apk | none.
lore_pkg_manager() {
  if [[ -n "${LORE_PKG_MANAGER:-}" ]]; then
    printf '%s\n' "$LORE_PKG_MANAGER"
    return 0
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then echo brew
      elif command -v port >/dev/null 2>&1; then echo port
      else echo none
      fi
      ;;
    *)
      local pm
      for pm in apt-get dnf yum pacman zypper apk brew; do
        if command -v "$pm" >/dev/null 2>&1; then
          if [[ "$pm" == apt-get ]]; then pm=apt; fi
          echo "$pm"
          return 0
        fi
      done
      echo none
      ;;
  esac
}

# lore_pkg_name <tool> <manager> — the package that provides <tool>, or empty
# when that manager has no plain package for it.
lore_pkg_name() {
  local tool="$1" pm="$2"
  case "$tool" in
    git|jq|tmux) echo "$tool" ;;
    python3)
      case "$pm" in
        brew) echo python ;;
        pacman) echo python ;;
        port) echo python313 ;;
        *) echo python3 ;;
      esac
      ;;
    go)
      case "$pm" in
        apt) echo golang-go ;;
        dnf|yum) echo golang ;;
        *) echo go ;;
      esac
      ;;
    cc)
      case "$pm" in
        apt) echo build-essential ;;
        pacman) echo base-devel ;;
        apk) echo build-base ;;
        dnf|yum|zypper) echo gcc ;;
        *) echo "" ;;  # macOS: Xcode Command Line Tools, not a package
      esac
      ;;
    gh)
      case "$pm" in
        pacman|apk) echo github-cli ;;
        *) echo gh ;;
      esac
      ;;
    *) echo "" ;;
  esac
}

# lore_pkg_install_cmd <manager> <pkg>... — the install command line.
lore_pkg_install_cmd() {
  local pm="$1"; shift
  local sudo="sudo "
  if [[ "$(id -u 2>/dev/null)" == 0 ]]; then sudo=""; fi
  case "$pm" in
    brew)   echo "brew install $*" ;;
    port)   echo "${sudo}port install $*" ;;
    apt)    echo "${sudo}apt-get install -y $*" ;;
    dnf)    echo "${sudo}dnf install -y $*" ;;
    yum)    echo "${sudo}yum install -y $*" ;;
    pacman) echo "${sudo}pacman -S --needed $*" ;;
    zypper) echo "${sudo}zypper install -y $*" ;;
    apk)    echo "${sudo}apk add $*" ;;
    *)      echo "" ;;
  esac
}

# lore_install_hint <tool> — print "<pkg>\x1f<fix>" for <tool> on this machine.
lore_install_hint() {
  local tool="$1" pm pkg fix
  pm=$(lore_pkg_manager)
  pkg=$(lore_pkg_name "$tool" "$pm")
  if [[ -n "$pkg" ]]; then
    fix=$(lore_pkg_install_cmd "$pm" "$pkg")
  fi
  if [[ -z "${fix:-}" ]]; then
    pkg=""
    if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
      case "$tool" in
        git|cc|python3) fix="xcode-select --install   (Apple's Command Line Tools: git, clang, python3)" ;;
        *) fix="install Homebrew (https://brew.sh), then: brew install $(lore_pkg_name "$tool" brew)" ;;
      esac
    else
      fix="install '$tool' with your distribution's package manager"
    fi
  fi
  printf '%s%s%s\n' "$pkg" "$_LORE_US" "$fix"
}

# _lore_record <level> <name> <detail> <tool-for-hint | "-" + literal fix>
_lore_record() {
  local level="$1" name="$2" detail="$3" hint_from="$4" hint
  if [[ "$hint_from" == -* ]]; then
    hint="${_LORE_US}${hint_from#-}"
  else
    hint=$(lore_install_hint "$hint_from")
  fi
  printf '%s%s%s%s%s%s%s\n' "$level" "$_LORE_US" "$name" "$_LORE_US" "$detail" "$_LORE_US" "$hint"
}

# lore_path_fix <dir> — the line that puts <dir> on PATH for the user's shell.
lore_path_fix() {
  local dir="$1"
  case "$(basename "${SHELL:-}")" in
    fish) echo "fish_add_path ${dir/#\$HOME/~}" ;;
    zsh)  echo "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.zshrc   (then open a new terminal)" ;;
    bash)
      if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then
        echo "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.bash_profile   (then open a new terminal)"
      else
        echo "echo 'export PATH=\"$dir:\$PATH\"' >> ~/.bashrc   (then open a new terminal)"
      fi
      ;;
    *) echo "add $dir to PATH in your shell's startup file, then open a new terminal" ;;
  esac
}

# lore_python_version <interpreter> — print "major.minor.micro" or nothing.
lore_python_version() {
  "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null
}

# lore_python_ok <interpreter> — succeed when it meets lore's floor.
lore_python_ok() {
  "$1" -c "import sys; sys.exit(0 if sys.version_info >= ($LORE_PYTHON_MIN_MAJOR, $LORE_PYTHON_MIN_MINOR) else 1)" >/dev/null 2>&1
}

# _lore_have <tool> — succeed when <tool> is on PATH and usable. A fresh Mac
# ships /usr/bin stubs for git, python3 and the C compilers that only work
# once the Command Line Tools are installed (running one opens an install
# dialog), so those count as missing until `xcode-select -p` succeeds.
_lore_have() {
  local path
  path=$(command -v "$1" 2>/dev/null) || return 1
  if [[ "$path" == /usr/bin/* && "$(uname -s 2>/dev/null)" == Darwin ]]; then
    case "$1" in
      git|python3|cc|clang|gcc)
        xcode-select -p >/dev/null 2>&1 || return 1 ;;
    esac
  fi
  return 0
}

# lore_prereq_records — one record per unmet prerequisite (format above).
lore_prereq_records() {
  local floor="$LORE_PYTHON_MIN_MAJOR.$LORE_PYTHON_MIN_MINOR"

  # --- Required ---------------------------------------------------------
  if ! _lore_have git; then
    _lore_record required git "git is not installed; lore keys knowledge stores to git repositories" git
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _lore_record required jq "jq is not installed; lore's scripts read their JSON config with it" jq
  fi
  if ! _lore_have python3; then
    _lore_record required python3 "python3 is not installed; search, capture and most lore commands are Python" python3
  elif ! lore_python_ok python3; then
    local have pm fix
    have=$(lore_python_version python3)
    pm=$(lore_pkg_manager)
    case "$pm" in
      dnf|yum) fix="$(lore_pkg_install_cmd "$pm" python3.11), then put python3.11 first on PATH as python3" ;;
      none) fix="install Python $floor or newer, then make sure python3 on PATH resolves to it" ;;
      *) fix="$(lore_pkg_install_cmd "$pm" "$(lore_pkg_name python3 "$pm")"), then make sure python3 on PATH resolves to it" ;;
    esac
    _lore_record required python3 "python3 on PATH is ${have:-unknown} ($(command -v python3)); lore needs $floor or newer" "-$fix"
  elif ! python3 -c "import sqlite3; sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE t USING fts5(x)')" >/dev/null 2>&1; then
    _lore_record required python3-sqlite-fts5 \
      "python3 ($(command -v python3)) has no SQLite FTS5 support; lore search depends on it" python3
  fi
  # install.sh links the CLI at ~/.local/bin/lore; skills and hooks call `lore`.
  case ":$PATH:" in
    *":$HOME/.local/bin:"*|*":$HOME/.local/bin/:"*) ;;
    *)
      if [[ "$(command -v lore 2>/dev/null)" != "$HOME/.local/bin/lore" ]]; then
        _lore_record required path "~/.local/bin is not on PATH; the lore command will not be found" "-$(lore_path_fix '$HOME/.local/bin')"
      fi
      ;;
  esac

  # --- Optional: each one gates a feature, not lore itself --------------
  if ! command -v go >/dev/null 2>&1; then
    _lore_record optional go "Go is not installed; it builds the TUI (run \`lore\`), which /coordinate needs" go
  else
    local gover minor
    gover=$(go env GOVERSION 2>/dev/null)
    minor=$(printf '%s' "$gover" | sed -n 's/^go1\.\([0-9][0-9]*\).*/\1/p')
    if [[ -n "$minor" && "$minor" -lt "$LORE_GO_MIN_MINOR" ]]; then
      _lore_record optional go "Go is $gover; the TUI build needs go1.$LORE_GO_MIN_MINOR+ (newer Go fetches the exact toolchain tui/go.mod pins)" \
        "-install a newer Go through your package manager; distribution packages can lag, so check that the version it offers is go1.$LORE_GO_MIN_MINOR+"
    fi
  fi
  if ! _lore_have cc && ! _lore_have clang && ! _lore_have gcc; then
    _lore_record optional cc "no C compiler (cc/clang/gcc); the TUI's terminal backend links C code" cc
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    _lore_record optional tmux "tmux is not installed; /coordinate runs worker sessions in it" tmux
  fi
  if ! command -v gh >/dev/null 2>&1; then
    _lore_record optional gh "GitHub CLI (gh) is not installed; /pr-review, /pr-create and the other PR skills use it" gh
  fi
  return 0
}

# lore_render_digest <records> — print numbered steps for records (this file's
# record format; doctor.sh adds its own installation records). Prints nothing
# for no records. Returns 1 when any record is required.
lore_render_digest() {
  local records="$1"
  local pm
  pm=$(lore_pkg_manager)

  # Two passes so numbering runs top to bottom: required first, then optional.
  local req_items="" opt_items="" req_pkgs="" opt_pkgs="" rc=0
  local level name detail pkg fix rest line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    rest="$line"
    level="${rest%%"$_LORE_US"*}"; rest="${rest#*"$_LORE_US"}"
    name="${rest%%"$_LORE_US"*}"; rest="${rest#*"$_LORE_US"}"
    detail="${rest%%"$_LORE_US"*}"; rest="${rest#*"$_LORE_US"}"
    pkg="${rest%%"$_LORE_US"*}"; fix="${rest#*"$_LORE_US"}"
    if [[ "$level" == required ]]; then
      rc=1
      req_items="${req_items}${detail}${_LORE_US}${fix}"$'\n'
      if [[ -n "$pkg" ]]; then req_pkgs="$req_pkgs $pkg"; fi
    else
      opt_items="${opt_items}${detail}${_LORE_US}${fix}"$'\n'
      if [[ -n "$pkg" ]]; then opt_pkgs="$opt_pkgs $pkg"; fi
    fi
  done <<< "$records"

  if [[ -z "$req_items$opt_items" ]]; then
    return 0
  fi
  local n=0 heading items
  for heading in required optional; do
    if [[ "$heading" == required ]]; then items="$req_items"; else items="$opt_items"; fi
    [[ -n "$items" ]] || continue
    if [[ "$heading" == required ]]; then
      echo "  Required:"
    else
      echo "  Optional (lore works without these; the named feature does not):"
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      n=$((n + 1))
      printf '    %d. %s\n       %s\n' "$n" "${line%%"$_LORE_US"*}" "${line#*"$_LORE_US"}"
    done <<< "$items"
    echo ""
  done
  # One command for every package the detected manager can install.
  local all_pkgs="${req_pkgs}${opt_pkgs}"
  if [[ "$(printf '%s' "$all_pkgs" | wc -w | tr -d ' ')" -gt 1 ]]; then
    if [[ -n "$req_pkgs" && -n "$opt_pkgs" ]]; then
      echo "  Required packages in one command:  $(lore_pkg_install_cmd "$pm" ${req_pkgs})"
      echo "  Everything in one command:         $(lore_pkg_install_cmd "$pm" ${all_pkgs})"
    else
      echo "  All of the above in one command:   $(lore_pkg_install_cmd "$pm" ${all_pkgs})"
    fi
    echo ""
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --records) lore_prereq_records ;;
    ""|--digest)
      _records=$(lore_prereq_records)
      if [[ -z "$_records" ]]; then
        echo "  All prerequisites are met."
        exit 0
      fi
      lore_render_digest "$_records"
      exit $?
      ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) echo "Usage: prereqs.sh [--records|--digest]" >&2; exit 1 ;;
  esac
fi
