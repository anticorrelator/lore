#!/usr/bin/env bash
# coordinate-watch.sh — Sleep until something you are watching needs you, then
# wake with enough state to act on it.
#
# This is the board-scoped counterpart to `lore session wait`. Wait watches one
# session, so N live sessions cost N watchers, N hand-composed stop sets, and N
# cursors to carry between wakes. Watch needs no arguments at all: it follows the
# session journal from a cursor it manages itself and returns on the first row a
# coordinator can act on. Re-arming after a wake is the same call.
#
# A wake is not just "something happened". It carries the matched row, what the
# watcher concluded about it, which authority it consulted to conclude that, and
# so the caller can decide what to do without a round of manual re-reading.
#
# A wake does not have to start with a row. A machine that suspends with a window
# open freezes that window silently, and a frozen window looks exactly like a
# healthy quiet board. A clock comparison covers that, ending the window when this
# machine has plainly been asleep. See "Suspension skew".
#
# Usage:
#   lore coordinate watch [--arc <slug>]...
#                         [--until <events>] [--since <cursor>]
#                         [--timeout <sec>] [--pending-stale <sec>]
#                         [--peek-timeout <sec>]
#                         [--spawn-gap <sec>]
#                         [--owner-pid <pid>] [--owner-tmux <name>]
#                         [--tmux-server <name>]
#                         [--wake-shaped] [--kdir <path>] [--json]
#
# Scoping:
#   --arc <slug>      Wake only on rows belonging to a work item the arc declares
#                     in its `members[]`. Repeatable; with no --arc the watch
#                     stays board-wide, which is what a seat owning the whole
#                     board wants. A row belongs when its `.slug` matches a
#                     member or its `links.work_item` does — worker sessions run
#                     under a derived `<work-item>--w<n>` slug, so a slug-only
#                     test would drop every worker row. Membership is declared,
#                     not inferred: items merely carrying the arc's project label
#                     are not included, so an arc whose members[] is empty
#                     contributes nothing. A scope that expands to no work items
#                     at all is refused rather than falling back to the whole
#                     board.
#
#                     Arc is the only scoping key. Work is grouped into arcs and
#                     watched by arc; a second key naming individual items would
#                     be a second way to say the same thing.
#
#   Actionable rows carrying neither identity key still wake a scoped watch, as
#   labeled "unattributed" advisories. Such a row cannot be scoped in or out on
#   the evidence it carries, and dropping it would turn a real event into
#   silence.
#
#   Each distinct scope keeps its own cursor, so two seats watching different
#   scopes on one store do not overwrite each other's position.
#
# Options:
#   --until <events>  Comma-separated event names to wake on. Default is the
#                     actionable set: closed, close_failed, orphaned,
#                     worktree_quarantined, terminus_reached, needs_input,
#                     modal_blocked, restore_refused — every edge where a session
#                     ended or parked waiting on somebody. Names are validated
#                     against the journal's event vocabulary up front, so a typo
#                     is a usage error rather than a watch that never returns.
#   --since <cursor>  Start from this cursor instead of the persisted one. An
#                     explicit value wins over the cursor file. Treat it as
#                     opaque: pass back a cursor this verb, `lore session wait`,
#                     or `lore session events` reported, never one you computed.
#   --timeout <sec>   How long to sleep before giving up (default: 600). Exit 2.
#                     Run this in the background rather than in the foreground of
#                     a harness turn — a foreground command is killed long before
#                     ten minutes are up, and a killed watcher reads as a hang.
#                     The default is the cadence a seat can count on: a window
#                     ends at least every ten minutes, and a board with nothing
#                     to report ends it with a quiet wake rather than silence.
#   --pending-stale <sec>
#                     Also wake when a spawn request has been sitting in the
#                     pending queue this long without being claimed (default:
#                     300; 0 disables). A request nobody claims never reaches the
#                     journal, so no journal watcher can see it — a request
#                     pinned to an instance that died between enqueue and claim
#                     parks silently and the board looks merely quiet.
#   --peek-timeout <sec>
#                     Budget for the screen read that confirms a parked session
#                     is still parked (default: 10; 0 skips the read). See
#                     "Classification" below.
#   --spawn-gap <sec> How young a session may be before a screen-confirmed park is
#                     demoted to a `spawn-gap` advisory (default: 90; 0 disables
#                     the age gate). See "Classification".
#   --owner-pid <pid> / --owner-tmux <name> / --tmux-server <name>
#                     Liveness handles for the seat this watcher reports to; the
#                     same two handles a coordination worktree lease records
#                     (--tmux-server defaults to lore-tui). See "Owner liveness".
#   --wake-shaped     Exit 2 at every terminal that could be re-armed from, and
#                     write the wake body to stderr. See "Exit codes".
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit one result object instead of plain rows (see below).
#
# Classification:
#   Some events state their own outcome — a `closed` row is the whole story. The
#   park-shaped ones (needs_input, modal_blocked) do not: they say a session
#   stopped, not whether it is still stopped now. For those the watcher confirms
#   before waking, and every wake names the authority it used:
#
#     hook-row          The row itself carried the state, from a lifecycle
#                       emitter. This wins outright: when the row is
#                       authoritative the screen is not consulted for that
#                       session at all. Two authorities that can disagree are
#                       where disagreement bugs live, so one is suppressed rather
#                       than blended with the other. `modal_blocked` is the one
#                       exception, and it is not a blend — the screen takes the
#                       classification over entirely. See "Transient modals".
#     screen-signature  The row was park-shaped and carried no state of its own,
#                       so the watcher peeked the session and matched the result
#                       against the strict signature set (see lib.sh's
#                       session_park_classify). The signature set is versioned and
#                       the version travels in the wake, so a matcher-contract
#                       change is visible instead of silently reclassifying parks.
#     owner-handle      The wake came from the owner-liveness check.
#     none              Nothing to classify — a quiet timeout, an unclaimed spawn
#                       request, or the clock comparison, none of which read a
#                       session's state at all.
#
#   A screen signature that fires is then age-gated. Between a pane being spawned
#   and its first prompt being submitted, a session renders a genuinely ready
#   composer — the strict signature is truthful about the screen and wrong about
#   the session, because "has not started" and "stopped, waiting on somebody" look
#   the same there. So before a screen-confirmed park is promoted to `confirmed`,
#   the row is joined against its own session's `spawned`/`claimed` row in the
#   journal; a session younger than --spawn-gap is demoted to an advisory labeled
#   `spawn-gap`. The age gate applies only to the screen-signature authority: a
#   hook row carrying emitter state is a positive claim about why the session
#   parked, not an inference from screen shape, so the same ambiguity does not
#   reach it. Every wake reports what the gate did in
#   `classification.spawn_gap`, including when it left the confirmation standing.
#
# Transient modals:
#   A `modal_blocked` row is the one emitter claim that routinely stops being true
#   before anyone can act on it. Some harnesses raise a modal and clear it
#   themselves within a second — under bypass-permissions the seat never had a
#   decision to make — so the row is true when written and stale when read, and
#   promoting it on the row alone costs the seat a full turn per flash.
#
#   So on a `modal_blocked` row the screen decides the tier, whether or not the
#   row carries emitter state. A modal on the screen confirms; a screen showing
#   anything else demotes to an advisory labeled `modal-not-on-screen`, which ages
#   and escalates like any other — a modal that keeps re-presenting and never
#   survives a peek is a session in trouble, and the demotion delays that wake by
#   a tier rather than silencing it. Nothing debounces on the emitter side: the
#   row lands the moment the modal appears, and only the wake tier softens.
#
#   Absence of evidence never demotes. A peek that cannot answer — no instance
#   hosts the session, the round trip fails, `--peek-timeout 0` — leaves the row's
#   claim standing at `confirmed` on `hook-row` authority. Every wake on a modal
#   row reports what the gate did in `classification.modal_gate`, including when
#   it left the confirmation standing. Other park events are untouched: their
#   emitter state is a claim about a condition that does not clear itself.
#
#   Strictness governs the wake's tier, never whether it wakes. A park nothing
#   confirmed wakes as a labeled `advisory` naming why no signature fired. The
#   seat is asleep and the watcher is its only observer, so there is no state in
#   which staying quiet is the safe answer.
#
# Suspension skew:
#   A laptop that sleeps with a window open freezes that window silently. Wall
#   time keeps moving across a suspension and monotonic time does not, so the
#   difference between how much of each elapsed since the window opened is the
#   suspension and nothing else, to within scheduling jitter of well under a
#   second.
#
#   The quiet wake reports that difference as `clock_skew.skew_seconds` and
#   leaves the reading to the seat: a window whose clocks disagree by minutes
#   computed every age it holds against a stopped clock, and the board is worth
#   re-joining before quiet is believed.
#
# Owner liveness:
#   With a handle passed, each poll checks whether the seat this watcher reports
#   to is still there. Not-alive is a hint rather than a verdict — registry and
#   process removal run ahead of the final journal append — so the watcher waits
#   out a short grace, reads the journal exactly once more, and only then exits 3
#   without a cursor rewind. Exit 3 is the one terminal that is not re-armable.
#
#   The check is stop-biased: only a positive proof of life counts. An answer
#   that cannot be obtained (no permission to signal the pid, no tmux binary)
#   reads as not-alive here, the opposite of the seat lease's bias, because a
#   watcher that outlives its seat is a runaway while a lease that reclaims a live
#   seat's checkout destroys work.
#
# The cursor:
#   Persisted at $KNOWLEDGE_DIR/_coordination/watch-cursor-<identity>-<scope>.json
#   as {schema_version, cursor, updated_at}. Identity is canonical store + owner
#   handle + normalized declared arcs; scope is the expanded member-slug set.
#   rewritten on every exit that reached the journal. That is what makes the
#   re-arm argument-free: the next call resumes exactly where this one stopped, so
#   no row is replayed and none is skipped. The first-ever run for a scope has no
#   file and baselines at the journal's current end ("wake on what happens next"),
#   which means it will not replay history the board has already dealt with.
#
#   On a match the cursor is the boundary immediately after the matched row, not
#   the end of the read that found it. One read can carry several actionable
#   rows; only the first is handed to the caller, so persisting the read's end
#   would drop the rest permanently. The no-match exits (advisory, timeout,
#   reader failure) withhold nothing, so they carry the read's end cursor.
#
# Output (plain): the matched event row, then the wake body as {"wake": {...}},
#   then a final {"next_cursor": N} row. A pending-staleness wake emits an
#   advisory row in place of the event row. Timeout emits no event row. Every row
#   is JSON on stdout; tell them apart by shape — has("event"), has("advisory"),
#   has("wake"), has("next_cursor").
#
# Output (--json): one object — the wake body, which is a superset of
#   `session wait`'s matched shape:
#     {schema_version, outcome, tier, authority, signature_version,
#      classification: {state, label, reason, peek, spawn_gap, modal_gate},
#      clock_skew: {wall_elapsed_seconds, monotonic_elapsed_seconds,
#                   skew_seconds} | null,
#      matched, pending,
#      scope: {mode, slugs, arcs, cursor_file}, next_cursor, until}
#   There is no top-level `slug`: session identity lives on the matched row.
#
#   `outcome` is one of: matched, pending_stale, owner_gone, timeout,
#   internal_error.
#
# Exit codes (local to this verb):
#   0  a matching row landed, or a stale pending request was found
#   1  error (bad args, unknown --until event, unknown arc, missing store)
#   2  timed out with nothing to report — the ordinary re-arm branch, not a
#      failure: just call the verb again
#   3  the owner handle stopped proving live and one final journal read found
#      nothing — stop; do not re-arm
#   4  internal error: the reference reader failed on all three attempts
#
#   Under --wake-shaped every re-armable terminal (match, advisory, timeout)
#   exits 2 instead, and the wake body is written to stderr. One exit code for
#   "here is a wake, arm again" is what a harness continuation channel can act on
#   uniformly; 3 and 4 keep their meanings because neither should be re-armed.
#
# This verb only reads the journal. It never appends to it — the journal keeps
# exactly one writer (session-event-append.sh), so every signal this watcher
# originates, including its classifications and the pending-staleness advisory,
# is printed to the caller rather than written where somebody could read it back
# as a lifecycle event.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

