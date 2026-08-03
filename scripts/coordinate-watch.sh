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
# Usage:
#   lore coordinate watch [--slug <s>]... [--arc <slug>]...
#                         [--until <events>] [--since <cursor>]
#                         [--timeout <sec>] [--pending-stale <sec>]
#                         [--peek-timeout <sec>] [--advisory-age <sec>]
#                         [--spawn-gap <sec>]
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
#   Each distinct scope keeps its own cursor, baseline, and advisory ledger, so
#   two seats watching different scopes on one store do not overwrite each
#   other's position.
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
#                       than blended with the other.
#     screen-signature  The row was park-shaped and carried no state of its own,
#                       so the watcher peeked the session and matched the result
#                       against the strict signature set (see lib.sh's
#                       session_park_classify). The signature set is versioned and
#                       the version travels in the wake, so a matcher-contract
#                       change is visible instead of silently reclassifying parks.
#     owner-handle      The wake came from the owner-liveness check.
#     none              Nothing to classify (a quiet timeout).
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
#   Strictness governs the wake's tier, never whether it wakes. A park nothing
#   confirmed wakes as a labeled `advisory` naming why no signature fired; an
#   advisory that keeps repeating past --advisory-age escalates to
#   `aged_advisory`. The seat is asleep and the watcher is its only observer, so
#   there is no state in which staying quiet is the safe answer.
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
#                       spawn_gap}, matched, pending,
#      scope: {mode, slugs, arcs, cursor_file}, board_delta, next_cursor, until}
#   There is no top-level `slug`: session identity lives on the matched row.
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
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --no-board-delta) BOARD_DELTA=0; shift ;;
    --wake-shaped) WAKE_SHAPED=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,209p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-watch.sh [--slug <s>]... [--arc <slug>]... [--until <events>] [--since <cursor>] [--timeout <sec>] [--pending-stale <sec>] [--peek-timeout <sec>] [--advisory-age <sec>] [--spawn-gap <sec>] [--owner-pid <pid>] [--owner-tmux <name>] [--tmux-server <name>] [--no-board-delta] [--wake-shaped] [--kdir <path>] [--json]" >&2
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
                       spawn_gap: $spawn_gap},
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

# classify_match <row-json> <unattributed>
# Fill the WAKE_* classification fields for one matched journal row.
classify_match() {
  local row="$1" unattributed="$2" event slug row_ts row_reason peek_out peek_status verdict label ready blocked

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
  if [[ -n "$row_reason" ]]; then
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="confirmed_park"
    WAKE_LABEL="row-carries-emitter-state"
    WAKE_REASON="$(jq -n --arg r "$row_reason" '$r')"
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
  peek_status=0
  peek_out="$(bash "$PEEK_SH" "$slug" --json --timeout "$PEEK_TIMEOUT" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)" \
    || peek_status=$?
  if [[ $peek_status -ne 0 ]]; then
    WAKE_LABEL="peek-unavailable"
    WAKE_PEEK="$(jq -n --arg e "$(printf '%s' "$peek_out" | jq -r '.error // "peek did not answer"' 2>/dev/null || echo 'peek did not answer')" \
      '{consulted: true, ready: null, blocked_reason: null, error: $e}')"
    apply_advisory_tier "park:$slug:$event:peek-unavailable"
    return 0
  fi

  ready="$(printf '%s' "$peek_out" | jq -r 'if (.ready | type) == "boolean" then (.ready | tostring) else "" end' 2>/dev/null || echo "")"
  blocked="$(printf '%s' "$peek_out" | jq -r '.blocked_reason // ""' 2>/dev/null || echo "")"
  WAKE_PEEK="$(jq -n --arg r "$ready" --arg b "$blocked" \
    '{consulted: true,
      ready: (if $r == "" then null else ($r == "true") end),
      blocked_reason: (if $b == "" then null else $b end),
      error: null}')"

  IFS=$'\t' read -r verdict label <<< "$(session_park_classify "$event" "$ready" "$blocked")"
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

# A cursor is a row boundary. An interior offset would make the tolerant
# reference reader parse a row's suffix and call the caller's bad input corrupt
# journal, so refuse it here and name the fix.
if [[ "$CURSOR" -gt 0 ]]; then
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
      apply_advisory_tier "pending_stale:$(printf '%s' "$PENDING" | jq -r '.[0].request_id')"
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
emit_wake "$CURSOR" 2 \
  "[coordinate] nothing actionable in scope after ${TIMEOUT}s (cursor $CURSOR persisted; re-arm with the same call)"
