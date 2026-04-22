#!/usr/bin/env bash
# scorecard-append.sh — Append a validated scorecard row to rows.jsonl
#
# Usage:
#   lore scorecard append --row '<json>'
#   echo '<json>' | lore scorecard append
#   lore scorecard append --row '<json>' [--kdir <path>] [--json]
#
# Reads a single JSON object (via --row or stdin), validates it against the
# canonical scorecard row schema, and appends one JSON line to
# $KDIR/_scorecards/rows.jsonl. Creates the _scorecards/ directory and file
# on first use.
#
# SOLE-WRITER INVARIANT: `scorecard-append.sh` / `lore scorecard append` is
# the only sanctioned writer of `$KDIR/_scorecards/rows.jsonl`. No other
# script, skill, agent prompt, or human process may append, edit, or truncate
# that file directly. Rows that bypass this validator are treated as corrupt
# by every reader — `/retro`, `/evolve`, scorecard-rollup.sh — which emit a
# `[scorecard] warning: rows.jsonl:<N> corrupt — <reason>` line to stderr
# and EXCLUDE the row from aggregation rather than silently counting it.
# See `_scorecards/README.md` for the invariant + reader contract.
#
# Required fields (row-level):
#   kind               enum: scored | telemetry
#   calibration_state  enum: calibrated | pre-calibration | unknown
#   schema_version     any non-null scalar (readers enforce upgrade policy)
#
# The row schema (see architecture/scorecards/row-schema.md) also defines:
#   template_id, template_version, metric, value, sample_size,
#   window_start, window_end, source_artifact_ids, granularity
# These are not hard-validated at append time (Phase 2 is substrate-only;
# downstream consumers encode stricter checks).
#
# Grounded-or-nothing enforcement (task-21, Phase 4):
#   When verdict_source == "reverse-auditor" AND kind == "scored", the row
#   must carry a non-empty claim_anchor object with file, line_range, and
#   exact_snippet fields all present and non-empty. Scored reverse-auditor
#   rows without grounded anchors are rejected. Telemetry-kind rows
#   (e.g., grounding_failure_rate) do not require the anchor — ungrounded
#   diagnostic telemetry is explicit and permitted.
#   Rationale: the reverse-auditor's scorecard weight is "grounded-or-
#   nothing" per the settlement plan — ungrounded concerns may surface in
#   /retro narrative but cannot drive producer-evaluation scoring. This is
#   enforced at the writer (not the agent prompt) because the writer is
#   the last line of defense: any path that reaches rows.jsonl without
#   this check corrupts the signal irreversibly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ROW=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --row)
      ROW="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: scorecard-append.sh [--row '<json>'] [--kdir <path>] [--json]" >&2
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

# --- Read row from stdin if not provided via flag ---
if [[ -z "$ROW" ]]; then
  if [[ -t 0 ]]; then
    fail "no row provided: pass --row '<json>' or pipe JSON on stdin"
  fi
  ROW=$(cat)
fi

if [[ -z "${ROW// }" ]]; then
  fail "row is empty"
fi

# --- Validate JSON structure ---
if ! command -v jq &>/dev/null; then
  fail "jq is required but not found on PATH"
fi

if ! printf '%s' "$ROW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  fail "row must be a JSON object"
fi

# --- Validate required fields ---
# schema_version present (any non-null scalar)
if ! printf '%s' "$ROW" | jq -e 'has("schema_version") and (.schema_version != null)' >/dev/null 2>&1; then
  fail "missing required field: schema_version"
fi

KIND=$(printf '%s' "$ROW" | jq -r '.kind // ""')
case "$KIND" in
  scored|telemetry) ;;
  "")
    fail "missing required field: kind (must be 'scored' or 'telemetry')"
    ;;
  *)
    fail "invalid kind: '$KIND' (must be 'scored' or 'telemetry')"
    ;;
esac

CAL_STATE=$(printf '%s' "$ROW" | jq -r '.calibration_state // ""')
case "$CAL_STATE" in
  calibrated|pre-calibration|unknown) ;;
  "")
    fail "missing required field: calibration_state (must be 'calibrated', 'pre-calibration', or 'unknown')"
    ;;
  *)
    fail "invalid calibration_state: '$CAL_STATE' (must be 'calibrated', 'pre-calibration', or 'unknown')"
    ;;
esac

# --- Grounded-or-nothing enforcement for reverse-auditor scored rows (task-21) ---
# If the row declares verdict_source == "reverse-auditor" AND kind == "scored",
# require claim_anchor.{file, line_range, exact_snippet} all non-empty.
# Telemetry rows (e.g., grounding_failure_rate) are exempt — ungrounded
# diagnostic signal is explicit and permitted under the kind discriminator.
VERDICT_SOURCE=$(printf '%s' "$ROW" | jq -r '.verdict_source // ""')
if [[ "$VERDICT_SOURCE" == "reverse-auditor" && "$KIND" == "scored" ]]; then
  ANCHOR_OK=$(printf '%s' "$ROW" | jq -e '
    (.claim_anchor // null) as $a
    | ($a != null)
      and (($a.file // "") != "")
      and (($a.line_range // "") != "")
      and (($a.exact_snippet // "") != "")
  ' >/dev/null 2>&1 && echo "true" || echo "false")
  if [[ "$ANCHOR_OK" != "true" ]]; then
    fail "reverse-auditor scored row rejected: grounded-or-nothing enforced — claim_anchor.{file, line_range, exact_snippet} all required and non-empty (kind=scored, verdict_source=reverse-auditor). Telemetry-kind rows are exempt; surface ungrounded concerns in /retro narrative instead."
  fi
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

SCORECARDS_DIR="$KNOWLEDGE_DIR/_scorecards"
ROWS_FILE="$SCORECARDS_DIR/rows.jsonl"
mkdir -p "$SCORECARDS_DIR"

# Seed _scorecards/README.md on first use so the invariant travels with the store.
if [[ ! -f "$SCORECARDS_DIR/README.md" ]]; then
  "$SCRIPT_DIR/seed-scorecards-readme.sh" "$SCORECARDS_DIR" 2>/dev/null || true
fi

# --- Compact to one line and append ---
COMPACT=$(printf '%s' "$ROW" | jq -c '.')
printf '%s\n' "$COMPACT" >> "$ROWS_FILE"

RELPATH="${ROWS_FILE#$KNOWLEDGE_DIR/}"

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(jq -n \
    --arg path "$RELPATH" \
    --arg kind "$KIND" \
    --arg calibration_state "$CAL_STATE" \
    '{path: $path, kind: $kind, calibration_state: $calibration_state, appended: true}')
  json_output "$RESULT"
fi

echo "[scorecard] Appended row to $RELPATH (kind=$KIND, calibration_state=$CAL_STATE)"
