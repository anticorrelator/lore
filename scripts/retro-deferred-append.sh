#!/usr/bin/env bash
# retro-deferred-append.sh — Sole physical appender for the retro outcome queue.
#
# Canonical writer for `$KDIR/_scorecards/retro-deferred-queue.jsonl`.
# Existing `done | deferred | skipped` rows retain their v1 shape. DUE decisions
# add a durable outcome identity and begin `disposition=unhandled`; later
# handling appends a correlated disposition row instead of rewriting history.
#
# Outcome usage:
#   retro-deferred-append.sh \
#     --cycle-id <slug> \
#     --event-type <spec-finalize|impl-close|session-orphaned> \
#     [--outcome <done|deferred|skipped|due>] \
#     --rate <float 0.0-1.0> \
#     --stratum <routine|new_template_version|first_k_routing_pair|degraded_closure|instance_death> \
#     [--reason <always-stratum|coin>] \
#     [--template-version <hash>] [--verdict <full|partial|none>] \
#     [--coin <float 0.0-1.0>] [--kdir <path>] [--json]
#
# Disposition usage (normally called through retro-queue.sh handle):
#   retro-deferred-append.sh --record-type disposition --outcome due \
#     (--outcome-id <id> | --cycle-id <slug>) \
#     --disposition handled --action <dispatched|deferred|skipped> \
#     --handled-by <actor> [--kdir <path>] [--json]
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned physical appender
# for `$KDIR/_scorecards/retro-deferred-queue.jsonl`. Operation-specific fronts
# may select an operation, but validation, idempotence, and append live here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CYCLE_ID=""
EVENT_TYPE=""
OUTCOME="deferred"
RECORD_TYPE="outcome"
OUTCOME_ID=""
DISPOSITION=""
ACTION=""
HANDLED_BY=""
REASON=""
RATE=""
STRATUM=""
TEMPLATE_VERSION=""
VERDICT=""
COIN=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  sed -n '2,33p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycle-id)          CYCLE_ID="$2";          shift 2 ;;
    --event-type)        EVENT_TYPE="$2";        shift 2 ;;
    --outcome)           OUTCOME="$2";           shift 2 ;;
    --record-type)       RECORD_TYPE="$2";       shift 2 ;;
    --outcome-id)        OUTCOME_ID="$2";        shift 2 ;;
    --disposition)       DISPOSITION="$2";       shift 2 ;;
    --action)            ACTION="$2";            shift 2 ;;
    --handled-by)        HANDLED_BY="$2";        shift 2 ;;
    --reason)            REASON="$2";            shift 2 ;;
    --rate)              RATE="$2";              shift 2 ;;
    --stratum)           STRATUM="$2";           shift 2 ;;
    --template-version)  TEMPLATE_VERSION="$2";  shift 2 ;;
    --verdict)           VERDICT="$2";           shift 2 ;;
    --coin)              COIN="$2";              shift 2 ;;
    --kdir)              KDIR_OVERRIDE="$2";     shift 2 ;;
    --json)              JSON_MODE=1;             shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

case "$RECORD_TYPE" in
  outcome|disposition) ;;
  *)
    echo "Error: --record-type must be 'outcome' or 'disposition' (got '$RECORD_TYPE')" >&2
    exit 1
    ;;
esac

case "$OUTCOME" in
  done|deferred|skipped|due) ;;
  *)
    echo "Error: --outcome must be 'done', 'deferred', 'skipped', or 'due' (got '$OUTCOME')" >&2
    exit 1
    ;;
esac

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "Error: knowledge store not found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

SCORECARDS_DIR="$KNOWLEDGE_DIR/_scorecards"
QUEUE="$SCORECARDS_DIR/retro-deferred-queue.jsonl"
mkdir -p "$SCORECARDS_DIR"
RELPATH="${QUEUE#"$KNOWLEDGE_DIR"/}"

