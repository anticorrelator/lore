#!/usr/bin/env bash
# trust-confirm.sh — Record a cheap held/contradicted verdict for a knowledge
# entry (`lore trust confirm`).
#
# The lightweight testimony front of the trust-ledger write surface: an agent
# or human confirms that an entry holds (or is contradicted) as of a repo
# state, without producing a code anchor. The verdict is grounded on the repo
# --sha rather than a file+line+snippet, so it weighs below a grounded
# `lore verify` in the fold — cheap enough to leave routinely, cheap enough
# that it must never masquerade as anchored verification.
#
# The ledger append is delegated to trust-event-append.sh (the sole physical
# writer of `_trust/trust-events.jsonl`); this front validates only its own
# flag surface and maps the surface verdict vocabulary (holds|contradicted)
# onto the ledger's disposition vocabulary (held|contradicted). A contradicted
# verdict lands in the ledger only — it is NOT bridged into a work item's
# consumption-contradiction channel. To escalate a real dispute into the
# judge-facing channel, use `lore verify contradicted` with a code anchor.
#
# Usage:
#   trust-confirm.sh <knowledge-path> --sha <hex> --verdict <holds|contradicted>
#       [--note <text>]
#       [--source <value>]   # default: interactive
#       [--kdir <path>]
#       [--json]
#
# <knowledge-path> is KDIR-relative (an absolute path under KDIR or a
# trailing-`.md`-less form is normalized); the entry file must exist. --sha is
# a repo commit hash recorded verbatim, never resolved against any repo.
#
# Exit codes:
#   0 — verdict recorded (or deduped no-op)
#   1 — validation failure, unknown flag, or entry not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: trust-confirm.sh <knowledge-path> \
           --sha <hex> \
           --verdict <holds|contradicted> \
           [--note <text>] \
           [--source <value>]   # default: interactive \
           [--kdir <path>] [--json]

Record a cheap verdict that a knowledge entry holds or is contradicted as of a
repo commit (--sha), without a code anchor. Weighs below a grounded
`lore verify` in the trust fold. Re-running an identical invocation (same
entry, verdict, source, and sha) is a silent no-op; a new sha appends a new
row.

A contradicted verdict lands in the ledger only. To escalate a dispute into
the judge-facing consumption-contradiction channel, use
`lore verify contradicted` with a grounded code anchor.
EOF
}

KNOWLEDGE_PATH=""
POSITIONAL_SEEN=0

SHA=""
VERDICT=""
NOTE=""
SOURCE_KIND="interactive"
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)        SHA="$2";            shift 2 ;;
    --verdict)    VERDICT="$2";        shift 2 ;;
    --note)       NOTE="$2";           shift 2 ;;
    --source)     SOURCE_KIND="$2";    shift 2 ;;
    --kdir)       KDIR_OVERRIDE="$2";  shift 2 ;;
    --json)       JSON_MODE=1;         shift ;;
    --help|-h)    usage; exit 0 ;;
    --*)
      echo "[trust-confirm] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ $POSITIONAL_SEEN -eq 0 ]]; then
        KNOWLEDGE_PATH="$1"; POSITIONAL_SEEN=1
      else
        echo "[trust-confirm] Error: unexpected argument '$1'" >&2
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
    json_error "[trust-confirm] $msg"
  fi
  echo "[trust-confirm] Error: $msg" >&2
  exit 1
}

# --- Positional ---
if [[ -z "$KNOWLEDGE_PATH" ]]; then
  fail "<knowledge-path> is required"
fi

# --- Surface verdict vocabulary; mapped to the ledger disposition below ---
case "$VERDICT" in
  holds|contradicted) : ;;
  "") fail "--verdict is required: holds or contradicted" ;;
  *)  fail "--verdict must be 'holds' or 'contradicted' (got '$VERDICT')" ;;
esac

# --- Repo-state grounding: a hex sha, recorded verbatim, never resolved ---
if [[ -z "$SHA" ]]; then
  fail "--sha is required (the repo commit the verdict is grounded on)"
fi
if ! printf '%s' "$SHA" | grep -Eq '^[0-9a-fA-F]{7,}$'; then
  fail "--sha must be a hex string of at least 7 characters (got '$SHA')"
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

# --- Map surface verdict onto the ledger's disposition vocabulary ---
LEDGER_VERDICT="$VERDICT"
if [[ "$VERDICT" == "holds" ]]; then
  LEDGER_VERDICT="held"
fi

# --- Append the trust-ledger event (sole physical writer owns schema) ---
TRUST_ARGS=(
  --event trust-confirmation
  --entry-path "$ENTRY_PATH"
  --source "$SOURCE_KIND"
  --verdict "$LEDGER_VERDICT"
  --sha "$SHA"
  --kdir "$KNOWLEDGE_DIR"
  --json
)
[[ -n "$NOTE" ]] && TRUST_ARGS+=(--note "$NOTE")

TRUST_OUT=$(bash "$SCRIPT_DIR/trust-event-append.sh" "${TRUST_ARGS[@]}")
EVENT_ID=$(printf '%s' "$TRUST_OUT" | jq -r '.event_id')
APPENDED=$(printf '%s' "$TRUST_OUT" | jq -r '.appended')

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg entry_path "$ENTRY_PATH" \
    --arg verdict "$LEDGER_VERDICT" \
    --arg sha "$SHA" \
    --arg event_id "$EVENT_ID" \
    --argjson appended "$APPENDED" \
    '{entry_path: $entry_path, verdict: $verdict, sha: $sha, event_id: $event_id, appended: $appended}')"
fi

if [[ "$APPENDED" == "true" ]]; then
  echo "[trust-confirm] $LEDGER_VERDICT verdict $EVENT_ID recorded for $ENTRY_PATH (sha $SHA)"
else
  echo "[trust-confirm] duplicate — $LEDGER_VERDICT verdict for $ENTRY_PATH already recorded ($EVENT_ID)"
fi
