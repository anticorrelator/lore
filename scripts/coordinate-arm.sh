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
#                        (--install <settings.json> | --render)
#                        [--tmux-server <name>] [--arc <slug>]...
#                        [--window <sec>] [--hook-timeout <sec>]
#                        [--kdir <path>] [--json]
#   lore coordinate arm run  (--owner-pid <pid> | --owner-tmux <session>)
#                        [--tmux-server <name>] [--arc <slug>]...
#                        [--window <sec>] [--kdir <path>]
#   lore coordinate disarm --settings <settings.json> [--kdir <path>] [--json]
#
# Three surfaces, one script:
#
#   (no subcommand)  The arming surface a coordinator runs. `--install <path>`
#                    writes the hook entry into that settings file through the
#                    harness hook adapter and reads it back to prove it landed;
#                    `--render` prints the entry and the watcher command line it
#                    carries and arms nothing. One of the two is required; see
#                    "Arming and rendering are separate requests" below.
#   run              The watcher window the hook itself runs. Not a human
#                    surface — every terminal state it can reach becomes a wake.
#   disarm           Removes the installed hook entry again. Same script as arm
#                    so the two cannot disagree about what an armed entry is.
#
# Options (arming surface):
#   --owner-pid <pid>     The long-lived harness process that owns the seat.
#                         A pid that is not alive is refused outright: the
#                         handle would be dead before the watcher is armed, and
#                         the first window would stop on a seat that was never
#                         there.
#   --owner-tmux <name>   tmux session name of the owner (same handle format as
#                         `lore coordinate worktree allocate`).
#   --tmux-server <name>  tmux server socket for --owner-tmux (default: lore-tui).
#   --arc <slug>          Scope wakes to an arc's declared members (repeatable).
#                         The arc must have a record in the store being armed
#                         from; see "A scope is checked before it is armed".
#   --window <sec>        How long one watcher window runs (default: 600).
#   --hook-timeout <sec>  The hook entry's own timeout (default: 660). MUST be
#                         strictly greater than --window; see "Two deadlines".
#   --install <path>      Write the entry into this settings file. No default —
#                         the file decides which sessions get armed, and lore
#                         will not guess a scope that could arm unrelated ones.
#   --render              Print the entry and the watcher command without
#                         writing anything. Whoever installs a rendered entry by
#                         hand owns removing it by hand. Not combinable with
#                         --install: one writes, the other deliberately does not.
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
# Arming and rendering are separate requests, and one of them must be made:
#   A bare `lore coordinate arm` used to print the hook entry and exit 0 with
#   nothing armed. The output reads exactly like success — a watcher command, a
#   hook entry, no error — so a seat takes it for an armed eye, and then nothing
#   ever wakes it. That has cost two seats a park each: one arc's worker sat
#   finished for over an hour with its coordinator blind, and an earlier seat
#   stalled on the same ambiguity.
#
#   So the mode is now always explicit. `--install <path>` arms and says what it
#   armed; `--render` prints and says it armed nothing; passing neither is a
#   usage error naming both, and passing both is a usage error too. The one thing
#   this surface will not do is pick a settings file on your behalf: installing
#   into a shared file arms every session that reads it, which is why the path is
#   never defaulted and rendering stays a first-class mode rather than a fallback.
#
#   A successful --install is verified by reading the settings file back and
#   finding the exact command that was armed. An adapter that exits 0 without
#   leaving an entry is the same silence in a different place, so it is reported
#   as a failure rather than as an install.
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
# How a later closure finds this watcher:
#   The installed hook entry carries its own scope. `watcher_command` writes the
#   `--arc <slug>` flags into the command line verbatim, and the
#   `LORE_FRAMEWORK=<name>` prefix names the adapter that installed it — so the
#   settings file answers who armed what, for whom, without a second file
#   mirroring it. `lore arc close` reads the entry. Nothing is recorded anywhere
#   else, and --install and --settings stay undefaulted: which settings file gets
#   the entry is the arm.
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
#   fires. That invariant is validated at arm time and refused loudly, which is
#   where the guarantee lives.
#
#   The defaults pair a ten-minute window with an eleven-minute hook timeout, so
#   a seat hears from its board at least every ten minutes. A quiet window is
#   still a wake — it says the board had nothing, and ending that turn opens the
#   next window. Pass a longer --window (and a --hook-timeout above it) if a
#   seat genuinely wants to hear less often.
#
# A window runs only for the seat that armed it:
#   The hook entry lives in a settings file, and every session that reads that
#   file fires it at every turn boundary — including sessions with no connection
#   to the seat named in the entry. So `run` first walks its own process
#   ancestry: the harness runs an armed hook as a direct child of the session
#   whose turn ended, so the owning seat is this process or one of its parents.
#   A firing that does not descend from a live --owner-pid is somebody else's
#   turn boundary reaching this seat's entry; it exits 0 without opening a window
#   and without a wake, which leaves the owner's own firing free to take the
#   window.
#
#   When the process table cannot be read at all, the window runs. The same
#   trade the per-scope lock makes: a missed rejection costs one duplicate
#   window, while refusing on an unreadable ancestry would cost the wake itself.
#
# Every window says what it did:
#   Each `run` appends one line to
#   $KNOWLEDGE_DIR/_coordination/arm-window<scope>.log, keyed by the same
#   per-scope suffix the window lock uses. The line carries the timestamp, this
#   process, its parent, the owner handle the entry was armed with, and what
#   became of the window: foreign, lock-held, opened, or the terminal it reached.
#   This script is the file's only writer; everything else reads it.
#
#   A window that opens and never delivers is otherwise indistinguishable from
#   one that was never opened — both are exit 0 with nothing on any stream — so
#   this is the file to read first when a seat has gone quiet. It is trimmed to
#   its recent tail past a small byte ceiling, and a log that cannot be written
#   degrades to a note on stderr rather than costing the window.
#
# A scope is checked before it is armed:
#   Every --arc is expanded against the store this command resolved, before
#   anything is written or printed, and an arc with no record there is refused by
#   name alongside the store it was looked for in. Membership is whatever the arc
#   record declares; an arc that exists but declares no members yet is armed with
#   a note, because arming at arc open precedes adding members.
#
#   Installing also reports what it displaced. One settings file holds one
#   watcher entry, so arming into a file another seat already armed replaces that
#   seat's entry — the report names its owner and scope, so the seat doing the
#   arming can put it back.
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
#   0  armed and verified, or --render printed the contract and said so
#   1  usage error: a missing owner handle, neither --install nor --render,
#      both of them, or an --install the settings file does not carry afterwards
#   2  (run) a wake was delivered on stderr — the harness's re-arm signal
#   3  (run) the owner is provably gone; no wake, no re-arm
#   0  (run) this firing belongs to another seat, or a window for this scope is
#      already open; no window, no wake, and the window log says which it was
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
ARCS=()
WINDOW=600
HOOK_TIMEOUT=660
INSTALL_PATH=""
RENDER_ONLY=0
SETTINGS_PATH=""
KDIR_OVERRIDE=""
JSON_MODE=0

