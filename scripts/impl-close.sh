#!/usr/bin/env bash
# impl-close.sh — Reconcile closure for a work item, write the closure block,
#                 archive on a clean close, and emit the terminal close report.
# Usage: impl-close.sh <ref> --verdict <full|partial|none> --summary <text>
#        [--divergence <text>] [--residue-title <text>] [--residue-anchor <text>]
#        [--check-task <subject>]... [--tier3-accepted <n>] [--tier3-rejected <n>]
#        [--lead-template-version <hash>] [--worker-template-version <hash>]
#        [--advisor-template-version <hash>] [--run-started-at <iso8601>]
#        [--template-version <hash>] [--json]
#
# Absorbs the /implement Steps 6–7 closure envelope. The verdict is required —
# this script never infers it. Per-verdict field contract (R = required,
# - = must be omitted):
#
#   verdict   --summary  --divergence  --residue-title/--residue-anchor
#   full         R            -                    -
#   partial      R            R                    R   (child work item created)
#   none         R            R                    -
#
# Sequence: reconcile plan.md checkboxes from --check-task subjects, heal the
# work structure, hard-block while unchecked tasks remain (mechanical-followup
# gate fires, then refuse), create the partial-residue child, write the
# `closure` block on _meta.json (this script is its sole sanctioned writer),
# write retro-bundle.json, append one execution-log entry (source: impl-verb),
# run the closure-validity gate (legacy/full -> archive and verify the move;
# partial/none -> hold the parent open; anything else -> refuse), append one
# kind=telemetry scorecard row, then invoke implement-closure-report.sh as the
# sole terminal emitter and propagate its exit.
#
# Post-telemetry session side effect: after the close's write sequence has
# completed and the pre-report consistency guard has passed, if
# LORE_SESSION_INSTANCE is set (the close is running inside a TUI-hosted
# session) a self-addressed close-request is enqueued via `session-close.sh
# --self --reason protocol_terminus`. The telemetry row above remains the last
# work-item-substrate write; the close-request targets a different substrate
# (the session) and is best-effort — any failure only warns and never changes
# this verb's exit code, verdict, or telemetry. A refused close (exit 1) emits
# nothing; a partial/none divergence (the report's exit 3) is a COMPLETED close
# whose write sequence ran to a terminal verdict, so it emits the close-request.
#
# Every write composes the file's sanctioned writer: update-plan-checkbox.sh,
# create-work.sh, create-followup.sh, write-execution-log.sh, archive-work.sh,
# scorecard-append.sh. The one write owned here is the `closure` block.
#
# Legacy items (no intent_anchor) accept only --verdict full: no closure block
# is written and the item archives; partial/none are anchor-relative verdicts
# and are refused.
#
# --tier3-accepted defaults to the promoted-commons.jsonl row count;
# --tier3-rejected defaults to 0 (rejected promotions leave no substrate
# trace) — both are display values for the close report.
#
# Exit codes:
#   0  clean close (full/legacy) — Done report emitted, item archived
#   1  validation error / precondition failure / no work-item match
#   2  ambiguous work-item reference
#   3  anchor divergence (partial/none) — banner emitted, parent held open

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VALID_VERDICTS="full|partial|none"

REF=""
VERDICT=""
SUMMARY=""
DIVERGENCE=""
RESIDUE_TITLE=""
RESIDUE_ANCHOR=""
CHECK_TASKS=()
TIER3_ACCEPTED=""
TIER3_REJECTED=""
LEAD_TV=""
WORKER_TV=""
ADVISOR_TV=""
RUN_STARTED_AT=""
TEMPLATE_VERSION=""
JSON_MODE=0
DIVERGENCE_SET=0
RESIDUE_TITLE_SET=0
RESIDUE_ANCHOR_SET=0

