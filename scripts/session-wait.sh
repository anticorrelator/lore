#!/usr/bin/env bash
# session-wait.sh — Block until a session-journal event lands, then hand back a
# resume cursor. This is the blocking front on the events journal: it polls
# session-events.sh (the reference reader) from a cursor and wakes the moment a
# matching row appears, so the harness can re-invoke a coordinator on session
# activity instead of the coordinator hand-rolling a sleep loop.
#
# Usage:
#   lore session wait <slug> [--until <events>] [--since <cursor>]
#                            [--request-id <id>] [--timeout <sec>] [--ttl <sec>]
#                            [--kdir <path>] [--json]
#
# Options:
#   --until <events>  Comma-separated event names to wake on (default:
#                     closed,close_failed — the close-outcome pair, since a
#                     teardown can end in either). Each name is checked against the
#                     journal's event vocabulary up front; a name that is not in it
#                     is a usage error, not a wait that never ends.
#   --since <cursor>  Byte-offset cursor to start reading from. Omit to start at
#                     the journal's current end ("wake on what happens next").
#                     Treat the value as opaque — pass back a cursor this verb or
#                     `session events` reported, never one you computed.
#   --request-id <id> Also require an exact request_id match. Use this when a slug
#                     can be reused across sessions so a late row from the prior
#                     session cannot satisfy the new wait. Omit it to preserve
#                     slug-and-event matching; no request-id guard is inferred.
#   --timeout <sec>   How long to wait before giving up (default: 60).
#   --ttl <sec>       Liveness window for the owning-instance check (default: 30).
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit one result object instead of plain rows (see below).
#
# A row matches when its slug equals <slug> exactly, its event is in the until-set,
# and — only when --request-id is supplied — its request_id equals that value.
# Slug matching is exact string equality on purpose: a worker session runs under
# a derived slug `<slug>--w<n>`, so matching by substring would wake a parent wait
# on its own worker's close.
#
# Output (plain):
#   On a match: the matched event row, then a final {"next_cursor": N} row — both
#   on stdout, in one read. On timeout or session-gone: just the {"next_cursor": N}
#   row on stdout, with a one-line diagnostic on stderr. Every non-error exit hands
#   back the cursor so the caller can re-arm with --since <that cursor> — no journal
#   replay, and it never re-matches the row it just consumed.
#
# Output (--json): one object {outcome, matched, next_cursor, slug, until} on every
#   terminal — outcome is "matched" | "timeout" | "session_gone", matched is the
#   event row or null.
#
# Exit codes (meanings are local to this verb — do not read them as a cross-verb
# contract):
#   0  a matching row landed
#   1  error (bad args, unknown --until event, missing store)
#   2  timed out before any match — the expected re-arm branch for a watcher, not a
#      failure: re-invoke with --since <emitted cursor>
#   3  session gone: no live instance hosts <slug> and no matching row arrived
#      during a two-second teardown grace followed by one final journal read.
#      Journal rows are authoritative; liveness only starts this grace check.
#      Suppressed when the until-set names a queue/pre-spawn event, since an
#      unhosted slug is the normal starting state there. A crashed instance can be
#      adopted by a replacement (which journals `recovered`), so a session-gone in
#      that window is re-armable — retry from the emitted cursor.
#
# Watching a human-initiated session: those are held open at protocol terminus and
# do NOT journal `closed` there — their terminus signal is `close_requested` with
# reason `protocol_terminus` (they emit `closed` only when the human dismisses the
# done panel). To watch a human session reach terminus, wait on close_requested.
#
# Race-free teardown idiom — capture the baseline BEFORE you act, or a row landing
# between the two commands is invisible to a default-baseline wait:
#   C=$(lore session events --cursor-only)
#   lore session close <slug>
#   lore session wait <slug> --since "$C"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SLUG_ARG=""
UNTIL="closed,close_failed"
SINCE=""
SINCE_SET=0
TIMEOUT=60
TTL=30
SESSION_GONE_GRACE_SECONDS=2
KDIR_OVERRIDE=""
JSON_MODE=0
REQUEST_ID=""
REQUEST_ID_SET=0

# Mirror of the sole writer's event vocabulary (session-event-append.sh's
# validation case-arm). tests/session-verbs.bats cross-checks this list against
# the writer and names any drift; if that test fails, reconcile this line with the
# writer rather than silencing the test.
SESSION_EVENT_VOCAB="requested claimed spawned needs_input quiescent resumed recovered closed step_completed harness_turn_ended spawn_failed request_reclaimed request_abandoned request_cancelled close_requested close_failed send_requested sent send_refused review_flagged review_held review_notified review_released"

# Waiting on any of these queue/pre-spawn events means an unhosted slug is the
# normal starting state, so the session-gone (liveness) exit is disabled for them —
# timeout is the only bound.
PRESPAWN_EVENTS="requested claimed spawned spawn_failed request_reclaimed request_abandoned request_cancelled"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --until) UNTIL="$2"; shift 2 ;;
    --since) SINCE="$2"; SINCE_SET=1; shift 2 ;;
    --request-id) REQUEST_ID="$2"; REQUEST_ID_SET=1; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,72p' "$0"; exit 0 ;;
    --*)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-wait.sh <slug> [--until <events>] [--since <cursor>] [--request-id <id>] [--timeout <sec>] [--ttl <sec>] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
    *)
      if [[ -z "$SLUG_ARG" ]]; then
        SLUG_ARG="$1"
      else
        echo "Unexpected extra argument: $1" >&2
        exit 1
      fi
      shift
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

[[ -n "$SLUG_ARG" ]] || fail "no target: pass a <slug>"
SLUG="$SLUG_ARG"

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail "invalid --timeout: '$TIMEOUT' (must be a non-negative integer)"
fi
if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
  fail "invalid --ttl: '$TTL' (must be a non-negative integer)"
