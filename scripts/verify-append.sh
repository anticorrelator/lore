#!/usr/bin/env bash
# verify-append.sh — Record a consumption-verification outcome for a
# knowledge entry (`lore verify`).
#
# The consumption-verification front of the trust-ledger write surface: an
# agent that checked a commons entry against real code during task work
# reports the outcome here — `held` (the code confirms the entry) or
# `contradicted` (the code falsifies it). Grounded-or-nothing applies to
# BOTH dispositions: file + line-range + exact-snippet are required, so a
# lazy "held" without a code anchor is rejected the same as an unanchored
# contradiction.
#
# The ledger append is delegated to trust-event-append.sh (the sole physical
# writer of `_trust/trust-events.jsonl`). A `contradicted` report is
# additionally bridged into the existing consumption-contradiction channel
# (`_work/<slug>/consumption-contradictions.jsonl`) through its sole writer,
# which remains the judge-facing dispute payload. Both writers dedupe, so
# re-running an identical invocation is a no-op on both files; the bridge is
# always attempted on contradicted so a partial prior run heals on re-run.
#
# Usage:
#   verify-append.sh <knowledge-path> <held|contradicted>
#       --source <worker|researcher|spec-lead|implement-lead>
#       --file <absolute-path>
#       --line-range <N-M>
#       --exact-snippet <verbatim>
#       # required when disposition is contradicted (the CC bridge needs them):
#       [--work-item <slug>]
#       [--rationale <why the code confirms/falsifies the entry>]
#       [--claim-text <the entry assertion being verified>]
#       [--falsifier <what evidence would disprove>]
#       # optional on both dispositions:
#       [--producer-role <role>]        # default: --source value
#       [--protocol-slot <slot>]        # default: lore-verify
#       [--cycle-id <id>]               # default: verify-<YYYY-MM-DD>
#       [--claim-id <id>]               # default: generated ver-<12hex>
#       [--heading <heading-text>]
#       [--template-version <hash>]
#       [--normalized-snippet-hash <sha256>]
#       [--kdir <path>]
#       [--json]
#
# <knowledge-path> is KDIR-relative (an absolute path under KDIR or a
# trailing-`.md`-less form is normalized); the entry file must exist.
#
# Exit codes:
#   0 — event recorded (or deduped no-op)
#   1 — validation failure, unknown flag, or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: verify-append.sh <knowledge-path> <held|contradicted> \
           --source <worker|researcher|spec-lead|implement-lead> \
           --file <absolute-path> \
           --line-range <N-M> \
           --exact-snippet <verbatim> \
           [--work-item <slug>]          # required for contradicted \
           [--rationale <text>]          # required for contradicted \
           [--claim-text <text>]         # required for contradicted \
           [--falsifier <text>]          # required for contradicted \
           [--producer-role <role>] [--protocol-slot <slot>] \
           [--cycle-id <id>] [--claim-id <id>] [--heading <text>] \
           [--template-version <hash>] [--normalized-snippet-hash <sha256>] \
           [--kdir <path>] [--json]

Record that a knowledge entry was verified against code during task work.
`held` and `contradicted` both require the grounded trio (--file,
--line-range, --exact-snippet). A contradicted report also lands one pending
row in the work item's consumption-contradictions.jsonl through its existing
writer. Re-running an identical invocation is a silent no-op on both files.
EOF
}

KNOWLEDGE_PATH=""
DISPOSITION=""
POSITIONAL_SEEN=0

SOURCE_KIND=""
CLAIM_FILE=""
LINE_RANGE=""
EXACT_SNIPPET=""
WORK_ITEM=""
RATIONALE=""
CLAIM_TEXT=""
FALSIFIER=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
CYCLE_ID=""
CLAIM_ID=""
HEADING=""
TEMPLATE_VERSION=""
NORMALIZED_SNIPPET_HASH=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)                   SOURCE_KIND="$2";              shift 2 ;;
    --file)                     CLAIM_FILE="$2";               shift 2 ;;
    --line-range)               LINE_RANGE="$2";               shift 2 ;;
    --exact-snippet)            EXACT_SNIPPET="$2";            shift 2 ;;
    --work-item)                WORK_ITEM="$2";                shift 2 ;;
    --rationale)                RATIONALE="$2";                shift 2 ;;
    --claim-text)               CLAIM_TEXT="$2";               shift 2 ;;
    --falsifier)                FALSIFIER="$2";                shift 2 ;;
    --producer-role)            PRODUCER_ROLE="$2";            shift 2 ;;
    --protocol-slot)            PROTOCOL_SLOT="$2";            shift 2 ;;
    --cycle-id)                 CYCLE_ID="$2";                 shift 2 ;;
    --claim-id)                 CLAIM_ID="$2";                 shift 2 ;;
    --heading)                  HEADING="$2";                  shift 2 ;;
    --template-version)         TEMPLATE_VERSION="$2";         shift 2 ;;
    --normalized-snippet-hash)  NORMALIZED_SNIPPET_HASH="$2";  shift 2 ;;
    --kdir)                     KDIR_OVERRIDE="$2";            shift 2 ;;
    --json)                     JSON_MODE=1;                   shift ;;
    --help|-h)                  usage; exit 0 ;;
    --*)
      echo "[verify] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ $POSITIONAL_SEEN -eq 0 ]]; then
        KNOWLEDGE_PATH="$1"; POSITIONAL_SEEN=1
      elif [[ $POSITIONAL_SEEN -eq 1 ]]; then
        DISPOSITION="$1"; POSITIONAL_SEEN=2
      else
        echo "[verify] Error: unexpected argument '$1'" >&2
        usage
        exit 1
      fi
      shift
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[verify] $msg"
  fi
  echo "[verify] Error: $msg" >&2
  exit 1
}

