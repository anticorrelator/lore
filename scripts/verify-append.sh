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
# Finding a contradiction carries responsibility for resolving it, so a
# `contradicted` report must say which of two things the reporter did about it:
#
#   --resolution corrected  the reporter rewrote the entry against the code
#   --resolution disputed   the reporter left a dated marker on the entry
#                           saying what it observed and why it stopped short
#
# Correcting takes evidence that can carry the claim. Two conditions send a
# would-be correction to the disputed branch instead, and the script exits 3
# (`disputed-required`) having written nothing: the reporter's own confidence
# is below `high`, or single-callsite evidence is being used against a claim
# pitched above implementation scale. Neither is a demotion — a marker is a
# real resolution, and the next agent with wider context settles it.
#
# The entry mutation always happens before the ledger append, so every durable
# negative event points at a repair or a marker that already exists. Both
# writes are keyed by stable ids, so a run interrupted between them converges
# when the same invocation is repeated rather than duplicating anything.
#
# The entry edit is delegated to apply-correction.sh (the sole body mutator)
# and the ledger append to trust-event-append.sh (the sole physical writer of
# `_trust/trust-events.jsonl`).
#
# Usage:
#   verify-append.sh <knowledge-path> <held|contradicted>
#       --source <worker|researcher|spec-lead|implement-lead>
#       --file <absolute-path>
#       --line-range <N-M>
#       --exact-snippet <verbatim>
#       # required when disposition is contradicted:
#       [--resolution <corrected|disputed>]
#       [--work-item <slug>]
#       [--rationale <why the code confirms/falsifies the entry>]
#       [--claim-text <the entry assertion being verified>]
#       [--falsifier <what evidence would disprove>]
#       # required when resolution is corrected:
#       [--superseded-text <entry text being replaced>]
#       [--replacement-text <what it becomes>]
#       [--confidence <high|medium|low>]
#       [--evidence-scope <single-callsite|multi-callsite|systemic>]
#       [--claim-scale <implementation|subsystem|architecture|abstract>]
#       # required when resolution is disputed:
#       [--dispute-note <what you observed and why you did not correct>]
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
#   3 — disputed-required: the evidence cannot carry a correction; re-run with
#       --resolution disputed. Nothing was written.

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
           [--resolution <corrected|disputed>]  # required for contradicted \
           [--work-item <slug>]          # required for contradicted \
           [--rationale <text>]          # required for contradicted \
           [--claim-text <text>]         # required for contradicted \
           [--falsifier <text>]          # required for contradicted \
           [--superseded-text <text>]    # required for corrected \
           [--replacement-text <text>]   # required for corrected \
           [--confidence <high|medium|low>]                       # corrected \
           [--evidence-scope <single-callsite|multi-callsite|systemic>]  # corrected \
           [--claim-scale <implementation|subsystem|architecture|abstract>]  # corrected \
           [--dispute-note <text>]       # required for disputed \
           [--producer-role <role>] [--protocol-slot <slot>] \
           [--cycle-id <id>] [--claim-id <id>] [--heading <text>] \
           [--template-version <hash>] [--normalized-snippet-hash <sha256>] \
           [--kdir <path>] [--json]

Record that a knowledge entry was verified against code during task work.
`held` and `contradicted` both require the grounded trio (--file,
--line-range, --exact-snippet). A contradicted report must also resolve what
it found: `--resolution corrected` rewrites the entry, `--resolution disputed`
leaves a dated marker on it. Exit 3 means the evidence cannot carry a
correction — re-run with `--resolution disputed`. Re-running an identical
invocation converges without duplicating anything.
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
RESOLUTION=""
SUPERSEDED_TEXT=""
REPLACEMENT_TEXT=""
CONFIDENCE=""
EVIDENCE_SCOPE=""
CLAIM_SCALE=""
DISPUTE_NOTE=""

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
    --resolution)               RESOLUTION="$2";               shift 2 ;;
    --superseded-text)          SUPERSEDED_TEXT="$2";          shift 2 ;;
    --replacement-text)         REPLACEMENT_TEXT="$2";         shift 2 ;;
    --confidence)               CONFIDENCE="$2";               shift 2 ;;
    --evidence-scope)           EVIDENCE_SCOPE="$2";           shift 2 ;;
    --claim-scale)              CLAIM_SCALE="$2";              shift 2 ;;
    --dispute-note)             DISPUTE_NOTE="$2";             shift 2 ;;
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

