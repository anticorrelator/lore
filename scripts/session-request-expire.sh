#!/usr/bin/env bash
# session-request-expire.sh — terminalize pending spawn requests past their TTL
#
# Internal claim-side sweep. Every live TUI invokes it before its queue claim
# pass; a tiny directory lock serializes those invocations. Eligible rows move
# atomically from requests/pending/ to requests/expiring/, then receive one
# deterministic `request_expired` row through session-event-append.sh before the
# queue file is deleted. An interrupted or failed append leaves the expiring row
# for the next sweep, so removal can never outrun its journal disposition.
#
# Usage: session-request-expire.sh [--kdir <path>] [--ttl <seconds>] [--json]
# --ttl is an internal/test override. Without it the schema-declared
# coordination.session_request_ttl_seconds setting is read (default 3600).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

KDIR_OVERRIDE=""
TTL_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --ttl) TTL_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
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

if [[ -n "$TTL_OVERRIDE" ]]; then
  if ! [[ "$TTL_OVERRIDE" =~ ^[0-9]+$ ]] \
      || (( TTL_OVERRIDE < 1 || TTL_OVERRIDE > SESSION_REQUEST_TTL_MAX_SECONDS )); then
    fail "invalid --ttl '$TTL_OVERRIDE' (expected 1..${SESSION_REQUEST_TTL_MAX_SECONDS} seconds)"
  fi
  REQUEST_TTL="$TTL_OVERRIDE"
else
  REQUEST_TTL="$(session_request_ttl_seconds)"
fi

REQUESTS_DIR="$KNOWLEDGE_DIR/_sessions/requests"
PENDING_DIR="$REQUESTS_DIR/pending"
EXPIRING_DIR="$REQUESTS_DIR/expiring"
LOCK_DIR="$REQUESTS_DIR/.expiry-sweep.lock"
mkdir -p "$PENDING_DIR" "$EXPIRING_DIR"

# mkdir is the cross-platform lock primitive here. A killed sweep can leave the
# empty directory behind; after 60s another heartbeat may reclaim it. The sweep
# performs only local renames plus one short journal append per row, so a live
# holder never approaches that bound.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # This is a directory rather than a registry <name>.json row, so derive its
  # age directly with the same portable mtime primitive.
  LOCK_MTIME="$(get_mtime "$LOCK_DIR" 2>/dev/null || true)"
  NOW_EPOCH="$(date -u +%s)"
  if [[ -n "$LOCK_MTIME" ]] && (( NOW_EPOCH - LOCK_MTIME > 60 )); then
    rmdir "$LOCK_DIR" 2>/dev/null || exit 0
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

# Select solely from the durable requested_at stamp. File mtime is deliberately
# absent: retry/repair rewrites must not buy a stuck request a fresh lifetime.
while IFS= read -r pending_path; do
  [[ -n "$pending_path" ]] || continue
  base="$(basename "$pending_path")"
  [[ -e "$EXPIRING_DIR/$base" ]] && continue
  mv "$pending_path" "$EXPIRING_DIR/$base" 2>/dev/null || true
done < <(python3 - "$PENDING_DIR" "$REQUEST_TTL" <<'PYEOF'
import datetime as dt
import json
import os
import sys

pending_dir, ttl_raw = sys.argv[1:3]
ttl = int(ttl_raw)
now = dt.datetime.now(dt.timezone.utc)
for name in sorted(os.listdir(pending_dir)):
    if not name.endswith(".json"):
        continue
    path = os.path.join(pending_dir, name)
    try:
        with open(path, encoding="utf-8") as f:
            row = json.load(f)
        stamp = str(row.get("requested_at") or "")
        requested = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if requested.tzinfo is None:
            requested = requested.replace(tzinfo=dt.timezone.utc)
    except (OSError, ValueError, TypeError):
        continue
    if (now - requested).total_seconds() > ttl:
        print(path)
PYEOF
)

EXPIRED=0
for path in "$EXPIRING_DIR"/*.json; do
  [[ -f "$path" ]] || continue
  base="$(basename "$path" .json)"
  if ! jq -e --arg id "$base" \
      'type == "object" and .request_id == $id and (.requested_at | type == "string" and length > 0)' \
      "$path" >/dev/null 2>&1; then
    echo "[session] warning: requests/expiring/${base}.json is malformed; retained" >&2
    continue
  fi

  event_id="request-expired-$(python3 - "$base" <<'PYEOF'
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:32])
PYEOF
)"
  event_row="$(jq -c --arg event_id "$event_id" '
    {event_id: $event_id, event: "request_expired", request_id: .request_id,
     reason: "ttl_elapsed"}
    + (if (.slug // "") != "" then {slug: .slug} else {} end)
    + (if (.type // "") != "" then {session_type: .type} else {} end)
    + (if (.initiator // "") != "" then {initiator: .initiator} else {} end)
    + (if (.target_instance // "") != "" then {target_instance: .target_instance} else {} end)
  ' "$path")"

  if ! printf '%s\n' "$event_row" \
      | bash "$SCRIPT_DIR/session-event-append.sh" --kdir "$KNOWLEDGE_DIR" >/dev/null; then
    fail "could not append request_expired for '$base'; expiring row was retained"
  fi
  rm -f "$path"
  EXPIRED=$((EXPIRED + 1))
done

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n --argjson expired "$EXPIRED" --argjson ttl "$REQUEST_TTL" \
    '{expired: $expired, request_ttl_seconds: $ttl}')"
fi
echo "[session] Expired $EXPIRED pending request(s) past ${REQUEST_TTL}s TTL"
