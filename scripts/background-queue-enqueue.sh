#!/usr/bin/env bash
# background-queue-enqueue.sh — Enqueue a background-queue job
#
# Filesystem-based request queue for background processing. Writes one
# file per job to $KDIR/_work-queue/<role>/<request-id>.json. A future
# dispatcher (see [[work:work-item-request-queue-background-processing]])
# drains the queue asynchronously, invoking the queued command outside
# the foreground loop.
#
# Rationale for queue location (_work-queue/ sibling of _work/):
#   scripts/heal-work.sh auto-promotes any directory under _work/ that
#   lacks _meta.json into a phantom work item. Placing queue data inside
#   _work/ would create ghost work items. _work-queue/ is a sibling and
#   is immune to that promotion. See the work-item-request-queue
#   investigation findings for the full rationale.
#
# Usage:
#   background-queue-enqueue.sh \
#       --job "<command to run, e.g. 'lore audit pr-99'>" \
#       --role <audit|capture|spec|implement|custom-tag> \
#       [--triggered-at <ISO-8601>] \
#       [--kdir <path>] \
#       [--json]
#
# The `--job` string is what the dispatcher will execute. `--role` is a
# sub-directory tag under `_work-queue/` so the dispatcher and retention
# policies can filter by role without parsing commands. For the Phase 5
# audit-trigger path, `probabilistic-audit-trigger.py` calls this with:
#     --job "lore audit <artifact-id>" --role audit
#
# Request file shape:
#   {
#     "request_id":   "<sha256(job+triggered_at)[:12]>",
#     "job":          "<verbatim command string>",
#     "role":         "audit | capture | spec | implement | custom",
#     "triggered_at": "<ISO-8601 timestamp>",
#     "enqueued_at":  "<ISO-8601 timestamp>",
#     "status":       "pending"
#   }
#
# `request_id` is content-addressed so repeat enqueues for the same
# (job, triggered_at) tuple produce the same filename and are idempotent
# — this matches the `_pending_captures/` pattern from the stop hook.
#
# Exit codes:
#   0 — enqueued (or idempotent no-op on duplicate)
#   1 — usage error
#   2 — could not create queue directory
#
# Dispatcher (future work):
#   A drain worker reads files from _work-queue/<role>/, executes each
#   job string via shell, updates `status` to `dispatched` then
#   `completed|failed`, and deletes completed files older than a
#   retention window. This enqueue script does not care which
#   dispatcher drains the queue — the filesystem layout is the contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

JOB=""
ROLE=""
TRIGGERED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  sed -n '2,55p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job)          JOB="$2";          shift 2 ;;
    --role)         ROLE="$2";         shift 2 ;;
    --triggered-at) TRIGGERED_AT="$2"; shift 2 ;;
    --kdir)         KDIR_OVERRIDE="$2"; shift 2 ;;
    --json)         JSON_MODE=1;       shift ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "[bg-queue] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"ok": false, "error": %s}\n' \
      "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  fi
  echo "[bg-queue] Error: $msg" >&2
  exit 1
}

[[ -n "$JOB"  ]] || fail "--job is required"
[[ -n "$ROLE" ]] || fail "--role is required"

# Role must be a plain slug (no path separators) — prevents traversal into
# sibling directories when the queue dispatcher globs $ROLE/*.json.
if [[ "$ROLE" =~ [/.] ]] && [[ "$ROLE" != "$(basename "$ROLE")" ]]; then
  fail "--role must be a plain slug (no path separators)"
fi

# --- Resolve KDIR ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

[[ -d "$KDIR" ]] || fail "knowledge directory not found: $KDIR"

# --- Default triggered_at to now ---
if [[ -z "$TRIGGERED_AT" ]]; then
  TRIGGERED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# --- Create queue dir (parents ok) ---
QUEUE_DIR="$KDIR/_work-queue/$ROLE"
if ! mkdir -p "$QUEUE_DIR" 2>/dev/null; then
  fail "could not create queue directory: $QUEUE_DIR"
fi

# --- Compute request_id (content-addressed) ---
# sha256(job + "|" + triggered_at) first 12 hex chars. Same material
# produces the same id ⇒ idempotent writes. Uses JOB (not artifact_id)
# as the dedup anchor so two distinct triggers with the same
# artifact-id but different ceremonies produce distinct requests.
REQUEST_ID=$(printf '%s|%s' "$JOB" "$TRIGGERED_AT" | \
  python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest()[:12])')

TARGET="$QUEUE_DIR/$REQUEST_ID.json"

# --- Idempotent enqueue ---
if [[ -f "$TARGET" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"ok": true, "request_id": %s, "target": %s, "duplicate": true}\n' \
      "$(printf '%s' "$REQUEST_ID" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$TARGET" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  else
    echo "[bg-queue] duplicate — $REQUEST_ID already queued (idempotent no-op)"
  fi
  exit 0
fi

# --- Atomic write via tempfile + rename ---
ENQUEUED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMP=$(mktemp "${TARGET}.XXXXXX")

JOB_ENV="$JOB" \
ROLE_ENV="$ROLE" \
TRIGGERED_AT_ENV="$TRIGGERED_AT" \
ENQUEUED_AT_ENV="$ENQUEUED_AT" \
REQUEST_ID_ENV="$REQUEST_ID" \
python3 > "$TMP" <<'PYEOF'
import json, os
print(json.dumps({
    "request_id":   os.environ["REQUEST_ID_ENV"],
    "job":          os.environ["JOB_ENV"],
    "role":         os.environ["ROLE_ENV"],
    "triggered_at": os.environ["TRIGGERED_AT_ENV"],
    "enqueued_at":  os.environ["ENQUEUED_AT_ENV"],
    "status":       "pending",
}, sort_keys=True))
PYEOF

mv "$TMP" "$TARGET"

if [[ $JSON_MODE -eq 1 ]]; then
  printf '{"ok": true, "request_id": %s, "target": %s, "duplicate": false}\n' \
    "$(printf '%s' "$REQUEST_ID" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    "$(printf '%s' "$TARGET" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
else
  echo "[bg-queue] queued $REQUEST_ID ($ROLE) → $TARGET"
fi
