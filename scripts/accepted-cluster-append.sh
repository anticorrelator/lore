#!/usr/bin/env bash
# accepted-cluster-append.sh — Sole writer for accepted-cluster lifecycle state.
#
# Every operation validates the complete sidecar before mutation. Exact append
# uses O_APPEND only after validation; consumption and legacy reconciliation use
# a hidden same-directory temporary file plus atomic replacement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODE=""
TARGET=""
CHANGE_TYPES=""
WORK_ITEMS=""
DECISION=""
ACCEPTED_AT_RUN_ID=""
JOURNAL_ROW_REFS=""
ACCEPTED_AT=""
CLUSTER_ID=""
CONSUMED_AT_RUN_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: accepted-cluster-append.sh --append-exact \
         --target <file-path> --change-types <comma-list> \
         --work-items <comma-list> --decision <merge|edit|split> \
         --accepted-at-run-id <run-id> --accepted-at <RFC3339> \
         [--journal-row-refs <ts:slug,...>] [--kdir <path>] [--json]

       accepted-cluster-append.sh --consume \
         --cluster-id <16-hex> --consumed-at-run-id <run-id> \
         [--kdir <path>] [--json]

       accepted-cluster-append.sh --reconcile-legacy-versions \
         [--kdir <path>] [--json]

Exactly one mode is required. Append is an exact semantic insert: an identical
cluster_id row is a no-op, while a changed row using the same id is a conflict.
Consume permits only null -> run_id; same-run replay is a no-op and a different
non-null run is a conflict. All rows are validated before any mutation.
EOF
}

fail() {
  local message="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -nc --arg error "[accepted-cluster] $message" '{status:"refused",error:$error}'
  else
    echo "[accepted-cluster] Error: $message" >&2
  fi
  exit 1
}

