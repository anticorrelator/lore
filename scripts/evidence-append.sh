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
# Rows may carry an OPTIONAL executable_falsifier object
# ({command, expected_output_shape[, root]}). It is never required; the row
# passes through this writer untouched and validate-tier2.sh type-checks it
# when present (additive — pre-existing rows without it validate unchanged).
# falsifier-run.py is the runner that executes it.
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

# --- Derive optional source-anchor metadata (additive, non-gating) ---
# file_relative: walk upward from the row's `file` looking for a `.git/`
#   ancestor; the file's path relative to that ancestor is `file_relative`.
#   Omit silently when no git root is found. When `file` is already relative,
#   `file_relative` equals `file` verbatim.
# captured_origin_ref: first ref under refs/remotes/origin/ that contains the
#   cwd repo's HEAD. JSON null when nothing matches (anchor on local-only
#   commits). Derived from the cwd, not from `file`'s repo.
# anchor_warning: set to "unpushed_local_only" iff captured_origin_ref is null,
#   AND emit a single-line stderr soft-warning. Capture continues either way.
ROW_FILE=$(printf '%s' "$ROW" | jq -r '.file // ""' 2>/dev/null || echo "")
FILE_RELATIVE=""
if [[ -n "$ROW_FILE" ]]; then
  if [[ "$ROW_FILE" != /* ]]; then
    FILE_RELATIVE="$ROW_FILE"
  else
    SEARCH_DIR=$(dirname "$ROW_FILE")
    while [[ "$SEARCH_DIR" != "/" && "$SEARCH_DIR" != "." ]]; do
      if [[ -e "$SEARCH_DIR/.git" ]]; then
        FILE_RELATIVE="${ROW_FILE#$SEARCH_DIR/}"
        break
      fi
      SEARCH_DIR=$(dirname "$SEARCH_DIR")
    done
  fi
fi

# `git for-each-ref refs/remotes/origin/` includes the symbolic `origin/HEAD`
# pointer (short name `origin`); skip it so we record the concrete branch.
CAPTURED_ORIGIN_REF=$(git for-each-ref --contains HEAD --format '%(refname:short)' refs/remotes/origin/ 2>/dev/null | grep -v '^origin$' | head -1 || true)

if [[ -n "$FILE_RELATIVE" ]]; then
  ROW=$(printf '%s' "$ROW" | jq --arg v "$FILE_RELATIVE" '.file_relative = $v')
fi
if [[ -n "$CAPTURED_ORIGIN_REF" ]]; then
  ROW=$(printf '%s' "$ROW" | jq --arg v "$CAPTURED_ORIGIN_REF" '.captured_origin_ref = $v')
else
  # Only stamp captured_origin_ref:null and anchor_warning when we are inside
  # a git repo at all — otherwise both fields stay absent (non-git capture).
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ROW=$(printf '%s' "$ROW" | jq '.captured_origin_ref = null | .anchor_warning = "unpushed_local_only"')
    WARN_CLAIM_ID=$(printf '%s' "$ROW" | jq -r '.claim_id // "(unknown)"')
    echo "evidence-append: warning: $WORK_ITEM/$WARN_CLAIM_ID anchored on commit not reachable from any origin/* ref; audits from sibling workspaces will fail until pushed." >&2
  fi
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
