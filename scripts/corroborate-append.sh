#!/usr/bin/env bash
# corroborate-append.sh — Record an observation for or against a knowledge
# entry's claim, or move that claim's epistemic lifecycle state
# (`lore claim corroborate` / `lore claim settle`).
#
# A corroboration is one observation, not a verdict. It says who saw what, when,
# and which way it pointed, and it accumulates in the entry's corroborations[]
# array so the next reader meets the evidence next to the claim. Deciding that
# the accumulated observations settle the question is a separate act:
# --kind-status moves the entry's kind_status.
#
# Usage:
#   corroborate-append.sh <knowledge-path>
#       --direction <supports|undermines>
#       --source <who or what observed it>
#       --note <what was seen and why it counts>
#       [--observed-at <YYYY-MM-DD>] [--work-item <slug>] [--reported-by <role>]
#       [--date <YYYY-MM-DD>] [--kdir <path>] [--json]
#
#   corroborate-append.sh <knowledge-path> --kind-status <value>
#       --note <what moved it>
#       [--source <who or what settled it>] [--work-item <slug>]
#       [--reported-by <role>] [--date <YYYY-MM-DD>] [--kdir <path>] [--json]
#
# <knowledge-path> is KDIR-relative (an absolute path under KDIR or a
# trailing-`.md`-less form is normalized); the entry file must exist.
#
# Two observations of the same claim from the same source on the same day
# pointing the same way are one observation, so re-running an invocation
# converges on the item already recorded. The note text sits outside that
# identity — re-wording an observation does not make it a second data point.
#
# The entry edit is delegated to apply-correction.sh (the sole body mutator),
# which owns the direction and kind_status vocabularies and all dedupe. This
# front resolves paths, checks its own argument shape, and sanitizes the values
# it passes through; it never edits a footer itself. Unlike a retirement, a
# corroboration writes no trust-ledger event: the record lives in the entry.
#
# Exit codes:
#   0 — observation or transition recorded (or a converging no-op)
#   1 — validation failure, unknown flag, or entry not found
#   2 — the entry cannot carry the transition (a kind with no lifecycle, or an
#       unreadable kind)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: corroborate-append.sh <knowledge-path> \
           --direction <supports|undermines> \
           --source <who or what observed it> \
           --note <what was seen and why it counts> \
           [--observed-at <YYYY-MM-DD>] [--work-item <slug>] \
           [--reported-by <role>] [--date <YYYY-MM-DD>] [--kdir <path>] [--json]

       corroborate-append.sh <knowledge-path> --kind-status <value> \
           --note <what moved it> \
           [--source <who or what settled it>] [--work-item <slug>] \
           [--reported-by <role>] [--date <YYYY-MM-DD>] [--kdir <path>] [--json]

Record one observation for or against an entry's claim, or settle that claim's
lifecycle. A corroboration accumulates in the entry's footer; --kind-status
moves the entry's kind_status (untested|supported|refuted for a hypothesis,
open|answered|dissolved for a question).

Re-running either invocation converges instead of recording the same
observation twice. Re-wording --note does not make a new observation.
EOF
}

KNOWLEDGE_PATH=""
POSITIONAL_SEEN=0
DIRECTION=""
SETTLE_STATUS=""
SOURCE_TEXT=""
NOTE=""
OBSERVED_AT=""
WORK_ITEM=""
REPORTED_BY=""
DATE_OVERRIDE=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direction)     DIRECTION="$2";      shift 2 ;;
    --kind-status)   SETTLE_STATUS="$2";  shift 2 ;;
    --source)        SOURCE_TEXT="$2";    shift 2 ;;
    --note)          NOTE="$2";           shift 2 ;;
    --observed-at)   OBSERVED_AT="$2";    shift 2 ;;
    --work-item)     WORK_ITEM="$2";      shift 2 ;;
    --reported-by)   REPORTED_BY="$2";    shift 2 ;;
    --date)          DATE_OVERRIDE="$2";  shift 2 ;;
    --kdir)          KDIR_OVERRIDE="$2";  shift 2 ;;
    --json)          JSON_MODE=1;         shift ;;
    --help|-h)       usage; exit 0 ;;
    --*)
      echo "[corroborate] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ $POSITIONAL_SEEN -eq 0 ]]; then
        KNOWLEDGE_PATH="$1"; POSITIONAL_SEEN=1
      else
        echo "[corroborate] Error: unexpected argument '$1'" >&2
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
    json_error "[corroborate] $msg"
  fi
  echo "[corroborate] Error: $msg" >&2
  exit 1
}

