#!/usr/bin/env bash
# coordinate-arm.sh — Arm the standing eye once; let the harness re-arm it.
#
# `lore coordinate watch` sleeps until the board needs you, but somebody has to
# start it again after every wake. On a harness whose turn-boundary hook can
# enqueue a new turn, that somebody is the harness: arm the hook once at seat
# open and it re-fires a fresh watcher window at the end of every turn, forever,
# without the seat ever remembering to.
#
# Usage:
#   lore coordinate arm  (--owner-pid <pid> | --owner-tmux <session>)
#                        [--tmux-server <name>] [--slug <s>]... [--arc <slug>]...
#                        [--window <sec>] [--hook-timeout <sec>]
#                        [--install <settings.json>] [--kdir <path>] [--json]
#   lore coordinate arm run  (--owner-pid <pid> | --owner-tmux <session>)
#                        [--tmux-server <name>] [--slug <s>]... [--arc <slug>]...
#                        [--window <sec>] [--kdir <path>]
#   lore coordinate disarm --settings <settings.json> [--kdir <path>] [--json]
#
# Three surfaces, one script:
#
#   (no subcommand)  The arming surface a coordinator runs. Prints the hook
#                    entry to install and the exact watcher command line it
#                    carries; `--install <path>` writes the entry into that
#                    settings file through the harness hook adapter.
#   run              The watcher window the hook itself runs. Not a human
#                    surface — every terminal state it can reach becomes a wake.
#   disarm           Removes the installed hook entry again. Same script as arm
#                    so the two cannot disagree about what an armed entry is.
#
# Options (arming surface):
#   --owner-pid <pid>     The long-lived harness process that owns the seat.
#                         Never $$: a subshell's pid dies when the command
#                         returns, recording a handle that looks live now and
#                         fails identically later.
#   --owner-tmux <name>   tmux session name of the owner (same handle format as
#                         `lore coordinate worktree allocate`).
#   --tmux-server <name>  tmux server socket for --owner-tmux (default: lore-tui).
#   --slug <s>            Scope wakes to this work item (repeatable).
#   --arc <slug>          Scope wakes to an arc's declared members (repeatable).
#   --window <sec>        How long one watcher window runs (default: 3600).
#   --hook-timeout <sec>  The hook entry's own timeout (default: 3900). MUST be
#                         strictly greater than --window; see "Two deadlines".
#   --install <path>      Write the entry into this settings file. No default —
#                         the file decides which sessions get armed, and lore
#                         will not guess a scope that could arm unrelated ones.
#   --kdir <path>         Knowledge-store override (test isolation).
#   --json                Emit one machine-readable object instead of prose.
#
# Options (disarm surface):
#   --settings <path>     The settings file to remove the entry from. Required,
#                         and never defaulted, for the same reason --install is
#                         not: the file decides which sessions are affected.
#   --kdir <path>         Knowledge-store override (test isolation).
#   --json                Emit one machine-readable object instead of prose.
#
# Disarming, and what it does not do:
#   Disarm belongs in the arc-closure sequence. A watcher armed for an arc that
#   has since closed keeps waking a seat about a board nobody is working, and
#   nothing else in the closure path switches it off.
#
#   What disarm removes is the hook entry, so no future turn boundary starts a
#   new window. It does not stop a window that is already running: that watcher
#   is a live process holding a per-scope lock, and it ends at its own deadline
#   with a final wake. Expect one more wake after disarming — a still-running
#   watcher is the previous window finishing, not a failed disarm.
#
#   A settings file with no armed entry is reported as such and exits 0, so
#   disarm is safe to run unconditionally at closure without checking first.
#
# What arming records, and why that is not a defaulted scope:
#   A successful --install upserts a record into
#   $KNOWLEDGE_DIR/_coordination/armed-watchers.json, keyed by the absolute
#   settings path, carrying the scope, owner, framework and deadlines it armed
#   with. The seat that closes an arc is often not the seat that armed it — a
#   fresh seat resumes from the ledger, and settings paths are harness config
#   rather than ledger material — so closure needs a mechanical way to find a
#   watcher nobody remembers arming.
#
#   The record is discovery metadata, never authority: the settings file remains
#   the truth about what is armed, disarm works fine with no record at all, and
#   disarm removes the record even when there was no entry to uninstall, so a
#   record can never outlive its hook entry. Reading back a record this surface
#   itself wrote is remembering an explicit choice, not guessing a scope — which
#   is why --install and --settings are still never defaulted. Arming without
#   --install writes nothing: whoever installs the printed entry by hand owns
#   removing it by hand. Every record failure degrades to a stderr note and the
#   behavior that predates the record; none of them blocks arm or disarm.
#
# The owner handle is required (arm and run surfaces only). A watcher with no provable owner is a runaway
# waiting to happen: it would keep waking a seat that no longer exists, and
# nothing in the chain would notice. Refusing here puts the failure in front of
# the person arming it, with a fixable message, instead of leaving a stray
# watcher for somebody to find later.
#
# Two deadlines, and why the inner one is shorter:
#   The hook entry carries an explicit timeout because the harness kills the
#   hook command at it — with a signal, not a report. A killed command exits
#   143, which is not the exit code that enqueues a wake, so a hook that runs
#   past its timeout ends the whole re-arm chain and says nothing about it. The
#   watcher window is therefore set strictly shorter and always exits with a
#   wake of its own, which turns the harness timeout into a backstop that never
#   fires. If it ever does fire, the SIGTERM trap below leaves a marker file so
#   the kill is distinguishable from a clean wake afterwards.
#
# Cross-harness behavior is read from the `turn_boundary_rewake` capability
# cell, never from the framework name:
#   full     Arm the hook; the session parks idle while the window runs.
#   partial  The harness can deliver a wake but only synchronously — a hook-
#            hosted watcher would hold the turn for its whole window. The verb
#            prints the watcher command line and says the seat re-arms it.
#   none     No hook-return continuation at all. Same seat-owned re-arm.
#
# Exit codes:
#   0  armed (or emitted), or the harness degrades and the contract was printed
#   1  usage error, including a missing owner handle
#   2  (run) a wake was delivered on stderr — the harness's re-arm signal
#   3  (run) the owner is provably gone; no wake, no re-arm
#   0  (disarm) the entry was removed, or there was none to remove — both are
#      the state the caller asked for, so neither is a refusal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WATCH_SH="$SCRIPT_DIR/coordinate-watch.sh"
HOOK_COMMAND_PATH="~/.lore/scripts/coordinate-arm.sh"

