#!/usr/bin/env bash
# trust-event-append.sh — Append a validated event row to the trust ledger.
#
# Canonical sole-writer for `$KDIR/_trust/trust-events.jsonl` — the single
# global append-only stream of per-entry trust events. Every other emitter
# (verify-append.sh, trust-event-migrate.sh, orchestrators) shells out to
# this script; nothing else may write the file. All schema validation
# happens before any filesystem access; rejected rows never reach disk. No
# read-modify-write on the ledger — we only append.
#
# Schema + dedupe-key recipes: architecture/trust-ledger/README.md (in KDIR)
#
# Event kinds and their payload flags:
#   consumption-verification  --disposition held|contradicted
#                             --file <abs> --line-range <N-M> --exact-snippet <s>
#                             # contradicted only, both required:
#                             --resolution corrected|disputed
#                             --resolution-ref <correction-id|dispute-id>
#                             [--normalized-snippet-hash <sha256>]
#                             [--work-item --producer-role --protocol-slot
#                              --cycle-id --claim-id --claim-text --rationale
#                              --falsifier --heading --template-version]
#   correction                --correction-id <id> --verification-event-id <sha256>
#                             --claim-id <id> --correction-date <YYYY-MM-DD>
#                             --before-sha256 <sha256> --after-sha256 <sha256>
#                             --prior-status <s> --result-status corrected
#                             [--before-text --after-text --work-item]
#   retirement                --action retired|restored --retirement-id <id>
#                             --prior-status <s> --result-status <s>
#                             # --action retired:
#                             --reason <s> --falsifier <s>
#                             # --action restored:
#                             --note <s> --restores-retirement-id <id>
#                             [--inbound-backlinks N] [--work-item <slug>]
#   mechanical-check          --check-name <s> --target <s>
#                             --result pass|fail|error|skip --run-id <id>
#                             [--detail <s>]
#   adjudication              --claim-id <id> --verdict confirmed|rejected
#                             --template-id <s> --template-version <hash>
#                             --run-id <id>
#   provenance-migration      --from-entry-path <rel> --to-entry-path <rel>
#                             --reason l3-supersede|renormalize-restructure
#                             [--verdict-id <id>]
#   trust-confirmation        --verdict held|contradicted --sha <hex>
#                             [--note <text>]
#
# Common flags:
#   --event <kind>            required
#   --entry-path <rel>        required (KDIR-relative; for provenance-migration
#                             it defaults to --to-entry-path and must match it
#                             when supplied)
#   --source <enum>           required: worker|researcher|spec-lead|
#                             implement-lead|drift-sweep|expire-sweep|audit|
#                             settlement|apply-correction|renormalize|interactive|
#                             coordinator
#   [--observed-at <iso8601>] [--kdir <path>] [--json]
#
# Grounded-or-nothing: consumption-verification rows require file, line-range,
# and exact-snippet for BOTH dispositions — a held report without a code
# anchor is rejected the same as an unanchored contradiction.
#
# Resolution-or-nothing: a `contradicted` row must name the repair that owns it
# (--resolution plus --resolution-ref pointing at the correction or dispute
# marker on the entry). A negative trust event with nobody accountable for the
# entry it decrements is rejected here, so no caller can express one.
#
# The `correction` event records that a repair landed. It is deliberately
# zero-weight in the trust fold (trust-compute.py): the contradiction that
# triggered it is the negative evidence, and counting the repair again would
# score the same observation twice.
#
# The `retirement` event records that an entry left the default result set, or
# came back. It is zero-weight for a different reason: a retirement is a claim
# about relevance, not about truth, and scoring it would conflate "no longer
# needed" with "wrong". `action` is part of the dedupe basis, so a
# retire -> restore -> retire cycle appends three distinct rows.
#
# `result_status` distinguishes the two ways an entry leaves that set: `retired`
# when a person judged it no longer relevant, `expired` when a clock ran out on
# an unresolved claim. The `expire-sweep` source belongs to the second — it is
# what expire-sweep.sh reports as, and the reason someone auditing the sweep can
# separate its rows from anybody's hand retirement. Both are zero-weight; the
# distinction is for the reader, not the fold.
#
# Dedupe: event_id = sha256 of a pipe-joined canonical basis per event kind
# (see README). A row whose event_id already exists is a silent no-op, exit 0
# (`"appended": false` under --json).
#
# Exit codes:
#   0 — row appended OR deduped no-op
#   1 — validation failure or unknown flag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: trust-event-append.sh \
           --event <mechanical-check|consumption-verification|correction|retirement|adjudication|provenance-migration|trust-confirmation> \
           --entry-path <path-relative-to-KDIR> \
           --source <worker|researcher|spec-lead|implement-lead|drift-sweep|expire-sweep|audit|settlement|apply-correction|renormalize|interactive|coordinator> \
           [--observed-at <iso8601>] [--kdir <path>] [--json] \
           <event-specific payload flags>