if [[ "$RECORD_TYPE" == "disposition" ]]; then
  if [[ "$OUTCOME" != "due" ]]; then
    echo "Error: disposition rows require --outcome due" >&2
    exit 1
  fi
  if [[ -n "$OUTCOME_ID" && -n "$CYCLE_ID" ]]; then
    echo "Error: disposition rows accept exactly one of --outcome-id or --cycle-id" >&2
    exit 1
  fi
  if [[ -z "$OUTCOME_ID" && -z "$CYCLE_ID" ]]; then
    echo "Error: disposition rows require --outcome-id or --cycle-id" >&2
    exit 1
  fi
  if [[ "$DISPOSITION" != "handled" ]]; then
    echo "Error: disposition rows require --disposition handled" >&2
    exit 1
  fi
  case "$ACTION" in
    dispatched|deferred|skipped) ;;
    *)
      echo "Error: --action must be one of: dispatched, deferred, skipped" >&2
      exit 1
      ;;
  esac
  if [[ -z "$HANDLED_BY" ]]; then
    echo "Error: --handled-by is required for a handled disposition" >&2
    exit 1
  fi
  if [[ -n "$EVENT_TYPE$REASON$RATE$STRATUM$TEMPLATE_VERSION$VERDICT$COIN" ]]; then
    echo "Error: outcome-evidence flags are not valid on disposition rows" >&2
    exit 1
  fi

  HANDLED_AT=$(timestamp_iso)
  RESULT=$(python3 - "$QUEUE" "$OUTCOME_ID" "$CYCLE_ID" "$ACTION" "$HANDLED_BY" "$HANDLED_AT" <<'PYEOF'
import json, os, sys

queue, outcome_id, cycle_id, action, handled_by, handled_at = sys.argv[1:7]
outcomes = {}
handled = {}
if os.path.isfile(queue):
    with open(queue, encoding="utf-8") as f:
        for line in f:
            try:
                row = json.loads(line)
            except (ValueError, TypeError):
                continue
            oid = row.get("outcome_id")
            if row.get("outcome") != "due" or not oid:
                continue
            if row.get("record_type") == "disposition":
                handled.setdefault(oid, []).append(row)
            elif row.get("record_type") == "outcome":
                outcomes[oid] = row

if outcome_id:
    target_ids = [outcome_id] if outcome_id in outcomes else []
else:
    # Cycle-wide handling means "claim every still-unhandled DUE for this
    # cycle." Previously handled identities are outside this operation: an
    # earlier coordinator disposition must be a no-op when direct /retro starts.
    target_ids = [oid for oid, row in outcomes.items()
                  if row.get("cycle_id") == cycle_id and not handled.get(oid)]

if not target_ids:
    if outcome_id:
        print(json.dumps({"error": f"no DUE outcome found for outcome_id '{outcome_id}'"}))
        sys.exit(4)
    print(json.dumps({"matched": 0, "appended": 0, "idempotent": 0, "rows": []}))
    sys.exit(0)

conflicts = []
idempotent = 0
rows = []
for oid in target_ids:
    existing = handled.get(oid, [])
    if existing:
        if all(r.get("action") == action and r.get("handled_by") == handled_by for r in existing):
            idempotent += 1
            continue
        conflicts.append({
            "outcome_id": oid,
            "existing": [{"action": r.get("action"), "handled_by": r.get("handled_by")} for r in existing],
            "requested": {"action": action, "handled_by": handled_by},
        })
        continue
    source = outcomes[oid]
    rows.append({
        "schema_version": "2",
        "kind": "retro_deferred",
        "record_type": "disposition",
        "outcome_id": oid,
        "cycle_id": source.get("cycle_id"),
        "event_type": source.get("event_type"),
        "outcome": "due",
        "disposition": "handled",
        "action": action,
        "handled_by": handled_by,
        "handled_at": handled_at,
        "ts": handled_at,
    })

if conflicts:
    print(json.dumps({"error": "conflicting handled transition", "conflicts": conflicts}))
    sys.exit(5)
print(json.dumps({
    "matched": len(target_ids),
    "appended": len(rows),
    "idempotent": idempotent,
    "rows": rows,
}))
PYEOF
  ) || {
    rc=$?
    error=$(printf '%s' "$RESULT" | jq -r '.error // "disposition validation failed"' 2>/dev/null || true)
    echo "Error: $error" >&2
    if [[ -n "$RESULT" ]]; then
      printf '%s\n' "$RESULT" >&2
    fi
    exit "$rc"
  }

  while IFS= read -r row; do
    [[ -n "$row" ]] && printf '%s\n' "$row" >> "$QUEUE"
  done < <(printf '%s' "$RESULT" | jq -c '.rows[]')

  MATCHED=$(printf '%s' "$RESULT" | jq -r '.matched')
  APPENDED=$(printf '%s' "$RESULT" | jq -r '.appended')
  IDEMPOTENT=$(printf '%s' "$RESULT" | jq -r '.idempotent')
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s' "$RESULT" | jq --arg path "$RELPATH" \
      '{path: $path, matched, appended, idempotent, outcome_ids: [.rows[].outcome_id]}'
  elif [[ "$APPENDED" -eq 0 ]]; then
    echo "[retro-deferred] No disposition row appended (matched=$MATCHED idempotent=$IDEMPOTENT)"
  else
    echo "[retro-deferred] Appended $APPENDED handled disposition row(s) to $RELPATH (action=$ACTION handled_by=$HANDLED_BY)"
  fi
  exit 0
