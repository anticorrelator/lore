#!/usr/bin/env bash
# expire-sweep.sh — Move knowledge entries that have sat unresolved too long out
# of the default result set (`lore claim expire-sweep`).
#
# An expiry is a claim about attention, not about truth. A hypothesis nobody has
# argued either way for two quarters, or a question nobody has looked into, keeps
# its file, its path, its backlinks, and its history; it just stops arriving in
# unfiltered search, and one command brings it back. `expired` is kept distinct
# from `retired` on purpose: a clock ran out, rather than a person judging the
# entry no longer relevant, and someone auditing what this sweep did needs to
# tell those apart.
#
# Two parts, and this is the half that writes. expire-sweep.py reads the store
# and decides which entries qualify, printing them as JSON and touching nothing.
# This script routes each candidate through the sole entry-body mutator and then
# the sole trust-ledger writer.
#
# Nothing schedules this. It runs when someone runs it — quarterly is the cadence
# it was sized for, and session hooks were ruled out for organization work
# because session endings are abrupt.
#
# Usage:
#   expire-sweep.sh [--days N] [--limit N] [--kind <id>]...
#                   [--source <ledger source>] [--work-item <slug>]
#                   [--today <YYYY-MM-DD>] [--dry-run] [--json] [--kdir <path>]
#
# Transaction order per candidate: the entry is mutated first and the ledger
# event appended second, both keyed to the id the mutator derives from the
# entry's own history. An interrupted run therefore leaves a marker with no event
# — never a durable event with nobody accountable. Re-running after a complete
# run writes nothing at all: the candidate scan skips entries already out of the
# default result set.
#
# That skip is also the limit of the convergence. Because it happens in the scan,
# an entry whose mutation landed but whose ledger append did not is skipped on
# the next run too, so the sweep does not append the missing event the way
# `lore retire` does when you repeat it by hand. Recovering one means naming the
# entry to `lore retire` directly; the entry itself is correct and readable
# either way, and what is missing is the ledger row about it.
#
# Exit codes:
#   0 — the sweep ran (no candidates is a normal result)
#   1 — validation failure, unknown flag, or a candidate could not be expired
#   2 — the knowledge store or the candidate scan could not be read

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: expire-sweep.sh [--days N] [--limit N] [--kind <id>]... \
                       [--source <ledger source>] [--work-item <slug>] \
                       [--today <YYYY-MM-DD>] [--dry-run] [--json] [--kdir <path>]

Expire knowledge entries whose epistemic lifecycle has sat unresolved for
--days days (default 180). An expired entry keeps its file, its backlinks, and
its history; `lore search <query> --include-status expired` reaches it and
`lore retire <path> --restore --note "..."` brings it back.

Candidates come from expire-sweep.py, which writes nothing. Use --dry-run to see
what a run would change without changing it.
EOF
}

DAYS=""
LIMIT=""
KINDS=()
SOURCE_KIND="expire-sweep"
WORK_ITEM=""
TODAY=""
DRY_RUN=0
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)        DAYS="$2";           shift 2 ;;
    --limit)       LIMIT="$2";          shift 2 ;;
    --kind)        KINDS+=("$2");       shift 2 ;;
    --source)      SOURCE_KIND="$2";    shift 2 ;;
    --work-item)   WORK_ITEM="$2";      shift 2 ;;
    --today)       TODAY="$2";          shift 2 ;;
    --dry-run)     DRY_RUN=1;           shift ;;
    --json)        JSON_MODE=1;         shift ;;
    --kdir)        KDIR_OVERRIDE="$2";  shift 2 ;;
    --help|-h)     usage; exit 0 ;;
    *)
      echo "[expire-sweep] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[expire-sweep] $msg"
  fi
  echo "[expire-sweep] Error: $msg" >&2
  exit 1
}

if [[ -n "$DAYS" ]] && ! printf '%s' "$DAYS" | grep -Eq '^[0-9]+$'; then
  fail "--days must be a non-negative integer (got '$DAYS')"
fi
if [[ -n "$LIMIT" ]] && ! printf '%s' "$LIMIT" | grep -Eq '^[0-9]+$'; then
  fail "--limit must be a non-negative integer (got '$LIMIT')"
fi
if [[ -n "$TODAY" ]] && ! printf '%s' "$TODAY" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
  fail "--today must match YYYY-MM-DD (got '$TODAY')"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

# --- Ask the emitter which entries qualify ---
SCAN_ARGS=("$KNOWLEDGE_DIR")
[[ -n "$DAYS" ]] && SCAN_ARGS+=(--days "$DAYS")
[[ -n "$LIMIT" ]] && SCAN_ARGS+=(--limit "$LIMIT")
[[ -n "$TODAY" ]] && SCAN_ARGS+=(--today "$TODAY")
for _k in ${KINDS[@]+"${KINDS[@]}"}; do
  SCAN_ARGS+=(--kind "$_k")
