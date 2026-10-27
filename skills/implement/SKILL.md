---
name: implement
description: "Carry out a work item's plan — the agent holding the plan does the tasks itself, hands one to another agent when one context cannot hold it, the tasks run in parallel, or someone should be able to watch and steer it, and leaves the same records on every route. One flow for standalone and commissioned runs."
user_invocable: true
argument_description: "[--yes] [--model <id>] [work item name] — an existing work item with an unchecked plan. `--yes` answers the anchor gate's misaligned-route question with re-spec; the archived-item confirmation stays interactive. `--model` sets the seat's own model for this run and touches no worker or advisor binding."
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

# /implement

You hold the plan seat. A plan is a set of task contracts someone wrote in another context: a deliverable, the files it owns, the constraints on it, and how it closes. Carrying it out means reading each contract against the code, doing the work, and leaving a record a later reader can check against the tree: commits, result rows from executed criteria, captures made as they arose, the checkbox revision, and one execution-log entry per task naming how it was done and why that fit. That record is the same whoever did the task.

One context that holds the plan serves most of its tasks well, so that is the default: you read the task, you do it, you check it against the whole feature. Hand a task to another agent in three cases: its working set would crowd out your view of the whole; it and its siblings are independent and can actually run at the same time; or it should run as its own session that a person can watch and steer, or that should outlive this one. The mechanics of handing a task on are in [dispatching.md](dispatching.md). Routing a task elsewhere for the model it runs on, or because the standing defaults say so, is a reason too; name it in the task's entry like any other.

Standalone, you hold the seat end to end. Commissioned by `/coordinate`, the coordinator holds acceptance and closure and you do the same work up to them; the seat is bound once, at entry, and nothing else changes with who holds it.

**What stays with you.** The verbs file judgments; they never make them. Whether the plan as written delivers the anchor, which route each task takes, whether what landed composes into the feature, whether a review is warranted, the closure verdict, and what the run taught that nobody checked are yours. When a verb looks able to infer one of these, supply the judgment explicitly instead.

**Vocabulary the verbs validate.** Each verb refuses a token it does not know, so these words are exact: anchor verdict `aligned | misaligned-respec | misaligned-override | abort | legacy-skip` and route `continue | respec | abort` (`lore impl gate-anchor`); consultation handler `lead | skill | agent` (`lore impl consult-log`, `lore impl check-report`); closure verdict `full | partial | none` (`lore impl close`). Rename one only together with the verb's contract, in the same commit.

**Writers are sanctioned.** The plan changes through `lore plan revise`; Tier 2 claims go through `evidence-append.sh`; results come only from `lore criteria run`; reports land through `lore coordinate report`; the execution log is appended by `write-execution-log.sh`; knowledge goes through `lore capture`, `lore correct` and `lore retire`. Nothing writes `tasks.json`, `task-claims.jsonl`, `results.jsonl` or store files by hand.

Work from confidence. Most mistakes are recoverable through ordinary review, and deferring a settled step costs more than an occasional error caught later. Defer at a genuine fork the protocol does not pre-decide, or before a destructive or shared-state operation; not as a default.

Every runnable command below is a recipe: its inputs are named on the line before it, it runs on its own in a fresh shell, and a test executes it against an isolated store. Carry values between recipes as variables you set from earlier output. Shapes in `text` or `json` fences are data for reading, not commands.

## 1. Orient

Resolve the store, the scripts beside the `lore` you are running, and this file's version, which stamps what the seat files. `RUN_STARTED_AT` is read by close:

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

The standing defaults bind this run — role routes, the concurrency ceiling, and the preferences by activity:

**Recipe inputs:** none.
<!-- implement-recipe: lore-defaults -->
`lore defaults`

**Your packet.** Commissioned, you arrive with a packet the coordinator synthesized; render it, and read its `## Left out by synthesis` list for what was set aside and why:

**Recipe inputs:** PACKET_ID.
<!-- implement-recipe: seat-packet-show -->
`lore packet show "$PACKET_ID"`

Start through the start verb, which resolves the reference, validates a structured plan with unchecked work, returns the title and `intent_anchor` verbatim with prior claims, models and template versions, and compiles the worker and designer briefs for the active framework:

**Recipe inputs:** INPUT.
<!-- implement-recipe: impl-start -->
`lore impl start "$INPUT" --compiled-positions --json`

Exit 1 is no match, no `plan.md` (run `/spec` first) or no unchecked task; exit 2 is an ambiguous reference — ask which candidate and re-run. An `archived: true` item waits for explicit confirmation, since the writing verbs refuse archived items. Hold `SLUG`, `ITEM_DIR`, `INTENT_ANCHOR`, the `template_versions` for worker and advisor, and the prior-claims maps. Standalone, build your own packet now that the slug is bound. The topic is one line naming what this run changes; `SCALE_SET` is the bucket that sits at (`skills/memory/SKILL.md` § Scale-Aware Navigation). Render it with the recipe above:

**Recipe inputs:** SLUG, TOPIC, SCALE_SET.
<!-- implement-recipe: seat-packet-build -->
`lore packet build --work-item "$SLUG" --role coordinator --caller implement-lead --topic "$TOPIC" --scale-set "$SCALE_SET"`

Either way its entries are candidates to check against the code, and a byline says who captured an entry and during what work — context, not weight. Read the item's evidence beside its plan, then `plan.md` and `notes.md` themselves; the verb validated structure, and the judgments below read content:

**Recipe inputs:** SLUG.
<!-- implement-recipe: work-show -->
`lore work show "$SLUG" --json`

**Anchor fit.** Decide whether the plan as written delivers the capability the anchor names. No script reads coverage; the sibling verifier checks the block's presence. Start-time verdicts are binary. On `aligned`, write a one-line fit statement. On a gap, name it in one line and route: `misaligned-respec` for a capability-level gap (what `--yes` selects); `misaligned-override` for a scope-level gap you can state as a one-line scope delta naming in-scope versus deferred; or ask, restating the anchor verbatim with re-spec, override and abort as the options, when the gap straddles both or the cost of being wrong is high — `abort` exists only on that path. An item with no anchor takes `legacy-skip`. The verb reads the anchor from `_meta.json`, refuses a field its verdict does not define, and prints `Route:`:

**Recipe inputs:** SLUG, VERDICT, FIT, GAP, SCOPE_DELTA, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: gate-anchor -->
```bash
args=("$SLUG" --verdict "$VERDICT" --template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$FIT" ]] && args+=(--fit "$FIT")
[[ -n "$GAP" ]] && args+=(--gap "$GAP")
[[ -n "$SCOPE_DELTA" ]] && args+=(--scope-delta "$SCOPE_DELTA")
lore impl gate-anchor "${args[@]}"
```

`continue` proceeds; `respec` hands back with `Next: run /spec <slug>`; `abort` stops. Both exits fire before any edit, so an aborted run leaves no stale artifacts beyond the gate row.

**Revision identity.** A plan is a document with a history: every change publishes a revision, `progress` when only checkbox state moved, `semantic` otherwise, and packets, results and reviews name the revision they answered. `open` and `next-batch` reconcile drift through the revision writer before selecting work. Two cases need your hand first. An item with no `tasks.json` at all publishes its first revision, and one with a history but no bound revision is adopted:

**Recipe inputs:** SLUG, REASON.
<!-- implement-recipe: plan-publish -->
`lore plan revise "$SLUG" --reason "$REASON"`

**Recipe inputs:** SLUG.
<!-- implement-recipe: plan-reconcile -->
`lore plan revise "$SLUG" --reconcile`