Event-specific payload flags:
  consumption-verification:
      --disposition <held|contradicted> --file <abs> --line-range <N-M> \
      --exact-snippet <verbatim> [--normalized-snippet-hash <sha256>] \
      --resolution <corrected|disputed>   # contradicted only, required \
      --resolution-ref <id>               # contradicted only, required \
      [--work-item <slug>] [--producer-role <role>] [--protocol-slot <slot>] \
      [--cycle-id <id>] [--claim-id <id>] [--claim-text <text>] \
      [--rationale <text>] [--falsifier <text>] [--heading <text>] \
      [--template-version <hash>]
  correction:
      --correction-id <id> --verification-event-id <sha256> --claim-id <id> \
      --correction-date <YYYY-MM-DD> --before-sha256 <sha256> \
      --after-sha256 <sha256> --prior-status <status> --result-status corrected \
      [--before-text <text>] [--after-text <text>] [--work-item <slug>]
  retirement:
      --action <retired|restored> --retirement-id <id> \
      --prior-status <status> --result-status <status> \
      --reason <text> --falsifier <text>          # --action retired \
      --note <text> --restores-retirement-id <id> # --action restored \
      [--inbound-backlinks <N>] [--work-item <slug>]
  mechanical-check:
      --check-name <name> --target <s> --result <pass|fail|error|skip> \
      --run-id <id> [--detail <text>]
  adjudication:
      --claim-id <id> --verdict <confirmed|rejected> --template-id <id> \
      --template-version <hash> --run-id <id>
  provenance-migration:
      --from-entry-path <rel> --to-entry-path <rel> \
      --reason <l3-supersede|renormalize-restructure> [--verdict-id <id>]
  trust-confirmation:
      --verdict <held|contradicted> --sha <hex> [--note <text>]

Appends one validated row to $KDIR/_trust/trust-events.jsonl. Duplicate
event_id is a silent no-op (exit 0). Schema and dedupe-key recipes:
architecture/trust-ledger/README.md in the knowledge store.
EOF
}