MODE="arm"
OWNER_PID=""
OWNER_TMUX=""
TMUX_SERVER="lore-tui"
SLUGS=()
ARCS=()
WINDOW=3600
HOOK_TIMEOUT=3900
INSTALL_PATH=""
SETTINGS_PATH=""
KDIR_OVERRIDE=""
JSON_MODE=0

# Grace before a not-alive owner is believed, mirroring session-wait.sh: the
# registry drops an owner before the journal records why it went, so an instant
# verdict reads a teardown as a death.
OWNER_GONE_GRACE_SECONDS=2
# Slack between the watcher's own deadline and the point this wrapper stops
# waiting for it. Only reachable if the watcher overruns its --timeout.
WINDOW_OVERRUN_GRACE_SECONDS="${LORE_ARM_OVERRUN_GRACE_SECONDS:-60}"
# Pause before an error wake so a reader that fails every time re-arms at a
# readable cadence instead of spinning the seat through wake-fail-wake turns.
ERROR_WAKE_BACKOFF_SECONDS="${LORE_ARM_ERROR_BACKOFF_SECONDS:-60}"

usage() {
  sed -n '2,120p' "$0"
}

case "${1:-}" in
  run) MODE="run"; shift ;;
  disarm) MODE="disarm"; shift ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --slug) SLUGS+=("${2:-}"); shift 2 ;;
    --arc) ARCS+=("${2:-}"); shift 2 ;;
    --window) WINDOW="${2:-}"; shift 2 ;;
    --hook-timeout) HOOK_TIMEOUT="${2:-}"; shift 2 ;;
    --install) INSTALL_PATH="${2:-}"; shift 2 ;;
    --settings) SETTINGS_PATH="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-arm.sh [run] (--owner-pid <pid> | --owner-tmux <session>) [--slug <s>]... [--arc <slug>]... [--window <sec>] [--hook-timeout <sec>] [--install <path>] [--kdir <path>] [--json]" >&2
      echo "       coordinate-arm.sh disarm --settings <path> [--kdir <path>] [--json]" >&2
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

# --- Argument validation ------------------------------------------------------

# Disarm takes no owner handle and no window: it removes an entry, it does not
# start anything. Its own flags are validated below, in cmd_disarm.
if [[ "$MODE" != "disarm" ]]; then

if [[ -n "$SETTINGS_PATH" ]]; then
  fail "--settings belongs to 'coordinate disarm'; the arming surface writes with --install <path>"
fi