UNTIL="${SESSION_ACTIONABLE_EVENTS// /,}"
SINCE=""
SINCE_SET=0
TIMEOUT=600
PENDING_STALE=300
PEEK_TIMEOUT=10
# The spawn-paste gap, measured rather than guessed. Live wakes on 2026-08-03 put
# false confirmations — a ready composer on a session that had not taken its first
# turn — at 11s and 13s past the session's start row, and true parks (a real
# completion message sitting at a real prompt) at ~600s and ~900s. 90s is the
# geometric middle of that separation: ~7x the widest observed spawn gap and ~7x
# under the earliest observed true park, so both ends have an order of magnitude
# to drift into before the gate starts being wrong. It errs generous on purpose —
# a demoted true park still wakes the seat as an advisory, while a promoted spawn
# gap sends the seat to steer a session that is still booting, which is the
# failure this gate exists to stop.
SPAWN_GAP=90
OWNER_PID=""
OWNER_TMUX=""
TMUX_SERVER="lore-tui"
WAKE_SHAPED=0
KDIR_OVERRIDE=""
JSON_MODE=0
CURSOR_SCHEMA_VERSION=1
WAKE_SCHEMA_VERSION=1
OWNER_GONE_GRACE_SECONDS=2

SCOPE_SLUGS=()
SCOPE_ARCS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arc) SCOPE_ARCS+=("${2:-}"); shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; SINCE_SET=1; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --pending-stale) PENDING_STALE="${2:-}"; shift 2 ;;
    --peek-timeout) PEEK_TIMEOUT="${2:-}"; shift 2 ;;
    --spawn-gap) SPAWN_GAP="${2:-}"; shift 2 ;;
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --wake-shaped) WAKE_SHAPED=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    # The header comment above is the help text. This range ends on its last
    # line; a header that grows past it prints truncated, which --help itself
    # cannot notice.
    -h|--help) sed -n '2,235p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-watch.sh [--arc <slug>]... [--until <events>] [--since <cursor>] [--timeout <sec>] [--pending-stale <sec>] [--peek-timeout <sec>] [--spawn-gap <sec>] [--owner-pid <pid>] [--owner-tmux <name>] [--tmux-server <name>] [--wake-shaped] [--kdir <path>] [--json]" >&2
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

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

