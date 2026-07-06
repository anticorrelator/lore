#!/usr/bin/env bash
# spec-finalize.sh — Run /spec's terminal gate sequence for a work item and
#                    emit one adoption-telemetry scorecard row.
# Usage: spec-finalize.sh <ref> [--template-version <hash>] [--json]
#
# Sequence (order matters — the telemetry row is the last work-item-substrate write):
#   1. resolve <ref>             resolve-work-ref.sh tri-state passthrough
#   2. backlink verify           verify-plan-backlinks.sh --fix; script failure
#                                refuses; unresolved backlinks warn and continue
#   3. intent-anchor gate        verify-plan-intent-anchor.sh; refuses on any
#                                non-zero; an absent anchor reports as skipped,
#                                never as passed
#   4. regen tasks               regen-tasks.sh --quiet; failure refuses
#   5. heal                      heal-work.sh; warn-and-continue
#   6. emission-contract assert  every retrieval_directive in tasks.json carries
#                                non-empty seeds AND non-empty scale_set (v2:
#                                per topic; legacy flat: top level); failure
#                                refuses naming the phase
#   6b. judgment-class gate      every task line in plan.md carries a
#                                [class: mechanical|standard|judgment-dense]
#                                marker AND every >1-task phase carries a
#                                **Split rationale:** block; failure refuses
#                                naming the offending line or phase. Emits the
#                                split_rationale + class_distribution recorded
#                                in the step-9 telemetry row
#   7. execution-log atom        write-execution-log.sh --source spec-verb
#   8. attribution counts        parse execution-log.md '## ... | source: <tok>'
#                                headers; spec-verb counts as verb-mediated,
#                                every other token as hand-run
#   9. telemetry row             scorecard-append.sh; append failure warns and
#                                the finalize still exits 0
#  10. session close-request     post-telemetry, best-effort side effect on the
#                                session substrate: if LORE_SESSION_INSTANCE is
#                                set (the finalize is running inside a TUI-hosted
#                                session), session-close.sh --self --reason
#                                protocol_terminus; unset = silent no-op
#
# Cross-substrate ordering: the telemetry row (step 9) is the last write to the
# work item's own substrate; step 10 targets a different substrate (the session)
# and is best-effort by design. A session-substrate failure can never cost the
# work item its telemetry row, and never alters this verb's exit code or refusal
# semantics — it only warns.
#
# A refused finalize emits no telemetry row, no spec-verb execution-log atom,
# and no session close-request. Earlier sanctioned mutations may have occurred
# before the refusal
# (backlink --fix corrections; a regenerated tasks.json when the failure is
# at the contract assert) — the report names them.
#
# The counts are family-relative bookkeeping attribution — which fraction of
# this work item's bookkeeping atoms routed through spec verbs — not a count
# of human actions. The metric measures verb ADOPTION, never lived trust;
# do not cite it as trust evidence.
#
# Each run appends a fresh point-event row. Re-finalizing after a plan fix is
# expected; rollups must key on latest-per-work-item or count events, never
# assume one row per item.
#
# Every write composes the target file's sanctioned writer:
# verify-plan-backlinks.sh --fix (plan.md), regen-tasks.sh (tasks.json),
# write-execution-log.sh (execution-log.md), scorecard-append.sh (rows.jsonl).
#
# Exit codes:
#   0  finalize passed — report emitted, telemetry appended (append failure warns)
#   1  validation/precondition error (no match, archived item, backlink script
#      failure, regen failure, contract-assert failure, atom write failure)
#   2  ambiguous work-item reference
#   3  intent-anchor gate failure (verifier code 2/3/4 surfaced in diagnostics,
#      not in the process exit code)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
TEMPLATE_VERSION=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: lore spec finalize <ref> [--template-version <hash>] [--json]

Runs the /spec terminal gate sequence (backlink verify, intent-anchor gate,
regen-tasks, heal, emission-contract asserts), stamps one spec-verb
execution-log atom, and appends one adoption-telemetry scorecard row.

Exit codes: 0 finalized, 1 error/refused, 2 ambiguous reference,
            3 intent-anchor gate failure
EOF
}