And a semantic revision leaves its changed tasks with `pending` anchor coverage and review requirement; such a task is left out of a selection until you record coverage and a dispatch decision. A review requirement of `required` or `pending` alone does not exclude a task — covered anchor plus an explicit `proceed`, or a `reuse` naming a prior review and why its scope still applies, makes it eligible while the review is outstanding, because the requirement records an obligation and the seat owns when to run against it. The writer validates task ids against the target revision and accepts only these three objects, each with an authored `by` and `note`:

**Recipe inputs:** SLUG, REVISION_ID, DECISION_ID, DECISIONS_FILE.
<!-- implement-recipe: plan-decision -->
`lore plan revise "$SLUG" --decision-for "$REVISION_ID" --decision-id "$DECISION_ID" --decisions "$DECISIONS_FILE"`

```json
{"anchor_coverage": {"disposition": "covered", "by": "implement-lead", "note": "task-2 delivers the named capability"},
 "dispatch_decision": {"disposition": "proceed", "by": "implement-lead", "note": "review outstanding; scope unchanged", "task_ids": ["task-2"], "prior_review_refs": []}}
```

`review_requirement` is the third (`required | not-required | pending`, with `prior_review_refs`). Acceptance rationale goes in notes, not here.

## 2. Open the work

Selection is your declaration — every task, or a subset by id when resuming or staging across sessions. `open` reconciles the plan, applies the coverage and dispatch decisions, serializes same-file collisions into edges, builds one packet per selected task at the plan's declared scale, and returns the envelope:

**Recipe inputs:** SLUG, TASK_IDS, FALLBACK_SCALE_SET, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: impl-open -->
```bash
args=("$SLUG" --compiled-positions --json --template-version "$LEAD_TEMPLATE_VERSION")
if [[ -n "$TASK_IDS" ]]; then for id in $TASK_IDS; do args+=(--task "$id"); done; else args+=(--all); fi
[[ -n "$FALLBACK_SCALE_SET" ]] && args+=(--fallback-scale-set "$FALLBACK_SCALE_SET")
lore impl open "${args[@]}"
```

What comes back, and what each part is for:

- **`manifest`** is the task graph: one `TaskCreate` per eligible task in plan order, with `add_blocked_by` edges complete inside the selection and edges that leave it as `external_blocked_by`. Each entry carries the identity its work is recorded under — `packet_id`, `revision_id`, `dispatch_attempt_id` — fresh on every preparation. The harness tool calls the manifest names are made only when a task is dispatched onto a route with shared task state; a task you do yourself needs none of them. An empty manifest is success with a `status`.
- **`collisions`** are same-file intersections already folded into edges. Cross-selection collisions are not detected, so on a subset you account for files held by unselected or in-flight tasks yourself. Known overlap consolidates or gets an explicit edge; worktree isolation never waives ownership.
- **`packets`** and **`prior_knowledge`** are the retrieval pass per task. A unit returning `status: needs-prefetch` wants a scale you have not declared: declare it and re-run with `--fallback-scale-set`. A task's packet is your reading when you do the task; it is the candidate set you synthesize when you hand the task on.
- **`tier2_extracts`** are prior canonical rows per task, matched by task id or file overlap.
- **`skill_invocation_map`** (plan `**Related skills:**`, each with its `skill_template_version`) and **`advisors`** (`mode: persistent` declarations only) say which outside expertise the plan asked for. Doing a task yourself, you invoke a related skill with the `Skill` tool and answer your own questions from code, plan and notes. Consultations exist only across a dispatch boundary; a task declaring `**Consultations required:**` domains gets its answers through the handler in [dispatching.md](dispatching.md).
- **`position_binding_inputs`** on each entry are the ingredients a dispatch binds; report id, report path and execution root are added after placement.

**Route each task.** Do it here unless one of the three cases above holds; then read [dispatching.md](dispatching.md) for the route that fits — a native subagent, a hosted session, or the Codex chaperone — and what it needs. Task classes (`mechanical`, `standard`, `judgment-dense`) are the worker tiers the standing defaults route to; an explicit per-run route pin wins over them. Concurrency stays inside the settings ceiling, lowered to the runtime capacity you actually have; coordinated work also intersects with `lore coordinate status` so only `act_now` streams launch.

