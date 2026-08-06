#!/usr/bin/env bash
# retire-append.sh — Retire a knowledge entry that no longer earns its place,
# or restore one that does again (`lore retire`).
#
# A retirement is a claim, not a deletion. The entry stays on disk with its
# backlinks and its ledger history; it leaves the default result set and comes
# back with one command. Retiring asks for two things: a reason, and a
# falsifier — the fact that would show the retirement was wrong, so the next
# agent who comes looking checks one stated fact instead of reconstructing the
# retiring agent's reasoning.
#
# Restoring takes a note and nothing else: no confidence declaration, no
# evidence scope, no claim scale, and no check on who retired the entry.
#
# The inbound backlink count is reported, never acted on. It is worth knowing
# before retiring; it is not grounds for refusing, and those links keep
# resolving either way.
#
# Usage:
#   retire-append.sh <knowledge-path>
#       --reason <why it no longer earns its place>
#       --falsifier <what would show this was wrong>
#       --source <worker|researcher|spec-lead|implement-lead|drift-sweep|audit|
#                 settlement|apply-correction|renormalize|interactive|coordinator>
#       [--superseded-by <path>] [--work-item <slug>] [--reported-by <role>]
#       [--date <YYYY-MM-DD>] [--kdir <path>] [--json]
#
#   retire-append.sh <knowledge-path> --restore
#       --note <what the entry is needed for>
#       --source <...>
#       [--work-item <slug>] [--reported-by <role>]
#       [--date <YYYY-MM-DD>] [--kdir <path>] [--json]
#
# <knowledge-path> is KDIR-relative (an absolute path under KDIR or a
# trailing-`.md`-less form is normalized); the entry file must exist.
#
# Transaction order: the entry is mutated first and the ledger event appended
# second, both keyed to the retirement id the mutator derives from the entry's
# own retirement history. An interrupted run therefore leaves a marker with no
# event — never a durable event with nobody accountable — and repeating the
# same invocation appends the missing event without touching the entry again.
#
# The entry edit is delegated to apply-correction.sh (the sole body mutator)
# and the ledger append to trust-event-append.sh (the sole physical writer of
# `_trust/trust-events.jsonl`).
#
# Exit codes:
#   0 — retirement or restoration recorded (or a converging no-op)
#   1 — validation failure, unknown flag, or entry not found
#   2 — the entry is not in a state this action can act on (restoring an entry
#       that is not retired, or a retired entry with no retirement record)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: retire-append.sh <knowledge-path> \
           --reason <why it no longer earns its place> \
           --falsifier <what would show this was wrong> \
           --source <worker|researcher|spec-lead|implement-lead|drift-sweep| \
                     audit|settlement|apply-correction|renormalize|interactive| \
                     coordinator> \
           [--superseded-by <path>] [--work-item <slug>] [--reported-by <role>] \
           [--date <YYYY-MM-DD>] [--kdir <path>] [--json]

       retire-append.sh <knowledge-path> --restore \
           --note <what the entry is needed for> \
           --source <...> \
           [--work-item <slug>] [--reported-by <role>] \
           [--date <YYYY-MM-DD>] [--kdir <path>] [--json]

Retire a knowledge entry out of the default result set, or restore one back
into it. A retired entry keeps its file, its backlinks, and its ledger
history; `--include-status retired` reaches it in search.

Retiring asks for two things: --reason, and --falsifier naming what would show
the retirement was wrong. Restoring asks for --note and nothing else — no
confidence, no evidence scope, no check on who retired it. Re-running either
invocation converges instead of duplicating a marker or a ledger row.
EOF
}

KNOWLEDGE_PATH=""
POSITIONAL_SEEN=0
RESTORE=0
REASON=""
FALSIFIER=""
NOTE=""
SUPERSEDED_BY=""
SOURCE_KIND=""
WORK_ITEM=""
REPORTED_BY=""
DATE_OVERRIDE=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --restore)         RESTORE=1;             shift ;;
    --reason)          REASON="$2";           shift 2 ;;
    --falsifier)       FALSIFIER="$2";        shift 2 ;;
    --note)            NOTE="$2";             shift 2 ;;
    --superseded-by)   SUPERSEDED_BY="$2";    shift 2 ;;
    --source)          SOURCE_KIND="$2";      shift 2 ;;
    --work-item)       WORK_ITEM="$2";        shift 2 ;;
    --reported-by)     REPORTED_BY="$2";      shift 2 ;;
    --date)            DATE_OVERRIDE="$2";    shift 2 ;;
    --kdir)            KDIR_OVERRIDE="$2";    shift 2 ;;
    --json)            JSON_MODE=1;           shift ;;
    --help|-h)         usage; exit 0 ;;
    --*)
      echo "[retire] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ $POSITIONAL_SEEN -eq 0 ]]; then
        KNOWLEDGE_PATH="$1"; POSITIONAL_SEEN=1
      else
        echo "[retire] Error: unexpected argument '$1'" >&2
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
    json_error "[retire] $msg"
  fi
  echo "[retire] Error: $msg" >&2
  exit 1
}

is_blank() {
  [[ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]]
}