fi

# Outcome-row validation. Existing done/deferred/skipped calls remain valid.
for _pair in "cycle-id:$CYCLE_ID" "event-type:$EVENT_TYPE" "rate:$RATE" "stratum:$STRATUM"; do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    echo "Error: --$_flag is required" >&2
    exit 1
  fi
done

case "$EVENT_TYPE" in
  spec-finalize|impl-close|session-orphaned) ;;
  *)
    echo "Error: --event-type must be 'spec-finalize', 'impl-close', or 'session-orphaned' (got '$EVENT_TYPE')" >&2
    exit 1
    ;;
esac

case "$STRATUM" in
  routine|new_template_version|first_k_routing_pair|degraded_closure|instance_death) ;;
  *)
    echo "Error: --stratum must be one of: routine, new_template_version, first_k_routing_pair, degraded_closure, instance_death (got '$STRATUM')" >&2
    exit 1
    ;;
esac

if [[ -n "$VERDICT" ]]; then
  case "$VERDICT" in
    full|partial|none) ;;
    *)
      echo "Error: --verdict must be 'full', 'partial', or 'none' (got '$VERDICT')" >&2
      exit 1
      ;;
  esac
fi

if ! python3 -c '
import sys
try:
    v = float(sys.argv[1])
    sys.exit(0 if 0.0 <= v <= 1.0 else 1)
except ValueError:
    sys.exit(1)
' "$RATE" 2>/dev/null; then
  echo "Error: --rate must be a float in [0.0, 1.0] (got '$RATE')" >&2
  exit 1
fi

if [[ -n "$COIN" ]] && ! python3 -c '
import sys
try:
    v = float(sys.argv[1])
    sys.exit(0 if 0.0 <= v < 1.0 else 1)
except ValueError:
    sys.exit(1)
' "$COIN" 2>/dev/null; then
  echo "Error: --coin must be a float in [0.0, 1.0) (got '$COIN')" >&2
  exit 1
fi

