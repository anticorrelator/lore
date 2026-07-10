#!/usr/bin/env bash
# accepted-cluster-append.sh — Write maintainer-accepted recurring-failure
# clusters to the evolve accepted-clusters sidecar.
#
# Canonical sole-writer for `_evolve/accepted-clusters.jsonl`. Invoked from
# `/evolve` Step 6 CLUSTER REVIEW after the maintainer accepts a candidate
# cluster (y / edit / split). The row records which retro-evolution journal
# rows clustered on a shared (target, change_type), so the Step 5
# recurring-failure gate in a later run can clear a staged suggestion.
#
# Row schema (skills/evolve/SKILL.md §Accepted-cluster artifact format):
#   schema_version, vocabulary_version, cluster_id, target, change_types[],
#   work_items[], journal_row_refs[],
#   accepted_at, accepted_at_run_id, accepted_by_maintainer_decision,
#   consumed_at_run_id (always null at append time — the gate sets it later).
#
# Usage (see --help for the full flag set):
#   accepted-cluster-append.sh
#       --target <file-path>
#       --change-types <comma-list>
#       --work-items <comma-list>
#       --decision <merge|edit|split>
#       --accepted-at-run-id <run-id>
#       [--journal-row-refs <ts:slug,ts:slug,...>]
#       [--accepted-at <iso8601>]
#       [--kdir <path>]
#       [--json]
#   accepted-cluster-append.sh
#       --reconcile-legacy-versions
#       [--kdir <path>]
#       [--json]
#
# cluster_id is sha256(target | sorted-change_types | sorted-work_items)[:16].
# Re-invocation with the same members + target + change_types yields the same
# cluster_id; if a row with that id already exists the writer is a silent
# no-op (exit 0), making acceptance idempotent across reruns.
#
# Exit codes:
#   0 — row appended, legacy versions reconciled, OR idempotent no-op
#   1 — validation failure, unknown flag, or knowledge store not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_evolve/accepted-clusters.jsonl`. All schema validation happens before any
# mutation; rejected rows never reach disk. Normal cluster acceptance opens the
# file only in append mode. The explicit legacy-version reconciliation mode
# validates the complete source before a same-directory atomic replacement and
# replaces nothing when no rows need stamps. The gate's consumed_at_run_id
# update lives in /evolve Step 5, not here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: accepted-cluster-append.sh \
           --target <file-path> \
           --change-types <comma-list> \
           --work-items <comma-list> \
           --decision <merge|edit|split> \
           --accepted-at-run-id <run-id> \
           [--journal-row-refs <ts:slug,ts:slug,...>] \
           [--accepted-at <iso8601>] \
           [--kdir <path>] \
           [--json]

       accepted-cluster-append.sh \
           --reconcile-legacy-versions \
           [--kdir <path>] \
           [--json]

Append a maintainer-accepted recurring-failure cluster to
_evolve/accepted-clusters.jsonl. cluster_id is derived deterministically from
(target, sorted change_types, sorted work_items); a re-invocation carrying the
same evidence is a silent no-op (exit 0).

Reconcile undeclared legacy rows only after validating each row against the
durable version-1 contract. The mode inserts the two version declarations
without reserializing any existing bytes and atomically replaces the sidecar
only when at least one row changes.
EOF
}

TARGET=""
CHANGE_TYPES=""
WORK_ITEMS=""
DECISION=""
ACCEPTED_AT_RUN_ID=""
JOURNAL_ROW_REFS=""
ACCEPTED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0
RECONCILE_LEGACY_VERSIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)              TARGET="$2";              shift 2 ;;
    --change-types)        CHANGE_TYPES="$2";        shift 2 ;;
    --work-items)          WORK_ITEMS="$2";          shift 2 ;;
    --decision)            DECISION="$2";            shift 2 ;;
    --accepted-at-run-id)  ACCEPTED_AT_RUN_ID="$2";  shift 2 ;;
    --journal-row-refs)    JOURNAL_ROW_REFS="$2";    shift 2 ;;
    --accepted-at)         ACCEPTED_AT="$2";         shift 2 ;;
    --kdir)                KDIR_OVERRIDE="$2";       shift 2 ;;
    --json)                JSON_MODE=1;              shift ;;
    --reconcile-legacy-versions)
                           RECONCILE_LEGACY_VERSIONS=1; shift ;;
    --help|-h)             usage; exit 0 ;;
    *)
      echo "[accepted-cluster] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Error routing helper: JSON mode vs stderr mode ---
fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[accepted-cluster] $msg"
  fi
  echo "[accepted-cluster] Error: $msg" >&2
  exit 1
}

# Reconciliation is a distinct operation. Append-only inputs are rejected
# rather than ignored so a caller can never believe it both appended and
# migrated in one invocation.
if [[ $RECONCILE_LEGACY_VERSIONS -eq 1 ]]; then
  for _pair in \
    "target:$TARGET" \
    "change-types:$CHANGE_TYPES" \
    "work-items:$WORK_ITEMS" \
    "decision:$DECISION" \
    "accepted-at-run-id:$ACCEPTED_AT_RUN_ID" \
    "journal-row-refs:$JOURNAL_ROW_REFS" \
    "accepted-at:$ACCEPTED_AT"
  do
    _flag="${_pair%%:*}"
    _val="${_pair#*:}"
    if [[ -n "$_val" ]]; then
      fail "--$_flag is not accepted with --reconcile-legacy-versions"
    fi
  done
fi

if [[ $RECONCILE_LEGACY_VERSIONS -eq 1 ]]; then
  command -v python3 >/dev/null 2>&1 || fail "python3 is required but not found on PATH"

  # Reconciliation necessarily resolves and reads the source before it can
  # validate row content, but no mutation occurs until every row passes.
  if [[ -n "$KDIR_OVERRIDE" ]]; then
    KNOWLEDGE_DIR="$KDIR_OVERRIDE"
  else
    KNOWLEDGE_DIR=$(resolve_knowledge_dir)
  fi
  if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
    fail "knowledge store not found at: $KNOWLEDGE_DIR"
  fi
  SIDECAR_DIR="$KNOWLEDGE_DIR/_evolve"
  SIDECAR="$SIDECAR_DIR/accepted-clusters.jsonl"

  if [[ ! -f "$SIDECAR" ]]; then
    fail "accepted-cluster sidecar not found at: $SIDECAR"
  fi

  RECONCILE_RESULT=$(python3 - "$SIDECAR" "$KNOWLEDGE_DIR" <<'PY_EOF'
import hashlib
import json
import os
import re
import stat
import sys
import tempfile


sidecar, knowledge_dir = sys.argv[1:3]
legacy_keys = {
    "cluster_id",
    "target",
    "change_types",
    "work_items",
    "journal_row_refs",
    "accepted_at",
    "accepted_at_run_id",
    "accepted_by_maintainer_decision",
    "consumed_at_run_id",
}
version_keys = {"schema_version", "vocabulary_version"}
versioned_keys = legacy_keys | version_keys
version_prefix = b'"schema_version":"1","vocabulary_version":"1",'


def reject(lineno, message):
    raise ValueError(f"line {lineno}: {message}")


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def validate_string_list(row, key, lineno, allow_empty=False):
    value = row.get(key)
    if not isinstance(value, list):
        reject(lineno, f"{key} must be an array")
    if not allow_empty and not value:
        reject(lineno, f"{key} must contain at least one value")
    if not all(nonempty_string(item) for item in value):
        reject(lineno, f"{key} entries must be non-empty strings")
    return value


def validate_v1_row(row, lineno, declared):
    expected_keys = versioned_keys if declared else legacy_keys
    actual_keys = set(row)
    if actual_keys != expected_keys:
        missing = sorted(expected_keys - actual_keys)
        extra = sorted(actual_keys - expected_keys)
        detail = []
        if missing:
            detail.append("missing " + ",".join(missing))
        if extra:
            detail.append("unknown " + ",".join(extra))
        reject(lineno, "row does not match the v1 durable shape (" + "; ".join(detail) + ")")

    cluster_id = row["cluster_id"]
    if not isinstance(cluster_id, str) or re.fullmatch(r"[0-9a-f]{16}", cluster_id) is None:
        reject(lineno, "cluster_id must be a 16-character lowercase hex string")
    if not nonempty_string(row["target"]):
        reject(lineno, "target must be a non-empty string")

    change_types = validate_string_list(row, "change_types", lineno)
    work_items = validate_string_list(row, "work_items", lineno)
    refs = row["journal_row_refs"]
    if not isinstance(refs, list):
        reject(lineno, "journal_row_refs must be an array")
    for pos, ref in enumerate(refs, 1):
        if not isinstance(ref, dict) or set(ref) != {"timestamp", "work_item"}:
            reject(lineno, f"journal_row_refs[{pos}] must contain only timestamp and work_item")
        if not nonempty_string(ref["timestamp"]) or not nonempty_string(ref["work_item"]):
            reject(lineno, f"journal_row_refs[{pos}] identifiers must be non-empty strings")

    for key in ("accepted_at", "accepted_at_run_id"):
        if not nonempty_string(row[key]):
            reject(lineno, f"{key} must be a non-empty string")
    if row["accepted_by_maintainer_decision"] not in {"merge", "edit", "split"}:
        reject(lineno, "accepted_by_maintainer_decision must be merge, edit, or split")
    consumed = row["consumed_at_run_id"]
    if consumed is not None and not nonempty_string(consumed):
        reject(lineno, "consumed_at_run_id must be null or a non-empty string")

    key = row["target"] + "|" + "|".join(sorted(change_types)) + "|" + "|".join(sorted(work_items))
    expected_id = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    if cluster_id != expected_id:
        reject(lineno, f"cluster_id does not match the v1 identity basis (expected {expected_id})")


try:
    source_stat = os.stat(sidecar)
    if not stat.S_ISREG(source_stat.st_mode):
        raise ValueError("accepted-cluster sidecar is not a regular file")
    with open(sidecar, "rb") as handle:
        original = handle.read()

    transformed = []
    updated = 0
    skipped = 0
    total = 0
    for lineno, raw_line in enumerate(original.splitlines(keepends=True), 1):
        if not raw_line.strip():
            transformed.append(raw_line)
            continue
        total += 1
        try:
            row = json.loads(raw_line)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            reject(lineno, f"malformed JSON ({exc})")
        if not isinstance(row, dict):
            reject(lineno, "row must be a JSON object")

        has_schema = "schema_version" in row
        has_vocabulary = "vocabulary_version" in row
        if has_schema != has_vocabulary:
            reject(lineno, "partial version declaration")
        declared = has_schema and has_vocabulary
        if declared and (row["schema_version"] != "1" or row["vocabulary_version"] != "1"):
            reject(lineno, "schema_version and vocabulary_version must both be string token 1")

        validate_v1_row(row, lineno, declared)
        if declared:
            transformed.append(raw_line)
            skipped += 1
            continue

        opening = len(raw_line) - len(raw_line.lstrip())
        if raw_line[opening:opening + 1] != b"{":
            reject(lineno, "object opening brace could not be located")
        transformed.append(raw_line[:opening + 1] + version_prefix + raw_line[opening + 1:])
        updated += 1

    replacement = b"".join(transformed)
    if updated:
        descriptor, temporary = tempfile.mkstemp(prefix=".accepted-clusters.", dir=os.path.dirname(sidecar))
        try:
            os.fchmod(descriptor, stat.S_IMODE(source_stat.st_mode))
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = -1
                handle.write(replacement)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, sidecar)
        except BaseException:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

    result = {
        "path": os.path.relpath(sidecar, knowledge_dir),
        "total": total,
        "updated": updated,
        "skipped": skipped,
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
except (OSError, ValueError) as exc:
    print(str(exc))
    sys.exit(1)
PY_EOF
  ) || fail "$RECONCILE_RESULT"

  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$RECONCILE_RESULT"
  fi

  RECONCILE_COUNTS=$(printf '%s' "$RECONCILE_RESULT" | python3 -c '
import json, sys
row = json.load(sys.stdin)
print("%s\t%s\t%s\t%s" % (row["updated"], row["skipped"], row["total"], row["path"]))
')
  IFS=$'\t' read -r RECONCILED SKIPPED TOTAL RELPATH <<< "$RECONCILE_COUNTS"
  if [[ "$RECONCILED" -eq 0 ]]; then
    echo "[accepted-cluster] Reconciled 0 legacy row(s); skipped $SKIPPED already-versioned row(s) in $RELPATH — no-op"
  else
    echo "[accepted-cluster] Reconciled $RECONCILED legacy row(s); skipped $SKIPPED already-versioned row(s) in $RELPATH"
  fi
  exit 0
fi

# --- Required-field validation (pre-filesystem) ---
for _pair in \
  "target:$TARGET" \
  "change-types:$CHANGE_TYPES" \
  "work-items:$WORK_ITEMS" \
  "decision:$DECISION" \
  "accepted-at-run-id:$ACCEPTED_AT_RUN_ID"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    fail "--$_flag is required"
  fi
done

# --- Enum validation: --decision ---
case "$DECISION" in
  merge|edit|split) : ;;
  *)
    fail "--decision must be 'merge', 'edit', or 'split' (got '$DECISION')"
    ;;