EVENT=""
ENTRY_PATH=""
SOURCE_KIND=""
OBSERVED_AT=""
KDIR_OVERRIDE=""
JSON_MODE=0
# consumption-verification payload
DISPOSITION=""
CLAIM_FILE=""
LINE_RANGE=""
EXACT_SNIPPET=""
NORMALIZED_SNIPPET_HASH=""
WORK_ITEM=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
CYCLE_ID=""
CLAIM_ID=""
CLAIM_TEXT=""
RATIONALE=""
FALSIFIER=""
HEADING=""
TEMPLATE_VERSION=""
RESOLUTION=""
RESOLUTION_REF=""
# correction payload
CORRECTION_ID=""
VERIFICATION_EVENT_ID=""
CORRECTION_DATE=""
BEFORE_SHA256=""
AFTER_SHA256=""
BEFORE_TEXT=""
AFTER_TEXT=""
PRIOR_STATUS=""
RESULT_STATUS=""
# retirement payload
ACTION=""
RETIREMENT_ID=""
RESTORES_RETIREMENT_ID=""
INBOUND_BACKLINKS=""
# mechanical-check payload
CHECK_NAME=""
TARGET=""
RESULT=""
RUN_ID=""
DETAIL=""
# adjudication payload
VERDICT=""
TEMPLATE_ID=""
# provenance-migration payload
FROM_ENTRY_PATH=""
TO_ENTRY_PATH=""
REASON=""
VERDICT_ID=""
# trust-confirmation payload
SHA=""
NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --event)                    EVENT="$2";                    shift 2 ;;
    --entry-path)               ENTRY_PATH="$2";               shift 2 ;;
    --source)                   SOURCE_KIND="$2";              shift 2 ;;
    --observed-at)              OBSERVED_AT="$2";              shift 2 ;;
    --kdir)                     KDIR_OVERRIDE="$2";            shift 2 ;;
    --json)                     JSON_MODE=1;                   shift ;;
    --disposition)              DISPOSITION="$2";              shift 2 ;;
    --file)                     CLAIM_FILE="$2";               shift 2 ;;
    --line-range)               LINE_RANGE="$2";               shift 2 ;;
    --exact-snippet)            EXACT_SNIPPET="$2";            shift 2 ;;
    --normalized-snippet-hash)  NORMALIZED_SNIPPET_HASH="$2";  shift 2 ;;
    --work-item)                WORK_ITEM="$2";                shift 2 ;;
    --producer-role)            PRODUCER_ROLE="$2";            shift 2 ;;
    --protocol-slot)            PROTOCOL_SLOT="$2";            shift 2 ;;
    --cycle-id)                 CYCLE_ID="$2";                 shift 2 ;;
    --claim-id)                 CLAIM_ID="$2";                 shift 2 ;;
    --claim-text)               CLAIM_TEXT="$2";               shift 2 ;;
    --rationale)                RATIONALE="$2";                shift 2 ;;
    --falsifier)                FALSIFIER="$2";                shift 2 ;;
    --heading)                  HEADING="$2";                  shift 2 ;;
    --template-version)         TEMPLATE_VERSION="$2";         shift 2 ;;
    --resolution)               RESOLUTION="$2";               shift 2 ;;
    --resolution-ref)           RESOLUTION_REF="$2";           shift 2 ;;
    --correction-id)            CORRECTION_ID="$2";            shift 2 ;;
    --verification-event-id)    VERIFICATION_EVENT_ID="$2";    shift 2 ;;
    --correction-date)          CORRECTION_DATE="$2";          shift 2 ;;
    --before-sha256)            BEFORE_SHA256="$2";            shift 2 ;;
    --after-sha256)             AFTER_SHA256="$2";             shift 2 ;;
    --before-text)              BEFORE_TEXT="$2";              shift 2 ;;
    --after-text)               AFTER_TEXT="$2";               shift 2 ;;
    --prior-status)             PRIOR_STATUS="$2";             shift 2 ;;
    --result-status)            RESULT_STATUS="$2";            shift 2 ;;
    --action)                   ACTION="$2";                   shift 2 ;;
    --retirement-id)            RETIREMENT_ID="$2";            shift 2 ;;
    --restores-retirement-id)   RESTORES_RETIREMENT_ID="$2";   shift 2 ;;
    --inbound-backlinks)        INBOUND_BACKLINKS="$2";        shift 2 ;;
    --check-name)               CHECK_NAME="$2";               shift 2 ;;
    --target)                   TARGET="$2";                   shift 2 ;;
    --result)                   RESULT="$2";                   shift 2 ;;
    --run-id)                   RUN_ID="$2";                   shift 2 ;;
    --detail)                   DETAIL="$2";                   shift 2 ;;
    --verdict)                  VERDICT="$2";                  shift 2 ;;
    --template-id)              TEMPLATE_ID="$2";              shift 2 ;;
    --from-entry-path)          FROM_ENTRY_PATH="$2";          shift 2 ;;
    --to-entry-path)            TO_ENTRY_PATH="$2";            shift 2 ;;
    --reason)                   REASON="$2";                   shift 2 ;;
    --verdict-id)               VERDICT_ID="$2";               shift 2 ;;
    --sha)                      SHA="$2";                      shift 2 ;;
    --note)                     NOTE="$2";                     shift 2 ;;
    --help|-h)                  usage; exit 0 ;;
    *)
      echo "[trust-event] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[trust-event] $msg"
  fi
  echo "[trust-event] Error: $msg" >&2
  exit 1
}

