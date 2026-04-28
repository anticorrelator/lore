#!/usr/bin/env bash
# lore-promote.sh — Promote a Tier 3 observation row to the knowledge commons.
#
# Usage:
#   echo '<json>' | lore-promote.sh --work-item <slug>
#   lore-promote.sh --file row.json --work-item <slug>
#   lore-promote.sh --file row.json --work-item <slug> --dry-run
#
# Reads a single Tier 3 JSON object from stdin or --file, validates it via
# validate-tier3.sh, forces confidence="unaudited", then delegates to capture.sh.
#
# Confidence policy:
#   confidence is ALWAYS set to "unaudited" by this script, regardless of what
#   the caller supplies. If the caller passes a different value, a warning is
#   emitted and the value is overridden. Advancement beyond "unaudited" is handled
#   exclusively by apply-correction.sh after independent audit.
#
# Required flags:
#   --work-item <slug>   Work item slug (propagated to capture.sh --work-item)
#
# Optional flags:
#   --file <path>              Read row from file instead of stdin
#   --dry-run                  Validate + print planned invocation; do NOT write
#   --producer-role <role>     Override producer_role from row (passthrough to capture.sh)
#   --protocol-slot <slot>     Override protocol_slot from row (passthrough to capture.sh)
#   --source-artifact-ids <s>  Override source_artifact_ids from row (comma-separated)
#   --template-version <v>     Template version hash (passthrough to capture.sh)
#   --category <cat>           Knowledge category (default: conventions)
#
# Exit codes:
#   0  success (or --dry-run success)
#   1  usage or validation error
#   2+ propagated from capture.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FILE_PATH=""
WORK_ITEM=""
DRY_RUN=0
PRODUCER_ROLE_OVERRIDE=""
PROTOCOL_SLOT_OVERRIDE=""
SOURCE_ARTIFACT_IDS_OVERRIDE=""
TEMPLATE_VERSION=""
CATEGORY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      FILE_PATH="$2"
      shift 2
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --producer-role)
      PRODUCER_ROLE_OVERRIDE="$2"
      shift 2
      ;;
    --protocol-slot)
      PROTOCOL_SLOT_OVERRIDE="$2"
      shift 2
      ;;
    --source-artifact-ids)
      SOURCE_ARTIFACT_IDS_OVERRIDE="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --category)
      CATEGORY="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: lore-promote.sh --work-item <slug> [--file <path>] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_ITEM" ]]; then
  die "--work-item <slug> is required"
fi

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

# --- Validate JSON object before anything else ---
if ! printf '%s' "$ROW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  die "row must be a JSON object"
fi

# --- Force confidence="unaudited" (sole writer policy) ---
CALLER_CONFIDENCE=$(printf '%s' "$ROW" | jq -r '.confidence // ""')
if [[ -n "$CALLER_CONFIDENCE" && "$CALLER_CONFIDENCE" != "unaudited" ]]; then
  echo "[promote] warning: caller supplied confidence=\"$CALLER_CONFIDENCE\"; overriding to \"unaudited\"." >&2
  echo "[promote] Use apply-correction.sh to advance confidence after independent audit." >&2
fi
ROW=$(printf '%s' "$ROW" | jq '. + {"confidence": "unaudited"}')

# --- Validate via validate-tier3.sh (gate before any write) ---
VALIDATE_SCRIPT="$SCRIPT_DIR/validate-tier3.sh"
if [[ ! -x "$VALIDATE_SCRIPT" ]]; then
  die "validate-tier3.sh not found or not executable at $VALIDATE_SCRIPT"
fi

if ! printf '%s' "$ROW" | "$VALIDATE_SCRIPT"; then
  echo "[promote] row rejected by validate-tier3.sh — capture.sh not called" >&2
  exit 1
fi

# --- Extract provenance fields from row (CLI overrides take precedence) ---
CLAIM_ID=$(printf '%s' "$ROW" | jq -r '.claim_id // ""')
CLAIM=$(printf '%s' "$ROW" | jq -r '.claim // ""')
FALSIFIER=$(printf '%s' "$ROW" | jq -r '.falsifier // ""')
WHY=$(printf '%s' "$ROW" | jq -r '.why_future_agent_cares // ""')