esac

# --- jq availability ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

command -v python3 >/dev/null 2>&1 || fail "python3 is required but not found on PATH"

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

SIDECAR_DIR="$KNOWLEDGE_DIR/_evolve"
SIDECAR="$SIDECAR_DIR/accepted-clusters.jsonl"

# --- Defaults for generated fields ---
if [[ -z "$ACCEPTED_AT" ]]; then
  ACCEPTED_AT=$(timestamp_iso)
fi

# --- Build the row + cluster_id via Python (correct escaping, list splitting,
#     and deterministic id derivation in one pass). ---
# cluster_id key construction matches the gate-side reader: the sorted
# change_types and sorted work_items are pipe-joined with the target, then
# sha256-hashed and truncated to 16 hex chars. Any drift here silently breaks
# idempotency and the gate's cluster lookup, so the key string is built once,
# here, and nowhere else.
export TARGET CHANGE_TYPES WORK_ITEMS DECISION ACCEPTED_AT_RUN_ID \
       JOURNAL_ROW_REFS ACCEPTED_AT

ROW=$(python3 <<'PY_EOF'
import hashlib, json, os

def env(name):
    return os.environ.get(name, "")

def split_csv(raw):
    return [p.strip() for p in raw.split(",") if p.strip()]

target = env("TARGET")
change_types = sorted(split_csv(env("CHANGE_TYPES")))
work_items = sorted(split_csv(env("WORK_ITEMS")))

# journal_row_refs: optional "<iso-ts>:<slug>" pairs. Split on the LAST colon
# so the work_item slug is taken from the tail and the ISO timestamp's own
# colons survive intact.
refs = []
raw_refs = env("JOURNAL_ROW_REFS")
if raw_refs:
    for chunk in raw_refs.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        ts, sep, slug = chunk.rpartition(":")
        if not sep:
            # No colon at all — treat the whole chunk as the slug.
            ts, slug = "", chunk
        refs.append({"timestamp": ts.strip(), "work_item": slug.strip()})

key = target + "|" + "|".join(change_types) + "|" + "|".join(work_items)
cluster_id = hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]

