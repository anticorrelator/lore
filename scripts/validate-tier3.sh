#!/usr/bin/env bash
# validate-tier3.sh — Validate a single Tier 3 observation row against the schema.
#
# Usage:
#   echo '<json>' | validate-tier3.sh
#   validate-tier3.sh --file row.json
#
# Reads a single JSON object from stdin or --file, validates it against the
# Tier 3 observations schema (architecture/artifacts/tier3-observations-schema.md),
# and exits 0 on valid or non-zero with per-field diagnostics to stderr.
#
# This script is read-only: it does NOT write anywhere.
#
# Required fields:
#   claim_id, tier, claim, producer_role, protocol_slot, scale,
#   why_future_agent_cares, falsifier, related_files, source_artifact_ids,
#   work_item, confidence, captured_at_sha
#
# tier must equal the literal string "reusable".
# confidence must equal the literal string "unaudited" on new entries.
# producer_role must be one of: researcher, worker, advisor, spec-lead, implement-lead
# claim, why_future_agent_cares, falsifier must be non-empty strings.
# source_artifact_ids must be a non-empty array.
# related_files must be an array (may be empty).

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
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: validate-tier3.sh [--file <path>]" >&2
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

# --- Required fields (non-null, present) ---
REQUIRED_FIELDS=(
  claim_id
  tier
  claim
  producer_role
  protocol_slot
  scale
  why_future_agent_cares
  falsifier
  related_files
  source_artifact_ids
  work_item
  confidence
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

# --- tier must be literal "reusable" ---
# Mirrors grounded-or-nothing pattern from scorecard-append.sh:140-157
TIER=$(printf '%s' "$ROW" | jq -r '.tier // ""')
if [[ "$TIER" != "reusable" ]]; then
  fail_field "tier must be \"reusable\", got: \"$TIER\""
fi

# --- confidence must be literal "unaudited" on new entries ---
CONFIDENCE=$(printf '%s' "$ROW" | jq -r '.confidence // ""')
if [[ "$CONFIDENCE" != "unaudited" ]]; then
  fail_field "confidence must be \"unaudited\" on initial promotion, got: \"$CONFIDENCE\" (use apply-correction.sh to advance confidence after audit)"
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

# --- scale must be a valid registry ID ---
SCALE_VAL=$(printf '%s' "$ROW" | jq -r '.scale // ""')
if [[ -z "${SCALE_VAL// }" ]]; then
  fail_field "scale must not be empty (must be one of the values from scale-registry.sh get-ids)"
else
  VALID_SCALES=$(bash "$SCRIPT_DIR/scale-registry.sh" get-ids 2>/dev/null)
  SCALE_VALID=0
  while IFS= read -r valid_id; do
    if [[ "$SCALE_VAL" == "$valid_id" ]]; then
      SCALE_VALID=1
      break
    fi
  done <<< "$VALID_SCALES"
  if [[ $SCALE_VALID -eq 0 ]]; then
    ENUM_LIST=$(printf '%s' "$VALID_SCALES" | tr '\n' ',' | sed 's/,$//')
    fail_field "invalid scale: \"$SCALE_VAL\" (must be one of: $ENUM_LIST)"
  fi
fi

# --- Non-empty string checks ---
for FIELD in claim why_future_agent_cares falsifier; do
  VAL=$(printf '%s' "$ROW" | jq -r --arg f "$FIELD" '.[$f] // ""')
  if [[ -z "${VAL// }" ]]; then
    fail_field "$FIELD must not be empty"
  fi
done

# --- related_files must be an array ---
if ! printf '%s' "$ROW" | jq -e '.related_files | type == "array"' >/dev/null 2>&1; then
  fail_field "related_files must be a JSON array (may be empty)"
fi

# --- source_artifact_ids must be a non-empty array ---
if ! printf '%s' "$ROW" | jq -e '.source_artifact_ids | type == "array"' >/dev/null 2>&1; then
  fail_field "source_artifact_ids must be a JSON array"
elif ! printf '%s' "$ROW" | jq -e '.source_artifact_ids | length > 0' >/dev/null 2>&1; then
  fail_field "source_artifact_ids must not be empty — at least one Tier 2 source artifact ID is required"
fi

# --- Final result ---
if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS validation error(s) — row rejected" >&2
  exit 1
fi

echo "ok" >&2
exit 0
