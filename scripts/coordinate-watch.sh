#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: coordinate-watch.sh [--arc SLUG]... [--until EVENTS] [--since CURSOR]
       [--timeout SECONDS] [--owner-pid PID | --owner-tmux NAME]
       [--tmux-server NAME] [--durable] [--compact] [--wake-shaped] [--kdir PATH] [--json]
       [--reconcile-interval SECONDS] [--reconcile-budget SECONDS]
       [--peek-timeout SECONDS] [--pending-stale SECONDS] [--spawn-gap SECONDS]

Watch scoped journal events and current session observations. Activity is separate
from input eligibility. Unknown or unavailable observation cannot confirm a park.
Default heartbeat is 600 seconds; reconciliation runs every 15 seconds with an
8-second budget and at most four concurrent peers, rotating across larger scopes.

--durable retains each wake_id until coordinate status --wake-id ID acknowledges
that exact receipt. Owner identity is required. Unacknowledged unchanged wakes
retry on the heartbeat cadence; new facts can wake promptly. Raw calls without
--durable retain cursor-based compatibility. --spawn-gap is a compatibility option;
current lifecycle observation determines activity.

Exit 0: event/advisory; 2: quiet heartbeat; 3: owner gone; 4: reader failure.
--compact implies --durable and requires an owner handle. Its notification is
bounded to 8KiB, with omitted counts and an exact full-evidence receipt pointer.
Durable --wake-shaped defaults to compact and emits only on stderr.
--wake-shaped sends re-armable output to stderr with exit 2. It makes no worker
input and does not itself provide a harness continuation capability.
EOF
}

UNTIL="${SESSION_ACTIONABLE_EVENTS// /,}"
SINCE=""
SINCE_SET=0
TIMEOUT=600
PENDING_STALE=300
PEEK_TIMEOUT=10
SPAWN_GAP=90
OWNER_PID=""
OWNER_TMUX=""
TMUX_SERVER="lore-tui"
WAKE_SHAPED=0
DURABLE=0
COMPACT=0
RECONCILE_INTERVAL=15
RECONCILE_BUDGET=8
KDIR_OVERRIDE=""
JSON_MODE=0
CURSOR_SCHEMA_VERSION=1
WAKE_SCHEMA_VERSION=1
WAKE_JOURNAL_BATCH='[]'
OWNER_GONE_GRACE_SECONDS=2

SCOPE_SLUGS=()
SCOPE_ARCS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arc) SCOPE_ARCS+=("${2:-}"); shift 2 ;;
    --until) UNTIL="${2:-}"; shift 2 ;;
    --since) SINCE="${2:-}"; SINCE_SET=1; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --pending-stale) PENDING_STALE="${2:-}"; shift 2 ;;
    --peek-timeout) PEEK_TIMEOUT="${2:-}"; shift 2 ;;
    --spawn-gap) SPAWN_GAP="${2:-}"; shift 2 ;;
    --owner-pid) OWNER_PID="${2:-}"; shift 2 ;;
    --owner-tmux) OWNER_TMUX="${2:-}"; shift 2 ;;
    --tmux-server) TMUX_SERVER="${2:-}"; shift 2 ;;
    --wake-shaped) WAKE_SHAPED=1; shift ;;
    --compact) COMPACT=1; DURABLE=1; shift ;;
    --durable) DURABLE=1; shift ;;
    --reconcile-interval) RECONCILE_INTERVAL="${2:-}"; shift 2 ;;
    --reconcile-budget) RECONCILE_BUDGET="${2:-}"; shift 2 ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: coordinate-watch.sh [--arc <slug>]... [--until <events>] [--since <cursor>] [--timeout <sec>] [--pending-stale <sec>] [--peek-timeout <sec>] [--spawn-gap <sec>] [--owner-pid <pid>] [--owner-tmux <name>] [--tmux-server <name>] [--wake-shaped] [--kdir <path>] [--json]" >&2
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

if [[ $WAKE_SHAPED -eq 1 && $DURABLE -eq 1 ]]; then COMPACT=1; fi

command -v jq &>/dev/null || fail "jq is required but not found on PATH"
command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

check_non_negative() {
  local flag="$1" value="$2" tail="${3:-}"
  [[ "$value" =~ ^[0-9]+$ ]] \
    || fail "invalid $flag: '$value' (must be a non-negative integer${tail:+; $tail})"
}

check_non_negative --reconcile-interval "$RECONCILE_INTERVAL"
check_non_negative --reconcile-budget "$RECONCILE_BUDGET"
check_non_negative --timeout "$TIMEOUT"
check_non_negative --pending-stale "$PENDING_STALE" "0 disables"
check_non_negative --peek-timeout "$PEEK_TIMEOUT" "0 disables"
check_non_negative --spawn-gap "$SPAWN_GAP" "0 disables the age gate"