if [[ -z "$OWNER_PID" && -z "$OWNER_TMUX" ]]; then
  fail 'arming the standing eye requires a liveness handle: pass --owner-pid or --owner-tmux.
  Without one the watcher cannot be proven to still have a seat to wake, so it would
  keep re-arming against a session that is already gone.
  --owner-pid must be the long-lived harness process that owns the seat. Do NOT pass
  $$: a subshell'"'"'s pid dies when the command returns, which records a handle that
  looks live at arm time and fails identically later.'
fi

if [[ -n "$OWNER_PID" ]] && ! [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --owner-pid: '$OWNER_PID' (must be a positive integer)"
fi
if ! [[ "$WINDOW" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --window: '$WINDOW' (must be a positive integer)"
fi
if ! [[ "$HOOK_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --hook-timeout: '$HOOK_TIMEOUT' (must be a positive integer)"
fi
if [[ "$HOOK_TIMEOUT" -le "$WINDOW" ]]; then
  fail "--hook-timeout ($HOOK_TIMEOUT s) must be strictly greater than --window ($WINDOW s): the harness kills the hook at its timeout with a signal, and a killed command cannot deliver the wake that re-arms the chain"
fi

fi  # end arm/run-only validation

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi

SCOPE_ARGS=()
for slug in ${SLUGS+"${SLUGS[@]}"}; do
  [[ -n "$slug" ]] || fail "empty --slug"
  SCOPE_ARGS+=(--slug "$slug")
done
for arc in ${ARCS+"${ARCS[@]}"}; do
  [[ -n "$arc" ]] || fail "empty --arc"
  SCOPE_ARGS+=(--arc "$arc")
done

# --- Owner liveness, biased toward stopping -----------------------------------

# Classify one handle as alive | dead | unknown. This is `owner_live()` from the
# worktree lease with its bias inverted, and the inversion is the point: a lease
# that cannot check protects the tree, because a wrong reclaim destroys work,
# while a watcher that cannot check must stop, because a wrong continuation is a
# runaway nobody is watching for.
probe_pid() {
  local pid="$1"
  command -v ps >/dev/null 2>&1 || { echo unknown; return 0; }
  if ps -p "$pid" >/dev/null 2>&1; then echo alive; else echo dead; fi
}

probe_tmux() {
  local session="$1"
  command -v tmux >/dev/null 2>&1 || { echo unknown; return 0; }
  if tmux -L "$TMUX_SERVER" has-session -t "$session" >/dev/null 2>&1; then
    echo alive
  else
    echo dead
  fi
}

# 0 when every declared handle allows the chain to continue; 1 otherwise. A
# single proof of death stops it, and so does the absence of any proof of life.
owner_may_continue() {
  local saw_alive=0 verdict
  if [[ -n "$OWNER_PID" ]]; then
    verdict="$(probe_pid "$OWNER_PID")"
    [[ "$verdict" == "dead" ]] && return 1
    [[ "$verdict" == "alive" ]] && saw_alive=1
  fi
  if [[ -n "$OWNER_TMUX" ]]; then
    verdict="$(probe_tmux "$OWNER_TMUX")"
    [[ "$verdict" == "dead" ]] && return 1
    [[ "$verdict" == "alive" ]] && saw_alive=1
  fi
  [[ $saw_alive -eq 1 ]]
}

owner_label() {
  local label=""
  if [[ -n "$OWNER_PID" ]]; then
    label="pid $OWNER_PID"
  fi
  if [[ -n "$OWNER_TMUX" ]]; then
    if [[ -n "$label" ]]; then
      label+=", "
    fi
    label+="tmux $TMUX_SERVER:$OWNER_TMUX"
  fi
  echo "$label"
}

# --- The record of what is armed ----------------------------------------------
#
# Sole writer: this script. Arm's --install upserts, disarm removes, and nothing
# else touches the file — one writer is what keeps the record from disagreeing
# with itself about a watcher two seats both think they own.
#
# Discovery metadata, not authority. `lore arc close` reads it to find a watcher
# armed by a seat that is gone; the settings file decides what is actually
# armed. So every failure below is a note and a shrug: an unrecorded arm is the
# behavior that predates this file, and it works.
ARMED_RECORD_FILE="$KNOWLEDGE_DIR/_coordination/armed-watchers.json"

# The key both surfaces agree on. Lexically absolute plus symlinks resolved, so
# `~/.claude/settings.json` from one seat and an absolute path from another land
# on the same record instead of two half-records that each look complete.
abs_settings_path() {
  python3 - "$1" <<'PYEOF' 2>/dev/null
import os, sys
print(os.path.realpath(os.path.expanduser(sys.argv[1])))
PYEOF
}

record_note() {
  echo "[coordinate] $1" >&2
}

# Upsert this arm into the record. 0 when the record now describes it, 1 when it
# does not — callers report the difference and carry on either way.
record_armed_watcher() {
  local settings_abs="$1" framework="$2"
  local dir tmp scope_tokens=() slug arc

  [[ -n "$settings_abs" ]] || { record_note "could not resolve an absolute path for $INSTALL_PATH; the arm was not recorded, so 'lore arc close' will not find it"; return 1; }

  dir="$(dirname "$ARMED_RECORD_FILE")"
  mkdir -p "$dir" 2>/dev/null || { record_note "could not create $dir; the arm was not recorded, so 'lore arc close' will not find it"; return 1; }
  tmp="$(mktemp "$dir/.tmp.armed-watchers.XXXXXX" 2>/dev/null)" || { record_note "could not open a temporary file in $dir; the arm was not recorded"; return 1; }

  for slug in ${SLUGS+"${SLUGS[@]}"}; do scope_tokens+=("slug:$slug"); done
  for arc in ${ARCS+"${ARCS[@]}"}; do scope_tokens+=("arc:$arc"); done

  if python3 - "$ARMED_RECORD_FILE" "$tmp" "$settings_abs" "$(owner_label)" \
      "$framework" "$(timestamp_iso)" "$WINDOW" "$HOOK_TIMEOUT" \
      ${scope_tokens+"${scope_tokens[@]}"} <<'PYEOF'
import json, os, sys

record_path, tmp_path, settings, owner, framework, armed_at = sys.argv[1:7]
window, hook_timeout = int(sys.argv[7]), int(sys.argv[8])
tokens = sys.argv[9:]

records = {}
if os.path.exists(record_path):
    try:
        with open(record_path, encoding="utf-8") as f:
            records = json.load(f)
    except (OSError, ValueError) as exc:
        # Refuse rather than start fresh: an unreadable record may still hold
        # another seat's watcher, and overwriting it would lose the only pointer
        # anyone has to that entry.
        print("existing record at %s is unreadable (%s)" % (record_path, exc), file=sys.stderr)
        raise SystemExit(1)
    if not isinstance(records, dict):
        print("existing record at %s is not an object" % record_path, file=sys.stderr)
        raise SystemExit(1)

records[settings] = {
    "settings_path": settings,
    "scopes": {
        "slugs": [t[len("slug:"):] for t in tokens if t.startswith("slug:")],
        "arcs": [t[len("arc:"):] for t in tokens if t.startswith("arc:")],
    },
    "owner": owner,
    "framework": framework,
    "armed_at": armed_at,
    "window_seconds": window,
    "hook_timeout_seconds": hook_timeout,
}

with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(records, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  then
    mv "$tmp" "$ARMED_RECORD_FILE" && return 0
    rm -f "$tmp"
    record_note "could not move the updated record into $ARMED_RECORD_FILE; the arm was not recorded"
    return 1
  fi

  rm -f "$tmp"
  record_note "the arm was not recorded in $ARMED_RECORD_FILE; 'lore arc close' will not find this watcher, so disarm it by hand: lore coordinate disarm --settings $settings_abs"
  return 1
}

# Drop this settings path from the record. Called on every disarm path that has
# resolved a settings file, including the ones that found nothing to uninstall:
# a record that outlived its hook entry would send a later close chasing a
# watcher that is not there.
forget_armed_watcher() {
  local settings_abs="$1"
  local dir tmp

  [[ -n "$settings_abs" ]] || return 0
  [[ -f "$ARMED_RECORD_FILE" ]] || return 0

  dir="$(dirname "$ARMED_RECORD_FILE")"
  tmp="$(mktemp "$dir/.tmp.armed-watchers.XXXXXX" 2>/dev/null)" || { record_note "could not open a temporary file in $dir; $settings_abs is disarmed but its record remains"; return 1; }

  if python3 - "$ARMED_RECORD_FILE" "$tmp" "$settings_abs" <<'PYEOF'
import json, sys

record_path, tmp_path, settings = sys.argv[1:4]
try:
    with open(record_path, encoding="utf-8") as f:
        records = json.load(f)
except (OSError, ValueError) as exc:
    print("record at %s is unreadable (%s)" % (record_path, exc), file=sys.stderr)
    raise SystemExit(1)
if not isinstance(records, dict):
    print("record at %s is not an object" % record_path, file=sys.stderr)
    raise SystemExit(1)

records.pop(settings, None)

with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(records, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  then
    mv "$tmp" "$ARMED_RECORD_FILE" && return 0
    rm -f "$tmp"
    record_note "could not move the updated record into $ARMED_RECORD_FILE; $settings_abs is disarmed but its record remains"
    return 1
  fi

  rm -f "$tmp"
  record_note "could not update $ARMED_RECORD_FILE; $settings_abs is disarmed but its record remains, so a later 'lore arc close' may report a watcher that is already gone"
  return 1
}

# --- Arming surface -----------------------------------------------------------

# The command line the hook runs. The LORE_FRAMEWORK prefix is what keeps a
# multi-harness install routing correctly: framework.json holds whichever
# harness was installed last, so a hook that omits the prefix resolves to the
# wrong adapter for every harness but that one.
watcher_command() {
  local framework="$1"
  local cmd="LORE_FRAMEWORK=$framework bash $HOOK_COMMAND_PATH run"
  [[ -n "$OWNER_PID" ]] && cmd+=" --owner-pid $OWNER_PID"
  if [[ -n "$OWNER_TMUX" ]]; then
    cmd+=" --owner-tmux $OWNER_TMUX --tmux-server $TMUX_SERVER"
  fi
  for slug in ${SLUGS+"${SLUGS[@]}"}; do cmd+=" --slug $slug"; done
  for arc in ${ARCS+"${ARCS[@]}"}; do cmd+=" --arc $arc"; done
  cmd+=" --window $WINDOW"
  printf '%s' "$cmd"
}

REWAKE_MESSAGE="The board watcher you armed finished a window. Read the wake on stderr, act on what it reports, then end your turn: ending the turn is what arms the next window."

cmd_arm() {
  local framework support adapter command entry="" install_abs="" recorded=0
  framework="$(resolve_active_framework 2>/dev/null)" || framework=""
  [[ -n "$framework" ]] || fail "could not resolve the active harness; set LORE_FRAMEWORK for this process"

  support="$(framework_capability turn_boundary_rewake "$framework")"
  command="$(watcher_command "$framework")"
  adapter="$LORE_REPO_DIR/adapters/hooks/$framework.sh"

  if [[ "$support" == "full" ]]; then
    [[ -f "$adapter" ]] || fail "turn_boundary_rewake is '$support' on $framework but its hook adapter is missing at $adapter"
    entry="$("$adapter" rewake-entry \
      --framework "$framework" \
      --command "$command" \
      --timeout "$HOOK_TIMEOUT" \
      --message "$REWAKE_MESSAGE")" || fail "hook adapter could not render the rewake entry"
    if [[ -n "$INSTALL_PATH" ]]; then
      "$adapter" rewake-install \
        --framework "$framework" \
        --settings "$INSTALL_PATH" \
        --command "$command" \
        --timeout "$HOOK_TIMEOUT" \
        --message "$REWAKE_MESSAGE" || fail "hook adapter could not install the rewake entry into $INSTALL_PATH"
      # Only a successful install is recorded. A record written beside a failed
      # install would point a later closure at a watcher that was never armed.
      install_abs="$(abs_settings_path "$INSTALL_PATH")" || install_abs=""
      if record_armed_watcher "$install_abs" "$framework"; then
        recorded=1
      fi
    fi
  elif [[ -n "$INSTALL_PATH" ]]; then
    fail "refusing --install: turn_boundary_rewake is '$support' on $framework, so an installed hook would not re-arm anything. Run the printed watcher command from the seat instead."
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg fw "$framework" \
      --arg support "$support" \
      --arg command "$command" \
      --arg installed "${INSTALL_PATH:-}" \
      --argjson entry "${entry:-null}" \
      --argjson window "$WINDOW" \
      --argjson hook_timeout "$HOOK_TIMEOUT" \
      '{framework: $fw, turn_boundary_rewake: $support, watcher_command: $command,
        window_seconds: $window, hook_timeout_seconds: $hook_timeout,
        hook_entry: $entry, installed_into: (if $installed == "" then null else $installed end)}')"
  fi

  echo "[coordinate] harness $framework, turn_boundary_rewake: $support"
  echo "[coordinate] owner handle: $(owner_label)"
  echo "[coordinate] watcher window ${WINDOW}s inside a ${HOOK_TIMEOUT}s hook timeout"
  echo
  echo "Watcher command:"
  echo "  $command"
  echo

  case "$support" in
    full)
      echo "Stop hook entry:"
      printf '%s\n' "$entry"
      echo
      if [[ -n "$INSTALL_PATH" ]]; then
        echo "[coordinate] installed into $INSTALL_PATH — the next turn boundary arms the first window."
        if [[ $recorded -eq 1 ]]; then
          echo "[coordinate] recorded in $ARMED_RECORD_FILE, so 'lore arc close' can find this watcher."
        fi
      else
        echo "[coordinate] not installed. Add the entry to the settings file whose scope you want armed,"
        echo "             or re-run with --install <settings.json>. Every session that reads that file"
        echo "             gets this watcher, so pick the file deliberately."
      fi
      ;;
    partial)
      echo "[coordinate] degraded: $framework delivers a hook continuation but runs hooks synchronously,"
      echo "             so a hook-hosted watcher would hold the turn for the whole ${WINDOW}s window."
      echo "             Run the watcher command from the seat and re-arm it after each wake."
      ;;
    *)
      echo "[coordinate] degraded: $framework has no turn-boundary continuation channel (support: $support)."
      echo "             Run the watcher command from the seat and re-arm it after each wake."
      ;;
  esac
}

# --- Disarming surface --------------------------------------------------------

# How many Stop entries the settings file carries. Compared across the adapter
# call to tell "removed one" from "there was none" — the adapter filters by its
# own command marker and reports neither, and duplicating that marker here would
# put the identity of an armed entry in a second place.
stop_entry_count() {
  local path="$1"
  [[ -f "$path" ]] || { echo 0; return 0; }
  python3 - "$path" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    print(0)
    raise SystemExit(0)
print(len((settings.get("hooks") or {}).get("Stop") or []))
PYEOF
}

disarm_report() {
  local framework="$1" support="$2" removed="$3" note="$4"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg fw "$framework" \
      --arg support "$support" \
      --arg settings "$SETTINGS_PATH" \
      --arg note "$note" \
      --argjson removed "$removed" \
      '{framework: $fw, turn_boundary_rewake: $support, settings: $settings,
        entries_removed: $removed, note: $note}')"
  fi
  echo "[coordinate] $note"
}

cmd_disarm() {
  local framework support adapter before after removed settings_abs

  [[ -n "$SETTINGS_PATH" ]] || fail "disarming requires --settings <path>: the settings file decides which sessions are disarmed, and lore will not guess a scope that could switch off a board somebody else is still working"

  settings_abs="$(abs_settings_path "$SETTINGS_PATH")" || settings_abs=""

  framework="$(resolve_active_framework 2>/dev/null)" || framework=""
  [[ -n "$framework" ]] || fail "could not resolve the active harness; set LORE_FRAMEWORK for this process"

  support="$(framework_capability turn_boundary_rewake "$framework")"
  adapter="$LORE_REPO_DIR/adapters/hooks/$framework.sh"

  # On a degraded harness the arming surface refuses --install outright, so no
  # entry was ever written and there is nothing here to remove. The watcher on
  # such a harness is seat-run, and it stops when the seat stops re-running it.
  if [[ "$support" != "full" ]]; then
    disarm_report "$framework" "$support" 0 \
      "nothing to disarm: turn_boundary_rewake is '$support' on $framework, so no hook entry was ever installed. A watcher here is seat-run — stop re-running it and it ends at its window deadline."
    exit 0
  fi

  [[ -f "$adapter" ]] || fail "turn_boundary_rewake is '$support' on $framework but its hook adapter is missing at $adapter"

  if [[ ! -f "$SETTINGS_PATH" ]]; then
    # No file, so no entry — and therefore no record is allowed to survive.
    forget_armed_watcher "$settings_abs" || true
    disarm_report "$framework" "$support" 0 \
      "nothing to disarm: no settings file at $SETTINGS_PATH."
    exit 0
  fi

  before="$(stop_entry_count "$SETTINGS_PATH")"
  "$adapter" rewake-uninstall \
    --framework "$framework" \
    --settings "$SETTINGS_PATH" || fail "hook adapter could not remove the rewake entry from $SETTINGS_PATH"
  after="$(stop_entry_count "$SETTINGS_PATH")"
  removed=$(( before - after ))

  # The entry goes first, the record after it — in that order, a failure between
  # the two leaves a record with no entry (a stale pointer a later close resolves
  # to "nothing to disarm") rather than an entry with no record (a live watcher
  # no closure can find).
  forget_armed_watcher "$settings_abs" || true

  if [[ "$removed" -le 0 ]]; then
    disarm_report "$framework" "$support" 0 \
      "nothing to disarm: $SETTINGS_PATH carries no armed watcher entry."
    exit 0
  fi

  local noun="entries"
  [[ "$removed" -eq 1 ]] && noun="entry"
  disarm_report "$framework" "$support" "$removed" \
    "disarmed: removed $removed watcher $noun from $SETTINGS_PATH — no further turn boundary will start a window. A window already running holds its own lock and ends at its deadline, so one more wake is expected."
  exit 0
}

# --- Watcher window (the polarity shim) ---------------------------------------
#
# `coordinate watch` speaks exit codes to a caller that can read them: 0 for a
# match, 2 for a quiet timeout, 3 for a vanished owner, 4 for a reader failure.
# The rewake channel speaks a different language — only exit 2 with something on
# stderr reaches the seat, and every other code is silence. So every terminal
# state that should reach a person becomes exit 2 here, and the one state that
# should not — a seat that no longer exists — is the only one that stays quiet.

KILL_MARKER_FILE="$KNOWLEDGE_DIR/_coordination/arm-window-killed.json"
WATCH_PID=""
WINDOW_STARTED_AT=""

# --- One live window per scope ------------------------------------------------
#
# The harness does not deduplicate async hooks: "each execution creates a
# separate background process. There is no deduplication across multiple firings
# of the same async hook." Stop fires at every turn boundary, including turns a
# user message or an unrelated notification causes while a window is already
# running. Without a guard an active seat accumulates one watcher per turn — all
# on the same scope, all racing the same cursor file, all waking for the same
# row.
#
# So: one scope, one window. A second instance that finds the lock held exits 0
# and emits nothing. That is not wake suppression. The instance holding the lock
# owns this window and will deliver its wake on stderr with exit 2, and its exit
# arms the next one; what the loser suppresses is a duplicate *watcher*, not a
# wake. Every row still reaches the seat exactly once.
#
# The lock is an flock on a descriptor this process holds open, which is the
# whole reason to use one: the kernel drops it when the process dies, including
# a SIGKILL that runs no trap. Do not replace it with a pidfile and a staleness
# check — that reintroduces by hand the stale-holder problem flock does not have,
# and a wrong staleness verdict either strands the seat or stacks watchers again.
#
# Descriptor 9 is written literally rather than through a variable: bash 3.2 (the
# system bash on macOS) cannot take a variable as a redirection target, and an
# eval to work around that buys nothing over a named constant in comments.
WINDOW_LOCK_FD=9

# Same recipe the watcher uses for its per-scope sidecars: order-insensitive and
# duplicate-insensitive, so one scope written two ways takes one lock. Keyed on
# the declared scope rather than the arc-expanded one — the firings this guards
# against all carry the identical command line the hook entry was armed with.
scope_lock_file() {
  local slug arc tokens="" key suffix=""
  for slug in ${SLUGS+"${SLUGS[@]}"}; do tokens+="slug:$slug"$'\n'; done
  for arc in ${ARCS+"${ARCS[@]}"}; do tokens+="arc:$arc"$'\n'; done
  if [[ -n "$tokens" ]]; then
    key="$(printf '%s' "$tokens" | LC_ALL=C sort -u \
      | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')"
    suffix="-$key"
  fi
  printf '%s' "$KNOWLEDGE_DIR/_coordination/arm-window${suffix}.lock"
}

# 0 when this process now owns the window, 1 when another instance already does.
# Anything that stops the lock from being taken at all — no python3, an
# unwritable store — degrades to running the window: a missed dedup costs a
# duplicate wake, while refusing to run would cost the wake itself.
acquire_window_lock() {
  local lock_file="$1"
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[coordinate] no python3 to take the per-scope window lock; running unguarded (duplicate watchers possible)" >&2
    return 0
  fi
  if ! exec 9>"$lock_file"; then
    echo "[coordinate] could not open $lock_file; running unguarded (duplicate watchers possible)" >&2
    return 0
  fi
  local status=0
  python3 - "$WINDOW_LOCK_FD" <<'PY' || status=$?
import fcntl, sys
try:
    fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
PY
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      echo "[coordinate] per-scope window lock could not be evaluated (exit $status); running unguarded" >&2
      return 0
      ;;
  esac
}

# The harness kills this command at the hook timeout, and a killed hook is
# indistinguishable from one that simply never woke anybody. The marker is the
# distinguishing evidence, written where the next window's operator can find it.
write_kill_marker() {
  local dir tmp elapsed
  dir="$(dirname "$KILL_MARKER_FILE")"
  mkdir -p "$dir" 2>/dev/null || return 0
  elapsed=$(( $(date +%s) - ${WINDOW_STARTED_AT:-$(date +%s)} ))
  tmp="$(mktemp "$dir/.tmp.arm-window-killed.XXXXXX")" || return 0
  if jq -n \
    --arg at "$(timestamp_iso)" \
    --arg owner "$(owner_label)" \
    --argjson window "$WINDOW" \
    --argjson elapsed "$elapsed" \
    '{killed_at: $at, owner: $owner, window_seconds: $window, elapsed_seconds: $elapsed,
      note: "SIGTERM reached the armed watcher window. The re-arm chain stopped here: a signalled hook exits 143, which the harness does not read as a wake."}' \
    > "$tmp" 2>/dev/null; then
    mv "$tmp" "$KILL_MARKER_FILE"
  else
    rm -f "$tmp"
  fi
}

on_sigterm() {
  trap - TERM
  [[ -n "$WATCH_PID" ]] && kill -TERM "$WATCH_PID" 2>/dev/null || true
  write_kill_marker
  exit 143
}

# Exit 2 with the body on stderr: the only shape the rewake channel reads.
emit_wake() {
  local tier="$1" body="$2"
  {
    echo "[coordinate wake] $tier — window ${WINDOW}s, owner $(owner_label)"
    if [[ -n "$body" ]]; then
      printf '%s\n' "$body"
    fi
  } >&2
  exit 2
}

emit_owner_gone() {
  echo "[coordinate] owner is gone ($(owner_label)); the armed watcher stops here and does not re-arm" >&2
  exit 3
}

cmd_run() {
  # Before anything else, and before the TERM trap: a losing instance should
  # cost the seat one fork, not a grace sleep and a kill marker.
  acquire_window_lock "$(scope_lock_file)" || exit 0

  trap on_sigterm TERM

  if ! owner_may_continue; then
    sleep "$OWNER_GONE_GRACE_SECONDS"
    owner_may_continue || emit_owner_gone
  fi

  local out_file err_file watch_status=0 overran=0 hard_deadline now
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$out_file' '$err_file'" EXIT

  WINDOW_STARTED_AT="$(date +%s)"
  # The watcher does not inherit the lock descriptor. The lock names the wrapper
  # that can still deliver a wake, so it must die with the wrapper: an orphaned
  # watcher holding it would block every re-arm for a whole window while having
  # no channel left to wake anyone through.
  "$WATCH_SH" --wake-shaped --timeout "$WINDOW" \
    ${KDIR_OVERRIDE:+--kdir "$KDIR_OVERRIDE"} \
    ${SCOPE_ARGS+"${SCOPE_ARGS[@]}"} \
    >"$out_file" 2>"$err_file" 9>&- &
  WATCH_PID=$!

  # The watcher owns its own deadline; this only catches the case where it does
  # not come back at it, because a window that outlives the hook timeout is the
  # silent-kill this whole design exists to make impossible.
  hard_deadline=$(( WINDOW_STARTED_AT + WINDOW + WINDOW_OVERRUN_GRACE_SECONDS ))
  while kill -0 "$WATCH_PID" 2>/dev/null; do
    now="$(date +%s)"
    if [[ "$now" -ge "$hard_deadline" ]]; then
      kill -TERM "$WATCH_PID" 2>/dev/null || true
      overran=1
      break
    fi
    sleep 1
  done
  wait "$WATCH_PID" || watch_status=$?
  WATCH_PID=""

  local body
  body="$(cat "$out_file"; cat "$err_file")"

  if [[ $overran -eq 1 ]]; then
    emit_wake "overran" "The watcher did not return at its ${WINDOW}s deadline and was stopped ${WINDOW_OVERRUN_GRACE_SECONDS}s past it. Nothing was read after that point.
$body"
  fi

  # A window that ends while the seat is gone has nobody to wake; every other
  # ending does, including the ones that found nothing.
  if ! owner_may_continue; then
    sleep "$OWNER_GONE_GRACE_SECONDS"
    owner_may_continue || emit_owner_gone
  fi

  case "$watch_status" in
    0) emit_wake "actionable" "$body" ;;
    2) emit_wake "quiet" "$body" ;;
    3) emit_owner_gone ;;
    *)
      sleep "$ERROR_WAKE_BACKOFF_SECONDS"
      emit_wake "watcher-failed (exit $watch_status)" "$body"
      ;;
  esac
}

case "$MODE" in
  arm) cmd_arm ;;
  run) cmd_run ;;
  disarm) cmd_disarm ;;
esac