# --- Contradicted requires the observation payload and a resolution ---
# Every branch field is checked here, before the first write, so a call that
# cannot complete leaves the ledger and the entry exactly as it found them.
if [[ "$DISPOSITION" == "contradicted" ]]; then
  for _pair in \
    "work-item:$WORK_ITEM" \
    "rationale:$RATIONALE" \
    "claim-text:$CLAIM_TEXT" \
    "falsifier:$FALSIFIER"
  do
    if [[ -z "${_pair#*:}" ]]; then
      fail "--${_pair%%:*} is required when disposition is 'contradicted'"
    fi
  done

  case "$RESOLUTION" in
    corrected|disputed) : ;;
    "") fail "--resolution is required when disposition is 'contradicted': record what you did about the contradiction — 'corrected' (you rewrote the entry) or 'disputed' (you left a dated marker on it)" ;;
    *)  fail "--resolution must be 'corrected' or 'disputed' (got '$RESOLUTION')" ;;
  esac

  if [[ "$RESOLUTION" == "corrected" ]]; then
    for _pair in \
      "superseded-text:$SUPERSEDED_TEXT" \
      "replacement-text:$REPLACEMENT_TEXT" \
      "confidence:$CONFIDENCE" \
      "evidence-scope:$EVIDENCE_SCOPE" \
      "claim-scale:$CLAIM_SCALE"
    do
      if [[ -z "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} is required when --resolution is 'corrected'"
      fi
    done
    case "$CONFIDENCE" in
      high|medium|low) : ;;
      *) fail "--confidence must be 'high', 'medium', or 'low' (got '$CONFIDENCE')" ;;
    esac
    case "$EVIDENCE_SCOPE" in
      single-callsite|multi-callsite|systemic) : ;;
      *) fail "--evidence-scope must be 'single-callsite', 'multi-callsite', or 'systemic' (got '$EVIDENCE_SCOPE')" ;;
    esac
    case "$CLAIM_SCALE" in
      implementation|subsystem|architecture|abstract) : ;;
      *) fail "--claim-scale must be 'implementation', 'subsystem', 'architecture', or 'abstract' (got '$CLAIM_SCALE')" ;;
    esac
    if [[ -n "$DISPUTE_NOTE" ]]; then
      fail "--dispute-note applies only to --resolution disputed"
    fi
  else
    if [[ -z "$DISPUTE_NOTE" ]]; then
      fail "--dispute-note is required when --resolution is 'disputed': say what you observed and why you did not correct the entry"
    fi
    for _pair in \
      "superseded-text:$SUPERSEDED_TEXT" \
      "replacement-text:$REPLACEMENT_TEXT" \
      "confidence:$CONFIDENCE" \
      "evidence-scope:$EVIDENCE_SCOPE" \
      "claim-scale:$CLAIM_SCALE"
    do
      if [[ -n "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} applies only to --resolution corrected"
      fi
    done
  fi
elif [[ -n "$RESOLUTION" ]]; then
  fail "--resolution applies only to disposition 'contradicted'"
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

# --- Contradicted: verify the work item exists before touching anything ---
# It is provenance on both the ledger event and the entry record, so a bad
# slug has to fail here rather than midway through the transaction.
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

CORRECTION_DATE=$(date +%Y-%m-%d)

# --- Corrected: does the evidence carry the claim? ---
# Two conditions route a would-be correction to the disputed branch. Both are
# about whether this reporter's evidence can support this rewrite; neither
# looks at how well-established the entry is. Nothing has been written yet.
if [[ "$DISPOSITION" == "contradicted" && "$RESOLUTION" == "corrected" ]]; then
  DISPUTED_REASON=""
  if [[ "$CONFIDENCE" != "high" ]]; then
    DISPUTED_REASON="your confidence in the correction is '$CONFIDENCE', not 'high'"
  elif [[ "$EVIDENCE_SCOPE" == "single-callsite" && "$CLAIM_SCALE" != "implementation" ]]; then
    DISPUTED_REASON="one callsite cannot settle a claim pitched at $CLAIM_SCALE scale"
  fi
  if [[ -n "$DISPUTED_REASON" ]]; then
    if [[ $JSON_MODE -eq 1 ]]; then
      jq -n --arg entry_path "$ENTRY_PATH" --arg reason "$DISPUTED_REASON" \
        '{outcome: "disputed-required", entry_path: $entry_path, reason: $reason, appended: false}'
    fi
    echo "[verify] disputed-required: $DISPUTED_REASON" >&2
    echo "[verify] Nothing was written. Re-run with --resolution disputed and a --dispute-note recording what you saw; the next agent with wider context can settle it." >&2
    exit 3
  fi
fi

# --- Precompute the verification event id ---
# Must reproduce trust-event-append.sh's canonical basis for this event kind
# byte-for-byte; the assertion after the append catches any drift. Knowing the
# id up front is what lets the entry record name the event that reports it.
EVENT_ID=$(printf '%s|%s|%s|%s|%s|%s' \
  "consumption-verification" "$ENTRY_PATH" "$DISPOSITION" "$SOURCE_KIND" "$CLAIM_FILE" "$LINE_RANGE" \
  | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

# --- Contradicted: put the owner on the entry before the negative event ---
RESOLUTION_REF=""
CORRECTION_BEFORE_SHA=""
CORRECTION_AFTER_SHA=""
CORRECTION_PRIOR_STATUS=""
ENTRY_ACTION=""
if [[ "$DISPOSITION" == "contradicted" ]]; then
  ENTRY_ABS="$KNOWLEDGE_DIR/$ENTRY_PATH"
  EVIDENCE_TEXT="$CLAIM_FILE:$LINE_RANGE — $RATIONALE"

  if [[ "$RESOLUTION" == "corrected" ]]; then
    CORRECTION_OUT=$(bash "$SCRIPT_DIR/apply-correction.sh" \
      --entry "$ENTRY_ABS" \
      --observation-id "$EVENT_ID" \
      --verdict-source peer-verification \
      --allow-peer-verification \
      --evidence "$EVIDENCE_TEXT" \
      --superseded-text "$SUPERSEDED_TEXT" \
      --replacement-text "$REPLACEMENT_TEXT" \
      --date "$CORRECTION_DATE" \
      --kdir "$KNOWLEDGE_DIR")
    RECORD=$(printf '%s\n' "$CORRECTION_OUT" | grep '^\[peer-correction\] result=' | head -1)
    if [[ -z "$RECORD" ]]; then
      fail "the correction mutator reported no result record; entry unchanged"
    fi
    ENTRY_ACTION=$(printf '%s' "$RECORD" | sed -n 's/.*result=\([^ ]*\).*/\1/p')
    RESOLUTION_REF=$(printf '%s' "$RECORD" | sed -n 's/.*correction_id=\([^ ]*\).*/\1/p')
    CORRECTION_BEFORE_SHA=$(printf '%s' "$RECORD" | sed -n 's/.*before_sha256=\([^ ]*\).*/\1/p')
    CORRECTION_AFTER_SHA=$(printf '%s' "$RECORD" | sed -n 's/.*after_sha256=\([^ ]*\).*/\1/p')
    CORRECTION_PRIOR_STATUS=$(printf '%s' "$RECORD" | sed -n 's/.*prior_status=\([^ ]*\).*/\1/p')
    if [[ -z "$RESOLUTION_REF" || -z "$CORRECTION_BEFORE_SHA" || -z "$CORRECTION_AFTER_SHA" ]]; then
      fail "could not read the correction record from the mutator output: $RECORD"
    fi
  else
    DISPUTE_OUT=$(bash "$SCRIPT_DIR/apply-correction.sh" \
      --dispute \
      --entry "$ENTRY_ABS" \
      --observation-id "$EVENT_ID" \
      --verdict-source peer-verification \
      --allow-peer-verification \
      --evidence "$EVIDENCE_TEXT" \
      --dispute-note "$DISPUTE_NOTE" \
      --reported-by "$SOURCE_KIND" \
      --work-item "$WORK_ITEM" \
      --date "$CORRECTION_DATE" \
      --kdir "$KNOWLEDGE_DIR")
    RECORD=$(printf '%s\n' "$DISPUTE_OUT" | grep '^\[dispute\] result=' | head -1)
    if [[ -z "$RECORD" ]]; then
      fail "the dispute mutator reported no result record; entry unchanged"
    fi
    ENTRY_ACTION=$(printf '%s' "$RECORD" | sed -n 's/.*result=\([^ ]*\).*/\1/p')
    RESOLUTION_REF=$(printf '%s' "$RECORD" | sed -n 's/.*dispute_id=\([^ ]*\).*/\1/p')
    if [[ -z "$RESOLUTION_REF" ]]; then
      fail "could not read the dispute record from the mutator output: $RECORD"
    fi
  fi
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
if [[ "$DISPOSITION" == "contradicted" ]]; then
  TRUST_ARGS+=(--resolution "$RESOLUTION" --resolution-ref "$RESOLUTION_REF")
fi

TRUST_OUT=$(bash "$SCRIPT_DIR/trust-event-append.sh" "${TRUST_ARGS[@]}")
LEDGER_EVENT_ID=$(printf '%s' "$TRUST_OUT" | jq -r '.event_id')
APPENDED=$(printf '%s' "$TRUST_OUT" | jq -r '.appended')
if [[ "$LEDGER_EVENT_ID" != "$EVENT_ID" ]]; then
  fail "verification event id mismatch (computed $EVENT_ID, ledger $LEDGER_EVENT_ID) — the canonical basis in trust-event-append.sh and the one recomputed here have diverged"
fi

# --- Corrected: record that the repair landed ---
# The contradiction above is the negative evidence; this event carries no
# weight of its own, and exists so a later reader can find the repaired text
# and check it. Attempted on every run so a prior run that stopped after the
# ledger append completes here.
CORRECTION_APPENDED=""
if [[ "$DISPOSITION" == "contradicted" && "$RESOLUTION" == "corrected" ]]; then
  CORRECTION_ARGS=(
    --event correction
    --entry-path "$ENTRY_PATH"
    --source "$SOURCE_KIND"
    --correction-id "$RESOLUTION_REF"
    --verification-event-id "$EVENT_ID"
    --claim-id "$CLAIM_ID"
    --correction-date "$CORRECTION_DATE"
    --before-sha256 "$CORRECTION_BEFORE_SHA"
    --after-sha256 "$CORRECTION_AFTER_SHA"
    --before-text "$SUPERSEDED_TEXT"
    --after-text "$REPLACEMENT_TEXT"
    --prior-status "$CORRECTION_PRIOR_STATUS"
    --result-status corrected
    --work-item "$WORK_ITEM"
    --kdir "$KNOWLEDGE_DIR"
    --json
  )
  CORRECTION_OUT_JSON=$(bash "$SCRIPT_DIR/trust-event-append.sh" "${CORRECTION_ARGS[@]}")
  CORRECTION_APPENDED=$(printf '%s' "$CORRECTION_OUT_JSON" | jq -r '.appended')
fi

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg entry_path "$ENTRY_PATH" \
    --arg disposition "$DISPOSITION" \
    --arg event_id "$EVENT_ID" \
    --argjson appended "$APPENDED" \
    --arg resolution "$RESOLUTION" \
    --arg resolution_ref "$RESOLUTION_REF" \
    --arg entry_action "$ENTRY_ACTION" \
    --arg correction_appended "$CORRECTION_APPENDED" \
    '{entry_path: $entry_path, disposition: $disposition, event_id: $event_id, appended: $appended}
     + (if $resolution != "" then
          {resolution: $resolution, resolution_ref: $resolution_ref, entry_action: $entry_action}
        else {} end)
     + (if $correction_appended != "" then
          {correction_event_appended: ($correction_appended == "true")}
        else {} end)')"
fi

if [[ "$APPENDED" == "true" ]]; then
  echo "[verify] $DISPOSITION event $EVENT_ID recorded for $ENTRY_PATH"
else
  echo "[verify] duplicate — $DISPOSITION event for $ENTRY_PATH already recorded ($EVENT_ID)"
fi
if [[ "$RESOLUTION" == "corrected" ]]; then
  echo "[verify] resolution: corrected — $ENTRY_PATH rewritten ($RESOLUTION_REF, entry $ENTRY_ACTION)"
elif [[ "$RESOLUTION" == "disputed" ]]; then
  echo "[verify] resolution: disputed — dated marker on $ENTRY_PATH ($RESOLUTION_REF, entry $ENTRY_ACTION)"
fi