if [[ -n "$OWNER_PID" ]] && ! [[ "$OWNER_PID" =~ ^[1-9][0-9]*$ ]]; then
  fail "invalid --owner-pid: '$OWNER_PID' (must be a positive integer)"
fi
if [[ -n "$OWNER_PID" && -n "$OWNER_TMUX" ]]; then
  fail "watcher identity takes exactly one owner handle: pass --owner-pid or --owner-tmux, not both"
fi
if [[ $SINCE_SET -eq 1 ]]; then
  case "$SINCE" in
    ''|*[!0-9]*) fail "invalid --since: '$SINCE' (must be a non-negative byte offset)" ;;
  esac
fi

# --- Validate --until against the writer's vocabulary; build the until-set ---
[[ -n "${UNTIL// }" ]] || fail "empty --until: pass at least one event name"
UNTIL_TOKENS=()
IFS=',' read -r -a _until_raw <<< "$UNTIL"
for tok in "${_until_raw[@]}"; do
  tok="${tok// }"   # tolerate incidental spaces around the commas
  [[ -n "$tok" ]] || continue
  session_event_in_vocab "$tok" \
    || fail "invalid --until event: '$tok' (not in the session event vocabulary)"
  UNTIL_TOKENS+=("$tok")
done
[[ ${#UNTIL_TOKENS[@]} -gt 0 ]] || fail "empty --until: pass at least one event name"

# --- Resolve store ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # A hook-hosted firing for a removed store is stale identity. It must not
  # create the store, emit a wake, or enter an error/re-arm loop.
  [[ $WAKE_SHAPED -eq 1 ]] && exit 3
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi
KNOWLEDGE_DIR="$(canonical_existing_dir "$KNOWLEDGE_DIR")" \
  || fail "could not canonicalize knowledge store: $KNOWLEDGE_DIR"

if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  NORMALIZED_ARCS=()
  while IFS= read -r arc; do
    [[ -n "$arc" ]] && NORMALIZED_ARCS+=("$arc")
  done < <(printf '%s\n' "${SCOPE_ARCS[@]}" | LC_ALL=C sort -u)
  SCOPE_ARCS=("${NORMALIZED_ARCS[@]}")
fi

EVENTS_SH="$SCRIPT_DIR/session-events.sh"
PEEK_SH="$SCRIPT_DIR/session-peek.sh"
EVENTS_FILE="$KNOWLEDGE_DIR/_sessions/events.jsonl"
PENDING_DIR="$KNOWLEDGE_DIR/_sessions/requests/pending"
# The watcher's sidecars sit at the top of _coordination/, deliberately outside
# the journal and outside the worktree manager's registry — every directory under
# there has a sole writer that would not expect a second file appearing in it.
COORD_DIR="$KNOWLEDGE_DIR/_coordination"

# --- Resolve the scope ------------------------------------------------------

SCOPE_REQUESTED=0
if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  SCOPE_REQUESTED=1
fi

for arc in ${SCOPE_ARCS[@]+"${SCOPE_ARCS[@]}"}; do
  [[ -n "$arc" ]] || fail "empty --arc: pass an arc slug"
  ARC_STATUS=0
  ARC_MEMBERS="$(session_arc_member_slugs "$KNOWLEDGE_DIR" "$arc")" || ARC_STATUS=$?
  case "$ARC_STATUS" in
    0) ;;
    1) fail "unknown --arc: '$arc' (no arc record at _work/_arcs/$arc/_meta.json)" ;;
    2) fail "unreadable arc record for --arc '$arc': _work/_arcs/$arc/_meta.json is not a JSON object" ;;
    3) fail "--arc '$arc' is closed, archived, or carries an unknown status; only active arcs can be watched" ;;
    *) fail "could not expand --arc '$arc'" ;;
  esac
  # An arc with no declared members scopes to nothing on its own. Naming it beats
  # a watch that silently never wakes; the arc may simply carry project-labeled
  # items that were never added as members.
  if [[ -z "${ARC_MEMBERS//[[:space:]]/}" ]]; then
    echo "[coordinate] arc '$arc' declares no members; it contributes nothing to this scope" >&2
    continue
  fi
  while IFS= read -r member; do
    [[ -n "$member" ]] || continue
    SCOPE_SLUGS+=("$member")
  done <<< "$ARC_MEMBERS"
done

