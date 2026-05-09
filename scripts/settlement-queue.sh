#!/usr/bin/env bash
# settlement-queue.sh — Typed settlement audit queue for task-claims rows
#
# Stores settlement-audit.v1 requests under:
#   $KDIR/_work-queue/settlement-audit/
#
# Usage:
#   settlement-queue.sh enqueue --work-item <slug> --claim-id <id> [--kdir <path>] [--json]
#   settlement-queue.sh scan [--kdir <path>] [--json]
#   settlement-queue.sh status [--kdir <path>] [--json]
#   settlement-queue.sh process [--kdir <path>] [--limit N] [--json] [--dry-run] [-- <audit args...>]
#
# Queue items are durable and content-addressed by artifact_path + claim_id.
# The queue item points at the owning task-claims.jsonl file plus the intended
# claim_ids, so processing never resolves a work item directory and falls back
# to execution-log.md or plan.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

QUEUE_ROLE="settlement-audit"
SCHEMA_VERSION="settlement-audit.v1"

usage() {
  sed -n '2,18p' "$0" >&2
}

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

resolve_kdir() {
  local override="$1"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
  else
    resolve_knowledge_dir
  fi
}

fail() {
  local json_mode="$1"
  local msg="$2"
  if [[ "$json_mode" -eq 1 ]]; then
    printf '{"ok":false,"error":%s}\n' "$(printf '%s' "$msg" | json_quote)"
  fi
  echo "[settlement-queue] Error: $msg" >&2
  exit 1
}

queue_dir_for() {
  local kdir="$1"
  printf '%s/_work-queue/%s\n' "$kdir" "$QUEUE_ROLE"
}

cmd_enqueue() {
  local work_item="" claim_id="" kdir_override="" json_mode=0 source="manual"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --work-item) work_item="$2"; shift 2 ;;
      --claim-id) claim_id="$2"; shift 2 ;;
      --kdir) kdir_override="$2"; shift 2 ;;
      --json) json_mode=1; shift ;;
      --source) source="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) fail "$json_mode" "unknown enqueue argument '$1'" ;;
    esac
  done

  [[ -n "$work_item" ]] || fail "$json_mode" "--work-item is required"
  [[ -n "$claim_id" ]] || fail "$json_mode" "--claim-id is required"

  local kdir item_dir artifact_path queue_dir
  kdir="$(resolve_kdir "$kdir_override")"
  [[ -d "$kdir" ]] || fail "$json_mode" "knowledge directory not found: $kdir"
  item_dir="$kdir/_work/$work_item"
  [[ -d "$item_dir" ]] || fail "$json_mode" "work item not found: $work_item"
  artifact_path="$item_dir/task-claims.jsonl"
  [[ -f "$artifact_path" ]] || fail "$json_mode" "task-claims artifact not found: $artifact_path"

  queue_dir="$(queue_dir_for "$kdir")"
  if ! mkdir -p "$queue_dir" 2>/dev/null; then
    fail "$json_mode" "could not create queue directory: $queue_dir"
  fi

  KDIR_ENV="$kdir" \
  QUEUE_DIR_ENV="$queue_dir" \
  WORK_ITEM_ENV="$work_item" \
  CLAIM_ID_ENV="$claim_id" \
  ARTIFACT_PATH_ENV="$artifact_path" \
  SOURCE_ENV="$source" \
  SCHEMA_VERSION_ENV="$SCHEMA_VERSION" \
  JSON_MODE_ENV="$json_mode" \
  python3 <<'PYEOF'
import datetime
import hashlib
import json
import os
import sys
import tempfile

kdir = os.environ["KDIR_ENV"]
queue_dir = os.environ["QUEUE_DIR_ENV"]
work_item = os.environ["WORK_ITEM_ENV"]
claim_id = os.environ["CLAIM_ID_ENV"]
artifact_path = os.environ["ARTIFACT_PATH_ENV"]
source = os.environ["SOURCE_ENV"]
schema_version = os.environ["SCHEMA_VERSION_ENV"]
json_mode = os.environ["JSON_MODE_ENV"] == "1"