# --- Validate everything before the first write ---
# A call that cannot complete must leave the entry and the ledger exactly as it
# found them, so every flag check happens up here.
if [[ -z "$KNOWLEDGE_PATH" ]]; then
  fail "<knowledge-path> is required"
fi

case "$SOURCE_KIND" in
  worker|researcher|spec-lead|implement-lead|drift-sweep|audit|settlement|apply-correction|renormalize|interactive|coordinator) : ;;
  "") fail "--source is required" ;;
  *)  fail "--source must be one of worker|researcher|spec-lead|implement-lead|drift-sweep|audit|settlement|apply-correction|renormalize|interactive|coordinator (got '$SOURCE_KIND')" ;;
esac

if [[ $RESTORE -eq 1 ]]; then
  ACTION="restored"
  if is_blank "$NOTE"; then
    fail "--note is required when restoring: say what the entry is needed for"
  fi
  for _pair in "reason:$REASON" "falsifier:$FALSIFIER" "superseded-by:$SUPERSEDED_BY"; do
    if [[ -n "${_pair#*:}" ]]; then
      fail "--${_pair%%:*} applies only to retirement, not to --restore"
    fi
  done
else
  ACTION="retired"
  if is_blank "$REASON"; then
    fail "--reason is required: say why the entry no longer earns its place in default retrieval"
  fi
  if is_blank "$FALSIFIER"; then
    fail "--falsifier is required: name what would show this retirement was wrong, so the next agent can check it in seconds rather than reconstructing your reasoning"
  fi
  if [[ -n "$NOTE" ]]; then
    fail "--note applies only to --restore"
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

if [[ -z "$REPORTED_BY" ]]; then
  REPORTED_BY="$SOURCE_KIND"
fi
RECORD_DATE="$DATE_OVERRIDE"
if [[ -z "$RECORD_DATE" ]]; then
  RECORD_DATE=$(date +%Y-%m-%d)
fi

# --- How many entries point here? Reported, never acted on. ---
INBOUND_BACKLINKS=$(python3 - "$KNOWLEDGE_DIR" "$ENTRY_PATH" <<'INBOUND_PY'
import json, os, sys

kdir, entry_path = sys.argv[1:3]
manifest_path = os.path.join(kdir, "_manifest.json")
try:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
except (OSError, json.JSONDecodeError):
    print(0)
    sys.exit(0)

stem = entry_path[:-3] if entry_path.endswith(".md") else entry_path


def targets_entry(link):
    """Does one [[...]] target text point at this entry?

    Manifest backlinks are the raw inner text of each reference, so a target
    can carry a `knowledge:` prefix, a `#Heading` suffix, or the `.md`.
    """
    target = link.split("#", 1)[0].strip()
    if target.startswith("knowledge:"):
        target = target[len("knowledge:"):]
    target = target.strip("/")
    if target.endswith(".md"):
        target = target[:-3]
    return bool(target) and target == stem


count = 0
for entry in manifest.get("entries", []):
    if not isinstance(entry, dict) or entry.get("path") == entry_path:
        continue
    links = entry.get("backlinks") or []
    if any(isinstance(link, str) and targets_entry(link) for link in links):
        count += 1
print(count)
INBOUND_PY
)

if [[ "$INBOUND_BACKLINKS" != "0" ]]; then
  if [[ "$INBOUND_BACKLINKS" == "1" ]]; then
    echo "[retire] 1 other entry links here — that link keeps resolving; the entry stays on disk either way."
  else
    echo "[retire] $INBOUND_BACKLINKS other entries link here — those links keep resolving; the entry stays on disk either way."
  fi
fi

# --- Mutate the entry (sole body mutator), then read back the record it wrote ---
# The mutator owns the retirement id: it derives it from the entry's own
# retirement history, which is what lets a repeat of this invocation recognize
# a record it already wrote instead of adding a second one.
MUTATE_ARGS=(
  --entry "$KNOWLEDGE_DIR/$ENTRY_PATH"
  --verdict-source peer-verification
  --allow-peer-verification
  --reported-by "$REPORTED_BY"
  --date "$RECORD_DATE"
  --kdir "$KNOWLEDGE_DIR"
)
if [[ $RESTORE -eq 1 ]]; then
  MUTATE_ARGS+=(--restore --note "$NOTE")
else
  MUTATE_ARGS+=(--retire --reason "$REASON" --falsifier "$FALSIFIER")
  [[ -n "$SUPERSEDED_BY" ]] && MUTATE_ARGS+=(--superseded-by "$SUPERSEDED_BY")
fi
[[ -n "$WORK_ITEM" ]] && MUTATE_ARGS+=(--work-item "$WORK_ITEM")

set +e
MUTATE_OUT=$(bash "$SCRIPT_DIR/apply-correction.sh" ${MUTATE_ARGS[@]+"${MUTATE_ARGS[@]}"} 2>&1)
MUTATE_STATUS=$?
set -e
if [[ $MUTATE_STATUS -ne 0 ]]; then
  printf '%s\n' "$MUTATE_OUT" >&2
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[retire] the entry was not modified"
  fi
  exit "$MUTATE_STATUS"
