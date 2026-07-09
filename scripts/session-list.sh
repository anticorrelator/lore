#!/usr/bin/env bash
# session-list.sh — Render the live session substrate: instances + queues
#
# Usage:
#   lore session list [--ttl <seconds>] [--kdir <path>] [--json]
#
# Options:
#   --ttl <seconds>   Instance liveness TTL (default: 30, matching the heartbeat contract).
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit a JSON object {instances, pending, claimed, close_requests}.
#
# Prepare-and-return reader. Registry instances are filtered to the live set by
# file mtime within the TTL (a hard-killed TUI leaves a stale file that ages out);
# the pending, claimed, and close-request queues are listed in full. A malformed
# or torn row is excluded with a stderr warning and never rewritten (reader
# contract) — validation is the writer's job, paid once at write time.
#
# In the human summary a slugless session renders as chat:<8-hex-of-session_id>
# (chat:? when it carries no session_id) instead of a blank slug, so no live
# hosted session is invisible; that short id is what `session close --session`
# accepts. The --json envelope is unchanged (raw registry rows).
#
# Exit codes: 0 success; 1 error. Codes 2 and 3 are reserved (unused here) for
# session verb family / composed-terminal-verb namespace compatibility.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TTL=30
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl) TTL="$2"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: session-list.sh [--ttl <seconds>] [--kdir <path>] [--json]" >&2
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

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

SESSIONS_DIR="$KNOWLEDGE_DIR/_sessions"

# One parse produces the full envelope; warnings for excluded rows go to stderr.
RESULT="$(python3 - "$SESSIONS_DIR" "$TTL" <<'PYEOF'
import json, os, sys, time

sessions_dir = sys.argv[1]
ttl = float(sys.argv[2])
now = time.time()


def load_dir(subpath, live_only=False):
    """Load every *.json row under sessions_dir/subpath.

    Excludes torn/malformed rows with a stderr warning (reader contract). When
    live_only, drops files whose mtime is older than the TTL (stale instances).
    """
    d = os.path.join(sessions_dir, subpath)
    rows = []
    if not os.path.isdir(d):
        return rows
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        if live_only and (now - mtime) > ttl:
            continue
        try:
            with open(path) as f:
                row = json.load(f)
        except (OSError, ValueError) as exc:
            sys.stderr.write(
                f"[session] warning: {subpath}/{name} corrupt — {exc}; excluded\n"
            )
            continue
        rows.append(row)
    return rows


envelope = {
    "fold_version": "1",
    "vocabulary_version": "1",
    "instances": load_dir("instances", live_only=True),
    "pending": load_dir("requests/pending"),
    "claimed": load_dir("requests/claimed"),
    "close_requests": load_dir("close-requests"),
}
print(json.dumps(envelope))
PYEOF
)"

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$RESULT"
fi

# --- Human summary ---
INSTANCE_COUNT="$(printf '%s' "$RESULT" | jq -r '.instances | length')"
PENDING_COUNT="$(printf '%s' "$RESULT" | jq -r '.pending | length')"
CLAIMED_COUNT="$(printf '%s' "$RESULT" | jq -r '.claimed | length')"
CLOSE_COUNT="$(printf '%s' "$RESULT" | jq -r '.close_requests | length')"

echo "[session] Live instances: $INSTANCE_COUNT | pending: $PENDING_COUNT | claimed: $CLAIMED_COUNT | close-requests: $CLOSE_COUNT"

if [[ "$INSTANCE_COUNT" -gt 0 ]]; then
  # Vintage column: prefer the embedded build SHA (release build), fall back to
  # the build_time timestamp (dev/go-run binary mtime), else "unknown" for a row
  # written by a binary predating the field. build_time appended in parens when a
  # SHA is present so a coordinator sees both identity and age.
  # A slugless session (chat/work session with no work-item slug) has an empty
  # slug, so listing raw slugs renders it invisibly as a blank in the joined
  # column. Render it instead as chat:<8-hex-of-session_id> — the same short id
  # `lore session close --session <id>` accepts, so a coordinator can copy it
  # straight from this line to tear the session down. A slugless session that
  # also carries no session_id (older row / non-id-binding harness) has nothing
  # targetable to show and renders chat:? — visible, honestly un-addressable.
  printf '%s' "$RESULT" | jq -r '
    .instances[]
    | (if .build_sha then .build_sha + (if .build_time then " (" + .build_time + ")" else "" end)
       elif .build_time then .build_time
       else "unknown" end) as $vintage
    | ([.sessions[]?
        | if (.slug // "") != "" then .slug
          else "chat:" + ((.session_id // "") | if . == "" then "?" else .[0:8] end)
          end]
       | join(", ")) as $sessions
    | "  instance \(.name) (pid \(.pid)) — vintage \($vintage) — sessions: \(if $sessions == "" then "none" else $sessions end)"'
fi
if [[ "$PENDING_COUNT" -gt 0 ]]; then
  printf '%s' "$RESULT" | jq -r '.pending[] | "  pending \(.request_id) \(.type) \(.slug // "(no slug)") → \(.target_instance // "any")\(if .min_vintage then " (min-vintage \(.min_vintage))" else "" end)"'
fi
if [[ "$CLAIMED_COUNT" -gt 0 ]]; then
  printf '%s' "$RESULT" | jq -r '.claimed[] | "  claimed \(.request_id) by \(.claimed_by // "?")"'
fi
if [[ "$CLOSE_COUNT" -gt 0 ]]; then
  printf '%s' "$RESULT" | jq -r '.close_requests[] | "  close-request \(.request_id) \(.slug // "(no slug)") → \(.target_instance // "?") (\(.reason))"'
fi
