#!/usr/bin/env bash
# impl-next-batch.sh — Return the unblocked pending task set for a work item
# Usage: impl-next-batch.sh <ref> [--active <task-id>]... [--template-version <hash>] [--json]
#
# Prepare-and-return emitter for /implement's batch loop. After task state
# changes (completions checked into plan.md via `lore work check`), this verb
# recomputes which pending tasks are dispatchable and returns them with
# refreshed payloads; the LEAD spawns workers. It never invokes harness
# tools, never spawns anything, and never decides routes.
#
# Completion state is read from plan.md checkboxes — the durable record the
# lead maintains — by matching each tasks.json subject against checked
# (`- [x]`) and unchecked (`- [ ]`) lines. Tasks whose subject matches no
# checkbox are returned as `unmatched` and treated as incomplete blockers.
# The plan checksum is deliberately NOT enforced here: checking boxes edits
# plan.md after tasks.json generation by design, so mid-run the cryptographic
# gate (open's job) would always fail.
#
# --active <task-id> declares a task the lead has already dispatched and is
# still in flight (live task state is harness-side; the lead passes it in).
# Active tasks are excluded from the batch and count as incomplete blockers.
#
# Batch entries carry refreshed per-task Tier 2 extracts (task-claims.jsonl
# rows matched by task_id or file-target overlap — rows workers appended in
# earlier batches are included). Same-file collision groups within the batch
# are returned as conditions: those tasks must not be parallel-dispatched
# across workers; serialize-within-one-worker vs merge is the lead's call.
#
# The four lead-inline gate conditions are returned as SEPARATE fields,
# never an aggregate boolean. An empty unblocked set is success with an
# explanatory status (all-blocked | all-complete), not an error.
#
# The only write is one execution-log attribution row (source: impl-verb).
#
# Exit codes:
#   0  batch emitted (possibly empty with explanatory status)
#   1  validation error / no match / missing tasks.json or plan.md
#   2  ambiguous work-item reference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
ACTIVE_TASKS=()
TEMPLATE_VERSION=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: lore impl next-batch <ref> [--active <task-id>]... [--template-version <hash>] [--json]

Return the unblocked pending task set (per plan.md checkboxes) with refreshed
Tier 2 extracts, collision groups, and the four lead-inline condition fields.
--active marks tasks currently dispatched; they are excluded and count as
incomplete blockers. Empty batch is success with status all-blocked or
all-complete.

Exit codes: 0 batch emitted, 1 error/no match, 2 ambiguous reference
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
    --active)
      ACTIVE_TASKS+=("${2:-}")
      shift 2
      ;;
    --active=*)
      ACTIVE_TASKS+=("${1#--active=}")
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

for a in ${ACTIVE_TASKS[@]+"${ACTIVE_TASKS[@]}"}; do
  if [[ -z "$a" ]]; then
    fail "--active requires a non-empty task id"
  fi
done

# --- Resolve the work-item reference (tri-state exit passthrough) ----------
RESOLVE_ARGS=("$REF")
[[ $JSON_MODE -eq 1 ]] && RESOLVE_ARGS+=(--json)

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "${RESOLVE_ARGS[@]}")
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  # Resolver already wrote diagnostics (stderr in text mode, JSON on stdout
  # with --json) — propagate its output and tri-state exit code unchanged.
  [[ -n "$RESOLVED" ]] && printf '%s\n' "$RESOLVED"
  exit "$RESOLVE_RC"
fi

if [[ $JSON_MODE -eq 1 ]]; then
  SLUG=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["slug"])')
  ARCHIVED=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["archived"] else "false")')
else
  SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
  ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
fi

if [[ "$ARCHIVED" == "true" ]]; then
  fail "work item '$SLUG' is archived — batch discovery applies to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"

