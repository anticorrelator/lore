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
# Required fields (fast-path producer emissions):
#   claim_id, tier, claim, producer_role, protocol_slot, task_id, phase_id,
#   scale, file, line_range, falsifier, why_this_work_needs_it,
#   captured_at_sha, change_context
#
# D2 grandfather waiver — slow-path legacy rows
# (provenance == "legacy-no-snippet"): all of the above are still required
# EXCEPT change_context. Pre-Phase-1 producer rows pre-date the change_context
# schema field the same way they pre-date snippet+hash; the slow-path
# grandfather state extends to both. New (fast-path) producer rows have no
# escape hatch — they must carry change_context.
#
# tier must equal the literal string "task-evidence".
# producer_role must be one of: researcher, worker, advisor, spec-lead, implement-lead
# scale must be one of the IDs from scale-registry.sh get-ids; "unknown" is rejected.
# claim, falsifier, why_this_work_needs_it must be non-empty strings.
# line_range must match N-M with N <= M.
#
# Snippet anchoring: each row must be in exactly one terminal state:
#   fast-path  — exact_snippet (non-empty string) AND
#                normalized_snippet_hash (lowercase 64-char hex matching
#                sha256(v1_normalize(exact_snippet))). provenance, if present,
#                must NOT be "legacy-no-snippet".
#   slow-path  — provenance == "legacy-no-snippet" AND exact_snippet and
#                normalized_snippet_hash are both absent (or null). The
#                migration writer is the only sanctioned emitter of this state;
#                evidence-append.sh rejects it at the writer-path gate.
# Any other combination (mixed, partial, malformed) is rejected.
#
# Optional source-anchor metadata (additive, non-gating):
#   file_relative           — string, path relative to a `.git/` ancestor of `file`
#   captured_origin_ref     — string or null, e.g. "origin/main"; null when HEAD
#                             is not reachable from any origin/* ref
#   anchor_warning          — string, e.g. "unpushed_local_only"
# When present, these fields are type-checked but never required. Pre-existing
# rows without them continue to validate. Derivation happens in evidence-append.sh.

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
      sed -n '2,35p' "$0"
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
# `change_context` is intentionally NOT in this list — it is checked separately
# below, gated behind `provenance != "legacy-no-snippet"`. Slow-path legacy
# rows from the Phase 2 backfill pre-date the `change_context` schema field
# and are grandfathered against it by D2; new producer rows (fast-path) still
# require change_context via the conditional check below.
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

# --- change_context required ONLY on non-legacy rows (D2 grandfather waiver) ---
# Pre-Phase-1 rows in the slow-path terminal state (provenance=legacy-no-snippet)
# are grandfathered against the change_context requirement — they pre-date the
# field entirely. Fast-path producer rows must still carry it.
GRANDFATHER_PROVENANCE=$(printf '%s' "$ROW" | jq -r '.provenance // ""')
if [[ "$GRANDFATHER_PROVENANCE" != "legacy-no-snippet" ]]; then
  if ! printf '%s' "$ROW" | jq -e 'has("change_context") and (.change_context != null)' >/dev/null 2>&1; then
    fail_field "missing required field: change_context"
  fi
fi

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

# --- change_context must be sufficient for downstream settlement judges ---
# Gated by the same D2 grandfather waiver: legacy-no-snippet rows skip the
# semantic checks because they pre-date the field. The presence check above
# already exempted them.
if [[ "$GRANDFATHER_PROVENANCE" != "legacy-no-snippet" ]]; then
  if ! printf '%s' "$ROW" | jq -e '.change_context | type == "object"' >/dev/null 2>&1; then
    fail_field "change_context must be an object"
  else
    if ! printf '%s' "$ROW" | jq -e '.change_context.summary | type == "string" and (length > 0)' >/dev/null 2>&1; then
      fail_field "change_context.summary must be a non-empty string"
    fi
    if ! printf '%s' "$ROW" | jq -e '.change_context.changed_files | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
      fail_field "change_context.changed_files must be a non-empty array of non-empty strings"
    fi
    if ! printf '%s' "$ROW" | jq -e '(.change_context.diff_ref == null) or (.change_context.diff_ref | type == "string")' >/dev/null 2>&1; then
      fail_field "change_context.diff_ref must be null or a string"
    fi
    if ! printf '%s' "$ROW" | jq -e '.file as $file | .change_context.changed_files | index($file)' >/dev/null 2>&1; then
      fail_field "change_context.changed_files must include file"
    fi
  fi
fi

# --- file must be non-empty ---
FILE_VAL=$(printf '%s' "$ROW" | jq -r '.file // ""')
if [[ -z "${FILE_VAL// }" ]]; then
  fail_field "file must not be empty"
fi

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

