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
# what changed on the coordination board since the last wake — so the caller can
# decide what to do without a round of manual re-reading.
#
# A wake does not have to start with a row. Rows only report what a session says
# about itself, and a session that hangs mid-turn says nothing — so does a machine
# that suspends with a window open. Both look exactly like a healthy quiet board.
# Two timers cover that: a liveness probe that reads the screen of scoped live
# sessions whose last journal row has gone old, and a clock comparison that ends
# the window when this machine has plainly been asleep. See "Stall detection" and
# "Suspension skew".
#
# Usage:
#   lore coordinate watch [--slug <s>]... [--arc <slug>]...
#                         [--until <events>] [--since <cursor>]
#                         [--timeout <sec>] [--pending-stale <sec>]
#                         [--peek-timeout <sec>] [--advisory-age <sec>]
#                         [--spawn-gap <sec>]
#                         [--probe-every <sec>] [--stall-after <sec>]
#                         [--stall-aged-after <sec>] [--probe-ttl <sec>]
#                         [--suspend-skew <sec>]
#                         [--owner-pid <pid>] [--owner-tmux <name>]
#                         [--tmux-server <name>] [--no-board-delta]
#                         [--wake-shaped] [--kdir <path>] [--json]
#
# Scoping:
#   --slug <s>        Wake only on rows belonging to work item <s>. Repeatable.
#                     A row belongs when its `.slug` matches or its
#                     `links.work_item` does — worker sessions run under a
#                     derived `<work-item>--w<n>` slug, so a slug-only test would
#                     drop every worker row. With no --slug and no --arc the
#                     watch stays board-wide, which is what a seat owning the
#                     whole board wants.
#   --arc <slug>      Add every work item the arc declares in its `members[]`.
#                     Repeatable, and combinable with --slug. Membership is
#                     declared, not inferred: items merely carrying the arc's
#                     project label are not included, so an arc whose members[]
#                     is empty contributes nothing. A scope that expands to no
#                     work items at all is refused rather than falling back to
#                     the whole board.
#
#   Actionable rows carrying neither identity key still wake a scoped watch, as
#   labeled "unattributed" advisories. Such a row cannot be scoped in or out on
#   the evidence it carries, and dropping it would turn a real event into
#   silence.
#
#   Each distinct scope keeps its own cursor, board baseline, advisory ledger,
#   probe cadence, and stall ledger, so two seats watching different scopes on one
#   store do not overwrite each other's position.
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
#   --timeout <sec>   How long to sleep before giving up (default: 3600). Exit 2.
#                     Run this in the background rather than in the foreground of
#                     a harness turn — a foreground command is killed long before
#                     an hour is up, and a killed watcher reads as a hang.
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
#   --advisory-age <sec>
#                     How long an unresolved advisory may repeat before it
#                     escalates from `advisory` to `aged_advisory` (default: 900;
#                     0 disables escalation).
#   --spawn-gap <sec> How young a session may be before a screen-confirmed park is
#                     demoted to a `spawn-gap` advisory (default: 90; 0 disables
#                     the age gate). See "Classification".
#   --probe-every <sec>
#                     How often the liveness probe runs (default: 120; 0 disables
#                     probing). The cadence is persisted per scope, so a window
#                     re-armed at every turn boundary keeps the same rhythm
#                     instead of probing every scoped session on every turn.
#   --stall-after <sec>
#                     How old a session's last journal row must be before the
#                     probe reads its screen (default: 900; 0 disables probing,
#                     the same as --probe-every 0). Detection latency is roughly
#                     this plus one cadence interval.
#   --stall-aged-after <sec>
#                     How old that row must be before a screen still generating
#                     output is itself reported, as `aged_advisory` (default:
#                     2700; 0 means a long turn is never reported). Must not be
#                     below --stall-after when both are set — an inverted pair
#                     looks configured and reaches nothing.
#   --probe-ttl <sec> How recently an instance must have touched its registry row
#                     to count as hosting its sessions (default: 30, matching
#                     `lore session peek`). The probe only ever addresses sessions
#                     inside this set. See "Stall detection".
#   --suspend-skew <sec>
#                     How far this window's wall clock may drift from its
#                     monotonic clock before the window ends (default: 120; 0
#                     disables the check). See "Suspension skew".
#   --owner-pid <pid> / --owner-tmux <name> / --tmux-server <name>
#                     Liveness handles for the seat this watcher reports to; the
#                     same two handles a coordination worktree lease records
#                     (--tmux-server defaults to lore-tui). See "Owner liveness".
#   --no-board-delta  Skip the board projection and report no delta. The wake is
#                     cheaper and less useful; the classification is unaffected.
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
#   confirmed wakes as a labeled `advisory` naming why no signature fired; an
#   advisory that keeps repeating past --advisory-age escalates to
#   `aged_advisory`. The seat is asleep and the watcher is its only observer, so
#   there is no state in which staying quiet is the safe answer.
#
# Stall detection:
#   Everything above starts with a row. A session that hangs mid-turn writes no
#   row, so nothing above ever fires for it and the board reads as quiet. Every
#   --probe-every seconds the watcher therefore asks the opposite question of the
#   sessions the registry claims are live: nothing has said anything about this
#   one for --stall-after seconds — is it alive?
#
#   Row age comes from the rows the watcher is already reading. Every row updates
#   a per-session "last heard from" map, including the ones no --until set wants
#   (step_completed, harness_turn_ended, quiescent, resumed) — those are precisely
#   the rows that prove a session is working. The map is seeded once at window
#   start from a single journal read bounded by --stall-aged-after; a session with
#   no row in that window has been silent for at least that long by construction.
#
#   A due probe reads the screen of each eligible session, stalest first, through
#   the same `lore session peek` the row-driven path uses, and hands the result to
#   the same signature table. What the screen shows decides:
#
#     a composer waiting, or a modal    a confirmed stall — wakes on sight
#     still generating, under
#       --stall-aged-after              a long turn, which is a session working.
#                                       No wake at all. This is the one place the
#                                       watcher deliberately says nothing about
#                                       something it observed: nothing is waiting
#                                       on the seat, and a wake for every long
#                                       turn is how a seat learns to ignore wakes.
#                                       The observation is not thrown away — it is
#                                       still counted in the `probe` block that
#                                       rides the next wake.
#     still generating, past
#       --stall-aged-after              the length of the turn is now the finding:
#                                       an `aged_advisory`.
#     nothing the matcher knows         an `advisory` naming what it saw, which
#                                       ages like any other.
#     the instance does not answer      a confirmed stall. The registry says an
#                                       instance is live and hosting this session,
#                                       so silence here means the thing that does
#                                       the observing has itself stopped serving.
#                                       (On the row-driven path an unanswered peek
#                                       is only an advisory, because a park row can
#                                       name a session no instance hosts at all.)
#
#   One wake per session per escalation step. A stall ledger beside the cursor
#   records the tier each session was last woken for; a later probe wakes again
#   only if it computes a strictly louder tier, so a session that degrades from a
#   long turn to a hung composer still gets its louder wake while one that just
#   keeps hanging does not repeat every cadence interval. That session's next
#   journal row clears the record outright — a row is exactly the evidence that
#   the silence ended.
#
#   The probe is bound by --slug/--arc scope, with no unattributed bypass. This is
#   the deliberate opposite of the rule for actionable rows above: a row carrying
#   neither identity key wakes a scoped watch anyway, because such a row cannot be
#   scoped on its own evidence and dropping it would turn a real event into
#   silence. The probe has no undecidable case — every registry session carries its
#   own slug — and a probe is an active interrogation of another seat's session
#   through that seat's instance, not a passive read of a row that already exists.
#   So an out-of-scope stalled session produces no wake here, and belongs to
#   whoever scoped it. A board-wide watch probes everything.
#
#   Sessions with no slug (chat sessions) cannot be probed at all, because peek
#   addresses sessions by slug. They are counted in `probe.skipped_slugless` so
#   the gap is visible rather than invisible.
#
# Suspension skew:
#   A laptop that sleeps with a window open freezes that window the same silent
#   way a hung session does. Wall time keeps moving across a suspension and
#   monotonic time does not, so the difference between how much of each has
#   elapsed since the window opened is the suspension and nothing else, to within
#   scheduling jitter of well under a second against a one-second poll. When that
#   difference reaches --suspend-skew the window ends
#   immediately, with outcome `clock_skew` and a body saying to re-join the board
#   before trusting quiet.
#
#   It ends the window rather than merely waking, because every piece of state
#   this window owns — cursor baseline, probe cadence, stall ledger, advisory ages
#   — was computed against a clock that stopped. A fresh window recomputes all of
#   them.
#
#   On each tick the check runs directly after the journal read, ahead of the
#   pending-staleness check and the probe. After a nap every pending request looks
#   stale and every session looks silent, so a skew check running later would emit
#   a burst of wakes about the frozen interval before reporting the freeze that
#   caused them. A real journal row still wins: it is an event that happened, not
#   an age computed against a stopped clock.
#
#   A supervisor that forks this watcher repeatedly across one logical window can
#   export LORE_WATCH_CLOCK_BASELINE as "<wall> <monotonic>" — the pair its own
#   span started from — and the skew is then measured from there rather than from
#   this child's start, so a suspension spanning a re-arm boundary is still seen.
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
#   Persisted at $KNOWLEDGE_DIR/_coordination/watch-cursor.json (board scope) or
#   watch-cursor-<scope>.json (scoped) as {schema_version, cursor, updated_at},
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
# The board delta:
#   Every wake also carries what changed on the coordination board since the last
#   wake, computed by diffing `coordinate-status.sh --json` row ids against a
#   baseline persisted beside the cursor. Board row ids are content hashes, so a
#   row whose content changed leaves under one id and returns under another; rows
#   pairing up by locator across the two sides are reported as changed rather than
#   as an unrelated removal and addition.
#
#   The delta is board-wide even under a scoped watch: scoping governs what wakes
#   you, the delta is what you are told once awake. It reserves a slot for
#   advisories the board projection cannot express, which is where the stale
#   pending requests are carried.
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
#      classification: {state, label, reason, advisory_age_seconds, peek,
#                       spawn_gap, modal_gate},
#      probe: {consulted, reason, cadence_seconds, stall_after_seconds,
#              aged_after_seconds, live_sessions, in_scope, skipped_slugless,
#              eligible, examined,
#              session: {slug, row_age_seconds, last_row_event, last_row_ts,
#                        band, peek, suppressed_from} | null},
#      clock_skew: {wall_elapsed_seconds, monotonic_elapsed_seconds,
#                   skew_seconds, threshold_seconds} | null,
#      matched, pending,
#      scope: {mode, slugs, arcs, cursor_file}, board_delta, next_cursor, until}
#   There is no top-level `slug`: session identity lives on the matched row, or on
#   `probe.session` for a stall wake. `probe` carries the last pass the window ran
#   even on a wake the probe did not cause, which is what makes a quiet wake
#   auditable: four sessions live, three in scope, two eligible, two examined, and
#   neither over a threshold is a different quiet from nothing having been looked
#   at. `probe.session` is filled only on the wake the probe itself caused.
#
#   `outcome` is one of: matched, pending_stale, session_stalled, clock_skew,
#   owner_gone, timeout, internal_error.
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
# originates, including its classifications, the pending-staleness advisory, and
# everything the liveness probe concludes, is printed to the caller rather than
# written where somebody could read it back as a lifecycle event.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

