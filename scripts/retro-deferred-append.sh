#!/usr/bin/env bash
# retro-deferred-append.sh — Append one row to the retro deferred-batch queue.
#
# Canonical writer for `$KDIR/_scorecards/retro-deferred-queue.jsonl`.
# One row per retro cycle that the retro-sampling gate (retro-sampling-gate.sh)
# routed to deferral at a protocol terminus (spec-finalize / impl-close). The
# queue is the debt ledger: a sampled-out cycle is a RECORDED outcome, never
# silence — retro is artifact-fed and time-independent, so a deferred cycle can
# be retro'd later from a batch without loss.
#
# Usage:
#   retro-deferred-append.sh \
#     --cycle-id <slug> \
#     --event-type <spec-finalize|impl-close> \
#     [--outcome <done|deferred|skipped>]   (default: deferred) \
#     --rate <float 0.0-1.0> \
#     --stratum <routine|new_template_version|first_k_routing_pair|degraded_closure> \
#     [--template-version <hash>] \
#     [--verdict <full|partial|none>] \
#     [--coin <float 0.0-1.0>] \
#     [--kdir <path>] [--json]
#
# The `outcome` vocabulary is the coordinate ledger's retro-outcome grammar
# (done | deferred | skipped) — the SAME tokens, deliberately not reinvented, so
# a queue row and a `coordination.md` ledger row read as one language. The gate
# only ever writes `deferred`; `done` / `skipped` are the tokens a later batch
# pass (out of scope here) appends when it processes or the user drops a queued
# cycle.
#
# Schema (one JSON line per row):
#   {
#     "schema_version": "1",
#     "kind": "retro_deferred",
#     "cycle_id": "<slug>",
#     "event_type": "spec-finalize|impl-close",
#     "outcome": "done|deferred|skipped",
#     "rate": <float>,
#     "stratum": "routine|new_template_version|first_k_routing_pair|degraded_closure",
#     "template_version": "<hash or null>",
#     "verdict": "<full|partial|none or null>",
#     "coin": <float or null>,
#     "ts": "<ISO-8601>"
#   }
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `$KDIR/_scorecards/retro-deferred-queue.jsonl`. Direct appends bypass
# validation and corrupt the debt read that surfaces deferred-cycle depth.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CYCLE_ID=""
EVENT_TYPE=""
OUTCOME="deferred"
RATE=""
STRATUM=""
TEMPLATE_VERSION=""
VERDICT=""
COIN=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycle-id)          CYCLE_ID="$2";          shift 2 ;;
    --event-type)        EVENT_TYPE="$2";        shift 2 ;;
    --outcome)           OUTCOME="$2";           shift 2 ;;
    --rate)              RATE="$2";              shift 2 ;;
    --stratum)           STRATUM="$2";           shift 2 ;;
    --template-version)  TEMPLATE_VERSION="$2";  shift 2 ;;
    --verdict)           VERDICT="$2";           shift 2 ;;
    --coin)              COIN="$2";              shift 2 ;;
    --kdir)              KDIR_OVERRIDE="$2";     shift 2 ;;
    --json)              JSON_MODE=1;            shift ;;
    -h|--help)
      sed -n '2,45p' "$0"
      exit 0
      ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      echo "Usage: retro-deferred-append.sh --cycle-id <slug> --event-type <type> --rate <float> --stratum <stratum> [--outcome <done|deferred|skipped>] [--template-version <hash>] [--verdict <v>] [--coin <float>] [--kdir <path>] [--json]" >&2
      exit 1
      ;;
  esac
done

# --- Required field validation ---
for _pair in "cycle-id:$CYCLE_ID" "event-type:$EVENT_TYPE" "rate:$RATE" "stratum:$STRATUM"; do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    echo "Error: --$_flag is required" >&2
    exit 1
  fi
done

case "$EVENT_TYPE" in
  spec-finalize|impl-close) ;;
  *)
    echo "Error: --event-type must be 'spec-finalize' or 'impl-close' (got '$EVENT_TYPE')" >&2
    exit 1
    ;;
esac

# Closed outcome vocabulary — the coordinate ledger's retro-outcome tokens.
case "$OUTCOME" in
  done|deferred|skipped) ;;
  *)
    echo "Error: --outcome must be 'done', 'deferred', or 'skipped' (got '$OUTCOME')" >&2
    exit 1
    ;;
esac

# Closed stratum vocabulary — kept in lockstep with retro-sampling-gate.sh.
case "$STRATUM" in
  routine|new_template_version|first_k_routing_pair|degraded_closure) ;;
  *)
    echo "Error: --stratum must be one of: routine, new_template_version, first_k_routing_pair, degraded_closure (got '$STRATUM')" >&2
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

# Validate rate is a float in [0, 1].
if ! python3 -c "
import sys
try:
    v = float(sys.argv[1])
    sys.exit(0 if 0.0 <= v <= 1.0 else 1)
except ValueError:
    sys.exit(1)
" "$RATE" 2>/dev/null; then
  echo "Error: --rate must be a float in [0.0, 1.0] (got '$RATE')" >&2
  exit 1
fi

# Validate coin (if provided) is a float in [0, 1).
if [[ -n "$COIN" ]]; then
  if ! python3 -c "
import sys
try:
    v = float(sys.argv[1])
    sys.exit(0 if 0.0 <= v < 1.0 else 1)
except ValueError:
    sys.exit(1)
" "$COIN" 2>/dev/null; then
    echo "Error: --coin must be a float in [0.0, 1.0) (got '$COIN')" >&2
    exit 1
  fi
fi

# --- Resolve knowledge directory ---
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

TS=$(timestamp_iso)

ROW=$(python3 -c '
import json, sys
(cycle_id, event_type, outcome, rate_str, stratum,
 template_version, verdict, coin_str, ts) = sys.argv[1:10]
row = {
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
}
print(json.dumps(row, ensure_ascii=False))
' "$CYCLE_ID" "$EVENT_TYPE" "$OUTCOME" "$RATE" "$STRATUM" \
  "$TEMPLATE_VERSION" "$VERDICT" "$COIN" "$TS")

printf '%s\n' "$ROW" >> "$QUEUE"

RELPATH="${QUEUE#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  jq -n --arg path "$RELPATH" --arg cycle "$CYCLE_ID" --arg outcome "$OUTCOME" \
        --arg stratum "$STRATUM" \
        '{path: $path, cycle_id: $cycle, outcome: $outcome, stratum: $stratum, appended: true}'
  exit 0
fi

echo "[retro-deferred] Appended row to $RELPATH (cycle=$CYCLE_ID outcome=$OUTCOME stratum=$STRATUM rate=$RATE)"
