#!/usr/bin/env bash
# correction-candidate-append.sh — Append a row to a work item's
# correction-candidates sidecar.
#
# Canonical sole-writer for `_work/<slug>/correction-candidates.jsonl`.
# The settlement post-verdict hook calls this script when a `contradicted`
# verdict is paired with a resolver-selected target commons entry.
#
# Schema: architecture/artifacts/correction-candidate-schema.md
#
# Usage (see --help):
#   correction-candidate-append.sh
#       --work-item <slug>
#       --candidate-for-verdict-id <id>
#       --settlement-run-id <id>
#       --claim-id <id>
#       --target-entry-path <path>
#       --target-rank <int>
#       --target-overlap true|false
#       --target-sim <float>
#       --verdict-evidence <text>
#       --verdict-correction-text <text>
#       --task-claim-anchor-file <abs-path>
#       --task-claim-anchor-line-range <N-M>
#       --task-claim-anchor-scale <abstract|architecture|subsystem|implementation>
#       --task-claim-anchor-producer-role <role>
#       --task-claim-anchor-change-context <json>
#       --resolver-version <hash>
#       [--candidate-id <id>]
#       [--emitted-at <iso8601>]
#       [--kdir <path>]
#       [--json]
#
# Verdict is fixed to "contradicted" — settlement emits candidates only for
# contradicted verdicts.
#
# Dedupe: sha256(candidate_for_verdict_id|target_entry_path|resolver_version)
# match → silent no-op, exit 0.
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — validation failure, unknown flag, or work-item not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_work/<slug>/correction-candidates.jsonl`. All schema validation happens
# before any filesystem access; rejected rows never reach disk. No
# read-modify-write on the sidecar — we only append.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: correction-candidate-append.sh \
           --work-item <slug> \
           --candidate-for-verdict-id <id> \
           --settlement-run-id <id> \
           --claim-id <id> \
           --target-entry-path <path> \
           --target-rank <int> \
           --target-overlap true|false \
           --target-sim <float> \
           --verdict-evidence <text> \
           --verdict-correction-text <text> \
           --task-claim-anchor-file <abs-path> \
           --task-claim-anchor-line-range <N-M> \
           --task-claim-anchor-scale <abstract|architecture|subsystem|implementation> \
           --task-claim-anchor-producer-role <role> \
           --task-claim-anchor-change-context <json> \
           --resolver-version <hash> \
           [--candidate-id <id>] \
           [--emitted-at <iso8601>] \
           [--kdir <path>] \
           [--json]

Append a row to a work item's _work/<slug>/correction-candidates.jsonl
sidecar. Verdict is fixed to "contradicted". Dedupes on
sha256(candidate_for_verdict_id|target_entry_path|resolver_version) — a
duplicate is a silent no-op (exit 0).
EOF
}

WORK_ITEM=""
CANDIDATE_ID=""
CANDIDATE_FOR_VERDICT_ID=""
SETTLEMENT_RUN_ID=""
CLAIM_ID=""
TARGET_ENTRY_PATH=""
TARGET_RANK=""
TARGET_OVERLAP=""
TARGET_SIM=""
VERDICT_EVIDENCE=""
VERDICT_CORRECTION_TEXT=""
ANCHOR_FILE=""
ANCHOR_LINE_RANGE=""
ANCHOR_SCALE=""
ANCHOR_PRODUCER_ROLE=""
ANCHOR_CHANGE_CONTEXT=""
RESOLVER_VERSION=""
EMITTED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)                            WORK_ITEM="$2";                shift 2 ;;
    --candidate-id)                         CANDIDATE_ID="$2";             shift 2 ;;
    --candidate-for-verdict-id)             CANDIDATE_FOR_VERDICT_ID="$2"; shift 2 ;;
    --settlement-run-id)                    SETTLEMENT_RUN_ID="$2";        shift 2 ;;
    --claim-id)                             CLAIM_ID="$2";                 shift 2 ;;
    --target-entry-path)                    TARGET_ENTRY_PATH="$2";        shift 2 ;;
    --target-rank)                          TARGET_RANK="$2";              shift 2 ;;
    --target-overlap)                       TARGET_OVERLAP="$2";           shift 2 ;;
    --target-sim)                           TARGET_SIM="$2";               shift 2 ;;
    --verdict-evidence)                     VERDICT_EVIDENCE="$2";         shift 2 ;;
    --verdict-correction-text)              VERDICT_CORRECTION_TEXT="$2";  shift 2 ;;
    --task-claim-anchor-file)               ANCHOR_FILE="$2";              shift 2 ;;
    --task-claim-anchor-line-range)         ANCHOR_LINE_RANGE="$2";        shift 2 ;;
    --task-claim-anchor-scale)              ANCHOR_SCALE="$2";             shift 2 ;;
    --task-claim-anchor-producer-role)      ANCHOR_PRODUCER_ROLE="$2";     shift 2 ;;
    --task-claim-anchor-change-context)     ANCHOR_CHANGE_CONTEXT="$2";    shift 2 ;;
    --resolver-version)                     RESOLVER_VERSION="$2";         shift 2 ;;
    --emitted-at)                           EMITTED_AT="$2";               shift 2 ;;
    --kdir)                                 KDIR_OVERRIDE="$2";            shift 2 ;;
    --json)                                 JSON_MODE=1;                   shift ;;
    --help|-h)                              usage; exit 0 ;;
    *)
      echo "[correction-candidate] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Error routing helper: JSON mode vs stderr mode ---
fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[correction-candidate] $msg"
  fi
  echo "[correction-candidate] Error: $msg" >&2
  exit 1
}

# --- Required-field validation (pre-filesystem) ---
# These are the D6 required fields the producer (post-verdict hook) supplies.
# `candidate_id` and `emitted_at` have defaults; all other fields below must
# be present and non-empty before we touch the filesystem.
for _pair in \
  "work-item:$WORK_ITEM" \
  "candidate-for-verdict-id:$CANDIDATE_FOR_VERDICT_ID" \
  "settlement-run-id:$SETTLEMENT_RUN_ID" \
  "claim-id:$CLAIM_ID" \
  "target-entry-path:$TARGET_ENTRY_PATH" \
  "target-rank:$TARGET_RANK" \
  "target-overlap:$TARGET_OVERLAP" \
  "target-sim:$TARGET_SIM" \
  "verdict-evidence:$VERDICT_EVIDENCE" \
  "verdict-correction-text:$VERDICT_CORRECTION_TEXT" \
  "task-claim-anchor-file:$ANCHOR_FILE" \
  "task-claim-anchor-line-range:$ANCHOR_LINE_RANGE" \
  "task-claim-anchor-scale:$ANCHOR_SCALE" \
  "task-claim-anchor-producer-role:$ANCHOR_PRODUCER_ROLE" \
  "task-claim-anchor-change-context:$ANCHOR_CHANGE_CONTEXT" \
  "resolver-version:$RESOLVER_VERSION"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    fail "--$_flag is required"
  fi
done

# --- Enum validation: --task-claim-anchor-scale ---
case "$ANCHOR_SCALE" in
  abstract|architecture|subsystem|implementation) : ;;
  *)
    fail "--task-claim-anchor-scale must be 'abstract', 'architecture', 'subsystem', or 'implementation' (got '$ANCHOR_SCALE')"
    ;;
esac

# --- Boolean validation: --target-overlap ---
case "$TARGET_OVERLAP" in
  true|false) : ;;
  *)
    fail "--target-overlap must be 'true' or 'false' (got '$TARGET_OVERLAP')"
    ;;
esac

# --- Integer validation: --target-rank (≥ 1) ---
if ! printf '%s' "$TARGET_RANK" | grep -Eq '^[1-9][0-9]*$'; then
  fail "--target-rank must be a positive integer (got '$TARGET_RANK')"
fi

# --- Float validation: --target-sim (0.0–1.0 inclusive) ---
if ! printf '%s' "$TARGET_SIM" | python3 -c '
import sys
s = sys.stdin.read().strip()
try:
    v = float(s)
except ValueError:
    sys.exit(1)
if not (0.0 <= v <= 1.0):
    sys.exit(1)
' >/dev/null 2>&1; then
  fail "--target-sim must be a float in [0.0, 1.0] (got '$TARGET_SIM')"
fi

# --- Line-range shape: "N" or "N-M" ---
if ! printf '%s' "$ANCHOR_LINE_RANGE" | grep -Eq '^[0-9]+(-[0-9]+)?$'; then
  fail "--task-claim-anchor-line-range must match 'N' or 'N-M' (got '$ANCHOR_LINE_RANGE')"
fi

# --- task_claim_anchor_change_context must be a JSON object ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi
if ! printf '%s' "$ANCHOR_CHANGE_CONTEXT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "--task-claim-anchor-change-context must be a JSON object (got: $(printf '%s' "$ANCHOR_CHANGE_CONTEXT" | head -c 80))"
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

SIDECAR="$WORK_DIR/correction-candidates.jsonl"

# --- Defaults for generated fields ---
if [[ -z "$CANDIDATE_ID" ]]; then
  CANDIDATE_ID="cc-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
fi
if [[ -z "$EMITTED_AT" ]]; then
  EMITTED_AT=$(timestamp_iso)
fi

# --- Dedupe key: sha256(candidate_for_verdict_id|target_entry_path|resolver_version) ---
DEDUPE_KEY=$(printf '%s|%s|%s' \
  "$CANDIDATE_FOR_VERDICT_ID" "$TARGET_ENTRY_PATH" "$RESOLVER_VERSION" \
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
export CANDIDATE_ID CANDIDATE_FOR_VERDICT_ID SETTLEMENT_RUN_ID WORK_ITEM \
       CLAIM_ID TARGET_ENTRY_PATH TARGET_RANK TARGET_OVERLAP TARGET_SIM \
       VERDICT_EVIDENCE VERDICT_CORRECTION_TEXT ANCHOR_FILE \
       ANCHOR_LINE_RANGE ANCHOR_SCALE ANCHOR_PRODUCER_ROLE \
       ANCHOR_CHANGE_CONTEXT RESOLVER_VERSION EMITTED_AT DEDUPE_KEY

ROW=$(python3 <<'PY_EOF'
import json, os

def env(name):
    return os.environ.get(name, "")

row = {
    "candidate_id":              env("CANDIDATE_ID"),
    "candidate_for_verdict_id":  env("CANDIDATE_FOR_VERDICT_ID"),
    "settlement_run_id":         env("SETTLEMENT_RUN_ID"),
    "work_item":                 env("WORK_ITEM"),
    "claim_id":                  env("CLAIM_ID"),
    "target_entry_path":         env("TARGET_ENTRY_PATH"),
    "target_rank":               int(env("TARGET_RANK")),
    "target_overlap":            env("TARGET_OVERLAP") == "true",
    "target_sim":                float(env("TARGET_SIM")),
    "verdict":                   "contradicted",
    "verdict_evidence":          env("VERDICT_EVIDENCE"),
    "verdict_correction_text":   env("VERDICT_CORRECTION_TEXT"),
    "task_claim_anchor": {
        "file":            env("ANCHOR_FILE"),
        "line_range":      env("ANCHOR_LINE_RANGE"),
        "scale":           env("ANCHOR_SCALE"),
        "producer_role":   env("ANCHOR_PRODUCER_ROLE"),
        "change_context":  json.loads(env("ANCHOR_CHANGE_CONTEXT")),
    },
    "resolver_version":  env("RESOLVER_VERSION"),
    "emitted_at":        env("EMITTED_AT"),
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
# object with all required top-level fields, the fixed verdict literal, the
# correct dedupe_key length, and a well-formed task_claim_anchor.
if ! printf '%s' "$ROW" | jq -e '
  type == "object"
  and (.candidate_id | type == "string" and . != "")
  and (.candidate_for_verdict_id | type == "string" and . != "")
  and (.settlement_run_id | type == "string" and . != "")
  and (.work_item | type == "string" and . != "")
  and (.claim_id | type == "string" and . != "")
  and (.target_entry_path | type == "string" and . != "")
  and (.target_rank | type == "number" and . >= 1)
  and (.target_overlap | type == "boolean")
  and (.target_sim | type == "number" and . >= 0 and . <= 1)
  and (.verdict == "contradicted")
  and (.verdict_evidence | type == "string" and . != "")
  and (.verdict_correction_text | type == "string" and . != "")
  and (.task_claim_anchor | type == "object")
  and (.task_claim_anchor.file | type == "string" and . != "")
  and (.task_claim_anchor.line_range | type == "string" and . != "")
  and (.task_claim_anchor.scale | type == "string" and (. | test("^(abstract|architecture|subsystem|implementation)$")))
  and (.task_claim_anchor.producer_role | type == "string" and . != "")
  and (.task_claim_anchor.change_context | type == "object")
  and (.resolver_version | type == "string" and . != "")
  and (.emitted_at | type == "string" and . != "")
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
    --arg candidate_id "$CANDIDATE_ID" \
    --arg dedupe_key "$DEDUPE_KEY" \
    '{path: $path, candidate_id: $candidate_id, dedupe_key: $dedupe_key, appended: true}')
  json_output "$RESULT"
fi

echo "[correction-candidate] Candidate $CANDIDATE_ID appended to $RELPATH"