check_non_negative() {
  local flag="$1" value="$2" tail="${3:-}"
  [[ "$value" =~ ^[0-9]+$ ]] \
    || fail "invalid $flag: '$value' (must be a non-negative integer${tail:+; $tail})"
}

check_non_negative --timeout "$TIMEOUT"
check_non_negative --pending-stale "$PENDING_STALE" "0 disables"
check_non_negative --peek-timeout "$PEEK_TIMEOUT" "0 disables"
check_non_negative --spawn-gap "$SPAWN_GAP" "0 disables the age gate"

if [[ -n "$OWNER_PID" ]] && ! [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --owner-pid: '$OWNER_PID' (must be a positive integer)"
fi
if [[ -n "$OWNER_PID" && -n "$OWNER_TMUX" ]]; then
  fail "watcher identity takes exactly one owner handle: pass --owner-pid or --owner-tmux, not both"
fi
if [[ $SINCE_SET -eq 1 ]]; then
  case "$SINCE" in
    ''|*[!0-9]*) fail "invalid --since: '$SINCE' (must be a non-negative byte offset)" ;;
  esac
fi

# --- Validate --until against the writer's vocabulary; build the until-set ---
[[ -n "${UNTIL// }" ]] || fail "empty --until: pass at least one event name"
UNTIL_TOKENS=()
IFS=',' read -r -a _until_raw <<< "$UNTIL"
for tok in "${_until_raw[@]}"; do
  tok="${tok// }"   # tolerate incidental spaces around the commas
  [[ -n "$tok" ]] || continue
  session_event_in_vocab "$tok" \
    || fail "invalid --until event: '$tok' (not in the session event vocabulary)"
  UNTIL_TOKENS+=("$tok")
done
[[ ${#UNTIL_TOKENS[@]} -gt 0 ]] || fail "empty --until: pass at least one event name"

# --- Resolve store ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # A hook-hosted firing for a removed store is stale identity. It must not
  # create the store, emit a wake, or enter an error/re-arm loop.
  [[ $WAKE_SHAPED -eq 1 ]] && exit 3
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi
KNOWLEDGE_DIR="$(canonical_existing_dir "$KNOWLEDGE_DIR")" \
  || fail "could not canonicalize knowledge store: $KNOWLEDGE_DIR"

if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  NORMALIZED_ARCS=()
  while IFS= read -r arc; do
    [[ -n "$arc" ]] && NORMALIZED_ARCS+=("$arc")
  done < <(printf '%s\n' "${SCOPE_ARCS[@]}" | LC_ALL=C sort -u)
  SCOPE_ARCS=("${NORMALIZED_ARCS[@]}")
fi

EVENTS_SH="$SCRIPT_DIR/session-events.sh"
PEEK_SH="$SCRIPT_DIR/session-peek.sh"
EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"
PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
# The watcher's sidecars sit at the top of _coordination/, deliberately outside
# the journal and outside the worktree manager's registry — every directory under
# there has a sole writer that would not expect a second file appearing in it.
COORD_DIR="$KNOWLEDGE_DIR/_coordination"

# --- Resolve the scope ------------------------------------------------------

SCOPE_REQUESTED=0
if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  SCOPE_REQUESTED=1
fi

for arc in ${SCOPE_ARCS[@]+"${SCOPE_ARCS[@]}"}; do
  [[ -n "$arc" ]] || fail "empty --arc: pass an arc slug"
  ARC_STATUS=0
  ARC_MEMBERS="$(session_arc_member_slugs "$KNOWLEDGE_DIR" "$arc")" || ARC_STATUS=$?
  case "$ARC_STATUS" in
    0) ;;
    1) fail "unknown --arc: '$arc' (no arc record at _work/_arcs/$arc/_meta.json)" ;;
    2) fail "unreadable arc record for --arc '$arc': _work/_arcs/$arc/_meta.json is not a JSON object" ;;
    3) fail "--arc '$arc' is closed, archived, or carries an unknown status; only active arcs can be watched" ;;
    *) fail "could not expand --arc '$arc'" ;;
  esac
  # An arc with no declared members scopes to nothing on its own. Naming it beats
  # a watch that silently never wakes; the arc may simply carry project-labeled
  # items that were never added as members.
  if [[ -z "${ARC_MEMBERS//[[:space:]]/}" ]]; then
    echo "[coordinate] arc '$arc' declares no members; it contributes nothing to this scope" >&2
    continue
  fi
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    SCOPE_SLUGS+=("$member")
  done <<< "$ARC_MEMBERS"