fi

RECORD=$(printf '%s\n' "$MUTATE_OUT" | grep '^\[retire\] result=' | head -1)
if [[ -z "$RECORD" ]]; then
  fail "the entry mutator reported no result record; entry unchanged"
fi
read_field() {
  printf '%s' "$RECORD" | sed -n "s/.*[[:space:]]$1=\([^ ]*\).*/\1/p"
}
ENTRY_ACTION=$(printf '%s' "$RECORD" | sed -n 's/.*result=\([^ ]*\).*/\1/p')
RETIREMENT_ID=$(read_field "retirement_id")
PRIOR_STATUS=$(read_field "prior_status")
RESULT_STATUS=$(read_field "result_status")
RESTORES_RETIREMENT_ID=$(read_field "restores_retirement_id")
if [[ -z "$RETIREMENT_ID" || -z "$PRIOR_STATUS" || -z "$RESULT_STATUS" ]]; then
  fail "could not read the retirement record from the mutator output: $RECORD"
fi

# --- Append the trust-ledger event (sole physical writer) ---
# Recomputed here from the same canonical basis the ledger writer uses; the
# comparison after the append catches any drift between the two.
EVENT_ID=$(printf '%s|%s|%s|%s' "retirement" "$ENTRY_PATH" "$ACTION" "$RETIREMENT_ID" \
  | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

TRUST_ARGS=(
  --event retirement
  --entry-path "$ENTRY_PATH"
  --source "$SOURCE_KIND"
  --action "$ACTION"
  --retirement-id "$RETIREMENT_ID"
  --prior-status "$PRIOR_STATUS"
  --result-status "$RESULT_STATUS"
  --inbound-backlinks "$INBOUND_BACKLINKS"
  --kdir "$KNOWLEDGE_DIR"
  --json
)
if [[ $RESTORE -eq 1 ]]; then
  TRUST_ARGS+=(--note "$NOTE" --restores-retirement-id "$RESTORES_RETIREMENT_ID")
else
  TRUST_ARGS+=(--reason "$REASON" --falsifier "$FALSIFIER")
fi
[[ -n "$WORK_ITEM" ]] && TRUST_ARGS+=(--work-item "$WORK_ITEM")

TRUST_OUT=$(bash "$SCRIPT_DIR/trust-event-append.sh" ${TRUST_ARGS[@]+"${TRUST_ARGS[@]}"})
LEDGER_EVENT_ID=$(printf '%s' "$TRUST_OUT" | jq -r '.event_id')
APPENDED=$(printf '%s' "$TRUST_OUT" | jq -r '.appended')
if [[ "$LEDGER_EVENT_ID" != "$EVENT_ID" ]]; then
  fail "retirement event id mismatch (computed $EVENT_ID, ledger $LEDGER_EVENT_ID) — the canonical basis in trust-event-append.sh and the one recomputed here have diverged"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg entry_path "$ENTRY_PATH" \
    --arg action "$ACTION" \
    --arg retirement_id "$RETIREMENT_ID" \
    --arg restores_retirement_id "$RESTORES_RETIREMENT_ID" \
    --arg entry_action "$ENTRY_ACTION" \
    --arg prior_status "$PRIOR_STATUS" \
    --arg result_status "$RESULT_STATUS" \
    --arg event_id "$EVENT_ID" \
    --argjson appended "$APPENDED" \
    --argjson inbound_backlinks "$INBOUND_BACKLINKS" \
    '{entry_path: $entry_path, action: $action, retirement_id: $retirement_id,
      entry_action: $entry_action, prior_status: $prior_status,
      result_status: $result_status, event_id: $event_id, appended: $appended,
      inbound_backlinks: $inbound_backlinks}
     + (if $restores_retirement_id != "" then
          {restores_retirement_id: $restores_retirement_id}
        else {} end)')"
fi

if [[ $RESTORE -eq 1 ]]; then
  if [[ "$ENTRY_ACTION" == "noop" ]]; then
    echo "[retire] $ENTRY_PATH was already restored ($RETIREMENT_ID) — nothing further to record on the entry"
  else
    echo "[retire] $ENTRY_PATH restored to status $RESULT_STATUS ($RETIREMENT_ID, reverses $RESTORES_RETIREMENT_ID)"
  fi
else
  if [[ "$ENTRY_ACTION" == "noop" ]]; then
    echo "[retire] $ENTRY_PATH was already retired ($RETIREMENT_ID) — nothing further to record on the entry"
  else
    echo "[retire] $ENTRY_PATH retired ($RETIREMENT_ID), was status $PRIOR_STATUS"
    echo "[retire] reachable with: lore search <query> --include-status retired"
    echo "[retire] reversible with: lore retire $ENTRY_PATH --restore --note \"<what you needed it for>\""
  fi
fi
if [[ "$APPENDED" == "true" ]]; then
  echo "[retire] $ACTION event $EVENT_ID recorded for $ENTRY_PATH"
else
  echo "[retire] duplicate — $ACTION event for $ENTRY_PATH already recorded ($EVENT_ID)"
fi
