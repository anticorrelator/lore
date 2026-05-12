#!/usr/bin/env bash
# propagation-miss-append.sh — Append a row to a work item's
# propagation-misses sidecar.
#
# Canonical sole-writer for `_work/<slug>/propagation-misses.jsonl`. The
# sidecar logs OPERATIONAL FAILURES in the settlement → commons propagation
# chain: hook crashes, hook-disabled gaps, emit-script crashes, and Tier-2
# rehydration failures. A contradicted verdict that legitimately produced
# zero correction targets is NOT a miss — that goes to filtered-claims.jsonl
# with stage=post-verdict. See architecture/artifacts/propagation-miss-schema.md.
#
# Usage (see --help for the full flag set):
#   propagation-miss-append.sh
#       --work-item <slug>
#       --settlement-run-id <id>
#       --reason <hook_crashed|hook_disabled|rehydration_failed|emit_failed>
#       --claim-id <id>
#       --detector <script-name>
#       [--detected-at <iso8601>]
#       [--kdir <path>]
#       [--json]
#
# Dedupe: sha256(settlement_run_id|reason) in the same work item → silent
# no-op, exit 0.
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — validation failure, unknown flag, or work-item not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_work/<slug>/propagation-misses.jsonl`. All schema validation happens
# before any filesystem access; rejected rows never reach disk. No
# read-modify-write on the sidecar — appends only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: propagation-miss-append.sh \
           --work-item <slug> \
           --settlement-run-id <id> \
           --reason <hook_crashed|hook_disabled|rehydration_failed|emit_failed> \
           --claim-id <id> \
           --detector <script-name> \
           [--detected-at <iso8601>] \
           [--kdir <path>] \
           [--json]

Append a row to a work item's _work/<slug>/propagation-misses.jsonl sidecar.
The sidecar logs operational failures in the settlement → commons propagation
chain (hook crash, hook disabled, rehydration failure, emit failure). It is
NOT for legitimate zero-target outcomes — those belong in filtered-claims.jsonl
with stage=post-verdict.

Dedupes on sha256(settlement_run_id|reason) — a duplicate is a silent no-op
(exit 0).
EOF
}

WORK_ITEM=""
SETTLEMENT_RUN_ID=""
REASON=""
CLAIM_ID=""
DETECTOR=""
DETECTED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)         WORK_ITEM="$2";         shift 2 ;;
    --settlement-run-id) SETTLEMENT_RUN_ID="$2"; shift 2 ;;
    --reason)            REASON="$2";            shift 2 ;;
    --claim-id)          CLAIM_ID="$2";          shift 2 ;;
    --detector)          DETECTOR="$2";          shift 2 ;;
    --detected-at)       DETECTED_AT="$2";       shift 2 ;;
    --kdir)              KDIR_OVERRIDE="$2";     shift 2 ;;
    --json)              JSON_MODE=1;            shift ;;
    --help|-h)           usage; exit 0 ;;
    *)
      echo "[propagation-miss] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Error routing helper: JSON mode vs stderr mode ---
fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[propagation-miss] $msg"
  fi
  echo "[propagation-miss] Error: $msg" >&2
  exit 1
}

# --- Required-field validation (pre-filesystem) ---
for _pair in \
  "work-item:$WORK_ITEM" \
  "settlement-run-id:$SETTLEMENT_RUN_ID" \
  "reason:$REASON" \
  "claim-id:$CLAIM_ID" \
  "detector:$DETECTOR"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    fail "--$_flag is required"
  fi
done

# --- Enum validation: --reason (closed set; operational failures only) ---
case "$REASON" in
  hook_crashed|hook_disabled|rehydration_failed|emit_failed) : ;;
  *)
    fail "--reason must be 'hook_crashed', 'hook_disabled', 'rehydration_failed', or 'emit_failed' (got '$REASON')"
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

WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"
if [[ ! -d "$WORK_DIR" ]]; then
  fail "work item not found: $WORK_ITEM (expected $WORK_DIR)"
fi

SIDECAR="$WORK_DIR/propagation-misses.jsonl"

# --- Defaults for generated fields ---
if [[ -z "$DETECTED_AT" ]]; then
  DETECTED_AT=$(timestamp_iso)
fi

# --- Dedupe key: sha256(settlement_run_id|reason) ---
DEDUPE_KEY=$(printf '%s|%s' "$SETTLEMENT_RUN_ID" "$REASON" \
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

# --- Build the row via Python (correct escaping for quotes/newlines) ---
export WORK_ITEM SETTLEMENT_RUN_ID REASON CLAIM_ID DETECTOR DETECTED_AT \
       DEDUPE_KEY

ROW=$(python3 <<'PY_EOF'
import json, os

def env(name):
    return os.environ.get(name, "")

row = {
    "settlement_run_id": env("SETTLEMENT_RUN_ID"),
    "reason":            env("REASON"),
    "detected_at":       env("DETECTED_AT"),
    "work_item":         env("WORK_ITEM"),
    "claim_id":          env("CLAIM_ID"),
    "detector":          env("DETECTOR"),
    "dedupe_key":        env("DEDUPE_KEY"),
}

print(json.dumps(row, ensure_ascii=False))
PY_EOF
)

if [[ -z "$ROW" ]]; then
  fail "internal error: row serialization produced empty output"
fi

# --- Final structural sanity via jq -e ---
# Belt-and-suspenders: ensures what we're about to append is a valid JSON
# object with all required top-level fields.
if ! printf '%s' "$ROW" | jq -e '
  type == "object"
  and (.settlement_run_id | type == "string" and . != "")
  and (.reason | type == "string" and test("^(hook_crashed|hook_disabled|rehydration_failed|emit_failed)$"))
  and (.detected_at | type == "string" and . != "")
  and (.work_item | type == "string" and . != "")
  and (.claim_id | type == "string" and . != "")
  and (.detector | type == "string" and . != "")
  and (.dedupe_key | type == "string" and (. | length) == 64)
' >/dev/null 2>&1; then
  fail "internal error: constructed row failed post-build schema check"
fi

# --- Atomic append (jq -c '.' >> $FILE); no read-modify-write ---
printf '%s\n' "$ROW" | jq -c '.' >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg dedupe_key "$DEDUPE_KEY" \
    --arg reason "$REASON" \
    '{path: $path, dedupe_key: $dedupe_key, reason: $reason, appended: true}')
  json_output "$RESULT"
fi

echo "[propagation-miss] Miss for run $SETTLEMENT_RUN_ID (reason=$REASON) appended to $RELPATH"