done

# A requested scope that expanded to nothing must not fall through to watching
# the whole board — the caller would get wakes it did not ask for and no sign
# that its scope was dropped. Refuse here, where the message can name the fix.
if [[ $SCOPE_REQUESTED -eq 1 && ${#SCOPE_SLUGS[@]} -eq 0 ]]; then
  fail "the requested scope expands to no work items (every --arc given declares an empty members[]); add members with \`lore arc member\`, or drop --arc to watch the whole board"
fi

SCOPED=0
SCOPE_MODE="board"
SCOPE_SUFFIX="board"
if [[ ${#SCOPE_SLUGS[@]} -gt 0 ]]; then
  SCOPED=1
  SCOPE_MODE="scoped"
  # One scope, one set of sidecars. The key is order-insensitive and
  # duplicate-insensitive so the same scope written two ways resumes one cursor.
  SCOPE_SUFFIX="$(printf '%s\n' "${SCOPE_SLUGS[@]}" | LC_ALL=C sort -u \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')"
fi

if [[ -n "$OWNER_PID" ]]; then
  IDENTITY_OWNER_KIND="pid"; IDENTITY_OWNER_VALUE="$OWNER_PID"
elif [[ -n "$OWNER_TMUX" ]]; then
  IDENTITY_OWNER_KIND="tmux"; IDENTITY_OWNER_VALUE="$OWNER_TMUX"
else
  IDENTITY_OWNER_KIND="none"; IDENTITY_OWNER_VALUE=""
fi
IDENTITY_KEY="$(watcher_identity_hash "$KNOWLEDGE_DIR" "$IDENTITY_OWNER_KIND" \
  "$IDENTITY_OWNER_VALUE" "$TMUX_SERVER" ${SCOPE_ARCS+"${SCOPE_ARCS[@]}"})"
CURSOR_FILE="$COORD_DIR/watch-cursor-$IDENTITY_KEY-$SCOPE_SUFFIX.json"

if [[ $SCOPED -eq 1 ]]; then
  SCOPE_SLUGS_JSON="$(printf '%s\n' "${SCOPE_SLUGS[@]}" | LC_ALL=C sort -u | jq -R . | jq -s -c .)"
else
  SCOPE_SLUGS_JSON='[]'
fi
if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  SCOPE_ARCS_JSON="$(printf '%s\n' "${SCOPE_ARCS[@]}" | jq -R . | jq -s -c .)"
else
  SCOPE_ARCS_JSON='[]'
fi
UNTIL_JSON="$(printf '%s\n' "${UNTIL_TOKENS[@]}" | jq -R . | jq -s -c .)"

# --- Cursor persistence ------------------------------------------------------

read_cursor_file() {
  [[ -f "$CURSOR_FILE" ]] || return 1
  local value
  value="$(jq -r 'if (.cursor | type) == "number" and .cursor >= 0 then .cursor else empty end' \
    "$CURSOR_FILE" 2>/dev/null)" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

# Written through mktemp + rename so a watcher killed mid-write leaves the prior
# cursor intact rather than a truncated file the next run has to guess about.
write_cursor_file() {
  local cursor="$1" tmp
  mkdir -p "$COORD_DIR"
  tmp="$(mktemp "$COORD_DIR/.tmp.watch-cursor.XXXXXX")" || return 0
  if jq -n --argjson v "$CURSOR_SCHEMA_VERSION" --argjson c "$cursor" \
    --arg at "$(timestamp_iso)" \
    '{schema_version: $v, cursor: $c, updated_at: $at}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CURSOR_FILE"
  else
    rm -f "$tmp"
  fi
}

# --- Wake payload and terminals ----------------------------------------------

WAKE_OUTCOME=""
WAKE_TIER="quiet"
WAKE_AUTHORITY="none"
WAKE_STATE="none"
WAKE_LABEL=""
WAKE_REASON="null"          # JSON
WAKE_PEEK="null"            # JSON
WAKE_MATCHED="null"         # JSON
WAKE_PENDING="[]"           # JSON
WAKE_SPAWN_GAP="null"       # JSON
WAKE_MODAL_GATE="null"      # JSON
WAKE_CLOCK_SKEW="null"      # JSON

# emit_wake <cursor> <exit-code> <message>
# The single terminal. Non-zero terminals print their JSON by hand: json_output
# hard-exits 0, which would erase the composed exit code.
emit_wake() {
  local cursor="$1" code="$2" message="$3" payload

  [[ "$cursor" == "null" ]] || write_cursor_file "$cursor"

  payload="$(jq -cn \
    --argjson schema "$WAKE_SCHEMA_VERSION" \
    --arg outcome "$WAKE_OUTCOME" \
    --arg tier "$WAKE_TIER" \
    --arg authority "$WAKE_AUTHORITY" \
    --argjson signature_version "$SESSION_PARK_SIGNATURE_VERSION" \
    --arg state "$WAKE_STATE" \
    --arg label "$WAKE_LABEL" \
    --argjson reason "$WAKE_REASON" \
    --argjson peek "$WAKE_PEEK" \
    --argjson spawn_gap "$WAKE_SPAWN_GAP" \
    --argjson modal_gate "$WAKE_MODAL_GATE" \
    --argjson clock_skew "$WAKE_CLOCK_SKEW" \
    --argjson matched "$WAKE_MATCHED" \
    --argjson pending "$WAKE_PENDING" \
    --arg mode "$SCOPE_MODE" \
    --argjson slugs "$SCOPE_SLUGS_JSON" \
    --argjson arcs "$SCOPE_ARCS_JSON" \
    --arg cursor_file "$(basename "$CURSOR_FILE")" \
    --argjson nc "$cursor" \
    --argjson until "$UNTIL_JSON" \
    '{schema_version: $schema, outcome: $outcome, tier: $tier, authority: $authority,
      signature_version: $signature_version,
      classification: {state: $state, label: $label, reason: $reason,
                       peek: $peek, spawn_gap: $spawn_gap,
                       modal_gate: $modal_gate},
      clock_skew: $clock_skew,
      matched: $matched, pending: $pending,
      scope: {mode: $mode, slugs: $slugs, arcs: $arcs, cursor_file: $cursor_file},
      next_cursor: $nc, until: $until}')"

  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$payload"
  else
    [[ "$WAKE_MATCHED" == "null" ]] || printf '%s\n' "$WAKE_MATCHED"
    if [[ "$WAKE_OUTCOME" == "pending_stale" ]]; then
      jq -cn --argjson pending "$WAKE_PENDING" '{advisory: "pending_stale", requests: $pending}'
    fi
    jq -cn --argjson wake "$payload" '{wake: $wake}'
    [[ "$cursor" == "null" ]] || jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi

  echo "$message" >&2
  if [[ $WAKE_SHAPED -eq 1 ]]; then
    printf '%s\n' "$payload" >&2
    # Every re-armable terminal reports the same way, so a continuation channel
    # can act on one code. 3 and 4 are not re-armable and keep their meanings.
    case "$code" in
      0|2) code=2 ;;
    esac
  fi
  exit "$code"
}

emit_internal_error() {
  local cursor="$1"
  WAKE_OUTCOME="internal_error"
  WAKE_TIER="quiet"
  WAKE_AUTHORITY="none"
  WAKE_STATE="reader_failed"
  WAKE_LABEL="session-events-failed-after-3-attempts"
  emit_wake "$cursor" 4 \
    "[coordinate] internal error: session-events failed after 3 attempts; fix the reader dependency and retry"
}

# --- Readers -----------------------------------------------------------------

# First row in the until-set that the scope admits, paired with the cursor the
# reader assigned to that row's end.
#
# The pairing is the point: one read can contain several actionable rows, and a
# match that reported the batch's end cursor would persist a position past the
# rows it never handed over — they would be skipped forever, since the next call
# resumes from that cursor. The reader owns each row's byte boundary in
# `.records`, the same boundaries `session wait` follows in follow mode; this verb
# applies the until-set and the scope predicate. Scoping raises the stakes on that
# discipline: the more rows a read withholds, the more a batch-end cursor loses.
first_match_record() {
  printf '%s' "$1" | jq -c \
    --argjson until "$UNTIL_JSON" \
    --argjson slugs "$SCOPE_SLUGS_JSON" \
    --argjson scoped "$SCOPED" \
    "$SESSION_SCOPE_JQ_PREDICATE"'
    first(
      .records[]
      | select(.event.event as $e | $until | index($e))
      | (.event | scope_state($scoped; $slugs)) as $scope
      | select($scope.matched)
      | . + {scope: $scope}
    )' 2>/dev/null || true
}

# Pending spawn requests older than the staleness bound, newest-first age order.
# Age comes from requested_at (the durable enqueue time) rather than file mtime,
# because a claiming instance rewrites the row on each retry and mtime would
# reset the clock on exactly the request that is stuck. mtime is the fallback for
# a row that predates the field or carries an unparseable value.
stale_pending() {
  python3 - "$PENDING_DIR" "$PENDING_STALE" <<'PYEOF'
import json, os, sys, time
from datetime import datetime, timezone

pending_dir, threshold = sys.argv[1], float(sys.argv[2])
now = time.time()
rows = []
if os.path.isdir(pending_dir):
    for name in sorted(os.listdir(pending_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(pending_dir, name)
        try:
            mtime = os.path.getmtime(path)
            with open(path, encoding="utf-8") as handle:
                row = json.load(handle)
        except (OSError, ValueError):
            continue
        stamp, source = None, "mtime"
        raw = row.get("requested_at")
        if isinstance(raw, str) and raw:
            try:
                text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
                parsed = datetime.fromisoformat(text)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                stamp, source = parsed.timestamp(), "requested_at"
            except ValueError:
                stamp = None
        if stamp is None:
            stamp = mtime
        age = int(now - stamp)
        if age < threshold:
            continue
        rows.append({
            "request_id": row.get("request_id") or os.path.splitext(name)[0],
            "slug": row.get("slug"),
            "target_instance": row.get("target_instance"),
            "age_seconds": age,
            "age_source": source,
        })
rows.sort(key=lambda r: r["age_seconds"], reverse=True)
print(json.dumps(rows, separators=(",", ":")))
PYEOF
}

# --- Classification ----------------------------------------------------------

park_shaped() {
  local event="$1" known
  for known in $SESSION_PARK_SHAPED_EVENTS; do
    [[ "$event" == "$known" ]] && return 0
  done
  return 1
}

# spawn_gap_record <signature> <age-json> <resolution>
# Compose the wake's `classification.spawn_gap` object. It is filled on every
# screen-confirmed park, including the ones the gate leaves standing: a seat that
# can see the gate ran and what it found can tell a correct confirmation from one
# nobody checked.
spawn_gap_record() {
  jq -cn --argjson threshold "$SPAWN_GAP" --arg signature "$1" \
    --argjson age "$2" --arg resolution "$3" \
    '{threshold_seconds: $threshold, age_seconds: $age,
      signature: $signature, resolution: $resolution}'
}

# spawn_gap_demotes <slug> <row-ts> <signature-label>
# Fill WAKE_SPAWN_GAP with what the age gate concluded, and return 0 when the
# screen's confirmation belongs at advisory tier instead of `confirmed`.
#
# Absence of evidence never demotes. A row with no timestamp to measure from and
# a reader that would not answer both leave the confirmation standing: the gate
# corrects one specific, observed misreading, and turning it into a general
# distrust of confirmations would cost the tier its meaning.
spawn_gap_demotes() {
  local slug="$1" row_ts="$2" signature="$3" age status=0

  if [[ "$SPAWN_GAP" -eq 0 ]]; then
    WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" null "disabled")"
    return 1
  fi
  if [[ -z "$row_ts" ]]; then
    WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" null "row-has-no-timestamp")"
    return 1
  fi

  age="$(session_events_start_age "$EVENTS_SH" "$KNOWLEDGE_DIR" "$slug" "$row_ts" "$SPAWN_GAP")" \
    || status=$?
  case "$status" in
    0) ;;
    # No start row inside the window is itself the answer: the session began
    # before the window opened, so it is past the gap by construction.
    1) WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" null "no-start-row-in-window")"
       return 1 ;;
    *) WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" null "start-row-unreadable")"
       return 1 ;;
  esac

  if [[ "$age" -ge "$SPAWN_GAP" ]]; then
    WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" "$age" "older-than-threshold")"
    return 1
  fi
  WAKE_SPAWN_GAP="$(spawn_gap_record "$signature" "$age" "demoted")"
  return 0
}

# What the last peek_session call read off the screen, as the response reported
# them: either may be empty when the response omitted the field.
PEEK_READY=""
PEEK_BLOCKED=""

# peek_session <slug>
# Ask the owning instance's readiness gate about <slug>, fill WAKE_PEEK with what
# came back, and leave the two fields a classifier needs in PEEK_READY and
# PEEK_BLOCKED.
#
# Returns non-zero when the peek did not answer at all; WAKE_PEEK then carries the
# error and the two fields are empty. What an unanswered screen means for the tier
# is the caller's to decide — it is not the same answer on every path.
#
# The results travel in globals rather than on stdout because WAKE_PEEK has to
# survive the call: a command substitution would run this in a subshell and the
# peek evidence would never reach the wake body.
peek_session() {
  local slug="$1" out status=0

  PEEK_READY=""
  PEEK_BLOCKED=""
  out="$(bash "$PEEK_SH" "$slug" --json --timeout "$PEEK_TIMEOUT" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)" \
    || status=$?
  if [[ $status -ne 0 ]]; then
    WAKE_PEEK="$(jq -n --arg e "$(printf '%s' "$out" | jq -r '.error // "peek did not answer"' 2>/dev/null || echo 'peek did not answer')" \
      '{consulted: true, ready: null, blocked_reason: null, error: $e}')"
    return 1
  fi

  PEEK_READY="$(printf '%s' "$out" | jq -r 'if (.ready | type) == "boolean" then (.ready | tostring) else "" end' 2>/dev/null || echo "")"
  PEEK_BLOCKED="$(printf '%s' "$out" | jq -r '.blocked_reason // ""' 2>/dev/null || echo "")"
  WAKE_PEEK="$(jq -n --arg r "$PEEK_READY" --arg b "$PEEK_BLOCKED" \
    '{consulted: true,
      ready: (if $r == "" then null else ($r == "true") end),
      blocked_reason: (if $b == "" then null else $b end),
      error: null}')"
}

# modal_gate_record <resolution> <screen-reason-json> <signature>
# Compose the wake's `classification.modal_gate`. It is filled on every
# `modal_blocked` row the gate reaches, including the ones it leaves confirmed: a
# seat that can see the gate ran and what the screen held can tell a modal still
# waiting from one nobody checked.
modal_gate_record() {
  jq -cn --arg resolution "$1" --argjson screen_reason "$2" --arg signature "$3" \
    '{resolution: $resolution, screen_reason: $screen_reason,
      signature: (if $signature == "" then null else $signature end)}'
}

# modal_gate <event> <slug>
# Decide, for a `modal_blocked` row, whether a modal is still on the screen.
#
# Exit: 0 the screen holds no modal — the tier belongs at advisory;
#       1 the modal is on the screen — confirm it, on the screen's authority;
#       2 nothing could answer, or the row is not a modal row at all — whatever
#         the caller already concluded stands.
#
# Absence of evidence never demotes, which is why 1 and 2 are distinct: 1 is the
# screen upholding the row, 2 is nobody having looked. The gate corrects one
# specific, observed misreading — a modal the harness cleared itself before anyone
# read the row — and turning it into a general distrust of emitter state would
# cost `confirmed` its meaning.
modal_gate() {
  local event="$1" slug="$2" verdict label reason_json

  [[ "$event" == "modal_blocked" ]] || return 2
  if [[ "$PEEK_TIMEOUT" -eq 0 ]]; then
    WAKE_MODAL_GATE="$(modal_gate_record "screen-classification-disabled" null "")"
    return 2
  fi
  if [[ -z "$slug" ]]; then
    WAKE_MODAL_GATE="$(modal_gate_record "row-has-no-slug-to-peek" null "")"
    return 2
  fi
  if ! peek_session "$slug"; then
    WAKE_MODAL_GATE="$(modal_gate_record "peek-unavailable" null "")"
    return 2
  fi

  IFS=$'\t' read -r verdict label <<< "$(session_park_classify modal_blocked "$PEEK_READY" "$PEEK_BLOCKED")"
  reason_json="$(jq -n --arg b "$PEEK_BLOCKED" 'if $b == "" then null else $b end')"
  if [[ "$verdict" == "confirmed" ]]; then
    WAKE_MODAL_GATE="$(modal_gate_record "modal-on-screen" "$reason_json" "$label")"
    return 1
  fi
  WAKE_MODAL_GATE="$(modal_gate_record "demoted" "$reason_json" "$label")"
  return 0
}

# classify_match <row-json> <unattributed>
# Fill the WAKE_* classification fields for one matched journal row.
classify_match() {
  local row="$1" unattributed="$2" event slug row_ts row_reason gate verdict label

  event="$(printf '%s' "$row" | jq -r '.event')"
  slug="$(printf '%s' "$row" | jq -r '.slug // ""')"
  row_ts="$(printf '%s' "$row" | jq -r '.ts // ""')"
  row_reason="$(printf '%s' "$row" | jq -r '.reason // ""')"

  if [[ "$unattributed" == "true" ]]; then
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="unattributed_row"
    WAKE_LABEL="row-carries-neither-slug-nor-work-item"
    WAKE_REASON="$(jq -n --arg r "$row_reason" 'if $r == "" then null else $r end')"
    WAKE_TIER="advisory"
    return 0
  fi

  if ! park_shaped "$event"; then
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="row_authoritative"
    WAKE_LABEL="event-states-its-own-outcome"
    WAKE_REASON="$(jq -n --arg r "$row_reason" 'if $r == "" then null else $r end')"
    return 0
  fi

  # An emitter that recorded why the session parked is the authority for that
  # session; the screen is not consulted alongside it. Suppressed, not blended —
  # two authorities that can disagree produce wakes nobody can act on.
  #
  # The exception is a modal, and it is a handover rather than a blend: a modal
  # the harness clears itself outlives the row that reported it, so the screen
  # takes the classification over entirely and the row keeps only its reason.
  if [[ -n "$row_reason" ]]; then
    WAKE_REASON="$(jq -n --arg r "$row_reason" '$r')"
    gate=0
    modal_gate "$event" "$slug" || gate=$?
    case "$gate" in
      0)
        WAKE_AUTHORITY="screen-signature"
        WAKE_STATE="park_unconfirmed"
        WAKE_LABEL="modal-not-on-screen"
        WAKE_TIER="advisory"
        return 0
        ;;
      1)
        WAKE_TIER="confirmed"
        WAKE_AUTHORITY="screen-signature"
        WAKE_STATE="confirmed_park"
        WAKE_LABEL="modal-signature"
        return 0
        ;;
    esac
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="confirmed_park"
    WAKE_LABEL="row-carries-emitter-state"
    return 0
  fi

  if [[ "$PEEK_TIMEOUT" -eq 0 || -z "$slug" ]]; then
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="park_unconfirmed"
    if [[ -z "$slug" ]]; then
      WAKE_LABEL="row-has-no-slug-to-peek"
    else
      WAKE_LABEL="screen-classification-disabled"
    fi
    WAKE_TIER="advisory"
    return 0
  fi

  WAKE_AUTHORITY="screen-signature"
  WAKE_STATE="park_unconfirmed"
  if ! peek_session "$slug"; then
    WAKE_LABEL="peek-unavailable"
    WAKE_TIER="advisory"
    return 0
  fi

  IFS=$'\t' read -r verdict label <<< "$(session_park_classify "$event" "$PEEK_READY" "$PEEK_BLOCKED")"
  WAKE_LABEL="$label"
  if [[ "$verdict" == "confirmed" ]]; then
    # The screen agrees the session is parked. Whether that means "stopped and
    # waiting" or only "has not started yet" is what the age gate settles — the
    # two are indistinguishable on the screen alone.
    if spawn_gap_demotes "$slug" "$row_ts" "$label"; then
      WAKE_LABEL="spawn-gap"
      WAKE_TIER="advisory"
      return 0
    fi
    WAKE_TIER="confirmed"
    WAKE_STATE="confirmed_park"
    return 0
  fi
  WAKE_TIER="advisory"
}

