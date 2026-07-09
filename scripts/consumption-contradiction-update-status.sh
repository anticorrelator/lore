#!/usr/bin/env bash
# consumption-contradiction-update-status.sh — Sanctioned lifecycle mutator for
# an existing consumption-contradiction sidecar row.
#
# Usage:
#   consumption-contradiction-update-status.sh \
#       --work-item <slug> \
#       --contradiction-id <ctr-id> \
#       --status <verified|contradicted> \
#       --settled-at <iso8601-with-timezone> \
#       [--settled-by-run-id <id>] [--kdir <path>] [--json]
#
# The writer owns identity, timestamp, and transition validation. It searches
# only the exact work item's active and archived sidecars, rejects ambiguous
# locations or duplicate identities, permits pending -> terminal and the same
# terminal as an idempotent no-op, and refuses conflicting terminal rewrites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: consumption-contradiction-update-status.sh \
           --work-item <slug> \
           --contradiction-id <ctr-id> \
           --status <verified|contradicted> \
           --settled-at <iso8601-with-timezone> \
           [--settled-by-run-id <id>] \
           [--kdir <path>] [--json]

Transition one exact work-item/contradiction row from pending to a correctness
verdict. Re-running the same terminal transition is an idempotent no-op.
EOF
}

WORK_ITEM=""
CONTRADICTION_ID=""
NEW_STATUS=""
SETTLED_AT=""
SETTLED_BY_RUN_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)            WORK_ITEM="$2";             shift 2 ;;
    --contradiction-id)     CONTRADICTION_ID="$2";      shift 2 ;;
    --status)               NEW_STATUS="$2";            shift 2 ;;
    --settled-at)           SETTLED_AT="$2";            shift 2 ;;
    --settled-by-run-id)    SETTLED_BY_RUN_ID="$2";     shift 2 ;;
    --kdir)                 KDIR_OVERRIDE="$2";         shift 2 ;;
    --json)                 JSON_MODE=1;                 shift ;;
    --help|-h)              usage; exit 0 ;;
    *)
      echo "[contradiction-update] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[contradiction-update] $msg"
  fi
  echo "[contradiction-update] Error: $msg" >&2
  exit 1
}

[[ -n "$WORK_ITEM" ]] || fail "--work-item is required"
[[ -n "$CONTRADICTION_ID" ]] || fail "--contradiction-id is required"
[[ -n "$NEW_STATUS" ]] || fail "--status is required"
[[ -n "$SETTLED_AT" ]] || fail "--settled-at is required"

case "$NEW_STATUS" in
  verified|contradicted) : ;;
  *) fail "--status must be 'verified' or 'contradicted' (got '$NEW_STATUS')" ;;
esac

if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

# Validate the caller-supplied historical completion time here, at the writer
# boundary. Callers must not implement their own weaker timestamp grammar.
if ! python3 - "$SETTLED_AT" <<'PY'
from datetime import datetime
import sys

value = sys.argv[1]
try:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if parsed.tzinfo is not None else 1)
PY
then
  fail "--settled-at must be an ISO-8601 timestamp with timezone (got '$SETTLED_AT')"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

ACTIVE_SIDECAR="$KNOWLEDGE_DIR/_work/$WORK_ITEM/consumption-contradictions.jsonl"
ARCHIVE_SIDECAR="$KNOWLEDGE_DIR/_work/_archive/$WORK_ITEM/consumption-contradictions.jsonl"

MATCHES=()
for candidate in "$ACTIVE_SIDECAR" "$ARCHIVE_SIDECAR"; do
  [[ -f "$candidate" ]] || continue
  count=$(python3 - "$candidate" "$WORK_ITEM" "$CONTRADICTION_ID" <<'PY'
import json, sys

path, work_item, contradiction_id = sys.argv[1:]
count = 0
with open(path, encoding="utf-8") as fh:
    for raw in fh:
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if (
            isinstance(row, dict)
            and row.get("work_item") == work_item
            and row.get("contradiction_id") == contradiction_id
        ):
            count += 1
print(count)
PY
  )
  if [[ "$count" -gt 1 ]]; then
    fail "ambiguous row identity: work_item=$WORK_ITEM contradiction_id=$CONTRADICTION_ID appears $count times in $candidate"
  fi
  if [[ "$count" -eq 1 ]]; then
    MATCHES+=("$candidate")
  fi