# Grace before a not-alive owner is believed, mirroring session-wait.sh: the
# registry drops an owner before the journal records why it went, so an instant
# verdict reads a teardown as a death.
OWNER_GONE_GRACE_SECONDS=2
# Pause before an error wake so a reader that fails every time re-arms at a
# readable cadence instead of spinning the seat through wake-fail-wake turns.
ERROR_WAKE_BACKOFF_SECONDS="${LORE_ARM_ERROR_BACKOFF_SECONDS:-60}"

usage() {
  sed -n '2,189p' "$0"
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
    --arc) ARCS+=("${2:-}"); shift 2 ;;
    --window) WINDOW="${2:-}"; shift 2 ;;
    --hook-timeout) HOOK_TIMEOUT="${2:-}"; shift 2 ;;
    --install) INSTALL_PATH="${2:-}"; shift 2 ;;
    --render) RENDER_ONLY=1; shift ;;
    --settings) SETTINGS_PATH="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-arm.sh [run] (--owner-pid <pid> | --owner-tmux <session>) (--install <path> | --render) [--arc <slug>]... [--window <sec>] [--hook-timeout <sec>] [--kdir <path>] [--json]" >&2
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
if [[ "$MODE" != "arm" && $RENDER_ONLY -eq 1 ]]; then
  fail "--render belongs to the arming surface: it chooses between writing the hook entry and only printing it. '$MODE' does neither"