_row_producer_role=$(printf '%s' "$ROW" | jq -r '.producer_role // ""')
PRODUCER_ROLE="${PRODUCER_ROLE_OVERRIDE:-$_row_producer_role}"
_row_protocol_slot=$(printf '%s' "$ROW" | jq -r '.protocol_slot // ""')
PROTOCOL_SLOT="${PROTOCOL_SLOT_OVERRIDE:-$_row_protocol_slot}"
SCALE=$(printf '%s' "$ROW" | jq -r '.scale // ""')
if [[ -z "$SCALE" ]]; then
  die "row missing required field: scale (must be one of: application, architectural, subsystem, implementation)"
fi
CAPTURED_AT_SHA=$(printf '%s' "$ROW" | jq -r '.captured_at_sha // ""')

# related_files: array → comma-separated string for capture.sh --related-files
RELATED_FILES=$(printf '%s' "$ROW" | jq -r '[.related_files // [] | .[] ] | join(",")')

# source_artifact_ids: array → comma-separated string; CLI override wins
if [[ -n "$SOURCE_ARTIFACT_IDS_OVERRIDE" ]]; then
  SOURCE_ARTIFACT_IDS="$SOURCE_ARTIFACT_IDS_OVERRIDE"
else
  SOURCE_ARTIFACT_IDS=$(printf '%s' "$ROW" | jq -r '[.source_artifact_ids // [] | .[] ] | join(",")')
fi

# Build insight text: combine claim + why_future_agent_cares + falsifier
INSIGHT="$CLAIM"
if [[ -n "$WHY" ]]; then
  INSIGHT="$INSIGHT Why future agent cares: $WHY"
fi
if [[ -n "$FALSIFIER" ]]; then
  INSIGHT="$INSIGHT Falsifier: $FALSIFIER"
fi

# Context: claim_id for traceability back to source row
CONTEXT="Promoted from Tier 3 observation $CLAIM_ID (work-item: $WORK_ITEM)"

# --- Resolve knowledge dir for dry-run target path ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
TARGET_CATEGORY="${CATEGORY:-conventions}"
TARGET_PATH="$KNOWLEDGE_DIR/$TARGET_CATEGORY/<slug>.md"

# --- Build capture.sh invocation ---
CAPTURE_ARGS=(
  --insight "$INSIGHT"
  --context "$CONTEXT"
  --confidence "unaudited"
  --scale "$SCALE"
  --work-item "$WORK_ITEM"
  --source "lore-promote"
)
[[ -n "$TARGET_CATEGORY" ]] && CAPTURE_ARGS+=(--category "$TARGET_CATEGORY")
[[ -n "$PRODUCER_ROLE" ]]   && CAPTURE_ARGS+=(--producer-role "$PRODUCER_ROLE")
[[ -n "$PROTOCOL_SLOT" ]]   && CAPTURE_ARGS+=(--protocol-slot "$PROTOCOL_SLOT")
[[ -n "$TEMPLATE_VERSION" ]] && CAPTURE_ARGS+=(--template-version "$TEMPLATE_VERSION")
[[ -n "$SOURCE_ARTIFACT_IDS" ]] && CAPTURE_ARGS+=(--source-artifact-ids "$SOURCE_ARTIFACT_IDS")
[[ -n "$RELATED_FILES" ]]   && CAPTURE_ARGS+=(--related-files "$RELATED_FILES")
[[ -n "$CAPTURED_AT_SHA" ]] && CAPTURE_ARGS+=(--captured-at-sha "$CAPTURED_AT_SHA")

# --- Dry-run: print planned invocation and exit ---
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[promote] dry-run: validation passed" >&2
  echo "[promote] claim_id: $CLAIM_ID"
  echo "[promote] target commons: $TARGET_PATH"
  echo "[promote] planned capture.sh invocation:"
  printf '  capture.sh'
  for ARG in "${CAPTURE_ARGS[@]}"; do
    printf ' %q' "$ARG"
  done
  printf '\n'
  exit 0
fi

# --- Invoke capture.sh ---
"$SCRIPT_DIR/capture.sh" "${CAPTURE_ARGS[@]}"
CAPTURE_EXIT=$?

if [[ $CAPTURE_EXIT -eq 0 ]]; then
  echo "[promote] promoted claim_id: $CLAIM_ID"
fi

exit $CAPTURE_EXIT