row = {
    "schema_version": "1",
    "vocabulary_version": "1",
    "cluster_id": cluster_id,
    "target": target,
    "change_types": change_types,
    "work_items": work_items,
    "journal_row_refs": refs,
    "accepted_at": env("ACCEPTED_AT"),
    "accepted_at_run_id": env("ACCEPTED_AT_RUN_ID"),
    "accepted_by_maintainer_decision": env("DECISION"),
    "consumed_at_run_id": None,
}

print(json.dumps(row, ensure_ascii=False))
PY_EOF
)

if [[ -z "$ROW" ]]; then
  fail "internal error: row serialization produced empty output"
fi

# --- Empty-list guard: a cluster with no work_items is meaningless and would
#     collapse cluster_ids across distinct targets. Reject post-build so the
#     check sees the parsed/split list, not the raw CSV. ---
WORK_ITEM_COUNT=$(printf '%s' "$ROW" | jq -r '.work_items | length')
if [[ "$WORK_ITEM_COUNT" -eq 0 ]]; then
  fail "--work-items must contain at least one non-empty slug"
fi
CHANGE_TYPE_COUNT=$(printf '%s' "$ROW" | jq -r '.change_types | length')
if [[ "$CHANGE_TYPE_COUNT" -eq 0 ]]; then
  fail "--change-types must contain at least one non-empty value"
