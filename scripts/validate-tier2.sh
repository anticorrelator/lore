#!/usr/bin/env bash
# validate-tier2.sh — Validate a single Tier 2 evidence row against the schema.
#
# Usage:
#   echo '<json>' | validate-tier2.sh
#   validate-tier2.sh --file row.json
#
# Reads a single JSON object from stdin or --file, validates it against the
# Tier 2 evidence schema (architecture/artifacts/tier2-evidence-schema.md),
# and exits 0 on valid or non-zero with per-field diagnostics to stderr.
#
# This script is read-only: it does NOT write anywhere.
#
# Required fields:
#   claim_id, tier, claim, producer_role, protocol_slot, task_id, phase_id,
#   scale, file, line_range, falsifier, why_this_work_needs_it, captured_at_sha
#
# tier must equal the literal string "task-evidence".
# producer_role must be one of: researcher, worker, advisor, spec-lead, implement-lead
# claim, falsifier, why_this_work_needs_it must be non-empty strings.
# line_range must match N-M with N <= M.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FILE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      FILE_PATH="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: validate-tier2.sh [--file <path>]" >&2
      exit 1
      ;;
  esac
done

# --- Read row ---
if [[ -n "$FILE_PATH" ]]; then
  if [[ ! -f "$FILE_PATH" ]]; then
    die "file not found: $FILE_PATH"
  fi
  ROW=$(cat "$FILE_PATH")
else
  if [[ -t 0 ]]; then
    die "no input: pass --file <path> or pipe JSON on stdin"
  fi
  ROW=$(cat)
fi

if [[ -z "${ROW// }" ]]; then
  die "row is empty"
fi

# --- Require jq ---
if ! command -v jq &>/dev/null; then
  die "jq is required but not found on PATH"
fi

# --- Validate JSON object ---
if ! printf '%s' "$ROW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  die "row must be a JSON object"
fi

ERRORS=0

fail_field() {
  echo "validation error: $1" >&2
  ERRORS=$(( ERRORS + 1 ))
}

# --- Required string fields (non-null, present) ---
REQUIRED_FIELDS=(
  claim_id
  tier
  claim
  producer_role
  protocol_slot
  task_id
  phase_id
  scale
  file
  line_range
  falsifier
  why_this_work_needs_it
  captured_at_sha
)

for FIELD in "${REQUIRED_FIELDS[@]}"; do
  if ! printf '%s' "$ROW" | jq -e --arg f "$FIELD" 'has($f) and (.[$f] != null)' >/dev/null 2>&1; then
    fail_field "missing required field: $FIELD"
  fi
done

# --- Only proceed with value checks if all required fields present ---
if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS validation error(s) — row rejected" >&2
  exit 1
fi

# --- tier must be literal "task-evidence" ---
# Mirrors grounded-or-nothing pattern from scorecard-append.sh:140-157
TIER=$(printf '%s' "$ROW" | jq -r '.tier // ""')
if [[ "$TIER" != "task-evidence" ]]; then
  fail_field "tier must be \"task-evidence\", got: \"$TIER\""
fi

# --- producer_role allowed values ---
PRODUCER_ROLE=$(printf '%s' "$ROW" | jq -r '.producer_role // ""')
case "$PRODUCER_ROLE" in
  researcher|worker|advisor|spec-lead|implement-lead) ;;
  "")
    fail_field "producer_role is empty (must be one of: researcher, worker, advisor, spec-lead, implement-lead)"
    ;;
  *)
    fail_field "invalid producer_role: \"$PRODUCER_ROLE\" (must be one of: researcher, worker, advisor, spec-lead, implement-lead)"
    ;;
esac

# --- Non-empty string checks ---
for FIELD in claim falsifier why_this_work_needs_it; do
  VAL=$(printf '%s' "$ROW" | jq -r --arg f "$FIELD" '.[$f] // ""')
  if [[ -z "${VAL// }" ]]; then
    fail_field "$FIELD must not be empty"
  fi
done

# --- line_range must match N-M with N <= M ---
LINE_RANGE=$(printf '%s' "$ROW" | jq -r '.line_range // ""')
if ! printf '%s' "$LINE_RANGE" | grep -qE '^[0-9]+-[0-9]+$'; then
  fail_field "line_range must match N-M format (e.g. \"42-57\"), got: \"$LINE_RANGE\""
else
  LR_N=$(printf '%s' "$LINE_RANGE" | cut -d'-' -f1)
  LR_M=$(printf '%s' "$LINE_RANGE" | cut -d'-' -f2)
  if [[ "$LR_N" -gt "$LR_M" ]]; then
    fail_field "line_range start ($LR_N) must be <= end ($LR_M)"
  fi
fi

# --- file must be non-empty ---
FILE_VAL=$(printf '%s' "$ROW" | jq -r '.file // ""')
if [[ -z "${FILE_VAL// }" ]]; then
  fail_field "file must not be empty"
fi

# --- Final result ---
if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS validation error(s) — row rejected" >&2
  exit 1
fi

echo "ok" >&2
exit 0