matches = []
with open(artifact_path, encoding="utf-8") as fh:
    for line_no, line in enumerate(fh, 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            print(f"[settlement-queue] Error: corrupt JSONL at {artifact_path}:{line_no}: {exc}", file=sys.stderr)
            sys.exit(1)
        if row.get("claim_id") == claim_id:
            canonical = json.dumps(row, sort_keys=True, separators=(",", ":"))
            matches.append((line_no, row, hashlib.sha256(canonical.encode()).hexdigest()))

if not matches:
    print(f"[settlement-queue] Error: claim_id not found in task-claims artifact: {claim_id}", file=sys.stderr)
    sys.exit(1)

if len(matches) > 1:
    print(f"[settlement-queue] Error: claim_id is not unique in task-claims artifact: {claim_id}", file=sys.stderr)
    sys.exit(1)

line_no, row, row_hash = matches[0]
artifact_id = f"task-claims:{work_item}:{claim_id}"
dedupe_key = f"{artifact_path}#{claim_id}"
request_id = hashlib.sha256(dedupe_key.encode()).hexdigest()[:16]
target = os.path.join(queue_dir, f"{request_id}.json")

if os.path.exists(target):
    result = {"ok": True, "request_id": request_id, "target": target, "duplicate": True}
    if json_mode:
        print(json.dumps(result, sort_keys=True))
    else:
        print(f"[settlement-queue] duplicate - {request_id} already queued")
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
request = {
    "schema_version": schema_version,
    "request_id": request_id,
    "artifact_id": artifact_id,
    "artifact_type": "task-claims",
    "artifact_path": artifact_path,
    "work_item": work_item,
    "claim_ids": [claim_id],
    "claim_count": 1,
    "claim_row_numbers": [line_no],
    "claim_row_hashes": [row_hash],
    "dedupe_key": dedupe_key,
    "source": source,
    "status": "pending",
    "enqueued_at": now,
}

fd, tmp = tempfile.mkstemp(prefix=f".{request_id}.", suffix=".tmp", dir=queue_dir)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(request, out, sort_keys=True)
        out.write("\n")
    os.replace(tmp, target)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass

result = {"ok": True, "request_id": request_id, "target": target, "duplicate": False}
if json_mode:
    print(json.dumps(result, sort_keys=True))
else:
    print(f"[settlement-queue] queued {request_id} ({artifact_id}) -> {target}")
PYEOF
}

cmd_scan() {
  local kdir_override="" json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kdir) kdir_override="$2"; shift 2 ;;
      --json) json_mode=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) fail "$json_mode" "unknown scan argument '$1'" ;;
    esac
  done

  local kdir queue_dir
  kdir="$(resolve_kdir "$kdir_override")"
  [[ -d "$kdir" ]] || fail "$json_mode" "knowledge directory not found: $kdir"
  queue_dir="$(queue_dir_for "$kdir")"

  QUEUE_DIR_ENV="$queue_dir" JSON_MODE_ENV="$json_mode" python3 <<'PYEOF'
import glob
import json
import os
import sys

queue_dir = os.environ["QUEUE_DIR_ENV"]
json_mode = os.environ["JSON_MODE_ENV"] == "1"
items = []
for path in sorted(glob.glob(os.path.join(queue_dir, "*.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except Exception as exc:
        obj = {"path": path, "status": "corrupt", "error": f"{type(exc).__name__}: {exc}"}
    else:
        obj["path"] = path
    items.append(obj)

if json_mode:
    print(json.dumps({"queue": "settlement-audit", "items": items}, sort_keys=True))
else:
    for item in items:
        print(f"{item.get('request_id', '?')}\t{item.get('status', '?')}\t{item.get('artifact_id', item.get('path', '?'))}")
PYEOF
}

cmd_status() {
  if [[ -x "$SCRIPT_DIR/settlement-queue-process.sh" ]]; then
    "$SCRIPT_DIR/settlement-queue-process.sh" status "$@"
    return
  fi

  local kdir_override="" json_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kdir) kdir_override="$2"; shift 2 ;;
      --json) json_mode=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) fail "$json_mode" "unknown status argument '$1'" ;;
    esac
  done

  local kdir queue_dir
  kdir="$(resolve_kdir "$kdir_override")"
  [[ -d "$kdir" ]] || fail "$json_mode" "knowledge directory not found: $kdir"
  queue_dir="$(queue_dir_for "$kdir")"

  QUEUE_DIR_ENV="$queue_dir" JSON_MODE_ENV="$json_mode" python3 <<'PYEOF'