# --- Positional validation ---
if [[ -z "$KNOWLEDGE_PATH" ]]; then
  fail "<knowledge-path> is required"
fi
case "$DISPOSITION" in
  held|contradicted) : ;;
  "") fail "disposition is required: held or contradicted" ;;
  *)  fail "disposition must be 'held' or 'contradicted' (got '$DISPOSITION')" ;;
esac

# --- Source enum: agent producers only ---
case "$SOURCE_KIND" in
  worker|researcher|spec-lead|implement-lead) : ;;
  "") fail "--source is required" ;;
  *)  fail "--source must be 'worker', 'researcher', 'spec-lead', or 'implement-lead' (got '$SOURCE_KIND')" ;;
esac

# --- Grounded-or-nothing: BOTH dispositions ---
if [[ -z "$CLAIM_FILE" || -z "$LINE_RANGE" || -z "$EXACT_SNIPPET" ]]; then
  fail "grounded-or-nothing enforced: --file, --line-range, --exact-snippet must all be present and non-empty for disposition '$DISPOSITION'"
fi
if ! printf '%s' "$LINE_RANGE" | grep -Eq '^[0-9]+(-[0-9]+)?$'; then
  fail "--line-range must match 'N' or 'N-M' (got '$LINE_RANGE')"
fi

# --- Contradicted requires the CC-bridge payload ---
if [[ "$DISPOSITION" == "contradicted" ]]; then
  for _pair in \
    "work-item:$WORK_ITEM" \
    "rationale:$RATIONALE" \
    "claim-text:$CLAIM_TEXT" \
    "falsifier:$FALSIFIER"
  do
    if [[ -z "${_pair#*:}" ]]; then
      fail "--${_pair%%:*} is required when disposition is 'contradicted' (the consumption-contradiction bridge needs it)"
    fi
  done
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

