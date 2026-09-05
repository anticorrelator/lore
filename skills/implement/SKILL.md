---
name: implement
description: "Execute a work item's plan through compiled worker positions and knowledge packets — one workflow for standalone and commissioned runs; commands record execution, the seat records acceptance and closure"
user_invocable: true
argument_description: "[--yes] [--model <id>] [work item name]"
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Edit
  - Write
  - TaskCreate
  - TaskUpdate
  - TaskList
  - TaskGet
  - Task
  - Agent
  - TeamCreate
  - TeamDelete
  - SendMessage
  - AskUserQuestion
  - Skill
---

# /implement Skill

One workflow executes a work item's `plan.md`, whether the run is standalone or commissioned. Standalone, the implement lead holds the seat. Commissioned by `/coordinate`, the coordinator holds the seat and the implement lead carries out the same steps; the seat is bound once, at entry, and nothing below changes with who holds it. Every dispatched worker and designer reads a compiled position brief bound to its task, with a knowledge packet built for that move. Commands record execution evidence — results, reviews, reports, claims — and the seat reads that evidence and records acceptance and closure. Records describe plans, commands, reviews and text; none of them scores an agent.

The mechanical verbs (`lore impl start | gate-anchor | open | next-batch | check-report | consult-log | promote-batch | close`, plus the evidence writers named where they are used) file judgments; they never make them. Each validates the vocabulary it receives and refuses a token it does not know, so the canonical words below are load-bearing: anchor verdict `aligned | misaligned-respec | misaligned-override | abort | legacy-skip` and route `continue | respec | abort` (`gate-anchor`); consultation handler `lead | skill | agent` (`consult-log`, `check-report`); closure verdict `full | partial | none` (`close`). Rename one only after changing the verb's contract in the same commit.

Work from confidence. Most mistakes are recoverable through ordinary review, and deferring a settled step costs more than an occasional error caught later. Defer at a genuine fork the protocol does not pre-decide, or before a destructive or shared-state operation; not as a default.

Every runnable command in this file is an exact recipe: its inputs are declared on the line before it as environment variables, and each recipe runs on its own in a fresh shell, so carry values between steps as variables you set from earlier output. A test executes these recipes against isolated stores, which is why a body cannot carry placeholders. Shapes shown in `text`, `json`, or `yaml` fences are data for reading, not commands.

### Step 1: Enter and read the revision

**Recipe inputs:** none.
<!-- implement-recipe: resolve-paths -->
```bash
KNOWLEDGE_DIR="$(lore resolve)"
WORK_DIR="$KNOWLEDGE_DIR/_work"
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$(command -v lore)")")/../scripts" && pwd -P)"
SKILL_FILE="$(cd "$SCRIPTS_DIR/.." && pwd -P)/skills/implement/SKILL.md"
LEAD_TEMPLATE_VERSION="$(bash "$SCRIPTS_DIR/template-version.sh" "$SKILL_FILE")"
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'KNOWLEDGE_DIR=%s\nWORK_DIR=%s\nSCRIPTS_DIR=%s\nSKILL_FILE=%s\nLEAD_TEMPLATE_VERSION=%s\nRUN_STARTED_AT=%s\n' \
  "$KNOWLEDGE_DIR" "$WORK_DIR" "$SCRIPTS_DIR" "$SKILL_FILE" "$LEAD_TEMPLATE_VERSION" "$RUN_STARTED_AT"
```

Hold those six values for the run. `SCRIPTS_DIR` is the scripts directory beside the `lore` CLI you are running, so direct script calls exercise the same checkout as the verbs. `LEAD_TEMPLATE_VERSION` is this file's hash and stamps every entry the seat files; `RUN_STARTED_AT` is consumed by close. Then render the standing defaults and treat them as binding for the run:

**Recipe inputs:** none.
<!-- implement-recipe: lore-defaults -->
`lore defaults`

They carry the role and model maps, the coordination concurrency ceiling, ceremony registrations, sampling rates and the preference directives by title. Resolve the worker ceiling there and lower it to the runtime capacity you actually have; never replace it with a per-run constant, and treat a missing or malformed concurrency value as one writer seat. Parse arguments: `--model <id>` exports `LORE_MODEL_LEAD` for this run only and touches no worker or advisor binding (per-role `LORE_MODEL_<ROLE>` overrides are honored independently); `--yes` suppresses one prompt, the anchor gate's misaligned-route question, and nothing else — the gate is still evaluated and filed, and the archived-item confirmation stays interactive.

**Bind the seat.** Commissioned entry arrives with a packet id and pointer from the coordinator; check that packet against the move you were given with `lore packet show <id>`, and treat its entries as candidates to verify against the code rather than as receipt. Standalone entry builds the seat's own packet: `lore packet build --work-item "$SLUG" --role coordinator --caller implement-lead --topic "<what this run changes>" --scale-set <bucket>`. A packet identifies assembled context; it is not receipt and not acceptance. Each entry you are handed carries a byline naming who captured it and during what work; the byline locates context and says nothing about how much to trust the entry. Later tasks, consultations and reviews each get their own packet at their declared scale.

**Start the run through the start verb — the sole entry envelope.** Do not improvise resolution with `ls`, `find` or directory listing, and do not hand-run the plan validation, branch cache, claims parsing or model resolution it absorbs:

**Recipe inputs:** INPUT.
<!-- implement-recipe: impl-start -->
`lore impl start "$INPUT" --compiled-positions --json`

`start` resolves the reference, validates a structured plan with unchecked work, returns the title and `intent_anchor` verbatim with prior claims, models, template versions and branch-cache status, and compiles the worker and designer briefs for the active framework and every resolved target, returned under `position_descriptors`. Exit `1` is no match, no `plan.md` (run `/spec` first) or no unchecked task — report the verb's message and stop; exit `2` is an ambiguous reference — disambiguate with `AskUserQuestion` from the candidates and re-invoke. Bind from the struct: `SLUG`, `ITEM_DIR` (`$WORK_DIR/<slug>`, or `$WORK_DIR/_archive/<slug>` when `archived: true`, which warns and waits for explicit confirmation, since the writing verbs refuse archived items), `INTENT_ANCHOR`, the three models, `WORKER_TEMPLATE_VERSION` and `ADVISOR_TEMPLATE_VERSION` (legacy meanings kept for the per-run `promote-batch` and `close` flags) and the prior-claims maps. Keep `worker_class_models` as the raw scalar bindings displayed for compatibility, and bind `worker_class_routes` as the structured dispatch map: each class route carries exactly `binding`, `source_framework`, `target_framework`, `native_binding` and `qualified`. Descriptors are snapshots, not launch identities; each dispatch compiles its target again.

Read the item's evidence beside its plan:

**Recipe inputs:** SLUG.
<!-- implement-recipe: work-show -->
`lore work show "$SLUG" --json`

It returns the plan, notes, revision head, results, reviews and `packet_summary` with each packet's binding as `current`, `stale`, `legacy-unbound`, `unknown` or `invalid`. Then read `$ITEM_DIR/plan.md` and `$ITEM_DIR/notes.md` directly: the verb validated structure, and the judgments below read content. Present the verb's operator lines (models, task counts, prior claims, the verbatim anchor) and proceed.

**Anchor gate — mandatory, lead-attested, never skipped.** Decide whether the plan as written delivers the capability the anchor names. No script adjudicates this; the sibling `verify-plan-intent-anchor.sh` checks the block's presence, never its coverage. Start-time verdicts are binary, aligned or misaligned; `partial` exists only at closure. On aligned, write a one-line **anchor fit statement**. On misaligned, name the gap in one line and route: `misaligned-respec` for a capability-level gap (the default, and what `--yes` selects); `misaligned-override` for a scope-level gap you can state as a one-line scope delta naming in-scope versus deferred; or escalate through `AskUserQuestion` when the gap straddles both or the cost of being wrong is high, restating the anchor body verbatim with options re-spec (recommended), override with a scope delta, or abort — abort exists only on that path. A start struct with no anchor takes `legacy-skip`: no prompt, no fit statement, still filed so the audit loop fires. File every verdict through the verb; it reads the anchor from `_meta.json`, encodes free text as single log lines and owns the six-field row, and it refuses any field its verdict does not define (`--fit` only on aligned; `--gap` on the three misaligned and abort verdicts; `--scope-delta` only on override):

**Recipe inputs:** SLUG, VERDICT, FIT, GAP, SCOPE_DELTA, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: gate-anchor -->
```bash
args=("$SLUG" --verdict "$VERDICT" --template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$FIT" ]] && args+=(--fit "$FIT")
[[ -n "$GAP" ]] && args+=(--gap "$GAP")
[[ -n "$SCOPE_DELTA" ]] && args+=(--scope-delta "$SCOPE_DELTA")
lore impl gate-anchor "${args[@]}"
```

The verb prints `Route:`. `continue` (aligned, override, legacy-skip) proceeds; `respec` exits with `Next: run /spec <slug>` and control returns to the user; `abort` exits immediately. Both exits fire before any dispatch, edit or notes write — the gate row and start's branch cache are the only side effects, so an aborted run leaves no stale artifacts. An override also writes a timestamped **Anchor-coverage override:** entry to `notes.md`.

**Revision identity.** A plan is a document with a history: every change publishes a revision, `progress` when only checkbox state moved, `semantic` otherwise, and packets, results and reviews name the revision they answered. `open` and `next-batch` reconcile drift through the revision writer before selecting work, so there is no checksum prompt to answer. Two cases need the seat's hand before dispatch. A legacy item with no revision history must be adopted before a compiled worker can complete, because compiled completion requires bound task, revision and packet identity and inventing a revision would put a made-up identity on the record built to prevent them:

**Recipe inputs:** SLUG.
<!-- implement-recipe: plan-reconcile -->
`lore plan revise "$SLUG" --reconcile`

Reconcile refuses an item that has no `tasks.json` at all; that item is adopted by publishing its first revision with the plan-publish recipe below, which writes the projection through the revision writer (`lore work tasks` only prints a generation to stdout).

