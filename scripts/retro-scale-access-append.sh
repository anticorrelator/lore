#!/usr/bin/env bash
# retro-scale-access-append.sh — Append a scale_access_appropriateness row to the retro sidecar
#
# Canonical writer for `$KDIR/_scorecards/retro-scale-access.jsonl`.
# One row per retro cycle. Not a producer scoring metric — this is a
# qualitative cycle-level observation for the spec-lead's review.
#
# Usage:
#   retro-scale-access-append.sh \
#     --cycle-id <id> \
#     --abstraction-grade <right-sized|too-coarse|too-fine> \
#     --abstraction-rationale "<text>" \
#     --recall-grade <useful|neutral|not-useful> \
#     --recall-rationale "<text>" \
#     [--kdir <path>]
#
# Schema (one JSON line per row):
#   {
#     "schema_version": "1",
#     "kind": "retro_scale_access",
#     "cycle_id": "<work-item slug>",
#     "abstraction_grade": "right-sized|too-coarse|too-fine",
#     "abstraction_rationale": "<one-line, cites specific retrieval calls>",
#     "recall_grade": "useful|neutral|not-useful",
#     "recall_rationale": "<one-line>",
#     "ts": "<ISO-8601>"
#   }
#
# SOLE-WRITER INVARIANT: this script is the only sanctioned writer of
# `$KDIR/_scorecards/retro-scale-access.jsonl`. Direct appends bypass
# schema validation and corrupt longitudinal trend reads.
#
# Directionality:
#   abstraction_grade=too-coarse → missing/under-linked child entries
#   abstraction_grade=too-fine   → missing bridging parent entries

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CYCLE_ID=""
ABSTRACTION_GRADE=""
ABSTRACTION_RATIONALE=""
RECALL_GRADE=""
RECALL_RATIONALE=""
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycle-id)               CYCLE_ID="$2";               shift 2 ;;
    --abstraction-grade)      ABSTRACTION_GRADE="$2";      shift 2 ;;
    --abstraction-rationale)  ABSTRACTION_RATIONALE="$2";  shift 2 ;;
    --recall-grade)           RECALL_GRADE="$2";           shift 2 ;;
    --recall-rationale)       RECALL_RATIONALE="$2";       shift 2 ;;
    --kdir)                   KDIR_OVERRIDE="$2";          shift 2 ;;
    -h|--help)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    *)
      echo "Error: unknown flag '$1'" >&2
      echo "Usage: retro-scale-access-append.sh --cycle-id <id> --abstraction-grade <grade> --abstraction-rationale <text> --recall-grade <grade> --recall-rationale <text> [--kdir <path>]" >&2
      exit 1
      ;;
  esac
done

# --- Required field validation ---
for _pair in \
  "cycle-id:$CYCLE_ID" \
  "abstraction-grade:$ABSTRACTION_GRADE" \
  "abstraction-rationale:$ABSTRACTION_RATIONALE" \
  "recall-grade:$RECALL_GRADE" \
  "recall-rationale:$RECALL_RATIONALE"
do
  _flag="${_pair%%:*}"
  _val="${_pair#*:}"
  if [[ -z "$_val" ]]; then
    echo "Error: --$_flag is required" >&2
    exit 1
  fi
done

case "$ABSTRACTION_GRADE" in
  right-sized|too-coarse|too-fine) ;;
  *)
    echo "Error: --abstraction-grade must be 'right-sized', 'too-coarse', or 'too-fine' (got '$ABSTRACTION_GRADE')" >&2
    exit 1
    ;;
esac

case "$RECALL_GRADE" in
  useful|neutral|not-useful) ;;
  *)
    echo "Error: --recall-grade must be 'useful', 'neutral', or 'not-useful' (got '$RECALL_GRADE')" >&2
    exit 1
    ;;
esac

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
SIDECAR="$SCORECARDS_DIR/retro-scale-access.jsonl"
mkdir -p "$SCORECARDS_DIR"

TS=$(timestamp_iso)

# --- Build and append the row ---
ROW=$(python3 -c '
import json, sys
(cycle_id, abstraction_grade, abstraction_rationale,
 recall_grade, recall_rationale, ts) = sys.argv[1:7]
row = {
    "schema_version": "1",
    "kind": "retro_scale_access",
    "cycle_id": cycle_id,
    "abstraction_grade": abstraction_grade,
    "abstraction_rationale": abstraction_rationale,
    "recall_grade": recall_grade,
    "recall_rationale": recall_rationale,
    "ts": ts,
}
print(json.dumps(row, ensure_ascii=False))
' "$CYCLE_ID" "$ABSTRACTION_GRADE" "$ABSTRACTION_RATIONALE" \
  "$RECALL_GRADE" "$RECALL_RATIONALE" "$TS")

printf '%s\n' "$ROW" >> "$SIDECAR"

RELPATH="${SIDECAR#$KNOWLEDGE_DIR/}"
echo "[retro-scale-access] Appended row to $RELPATH (cycle=$CYCLE_ID abstraction=$ABSTRACTION_GRADE recall=$RECALL_GRADE)"
