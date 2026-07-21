#!/usr/bin/env bash
# session-wait.sh — Block until a session-journal event lands, then hand back a
# resume cursor. This is the blocking front on the events journal: it polls
# session-events.sh (the reference reader) from a cursor and wakes the moment a
# matching row appears, so the harness can re-invoke a coordinator on session
# activity instead of the coordinator hand-rolling a sleep loop.
#
# Usage:
#   lore session wait (<slug> | --work-item <base-slug>)
#                            [--until <events>] [--since <cursor>]
#                            [--request-id <id>] [--follow] [--next-session]
#                            [--timeout <sec>] [--ttl <sec>]
#                            [--kdir <path>] [--json]
#
# Options:
#   --until <events>  Comma-separated event names to wake on (default:
#                     closed,close_failed,orphaned — terminal close/recovery outcomes
#                     teardown can end in either). Each name is checked against the
#                     journal's event vocabulary up front; a name that is not in it
#                     is a usage error, not a wait that never ends.
#                     `step_completed` is an explicit progress wake: inspect the
#                     matched row's step_id and step_label before acting. It is not
#                     part of the default teardown set and does not mean the whole
#                     protocol reached terminus.
#   --since <cursor>  Byte-offset cursor to start reading from. Omit to start at
#                     the journal's current end ("wake on what happens next").
#                     Treat the value as opaque — pass back a cursor this verb or
#                     `session events` reported, never one you computed.
#   --request-id <id> Also require an exact request_id match. Use this when a slug
#                     can be reused across sessions so a late `closed` row from
#                     the prior session cannot satisfy the new wait. The guard
#                     applies to `closed` only; a target-matched `close_failed`
#                     remains a deliberately sloppy wake for an exact re-read.
#   --work-item <slug> Match the base slug and canonical derived worker slugs
#                     `<slug>--w<n>`. This is an alternative to positional slug.
#   --follow          Emit every target row and stop after emitting the first
#                     event in --until. Without it, wait remains one-shot.
#   --next-session    Follow-only exact-slug mode: ignore the predecessor and
#                     bind the first future request identity before emitting.
#   --timeout <sec>   How long to wait before giving up (default: 3600).
#   --ttl <sec>       Liveness window for the owning-instance check (default: 30).
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit one result object instead of plain rows (see below).
#
# Positional slug matching is exact. Work-item matching accepts only the exact base
# or its canonical `<base>--w<n>` worker form. When --request-id is supplied it
# narrows `closed` rows only; other requested events remain loose wake edges.
#
# Output (plain):
#   On a match: the matched event row, then a final {"next_cursor": N} row — both
#   on stdout, in one read. On timeout or session-gone: just the {"next_cursor": N}
#   row on stdout, with a one-line diagnostic on stderr. Every non-error exit hands
#   back the cursor so the caller can re-arm with --since <that cursor> — no journal
#   replay, and it never re-matches the row it just consumed.
#
# Output (--json): one-shot emits one object
#   {outcome, matched, next_cursor, slug, until}. Follow emits one NDJSON matched
#   object per target row, with terminal=true on the --until stop row; timeout,
#   session-gone, and internal-error append the existing terminal-shaped object.
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
#   4  internal error: the reference reader failed on all three attempts. This is
#      distinct from timeout 2; retry the operation after fixing the dependency.
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
WORK_ITEM=""
WORK_ITEM_SET=0
UNTIL="closed,close_failed,orphaned"
SINCE=""
SINCE_SET=0
TIMEOUT=3600
TTL=30
SESSION_GONE_GRACE_SECONDS=2
KDIR_OVERRIDE=""
JSON_MODE=0
REQUEST_ID=""
REQUEST_ID_SET=0
FOLLOW=0
NEXT_SESSION=0
EVENTS_RETRY_DELAYS=(1 2)

# Mirror of the sole writer's event vocabulary (session-event-append.sh's
# validation case-arm). tests/session-verbs.bats cross-checks this list against
# the writer and names any drift; if that test fails, reconcile this line with the
# writer rather than silencing the test.
SESSION_EVENT_VOCAB="requested claimed spawned needs_input quiescent resumed recovered closed orphaned step_completed terminus_reached harness_turn_ended spawn_failed request_reclaimed request_abandoned request_cancelled close_requested close_failed restore_refused worktree_quarantined send_requested sent send_refused answer_requested answered answer_refused modal_blocked review_flagged review_held review_notified review_released"