is_blank() {
  [[ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]]
}

# --- Validate everything before the first write ---
# A call that cannot complete must leave the entry exactly as it found it, so
# every check happens up here. The vocabularies themselves are the mutator's to
# police — repeating them here would fork them.
if [[ -z "$KNOWLEDGE_PATH" ]]; then
  fail "<knowledge-path> is required"
fi

if [[ -n "$SETTLE_STATUS" ]]; then
  MODE="settle"
  if [[ -n "$DIRECTION" ]]; then
    fail "--direction applies to a corroboration, not to --kind-status"
  fi
  if [[ -n "$OBSERVED_AT" ]]; then
    fail "--observed-at applies to a corroboration, not to --kind-status"
  fi
  if is_blank "$NOTE"; then
    fail "--note is required when settling: say what moved the claim"
  fi
else
  MODE="corroborate"
  if [[ -z "$DIRECTION" ]]; then
    fail "--direction is required: which way the observation points"
  fi
  if is_blank "$SOURCE_TEXT"; then
    fail "--source is required: name who or what observed it, so the next reader knows whose observation this is"
  fi
  if is_blank "$NOTE"; then
    fail "--note is required: say what was seen and why it counts"
  fi
  if [[ -n "$OBSERVED_AT" ]] && ! printf '%s' "$OBSERVED_AT" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    fail "--observed-at must match YYYY-MM-DD (got '$OBSERVED_AT')"
  fi
fi

if [[ -n "$DATE_OVERRIDE" ]] && ! printf '%s' "$DATE_OVERRIDE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  fail "--date must match YYYY-MM-DD (got '$DATE_OVERRIDE')"
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

RECORD_DATE="$DATE_OVERRIDE"
if [[ -z "$RECORD_DATE" ]]; then
  RECORD_DATE=$(date +%Y-%m-%d)
fi
if [[ -z "$REPORTED_BY" && -n "$SOURCE_TEXT" ]]; then
  REPORTED_BY="$SOURCE_TEXT"
fi

# The footer is one line of " | "-joined pairs with no escaping anywhere, and
# these values end up inside a JSON array on that line. A "|" or ">" in any of
# them splits or truncates the field for every footer parser.
SAFE_SOURCE=$(sanitize_footer_value "$SOURCE_TEXT")
SAFE_NOTE=$(sanitize_footer_value "$NOTE")
SAFE_REPORTED_BY=$(sanitize_footer_value "$REPORTED_BY")

# --- Mutate the entry (sole body mutator), then read back the record it wrote ---
# The mutator owns the record id: it derives a corroboration id from the
# observation's own identity and a transition id from the entry's transition
# history, which is what lets a repeat of this invocation recognize a record it
# already wrote instead of adding a second one.
MUTATE_ARGS=(
  --entry "$KNOWLEDGE_DIR/$ENTRY_PATH"
  --verdict-source peer-verification
  --allow-peer-verification
  --date "$RECORD_DATE"
  --kdir "$KNOWLEDGE_DIR"
)
[[ -n "$SAFE_REPORTED_BY" ]] && MUTATE_ARGS+=(--reported-by "$SAFE_REPORTED_BY")
[[ -n "$WORK_ITEM" ]] && MUTATE_ARGS+=(--work-item "$WORK_ITEM")