done

set +e
SWEEP_JSON=$(python3 "$SCRIPT_DIR/expire-sweep.py" ${SCAN_ARGS[@]+"${SCAN_ARGS[@]}"})
SCAN_STATUS=$?
set -e
if [[ $SCAN_STATUS -ne 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[expire-sweep] the candidate scan failed"
  fi
  exit 2
fi

THRESHOLD=$(printf '%s' "$SWEEP_JSON" | jq -r '.threshold_days')
SCANNED=$(printf '%s' "$SWEEP_JSON" | jq -r '.scanned')
CANDIDATE_COUNT=$(printf '%s' "$SWEEP_JSON" | jq -r '.candidates | length')
RECORD_DATE="$TODAY"
if [[ -z "$RECORD_DATE" ]]; then
  RECORD_DATE=$(date +%Y-%m-%d)
fi

EXPIRED_COUNT=0
NOOP_COUNT=0
RESULTS_JSON="[]"

# --- Expire each candidate: entry first, ledger second ---
CANDIDATES=$(printf '%s' "$SWEEP_JSON" | jq -c '.candidates[]')
while IFS= read -r CAND; do
  [[ -z "$CAND" ]] && continue

  ENTRY_PATH=$(printf '%s' "$CAND" | jq -r '.entry_path')
  DAYS_UNTOUCHED=$(printf '%s' "$CAND" | jq -r '.days_untouched')
  # The reason and the falsifier land inside a JSON array on the footer's single
  # pipe-joined line, so they go through the shared sanitizer like any other
  # footer value.
  REASON=$(sanitize_footer_value "$(printf '%s' "$CAND" | jq -r '.reason')")
  FALSIFIER=$(sanitize_footer_value "$(printf '%s' "$CAND" | jq -r '.falsifier')")

  MUTATE_ARGS=(
    --retire
    --result-status expired
    --entry "$KNOWLEDGE_DIR/$ENTRY_PATH"
    --verdict-source peer-verification
    --allow-peer-verification
    --reason "$REASON"
    --falsifier "$FALSIFIER"
    --reported-by "$SOURCE_KIND"
    --date "$RECORD_DATE"
    --kdir "$KNOWLEDGE_DIR"
  )
  [[ -n "$WORK_ITEM" ]] && MUTATE_ARGS+=(--work-item "$WORK_ITEM")
  [[ $DRY_RUN -eq 1 ]] && MUTATE_ARGS+=(--dry-run)

  set +e
  MUTATE_OUT=$(bash "$SCRIPT_DIR/apply-correction.sh" ${MUTATE_ARGS[@]+"${MUTATE_ARGS[@]}"} 2>&1)
  MUTATE_STATUS=$?
  set -e
  if [[ $MUTATE_STATUS -ne 0 ]]; then
    printf '%s\n' "$MUTATE_OUT" >&2
    fail "$ENTRY_PATH was not expired; the sweep stopped here so the entries already written stay consistent"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run][expire-sweep] $ENTRY_PATH — untouched $DAYS_UNTOUCHED days"
    echo "[dry-run][expire-sweep]   reason: $REASON"
    echo "[dry-run][expire-sweep]   overturned if: $FALSIFIER"
    EXPIRED_COUNT=$((EXPIRED_COUNT + 1))
    continue
  fi

  RECORD=$(printf '%s\n' "$MUTATE_OUT" | grep '^\[retire\] result=' | head -1)
  if [[ -z "$RECORD" ]]; then
    fail "the entry mutator reported no result record for $ENTRY_PATH; entry unchanged"
  fi
  read_field() {
    printf '%s' "$RECORD" | sed -n "s/.*[[:space:]]$1=\([^ ]*\).*/\1/p"
  }
  ENTRY_ACTION=$(printf '%s' "$RECORD" | sed -n 's/.*result=\([^ ]*\).*/\1/p')
  RETIREMENT_ID=$(read_field "retirement_id")
  PRIOR_STATUS=$(read_field "prior_status")
  RESULT_STATUS=$(read_field "result_status")
  if [[ -z "$RETIREMENT_ID" || -z "$PRIOR_STATUS" || -z "$RESULT_STATUS" ]]; then
    fail "could not read the expiry record from the mutator output: $RECORD"
  fi

  # Recomputed from the same canonical basis the ledger writer uses; the
  # comparison after the append catches drift between the two.
  EVENT_ID=$(printf '%s|%s|%s|%s' "retirement" "$ENTRY_PATH" "retired" "$RETIREMENT_ID" \
    | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
')

  TRUST_ARGS=(
    --event retirement
    --entry-path "$ENTRY_PATH"
    --source "$SOURCE_KIND"
    --action retired
    --retirement-id "$RETIREMENT_ID"
    --prior-status "$PRIOR_STATUS"
    --result-status "$RESULT_STATUS"
    --reason "$REASON"
    --falsifier "$FALSIFIER"
    --kdir "$KNOWLEDGE_DIR"
    --json
  )
  [[ -n "$WORK_ITEM" ]] && TRUST_ARGS+=(--work-item "$WORK_ITEM")

  set +e
  TRUST_OUT=$(bash "$SCRIPT_DIR/trust-event-append.sh" ${TRUST_ARGS[@]+"${TRUST_ARGS[@]}"})
  TRUST_STATUS=$?
  set -e
  if [[ $TRUST_STATUS -ne 0 ]]; then
    printf '%s\n' "$TRUST_OUT" >&2
    # Re-running the sweep will NOT pick this up: the candidate scan skips
    # entries already at expired, so the missing row has to be asked for by name.
    # The recovery reports as `interactive` because someone is running it by
    # hand; source is outside the retirement dedupe basis, so the row still
    # lands under the expiry id this run derived.
    fail "$ENTRY_PATH is expired but its ledger event was not appended. A later sweep will skip it, so recover it by name: lore retire $ENTRY_PATH --reason \"...\" --falsifier \"...\" --source interactive — that leaves the entry alone and appends the missing event"
  fi
  LEDGER_EVENT_ID=$(printf '%s' "$TRUST_OUT" | jq -r '.event_id')
  APPENDED=$(printf '%s' "$TRUST_OUT" | jq -r '.appended')
  if [[ "$LEDGER_EVENT_ID" != "$EVENT_ID" ]]; then
    fail "expiry event id mismatch for $ENTRY_PATH (computed $EVENT_ID, ledger $LEDGER_EVENT_ID) — the canonical basis in trust-event-append.sh and the one recomputed here have diverged"
  fi

  if [[ "$ENTRY_ACTION" == "noop" ]]; then
    NOOP_COUNT=$((NOOP_COUNT + 1))
    echo "[expire-sweep] $ENTRY_PATH was already out of the default result set ($RETIREMENT_ID)"
  else
    EXPIRED_COUNT=$((EXPIRED_COUNT + 1))
    echo "[expire-sweep] $ENTRY_PATH expired ($RETIREMENT_ID), was status $PRIOR_STATUS, untouched $DAYS_UNTOUCHED days"
  fi

  RESULTS_JSON=$(printf '%s' "$RESULTS_JSON" | jq -c \
    --arg entry_path "$ENTRY_PATH" \
    --arg retirement_id "$RETIREMENT_ID" \
    --arg entry_action "$ENTRY_ACTION" \
    --arg prior_status "$PRIOR_STATUS" \
    --arg result_status "$RESULT_STATUS" \
    --arg event_id "$EVENT_ID" \
    --argjson appended "$APPENDED" \
    --argjson days_untouched "$DAYS_UNTOUCHED" \
    '. + [{entry_path: $entry_path, retirement_id: $retirement_id,
           entry_action: $entry_action, prior_status: $prior_status,
           result_status: $result_status, event_id: $event_id,
           appended: $appended, days_untouched: $days_untouched}]')
done <<< "$CANDIDATES"

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --argjson threshold_days "$THRESHOLD" \
    --argjson scanned "$SCANNED" \
    --argjson candidates "$CANDIDATE_COUNT" \
    --argjson expired "$EXPIRED_COUNT" \
    --argjson already_out "$NOOP_COUNT" \
    --argjson dry_run "$([[ $DRY_RUN -eq 1 ]] && echo true || echo false)" \
    --argjson entries "$RESULTS_JSON" \
    '{threshold_days: $threshold_days, scanned: $scanned,
      candidates: $candidates, expired: $expired,
      already_out_of_default: $already_out, dry_run: $dry_run,
      entries: $entries}')"
fi

if [[ "$CANDIDATE_COUNT" == "0" ]]; then
  echo "[expire-sweep] $SCANNED entries scanned, nothing unresolved past $THRESHOLD days — no changes"
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[expire-sweep] $SCANNED entries scanned; $CANDIDATE_COUNT would be expired past $THRESHOLD days (nothing was written)"
else
  echo "[expire-sweep] $SCANNED entries scanned; $EXPIRED_COUNT expired, $NOOP_COUNT already out of the default result set"
  echo "[expire-sweep] reachable with: lore search <query> --include-status expired"
  echo "[expire-sweep] reversible with: lore retire <path> --restore --note \"<what you needed it for>\""
fi
