#!/usr/bin/env bash
# coordinate-spend.sh — Roll up session spend from the journal, by work item.
#
# Usage:
#   lore coordinate spend [--arc <slug> | --work-item <slug>]
#                         [--window-start <RFC3339> --window-end <RFC3339>]
#                         [--kdir <path>] [--json]
#
# Options:
#   --arc <slug>          Scope to one arc's declared members (the `members`
#                         array in _work/_arcs/<slug>/_meta.json).
#   --work-item <slug>    Scope to one work item. Not combinable with --arc.
#   --window-start <ts>   Lower bound, RFC3339. Must be paired with --window-end.
#   --window-end <ts>     Upper bound, RFC3339. Must be paired with --window-start.
#   --kdir <path>         Knowledge-store override (test isolation).
#   --json                Emit one machine-readable object instead of prose.
#   --help, -h            Show this help.
#
# What it reads, and what it does not:
#   The journal's `closed` rows carry a session's spend; this verb sums them and
#   groups by work item. It reads them through `lore session events --json`,
#   the reference cursor reader, rather than opening events.jsonl — one reader
#   owns the malformed-row and window-bounding rules, and this is a consumer.
#   The verb writes nothing.
#
#   Spend arrives already normalized: `duration_seconds` always, plus a `basis`
#   saying where the token counts came from (transcript, rollout, store, or
#   duration-only when they could not be sourced at all). Per-harness token
#   dialects were reconciled at extraction, so nothing here re-maps them — a
#   duration-only row contributes its seconds and no tokens, and the output says
#   how many rows landed in each basis so a small token total is readable as
#   "mostly unmeasured" rather than "cheap".
#
# How rows are attributed to a work item:
#   A worker session runs under a derived slug (`<item>--w1`), which matches no
#   arc member by string. The journal's writer already stamps `links.work_item`
#   with the base slug on those rows, so the grouping reads that link and falls
#   back to `.slug` when it is absent. Both keys, always — a `.slug`-only
#   predicate silently drops every worker session, which is most of an arc's
#   cost.
#
# This is not retro's session-spend number, on purpose:
#   Retro sums `closed` rows by exact work-item slug, so worker sessions fall
#   out of its join — it is measuring what the orchestration cost. An arc tally
#   wants the opposite: the worker sessions *are* the arc's cost. The two
#   numbers differ for the same arc and both are correct. Do not reconcile them.
#
#   `orphaned` rows carry spend too — a session whose instance died and whose
#   recovery found no surviving tmux. They are reported on their own line and
#   never folded into the total, because the total means "the journal's closed
#   sessions". Dropping them silently would make the tally quietly low, so the
#   exclusion is printed instead of hidden.
#
# Exit codes:
#   0  the roll-up printed, including when it found nothing in scope
#   1  usage or environment error
#   4  --arc named an arc with no record — the scope does not exist, and
#      reporting zero for a mistyped slug would look like a cheap arc

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

EVENTS_SH="$SCRIPT_DIR/session-events.sh"

# Read-only mirror of two event names owned by session-event-append.sh's
# case-arm. tests/test_coordinate_spend.sh cross-checks both against that
# writer; if the vocabulary changes there, that test fails here.
CLOSED_EVENT="closed"
ORPHANED_EVENT="orphaned"

ARC=""
WORK_ITEM=""
WINDOW_START=""
WINDOW_END=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  sed -n '2,58p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arc) ARC="${2:-}"; shift 2 ;;
    --arc=*) ARC="${1#*=}"; shift ;;
    --work-item) WORK_ITEM="${2:-}"; shift 2 ;;
    --work-item=*) WORK_ITEM="${1#*=}"; shift ;;
    --window-start) WINDOW_START="${2:-}"; shift 2 ;;
    --window-start=*) WINDOW_START="${1#*=}"; shift ;;
    --window-end) WINDOW_END="${2:-}"; shift 2 ;;
    --window-end=*) WINDOW_END="${1#*=}"; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --kdir=*) KDIR_OVERRIDE="${1#*=}"; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[coordinate] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  die "$msg"
}

refuse() {
  local code="$1" msg="$2"
  if [[ $JSON_MODE -eq 1 ]]; then
    jq -n --arg error "$msg" --argjson code "$code" '{ok: false, error: $error, exit_code: $code}'
  else
    printf '[coordinate] Error: %s\n' "$msg" >&2
  fi
  exit "$code"
}

