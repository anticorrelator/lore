#!/usr/bin/env bash
# evidence-update.sh — Mutate a single Tier 2 evidence row in task-claims.jsonl.
#
# Usage:
#   evidence-update.sh --work-item <slug> --claim-id <id> --set <field>=<value> [--set ...]
#   evidence-update.sh --task-claims-path <abs-path> --claim-id <id> --from-stdin
#   echo '<merge.json>' | evidence-update.sh --work-item <slug> --claim-id <id> --from-stdin
#
# Reads the target task-claims.jsonl, locates the row whose `claim_id` matches
# `--claim-id`, applies the requested merge (one or more `--set field=value`
# pairs OR a single JSON-object merge read from stdin), validates the resulting
# row against validate-tier2.sh, and rewrites the file atomically (read whole
# file → mutate target line in memory → write to <file>.tmp → rename).
#
# SOLE-WRITER INVARIANT (UPDATE OPERATION): `evidence-update.sh` is the only
# sanctioned writer of the *update* operation on `$KDIR/_work/<slug>/task-claims.jsonl`.
# `evidence-append.sh` remains the sole writer of the append operation. The two
# scripts together cover every legitimate write path for that file. No other
# script, skill, agent prompt, or human process may edit, truncate, or rewrite
# the file directly. The per-file sole-writer invariant (see
# `conventions/sole-writer-invariant-is-granular-by-file-not-by.md`) is
# granular per *operation*, so distinct scripts can each own their own
# operation as long as no other writer touches the file.
#
# Writer-path divergence from evidence-append.sh:
#   - `evidence-append.sh` REJECTS `provenance: "legacy-no-snippet"` at a
#     writer-path gate. New producer rows cannot carry the legacy marker.
#   - `evidence-update.sh` ACCEPTS `provenance: "legacy-no-snippet"`. This
#     script is the only sanctioned emitter of the slow-path legacy terminal
#     state, used by `scripts/evidence-backfill-snippets.py` for rows whose
#     source bytes are unrecoverable at `captured_at_sha`.
#
# Origin-preserving: `producer_role` is NEVER mutated, even if `--set` or the
# stdin merge object names it. The migration is origin-preserving — the row's
# original producer identity is part of the evidence trail.
#
# D2 exclusive-terminal-state enforcement: the post-mutation row must be in
# exactly one of the two terminal states defined in validate-tier2.sh.
# `validate-tier2.sh` enforces this directly; this script delegates to it.
#
# Required arguments:
#   --claim-id <id>            Row to mutate (matched against `claim_id` field).
#   One of:
#     --work-item <slug>       Resolved through `lore work resolve` (active +
#                              archived slugs both supported).
#     --task-claims-path <p>   Absolute path to task-claims.jsonl. Bypasses
#                              slug resolution; preferred by the migration
#                              driver when enumerating files directly.
#   One of:
#     --set <field>=<value>    May be repeated. Values are merged as JSON
#                              strings (use --from-stdin for nested objects).
#     --from-stdin             Read a single JSON object from stdin; its keys
#                              merge into the target row.
#
# Optional arguments:
#   --kdir <path>              Override the knowledge store directory (testing).
#   --quiet                    Suppress the success summary on stdout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORK_ITEM=""
TASK_CLAIMS_PATH=""
CLAIM_ID=""
FROM_STDIN=0
KDIR_OVERRIDE=""
QUIET=0
SET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --task-claims-path)
      TASK_CLAIMS_PATH="$2"
      shift 2
      ;;
    --claim-id)
      CLAIM_ID="$2"
      shift 2
      ;;
    --set)
      SET_ARGS+=("$2")
      shift 2
      ;;
    --from-stdin)
      FROM_STDIN=1
      shift
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CLAIM_ID" ]]; then
  die "--claim-id <id> is required"
fi

if [[ -z "$WORK_ITEM" && -z "$TASK_CLAIMS_PATH" ]]; then
  die "one of --work-item <slug> or --task-claims-path <path> is required"