# Waiting on any of these queue/pre-spawn events means an unhosted slug is the
# normal starting state, so the session-gone (liveness) exit is disabled for them —
# timeout is the only bound.
PRESPAWN_EVENTS="requested claimed spawned spawn_failed request_reclaimed request_abandoned request_cancelled"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --until) UNTIL="$2"; shift 2 ;;
    --since) SINCE="$2"; SINCE_SET=1; shift 2 ;;
    --request-id) REQUEST_ID="$2"; REQUEST_ID_SET=1; shift 2 ;;
    --work-item) WORK_ITEM="$2"; WORK_ITEM_SET=1; shift 2 ;;
    --follow) FOLLOW=1; shift ;;
    --next-session) NEXT_SESSION=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,72p' "$0"; exit 0 ;;
    --*)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-wait.sh (<slug> | --work-item <base-slug>) [--until <events>] [--since <cursor>] [--request-id <id>] [--follow] [--next-session] [--timeout <sec>] [--ttl <sec>] [--kdir <path>] [--json]" >&2
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

if [[ -n "$SLUG_ARG" && $WORK_ITEM_SET -eq 1 ]]; then
  fail "multiple targets: pass either a positional <slug> or --work-item, not both"
fi
if [[ -z "$SLUG_ARG" && $WORK_ITEM_SET -eq 0 ]]; then
  fail "no target: pass a positional <slug> or --work-item <base-slug>"
fi
if [[ $WORK_ITEM_SET -eq 1 && -z "$WORK_ITEM" ]]; then
  fail "invalid --work-item: value must be non-empty"
fi
SLUG="${WORK_ITEM:-$SLUG_ARG}"

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
if [[ $NEXT_SESSION -eq 1 ]]; then
  [[ $FOLLOW -eq 1 ]] || fail "--next-session requires --follow"
  [[ $WORK_ITEM_SET -eq 0 ]] || fail "--next-session requires an exact positional slug, not --work-item"
  [[ $REQUEST_ID_SET -eq 0 ]] || fail "--next-session binds the successor request ID; do not pass --request-id"
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
if [[ $NEXT_SESSION -eq 1 ]]; then
  LIVENESS_ENABLED=0
fi

# --- Resolve store ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

SESSIONS_DIR="$KNOWLEDGE_DIR/_sessions"
EVENTS_SH="$SCRIPT_DIR/session-events.sh"
EVENTS_FILE="$SESSIONS_DIR/events.jsonl"

# A supplied cursor is a row boundary, not an arbitrary byte offset. Reject an
# interior offset here so the tolerant reference reader never mistakes a valid
# row suffix for corrupt JSON. Past-EOF retains the reader's reset behavior.
if [[ $SINCE_SET -eq 1 && "$SINCE" -gt 0 ]]; then
  ALIGNMENT_STATUS=0
  python3 - "$EVENTS_FILE" "$SINCE" <<'PYEOF' || ALIGNMENT_STATUS=$?
import os, sys

path, cursor = sys.argv[1], int(sys.argv[2])
try:
    size = os.path.getsize(path)
except FileNotFoundError:
    size = 0
if cursor <= size:
    with open(path, "rb") as f:
        f.seek(cursor - 1)
        if f.read(1) != b"\n":
            raise SystemExit(2)
PYEOF
  case "$ALIGNMENT_STATUS" in
    0) ;;
    2) fail "invalid --since cursor $SINCE: cursor-not-row-aligned (preceding byte is not newline); reuse a next_cursor emitted by lore session events or lore session wait" ;;
    *) fail "could not validate --since cursor $SINCE" ;;
  esac
fi

# --until rendered as a JSON array — reused for matching and the --json terminal.
UNTIL_JSON="$(printf '%s\n' "${UNTIL_TOKENS[@]}" | jq -R . | jq -s -c .)"

