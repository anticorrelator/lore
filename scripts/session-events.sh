#!/usr/bin/env bash
# session-events.sh — Read _sessions/events.jsonl from an opaque byte-offset cursor
#
# Usage:
#   lore session events [--since <cursor>] [--tail <N>] [--cursor-only] [--kdir <path>] [--json]
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
#                     cursor before acting (e.g. close-then-wait teardown).
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit {events: [...], next_cursor: N} on stdout. Default plain
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
#   - A cursor exceeding the file size (only possible via external tampering)
#     resets to a full re-read with a warning.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --tail) TAIL_N="$2"; shift 2 ;;
    --cursor-only) CURSOR_ONLY=1; shift ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
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

# The cursor reader is pure: it emits {events, next_cursor} on stdout and any
# exclusion/reset warnings on stderr. Byte-offset arithmetic lives entirely here.
RESULT="$(python3 - "$EVENTS_FILE" "$SINCE" <<'PYEOF'
import json, os, sys

events_file = sys.argv[1]
since = int(sys.argv[2])

size = os.path.getsize(events_file) if os.path.exists(events_file) else 0

# A cursor past EOF is impossible without external tampering; reset to a full
# re-read rather than silently returning nothing.
if since > size:
    sys.stderr.write(
        f"[session] warning: cursor {since} exceeds events.jsonl size {size} — "
        f"resetting to full re-read\n"
    )
    since = 0

events = []
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
                events.append(obj)
                next_cursor = line_end
        idx = nl + 1
        pos = line_end

print(json.dumps({"events": events, "next_cursor": next_cursor}))
PYEOF
)"

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