A task that mutates the tree needs a tree someone owns. The seat's own tree is yours to edit. A mutating native subagent works inside a tree allocated to this seat; a hosted session gets its tree from the store's session host. Read-only work needs no worktree, and a dispatched agent never allocates one.

## 3. Do the task

Read the contract against the code before editing: the deliverable, the owned files, each constraint and the reason the plan gave for it, and the close criteria. A constraint whose reason no longer fits the code is a finding, not an instruction to follow anyway; note what you did instead in the task's entry. When the task cannot be built as scoped, say which premise failed and route it back to `/spec` (§ Partial completion and resume) rather than approximating a wrong plan — that report comes from someone closer to the ground than the plan was, and the same is true when a dispatched agent sends it.

**The record a task leaves**, whoever did it:

- **Commits** in the tree the task owns, with messages for maintainers in plain language about what the code does; the plan's vocabulary and this system's labels stay out of them.
- **Tier 2 rows** for each grounded assertion the work rests on — a claim anchored to a file, line range and exact snippet, with its falsifier. Hash the snippet with the canonical helper; the row's required fields are the set `validate-tier2.sh` checks, with `producer_role` `implement-lead` for your own rows and the attempt's `position_dispatch` pair on a dispatched agent's:

**Recipe inputs:** SCRIPTS_DIR, SNIPPET.
<!-- implement-recipe: snippet-hash -->
`python3 "$SCRIPTS_DIR/snippet_normalize.py" --hash <<<"$SNIPPET"`

**Recipe inputs:** SCRIPTS_DIR, SLUG, ROW_FILE.
<!-- implement-recipe: append-tier2 -->
`bash "$SCRIPTS_DIR/evidence-append.sh" --file "$ROW_FILE" --work-item "$SLUG"`

- **Result rows** from the close criteria, run through the executor. A row means a command ran against a recorded revision and code identity; nobody types one. Inside a dispatched attempt the packet id fixes work item, task, revision and attempt; outside one, name the revision and say why the run is unbound:

**Recipe inputs:** SLUG, TASK_ID, CRITERION_ID, EXECUTION_ROOT, PACKET_ID, REVISION_ID, UNBOUND_REASON.
<!-- implement-recipe: criteria-run -->
```bash
args=("$SLUG" "$TASK_ID" "$CRITERION_ID" --execution-worktree "$EXECUTION_ROOT" --json)
if [[ -n "$PACKET_ID" ]]; then args+=(--packet-id "$PACKET_ID"); else args+=(--revision "$REVISION_ID" --unbound-reason "$UNBOUND_REASON"); fi
lore criteria run "${args[@]}"
```

   States stay distinct and are reported as they are, never rerun until one passes: `pass`; `fail`; `skipped`, which means only that the applicability predicate observed its declared inapplicable exit; `unavailable`, where execution could not provide a usable outcome and the launch and output facts are retained. A row whose source head, worktree digest, criterion version or revision no longer matches the live root reads stale. An interrupted run is recovered without executing anything, keeping its sequence; a new execution after a fail is a new run with a new id:

**Recipe inputs:** SLUG, RESULT_ID.
<!-- implement-recipe: criteria-recover -->
`lore criteria run "$SLUG" --recover "$RESULT_ID"`

   A task with no executable criteria is an explicit absence of execution evidence: publish criteria through the revision writer, or say in the entry why your acceptance is a prose judgment.

- **Captures** at the moment of discovery, with `--producer-role implement-lead --work-item <slug>` for your own and the position's role for a dispatched agent's; the precise framing degrades by the end of a session. When a packet entry meets the code, `lore verify <entry> held` or `contradicted`, anchored to what you read; a contradiction carries its resolution in the same call.
- **The task's execution-log entry**, written once the task is done and read, never before. One entry per task, these labels in this order, `None` or `none` where a field is empty, and the `Spend:` line only when a dispatched report carried `**Spend:**` (copied with `task=<task-id>` prepended and nothing rewritten; close joins it to the task):

