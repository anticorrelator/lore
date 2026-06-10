#!/usr/bin/env bash
# impl-open.sh — Prepare the /implement dispatch manifest for a work item
# Usage: impl-open.sh <ref> (--all | --phase <n> ... | --task <id> ...)
#        [--fallback-scale-set <buckets>] [--template-version <hash>] [--json]
#
# Prepare-and-return emitter for /implement Steps 2–3.6. Computes the
# bash-scriptable dispatch envelope and returns it; the LEAD executes every
# harness tool call (TeamCreate, TaskCreate, TaskUpdate blockedBy wiring) in
# manifest order and spawns workers itself. This script never invokes harness
# tools, never spawns anything, and never decides routes.
#
# Computed envelope:
#   - orchestration-adapter capability gates (completion_enforcement,
#     team_messaging) for the active framework
#   - tasks.json checksum validation (delegates to load-tasks.sh; a mismatch
#     is a hard error directing the caller to `lore work regen-tasks`)
#   - phase map (number, name, objective, files, retrieval-directive kind)
#   - per-phase prior knowledge via the 3-branch gate: retrieval_directive ->
#     resolve-manifest.sh; embedded `## Prior Knowledge` in task descriptions
#     -> skip; otherwise fallback `lore prefetch` (runs only when the caller
#     declares --fallback-scale-set; without a declaration the phase is
#     returned as status=needs-prefetch with the suggested query — scale is
#     the caller's declaration, never a default)
#   - per-task Tier 2 extracts from task-claims.jsonl (task_id or file overlap)
#   - skill-invocation map from plan.md `**Related skills:**` merged with
#     `lore ceremony get implement` entries (source: ceremony)
#   - persistent-advisor declarations (mode: persistent only)
#   - same-file collision intersection: concurrent selected tasks sharing a
#     file target with no dependency path between them get a serialization
#     edge, so the manifest's blockedBy wiring is already collision-safe
#   - the four lead-inline gate conditions as SEPARATE fields (single_task,
#     prescriptive, no_persistent_advisor, no_required_consultation) — never
#     an aggregate eligibility boolean; the lead reads conditions and decides
#
# Manifest contract (D2): first element is TeamCreate, then TaskCreate per
# eligible task in tasks.json order, then TaskUpdate wiring ops whose
# add_blocked_by edges are complete (tasks.json edges within the selection
# plus collision-serialization edges). Edges pointing outside the selection
# are surfaced per-task as external_blocked_by for the lead to wire against
# already-created tasks. No eligible tasks is a successful empty manifest
# with an explanatory status, not an error.
#
# The only write is one execution-log attribution row (source: impl-verb).
#
# Exit codes:
#   0  manifest emitted (possibly empty with explanatory status)
#   1  validation error / no match / missing tasks.json / checksum mismatch
#   2  ambiguous work-item reference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VALID_BUCKETS="abstract|architecture|subsystem|implementation"

REF=""
SELECT_ALL=0
SELECT_PHASES=()
SELECT_TASKS=()
FALLBACK_SCALE_SET=""
TEMPLATE_VERSION=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: lore impl open <ref> (--all | --phase <n> ... | --task <id> ...)
                      [--fallback-scale-set <buckets>] [--template-version <hash>] [--json]

Selection (exactly one mode is required — no default):
  --all                 every task in tasks.json
  --phase <n>           tasks in phase <n> (repeatable)
  --task <id>           a specific task id, e.g. task-3 (repeatable)

  --fallback-scale-set  scale buckets (comma-separated: $VALID_BUCKETS)
                        declared for fallback-branch prefetch; phases needing
                        the fallback are returned as needs-prefetch when omitted

Exit codes: 0 manifest emitted, 1 error/no match, 2 ambiguous reference
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
    --all)
      SELECT_ALL=1
      shift
      ;;
    --phase)
      SELECT_PHASES+=("${2:-}")
      shift 2
      ;;
    --phase=*)
      SELECT_PHASES+=("${1#--phase=}")
      shift
      ;;
    --task)
      SELECT_TASKS+=("${2:-}")
      shift 2
      ;;
    --task=*)
      SELECT_TASKS+=("${1#--task=}")
      shift
      ;;
    --fallback-scale-set)
      FALLBACK_SCALE_SET="${2:-}"
      shift 2
      ;;
    --fallback-scale-set=*)
      FALLBACK_SCALE_SET="${1#--fallback-scale-set=}"
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