if [[ -n "$ARC" && -n "$WORK_ITEM" ]]; then
  fail "--arc and --work-item are alternative scopes; pass one. An arc already expands to its member work items."
fi
if [[ -n "$WINDOW_START" || -n "$WINDOW_END" ]]; then
  [[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || fail "--window-start and --window-end must be supplied together — an open-ended window would silently mean 'the whole journal' on one side"
fi

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

# --- Scope resolution ---------------------------------------------------------

MEMBERS_JSON="null"
SCOPE_LABEL="every work item in the journal"

if [[ -n "$ARC" ]]; then
  ARC_META="$KNOWLEDGE_DIR/_work/_arcs/$ARC/_meta.json"
  if [[ ! -f "$ARC_META" ]]; then
    refuse 4 "arc '$ARC' has no record at $ARC_META. Check the slug with 'lore arc list' — an unknown arc scoped to nothing would print a zero tally that reads like a cheap arc."
  fi
  MEMBERS_JSON="$(jq -c '.members // []' "$ARC_META")" || fail "could not read the members array from $ARC_META"
  MEMBER_COUNT="$(jq 'length' <<<"$MEMBERS_JSON")"
  MEMBER_NOUN="members"
  [[ "$MEMBER_COUNT" -eq 1 ]] && MEMBER_NOUN="member"
  SCOPE_LABEL="arc '$ARC' ($MEMBER_COUNT declared $MEMBER_NOUN)"
elif [[ -n "$WORK_ITEM" ]]; then
  MEMBERS_JSON="$(jq -c -n --arg s "$WORK_ITEM" '[$s]')"
  SCOPE_LABEL="work item '$WORK_ITEM'"
fi

# --- Journal read -------------------------------------------------------------

EVENTS_ARGS=(--json --kdir "$KNOWLEDGE_DIR")
if [[ -n "$WINDOW_START" ]]; then
  EVENTS_ARGS+=(--window-start "$WINDOW_START" --window-end "$WINDOW_END")
fi

WORK_TMP="$(mktemp -d)" || fail "could not create a temporary directory"
trap 'rm -rf "$WORK_TMP"' EXIT
JOURNAL_FILE="$WORK_TMP/journal.json"

bash "$EVENTS_SH" "${EVENTS_ARGS[@]}" > "$JOURNAL_FILE" || fail "the journal reader failed; nothing was rolled up"

ROLLUP="$(
  python3 - "$JOURNAL_FILE" "$MEMBERS_JSON" "$CLOSED_EVENT" "$ORPHANED_EVENT" <<'PYEOF'
import json, sys

journal_path, members_raw, closed_event, orphaned_event = sys.argv[1:5]
members = json.loads(members_raw)
scope = set(members) if members is not None else None

with open(journal_path, encoding="utf-8") as f:
    payload = json.load(f)
events = payload.get("events") or []


def group_key(row):
    """The journal's two identity keys, in the order the writer stamps them.

    A worker session's own slug is derived (`<item>--w1`); links.work_item
    carries the base slug it belongs to. Reading only .slug drops those rows.
    """
    link = ((row.get("links") or {}).get("work_item") or "").strip()
    if link:
        return link
    return (row.get("slug") or "").strip() or "(unattributed)"


TOKEN_FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "reasoning_output_tokens",
)


def new_bucket():
    return {
        "sessions": 0,
        "duration_seconds": 0,
        "total_tokens": 0,
        "cost_usd": 0.0,
        "token_rows": 0,
        "basis": {},
    }


def absorb(bucket, row):
    bucket["sessions"] += 1
    spend = row.get("spend") or {}
    basis = spend.get("basis") or "unstated"
    bucket["basis"][basis] = bucket["basis"].get(basis, 0) + 1
    bucket["duration_seconds"] += int(spend.get("duration_seconds") or 0)
    # total_tokens is the normalized roll-up field; sum the component fields
    # only when the extractor left it out, and never re-derive across dialects.
    total = spend.get("total_tokens")
    if total is None:
        parts = [spend.get(f) for f in TOKEN_FIELDS]
        total = sum(p for p in parts if isinstance(p, (int, float)))
        if not any(isinstance(p, (int, float)) for p in parts):
            total = 0
    if total:
        bucket["total_tokens"] += int(total)
        bucket["token_rows"] += 1
    cost = spend.get("cost_usd")
    if isinstance(cost, (int, float)):
        bucket["cost_usd"] += float(cost)


by_item = {}
closed_total = new_bucket()
orphaned_total = new_bucket()
orphaned_by_item = {}

for row in events:
    event = row.get("event")
    if event not in (closed_event, orphaned_event):
        continue
    key = group_key(row)
    if scope is not None and key not in scope:
        continue
    if event == closed_event:
        absorb(closed_total, row)
        absorb(by_item.setdefault(key, new_bucket()), row)
    else:
        absorb(orphaned_total, row)
        absorb(orphaned_by_item.setdefault(key, new_bucket()), row)

out = {
    "closed": closed_total,
    "by_work_item": by_item,
    "orphaned": orphaned_total,
    "orphaned_by_work_item": orphaned_by_item,
}
print(json.dumps(out, separators=(",", ":")))
PYEOF
)" || fail "could not roll up the journal rows"