```text
Task: <task-id> — <subject>
Route: <seat | native | session | chaperone> — <why it fit>
Changes: <file: what changed, per file>
Results: <result ids, or none>
Tier2-claims: <claim ids, or none>
Captures: <entry paths, or none>
Surfaced concerns: <off-scale concerns, or None>
Blockers: <none, or what blocks>
Spend: task=<task-id> harness=<h> model=<m> effort=<e|none> input_tokens=<n> duration_seconds=<n> basis=<b>
```

   `--template-version` names the text that produced the work — yours for a task you did, the attempt's producer version for a dispatched one, with the manifest pair the binder returned so the record shows which brief produced it — and your own version travels as the filing version. A `Surfaced concerns:` payload other than `None` is forwarded to the off-scale writer under the producer's role. Advisor activations and other seat notes go through the same writer with your version alone:

**Recipe inputs:** SCRIPTS_DIR, SLUG, ENTRY_FILE, PRODUCER_TEMPLATE_VERSION, LEAD_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256, PRODUCER_ROLE.
<!-- implement-recipe: log-entry -->
```bash
args=(--slug "$SLUG" --source implement-lead --template-version "$PRODUCER_TEMPLATE_VERSION" --filing-template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256")
[[ -n "$PRODUCER_ROLE" ]] && args+=(--producer-role "$PRODUCER_ROLE")
bash "$SCRIPTS_DIR/write-execution-log.sh" "${args[@]}" < "$ENTRY_FILE"
```

A dispatched agent's account reaches this record as its landed report; that is the transport for what it did, and § Collecting in [dispatching.md](dispatching.md) is how the report is read against the attempt it answers. Its `**Tier 3 candidates:**` block is set aside for close exactly as written.

## 4. Integrate

Read what landed — your own work or a dispatched agent's — against the task's contract and against the whole feature: does it compose with the tasks around it, did the checks show what the contract asked, what did it not do. Changed files, canonical claims and result outputs are what you read; a report's manifest points at them. Where a mutating task ran in another tree, integration goes through the coordination substrate: freeze the immutable source manifest, run pre-merge conformance, integrate from the stable control checkout, then freeze the integrated manifest and clean the tree — a conflict is recorded and the seat decides the intended composition. The checkbox waits for proof of path absence, Git-registry absence and branch/ref disposition; `cleanup_blocked` or an unresolved conflict keeps it open.

A worker's divergence from a woven norm is yours to read. "Woven but inapplicable to this change" is a legitimate rationale and a signal the weave was loose; record your reading in the task's entry, raise an unconvincing one when the change is reviewed, and tighten the weave in the next plan you write. Nothing here edits the worker's output.

**Review is a judgment, not a step.** When a second reader would catch what you can't — a contract other tasks consume, a change you are unsure of, a person who asked — prepare a frozen copy at the attempt's revision against the execution worktree, write the judgment, and seal it once. The `spec-post-plan` label with `purpose: integration` stores an implementation read and invokes nothing from `/spec`; prepare needs a stored anchor:

**Recipe inputs:** SLUG, ATTEMPT_ID, REVISION_ID, EXECUTION_ROOT.
<!-- implement-recipe: review-prepare -->
`lore plan review prepare "$SLUG" --attempt-id "$ATTEMPT_ID" --ceremony spec-post-plan --revision "$REVISION_ID" --purpose integration --execution-worktree "$EXECUTION_ROOT" --json`

**Recipe inputs:** SLUG, ATTEMPT_ID, OUTPUT_FILE, DISPOSITIONS_FILE, EVALUATOR_FILE.
<!-- implement-recipe: review-seal -->
`lore plan review seal "$SLUG" --attempt-id "$ATTEMPT_ID" --output "$OUTPUT_FILE" --dispositions "$DISPOSITIONS_FILE" --evaluator-manifest "$EVALUATOR_FILE" --json`