import glob
import json
import os

queue_dir = os.environ["QUEUE_DIR_ENV"]
json_mode = os.environ["JSON_MODE_ENV"] == "1"
counts = {}
total = 0
for path in sorted(glob.glob(os.path.join(queue_dir, "*.json"))):
    total += 1
    try:
        with open(path, encoding="utf-8") as fh:
            status = json.load(fh).get("status", "unknown")
    except Exception:
        status = "corrupt"
    counts[status] = counts.get(status, 0) + 1

out = {"queue": "settlement-audit", "queue_dir": queue_dir, "total": total, "counts": counts}
if json_mode:
    print(json.dumps(out, sort_keys=True))
else:
    print(f"settlement-audit queue: total={total} pending={counts.get('pending', 0)} processing={counts.get('processing', 0)} completed={counts.get('completed', 0)} failed={counts.get('failed', 0)} corrupt={counts.get('corrupt', 0)}")
PYEOF
}

cmd_process() {
  if [[ -x "$SCRIPT_DIR/settlement-queue-process.sh" ]]; then
    "$SCRIPT_DIR/settlement-queue-process.sh" process "$@"
    return
  fi

  local kdir_override="" json_mode=0 limit=1 dry_run=0
  local audit_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kdir) kdir_override="$2"; shift 2 ;;
      --json) json_mode=1; shift ;;
      --limit) limit="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --) shift; audit_args=("$@"); break ;;
      -h|--help) usage; return 0 ;;
      *) fail "$json_mode" "unknown process argument '$1'" ;;
    esac
  done

  [[ "$limit" =~ ^[0-9]+$ ]] || fail "$json_mode" "--limit must be a non-negative integer"

  local kdir queue_dir selected_file
  kdir="$(resolve_kdir "$kdir_override")"
  [[ -d "$kdir" ]] || fail "$json_mode" "knowledge directory not found: $kdir"
  queue_dir="$(queue_dir_for "$kdir")"
  mkdir -p "$queue_dir"

  selected_file=$(mktemp "${TMPDIR:-/tmp}/settlement-queue-selected-XXXXXX.json")
  trap 'rm -f "$selected_file" "$priority_file" 2>/dev/null || true' RETURN

  QUEUE_DIR_ENV="$queue_dir" LIMIT_ENV="$limit" SELECTED_FILE_ENV="$selected_file" python3 <<'PYEOF'
import glob
import json
import os

