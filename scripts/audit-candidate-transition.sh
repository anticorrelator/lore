#!/usr/bin/env bash
# audit-candidate-transition.sh — Transition an audit-candidate through the lifecycle
#
# Updates the `status` field on an existing row in
# $KDIR/_work/<slug>/audit-candidates.jsonl, preserving all other fields
# and adding/updating a `transitioned_at` timestamp. The file stays JSONL-
# shaped — one candidate per line — but the line matching the given
# candidate_id is rewritten with the new status. Other lines are
# byte-identical.
#
# Usage:
#   audit-candidate-transition.sh \
#       --work-item <slug> \
#       --candidate-id <id> \
#       --status <gate-passed | gate-failed | retired> \
#       [--kdir <path>]
#
# Lifecycle states (per plan Phase 4 / task-26):
#   pending_correctness_gate  initial state — set by audit-queue-route.sh
#                             when preflight passes
#   gate-passed               correctness-gate returned "verified" for the
#                             candidate's claim. Eligible for commons
#                             promotion at the L2 write path.
#   gate-failed               correctness-gate returned "unverified" or
#                             "contradicted". Stays in the candidate queue
#                             for /retro narrative visibility but never
#                             promoted to commons.
#   retired                   candidate was superseded (e.g., duplicate of
#                             a later emission) or the containing work
#                             item archived. Ignored by Phase 7b
#                             backlog-health checks.
#
# Legal transitions enforced:
#   pending_correctness_gate  →  gate-passed | gate-failed | retired
#   gate-passed               →  retired
#   gate-failed               →  retired
#   retired                   →  (terminal — no transitions out)
#
# Any other transition is rejected with exit 1. This keeps /retro backlog
# counts coherent: a candidate can only move forward or retire.
#
# Sole-writer principle: this is the only sanctioned mutator of the
# `status` field on an audit-candidates.jsonl row. The initial append is
# done by audit-queue-route.sh; every subsequent status update routes
# through here. Direct in-place edits bypass the transition-legality
# check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORK_ITEM=""
CANDIDATE_ID=""
NEW_STATUS=""
KDIR_OVERRIDE=""

usage() {
  sed -n '2,40p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-item)    WORK_ITEM="$2";    shift 2 ;;
    --candidate-id) CANDIDATE_ID="$2"; shift 2 ;;
    --status)       NEW_STATUS="$2";   shift 2 ;;
    --kdir)         KDIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)
      echo "[transition] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  echo "[transition] Error: $1" >&2
  exit 1
}

[[ -n "$WORK_ITEM"    ]] || fail "--work-item is required"
[[ -n "$CANDIDATE_ID" ]] || fail "--candidate-id is required"
[[ -n "$NEW_STATUS"   ]] || fail "--status is required"

case "$NEW_STATUS" in
  gate-passed|gate-failed|retired) ;;
  pending_correctness_gate)
    fail "pending_correctness_gate is the initial state; use audit-queue-route.sh to create a candidate"
    ;;
  *)
    fail "--status must be one of: gate-passed, gate-failed, retired"
    ;;
esac

# --- Resolve kdir ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

[[ -d "$KDIR" ]] || fail "knowledge directory not found: $KDIR"

ITEM_DIR="$KDIR/_work/$WORK_ITEM"
[[ -d "$ITEM_DIR" ]] || fail "work item not found: $WORK_ITEM (expected at $ITEM_DIR)"

CAND_FILE="$ITEM_DIR/audit-candidates.jsonl"
[[ -f "$CAND_FILE" ]] || fail "audit-candidates.jsonl not found at $CAND_FILE"

# --- In-place rewrite via atomic temp-file ---
# Python handles the lookup + transition-legality check + rewrite. The
# tempfile approach avoids truncation races: if the script crashes mid-
# write, the original file is untouched.
OUT_FILE=$(mktemp "${CAND_FILE}.XXXXXX")

set +e
CANDIDATE_ID_ENV="$CANDIDATE_ID" \
NEW_STATUS_ENV="$NEW_STATUS" \
CAND_FILE_ENV="$CAND_FILE" \
OUT_FILE_ENV="$OUT_FILE" \
python3 <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

candidate_id = os.environ["CANDIDATE_ID_ENV"]
new_status = os.environ["NEW_STATUS_ENV"]
cand_file = os.environ["CAND_FILE_ENV"]
out_file = os.environ["OUT_FILE_ENV"]

LEGAL = {
    "pending_correctness_gate": {"gate-passed", "gate-failed", "retired"},
    "gate-passed":               {"retired"},
    "gate-failed":                {"retired"},
    "retired":                    set(),
}

found = False
matched_current_status = None

with open(cand_file) as fh_in, open(out_file, "w") as fh_out:
    for line in fh_in:
        stripped = line.strip()
        if not stripped:
            fh_out.write(line)
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            # Preserve corrupt lines so readers can flag them, but warn.
            sys.stderr.write(f"[transition] Warning: skipping unparseable line (preserved): {stripped!r}\n")
            fh_out.write(line)
            continue
        if row.get("candidate_id") == candidate_id:
            if found:
                sys.stderr.write(f"[transition] Warning: duplicate candidate_id {candidate_id} — only first occurrence is transitioned\n")
                fh_out.write(line)
                continue
            current = row.get("status", "")
            if current not in LEGAL:
                sys.stderr.write(f"[transition] Error: candidate {candidate_id} has unknown status '{current}'\n")
                sys.exit(1)
            if new_status not in LEGAL[current]:
                sys.stderr.write(f"[transition] Error: illegal transition for {candidate_id}: {current} → {new_status}\n")
                sys.exit(1)
            matched_current_status = current
            row["status"] = new_status
            row["transitioned_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            fh_out.write(json.dumps(row, sort_keys=True) + "\n")
            found = True
        else:
            fh_out.write(line)

if not found:
    sys.stderr.write(f"[transition] Error: candidate_id {candidate_id} not found in {cand_file}\n")
    sys.exit(1)

print(f"[transition] {candidate_id}: {matched_current_status} → {new_status}")
PYEOF

# If the python step failed (non-zero exit), the temp file is garbage —
# discard it and leave the original untouched.
py_exit=$?
set -e
if [[ $py_exit -ne 0 ]]; then
  rm -f "$OUT_FILE"
  exit $py_exit
fi

# Swap: atomic rename.
mv "$OUT_FILE" "$CAND_FILE"