# clock_pair — "<wall><TAB><monotonic>", the two clocks read together.
# Wall time advances across a system suspension and monotonic time does not, so a
# pair taken now and a pair taken later bound how long this machine was asleep.
clock_pair() {
  python3 -c 'import time; print("%.3f\t%.3f" % (time.time(), time.monotonic()))'
}

# clock_elapsed <wall-baseline> <monotonic-baseline>
# "<wall_elapsed><TAB><monotonic_elapsed><TAB><skew>", whole seconds.
clock_elapsed() {
  python3 -c '
import sys, time

w0, m0 = float(sys.argv[1]), float(sys.argv[2])
wall = time.time() - w0
mono = time.monotonic() - m0
print("%d\t%d\t%d" % (int(wall), int(mono), int(wall - mono)))
' "$1" "$2"
}

# --- Baseline: explicit --since, else the persisted cursor, else journal end ---
if [[ $SINCE_SET -eq 1 ]]; then
  CURSOR="$SINCE"
elif CURSOR="$(read_cursor_file)"; then
  :
else
  # First-ever run for this scope: start at the end so the very first watch does
  # not replay a journal the board has already worked through.
  CURSOR="$(session_events_cursor "$EVENTS_SH" "$KNOWLEDGE_DIR")" || emit_internal_error null