usage() {
  cat >&2 <<EOF
Usage: lore impl close <ref> --verdict <full|partial|none> --summary <text>
                       [--divergence <text>] [--residue-title <text>] [--residue-anchor <text>]
                       [--check-task <subject>]... [--tier3-accepted <n>] [--tier3-rejected <n>]
                       [--lead-template-version <hash>] [--worker-template-version <hash>]
                       [--advisor-template-version <hash>] [--run-started-at <iso8601>]
                       [--template-version <hash>] [--json]

Per-verdict fields: --divergence on partial/none; --residue-title and
--residue-anchor on partial. All other combinations are rejected.

Exit codes: 0 clean close (archived), 1 error/refused, 2 ambiguous reference,
            3 anchor divergence (parent held open)
EOF
}

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[impl] Error: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verdict)
      VERDICT="${2:-}"
      shift 2
      ;;
    --verdict=*)
      VERDICT="${1#--verdict=}"
      shift
      ;;
    --summary)
      SUMMARY="${2:-}"
      shift 2
      ;;
    --summary=*)
      SUMMARY="${1#--summary=}"
      shift
      ;;
    --divergence)
      DIVERGENCE="${2:-}"
      DIVERGENCE_SET=1
      shift 2
      ;;
    --divergence=*)
      DIVERGENCE="${1#--divergence=}"
      DIVERGENCE_SET=1
      shift
      ;;
    --residue-title)
      RESIDUE_TITLE="${2:-}"
      RESIDUE_TITLE_SET=1
      shift 2
      ;;
    --residue-title=*)
      RESIDUE_TITLE="${1#--residue-title=}"
      RESIDUE_TITLE_SET=1
      shift
      ;;
    --residue-anchor)
      RESIDUE_ANCHOR="${2:-}"
      RESIDUE_ANCHOR_SET=1
      shift 2
      ;;
    --residue-anchor=*)
      RESIDUE_ANCHOR="${1#--residue-anchor=}"
      RESIDUE_ANCHOR_SET=1
      shift
      ;;
    --check-task)
      CHECK_TASKS+=("${2:-}")
      shift 2
      ;;
    --check-task=*)
      CHECK_TASKS+=("${1#--check-task=}")
      shift
      ;;
    --tier3-accepted)
      TIER3_ACCEPTED="${2:-}"
      shift 2
      ;;
    --tier3-accepted=*)
      TIER3_ACCEPTED="${1#--tier3-accepted=}"
      shift
      ;;
    --tier3-rejected)
      TIER3_REJECTED="${2:-}"
      shift 2
      ;;
    --tier3-rejected=*)
      TIER3_REJECTED="${1#--tier3-rejected=}"
      shift
      ;;
    --lead-template-version)
      LEAD_TV="${2:-}"
      shift 2
      ;;
    --lead-template-version=*)
      LEAD_TV="${1#--lead-template-version=}"
      shift
      ;;
    --worker-template-version)
      WORKER_TV="${2:-}"
      shift 2
      ;;
    --worker-template-version=*)
      WORKER_TV="${1#--worker-template-version=}"
      shift
      ;;
    --advisor-template-version)
      ADVISOR_TV="${2:-}"
      shift 2
      ;;
    --advisor-template-version=*)
      ADVISOR_TV="${1#--advisor-template-version=}"
      shift
      ;;
    --run-started-at)
      RUN_STARTED_AT="${2:-}"
      shift 2
      ;;
    --run-started-at=*)
      RUN_STARTED_AT="${1#--run-started-at=}"
      shift
      ;;
    --template-version)
      TEMPLATE_VERSION="${2:-}"
      shift 2
      ;;
    --template-version=*)
      TEMPLATE_VERSION="${1#--template-version=}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown flag: $1"
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        fail "Unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  usage
  fail "Missing required argument: <ref>"
fi

if [[ -z "$VERDICT" ]]; then
  fail "--verdict is required ($VALID_VERDICTS)"
fi

case "$VERDICT" in
  full|partial|none) ;;
  *)
    fail "--verdict must be one of: $VALID_VERDICTS (got '$VERDICT')"
    ;;
esac

if [[ -z "$SUMMARY" ]]; then
  fail "--summary is required (one line naming what shipped, or what was attempted on 'none')"
fi

