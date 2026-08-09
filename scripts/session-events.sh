#!/usr/bin/env bash
# session-events.sh — Read _sessions/events.jsonl from an opaque byte-offset cursor
#
# Usage:
#   lore session events [--since <cursor>] [--tail <N>] [--window-start <RFC3339> --window-end <RFC3339>] [--cursor-only] [--kdir <path>] [--json]
#
# Options:
#   --since <cursor>  Byte offset to resume from (default: 0). Treated as an
#                     OPAQUE token — consumers store and echo the reported
#                     next_cursor, never compute with it.
#   --tail <N>        Emit only the last N event rows (plus the cursor row) instead
#                     of every row from the cursor — a baseline snapshot without a
#                     hand-rolled `| tail -N`. Plain mode only.
#   --cursor-only     Print just the current end-of-journal byte offset and exit —
#                     an O(1) stat, no rows replayed. Use it to capture a baseline
#                     cursor before acting (e.g. close-then-wait teardown). The
#                     answer does not depend on --since, so this mode consumes no
#                     cursor and runs none of the cursor checks below.
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit {events: [...], records: [...], next_cursor: N} on
#                     stdout. Each records entry pairs an event with the cursor
#                     immediately after that row. Default plain
#                     output is one JSON value per line: the NDJSON event rows,
#                     then a final {"next_cursor": N} row — all on stdout. Consumers
#                     tell them apart by shape (has("event") vs has("next_cursor")).
#
# This is the reference reader for the cursor contract in docs/session-substrate.md:
#   - Reads rows from the given offset and always reports next_cursor, the byte
#     offset of the next unread byte.
#   - A torn/malformed trailing row stops the read at the last newline-terminated
#     valid row; the reported cursor points there.
#   - A malformed interior row is excluded with a stderr warning, never repaired.
#   - A cursor is a row boundary, not an arbitrary byte offset. An interior offset
#     is refused (`cursor-not-row-aligned`) rather than read as a row suffix, so
#     the caller's bad input is never reported as journal damage.
#   - A cursor exceeding the file size is refused (`cursor-past-eof`). The journal
#     is append-only with no rotation, so such a cursor was computed rather than
#     echoed, or was persisted against a different journal; replaying from byte
#     zero would hand back the whole journal as if it were new.
#
# The cursor is data, so it rides stdout with the rows it belongs to: a consumer
# reads the whole stream and never has to merge stderr back in to stay caught up.
#
# Exit codes: 0 success; 1 error. Codes 2 and 3 are reserved (unused here) for
# session verb family / composed-terminal-verb namespace compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=0
KDIR_OVERRIDE=""
JSON_MODE=0
CURSOR_ONLY=0
TAIL_N=""
WINDOW_START=""
WINDOW_END=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --tail) TAIL_N="$2"; shift 2 ;;
    --window-start) WINDOW_START="$2"; shift 2 ;;
    --window-end) WINDOW_END="$2"; shift 2 ;;
    --cursor-only) CURSOR_ONLY=1; shift ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-events.sh [--since <cursor>] [--tail <N>] [--cursor-only] [--kdir <path>] [--json]" >&2
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

if [[ -n "$WINDOW_START" || -n "$WINDOW_END" ]]; then
  [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || fail "--window-start and --window-end must be supplied together"
  [[ $CURSOR_ONLY -eq 0 ]] || fail "window bounds cannot be combined with --cursor-only"
fi

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

case "$SINCE" in
  ''|*[!0-9]*) fail "invalid --since: '$SINCE' (must be a non-negative byte offset)" ;;
esac

if [[ -n "$TAIL_N" ]]; then
  case "$TAIL_N" in
    ''|*[!0-9]*|0) fail "invalid --tail: '$TAIL_N' (must be a positive integer)" ;;
  esac
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"

# --cursor-only: the current end-of-journal offset is just the file size (the byte
# after the last row), so this is an O(1) stat — no read, no row replay.
if [[ $CURSOR_ONLY -eq 1 ]]; then
  if [[ -f "$EVENTS_FILE" ]]; then
    wc -c < "$EVENTS_FILE" | tr -d '[:space:]'
  else
    echo 0
  fi
  exit 0
fi

# The reader validates the cursor it is about to consume and reports the verdict
# as an exit code, so the two refusals cost no extra process in a poll loop —
# `lore coordinate watch` calls this script once a second for hours, and the
# checks need the same open file the read already needs.
CURSOR_PAST_EOF=11
CURSOR_NOT_ROW_ALIGNED=12

# The cursor reader is pure: it emits {events, next_cursor} on stdout and any
# exclusion warnings on stderr. Byte-offset arithmetic lives entirely here.
READER_STATUS=0
RESULT="$(python3 - "$EVENTS_FILE" "$SINCE" "$WINDOW_START" "$WINDOW_END" <<'PYEOF'
import json, os, sys
from datetime import datetime, timezone

events_file, since_raw, start_raw, end_raw = sys.argv[1:]
since = int(since_raw)

def parse(value):
    value = value[:-1] + "+00:00" if value.endswith("Z") else value
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        raise ValueError("timezone required")
    return dt.astimezone(timezone.utc)

