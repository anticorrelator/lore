#!/usr/bin/env bash
# session-events.sh — Read _sessions/events.jsonl from an opaque byte-offset cursor
#
# Usage:
#   lore session events [--since <cursor>] [--kdir <path>] [--json]
#
# Options:
#   --since <cursor>  Byte offset to resume from (default: 0). Treated as an
#                     OPAQUE token — consumers store and echo the reported
#                     next_cursor, never compute with it.
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit {events: [...], next_cursor: N}. Default plain output is
#                     NDJSON rows on stdout and a `next_cursor:` line on stderr so
#                     stdout stays machine-consumable.
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
# Exit codes: 0 success; 1 error. Codes 2 and 3 are reserved (unused here) for
# session verb family / composed-terminal-verb namespace compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=0
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-events.sh [--since <cursor>] [--kdir <path>] [--json]" >&2
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

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"

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

# Plain: NDJSON rows on stdout; next_cursor on stderr so stdout stays consumable.
printf '%s' "$RESULT" | jq -c '.events[]'
NEXT_CURSOR="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
echo "next_cursor: $NEXT_CURSOR" >&2
