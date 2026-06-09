#!/usr/bin/env bash
# implement-closure-report.sh — Sole terminal emitter for the /implement close.
#
# Usage:
#   implement-closure-report.sh --slug <slug> [--kdir <path>]
#
# Reads the work item's _meta.json (from either the active _work/<slug>/ or the
# archived _work/_archive/<slug>/ location) and emits EXACTLY ONE of two outputs,
# branched on the closure verdict:
#
#   full / legacy (no intent_anchor)  -> Done success summary on stdout, exit 0
#   partial / none                    -> isolated divergence banner on stdout, exit 3
#
# A location-vs-verdict contradiction (archived item carrying
# capability_incomplete==true, or an active item claiming verdict full) is a
# corrupted state: the script exits non-zero (4) WITHOUT printing the Done
# summary, so a corrupted close can never launder into a success report.
#
# The success summary text exists ONLY on the exit-0 branch of this script. The
# /implement Step 7 prose invokes this script and emits its stdout verbatim; it
# does not hand-compose a Done block, so the divergence (non-zero exit) path has
# no success text the caller could re-emit.
#
# Required arguments:
#   --slug <slug>    Work item slug.
#
# Optional arguments:
#   --kdir <path>    Override the knowledge store directory (testing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Non-zero exit codes are part of this script's contract; callers and the
# regression test branch on them:
#   3 = anchor divergence (partial/none) — a loud, expected non-completion.
#   4 = location-vs-verdict mismatch — corrupted state, never a success report.
EXIT_DIVERGENCE=3
EXIT_MISMATCH=4

SLUG=""
KDIR_OVERRIDE=""
# Optional run-context counts — rendered ONLY on the full/legacy success branch
# so the observable clean close matches the historical Step 7 report. Empty =
# omit that line (graceful). These are values, not prose: the script owns the
# template, so they never appear on the divergence branch.
TASKS_COMPLETED=""
TASKS_TOTAL=""
TIER2_COUNT=""
TIER3_ACCEPTED=""
TIER3_REJECTED=""
FOLLOWUP_TITLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)
      SLUG="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --tasks-completed)
      TASKS_COMPLETED="$2"
      shift 2
      ;;
    --tasks-total)
      TASKS_TOTAL="$2"
      shift 2
      ;;
    --tier2-count)
      TIER2_COUNT="$2"
      shift 2
      ;;
    --tier3-accepted)
      TIER3_ACCEPTED="$2"
      shift 2
      ;;
    --tier3-rejected)
      TIER3_REJECTED="$2"
      shift 2
      ;;
    --followup)
      FOLLOWUP_TITLE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "[implement] Unknown argument: $1" >&2
      echo "Usage: implement-closure-report.sh --slug <slug> [--kdir <path>] [--tasks-completed N] [--tasks-total M] [--tier2-count C] [--tier3-accepted A] [--tier3-rejected R] [--followup <title>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  die "--slug <slug> is required"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  die "knowledge store not found at: $KNOWLEDGE_DIR"
fi

# Archive runs before this report (Step 7 anti-skip ordering), so a full/legacy
# close has already moved _meta.json to _archive/, while a capability-incomplete
# close keeps it active. Resolve from both and remember which location matched —
# location is cross-checked against the verdict below.
ACTIVE_META="$KNOWLEDGE_DIR/_work/$SLUG/_meta.json"
ARCHIVED_META="$KNOWLEDGE_DIR/_work/_archive/$SLUG/_meta.json"

if [[ -f "$ACTIVE_META" ]]; then
  META_PATH="$ACTIVE_META"
  META_LOCATION="active"
elif [[ -f "$ARCHIVED_META" ]]; then
  META_PATH="$ARCHIVED_META"
  META_LOCATION="archived"
else
  die "work item _meta.json not found in _work/$SLUG/ or _work/_archive/$SLUG/"
fi