# --- Gate state (for the report; every gate outcome is named, skips included)
BACKLINKS_STATUS="not-run"
BACKLINKS_JSON="null"
ANCHOR_STATUS="not-run"
ANCHOR_VERIFIER_EXIT="null"
ANCHOR_REASON=""
REGEN_STATUS="not-run"
REGEN_SUMMARY=""
HEAL_STATUS="not-run"
CONTRACT_STATUS="not-run"
CONTRACT_DETAIL=""
CLASS_GATE_STATUS="not-run"
CLASS_GATE_DETAIL=""
# Telemetry payloads computed by the class-annotation gate (step 6b). Defaults
# stand in only if the gate never runs — every success path overwrites this.
CLASS_GATE_PAYLOAD='{"split_rationale": {}, "class_distribution": {"mechanical": 0, "standard": 0, "judgment-dense": 0}}'
TELEMETRY_STATUS="not-run"
VERB_MEDIATED_COUNT=0
HAND_RUN_COUNT=0

json_string() {
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

# Emits the --json terminal (gate states as far as they ran) and exits.
# lib.sh json_error hard-exits 1, so the exit-2/exit-3 paths need this
# manual emission path.
emit_json_and_exit() {
  local exit_code="$1" error_msg="$2"
  if [[ $JSON_MODE -eq 1 ]]; then
    local error_field="null"
    [[ -n "$error_msg" ]] && error_field=$(json_string "$error_msg")
    python3 - "$SLUG" "$error_field" \
      "$BACKLINKS_STATUS" "$BACKLINKS_JSON" \
      "$ANCHOR_STATUS" "$ANCHOR_VERIFIER_EXIT" "$(json_string "$ANCHOR_REASON")" \
      "$REGEN_STATUS" "$(json_string "$REGEN_SUMMARY")" \
      "$HEAL_STATUS" \
      "$CONTRACT_STATUS" "$(json_string "$CONTRACT_DETAIL")" \
      "$TELEMETRY_STATUS" "$VERB_MEDIATED_COUNT" "$HAND_RUN_COUNT" <<'PYEOF'
import json, sys
(slug, error_field, bl_status, bl_json, an_status, an_exit, an_reason,
 rg_status, rg_summary, heal_status, ct_status, ct_detail,
 tm_status, verb_count, hand_count) = sys.argv[1:16]

def loads_or(value, fallback=None):
    try:
        return json.loads(value)
    except ValueError:
        return fallback

result = {
    "slug": slug or None,
    "error": loads_or(error_field),
    "backlinks": {"status": bl_status, "result": loads_or(bl_json)},
    "anchor": {
        "status": an_status,
        "verifier_exit": loads_or(an_exit),
        "reason": loads_or(an_reason, ""),
    },
    "regen_tasks": {"status": rg_status, "summary": loads_or(rg_summary, "")},
    "heal": {"status": heal_status},
    "contract_asserts": {"status": ct_status, "detail": loads_or(ct_detail, "")},
    "telemetry": {
        "status": tm_status,
        "event_type": "spec-finalize",
        "metric": "spec_finalize_bookkeeping",
    },
    "verb_mediated_count": int(verb_count),
    "hand_run_count": int(hand_count),
}
print(json.dumps(result, ensure_ascii=False))
PYEOF
  fi
  exit "$exit_code"
}

fail() {
  echo "[spec] Error: $1" >&2
  emit_json_and_exit 1 "$1"
}

SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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

# --- 1. Resolve the work-item reference (tri-state exit passthrough) --------
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
  fail "work item '$SLUG' is archived — finalize applies to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
META="$ITEM_DIR/_meta.json"
PLAN_FILE="$ITEM_DIR/plan.md"
TASKS_FILE="$ITEM_DIR/tasks.json"
LOG_FILE="$ITEM_DIR/execution-log.md"

if [[ ! -f "$META" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi
if [[ ! -f "$PLAN_FILE" ]]; then
  fail "no plan.md for work item '$SLUG' — run /spec to produce a plan before finalizing"
fi

# --- Provenance: stamp the producing template's version ----------------------
# Default derives from the spec skill template; --template-version overrides.
if [[ -z "$TEMPLATE_VERSION" ]]; then
  REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
  SKILL_TEMPLATE="$REPO_DIR/skills/spec/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi
if [[ -z "$TEMPLATE_VERSION" ]]; then
  TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "${BASH_SOURCE[0]}")
fi

# --- 2. Backlink verify (script failure refuses; unresolved warns) ----------
set +e
BACKLINKS_OUTPUT=$(bash "$SCRIPT_DIR/verify-plan-backlinks.sh" "$PLAN_FILE" "$KNOWLEDGE_DIR" --fix 2>&1)
BACKLINKS_RC=$?
set -e
if [[ $BACKLINKS_RC -ne 0 ]]; then
  BACKLINKS_STATUS="failed"
  echo "$BACKLINKS_OUTPUT" >&2
  fail "backlink verifier failed (exit $BACKLINKS_RC) for '$SLUG'"
fi

BACKLINKS_JSON=$(printf '%s\n' "$BACKLINKS_OUTPUT" | python3 -c '
import json, sys
text = sys.stdin.read()
start = text.find("{")
if start < 0:
    print("null")
    sys.exit(0)
try:
    print(json.dumps(json.loads(text[start:])))
except ValueError:
    print("null")
')
UNRESOLVED_COUNT=$(printf '%s' "$BACKLINKS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(len(data.get("unresolved") or []) if isinstance(data, dict) else 0)
')
if [[ "$UNRESOLVED_COUNT" -gt 0 ]]; then
  BACKLINKS_STATUS="warned"
  echo "[spec] Warning: $UNRESOLVED_COUNT unresolved backlink(s) in plan.md; finalize continues (backlinks are advisory)." >&2
else
  BACKLINKS_STATUS="passed"
fi

# --- 3. Intent-anchor gate (hard gate; absent anchor is a legible skip) ------
ANCHOR_PRESENT=$(python3 -c 'import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
anchor = data.get("intent_anchor")
print("yes" if isinstance(anchor, str) and anchor.strip() else "no")
' "$META")

set +e
ANCHOR_STDERR=$(bash "$SCRIPT_DIR/verify-plan-intent-anchor.sh" "$SLUG" 2>&1 >/dev/null)
ANCHOR_RC=$?
set -e
ANCHOR_VERIFIER_EXIT="$ANCHOR_RC"

if [[ $ANCHOR_RC -eq 0 ]]; then
  if [[ "$ANCHOR_PRESENT" == "yes" ]]; then
    ANCHOR_STATUS="passed"
  else
    ANCHOR_STATUS="skipped"
    ANCHOR_REASON="$ANCHOR_STDERR"
  fi
elif [[ $ANCHOR_RC -eq 1 ]]; then
  ANCHOR_STATUS="failed"
  ANCHOR_REASON="$ANCHOR_STDERR"
  echo "$ANCHOR_STDERR" >&2
  fail "intent-anchor verifier usage error (exit 1) for '$SLUG'"
else
  ANCHOR_STATUS="failed"
  ANCHOR_REASON="$ANCHOR_STDERR"
  case "$ANCHOR_RC" in
    2) CODE_MEANING="2 = Intent Anchor section missing from plan.md" ;;
    3) CODE_MEANING="3 = anchor body diverges from _meta.json.intent_anchor" ;;
    4) CODE_MEANING="4 = Scope delta line missing inside the section" ;;
    *) CODE_MEANING="$ANCHOR_RC = undocumented verifier exit" ;;
  esac
  {
    echo "[spec] Error: intent-anchor gate refused finalize for '$SLUG' (verifier code $CODE_MEANING)"
    echo "$ANCHOR_STDERR" | sed 's/^/[spec]   /'
    echo "[spec] Fix plan.md and re-run: lore spec finalize $SLUG"
  } >&2
  emit_json_and_exit 3 "intent-anchor gate failed (verifier code $CODE_MEANING)"
fi

# --- 4. Regenerate tasks.json (failure refuses) ------------------------------
set +e
REGEN_OUTPUT=$(bash "$SCRIPT_DIR/regen-tasks.sh" "$SLUG" --quiet 2>&1)
REGEN_RC=$?
set -e
if [[ $REGEN_RC -ne 0 ]]; then
  REGEN_STATUS="failed"
  REGEN_SUMMARY="$REGEN_OUTPUT"
  echo "$REGEN_OUTPUT" >&2
  fail "regen-tasks failed (exit $REGEN_RC) for '$SLUG'"
fi
REGEN_STATUS="passed"
REGEN_SUMMARY=$(printf '%s\n' "$REGEN_OUTPUT" | grep '^\[work\] Regenerated' | head -1 || true)
[[ -z "$REGEN_SUMMARY" ]] && REGEN_SUMMARY="$REGEN_OUTPUT"

# --- 5. Heal (warn-and-continue) ---------------------------------------------
if bash "$SCRIPT_DIR/heal-work.sh" >/dev/null 2>&1; then
  HEAL_STATUS="passed"
else
  HEAL_STATUS="warned"
  echo "[spec] Warning: heal-work.sh reported issues; finalize continues." >&2
fi

# --- 6. Emission-contract assert over tasks.json -----------------------------
# Every retrieval_directive must carry non-empty seeds AND non-empty scale_set.
# v2 directives are checked per topic; legacy flat directives at top level.
# A null directive is a legitimate absence, not a failure.
if [[ ! -f "$TASKS_FILE" ]]; then
  CONTRACT_STATUS="failed"
  CONTRACT_DETAIL="tasks.json missing after regen"
  fail "emission-contract assert: tasks.json missing after regen for '$SLUG'"
fi

set +e
CONTRACT_DETAIL=$(python3 - "$TASKS_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

failures = []
checked = 0
for phase in data.get("phases", []):
    num = phase.get("phase_number")
    directive = phase.get("retrieval_directive")
    if not isinstance(directive, dict):
        continue
    topics = directive.get("topics")
    if isinstance(topics, list):
        for topic in topics:
            checked += 1
            label = topic.get("topic") or topic.get("role") or "?"
            if not topic.get("seeds"):
                failures.append(f"phase {num} topic '{label}': empty seeds")
            if not topic.get("scale_set"):
                failures.append(f"phase {num} topic '{label}': empty scale_set")
    else:
        checked += 1
        if not directive.get("seeds"):
            failures.append(f"phase {num}: empty seeds")
        if not directive.get("scale_set"):
            failures.append(f"phase {num}: empty scale_set")

if failures:
    print("; ".join(failures))
    sys.exit(1)
print(f"{checked} directive(s) checked, all carry seeds and scale_set")
PYEOF
)
CONTRACT_RC=$?
set -e
if [[ $CONTRACT_RC -ne 0 ]]; then
  CONTRACT_STATUS="failed"
  {
    echo "[spec] Error: emission-contract assert failed for '$SLUG': $CONTRACT_DETAIL"
    echo "[spec] Fix the retrieval directive block(s) in plan.md and re-run: lore spec finalize $SLUG"
  } >&2
  emit_json_and_exit 1 "emission-contract assert failed: $CONTRACT_DETAIL"
fi
CONTRACT_STATUS="passed"

# --- 6b. Judgment-class annotation + split-rationale gate over plan.md --------
# Every task checkbox line must carry a trailing [class: mechanical|standard|
# judgment-dense] marker, and any phase with more than one task must carry a
# **Split rationale:** block. The gate refuses (exit 1) before any telemetry row
# or spec-verb execution-log atom is written. On success it emits the
# split_rationale text and class distribution the step-9 telemetry row records.
# Class markers ride here (not on the emission-contract assert) because they are
# a plan.md authoring property, parsed straight from the source of truth rather
# than from the regenerated tasks.json.
set +e
CLASS_GATE_JSON=$(python3 - "$PLAN_FILE" <<'PYEOF'
import json, re, sys

with open(sys.argv[1], encoding="utf-8") as f:
    plan = f.read()

CLASS_RE = re.compile(r"\[class:\s*(mechanical|standard|judgment-dense)\s*\]")
TASK_RE = re.compile(r"^- \[[ xX]\]\s+(.*)", re.MULTILINE)
PHASE_RE = re.compile(r"^### Phase (\d+):\s*(.*)", re.MULTILINE)
matches = list(PHASE_RE.finditer(plan))

unannotated = []            # task lines with no [class: ...] marker
missing_rationale = []      # >1-task phases with no **Split rationale:**
split_rationale = {}        # phase_number -> rationale text
class_distribution = {"mechanical": 0, "standard": 0, "judgment-dense": 0}

for i, m in enumerate(matches):
    phase_num = m.group(1)
    start = m.end()
    if i + 1 < len(matches):
        end = matches[i + 1].start()
    else:
        nxt = re.search(r"^## ", plan[start:], re.MULTILINE)
        end = start + nxt.start() if nxt else len(plan)
    body = plan[start:end]

    tasks = TASK_RE.findall(body)
    for line in tasks:
        cm = CLASS_RE.search(line)
        if cm:
            class_distribution[cm.group(1)] += 1
        else:
            unannotated.append(f"phase {phase_num}: {line.strip()}")

    sr = re.search(
        r"^\*\*Split rationale:\*\*[ \t]*(.*?)(?=\n\*\*[A-Za-z]|\n- \[|\n#|\Z)",
        body, re.DOTALL | re.MULTILINE,
    )
    sr_text = re.sub(r"<!--.*?-->", "", sr.group(1), flags=re.DOTALL).strip() if sr else ""
    if sr_text.startswith("<") and sr_text.endswith(">"):
        sr_text = ""  # unfilled <placeholder> counts as absent
    if sr_text:
        split_rationale[phase_num] = sr_text
    if len(tasks) > 1 and not sr_text:
        missing_rationale.append(phase_num)

if unannotated or missing_rationale:
    print("[spec] Error: judgment-class gate refused finalize:", file=sys.stderr)
    for u in unannotated:
        print(f"[spec]   unannotated task line — {u}", file=sys.stderr)
    for p in missing_rationale:
        print(f"[spec]   phase {p}: more than one task with no **Split rationale:** block", file=sys.stderr)
    sys.exit(1)

print(json.dumps({"split_rationale": split_rationale, "class_distribution": class_distribution}))
PYEOF
)
CLASS_GATE_RC=$?
set -e
if [[ $CLASS_GATE_RC -ne 0 ]]; then
  CLASS_GATE_STATUS="failed"
  CLASS_GATE_DETAIL="unannotated task line(s) or multi-task phase(s) missing split rationale"
  echo "[spec] Annotate every task line with [class: mechanical|standard|judgment-dense] and add **Split rationale:** to multi-task phases, then re-run: lore spec finalize $SLUG" >&2
  emit_json_and_exit 1 "judgment-class gate failed: $CLASS_GATE_DETAIL"
fi
CLASS_GATE_STATUS="passed"
CLASS_GATE_PAYLOAD="$CLASS_GATE_JSON"

# --- 7. Execution-log atom (source: spec-verb) --------------------------------
ATOM_BODY=$(printf 'Spec finalize: terminal gate sequence completed\nBacklinks: %s\nAnchor gate: %s\nTasks: %s\nHeal: %s\nContract asserts: %s' \
  "$BACKLINKS_STATUS" "$ANCHOR_STATUS" "$REGEN_SUMMARY" "$HEAL_STATUS" "$CONTRACT_DETAIL")

if ! printf '%s\n' "$ATOM_BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" \
    --slug "$SLUG" --source spec-verb --template-version "$TEMPLATE_VERSION" >/dev/null; then
  fail "execution-log append failed for '$SLUG' — no telemetry row emitted"
fi

# --- 8. Bookkeeping attribution counts (atom above is counted) ----------------
read -r VERB_MEDIATED_COUNT HAND_RUN_COUNT < <(python3 - "$LOG_FILE" <<'PYEOF'
import re, sys
verb = hand = 0
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        m = re.match(r'^## .*\| source: (\S+)', line)
        if m:
            if m.group(1) == "spec-verb":
                verb += 1
            else:
                hand += 1
print(verb, hand)
PYEOF
)

# --- 9. Telemetry row (LAST write; append failure warns, never refuses) -------
CAPTURED_SHA=$(captured_at_sha)
TELEMETRY_ROW=$(python3 -c '
import json, sys
slug, verb_count, hand_count, tv, sha, ts, gate_payload = sys.argv[1:8]
payload = json.loads(gate_payload)
row = {
    "schema_version": "1",
    "kind": "telemetry",
    "tier": "telemetry",
    "calibration_state": "pre-calibration",
    "event_type": "spec-finalize",
    "metric": "spec_finalize_bookkeeping",
    "work_item": slug,
    "verb_mediated_count": int(verb_count),
    "hand_run_count": int(hand_count),
    "split_rationale": payload.get("split_rationale", {}),
    "class_distribution": payload.get("class_distribution", {}),
    "template_version": tv,
    "captured_at_sha": None if sha == "null" else sha,
    "ts": ts,
}
print(json.dumps(row, ensure_ascii=False))
' "$SLUG" "$VERB_MEDIATED_COUNT" "$HAND_RUN_COUNT" "$TEMPLATE_VERSION" "$CAPTURED_SHA" "$(timestamp_iso)" "$CLASS_GATE_PAYLOAD")

if printf '%s' "$TELEMETRY_ROW" | bash "$SCRIPT_DIR/scorecard-append.sh" >/dev/null; then
  TELEMETRY_STATUS="appended"
else
  TELEMETRY_STATUS="failed"
  echo "[spec] Warning: telemetry row append failed; finalize continues (observability-only)." >&2
fi

# --- 10. Protocol terminus: self-addressed session close-request (best-effort) -
# Post-telemetry side effect on the session substrate. Fires only inside a
# TUI-hosted session (LORE_SESSION_INSTANCE set) — a bare-terminal finalize has
# no session to close, so it silently no-ops. Every refusal path exits before
# this point, so a refused finalize never emits. The `if !` guard keeps a
# non-zero child from tripping set -e; stdout is discarded so it cannot corrupt
# the --json payload emitted below. Any failure only warns.
if [[ -n "${LORE_SESSION_INSTANCE:-}" ]]; then
  if ! bash "$SCRIPT_DIR/session-close.sh" --self --reason protocol_terminus >/dev/null; then
    echo "[spec] Warning: session close-request failed; finalize already complete (session teardown is best-effort)." >&2
  fi
fi

# --- 11. Protocol terminus: retro-sampling gate (best-effort) -----------------
# Same terminus tier as the session close-request above — a post-telemetry
# cross-substrate side effect reached only after every refusal/fatal gate, so a
# refused finalize never consults it. Decides whether this completed cycle
# surfaces a retro now or defers to the batch queue, recording the outcome
# either way (sampled-out is never silence). Unlike the session close-request it
# is NOT gated on LORE_SESSION_INSTANCE: the retro cadence covers the work cycle,
# so a bare-terminal finalize gets the same discipline. stdout is discarded so it
# cannot corrupt the --json payload; the operator prompt/note rides stderr. Any
# failure only warns and never alters this verb's exit code or telemetry.
if ! bash "$SCRIPT_DIR/retro-sampling-gate.sh" \
    --terminus spec-finalize --slug "$SLUG" \
    --template-version "$TEMPLATE_VERSION" >/dev/null; then
  echo "[spec] Warning: retro-sampling gate errored; finalize already complete (gate is best-effort)." >&2
fi

# --- Report -------------------------------------------------------------------
if [[ $JSON_MODE -eq 1 ]]; then
  emit_json_and_exit 0 ""
fi

echo "[spec] Finalize complete for '$SLUG'"
echo "[spec]   Backlinks:        $BACKLINKS_STATUS"
if [[ "$BACKLINKS_STATUS" == "warned" ]]; then
  printf '%s' "$BACKLINKS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
if isinstance(data, dict):
    for item in data.get("unresolved") or []:
        backlink = item.get("backlink", "?") if isinstance(item, dict) else str(item)
        print(f"[spec]     unresolved: {backlink}")
'
fi
if [[ "$ANCHOR_STATUS" == "skipped" ]]; then
  echo "[spec]   Anchor gate:      skipped — $ANCHOR_REASON"
else
  echo "[spec]   Anchor gate:      $ANCHOR_STATUS"
fi
echo "[spec]   Tasks:            $REGEN_SUMMARY"
echo "[spec]   Heal:             $HEAL_STATUS"
echo "[spec]   Contract asserts: $CONTRACT_STATUS ($CONTRACT_DETAIL)"
echo "[spec]   Class gate:       $CLASS_GATE_STATUS"
echo "[spec]   Attribution:      verb-mediated=$VERB_MEDIATED_COUNT hand-run=$HAND_RUN_COUNT"
echo "[spec]   Telemetry:        $TELEMETRY_STATUS (metric: spec_finalize_bookkeeping)"