UNTIL="${SESSION_ACTIONABLE_EVENTS// /,}"
SINCE=""
SINCE_SET=0
TIMEOUT=3600
PENDING_STALE=300
PEEK_TIMEOUT=10
ADVISORY_AGE=900
# The spawn-paste gap, measured rather than guessed. Live wakes on 2026-08-03 put
# false confirmations — a ready composer on a session that had not taken its first
# turn — at 11s and 13s past the session's start row, and true parks (a real
# completion message sitting at a real prompt) at ~600s and ~900s. 90s is the
# geometric middle of that separation: ~7x the widest observed spawn gap and ~7x
# under the earliest observed true park, so both ends have an order of magnitude
# to drift into before the gate starts being wrong. It errs generous on purpose —
# a demoted true park still wakes the seat as an advisory that ages into
# `aged_advisory`, while a promoted spawn gap sends the seat to steer a session
# that is still booting, which is the failure this gate exists to stop.
SPAWN_GAP=90
# The stall thresholds, sized against the miss that motivated them: a research
# session silent for two hours with nobody watching. A healthy session emits a
# turn-boundary row every turn and a long single turn runs minutes, so 900s is
# about an order of magnitude above ordinary turn length and well under that
# miss. 2700s is three times that and still well under two hours, leaving a
# genuinely long turn room before it is called anomalous. A 120s cadence bounds
# detection latency to roughly --stall-after plus one interval, at a handful of
# screen reads per hour-long window.
PROBE_EVERY=120
STALL_AFTER=900
STALL_AGED_AFTER=2700
PROBE_TTL=30
SUSPEND_SKEW=120
OWNER_PID=""
OWNER_TMUX=""
TMUX_SERVER="lore-tui"
BOARD_DELTA=1
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
    --slug) SCOPE_SLUGS+=("${2:-}"); shift 2 ;;
    --arc) SCOPE_ARCS+=("${2:-}"); shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; SINCE_SET=1; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --pending-stale) PENDING_STALE="${2:-}"; shift 2 ;;
    --peek-timeout) PEEK_TIMEOUT="${2:-}"; shift 2 ;;
    --advisory-age) ADVISORY_AGE="${2:-}"; shift 2 ;;
    --spawn-gap) SPAWN_GAP="${2:-}"; shift 2 ;;
    --probe-every) PROBE_EVERY="${2:-}"; shift 2 ;;
    --stall-after) STALL_AFTER="${2:-}"; shift 2 ;;
    --stall-aged-after) STALL_AGED_AFTER="${2:-}"; shift 2 ;;
    --probe-ttl) PROBE_TTL="${2:-}"; shift 2 ;;
    --suspend-skew) SUSPEND_SKEW="${2:-}"; shift 2 ;;
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --no-board-delta) BOARD_DELTA=0; shift ;;
    --wake-shaped) WAKE_SHAPED=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    # The header comment above is the help text. This range ends on its last
    # line; a header that grows past it prints truncated, which --help itself
    # cannot notice.
    -h|--help) sed -n '2,377p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-watch.sh [--slug <s>]... [--arc <slug>]... [--until <events>] [--since <cursor>] [--timeout <sec>] [--pending-stale <sec>] [--peek-timeout <sec>] [--advisory-age <sec>] [--spawn-gap <sec>] [--probe-every <sec>] [--stall-after <sec>] [--stall-aged-after <sec>] [--probe-ttl <sec>] [--suspend-skew <sec>] [--owner-pid <pid>] [--owner-tmux <name>] [--tmux-server <name>] [--no-board-delta] [--wake-shaped] [--kdir <path>] [--json]" >&2
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
check_non_negative --advisory-age "$ADVISORY_AGE" "0 disables"
check_non_negative --spawn-gap "$SPAWN_GAP" "0 disables the age gate"
check_non_negative --probe-every "$PROBE_EVERY" "0 disables stall probing"
check_non_negative --stall-after "$STALL_AFTER" "0 disables stall probing"
check_non_negative --stall-aged-after "$STALL_AGED_AFTER" "0 disables the escalation"
check_non_negative --probe-ttl "$PROBE_TTL"
check_non_negative --suspend-skew "$SUSPEND_SKEW" "0 disables"

