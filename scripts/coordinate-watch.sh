#!/usr/bin/env bash
# coordinate-watch.sh — Sleep until anything on the coordination board needs you.
#
# This is the board-scoped counterpart to `lore session wait`. Wait watches one
# session, so N live sessions cost N watchers, N hand-composed stop sets, and N
# cursors to carry between wakes. Watch takes no arguments at all: it follows the
# whole session journal from a cursor it manages itself and returns on the first
# row — any session, any slug — that a coordinator can act on. Re-arming after a
# wake is the same zero-argument call.
#
# Usage:
#   lore coordinate watch [--until <events>] [--since <cursor>]
#                         [--timeout <sec>] [--pending-stale <sec>]
#                         [--kdir <path>] [--json]
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
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit one result object instead of plain rows (see below).
#
# The cursor:
#   Persisted at $KNOWLEDGE_DIR/_coordination/watch-cursor.json as
#   {schema_version, cursor, updated_at}, rewritten on every exit that reached the
#   journal — match, advisory, timeout, reader failure. That is what makes the
#   re-arm zero-argument: the next call resumes exactly where this one stopped, so
#   no row is replayed and none is skipped. The first-ever run has no file and
#   baselines at the journal's current end ("wake on what happens next"), which
#   means it will not replay history the board has already dealt with.
#
#   On a match the cursor is the boundary immediately after the matched row, not
#   the end of the read that found it. One read can carry several actionable
#   rows; only the first is handed to the caller, so persisting the read's end
#   would drop the rest permanently. The no-match exits (advisory, timeout,
#   reader failure) withhold nothing, so they carry the read's end cursor.
#
# Output (plain): the matched event row, then a final {"next_cursor": N} row.
#   A pending-staleness wake emits an advisory row instead of an event row.
#   Timeout emits only the cursor row, with a diagnostic on stderr. Every row is
#   JSON on stdout; tell them apart by shape — has("event"), has("advisory"),
#   has("next_cursor").
#
# Output (--json): one object, mirroring `session wait`'s matched shape:
#   {outcome, matched, next_cursor, until} plus {pending} on a staleness wake.
#   There is no `slug` field: the watch is board-scoped, so session identity lives
#   on the matched row itself rather than on the watch.
#
# Exit codes (local to this verb):
#   0  a matching row landed, or a stale pending request was found
#   1  error (bad args, unknown --until event, missing store)
#   2  timed out with nothing to report — the ordinary re-arm branch, not a
#      failure: just call the verb again
#   4  internal error: the reference reader failed on all three attempts
#
# This verb only reads the journal. It never appends to it — the journal keeps
# exactly one writer (session-event-append.sh), and a pending-staleness wake is
# an advisory printed to the caller, not a row anybody else can later read back.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

UNTIL="${SESSION_ACTIONABLE_EVENTS// /,}"
SINCE=""
SINCE_SET=0
TIMEOUT=3600
PENDING_STALE=300
KDIR_OVERRIDE=""
JSON_MODE=0
CURSOR_SCHEMA_VERSION=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --until) UNTIL="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; SINCE_SET=1; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --pending-stale) PENDING_STALE="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,71p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-watch.sh [--until <events>] [--since <cursor>] [--timeout <sec>] [--pending-stale <sec>] [--kdir <path>] [--json]" >&2
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

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  fail "invalid --timeout: '$TIMEOUT' (must be a non-negative integer)"
fi
if ! [[ "$PENDING_STALE" =~ ^[0-9]+$ ]]; then
  fail "invalid --pending-stale: '$PENDING_STALE' (must be a non-negative integer; 0 disables)"
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
EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"
PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
# The cursor sits at the top of _coordination/, deliberately outside the journal
# and outside the worktree manager's registry — every directory under there has a
# sole writer that would not expect a second file appearing in it.
CURSOR_DIR="$KNOWLEDGE_DIR/_coordination"
CURSOR_FILE="$CURSOR_DIR/watch-cursor.json"

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
  mkdir -p "$CURSOR_DIR"
  tmp="$(mktemp "$CURSOR_DIR/.tmp.watch-cursor.XXXXXX")" || return 0
  if jq -n --argjson v "$CURSOR_SCHEMA_VERSION" --argjson c "$cursor" \
    --arg at "$(timestamp_iso)" \
    '{schema_version: $v, cursor: $c, updated_at: $at}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CURSOR_FILE"
  else
    rm -f "$tmp"
  fi
}