done

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  fail "row not found: work_item=$WORK_ITEM contradiction_id=$CONTRADICTION_ID"
fi
if [[ ${#MATCHES[@]} -gt 1 ]]; then
  fail "ambiguous active/archive identity: work_item=$WORK_ITEM contradiction_id=$CONTRADICTION_ID exists in both locations"
fi

SIDECAR="${MATCHES[0]}"
if [[ "$SIDECAR" == "$ARCHIVE_SIDECAR" ]]; then
  LOCATION="archive"
else
  LOCATION="active"
fi

TMP_BODY=$(mktemp -t cc-update-body-XXXXXX)
TMP_META=$(mktemp -t cc-update-meta-XXXXXX)
trap 'rm -f "$TMP_BODY" "$TMP_META"' EXIT

if ! SIDECAR="$SIDECAR" \
  WORK_ITEM="$WORK_ITEM" \
  CONTRADICTION_ID="$CONTRADICTION_ID" \
  NEW_STATUS="$NEW_STATUS" \
  SETTLED_AT="$SETTLED_AT" \
  SETTLED_BY_RUN_ID="$SETTLED_BY_RUN_ID" \
  BODY_PATH="$TMP_BODY" \
  META_PATH="$TMP_META" \
  python3 <<'PY'
import json
import os
import sys

path = os.environ["SIDECAR"]
work_item = os.environ["WORK_ITEM"]
contradiction_id = os.environ["CONTRADICTION_ID"]
new_status = os.environ["NEW_STATUS"]
settled_at = os.environ["SETTLED_AT"]
settled_by = os.environ["SETTLED_BY_RUN_ID"]
body_path = os.environ["BODY_PATH"]
meta_path = os.environ["META_PATH"]

with open(path, "rb") as fh:
    raw = fh.read()
trailing_nl = raw.endswith(b"\n")
lines = raw.decode("utf-8").splitlines()

matches = []
for idx, line in enumerate(lines):
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if (
        isinstance(row, dict)
        and row.get("work_item") == work_item
        and row.get("contradiction_id") == contradiction_id
    ):
        matches.append((idx, row))

if len(matches) != 1:
    sys.stderr.write(
        f"[contradiction-update] Error: identity changed during update: "
        f"work_item={work_item} contradiction_id={contradiction_id} matches={len(matches)}\n"
    )
    raise SystemExit(2)

idx, row = matches[0]
previous = row.get("status")
if previous not in {"pending", "verified", "contradicted"}:
    sys.stderr.write(
        f"[contradiction-update] Error: invalid existing status {previous!r}: "
        f"work_item={work_item} contradiction_id={contradiction_id}\n"
    )
    raise SystemExit(3)
if previous in {"verified", "contradicted"} and previous != new_status:
    sys.stderr.write(
        f"[contradiction-update] Error: conflicting terminal transition {previous}->{new_status}: "
        f"work_item={work_item} contradiction_id={contradiction_id}\n"
    )
    raise SystemExit(4)

if previous == new_status:
    result = {"verb": "idempotent", "previous_status": previous}
else:
    row["status"] = new_status
    row["settled_at"] = settled_at
    if settled_by:
        row["settled_by_run_id"] = settled_by
    lines[idx] = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    output = "\n".join(lines) + ("\n" if trailing_nl else "")
    with open(body_path, "wb") as fh:
        fh.write(output.encode("utf-8"))
    result = {"verb": "applied", "previous_status": previous}

with open(meta_path, "w", encoding="utf-8") as fh:
    json.dump(result, fh)
PY
then
  fail "writer refused transition: work_item=$WORK_ITEM contradiction_id=$CONTRADICTION_ID target=$NEW_STATUS"
fi

VERB=$(jq -r '.verb' "$TMP_META")
PREVIOUS_STATUS=$(jq -r '.previous_status' "$TMP_META")
if [[ "$VERB" == "applied" ]]; then
  mv "$TMP_BODY" "$SIDECAR"
elif [[ "$VERB" != "idempotent" ]]; then
  fail "internal error: unrecognized writer result '$VERB'"
fi

RESULT=$(jq -n \
  --arg status "$VERB" \
  --arg work_item "$WORK_ITEM" \
  --arg cid "$CONTRADICTION_ID" \
  --arg previous "$PREVIOUS_STATUS" \
  --arg new "$NEW_STATUS" \
  --arg settled_at "$SETTLED_AT" \
  --arg run_id "$SETTLED_BY_RUN_ID" \
  --arg location "$LOCATION" \
  '{status:$status,work_item:$work_item,contradiction_id:$cid,previous_status:$previous,new_status:$new,settled_at:$settled_at,sidecar_location:$location}
   + (if ($run_id|length)>0 then {settled_by_run_id:$run_id} else {} end)')

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$RESULT" | jq -c .
fi

if [[ "$VERB" == "idempotent" ]]; then
  echo "[contradiction-update] OK: $WORK_ITEM/$CONTRADICTION_ID already $NEW_STATUS (idempotent; $LOCATION)"
else
  echo "[contradiction-update] OK: $WORK_ITEM/$CONTRADICTION_ID pending → $NEW_STATUS ($LOCATION)"
fi
