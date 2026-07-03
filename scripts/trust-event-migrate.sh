#!/usr/bin/env bash
# trust-event-migrate.sh — Emit a provenance-migration event to the trust ledger.
#
# The migration-operation front of the trust-ledger write surface: sanctioned
# entry-path mutations (apply-correction.sh L3 supersede, the renormalize
# restructure path) call this script when a knowledge entry's KDIR-relative
# path changes, so `trust-compute.py` can follow the entry's event history
# across the move. Historical rows are never rewritten — this appends a
# redirect, nothing more.
#
# The physical append is delegated to trust-event-append.sh, which owns all
# ledger validation and dedupe. Only the sanctioned reasons are accepted;
# bare manual moves (e.g. `git mv` outside a sanctioned path) intentionally
# have no emission path and degrade at fold time with a warning.
#
# Usage:
#   trust-event-migrate.sh
#       --from-entry-path <path-relative-to-KDIR>   # where the content was
#       --to-entry-path <path-relative-to-KDIR>     # where the content is now
#       --reason <l3-supersede|renormalize-restructure>
#       --source <apply-correction|renormalize>
#       [--verdict-id <id>]
#       [--kdir <path>]
#       [--json]
#
# Exit codes:
#   0 — event appended OR deduped no-op
#   1 — validation failure or unknown flag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: trust-event-migrate.sh \
           --from-entry-path <path-relative-to-KDIR> \
           --to-entry-path <path-relative-to-KDIR> \
           --reason <l3-supersede|renormalize-restructure> \
           --source <apply-correction|renormalize> \
           [--verdict-id <id>] [--kdir <path>] [--json]

Append a provenance-migration event to $KDIR/_trust/trust-events.jsonl,
redirecting the entry's trust-event key from --from-entry-path forward to
--to-entry-path. Only sanctioned mutation paths may emit migrations.
EOF
}

FROM_ENTRY_PATH=""
TO_ENTRY_PATH=""
REASON=""
SOURCE_KIND=""
VERDICT_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-entry-path)  FROM_ENTRY_PATH="$2";  shift 2 ;;
    --to-entry-path)    TO_ENTRY_PATH="$2";    shift 2 ;;
    --reason)           REASON="$2";           shift 2 ;;
    --source)           SOURCE_KIND="$2";      shift 2 ;;
    --verdict-id)       VERDICT_ID="$2";       shift 2 ;;
    --kdir)             KDIR_OVERRIDE="$2";    shift 2 ;;
    --json)             JSON_MODE=1;           shift ;;
    --help|-h)          usage; exit 0 ;;
    *)
      echo "[trust-event-migrate] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[trust-event-migrate] $msg"
  fi
  echo "[trust-event-migrate] Error: $msg" >&2
  exit 1
}

for _pair in \
  "from-entry-path:$FROM_ENTRY_PATH" \
  "to-entry-path:$TO_ENTRY_PATH" \
  "reason:$REASON" \
  "source:$SOURCE_KIND"
do
  if [[ -z "${_pair#*:}" ]]; then
    fail "--${_pair%%:*} is required"
  fi
done

# Migration sources are a stricter subset of the ledger's source enum.
case "$SOURCE_KIND" in
  apply-correction|renormalize) : ;;
  *) fail "--source must be 'apply-correction' or 'renormalize' (got '$SOURCE_KIND')" ;;
esac

ARGS=(
  --event provenance-migration
  --from-entry-path "$FROM_ENTRY_PATH"
  --to-entry-path "$TO_ENTRY_PATH"
  --reason "$REASON"
  --source "$SOURCE_KIND"
)
if [[ -n "$VERDICT_ID" ]]; then
  ARGS+=(--verdict-id "$VERDICT_ID")
fi
if [[ -n "$KDIR_OVERRIDE" ]]; then
  ARGS+=(--kdir "$KDIR_OVERRIDE")
fi
if [[ $JSON_MODE -eq 1 ]]; then
  ARGS+=(--json)
fi

exec bash "$SCRIPT_DIR/trust-event-append.sh" "${ARGS[@]}"