# One incremental read from the given cursor. Composing the reference reader means
# torn-row, interior-malformed, and past-EOF-reset tolerance are inherited, not
# re-derived here. Echoes the reader's {events, records, next_cursor} object.
# Run the reference reader at most three times. The fixed 1s/2s backoff is
# intentionally bounded: this remains a caller-owned wait, not a supervisor.
run_events() {
  local output attempt
  for attempt in 0 1 2; do
    if output="$(bash "$EVENTS_SH" "$@")"; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ $attempt -lt 2 ]]; then
      sleep "${EVENTS_RETRY_DELAYS[$attempt]}"
    fi
  done
  return 1
}

read_from() {
  run_events --json --since "$1" --kdir "$KNOWLEDGE_DIR"
}

# First target-matched event in the until-set. Positional targets are exact;
# work-item targets admit only the base and canonical worker suffix. A supplied
# request ID narrows `closed` only; other requested outcomes remain loose wakes.
first_match() {
  printf '%s' "$1" | jq -c --arg slug "$SLUG" --argjson until "$UNTIL_JSON" \
    --arg request_id "$REQUEST_ID" --argjson request_id_set "$REQUEST_ID_SET" \
    --argjson work_item_set "$WORK_ITEM_SET" \
    'def target_matches:
      . == $slug or (
        $work_item_set == 1
        and startswith($slug + "--w")
        and (.[($slug | length) + 3:] | test("^[0-9]+$"))
      );
    first(.events[] | select(
      (.slug | target_matches)
      and (.event as $e | $until | index($e))
      and ($request_id_set == 0 or .event != "closed" or .request_id? == $request_id)
    ))' 2>/dev/null || true
}

# Ordered target-scoped reader records for follow mode. The reader owns each
# row's byte boundary; this verb only applies target and request filters.
follow_records() {
  printf '%s' "$1" | jq -c --arg slug "$SLUG" \
    --arg request_id "$REQUEST_ID" --argjson request_id_set "$REQUEST_ID_SET" \
    --argjson work_item_set "$WORK_ITEM_SET" \
    'def target_matches:
      . == $slug or (
        $work_item_set == 1
        and startswith($slug + "--w")
        and (.[($slug | length) + 3:] | test("^[0-9]+$"))
      );
    .records[] | select(
      (.event.slug | target_matches)
      and ($request_id_set == 0 or .event.event != "closed" or .event.request_id? == $request_id)
    )'
}

event_in_until() {
  local event="$1" tok
  for tok in "${UNTIL_TOKENS[@]}"; do
    [[ "$event" == "$tok" ]] && return 0
  done
  return 1
}

emit_follow_record() {
  local row="$1" cursor="$2" terminal="$3"
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -cn --argjson matched "$row" --argjson nc "$cursor" \
      --arg slug "$SLUG" --argjson until "$UNTIL_JSON" --argjson terminal "$terminal" \
      '{outcome: "matched", matched: $matched, next_cursor: $nc, slug: $slug, until: $until, terminal: $terminal}'
  else
    printf '%s\n' "$row"
    jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi
}

process_follow_result() {
  local result="$1" record row row_cursor event row_request_id terminal
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    row="$(printf '%s' "$record" | jq -c '.event')"
    row_cursor="$(printf '%s' "$record" | jq -r '.next_cursor')"
    event="$(printf '%s' "$row" | jq -r '.event')"

    if [[ $NEXT_SESSION -eq 1 ]]; then
      row_request_id="$(printf '%s' "$row" | jq -r '.request_id? // empty')"
      if [[ $NEXT_BOUND -eq 0 ]]; then
        case "$event" in
          requested|claimed|spawned|spawn_failed)
            [[ -n "$row_request_id" ]] || continue
            NEXT_BOUND=1
            BOUND_REQUEST_ID="$row_request_id"
            ;;
          *) continue ;;
        esac
      fi

      case "$event" in
        requested|claimed|spawned|spawn_failed|request_reclaimed|request_abandoned|request_cancelled|closed)
          [[ "$row_request_id" == "$BOUND_REQUEST_ID" ]] || continue
          ;;
      esac

      [[ "$event" == "claimed" ]] && BOUND_CLAIM_SEEN=1
      if [[ "$event" == "spawned" ]]; then
        LIVENESS_ENABLED=1
      elif [[ "$event" == "recovered" && $BOUND_CLAIM_SEEN -eq 1 ]]; then
        LIVENESS_ENABLED=1
      fi

      if [[ "$event" == "request_abandoned" || "$event" == "request_cancelled" ]]; then
        emit_follow_record "$row" "$row_cursor" false
        emit_terminal "session_gone" "$row_cursor" 3 \
          "[session] successor request '$BOUND_REQUEST_ID' ended with $event; session gone (re-armable from cursor $row_cursor)"
      fi
    fi

    terminal=false
    if event_in_until "$event"; then
      terminal=true
    fi
    if [[ $NEXT_SESSION -eq 1 && ( "$event" == "spawn_failed" || "$event" == "request_reclaimed" ) ]]; then
      terminal=false
    fi
    emit_follow_record "$row" "$row_cursor" "$terminal"
    [[ "$terminal" == true ]] && exit 0
  done < <(follow_records "$result")
}