Seal validates each cited result id against `results.jsonl` and freezes the rows; `docs/protocol-evidence.md` § Reviews has the dispositions shape. A sealed review is one input to the acceptance you record, never the acceptance itself. When none is warranted, none runs.

**Accept and check off.** Record your acceptance in a note with the result and review ids it rests on, then check the task off through the writer. Checkoff publishes a progress revision, and result freshness compares exact revision ids, so those rows become historical the moment the box is checked; keep their ids rather than rerunning to erase history. A semantic plan change needs renewed coverage and a decision about affected results and reviews. In a hosted session the milestone is also journaled; an unhosted run skips silently:

**Recipe inputs:** SCRIPTS_DIR, SLUG, TASK_SUBJECT, TASK_ID.
<!-- implement-recipe: check-task -->
```bash
lore work check "$SLUG" "$TASK_SUBJECT"
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash "$SCRIPTS_DIR/session-step.sh" --step-id "implement:task:$TASK_ID" --step-label "Accepted task $TASK_ID" \
    || echo "[implement] Warning: step for task $TASK_ID not journaled; the logged entry and checked task remain authoritative." >&2
fi
```

**Rejoin the board.** After every acceptance, dispatch, terminus or blocker, ask what is dispatchable now rather than waiting on unrelated work. `next-batch` reconciles progress, excludes complete and active tasks, and returns each ready task with a fresh packet, attempt and revision tuple, so § 2's route judgment repeats per task:

**Recipe inputs:** SLUG, ACTIVE_TASK_IDS, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: impl-next-batch -->
```bash
args=("$SLUG" --json --template-version "$LEAD_TEMPLATE_VERSION")
for id in $ACTIVE_TASK_IDS; do args+=(--active "$id"); done
lore impl next-batch "${args[@]}"
```

`all-blocked` returns you to in-flight work or blockers; `all-complete` means every writer is reconciled and cleaned, and whatever was dispatched is torn down (§ Teardown in [dispatching.md](dispatching.md)).

## 5. Close

**Promotion.** Capture happened at discovery, so promotion selects only the uncaptured, grounded candidates: the Tier 3 blocks set aside from reports plus any cross-task candidate you draw from reading the whole `execution-log.md`. Judge each on reusability, grounding and falsifier quality, write the accepted set to a file (JSON array or JSONL of Tier 3 rows with `producer_role` and `source_artifact_ids` kept), and run the verb on it — an empty set still files the `0 accepted, 0 rejected` summary a later reader looks for. The verb verifies every source id against this item's `task-claims.jsonl`, runs one `lore promote` per candidate so attribution is never merged, and reports a rejection as a result:

**Recipe inputs:** SLUG, CANDIDATES_FILE, LEAD_TEMPLATE_VERSION, WORKER_TEMPLATE_VERSION, ADVISOR_TEMPLATE_VERSION.
<!-- implement-recipe: promote-batch -->
```bash
args=("$SLUG" --candidates "$CANDIDATES_FILE" --lead-template-version "$LEAD_TEMPLATE_VERSION" --template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$WORKER_TEMPLATE_VERSION" ]] && args+=(--worker-template-version "$WORKER_TEMPLATE_VERSION")
[[ -n "$ADVISOR_TEMPLATE_VERSION" ]] && args+=(--advisor-template-version "$ADVISOR_TEMPLATE_VERSION")
lore impl promote-batch "${args[@]}"
```

**Salvage.** Two questions, each with "nothing" as a complete and common answer. Did the run leave you believing something you never checked? File it as a hypothesis with the test that would settle it. Did you carry a question you could not answer? File it with where you looked. Both go through capture directly, because a promotion row demands grounding an unchecked belief does not have:

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