fi

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

# The arming surface's own check on the handle it is about to bake into a hook
# entry: a dead pid arms a watcher that halts at its first window, which reads as
# silence rather than as a refusal.
#
# The arm surface only. `run` receives the pid the hook entry was armed with, and
# the harness runs that hook as a direct child of the process the pid names — so
# owner == parent is the correct arrangement there, not the mistake. `run`
# already answers a dead owner with exit 3.
check_arm_owner_pid() {
  [[ -n "$OWNER_PID" ]] || return 0
  if [[ "$(probe_pid "$OWNER_PID")" == "dead" ]]; then
    fail "refusing --owner-pid $OWNER_PID: no such process. The handle is dead before the
  watcher is even armed, so the first window would stop on a seat that was never there.
  Pass the pid of a process that is alive now and outlives this command."
  fi
}

# The arming surface's check on the scope it is about to bake into the entry,
# and the third member of the set the other two already cover: a dead handle is
# refused, an install that did not land is refused, and a scope that resolves to
# nothing would otherwise arm a watcher that exits 1 at every window.
#
# Which store the scope is resolved against matters as much as the answer: the
# hook command carries no --kdir, so a session running this entry resolves the
# store from its own working directory. Naming the store here is what makes a
# refusal actionable rather than puzzling.
check_arm_arc_scope() {
  local arc status members
  [[ ${#ARCS[@]} -gt 0 ]] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    record_note "no python3 to expand --arc against $KNOWLEDGE_DIR; the scope is being armed unchecked"
    return 0
  fi
  for arc in ${ARCS[@]+"${ARCS[@]}"}; do
    status=0
    members="$(session_arc_member_slugs "$KNOWLEDGE_DIR" "$arc")" || status=$?
    case "$status" in
      0) ;;
      1) fail "refusing --arc '$arc': $KNOWLEDGE_DIR has no arc record at _work/_arcs/$arc/_meta.json.
  A watcher armed for a scope that resolves to nothing exits with an error at every window and
  wakes nobody. Check the slug, or arm from the store the arc lives in — the installed entry
  carries no store path, so every window resolves it from the running session's directory." ;;
      2) fail "refusing --arc '$arc': its record in $KNOWLEDGE_DIR is not readable as a JSON object
  (_work/_arcs/$arc/_meta.json). Repair the record before arming an eye that depends on it." ;;
      3) fail "refusing --arc '$arc': its record in $KNOWLEDGE_DIR is archived or carries an unknown
  status, and the watcher will not expand it. Reopen the arc, or arm the whole board instead." ;;
      *) fail "refusing --arc '$arc': could not expand it against $KNOWLEDGE_DIR (exit $status)" ;;
    esac
    # An arc opens before it has members, and arming is part of opening one, so
    # an empty members[] is a note rather than a refusal. It does mean this
    # scope contributes nothing until members are added.
    if [[ -z "${members//[[:space:]]/}" ]]; then
      record_note "arc '$arc' declares no members yet; it contributes nothing to this scope until members are added"
    fi
  done
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

# --- Notes that do not fail the arm ------------------------------------------

record_note() {
  echo "[coordinate] $1" >&2
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
  for arc in ${ARCS+"${ARCS[@]}"}; do cmd+=" --arc $arc"; done
  cmd+=" --window $WINDOW"
  printf '%s' "$cmd"
}

REWAKE_MESSAGE="The board watcher you armed finished a window. Read the wake on stderr, act on what it reports, then end your turn: ending the turn is what arms the next window."

# 0 when the settings file carries a Stop hook whose command is exactly the one
# this arm composed. The adapter reports success by exit code, and an exit code
# is a claim about a write, not the write — so the claim is checked against the
# file. Same failure class as a bare arm reading like an armed one, one layer
# further in.
installed_entry_present() {
  local path="$1" cmd="$2"
  [[ -f "$path" ]] || return 1
  python3 - "$path" "$cmd" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        settings = json.load(f)
except (OSError, ValueError):
    raise SystemExit(1)
wanted = sys.argv[2]
for entry in (settings.get("hooks") or {}).get("Stop") or []:
    for hook in entry.get("hooks") or []:
        if hook.get("command") == wanted:
            raise SystemExit(0)
raise SystemExit(1)
PYEOF
}