# An inverted pair reads as configured and reaches nothing: no row age can be at
# once past --stall-after and past a smaller --stall-aged-after in the order the
# bands are tested, so the escalation cell is unreachable. Refuse where the
# message can name the fix rather than leave a watcher that silently never
# escalates.
if [[ "$STALL_AFTER" -gt 0 && "$STALL_AGED_AFTER" -gt 0 && "$STALL_AGED_AFTER" -lt "$STALL_AFTER" ]]; then
  fail "invalid --stall-aged-after: ${STALL_AGED_AFTER}s is below --stall-after (${STALL_AFTER}s); raise it above --stall-after, or pass 0 to turn the escalation off"
fi

# The probe reads screens, so a run that cannot read a screen has no instrument.
PROBE_ENABLED=1
PROBE_OFF_REASON=""
if [[ "$PROBE_EVERY" -eq 0 ]]; then
  PROBE_ENABLED=0; PROBE_OFF_REASON="disabled by --probe-every 0"
elif [[ "$STALL_AFTER" -eq 0 ]]; then
  PROBE_ENABLED=0; PROBE_OFF_REASON="disabled by --stall-after 0"
elif [[ "$PEEK_TIMEOUT" -eq 0 ]]; then
  PROBE_ENABLED=0; PROBE_OFF_REASON="disabled by --peek-timeout 0: the probe has no instrument without a screen read"
fi