Did the run cross a settling test an existing hypothesis or open question names? Evidence that surfaced only at the seat — in reports, results or the composed tree — is recorded here, and settled when the test ran to a decisive result. `KIND_STATUS` is empty to corroborate only, or `answered`, `dissolved`, `supported` or `refuted` to settle:

**Recipe inputs:** KNOWLEDGE_PATH, DIRECTION, NOTE, SLUG, KIND_STATUS.
<!-- implement-recipe: claim-record -->
```bash
lore claim corroborate "$KNOWLEDGE_PATH" --direction "$DIRECTION" --source implement-lead --work-item "$SLUG" --note "$NOTE"
[[ -z "$KIND_STATUS" ]] || lore claim settle "$KNOWLEDGE_PATH" --kind-status "$KIND_STATUS" --note "$NOTE" --work-item "$SLUG"
```

**Closure verdict.** Compare what shipped against `intent_anchor` and decide `full | partial | none`. Every box checked is the verdict's input, never its conclusion: substrate completion — valid claims, passing commands — can coexist with a load-bearing step that was mocked or deferred, and only a reading of the capability tells the two apart, which is why the verdict stays authored and `close` refuses to infer it. `full`: the load-bearing capability is operable; write a one-line `capability_loop_summary`. `partial`: a load-bearing step is mocked or deferred; the parent stays open as `capability-incomplete`, with a summary naming what shipped, a `divergence_summary` naming what was deferred, and a residue title and anchor for the deferred capability described in its own terms. `none`: no load-bearing capability delivered; summary and divergence, no residue. Ask only when the run's evidence cannot ground the call. An item with no anchor takes only `full` and archives through the mechanical layers alone.

Record the session in notes before closing — focus, tasks completed of total, what remains or that the work is complete:

**Recipe inputs:** SLUG, NOTE_FILE.
<!-- implement-recipe: work-note -->
`lore work note "$SLUG" < "$NOTE_FILE"`

Then close through the verb, the sole writer of the `closure` block. `CHECK_TASKS_FILE` lists one subject per line for tasks whose checkbox might still be unchecked; the verb reconciles before counting, refuses while any task is unchecked, and refuses a field its verdict does not take — `--divergence` on partial and none, the residue pair on partial:

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

Close runs its sequence in load-bearing order through each file's writer: reconcile and heal, validate reconciliation manifests and cleanup proof for every writer attempt, create the residue child before the parent closure on `partial`, write the closure block, write `retro-bundle.json` (the producer bundle `/retro` reads, with per-task attribution and spend), log, archive a `full` close and verify the move. Exit 0 is a clean close; exit 3 is a `partial` or `none` close with the parent held open and the residue named; exit 1 is a refusal with no verdict written. Emit the verb's stdout verbatim as the terminal message and add nothing after it — a non-zero exit is the run's outcome, reported as such.

## Partial completion and resume

When the run cannot finish, progress is already durable: accepted tasks are checked off, blockers are in `notes.md`, and the remaining capability is named. A task whose premise failed goes back to `/spec` with the finding; write the session note, say what completed and what remains, and let a later run pick it up. Attempting close with unchecked tasks refuses loudly, which is the right outcome.

Resuming is the same flow. `start` re-reads `task-claims.jsonl`, so prior evidence is in view; `open` and `next-batch` return already-checked tasks as `already_complete` and select the remainder, each with a fresh packet, attempt and revision against the current revision. Prior attempts are never overwritten, and their results and reviews stay bound to the revisions they answered.

## Revising this file

Calibrations land at the altitude they were given, in this file's voice, with their evidence in the item that produced them. Prose that teaches a reader to work around a verb is a bug report against the verb: fix the verb and delete the sentence. At steady state this file holds what carrying out a plan is for, the judgments the seat keeps, the record every route leaves, and the vocabulary the verbs validate; [dispatching.md](dispatching.md) and the verbs carry the rest.