# --- Output -------------------------------------------------------------------

WINDOW_LABEL="the whole journal"
[[ -n "$WINDOW_START" ]] && WINDOW_LABEL="$WINDOW_START .. $WINDOW_END"

if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(jq -n \
    --argjson rollup "$ROLLUP" \
    --arg arc "$ARC" \
    --arg work_item "$WORK_ITEM" \
    --arg window_start "$WINDOW_START" \
    --arg window_end "$WINDOW_END" \
    --argjson members "$MEMBERS_JSON" \
    '{ok: true,
      scope: {arc: (if $arc == "" then null else $arc end),
              work_item: (if $work_item == "" then null else $work_item end),
              members: $members},
      window: {start: (if $window_start == "" then null else $window_start end),
               end: (if $window_end == "" then null else $window_end end)}}
     + $rollup')"
fi

ROLLUP_FILE="$WORK_TMP/rollup.json"
printf '%s\n' "$ROLLUP" > "$ROLLUP_FILE"

python3 - "$ROLLUP_FILE" "$SCOPE_LABEL" "$WINDOW_LABEL" <<'PYEOF'
import json, sys

rollup_path, scope_label, window_label = sys.argv[1:4]
with open(rollup_path, encoding="utf-8") as f:
    data = json.load(f)


def duration(seconds):
    hours, rest = divmod(int(seconds), 3600)
    minutes = rest // 60
    if hours:
        return f"{hours}h {minutes:02d}m"
    return f"{minutes}m"


def basis_line(bucket):
    parts = sorted(bucket["basis"].items(), key=lambda kv: (-kv[1], kv[0]))
    return ", ".join(f"{name} {count}" for name, count in parts) or "none"


def money(value):
    return f"${value:,.2f}" if value else "$0.00 (no cost reported)"


def sessions(count):
    return f"{count} session" if count == 1 else f"{count} sessions"


closed = data["closed"]
print(f"scope:  {scope_label}")
print(f"window: {window_label}")
print()
print(
    f"closed: {sessions(closed['sessions'])}  "
    f"duration {duration(closed['duration_seconds'])}  "
    f"tokens {closed['total_tokens']:,}  "
    f"cost {money(closed['cost_usd'])}"
)
print(f"  token basis: {basis_line(closed)}")
if closed["sessions"] and closed["token_rows"] < closed["sessions"]:
    unmeasured = closed["sessions"] - closed["token_rows"]
    print(
        f"  {unmeasured} of {closed['sessions']} closed rows reported no tokens; "
        "their duration is in the total and their tokens are not."
    )
elif not closed["sessions"]:
    print("  nothing closed in scope — the total above is zero because there were no rows, not because they were free.")

by_item = data["by_work_item"]
if by_item:
    print()
    print("by work item:")
    width = max(len(k) for k in by_item)
    for key, bucket in sorted(
        by_item.items(), key=lambda kv: (-kv[1]["total_tokens"], -kv[1]["duration_seconds"], kv[0])
    ):
        print(
            f"  {key.ljust(width)}  {sessions(bucket['sessions']):>11}  "
            f"{duration(bucket['duration_seconds']):>9}  "
            f"{bucket['total_tokens']:>12,} tokens  {money(bucket['cost_usd'])}"
        )

orphaned = data["orphaned"]
print()
if orphaned["sessions"]:
    print(
        f"orphaned (NOT in the total above): {sessions(orphaned['sessions'])}  "
        f"duration {duration(orphaned['duration_seconds'])}  "
        f"tokens {orphaned['total_tokens']:,}"
    )
    print(
        "  These are sessions whose instance died before a clean close. Their cost "
        "was real; it is reported separately because the total means closed sessions."
    )
else:
    print("orphaned: none in scope")
PYEOF
