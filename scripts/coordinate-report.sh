#!/usr/bin/env bash
# coordinate-report.sh — Land a returned worker report at the path it was assigned.
#
# Usage:
#   lore coordinate report <work-item> --report-id <id> [--kdir <path>] [--json]
#     ... with the report body on stdin.
#
# Options:
#   --report-id <id>  The report id assigned at dispatch. Decides the filename:
#                     _work/<work-item>/worker-reports/<id>.md. Must be
#                     filesystem-safe — no slashes, no leading dot.
#   --kdir <path>     Knowledge-store override (test isolation).
#   --json            Emit one machine-readable object instead of prose.
#   --help, -h        Show this help.
#
# Why this verb exists:
#   A subagent hands its report back as a string in a tool result. That string
#   is delivery, not evidence — the durable record is the file at the report's
#   assigned path, and somebody has to move one to the other. Done by hand, that
#   copy is the step that gets skipped when the dispatching seat is busy reading
#   the report instead of landing it. Here it is one call that either lands the
#   file or tells you why it did not.
#
#   The verb lands. It does not judge the report: whether the Tier-2 references
#   check out and the consultations were acknowledged is impl-check-report.sh's
#   job, and it runs on the landed file.
#
# Why it does not validate an identity header:
#   The path is the identity. A file at <work-item>/worker-reports/<id>.md
#   already asserts which item and which report id it belongs to, and asserts it
#   where a reader will actually look. A header restating both was compared
#   against argv — two values the same seat typed seconds earlier — so it could
#   only catch a caller disagreeing with itself.
#
# Write-once, and why a replay is refused:
#   An accepted report is immutable, and a re-dispatch is supposed to carry a
#   fresh id. So an existing path is a refusal — including when the body is
#   byte-identical to what is already there. Treating an identical replay as a
#   harmless no-op is what would make id reuse invisible, and id reuse is
#   precisely what overwrites a previous attempt's evidence. If you meant to
#   land a second attempt, give it a second id.
#
# Exit codes:
#   0  landed — the file is at the reported path
#   1  usage or environment error (bad arguments, no such work item, empty body)
#   4  the report path already exists — nothing was written, and the existing
#      file is named in the message
#
#   4 stays distinct from 1 for the same reason it does on `coordinate pin
#   --preflight`: 1 means what you handed me is wrong, 4 means the destination is
#   already spoken for. They call for different corrections, and a caller that
#   cannot tell them apart has to go look at the directory to find out.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  sed -n '2,52p' "$0" >&2
}

WORK_ITEM=""
REPORT_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report-id) REPORT_ID="${2:-}"; shift 2 ;;
    --report-id=*) REPORT_ID="${1#*=}"; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --kdir=*) KDIR_OVERRIDE="${1#*=}"; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "[coordinate] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

# refuse <exit-code> <message> — a validation refusal, distinguished from a
# usage error by its code. json_error exits 1, so the JSON terminal is printed
# by hand here.
refuse() {
  local code="$1" msg="$2"
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -n --arg error "$msg" --argjson code "$code" '{ok: false, error: $error, exit_code: $code}'
  else
    printf '[coordinate] Error: %s\n' "$msg" >&2
  fi
  exit "$code"
}

if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
  echo "[coordinate] Error: missing required argument: work-item" >&2
  usage
  exit 1
fi
WORK_ITEM="${POSITIONAL[0]}"
if [[ ${#POSITIONAL[@]} -gt 1 ]]; then
  echo "[coordinate] Error: unexpected argument '${POSITIONAL[1]}'" >&2
  usage
  exit 1
fi

[[ -n "$REPORT_ID" ]] || fail "missing required option: --report-id (the id assigned at dispatch; it decides the filename)"
if [[ "$REPORT_ID" == */* || "$REPORT_ID" == .* || "$REPORT_ID" == *..* ]]; then
  fail "invalid --report-id '$REPORT_ID': the id becomes a filename, so it may not contain '/' or '..' or start with a dot"
fi
command -v jq &>/dev/null || fail "jq is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

ITEM_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"
[[ -d "$ITEM_DIR" ]] || fail "work item '$WORK_ITEM' has no directory at $ITEM_DIR — reports land beside the item they belong to, so the item must exist first"

BODY="$(cat)"
# Glob-match rather than ${BODY//[[:space:]]/}: pattern substitution over a large
# multibyte body is super-linear in bash, and report bodies run to tens of KB.
[[ "$BODY" == *[![:space:]]* ]] || fail "the report body arrives on stdin and it was empty — pipe the returned report in, e.g. printf '%s' \"\$REPORT\" | lore coordinate report $WORK_ITEM --report-id $REPORT_ID"

# --- Landing ------------------------------------------------------------------

REPORTS_DIR="$ITEM_DIR/worker-reports"
DEST="$REPORTS_DIR/$REPORT_ID.md"

if [[ -e "$DEST" ]]; then
  refuse 4 "a report is already landed at $DEST. An accepted report is immutable, so this call writes nothing — not even for a byte-identical body. A second attempt at this task needs a fresh report id."
fi

mkdir -p "$REPORTS_DIR" || fail "could not create $REPORTS_DIR"

# atomic_write leaves either no file or the complete report; a reader never sees
# a partial one, and a failed mktemp stops before the printf.
atomic_write() {
  # atomic_write <dir> <dest-path> <content>
  local dir="$1" dest="$2" content="$3" tmp
  if ! tmp="$(mktemp "$dir/.tmp.report.XXXXXX" 2>/dev/null)"; then
    echo "[coordinate] Error: could not create a temporary file in $dir — nothing was landed" >&2
    return 1
  fi
  if ! printf '%s\n' "$content" > "$tmp" || ! mv "$tmp" "$dest"; then
    rm -f "$tmp"
    echo "[coordinate] Error: could not write the report at $dest — nothing was landed" >&2
    return 1
  fi
}

atomic_write "$REPORTS_DIR" "$DEST" "$BODY" || exit 1

BYTES=$(wc -c < "$DEST" | tr -d '[:space:]')

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --arg path "$DEST" \
    --arg work_item "$WORK_ITEM" \
    --arg report_id "$REPORT_ID" \
    --argjson bytes "$BYTES" \
    '{ok: true, work_item: $work_item, report_id: $report_id, path: $path, bytes: $bytes}')"
fi

echo "[coordinate] landed report '$REPORT_ID' ($BYTES bytes) at $DEST"