fi

# A cursor is a row boundary inside this journal, and the reader refuses both
# ways of missing it. Refuse them here first: the reader's refusal reaches the
# loop as a read that failed, which retries twice more and exits as an internal
# error telling the seat to fix a dependency that is working correctly. The
# baseline is set once, so reading the journal's length here costs nothing on the
# poll path.
if [[ "$CURSOR" -gt 0 ]]; then
  JOURNAL_SIZE=0
  if [[ -f "$EVENTS_FILE" ]]; then
    JOURNAL_SIZE="$(wc -c < "$EVENTS_FILE" | tr -d '[:space:]')"
  fi
  if [[ "$CURSOR" -gt "$JOURNAL_SIZE" ]]; then
    if [[ $SINCE_SET -eq 1 ]]; then
      CURSOR_FIX="re-arm from a cursor this journal emitted, or drop --since to watch from the journal's end"
    else
      CURSOR_FIX="this cursor was persisted by an earlier watch — remove $CURSOR_FILE and the next watch re-baselines at the journal's end"
    fi
    fail "invalid cursor $CURSOR: cursor-past-eof — events.jsonl is $JOURNAL_SIZE bytes, so this cursor points past the end of the journal.
  The journal is append-only and is never compacted, truncated, or rotated, so a cursor lands here only if it was computed rather than echoed back, or if it was taken against a different journal (a store that was reset, restored, or replaced).
  Watching from it would replay the journal from byte zero and wake on rows the board worked through long ago, so it is refused rather than answered: $CURSOR_FIX"
  fi

  ALIGNMENT_STATUS=0
  session_cursor_row_aligned "$EVENTS_FILE" "$CURSOR" || ALIGNMENT_STATUS=$?
  case "$ALIGNMENT_STATUS" in
    0) ;;
    2) fail "invalid cursor $CURSOR: cursor-not-row-aligned (preceding byte is not newline); reuse a next_cursor emitted by lore coordinate watch, lore session wait, or lore session events" ;;
    *) fail "could not validate cursor $CURSOR" ;;
  esac