# The gate that keeps this verb from ever succeeding without having armed
# anything. Runs after the harness is known, because what the caller can even ask
# for depends on it: a harness with no turn-boundary continuation has no entry to
# install, so --render is the only request it can honor.
require_explicit_mode() {
  local support="$1" framework="$2" command="$3"

  if [[ -n "$INSTALL_PATH" && $RENDER_ONLY -eq 1 ]]; then
    fail "refusing --install with --render: --install writes the hook entry into $INSTALL_PATH, --render
  deliberately writes nothing. Pass the one you meant — there is no reading of both that arms a watcher
  and also leaves the file untouched."
  fi

  if [[ -n "$INSTALL_PATH" || $RENDER_ONLY -eq 1 ]]; then
    return 0
  fi

  if [[ "$support" == "full" ]]; then
    fail "refusing a bare arm: nothing was armed, and printing the entry here would read exactly like
  having armed it — a watcher command, a hook entry, exit 0 — while no window ever opens and every park
  goes unseen. Say which you want:
    --install <settings.json>   write the entry and arm the standing eye
    --render                    print the entry and the watcher command, arming nothing
  The settings file is never defaulted: every session that reads it inherits this watcher, so the scope
  is yours to choose. Choosing it is the arm."
  fi

  fail "refusing a bare arm: turn_boundary_rewake is '$support' on $framework, so there is no hook entry
  to install here and this command can only print — which, at exit 0 with no request made, reads as an
  armed watcher that does not exist. Pass --render to print the contract, then run the watcher from the
  seat, re-running it after each wake:
    $command"
}

# What an install replaced, as the hook adapter reported it. Empty when the
# settings file carried no watcher entry of its own.
DISPLACED=""

