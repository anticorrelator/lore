#!/usr/bin/env bash
# accepted-cluster-append.sh — Append a maintainer-accepted recurring-failure
# cluster to the evolve accepted-clusters sidecar.
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
#
# cluster_id is sha256(target | sorted-change_types | sorted-work_items)[:16].
# Re-invocation with the same members + target + change_types yields the same
# cluster_id; if a row with that id already exists the writer is a silent
# no-op (exit 0), making acceptance idempotent across reruns.
#
# Exit codes:
#   0 — row appended OR idempotent no-op
#   1 — validation failure, unknown flag, or knowledge store not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_evolve/accepted-clusters.jsonl`. All schema validation happens before any
# filesystem access; rejected rows never reach disk. The file is opened only
# in append mode (`>> $FILE`) — no read-modify-write, no in-place row edits,
# no deletions. The gate's consumed_at_run_id update lives in /evolve Step 5,
# not here.

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

Append a maintainer-accepted recurring-failure cluster to
_evolve/accepted-clusters.jsonl. cluster_id is derived deterministically from
(target, sorted change_types, sorted work_items); a re-invocation carrying the
same evidence is a silent no-op (exit 0).
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
