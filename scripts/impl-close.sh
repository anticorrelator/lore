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
import json, os, sys
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

# Advisor consultations = filed transcript records handled by an advisor
# (handler:agent). Execution-log "Consultations:" header lines include
# "Consultations: none" boilerplate and overcount.
consultations = 0
transcript_path = os.path.join(item_dir, "consultation-transcript.jsonl")
if os.path.isfile(transcript_path):
    with open(transcript_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("handler") == "agent":
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

# --- Per-task class-routing attribution + spend join (before the archive move) -
# Reconstruct, per task, the class-qualified model routing resolves at dispatch,
# for /retro to correlate rework with (judgment_class, worker_model, size), and
# join measured per-task cost mined from execution-log.md's `Spend:` lines onto
# each entry as a nullable `spend` object (absent -> null; one line -> object;
# re-dispatch duplicates -> ordered list). Both tasks.json and execution-log.md
# are read while the item is still in active _work/ — the archive move below
# relocates the dir. Observability-only: a missing/unreadable tasks.json yields
# an empty array, a malformed `Spend:` line degrades that task to null with a
# stderr warning, and neither ever blocks the close.
resolve_class_model() {
  local role="$1" model
  if model=$(resolve_model_for_role "$role" implement 2>/dev/null) && [[ -n "$model" ]]; then
    printf '%s' "$model"
  fi
}
WORKER_STD_MODEL=$(resolve_class_model worker)
WORKER_MECH_MODEL=$(resolve_class_model worker-mechanical)
WORKER_JD_MODEL=$(resolve_class_model worker-judgment-dense)

ATTRIBUTION_JSON=$(_LORE_STD="$WORKER_STD_MODEL" _LORE_MECH="$WORKER_MECH_MODEL" \
  _LORE_JD="$WORKER_JD_MODEL" python3 - "$ITEM_DIR/tasks.json" "$LOG_FILE" <<'PYEOF'
import json, os, re, sys
model_by_class = {
    "mechanical": os.environ.get("_LORE_MECH") or None,
    "judgment-dense": os.environ.get("_LORE_JD") or None,
}
standard_model = os.environ.get("_LORE_STD") or None

# Mine execution-log.md for `Spend: task=<id> key=value …` lines (written by the
# lead at task acceptance, D1 vocabulary flattened). Token fields are ints,
# duration/cost floats, the rest strings; unknown keys are ignored so the schema
# can grow. A line missing `task=` or carrying a non-numeric numeric field is
# malformed: it contributes nothing (the task stays null) and warns.
INT_FIELDS = {"input_tokens", "output_tokens", "cache_read_input_tokens",
              "cache_creation_input_tokens", "reasoning_output_tokens", "total_tokens"}
FLOAT_FIELDS = {"duration_seconds", "cost_usd"}
STR_FIELDS = {"model", "harness", "basis", "effort"}
SPEND_RE = re.compile(r'^\s*[*_]*Spend:[*_]*\s*(.*)$')

spend_by_task = {}  # task_id -> [spend obj, …] in file order (re-dispatch keeps all)
log_path = sys.argv[2] if len(sys.argv) > 2 else ""
if log_path and os.path.isfile(log_path):
    with open(log_path, encoding="utf-8") as f:
        for raw in f:
            m = SPEND_RE.match(raw.rstrip("\n"))
            if not m:
                continue
            body = m.group(1).strip()
            fields, malformed = {}, False
            for tok in body.split():
                if "=" not in tok:
                    malformed = True
                    break
                k, v = tok.split("=", 1)
                if k in INT_FIELDS:
                    try:
                        fields[k] = int(v)
                    except ValueError:
                        malformed = True
                        break
                elif k in FLOAT_FIELDS:
                    try:
                        fields[k] = float(v)
                    except ValueError:
                        malformed = True
                        break
                elif k == "task" or k in STR_FIELDS:
                    fields[k] = v
                # unknown keys ignored (forward-compatible)
            task_id = fields.pop("task", None)
            if malformed or not task_id:
                sys.stderr.write(
                    "[impl] Warning: malformed Spend: line in execution-log.md "
                    "ignored (task spend degrades to null): %s\n" % body)
                continue
            spend_by_task.setdefault(task_id, []).append(fields)

attribution = []
matched = set()
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    data = None
if isinstance(data, dict):
    for phase in data.get("phases", []):
        for task in phase.get("tasks", []):
            jc = task.get("judgment_class")
            # standard/null and any unrecognized value route as plain worker.
            worker_model = model_by_class.get(jc, standard_model)
            estimate = task.get("context_cost_estimate")
            total_chars = estimate.get("total_chars") if isinstance(estimate, dict) else None
            tid = task.get("id")
            spends = spend_by_task.get(tid, [])
            if tid is not None:
                matched.add(tid)
            # Absent -> null; one line -> object; re-dispatch duplicates -> list.
            spend = None if not spends else (spends[0] if len(spends) == 1 else spends)
            attribution.append({
                "task_id": tid,
                "judgment_class": jc,
                "worker_model": worker_model,
                "context_cost_estimate": total_chars,
                "spend": spend,
            })

for tid in spend_by_task:
    if tid not in matched:
        sys.stderr.write(
            "[impl] Warning: Spend: line for task=%s has no matching "
            "task_attribution entry; dropped.\n" % tid)

print(json.dumps(attribution, ensure_ascii=False))
PYEOF
)

# --- Closure-validity gate: validate the archive route or refuse -------------
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
# Carries the per-task class-routing attribution array under task_attribution,
# each entry's `spend` joined from the execution log's Spend: lines.
TELEMETRY_ROW=$(_LORE_ATTRIBUTION="$ATTRIBUTION_JSON" python3 -c '
import json, os, sys
slug, verdict, verb_count, hand_count, tv, sha, ts = sys.argv[1:8]
try:
    attribution = json.loads(os.environ.get("_LORE_ATTRIBUTION") or "[]")
except ValueError:
    attribution = []
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
    "task_attribution": attribution,
    "template_version": tv,
    "captured_at_sha": None if sha == "null" else sha,
    "ts": ts,
}
print(json.dumps(row, ensure_ascii=False))
' "$SLUG" "$VERDICT" "$VERB_MEDIATED_COUNT" "$HAND_RUN_COUNT" "$TEMPLATE_VERSION" "$CAPTURED_SHA" "$(timestamp_iso)")

if ! printf '%s' "$TELEMETRY_ROW" | bash "$SCRIPT_DIR/scorecard-append.sh" >/dev/null; then
  echo "[impl] Warning: telemetry row append failed; close continues (observability-only)." >&2
fi

# --- Conformance aggregate: SAMPLED assembly before the archive move ---------
# The renderer owns closure-conformance.md. It runs after the closure write and
# telemetry while the active item directory still exists. Assembly failure is
# observable but never changes archive behavior or the close exit code.
#
# Sampling (owner constraint, 2026-07-16): the eager render is sampled, not
# universal. A skip loses nothing — `lore work conformance <slug>` reproduces
# the same aggregate on demand — so sampling the auto-render is not a silent
# skip: the decision is announced, and the artifact stays derivable.
#   Always-stratum: a degraded closure verdict (partial/none) always renders.
#   Routine coin:   sha256("conformance:<slug>:<date>") vs
#                   conformance_sampling.render_rate (settings.json;
#                   default 0.25; env LORE_CONFORMANCE_RENDER_RATE overrides
#                   for tests). Same slug + date → same decision, RNG-free.
CONF_RATE="${LORE_CONFORMANCE_RENDER_RATE:-}"
if [[ -z "$CONF_RATE" ]]; then
  CONF_RATE=$(bash "$SCRIPT_DIR/settings.sh" get conformance_sampling.render_rate 2>/dev/null || true)
fi
[[ -n "$CONF_RATE" ]] || CONF_RATE="0.25"
CONF_DECISION=$(python3 - "$SLUG" "$VERDICT" "$CONF_RATE" <<'PYEOF'
import hashlib, sys, datetime
slug, verdict, rate_str = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    rate = max(0.0, min(1.0, float(rate_str)))
except ValueError:
    rate = 0.25
if verdict in ("partial", "none"):
    print("render degraded_closure")
    sys.exit(0)
date = datetime.date.today().isoformat()
digest = hashlib.sha256(f"conformance:{slug}:{date}".encode()).hexdigest()
coin = int(digest[:8], 16) / 0x100000000
print(f"render coin={coin:.4f}" if coin < rate else f"skip coin={coin:.4f}")
PYEOF
)
if [[ "$CONF_DECISION" == render* ]]; then
  echo "[impl] conformance render: ${CONF_DECISION#render } (rate=$CONF_RATE)" >&2
  if ! bash "$SCRIPT_DIR/conformance-render.sh" "$SLUG" >/dev/null; then
    echo "[impl] Warning: conformance aggregate render failed; close continues (observability-only)." >&2
  fi
else
  echo "[impl] conformance render sampled out (${CONF_DECISION#skip } rate=$CONF_RATE); 'lore work conformance $SLUG' renders the same aggregate on demand." >&2
fi

# --- Archive only after durable close evidence has been assembled ------------
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
    ;;
esac

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
  if ! bash "$SCRIPT_DIR/session-terminus.sh" --reason impl-close >/dev/null; then
    echo "[impl] Warning: terminus event append failed; close already complete (completion journal is best-effort)." >&2
  fi
  if ! bash "$SCRIPT_DIR/session-close.sh" --self --reason protocol_terminus >/dev/null; then
    echo "[impl] Warning: session close-request failed; close already complete (session teardown is best-effort)." >&2
  fi
fi

# --- Protocol terminus: retro-sampling gate (best-effort) --------------------
# Same terminus tier as the session close-request above — a post-telemetry
# cross-substrate side effect reached only after the close write sequence and the
# pre-report guard, so every refusal path (all exit earlier) skips it while a
# completed close (report exit 0 full/legacy OR exit 3 partial/none divergence)
# consults it. Decides whether this cycle surfaces a retro now or defers to the
# batch queue, recording the outcome either way. A partial/none verdict trips the
# degraded_closure always-stratum; the per-task routing attribution feeds the
# first-K stratum. NOT gated on LORE_SESSION_INSTANCE (the cadence covers the work
# cycle, so a bare-terminal close gets the same discipline). stdout is discarded
# so it cannot corrupt the report/--json below; the operator prompt/note rides
# stderr. Any failure only warns and never alters this verb's exit code.
if ! bash "$SCRIPT_DIR/retro-sampling-gate.sh" \
    --terminus impl-close --slug "$SLUG" \
    --template-version "$TEMPLATE_VERSION" --verdict "$VERDICT" \
    --task-attribution "$ATTRIBUTION_JSON" >/dev/null; then
  echo "[impl] Warning: retro-sampling gate errored; close already complete (gate is best-effort)." >&2
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