# --- Per-verdict field-presence contract -----------------------------------
case "$VERDICT" in
  full)
    if [[ $DIVERGENCE_SET -eq 1 ]]; then
      fail "verdict 'full' does not take --divergence"
    fi
    if [[ $RESIDUE_TITLE_SET -eq 1 || $RESIDUE_ANCHOR_SET -eq 1 ]]; then
      fail "verdict 'full' does not take --residue-title/--residue-anchor"
    fi
    ;;
  partial)
    if [[ $DIVERGENCE_SET -eq 0 || -z "$DIVERGENCE" ]]; then
      fail "verdict 'partial' requires --divergence <text> (what was mocked or deferred)"
    fi
    if [[ $RESIDUE_TITLE_SET -eq 0 || -z "$RESIDUE_TITLE" ]]; then
      fail "verdict 'partial' requires --residue-title <text> for the residue child work item"
    fi
    if [[ $RESIDUE_ANCHOR_SET -eq 0 || -z "$RESIDUE_ANCHOR" ]]; then
      fail "verdict 'partial' requires --residue-anchor <text> for the residue child work item"
    fi
    ;;
  none)
    if [[ $DIVERGENCE_SET -eq 0 || -z "$DIVERGENCE" ]]; then
      fail "verdict 'none' requires --divergence <text> (what was mocked or deferred)"
    fi
    if [[ $RESIDUE_TITLE_SET -eq 1 || $RESIDUE_ANCHOR_SET -eq 1 ]]; then
      fail "verdict 'none' does not take --residue-title/--residue-anchor (no residue child on 'none')"
    fi
    ;;
esac

# --- Resolve the work-item reference (tri-state exit passthrough) ----------
set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF")
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"error": "could not resolve work-item reference (exit %s)"}\n' "$RESOLVE_RC"
  fi
  exit "$RESOLVE_RC"
fi

SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')

if [[ "$ARCHIVED" == "true" ]]; then
  fail "work item '$SLUG' is already archived — closure applies to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
META="$ITEM_DIR/_meta.json"
PLAN_FILE="$ITEM_DIR/plan.md"
LOG_FILE="$ITEM_DIR/execution-log.md"