# Read verdict + the fields the success summary and banner render. The closure
# block is absent on legacy (no-anchor) items, which the success path handles
# as a legacy close.
read_meta() {
  python3 - "$META_PATH" "$META_LOCATION" << 'PYEOF'
import json, sys
path, location = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

anchor = (data.get("intent_anchor") or "").strip()
closure = data.get("closure")
closure = closure if isinstance(closure, dict) else {}

verdict = closure.get("verdict")
cap_incomplete = bool(closure.get("capability_incomplete"))
summary = (closure.get("capability_loop_summary") or "").strip()
divergence = (closure.get("divergence_summary") or "").strip()
residue = (closure.get("residue_followup") or "").strip()

# legacy = anchored items skip the verdict; closure block is absent/empty.
if not anchor and not verdict:
    state = "legacy"
elif verdict == "full":
    state = "full"
elif verdict in ("partial", "none"):
    state = "diverged"
else:
    state = "invalid"

# Cross-check location against verdict. An archived item carrying
# capability_incomplete, or an active item claiming a successful full close, is
# a contradiction the caller must not launder into a success report.
mismatch = ""
if location == "archived" and cap_incomplete:
    mismatch = "archived location carries capability_incomplete=true"
elif location == "active" and verdict == "full":
    mismatch = "active location claims verdict=full (full must archive)"

print("\x1f".join([state, verdict or "", str(cap_incomplete), summary,
                   divergence, residue, mismatch]))
PYEOF
}

IFS=$'\x1f' read -r STATE VERDICT CAP_INCOMPLETE SUMMARY DIVERGENCE RESIDUE MISMATCH < <(read_meta)

if [[ -n "$MISMATCH" ]]; then
  echo "[implement] FATAL: closure location/verdict mismatch — $MISMATCH." >&2
  echo "[implement]        Refusing to emit a close. Re-run Step 6 to record a consistent closure state." >&2
  exit "$EXIT_MISMATCH"
fi

case "$STATE" in
  invalid)
    echo "[implement] FATAL: anchored work item has no valid closure verdict (got '${VERDICT:-<none>}'); cannot emit close." >&2
    echo "[implement]        Re-run Step 6 to record the closure verdict." >&2
    exit "$EXIT_MISMATCH"
    ;;
  full|legacy)
    # Success path — this is the SOLE place the Done summary exists. The
    # observable close matches the historical Step 7 report; run-context counts
    # arrive as flags (values, not prose) and each line is omitted when its flag
    # is absent.
    CLOSURE_LINE="legacy"
    if [[ "$STATE" == "full" ]]; then
      CLOSURE_LINE="full"
    fi
    echo "[implement] Done."
    if [[ -n "$TASKS_COMPLETED" && -n "$TASKS_TOTAL" ]]; then
      echo "Completed: $TASKS_COMPLETED/$TASKS_TOTAL tasks"
    fi
    echo "Closure: $CLOSURE_LINE"
    if [[ -n "$SUMMARY" ]]; then
      echo "Delivered: $SUMMARY"
    fi
    if [[ -n "$TIER2_COUNT" ]]; then
      echo "Tier 2 claims written: $TIER2_COUNT"
    fi
    if [[ -n "$TIER3_ACCEPTED" && -n "$TIER3_REJECTED" ]]; then
      echo "Tier 3 promoted: $TIER3_ACCEPTED (rejected: $TIER3_REJECTED)"
    fi
    echo "Remaining: none — work item archived"
    if [[ -n "$FOLLOWUP_TITLE" ]]; then
      echo "Followup: $FOLLOWUP_TITLE"
    fi
    echo "Consider \`/retro $SLUG\` to evaluate knowledge system effectiveness for this work."
    exit 0
    ;;
  diverged)
    # Divergence path — banner ONLY. No "Done"/"archived"/"complete" text exists
    # on this branch, so the run's terminal output cannot read as a clean close.
    echo "[implement] DIVERGED FROM ANCHOR — capability incomplete ($VERDICT)."
    if [[ -n "$DIVERGENCE" ]]; then
      echo "Divergence: $DIVERGENCE"
    fi
    if [[ "$VERDICT" == "partial" ]]; then
      echo "A load-bearing step the anchor depends on was mocked or deferred."
    else
      echo "The run did not deliver the load-bearing capability the anchor names."
    fi
    if [[ -n "$RESIDUE" ]]; then
      echo "Residue follow-up: $RESIDUE"
    fi
    echo "Work item NOT archived — remains active in _work/$SLUG/ as capability-incomplete."
    exit "$EXIT_DIVERGENCE"
    ;;
  *)
    die "unrecognized closure state '$STATE'"
    ;;
esac