# Echo one live owner for the active target mode. Work-item mode deliberately
# mirrors target_matches so a live derived worker suppresses session-gone.
resolve_target_owner() {
  if [[ $WORK_ITEM_SET -eq 0 ]]; then
    resolve_session_owner "$SESSIONS_DIR/instances" "$SLUG" "$TTL"
    return
  fi
  python3 - "$SESSIONS_DIR/instances" "$SLUG" "$TTL" <<'PYEOF'
import json, os, re, sys, time

instances_dir, base, ttl = sys.argv[1], sys.argv[2], float(sys.argv[3])
worker = re.compile(re.escape(base) + r"--w[0-9]+\Z")
now = time.time()
if os.path.isdir(instances_dir):
    for name in sorted(os.listdir(instances_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(instances_dir, name)
        try:
            if now - os.path.getmtime(path) > ttl:
                continue
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError):
            continue
        if any((s.get("slug") == base or worker.fullmatch(s.get("slug") or ""))
               for s in row.get("sessions") or []):
            print(row.get("name", ""))
            raise SystemExit(0)
PYEOF
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

emit_internal_error() {
  local cursor="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$(jq -n --argjson nc "$cursor" --arg slug "$SLUG" \
      --argjson until "$UNTIL_JSON" \
      '{outcome: "internal_error", matched: null, next_cursor: $nc, slug: $slug, until: $until}')"
  elif [[ "$cursor" != "null" ]]; then
    jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi
  echo "[session] internal error: session-events failed after 3 attempts; fix the reader dependency and retry" >&2
  exit 4
}

# --- Baseline: default to the journal's current end ("wake on what happens next") ---
if [[ $SINCE_SET -eq 1 ]]; then
  CURSOR="$SINCE"
else
  CURSOR="$(run_events --cursor-only --kdir "$KNOWLEDGE_DIR")" || emit_internal_error null
fi

NEXT_BOUND=0
BOUND_REQUEST_ID=""
BOUND_CLAIM_SEEN=0

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESULT="$(read_from "$CURSOR")" || emit_internal_error "$CURSOR"
  if [[ $FOLLOW -eq 0 ]]; then
    MATCH="$(first_match "$RESULT")"
    if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
      NC="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
      emit_matched "$MATCH" "$NC"
    fi
  else
    process_follow_result "$RESULT"
  fi
  CURSOR="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"

  if [[ $LIVENESS_ENABLED -eq 1 ]]; then
    OWNER="$(resolve_target_owner)"
    if [[ -z "$OWNER" ]]; then
      # Registry removal precedes the terminal journal append during teardown.
      # Liveness is therefore only a hint: give the authoritative journal one
      # short grace, then read exactly once more before declaring session-gone.
      sleep "$SESSION_GONE_GRACE_SECONDS"
      RESULT="$(read_from "$CURSOR")" || emit_internal_error "$CURSOR"
      if [[ $FOLLOW -eq 0 ]]; then
        MATCH="$(first_match "$RESULT")"
        NC="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
        if [[ -n "$MATCH" && "$MATCH" != "null" ]]; then
          emit_matched "$MATCH" "$NC"
        fi
      else
        process_follow_result "$RESULT"
        NC="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
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