# --- Normalize the knowledge path to KDIR-relative with .md ---
ENTRY_PATH="$KNOWLEDGE_PATH"
ENTRY_PATH="${ENTRY_PATH#"$KNOWLEDGE_DIR/"}"
if [[ "$ENTRY_PATH" == /* ]]; then
  fail "knowledge-path must be relative to the knowledge store (got '$KNOWLEDGE_PATH')"
fi
if [[ "$ENTRY_PATH" == *".."* ]]; then
  fail "knowledge-path must not contain '..' (got '$KNOWLEDGE_PATH')"
fi
if [[ ! -f "$KNOWLEDGE_DIR/$ENTRY_PATH" ]]; then
  if [[ -f "$KNOWLEDGE_DIR/$ENTRY_PATH.md" ]]; then
    ENTRY_PATH="$ENTRY_PATH.md"
  else
    fail "knowledge entry not found: $ENTRY_PATH (under $KNOWLEDGE_DIR)"
  fi
fi

# --- Contradicted: verify the work item exists before touching the ledger ---
# The bridge is the second write of a compound operation; validating its
# preconditions up front keeps the ledger and sidecar from diverging on a
# doomed invocation.
if [[ "$DISPOSITION" == "contradicted" && ! -d "$KNOWLEDGE_DIR/_work/$WORK_ITEM" ]]; then
  fail "work item not found: $WORK_ITEM (expected $KNOWLEDGE_DIR/_work/$WORK_ITEM)"
fi

# --- Defaults ---
if [[ -z "$PRODUCER_ROLE" ]]; then
  PRODUCER_ROLE="$SOURCE_KIND"
fi
if [[ -z "$PROTOCOL_SLOT" ]]; then
  PROTOCOL_SLOT="lore-verify"
fi
if [[ -z "$CYCLE_ID" ]]; then
  CYCLE_ID="verify-$(date +%Y-%m-%d)"
fi
if [[ -z "$CLAIM_ID" ]]; then
  CLAIM_ID="ver-$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')"
fi

# --- Append the trust-ledger event (sole physical writer) ---
TRUST_ARGS=(
  --event consumption-verification
  --entry-path "$ENTRY_PATH"
  --source "$SOURCE_KIND"
  --disposition "$DISPOSITION"
  --file "$CLAIM_FILE"
  --line-range "$LINE_RANGE"
  --exact-snippet "$EXACT_SNIPPET"
  --producer-role "$PRODUCER_ROLE"
  --protocol-slot "$PROTOCOL_SLOT"
  --cycle-id "$CYCLE_ID"
  --claim-id "$CLAIM_ID"
  --kdir "$KNOWLEDGE_DIR"
  --json
)
[[ -n "$WORK_ITEM" ]]                && TRUST_ARGS+=(--work-item "$WORK_ITEM")
[[ -n "$RATIONALE" ]]                && TRUST_ARGS+=(--rationale "$RATIONALE")
[[ -n "$CLAIM_TEXT" ]]               && TRUST_ARGS+=(--claim-text "$CLAIM_TEXT")
[[ -n "$FALSIFIER" ]]                && TRUST_ARGS+=(--falsifier "$FALSIFIER")
[[ -n "$HEADING" ]]                  && TRUST_ARGS+=(--heading "$HEADING")
[[ -n "$TEMPLATE_VERSION" ]]         && TRUST_ARGS+=(--template-version "$TEMPLATE_VERSION")
[[ -n "$NORMALIZED_SNIPPET_HASH" ]]  && TRUST_ARGS+=(--normalized-snippet-hash "$NORMALIZED_SNIPPET_HASH")

TRUST_OUT=$(bash "$SCRIPT_DIR/trust-event-append.sh" "${TRUST_ARGS[@]}")
EVENT_ID=$(printf '%s' "$TRUST_OUT" | jq -r '.event_id')
APPENDED=$(printf '%s' "$TRUST_OUT" | jq -r '.appended')

# --- Contradicted: bridge one row into the consumption-contradiction channel ---
# Always attempted (not gated on the ledger dedupe) so a partial prior run
# heals; the CC writer's own dedupe makes this idempotent.
BRIDGE_STATUS=""
CONTRADICTION_ID=""
if [[ "$DISPOSITION" == "contradicted" ]]; then
  CC_ARGS=(
    --work-item "$WORK_ITEM"
    --source "$SOURCE_KIND"
    --producer-role "$PRODUCER_ROLE"
    --protocol-slot "$PROTOCOL_SLOT"
    --cycle-id "$CYCLE_ID"
    --knowledge-path "$ENTRY_PATH"
    --contradiction-rationale "$RATIONALE"
    --claim-id "$CLAIM_ID"
    --claim-text "$CLAIM_TEXT"
    --file "$CLAIM_FILE"
    --line-range "$LINE_RANGE"
    --exact-snippet "$EXACT_SNIPPET"
    --falsifier "$FALSIFIER"
    --kdir "$KNOWLEDGE_DIR"
    --json
  )
  [[ -n "$HEADING" ]]                 && CC_ARGS+=(--heading "$HEADING")
  [[ -n "$TEMPLATE_VERSION" ]]        && CC_ARGS+=(--template-version "$TEMPLATE_VERSION")
  [[ -n "$NORMALIZED_SNIPPET_HASH" ]] && CC_ARGS+=(--normalized-snippet-hash "$NORMALIZED_SNIPPET_HASH")

  CC_OUT=$(bash "$SCRIPT_DIR/consumption-contradiction-append.sh" "${CC_ARGS[@]}")
  if [[ -z "$CC_OUT" ]]; then
    # The CC writer dedupes with a silent exit 0.
    BRIDGE_STATUS="duplicate"
  else
    BRIDGE_STATUS="appended"
    CONTRADICTION_ID=$(printf '%s' "$CC_OUT" | jq -r '.contradiction_id // empty')
  fi
fi

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg entry_path "$ENTRY_PATH" \
    --arg disposition "$DISPOSITION" \
    --arg event_id "$EVENT_ID" \
    --argjson appended "$APPENDED" \
    --arg bridge_status "$BRIDGE_STATUS" \
    --arg contradiction_id "$CONTRADICTION_ID" \
    '{entry_path: $entry_path, disposition: $disposition, event_id: $event_id, appended: $appended}
     + (if $bridge_status != "" then
          {contradiction_bridge: ({status: $bridge_status}
            + (if $contradiction_id != "" then {contradiction_id: $contradiction_id} else {} end))}
        else {} end)')"
fi

if [[ "$APPENDED" == "true" ]]; then
  echo "[verify] $DISPOSITION event $EVENT_ID recorded for $ENTRY_PATH"
else
  echo "[verify] duplicate — $DISPOSITION event for $ENTRY_PATH already recorded ($EVENT_ID)"
fi
if [[ -n "$BRIDGE_STATUS" ]]; then
  if [[ "$BRIDGE_STATUS" == "appended" ]]; then
    echo "[verify] contradiction bridged to _work/$WORK_ITEM/consumption-contradictions.jsonl ($CONTRADICTION_ID)"
  else
    echo "[verify] contradiction already present in _work/$WORK_ITEM/consumption-contradictions.jsonl"
  fi
fi