if [[ "$MODE" == "settle" ]]; then
  RESULT_TAG="kind-status"
  MUTATE_ARGS+=(--set-kind-status --kind-status "$SETTLE_STATUS" --kind-status-note "$SAFE_NOTE")
else
  RESULT_TAG="corroborate"
  MUTATE_ARGS+=(
    --corroborate
    --direction "$DIRECTION"
    --corroboration-source "$SAFE_SOURCE"
    --corroboration-note "$SAFE_NOTE"
  )
  [[ -n "$OBSERVED_AT" ]] && MUTATE_ARGS+=(--observed-at "$OBSERVED_AT")
fi

set +e
MUTATE_OUT=$(bash "$SCRIPT_DIR/apply-correction.sh" ${MUTATE_ARGS[@]+"${MUTATE_ARGS[@]}"} 2>&1)
MUTATE_STATUS=$?
set -e
if [[ $MUTATE_STATUS -ne 0 ]]; then
  printf '%s\n' "$MUTATE_OUT" >&2
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[corroborate] the entry was not modified"
  fi
  exit "$MUTATE_STATUS"
fi

RECORD=$(printf '%s\n' "$MUTATE_OUT" | grep "^\[$RESULT_TAG\] result=" | head -1)
if [[ -z "$RECORD" ]]; then
  fail "the entry mutator reported no result record; entry unchanged"
fi
read_field() {
  printf '%s' "$RECORD" | sed -n "s/.*[[:space:]]$1=\([^ ]*\).*/\1/p"
}
ENTRY_ACTION=$(printf '%s' "$RECORD" | sed -n 's/.*result=\([^ ]*\).*/\1/p')

if [[ "$MODE" == "settle" ]]; then
  TRANSITION_ID=$(read_field "transition_id")
  FROM_STATUS=$(read_field "from")
  TO_STATUS=$(read_field "to")
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg entry_path "$ENTRY_PATH" \
      --arg action "$ENTRY_ACTION" \
      --arg transition_id "$TRANSITION_ID" \
      --arg from "$FROM_STATUS" \
      --arg to "$TO_STATUS" \
      '{entry_path: $entry_path, mode: "settle", action: $action,
        transition_id: $transition_id, from: $from, to: $to}')"
  fi
  if [[ "$ENTRY_ACTION" == "noop" ]]; then
    echo "[corroborate] $ENTRY_PATH was already $TO_STATUS — nothing further to record"
  else
    echo "[corroborate] $ENTRY_PATH settled: kind_status $FROM_STATUS -> $TO_STATUS ($TRANSITION_ID)"
    echo "[corroborate] reversible with: lore claim settle $ENTRY_PATH --kind-status $FROM_STATUS --note \"<why it reopens>\""
  fi
else
  CORROBORATION_ID=$(read_field "corroboration_id")
  OBSERVED=$(read_field "observed_at")
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$(jq -n \
      --arg entry_path "$ENTRY_PATH" \
      --arg action "$ENTRY_ACTION" \
      --arg corroboration_id "$CORROBORATION_ID" \
      --arg direction "$DIRECTION" \
      --arg observed_at "$OBSERVED" \
      --arg source "$SAFE_SOURCE" \
      '{entry_path: $entry_path, mode: "corroborate", action: $action,
        corroboration_id: $corroboration_id, direction: $direction,
        observed_at: $observed_at, source: $source}')"
  fi
  if [[ "$ENTRY_ACTION" == "noop" ]]; then
    echo "[corroborate] $ENTRY_PATH already carries this observation ($CORROBORATION_ID) — nothing further to record"
  else
    echo "[corroborate] $ENTRY_PATH: $DIRECTION, observed $OBSERVED by $SAFE_SOURCE ($CORROBORATION_ID)"
    echo "[corroborate] settle the claim when the observations decide it: lore claim settle $ENTRY_PATH --kind-status <value> --note \"<what moved it>\""
  fi
fi