# --- Snippet anchoring: exactly one of two terminal states ---
# fast-path:  exact_snippet + normalized_snippet_hash (semantic checks pass),
#             and provenance != "legacy-no-snippet".
# slow-path:  provenance == "legacy-no-snippet" with no snippet/hash.
# Any other shape is rejected (presence-without-the-pair, partial pair,
# mixed state with legacy marker + snippet, malformed hash, hash mismatch).
HAS_SNIPPET=$(printf '%s' "$ROW" | jq -e 'has("exact_snippet") and (.exact_snippet != null)' >/dev/null 2>&1 && echo 1 || echo 0)
HAS_HASH=$(printf '%s' "$ROW" | jq -e 'has("normalized_snippet_hash") and (.normalized_snippet_hash != null)' >/dev/null 2>&1 && echo 1 || echo 0)
PROVENANCE=$(printf '%s' "$ROW" | jq -r '.provenance // ""')

if [[ "$PROVENANCE" == "legacy-no-snippet" ]]; then
  # Slow-path legacy terminal state: snippet and hash must both be absent.
  if [[ "$HAS_SNIPPET" == "1" || "$HAS_HASH" == "1" ]]; then
    fail_field "provenance=\"legacy-no-snippet\" rows must not carry exact_snippet or normalized_snippet_hash (mixed terminal state)"
  fi
else
  # Fast-path: both fields required, with semantic validation.
  if [[ "$HAS_SNIPPET" == "0" ]]; then
    fail_field "missing required field: exact_snippet (or set provenance=\"legacy-no-snippet\" for the migration slow-path)"
  fi
  if [[ "$HAS_HASH" == "0" ]]; then
    fail_field "missing required field: normalized_snippet_hash (or set provenance=\"legacy-no-snippet\" for the migration slow-path)"
  fi
  if [[ "$HAS_SNIPPET" == "1" && "$HAS_HASH" == "1" ]]; then
    SNIPPET_TYPE=$(printf '%s' "$ROW" | jq -r '.exact_snippet | type')
    HASH_TYPE=$(printf '%s' "$ROW" | jq -r '.normalized_snippet_hash | type')
    if [[ "$SNIPPET_TYPE" != "string" ]]; then
      fail_field "exact_snippet must be a string, got: $SNIPPET_TYPE"
    fi
    if [[ "$HASH_TYPE" != "string" ]]; then
      fail_field "normalized_snippet_hash must be a string, got: $HASH_TYPE"
    fi
    if [[ "$SNIPPET_TYPE" == "string" && "$HASH_TYPE" == "string" ]]; then
      SNIPPET_VAL=$(printf '%s' "$ROW" | jq -r '.exact_snippet')
      HASH_VAL=$(printf '%s' "$ROW" | jq -r '.normalized_snippet_hash')
      if [[ -z "$SNIPPET_VAL" ]]; then
        fail_field "exact_snippet must be a non-empty string"
      fi
      if ! printf '%s' "$HASH_VAL" | grep -qE '^[0-9a-f]{64}$'; then
        fail_field "normalized_snippet_hash must match ^[0-9a-f]{64}$ (lowercase 64-char hex), got: \"$HASH_VAL\""
      elif [[ -n "$SNIPPET_VAL" ]]; then
        EXPECTED_HASH=$(printf '%s' "$SNIPPET_VAL" | python3 "$SCRIPT_DIR/snippet_normalize.py" --hash)
        if [[ "$EXPECTED_HASH" != "$HASH_VAL" ]]; then
          fail_field "normalized_snippet_hash does not match sha256(v1_normalize(exact_snippet)): expected \"$EXPECTED_HASH\", got \"$HASH_VAL\""
        fi
      fi
    fi
  fi
fi

# --- Optional source-anchor metadata: type checks only ---
# These fields are additive and non-gating. When present, they must have the
# documented shape; when absent, validation is unaffected.
if printf '%s' "$ROW" | jq -e 'has("file_relative")' >/dev/null 2>&1; then
  if ! printf '%s' "$ROW" | jq -e '.file_relative | type == "string"' >/dev/null 2>&1; then
    fail_field "file_relative must be a string"
  fi
fi
if printf '%s' "$ROW" | jq -e 'has("captured_origin_ref")' >/dev/null 2>&1; then
  if ! printf '%s' "$ROW" | jq -e '(.captured_origin_ref == null) or (.captured_origin_ref | type == "string")' >/dev/null 2>&1; then
    fail_field "captured_origin_ref must be a string or null"
  fi
fi
if printf '%s' "$ROW" | jq -e 'has("anchor_warning")' >/dev/null 2>&1; then
  if ! printf '%s' "$ROW" | jq -e '.anchor_warning | type == "string"' >/dev/null 2>&1; then
    fail_field "anchor_warning must be a string"
  fi
fi

# --- Final result ---
if [[ $ERRORS -gt 0 ]]; then
  echo "$ERRORS validation error(s) — row rejected" >&2
  exit 1
fi

echo "ok" >&2
exit 0
