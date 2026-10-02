---
name: spec
description: "Plan a change that splits across working sets — read the code, decide the design with its reasons, and leave /implement tasks it can execute. One flow: the seat reads and designs itself, and commissions investigators only when one context cannot hold the reading."
user_invocable: true
argument_description: "[--yes] [--model <id>] [name or description] — an existing work item, or a freeform description to start from. `--yes` skips both owner stops. `--model` overrides every role's model for this run; otherwise roles resolve through `lore defaults`. A leading `short` is still accepted; there is one flow."
---

# /spec

You hold the spec seat. A spec writes the plan for a *change*: work that splits across working sets, so someone in another context can build it and someone later can see why it took this shape. Two things in the plan carry that. The design decisions, with their reasons, are what `lore why` later returns for these files. The tasks are what `/implement` executes, and each one is a contract: a deliverable, the files it owns, the constraints on it, and how it closes.

Most work needs no spec. A fix restores specified behavior and a decision gets one rationale row; both go straight to a worker with a brief that is the plan (`skills/coordinate/SKILL.md` § The loop). If the reading shows the work is one task with no real design choice, say so and stop — that is a complete result, and a better one than a plan that dresses one edit as a design.

One context that reads the code itself serves most specs well, so that is the default: you read, you design, you plan. When the reading is wider than one context can hold, or its unknowns genuinely run in parallel, commission investigators for that part (§ Commissioning investigators).

Standalone, you also hold the gates: you read the evidence, stop for the owner twice, and record acceptance. Commissioned by `/coordinate`, the coordinator holds the gates and you do the same work up to them; the seat is bound once, at entry, and nothing else changes with who holds it.

**What stays with you.** The verbs prepare evidence and persist decisions; they do not make them. The questions worth asking, which skills and norms apply, the design and its reasons, how the work splits into tasks, whether a review is warranted, whether feedback changes the plan, and every launch are yours. When a verb looks able to infer one of these, supply the judgment explicitly instead.

**Four things hold everywhere.**

1. **The intent anchor is quoted, never paraphrased.** Publication compares it by string, so a paraphrase breaks the check even when the meaning survives. A narrowing is named in the plan's `**Scope delta:**` line.
2. **Writers are sanctioned.** The plan changes through `lore plan revise`; Tier 2 claims go through `evidence-append.sh`; reports go through `lore coordinate report`; knowledge goes through `lore capture`, `lore correct` and `lore retire`. Nothing writes `tasks.json`, `task-claims.jsonl` or store files by hand.
3. **The task grammar is a contract.** `/implement`'s generator parses it literally. The format lives in [templates/plan.md](templates/plan.md); the vocabulary is pinned in § 4.
4. **Close through `lore spec finalize`.** It owns backlink verification, the anchor gate, task generation, revision publication, healing, the emission and sizing asserts, and telemetry. Don't hand-run its parts.

Every runnable command below is a recipe: its inputs are named on the line before it, it runs on its own in a fresh shell, and a test executes it against an isolated store. Carry values between recipes as variables you set from earlier output.

## 1. Orient

Resolve the store, the scripts beside the `lore` you are running, and this file's version, which stamps what the seat files:

**Recipe inputs:** none.
<!-- spec-recipe: resolve-paths -->
```bash
KNOWLEDGE_DIR="$(lore resolve)"
WORK_DIR="$KNOWLEDGE_DIR/_work"
SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "$(command -v lore)")")/../scripts" && pwd -P)"
SKILL_FILE="$(cd "$SCRIPTS_DIR/.." && pwd -P)/skills/spec/SKILL.md"
LEAD_TEMPLATE_VERSION="$(bash "$SCRIPTS_DIR/template-version.sh" "$SKILL_FILE")"
printf 'KNOWLEDGE_DIR=%s\nWORK_DIR=%s\nSCRIPTS_DIR=%s\nSKILL_FILE=%s\nLEAD_TEMPLATE_VERSION=%s\n' \
  "$KNOWLEDGE_DIR" "$WORK_DIR" "$SCRIPTS_DIR" "$SKILL_FILE" "$LEAD_TEMPLATE_VERSION"
```

The standing defaults bind this run — role routes, preference directives by title:

**Recipe inputs:** none.
<!-- spec-recipe: lore-defaults -->
`lore defaults`