# A requested scope that expanded to nothing must not fall through to watching
# the whole board — the caller would get wakes it did not ask for and no sign
# that its scope was dropped. Refuse here, where the message can name the fix.
if [[ $SCOPE_REQUESTED -eq 1 && ${#SCOPE_SLUGS[@]} -eq 0 ]]; then
  fail "the requested scope expands to no work items (every --arc given declares an empty members[]); add members with \`lore arc member\`, or drop --arc to watch the whole board"
fi

SCOPED=0
SCOPE_MODE="board"
SCOPE_SUFFIX="board"
if [[ ${#SCOPE_SLUGS[@]} -gt 0 ]]; then
  SCOPED=1
  SCOPE_MODE="scoped"
  # One scope, one set of sidecars. The key is order-insensitive and
  # duplicate-insensitive so the same scope written two ways resumes one cursor.
  SCOPE_SUFFIX="$(printf '%s\n' "${SCOPE_SLUGS[@]}" | LC_ALL=C sort -u \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')"
fi

if [[ -n "$OWNER_PID" ]]; then
  IDENTITY_OWNER_KIND="pid"; IDENTITY_OWNER_VALUE="$OWNER_PID"
elif [[ -n "$OWNER_TMUX" ]]; then
  IDENTITY_OWNER_KIND="tmux"; IDENTITY_OWNER_VALUE="$OWNER_TMUX"
else
  IDENTITY_OWNER_KIND="none"; IDENTITY_OWNER_VALUE=""
fi
IDENTITY_KEY="$(watcher_identity_hash "$KNOWLEDGE_DIR" "$IDENTITY_OWNER_KIND" \
  "$IDENTITY_OWNER_VALUE" "$TMUX_SERVER" ${SCOPE_ARCS+"${SCOPE_ARCS[@]}"})"
CURSOR_FILE="$COORD_DIR/watch-cursor-$IDENTITY_KEY-$SCOPE_SUFFIX.json"
DELIVERY_FILE="$COORD_DIR/watch-delivery-$IDENTITY_KEY.json"
OBSERVATION_FILE="$COORD_DIR/watch-observation-$IDENTITY_KEY-$SCOPE_SUFFIX.json"
WATCH_HELPER="$SCRIPT_DIR/coordinate_watch_state.py"
if [[ $DURABLE -eq 1 && "$IDENTITY_OWNER_KIND" == "none" ]]; then
  fail "--durable requires --owner-pid or --owner-tmux for receipt identity"
fi
IDENTITY_JSON="$(jq -cn --arg key "$IDENTITY_KEY" --arg kind "$IDENTITY_OWNER_KIND" --arg value "$IDENTITY_OWNER_VALUE" --arg server "$TMUX_SERVER" --arg scope "$SCOPE_SUFFIX" '{key:$key,owner_kind:$kind,owner_value:$value,tmux_server:$server,scope:$scope}')"

if [[ $SCOPED -eq 1 ]]; then
  SCOPE_SLUGS_JSON="$(printf '%s\n' "${SCOPE_SLUGS[@]}" | LC_ALL=C sort -u | jq -R . | jq -s -c .)"
else
  SCOPE_SLUGS_JSON='[]'
fi
if [[ ${#SCOPE_ARCS[@]} -gt 0 ]]; then
  SCOPE_ARCS_JSON="$(printf '%s\n' "${SCOPE_ARCS[@]}" | jq -R . | jq -s -c .)"
else
  SCOPE_ARCS_JSON='[]'
fi
UNTIL_JSON="$(printf '%s\n' "${UNTIL_TOKENS[@]}" | jq -R . | jq -s -c .)"

# --- Cursor persistence ------------------------------------------------------

read_cursor_file() {
  if [[ $DURABLE -eq 1 ]]; then
    local observed
    observed="$(python3 "$WATCH_HELPER" cursor --path "$DELIVERY_FILE")" || return 1
    if [[ "$observed" != "null" ]]; then
      printf '%s\n' "$observed"
      return 0
    fi
  fi
  [[ -f "$CURSOR_FILE" ]] || return 1
  local value
  value="$(jq -r 'if (.cursor | type) == "number" and .cursor >= 0 then .cursor else empty end' \
    "$CURSOR_FILE" 2>/dev/null)" || return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

# Written through mktemp + rename so a watcher killed mid-write leaves the prior
# cursor intact rather than a truncated file the next run has to guess about.
write_cursor_file() {
  local cursor="$1" tmp
  mkdir -p "$COORD_DIR"
  tmp="$(mktemp "$COORD_DIR/.tmp.watch-cursor.XXXXXX")" || return 0
  if jq -n --argjson v "$CURSOR_SCHEMA_VERSION" --argjson c "$cursor" \
    --arg at "$(timestamp_iso)" \
    '{schema_version: $v, cursor: $c, updated_at: $at}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CURSOR_FILE"
  else
    rm -f "$tmp"
  fi
}

# --- Wake payload and terminals ----------------------------------------------

WAKE_OUTCOME=""
WAKE_TIER="quiet"
WAKE_AUTHORITY="none"
WAKE_STATE="none"
WAKE_LABEL=""
WAKE_REASON="null"          # JSON
WAKE_PEEK="null"            # JSON
WAKE_MATCHED="null"         # JSON
WAKE_PENDING="[]"           # JSON
WAKE_SPAWN_GAP="null"       # JSON
WAKE_MODAL_GATE="null"      # JSON
WAKE_CLOCK_SKEW="null"      # JSON
CURRENT_OBSERVATIONS='{"current":[],"delta":[],"unavailable":[],"complete":false}'
CURRENT_DELTA='[]'
LAST_RECONCILE=0

# emit_wake <cursor> <exit-code> <message>
# The single terminal. Non-zero terminals print their JSON by hand: json_output
# hard-exits 0, which would erase the composed exit code.
emit_wake() {
  local cursor="$1" code="$2" message="$3" payload

  CURRENT_OBSERVATIONS="$(printf '%s' "$CURRENT_OBSERVATIONS" | python3 "$WATCH_HELPER" current)" || fail "could not validate current observation freshness"
  CURRENT_DELTA="$(printf '%s' "$CURRENT_OBSERVATIONS" | jq -c '.delta')"
  if [[ "$WAKE_OUTCOME" == "current_delta" ]]; then
    WAKE_TIER="$(printf '%s' "$CURRENT_DELTA" | jq -r 'if any(.[]; .observation.fresh == true and (.observation.activity == "idle" or .observation.activity == "blocked")) then "confirmed" else "advisory" end')"
  fi
  payload="$(jq -cn \
    --argjson schema "$WAKE_SCHEMA_VERSION" \
    --arg outcome "$WAKE_OUTCOME" \
    --arg tier "$WAKE_TIER" \
    --arg authority "$WAKE_AUTHORITY" \
    --argjson signature_version "$SESSION_PARK_SIGNATURE_VERSION" \
    --arg state "$WAKE_STATE" \
    --arg label "$WAKE_LABEL" \
    --argjson reason "$WAKE_REASON" \
    --argjson peek "$WAKE_PEEK" \
    --argjson spawn_gap "$WAKE_SPAWN_GAP" \
    --argjson modal_gate "$WAKE_MODAL_GATE" \
    --argjson clock_skew "$WAKE_CLOCK_SKEW" \
    --argjson matched "$WAKE_MATCHED" \
    --argjson journal_batch "$WAKE_JOURNAL_BATCH" \
    --argjson pending "$WAKE_PENDING" \
    --arg mode "$SCOPE_MODE" \
    --argjson slugs "$SCOPE_SLUGS_JSON" \
    --argjson arcs "$SCOPE_ARCS_JSON" \
    --arg cursor_file "$(basename "$CURSOR_FILE")" \
    --argjson nc "$cursor" \
    --argjson until "$UNTIL_JSON" \
    --argjson current "$CURRENT_OBSERVATIONS" --argjson delta "$CURRENT_DELTA" \
    '{schema_version: $schema, outcome: $outcome, tier: $tier, authority: $authority,
      signature_version: $signature_version,
      classification: {state: $state, label: $label, reason: $reason,
                       peek: $peek, spawn_gap: $spawn_gap,
                       modal_gate: $modal_gate},
      clock_skew: $clock_skew,
      matched: $matched, pending: $pending,
      scope: {mode: $mode, slugs: $slugs, arcs: $arcs, cursor_file: $cursor_file},
      next_cursor: $nc, until: $until, current_observations:$current, current_delta:$delta}
      + (if ($journal_batch | length) > 1 then {journal_batch:$journal_batch} else {} end)')"

  if [[ $DURABLE -eq 1 ]]; then
    payload="$(printf '%s' "$payload" | python3 "$WATCH_HELPER" publish --path "$DELIVERY_FILE" --identity "$IDENTITY_JSON" --interval "$TIMEOUT")" || fail "could not persist wake; cursor remains uncommitted"
    [[ "$payload" != "null" ]] || return 0
  fi
  [[ "$cursor" == "null" ]] || write_cursor_file "$cursor"
  printf '%s' "$payload" | python3 "$WATCH_HELPER" consume --path "$OBSERVATION_FILE" >/dev/null || fail "could not commit observation delta"

  if [[ $COMPACT -eq 1 ]]; then
    emit_compact "$payload" "$code"
  fi
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$payload"
  else
    [[ "$WAKE_MATCHED" == "null" ]] || printf '%s\n' "$WAKE_MATCHED"
    if [[ "$WAKE_OUTCOME" == "pending_stale" ]]; then
      jq -cn --argjson pending "$WAKE_PENDING" '{advisory: "pending_stale", requests: $pending}'
    fi
    jq -cn --argjson wake "$payload" '{wake: $wake}'
    [[ "$cursor" == "null" ]] || jq -cn --argjson nc "$cursor" '{next_cursor: $nc}'
  fi

  echo "$message" >&2
  if [[ $WAKE_SHAPED -eq 1 ]]; then
    printf '%s\n' "$payload" >&2
    # Every re-armable terminal reports the same way, so a continuation channel
    # can act on one code. 3 and 4 are not re-armable and keep their meanings.
    case "$code" in
      0|2) code=2 ;;
    esac
  fi
  exit "$code"
}

emit_internal_error() {
  local cursor="$1"
  WAKE_OUTCOME="internal_error"
  WAKE_TIER="quiet"
  WAKE_AUTHORITY="none"
  WAKE_STATE="reader_failed"
  WAKE_LABEL="session-events-failed-after-3-attempts"
  emit_wake "$cursor" 4 \
    "[coordinate] internal error: session-events failed after 3 attempts; fix the reader dependency and retry"
}

# --- Readers -----------------------------------------------------------------

# First row in the until-set that the scope admits, paired with the cursor the
# reader assigned to that row's end.
#
# The pairing is the point: one read can contain several actionable rows, and a
# match that reported the batch's end cursor would persist a position past the
# rows it never handed over — they would be skipped forever, since the next call
# resumes from that cursor. The reader owns each row's byte boundary in
# `.records`, the same boundaries `session wait` follows in follow mode; this verb
# applies the until-set and the scope predicate. Scoping raises the stakes on that
# discipline: the more rows a read withholds, the more a batch-end cursor loses.
first_match_record() {
  printf '%s' "$1" | jq -c \
    --argjson until "$UNTIL_JSON" \
    --argjson durable "$DURABLE" \
    --argjson slugs "$SCOPE_SLUGS_JSON" \
    --argjson scoped "$SCOPED" \
    "$SESSION_SCOPE_JQ_PREDICATE"'
    .records as $records |
    [
      $records[] as $candidate
      | $candidate
      | select((.event.event != "needs_input" and .event.event != "modal_blocked") or
          ([ $records[] | select(.next_cursor > $candidate.next_cursor and .event.slug == $candidate.event.slug)
             | select(.event.event == "resumed" or .event.event == "closed" or .event.event == "recovered" or .event.event == "spawned") ] | length == 0))
      | select(.event.event as $e | $until | index($e))
      | (.event | scope_state($scoped; $slugs)) as $scope
      | select($scope.matched)
      | . + {scope: $scope}
    ] | if length == 0 then empty
        elif $durable == 1 then . as $batch | .[-1] + {matched_batch: [$batch[].event]}
        else .[0] end' 2>/dev/null || true
}

# Pending spawn requests older than the staleness bound, newest-first age order.
# Age comes from requested_at (the durable enqueue time) rather than file mtime,
# because a claiming instance rewrites the row on each retry and mtime would
# reset the clock on exactly the request that is stuck. mtime is the fallback for
# a row that predates the field or carries an unparseable value.
stale_pending() {
  python3 - "$PENDING_DIR" "$PENDING_STALE" <<'PYEOF'
import json, os, sys, time
from datetime import datetime, timezone

pending_dir, threshold = sys.argv[1], float(sys.argv[2])
now = time.time()
rows = []
if os.path.isdir(pending_dir):
    for name in sorted(os.listdir(pending_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(pending_dir, name)
        try:
            mtime = os.path.getmtime(path)
            with open(path, encoding="utf-8") as handle:
                row = json.load(handle)
        except (OSError, ValueError):
            continue
        stamp, source = None, "mtime"
        raw = row.get("requested_at")
        if isinstance(raw, str) and raw:
            try:
                text = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
                parsed = datetime.fromisoformat(text)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                stamp, source = parsed.timestamp(), "requested_at"
            except ValueError:
                stamp = None
        if stamp is None:
            stamp = mtime
        age = int(now - stamp)
        if age < threshold:
            continue
        rows.append({
            "request_id": row.get("request_id") or os.path.splitext(name)[0],
            "slug": row.get("slug"),
            "target_instance": row.get("target_instance"),
            "age_seconds": age,
            "age_source": source,
        })
rows.sort(key=lambda r: r["age_seconds"], reverse=True)
print(json.dumps(rows, separators=(",", ":")))
PYEOF
}

# --- Classification ----------------------------------------------------------

park_shaped() {
  local event="$1" known
  for known in $SESSION_PARK_SHAPED_EVENTS; do
    [[ "$event" == "$known" ]] && return 0
  done
  return 1
}

peek_session() {
  local slug="$1" out status=0

  out="$(printf '%s' "$CURRENT_OBSERVATIONS" | jq -c --arg slug "$slug" '[.current[]? | select(.slug == $slug) | .peek][0] // null')"
  if [[ "$out" == "null" ]]; then
    out="$(bash "$PEEK_SH" "$slug" --json --timeout "$PEEK_TIMEOUT" --kdir "$KNOWLEDGE_DIR" 2>/dev/null)" || status=$?
  fi
  if [[ $status -ne 0 ]]; then
    WAKE_PEEK="$(jq -n --arg e "$(printf '%s' "$out" | jq -r '.error // "peek did not answer"' 2>/dev/null || echo 'peek did not answer')" \
      '{consulted: true, ready: null, blocked_reason: null, error: $e}')"
    return 1
  fi

  WAKE_PEEK="$(printf '%s' "$out" | jq -c '. + {consulted:true,error:null}')"
}

classify_match() {
  local row="$1" unattributed="$2" event slug row_reason

  event="$(printf '%s' "$row" | jq -r '.event')"
  slug="$(printf '%s' "$row" | jq -r '.slug // ""')"
  row_reason="$(printf '%s' "$row" | jq -r '.reason // ""')"

  if [[ "$unattributed" == "true" ]]; then
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="unattributed_row"
    WAKE_LABEL="row-carries-neither-slug-nor-work-item"
    WAKE_REASON="$(jq -n --arg r "$row_reason" 'if $r == "" then null else $r end')"
    WAKE_TIER="advisory"
    return 0
  fi

  if ! park_shaped "$event"; then
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="hook-row"
    WAKE_STATE="row_authoritative"
    WAKE_LABEL="event-states-its-own-outcome"
    WAKE_REASON="$(jq -n --arg r "$row_reason" 'if $r == "" then null else $r end')"
    return 0
  fi

  WAKE_TIER="advisory"
  WAKE_AUTHORITY="none"
  WAKE_STATE="park_unconfirmed"
  WAKE_REASON="$(jq -cn --arg r "$row_reason" '$r')"
  if [[ "$PEEK_TIMEOUT" -eq 0 || -z "$slug" ]]; then
    WAKE_LABEL="observation-unavailable"
    return 0
  fi
  if ! peek_session "$slug"; then
    WAKE_LABEL="peek-unavailable"
    return 0
  fi
  local classified
  classified="$(jq -cn --argjson row "$row" --argjson peek "$WAKE_PEEK" '{row:$row,peek:$peek}' | python3 "$WATCH_HELPER" classify)"
  WAKE_TIER="$(printf '%s' "$classified" | jq -r '.tier')"
  WAKE_AUTHORITY="$(printf '%s' "$classified" | jq -r '.authority')"
  WAKE_STATE="$(printf '%s' "$classified" | jq -r '.state')"
  WAKE_LABEL="$(printf '%s' "$classified" | jq -r '.label')"
  WAKE_PEEK="$(printf '%s' "$WAKE_PEEK" | jq -c --argjson c "$classified" '. + {observation:$c.observation}')"

}

# clock_pair — "<wall><TAB><monotonic>", the two clocks read together.
# Wall time advances across a system suspension and monotonic time does not, so a
# pair taken now and a pair taken later bound how long this machine was asleep.
clock_pair() {
  python3 -c 'import time; print("%.3f\t%.3f" % (time.time(), time.monotonic()))'
}

# clock_elapsed <wall-baseline> <monotonic-baseline>
# "<wall_elapsed><TAB><monotonic_elapsed><TAB><skew>", whole seconds.
clock_elapsed() {
  python3 -c '
import sys, time

w0, m0 = float(sys.argv[1]), float(sys.argv[2])
wall = time.time() - w0
mono = time.monotonic() - m0
print("%d\t%d\t%d" % (int(wall), int(mono), int(wall - mono)))
' "$1" "$2"
}

# --- Baseline: explicit --since, else the persisted cursor, else journal end ---
if [[ $SINCE_SET -eq 1 ]]; then
  CURSOR="$SINCE"
elif CURSOR="$(read_cursor_file)"; then
  :
else
  # First-ever run for this scope: start at the end so the very first watch does
  # not replay a journal the board has already worked through.
  CURSOR="$(session_events_cursor "$EVENTS_SH" "$KNOWLEDGE_DIR")" || emit_internal_error null
fi

# A cursor is a row boundary inside this journal, and the reader refuses both
# ways of missing it. Refuse them here first: the reader's refusal reaches the
# loop as a read that failed, which retries twice more and exits as an internal
# error telling the seat to fix a dependency that is working correctly. The
# baseline is set once, so reading the journal's length here costs nothing on the
# poll path.
if [[ "$CURSOR" -gt 0 ]]; then
  JOURNAL_SIZE=0
  if [[ -f "$EVENTS_FILE" ]]; then
    JOURNAL_SIZE="$(wc -c < "$EVENTS_FILE" | tr -d '[:space:]')"
  fi
  if [[ "$CURSOR" -gt "$JOURNAL_SIZE" ]]; then
    if [[ $SINCE_SET -eq 1 ]]; then
      CURSOR_FIX="re-arm from a cursor this journal emitted, or drop --since to watch from the journal's end"
    else
      CURSOR_FIX="this cursor was persisted by an earlier watch — remove $CURSOR_FILE and the next watch re-baselines at the journal's end"
    fi
    fail "invalid cursor $CURSOR: cursor-past-eof — events.jsonl is $JOURNAL_SIZE bytes, so this cursor points past the end of the journal.
  The journal is append-only and is never compacted, truncated, or rotated, so a cursor lands here only if it was computed rather than echoed back, or if it was taken against a different journal (a store that was reset, restored, or replaced).
  Watching from it would replay the journal from byte zero and wake on rows the board worked through long ago, so it is refused rather than answered: $CURSOR_FIX"
  fi

  ALIGNMENT_STATUS=0
  session_cursor_row_aligned "$EVENTS_FILE" "$CURSOR" || ALIGNMENT_STATUS=$?
  case "$ALIGNMENT_STATUS" in
    0) ;;
    2) fail "invalid cursor $CURSOR: cursor-not-row-aligned (preceding byte is not newline); reuse a next_cursor emitted by lore coordinate watch, lore session wait, or lore session events" ;;
    *) fail "could not validate cursor $CURSOR" ;;
  esac
fi

OWNER_CHECK_ENABLED=0
if [[ -n "$OWNER_PID" || -n "$OWNER_TMUX" ]]; then
  OWNER_CHECK_ENABLED=1
fi

# emit_matched_from_record <record-json> — terminal for one matched read record.
emit_matched_from_record() {
  local record="$1" row cursor
  row="$(printf '%s' "$record" | jq -c '.event')"
  cursor="$(printf '%s' "$record" | jq -r '.next_cursor')"
  WAKE_OUTCOME="matched"
  WAKE_MATCHED="$row"
  WAKE_JOURNAL_BATCH="$(printf '%s' "$record" | jq -c '.matched_batch // []')"
  reconcile_current
  classify_match "$row" "$(printf '%s' "$record" | jq -r '.scope.unattributed')"
  emit_wake "$cursor" 0 \
    "[coordinate] wake: $(printf '%s' "$row" | jq -r '.event') on '$(printf '%s' "$row" | jq -r '.slug // "(no slug)"')' — tier=$WAKE_TIER authority=$WAKE_AUTHORITY state=$WAKE_STATE label=$WAKE_LABEL"
}

reconcile_current() {
  local current_time
  current_time=$(date +%s)
  if [[ "${1:-}" != "force" && $LAST_RECONCILE -gt 0 && $((current_time - LAST_RECONCILE)) -lt $RECONCILE_INTERVAL ]]; then
    return 0
  fi
  CURRENT_OBSERVATIONS="$(python3 "$WATCH_HELPER" sweep --kdir "$KNOWLEDGE_DIR" --scripts "$SCRIPT_DIR" --path "$OBSERVATION_FILE" --scope "$SCOPE_SLUGS_JSON" --budget "$RECONCILE_BUDGET" --peek-timeout "$PEEK_TIMEOUT")" || CURRENT_OBSERVATIONS='{"current":[],"delta":[],"unavailable":[{"error":"reconciliation-failed"}],"complete":false}'
  CURRENT_DELTA="$(printf '%s' "$CURRENT_OBSERVATIONS" | jq -c '.delta')"
  LAST_RECONCILE=$(date +%s)
}

emit_current_delta() {
  if [[ "$(printf '%s' "$CURRENT_DELTA" | jq '[.[] | select(.observation.activity == "idle" or .observation.activity == "blocked" or .observation.activity == "unknown")] | length')" -gt 0 ]]; then
    WAKE_OUTCOME="current_delta"
    WAKE_TIER="advisory"
    if [[ "$(printf '%s' "$CURRENT_DELTA" | jq '[.[] | select(.observation.fresh == true and (.observation.activity == "idle" or .observation.activity == "blocked"))] | length')" -gt 0 ]]; then WAKE_TIER="confirmed"; fi
    WAKE_AUTHORITY="observation"
    WAKE_STATE="current_observation"
    WAKE_LABEL="current-session-delta"
    emit_wake "$CURSOR" 0 "[coordinate] current session activity changed in scope"
  fi
}

emit_compact() {
  local payload="$1" code="$2"
  payload="$(printf '%s' "$payload" | python3 "$WATCH_HELPER" compact)" || fail "could not render compact wake; full evidence remains retained"
  if [[ $WAKE_SHAPED -eq 1 ]]; then
    printf '%s\n' "$payload" >&2
    case "$code" in 0|2) code=2 ;; esac
  else
    printf '%s\n' "$payload"
  fi
  exit "$code"
}

replay_pending() {
  [[ $DURABLE -eq 1 ]] || return 0
  local payload outcome code=0
  payload="$(printf '%s' "$CURRENT_OBSERVATIONS" | python3 "$WATCH_HELPER" pending --path "$DELIVERY_FILE")" || fail "could not read durable wake"
  [[ "$payload" != "null" ]] || return 0
  outcome="$(printf '%s' "$payload" | jq -r '.outcome')"
  [[ "$outcome" == "timeout" ]] && code=2
  if [[ $COMPACT -eq 1 ]]; then emit_compact "$payload" "$code"; fi
  if [[ $JSON_MODE -eq 1 ]]; then printf '%s\n' "$payload"; else jq -cn --argjson wake "$payload" '{wake:$wake}'; fi
  echo "[coordinate] pending receipt: $(printf '%s' "$payload" | jq -r '.wake_id'); acknowledge with coordinate status --wake-id after reading" >&2
  if [[ $WAKE_SHAPED -eq 1 ]]; then printf '%s\n' "$payload" >&2; code=2; fi
  exit "$code"
}

CLOCK_WALL0=""
CLOCK_MONO0=""
IFS=$'\t' read -r CLOCK_WALL0 CLOCK_MONO0 <<< "$(clock_pair)"

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  RESULT="$(session_events_read "$EVENTS_SH" "$KNOWLEDGE_DIR" "$CURSOR")" || emit_internal_error "$CURSOR"
  RECORD="$(first_match_record "$RESULT")"
  NEXT="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
  if [[ -n "$RECORD" && "$RECORD" != "null" ]]; then
    emit_matched_from_record "$RECORD"
  fi
  # No match: nothing was withheld from the caller, so the batch cursor is the
  # row after the last row this read consumed, and advancing to it is correct.
  CURSOR="$NEXT"
  reconcile_current
  emit_current_delta
  replay_pending

  # A journal row always wins: it is the real event, and the pending check is
  # only there for the case where no row will ever come.
  if [[ "$PENDING_STALE" -gt 0 ]]; then
    PENDING="$(stale_pending)"
    if [[ "$(printf '%s' "$PENDING" | jq -r 'length')" -gt 0 ]]; then
      WAKE_OUTCOME="pending_stale"
      WAKE_PENDING="$PENDING"
      WAKE_AUTHORITY="none"
      WAKE_STATE="pending_stale"
      WAKE_LABEL="unclaimed-spawn-request-never-reaches-the-journal"
      WAKE_TIER="advisory"
      emit_wake "$CURSOR" 0 \
        "[coordinate] $(printf '%s' "$PENDING" | jq -r 'length') pending spawn request(s) unclaimed past ${PENDING_STALE}s; an unclaimed request never reaches the journal, so nothing else will report it (tier=$WAKE_TIER)"
    fi
  fi

  if [[ $OWNER_CHECK_ENABLED -eq 1 ]] \
    && ! session_owner_alive "$OWNER_PID" "$OWNER_TMUX" "$TMUX_SERVER"; then
    # Liveness is a hint, not a verdict: the owner's registry row and process go
    # away before the last journal append lands. Wait out a short grace and read
    # exactly once more, so the row this watcher exists to deliver is not the one
    # it drops on the way out.
    sleep "$OWNER_GONE_GRACE_SECONDS"
    RESULT="$(session_events_read "$EVENTS_SH" "$KNOWLEDGE_DIR" "$CURSOR")" || emit_internal_error "$CURSOR"
    RECORD="$(first_match_record "$RESULT")"
    if [[ -n "$RECORD" && "$RECORD" != "null" ]]; then
      emit_matched_from_record "$RECORD"
    fi
    CURSOR="$(printf '%s' "$RESULT" | jq -r '.next_cursor')"
    WAKE_OUTCOME="owner_gone"
    WAKE_TIER="confirmed"
    WAKE_AUTHORITY="owner-handle"
    WAKE_STATE="owner_gone"
    WAKE_LABEL="no-handle-proves-the-owner-is-alive"
    emit_wake "$CURSOR" 3 \
      "[coordinate] the watched owner is gone (pid='${OWNER_PID:-none}' tmux='${OWNER_TMUX:-none}') and a final read found nothing; stopping without re-arming"
  fi

  [[ $(date +%s) -ge $DEADLINE ]] && break
  sleep 1
done

reconcile_current force
emit_current_delta
WAKE_PENDING='[]'
WAKE_OUTCOME="timeout"
WAKE_TIER="quiet"
WAKE_AUTHORITY="none"
WAKE_STATE="quiet"
WAKE_LABEL="nothing-actionable-in-scope"

# What the two clocks say this window actually spanned. A machine that slept with
# the window open froze the monotonic clock and not the wall clock, so a wide
# difference here says every age this window computed was measured against a
# stopped clock — worth re-joining the board before believing the quiet.
SKEW_LINE="$(clock_elapsed "$CLOCK_WALL0" "$CLOCK_MONO0")" || SKEW_LINE=""
if [[ -n "$SKEW_LINE" ]]; then
  IFS=$'\t' read -r WALL_ELAPSED MONO_ELAPSED SKEW <<< "$SKEW_LINE"
  WAKE_CLOCK_SKEW="$(jq -cn --argjson wall "$WALL_ELAPSED" --argjson mono "$MONO_ELAPSED" \
    --argjson skew "$SKEW" \
    '{wall_elapsed_seconds: $wall, monotonic_elapsed_seconds: $mono,
      skew_seconds: $skew}')"
fi

emit_wake "$CURSOR" 2 \
  "[coordinate] nothing actionable in scope after ${TIMEOUT}s (cursor $CURSOR persisted; re-arm with the same call)"