if [[ -n "$OWNER_PID" ]] && ! [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --owner-pid: '$OWNER_PID' (must be a positive integer)"
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
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

EVENTS_SH="$SCRIPT_DIR/session-events.sh"
PEEK_SH="$SCRIPT_DIR/session-peek.sh"
STATUS_SH="$SCRIPT_DIR/coordinate-status.sh"
EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"
PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
# The watcher's sidecars sit at the top of _coordination/, deliberately outside
# the journal and outside the worktree manager's registry — every directory under
# there has a sole writer that would not expect a second file appearing in it.
COORD_DIR="$KNOWLEDGE_DIR/_coordination"

# --- Resolve the scope ------------------------------------------------------

SCOPE_REQUESTED=0
if [[ ${#SCOPE_SLUGS[@]} -gt 0 || ${#SCOPE_ARCS[@]} -gt 0 ]]; then
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
    3) fail "--arc '$arc' is archived or carries an unknown status; scope it by --slug if you mean to watch it anyway" ;;
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

for slug in ${SCOPE_SLUGS[@]+"${SCOPE_SLUGS[@]}"}; do
  [[ -n "$slug" ]] || fail "empty --slug: pass a work-item slug"
done

# A requested scope that expanded to nothing must not fall through to watching
# the whole board — the caller would get wakes it did not ask for and no sign
# that its scope was dropped. Refuse here, where the message can name the fix.
if [[ $SCOPE_REQUESTED -eq 1 && ${#SCOPE_SLUGS[@]} -eq 0 ]]; then
  fail "the requested scope expands to no work items (every --arc given declares an empty members[]); add members with \`lore arc member\`, or scope by --slug"
fi

SCOPED=0
SCOPE_MODE="board"
SCOPE_SUFFIX=""
if [[ ${#SCOPE_SLUGS[@]} -gt 0 ]]; then
  SCOPED=1
  SCOPE_MODE="scoped"
  # One scope, one set of sidecars. The key is order-insensitive and
  # duplicate-insensitive so the same scope written two ways resumes one cursor.
  SCOPE_SUFFIX="-$(printf '%s\n' "${SCOPE_SLUGS[@]}" | LC_ALL=C sort -u \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')"
fi

CURSOR_FILE="$COORD_DIR/watch-cursor${SCOPE_SUFFIX}.json"
BASELINE_FILE="$COORD_DIR/watch-board-baseline${SCOPE_SUFFIX}.json"
ADVISORY_FILE="$COORD_DIR/watch-advisories${SCOPE_SUFFIX}.json"
PROBE_FILE="$COORD_DIR/watch-probe${SCOPE_SUFFIX}.json"
STALL_FILE="$COORD_DIR/watch-stalls${SCOPE_SUFFIX}.json"

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

# --- Advisory aging ----------------------------------------------------------

# advisory_tier <key> — echo "<tier>\t<age_seconds>\t<first_seen_iso>" for a
# recurring advisory, recording the first sighting of <key> if it is new.
# An advisory the coordinator has not resolved is a different problem the tenth
# time it fires than the first, so the ledger is what turns repetition into a
# louder tier rather than identical noise.
advisory_tier() {
  local key="$1"
  mkdir -p "$COORD_DIR"
  python3 - "$ADVISORY_FILE" "$key" "$ADVISORY_AGE" <<'PYEOF'
import json, os, sys, tempfile, time
from datetime import datetime, timezone

path, key, threshold = sys.argv[1], sys.argv[2], float(sys.argv[3])
now = time.time()
PRUNE_AFTER = 7 * 24 * 3600


def iso(stamp):
    return datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


ledger = {}
try:
    with open(path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict) and isinstance(loaded.get("seen"), dict):
        ledger = loaded["seen"]
except (OSError, ValueError):
    ledger = {}

entry = ledger.get(key)
if not isinstance(entry, dict) or not isinstance(entry.get("first_seen"), (int, float)):
    entry = {"first_seen": now}
entry["last_seen"] = now
ledger[key] = entry

kept = {}
for name, row in ledger.items():
    if not isinstance(row, dict):
        continue
    first = row.get("first_seen")
    if not isinstance(first, (int, float)):
        continue
    last = row.get("last_seen")
    if not isinstance(last, (int, float)):
        last = first
    if (now - last) > PRUNE_AFTER:
        continue
    kept[name] = {"first_seen": first, "last_seen": last, "first_seen_at": iso(first)}

try:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.watch-advisories.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"schema_version": 1, "updated_at": iso(now), "seen": kept}, handle)
    os.replace(tmp, path)
except OSError:
    pass

elapsed = now - float(entry["first_seen"])
tier = "aged_advisory" if (threshold > 0 and elapsed >= threshold) else "advisory"
print("%s\t%d\t%s" % (tier, int(elapsed), iso(float(entry["first_seen"]))))
PYEOF
}

# --- Board delta -------------------------------------------------------------

# board_delta <pending-json> — echo the wake's board_delta object.
#
# Composed from the published read-only projection: the delta adds a set
# difference over row ids, no new join. Never fatal — a projection this watcher
# could not read degrades the delta to an error field, because the wake it rides
# on is about the journal, not about the board.
# The python below writes to a file rather than being captured in a command
# substitution: bash 3.2 scans a heredoc nested inside $( ) for quotes, so an
# apostrophe in a Python comment there is a parse error rather than a comment.
board_delta() {
  local pending="$1" status=0 projection computed out
  if [[ $BOARD_DELTA -eq 0 ]]; then
    jq -cn --argjson pending "$pending" \
      '{consulted: false, reason: "disabled by --no-board-delta", advisories: {pending_stale: $pending}}'
    return 0
  fi
  mkdir -p "$COORD_DIR"
  projection="$(mktemp "$COORD_DIR/.tmp.watch-board.XXXXXX")" || {
    jq -cn --argjson pending "$pending" \
      '{consulted: false, error: "could not create a temporary file for the board projection", advisories: {pending_stale: $pending}}'
    return 0
  }
  computed="$(mktemp "$COORD_DIR/.tmp.watch-delta.XXXXXX")" || {
    rm -f "$projection"
    jq -cn --argjson pending "$pending" \
      '{consulted: false, error: "could not create a temporary file for the board delta", advisories: {pending_stale: $pending}}'
    return 0
  }
  if ! bash "$STATUS_SH" --kdir "$KNOWLEDGE_DIR" --json > "$projection" 2>/dev/null; then
    rm -f "$projection" "$computed"
    jq -cn --argjson pending "$pending" \
      '{consulted: false, error: "coordinate status projection failed", advisories: {pending_stale: $pending}}'
    return 0
  fi
  python3 - "$BASELINE_FILE" "$projection" > "$computed" 2>/dev/null <<'PYEOF' || status=$?
import json, os, sys, tempfile, time
from datetime import datetime, timezone

baseline_path, projection_path = sys.argv[1], sys.argv[2]


def digest(row):
    return {
        "id": row.get("id"),
        "source_id": row.get("source_id"),
        "kind": row.get("kind"),
        "title": row.get("title"),
        "locator": (row.get("evidence") or {}).get("locator"),
        "rule_id": (row.get("classification") or {}).get("rule_id"),
    }


with open(projection_path, encoding="utf-8") as handle:
    projection = json.load(handle)

current = {}
for name, rows in (projection.get("buckets") or {}).items():
    if not isinstance(rows, list):
        continue
    current[name] = {
        row["id"]: digest(row)
        for row in rows
        if isinstance(row, dict) and row.get("id")
    }

prior = None
try:
    with open(baseline_path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict) and isinstance(loaded.get("buckets"), dict):
        prior = loaded
except (OSError, ValueError):
    prior = None

delta_buckets = {}
counts = {"added": 0, "removed": 0, "changed": 0}
for name in sorted(current):
    now_rows = current[name]
    was_rows = ((prior or {}).get("buckets") or {}).get(name) or {}
    if not isinstance(was_rows, dict):
        was_rows = {}

    # Row ids are content hashes, so an edited row leaves under one id and
    # returns under another. Pairing the two sides by locator recovers that as
    # one change instead of an unrelated removal plus addition.
    unmatched_added = {}
    for row_id in sorted(now_rows):
        if row_id in was_rows:
            continue
        unmatched_added.setdefault(now_rows[row_id].get("locator"), []).append(row_id)

    changed, removed = [], []
    for row_id in sorted(was_rows):
        if row_id in now_rows:
            continue
        was = was_rows[row_id] if isinstance(was_rows[row_id], dict) else {}
        locator = was.get("locator")
        candidates = unmatched_added.get(locator) if locator else None
        if candidates:
            new_id = candidates.pop(0)
            changed.append({
                "locator": locator,
                "from_id": row_id,
                "to_id": new_id,
                "title": now_rows[new_id].get("title"),
                "rule_id": now_rows[new_id].get("rule_id"),
            })
        else:
            removed.append(was)

    added = [now_rows[row_id] for ids in unmatched_added.values() for row_id in ids]
    added.sort(key=lambda row: row.get("id") or "")

    if added or removed or changed:
        delta_buckets[name] = {"added": added, "removed": removed, "changed": changed}
    counts["added"] += len(added)
    counts["removed"] += len(removed)
    counts["changed"] += len(changed)

# With no baseline there is nothing to have changed since. Reporting the whole
# board as newly added would bury the first wake of every scope under rows that
# were already there; the bucket counts still say how big the board is.
if prior is None:
    delta_buckets = {}
    counts = {"added": 0, "removed": 0, "changed": 0}

now = time.time()
stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(baseline_path), prefix=".tmp.watch-board-baseline.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({
            "schema_version": 1,
            "updated_at": stamp,
            "observed_at": projection.get("observed_at"),
            "buckets": current,
        }, handle)
    os.replace(tmp, baseline_path)
except OSError:
    pass

print(json.dumps({
    "consulted": True,
    "first_observation": prior is None,
    "observed_at": projection.get("observed_at"),
    "baseline_observed_at": (prior or {}).get("observed_at"),
    "bucket_counts": {name: len(rows) for name, rows in sorted(current.items())},
    "counts": counts,
    "buckets": delta_buckets,
}, separators=(",", ":")))
PYEOF
  out="$(cat "$computed")"
  rm -f "$projection" "$computed"
  if [[ $status -ne 0 || -z "$out" ]]; then
    jq -cn --argjson pending "$pending" \
      '{consulted: false, error: "board delta could not be computed from the projection", advisories: {pending_stale: $pending}}'
    return 0
  fi
  # The advisory slot carries what the board projection has no row for: an
  # unclaimed spawn request never becomes a journal row, so nothing in the
  # projection can represent it.
  printf '%s' "$out" | jq -c --argjson pending "$pending" '. + {advisories: {pending_stale: $pending}}'
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
WAKE_ADVISORY_AGE="null"    # JSON
WAKE_SPAWN_GAP="null"       # JSON
WAKE_MODAL_GATE="null"      # JSON
WAKE_PROBE="null"           # JSON
WAKE_CLOCK_SKEW="null"      # JSON

if [[ $PROBE_ENABLED -eq 0 ]]; then
  WAKE_PROBE="$(jq -cn --arg r "$PROBE_OFF_REASON" '{consulted: false, reason: $r}')"
fi

# emit_wake <cursor> <exit-code> <message>
# The single terminal. Non-zero terminals print their JSON by hand: json_output
# hard-exits 0, which would erase the composed exit code.
emit_wake() {
  local cursor="$1" code="$2" message="$3" payload delta

  [[ "$cursor" == "null" ]] || write_cursor_file "$cursor"
  delta="$(board_delta "$WAKE_PENDING")"

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
    --argjson advisory_age "$WAKE_ADVISORY_AGE" \
    --argjson spawn_gap "$WAKE_SPAWN_GAP" \
    --argjson modal_gate "$WAKE_MODAL_GATE" \
    --argjson probe "$WAKE_PROBE" \
    --argjson clock_skew "$WAKE_CLOCK_SKEW" \
    --argjson matched "$WAKE_MATCHED" \
    --argjson pending "$WAKE_PENDING" \
    --arg mode "$SCOPE_MODE" \
    --argjson slugs "$SCOPE_SLUGS_JSON" \
    --argjson arcs "$SCOPE_ARCS_JSON" \
    --arg cursor_file "$(basename "$CURSOR_FILE")" \
    --argjson delta "$delta" \
    --argjson nc "$cursor" \
    --argjson until "$UNTIL_JSON" \
    '{schema_version: $schema, outcome: $outcome, tier: $tier, authority: $authority,
      signature_version: $signature_version,
      classification: {state: $state, label: $label, reason: $reason,
                       advisory_age_seconds: $advisory_age, peek: $peek,
                       spawn_gap: $spawn_gap, modal_gate: $modal_gate},
      probe: $probe, clock_skew: $clock_skew,
      matched: $matched, pending: $pending,
      scope: {mode: $mode, slugs: $slugs, arcs: $arcs, cursor_file: $cursor_file},
      board_delta: $delta, next_cursor: $nc, until: $until}')"

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

# Set the advisory tier and its age from the recurrence ledger.
apply_advisory_tier() {
  local key="$1" line
  line="$(advisory_tier "$key")" || line=""
  if [[ -n "$line" ]]; then
    WAKE_TIER="$(printf '%s' "$line" | cut -f1)"
    WAKE_ADVISORY_AGE="$(printf '%s' "$line" | cut -f2)"
  else
    WAKE_TIER="advisory"
    WAKE_ADVISORY_AGE="null"
  fi
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
    apply_advisory_tier "unattributed:$event"
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
        apply_advisory_tier "park:$slug:$event:modal-not-on-screen"
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
    apply_advisory_tier "park:$slug:$event:$WAKE_LABEL"
    return 0
  fi

  WAKE_AUTHORITY="screen-signature"
  WAKE_STATE="park_unconfirmed"
  if ! peek_session "$slug"; then
    WAKE_LABEL="peek-unavailable"
    apply_advisory_tier "park:$slug:$event:peek-unavailable"
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
      apply_advisory_tier "park:$slug:$event:spawn-gap"
      return 0
    fi
    WAKE_TIER="confirmed"
    WAKE_STATE="confirmed_park"
    return 0
  fi
  apply_advisory_tier "park:$slug:$event:$label"
}

# --- Stall detection ---------------------------------------------------------

# slug -> {ts, event} for the most recent journal row seen about each session.
LAST_ROW_MAP='{}'

# absorb_rows <reader-payload> — fold every row of one read into the last-row map.
#
# Every row, not only the ones the until-set wants: a step_completed or a
# harness_turn_ended is worthless as a wake and is exactly what proves a session
# is still working. Rows carrying no timestamp are left out, since there is
# nothing to measure staleness from; the sole writer stamps every row it appends.
absorb_rows() {
  local payload="$1" folded=""
  folded="$(printf '%s' "$payload" | jq -c --argjson map "$LAST_ROW_MAP" '
    reduce (.events[]? | select(type == "object")) as $row ($map;
      ($row.slug // "") as $s
      | ($row.ts // "") as $t
      | if $s == "" or $t == "" then .
        else .[$s] = {ts: $t, event: ($row.event // null)}
        end)' 2>/dev/null)" || folded=""
  if [[ -n "$folded" ]]; then
    LAST_ROW_MAP="$folded"
  fi
  return 0
}

# seed_last_rows — one bounded backward read so the map starts the window with
# what the board has been saying, rather than knowing nothing until the first row
# of this window arrives. The window is --stall-aged-after wide because that is
# the oldest age the bands distinguish: a session with no row in it is silent by
# at least that much, whatever happened before.
seed_last_rows() {
  local lookback="$1" bounds window_start="" window_end="" payload
  bounds="$(python3 -c '
import sys
from datetime import datetime, timedelta, timezone

lookback = float(sys.argv[1])
now = datetime.now(timezone.utc)
fmt = "%Y-%m-%dT%H:%M:%SZ"
print((now - timedelta(seconds=lookback)).strftime(fmt))
print((now + timedelta(seconds=1)).strftime(fmt))
' "$lookback" 2>/dev/null)" || return 0
  { IFS= read -r window_start; IFS= read -r window_end; } <<< "$bounds"
  [[ -n "$window_start" && -n "$window_end" ]] || return 0
  payload="$(session_events_run "$EVENTS_SH" --json \
    --window-start "$window_start" --window-end "$window_end" --kdir "$KNOWLEDGE_DIR")" || return 0
  absorb_rows "$payload"
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

# probe_due — 0 when a probe pass is owed, recording the pass as run.
# The cadence is persisted per scope because the window re-opens at every turn
# boundary: without it an active seat would probe every scoped session every turn.
# No file means due now, so a fresh scope gets its first pass immediately.
probe_due() {
  mkdir -p "$COORD_DIR"
  python3 - "$PROBE_FILE" "$PROBE_EVERY" <<'PYEOF'
import json, os, sys, tempfile, time
from datetime import datetime, timezone

path, cadence = sys.argv[1], float(sys.argv[2])
now = time.time()

last = None
try:
    with open(path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict) and isinstance(loaded.get("last_probe_at"), (int, float)):
        last = float(loaded["last_probe_at"])
except (OSError, ValueError):
    last = None

if last is not None and (now - last) < cadence:
    raise SystemExit(1)

stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.watch-probe.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"schema_version": 1, "last_probe_at": now, "updated_at": stamp}, handle)
    os.replace(tmp, path)
except OSError:
    pass
PYEOF
}

# probe_set <live-tsv> — echo one JSON object describing this pass's candidates:
# {live_sessions, in_scope, skipped_slugless, eligible, candidates: [...]},
# stalest first.
#
# Scope admits a worker session by its work item, the same join the journal
# predicate makes through links.work_item, so a seat scoped to a work item sees
# its workers stall. Out-of-scope sessions are dropped outright: unlike a journal
# row carrying no identity key, a registry session is always decidable, so
# dropping one silences nothing that this seat could have been expected to act on.
probe_set() {
  local live="$1"
  PROBE_LIVE="$live" PROBE_MAP="$LAST_ROW_MAP" PROBE_SCOPE="$SCOPE_SLUGS_JSON" \
    python3 - "$SCOPED" "$STALL_AFTER" "$STALL_AGED_AFTER" <<'PYEOF'
import json, os, re, sys
from datetime import datetime, timezone

scoped = sys.argv[1] == "1"
stall_after, aged_after = float(sys.argv[2]), float(sys.argv[3])

try:
    scope = set(json.loads(os.environ.get("PROBE_SCOPE") or "[]"))
except ValueError:
    scope = set()
try:
    last_rows = json.loads(os.environ.get("PROBE_MAP") or "{}")
except ValueError:
    last_rows = {}
if not isinstance(last_rows, dict):
    last_rows = {}

WORKER_SLUG = re.compile(r"^(.+)--w[0-9]+$")
now = datetime.now(timezone.utc)


def parse(value):
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    stamp = datetime.fromisoformat(text)
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


live_sessions, slugless, in_scope = 0, 0, []
for line in (os.environ.get("PROBE_LIVE") or "").splitlines():
    state, _, slug = line.partition("\t")
    if state == "slugless":
        live_sessions += 1
        slugless += 1
        continue
    if state != "named" or not slug:
        continue
    live_sessions += 1
    if scoped:
        match = WORKER_SLUG.match(slug)
        owner = match.group(1) if match else slug
        if slug not in scope and owner not in scope:
            continue
    in_scope.append(slug)

candidates = []
for slug in in_scope:
    row = last_rows.get(slug)
    age, last_ts, last_event = None, None, None
    if isinstance(row, dict):
        last_event = row.get("event")
        raw = row.get("ts")
        if isinstance(raw, str) and raw:
            last_ts = raw
            try:
                age = int((now - parse(raw)).total_seconds())
            except ValueError:
                age = None
    if age is None:
        # Nothing about this session inside the seed window, so it has been
        # silent for at least the whole window.
        band = "aged" if aged_after > 0 else "stalled"
    elif age < stall_after:
        band = "fresh"
    elif aged_after > 0 and age >= aged_after:
        band = "aged"
    else:
        band = "stalled"
    if band == "fresh":
        continue
    candidates.append({
        "slug": slug,
        "row_age_seconds": age,
        "last_row_event": last_event,
        "last_row_ts": last_ts,
        "band": band,
    })

# Stalest first: the longest silence is the likeliest real stall, and the window
# ends on the first session that warrants a wake.
candidates.sort(key=lambda c: (
    0 if c["row_age_seconds"] is None else 1,
    -(c["row_age_seconds"] or 0),
    c["slug"],
))

print(json.dumps({
    "live_sessions": live_sessions,
    "in_scope": len(in_scope),
    "skipped_slugless": slugless,
    "eligible": len(candidates),
    "candidates": candidates,
}, separators=(",", ":")))
PYEOF
}

# stall_ledger_admits <slug> <tier> <last-row-ts> <live-tsv>
# "<wake|suppressed><TAB><tier previously woken for, or empty>".
#
# Without this a confirmed stall would wake once per cadence interval for as long
# as the session stays hung — thirty wakes an hour for one problem. Ranking rather
# than equality means a session degrading from a long turn to a hung composer
# still gets its louder wake, while one whose screen read goes flaky and reports
# something weaker does not wake again. A record is dropped when that session
# speaks (a new row is exactly the evidence the silence ended) or when its slug
# leaves the registry, so a recovered session starts clean at every tier.
stall_ledger_admits() {
  local slug="$1" tier="$2" last_ts="$3" live="$4"
  mkdir -p "$COORD_DIR"
  PROBE_LIVE="$live" python3 - "$STALL_FILE" "$slug" "$tier" "$last_ts" <<'PYEOF'
import json, os, sys, tempfile, time
from datetime import datetime, timezone

path, slug, tier, last_ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
RANK = {"advisory": 1, "aged_advisory": 2, "confirmed": 3}
PRUNE_AFTER = 7 * 24 * 3600
now = time.time()

live = set()
for line in (os.environ.get("PROBE_LIVE") or "").splitlines():
    state, _, name = line.partition("\t")
    if state == "named" and name:
        live.add(name)

ledger = {}
try:
    with open(path, encoding="utf-8") as handle:
        loaded = json.load(handle)
    if isinstance(loaded, dict) and isinstance(loaded.get("woken"), dict):
        ledger = loaded["woken"]
except (OSError, ValueError):
    ledger = {}

kept = {}
for name, row in ledger.items():
    if not isinstance(row, dict) or name not in live:
        continue
    stamp = row.get("woken_at")
    if not isinstance(stamp, (int, float)) or (now - stamp) > PRUNE_AFTER:
        continue
    kept[name] = row

entry = kept.get(slug)
if isinstance(entry, dict) and (entry.get("last_row_ts") or "") != last_ts:
    entry = None
    kept.pop(slug, None)

previous = ""
wake = True
if isinstance(entry, dict):
    previous = entry.get("tier") or ""
    if RANK.get(tier, 0) <= RANK.get(previous, 0):
        wake = False

if wake:
    kept[slug] = {"tier": tier, "last_row_ts": last_ts, "woken_at": now}

stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
try:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.watch-stalls.")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump({"schema_version": 1, "updated_at": stamp, "woken": kept}, handle)
    os.replace(tmp, path)
except OSError:
    pass

print("%s\t%s" % ("wake" if wake else "suppressed", previous))
PYEOF
}

# probe_record <set-json> <examined> <session-json>
probe_record() {
  jq -cn --argjson counts "$1" --argjson examined "$2" --argjson session "$3" \
    --argjson cadence "$PROBE_EVERY" --argjson stall "$STALL_AFTER" \
    --argjson aged "$STALL_AGED_AFTER" \
    '{consulted: true, reason: null, cadence_seconds: $cadence,
      stall_after_seconds: $stall, aged_after_seconds: $aged,
      live_sessions: $counts.live_sessions, in_scope: $counts.in_scope,
      skipped_slugless: $counts.skipped_slugless, eligible: $counts.eligible,
      examined: $examined, session: $session}'
}

# run_probe — one due pass. Terminates the window through emit_wake on the first
# session that warrants one; returns having recorded the pass otherwise.
run_probe() {
  local live set_json total="" examined=0 index=0 entry slug band last_ts
  local peek_out peek_status ready blocked peek_json verdict label tier
  local decision admits suppressed_from
  # A pass that examines sessions without waking must leave the wake fields as it
  # found them, or a later quiet timeout would inherit a tier nothing set for it.
  local held_tier="$WAKE_TIER" held_state="$WAKE_STATE" held_age="$WAKE_ADVISORY_AGE"

  live="$(session_live_slugs "$KNOWLEDGE_DIR/_sessions/instances" "$PROBE_TTL")" || live=""
  set_json="$(probe_set "$live")" || return 0
  [[ -n "$set_json" ]] || return 0
  total="$(printf '%s' "$set_json" | jq -r '.candidates | length')" || total=""
  [[ "$total" =~ ^[0-9]+$ ]] || total=0

  while [[ $index -lt $total ]]; do
    entry="$(printf '%s' "$set_json" | jq -c --argjson i "$index" '.candidates[$i]')"
    index=$(( index + 1 ))
    slug="$(printf '%s' "$entry" | jq -r '.slug')"
    band="$(printf '%s' "$entry" | jq -r '.band')"
    last_ts="$(printf '%s' "$entry" | jq -r '.last_row_ts // ""')"
    examined=$(( examined + 1 ))

    # Contained per candidate: one session whose instance will not answer must not
    # end the pass before the others have been looked at.
    peek_status=0
    peek_out="$(bash "$PEEK_SH" "$slug" --json --timeout "$PEEK_TIMEOUT" \
      --ttl "$PROBE_TTL" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)" || peek_status=$?

    if [[ $peek_status -ne 0 ]]; then
      tier="confirmed"
      label="probe-unanswered-by-live-instance"
      WAKE_STATE="stall_confirmed"
      peek_json="$(jq -n --arg e "$(printf '%s' "$peek_out" | jq -r '.error // "peek did not answer"' 2>/dev/null || echo 'peek did not answer')" \
        '{consulted: true, ready: null, blocked_reason: null, error: $e}')"
    else
      ready="$(printf '%s' "$peek_out" | jq -r 'if (.ready | type) == "boolean" then (.ready | tostring) else "" end' 2>/dev/null || echo "")"
      blocked="$(printf '%s' "$peek_out" | jq -r '.blocked_reason // ""' 2>/dev/null || echo "")"
      peek_json="$(jq -n --arg r "$ready" --arg b "$blocked" \
        '{consulted: true,
          ready: (if $r == "" then null else ($r == "true") end),
          blocked_reason: (if $b == "" then null else $b end),
          error: null}')"
      IFS=$'\t' read -r verdict label <<< "$(session_park_classify "probe:$band" "$ready" "$blocked")"
      if [[ "$verdict" == "confirmed" ]]; then
        tier="confirmed"
        WAKE_STATE="stall_confirmed"
      elif [[ "$label" == "long-turn-below-aged-threshold" ]]; then
        # The one observation this watcher deliberately does not deliver. The
        # session is working and nobody is waiting on the seat, so there is no
        # actionable event here to go silent on — the probe asked the question and
        # the answer is that there is nothing to say yet.
        continue
      elif [[ "$label" == "long-turn-past-aged-threshold" ]]; then
        tier="aged_advisory"
        WAKE_STATE="stall_unconfirmed"
      else
        apply_advisory_tier "stall:$slug:$label"
        tier="$WAKE_TIER"
        WAKE_STATE="stall_unconfirmed"
      fi
    fi

    decision="$(stall_ledger_admits "$slug" "$tier" "$last_ts" "$live")" || decision=""
    admits="wake"
    suppressed_from=""
    if [[ -n "$decision" ]]; then
      IFS=$'\t' read -r admits suppressed_from <<< "$decision"
    fi
    if [[ "$admits" == "suppressed" ]]; then
      continue
    fi

    WAKE_OUTCOME="session_stalled"
    WAKE_TIER="$tier"
    WAKE_AUTHORITY="screen-signature"
    WAKE_LABEL="$label"
    WAKE_PEEK="$peek_json"
    WAKE_PROBE="$(probe_record "$set_json" "$examined" \
      "$(printf '%s' "$entry" | jq -c --argjson peek "$peek_json" --arg from "$suppressed_from" \
        '. + {peek: $peek, suppressed_from: (if $from == "" then null else $from end)}')")"
    emit_wake "$CURSOR" 0 \
      "[coordinate] wake: '$slug' has been silent since $(printf '%s' "$entry" | jq -r '.last_row_ts // "before this window opened"') and its screen says $label — tier=$WAKE_TIER"
  done

  # Nothing crossed a threshold. The counts still ride the next wake, so a quiet
  # window can be told from one where nothing was looked at.
  WAKE_PROBE="$(probe_record "$set_json" "$examined" null)"
  WAKE_TIER="$held_tier"
  WAKE_STATE="$held_state"
  WAKE_ADVISORY_AGE="$held_age"
  return 0
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
if [[ "$SUSPEND_SKEW" -gt 0 ]]; then
  CLOCK_BASELINE="${LORE_WATCH_CLOCK_BASELINE:-}"
  if [[ -z "$CLOCK_BASELINE" ]]; then
    CLOCK_BASELINE="$(clock_pair)" || CLOCK_BASELINE=""
  fi
  IFS=$' \t' read -r CLOCK_WALL0 CLOCK_MONO0 <<< "$CLOCK_BASELINE"
fi

if [[ $PROBE_ENABLED -eq 1 ]]; then
  SEED_LOOKBACK="$STALL_AGED_AFTER"
  [[ "$SEED_LOOKBACK" -ge "$STALL_AFTER" ]] || SEED_LOOKBACK="$STALL_AFTER"
  seed_last_rows "$SEED_LOOKBACK"
fi

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
  if [[ $PROBE_ENABLED -eq 1 ]]; then
    absorb_rows "$RESULT"
  fi

  # Before anything that reads a clock-derived threshold. After a suspension every
  # pending request looks stale and every session looks silent, so this check
  # running later would emit a burst of wakes about the frozen interval before
  # reporting the freeze that produced them.
  if [[ -n "$CLOCK_WALL0" && -n "$CLOCK_MONO0" ]]; then
    SKEW_LINE="$(clock_elapsed "$CLOCK_WALL0" "$CLOCK_MONO0")" || SKEW_LINE=""
    if [[ -n "$SKEW_LINE" ]]; then
      IFS=$'\t' read -r WALL_ELAPSED MONO_ELAPSED SKEW <<< "$SKEW_LINE"
      if [[ "$SKEW" -ge "$SUSPEND_SKEW" ]]; then
        WAKE_CLOCK_SKEW="$(jq -cn --argjson wall "$WALL_ELAPSED" --argjson mono "$MONO_ELAPSED" \
          --argjson skew "$SKEW" --argjson threshold "$SUSPEND_SKEW" \
          '{wall_elapsed_seconds: $wall, monotonic_elapsed_seconds: $mono,
            skew_seconds: $skew, threshold_seconds: $threshold}')"
        WAKE_OUTCOME="clock_skew"
        WAKE_TIER="confirmed"
        WAKE_AUTHORITY="none"
        WAKE_STATE="clock_skew"
        WAKE_LABEL="window-slept-through-suspension"
        emit_wake "$CURSOR" 0 \
          "[coordinate] this machine was asleep for about ${SKEW}s with the window open; every age this window computed is measured against a stopped clock. Re-join the board and re-arm before trusting quiet"
      fi
    fi
  fi

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
      apply_advisory_tier "pending_stale:$(printf '%s' "$PENDING" | jq -r '.[0].request_id')"
      emit_wake "$CURSOR" 0 \
        "[coordinate] $(printf '%s' "$PENDING" | jq -r 'length') pending spawn request(s) unclaimed past ${PENDING_STALE}s; an unclaimed request never reaches the journal, so nothing else will report it (tier=$WAKE_TIER)"
    fi
  fi

  # Rows first, silence second: a session that spoke is not a session to go
  # reading screens about.
  if [[ $PROBE_ENABLED -eq 1 ]] && probe_due; then
    run_probe
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
emit_wake "$CURSOR" 2 \
  "[coordinate] nothing actionable in scope after ${TIMEOUT}s (cursor $CURSOR persisted; re-arm with the same call)"