[[ -f "$ITEM_DIR/_meta.json" ]] || fail "missing _meta.json for work item '$SLUG'"
[[ -f "$ITEM_DIR/plan.md" ]] || fail "No structured plan found for '$SLUG'. Run /spec first to create phases and tasks."
if [[ ! -f "$ITEM_DIR/tasks.json" ]]; then
  fail "no tasks.json for '$SLUG' — generate it first: lore work tasks $SLUG"
fi

CEREMONY_JSON=$(bash "$SCRIPT_DIR/ceremony-config.sh" get implement 2>/dev/null) || CEREMONY_JSON="[]"
if ! printf '%s' "$CEREMONY_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list)' 2>/dev/null; then
  echo "[impl] Warning: ceremony config for 'implement' is not a JSON array; treating as empty" >&2
  CEREMONY_JSON="[]"
fi

# --- Provenance: stamp the producing template's version at emission ---------
if [[ -z "$TEMPLATE_VERSION" ]]; then
  SKILL_TEMPLATE="$LORE_REPO_DIR/skills/implement/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi

ACTIVE_CSV=$(IFS=','; echo "${ACTIVE_TASKS[*]-}")

PAYLOAD=$(_LORE_CEREMONY_JSON="$CEREMONY_JSON" python3 - "$ITEM_DIR" "$SLUG" "$ACTIVE_CSV" <<'PYEOF'
import json
import os
import re
import sys

item_dir, slug, active_csv = sys.argv[1:4]
active = {a for a in active_csv.split(",") if a}
ceremony_skills = json.loads(os.environ.get("_LORE_CEREMONY_JSON", "[]"))

with open(os.path.join(item_dir, "tasks.json"), encoding="utf-8") as f:
    tasks_data = json.load(f)
with open(os.path.join(item_dir, "plan.md"), encoding="utf-8") as f:
    plan = f.read()

warnings = []


def warn(msg):
    warnings.append(msg)
    print(f"[impl] Warning: {msg}", file=sys.stderr)


all_tasks = []
task_by_id = {}
phase_of = {}
phases = tasks_data.get("phases", [])
for phase in phases:
    for task in phase.get("tasks", []):
        all_tasks.append(task)
        task_by_id[task["id"]] = task
        phase_of[task["id"]] = phase.get("phase_number")

for a in sorted(active):
    if a not in task_by_id:
        warn(f"--active {a} matches no task in tasks.json")

# --- Completion state from plan.md checkboxes ---------------------------------
checked = [m.group(1).strip()
           for m in re.finditer(r"^\s*- \[x\]\s+(.*)$", plan, re.MULTILINE)]
unchecked = [m.group(1).strip()
             for m in re.finditer(r"^\s*- \[ \]\s+(.*)$", plan, re.MULTILINE)]

completed, pending, unmatched = [], [], []
for task in all_tasks:
    tid = task["id"]
    subject = (task.get("subject") or "").lower()
    if subject and any(subject in c.lower() for c in checked):
        completed.append(tid)
    elif subject and any(subject in u.lower() for u in unchecked):
        pending.append(tid)
    else:
        unmatched.append(tid)
        warn(f"{tid} subject matches no plan.md checkbox — plan.md and tasks.json "
             f"have drifted; treating it as incomplete (run lore work regen-tasks "
             f"{slug} if the plan was restructured)")

completed_set = set(completed)

# --- Unblocked pending set -----------------------------------------------------
# A blocker counts as satisfied only when checked complete in plan.md; active
# (in-flight) and unmatched tasks are incomplete by definition.
batch_ids = []
pending_blocked = []
for tid in pending:
    if tid in active:
        continue
    blockers = [dep for dep in task_by_id[tid].get("blockedBy", [])
                if dep not in completed_set]
    if blockers:
        pending_blocked.append({"id": tid, "blocked_by_pending": blockers})
    else:
        batch_ids.append(tid)

# --- Refreshed Tier 2 extracts (task_id or file-target overlap) ----------------
claims = []
claims_path = os.path.join(item_dir, "task-claims.jsonl")
if os.path.isfile(claims_path):
    with open(claims_path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError("not an object")
            except ValueError:
                warn(f"skipping malformed line {lineno} in task-claims.jsonl")
                continue
            claims.append(row)

batch = []
for tid in batch_ids:
    task = task_by_id[tid]
    targets = set(task.get("file_targets", []))
    rows = [r for r in claims
            if r.get("task_id") == tid or (r.get("file") and r["file"] in targets)]
    batch.append({
        "local_id": tid,
        "phase": phase_of[tid],
        "subject": task.get("subject", ""),
        "activeForm": task.get("activeForm", ""),
        "description": task.get("description", ""),
        "file_targets": task.get("file_targets", []),
        "tier2_extract": [{
            "claim_id": r.get("claim_id"),
            "claim": r.get("claim"),
            "task_id": r.get("task_id"),
            "file": r.get("file"),
            "captured_at_sha": r.get("captured_at_sha"),
        } for r in rows],
    })

# --- Same-file collision groups within the batch -------------------------------
# Returned as conditions: never parallel-dispatch these across workers;
# serialize-within-one-worker vs merge is the lead's decision.
by_file = {}
for tid in batch_ids:
    for ft in task_by_id[tid].get("file_targets", []):
        by_file.setdefault(ft, []).append(tid)
collision_groups = [{"file": ft, "tasks": tids}
                    for ft, tids in by_file.items() if len(tids) > 1]

if batch_ids:
    status = "batch-ready"
elif pending_blocked or active:
    status = "all-blocked"
else:
    status = "all-complete"

# --- Lead-inline gate conditions: four separate fields, never an aggregate -----
phase_blocks = {}
matches = list(re.finditer(r"^### Phase (\d+):[^\n]*\n", plan, re.MULTILINE))
for i, m in enumerate(matches):
    end = matches[i + 1].start() if i + 1 < len(matches) else len(plan)
    phase_blocks[int(m.group(1))] = plan[m.start():end]

persistent_advisors = []
consultations_by_phase = {}
task_format_by_phase = {}
for pnum, content in sorted(phase_blocks.items()):
    am = re.search(r"^\*\*Advisors:\*\*\s*\n((?:(?!^\*\*|\n##).*\n?)*)",
                   content, re.MULTILINE)
    if am:
        for line in am.group(1).splitlines():
            line = line.strip()
            if line.startswith("- ") and re.search(r"\bmode\s*:\s*persistent\b", line):
                body = line[2:].strip()
                m = re.match(r"(\S+)\s*(?:—|--)?\s*(.*?)\.?\s*mode\s*:\s*persistent\b", body)
                persistent_advisors.append({
                    "name": (m.group(1) if m else body.split()[0]).strip(),
                    "domain": (m.group(2).strip() if m else ""),
                    "mode": "persistent",
                    "phase": pnum,
                })
    cm = re.search(r"^\*\*Consultations required:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
                   content, re.MULTILINE)
    if cm:
        domains = []
        for line in cm.group(1).splitlines():
            text = line.strip()
            if not text.startswith("- ") or text.startswith("- [ ]") or text.startswith("- [x]"):
                continue
            text = text[2:].strip()
            if not text or (text.startswith("<") and text.endswith(">")):
                continue
            domains.append(text)
        if domains:
            consultations_by_phase[str(pnum)] = domains
    fm = re.search(r"\*\*Task format:\*\*\s*(.*)", content)
    task_format_by_phase[str(pnum)] = (fm.group(1).strip().lower() if fm else None)

related_skills = []
rm = re.search(r"^\*\*Related skills:\*\*\s*\n((?:- .*\n?)*)", plan, re.MULTILINE)
if rm:
    for line in rm.group(1).splitlines():
        text = line.strip()
        if not text.startswith("- "):
            continue
        sm = re.match(r"/([A-Za-z0-9_-]+)", text[2:].strip())
        if sm:
            related_skills.append(sm.group(1))

task_count = len(all_tasks)
single_task = task_count == 1
single_phase = phase_of[all_tasks[0]["id"]] if single_task else None
prescriptive = bool(
    single_task and task_format_by_phase.get(str(single_phase)) == "prescriptive")

lead_inline_conditions = {
    "single_task": single_task,
    "prescriptive": prescriptive,
    "no_persistent_advisor": not persistent_advisors,
    "no_required_consultation": (not consultations_by_phase
                                 and not ceremony_skills
                                 and not related_skills),
    "detail": {
        "task_count": task_count,
        "task_format_by_phase": task_format_by_phase,
        "persistent_advisors": persistent_advisors,
        "consultations_required_by_phase": consultations_by_phase,
        "ceremony_skills": ceremony_skills,
        "related_skills": related_skills,
        "file_count_diagnostic": (
            len(all_tasks[0].get("file_targets", [])) if single_task else None),
    },
}

print(json.dumps({
    "slug": slug,
    "status": status,
    "batch": batch,
    "active": sorted(active),
    "completed": completed,
    "pending_blocked": pending_blocked,
    "unmatched": unmatched,
    "collision_groups": collision_groups,
    "lead_inline_conditions": lead_inline_conditions,
    "warnings": warnings,
}, ensure_ascii=False))
PYEOF
)

# --- Execution-log attribution row (the verb's only write) -------------------
LOG_BODY=$(_LORE_PAYLOAD="$PAYLOAD" python3 <<'PYEOF'
import json
import os

d = json.loads(os.environ["_LORE_PAYLOAD"])
batch_ids = ", ".join(t["local_id"] for t in d["batch"]) or "none"
print("\n".join([
    f"Implement next-batch: {len(d['batch'])} unblocked task(s) returned",
    f"Status: {d['status']}",
    f"Batch: {batch_ids}",
    f"Completed: {len(d['completed'])}  Blocked: {len(d['pending_blocked'])}  Active: {len(d['active'])}",
    f"Collision groups: {len(d['collision_groups'])}",
]))
PYEOF
)

WLOG_ARGS=(--slug "$SLUG" --source impl-verb)
if [[ -n "$TEMPLATE_VERSION" ]]; then
  WLOG_ARGS+=(--template-version "$TEMPLATE_VERSION")
fi
if ! printf '%s\n' "$LOG_BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" "${WLOG_ARGS[@]}" >/dev/null; then
  fail "execution-log append failed for '$SLUG'"
fi

# --- Output -------------------------------------------------------------------
if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$PAYLOAD"
fi

python3 - "$PAYLOAD" <<'PYEOF'
import json
import sys

d = json.loads(sys.argv[1])
print(f"[impl next-batch] {d['slug']}")
print(f"Status: {d['status']}")
print(f"Completed: {len(d['completed'])}  Blocked: {len(d['pending_blocked'])}  "
      f"Active: {len(d['active'])}  Unmatched: {len(d['unmatched'])}")
print()
if d["batch"]:
    print("Unblocked batch (lead dispatches; collisions below must not run in parallel):")
    for t in d["batch"]:
        extract = f"  [{len(t['tier2_extract'])} Tier 2 row(s)]" if t["tier2_extract"] else ""
        print(f"  -  {t['local_id']} (phase {t['phase']}): {t['subject']}{extract}")
else:
    print("Unblocked batch: empty")
for blocked in d["pending_blocked"]:
    print(f"  blocked: {blocked['id']} <- {', '.join(blocked['blocked_by_pending'])}")
if d["collision_groups"]:
    print()
    print("Same-file collision groups (serialize within one worker, or merge — your call):")
    for g in d["collision_groups"]:
        print(f"  {g['file']}: {', '.join(g['tasks'])}")
print()
c = d["lead_inline_conditions"]
print("Lead-inline conditions (read each; the route decision is yours):")
print(f"  single_task: {c['single_task']}")
print(f"  prescriptive: {c['prescriptive']}")
print(f"  no_persistent_advisor: {c['no_persistent_advisor']}")
print(f"  no_required_consultation: {c['no_required_consultation']}")
PYEOF