Run the read-only startup verb. `INPUT` may be empty, which asks it to infer the item from the branch; `TRACK` is `short` only when the invocation led with `short`, and is otherwise `full`; `MODEL_OVERRIDE` may be empty:

**Recipe inputs:** INPUT, TRACK, MODEL_OVERRIDE.
<!-- spec-recipe: spec-start -->
```bash
START_INPUT=${INPUT:-__branch_inference__}
START_ARGS=("$START_INPUT" --branch "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)" --json)
[[ "$TRACK" == "short" ]] && START_ARGS+=(--short)
[[ -n "$MODEL_OVERRIDE" ]] && START_ARGS+=(--model "$MODEL_OVERRIDE")
START=$(lore spec start "${START_ARGS[@]}")
printf '%s\n' "$START"
```

Exit 2 means the reference is ambiguous: ask which candidate, then re-run with the exact slug. Route on what it returns:

| Returned | Next |
|---|---|
| `resolved=false`, input given | new work — refine the goal (below) |
| `resolved=false`, no input | ask what to spec; never turn the inferred branch into an item |
| `archived=true` | wait for explicit confirmation (`--yes` does not answer this) |
| `plan_state=none` | § 2 Read |
| `plan_state=investigations-only` | load the findings and any `## Strategy`, then § 3 |
| `plan_state=incomplete` | present what exists and pick up where it stopped |
| `plan_state=follow-up-needed` | read the open questions and do the targeted reading (§ Iterate) |
| `plan_state=synthesis-complete` | load `plan.md`, then § 5 |

**New work.** Restate the request in a sentence or two. Ask two to four questions only where the code cannot answer — scope boundaries, constraints, approach — and skip them when the request is already specific. Create the item with an anchor that names the user-visible outcome, and read it for looseness first: alternatives ("X or Y" admits doing one), comparatives without a bar ("faster"), vague verbs ("support", "improve"), or a meta-instruction with no capability named. One targeted question closes what remains:

**Recipe inputs:** TITLE, SLUG, INTENT_ANCHOR.
<!-- spec-recipe: work-create -->
`lore work create --title "$TITLE" --slug "$SLUG" --intent-anchor "$INTENT_ANCHOR" --json`

**Your packet.** Commissioned, you arrive with a packet the coordinator synthesized; render it, and read its `## Left out by synthesis` list for what was set aside and why:

**Recipe inputs:** PACKET_ID.
<!-- spec-recipe: seat-packet-show -->
`lore packet show "$PACKET_ID"`

Standalone, build your own once the slug is bound. The topic is one line naming what this spec changes; `SCALE_SET` is the bucket that sits at (rubric: `skills/memory/SKILL.md` § Scale-Aware Navigation). Render it with the recipe above:

**Recipe inputs:** SLUG, TOPIC, SCALE_SET.
<!-- spec-recipe: seat-packet-build -->
`lore packet build --work-item "$SLUG" --role coordinator --caller spec-lead --topic "$TOPIC" --scale-set "$SCALE_SET"`

Either way its entries are candidates to check against the code, and a byline says who captured an entry and during what work — context, not weight. Read the item's evidence beside its plan before deciding anything from the plan state alone:

**Recipe inputs:** SLUG.
<!-- spec-recipe: work-show -->
`lore work show "$SLUG" --json`

## 2. Read

Start from what the store already holds, at the altitude you are reading:

**Recipe inputs:** TOPIC, SCALE_SET, LIMIT.
<!-- spec-recipe: knowledge-search -->
`lore search "$TOPIC" --type knowledge --scale-set "$SCALE_SET" --json --limit "$LIMIT"`

**Discovery.** The verb enumerates candidate external skills and agents, preferences, and conventions; it ranks within each source and never decides what applies:

**Recipe inputs:** SLUG.
<!-- spec-recipe: spec-discover -->
```bash
DISCOVERY=$(lore spec discover "$SLUG" --json)
printf '%s\n' "$DISCOVERY"
```

Applicability is yours, and the two kinds pull in opposite directions. External skills and agents are **strict**: keep one only when its stated domain materially contributes to this implementation; lore's own skills are toolchain, never advisors. A match goes in a `**Related skills:**` block beside the investigations (`- /skill-name — why it applies`), which `/implement` reads, and a task whose surface it covers can name it under `**Advisors:**` — `must-consult` when the skill defines invariants a worker has to respect, `on-demand` otherwise. Preferences and conventions are **permissive**: keep anything the work might need to honor, because missing a binding preference costs more than carrying one that turns out not to apply. The whole permissive set becomes the plan's `**Related preferences/conventions:**` manifest, one `[[knowledge:…]] — what to honor` line each. The verb's query seed is the item title, and `/implement`'s close re-runs it seeded from the shipped diff, so a descriptive title is what lets the two passes catch different norms.