start = end = None
if start_raw or end_raw:
    try:
        start, end = parse(start_raw), parse(end_raw)
    except ValueError as exc:
        raise SystemExit(f"[session] invalid window: {exc}")
    if start >= end:
        raise SystemExit("[session] window start must precede window end")

size = os.path.getsize(events_file) if os.path.exists(events_file) else 0

# The reader is deliberately tolerant of a damaged journal, which is exactly why
# it must not be tolerant of a bad cursor: once the read starts, a caller's bad
# offset is indistinguishable from a journal fact. A mid-row offset reads a valid
# row's suffix and reports it as corrupt JSON; a past-EOF offset replays the
# whole journal as if none of it had been seen. Both are refused here, at the
# only point that holds the file and the offset together.
if since > size:
    raise SystemExit(11)          # CURSOR_PAST_EOF
if since > 0:
    with open(events_file, "rb") as f:
        f.seek(since - 1)
        if f.read(1) != b"\n":
            raise SystemExit(12)  # CURSOR_NOT_ROW_ALIGNED

events = []
records = []
next_cursor = since

if size > 0 and since < size:
    with open(events_file, "rb") as f:
        base_line = f.read(since).count(b"\n")  # 0-based line count before `since`
        raw = f.read()

    # Bytes after the final newline are a torn trailing fragment: never emitted,
    # never consumed — the cursor stops before them.
    idx = 0
    pos = since
    lineno = base_line
    pending_malformed = []  # (lineno,) held until proven interior (a later valid row)
    while True:
        nl = raw.find(b"\n", idx)
        if nl == -1:
            break
        line = raw[idx:nl]
        line_end = pos + (nl - idx) + 1
        lineno += 1
        stripped = line.strip()
        if stripped == b"":
            next_cursor = line_end  # blank line consumed, no event
        else:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                # Defer: interior malformed rows warn-and-exclude once a later
                # valid row confirms them; a trailing malformed row leaves the
                # cursor at the last valid row (read stops there).
                pending_malformed.append(lineno)
            else:
                for bad in pending_malformed:
                    sys.stderr.write(
                        f"[session] warning: events.jsonl:{bad} corrupt — "
                        f"invalid JSON; excluded\n"
                    )
                pending_malformed = []
                include = start is None
                if start is not None:
                    stamp = next((obj.get(k) for k in ("timestamp", "ts", "created_at", "started_at", "completed_at") if obj.get(k)), None)
                    if isinstance(stamp, str):
                        try:
                            if start <= parse(stamp) < end:
                                include = True
                        except ValueError:
                            sys.stderr.write(f"[session] warning: events.jsonl:{lineno} invalid timestamp; excluded\n")
                if include:
                    events.append(obj)
                    records.append({"event": obj, "next_cursor": line_end})
                next_cursor = line_end
        idx = nl + 1
        pos = line_end

print(json.dumps({
    "reader_contract_version": "1",
    "projection_mode": "half-open-window" if start is not None else "cursor",
    "window": {"start": start_raw, "end": end_raw} if start is not None else None,
    "fold_version": "1",
    "vocabulary_version": "1",
    "events": events,
    "records": records,
    "next_cursor": next_cursor,
}))
PYEOF
)" || READER_STATUS=$?

# The refusal messages are composed here so --json still gets the family's error
# shape. The journal length is read only on this cold path.
case "$READER_STATUS" in
  0) ;;
  "$CURSOR_PAST_EOF")
    JOURNAL_SIZE=0
    if [[ -f "$EVENTS_FILE" ]]; then
      JOURNAL_SIZE="$(wc -c < "$EVENTS_FILE" | tr -d '[:space:]')"
    fi
    fail "invalid --since cursor $SINCE: cursor-past-eof — events.jsonl is $JOURNAL_SIZE bytes, so this cursor points past the end of the journal.
  The journal is append-only and is never compacted, truncated, or rotated, so a cursor lands here only if it was computed rather than echoed back, or if it was persisted against a different journal (a store that was reset, restored, or replaced).
  Reading from it would replay the journal from byte zero and hand back rows already seen, so it is refused rather than answered. Start again from a cursor this journal emitted: 'lore session events --cursor-only' for the current end, or --since 0 to replay it whole."
    ;;
  "$CURSOR_NOT_ROW_ALIGNED")
    fail "invalid --since cursor $SINCE: cursor-not-row-aligned (the preceding byte is not a newline, so this offset points into the middle of a row); reuse a next_cursor emitted by lore session events, lore session wait, or lore coordinate watch"
    ;;
  *) exit "$READER_STATUS" ;;
esac

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$RESULT"
fi

# Plain: one JSON value per line on stdout — the event rows, then a final
# {"next_cursor": N} row. The cursor is data, so it rides stdout with the rows;
# stdout stays NDJSON-pure and a consumer reads the whole stream in one go.
if [[ -n "$TAIL_N" ]]; then
  printf '%s' "$RESULT" | jq -c ".events[-${TAIL_N}:][]?"
else
  printf '%s' "$RESULT" | jq -c '.events[]'
fi
printf '%s' "$RESULT" | jq -c '{next_cursor: .next_cursor}'