# --- Selection: exactly one mode, declared by the caller (no default) -------
MODE_COUNT=0
[[ $SELECT_ALL -eq 1 ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ ${#SELECT_PHASES[@]} -gt 0 ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ ${#SELECT_TASKS[@]} -gt 0 ]] && MODE_COUNT=$((MODE_COUNT + 1))
if [[ $MODE_COUNT -eq 0 ]]; then
  usage
  fail "a selection is required: --all, --phase <n>, or --task <id>"
fi
if [[ $MODE_COUNT -gt 1 ]]; then
  fail "selection modes are exclusive: pass exactly one of --all, --phase, --task"
fi

for p in ${SELECT_PHASES[@]+"${SELECT_PHASES[@]}"}; do
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then
    fail "--phase requires a positive integer (got '$p')"
  fi
done

if [[ -n "$FALLBACK_SCALE_SET" ]]; then
  IFS=',' read -ra _buckets <<< "$FALLBACK_SCALE_SET"
  for b in "${_buckets[@]}"; do
    case "$b" in
      abstract|architecture|subsystem|implementation) ;;
      *)
        fail "--fallback-scale-set bucket must be one of: $VALID_BUCKETS (got '$b')"
        ;;
    esac
  done
fi

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
  fail "work item '$SLUG' is archived — dispatch preparation applies to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"
META="$ITEM_DIR/_meta.json"
PLAN_FILE="$ITEM_DIR/plan.md"
TASKS_FILE="$ITEM_DIR/tasks.json"

[[ -f "$META" ]] || fail "missing _meta.json for work item '$SLUG'"
[[ -f "$PLAN_FILE" ]] || fail "No structured plan found for '$SLUG'. Run /spec first to create phases and tasks."
if [[ ! -f "$TASKS_FILE" ]]; then
  fail "no tasks.json for '$SLUG' — generate it first: lore work tasks $SLUG"
fi

# --- Checksum gate: delegate to the load-tasks sole validator ---------------
set +e
LOAD_OUTPUT=$(bash "$SCRIPT_DIR/load-tasks.sh" "$SLUG" 2>&1)
LOAD_RC=$?
set -e
if [[ $LOAD_RC -ne 0 ]]; then
  printf '%s\n' "$LOAD_OUTPUT" >&2
  fail "tasks.json failed load-tasks validation for '$SLUG' — plan.md was edited after generation; run: lore work regen-tasks $SLUG (or restore plan.md)"
fi
CHECKSUM_LINE=$(printf '%s\n' "$LOAD_OUTPUT" | sed -n '1p')

# --- Adapter capability gates (warn + degrade, never abort the manifest) ----
FRAMEWORK=$(resolve_active_framework 2>/dev/null) || FRAMEWORK=""
ENFORCEMENT=""
if [[ -n "$FRAMEWORK" && -f "$LORE_REPO_DIR/adapters/agents/$FRAMEWORK.sh" ]]; then
  ENFORCEMENT=$(bash "$LORE_REPO_DIR/adapters/agents/$FRAMEWORK.sh" completion_enforcement 2>/dev/null) || ENFORCEMENT=""
fi
if [[ -z "$ENFORCEMENT" ]]; then
  echo "[impl] Warning: could not resolve completion_enforcement for framework '$FRAMEWORK'" >&2
  ENFORCEMENT="unknown"
fi
TEAM_MESSAGING=$(framework_capability team_messaging 2>/dev/null) || TEAM_MESSAGING=""
if [[ -z "$TEAM_MESSAGING" ]]; then
  echo "[impl] Warning: could not resolve team_messaging capability" >&2
  TEAM_MESSAGING="unknown"
fi

# --- Ceremony config (lead-invocation entries; [] when unconfigured) --------
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

# --- Assemble the dispatch payload -------------------------------------------
SELECT_PHASES_CSV=$(IFS=','; echo "${SELECT_PHASES[*]-}")
SELECT_TASKS_CSV=$(IFS=','; echo "${SELECT_TASKS[*]-}")

PAYLOAD=$(_LORE_CEREMONY_JSON="$CEREMONY_JSON" python3 - "$ITEM_DIR" "$SLUG" \
  "$SELECT_ALL" "$SELECT_PHASES_CSV" "$SELECT_TASKS_CSV" \
  "$FALLBACK_SCALE_SET" "$FRAMEWORK" "$ENFORCEMENT" "$TEAM_MESSAGING" \
  "$SCRIPT_DIR" "$LORE_REPO_DIR" "$CHECKSUM_LINE" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

(item_dir, slug, select_all, phases_csv, tasks_csv, fallback_scale_set,
 framework, enforcement, team_messaging, script_dir, repo_dir,
 checksum_line) = sys.argv[1:13]

ceremony_skills = json.loads(os.environ.get("_LORE_CEREMONY_JSON", "[]"))

with open(os.path.join(item_dir, "_meta.json"), encoding="utf-8") as f:
    meta = json.load(f)
title = meta.get("title") or slug

with open(os.path.join(item_dir, "tasks.json"), encoding="utf-8") as f:
    tasks_data = json.load(f)

with open(os.path.join(item_dir, "plan.md"), encoding="utf-8") as f:
    plan = f.read()

warnings = []


def warn(msg):
    warnings.append(msg)
    print(f"[impl] Warning: {msg}", file=sys.stderr)


# --- Flatten tasks and index phases ------------------------------------------
all_tasks = []       # tasks.json document order
task_by_id = {}
phase_of = {}
phases = tasks_data.get("phases", [])
for phase in phases:
    for task in phase.get("tasks", []):
        all_tasks.append(task)
        task_by_id[task["id"]] = task
        phase_of[task["id"]] = phase.get("phase_number")

# --- Selection ----------------------------------------------------------------
if select_all == "1":
    selection = {"mode": "all"}
    selected_ids = [t["id"] for t in all_tasks]
elif phases_csv:
    wanted = {int(p) for p in phases_csv.split(",") if p}
    selection = {"mode": "phase", "phases": sorted(wanted)}
    selected_ids = [t["id"] for t in all_tasks if phase_of[t["id"]] in wanted]
    known_phases = {p.get("phase_number") for p in phases}
    for p in sorted(wanted - known_phases):
        warn(f"--phase {p} matches no phase in tasks.json")
else:
    wanted = [t for t in tasks_csv.split(",") if t]
    selection = {"mode": "task", "tasks": wanted}
    unknown = [t for t in wanted if t not in task_by_id]
    for t in unknown:
        warn(f"--task {t} matches no task in tasks.json")
    wanted_set = set(wanted)
    selected_ids = [t["id"] for t in all_tasks if t["id"] in wanted_set]

# --- Exclude tasks already completed in plan.md -------------------------------
checked = [m.group(1).strip()
           for m in re.finditer(r"^\s*- \[x\]\s+(.*)$", plan, re.MULTILINE)]
already_complete = []
eligible_ids = []
for tid in selected_ids:
    subject = task_by_id[tid].get("subject", "")
    if any(subject and subject.lower() in c.lower() for c in checked):
        already_complete.append(tid)
    else:
        eligible_ids.append(tid)
eligible_set = set(eligible_ids)

# --- Dependency closure over the full tasks.json DAG --------------------------
# reach[t] = set of task ids t transitively depends on (its ancestors).
order = [t["id"] for t in all_tasks]
reach = {}
for tid in order:  # blockedBy always points to earlier tasks, so one pass works
    deps = set()
    for dep in task_by_id[tid].get("blockedBy", []):
        deps.add(dep)
        deps |= reach.get(dep, set())
    reach[tid] = deps


def connected(a, b):
    return a in reach.get(b, set()) or b in reach.get(a, set())


# --- Same-file collision intersection -----------------------------------------
# Concurrent (path-unconnected) selected tasks sharing a file target get a
# serialization edge in document order so they are never parallel-dispatched.
by_file = {}
for tid in eligible_ids:
    for ft in task_by_id[tid].get("file_targets", []):
        by_file.setdefault(ft, []).append(tid)

collisions = []
collision_edges = {}  # blocked task -> set of serialization blockers
for ft, tids in by_file.items():
    for earlier, later in zip(tids, tids[1:]):
        if not connected(earlier, later):
            collisions.append({"file": ft, "tasks": [earlier, later],
                               "serialized_edge": {"blocker": earlier, "blocked": later}})
            collision_edges.setdefault(later, set()).add(earlier)
            reach[later] = reach.get(later, set()) | {earlier} | reach.get(earlier, set())

# --- Edge resolution within the selection --------------------------------------
edges = {}              # task id -> in-selection add_blocked_by list
external_blocked_by = {}
for tid in eligible_ids:
    in_sel, external = [], []
    for dep in task_by_id[tid].get("blockedBy", []):
        if dep in eligible_set:
            in_sel.append(dep)
        elif dep in already_complete:
            continue  # satisfied per plan.md — no wiring needed
        else:
            external.append(dep)
    for dep in sorted(collision_edges.get(tid, set())):
        if dep not in in_sel:
            in_sel.append(dep)
    if in_sel:
        edges[tid] = in_sel
    if external:
        external_blocked_by[tid] = external
        warn(f"{tid} is blocked by tasks outside this selection: {', '.join(external)} — wire those edges against the already-created tasks")

# --- Manifest: TeamCreate first, TaskCreate in order, then blockedBy wiring ---
manifest = []
if eligible_ids:
    manifest.append({
        "op": "TeamCreate",
        "team_name": f"impl-{slug}",
        "description": f"Implementing {title}",
    })
    for tid in eligible_ids:
        task = task_by_id[tid]
        entry = {
            "op": "TaskCreate",
            "local_id": tid,
            "phase": phase_of[tid],
            "subject": task.get("subject", ""),
            "activeForm": task.get("activeForm", ""),
            "description": task.get("description", ""),
            "file_targets": task.get("file_targets", []),
        }
        if tid in external_blocked_by:
            entry["external_blocked_by"] = external_blocked_by[tid]
        manifest.append(entry)
    for tid in eligible_ids:
        if tid not in edges:
            continue
        wiring = {
            "op": "TaskUpdate",
            "local_id": tid,
            "add_blocked_by": edges[tid],
        }
        serialized = sorted(collision_edges.get(tid, set()))
        if serialized:
            wiring["collision_serialized"] = serialized
        manifest.append(wiring)

initial_unblocked = [tid for tid in eligible_ids
                     if not edges.get(tid) and tid not in external_blocked_by]

if eligible_ids:
    status, status_reason = "ready", None
elif already_complete and not eligible_ids:
    status = "empty"
    status_reason = "all selected tasks are already checked complete in plan.md"
else:
    status = "empty"
    status_reason = "selection matched no tasks in tasks.json"

# --- Phase map + per-phase prior knowledge (3-branch gate) ---------------------
selected_phase_nums = sorted({phase_of[tid] for tid in eligible_ids})
phase_map = []
prior_knowledge = []
for phase in phases:
    pnum = phase.get("phase_number")
    directive = phase.get("retrieval_directive")
    if directive is None:
        directive_kind = None
    elif isinstance(directive, dict) and directive.get("version") == 2:
        directive_kind = "v2"
    else:
        directive_kind = "legacy"
    phase_map.append({
        "phase_number": pnum,
        "phase_name": phase.get("phase_name", ""),
        "objective": phase.get("objective", ""),
        "files": phase.get("files", []),
        "retrieval_directive_kind": directive_kind,
        "selected": pnum in selected_phase_nums,
    })

    if pnum not in selected_phase_nums:
        continue

    entry = {"phase_number": pnum, "phase_name": phase.get("phase_name", "")}
    # Each phase resolves independently — one failed phase must not abort
    # the manifest, so every subprocess branch is contained per-iteration.
    if directive is not None:
        entry["branch"] = "directive"
        try:
            proc = subprocess.run(
                ["bash", os.path.join(script_dir, "resolve-manifest.sh"), slug, str(pnum)],
                capture_output=True, text=True, timeout=120)
            if proc.returncode == 0:
                content = proc.stdout.strip()
                entry["content"] = proc.stdout if content else None
                if content:
                    entry["status"] = "resolved"
                else:
                    # Empty sections mean the per-topic search failed (e.g. the
                    # FTS5 lowercase-operator trap), not that no knowledge exists.
                    entry["status"] = "resolved-empty"
                    entry["note"] = ("resolve-manifest.sh returned no content — per-topic "
                                     "search may have failed; see conventions/"
                                     "empty-prior-knowledge-sections-resolve-manifest-sh")
            else:
                entry["status"] = "error"
                entry["content"] = None
                stderr_lines = (proc.stderr or "").strip().splitlines()
                entry["note"] = stderr_lines[-1] if stderr_lines else None
                warn(f"phase {pnum}: resolve-manifest.sh failed (exit {proc.returncode})")
        except Exception as exc:  # containment: timeout, missing binary, etc.
            entry["status"] = "error"
            entry["content"] = None
            entry["note"] = str(exc)
            warn(f"phase {pnum}: resolve-manifest.sh failed ({exc})")
    elif any("## Prior Knowledge" in (t.get("description") or "")
             for t in phase.get("tasks", [])):
        entry["branch"] = "task-descriptions"
        entry["status"] = "skipped-embedded"
        entry["content"] = None
        entry["note"] = "phase tasks already embed ## Prior Knowledge; appending would duplicate"
    else:
        entry["branch"] = "fallback"
        files = phase.get("files", [])
        query = " ".join([phase.get("objective", "")] + files).strip()
        entry["fallback_query"] = query
        if fallback_scale_set:
            try:
                proc = subprocess.run(
                    [os.path.join(repo_dir, "cli", "lore"), "prefetch", query,
                     "--format", "prompt", "--limit", "3",
                     "--scale-set", fallback_scale_set],
                    capture_output=True, text=True, timeout=120)
                if proc.returncode == 0 and proc.stdout.strip():
                    entry["status"] = "resolved"
                    entry["content"] = proc.stdout
                else:
                    entry["status"] = "resolved-empty" if proc.returncode == 0 else "error"
                    entry["content"] = None
                    if proc.returncode != 0:
                        warn(f"phase {pnum}: fallback prefetch failed (exit {proc.returncode})")
            except Exception as exc:
                entry["status"] = "error"
                entry["content"] = None
                entry["note"] = str(exc)
                warn(f"phase {pnum}: fallback prefetch failed ({exc})")
        else:
            entry["status"] = "needs-prefetch"
            entry["content"] = None
            entry["note"] = ("no retrieval directive and no embedded Prior Knowledge — "
                             "declare --fallback-scale-set to resolve, or run lore prefetch "
                             "with your declared scale")
    prior_knowledge.append(entry)

# --- Per-task Tier 2 extracts (task_id or file-target overlap) -----------------
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

tier2_extracts = {}
for tid in eligible_ids:
    targets = set(task_by_id[tid].get("file_targets", []))
    rows = [r for r in claims
            if r.get("task_id") == tid or (r.get("file") and r["file"] in targets)]
    if rows:
        tier2_extracts[tid] = [{
            "claim_id": r.get("claim_id"),
            "claim": r.get("claim"),
            "task_id": r.get("task_id"),
            "file": r.get("file"),
            "captured_at_sha": r.get("captured_at_sha"),
        } for r in rows]

# --- Per-phase plan content: advisors, consultations, task format --------------
phase_blocks = {}
matches = list(re.finditer(r"^### Phase (\d+):[^\n]*\n", plan, re.MULTILINE))
for i, m in enumerate(matches):
    end = matches[i + 1].start() if i + 1 < len(matches) else len(plan)
    phase_blocks[int(m.group(1))] = plan[m.start():end]


def advisors_block(content):
    m = re.search(r"^\*\*Advisors:\*\*\s*\n((?:(?!^\*\*|\n##).*\n?)*)",
                  content, re.MULTILINE)
    return m.group(1) if m else ""


persistent_advisors = []
for pnum, content in sorted(phase_blocks.items()):
    block = advisors_block(content)
    for line in block.splitlines():
        line = line.strip()
        if line.startswith("- ") and re.search(r"\bmode\s*:\s*persistent\b", line):
            body = line[2:].strip()
            m = re.match(r"(\S+)\s*(?:—|--)?\s*(.*?)\.?\s*mode\s*:\s*persistent\b", body)
            name = (m.group(1) if m else body.split()[0]).strip()
            domain = (m.group(2).strip() if m else "")
            persistent_advisors.append({"name": name, "domain": domain,
                                        "mode": "persistent", "phase": pnum})

consultations_by_phase = {}
for pnum, content in sorted(phase_blocks.items()):
    m = re.search(r"^\*\*Consultations required:\*\*\s*\n((?:(?!^\*\*|\n##)- .*\n?)*)",
                  content, re.MULTILINE)
    if not m:
        continue
    domains = []
    for line in m.group(1).splitlines():
        text = line.strip()
        if not text.startswith("- ") or text.startswith("- [ ]") or text.startswith("- [x]"):
            continue
        text = text[2:].strip()
        if not text or (text.startswith("<") and text.endswith(">")):
            continue
        domains.append(text)
    if domains:
        consultations_by_phase[str(pnum)] = domains

task_format_by_phase = {}
for pnum, content in sorted(phase_blocks.items()):
    m = re.search(r"\*\*Task format:\*\*\s*(.*)", content)
    task_format_by_phase[str(pnum)] = (m.group(1).strip().lower() if m else None)

# --- Skill-invocation map: plan Related skills + ceremony injection ------------
related_skills = []
m = re.search(r"^\*\*Related skills:\*\*\s*\n((?:- .*\n?)*)", plan, re.MULTILINE)
if m:
    for line in m.group(1).splitlines():
        text = line.strip()
        if not text.startswith("- "):
            continue
        text = text[2:].strip()
        sm = re.match(r"/([A-Za-z0-9_-]+)\s*(?:—|--)?\s*(.*)", text)
        if not sm:
            continue  # "none — ..." and prose bullets are not skill entries
        related_skills.append({"skill": sm.group(1), "annotation": sm.group(2).strip()})


def skill_template_version(name):
    path = os.path.join(repo_dir, "skills", name, "SKILL.md")
    if not os.path.isfile(path):
        warn(f"skill '{name}' has no SKILL.md at {path}; template version empty")
        return ""
    try:
        proc = subprocess.run(
            ["bash", os.path.join(script_dir, "template-version.sh"), path],
            capture_output=True, text=True, timeout=30)
        return proc.stdout.strip() if proc.returncode == 0 else ""
    except Exception:
        return ""


persistent_names = {a["name"].lstrip("/") for a in persistent_advisors}
skill_invocation_map = {}
for entry in related_skills:
    name = entry["skill"]
    if name in persistent_names:
        continue  # persistent-advisor skills route to the agent, not this map
    skill_invocation_map[name] = {
        "skill": name,
        "skill_template_version": skill_template_version(name),
        "source": "plan",
        "annotation": entry["annotation"],
    }

ceremony_injected = []
for name in ceremony_skills:
    if not isinstance(name, str) or name in skill_invocation_map or name in persistent_names:
        continue
    tv = skill_template_version(name)
    skill_invocation_map[name] = {
        "skill": name,
        "skill_template_version": tv,
        "source": "ceremony",
    }
    ceremony_injected.append({"skill": name, "skill_template_version": tv})

# --- Lead-inline gate conditions: four separate fields, never an aggregate -----
task_count = len(all_tasks)
single_task = task_count == 1
single_phase = phase_of[all_tasks[0]["id"]] if single_task else None
prescriptive = bool(
    single_task and task_format_by_phase.get(str(single_phase)) == "prescriptive")
no_persistent_advisor = not persistent_advisors
no_required_consultation = (not consultations_by_phase
                            and not ceremony_skills
                            and not related_skills)

lead_inline_conditions = {
    "single_task": single_task,
    "prescriptive": prescriptive,
    "no_persistent_advisor": no_persistent_advisor,
    "no_required_consultation": no_required_consultation,
    "detail": {
        "task_count": task_count,
        "task_format_by_phase": task_format_by_phase,
        "persistent_advisors": persistent_advisors,
        "consultations_required_by_phase": consultations_by_phase,
        "ceremony_skills": ceremony_skills,
        "related_skills": [e["skill"] for e in related_skills],
        "file_count_diagnostic": (
            len(all_tasks[0].get("file_targets", [])) if single_task else None),
    },
}

print(json.dumps({
    "slug": slug,
    "title": title,
    "team_name": f"impl-{slug}",
    "selection": selection,
    "status": status,
    "status_reason": status_reason,
    "checksum": checksum_line,
    "capabilities": {
        "framework": framework or None,
        "completion_enforcement": enforcement,
        "team_messaging": team_messaging,
    },
    "recommended_workers": tasks_data.get("recommended_workers"),
    "manifest": manifest,
    "initial_unblocked": initial_unblocked,
    "already_complete": already_complete,
    "collisions": collisions,
    "phase_map": phase_map,
    "prior_knowledge": prior_knowledge,
    "tier2_extracts": tier2_extracts,
    "skill_invocation_map": skill_invocation_map,
    "ceremony_injected": ceremony_injected,
    "advisors": persistent_advisors,
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
counts = {}
for op in d["manifest"]:
    counts[op["op"]] = counts.get(op["op"], 0) + 1
sel = d["selection"]
sel_str = sel["mode"]
if sel.get("phases"):
    sel_str += " " + ",".join(str(p) for p in sel["phases"])
if sel.get("tasks"):
    sel_str += " " + ",".join(sel["tasks"])
lines = [
    "Implement open: dispatch manifest prepared",
    f"Selection: {sel_str}",
    f"Status: {d['status']}",
    "Manifest ops: " + (", ".join(f"{v} {k}" for k, v in counts.items()) or "none"),
    f"Collisions serialized: {len(d['collisions'])}",
]
for c in d["ceremony_injected"]:
    tv = c["skill_template_version"] or "unknown"
    lines.append(f"Ceremony-injected skill: {c['skill']} (template-version {tv})")
print("\n".join(lines))
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
print(f"[impl open] {d['title']}")
print(f"Slug: {d['slug']}  Team: {d['team_name']}")
print(f"Status: {d['status']}" + (f" — {d['status_reason']}" if d.get("status_reason") else ""))
print(d["checksum"])
caps = d["capabilities"]
print(f"Capabilities: framework={caps['framework']}  "
      f"completion_enforcement={caps['completion_enforcement']}  "
      f"team_messaging={caps['team_messaging']}")
print(f"Recommended workers: {d['recommended_workers']}")
print()
print("Manifest (lead executes top-to-bottom):")
for op in d["manifest"]:
    if op["op"] == "TeamCreate":
        print(f"  1. TeamCreate {op['team_name']}")
    elif op["op"] == "TaskCreate":
        ext = f"  [external blockedBy: {', '.join(op['external_blocked_by'])}]" if op.get("external_blocked_by") else ""
        print(f"  -  TaskCreate {op['local_id']} (phase {op['phase']}): {op['subject']}{ext}")
    else:
        ser = f"  [collision-serialized: {', '.join(op['collision_serialized'])}]" if op.get("collision_serialized") else ""
        print(f"  -  TaskUpdate {op['local_id']} addBlockedBy=[{', '.join(op['add_blocked_by'])}]{ser}")
if not d["manifest"]:
    print("  (empty)")
print()
print(f"Initially unblocked: {', '.join(d['initial_unblocked']) or 'none'}")
if d["already_complete"]:
    print(f"Already complete in plan.md: {', '.join(d['already_complete'])}")
print()
print("Prior knowledge:")
for pk in d["prior_knowledge"]:
    print(f"  Phase {pk['phase_number']} ({pk['branch']}): {pk['status']}")
print()
c = d["lead_inline_conditions"]
print("Lead-inline conditions (read each; the route decision is yours):")
print(f"  single_task: {c['single_task']}")
print(f"  prescriptive: {c['prescriptive']}")
print(f"  no_persistent_advisor: {c['no_persistent_advisor']}")
print(f"  no_required_consultation: {c['no_required_consultation']}")
if d["skill_invocation_map"]:
    print()
    print("Skill-invocation map:")
    for name, e in d["skill_invocation_map"].items():
        print(f"  {name} (source: {e['source']}, template-version: {e['skill_template_version'] or 'unknown'})")
if d["tier2_extracts"]:
    total = sum(len(v) for v in d["tier2_extracts"].values())
    print()
    print(f"Tier 2 extracts: {total} row(s) across {len(d['tier2_extracts'])} task(s)")
PYEOF
