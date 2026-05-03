#!/usr/bin/env bash
# consumption-contradiction-append.sh — Append a row to a work item's
# consumption-contradictions sidecar.
#
# Canonical sole-writer for `_work/<slug>/consumption-contradictions.jsonl`.
# Used by agents (workers, researchers, spec-leads, implement-leads) that read
# a prefetched commons entry during task work and observe the code falsifying
# it. The row carries a full audit `claim_payload` so it can flow into
# `lore audit --priority-claims` without field translation.
#
# Schema: architecture/consumption-contradictions/sidecar-schema.md
#
# Usage (see --help for the full flag set):
#   consumption-contradiction-append.sh
#       --work-item <slug>
#       --source <worker|researcher|spec-lead|implement-lead>
#       --producer-role <role>
#       --protocol-slot <slot>
#       --cycle-id <id>
#       --knowledge-path <path-relative-to-KDIR>
#       --contradiction-rationale <text>
#       --claim-id <id>
#       --claim-text <text>
#       --file <absolute-path>
#       --line-range <N-M>
#       --exact-snippet <verbatim>
#       --falsifier <text>
#       [--heading <heading-text>]
#       [--template-version <hash>]
#       [--normalized-snippet-hash <sha256>]
#       [--symbol-anchor <anchor>]
#       [--severity-hint low|medium|high]
#       [--status pending|accepted|declined|remediated]
#       [--contradiction-id <ctr-id>]
#       [--created-at <iso8601>]
#       [--kdir <path>]
#       [--json]
#
# Dedupe: same (source, knowledge_path, heading, file, line_range) sha256 in
# the same work item → silent no-op, exit 0.
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — validation failure, unknown flag, or work-item not found
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `_work/<slug>/consumption-contradictions.jsonl`. All schema validation
# happens before any filesystem access; rejected rows never reach disk. No
# read-modify-write on the sidecar — we only append.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: consumption-contradiction-append.sh \
           --work-item <slug> \
           --source <worker|researcher|spec-lead|implement-lead> \
           --producer-role <role> \
           --protocol-slot <slot> \
           --cycle-id <id> \
           --knowledge-path <path-relative-to-KDIR> \
           --contradiction-rationale <text> \
           --claim-id <id> \
           --claim-text <text> \
           --file <absolute-path> \
           --line-range <N-M> \
           --exact-snippet <verbatim> \
           --falsifier <text> \
           [--heading <heading-text>] \
           [--template-version <hash>] \
           [--normalized-snippet-hash <sha256>] \
           [--symbol-anchor <anchor>] \
           [--severity-hint low|medium|high] \
           [--status pending|accepted|declined|remediated] \
           [--contradiction-id <ctr-id>] \
           [--created-at <iso8601>] \
           [--kdir <path>] \
           [--json]

Append a row to a work item's _work/<slug>/consumption-contradictions.jsonl
sidecar. The row reuses the audit claim_payload shape so it can flow into
`lore audit --priority-claims` without field translation.

Dedupes on sha256(source|knowledge_path|heading|file|line_range) — a
duplicate is a silent no-op (exit 0).
EOF
}

WORK_ITEM=""
SOURCE_KIND=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
TEMPLATE_VERSION=""
CYCLE_ID=""
KNOWLEDGE_PATH=""
HEADING=""
CONTRADICTION_RATIONALE=""
CLAIM_ID=""
CLAIM_TEXT=""
CLAIM_FILE=""
LINE_RANGE=""
EXACT_SNIPPET=""
NORMALIZED_SNIPPET_HASH=""
FALSIFIER=""
SYMBOL_ANCHOR=""
SEVERITY_HINT=""
STATUS=""
CONTRADICTION_ID=""
CREATED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)                WORK_ITEM="$2";                shift 2 ;;
    --source)                   SOURCE_KIND="$2";              shift 2 ;;
    --producer-role)            PRODUCER_ROLE="$2";            shift 2 ;;
    --protocol-slot)            PROTOCOL_SLOT="$2";            shift 2 ;;
    --template-version)         TEMPLATE_VERSION="$2";         shift 2 ;;
    --cycle-id)                 CYCLE_ID="$2";                 shift 2 ;;
    --knowledge-path)           KNOWLEDGE_PATH="$2";           shift 2 ;;
    --heading)                  HEADING="$2";                  shift 2 ;;
    --contradiction-rationale)  CONTRADICTION_RATIONALE="$2";  shift 2 ;;
    --claim-id)                 CLAIM_ID="$2";                 shift 2 ;;
    --claim-text)               CLAIM_TEXT="$2";               shift 2 ;;
    --file)                     CLAIM_FILE="$2";               shift 2 ;;
    --line-range)               LINE_RANGE="$2";               shift 2 ;;
    --exact-snippet)            EXACT_SNIPPET="$2";            shift 2 ;;
    --normalized-snippet-hash)  NORMALIZED_SNIPPET_HASH="$2";  shift 2 ;;
    --falsifier)                FALSIFIER="$2";                shift 2 ;;
    --symbol-anchor)            SYMBOL_ANCHOR="$2";            shift 2 ;;
    --severity-hint)            SEVERITY_HINT="$2";            shift 2 ;;
    --status)                   STATUS="$2";                   shift 2 ;;
    --contradiction-id)         CONTRADICTION_ID="$2";         shift 2 ;;
    --created-at)               CREATED_AT="$2";               shift 2 ;;
    --kdir)                     KDIR_OVERRIDE="$2";            shift 2 ;;
    --json)                     JSON_MODE=1;                   shift ;;
    --help|-h)                  usage; exit 0 ;;
    *)
      echo "[consumption-contradiction] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Error routing helper: JSON mode vs stderr mode ---
fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[consumption-contradiction] $msg"
  fi
  echo "[consumption-contradiction] Error: $msg" >&2
  exit 1
}

# --- Required-field validation (pre-filesystem) ---
for _pair in \
  "work-item:$WORK_ITEM" \
  "source:$SOURCE_KIND" \
  "producer-role:$PRODUCER_ROLE" \
  "protocol-slot:$PROTOCOL_SLOT" \
  "cycle-id:$CYCLE_ID" \
  "knowledge-path:$KNOWLEDGE_PATH" \
  "contradiction-rationale:$CONTRADICTION_RATIONALE" \
  "claim-id:$CLAIM_ID" \
  "claim-text:$CLAIM_TEXT" \
  "file:$CLAIM_FILE" \
  "line-range:$LINE_RANGE" \
  "exact-snippet:$EXACT_SNIPPET" \
  "falsifier:$FALSIFIER"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    fail "--$_flag is required"
  fi
done

# --- Enum validation: --source ---
case "$SOURCE_KIND" in
  worker|researcher|spec-lead|implement-lead) : ;;
  *)
    fail "--source must be 'worker', 'researcher', 'spec-lead', or 'implement-lead' (got '$SOURCE_KIND')"
    ;;
esac

# --- Enum validation: --status (default pending) ---
if [[ -z "$STATUS" ]]; then
  STATUS="pending"
fi
case "$STATUS" in
  pending|accepted|declined|remediated) : ;;
  *)
    fail "--status must be 'pending', 'accepted', 'declined', or 'remediated' (got '$STATUS')"
    ;;
esac

# --- Enum validation: --severity-hint (optional; when supplied must be valid) ---
if [[ -n "$SEVERITY_HINT" ]]; then
  case "$SEVERITY_HINT" in
    low|medium|high) : ;;
    *)
      fail "--severity-hint must be 'low', 'medium', or 'high' (got '$SEVERITY_HINT')"
      ;;
  esac
fi

# --- Grounded-or-nothing: file + line_range + exact_snippet all non-empty ---
# Covered above by the required-field loop; re-assert explicitly so the
# invariant is not silently weakened if the required list is edited later.
if [[ -z "$CLAIM_FILE" || -z "$LINE_RANGE" || -z "$EXACT_SNIPPET" ]]; then
  fail "grounded-or-nothing enforced: --file, --line-range, --exact-snippet must all be present and non-empty"
fi

# --- Line-range shape: "N-M" or "N" ---
if ! printf '%s' "$LINE_RANGE" | grep -Eq '^[0-9]+(-[0-9]+)?$'; then
  fail "--line-range must match 'N' or 'N-M' (got '$LINE_RANGE')"
fi

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

SIDECAR="$WORK_DIR/consumption-contradictions.jsonl"

# --- Defaults for generated fields ---
if [[ -z "$CONTRADICTION_ID" ]]; then
  # Match off-scale-routing / audit-queue-route style: ctr-<12 hex>.
  CONTRADICTION_ID="ctr-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
fi
if [[ -z "$CREATED_AT" ]]; then
  CREATED_AT=$(timestamp_iso)
fi

# --- Branch-provenance trio (always emitted, null sentinel when unavailable) ---
CAPTURED_AT_BRANCH=$(captured_at_branch)
CAPTURED_AT_SHA=$(captured_at_sha)
CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)