# --- Terminals ---------------------------------------------------------------

emit_matched() {
  local row="$1" cursor="$2"
  write_cursor_file "$cursor"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n --argjson matched "$row" --argjson nc "$cursor" \
      --argjson until "$UNTIL_JSON" \
      '{outcome: "matched", matched: $matched, next_cursor: $nc, until: $until}')"
  fi
  printf '%s\n' "$row"
  jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  exit 0
}

emit_pending_stale() {
  local pending="$1" cursor="$2"
  write_cursor_file "$cursor"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n --argjson pending "$pending" --argjson nc "$cursor" \
      --argjson until "$UNTIL_JSON" \
      '{outcome: "pending_stale", matched: null, pending: $pending, next_cursor: $nc, until: $until}')"
  fi
  jq -cn --argjson pending "$pending" \
    '{advisory: "pending_stale", requests: $pending}'
  jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  echo "[coordinate] $(printf '%s' "$pending" | jq -r 'length') pending spawn request(s) unclaimed past ${PENDING_STALE}s; an unclaimed request never reaches the journal, so nothing else will report it" >&2
  exit 0
}

# Non-zero terminals print their JSON by hand: json_output hard-exits 0, which
# would erase the composed exit code.
emit_timeout() {
  local cursor="$1"
  write_cursor_file "$cursor"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$(jq -n --argjson nc "$cursor" --argjson until "$UNTIL_JSON" \
      '{outcome: "timeout", matched: null, next_cursor: $nc, until: $until}')"
  else
    jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi
  echo "[coordinate] nothing actionable on the board after ${TIMEOUT}s (cursor $cursor persisted; re-arm with a plain \`lore coordinate watch\`)" >&2
  exit 2
}

emit_internal_error() {
  local cursor="$1"
  [[ "$cursor" == "null" ]] || write_cursor_file "$cursor"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$(jq -n --argjson nc "$cursor" --argjson until "$UNTIL_JSON" \
      '{outcome: "internal_error", matched: null, next_cursor: $nc, until: $until}')"
  elif [[ "$cursor" != "null" ]]; then
    jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi
  echo "[coordinate] internal error: session-events failed after 3 attempts; fix the reader dependency and retry" >&2
  exit 4
}

# --- Readers -----------------------------------------------------------------

# First row in the until-set, whatever session it belongs to, paired with the
# cursor the reader assigned to that row's end. No slug filter: board scope is
# the whole point of this verb.
#
# The pairing is the point: one read can contain several actionable rows, and a
# match that reported the batch's end cursor would persist a position past the
# rows it never handed over — they would be skipped forever, since the next
# zero-argument call resumes from that cursor. The reader owns each row's byte
# boundary in `.records`, the same boundaries `session wait` follows in follow
# mode; this verb only applies the until-set filter.
first_match_record() {
  printf '%s' "$1" | jq -c --argjson until "$UNTIL_JSON" \
    'first(.records[] | select(.event.event as $e | $until | index($e)))' 2>/dev/null || true
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

# --- Baseline: explicit --since, else the persisted cursor, else journal end ---
if [[ $SINCE_SET -eq 1 ]]; then
  CURSOR="$SINCE"
elif CURSOR="$(read_cursor_file)"; then
  :
else
  # First-ever run on this store: start at the end so the very first watch does
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

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESULT="$(session_events_read "$EVENTS_SH" "$KNOWLEDGE_DIR" "$CURSOR")" || emit_internal_error "$CURSOR"
  RECORD="$(first_match_record "$RESULT")"
  NEXT="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
  if [[ -n "$RECORD" && "$RECORD" != "null" ]]; then
    emit_matched \
      "$(printf '%s' "$RECORD" | jq -c '.event')" \
      "$(printf '%s' "$RECORD" | jq -r '.next_cursor')"
  fi
  # No match: nothing was withheld from the caller, so the batch cursor is the
  # row after the last row this read consumed, and advancing to it is correct.
  CURSOR="$NEXT"

  # A journal row always wins: it is the real event, and the pending check is
  # only there for the case where no row will ever come.
  if [[ "$PENDING_STALE" -gt 0 ]]; then
    PENDING="$(stale_pending)"
    if [[ "$(printf '%s' "$PENDING" | jq -r 'length')" -gt 0 ]]; then
      emit_pending_stale "$PENDING" "$CURSOR"
    fi
  fi

  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 1
done

emit_timeout "$CURSOR"