**The code.** Read the three to eight files the change turns on. Two habits catch most of what goes wrong later:

- **Check notes against HEAD.** A current-state claim from a sibling item's `notes.md` or other uncommitted prose is verified against the code before it constrains the design. Notes age faster than code.
- **Trace the seams.** When the change adds a field to a shared substrate or inserts a step into an existing gate, trace three things before designing: whether an existing guard intercepts the new state, whether the read model (`_index.json` and the like) projects the field, and whether ordering (archive, move) changes where a later step finds the file.

**Record what you found** in `## Investigations`, one entry per question in the template's shape. Findings go in as they stood; when the question's premise did not hold, that sentence is the finding, and re-asking in narrower words would replace it with the answer the plan expected. Observations — mechanism, rationale, structural footprint — go in unpolished; `None` is a complete value.

A grounded assertion — a claim the design rests on, anchored to a file, line range and exact snippet — goes to Tier 2. Hash the snippet with the canonical helper, never inline:

**Recipe inputs:** SCRIPTS_DIR, SNIPPET.
<!-- spec-recipe: snippet-hash -->
`python3 "$SCRIPTS_DIR/snippet_normalize.py" --hash <<<"$SNIPPET"`

The row's required fields are the set `scripts/validate-tier2.sh` checks; it carries `producer_role: spec-lead`, this file's version, and a `change_context` saying why the reading made the claim relevant. Append it through the sole writer, then mirror it in `evidence.md`; a rejected row stays rejected, and the failure is the record:

**Recipe inputs:** SCRIPTS_DIR, SLUG, ROW_FILE.
<!-- spec-recipe: append-tier2 -->
`bash "$SCRIPTS_DIR/evidence-append.sh" --file "$ROW_FILE" --work-item "$SLUG"`

When a packet entry meets the code, record what happened: `lore verify <entry> held` or `contradicted`, anchored to the file, line range and snippet you read (`lore verify --help` names the flags). A contradiction carries its resolution in the same call — `corrected` when the code settles the question and your evidence covers the claim's scope, `disputed` with a note when it doesn't. Capture what surprised you the moment it does, with `--producer-role spec-lead --work-item <slug>`; the precise framing degrades by the end of a session.

`surfaced_concerns.jsonl` in the item, when present, holds concerns workers raised against an earlier plan. Read the unresolved ones as findings.

### Commissioning investigators

Commission when the reading is wider than one context can hold, or when its unknowns are independent enough to run at once. Each question targets one concern, is answerable by reading, and stands on its own. Discovery stays with you; investigators read the code.

`lore spec open` turns your investigation document into one dispatch directive per question: it builds and records each investigator's packet, compiles the investigator position, binds the attempt, and freezes what the investigator will receive. Launching each directive, reading what comes back, and relaying a finding that changes a sibling's ground are yours. The document's shape, the launch for each route, and collection — landing the report, checking it answers this attempt, appending its assertions, routing its worker leads and unknowns — are in [commissioning.md](commissioning.md). The report contract is `docs/position-report-contracts.md` § Investigator report.

Collected reports enter `## Investigations` like your own reading, and each investigator's observations keep its attribution when you capture from them.

## 3. Design, then the first stop

The design is the abstract plan: Goal, Narrative, Intent Anchor, Design Decisions and, when the change crosses two or more modules, an Architecture Diagram. The template carries each section's shape.

- **Start from the simplest shape that could work.** When the coordinator seeded a strawman, design against it; otherwise sketch one yourself first. A decision that adds mechanism beyond it names, in its `**Rationale:**`, what the simple shape fails to do — and finding that the simple shape works is a decision too, recorded as one. Itemized findings each suggest an addition; the strawman is the counterweight.
- **Organize the findings; don't narrate over them.** A rationale cites the finding or assertion it rests on rather than restating it in looser words. The Narrative is the one place that tells the story.
- **Goal** is one paragraph in a plain register: sentences of at most 25 words, active voice, one idea each, common words, no internal vocabulary that isn't grounded at first use. The Narrative keeps that register where it costs no precision.
- **Intent Anchor** goes in now, not later: the anchor verbatim and its `**Scope delta:**` line (`none — anchor preserved unchanged` by default). Publication refuses an anchored plan without them — code 2 for the missing section, 3 for a diverging body, 4 for a missing delta.
- **Architecture Diagram** is plain ASCII in a fenced block, never Mermaid; `claude-md/review-protocol/followup-template.md` has the conventions.