fi

OWNER_CHECK_ENABLED=0
if [[ -n "$OWNER_PID" || -n "$OWNER_TMUX" ]]; then
  OWNER_CHECK_ENABLED=1
fi

# emit_matched_from_record <record-json> — terminal for one matched read record.
emit_matched_from_record() {
  local record="$1" row cursor
  row="$(printf '%s' "$record" | jq -c '.event')"
  cursor="$(printf '%s' "$record" | jq -r '.next_cursor')"
  WAKE_OUTCOME="matched"
  WAKE_MATCHED="$row"
  classify_match "$row" "$(printf '%s' "$record" | jq -r '.scope.unattributed')"
  emit_wake "$cursor" 0 \
    "[coordinate] wake: $(printf '%s' "$row" | jq -r '.event') on '$(printf '%s' "$row" | jq -r '.slug // "(no slug)"')' — tier=$WAKE_TIER authority=$WAKE_AUTHORITY state=$WAKE_STATE label=$WAKE_LABEL"
}

CLOCK_WALL0=""
CLOCK_MONO0=""
IFS=$'\t' read -r CLOCK_WALL0 CLOCK_MONO0 <<< "$(clock_pair)"

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESULT="$(session_events_read "$EVENTS_SH" "$KNOWLEDGE_DIR" "$CURSOR")" || emit_internal_error "$CURSOR"
  RECORD="$(first_match_record "$RESULT")"
  NEXT="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
  if [[ -n "$RECORD" && "$RECORD" != "null" ]]; then
    emit_matched_from_record "$RECORD"
  fi
  # No match: nothing was withheld from the caller, so the batch cursor is the
  # row after the last row this read consumed, and advancing to it is correct.
  CURSOR="$NEXT"

  # A journal row always wins: it is the real event, and the pending check is
  # only there for the case where no row will ever come.
  if [[ "$PENDING_STALE" -gt 0 ]]; then
    PENDING="$(stale_pending)"
    if [[ "$(printf '%s' "$PENDING" | jq -r 'length')" -gt 0 ]]; then
      WAKE_OUTCOME="pending_stale"
      WAKE_PENDING="$PENDING"
      WAKE_AUTHORITY="none"
      WAKE_STATE="pending_stale"
      WAKE_LABEL="unclaimed-spawn-request-never-reaches-the-journal"
      WAKE_TIER="advisory"
      emit_wake "$CURSOR" 0 \
        "[coordinate] $(printf '%s' "$PENDING" | jq -r 'length') pending spawn request(s) unclaimed past ${PENDING_STALE}s; an unclaimed request never reaches the journal, so nothing else will report it (tier=$WAKE_TIER)"
    fi
  fi

  if [[ $OWNER_CHECK_ENABLED -eq 1 ]] \
    && ! session_owner_alive "$OWNER_PID" "$OWNER_TMUX" "$TMUX_SERVER"; then
    # Liveness is a hint, not a verdict: the owner's registry row and process go
    # away before the last journal append lands. Wait out a short grace and read
    # exactly once more, so the row this watcher exists to deliver is not the one
    # it drops on the way out.
    sleep "$OWNER_GONE_GRACE_SECONDS"
    RESULT="$(session_events_read "$EVENTS_SH" "$KNOWLEDGE_DIR" "$CURSOR")" || emit_internal_error "$CURSOR"
    RECORD="$(first_match_record "$RESULT")"
    if [[ -n "$RECORD" && "$RECORD" != "null" ]]; then
      emit_matched_from_record "$RECORD"
    fi
    CURSOR="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
    WAKE_OUTCOME="owner_gone"
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="owner-handle"
    WAKE_STATE="owner_gone"
    WAKE_LABEL="no-handle-proves-the-owner-is-alive"
    emit_wake "$CURSOR" 3 \
      "[coordinate] the watched owner is gone (pid='${OWNER_PID:-none}' tmux='${OWNER_TMUX:-none}') and a final read found nothing; stopping without re-arming"
  fi

  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 1