if [[ ! -f "$META" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi

TITLE=$(json_field "title" "$META")

INTENT_ANCHOR=$(python3 -c 'import json,sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
print((data.get("intent_anchor") or "").strip())
' "$META")

# Anchor verdicts are relative to intent_anchor; a legacy item has nothing to
# diverge from, so only the archiving verdict is meaningful.
if [[ -z "$INTENT_ANCHOR" && "$VERDICT" != "full" ]]; then
  fail "work item '$SLUG' has no intent_anchor — verdict '$VERDICT' is anchor-relative; close legacy items with --verdict full (archives without a closure block)"
fi

# --- Provenance: stamp the producing template's version at emission ---------
# Default derives from the implement skill template; --template-version overrides.
if [[ -z "$TEMPLATE_VERSION" ]]; then
  REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
  SKILL_TEMPLATE="$REPO_DIR/skills/implement/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi
if [[ -z "$TEMPLATE_VERSION" ]]; then
  TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "${BASH_SOURCE[0]}")
fi

# --- Reconcile plan.md from the task system ---------------------------------
# The caller passes one --check-task per task completed this run; plan.md is
# the durable completion record the archive precondition below counts against.
if [[ ${#CHECK_TASKS[@]} -gt 0 ]]; then
  for subject in "${CHECK_TASKS[@]}"; do
    if [[ -z "$subject" ]]; then
      fail "--check-task requires a non-empty task subject"
    fi
    if ! bash "$SCRIPT_DIR/update-plan-checkbox.sh" "$SLUG" "$subject" >/dev/null; then
      fail "plan reconcile failed for --check-task '$subject' — fix the subject (or plan.md) and re-run close"
    fi
  done
fi

bash "$SCRIPT_DIR/heal-work.sh" >/dev/null 2>&1 \
  || echo "[impl] Warning: heal-work.sh reported issues; close continues." >&2

# --- Blocker scan (mechanical-followup gate, signal 2) -----------------------
BLOCKERS=""
if [[ -f "$LOG_FILE" ]]; then
  BLOCKERS=$(python3 - "$LOG_FILE" <<'PYEOF'
import re, sys
blockers = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^\s*[*_]*Blockers:[*_]*\s*(.*)$', line.strip(), re.IGNORECASE)
        if m:
            value = m.group(1).strip().strip("*_ ").strip()
            if value and value.lower() != "none":
                blockers.append(value)
for b in blockers:
    print(b)
PYEOF
)
fi

# --- Task-system archive precondition (REMAINING_COUNT) ---------------------
REMAINING_COUNT=0
TASKS_COMPLETED=0
UNCHECKED_LIST=""
if [[ -f "$PLAN_FILE" ]]; then
  REMAINING_COUNT=$(grep -c '^[[:space:]]*- \[ \]' "$PLAN_FILE" || true)
  TASKS_COMPLETED=$(grep -c '^[[:space:]]*- \[x\]' "$PLAN_FILE" || true)
  UNCHECKED_LIST=$(grep '^[[:space:]]*- \[ \]' "$PLAN_FILE" | sed 's/^[[:space:]]*//' || true)
fi
TASKS_TOTAL=$((TASKS_COMPLETED + REMAINING_COUNT))

create_followup() {
  # $1: one-line summary; $2: checklist body (may be empty)
  local content="$1"
  if [[ -n "$2" ]]; then
    content=$(printf '%s\n\n%s' "$1" "$2")
  fi
  bash "$SCRIPT_DIR/create-followup.sh" \
    --title "Deferred work: $TITLE" \
    --source "implement" \
    --attachments "[{\"type\":\"work_item\",\"slug\":\"$SLUG\"}]" \
    --suggested-actions '[{"type":"create_work_item"}]' \
    --template-version "$TEMPLATE_VERSION" \
    --content "$content" >/dev/null
}

FOLLOWUP_TITLE=""
if [[ "$REMAINING_COUNT" -gt 0 ]]; then
  # Run order is load-bearing: with tasks remaining, the mechanical gate fires
  # and the close stops — no verdict is recorded, no closure block is written.
  BODY="Close refused with $REMAINING_COUNT task(s) unchecked in plan.md."
  CHECKLIST="$UNCHECKED_LIST"
  if [[ -n "$BLOCKERS" ]]; then
    CHECKLIST=$(printf '%s\n\nBlockers reported in execution-log.md:\n%s' "$UNCHECKED_LIST" "$BLOCKERS")
  fi
  create_followup "$BODY" "$CHECKLIST" \
    || echo "[impl] Warning: mechanical-followup creation failed." >&2
  {
    echo "[impl] Error: cannot close '$SLUG' — $REMAINING_COUNT task(s) still unchecked in plan.md:"
    printf '%s\n' "$UNCHECKED_LIST" | sed 's/^/[impl]   /'
    echo "[impl] No closure verdict recorded; work item NOT archived. A 'Deferred work' followup was filed."
    echo "[impl] Complete or re-plan the remaining tasks (pass --check-task for tasks finished this run), then re-run close."
  } >&2
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"error": "close refused: %s task(s) unchecked in plan.md", "slug": "%s"}\n' "$REMAINING_COUNT" "$SLUG"
  fi
  exit 1
fi

if [[ -n "$BLOCKERS" ]]; then
  if create_followup "Tasks complete but execution-log.md carries unresolved Blockers entries." "$BLOCKERS"; then
    FOLLOWUP_TITLE="Deferred work: $TITLE"
  else
    echo "[impl] Warning: mechanical-followup creation failed." >&2
  fi
fi

# --- Partial residue: create the child BEFORE writing the parent's closure ---
CHILD_SLUG=""
if [[ "$VERDICT" == "partial" ]]; then
  set +e
  CHILD_OUTPUT=$(bash "$SCRIPT_DIR/create-work.sh" --json \
    --title "$RESIDUE_TITLE" \
    --intent-anchor "$RESIDUE_ANCHOR" \
    --related-work "$SLUG" 2>&1)
  CHILD_RC=$?
  set -e
  if [[ $CHILD_RC -ne 0 ]]; then
    echo "$CHILD_OUTPUT" >&2
    fail "child work item creation failed for the partial-residue path — parent closure block NOT written; re-attempt after diagnosing"
  fi
  CHILD_SLUG=$(printf '%s' "$CHILD_OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])' 2>/dev/null || true)
  if [[ -z "$CHILD_SLUG" ]]; then
    fail "could not read child slug from create-work.sh output — parent closure block NOT written"
  fi
fi

# --- Closure block: this script is the sole sanctioned writer ----------------
# Schema is the fixed contract implement-closure-report.sh and the work-index
# projector code against — field names must not change.
if [[ -n "$INTENT_ANCHOR" ]]; then
  python3 - "$META" "$VERDICT" "$SUMMARY" "$INTENT_ANCHOR" "$DIVERGENCE" "$CHILD_SLUG" "$(timestamp_iso)" <<'PYEOF'
import json, sys
path, verdict, summary, anchor, divergence, residue, ts = sys.argv[1:8]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["closure"] = {
    "verdict": verdict,
    "capability_incomplete": verdict in ("partial", "none"),
    "capability_loop_summary": summary,
    "divergence_summary": divergence or None,
    "residue_followup": residue or None,
    "verdict_at": ts,
    "intent_anchor_at_close": anchor,
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
fi

if [[ "$VERDICT" == "partial" ]]; then
  printf '\n## %s\n**Closure (partial):** see follow-up `%s`. Delivered subset: %s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M")" "$CHILD_SLUG" "$SUMMARY" \
    >> "$ITEM_DIR/notes.md"
fi

# --- Retro-prep bundle (snapshot semantics: overwrite per run) ----------------
CAPTURED_SHA=$(captured_at_sha)
_LORE_BLOCKERS="$BLOCKERS" python3 - "$ITEM_DIR" "$SLUG" "$TASKS_COMPLETED" \
  "$LEAD_TV" "$WORKER_TV" "$ADVISOR_TV" "$CAPTURED_SHA" "$RUN_STARTED_AT" <<'PYEOF'
import json, os, re, sys
item_dir, slug, tasks_completed, lead_tv, worker_tv, advisor_tv, sha, started = sys.argv[1:9]

tier2_ids = []
claims_path = os.path.join(item_dir, "task-claims.jsonl")
if os.path.isfile(claims_path):
    with open(claims_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            cid = row.get("claim_id")
            if cid:
                tier2_ids.append(cid)

tier3_ids = []
promoted_path = os.path.join(item_dir, "promoted-commons.jsonl")
if os.path.isfile(promoted_path):
    with open(promoted_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            entry = row.get("entry_path") or row.get("claim_id")
            if entry:
                tier3_ids.append(entry)

consultations = 0
log_path = os.path.join(item_dir, "execution-log.md")
if os.path.isfile(log_path):
    with open(log_path, encoding="utf-8") as f:
        for line in f:
            if re.match(r'^\s*[*_]*(Advisor consultations|Consultations):', line.strip()):
                consultations += 1

blockers = [b for b in os.environ.get("_LORE_BLOCKERS", "").splitlines() if b.strip()]

bundle = {
    "work_item": slug,
    "tasks_completed": int(tasks_completed),
    "tier2_claim_ids": tier2_ids,
    "tier3_promoted_ids": tier3_ids,
    "advisor_consultations_count": consultations,
    "blockers": blockers,
    "template_versions": {
        "lead": lead_tv or None,
        "worker": worker_tv or None,
        "advisor": advisor_tv or None,
    },
    "captured_at_sha": None if sha == "null" else sha,
    "run_started_at": started or None,
}
with open(os.path.join(item_dir, "retro-bundle.json"), "w", encoding="utf-8") as f:
    json.dump(bundle, f, indent=2)
    f.write("\n")
PYEOF

# --- Execution-log entry (source: impl-verb) ---------------------------------
json_string() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

DIVERGENCE_JSON="None"
RESIDUE_LINE="None"
FOLLOWUP_LINE="None"
[[ -n "$DIVERGENCE" ]] && DIVERGENCE_JSON=$(json_string "$DIVERGENCE")
[[ -n "$CHILD_SLUG" ]] && RESIDUE_LINE="$CHILD_SLUG"
[[ -n "$FOLLOWUP_TITLE" ]] && FOLLOWUP_LINE=$(json_string "$FOLLOWUP_TITLE")

BODY=$(printf 'Closure verdict: %s\nCapability loop summary: %s\nDivergence summary: %s\nResidue followup: %s\nMechanical followup: %s' \
  "$VERDICT" "$(json_string "$SUMMARY")" "$DIVERGENCE_JSON" "$RESIDUE_LINE" "$FOLLOWUP_LINE")

if ! printf '%s\n' "$BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" \
    --slug "$SLUG" --source impl-verb --template-version "$TEMPLATE_VERSION" >/dev/null; then
  fail "execution-log append failed for '$SLUG'"
fi

# --- Bookkeeping attribution counts (read before the archive move) -----------
read -r VERB_MEDIATED_COUNT HAND_RUN_COUNT < <(python3 - "$LOG_FILE" <<'PYEOF'
import re, sys
verb = hand = 0
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^## .*\| source: (\S+)', line)
        if m:
            if m.group(1) == "impl-verb":
                verb += 1
            else:
                hand += 1
print(verb, hand)
PYEOF
)

# --- Tier 2/3 display counts for the close report ----------------------------
TIER2_COUNT=0
if [[ -f "$ITEM_DIR/task-claims.jsonl" ]]; then
  TIER2_COUNT=$(grep -c '[^[:space:]]' "$ITEM_DIR/task-claims.jsonl" || true)
fi
if [[ -z "$TIER3_ACCEPTED" ]]; then
  TIER3_ACCEPTED=0
  if [[ -f "$ITEM_DIR/promoted-commons.jsonl" ]]; then
    TIER3_ACCEPTED=$(grep -c '[^[:space:]]' "$ITEM_DIR/promoted-commons.jsonl" || true)
  fi
fi
if [[ -z "$TIER3_REJECTED" ]]; then
  TIER3_REJECTED=0
fi

# --- Closure-validity gate: archive, hold open, or refuse --------------------
CLOSURE_VALID=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
anchor = (data.get("intent_anchor") or "").strip()
if not anchor:
    print("legacy")
    sys.exit(0)
closure = data.get("closure")
if not isinstance(closure, dict):
    print("missing")
    sys.exit(0)
verdict = closure.get("verdict")
summary = (closure.get("capability_loop_summary") or "").strip()
anchor_at_close = (closure.get("intent_anchor_at_close") or "").strip()
cap_incomplete = bool(closure.get("capability_incomplete"))
divergence = (closure.get("divergence_summary") or "").strip()
residue = closure.get("residue_followup")
if verdict not in ("full", "partial", "none"):
    print("bad_verdict")
    sys.exit(0)
if not summary:
    print("missing_summary")
    sys.exit(0)
if not anchor_at_close:
    print("missing_anchor_at_close")
    sys.exit(0)
if verdict in ("partial", "none"):
    if not cap_incomplete or not divergence:
        print("bad_incomplete_row")
        sys.exit(0)
    if verdict == "partial" and not (isinstance(residue, str) and residue.strip()):
        print("missing_residue_for_partial")
        sys.exit(0)
    print("capability_incomplete")
    sys.exit(0)
print("ok")
' "$META")

WAS_ARCHIVED=false
case "$CLOSURE_VALID" in
  legacy|ok)
    if ! bash "$SCRIPT_DIR/archive-work.sh" "$SLUG" >/dev/null; then
      fail "archive-work.sh failed for '$SLUG' — diagnose and re-run close"
    fi
    if [[ ! -d "$KNOWLEDGE_DIR/_work/_archive/$SLUG" ]]; then
      fail "FATAL: archive did not move work item to _archive/"
    fi
    if [[ -d "$ITEM_DIR" ]]; then
      fail "FATAL: archive left work item in active _work/ path"
    fi
    WAS_ARCHIVED=true
    ;;
  capability_incomplete)
    if [[ ! -d "$ITEM_DIR" ]]; then
      fail "FATAL: capability-incomplete close but work item not in active _work/"
    fi
    ;;
  *)
    echo "[impl] FATAL: anchored work item lacks a valid _meta.json.closure block ($CLOSURE_VALID); refusing to archive." >&2
    echo "[impl]        Re-run close to record a consistent closure verdict before archive." >&2
    if [[ $JSON_MODE -eq 1 ]]; then
      printf '{"error": "invalid closure block: %s", "slug": "%s"}\n' "$CLOSURE_VALID" "$SLUG"
    fi
    exit 1
    ;;
esac

# --- Per-cycle telemetry row (observability-only; never kind=scored) ----------
TELEMETRY_ROW=$(python3 -c '
import json, sys
slug, verdict, verb_count, hand_count, tv, sha, ts = sys.argv[1:8]
row = {
    "schema_version": "1",
    "kind": "telemetry",
    "tier": "telemetry",
    "calibration_state": "pre-calibration",
    "event_type": "impl-close",
    "metric": "impl_close_bookkeeping",
    "work_item": slug,
    "verdict": verdict,
    "verb_mediated_count": int(verb_count),
    "hand_run_count": int(hand_count),
    "template_version": tv,
    "captured_at_sha": None if sha == "null" else sha,
    "ts": ts,
}
print(json.dumps(row, ensure_ascii=False))
' "$SLUG" "$VERDICT" "$VERB_MEDIATED_COUNT" "$HAND_RUN_COUNT" "$TEMPLATE_VERSION" "$CAPTURED_SHA" "$(timestamp_iso)")

if ! printf '%s' "$TELEMETRY_ROW" | bash "$SCRIPT_DIR/scorecard-append.sh" >/dev/null; then
  echo "[impl] Warning: telemetry row append failed; close continues (observability-only)." >&2
fi

# --- Pre-report guard: a completed-but-active parent must carry a valid -------
# capability_incomplete closure row (the expected divergence state); anything
# else is a stuck close the report must not launder.
if [[ -d "$ITEM_DIR" ]]; then
  PRE_REPORT=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    anchor = (data.get("intent_anchor") or "").strip()
    closure = data.get("closure")
    closure = closure if isinstance(closure, dict) else {}
    verdict = closure.get("verdict")
    cap_incomplete = bool(closure.get("capability_incomplete"))
    divergence = (closure.get("divergence_summary") or "").strip()
    if not anchor:
        print("legacy_unarchived")
    elif verdict in ("partial", "none") and cap_incomplete and divergence:
        print("diverged")
    elif not closure:
        print("anchored_no_closure")
    else:
        print("anchored_invalid_closure")
except Exception:
    print("other")
' "$META")
  case "$PRE_REPORT" in
    diverged)
      ;;
    anchored_no_closure|anchored_invalid_closure)
      fail "FATAL: tasks complete but anchored work item has no valid closure row. Re-run close to record the verdict."
      ;;
    *)
      fail "FATAL: all tasks completed but work item not archived. Diagnose the archive step before the close report."
      ;;
  esac
fi

# --- Protocol terminus: self-addressed session close-request (best-effort) -----
# Post-telemetry side effect on the session substrate, reached only after the
# close write sequence has completed and the pre-report guard has passed — so
# every refusal path (all exit before this point) emits nothing, while a
# completed close reaches here whether the report will exit 0 (full/legacy) or 3
# (partial/none divergence). Fires only inside a TUI-hosted session
# (LORE_SESSION_INSTANCE set); a bare-terminal close silently no-ops. The `if !`
# guard keeps a non-zero child from tripping set -e; stdout is discarded so it
# cannot corrupt the --json object emitted below. Any failure only warns.
if [[ -n "${LORE_SESSION_INSTANCE:-}" ]]; then
  if ! bash "$SCRIPT_DIR/session-close.sh" --self --reason protocol_terminus >/dev/null; then
    echo "[impl] Warning: session close-request failed; close already complete (session teardown is best-effort)." >&2
  fi
fi

# --- Terminal close: the closure-report script is the sole emitter ------------
CLOSURE_FLAGS=(--tasks-completed "$TASKS_COMPLETED" --tasks-total "$TASKS_TOTAL"
               --tier2-count "$TIER2_COUNT"
               --tier3-accepted "$TIER3_ACCEPTED" --tier3-rejected "$TIER3_REJECTED")
if [[ -n "$FOLLOWUP_TITLE" ]]; then
  CLOSURE_FLAGS+=(--followup "$FOLLOWUP_TITLE")
fi

set +e
REPORT_OUTPUT=$(bash "$SCRIPT_DIR/implement-closure-report.sh" --slug "$SLUG" "${CLOSURE_FLAGS[@]}")
REPORT_RC=$?
set -e

if [[ $JSON_MODE -eq 1 ]]; then
  _LORE_REPORT="$REPORT_OUTPUT" python3 -c '
import json, os, sys
slug, verdict, archived, child, followup, rc = sys.argv[1:7]
print(json.dumps({
    "slug": slug,
    "verdict": verdict,
    "archived": archived == "true",
    "residue_followup": child or None,
    "mechanical_followup": followup or None,
    "report_exit": int(rc),
    "report": os.environ.get("_LORE_REPORT", ""),
}, ensure_ascii=False))
' "$SLUG" "$VERDICT" "$WAS_ARCHIVED" "$CHILD_SLUG" "$FOLLOWUP_TITLE" "$REPORT_RC"
  exit "$REPORT_RC"
fi

printf '%s\n' "$REPORT_OUTPUT"
exit "$REPORT_RC"