queue_dir = os.environ["QUEUE_DIR_ENV"]
limit = int(os.environ["LIMIT_ENV"])
selected_file = os.environ["SELECTED_FILE_ENV"]
items = []
for path in sorted(glob.glob(os.path.join(queue_dir, "*.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except Exception:
        continue
    if obj.get("schema_version") == "settlement-audit.v1" and obj.get("status") == "pending":
        obj["path"] = path
        items.append(obj)
    if limit and len(items) >= limit:
        break
with open(selected_file, "w", encoding="utf-8") as fh:
    json.dump(items, fh)
PYEOF

  local processed=0 failed=0 priority_file=""
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    processed=$((processed + 1))
    local path artifact_path claim_ids request_id
    path=$(printf '%s' "$item" | jq -r '.path')
    artifact_path=$(printf '%s' "$item" | jq -r '.artifact_path')
    claim_ids=$(printf '%s' "$item" | jq -c '.claim_ids')
    request_id=$(printf '%s' "$item" | jq -r '.request_id')

    if [[ "$dry_run" -eq 1 ]]; then
      if [[ "$json_mode" -eq 0 ]]; then
        echo "[settlement-queue] dry-run would process $request_id -> $artifact_path claim_ids=$claim_ids"
      fi
      continue
    fi

    priority_file=$(mktemp "${TMPDIR:-/tmp}/settlement-priority-XXXXXX.json")
    printf '%s\n' "$claim_ids" > "$priority_file"

    QUEUE_ITEM_PATH="$path" QUEUE_STATUS="processing" python3 <<'PYEOF'
import datetime, json, os, tempfile
path = os.environ["QUEUE_ITEM_PATH"]
status = os.environ["QUEUE_STATUS"]
with open(path, encoding="utf-8") as fh:
    obj = json.load(fh)
obj["status"] = status
obj["processing_started_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fd, tmp = tempfile.mkstemp(prefix=".status.", suffix=".tmp", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as out:
    json.dump(obj, out, sort_keys=True)
    out.write("\n")
os.replace(tmp, path)
PYEOF

    local rc=0
    set +e
    bash "$SCRIPT_DIR/audit-artifact.sh" "$artifact_path" --kdir "$kdir" --priority-claims "$priority_file" "${audit_args[@]}"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      failed=$((failed + 1))
      QUEUE_ITEM_PATH="$path" QUEUE_STATUS="failed" QUEUE_EXIT_CODE="$rc" python3 <<'PYEOF'
import datetime, json, os, tempfile
path = os.environ["QUEUE_ITEM_PATH"]
with open(path, encoding="utf-8") as fh:
    obj = json.load(fh)
obj["status"] = os.environ["QUEUE_STATUS"]
obj["exit_code"] = int(os.environ["QUEUE_EXIT_CODE"])
obj["finished_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fd, tmp = tempfile.mkstemp(prefix=".status.", suffix=".tmp", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as out:
    json.dump(obj, out, sort_keys=True)
    out.write("\n")
os.replace(tmp, path)
PYEOF
    else
      QUEUE_ITEM_PATH="$path" QUEUE_STATUS="completed" python3 <<'PYEOF'
import datetime, json, os, tempfile
path = os.environ["QUEUE_ITEM_PATH"]
with open(path, encoding="utf-8") as fh:
    obj = json.load(fh)
obj["status"] = os.environ["QUEUE_STATUS"]
obj["finished_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
fd, tmp = tempfile.mkstemp(prefix=".status.", suffix=".tmp", dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as out:
    json.dump(obj, out, sort_keys=True)
    out.write("\n")
os.replace(tmp, path)
PYEOF
    fi
    rm -f "$priority_file"
    priority_file=""
  done < <(jq -c '.[]' "$selected_file")

  if [[ "$json_mode" -eq 1 ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      PROCESSED_ENV="$processed" FAILED_ENV="$failed" SELECTED_FILE_ENV="$selected_file" python3 <<'PYEOF'
import json, os
with open(os.environ["SELECTED_FILE_ENV"], encoding="utf-8") as fh:
    items = json.load(fh)
trimmed = [
    {
        "request_id": item.get("request_id"),
        "artifact_path": item.get("artifact_path"),
        "artifact_type": item.get("artifact_type"),
        "work_item": item.get("work_item"),
        "claim_ids": item.get("claim_ids", []),
    }
    for item in items
]
print(json.dumps({
    "ok": True,
    "processed": int(os.environ["PROCESSED_ENV"]),
    "failed": int(os.environ["FAILED_ENV"]),
    "dry_run": True,
    "items": trimmed,
}, sort_keys=True))
PYEOF
    else
      printf '{"ok":true,"processed":%s,"failed":%s,"dry_run":false}\n' "$processed" "$failed"
    fi
  else
    echo "[settlement-queue] processed=$processed failed=$failed dry_run=$dry_run"
  fi
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

subcmd="$1"
shift
case "$subcmd" in
  enqueue) cmd_enqueue "$@" ;;
  scan) cmd_scan "$@" ;;
  status) cmd_status "$@" ;;
  process) cmd_process "$@" ;;
  --help|-h) usage ;;
  *) fail 0 "unknown subcommand '$subcmd'" ;;
esac