Publish the abstract plan; the returned `revision_id` is what the stop reads:

**Recipe inputs:** SLUG, REASON, AUTHOR_ROLE.
<!-- spec-recipe: publish-revision -->
`lore plan revise "$SLUG" --reason "$REASON" --author-role "$AUTHOR_ROLE" --json`

`AUTHOR_ROLE` is `spec-lead`. Identical bytes return the current revision; changed bytes publish the next one.

**First stop.** In one message, give the owner what the reading found, ask whether there is a strategy to apply, and present the design, naming the revision. A strategy they give goes into `## Strategy` verbatim and shapes everything after; an existing `## Strategy` is read silently instead of asking again. Wait for their answer unless `--yes` was passed. Commissioned, this stop is the coordinator's to read; post a note naming the revision and wait. In a hosted session, journal the milestone once the design is accepted:

**Recipe inputs:** SCRIPTS_DIR, STEP_ID, STEP_LABEL, LORE_SESSION_INSTANCE, LORE_SESSION_SLUG, LORE_SESSION_TYPE.
<!-- spec-recipe: journal-step -->
```bash
if [[ -n "${LORE_SESSION_INSTANCE:-}" && -n "${LORE_SESSION_SLUG:-}" && -n "${LORE_SESSION_TYPE:-}" ]]; then
  bash "$SCRIPTS_DIR/session-step.sh" --step-id "$STEP_ID" --step-label "$STEP_LABEL" \
    || echo "[spec] Warning: $STEP_ID not journaled; the persisted artifacts remain authoritative." >&2
fi
```

Here `STEP_ID=spec:design` and `STEP_LABEL="Design accepted"`; § 5 uses `spec:plan-ready`. The three `LORE_SESSION_*` variables come from the hosting session and are empty on an unhosted run, which skips silently.

**Review is a judgment, not a step.** When a second reader would catch what you can't — a contract other work will consume, a design you are unsure of, an owner who asked — commission one against a frozen copy of the revision with `lore plan review prepare` — `--ceremony spec-design` for the design, `spec-post-plan` for the tasks — and let the reviewer seal its judgment with `lore plan review seal` (`docs/protocol-evidence.md` § Reviews). A sealed review is one input to the acceptance you record, never the acceptance itself. When none is warranted, none runs.

## 4. Plan the tasks

The tasks build on the accepted design. [templates/plan.md](templates/plan.md) carries the format — headings, fields, markers, and what task generation refuses. This section carries the judgment.

**Name the tempting narrower version.** Under `**Scope delta:**`, add `**Tempting narrower implementation:**`: the version that would look done while missing the anchor. Then check that the Goal, the task constraints and the Verification bar cover the promise it would miss.

**Size each task around one design center** — the single interface, mechanism or subsystem whose shape the worker decides — with at least one real choice left to make about it. "Scope" and "file set" measure how much a task touches; the design center measures how much it decides, and that is what sizing turns on.

- A deliverable spanning several independent design centers splits, even when the parts run in sequence: each keeps its own acceptance, report and premise-wrong exit.
- Work that is only verification, capture, cleanup, a single command, or a sub-edit of another task folds into the task it serves.
- A task's owned files plus its brief fit one worker's context with room to work. When they don't, the split is forced — an over-large task reads well on the page and fails in flight, at the most expensive point to find out.
- A shift in judgment density is a legitimate split point: pulling a judgment-dense core away from a mechanical shell routes each to its own worker tier. A uniform sweep of one mechanism stays one task, because one worker doing one pass beats several repeating the same edit.
- Record the sizing either way: a `**Split rationale:**` for more than one task (what the split buys against its spawn and integration cost), a `**Merge rationale:**` for exactly one (the design center the parts share). Finalize refuses a plan with neither.