cmd_arm() {
  local framework support adapter command entry="" displaced_line
  framework="$(resolve_active_framework 2>/dev/null)" || framework=""
  [[ -n "$framework" ]] || fail "could not resolve the active harness; set LORE_FRAMEWORK for this process"

  support="$(framework_capability turn_boundary_rewake "$framework")"
  command="$(watcher_command "$framework")"
  adapter="$LORE_REPO_DIR/adapters/hooks/$framework.sh"

  require_explicit_mode "$support" "$framework" "$command"
  # After the mode is settled and before anything is written or printed: the
  # scope has to resolve in this store or there is nothing worth arming.
  check_arm_arc_scope

  if [[ "$support" == "full" ]]; then
    [[ -f "$adapter" ]] || fail "turn_boundary_rewake is '$support' on $framework but its hook adapter is missing at $adapter"
    entry="$("$adapter" rewake-entry \
      --framework "$framework" \
      --command "$command" \
      --timeout "$HOOK_TIMEOUT" \
      --message "$REWAKE_MESSAGE")" || fail "hook adapter could not render the rewake entry"
    if [[ -n "$INSTALL_PATH" ]]; then
      # The adapter's stdout is its account of what the install displaced: one
      # settings file holds one watcher entry, so arming here can switch off an
      # eye somebody else is relying on.
      DISPLACED="$("$adapter" rewake-install \
        --framework "$framework" \
        --settings "$INSTALL_PATH" \
        --command "$command" \
        --timeout "$HOOK_TIMEOUT" \
        --message "$REWAKE_MESSAGE")" || fail "hook adapter could not install the rewake entry into $INSTALL_PATH"
      # The adapter said it wrote; the file says whether it did. Without python3
      # there is no way to read it back, and refusing a good install over a
      # missing interpreter would be the louder error in the wrong direction —
      # so that one case degrades to a note naming what went unchecked.
      if command -v python3 >/dev/null 2>&1; then
        installed_entry_present "$INSTALL_PATH" "$command" || fail "the hook adapter reported success but $INSTALL_PATH does not carry the entry
  it was asked to write. Nothing is armed, whatever the adapter's exit code said. Inspect that file's
  Stop hooks before re-running: something else is writing it, or the write did not survive."
      else
        record_note "no python3 to read $INSTALL_PATH back; the adapter reported the install but it was not verified"
      fi
    fi
  elif [[ -n "$INSTALL_PATH" ]]; then
    # The refusal carries the command itself. It used to send the caller to "the
    # printed watcher command", which this branch exits before ever printing.
    fail "refusing --install: turn_boundary_rewake is '$support' on $framework, so an installed
  hook entry would never fire — this harness has no turn-boundary continuation to fire it, and
  the entry would sit in $INSTALL_PATH looking armed. Nothing was written.
  Run the watcher from the seat instead, re-running it after each wake:
    $command"
  fi

  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg fw "$framework" \
      --arg support "$support" \
      --arg command "$command" \
      --arg installed "${INSTALL_PATH:-}" \
      --arg displaced "$DISPLACED" \
      --argjson entry "${entry:-null}" \
      --argjson window "$WINDOW" \
      --argjson hook_timeout "$HOOK_TIMEOUT" \
      --argjson armed "$([[ -n "$INSTALL_PATH" ]] && echo true || echo false)" \
      '{framework: $fw, turn_boundary_rewake: $support, watcher_command: $command,
        window_seconds: $window, hook_timeout_seconds: $hook_timeout, armed: $armed,
        hook_entry: $entry, installed_into: (if $installed == "" then null else $installed end),
        displaced: (if $displaced == "" then null else $displaced end)}')"
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
        echo "[coordinate] installed into $INSTALL_PATH and read back — the next turn boundary arms the first window."
        echo "[coordinate] the entry carries its own scope, so 'lore arc close' can find this watcher."
        if [[ -n "$DISPLACED" ]]; then
          while IFS= read -r displaced_line; do
            [[ -n "$displaced_line" ]] || continue
            echo "[coordinate] $displaced_line"
          done <<< "$DISPLACED"
          echo "[coordinate] that seat is now unwatched. Re-arm it into a settings file of its own if it is still working a board."
        fi
      else
        echo "[coordinate] --render: NOTHING IS ARMED. No settings file was written and no window will open."
        echo "             Add the entry above to the settings file whose scope you want armed, and own"
        echo "             removing it by hand — 'lore arc close' only reads the settings file lore itself"
        echo "             installs into."
        echo "             To arm it here instead: re-run with --install <settings.json>. Every session"
        echo "             that reads that file gets this watcher, so pick the file deliberately."
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
  local framework support adapter before after removed

  [[ -n "$SETTINGS_PATH" ]] || fail "disarming requires --settings <path>: the settings file decides which sessions are disarmed, and lore will not guess a scope that could switch off a board somebody else is still working"

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
#
# This window always asks for --wake-shaped, so the watcher has already collapsed
# 0 and 2 into 2 by the time the status reaches here: what came back says the
# window is re-armable, not what it found. Anything that needs to tell a match
# from a quiet timeout reads the wake body, never the status. See
# wake_disposition.

WATCH_PID=""

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
# duplicate-insensitive, so one scope written two ways takes one lock and writes
# one log. Keyed on the declared scope rather than the arc-expanded one — the
# firings this guards against all carry the identical command line the hook
# entry was armed with. With no scope, and when the key cannot be computed, the
# suffix is empty and every firing shares one pair of sidecars.
scope_suffix() {
  local arc tokens="" key
  for arc in ${ARCS+"${ARCS[@]}"}; do tokens+="arc:$arc"$'\n'; done
  [[ -n "$tokens" ]] || return 0
  key="$(printf '%s' "$tokens" | LC_ALL=C sort -u \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')" || return 0
  printf '%s' "-$key"
}