done

WAKE_OUTCOME="timeout"
WAKE_TIER="quiet"
WAKE_AUTHORITY="none"
WAKE_STATE="quiet"
WAKE_LABEL="nothing-actionable-in-scope"

# What the two clocks say this window actually spanned. A machine that slept with
# the window open froze the monotonic clock and not the wall clock, so a wide
# difference here says every age this window computed was measured against a
# stopped clock — worth re-joining the board before believing the quiet.
SKEW_LINE="$(clock_elapsed "$CLOCK_WALL0" "$CLOCK_MONO0")" || SKEW_LINE=""
if [[ -n "$SKEW_LINE" ]]; then
  IFS=$'\t' read -r WALL_ELAPSED MONO_ELAPSED SKEW <<< "$SKEW_LINE"
  WAKE_CLOCK_SKEW="$(jq -cn --argjson wall "$WALL_ELAPSED" --argjson mono "$MONO_ELAPSED" \
    --argjson skew "$SKEW" \
    '{wall_elapsed_seconds: $wall, monotonic_elapsed_seconds: $mono,
      skew_seconds: $skew}')"
fi

emit_wake "$CURSOR" 2 \
  "[coordinate] nothing actionable in scope after ${TIMEOUT}s (cursor $CURSOR persisted; re-arm with the same call)"