And a semantic revision leaves its changed tasks with `pending` anchor coverage and review requirement; such a task is excluded from dispatch until you record coverage and a dispatch decision. A review requirement of `required` or `pending` alone does not exclude a task — covered anchor plus an explicit `proceed`, or a `reuse` naming a prior review and why its scope still applies, makes it eligible while the review is outstanding, because the requirement records an obligation and the seat owns when to run against it. Attempts already running keep the revision they were dispatched under. Record decisions through the writer, which validates the task ids against the target revision:

**Recipe inputs:** SLUG, REVISION_ID, DECISION_ID, DECISIONS_FILE.
<!-- implement-recipe: plan-decision -->
`lore plan revise "$SLUG" --decision-for "$REVISION_ID" --decision-id "$DECISION_ID" --decisions "$DECISIONS_FILE"`

The file carries any of `anchor_coverage` (`covered | not-covered | pending`), `review_requirement` (`required | not-required | pending`, with `prior_review_refs`) and `dispatch_decision` (`proceed | wait | reuse`, with `task_ids` and `prior_review_refs`), each with authored `by` and `note`; the writer accepts no other object, so acceptance rationale goes in notes, not here:

```json
{"anchor_coverage": {"disposition": "covered", "by": "implement-lead", "note": "task-2 delivers the named capability"},
 "dispatch_decision": {"disposition": "proceed", "by": "implement-lead", "note": "review outstanding; scope unchanged", "task_ids": ["task-2"], "prior_review_refs": []}}
```

A sealed review also needs a stored original anchor. When the item has none and existing owner intent settles it, record that capability, preserve it in the plan, and publish the revision; never infer an anchor from shipped code at closure, and when no owner intent exists leave the review unavailable and ask for the missing intent:

**Recipe inputs:** SLUG, INTENT_ANCHOR.
<!-- implement-recipe: set-intent-anchor -->
`lore work set "$SLUG" --intent-anchor "$INTENT_ANCHOR"`

**Recipe inputs:** SLUG, REASON.
<!-- implement-recipe: plan-publish -->
`lore plan revise "$SLUG" --reason "$REASON"`

### Step 2: Prepare the next move

**Open the dispatch.** Selection is your declaration — every task, or a subset by id when resuming or staging across sessions; there is no default. `open` reconciles the plan first, then returns the manifest, collisions, prior knowledge, lead-inline conditions and, with `--compiled-positions`, each task's `position_binding_inputs`:

**Recipe inputs:** SLUG, TASK_IDS, FALLBACK_SCALE_SET, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: impl-open -->
```bash
args=("$SLUG" --compiled-positions --json --template-version "$LEAD_TEMPLATE_VERSION")
if [[ -n "$TASK_IDS" ]]; then for id in $TASK_IDS; do args+=(--task "$id"); done; else args+=(--all); fi
[[ -n "$FALLBACK_SCALE_SET" ]] && args+=(--fallback-scale-set "$FALLBACK_SCALE_SET")
lore impl open "${args[@]}"
```

What it returns, and what each part is for:

- **Generation reconciliation.** Plan drift publishes a revision, a torn projection is repaired from the committed snapshot, an identical generation returns the current revision. Structural anchor failure is a hard exit `1`, a plan defect rather than drift. Only a legacy item with no `tasks.json` needs its first revision published (Step 1) before `open` can run. A changed semantic task without coverage or a dispatch decision is excluded, not prompted about — recording the decision is your Step 1 work, and the ready tasks dispatch as usual.
- **`manifest`** — TeamCreate, then one TaskCreate per eligible task in `tasks.json` order, then TaskUpdate wiring whose `add_blocked_by` edges are complete; edges outside the selection surface as `external_blocked_by` for you to wire against already-created tasks. An empty manifest is success with a `status`. **`collisions`** are same-file intersections already folded into serialization edges; cross-selection collisions are not detected, so on a subset you account for files held by unselected or in-flight tasks yourself. Known overlap consolidates or receives an explicit edge before dispatch; worktree isolation never waives ownership.
- **`capabilities.team_messaging`** — `full | partial | fallback | none`, one input to the probe below, never a proxy for the whole subagent surface.
- **`unit_map`, `prior_knowledge`, `packets`** — knowledge resolved per brief owner through the shared packet builder at the plan's declared scale; a description already carrying `## Prior Knowledge` skips prefetch so nothing is duplicated. A unit returning `status: needs-prefetch` wants a scale declaration you have not made: declare the bucket per `skills/memory/SKILL.md` § Scale-Aware Navigation, re-run `open` with `--fallback-scale-set`, and file one `Knowledge-delivery-path: lead-fallback-prefetch` line through the lead-log recipe below so the delivery gap is visible to the retrospective. Resolve every `needs-prefetch` before launching a worker.
- **Packet identity** — every preparation allocates a fresh `dispatch_attempt_id` per task and puts `packet_id`, `revision_id` and `dispatch_attempt_id` on the TaskCreate and `packets[]` entries; on a legacy item the last two are null. Carry the tuple unchanged into the worker's bindings. A running attempt keeps the identity it was stamped with when the plan moves; a later `open` or `next-batch` writes a new packet against the current generation. Assembly is not receipt.
- **`tier2_extracts`** — prior canonical rows per task, matched by task id or file overlap; they travel to the worker as the prior-evidence block the wrapper recipe appends, and an empty extract adds nothing.
- **`skill_invocation_map`** (plan `**Related skills:**` merged with `lore ceremony get implement`, each with its `skill_template_version`), **`advisors`** (`mode: persistent` declarations only; other advisor annotations are handled inline by the seat and spawn nothing), and **`lead_inline_conditions`** as four separate fields with a `detail` block, never an aggregate boolean.
- **`position_binding_inputs`** on each TaskCreate entry: work item, task, revision, packet id and pointer, dispatch attempt and the exact assignment, copied from the entry's own description. Report id, report path and execution root are yours to add after placement; consultation fields do not exist until a worker asks. Nothing is published by `open`.