set_mode() {
  [[ -z "$MODE" ]] || fail "exactly one operation mode is required"
  MODE="$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --append-exact) set_mode append-exact; shift ;;
    --consume) set_mode consume; shift ;;
    --reconcile-legacy-versions) set_mode reconcile-legacy-versions; shift ;;
    --target) [[ $# -ge 2 ]] || fail "--target requires a value"; TARGET="$2"; shift 2 ;;
    --change-types) [[ $# -ge 2 ]] || fail "--change-types requires a value"; CHANGE_TYPES="$2"; shift 2 ;;
    --work-items) [[ $# -ge 2 ]] || fail "--work-items requires a value"; WORK_ITEMS="$2"; shift 2 ;;
    --decision) [[ $# -ge 2 ]] || fail "--decision requires a value"; DECISION="$2"; shift 2 ;;
    --accepted-at-run-id) [[ $# -ge 2 ]] || fail "--accepted-at-run-id requires a value"; ACCEPTED_AT_RUN_ID="$2"; shift 2 ;;
    --journal-row-refs) [[ $# -ge 2 ]] || fail "--journal-row-refs requires a value"; JOURNAL_ROW_REFS="$2"; shift 2 ;;
    --accepted-at) [[ $# -ge 2 ]] || fail "--accepted-at requires a value"; ACCEPTED_AT="$2"; shift 2 ;;
    --cluster-id) [[ $# -ge 2 ]] || fail "--cluster-id requires a value"; CLUSTER_ID="$2"; shift 2 ;;
    --consumed-at-run-id) [[ $# -ge 2 ]] || fail "--consumed-at-run-id requires a value"; CONSUMED_AT_RUN_ID="$2"; shift 2 ;;
    --kdir) [[ $# -ge 2 ]] || fail "--kdir requires a value"; KDIR_OVERRIDE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "unknown flag '$1'" ;;
  esac
done

[[ -n "$MODE" ]] || { usage; fail "exactly one operation mode is required"; }
command -v python3 >/dev/null 2>&1 || fail "python3 is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

SIDECAR_DIR="$KNOWLEDGE_DIR/_evolve"
SIDECAR="$SIDECAR_DIR/accepted-clusters.jsonl"

export MODE TARGET CHANGE_TYPES WORK_ITEMS DECISION ACCEPTED_AT_RUN_ID \
  JOURNAL_ROW_REFS ACCEPTED_AT CLUSTER_ID CONSUMED_AT_RUN_ID KNOWLEDGE_DIR SIDECAR

set +e
RESULT=$(python3 <<'PY'
import datetime as dt
import hashlib
import json
import os
import re
import stat
import sys
import tempfile

mode = os.environ["MODE"]
sidecar = os.environ["SIDECAR"]
kdir = os.environ["KNOWLEDGE_DIR"]

LEGACY_KEYS = {
    "cluster_id", "target", "change_types", "work_items", "journal_row_refs",
    "accepted_at", "accepted_at_run_id", "accepted_by_maintainer_decision",
    "consumed_at_run_id",
}
VERSION_KEYS = {"schema_version", "vocabulary_version"}
V1_KEYS = LEGACY_KEYS | VERSION_KEYS
VERSION_PREFIX = b'"schema_version":"1","vocabulary_version":"1",'

def reject(message):
    print(message)
    raise SystemExit(1)

def nonempty(value):
    return isinstance(value, str) and bool(value.strip())

def split_csv(raw):
    values = sorted({part.strip() for part in raw.split(",") if part.strip()})
    return values

def validate_timestamp(value, label):
    if not nonempty(value):
        reject(f"{label} must be a non-empty RFC3339 timestamp")
    try:
        parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
        if parsed.tzinfo is None:
            raise ValueError("timezone required")
    except Exception as exc:
        reject(f"{label} must be RFC3339 with timezone ({exc})")

def validate_string_list(row, key, line, allow_empty=False):
    value = row.get(key)
    if not isinstance(value, list) or (not allow_empty and not value):
        reject(f"line {line}: {key} must be a{' non-empty' if not allow_empty else 'n'} array")
    if not all(nonempty(item) for item in value):
        reject(f"line {line}: {key} entries must be non-empty strings")
    if value != sorted(set(value)):
        reject(f"line {line}: {key} must be sorted and unique")
    return value

def validate_row(row, line, declared_required=True):
    if not isinstance(row, dict):
        reject(f"line {line}: row must be a JSON object")
    has_schema = "schema_version" in row
    has_vocab = "vocabulary_version" in row
    if has_schema != has_vocab:
        reject(f"line {line}: partial version declaration")
    declared = has_schema and has_vocab
    expected = V1_KEYS if declared else LEGACY_KEYS
    if set(row) != expected:
        reject(f"line {line}: row does not match the {'declared ' if declared else 'legacy '}v1 durable shape")
    if declared and (row["schema_version"] != "1" or row["vocabulary_version"] != "1"):
        reject(f"line {line}: schema_version and vocabulary_version must both be string token 1")
    if declared_required and not declared:
        reject(f"line {line}: legacy row requires --reconcile-legacy-versions before lifecycle mutation")
    if re.fullmatch(r"[0-9a-f]{16}", str(row.get("cluster_id") or "")) is None:
        reject(f"line {line}: cluster_id must be 16 lowercase hex characters")
    if not nonempty(row.get("target")):
        reject(f"line {line}: target must be non-empty")
    change_types = validate_string_list(row, "change_types", line)
    work_items = validate_string_list(row, "work_items", line)
    refs = row.get("journal_row_refs")
    if not isinstance(refs, list):
        reject(f"line {line}: journal_row_refs must be an array")
    for index, ref in enumerate(refs):
        if not isinstance(ref, dict) or set(ref) != {"timestamp", "work_item"}:
            reject(f"line {line}: journal_row_refs[{index}] must contain only timestamp and work_item")
        validate_timestamp(ref.get("timestamp"), f"line {line}: journal_row_refs[{index}].timestamp")
        if not nonempty(ref.get("work_item")):
            reject(f"line {line}: journal_row_refs[{index}].work_item must be non-empty")
    validate_timestamp(row.get("accepted_at"), f"line {line}: accepted_at")
    if not nonempty(row.get("accepted_at_run_id")):
        reject(f"line {line}: accepted_at_run_id must be non-empty")
    if row.get("accepted_by_maintainer_decision") not in {"merge", "edit", "split"}:
        reject(f"line {line}: accepted_by_maintainer_decision must be merge, edit, or split")
    consumed = row.get("consumed_at_run_id")
    if consumed is not None and not nonempty(consumed):
        reject(f"line {line}: consumed_at_run_id must be null or non-empty")
    basis = row["target"] + "|" + "|".join(change_types) + "|" + "|".join(work_items)
    expected_id = hashlib.sha256(basis.encode()).hexdigest()[:16]
    if row["cluster_id"] != expected_id:
        reject(f"line {line}: cluster_id does not match the v1 identity basis (expected {expected_id})")
    return declared

def load_rows(declared_required=True):
    if not os.path.exists(sidecar):
        return b"", [], None
    source_stat = os.stat(sidecar)
    if not stat.S_ISREG(source_stat.st_mode):
        reject("accepted-cluster sidecar is not a regular file")
    original = open(sidecar, "rb").read()
    rows = []
    for line, raw in enumerate(original.splitlines(keepends=True), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except Exception as exc:
            reject(f"line {line}: malformed JSON ({exc})")
        validate_row(row, line, declared_required=declared_required)
        rows.append((line, raw, row))
    return original, rows, source_stat

def replace_bytes(replacement, source_stat):
    os.makedirs(os.path.dirname(sidecar), exist_ok=True)
    mode_bits = stat.S_IMODE(source_stat.st_mode) if source_stat else 0o644
    descriptor, temporary = tempfile.mkstemp(prefix=".accepted-clusters.", dir=os.path.dirname(sidecar))
    try:
        os.fchmod(descriptor, mode_bits)
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(replacement)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, sidecar)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try: os.unlink(temporary)
        except FileNotFoundError: pass
        raise

if mode == "reconcile-legacy-versions":
    forbidden = [name for name in (
        "TARGET", "CHANGE_TYPES", "WORK_ITEMS", "DECISION", "ACCEPTED_AT_RUN_ID",
        "JOURNAL_ROW_REFS", "ACCEPTED_AT", "CLUSTER_ID", "CONSUMED_AT_RUN_ID",
    ) if os.environ.get(name)]
    if forbidden:
        flags = ", ".join("--" + name.lower().replace("_", "-") for name in forbidden)
        reject(flags + " not accepted with --reconcile-legacy-versions")
    if not os.path.isfile(sidecar):
        reject(f"accepted-cluster sidecar not found at: {sidecar}")
    original, rows, source_stat = load_rows(declared_required=False)
    updated = 0
    skipped = 0
    transformed = []
    row_by_line = {line: (raw, row) for line, raw, row in rows}
    for line, raw in enumerate(original.splitlines(keepends=True), 1):
        if not raw.strip():
            transformed.append(raw)
            continue
        _, row = row_by_line[line]
        if "schema_version" in row:
            transformed.append(raw)
            skipped += 1
            continue
        opening = len(raw) - len(raw.lstrip())
        transformed.append(raw[:opening + 1] + VERSION_PREFIX + raw[opening + 1:])
        updated += 1
    if updated:
        replace_bytes(b"".join(transformed), source_stat)
    result = {"operation": mode, "status": "reconciled" if updated else "reused",
              "path": os.path.relpath(sidecar, kdir), "total": len(rows),
              "updated": updated, "skipped": skipped}

elif mode == "append-exact":
    required = ("TARGET", "CHANGE_TYPES", "WORK_ITEMS", "DECISION", "ACCEPTED_AT_RUN_ID", "ACCEPTED_AT")
    missing = ["--" + name.lower().replace("_", "-") for name in required if not os.environ.get(name)]
    if missing:
        reject("required append flag(s) missing: " + ", ".join(missing))
    if os.environ.get("CLUSTER_ID") or os.environ.get("CONSUMED_AT_RUN_ID"):
        reject("consume flags are not accepted with --append-exact")
    change_types = split_csv(os.environ["CHANGE_TYPES"])
    work_items = split_csv(os.environ["WORK_ITEMS"])
    if not change_types or not work_items:
        reject("--change-types and --work-items must contain non-empty values")
    refs = []
    for chunk in (os.environ.get("JOURNAL_ROW_REFS") or "").split(","):
        if not chunk.strip():
            continue
        timestamp, separator, work_item = chunk.strip().rpartition(":")
        if not separator:
            reject("--journal-row-refs entries must use <RFC3339>:<work-item>")
        refs.append({"timestamp": timestamp, "work_item": work_item})
    basis = os.environ["TARGET"] + "|" + "|".join(change_types) + "|" + "|".join(work_items)
    cluster_id = hashlib.sha256(basis.encode()).hexdigest()[:16]
    candidate = {
        "schema_version": "1", "vocabulary_version": "1", "cluster_id": cluster_id,
        "target": os.environ["TARGET"], "change_types": change_types, "work_items": work_items,
        "journal_row_refs": refs, "accepted_at": os.environ["ACCEPTED_AT"],
        "accepted_at_run_id": os.environ["ACCEPTED_AT_RUN_ID"],
        "accepted_by_maintainer_decision": os.environ["DECISION"], "consumed_at_run_id": None,
    }
    validate_row(candidate, "candidate")
    original, rows, _ = load_rows(declared_required=True)
    matches = [row for _, _, row in rows if row["cluster_id"] == cluster_id]
    if len(matches) > 1:
        reject(f"cluster_id {cluster_id} occurs more than once")
    if matches:
        if matches[0] != candidate:
            reject(f"cluster_id {cluster_id} already exists with different semantics")
        result = {"operation": mode, "status": "reused", "path": os.path.relpath(sidecar, kdir),
                  "cluster_id": cluster_id, "appended": False}
    else:
        os.makedirs(os.path.dirname(sidecar), exist_ok=True)
        with open(sidecar, "ab") as handle:
            handle.write(json.dumps(candidate, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")).encode() + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        result = {"operation": mode, "status": "created", "path": os.path.relpath(sidecar, kdir),
                  "cluster_id": cluster_id, "appended": True}

elif mode == "consume":
    cluster_id = os.environ.get("CLUSTER_ID")
    run_id = os.environ.get("CONSUMED_AT_RUN_ID")
    if re.fullmatch(r"[0-9a-f]{16}", cluster_id or "") is None or not nonempty(run_id):
        reject("--cluster-id (16 lowercase hex) and --consumed-at-run-id are required")
    if any(os.environ.get(name) for name in (
        "TARGET", "CHANGE_TYPES", "WORK_ITEMS", "DECISION", "ACCEPTED_AT_RUN_ID",
        "JOURNAL_ROW_REFS", "ACCEPTED_AT",
    )):
        reject("append flags are not accepted with --consume")
    original, rows, source_stat = load_rows(declared_required=True)
    matches = [(line, row) for line, _, row in rows if row["cluster_id"] == cluster_id]
    if len(matches) != 1:
        reject(f"cluster_id {cluster_id} must identify exactly one row")
    _, match = matches[0]
    current = match.get("consumed_at_run_id")
    if current == run_id:
        result = {"operation": mode, "status": "reused", "path": os.path.relpath(sidecar, kdir),
                  "cluster_id": cluster_id, "consumed_at_run_id": run_id, "updated": False}
    elif current is not None:
        reject(f"cluster_id {cluster_id} is already consumed by a different run: {current}")
    else:
        replacement = []
        for line, raw, row in rows:
            if row["cluster_id"] == cluster_id:
                row = dict(row)
                row["consumed_at_run_id"] = run_id
                replacement.append(json.dumps(row, ensure_ascii=False, sort_keys=True,
                                              separators=(",", ":")).encode() + (b"\n" if raw.endswith(b"\n") else b""))
            else:
                replacement.append(raw)
        # Preserve blank lines by rebuilding against physical lines.
        by_line = {line: value for (line, _, _), value in zip(rows, replacement)}
        rebuilt = []
        for line, raw in enumerate(original.splitlines(keepends=True), 1):
            rebuilt.append(by_line.get(line, raw))
        replace_bytes(b"".join(rebuilt), source_stat)
        result = {"operation": mode, "status": "updated", "path": os.path.relpath(sidecar, kdir),
                  "cluster_id": cluster_id, "consumed_at_run_id": run_id, "updated": True}
else:
    reject("unknown operation mode")

print(json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
)
RC=$?
set -e
[[ $RC -eq 0 ]] || fail "$RESULT"

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$RESULT"
else
  STATUS=$(printf '%s' "$RESULT" | jq -r .status)
  echo "[accepted-cluster] $MODE $STATUS — $(printf '%s' "$RESULT" | jq -r .path)"
fi