fi

if [[ -n "$WORK_ITEM" && -n "$TASK_CLAIMS_PATH" ]]; then
  die "--work-item and --task-claims-path are mutually exclusive"
fi

if [[ $FROM_STDIN -eq 1 && ${#SET_ARGS[@]} -gt 0 ]]; then
  die "--from-stdin and --set are mutually exclusive"
fi

if [[ $FROM_STDIN -eq 0 && ${#SET_ARGS[@]} -eq 0 ]]; then
  die "must provide either --set <field>=<value> (one or more) or --from-stdin"
fi

# --- Resolve target file ---
if [[ -n "$TASK_CLAIMS_PATH" ]]; then
  TARGET="$TASK_CLAIMS_PATH"
else
  # Resolve --work-item through lore work resolve so active and archived slugs both work.
  if [[ -n "$KDIR_OVERRIDE" ]]; then
    KNOWLEDGE_DIR="$KDIR_OVERRIDE"
  else
    KNOWLEDGE_DIR=$(resolve_knowledge_dir)
  fi
  if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
    die "knowledge store not found at: $KNOWLEDGE_DIR"
  fi

  # Try active first, then archive — bypass `lore work resolve` to keep the
  # writer dependency-light (the migration driver may run before lore CLI is
  # set up, and `--task-claims-path` exists for that case). Workers calling
  # with a slug get the same behavior as evidence-append.sh.
  if [[ -d "$KNOWLEDGE_DIR/_work/$WORK_ITEM" ]]; then
    TARGET="$KNOWLEDGE_DIR/_work/$WORK_ITEM/task-claims.jsonl"
  elif [[ -d "$KNOWLEDGE_DIR/_work/_archive/$WORK_ITEM" ]]; then
    TARGET="$KNOWLEDGE_DIR/_work/_archive/$WORK_ITEM/task-claims.jsonl"
  else
    die "work item not found (active or archive): $WORK_ITEM"
  fi
fi

if [[ ! -f "$TARGET" ]]; then
  die "task-claims.jsonl not found at: $TARGET"
fi

# --- Read merge object ---
if [[ $FROM_STDIN -eq 1 ]]; then
  if [[ -t 0 ]]; then
    die "no input: --from-stdin requires a JSON object on stdin"
  fi
  MERGE_JSON=$(cat)
  if [[ -z "${MERGE_JSON// }" ]]; then
    die "stdin merge object is empty"
  fi
  if ! printf '%s' "$MERGE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die "stdin merge must be a JSON object"
  fi
else
  # Build merge object from one or more --set field=value args. Values are
  # treated as JSON strings (the common case for snippet/hash/provenance).
  # For richer merges (nested objects, non-string types) use --from-stdin.
  MERGE_JSON='{}'
  for kv in "${SET_ARGS[@]}"; do
    if [[ "$kv" != *=* ]]; then
      die "invalid --set value (must be field=value): $kv"
    fi
    K="${kv%%=*}"
    V="${kv#*=}"
    MERGE_JSON=$(printf '%s' "$MERGE_JSON" | jq --arg k "$K" --arg v "$V" '. + {($k): $v}')
  done
fi

# --- Mutate, validate, atomic-replace ---
RESULT=$(
  TARGET="$TARGET" \
  CLAIM_ID="$CLAIM_ID" \
  MERGE_JSON="$MERGE_JSON" \
  python3 - <<'PYEOF'
import json
import os
import sys

target = os.environ["TARGET"]
claim_id = os.environ["CLAIM_ID"]
merge = json.loads(os.environ["MERGE_JSON"])

with open(target, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

match_idx = None
match_row = None
for i, raw in enumerate(lines):
    stripped = raw.strip()
    if not stripped:
        continue
    try:
        row = json.loads(stripped)
    except json.JSONDecodeError:
        continue
    if not isinstance(row, dict):
        continue
    if str(row.get("claim_id") or "") == claim_id:
        match_idx = i
        match_row = row
        break

if match_idx is None:
    print(f"no row matched claim_id={claim_id!r}", file=sys.stderr)
    sys.exit(2)

# Origin-preserving: producer_role is never mutated, even if the merge names it.
original_producer_role = match_row.get("producer_role")
mutated = dict(match_row)
for k, v in merge.items():
    if k == "producer_role":
        # Silently ignore; the migration is origin-preserving by contract.
        continue
    mutated[k] = v
if original_producer_role is not None:
    mutated["producer_role"] = original_producer_role

# Idempotency: if mutation produces the same row, emit a no-op marker so the
# caller can short-circuit before re-validating and re-writing the file.
new_line = json.dumps(mutated, sort_keys=False, separators=(",", ":"))
old_line_normalized = json.dumps(match_row, sort_keys=False, separators=(",", ":"))
if new_line == old_line_normalized:
    print(json.dumps({
        "noop": True,
        "claim_id": claim_id,
        "match_line": match_idx + 1,
    }))
    sys.exit(0)

print(json.dumps({
    "noop": False,
    "claim_id": claim_id,
    "match_line": match_idx + 1,
    "new_line": new_line,
    "match_idx": match_idx,
}))
PYEOF
) || {
  rc=$?
  if [[ $rc -eq 2 ]]; then
    die "claim_id not found in $TARGET: $CLAIM_ID"
  fi
  die "mutation step failed (exit $rc)"
}

NOOP=$(printf '%s' "$RESULT" | jq -r '.noop')
MATCH_LINE=$(printf '%s' "$RESULT" | jq -r '.match_line')

if [[ "$NOOP" == "true" ]]; then
  if [[ $QUIET -eq 0 ]]; then
    echo "[evidence-update] no-op: claim '$CLAIM_ID' at line $MATCH_LINE already matches the requested mutation"
  fi
  exit 0
fi

NEW_LINE=$(printf '%s' "$RESULT" | jq -r '.new_line')
MATCH_IDX=$(printf '%s' "$RESULT" | jq -r '.match_idx')

# Validate the post-mutation row via validate-tier2.sh. The validator enforces
# the D2 exclusive-terminal-state rule directly: rows in mixed state (legacy
# flag + snippet/hash present) are rejected. Reject the mutation and leave the
# file untouched on any validation failure.
if ! printf '%s' "$NEW_LINE" | "$SCRIPT_DIR/validate-tier2.sh" >/dev/null; then
  echo "[evidence-update] Mutation rejected by validate-tier2.sh — file untouched: $TARGET (claim_id=$CLAIM_ID)" >&2
  exit 1
fi

# Atomic JSONL rewrite: read whole file → splice mutated line → write to .tmp
# → rename. mv is atomic on POSIX filesystems; readers see either the old or
# new contents, never a partial write.
TMP_TARGET="${TARGET}.tmp.$$"
trap 'rm -f "$TMP_TARGET"' EXIT

TARGET="$TARGET" \
TMP_TARGET="$TMP_TARGET" \
MATCH_IDX="$MATCH_IDX" \
NEW_LINE="$NEW_LINE" \
python3 - <<'PYEOF'
import os

target = os.environ["TARGET"]
tmp = os.environ["TMP_TARGET"]
match_idx = int(os.environ["MATCH_IDX"])
new_line = os.environ["NEW_LINE"]

with open(target, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

# Preserve trailing newline-or-not from the original file's matched line.
original = lines[match_idx]
if original.endswith("\n"):
    lines[match_idx] = new_line + "\n"
else:
    lines[match_idx] = new_line

with open(tmp, "w", encoding="utf-8") as fh:
    fh.writelines(lines)

os.replace(tmp, target)
PYEOF

trap - EXIT

if [[ $QUIET -eq 0 ]]; then
  echo "[evidence-update] Mutated claim '$CLAIM_ID' at line $MATCH_LINE of $TARGET"
fi