**Write each task line as a deliverable.** It names a durable outcome with a building verb (Implement, Refactor, Author, Migrate, Add support for, Wire), the file or surface it owns, and at least one constraint on the worker's choices. Verify, Check, Inspect, Run, Capture, Append, Cross-link, Note and Document-only are never tasks: checks go to the plan's `**Verification:**` bar, captures and notes are the seat's once the plan closes, and single edits fold into the adjacent task. Write a constraint's reason in the codebase's own words — the symbol, flag or error string it protects — because the reason is what a handoff loses first, and a worker who has it can adapt when the letter doesn't fit. When the task answers a concrete failure, include the command or input that reproduces it; a pointer the worker can run outranks a description of what it would show.

**Mark the judgment class** at the end of every task line — `[class: mechanical | standard | judgment-dense]` — which is the worker tier `/implement` routes it to. Finalize refuses an unmarked line.

**Order through files and edges.** Tasks that share a file chain automatically. For an ordering no shared file expresses, end the consuming line with `[depends-on: task-N]`. A task that fixes an interface later tasks rely on says so in its `**Scope:**` as `- Output contract: …`, and its consumers depend on it.

**Deliver norms on two channels.** Distribution is permissive: every surfaced preference or convention whose files, scope or domain overlaps a task goes into that task's `**Knowledge context:**` as a backlink with a line telling the worker what to do with it, duplicated across tasks where several overlap; an entry that overlaps no task stays in the manifest only. Weaving is strict: a norm becomes a constraint clause in the task line — `honor <stable-label> (<what to do>)` beside its backlink — only when it overlaps the task's scope *and* compliance takes judgment a one-line check could not make. Mechanical norms are never woven. The top-level manifest keeps the full surfaced set regardless; the manifest is provenance, the task line is delivery, and the closure conformance read parses both.

**Widen and direct retrieval.** Prefetch per task to widen its `**Knowledge context:**` beyond what the reading surfaced, declaring the scale every time:

**Recipe inputs:** TOPIC, SCALE_SET.
<!-- spec-recipe: prefetch -->
`lore prefetch "$TOPIC" --type knowledge --limit 5 --scale-set "$SCALE_SET"`

Then derive each task's `**Retrieval directive:**` from that task's own files and knowledge context, in the template's form; `lore impl open` resolves it into the worker's packet at dispatch.

**Set the bar once.** `**Verification:**` is the plan's acceptance bar: zero to three behaviors of the changed system a reader can check without reading the diff, rendered into every worker brief. Suite-level certification happens once, at integration, so a bar that asks for it pushes that cost onto every worker. A task's `**Close criteria:**` are a different instrument — exact commands whose exit `lore criteria run` records against a code identity. Budget their timeouts from a measured run, and leave adequacy to whoever reviews (`docs/protocol-evidence.md` § Results).

**Every task keeps a second way to finish.** A worker may report that the task cannot be built as scoped and name the premise that failed. That report comes from someone closer to the ground than the plan was, and it routes to § Iterate rather than to an approximation of a wrong plan. Never write a task whose only expressible outcome is success.

Unknowns the reading could not settle go in `## Open Questions`, each with what would settle it. Publish the concrete plan with the publish-revision recipe; publication also generates `tasks.json`.

<!-- INVARIANT — canonical /spec weave and task-grammar vocabulary. Keep these terms
     stable; the /implement worker report's `Convention handling:` field and the lead's
     completeness comparison key on them, and the task generator and closure
     conformance renderer parse them literally. Drift silently breaks the handoff.
       - "constraint clause" — the imperative norm woven into a task line
       - "woven norm" / "binding norm" — a surfaced norm that became a constraint clause
       - "stable label" — the entry slug/title the backlink resolves to; the
         identifier shared with the worker report and the lead comparison
       - `honor <stable-label>` — the task-line token that, paired with a same-line
         knowledge backlink, is extracted into `tasks.json` as `woven_norms`
       - `**Related preferences/conventions:**` — the audit-manifest block label the
         closure conformance renderer parses as the spec-time panel of
         `closure-conformance.md`
       - `### Task N:` — the unit heading the generator's flat branch discriminates on;
         N is the task's id
       - `[depends-on: task-N]` — the trailing task-line marker parsed into `blockedBy`
       - `- Output contract:` — the `**Scope:**` bullet declaring what a task fixes for
         its consumers -->

## 5. The second stop, then close

**Second stop.** Before finalizing, show the owner the plan they are accepting, in one message:

- five to ten assumptions the plan rests on — each behavioral claim marked `[verified]` or `[unverified]` and traced to its investigation or assertion, each decision with the alternative it set aside, the scope boundaries, and the anchor with its scope delta;
- one summary per task: deliverable, mechanism in a sentence or three, owned files, and what it depends on — headed by the worker count `tasks.json` recommends.

Corrections go back through the sections their traces name; re-present only what changed. Wait for approval unless `--yes` was passed. Commissioned, the coordinator reads this stop. Once it is accepted, journal `spec:plan-ready` (journal-step recipe, `STEP_LABEL="Plan ready"`).

**Settle what the reading crossed.** Reading code routinely answers an open question or walks past a hypothesis's settling test without noticing. Sweep the `### Open questions` and `### Hypotheses` your packets carried against what you found. An answered question becomes a regular capture and is settled, with the note naming the answering entry. A hypothesis whose test you walked past gets one observation, and is settled when the result was decisive. `KIND_STATUS` is empty to corroborate only, or `answered`, `dissolved`, `supported` or `refuted` to settle; "nothing crossed" is a complete answer:

**Recipe inputs:** KNOWLEDGE_PATH, DIRECTION, NOTE, SLUG, KIND_STATUS.
<!-- spec-recipe: claim-record -->
```bash
lore claim corroborate "$KNOWLEDGE_PATH" --direction "$DIRECTION" --source spec-lead --work-item "$SLUG" --note "$NOTE"
[[ -z "$KIND_STATUS" ]] || lore claim settle "$KNOWLEDGE_PATH" --kind-status "$KIND_STATUS" --source spec-lead --work-item "$SLUG" --note "$NOTE"
```

A capture holds up when it pairs what to do with what it replaces and why that fails, uses the codebase's own identifiers, says when it applies, comes from a surprise rather than a summary, and points at `file:line@SHA`.

**Update the theory of the subsystem you touched.** If it has a theory page, read it against what you just learned and revise what no longer describes the code; if it has none and is coherent enough for one, write it, including what it deliberately does not do and why. The page already being current, or no coherent subsystem being touched, both complete this with nothing written:

**Recipe inputs:** SUBSYSTEM, INSIGHT, SLUG, TEMPLATE_VERSION.
<!-- spec-recipe: capture-theory -->
```bash
lore capture --kind theory --subsystem "$SUBSYSTEM" --category architecture --scale architecture,subsystem \
  --insight "$INSIGHT" --producer-role spec-lead --protocol-slot Synthesis --work-item "$SLUG" --template-version "$TEMPLATE_VERSION"
```

**Check the plan against the live tree** — the reads a script cannot make. Every path, symbol and package the plan names resolves; anything that doesn't is marked `(unverified)` where it appears, so the mark is what a later reader checks. Every command the plan tells an agent to run matches the script's current flags. Tier 2 instructions point at the validator's required set rather than listing fields.

Then finalize:

**Recipe inputs:** SLUG, LEAD_TEMPLATE_VERSION.
<!-- spec-recipe: spec-finalize -->
`lore spec finalize "$SLUG" --template-version "$LEAD_TEMPLATE_VERSION"`

Show its output. Exit 3 is the anchor gate or an emission assert, with the verifier's code or the failing task named; exit 2 is an ambiguous reference; exit 1 names its diagnostic. Fix `plan.md` and run it again — a refused run writes no telemetry and no atom. The anchor gate checks that the anchor is preserved and its delta stated, not that the rest of the plan serves it; that read is yours.

Leave a note for whoever picks this up — what was published, what remains:

**Recipe inputs:** SLUG, NOTE_FILE.
<!-- spec-recipe: work-note -->
`lore work note "$SLUG" < "$NOTE_FILE"`

Then mention `/retro <slug>` as available.

## Iterate

Gaps arrive from a worker's premise-wrong report, a review, or the owner. Do the targeted reading — yourself, or by commissioning investigators for just those questions — append the findings, revise the stages the change reaches, and publish. An edit that reaches the abstract sections goes back through the first stop; one confined to tasks goes back through the second.

## Revising this file

Calibrations land at the altitude they were given, in this file's voice, with their evidence in the item that produced them. Prose that teaches a reader to work around a verb is a bug report against the verb: fix the verb and delete the sentence. At steady state this file holds what a spec is for, the judgment it keeps, the hard edges and the task vocabulary; the template, [commissioning.md](commissioning.md) and the verbs carry the rest.