fi
if [[ $SINCE_SET -eq 1 ]]; then
  case "$SINCE" in
    ''|*[!0-9]*) fail "invalid --since: '$SINCE' (must be a non-negative byte offset)" ;;
  esac
fi
if [[ $REQUEST_ID_SET -eq 1 && -z "$REQUEST_ID" ]]; then
  fail "invalid --request-id: value must be non-empty"
fi

# --- Validate --until against the writer's vocabulary; build the until-set ---
[[ -n "${UNTIL// }" ]] || fail "empty --until: pass at least one event name"
UNTIL_TOKENS=()
IFS=',' read -r -a _until_raw <<< "$UNTIL"
for tok in "${_until_raw[@]}"; do
  tok="${tok// }"   # tolerate incidental spaces around the commas
  [[ -n "$tok" ]] || continue
  ok=0
  for v in $SESSION_EVENT_VOCAB; do
    if [[ "$tok" == "$v" ]]; then ok=1; break; fi
  done
  [[ $ok -eq 1 ]] || fail "invalid --until event: '$tok' (not in the session event vocabulary)"
  UNTIL_TOKENS+=("$tok")
done
[[ ${#UNTIL_TOKENS[@]} -gt 0 ]] || fail "empty --until: pass at least one event name"

# --- Session-gone applies only to session-lifetime watches (see PRESPAWN_EVENTS) ---
LIVENESS_ENABLED=1
for tok in "${UNTIL_TOKENS[@]}"; do
  for p in $PRESPAWN_EVENTS; do
    if [[ "$tok" == "$p" ]]; then LIVENESS_ENABLED=0; break 2; fi
  done
done

# --- Resolve store ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

SESSIONS_DIR="$KNOWLEDGE_DIR/_sessions"
EVENTS_SH="$SCRIPT_DIR/session-events.sh"

# --until rendered as a JSON array — reused for matching and the --json terminal.
UNTIL_JSON="$(printf '%s\n' "${UNTIL_TOKENS[@]}" | jq -R . | jq -s -c .)"

# One incremental read from the given cursor. Composing the reference reader means
# torn-row, interior-malformed, and past-EOF-reset tolerance are inherited, not
# re-derived here. Echoes the reader's {events, next_cursor} object.
read_from() {
  bash "$EVENTS_SH" --json --since "$1" --kdir "$KNOWLEDGE_DIR"
}

# First event in a read whose slug equals SLUG exactly, whose event is in the
# until-set, and whose request_id equals REQUEST_ID when the caller supplied that
# guard; or empty output. jq string equality — never substring or inferred guard.
first_match() {
  printf '%s' "$1" | jq -c --arg slug "$SLUG" --argjson until "$UNTIL_JSON" \
    --arg request_id "$REQUEST_ID" --argjson request_id_set "$REQUEST_ID_SET" \
    'first(.events[] | select(
      .slug == $slug
      and (.event as $e | $until | index($e))
      and ($request_id_set == 0 or .request_id? == $request_id)
    ))' 2>/dev/null || true
}

emit_matched() {
  local row="$1" cursor="$2"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n --argjson matched "$row" --argjson nc "$cursor" \
      --arg slug "$SLUG" --argjson until "$UNTIL_JSON" \
      '{outcome: "matched", matched: $matched, next_cursor: $nc, slug: $slug, until: $until}')"
  fi
  printf '%s\n' "$row"
  jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  exit 0
}

# Non-zero terminals (timeout, session-gone) print their JSON manually: json_output
# hard-exits 0, which would erase the composed exit code.
emit_terminal() {
  local outcome="$1" cursor="$2" code="$3" diag="$4"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$(jq -n --arg outcome "$outcome" --argjson nc "$cursor" \
      --arg slug "$SLUG" --argjson until "$UNTIL_JSON" \
      '{outcome: $outcome, matched: null, next_cursor: $nc, slug: $slug, until: $until}')"
  else
    jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi
  echo "$diag" >&2
  exit "$code"
}

# --- Baseline: default to the journal's current end ("wake on what happens next") ---
if [[ $SINCE_SET -eq 1 ]]; then
  CURSOR="$SINCE"
else
  CURSOR="$(bash "$EVENTS_SH" --cursor-only --kdir "$KNOWLEDGE_DIR")"
fi

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESULT="$(read_from "$CURSOR")" || fail "session-events read failed"
  MATCH="$(first_match "$RESULT")"
  if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
    NC="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
    emit_matched "$MATCH" "$NC"
  fi
  CURSOR="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"

  if [[ $LIVENESS_ENABLED -eq 1 ]]; then
    OWNER="$(resolve_session_owner "$SESSIONS_DIR/instances" "$SLUG" "$TTL")"
    if [[ -z "$OWNER" ]]; then
      # Registry removal precedes the terminal journal append during teardown.
      # Liveness is therefore only a hint: give the authoritative journal one
      # short grace, then read exactly once more before declaring session-gone.
      sleep "$SESSION_GONE_GRACE_SECONDS"
      RESULT="$(read_from "$CURSOR")" || fail "session-events read failed"
      MATCH="$(first_match "$RESULT")"
      NC="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
      if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
        emit_matched "$MATCH" "$NC"
      fi
      emit_terminal "session_gone" "$NC" 3 \
        "[session] no live instance hosts '$SLUG' and no matching event arrived; session gone (re-armable from cursor $NC)"
    fi
  fi

  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 1
done

emit_terminal "timeout" "$CURSOR" 2 \
  "[session] timed out after ${TIMEOUT}s waiting for [$UNTIL] on '$SLUG' (re-arm with --since $CURSOR)"
