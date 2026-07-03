#!/usr/bin/env bash
# promote-commons-append.sh — Append a validated commons-audit producer row to
# promoted-commons.jsonl.
#
# Usage:
#   echo '<json>' | promote-commons-append.sh --work-item <slug> --entry-path <rel>
#   promote-commons-append.sh --file <row.json> --work-item <slug> --entry-path <rel>
#
# Records the durable audit payload for a freshly-promoted Tier-3 commons entry.
# Each row carries the claim_payload (claim, falsifier, related_files, scale,
# claim_id) plus `entry_path` — the knowledge-store-relative path of the entry
# the audit will flow back to. The falsifier survives ONLY here: capture.sh does
# not persist it into the entry .md, so this row is the sole reconstructable
# source for the correctness-gate that audits the entry.
#
# SOLE-WRITER INVARIANT: promote-commons-append.sh is the only sanctioned writer
# of $KDIR/_work/<slug>/promoted-commons.jsonl. It is a Tier-3 *producer* log (a
# sibling of task-claims.jsonl), not a settlement *correction* sidecar — the
# settlement processor reads it via the generic source-stream machinery
# (KIND_SOURCES["commons"]). Rows that bypass this validator are corrupt to every
# reader of the file.
#
# Required arguments:
#   --work-item <slug>    Work item slug whose promoted-commons.jsonl to append to.
#   --entry-path <rel>    Knowledge-store-relative path of the promoted entry
#                         (e.g. conventions/my-entry.md). Stamped onto the row as
#                         `entry_path`; the flowback terminus resolves mutation
#                         authority from it.
#
# Optional arguments:
#   --file <path>         Read the JSON row from a file instead of stdin.
#   --kdir <path>         Override the knowledge store directory (testing).
#
# Exit codes:
#   0  success
#   1  usage or validation error (fail-closed: no row appended)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FILE_PATH=""
WORK_ITEM=""
ENTRY_PATH=""
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
    --entry-path)
      ENTRY_PATH="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,36p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: promote-commons-append.sh --work-item <slug> --entry-path <rel> [--file <path>] [--kdir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$WORK_ITEM" ]]; then
  die "--work-item <slug> is required"
fi
if [[ -z "$ENTRY_PATH" ]]; then
  die "--entry-path <rel> is required"
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

if ! command -v jq &>/dev/null; then
  die "jq is required but not found on PATH"
fi

if ! printf '%s' "$ROW" | jq -e 'type == "object"' >/dev/null 2>&1; then
  die "row must be a JSON object"
fi

# --- Stamp entry_path onto the row ---
# entry_path is mutation authority for the flowback terminus; the caller resolves
# it from capture.sh stdout rather than trusting any value already on the row.
ROW=$(printf '%s' "$ROW" | jq --arg p "$ENTRY_PATH" '. + {entry_path: $p}')

# --- Inline claim_payload validation (schema-in-writer; no separate JSON Schema) ---
# Mirrors validate-tier2/tier3: the auditable payload the correctness-gate needs
# (claim_id + claim + falsifier + related_files + scale) plus entry_path must all
# be present and well-typed. A missing field here would silently break the audit
# that consumes this row.
INVALID=$(printf '%s' "$ROW" | jq -r '
  def nonempty_str: type == "string" and (. | gsub("^\\s+|\\s+$"; "") | length) > 0;
  [
    (if (.claim_id | nonempty_str) then empty else "claim_id" end),
    (if (.claim | nonempty_str) then empty else "claim" end),
    (if (.falsifier | nonempty_str) then empty else "falsifier" end),
    (if (.entry_path | nonempty_str) then empty else "entry_path" end),
    (if (.scale | nonempty_str) then empty else "scale" end),
    (if (.related_files | type == "array" and length > 0) then empty else "related_files" end)
  ] | join(", ")
')
if [[ -n "$INVALID" ]]; then
  echo "[promote-commons] Row rejected: missing/invalid field(s): $INVALID" >&2
  exit 1
fi

SCALE=$(printf '%s' "$ROW" | jq -r '.scale')
case "$SCALE" in
  abstract|architecture|subsystem|implementation) : ;;
  *)
    echo "[promote-commons] Row rejected: scale must be abstract|architecture|subsystem|implementation (got '$SCALE')" >&2
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
  die "knowledge store not found at: $KNOWLEDGE_DIR"
fi

# entry_path must resolve to an existing commons entry inside the store; reject a
# row whose target escapes $KDIR or does not exist (it becomes mutation authority
# downstream, so a bad path here is unrecoverable).
ENTRY_ABS=$(cd "$KNOWLEDGE_DIR" && python3 -c '
import os, sys
kdir = os.path.abspath(sys.argv[1])
target = os.path.abspath(os.path.join(kdir, sys.argv[2]))
if os.path.commonpath([kdir, target]) != kdir:
    print(""); sys.exit(0)
print(target if os.path.isfile(target) else "")
' "$KNOWLEDGE_DIR" "$ENTRY_PATH")
if [[ -z "$ENTRY_ABS" ]]; then
  echo "[promote-commons] Row rejected: entry_path does not resolve to an existing entry inside the store: $ENTRY_PATH" >&2
  exit 1
fi

# Archived work items keep their artifacts under _work/_archive/<slug>/ —
# resolve at write time by artifact presence (active then archive) so rows for
# an archived item land next to its other files and a stale active stub can no
# longer win over the archive copy that holds the item's existing rows.
if ! WORK_DIR=$(resolve_work_item_dir "$KNOWLEDGE_DIR" "$WORK_ITEM" "promoted-commons.jsonl"); then
  die "work item not found in _work/ or _work/_archive/: $WORK_ITEM"
fi

TARGET="$WORK_DIR/promoted-commons.jsonl"

# --- Compact to one line and append ---
COMPACT=$(printf '%s' "$ROW" | jq -c '.')
printf '%s\n' "$COMPACT" >> "$TARGET"

CLAIM_ID=$(printf '%s' "$ROW" | jq -r '.claim_id // "(unknown)"')
echo "[promote-commons] Appended claim '$CLAIM_ID' to ${TARGET#"$KNOWLEDGE_DIR/"}"