fi

CLUSTER_ID=$(printf '%s' "$ROW" | jq -r '.cluster_id')

# --- Final structural sanity via jq -e ---
# Belt-and-suspenders: ensures what we're about to append is a valid JSON
# object with the schema the gate reader depends on.
if ! printf '%s' "$ROW" | jq -e '
  type == "object"
  and (.schema_version == "1")
  and (.vocabulary_version == "1")
  and (.cluster_id | type == "string" and (. | length) == 16)
  and (.target | type == "string" and . != "")
  and (.change_types | type == "array" and length > 0)
  and (.work_items | type == "array" and length > 0)
  and (.journal_row_refs | type == "array")
  and (.accepted_at | type == "string" and . != "")
  and (.accepted_at_run_id | type == "string" and . != "")
  and (.accepted_by_maintainer_decision | type == "string" and . != "")
  and (has("consumed_at_run_id"))
  and (.consumed_at_run_id == null)
' >/dev/null 2>&1; then
  fail "internal error: constructed row failed post-build schema check"
fi

# --- Idempotency: re-invocation with the same cluster_id is a silent no-op ---
# Same (target, sorted change_types, sorted work_items) → same cluster_id, so
# accepting the identical cluster across reruns appends nothing the second time.
if [[ -f "$SIDECAR" ]]; then
  if python3 -c '
import json, sys
sidecar, cid = sys.argv[1:3]
with open(sidecar) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("cluster_id") == cid:
            sys.exit(0)
sys.exit(1)
' "$SIDECAR" "$CLUSTER_ID"; then
    # Existing row with this cluster_id — idempotent no-op.
    if [[ $JSON_MODE -eq 1 ]]; then
      RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"
      RESULT=$(jq -n \
        --arg path "$RELPATH" \
        --arg cluster_id "$CLUSTER_ID" \
        '{path: $path, cluster_id: $cluster_id, appended: false, deduped: true}')
      json_output "$RESULT"
    fi
    echo "[accepted-cluster] Cluster $CLUSTER_ID already present — no-op"
    exit 0
  fi
fi

# --- Atomic append (jq -c '.' >> $FILE); no read-modify-write ---
mkdir -p "$SIDECAR_DIR"
printf '%s\n' "$ROW" | jq -c '.' >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg cluster_id "$CLUSTER_ID" \
    '{path: $path, cluster_id: $cluster_id, appended: true, deduped: false}')
  json_output "$RESULT"
fi

echo "[accepted-cluster] Cluster $CLUSTER_ID appended to $RELPATH"