# --- Event-kind enum ---
case "$EVENT" in
  mechanical-check|consumption-verification|correction|retirement|adjudication|provenance-migration|trust-confirmation) : ;;
  "") fail "--event is required" ;;
  *)  fail "--event must be 'mechanical-check', 'consumption-verification', 'correction', 'retirement', 'adjudication', 'provenance-migration', or 'trust-confirmation' (got '$EVENT')" ;;
esac

# --- Source enum ---
case "$SOURCE_KIND" in
  worker|researcher|spec-lead|implement-lead|drift-sweep|expire-sweep|audit|settlement|apply-correction|renormalize|interactive|coordinator) : ;;
  "") fail "--source is required" ;;
  *)  fail "--source must be one of worker|researcher|spec-lead|implement-lead|drift-sweep|expire-sweep|audit|settlement|apply-correction|renormalize|interactive|coordinator (got '$SOURCE_KIND')" ;;
esac

# --- Entry-path shape: KDIR-relative, no traversal ---
validate_rel_path() {
  local flag="$1" val="$2"
  if [[ -z "$val" ]]; then
    fail "$flag is required"
  fi
  if [[ "$val" == /* ]]; then
    fail "$flag must be KDIR-relative, not absolute (got '$val')"
  fi
  if [[ "$val" == *".."* ]]; then
    fail "$flag must not contain '..' (got '$val')"
  fi
}

# --- Per-event payload validation ---
case "$EVENT" in
  consumption-verification)
    case "$DISPOSITION" in
      held|contradicted) : ;;
      "") fail "--disposition is required for consumption-verification" ;;
      *)  fail "--disposition must be 'held' or 'contradicted' (got '$DISPOSITION')" ;;
    esac
    # Grounded-or-nothing on BOTH dispositions.
    if [[ -z "$CLAIM_FILE" || -z "$LINE_RANGE" || -z "$EXACT_SNIPPET" ]]; then
      fail "grounded-or-nothing enforced: --file, --line-range, --exact-snippet must all be present and non-empty for disposition '$DISPOSITION'"
    fi
    if ! printf '%s' "$LINE_RANGE" | grep -Eq '^[0-9]+(-[0-9]+)?$'; then
      fail "--line-range must match 'N' or 'N-M' (got '$LINE_RANGE')"
    fi
    # Resolution-or-nothing: a contradicted row must name its owning repair.
    if [[ "$DISPOSITION" == "contradicted" ]]; then
      case "$RESOLUTION" in
        corrected|disputed) : ;;
        "") fail "--resolution is required when --disposition is 'contradicted': every negative event must name the repair that owns it ('corrected' or 'disputed')" ;;
        *)  fail "--resolution must be 'corrected' or 'disputed' (got '$RESOLUTION')" ;;
      esac
      if [[ -z "$RESOLUTION_REF" ]]; then
        fail "--resolution-ref is required when --disposition is 'contradicted' (the correction or dispute-marker id recorded on the entry)"
      fi
    else
      if [[ -n "$RESOLUTION" || -n "$RESOLUTION_REF" ]]; then
        fail "--resolution and --resolution-ref apply only to --disposition contradicted"
      fi
    fi
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
  correction)
    for _pair in \
      "correction-id:$CORRECTION_ID" \
      "verification-event-id:$VERIFICATION_EVENT_ID" \
      "claim-id:$CLAIM_ID" \
      "correction-date:$CORRECTION_DATE" \
      "before-sha256:$BEFORE_SHA256" \
      "after-sha256:$AFTER_SHA256" \
      "prior-status:$PRIOR_STATUS" \
      "result-status:$RESULT_STATUS"
    do
      if [[ -z "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} is required for correction"
      fi
    done
    for _pair in \
      "verification-event-id:$VERIFICATION_EVENT_ID" \
      "before-sha256:$BEFORE_SHA256" \
      "after-sha256:$AFTER_SHA256"
    do
      if ! printf '%s' "${_pair#*:}" | grep -Eq '^[0-9a-f]{64}$'; then
        fail "--${_pair%%:*} must be a lowercase 64-char sha256 hex digest (got '${_pair#*:}')"
      fi
    done
    if ! printf '%s' "$CORRECTION_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      fail "--correction-date must match YYYY-MM-DD (got '$CORRECTION_DATE')"
    fi
    if [[ "$RESULT_STATUS" != "corrected" ]]; then
      fail "--result-status must be 'corrected' (got '$RESULT_STATUS')"
    fi
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
  retirement)
    case "$ACTION" in
      retired|restored) : ;;
      "") fail "--action is required for retirement" ;;
      *)  fail "--action must be 'retired' or 'restored' (got '$ACTION')" ;;
    esac
    for _pair in \
      "retirement-id:$RETIREMENT_ID" \
      "prior-status:$PRIOR_STATUS" \
      "result-status:$RESULT_STATUS"
    do
      if [[ -z "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} is required for retirement"
      fi
    done
    if [[ "$ACTION" == "retired" ]]; then
      # The falsifier is what a retirement grounds on, the way an anchor
      # grounds a consumption-verification: without it the next reader has to
      # reconstruct the retiring agent's reasoning instead of checking one fact.
      for _pair in "reason:$REASON" "falsifier:$FALSIFIER"; do
        if [[ -z "${_pair#*:}" ]]; then
          fail "--${_pair%%:*} is required when --action is 'retired'"
        fi
      done
      for _pair in "note:$NOTE" "restores-retirement-id:$RESTORES_RETIREMENT_ID"; do
        if [[ -n "${_pair#*:}" ]]; then
          fail "--${_pair%%:*} applies only to --action restored"
        fi
      done
    else
      for _pair in "note:$NOTE" "restores-retirement-id:$RESTORES_RETIREMENT_ID"; do
        if [[ -z "${_pair#*:}" ]]; then
          fail "--${_pair%%:*} is required when --action is 'restored'"
        fi
      done
      for _pair in "reason:$REASON" "falsifier:$FALSIFIER"; do
        if [[ -n "${_pair#*:}" ]]; then
          fail "--${_pair%%:*} applies only to --action retired"
        fi
      done
    fi
    if [[ -n "$INBOUND_BACKLINKS" ]] && ! printf '%s' "$INBOUND_BACKLINKS" | grep -Eq '^[0-9]+$'; then
      fail "--inbound-backlinks must be a non-negative integer (got '$INBOUND_BACKLINKS')"
    fi
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
  mechanical-check)
    for _pair in "check-name:$CHECK_NAME" "target:$TARGET" "result:$RESULT" "run-id:$RUN_ID"; do
      if [[ -z "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} is required for mechanical-check"
      fi
    done
    case "$RESULT" in
      pass|fail|error|skip) : ;;
      *) fail "--result must be 'pass', 'fail', 'error', or 'skip' (got '$RESULT')" ;;
    esac
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
  adjudication)
    for _pair in "claim-id:$CLAIM_ID" "verdict:$VERDICT" "template-id:$TEMPLATE_ID" "template-version:$TEMPLATE_VERSION" "run-id:$RUN_ID"; do
      if [[ -z "${_pair#*:}" ]]; then
        fail "--${_pair%%:*} is required for adjudication"
      fi
    done
    case "$VERDICT" in
      confirmed|rejected) : ;;
      *) fail "--verdict must be 'confirmed' or 'rejected' (got '$VERDICT'); emitters map judge vocabulary at the call site" ;;
    esac
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
  provenance-migration)
    validate_rel_path "--from-entry-path" "$FROM_ENTRY_PATH"
    validate_rel_path "--to-entry-path" "$TO_ENTRY_PATH"
    if [[ "$FROM_ENTRY_PATH" == "$TO_ENTRY_PATH" ]]; then
      fail "--from-entry-path and --to-entry-path must differ"
    fi
    case "$REASON" in
      l3-supersede|renormalize-restructure) : ;;
      "") fail "--reason is required for provenance-migration" ;;
      *)  fail "--reason must be 'l3-supersede' or 'renormalize-restructure' (got '$REASON'); only sanctioned mutation paths emit migrations" ;;
    esac
    # entry_path is the entry's post-migration identity.
    if [[ -z "$ENTRY_PATH" ]]; then
      ENTRY_PATH="$TO_ENTRY_PATH"
    elif [[ "$ENTRY_PATH" != "$TO_ENTRY_PATH" ]]; then
      fail "--entry-path must equal --to-entry-path for provenance-migration (got '$ENTRY_PATH' vs '$TO_ENTRY_PATH')"
    fi
    ;;
  trust-confirmation)
    case "$VERDICT" in
      held|contradicted) : ;;
      "") fail "--verdict is required for trust-confirmation" ;;
      *)  fail "--verdict must be 'held' or 'contradicted' (got '$VERDICT'); the confirm front maps 'holds' to 'held'" ;;
    esac
    if [[ -z "$SHA" ]]; then
      fail "--sha is required for trust-confirmation"
    fi
    if ! printf '%s' "$SHA" | grep -Eq '^[0-9a-fA-F]{7,}$'; then
      fail "--sha must be a hex string of at least 7 characters (got '$SHA')"
    fi
    validate_rel_path "--entry-path" "$ENTRY_PATH"
    ;;
esac

# --- jq availability ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

# --- Normalized snippet hash: compute when absent, verify when supplied ---
if [[ "$EVENT" == "consumption-verification" ]]; then
  COMPUTED_HASH=$(printf '%s' "$EXACT_SNIPPET" | python3 "$SCRIPT_DIR/snippet_normalize.py" --hash)
  if [[ -z "$NORMALIZED_SNIPPET_HASH" ]]; then
    NORMALIZED_SNIPPET_HASH="$COMPUTED_HASH"
  elif [[ "$NORMALIZED_SNIPPET_HASH" != "$COMPUTED_HASH" ]]; then
    fail "--normalized-snippet-hash does not match sha256(v1_normalize(exact_snippet)): expected $COMPUTED_HASH"
  fi
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

LEDGER_DIR="$KNOWLEDGE_DIR/_trust"
LEDGER="$LEDGER_DIR/trust-events.jsonl"

if [[ -z "$OBSERVED_AT" ]]; then
  OBSERVED_AT=$(timestamp_iso)
fi

# --- Branch-provenance trio (always emitted, null sentinel when unavailable) ---
CAPTURED_AT_BRANCH=$(captured_at_branch)
CAPTURED_AT_SHA=$(captured_at_sha)
CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)

# --- Dedupe key (event_id): sha256 of the pipe-joined canonical basis ---
# The basis per event kind is a protocol constant shared with any reader that
# recomputes it — see architecture/trust-ledger/README.md. All components are
# single-valued; a future multi-valued component must be sorted before joining.
case "$EVENT" in
  consumption-verification)
    # The basis excludes resolution: an upgraded row for an observation already
    # in the ledger must dedupe against it rather than decrementing twice.
    KEY_BASIS=$(printf '%s|%s|%s|%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$DISPOSITION" "$SOURCE_KIND" "$CLAIM_FILE" "$LINE_RANGE")
    ;;
  correction)
    KEY_BASIS=$(printf '%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$VERIFICATION_EVENT_ID")
    ;;
  retirement)
    # `action` is in the basis so the two directions never collapse into one
    # row, and a later retirement of the same entry carries a fresh id.
    KEY_BASIS=$(printf '%s|%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$ACTION" "$RETIREMENT_ID")
    ;;
  mechanical-check)
    KEY_BASIS=$(printf '%s|%s|%s|%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$CHECK_NAME" "$TARGET" "$RESULT" "$RUN_ID")
    ;;
  adjudication)
    KEY_BASIS=$(printf '%s|%s|%s|%s|%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$CLAIM_ID" "$VERDICT" "$TEMPLATE_ID" "$TEMPLATE_VERSION" "$RUN_ID")
    ;;
  provenance-migration)
    KEY_BASIS=$(printf '%s|%s|%s|%s' \
      "$EVENT" "$FROM_ENTRY_PATH" "$TO_ENTRY_PATH" "$REASON")
    ;;
  trust-confirmation)
    KEY_BASIS=$(printf '%s|%s|%s|%s|%s' \
      "$EVENT" "$ENTRY_PATH" "$VERDICT" "$SOURCE_KIND" "$SHA")
    ;;
esac

EVENT_ID=$(printf '%s' "$KEY_BASIS" | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

# --- Dedupe check: silent no-op exit 0 on match ---
if [[ -f "$LEDGER" ]]; then
  if python3 -c '
import json, sys
ledger, key = sys.argv[1:3]
try:
    with open(ledger) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if row.get("event_id") == key:
                sys.exit(0)
    sys.exit(1)
except FileNotFoundError:
    sys.exit(1)
' "$LEDGER" "$EVENT_ID"; then
    if [[ $JSON_MODE -eq 1 ]]; then
      json_output "$(jq -n --arg event_id "$EVENT_ID" --arg event "$EVENT" \
        '{event_id: $event_id, event: $event, appended: false}')"
    fi
    exit 0
  fi
fi

# --- Build the row via Python (correct escaping for quotes/newlines) ---
# Optional payload fields are omit-when-empty; heading is stored verbatim
# including empty string only when the flag was supplied — matching the
# consumption-contradiction writer's convention is unnecessary here, so
# heading is plain omit-when-empty.
export EVENT ENTRY_PATH SOURCE_KIND OBSERVED_AT EVENT_ID \
       CAPTURED_AT_BRANCH CAPTURED_AT_SHA CAPTURED_AT_MERGE_BASE_SHA \
       DISPOSITION CLAIM_FILE LINE_RANGE EXACT_SNIPPET NORMALIZED_SNIPPET_HASH \
       WORK_ITEM PRODUCER_ROLE PROTOCOL_SLOT CYCLE_ID CLAIM_ID CLAIM_TEXT \
       RATIONALE FALSIFIER HEADING TEMPLATE_VERSION RESOLUTION RESOLUTION_REF \
       CORRECTION_ID VERIFICATION_EVENT_ID CORRECTION_DATE \
       BEFORE_SHA256 AFTER_SHA256 BEFORE_TEXT AFTER_TEXT \
       PRIOR_STATUS RESULT_STATUS \
       ACTION RETIREMENT_ID RESTORES_RETIREMENT_ID INBOUND_BACKLINKS \
       CHECK_NAME TARGET RESULT RUN_ID DETAIL \
       VERDICT TEMPLATE_ID \
       FROM_ENTRY_PATH TO_ENTRY_PATH REASON VERDICT_ID \
       SHA NOTE

ROW=$(python3 <<'PY_EOF'
import json, os

def env(name):
    return os.environ.get(name, "")

def provenance(val):
    return None if val == "null" else val

event = env("EVENT")

row = {
    "schema_version": "1",
    "event": event,
    "event_id": env("EVENT_ID"),
    "entry_path": env("ENTRY_PATH"),
    "source": env("SOURCE_KIND"),
    "observed_at": env("OBSERVED_AT"),
    "captured_at_branch": provenance(env("CAPTURED_AT_BRANCH")),
    "captured_at_sha": provenance(env("CAPTURED_AT_SHA")),
    "captured_at_merge_base_sha": provenance(env("CAPTURED_AT_MERGE_BASE_SHA")),
}

if event == "consumption-verification":
    payload = {
        "disposition": env("DISPOSITION"),
        "file": env("CLAIM_FILE"),
        "line_range": env("LINE_RANGE"),
        "exact_snippet": env("EXACT_SNIPPET"),
        "normalized_snippet_hash": env("NORMALIZED_SNIPPET_HASH"),
    }
    for key, var in (
        ("work_item", "WORK_ITEM"),
        ("producer_role", "PRODUCER_ROLE"),
        ("protocol_slot", "PROTOCOL_SLOT"),
        ("cycle_id", "CYCLE_ID"),
        ("claim_id", "CLAIM_ID"),
        ("claim_text", "CLAIM_TEXT"),
        ("rationale", "RATIONALE"),
        ("falsifier", "FALSIFIER"),
        ("heading", "HEADING"),
        ("template_version", "TEMPLATE_VERSION"),
        ("resolution", "RESOLUTION"),
        ("resolution_ref", "RESOLUTION_REF"),
    ):
        val = env(var)
        if val:
            payload[key] = val
elif event == "correction":
    payload = {
        "correction_id": env("CORRECTION_ID"),
        "verification_event_id": env("VERIFICATION_EVENT_ID"),
        "claim_id": env("CLAIM_ID"),
        "date": env("CORRECTION_DATE"),
        "before_sha256": env("BEFORE_SHA256"),
        "after_sha256": env("AFTER_SHA256"),
        "prior_status": env("PRIOR_STATUS"),
        "result_status": env("RESULT_STATUS"),
    }
    for key, var in (
        ("before_text", "BEFORE_TEXT"),
        ("after_text", "AFTER_TEXT"),
        ("work_item", "WORK_ITEM"),
    ):
        val = env(var)
        if val:
            payload[key] = val
elif event == "retirement":
    payload = {
        "action": env("ACTION"),
        "retirement_id": env("RETIREMENT_ID"),
        "prior_status": env("PRIOR_STATUS"),
        "result_status": env("RESULT_STATUS"),
    }
    for key, var in (
        ("reason", "REASON"),
        ("falsifier", "FALSIFIER"),
        ("note", "NOTE"),
        ("restores_retirement_id", "RESTORES_RETIREMENT_ID"),
        ("work_item", "WORK_ITEM"),
    ):
        val = env(var)
        if val:
            payload[key] = val
    if env("INBOUND_BACKLINKS"):
        payload["inbound_backlinks"] = int(env("INBOUND_BACKLINKS"))
elif event == "mechanical-check":
    payload = {
        "check_name": env("CHECK_NAME"),
        "target": env("TARGET"),
        "result": env("RESULT"),
        "run_id": env("RUN_ID"),
    }
    if env("DETAIL"):
        payload["detail"] = env("DETAIL")
elif event == "adjudication":
    payload = {
        "claim_id": env("CLAIM_ID"),
        "verdict": env("VERDICT"),
        "template_id": env("TEMPLATE_ID"),
        "template_version": env("TEMPLATE_VERSION"),
        "run_id": env("RUN_ID"),
    }
elif event == "trust-confirmation":
    payload = {
        "verdict": env("VERDICT"),
        "sha": env("SHA"),
    }
    if env("NOTE"):
        payload["note"] = env("NOTE")
else:
    payload = {
        "from_entry_path": env("FROM_ENTRY_PATH"),
        "to_entry_path": env("TO_ENTRY_PATH"),
        "reason": env("REASON"),
    }
    if env("VERDICT_ID"):
        payload["verdict_id"] = env("VERDICT_ID")

row["payload"] = payload
print(json.dumps(row, ensure_ascii=False))
PY_EOF
)

if [[ -z "$ROW" ]]; then
  fail "internal error: row serialization produced empty output"
fi

# --- Final structural sanity via jq -e ---
if ! printf '%s' "$ROW" | jq -e '
  type == "object"
  and (.schema_version == "1")
  and (.event | type == "string" and . != "")
  and (.event_id | type == "string" and (. | length) == 64)
  and (.entry_path | type == "string" and . != "")
  and (.source | type == "string" and . != "")
  and (.observed_at | type == "string" and . != "")
  and (has("captured_at_branch"))
  and (has("captured_at_sha"))
  and (has("captured_at_merge_base_sha"))
  and (.payload | type == "object")
' >/dev/null 2>&1; then
  fail "internal error: constructed row failed post-build schema check"
fi

mkdir -p "$LEDGER_DIR"

# --- Atomic append; no read-modify-write ---
printf '%s\n' "$ROW" | jq -c '.' >> "$LEDGER"

# Rank-staleness marker: appends never touch entry files, so the pk_search
# incremental indexer keys its cached trust_score refresh off this marker.
# Best-effort — the row above is already durable.
touch "$LEDGER_DIR/.rank-stale" 2>/dev/null || true

RELPATH="${LEDGER#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg path "$RELPATH" \
    --arg event_id "$EVENT_ID" \
    --arg event "$EVENT" \
    --arg entry_path "$ENTRY_PATH" \
    '{path: $path, event_id: $event_id, event: $event, entry_path: $entry_path, appended: true}')"
fi

echo "[trust-event] $EVENT event $EVENT_ID appended to $RELPATH (entry: $ENTRY_PATH)"