if [[ "$OUTCOME" == "due" ]]; then
  if [[ "$DISPOSITION" != "" && "$DISPOSITION" != "unhandled" ]]; then
    echo "Error: DUE outcome rows require --disposition unhandled" >&2
    exit 1
  fi
  case "$REASON" in
    always-stratum|coin) ;;
    *)
      echo "Error: DUE outcome rows require --reason always-stratum or --reason coin" >&2
      exit 1
      ;;
  esac
  if [[ -n "$ACTION$HANDLED_BY" ]]; then
    echo "Error: handled action fields are not valid on a DUE outcome row" >&2
    exit 1
  fi
  [[ -z "$OUTCOME_ID" ]] && OUTCOME_ID=$(python3 -c 'import uuid; print("retro-due-" + uuid.uuid4().hex)')

  if [[ -f "$QUEUE" ]]; then
    EXISTING=$(jq -c --arg id "$OUTCOME_ID" 'select(.record_type == "outcome" and .outcome_id == $id)' "$QUEUE" | tail -n 1)
    if [[ -n "$EXISTING" ]]; then
      if ! jq -e -n --argjson existing "$EXISTING" --arg cycle "$CYCLE_ID" --arg event "$EVENT_TYPE" --arg stratum "$STRATUM" \
        '$existing.cycle_id == $cycle and $existing.event_type == $event and $existing.stratum == $stratum and $existing.outcome == "due" and $existing.disposition == "unhandled"' >/dev/null; then
        echo "Error: --outcome-id '$OUTCOME_ID' already names a different outcome" >&2
        exit 1
      fi
      if [[ $JSON_MODE -eq 1 ]]; then
        jq -n --arg path "$RELPATH" --arg cycle "$CYCLE_ID" --arg outcome_id "$OUTCOME_ID" \
          '{path:$path,cycle_id:$cycle,outcome:"due",outcome_id:$outcome_id,appended:false,idempotent:true}'
      else
        echo "[retro-deferred] Outcome already present in $RELPATH (outcome_id=$OUTCOME_ID)"
      fi
      exit 0
    fi
  fi
else
  if [[ -n "$OUTCOME_ID$DISPOSITION$ACTION$HANDLED_BY$REASON" ]]; then
    echo "Error: lifecycle fields are valid only for outcome=due" >&2
    exit 1
  fi
fi

TS=$(timestamp_iso)
if [[ "$OUTCOME" == "due" ]]; then
  ROW=$(python3 -c '
import json, sys
(cycle_id, event_type, outcome_id, reason, rate_str, stratum,
 template_version, verdict, coin_str, ts) = sys.argv[1:11]
print(json.dumps({
    "schema_version": "2",
    "kind": "retro_deferred",
    "record_type": "outcome",
    "outcome_id": outcome_id,
    "cycle_id": cycle_id,
    "event_type": event_type,
    "outcome": "due",
    "disposition": "unhandled",
    "reason": reason,
    "rate": float(rate_str),
    "stratum": stratum,
    "template_version": template_version or None,
    "verdict": verdict or None,
    "coin": float(coin_str) if coin_str else None,
    "ts": ts,
}, ensure_ascii=False, separators=(",", ":")))
' "$CYCLE_ID" "$EVENT_TYPE" "$OUTCOME_ID" "$REASON" "$RATE" "$STRATUM" \
    "$TEMPLATE_VERSION" "$VERDICT" "$COIN" "$TS")
else
  ROW=$(python3 -c '
import json, sys
(cycle_id, event_type, outcome, rate_str, stratum,
 template_version, verdict, coin_str, ts) = sys.argv[1:10]
print(json.dumps({
    "schema_version": "1",
    "kind": "retro_deferred",
    "cycle_id": cycle_id,
    "event_type": event_type,
    "outcome": outcome,
    "rate": float(rate_str),
    "stratum": stratum,
    "template_version": template_version or None,
    "verdict": verdict or None,
    "coin": float(coin_str) if coin_str else None,
    "ts": ts,
}, ensure_ascii=False, separators=(",", ":")))
' "$CYCLE_ID" "$EVENT_TYPE" "$OUTCOME" "$RATE" "$STRATUM" \
    "$TEMPLATE_VERSION" "$VERDICT" "$COIN" "$TS")
fi

printf '%s\n' "$ROW" >> "$QUEUE"

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n --arg path "$RELPATH" --arg cycle "$CYCLE_ID" --arg outcome "$OUTCOME" \
        --arg stratum "$STRATUM" --arg outcome_id "$OUTCOME_ID" \
        '{path: $path, cycle_id: $cycle, outcome: $outcome, stratum: $stratum, outcome_id: (if ($outcome_id | length) > 0 then $outcome_id else null end), appended: true}'
  exit 0
fi

DETAIL="cycle=$CYCLE_ID outcome=$OUTCOME stratum=$STRATUM rate=$RATE"
[[ -n "$OUTCOME_ID" ]] && DETAIL="$DETAIL outcome_id=$OUTCOME_ID"
echo "[retro-deferred] Appended row to $RELPATH ($DETAIL)"
