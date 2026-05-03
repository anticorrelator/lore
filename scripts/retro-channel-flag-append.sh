#!/usr/bin/env bash
# retro-channel-flag-append.sh — Append a channel-contract review flag to the retro sidecar
#
# Canonical writer for `$KDIR/_scorecards/retro-channel-flags.jsonl`.
# Fires when sustained under-routing, over-capture, or evidence-only
# durable-claim drift is detected for a role × slot combination.
#
# These flags are qualitative cycle-level observations — NOT producer
# scoring rows. They live in a separate sidecar so /evolve cannot
# consume them as scored settlement signal.
#
# Usage:
#   retro-channel-flag-append.sh \
#     --cycle-id <slug> \
#     --role <role> \
#     --slot <slot> \
#     --signal-type <under_routing|over_capture|evidence_only_durable> \
#     --rate <fraction 0.0-1.0> \
#     --window-cycles <N> \
#     [--remedy-hint "<text>"] \
#     [--kdir <path>]
#
# Schema (one JSON line per row):
#   {
#     "schema_version": "1",
#     "kind": "retro_flag",
#     "reason": "channel-contract review",
#     "cycle_id": "<slug>",
#     "role": "<role>",
#     "slot": "<slot>",
#     "signal_type": "under_routing|over_capture|evidence_only_durable",
#     "rate": <float>,
#     "window_cycles": <int>,
#     "remedy_hint": "<text or null>",
#     "ts": "<ISO-8601>"
#   }
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `$KDIR/_scorecards/retro-channel-flags.jsonl`. Direct appends bypass
# validation and corrupt longitudinal trend reads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CYCLE_ID=""
ROLE=""
SLOT=""
SIGNAL_TYPE=""
RATE=""
WINDOW_CYCLES=""
REMEDY_HINT=""
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycle-id)       CYCLE_ID="$2";       shift 2 ;;
    --role)           ROLE="$2";           shift 2 ;;
    --slot)           SLOT="$2";           shift 2 ;;
    --signal-type)    SIGNAL_TYPE="$2";    shift 2 ;;
    --rate)           RATE="$2";           shift 2 ;;
    --window-cycles)  WINDOW_CYCLES="$2";  shift 2 ;;
    --remedy-hint)    REMEDY_HINT="$2";    shift 2 ;;
    --kdir)           KDIR_OVERRIDE="$2";  shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      echo "Usage: retro-channel-flag-append.sh --cycle-id <id> --role <role> --slot <slot> --signal-type <type> --rate <float> --window-cycles <N> [--remedy-hint <text>] [--kdir <path>]" >&2
      exit 1
      ;;
  esac
done

# --- Required field validation ---
for _pair in \
  "cycle-id:$CYCLE_ID" \
  "role:$ROLE" \
  "slot:$SLOT" \
  "signal-type:$SIGNAL_TYPE" \
  "rate:$RATE" \
  "window-cycles:$WINDOW_CYCLES"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    echo "Error: --$_flag is required" >&2
    exit 1
  fi
done

case "$SIGNAL_TYPE" in
  under_routing|over_capture|evidence_only_durable) ;;
  *)
    echo "Error: --signal-type must be 'under_routing', 'over_capture', or 'evidence_only_durable' (got '$SIGNAL_TYPE')" >&2
    exit 1
    ;;
esac

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

# Validate window-cycles is a positive integer.
if ! [[ "$WINDOW_CYCLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --window-cycles must be a positive integer (got '$WINDOW_CYCLES')" >&2
  exit 1
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
SIDECAR="$SCORECARDS_DIR/retro-channel-flags.jsonl"
mkdir -p "$SCORECARDS_DIR"

TS=$(timestamp_iso)

# --- Build and append the row ---
ROW=$(python3 -c '
import json, sys
(cycle_id, role, slot, signal_type, rate_str,
 window_cycles_str, remedy_hint, ts) = sys.argv[1:9]
row = {
    "schema_version": "1",
    "kind": "retro_flag",
    "reason": "channel-contract review",
    "cycle_id": cycle_id,
    "role": role,
    "slot": slot,
    "signal_type": signal_type,
    "rate": float(rate_str),
    "window_cycles": int(window_cycles_str),
    "remedy_hint": remedy_hint if remedy_hint else None,
    "ts": ts,
}
print(json.dumps(row, ensure_ascii=False))
' "$CYCLE_ID" "$ROLE" "$SLOT" "$SIGNAL_TYPE" "$RATE" \
  "$WINDOW_CYCLES" "$REMEDY_HINT" "$TS")

printf '%s\n' "$ROW" >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"
echo "[retro-channel-flag] Appended row to $RELPATH (cycle=$CYCLE_ID role=$ROLE slot=$SLOT signal=$SIGNAL_TYPE rate=$RATE)"