**Choose the route by capability and ownership, not by framework name.** Probe what the selection needs: a spawn surface, direct result collection, completion enforcement that is `native_blocking` or `lead_validator` (`self_attestation` or `unavailable` disqualifies dispatch, because a worker's own word is never acceptance evidence), and a way to land each report at its canonical path before checking it. Probe messaging only when the selection needs it — declared `**Consultations required:**` domains, persistent advisors, or steering you intend:

**Recipe inputs:** SCRIPTS_DIR.
<!-- implement-recipe: probe-operations -->
```bash
source "$SCRIPTS_DIR/lib.sh"
FRAMEWORK="$(resolve_active_framework)"
ADAPTER="$LORE_REPO_DIR/adapters/agents/$FRAMEWORK.sh"
printf 'framework=%s\nsubagents=%s\nteam_messaging=%s\ntask_completed_hook=%s\ncompletion_enforcement=%s\n' \
  "$FRAMEWORK" "$(framework_capability subagents)" "$(framework_capability team_messaging)" \
  "$(framework_capability task_completed_hook)" "$(bash "$ADAPTER" completion_enforcement)"
```

Three routes exist for a worker, and the seat chooses per task. **Session** is the default: an item-backed worker session whose tree the claiming host allocates under ordinary placement, or a fixed placement in a tree the seat already holds. **Native** is the same-framework subagent (Claude Code `Agent`, Codex `spawn_agent`), used when its readiness check passes; a mutating native worker is admitted only inside a tree allocated to the dispatching seat, and a foreign Codex target rides the existing chaperone. **Lead-inline** executes the task at the seat. A failed native readiness check is a fact about that boundary and never permission to substitute a generic agent while keeping compiled attribution; the task takes a fresh session attempt instead. Whether a reply can reach a running worker mid-task is a property of the live surface for that handle, which the probe and the tool's own follow-up operations establish, not of the framework's name; where none exists, a task with required consultations on that route is a boundary to record, not a reason to drop the requirement.

**Lead-inline has two doors, and selecting either is provisional until the read-back in Step 4 proves one landed report per task.** Capability collapse: the probe disqualifies dispatch (no spawn surface, no result collection, enforcement at self-attestation, no way to land a report, or a messaging-requiring selection with no messaging and no session route chosen). You then execute every selected task serially in dependency order, still performing every judgment, consultation and skill obligation yourself, and when no route at all can land and validate the report, you refuse the run rather than audit a transcript. Efficiency collapse, on a capable harness: all four conditions hold — `single_task`, `prescriptive` (`**Task format:** prescriptive`; intent-and-constraints work needs a worker's discretion), `no_persistent_advisor`, and `no_required_consultation` (no required domains, empty ceremony list, no `**Related skills:**`). One carve-out: when the fourth is false only because `detail.related_skills` is non-empty, the route stays eligible provided you invoke each skill with the `Skill` tool first and log it. There is no file-count cap; a fifty-file prescriptive rename is fifty edits with no discretion, and `detail.file_count_diagnostic` is telemetry. Context estimates are advisory: the generator's fixed `context_cost_estimate` (basis `legacy-fixed-character-estimate`) and, once an attempt is bound, the manifest's measured payload projected as `dispatch_context`; neither selects a worker, gates a dispatch or weights a report. If you are unsure a prescriptive task is fully determined, dispatch a worker; that pause exists only on the efficiency door. Log the selection without claiming the collapse fired (`Lead-inline execution: route selected` / `Route:` / `Task count:`), then run the same local steps a worker would — edits, claims, report, reduction, read-back — under truthful lead attribution.

**Budget concurrency.** Dispatch ready work up to the settings ceiling bounded by runtime capacity; for coordinated work intersect with `lore coordinate status` so only `act_now` streams with no active attempt and terminal full-and-cleaned predecessors launch. Group tasks by judgment class: `mechanical` → `worker-mechanical`, `standard` or null → `worker`, `judgment-dense` → `worker-judgment-dense`; a collision chain runs at its `chain_class`. An explicit per-run model or route pin wins over class bindings; otherwise the class's `worker_class_routes` entry supplies `native_binding` and `target_framework`. Designers resolve through the `advisor` role:

**Recipe inputs:** SCRIPTS_DIR, ROLE.
<!-- implement-recipe: resolve-role-model -->
```bash
source "$SCRIPTS_DIR/lib.sh"
bash "$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh" resolve_model_for_role "$ROLE"
```

**Bind the assignment.** Assign the report id first — filesystem-safe and attempt-specific, `<task-id>-r<attempt>`, fresh on every re-dispatch because the binder refuses an id another attempt holds and the report writer refuses an existing path. Then normalize the task's identity from `open` or `next-batch` output into a bindings file. Both shapes carry `local_id`, `description`, `packet_id`, `dispatch_attempt_id` and `revision_id`; the recipe reads whichever it is given, and refuses a legacy-unbound task with the adoption step it needs. `EXECUTION_ROOT` is the allocated directory for a native, chaperoned or fixed-placement worker (the checkout it reads, for a read-only task) and empty for an ordinary session, whose host supplies the tree after the request is claimed:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DISPATCH_JSON, TASK_ID, SLUG, REPORT_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- implement-recipe: normalize-bindings -->
```python
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from packet_builder import pointer
kdir = Path(os.environ["KNOWLEDGE_DIR"]).resolve()
data = json.loads(Path(os.environ["DISPATCH_JSON"]).read_bytes())
task_id, slug = os.environ["TASK_ID"], os.environ["SLUG"]
entries = [e for e in data.get("manifest", []) if e.get("op") == "TaskCreate"] + list(data.get("batch", []))
task = next((e for e in entries if e.get("local_id") == task_id), None)
if task is None:
    sys.exit(f"task {task_id} is not in this dispatch output; it is complete, blocked, excluded or active")
inputs = task.get("position_binding_inputs") or {
    "work_item": slug, "task_id": task_id, "revision_id": task.get("revision_id"),
    "packet_id": task.get("packet_id"), "dispatch_attempt_id": task.get("dispatch_attempt_id"),
    "assignment": task["description"],
    "packet_pointer": pointer(kdir, task["packet_id"]) if task.get("packet_id") else None}
missing = [k for k in ("task_id", "revision_id", "packet_id", "dispatch_attempt_id") if not inputs.get(k)]
if missing:
    sys.exit("legacy-unbound task; adopt the item with lore plan revise --reconcile before compiled dispatch: " + ", ".join(missing))
fields = ("work_item", "task_id", "revision_id", "packet_id", "packet_pointer", "dispatch_attempt_id", "assignment",
          "report_id", "report_path", "execution_root", "mode", "consultation_id", "domain", "reply_destination")
b = dict.fromkeys(fields)
b.update(inputs)
report_id = os.environ["REPORT_ID"]
b.update(report_id=report_id, report_path=str(kdir / "_work" / slug / "worker-reports" / (report_id + ".md")),
         execution_root=os.environ["EXECUTION_ROOT"] or None)
reasons = {k: "designer consultation fields do not apply to a worker" for k in ("mode", "consultation_id", "domain", "reply_destination")}
if b["execution_root"] is None:
    reasons["execution_root"] = "the ordinary session host supplies its physical worktree"
b["absence_reasons"] = reasons
Path(os.environ["BINDINGS_FILE"]).write_text(json.dumps(b, indent=2) + "\n")
print(json.dumps({k: b[k] for k in ("task_id", "revision_id", "packet_id", "dispatch_attempt_id", "report_id", "execution_root")}))
```

Render guidance and compile the selected target immediately before binding, once per launch and retry. The rendered block becomes the payload's first component, so nothing is prepended at the tool call; a second copy would change the bytes the manifest records. The descriptor's `template_version` is the producer version this worker will stamp as `Template-version:`; hold it per attempt as `PRODUCER_TEMPLATE_VERSION` (or `DESIGNER_TEMPLATE_VERSION` for a designer), never substituting the start snapshot or this skill's own hash:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, POSITION, TARGET_FRAMEWORK, GUIDANCE_FILE, DESCRIPTOR_FILE.
<!-- implement-recipe: compile-position -->
```bash
lore dispatch guidance > "$GUIDANCE_FILE"
bash "$SCRIPTS_DIR/position-compile.sh" "$POSITION" --framework "$TARGET_FRAMEWORK" \
  --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE" > "$DESCRIPTOR_FILE"
python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["template_version"])' "$DESCRIPTOR_FILE"
```

This skill is the wrapper around the compiled brief: its identity (`implement/skill`, this file's hash and digest) is recorded on the manifest apart from the producer's, so both stay attributable and an edit here never moves the brief's version. The prefix is the identity lines the packet assessor and the worker read — `Packet-id:`, `Report-id:`, `Revision-id:`, `Dispatch-attempt-id:` — and the suffix is the dispatching note below, which tells the worker what the brief cannot know: its route, where its report goes, how a consultation travels, and the placement rule. `ROUTE` is `native`, `chaperone`, `session` or `designer`; `PLACEMENT_NOTE` names the worktree, stream, attempt and lease owner for a mutating tree, or says the task is read-only; `TIER2_EXTRACT_FILE` may be empty:

**Recipe inputs:** SKILL_FILE, BINDINGS_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, ROUTE, WORK_TITLE, TARGET_FRAMEWORK, TEAM_NAME, LEAD_NAME, PLACEMENT_NOTE, TIER2_EXTRACT_FILE.
<!-- implement-recipe: author-wrapper -->
```python
import hashlib, json, os
from pathlib import Path
E = os.environ
skill = Path(E["SKILL_FILE"]).resolve()
sha = hashlib.sha256(skill.read_bytes()).hexdigest()
Path(E["WRAPPER_FILE"]).write_text(json.dumps({"template_id": "implement/skill", "template_version": sha[:12], "path": str(skill), "sha256": sha}))
b = json.loads(Path(E["BINDINGS_FILE"]).read_bytes())
ids = [("Packet-id", b["packet_id"]), ("Report-id", b["report_id"]), ("Revision-id", b["revision_id"]), ("Dispatch-attempt-id", b["dispatch_attempt_id"])]
Path(E["PREFIX_FILE"]).write_text("".join(f"{k}: {v}\n" for k, v in ids if v))
route, slug, task = E["ROUTE"], b["work_item"], b["task_id"] or "(consultation)"
path = {"native": "harness-subagent", "chaperone": "codex-chaperone", "session": "worker-session", "designer": "designer-consultation"}[route]
digest = ("the two environment variables LORE_POSITION_DISPATCH_MANIFEST and LORE_POSITION_DISPATCH_SHA256" if route == "session"
          else "the sha256 you compute over the manifest file the envelope names")
note = [f"## From the dispatching lead\n\nThe implement lead for {E['WORK_TITLE']} dispatched you on the {route} route for task {task} of work item {slug}"
        + (f", on team {E['TEAM_NAME']} led by {E['LEAD_NAME']}" if E["TEAM_NAME"] else "") + ". The identity envelope above is the binder's record of this attempt. "
        "Your assignment is position_dispatch.bindings.assignment, the complete task description. The Packet-id line names a packet built for this move; "
        "lore packet show renders it, and its entries are candidates to check against the code. Revision-id and Dispatch-attempt-id name the plan revision and this attempt. "
        f"Work in position_dispatch.bindings.execution_root and allocate no other tree. {E['PLACEMENT_NOTE']}"]
if route == "designer":
    note.append("You are the persistent advisor for the domain in position_dispatch.bindings.domain, answering the worker request carried verbatim in the assignment. "
                "Read current code in the execution root before answering a question about current behavior; the baseline in the assignment is older than the file the worker asks about. "
                "Write the reply to position_dispatch.bindings.reply_destination and return the same text as your result. Its first four lines are the headers the ledger joins on: "
                "consultation-id (from the assignment), handler: agent, advisor_template_version (position_dispatch.producer.template_version), advisor-acknowledged: true; then "
                "**Domain:**, **Guidance:**, **Key files:**, **Cautions:**. You stay available: a later question arrives with its own envelope and destination. "
                "Tier 2 rows you append carry producer_role advisor. You implement no source and complete no task.")
else:
    note.append(f"Write the schema 1 report with these header lines first, plain, one per line: Report-schema: 1, Report-id and Work-item from the envelope, Task: <the task subject>, "
                f"Producer-role: worker, Dispatch-path: {path}, Harness: {E['TARGET_FRAMEWORK']}, Status:, Template-version: position_dispatch.producer.template_version, "
                f"Position-dispatch-manifest: the envelope's manifest_path, Position-dispatch-sha256: {digest}, then Packet-id:, Revision-id:, Dispatch-attempt-id:. "
                f"Tier 2 rows go through evidence-append.sh --work-item {slug} with task_id {task} as each claim forms; the report lists claim IDs only. "
                f"Close criteria run through lore criteria run {slug} {task} <criterion-id> --execution-worktree \"$PWD\" --packet-id {b['packet_id']}; cite result IDs.")
    if route == "session":
        note.append("You run as a hosted worker session, and no lead collects a session's message: land the report yourself with "
                    f"printf '%s' \"$REPORT\" | lore coordinate report {slug} --report-id {b['report_id']}. Exit 4 means a file already exists at that path and the id was used before; "
                    "record that under Blockers as written. Exit 1 means the arguments, environment or an empty body were wrong; read the message and correct the call. "
                    "After the report has landed and the rows are appended, end the session with lore session close --self --reason protocol_terminus. "
                    "A required consultation goes in this session's output as a ## Consultation request (consultation-id, domain, reason, question, task); the lead can reach this session with lore session send. "
                    "If no reply arrives, record the domain and how long you waited under Blockers rather than implementing past the requirement.")
    elif route == "chaperone":
        note.append("The chaperone that launched you relays your final message verbatim and lands it at the bound report path; do not land it yourself. "
                    "A required consultation is a ## Consultation request in your output; wait for the reply before implementing past the requirement.")
    else:
        note.append("Return the finished report as your final message; the lead lands it at the bound report path and checks it against its own copy of this attempt's reference. "
                    "A required consultation travels the same way: return the ## Consultation request (consultation-id, domain, reason, question, task) as your message and stop; "
                    "the reply sent to your name resumes you.")
extract = Path(E["TIER2_EXTRACT_FILE"]).read_text() if E["TIER2_EXTRACT_FILE"] else ""
if extract.strip():
    note.append("Prior Tier 2 evidence for this task, from task-claims.jsonl:\n\n" + extract.rstrip() + "\n")
Path(E["SUFFIX_FILE"]).write_text("\n\n".join(note) + "\n")
```

Bind, or prepare. Every route except an ordinary-placement session binds here, freezing payload, native definition and manifest under `position-dispatch/<attempt-id>/` and returning the six-field reference (`manifest_path`, `manifest_sha256`, `payload_path`, `payload_sha256`, `native_path`, `native_sha256`) — your independent copy of this attempt's identity, held per task and never read back from the report. `REQUIRED_BINDINGS` is `task_id revision_id packet_id packet_pointer` for a worker and `packet_id packet_pointer` for a designer; `NATIVE_MODEL` is set on the two native routes and empty on the chaperone and fixed-session routes, where the payload is consumed as a primary prompt. An identical retry returns the same reference; a changed payload under the same attempt refuses; a real retry mints a fresh attempt and report id:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, REQUIRED_BINDINGS, NATIVE_MODEL.
<!-- implement-recipe: bind-attempt -->
```bash
args=(--descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE"
      --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE")
for field in $REQUIRED_BINDINGS; do args+=(--require "$field"); done
[[ -n "$NATIVE_MODEL" ]] && args+=(--native-model "$NATIVE_MODEL")
python3 "$SCRIPTS_DIR/position-bind.py" bind "${args[@]}"
```

**Native launch.** The lead performs the actual tool calls; a CLI verb cannot. On Claude Code the compiled definition has to be a name the running session's `Agent` tool offers, and the binder owns the file: pass `AGENTS_SCOPE`, an absolute `.claude/agents` directory this session watches (`resolve_harness_install_path agents` names the user-level one), and the recipe registers before rendering the input. On Codex leave `AGENTS_SCOPE` empty; nothing is registered because Codex takes the prepared text directly:

**Recipe inputs:** SCRIPTS_DIR, MANIFEST_PATH, MANIFEST_SHA256, AGENTS_SCOPE.
<!-- implement-recipe: native-input -->
```bash
if [[ -n "$AGENTS_SCOPE" ]]; then
  python3 "$SCRIPTS_DIR/position-bind.py" register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE" >&2
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
else
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256"
fi
```

`tool_input` carries the exact payload (`prompt` on Claude Code with `subagent_type` and `model`; `message` with the split model and effort keys on Codex) and `readiness` names the check owed: on Claude Code, that `selection_name` is among the `subagent_type` values the live tool offers — a file on disk is not that check, because a shell cannot see which directories the session watched at startup or whether a higher-precedence definition shadows the name; on Codex, that the live `spawn_agent` accepts the fields. When the check fails, the task stays undispatched on this route and the record names the boundary. Pass `tool_input` as returned — do not rename `prompt`, drop `model`, edit the bytes or add a digest — adding only the tool's own `description`, `team_name` `impl-<slug>`, `name` and `mode` (or a Codex `task_name` and non-inheriting fork setting), and keep the handle the tool returns. When the route has shared task state, TeamCreate runs before TaskCreate so tasks land in the team's list rather than orphaned in the session's default; the session default needs no unused team. On the native routes you hold the team task: set `owner` at launch, re-read it once before the call because another lead on the same team could have taken it, and record the reference as `metadata.position_dispatch` with `metadata.lore_task_id` so the completion hook reads it from there. A mutating native worker needs a tree allocated to this seat first (`STREAM_ID` and `ATTEMPT_ID` are the coordination identities you carry into the dispatch; read-only work needs no worktree, and a worker never allocates):

**Recipe inputs:** SLUG, STREAM_ID, ATTEMPT_ID, OWNER_ID, SOURCE_DIR.
<!-- implement-recipe: allocate-worktree -->
`lore coordinate worktree allocate --work-item "$SLUG" --stream "$STREAM_ID" --attempt "$ATTEMPT_ID" --owner-kind seat --owner-id "$OWNER_ID" --source-dir "$SOURCE_DIR" --json`

**Session launch.** Under ordinary placement nothing can be published yet, so the context is the binder's pending preparation, which retains the exact wrapper source, prefix, suffix and activation so the host publishes exactly what was admitted. `SESSION_SLUG` is the derived `<slug>--w<n>`; the report still belongs to the base work item:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, SESSION_SLUG, CONTEXT_FILE.
<!-- implement-recipe: prepare-session -->
```bash
python3 - "$SCRIPTS_DIR" "$KNOWLEDGE_DIR" "$DESCRIPTOR_FILE" "$BINDINGS_FILE" "$GUIDANCE_FILE" "$WRAPPER_FILE" "$PREFIX_FILE" "$SUFFIX_FILE" "$SESSION_SLUG" > "$CONTEXT_FILE" <<'PY'
import importlib.util, json, sys
from pathlib import Path
scripts, kdir, descriptor, bindings, guidance, wrapper, prefix, suffix, slug = sys.argv[1:]
sys.path.insert(0, scripts)
spec = importlib.util.spec_from_file_location("binder", Path(scripts) / "position-bind.py")
binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
context = binder.prepare_session_input(json.loads(Path(descriptor).read_bytes()), json.loads(Path(bindings).read_bytes()),
                                       Path(kdir), Path(guidance).read_bytes(), slug=slug, wrapper=json.loads(Path(wrapper).read_bytes()),
                                       prefix=Path(prefix).read_bytes(), suffix=Path(suffix).read_bytes())
print(json.dumps(context))
PY
```

Under fixed placement — a manager-owned worktree already allocated to this seat — bind with the recipe above (no `NATIVE_MODEL`), write `{"dispatch_guidance": <payload text>, "position_dispatch": <reference>}` as the context, and pass the worktree pair; the host revalidates that exact root and a published attempt never moves. A worker request also requires the item to declare its source checkout, so the host knows which clone the session belongs in; a session-hosted seat seeds it once with `lore work source-checkout <slug>` from its own provenance, and the request is refused with that remedy until it exists. Enqueue with exactly one placement stance (`TARGET_INSTANCE` names one live instance, otherwise any instance may claim), and without `--position` or `--packet`, which would select generic preparation or add a second packet line instead of preserving the admitted composition:

**Recipe inputs:** SESSION_SLUG, TARGET_FRAMEWORK, WORKER_MODEL, CONTEXT_FILE, TARGET_INSTANCE, MIN_VINTAGE, WORKTREE_ID, EXECUTION_DIR.
<!-- implement-recipe: request-session -->
```bash
args=(--type worker --slug "$SESSION_SLUG" --framework "$TARGET_FRAMEWORK" --model "$WORKER_MODEL"
      --context "$CONTEXT_FILE" --initiator agent --json)
if [[ -n "$TARGET_INSTANCE" ]]; then args+=(--target "$TARGET_INSTANCE"); else args+=(--anywhere); fi
[[ -n "$MIN_VINTAGE" ]] && args+=(--min-vintage "$MIN_VINTAGE")
[[ -n "$WORKTREE_ID" ]] && args+=(--worktree-id "$WORKTREE_ID" --execution-dir "$EXECUTION_DIR")
lore session request "${args[@]}"
```

Retain the context file and the request id. After the host publishes, collect the attempt's reference independently of the report, together with the `completion_input` Step 4 uses:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, CONTEXT_FILE.
<!-- implement-recipe: session-reference -->
`python3 "$SCRIPTS_DIR/position-bind.py" session-reference --kdir "$KNOWLEDGE_DIR" < "$CONTEXT_FILE"`

Its `delivery_proven` is false by design: a prepared payload proves what was admitted, not what a model consumed. Spawn as soon as the bindings exist. The size of the work is not a decision request, and asking for confirmation before dispatch adds a session-spanning delay without adding a check that Step 4 does not already perform. Three things stop dispatch: an unconfirmed archived item, a brief that cannot be compiled and bound (there is then no versioned prompt to attribute a report to, and an improvised one is not a substitute), or a lead-inline route that already completed the work.

### Step 3: Work and answer

Workers work from the brief. They capture reusable discoveries at the moment of discovery through `lore capture` with their position and the work item, emit canonical Tier 2 rows through `evidence-append.sh` as claims form, run criteria through `lore criteria run`, and return the schema 1 report whose labels `docs/position-report-contracts.md` lists with their readers: `**Artifacts:**`, `**Changes:**`, `**Checks:**`, `**Skills used:**`, `**Observations:**`, `**Tier 2 evidence:**`, optional `**Tier 3 candidates:**` (literal-prefix-matched by the completion hook; no alias is read), `**Convention handling:**`, `**Surfaced concerns:**`, `**Investigation:**`, `**Consultations:**`, `**Blockers:**`, and `**Spend:**` on chaperone-relayed reports only. An Observations block of `- claim: "None"` is complete; there is no observation quota, and a capture already made is not repeated in the report. The tiers are kinds of record with distinct writers — Tier 2 rows validated by `validate-tier2.sh` and appended by `evidence-append.sh`, Tier 3 candidates promoted by `lore promote` — never ranks of agents.

While workers run, three kinds of message come back: a `## Consultation` request carrying `consultation-id:`, a completion report, or a blocker. Answer a consultation immediately so the worker resumes at its next turn boundary; a compiled Claude worker returns the request as its message and stops, a Codex child uses its harness's tools, a session puts it in its output. Steer a blocked worker through the follow-up operation the live surface exposes for its handle (on Claude Code, `SendMessage` to its name; on Codex, the tool's follow-up for the retained handle; for a session, `lore session send`). Where no operation reaches the running worker, a corrected dispatch is a new attempt with fresh attempt and report ids, and the blocked report stays as the record of the first; an unresolvable blocker goes to `notes.md` and independent work continues.

#### Lead consultation handler

The durable consultation record is `$ITEM_DIR/consultation-transcript.jsonl`, one acknowledged reply per line, written only by `lore impl consult-log`. The report check intersects required domains against this file, so an answer that was given but never filed is indistinguishable from one never given; file every reply. Answering is judgment — matching the worker's question to plan, investigation and code — and stays with the seat; only the filing is a verb.

1. **Parse the request body:** `consultation-id` (an opaque token the worker minted), `domain`, `reason`, `question`, `task`.
2. **Route by domain** through `$SKILL_INVOCATION_MAP`, the map `open` returned. **(a)** A skill-backed domain: Invoke the named skill via the `Skill` tool with the worker's question as its argument, capture the output and the map's `skill_template_version`, and set `handler="skill"`. **(b)** No entry: answer inline from your own reading of code, plan and notes, `handler="lead"`; the absent entry is the signal that the seat answers, not a reason to spawn anything. **(c)** The domain of a prepared persistent advisor: the request is what the designer was waiting for. Build its session-scoped packet, bind a consultation attempt, and activate the designer on the first request (below).
3. **Reply via SendMessage** to the worker's name on Claude Code, or by the follow-up operation the live surface exposes for its handle elsewhere. Where none exists, file the consultation all the same, record the boundary, and let the task return blocked rather than re-spawning a worker to carry the answer. The body, in order:

   ```text
   consultation-id: <verbatim from request>
   handler: <skill|lead>
   lead-acknowledged: true
   skill_template_version: <12-char hash from the map, when handler is skill>

   <answer body — concrete, anchored, ready for the worker to apply>
   ```

   `lead-acknowledged: true` is the acknowledgement the required-consultation check reads.
4. **File it immediately** — the transcript record and its execution-log entry in one call. Field contract per handler: `skill` requires `--skill-template-version`; `agent` requires `--advisor-template-version` and, for a compiled designer, the manifest path and digest of the consultation attempt you bound; `lead` takes neither. `--template-version` is your filing version on every handler, never the answerer's. A pair that resolves to this work item, consultation id and domain in consultation mode files as `resolved`; a well-formed pair naming another consultation files as `unknown` with its reason, which the advisor rollup does not score; a resolved manifest whose version disagrees with the one you pass refuses before any write:

   **Recipe inputs:** SLUG, CONSULTATION_ID, WORKER_NAME, DOMAIN, HANDLER, QUESTION, ANSWER, SKILL_TEMPLATE_VERSION, ADVISOR_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256, LEAD_TEMPLATE_VERSION.
   <!-- implement-recipe: consult-log -->
   ```bash
   args=("$SLUG" --consultation-id "$CONSULTATION_ID" --worker "$WORKER_NAME" --domain "$DOMAIN" --handler "$HANDLER"
         --question "$QUESTION" --answer "$ANSWER" --template-version "$LEAD_TEMPLATE_VERSION")
   case "$HANDLER" in
     skill) args+=(--skill-template-version "$SKILL_TEMPLATE_VERSION") ;;
     agent) args+=(--advisor-template-version "$ADVISOR_TEMPLATE_VERSION")
            [[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256") ;;
   esac
   lore impl consult-log "${args[@]}"
   ```

5. Never block other work on a consultation: reply, file, and return to whichever queue the next message arrives on.

**Persistent advisors are compiled designers, prepared at open and activated by the first real question.** The binder needs a consultation id, a domain and a reply destination to publish a consultation attempt, and none exists until a worker asks, so preparation holds the name, domain, baseline (the plan's investigation for that domain) and advisor model, and spawns nothing; `Advisor spawned:` is logged only when a process starts. No advisory mixin is appended to compiled worker prompts: it would describe a messaging channel a compiled worker does not have. On the first request for a domain, build the packet for the question — session-scoped, not task-bound, because a task-bound packet belongs to the worker's attempt and the binder would refuse the collision:

**Recipe inputs:** SLUG, DOMAIN, QUESTION, SCALE_SET.
<!-- implement-recipe: designer-packet -->
`lore packet build --work-item "$SLUG" --role designer --caller implement-lead --topic "$DOMAIN: $QUESTION" --scale-set "$SCALE_SET"`

Then assemble the consultation bindings from the request. The recipe refuses a request that is not a `## Consultation` body with a consultation id, domain and question, because an attempt bound to a malformed request would carry an identity no reply could join:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, REQUEST_FILE, SLUG, PACKET_ID, ADVISOR_NAME, WORKER_NAME, TASK_ID, REVISION_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- implement-recipe: designer-bindings -->
```python
import json, os, re, sys, uuid
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from packet_builder import pointer
E = os.environ
kdir = Path(E["KNOWLEDGE_DIR"]).resolve()
text = Path(E["REQUEST_FILE"]).read_text()
lines = text.strip().splitlines()
fields = {m.group(1): m.group(2).strip() for m in (re.match(r"^([a-z-]+):\s*(.*)$", l) for l in lines[1:]) if m}
missing = [k for k in ("consultation-id", "domain", "question") if not fields.get(k)]
if not lines or lines[0].strip() != "## Consultation" or missing:
    sys.exit("consultation request refused: not a ## Consultation body with " + ", ".join(missing or ["the required headers"]))
cid, domain = fields["consultation-id"], fields["domain"]
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", cid):
    sys.exit("consultation request refused: consultation-id is not a path-safe token")
item = kdir / "_work" / E["SLUG"]
report_id = re.sub(r"[^A-Za-z0-9_.-]", "-", f"{E['ADVISOR_NAME']}-{cid}")
assignment = {"request": text, "worker": E["WORKER_NAME"], "task_id": E["TASK_ID"], "revision_id": E["REVISION_ID"]}
b = {"work_item": E["SLUG"], "task_id": None, "revision_id": None, "packet_id": E["PACKET_ID"], "packet_pointer": pointer(kdir, E["PACKET_ID"]),
     "dispatch_attempt_id": "consult-" + uuid.uuid4().hex, "assignment": json.dumps(assignment), "report_id": report_id,
     "report_path": str(item / "worker-reports" / (report_id + ".md")), "execution_root": E["EXECUTION_ROOT"], "mode": "consultation",
     "consultation_id": cid, "domain": domain, "reply_destination": str(item / "consultation-replies" / (cid + ".md")),
     "absence_reasons": {k: "consultation packet is session-scoped; the worker's task and revision are in the assignment" for k in ("task_id", "revision_id")}}
Path(E["BINDINGS_FILE"]).write_text(json.dumps(b, indent=2) + "\n")
print(json.dumps({k: b[k] for k in ("dispatch_attempt_id", "report_id", "consultation_id", "domain", "reply_destination")}))
```

Compile the designer against fresh guidance, author the wrapper with `ROUTE=designer`, bind with `REQUIRED_BINDINGS="packet_id packet_pointer"` and the advisor model, and activate on the native surface with the native-input recipe; when the name is not offered or the tool rejects the fields, answer inline as `handler: lead` and record the boundary — a generic agent would attribute the reply to a brief nobody read. Log the activation through the lead-log recipe with `Advisor spawned:` / `Domain:` / `Mode: persistent` under `DESIGNER_TEMPLATE_VERSION`, and record framework, model, descriptor version, execution root and handle. A later request for the same domain gets its own packet, bindings and bound attempt, delivered to the running process through its follow-up operation when producer, framework, model and root match the activation; when the compiled version has changed, shut the old designer down with its shutdown line and activate a fresh one, because the running process read a different brief than the new payload names. Where no follow-up operation exists, later requests are answered as `handler: lead` with the boundary noted rather than spawning a replacement per request.

The designer's reply arrives as a file at the reply destination (and as its result where the surface returns one). Check the four headers before anything else — a reply missing one cannot be joined, and the worker's report would be held for a reason that has nothing to do with the worker:

**Recipe inputs:** REPLY_FILE, CONSULTATION_ID, DESIGNER_TEMPLATE_VERSION.
<!-- implement-recipe: check-reply -->
```python
import os, sys
from pathlib import Path
head = Path(os.environ["REPLY_FILE"]).read_text().splitlines()[:4]
want = [f"consultation-id: {os.environ['CONSULTATION_ID']}", "handler: agent",
        f"advisor_template_version: {os.environ['DESIGNER_TEMPLATE_VERSION']}", "advisor-acknowledged: true"]
bad = [w for h, w in zip(head + [""] * 4, want) if h.strip() != w]
sys.exit("designer reply refused; headers missing or wrong: " + "; ".join(bad) if bad else 0)
```

Land it with the land-report recipe under the designer's bound report id, file it with `HANDLER=agent` and the consultation attempt's manifest pair, and forward the body to the worker. The designer's reply is the answer; no `lead-acknowledged` line is added to it. At `all-complete`, send each activated designer its shutdown request and log `Advisor shutdown:` / `Domain:` under its version; a prepared designer no worker ever asked was never a process and gets no line.

### Step 4: Read evidence and accept

**Land the report before anything reads it.** The message body, tool result, task description and adapter envelope are transport; the landed file is the evidence of record, immutable once accepted. The writer refuses an existing path (exit `4`), so a reused id cannot overwrite an earlier attempt; a retry lands under a fresh id. A session or chaperone lands its own report at the bound path — validate that file rather than re-copying the relay:

**Recipe inputs:** SLUG, REPORT_ID, REPORT_BODY_FILE.
<!-- implement-recipe: land-report -->
`lore coordinate report "$SLUG" --report-id "$REPORT_ID" < "$REPORT_BODY_FILE"`

**Compare identity against what you hold.** The report's `Template-version` must equal the producer version you compiled for this attempt, and its `Position-dispatch-manifest` / `Position-dispatch-sha256` must equal the reference the binder (or `session-reference`) returned to you. Agreement means the report answers this attempt; disagreement means it answers some other input, and the task is re-dispatched under fresh ids:

**Recipe inputs:** REPORT_PATH, REFERENCE_FILE.
<!-- implement-recipe: check-identity -->
```python
import hashlib, json, os, sys
from pathlib import Path
ref = json.load(open(os.environ["REFERENCE_FILE"]))
ref = ref.get("reference", ref)
manifest = Path(ref["manifest_path"])
raw = manifest.read_bytes()
if hashlib.sha256(raw).hexdigest() != ref["manifest_sha256"]:
    sys.exit("held reference does not match the manifest bytes; do not read this report against it")
producer = json.loads(raw)["producer"]["template_version"]
headers = dict(l.split(": ", 1) for l in Path(os.environ["REPORT_PATH"]).read_text().splitlines()[:16] if ": " in l)
want = {"Template-version": producer, "Position-dispatch-manifest": str(manifest), "Position-dispatch-sha256": ref["manifest_sha256"]}
bad = [k for k, v in want.items() if headers.get(k) != v]
sys.exit("report answers another input; re-dispatch under fresh ids. mismatched: " + ", ".join(bad) if bad else 0)
```

**Typed completion.** Where no native hook fired for the attempt — a compiled Claude worker returns rather than completing a team task, a session lands a file — run the completion check yourself against your reference (`REFERENCE_FILE` is the six-field reference, or the `session-reference` output whose `completion_input` the recipe uses as is). Exit `0` means the landed report carries the assigned headers, every required label, Tier 2 references that each resolve to one canonical row for this task, and a passing mechanical check. Where a chaperone completed the team task, the hook already ran against the same reference. Neither outcome is acceptance:

**Recipe inputs:** SCRIPTS_DIR, REFERENCE_FILE, TASK_ID.
<!-- implement-recipe: typed-completion -->
```bash
python3 - "$REFERENCE_FILE" "$TASK_ID" <<'PY' | bash "$SCRIPTS_DIR/task-completed-capture-check.sh"
import json, sys
ref = json.load(open(sys.argv[1]))
print(json.dumps(ref.get("completion_input") or {"position_dispatch": ref, "lore_task_id": sys.argv[2]}))
PY
```

**Run the mechanical check with the harness facts the verb cannot read.** Pass the attempt's own `Revision-id`: a plan revised after dispatch may have changed the task, and the attempt owes the consultations it was dispatched with; a task absent from that snapshot is an exit-1 refusal, never an empty required set. `--transcript` is required when the task declares required domains. Source woven-norm labels from the task's `woven_norms` in `tasks.json` (re-derive from `honor <label>` clauses with a same-line backlink when the field is absent). `--provider-status` is needed only when the report carries `handler: agent` consultations, and `full` additionally requires `--spawned-advisors` (empty when none activated):

**Recipe inputs:** SLUG, TASK_ID, REPORT_PATH, REVISION_ID, TRANSCRIPT_FILE, WOVEN_NORMS, PROVIDER_STATUS, SPAWNED_ADVISORS, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: check-report -->
```bash
args=("$SLUG" --task "$TASK_ID" --report "$REPORT_PATH" --template-version "$LEAD_TEMPLATE_VERSION" --json)
[[ -n "$REVISION_ID" ]] && args+=(--revision "$REVISION_ID")
[[ -n "$TRANSCRIPT_FILE" ]] && args+=(--transcript "$TRANSCRIPT_FILE")
for label in $WOVEN_NORMS; do args+=(--woven-norm "$label"); done
if [[ -n "$PROVIDER_STATUS" ]]; then
  args+=(--provider-status "$PROVIDER_STATUS")
  [[ "$PROVIDER_STATUS" == full ]] && args+=(--spawned-advisors "$SPAWNED_ADVISORS")
fi
lore impl check-report "${args[@]}"
```

The verb never accepts or rejects; it runs the checks and files the findings, and every check reports a status so skips are loud. **Tier 2 cross-reference (blocking):** every claim id under `**Tier 2 evidence:**` exists in canonical `task-claims.jsonl`; the substrate is checked, never the report's assertion. **Required-consultation acknowledgement check (blocking):** each `**Consultations required:**` domain has a report entry whose `consultation_id` appears in the transcript with a matching domain — a `lead-acknowledged: true` or advisor-acknowledged reply was actually filed. Lead-side tracking adds one lever the previous pipeline lacked: a report naming a `consultation_id` no acknowledged record matches fails here, so fabricated entries cannot satisfy a required consult. **Convention-handling completeness (non-blocking):** dispositions compared against the woven list; missing, duplicated or unrecognized labels and `none in scope` despite woven norms are findings, never failures, and divergence rationales are filed verbatim for the closure conformance aggregate. **Producer attribution (informational):** the report's manifest pair resolved as `legacy`, `resolved` or `unknown` with reason, and the same for each `handler: agent` entry. **Fabrication guard (non-blocking, metadata-only):** `handler: agent` entries are intersected with `--spawned-advisors` under `--provider-status`: (a) provider OK and every claimed advisor is verified, with any compiled reference resolving to its claimed version — the subset flows to the advisor-impact rollup; (b) Mismatch — each unverified entry is stripped and logged `fabrication-guard: skipped <identifier>`; (c) provider `unavailable`, or `partial` with the spawn surface degraded — the rollup is withheld and `fabrication-guard: provider-<status>; rollup skipped` is logged. Absent verification is never license to attribute, so (c) does not fall through to verbatim-trust of the report; the worker's changes and Tier 2 grounding are unaffected, only advisor scorecard attribution is withheld. Compute the provider status through the canonical consumer pattern:

**Recipe inputs:** SCRIPTS_DIR.
<!-- implement-recipe: provider-status -->
```python
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(os.environ["SCRIPTS_DIR"]).resolve().parent))
from adapters.transcripts import get_provider, UnsupportedFrameworkError
try:
    provider = get_provider()
    status, _reason = provider.provider_status()
except UnsupportedFrameworkError:
    status = "unavailable"
print(status)
```

Exit `3` means `mechanical_pass: false` and the task is rejected: send the `fail_reasons` back to the worker, do not accept, and expect the retry under a fresh report id while the rejected file stays as evidence. Exit `0` means the mechanics passed and acceptance is still yours.

**Run the close criteria through the executor.** A result row means a command ran against a recorded revision and code identity; nobody types one. A schema 2 packet fixes work item, task, revision and attempt, so pass its id; outside a dispatched packet, name the revision and say why the run is unbound. The runner prints the allocated result id and execution attempt on stderr before launch, publishes a single JSON object with `status` `published` or `recovered` and the full row on success, and exits `0` for pass or skipped, `1` fail, `2` unavailable, `3` refused or publication error:

**Recipe inputs:** SLUG, TASK_ID, CRITERION_ID, EXECUTION_ROOT, PACKET_ID, REVISION_ID, UNBOUND_REASON.
<!-- implement-recipe: criteria-run -->
```bash
args=("$SLUG" "$TASK_ID" "$CRITERION_ID" --execution-worktree "$EXECUTION_ROOT" --json)
if [[ -n "$PACKET_ID" ]]; then args+=(--packet-id "$PACKET_ID"); else args+=(--revision "$REVISION_ID" --unbound-reason "$UNBOUND_REASON"); fi
lore criteria run "${args[@]}"
```

States stay distinct and are reported as they are, never rerun until one passes: `pass`; `fail`; `skipped`, meaning only that the applicability predicate observed its declared inapplicable exit (an accepted skip needs that predicate and your explicit rationale); `unavailable`, observed evidence that execution could not provide a usable outcome (launch, cwd, output persistence, inaccessible source, interruption) and neither a fail nor an absence, since retained launch and output facts exist. Freshness is separate from state: a row whose source head, worktree digest, criterion version or revision no longer matches the live root reads stale, a root the reader cannot inspect reads unknown, and only a current pass supports a current passing check. Each run receives an immutable `execution_sequence`, and readers pick the latest attempt per criterion by sequence. An interrupted or unpublished run is recovered without executing anything; recovery keeps the original sequence and refuses conflicting identity or a changed output, and an attempt with no durable completion records `unavailable`. A new execution after a fail is a new run with a new id:

**Recipe inputs:** SLUG, RESULT_ID.
<!-- implement-recipe: criteria-recover -->
`lore criteria run "$SLUG" --recover "$RESULT_ID"`

A task with no executable criteria is an explicit absence of execution evidence: publish appropriate criteria through the revision writer, or record in notes why your acceptance is a prose judgment. Result rows are evidence, not authority: a pass on every criterion does not check off the task, accept the report or close the item, and the runner never does any of those itself.

**Seal an integration review for judgment-dense work.** Mechanical work is accepted on the report's required identity, artifacts and consultation checks plus passing applicable results; it needs no second discretionary test review. Standard work adds your scoped read of the artifacts. Judgment-dense work also gets a review the seat-holder authors: prepare a frozen copy at the attempt's revision against the execution worktree, write the judgment, and seal it once. Storage uses the existing `spec-post-plan` ceremony label with `purpose: integration`; it records an implement integration read and does not invoke `/spec`. Prepare refuses without a stored original anchor (Step 1):

**Recipe inputs:** SLUG, ATTEMPT_ID, REVISION_ID, EXECUTION_ROOT.
<!-- implement-recipe: review-prepare -->
`lore plan review prepare "$SLUG" --attempt-id "$ATTEMPT_ID" --ceremony spec-post-plan --revision "$REVISION_ID" --purpose integration --execution-worktree "$EXECUTION_ROOT" --json`

**Recipe inputs:** SLUG, ATTEMPT_ID, OUTPUT_FILE, DISPOSITIONS_FILE, EVALUATOR_FILE.
<!-- implement-recipe: review-seal -->
`lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" --output "$OUTPUT_FILE" --dispositions "$DISPOSITIONS_FILE" --evaluator-manifest "$EVALUATOR_FILE" --json`

`dispositions.json` carries `schema_version: 1`, `outcome` (`completed | failed | skipped | needs-decision`), `verdict`, `reason` (null unless skipped or needs-decision), `judgments` as `{purpose, judgment, rationale, result_ids}` with the prepared purpose present, and `dispositions` as `{finding, disposition, reason}`; the evaluator manifest is `{evaluator_locator, evaluator_template_version, framework, model, final_round}`. Seal validates each cited result id against `results.jsonl` and freezes the rows; empty `result_ids` records that no execution evidence was cited. A review's `binding.state: current` establishes revision agreement only — its projection does not compare the frozen source identity with live code, so read the prepared source identity before relying on it. Seal preserves the evaluator identity and citations; normalize the outcome without parsing a prose verdict into a decision. Review and executor records never accept the task.

**Accept.** Read the artifacts the report's manifest points at — changed files, canonical claims, result outputs — and weigh substance: scope, blockers, what the checks showed. Then record your acceptance in one sentence with the result and review ids it rests on, before checkoff. Checkoff publishes a progress revision, and result freshness compares exact revision ids, so those rows become historical the moment the box is checked; retain their ids and your applicability reasoning rather than calling them current or rerunning to erase history. Changed criterion definitions or relevant source need new affected runs; a semantic plan change needs renewed coverage and an explicit decision about affected results and reviews.

Assess divergence rationales yourself. A worker may legitimately diverge from a woven norm, and silencing principled divergence is worse than the violation; "woven but inapplicable to this change" is valid and a signal the weave was loose. You judge the rationale, not compliance from the diff, and this never blocks acceptance or edits the worker's output. An unconvincing divergence or a completeness finding opens a non-blocking followup, the review loop's input:

**Recipe inputs:** SCRIPTS_DIR, WORK_TITLE, TASK_SUBJECT, SLUG, CONTENT.
<!-- implement-recipe: followup-divergence -->
```bash
bash "$SCRIPTS_DIR/create-followup.sh" --title "Convention handling: $WORK_TITLE — $TASK_SUBJECT" --source implement \
  --attachments "[{\"type\":\"work_item\",\"slug\":\"$SLUG\"}]" --suggested-actions '[{"type":"create_work_item"}]' --content "$CONTENT"
```

**Write the task's execution-log reduction** immediately after acceptance, one entry per task, never a placeholder before the report arrives, never several tasks in one entry. The body carries these labels in this order, `None` where a field is empty; the `Spend:` line appears only when the report carried `**Spend:**` (chaperone and session routes), copied verbatim with `task=<task-id>` prepended and nothing rewritten or backfilled, and close reads its absence as `spend: null`:

```text
Task: <task subject>
Changes: <worker Changes>
Skills: <worker Skills used>
Tier2-claims: <comma-separated claim ids>
Observations: <worker Observations or Tier 3 summary>
Convention: <worker Convention handling + your assessment: clean | followup-opened: <reason>>
Investigation: <worker Investigation>
Blockers: <worker Blockers>
Consultations: <worker Consultations, verbatim YAML list, or none>
Surfaced concerns: <worker Surfaced concerns, or None>
Test result: <passed|failed|skipped>
Spend: task=<task-id> harness=<h> model=<m> effort=<e|none> input_tokens=<n> duration_seconds=<n> basis=<b>
```

`--template-version` names the text that produced the report — the attempt's producer version — and your own version travels separately as the filing version, so producer and filer stay two headers. Pass the attempt's manifest pair, the same reference you checked the headers against; the writer resolves it, checks that it binds this work item and that its producer version is the one you passed, and writes `Producer-attribution:` as `resolved` or `unknown` with reason — nothing falls back to a template on disk. A `Surfaced concerns:` payload other than `None` goes to the off-scale writer under the producer's resolved version. For a lead-inline task pass your own hash as both versions, no pair, and `PRODUCER_ROLE=implement-lead` so the concern is filed as yours (a lead-inline body also begins with `Report-key: <RUN_STARTED_AT>/<task-id>`):

**Recipe inputs:** SCRIPTS_DIR, SLUG, REDUCTION_FILE, PRODUCER_TEMPLATE_VERSION, LEAD_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256, PRODUCER_ROLE.
<!-- implement-recipe: log-reduction -->
```bash
args=(--slug "$SLUG" --source implement-lead --template-version "$PRODUCER_TEMPLATE_VERSION" --filing-template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256")
[[ -n "$PRODUCER_ROLE" ]] && args+=(--producer-role "$PRODUCER_ROLE")
bash "$SCRIPTS_DIR/write-execution-log.sh" "${args[@]}" < "$REDUCTION_FILE"
```

Other seat entries — route selection, lead-invoked skills (`Lead-invoked skill:` / `Domain:` / `Skill template-version:`), the knowledge fallback line, advisor activation and shutdown — file through the same writer under the version that produced them (yours, or the designer's for its lines):

**Recipe inputs:** SCRIPTS_DIR, SLUG, ENTRY_FILE, TEMPLATE_VERSION.
<!-- implement-recipe: lead-log -->
`bash "$SCRIPTS_DIR/write-execution-log.sh" --slug "$SLUG" --source implement-lead --template-version "$TEMPLATE_VERSION" < "$ENTRY_FILE"`

Set aside any `**Tier 3 candidates:**` block for Step 6 exactly as written, `producer_role` and `source_artifact_ids` included; the source ids are how promotion recovers the candidate's producer. Do not promote here.

**Lead-inline evidence.** Inline work lands the same records with truthful attribution: each Tier 2 row through the writer (compute `normalized_snippet_hash` with the canonical helper, never an inlined recipe), the full schema 1 report with `Producer-role: implement-lead` and `Dispatch-path: lead-inline` landed through the report writer under its attempt-specific id, the reduction above, and a durable read-back before the task is checked off. Comment discipline applies to the lead as to a worker: comments and commit messages are for maintainers, in plain language about what the code does, with the plan's vocabulary and this system's labels kept out.

**Recipe inputs:** SCRIPTS_DIR, SNIPPET.
<!-- implement-recipe: snippet-hash -->
`python3 "$SCRIPTS_DIR/snippet_normalize.py" --hash <<<"$SNIPPET"`

**Recipe inputs:** SCRIPTS_DIR, SLUG, ROW_FILE.
<!-- implement-recipe: append-tier2 -->
`bash "$SCRIPTS_DIR/evidence-append.sh" --file "$ROW_FILE" --work-item "$SLUG"`

**Recipe inputs:** KNOWLEDGE_DIR, SLUG, REPORT_ID, REPORT_KEY.
<!-- implement-recipe: readback-report -->
```bash
ITEM="$KNOWLEDGE_DIR/_work/$SLUG"
test -s "$ITEM/worker-reports/$REPORT_ID.md"
test "$(grep -Fxc "Report-key: $REPORT_KEY" "$ITEM/execution-log.md")" -eq 1
```

The collapse is committed only after every selected task passes read-back; a screen-rendered report or in-memory draft counts for nothing. Count the durable reports and log the gate as fired; a count other than the selected task count halts before promotion, because the collapse did not fire:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, RUN_STARTED_AT, TASK_COUNT, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: inline-commit -->
```bash
LOG="$KNOWLEDGE_DIR/_work/$SLUG/execution-log.md"
REPORT_COUNT="$(grep -Fc "Report-key: $RUN_STARTED_AT/" "$LOG")" || REPORT_COUNT=0
test "$REPORT_COUNT" -eq "$TASK_COUNT"
printf 'Lead-inline execution: gate fired\nDurable per-task reports: %d/%d\n' "$REPORT_COUNT" "$TASK_COUNT" \
  | bash "$SCRIPTS_DIR/write-execution-log.sh" --slug "$SLUG" --source implement-lead --template-version "$LEAD_TEMPLATE_VERSION"
```

### Step 5: Integrate and continue

A read-only task proceeds to its checkbox after acceptance. For a mutating task, worker completion means quiescent, not done: freeze the immutable source manifest, run pre-merge conformance, and integrate from the stable control checkout; a conflict is recorded and aborted, and the seat decides the intended composition, re-dispatches source edits and freezes a new attempt. After a clean merge, freeze the integrated manifest, advance the manager to `cleanup_due`, and clean the tree. Only a full verdict plus proof of path absence, Git-registry absence and branch/ref disposition permits the checkbox; `cleanup_blocked`, missing proof or an unresolved conflict keeps it open. Check off through the writer, then journal the milestone when this run is a hosted session (the three `LORE_SESSION_*` variables are the hosted-session test; an unhosted run skips silently, and a failed append warns without unwinding the acceptance):

**Recipe inputs:** SCRIPTS_DIR, SLUG, TASK_SUBJECT, TASK_ID.
<!-- implement-recipe: check-task -->
```bash
lore work check "$SLUG" "$TASK_SUBJECT"
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash "$SCRIPTS_DIR/session-step.sh" --step-id "implement:task:$TASK_ID" --step-label "Accepted task $TASK_ID" \
    || echo "[implement] Warning: step for task $TASK_ID not journaled; the logged report and checked task remain authoritative." >&2
fi
```

On an adopted item the checkbox writer hands off to the revision writer under the publication lock: with no semantic drift it applies the checkbox and publishes a `progress` revision that inherits the anchor, review and dispatch decisions (`inherited_from_revision` names their source); with drift it refuses, and you record the semantic revision or missing decisions first. A completion never publishes a semantic revision on its own. The journal row asserts the full sequence — report accepted, logged, checkbox persisted — and nothing upstream of it emits; no completion message from a worker means accepted work.

**Rejoin the board eagerly.** After every acceptance, rejection, dispatch, terminus, reconciliation, cleanup, failure or steering transition, ask what is dispatchable; do not wait for unrelated active workers. `next-batch` reconciles progress first (publishing checkbox writes as `progress` revisions on an adopted item, and keeping a legacy item on its old path only when it can prove the bytes are unchanged apart from checkbox state), excludes complete and active tasks, and returns each ready task with its description and a fresh packet, attempt and revision tuple, so Step 2 repeats from the normalize-bindings recipe without changing any evidence obligation:

**Recipe inputs:** SLUG, ACTIVE_TASK_IDS, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: impl-next-batch -->
```bash
args=("$SLUG" --json --template-version "$LEAD_TEMPLATE_VERSION")
for id in $ACTIVE_TASK_IDS; do args+=(--active "$id"); done
lore impl next-batch "${args[@]}"
```

`status: all-blocked` returns you to collecting reports or resolving blockers; `status: all-complete` means every coordinated writer is reconciled and cleanup-verified, and the route's teardown follows — shutdown requests to active workers and designers through the adapter, shutdown lines for activated designers, and `TeamDelete` only where a team was created.

### Step 6: Closure verdict — capture what remains, then close

**Promotion.** Capture happened at discovery, so promotion selects only the uncaptured, grounded candidates: the Tier 3 blocks set aside in Step 4 plus any cross-task candidate you produce from reading the whole `execution-log.md`. Judge each on reusability, grounding and falsifier quality, write the accepted set to a file (JSON array or JSONL of Tier 3 rows with `producer_role` and `source_artifact_ids` preserved), and run the verb on it — including an empty set, which still files `Tier 3 promotion summary: 0 accepted, 0 rejected`, the committed evaluation a later reader looks for. The verb verifies every source id against this item's `task-claims.jsonl`, resolves each source's dispatch reference again and rejects a candidate whose sources read unknown, mix compiled and legacy, or name different compiled versions; `producer_role` must be the legacy role for the source position (`worker`, `advisor`, `researcher`, `spec-lead`, or `implement-lead` for your own), one `lore promote` per candidate so attribution is never merged, and a rejection is a result, not a command failure. The per-run version flags are the historical fallback and never override a compiled candidate's producer; pass your own hash as `--template-version`, because an omitted flag stamps the entry with whatever skill file is installed at that moment:

**Recipe inputs:** SLUG, CANDIDATES_FILE, LEAD_TEMPLATE_VERSION, WORKER_TEMPLATE_VERSION, ADVISOR_TEMPLATE_VERSION.
<!-- implement-recipe: promote-batch -->
```bash
args=("$SLUG" --candidates "$CANDIDATES_FILE" --lead-template-version "$LEAD_TEMPLATE_VERSION" --template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$WORKER_TEMPLATE_VERSION" ]] && args+=(--worker-template-version "$WORKER_TEMPLATE_VERSION")
[[ -n "$ADVISOR_TEMPLATE_VERSION" ]] && args+=(--advisor-template-version "$ADVISOR_TEMPLATE_VERSION")
lore impl promote-batch "${args[@]}"
```

**Salvage.** Three retrospective questions, each with "nothing" as a complete and common answer. Did the run leave you believing something you never checked? File it as a hypothesis with the test that would settle it. Did you carry a question you could not answer? File it with where you looked. These go through capture directly, because a promotion row demands grounding an unchecked belief does not yet have:

**Recipe inputs:** SLUG, INSIGHT, SCALE, KIND, WHERE_LOOKED.
<!-- implement-recipe: capture-discovery -->
```bash
args=(--insight "$INSIGHT" --scale "$SCALE" --producer-role implement-lead --work-item "$SLUG")
case "$KIND" in
  hypothesis) args+=(--kind hypothesis --kind-status untested --protocol-slot salvage) ;;
  question) args+=(--kind question --kind-status open --where-looked "$WHERE_LOOKED" --protocol-slot salvage) ;;
  fact) args+=(--protocol-slot discovery) ;;
  *) echo "capture kind must be fact, hypothesis or question: $KIND" >&2; exit 1 ;;
esac
lore capture "${args[@]}"
```

Did the run cross a settling test an existing hypothesis or open question names? Workers record crossings mid-task; evidence that surfaced only at the seat — in reports, in results, in the composed tree — is recorded here, and settled when the test ran to a decisive result. An undermining observation that matches the named falsifier and leaves `kind_status` untouched is the gap this question exists to close:

**Recipe inputs:** KNOWLEDGE_PATH, DIRECTION, NOTE, SLUG, KIND_STATUS.
<!-- implement-recipe: claim-record -->
```bash
lore claim corroborate "$KNOWLEDGE_PATH" --direction "$DIRECTION" --source implement-lead --work-item "$SLUG" --note "$NOTE"
[[ -z "$KIND_STATUS" ]] || lore claim settle "$KNOWLEDGE_PATH" --kind-status "$KIND_STATUS" --note "$NOTE" --work-item "$SLUG"
```

**Closure verdict.** Compare what shipped against `intent_anchor` and decide `full | partial | none`. The failure this catches is closure laundering: substrate completion — valid claims, every box checked — accepted as capability completion when a load-bearing step was mocked or deferred. Passing commands cannot decide that, which is why the verdict stays authored and `close` refuses to infer it. `full`: the load-bearing capability is operable; write a one-line `capability_loop_summary`. `partial`: a load-bearing step is mocked or deferred; the parent stays active as `capability-incomplete`, with a summary naming what shipped, a `divergence_summary` naming what was mocked or deferred, and a residue title and neutral residue anchor for the deferred capability (describe it in its own terms, never the parent's framing). `none`: no load-bearing capability delivered; also a non-completion, summary naming what was attempted, divergence saying so, no residue child. Ask through `AskUserQuestion` only when the run's evidence cannot ground the call. Four closure layers operate on disjoint signals and none overrides another: the task-system precondition (every checkbox checked, or the close refuses with exit `1`, files the deferred-work followup and records no verdict); the coordinated cleanup precondition (valid immutable source and integrated manifests and cleanup proof for every writer attempt; `full` additionally needs each stream's latest attempt integrated, full and cleaned; Unproven removal across path, Git registry or branch/ref disposition is a failed close with no verdict written); the mechanical followup gate (unchecked tasks or non-`none` blockers file a `Deferred work:` followup, without consulting the anchor); and the anchor verdict, where only `full` permits archive. An item with no anchor takes only `--verdict full` and archives through the mechanical layers alone — closure-time anchor synthesis would be retroactive intake. `lore work check` and this verdict sit at different altitudes: every task checked is the verdict's input, never its conclusion. No automatic audit fires at session end; promotions are audited out of band at calibration time.

Record the session in notes before closing: focus, tasks completed of total, Tier 2 and Tier 3 counts, and what remains or that implementation is complete:

**Recipe inputs:** SLUG, NOTE_FILE.
<!-- implement-recipe: work-note -->
`lore work note "$SLUG" < "$NOTE_FILE"`

Then close through the verb — the sole writer of the `closure` block and of every composed close artifact. `CHECK_TASKS_FILE` lists one subject per line for tasks completed this run whose checkbox might still be unchecked (the verb reconciles before counting); the three role versions keep their legacy meanings on the close row, and per-attempt producers are read from the execution log instead:

**Recipe inputs:** SLUG, VERDICT, SUMMARY, DIVERGENCE, RESIDUE_TITLE, RESIDUE_ANCHOR, CHECK_TASKS_FILE, TIER3_ACCEPTED, TIER3_REJECTED, LEAD_TEMPLATE_VERSION, WORKER_TEMPLATE_VERSION, ADVISOR_TEMPLATE_VERSION, RUN_STARTED_AT.
<!-- implement-recipe: impl-close -->
```bash
args=("$SLUG" --verdict "$VERDICT" --summary "$SUMMARY" --tier3-accepted "$TIER3_ACCEPTED" --tier3-rejected "$TIER3_REJECTED"
      --lead-template-version "$LEAD_TEMPLATE_VERSION" --template-version "$LEAD_TEMPLATE_VERSION" --run-started-at "$RUN_STARTED_AT")
[[ -n "$WORKER_TEMPLATE_VERSION" ]] && args+=(--worker-template-version "$WORKER_TEMPLATE_VERSION")
[[ -n "$ADVISOR_TEMPLATE_VERSION" ]] && args+=(--advisor-template-version "$ADVISOR_TEMPLATE_VERSION")
[[ -n "$DIVERGENCE" ]] && args+=(--divergence "$DIVERGENCE")
[[ -n "$RESIDUE_TITLE" ]] && args+=(--residue-title "$RESIDUE_TITLE" --residue-anchor "$RESIDUE_ANCHOR")
while IFS= read -r subject; do [[ -n "$subject" ]] && args+=(--check-task "$subject"); done < "$CHECK_TASKS_FILE"
lore impl close "${args[@]}"
```

Per-verdict fields: `--divergence` on partial and none; `--residue-title` and `--residue-anchor` on partial; every other combination is refused. The verb runs the composed sequence in load-bearing order, every write through its file's sanctioned writer: reconcile checkboxes and heal; refuse on the task-system precondition; validate reconciliation manifests and cleanup proof; on `partial`, create the residue child before the parent closure so a failed creation leaves the parent untouched; write the closure block (`verdict`, `capability_incomplete`, `capability_loop_summary`, `divergence_summary`, `residue_followup`, `verdict_at`, `intent_anchor_at_close` — read it, never hand-write it); write `retro-bundle.json`, the ten-field producer bundle `/retro` reads — `work_item`, `tasks_completed`, `tier2_claim_ids`, `tier3_promoted_ids`, `advisor_consultations_count`, `blockers`, `template_versions`, `captured_at_sha`, `run_started_at`, and `task_attribution`, the per-task array of freshly resolved producer projections, context estimates and spend — overwritten per run while the canonical artifacts remain historical truth; append one closure log entry; validate the anchored closure block before any archive move; append one `kind=telemetry` scorecard row (`impl_close_bookkeeping`, observability only, never scored, a failed append warns); render the closure conformance aggregate when sampled (a degraded verdict always renders, a routine close when the deterministic coin clears `conformance_sampling.render_rate`, and a sampled-out close announces `lore work conformance <slug>` so eagerness is lost, never evidence); then archive `full` and legacy closes and verify the move before the terminal report renders, so the archive can no longer be skipped once the report's clean-handoff feel lands. Exit `0` is a clean close with the Done report; `1` a precondition refusal; `2` an ambiguous reference; `3` anchor divergence, the parent held open with the banner naming the residue child.

Emit the verb's stdout verbatim as the terminal close, and nothing further. The success summary exists only inside the report script's exit-0 branch, so a divergence path has no success prose to re-emit, and a non-zero exit is the run's non-completion — report it as such rather than following it with a hand-authored success line. On exit `3` the parent remains responsible for the deferred residue until the child delivers it through its own `/spec` and `/implement` cycle.

## Partial completion and resume

When workers hit blockers or the run cannot finish, progress is already durable: accepted tasks are checked off (accepted work only, never work merely reported), open blockers are in `notes.md`, and the remaining capability is named explicitly. Write the session note, report what completed and what remains, and let a later run pick it up; attempting close with unchecked tasks refuses loudly and files the deferred-work followup, which is the correct outcome.

Resuming is the same six steps. `start` re-reads `task-claims.jsonl`, so resumed workers see prior evidence; `open` and `next-batch` exclude already-checked tasks (returned as `already_complete`) and select the remainder, with cross-selection collisions accounted for by you. Each remaining task receives a fresh packet, attempt and report id against the current revision; prior attempts are never overwritten, and their results and reviews stay bound to the revisions they answered. Report `Resuming — N remaining tasks` and continue.
