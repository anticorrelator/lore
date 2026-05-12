#!/usr/bin/env bash
# filtered-claim-append.sh — Append a row to a work item's
# filtered-claims sidecar.
#
# Canonical sole-writer for `_work/<slug>/filtered-claims.jsonl`. Used by the
# settlement→commons propagation filter (D5) when a Tier-2 claim is excluded
# from settlement enqueue (pre-enqueue stage) or reported after a verdict
# (post-verdict stage) without changing the enqueue decision.
#
# Schema: architecture/artifacts/filtered-claim-schema.md
#
# Usage (see --help for the full flag set):
#   filtered-claim-append.sh
#       --work-item <slug>
#       --claim-id <id>
#       --reason <templated-claim|templated-falsifier|no-discoverable-target|concordance-stale>
#       --mode <exclude|report-only>
#       --stage <pre-enqueue|post-verdict>
#       [--settlement-run-id <id>]    # REQUIRED iff stage=post-verdict; FORBIDDEN iff stage=pre-enqueue
#       --file <absolute-path>
#       --line-range <N-M|N>
#       --change-context <json-object>
#       --enqueued-anyway <true|false>
#       --resolver-version <string>
#       [--kdir <path>]
#       [--json]
#
# Dedupe: same sha256(claim_id|stage|reason|settlement_run_id|resolver_version)
# in the same work item → silent no-op, exit 0. When settlement_run_id is
# absent (stage=pre-enqueue), the hash substitutes the empty string.
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — validation failure, unknown flag, or work-item not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_work/<slug>/filtered-claims.jsonl`. All schema validation happens before
# any filesystem access; rejected rows never reach disk. No read-modify-write
# on the sidecar — we only append.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: filtered-claim-append.sh \
           --work-item <slug> \
           --claim-id <id> \
           --reason <templated-claim|templated-falsifier|no-discoverable-target|concordance-stale> \
           --mode <exclude|report-only> \
           --stage <pre-enqueue|post-verdict> \
           [--settlement-run-id <id>] \
           --file <absolute-path> \
           --line-range <N-M|N> \
           --change-context <json-object> \
           --enqueued-anyway <true|false> \
           --resolver-version <string> \
           [--kdir <path>] \
           [--json]

Append a row to a work item's _work/<slug>/filtered-claims.jsonl sidecar.

Stage discriminator (load-bearing):
  stage=pre-enqueue   → --settlement-run-id MUST be absent
  stage=post-verdict  → --settlement-run-id MUST be present

Dedupes on sha256(claim_id|stage|reason|settlement_run_id|resolver_version)
— a duplicate is a silent no-op (exit 0). When settlement_run_id is absent
(stage=pre-enqueue), the hash substitutes the empty string.
EOF
}

WORK_ITEM=""
CLAIM_ID=""
REASON=""
MODE=""
STAGE=""
SETTLEMENT_RUN_ID=""
SETTLEMENT_RUN_ID_SET=0
CLAIM_FILE=""
LINE_RANGE=""
CHANGE_CONTEXT=""
ENQUEUED_ANYWAY=""
RESOLVER_VERSION=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)          WORK_ITEM="$2";          shift 2 ;;
    --claim-id)           CLAIM_ID="$2";           shift 2 ;;
    --reason)             REASON="$2";             shift 2 ;;
    --mode)               MODE="$2";               shift 2 ;;
    --stage)              STAGE="$2";              shift 2 ;;
    --settlement-run-id)
      SETTLEMENT_RUN_ID="$2"
      SETTLEMENT_RUN_ID_SET=1
      shift 2
      ;;
    --file)               CLAIM_FILE="$2";         shift 2 ;;
    --line-range)         LINE_RANGE="$2";         shift 2 ;;
    --change-context)     CHANGE_CONTEXT="$2";     shift 2 ;;
    --enqueued-anyway)    ENQUEUED_ANYWAY="$2";    shift 2 ;;
    --resolver-version)   RESOLVER_VERSION="$2";   shift 2 ;;
    --kdir)               KDIR_OVERRIDE="$2";      shift 2 ;;
    --json)               JSON_MODE=1;             shift ;;
    --help|-h)            usage; exit 0 ;;
    *)
      echo "[filtered-claim] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Error routing helper: JSON mode vs stderr mode ---
fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[filtered-claim] $msg"
  fi
  echo "[filtered-claim] Error: $msg" >&2
  exit 1
}

# --- Required-field validation (pre-filesystem) ---
for _pair in \
  "work-item:$WORK_ITEM" \
  "claim-id:$CLAIM_ID" \
  "reason:$REASON" \
  "mode:$MODE" \
  "stage:$STAGE" \
  "file:$CLAIM_FILE" \
  "line-range:$LINE_RANGE" \
  "change-context:$CHANGE_CONTEXT" \
  "enqueued-anyway:$ENQUEUED_ANYWAY" \
  "resolver-version:$RESOLVER_VERSION"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    fail "--$_flag is required"
  fi
done

# --- Enum validation: --reason ---
case "$REASON" in
  templated-claim|templated-falsifier|no-discoverable-target|concordance-stale) : ;;
  *)
    fail "--reason must be 'templated-claim', 'templated-falsifier', 'no-discoverable-target', or 'concordance-stale' (got '$REASON')"
    ;;
esac

# --- Enum validation: --mode ---
case "$MODE" in
  exclude|report-only) : ;;
  *)
    fail "--mode must be 'exclude' or 'report-only' (got '$MODE')"
    ;;
esac

# --- Enum validation: --stage ---
case "$STAGE" in
  pre-enqueue|post-verdict) : ;;
  *)
    fail "--stage must be 'pre-enqueue' or 'post-verdict' (got '$STAGE')"
    ;;
esac

# --- Stage-conditional rule: settlement_run_id presence (D5 load-bearing invariant) ---
# Mirror scorecard-append.sh's tier-conditional gates: validate the
# stage↔settlement_run_id pairing before any filesystem access. Both
# directions enforced — pre-enqueue rows with a run_id corrupt the
# downstream reconciliation script's run-id grouping; post-verdict rows
# without a run_id cannot be traced back to the verdict that produced them.
if [[ "$STAGE" == "post-verdict" ]]; then
  if [[ $SETTLEMENT_RUN_ID_SET -eq 0 || -z "$SETTLEMENT_RUN_ID" ]]; then
    fail "--settlement-run-id is REQUIRED when --stage=post-verdict"
  fi
else
  # stage=pre-enqueue
  if [[ $SETTLEMENT_RUN_ID_SET -eq 1 ]]; then
    fail "--settlement-run-id MUST be absent when --stage=pre-enqueue (got '$SETTLEMENT_RUN_ID')"
  fi
fi

# --- Enum validation: --enqueued-anyway (bool) ---
case "$ENQUEUED_ANYWAY" in
  true|false) : ;;
  *)
    fail "--enqueued-anyway must be 'true' or 'false' (got '$ENQUEUED_ANYWAY')"
    ;;
esac

# --- Mode↔enqueued_anyway consistency check ---
# Documented contract from the task spec: mode=report-only ⇒ enqueued_anyway=true;
# mode=exclude ⇒ enqueued_anyway=false. Surfacing the mismatch at write time
# prevents the downstream filter from emitting contradictory rows.
if [[ "$MODE" == "exclude" && "$ENQUEUED_ANYWAY" == "true" ]]; then
  fail "--mode=exclude requires --enqueued-anyway=false (exclude means the claim was NOT enqueued)"
fi
if [[ "$MODE" == "report-only" && "$ENQUEUED_ANYWAY" == "false" ]]; then
  fail "--mode=report-only requires --enqueued-anyway=true (report-only means the claim WAS enqueued)"
fi

# --- Line-range shape: "N-M" or "N" ---
if ! printf '%s' "$LINE_RANGE" | grep -Eq '^[0-9]+(-[0-9]+)?$'; then
  fail "--line-range must match 'N' or 'N-M' (got '$LINE_RANGE')"
fi

# --- jq availability ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

# --- change-context must parse as a JSON object ---
if ! printf '%s' "$CHANGE_CONTEXT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "--change-context must be a valid JSON object (got '$CHANGE_CONTEXT')"
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

WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"
if [[ ! -d "$WORK_DIR" ]]; then
  fail "work item not found: $WORK_ITEM (expected $WORK_DIR)"
fi

SIDECAR="$WORK_DIR/filtered-claims.jsonl"

# --- Dedupe key: sha256(claim_id|stage|reason|settlement_run_id|resolver_version) ---
# When stage=pre-enqueue, settlement_run_id is absent — substitute empty
# string in the hash input so the key is well-defined for both stages.
DEDUPE_KEY=$(printf '%s|%s|%s|%s|%s' \
  "$CLAIM_ID" "$STAGE" "$REASON" "$SETTLEMENT_RUN_ID" "$RESOLVER_VERSION" \
  | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

# --- Dedupe check: silent no-op exit 0 on match ---
if [[ -f "$SIDECAR" ]]; then
  if python3 -c '
import json, sys
sidecar, key = sys.argv[1:3]
try:
    with open(sidecar) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("dedupe_key") == key:
                sys.exit(0)
    sys.exit(1)
except FileNotFoundError:
    sys.exit(1)
' "$SIDECAR" "$DEDUPE_KEY"; then
    # Match found — silent no-op.
    exit 0
  fi
fi

# --- Defaults for generated fields ---
CREATED_AT=$(timestamp_iso)

# --- Branch-provenance trio (always emitted, null sentinel when unavailable) ---
CAPTURED_AT_BRANCH=$(captured_at_branch)
CAPTURED_AT_SHA=$(captured_at_sha)
CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)

# --- Build the row via Python (correct escaping for quotes/newlines) ---
# Field conventions:
#   - settlement_run_id: present iff stage=post-verdict; absent iff
#     stage=pre-enqueue (the load-bearing stage-conditional invariant).
#   - change_context: a JSON object passed through verbatim from the source row.
#   - enqueued_anyway: bool — true for mode=report-only, false for mode=exclude.
#   - Branch-provenance trio: always emitted; stored as JSON null when the
#     helper returned the literal string "null".
export WORK_ITEM CLAIM_ID REASON MODE STAGE SETTLEMENT_RUN_ID \
       SETTLEMENT_RUN_ID_SET CLAIM_FILE LINE_RANGE CHANGE_CONTEXT \
       ENQUEUED_ANYWAY RESOLVER_VERSION CREATED_AT DEDUPE_KEY \
       CAPTURED_AT_BRANCH CAPTURED_AT_SHA CAPTURED_AT_MERGE_BASE_SHA

ROW=$(python3 <<'PY_EOF'
import json, os

def env(name):
    return os.environ.get(name, "")

def provenance(val):
    return None if val == "null" else val

row = {
    "work_item":        env("WORK_ITEM"),
    "claim_id":         env("CLAIM_ID"),
    "reason":           env("REASON"),
    "mode":             env("MODE"),
    "stage":            env("STAGE"),
    "file":             env("CLAIM_FILE"),
    "line_range":       env("LINE_RANGE"),
    "change_context":   json.loads(env("CHANGE_CONTEXT")),
    "enqueued_anyway":  env("ENQUEUED_ANYWAY") == "true",
    "resolver_version": env("RESOLVER_VERSION"),
    "created_at":       env("CREATED_AT"),
    "dedupe_key":       env("DEDUPE_KEY"),
    "captured_at_branch":         provenance(env("CAPTURED_AT_BRANCH")),
    "captured_at_sha":            provenance(env("CAPTURED_AT_SHA")),
    "captured_at_merge_base_sha": provenance(env("CAPTURED_AT_MERGE_BASE_SHA")),
}

# Stage-conditional: settlement_run_id present iff stage=post-verdict.
if env("STAGE") == "post-verdict":
    row["settlement_run_id"] = env("SETTLEMENT_RUN_ID")

print(json.dumps(row, ensure_ascii=False))
PY_EOF
)

if [[ -z "$ROW" ]]; then
  fail "internal error: row serialization produced empty output"
fi

# --- Final structural sanity via jq -e ---
# Belt-and-suspenders: ensures what we're about to append is a valid JSON
# object with all required top-level fields AND the stage-conditional rule
# holds in the serialized row.
if ! printf '%s' "$ROW" | jq -e '
  type == "object"
  and (.work_item        | type == "string" and . != "")
  and (.claim_id         | type == "string" and . != "")
  and (.reason           | type == "string" and . != "")
  and (.mode             | type == "string" and . != "")
  and (.stage            | type == "string" and . != "")
  and (.file             | type == "string" and . != "")
  and (.line_range       | type == "string" and . != "")
  and (.change_context   | type == "object")
  and (.enqueued_anyway  | type == "boolean")
  and (.resolver_version | type == "string" and . != "")
  and (.dedupe_key       | type == "string" and (. | length) == 64)
  and (has("captured_at_branch"))
  and (has("captured_at_sha"))
  and (has("captured_at_merge_base_sha"))
  and (
    (.stage == "post-verdict"  and (.settlement_run_id // "") != "")
    or
    (.stage == "pre-enqueue"   and (has("settlement_run_id") | not))
  )
' >/dev/null 2>&1; then
  fail "internal error: constructed row failed post-build schema check"
fi

# --- Atomic append (jq -c '.' >> $FILE); no read-modify-write ---
printf '%s\n' "$ROW" | jq -c '.' >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg claim_id "$CLAIM_ID" \
    --arg stage "$STAGE" \
    --arg reason "$REASON" \
    --arg mode "$MODE" \
    --arg dedupe_key "$DEDUPE_KEY" \
    '{path: $path, claim_id: $claim_id, stage: $stage, reason: $reason, mode: $mode, dedupe_key: $dedupe_key, appended: true}')
  json_output "$RESULT"
fi

echo "[filtered-claim] Filtered claim $CLAIM_ID (stage=$STAGE, reason=$REASON, mode=$MODE) appended to $RELPATH"
