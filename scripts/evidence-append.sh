#!/usr/bin/env bash
# evidence-append.sh — Append a validated Tier 2 evidence row to task-claims.jsonl
#
# Usage:
#   echo '<json>' | evidence-append.sh --work-item <slug>
#   evidence-append.sh --file <row.json> --work-item <slug>
#
# Reads a single JSON object (via stdin or --file), validates it against the
# Tier 2 evidence schema via validate-tier2.sh, and appends one JSONL line to
# $KDIR/_work/<slug>/task-claims.jsonl. Creates the file on first use.
#
# SOLE-WRITER INVARIANT: `evidence-append.sh` is the only sanctioned writer of
# `$KDIR/_work/<slug>/task-claims.jsonl`. No other script, skill, agent prompt,
# or human process may append, edit, or truncate that file directly. Rows that
# bypass this validator are treated as corrupt by every reader of task-claims.jsonl
# and are excluded from phase-acceptance checks. Direct writes circumvent the
# schema validator and silently invalidate the evidence trail for the work item.
# See `architecture/artifacts/tier2-evidence-schema.md` for the schema and
# validation rules.
#
# Required arguments:
#   --work-item <slug>   Slug of the work item whose task-claims.jsonl to append to.
#
# Optional arguments:
#   --file <path>        Read the JSON row from a file instead of stdin.
#   --kdir <path>        Override the knowledge store directory (testing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FILE_PATH=""
WORK_ITEM=""
KDIR_OVERRIDE=""

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
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,23p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: evidence-append.sh --work-item <slug> [--file <path>] [--kdir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_ITEM" ]]; then
  echo "Error: --work-item <slug> is required" >&2
  echo "Usage: evidence-append.sh --work-item <slug> [--file <path>] [--kdir <path>]" >&2
  exit 1
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

# --- Writer-path gate: reject the legacy-migration marker ---
# `provenance: "legacy-no-snippet"` is reserved for the Phase 2 backfill writer
# (evidence-update.sh). New producer emissions via evidence-append.sh must
# carry a real snippet+hash; they cannot opt into the slow-path legacy state.
# The validator (validate-tier2.sh) accepts the legacy state because the
# migration writer reuses it for the canonical schema check, but only this
# script is the sanctioned writer for new rows.
APPEND_PROVENANCE=$(printf '%s' "$ROW" | jq -r '.provenance // ""' 2>/dev/null || echo "")
if [[ "$APPEND_PROVENANCE" == "legacy-no-snippet" ]]; then
  echo "[evidence-append] Row rejected: provenance=\"legacy-no-snippet\" is reserved for the migration writer; new emissions must carry exact_snippet + normalized_snippet_hash" >&2
  exit 1
fi

# --- Validate via validate-tier2.sh ---
# Let the validator write its own diagnostics to stderr directly.
# The || block only runs if the validator exits non-zero; -e does not
# fire on the left side of || inside set -e.
if ! printf '%s' "$ROW" | "$SCRIPT_DIR/validate-tier2.sh" >/dev/null; then
  echo "[evidence-append] Row rejected by validate-tier2.sh — not appended" >&2
  exit 1
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  die "knowledge store not found at: $KNOWLEDGE_DIR"
fi

WORK_DIR="$KNOWLEDGE_DIR/_work/$WORK_ITEM"
if [[ ! -d "$WORK_DIR" ]]; then
  die "work item not found: $WORK_DIR"
fi

TARGET="$WORK_DIR/task-claims.jsonl"

# --- Compact to one line and append ---
COMPACT=$(printf '%s' "$ROW" | jq -c '.')
printf '%s\n' "$COMPACT" >> "$TARGET"

# Fail-open settlement trigger: validated Tier 2 evidence is the durable
# enqueue point, but settlement availability must never make evidence append
# provider-specific or lossy. Queue failures warn and preserve exit 0.
if [[ -x "$SCRIPT_DIR/settlement-queue.sh" ]]; then
  if ! printf '%s' "$COMPACT" \
    | "$SCRIPT_DIR/settlement-queue.sh" enqueue --work-item "$WORK_ITEM" --kdir "$KNOWLEDGE_DIR" --json >/dev/null; then
    echo "[evidence-append] warning: settlement enqueue failed; evidence append preserved" >&2
  fi
fi

CLAIM_ID=$(printf '%s' "$ROW" | jq -r '.claim_id // "(unknown)"')
echo "[evidence-append] Appended claim '$CLAIM_ID' to _work/$WORK_ITEM/task-claims.jsonl"