scope_lock_file() {
  printf '%s' "$KNOWLEDGE_DIR/_coordination/arm-window$(scope_suffix).lock"
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

# --- The per-scope window log -------------------------------------------------
#
# What a window did, in one line, at the same per-scope key as the lock. This
# script is the file's only writer: every disposition it records — a firing
# refused as foreign, a firing that lost the lock — exists only here, in the
# wrapper, and is gone by the time anything else could observe it. Everything
# else that wants to know what a window did reads this file.
#
# A refused firing and a healthy one are otherwise identical from outside: both
# exit 0 with nothing on any stream, and the harness reports no output and no
# errors for either. Reading this file is how a seat that has gone quiet finds
# out whether its windows were opening at all.
#
# Nothing here may cost a window. A log that cannot be written or trimmed
# degrades to a note on stderr.
WINDOW_LOG_MAX_BYTES=65536
WINDOW_LOG_KEEP_BYTES=32768

scope_window_log() {
  printf '%s' "$KNOWLEDGE_DIR/_coordination/arm-window$(scope_suffix).log"
}

trim_window_log() {
  local log_file="$1" size tmp
  size="$(wc -c < "$log_file" 2>/dev/null)" || return 0
  size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  [[ "$size" -gt "$WINDOW_LOG_MAX_BYTES" ]] || return 0
  tmp="$log_file.trim.$$"
  # The first line of a byte-bounded tail is usually a fragment of a line.
  if tail -c "$WINDOW_LOG_KEEP_BYTES" "$log_file" 2>/dev/null | tail -n +2 > "$tmp" 2>/dev/null \
    && mv "$tmp" "$log_file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  echo "[coordinate] could not trim $log_file; it keeps growing until it can be" >&2
}

record_window_disposition() {
  local disposition="$1" note="${2:-}" log_file line
  log_file="$(scope_window_log)"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  line="$(timestamp_iso) pid=$$ ppid=${PPID:-unknown} owner=${OWNER_PID:-none} disposition=$disposition"
  [[ -n "$note" ]] && line+=" note=$note"
  if ! printf '%s\n' "$line" >> "$log_file" 2>/dev/null; then
    echo "[coordinate] could not append this window's disposition ($disposition) to $log_file" >&2
    return 0
  fi
  trim_window_log "$log_file"
}

# --- Whose turn boundary is this? ---------------------------------------------
#
# Bounded so an unexpected process table — a cycle, a pid that reports itself as
# its own parent — cannot spin the walk instead of answering.
ANCESTRY_WALK_LIMIT=64

parent_pid_of() {
  local pid="$1" parent
  parent="$(ps -o ppid= -p "$pid" 2>/dev/null)" || return 1
  parent="${parent//[[:space:]]/}"
  [[ "$parent" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$parent"
}

# Where this firing sits relative to the seat the entry names:
#   owned       the owner handle is this process or one of its ancestors
#   foreign     the owner is alive elsewhere, so this is another seat's turn
#               boundary running an entry it inherited from a shared settings file
#   owner-gone  no owner process to descend from; the window's own owner check
#               answers that case, and answers it with a report
#   unreadable  the process table would not say
classify_firing() {
  local pid=$$ steps=0 parent
  [[ -n "$OWNER_PID" ]] || { printf owned; return 0; }
  command -v ps >/dev/null 2>&1 || { printf unreadable; return 0; }
  while [[ "$pid" -gt 1 && $steps -lt $ANCESTRY_WALK_LIMIT ]]; do
    [[ "$pid" == "$OWNER_PID" ]] && { printf owned; return 0; }
    parent="$(parent_pid_of "$pid")" || { printf unreadable; return 0; }
    pid="$parent"
    steps=$((steps + 1))
  done
  [[ "$pid" == "$OWNER_PID" ]] && { printf owned; return 0; }
  if [[ "$(probe_pid "$OWNER_PID")" == "alive" ]]; then
    printf foreign
  else
    printf owner-gone
  fi
}

on_sigterm() {
  trap - TERM
  record_window_disposition killed
  [[ -n "$WATCH_PID" ]] && kill -TERM "$WATCH_PID" 2>/dev/null || true
  exit 143
}

# What this window actually found, read off the wake body rather than off the
# watcher's exit code.
#
# The code cannot answer it. Under --wake-shaped the watcher folds every
# re-armable terminal onto exit 2 on purpose — seat-owned windows invoke the
# watch verb directly and act on that one code — so the status this wrapper waits
# on says "re-armable", never "actionable". Keying the disposition off it logged
# every wake as quiet, including the ones carrying a closed row, which is exactly
# the distinction the window log exists to record.
#
# The body says which. Its payload carries the matched row and the pending
# requests, so the wake that woke somebody and the wake that found nothing are
# told apart by what was delivered:
#
#   actionable  a matched row, or unclaimed spawn requests — something to act on
#   quiet       neither: a window that ended with nothing to report
#   unreadable  no payload to read, so neither claim can be made honestly
#
# Returns the disposition on stdout.
wake_disposition() {
  local body="$1" line payload="" verdict
  # The payload is the last JSON object on the body; the human line comes first,
  # and anything the watcher's dependencies wrote to stderr is not a payload.
  while IFS= read -r line; do
    case "$line" in
      '{'*) ;;
      *) continue ;;
    esac
    printf '%s' "$line" | jq -e 'type == "object" and has("outcome")' >/dev/null 2>&1 \
      || continue
    payload="$line"
  done <<< "$body"

  [[ -n "$payload" ]] || { printf unreadable; return 0; }
  verdict="$(printf '%s' "$payload" | jq -r \
    'if (.matched != null) or (((.pending // []) | length) > 0)
     then "actionable" else "quiet" end' 2>/dev/null)" || verdict=""
  case "$verdict" in
    actionable|quiet) printf '%s' "$verdict" ;;
    *) printf unreadable ;;
  esac
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
  # Whose firing this is, before the lock: a foreign session contesting a lock it
  # has no business holding is how a seat loses its own window, and the loser of
  # that contest exits 0 in silence — no wake, and so no next window either.
  case "$(classify_firing)" in
    foreign)
      record_window_disposition foreign
      exit 0
      ;;
    unreadable)
      echo "[coordinate] could not read this process's ancestry to check it against owner $OWNER_PID; opening the window anyway" >&2
      ;;
  esac

  # Before anything else, and before the TERM trap: a losing instance should
  # cost the seat one fork, not a grace sleep.
  if ! acquire_window_lock "$(scope_lock_file)"; then
    record_window_disposition lock-held
    exit 0
  fi

  trap on_sigterm TERM

  if ! owner_may_continue; then
    sleep "$OWNER_GONE_GRACE_SECONDS"
    if ! owner_may_continue; then
      record_window_disposition owner-gone before-opening
      emit_owner_gone
    fi
  fi

  record_window_disposition opened

  local err_file watch_status=0
  err_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$err_file'" EXIT

  # The watcher does not inherit the lock descriptor. The lock names the wrapper
  # that can still deliver a wake, so it must die with the wrapper: an orphaned
  # watcher holding it would block every re-arm for a whole window while having
  # no channel left to wake anyone through.
  "$WATCH_SH" --wake-shaped --timeout "$WINDOW" \
    ${KDIR_OVERRIDE:+--kdir "$KDIR_OVERRIDE"} \
    ${SCOPE_ARGS+"${SCOPE_ARGS[@]}"} \
    >/dev/null 2>"$err_file" 9>&- &
  WATCH_PID=$!

  # The watcher owns its own deadline and exits at it, every time, with a wake.
  # --hook-timeout > --window is validated at arm time, so the harness kill is a
  # backstop the arithmetic already excludes.
  wait "$WATCH_PID" || watch_status=$?
  WATCH_PID=""

  # Only stderr. Under --wake-shaped the watcher writes its wake body to both
  # streams, and stderr's copy is the superset — it carries the matched row and
  # the next cursor that stdout reports separately. Concatenating the two sent
  # the seat every wake twice.
  local body
  body="$(cat "$err_file")"

  # A window that ends while the seat is gone has nobody to wake; every other
  # ending does, including the ones that found nothing.
  if ! owner_may_continue; then
    sleep "$OWNER_GONE_GRACE_SECONDS"
    if ! owner_may_continue; then
      record_window_disposition owner-gone after-window
      emit_owner_gone
    fi
  fi

  local disposition
  case "$watch_status" in
    0|2)
      # One arm for both: the watcher normalizes 0 and 2 to 2 before it exits, so
      # the two arms this used to have were one live arm and one unreachable one.
      disposition="$(wake_disposition "$body")"
      record_window_disposition "wake-$disposition"
      emit_wake "$disposition" "$body"
      ;;
    3)
      record_window_disposition owner-gone reported-by-watcher
      emit_owner_gone
      ;;
    *)
      record_window_disposition watcher-failed "exit-$watch_status"
      sleep "$ERROR_WAKE_BACKOFF_SECONDS"
      emit_wake "watcher-failed (exit $watch_status)" "$body"
      ;;
  esac
}

case "$MODE" in
  arm) check_arm_owner_pid; cmd_arm ;;
  run) cmd_run ;;
  disarm) cmd_disarm ;;
esac