# --- Dedupe key: sha256(source|knowledge_path|normalized_heading|file|line_range) ---
# Normalize heading for dedupe-key stability: lowercase + whitespace-collapse.
# Leave the stored heading verbatim (see sidecar-schema.md §heading-normalization).
NORMALIZED_HEADING=$(printf '%s' "$HEADING" | python3 -c '
import re, sys
h = sys.stdin.read()
h = re.sub(r"\s+", " ", h).strip().lower()
print(h, end="")
')

DEDUPE_KEY=$(printf '%s|%s|%s|%s|%s' \
  "$SOURCE_KIND" "$KNOWLEDGE_PATH" "$NORMALIZED_HEADING" "$CLAIM_FILE" "$LINE_RANGE" \
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
# Field conventions:
#   - Branch-provenance trio: always emitted; stored as JSON null when the
#     helper returned the literal string "null".
#   - template_version, symbol_anchor, severity_hint, normalized_snippet_hash:
#     omit-when-empty (absent from the row entirely when the flag was not
#     supplied). This matches the off-scale/audit convention.
#   - heading: stored verbatim even when empty — empty string is meaningful
#     (the commons entry has no section heading).
export CONTRADICTION_ID WORK_ITEM SOURCE_KIND PRODUCER_ROLE PROTOCOL_SLOT \
       CYCLE_ID KNOWLEDGE_PATH HEADING CONTRADICTION_RATIONALE CLAIM_ID \
       CLAIM_TEXT CLAIM_FILE LINE_RANGE EXACT_SNIPPET FALSIFIER STATUS \
       CREATED_AT DEDUPE_KEY CAPTURED_AT_BRANCH CAPTURED_AT_SHA \
       CAPTURED_AT_MERGE_BASE_SHA TEMPLATE_VERSION SYMBOL_ANCHOR \
       SEVERITY_HINT NORMALIZED_SNIPPET_HASH

ROW=$(python3 <<'PY_EOF'
import json, os

def env(name):
    return os.environ.get(name, "")

def provenance(val):
    return None if val == "null" else val

row = {
    "contradiction_id":    env("CONTRADICTION_ID"),
    "verdict_source":      "consumer-contradiction-channel",
    "work_item":           env("WORK_ITEM"),
    "source":              env("SOURCE_KIND"),
    "producer_role":       env("PRODUCER_ROLE"),
    "protocol_slot":       env("PROTOCOL_SLOT"),
    "cycle_id":            env("CYCLE_ID"),
    "prefetched_commons_entry": {
        "knowledge_path": env("KNOWLEDGE_PATH"),
        "heading": env("HEADING"),
    },
    "contradiction_rationale": env("CONTRADICTION_RATIONALE"),
    "claim_payload": {
        "claim_id":    env("CLAIM_ID"),
        "claim_text":  env("CLAIM_TEXT"),
        "file":        env("CLAIM_FILE"),
        "line_range":  env("LINE_RANGE"),
        "exact_snippet": env("EXACT_SNIPPET"),
        "falsifier":   env("FALSIFIER"),
    },
    "status":              env("STATUS"),
    "created_at":          env("CREATED_AT"),
    "resolved_at":         None,
    "resolved_by":         None,
    "dedupe_key":          env("DEDUPE_KEY"),
    "captured_at_branch":          provenance(env("CAPTURED_AT_BRANCH")),
    "captured_at_sha":             provenance(env("CAPTURED_AT_SHA")),
    "captured_at_merge_base_sha":  provenance(env("CAPTURED_AT_MERGE_BASE_SHA")),
}

tv = env("TEMPLATE_VERSION")
if tv:
    row["template_version"] = tv

sa = env("SYMBOL_ANCHOR")
if sa:
    row["claim_payload"]["symbol_anchor"] = sa

sh = env("SEVERITY_HINT")
if sh:
    row["claim_payload"]["severity_hint"] = sh

nsh = env("NORMALIZED_SNIPPET_HASH")
if nsh:
    row["claim_payload"]["normalized_snippet_hash"] = nsh

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
  and (.contradiction_id | type == "string" and . != "")
  and (.verdict_source == "consumer-contradiction-channel")
  and (.work_item | type == "string" and . != "")
  and (.source | type == "string" and . != "")
  and (.producer_role | type == "string" and . != "")
  and (.protocol_slot | type == "string" and . != "")
  and (.cycle_id | type == "string" and . != "")
  and (.prefetched_commons_entry | type == "object")
  and (.prefetched_commons_entry.knowledge_path | type == "string" and . != "")
  and (.contradiction_rationale | type == "string" and . != "")
  and (.claim_payload | type == "object")
  and (.claim_payload.claim_id | type == "string" and . != "")
  and (.claim_payload.file | type == "string" and . != "")
  and (.claim_payload.line_range | type == "string" and . != "")
  and (.claim_payload.exact_snippet | type == "string" and . != "")
  and (.claim_payload.falsifier | type == "string" and . != "")
  and (.status | type == "string" and . != "")
  and (.dedupe_key | type == "string" and (. | length) == 64)
  and (has("captured_at_branch"))
  and (has("captured_at_sha"))
  and (has("captured_at_merge_base_sha"))
' >/dev/null 2>&1; then
  fail "internal error: constructed row failed post-build schema check"
fi

# --- Atomic append (jq -c '.' >> $FILE); no read-modify-write ---
printf '%s\n' "$ROW" | jq -c '.' >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg contradiction_id "$CONTRADICTION_ID" \
    --arg dedupe_key "$DEDUPE_KEY" \
    --arg status "$STATUS" \
    '{path: $path, contradiction_id: $contradiction_id, dedupe_key: $dedupe_key, status: $status, appended: true}')
  json_output "$RESULT"
fi

echo "[consumption-contradiction] Contradiction $CONTRADICTION_ID appended to $RELPATH"
